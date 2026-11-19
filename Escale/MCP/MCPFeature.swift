import AppKit
import Foundation
import Observation
import EscaleCore

/// Accès des agents IA (serveur MCP local). Hors de ce module, l'app ne connaît que `AgentAccess` (fiche d'hôte).
///
/// Règles (AGENTS.md, invariant 21) :
/// - désactivé par défaut ; socket Unix 0600 dans un dossier 0700, pair limité à l'uid de l'utilisateur, aucune écoute TCP ;
/// - seuls les hôtes SSH de la bibliothèque dont `agentAccess != .none` sont visibles ;
/// - par défaut aucun maître n'est ouvert pour un agent ; si l'utilisateur active `allowAutoConnect`, un hôte exposé
///   peut être connecté à la demande (avec confirmation sur les hôtes `confirm`) et son bail est libéré à l'arrêt ;
/// - les actions sur un hôte `confirm` attendent l'accord de l'utilisateur (panneau flottant, sans vol de focus) ;
/// - chaque appel est journalisé en mémoire (jamais sur disque, jamais de contenu de fichier ni de sortie).
@MainActor
@Observable
final class MCPFeature: AppFeature {
    static let enabledKey = "mcp.enabled"
    static let autoConnectKey = "mcp.autoConnect"
    static let selfTestSuite = "com.attila-krb.Escale.selftest-mcp"
    static let maxJournal = 500

    /// Une demande de confirmation en attente.
    struct Confirmation: Identifiable {
        let id: UUID
        let client: String
        let tool: MCPCatalog.Tool
        let hostName: String
        /// Ce que l'agent veut faire, tel quel (commande, texte saisi, chemin, tunnel).
        let detail: String
        fileprivate let resume: (Bool) -> Void
    }

    struct JournalEntry: Identifiable, Equatable {
        enum Outcome: Equatable {
            case allowed, approved, refusedByUser, denied(String), failed(String)
        }
        let id = UUID()
        let date: Date
        let client: String
        let tool: String
        let hostName: String?
        let summary: String
        var outcome: Outcome
    }

    private(set) var isEnabled = false
    private(set) var allowAutoConnect = false
    private(set) var isRunning = false
    private(set) var serverError: String?
    private(set) var clientCount = 0
    private(set) var journal: [JournalEntry] = []
    private(set) var pending: [Confirmation] = []
    /// Liens SSH ouverts à la demande pour les agents (conservés entre appels jusqu'à l'arrêt ou la désactivation).
    private(set) var agentRetainedLinks: [UUID: SSHLink] = [:]
    /// État détecté des clients IA (`agy`, Claude Code, Claude Desktop, Codex).
    private(set) var clientStatuses: [AIClientKind: AIClientStatus] = [:]
    /// Message de retour suite à une action de configuration / copie d'un client IA.
    private(set) var clientActionMessage: String?
    private(set) var clientActionIsError = false
    var isSettingsPresented = false

    /// Recettes : réponse automatique aux confirmations (aucun panneau). nil = demander à l'utilisateur.
    @ObservationIgnored var confirmationOverride: ((Confirmation) -> Bool)?
    @ObservationIgnored private(set) weak var model: AppModel?
    @ObservationIgnored private var server: MCPSocketServer?
    @ObservationIgnored private var defaults: UserDefaults = .standard
    @ObservationIgnored private lazy var panel = MCPConfirmationPanel(feature: self)
    @ObservationIgnored var clientConfigurator = AIClientConfigurator()

    let socketPath = MCPEndpoint.socketPath()

    var activeAgentLinkCount: Int { agentRetainedLinks.count }

    func attach(_ model: AppModel) {
        self.model = model
        // Une recette n'écoute jamais sur le socket réel et ne lit pas les préférences de l'utilisateur.
        if model.options.isSelfTest { defaults = UserDefaults(suiteName: Self.selfTestSuite) ?? .standard }
        allowAutoConnect = defaults.bool(forKey: Self.autoConnectKey)
        model.connections.linkObservers["mcp"] = { [weak self] link, event in
            guard event == .disconnected else { return }
            self?.handleLinkDisconnected(link)
        }
        if defaults.bool(forKey: Self.enabledKey) { setEnabled(true) }
    }

    func shutdown() async {
        releaseAgentLinks()
        await stopServer()
        for c in pending { c.resume(false) }
        pending.removeAll()
        panel.update()
    }

    // MARK: Activation

    func setEnabled(_ on: Bool) {
        isEnabled = on
        defaults.set(on, forKey: Self.enabledKey)
        if on { startServer() } else { Task { await stopServer() } }
    }

    func setAutoConnect(_ on: Bool) {
        allowAutoConnect = on
        defaults.set(on, forKey: Self.autoConnectKey)
        if !on { releaseAgentLinks() }
    }

    /// Libère tous les liens SSH ouverts à la demande pour les agents (les onglets utilisateur restent intacts).
    func disconnectAgentLinks() {
        releaseAgentLinks()
    }

    private func releaseAgentLinks() {
        guard !agentRetainedLinks.isEmpty else { return }
        let links = Array(agentRetainedLinks.values)
        agentRetainedLinks.removeAll()
        for link in links {
            link.release()
        }
    }

    private func handleLinkDisconnected(_ link: SSHLink) {
        guard let held = agentRetainedLinks[link.profile.id], held === link else { return }
        agentRetainedLinks.removeValue(forKey: link.profile.id)
        link.tabCount = max(0, link.tabCount - 1)
    }

    private func startServer() {
        guard server == nil else { return }
        let provider = MCPAppProvider(feature: self)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let s = MCPSocketServer(socketPath: socketPath, onEvent: { [weak self] e in
            Task { @MainActor in self?.serverEvent(e) }
        }, makeSession: { id in MCPSession(provider: provider, serverVersion: version, connectionID: id) })
        do {
            try s.start()
            server = s; isRunning = true; serverError = nil
        } catch {
            serverError = "\(error)"
            isRunning = false
        }
    }

    private func stopServer() async {
        releaseAgentLinks()
        guard let s = server else { return }
        server = nil; isRunning = false; clientCount = 0
        await Task.detached { s.stop() }.value
    }

    private func serverEvent(_ e: MCPSocketServer.Event) {
        switch e {
        case .connected: clientCount += 1
        case .disconnected: clientCount = max(0, clientCount - 1)
        case .rejectedPeer: break
        }
    }

    func clearJournal() { journal.removeAll() }

    /// Commande à copier pour déclarer Escale à un client MCP.
    var executablePath: String { Bundle.main.executablePath ?? "/Applications/Escale.app/Contents/MacOS/Escale" }
    var claudeCodeCommand: String { AIClientConfigurator.copySnippet(for: .claudeCode, executablePath: executablePath) }
    var jsonConfiguration: String { AIClientConfigurator.jsonSnippet(executablePath: executablePath) }
    var codexTOMLConfiguration: String { AIClientConfigurator.codexTOMLSnippet(executablePath: executablePath) }

    // MARK: Configuration des clients IA (agy, Claude, Codex)

    func refreshClientStatuses() {
        let exe = executablePath
        var next: [AIClientKind: AIClientStatus] = [:]
        for client in AIClientKind.allCases {
            next[client] = clientConfigurator.status(for: client, executablePath: exe)
        }
        clientStatuses = next
    }

    func status(for client: AIClientKind) -> AIClientStatus {
        clientStatuses[client] ?? clientConfigurator.status(for: client, executablePath: executablePath)
    }

    func installClient(_ client: AIClientKind) {
        do {
            try clientConfigurator.install(for: client, executablePath: executablePath)
            if !isEnabled { setEnabled(true) }
            refreshClientStatuses()
            clientActionIsError = false
            clientActionMessage = String(localized: "\(client.displayName) configuré (\(client.displayConfigPath)).")
        } catch {
            refreshClientStatuses()
            clientActionIsError = true
            clientActionMessage = String(localized: "Impossible de configurer \(client.displayName) : \(error.localizedDescription)")
        }
    }

    func uninstallClient(_ client: AIClientKind) {
        do {
            try clientConfigurator.uninstall(for: client)
            refreshClientStatuses()
            clientActionIsError = false
            clientActionMessage = String(localized: "Entrée Escale retirée de \(client.displayName).")
        } catch {
            refreshClientStatuses()
            clientActionIsError = true
            clientActionMessage = String(localized: "Impossible de modifier \(client.displayName) : \(error.localizedDescription)")
        }
    }

    func copySnippet(for client: AIClientKind) {
        let snippet = AIClientConfigurator.copySnippet(for: client, executablePath: executablePath)
        copyToPasteboard(snippet, label: client.displayName)
    }

    func copyToPasteboard(_ text: String, label: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        clientActionIsError = false
        clientActionMessage = String(localized: "Configuration copiée pour \(label).")
    }

    /// Tous les hôtes SSH enregistrés dans la bibliothèque, triés par nom.
    var sshHosts: [HostProfile] {
        (model?.library.library.hosts ?? [])
            .filter { $0.connectionProtocol == .ssh }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Met à jour le niveau d'accès agent d'un hôte SSH directement depuis la fenêtre Agents IA.
    func setHostAccess(_ access: AgentAccess, for host: HostProfile) {
        guard host.agentAccess != access else { return }
        var updated = host
        updated.agentAccess = access
        model?.library.upsert(updated)
    }

    // MARK: Confirmations

    func respond(_ id: UUID, approved: Bool) {
        guard let i = pending.firstIndex(where: { $0.id == id }) else { return }
        let c = pending.remove(at: i)
        c.resume(approved)
        panel.update()
    }

    private func confirm(_ tool: MCPCatalog.Tool, client: String, host: HostProfile, detail: String) async -> Bool {
        if Task.isCancelled { return false }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                var done = false
                let c = Confirmation(id: id, client: client, tool: tool, hostName: host.name, detail: detail) { ok in
                    guard !done else { return }
                    done = true
                    cont.resume(returning: ok)
                }
                if let o = confirmationOverride { c.resume(o(c)); return }
                pending.append(c)
                panel.update()
            }
        } onCancel: {
            // Client déconnecté : la demande disparaît (refus). Sans effet si elle a déjà reçu sa réponse.
            Task { @MainActor [weak self] in self?.respond(id, approved: false) }
        }
    }

    // MARK: Journal

    private func log(_ client: String, _ tool: MCPCatalog.Tool, _ host: HostProfile?, _ summary: String,
                     _ outcome: JournalEntry.Outcome) {
        journal.append(JournalEntry(date: Date(), client: client, tool: tool.rawValue, hostName: host?.name,
                                    summary: String(summary.prefix(300)), outcome: outcome))
        if journal.count > Self.maxJournal { journal.removeFirst(journal.count - Self.maxJournal) }
    }

    // MARK: Outils

    /// Hôtes visibles des agents : SSH, dans la bibliothèque, accès différent de `none`.
    var exposedHosts: [HostProfile] {
        (model?.library.library.hosts ?? []).filter { $0.connectionProtocol == .ssh && $0.agentAccess.allowsVisibility }
    }

    private struct ToolFailure: Error {
        let message: String
        var alreadyLogged = false
    }

    private func isHostConnected(_ host: HostProfile) -> Bool {
        model?.connections.existing(host.id)?.links.contains(where: { $0.state == .connected }) == true
    }

    private func toolRequiresConnectedLink(_ tool: MCPCatalog.Tool) -> Bool {
        switch tool {
        case .connectHost, .exec, .listFiles, .readFile, .writeFile, .startTunnel: true
        case .listHosts, .listSessions, .readTerminal, .sendInput, .listTunnels, .stopTunnel: false
        }
    }

    private static func notConnectedMessage(for host: HostProfile) -> String {
        "host '\(host.name)' is not connected: ask the user to open it in Escale first (or enable on-demand agent connections in Escale)"
    }

    private func host(_ args: MCPArguments) throws -> HostProfile {
        let key = try args.string("host").trimmingCharacters(in: .whitespaces)
        let hosts = exposedHosts
        if let id = UUID(uuidString: key), let h = hosts.first(where: { $0.id == id }) { return h }
        let named = hosts.filter { $0.name == key }
        if named.count == 1 { return named[0] }
        if named.count > 1 { throw ToolFailure(message: "several hosts are named '\(key)': use the host id") }
        throw ToolFailure(message: "unknown host '\(key)' (or not exposed to agents): see list_hosts")
    }

    /// Lien maître connecté, retenu pour la durée de l'appel (l'appelant libère par `link.release()`).
    /// Si l'hôte est déconnecté et `allowAutoConnect` est actif, ouvre la connexion à la demande et garde un bail
    /// dans `agentRetainedLinks` pour les appels suivants.
    private func connectedLink(_ host: HostProfile, client: String, alreadyConfirmed: Bool) async throws -> SSHLink {
        if let existing = model?.connections.existing(host.id)?.links.first(where: { $0.state == .connected }) {
            existing.cancelGrace()
            existing.tabCount += 1
            return existing
        }
        guard allowAutoConnect else {
            throw ToolFailure(message: Self.notConnectedMessage(for: host))
        }
        guard let model else { throw ToolFailure(message: "application stopped") }
        let targetDetail = host.port.map { "\(host.target):\($0)" } ?? host.target
        if host.agentAccess == .confirm && !alreadyConfirmed {
            guard await confirm(.connectHost, client: client, host: host, detail: targetDetail) else {
                log(client, .connectHost, host, targetDetail, .refusedByUser)
                throw ToolFailure(message: "the user refused this action in Escale", alreadyLogged: true)
            }
            log(client, .connectHost, host, targetDetail, .approved)
        }
        let link: SSHLink
        let createdLease: Bool
        if let held = agentRetainedLinks[host.id] {
            link = held
            createdLease = false
        } else {
            link = model.connections.connection(for: host).acquireLink()
            agentRetainedLinks[host.id] = link
            createdLease = true
        }
        do {
            try await link.ensureConnected()
        } catch {
            if createdLease, agentRetainedLinks[host.id] === link {
                agentRetainedLinks.removeValue(forKey: host.id)
                link.release()
            }
            throw ToolFailure(message: link.message(for: error))
        }
        guard isRunning, allowAutoConnect else {
            if createdLease, agentRetainedLinks[host.id] === link {
                agentRetainedLinks.removeValue(forKey: host.id)
                link.release()
            }
            throw ToolFailure(message: "agent access or auto-connect was disabled while connecting")
        }
        link.cancelGrace()
        link.tabCount += 1
        return link
    }

    private var panes: [Pane] { model?.workspace.tabs.flatMap(\.panes) ?? [] }

    private func pane(_ args: MCPArguments) throws -> (Pane, HostProfile) {
        let key = try args.string("session_id")
        let visible = Dictionary(uniqueKeysWithValues: exposedHosts.map { ($0.id, $0) })
        guard let id = UUID(uuidString: key), let p = panes.first(where: { $0.id == id }),
              let hid = p.hostID, let h = visible[hid] else {
            throw ToolFailure(message: "unknown session '\(key)': see list_sessions")
        }
        return (p, h)
    }

    func tools() -> [MCPToolDefinition] { MCPCatalog.definitions }

    func call(_ call: MCPToolCall) async -> MCPToolResult {
        guard isRunning, let tool = MCPCatalog.Tool(rawValue: call.name) else { return .error("agent access is disabled in Escale") }
        let client = call.client.label
        var target: HostProfile?
        do {
            switch tool {
            case .listHosts:
                return .json(["hosts": .array(exposedHosts.map(hostJSON)), "auto_connect": .bool(allowAutoConnect)])
            case .listSessions:
                return .json(["sessions": .array(sessionsJSON())])
            default: break
            }
            // Outils portant sur un hôte : résolution, politique, confirmation.
            let h: HostProfile
            let p: Pane?
            if tool == .readTerminal || tool == .sendInput {
                let (pp, hh) = try pane(call.arguments)
                h = hh; p = pp
            } else {
                h = try host(call.arguments); p = nil
            }
            target = h
            let summary = try describe(tool, call.arguments, host: h)
            var decision = MCPPolicy.decide(tool.operation, access: h.agentAccess)
            if tool == .connectHost {
                let openTab = try call.arguments.bool("open_tab", default: false)
                // Sur un hôte en lecture seule, connect_host (sans ouvrir d'onglet) reste cohérent avec list_files/read_file.
                if h.agentAccess == .read && !openTab {
                    decision = .allow
                } else if decision == .confirm && isHostConnected(h) && !openTab {
                    // Réutilisation sans nouvelle connexion ni onglet : pas de confirmation inutile.
                    decision = .allow
                }
            }
            if case .deny(let m) = decision {
                log(client, tool, h, summary, .denied(m))
                return .error(m)
            }
            // Refuser immédiatement si l'hôte est déconnecté et l'auto-connexion désactivée (avant toute confirmation).
            if toolRequiresConnectedLink(tool) && !isHostConnected(h) && !allowAutoConnect {
                throw ToolFailure(message: Self.notConnectedMessage(for: h))
            }
            var confirmed = false
            switch decision {
            case .deny(let m):
                log(client, tool, h, summary, .denied(m))
                return .error(m)
            case .allow:
                if tool.operation == .action { log(client, tool, h, summary, .allowed) }
            case .confirm:
                guard await confirm(tool, client: client, host: h, detail: summary) else {
                    log(client, tool, h, summary, .refusedByUser)
                    return .error("the user refused this action in Escale")
                }
                confirmed = true
                log(client, tool, h, summary, .approved)
            }
            return try await run(tool, call.arguments, host: h, pane: p, client: client, alreadyConfirmed: confirmed)
        } catch let e as ToolFailure {
            if let target, !e.alreadyLogged { markFailure(client, tool, target, e.message) }
            return .error(e.message)
        } catch let e as MCPArgumentError {
            return .error(e.message)
        } catch {
            let m = SSHLink.describe(error)
            if let target { markFailure(client, tool, target, m) }
            return .error(m)
        }
    }

    /// Une action journalisée puis en échec : l'entrée passe en échec (sinon, échec de lecture : nouvelle entrée).
    private func markFailure(_ client: String, _ tool: MCPCatalog.Tool, _ host: HostProfile, _ message: String) {
        if tool.operation == .action, let i = journal.lastIndex(where: { $0.tool == tool.rawValue && $0.hostName == host.name && $0.client == client }),
           journal[i].outcome == .allowed || journal[i].outcome == .approved {
            journal[i].outcome = .failed(message)
        } else {
            log(client, tool, host, "", .failed(message))
        }
    }

    /// Résumé affiché à l'utilisateur (confirmation, journal) : ce que l'agent demande, sans le contenu des fichiers.
    private func describe(_ tool: MCPCatalog.Tool, _ a: MCPArguments, host: HostProfile) throws -> String {
        switch tool {
        case .connectHost:
            return host.port.map { "\(host.target):\($0)" } ?? host.target
        case .exec: return try a.string("command")
        case .sendInput:
            let t = try a.string("text")
            let shown = t.unicodeScalars.map { s in
                s.value < 0x20 || s.value == 0x7f ? (s == "\r" || s == "\n" ? "⏎" : "^\(Character(UnicodeScalar(s.value ^ 0x40) ?? "?"))") : String(s)
            }.joined()
            return try a.bool("press_enter", default: false) ? shown + "⏎" : shown
        case .writeFile:
            let n = try a.string("content").utf8.count
            return String(localized: "\(try a.string("path")) (\(n) octets)")
        case .readFile: return try a.string("path")
        case .listFiles: return try a.optionalString("path") ?? "."
        case .startTunnel, .stopTunnel:
            let id = try a.string("tunnel_id")
            return host.tunnels.first { $0.id.uuidString.caseInsensitiveCompare(id) == .orderedSame }?.title ?? id
        case .readTerminal, .listTunnels, .listHosts, .listSessions: return ""
        }
    }

    private func run(_ tool: MCPCatalog.Tool, _ a: MCPArguments, host: HostProfile, pane: Pane?,
                     client: String, alreadyConfirmed: Bool) async throws -> MCPToolResult {
        switch tool {
        case .connectHost:
            let openTab = try a.bool("open_tab", default: false)
            let alreadyConnected = model?.connections.existing(host.id)?.links.contains(where: { $0.state == .connected }) == true
            let link = try await connectedLink(host, client: client, alreadyConfirmed: alreadyConfirmed)
            defer { link.release() }
            var sessionID: String?
            if openTab, let model {
                if let existingPane = panes.first(where: { $0.hostID == host.id }) {
                    sessionID = existingPane.id.uuidString
                } else {
                    let tab = model.newTab(host)
                    sessionID = tab.panes.first?.id.uuidString
                }
            }
            var payload: [String: JSONValue] = [
                "host_id": .string(host.id.uuidString),
                "host": .string(host.name),
                "state": .string(Self.stateName(link.state)),
                "already_connected": .bool(alreadyConnected),
            ]
            if let sessionID { payload["session_id"] = .string(sessionID) }
            return .json(.object(payload))
        case .readTerminal:
            guard let pane else { throw ToolFailure(message: "no session") }
            let n = try a.int("max_lines", default: 200, range: 1...MCPCatalog.maxTerminalLines)
            var lines = pane.session.engine.text(includingScrollback: true).components(separatedBy: "\n")
            while let l = lines.last, l.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
            let text = lines.suffix(n).joined(separator: "\n")
            return MCPToolResult(text: text, structured: ["session_id": .string(pane.id.uuidString), "status": .string(statusName(pane.status)),
                                                          "lines": .int(min(n, lines.count)), "text": .string(text)])
        case .sendInput:
            guard let pane else { throw ToolFailure(message: "no session") }
            guard pane.status == .running else { throw ToolFailure(message: "session is not running (\(statusName(pane.status)))") }
            var data = Data(try a.string("text").utf8)
            if try a.bool("press_enter", default: false) { data.append(0x0d) }
            guard data.count <= MCPCatalog.maxInputBytes else { throw ToolFailure(message: "text too long (max 64 KiB)") }
            pane.session.engine.sendInput(data)
            return .json(["sent_bytes": .int(data.count)])
        case .exec:
            let command = try a.string("command")
            guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ToolFailure(message: "empty command") }
            let timeout = try a.int("timeout_seconds", default: 60, range: 1...MCPCatalog.maxExecTimeout)
            let link = try await connectedLink(host, client: client, alreadyConfirmed: alreadyConfirmed)
            defer { link.release() }
            let r = try await link.transport.exec(command, timeout: TimeInterval(timeout), maxOutputBytes: MCPCatalog.maxExecOutputBytes)
            if let f = r.failure { throw ToolFailure(message: f) }
            let v: JSONValue = [
                "exit_code": r.exitCode.map { .int(Int($0)) } ?? .null, "stdout": .string(r.stdout), "stderr": .string(r.stderr),
                "stdout_truncated": .bool(r.stdoutTruncated), "stderr_truncated": .bool(r.stderrTruncated),
                "timed_out": .bool(r.timedOut), "duration_seconds": .double((r.duration * 1000).rounded() / 1000),
            ]
            var res = MCPToolResult.json(v)
            res.isError = r.timedOut
            return res
        case .listFiles, .readFile, .writeFile:
            let link = try await connectedLink(host, client: client, alreadyConfirmed: alreadyConfirmed)
            defer { link.release() }
            let fs = try await RemoteFileSystemOpener.open(transport: link.transport).fileSystem
            do {
                let r = try await files(tool, a, fs)
                await fs.close()
                return r
            } catch { await fs.close(); throw error }
        case .listTunnels:
            return .json(["tunnels": .array(host.tunnels.map { tunnelJSON($0) })])
        case .startTunnel, .stopTunnel:
            guard let model else { throw ToolFailure(message: "application stopped") }
            let key = try a.string("tunnel_id")
            guard let spec = host.tunnels.first(where: { $0.id.uuidString.caseInsensitiveCompare(key) == .orderedSame }) else {
                throw ToolFailure(message: "unknown tunnel '\(key)': see list_tunnels")
            }
            if tool == .stopTunnel {
                _ = await model.tunnels.stop(spec, on: host)
                return .json(tunnelJSON(spec))
            }
            // Le module Tunnels connecterait l'hôte au besoin : on passe toujours par `connectedLink` qui applique `allowAutoConnect`.
            let link = try await connectedLink(host, client: client, alreadyConfirmed: alreadyConfirmed)
            defer { link.release() }
            let state = await model.tunnels.start(spec, on: host)
            if case .failed(let m) = state { throw ToolFailure(message: m) }
            return .json(tunnelJSON(spec))
        case .listHosts, .listSessions:
            throw ToolFailure(message: "unexpected tool")
        }
    }

    private nonisolated func files(_ tool: MCPCatalog.Tool, _ a: MCPArguments, _ fs: any RemoteFileSystem) async throws -> MCPToolResult {
        switch tool {
        case .listFiles:
            let raw = try a.optionalString("path") ?? "."
            let path = try await fs.canonicalPath(Data((raw.isEmpty ? "." : raw).utf8))
            let entries = try await fs.listEntries(in: Data(path.utf8)).sorted { $0.name < $1.name }
            let list: [JSONValue] = entries.prefix(5000).map { e in
                var o: [String: JSONValue] = ["name": .string(e.name), "type": .string(Self.typeName(e.type))]
                if let s = e.attributes.size { o["size"] = .int(Int(clamping: s)) }
                if let p = e.attributes.permissions { o["mode"] = .string(String(p & 0o7777, radix: 8)) }
                if let m = e.attributes.modificationTime { o["modified"] = .string(ISO8601DateFormatter().string(from: m)) }
                return .object(o)
            }
            return .json(["path": .string(path), "entries": .array(list), "truncated": .bool(entries.count > 5000)])
        case .readFile:
            let path = Data(try a.string("path").utf8)
            let offset = try a.int("offset", default: 0, range: 0...Int.max)
            let max = try a.int("max_bytes", default: 262_144, range: 1...MCPCatalog.maxReadBytes)
            let size = try await fs.attributes(of: path).size
            var data = Data()
            while data.count < max {
                let block = try await fs.readBlock(path, offset: UInt64(offset + data.count), length: min(256 * 1024, max - data.count))
                if block.isEmpty { break }
                data.append(block)
            }
            let total = size.map { Int(clamping: $0) }
            let truncated = total.map { offset + data.count < $0 } ?? (data.count == max)
            var o: [String: JSONValue] = ["path": .string(try a.string("path")), "offset": .int(offset), "bytes": .int(data.count),
                                          "truncated": .bool(truncated)]
            if let total { o["size"] = .int(total) }
            if let s = String(data: data, encoding: .utf8) {
                o["encoding"] = "utf8"; o["content"] = .string(s)
                return MCPToolResult(text: s, structured: .object(o))
            }
            o["encoding"] = "base64"; o["content"] = .string(data.base64EncodedString())
            return .json(.object(o))
        case .writeFile:
            let pathString = try a.string("path")
            let path = Data(pathString.utf8)
            let content = try a.string("content")
            let enc = try a.optionalString("encoding") ?? "utf8"
            let data: Data
            switch enc {
            case "utf8": data = Data(content.utf8)
            case "base64":
                guard let d = Data(base64Encoded: content, options: .ignoreUnknownCharacters) else { throw ToolFailure(message: "invalid base64 content") }
                data = d
            default: throw ToolFailure(message: "encoding must be 'utf8' or 'base64'")
            }
            guard data.count <= MCPCatalog.maxWriteBytes else { throw ToolFailure(message: "content too large (max 4 MiB)") }
            let chunk = 256 * 1024
            var offset = 0
            repeat {
                let end = min(offset + chunk, data.count)
                try await fs.writeBlock(path, offset: UInt64(offset), data: data.subdata(in: offset..<end), truncate: offset == 0)
                offset = end
            } while offset < data.count
            return .json(["path": .string(pathString), "bytes_written": .int(data.count)])
        default:
            throw ToolFailure(message: "unexpected tool")
        }
    }

    // MARK: Représentations JSON (aucun secret : ni mot de passe, ni compte Trousseau, ni chemin de clé)

    private func hostJSON(_ h: HostProfile) -> JSONValue {
        let state = model?.connections.state(of: h.id) ?? .disconnected
        var o: [String: JSONValue] = [
            "id": .string(h.id.uuidString), "name": .string(h.name), "address": .string(h.host),
            "access": .string(h.agentAccess.rawValue), "state": .string(Self.stateName(state)),
            "tags": .array(h.tags.map { .string($0) }),
        ]
        if let u = h.user { o["user"] = .string(u) }
        if let p = h.port { o["port"] = .int(p) }
        if !h.tunnels.isEmpty { o["tunnels"] = .int(h.tunnels.count) }
        return .object(o)
    }

    private func sessionsJSON() -> [JSONValue] {
        let visible = Dictionary(uniqueKeysWithValues: exposedHosts.map { ($0.id, $0) })
        var out: [JSONValue] = []
        for (ti, tab) in (model?.workspace.tabs ?? []).enumerated() {
            for p in tab.panes {
                guard let hid = p.hostID, let h = visible[hid] else { continue }
                out.append(["session_id": .string(p.id.uuidString), "host_id": .string(h.id.uuidString), "host": .string(h.name),
                            "title": .string(p.displayTitle), "status": .string(statusName(p.status)), "tab": .int(ti + 1),
                            "active": .bool(tab.activePane.id == p.id && model?.workspace.activeTab?.id == tab.id)])
            }
        }
        return out
    }

    private func tunnelJSON(_ t: TunnelSpec) -> JSONValue {
        var o: [String: JSONValue] = ["id": .string(t.id.uuidString), "name": .string(t.title), "spec": .string(t.summary)]
        switch model?.tunnels.state(of: t.id) ?? .stopped {
        case .active: o["state"] = "active"
        case .opening: o["state"] = "opening"
        case .stopped: o["state"] = "stopped"
        case .failed(let m): o["state"] = "failed"; o["error"] = .string(m)
        }
        if let port = model?.tunnels.allocatedPorts[t.id] { o["allocated_port"] = .int(port) }
        return .object(o)
    }

    private func statusName(_ s: Pane.Status) -> String {
        switch s {
        case .connecting: "connecting"
        case .running: "running"
        case .reconnecting: "reconnecting"
        case .ended: "ended"
        case .failed: "failed"
        }
    }

    static func stateName(_ s: SSHLink.State) -> String {
        switch s {
        case .connected: "connected"
        case .connecting: "connecting"
        case .reconnecting: "reconnecting"
        case .disconnected: "disconnected"
        case .authRequired: "auth_required"
        case .cancelled, .failed: "failed"
        case .hostKeyChanged: "host_key_changed"
        }
    }

    nonisolated static func typeName(_ t: SFTPFileType) -> String {
        switch t {
        case .regular: "file"
        case .directory: "directory"
        case .symlink: "symlink"
        case .other: "other"
        case .unknown: "unknown"
        }
    }
}

/// Pont entre les sessions MCP (threads du socket) et le module, isolé sur l'acteur principal.
struct MCPAppProvider: MCPToolProvider {
    let feature: MCPFeature
    func tools() async -> [MCPToolDefinition] { await feature.tools() }
    func call(_ call: MCPToolCall) async -> MCPToolResult { await feature.call(call) }
}
