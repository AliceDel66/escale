import AppKit
import QuartzCore
import Foundation
import EscaleCore

/// `--selftest-mcp <dossier>` : serveur MCP de bout en bout contre un sshd local. Le client est le VRAI relais
/// (`Escale --mcp`, processus fils de l'app, JSON-RPC ligne à ligne sur stdin/stdout) ; le socket est celui de
/// `ESCALE_MCP_SOCKET` (dossier de la recette, jamais le socket réel). Écrit result.json + PNG.
@MainActor
struct MCPSelfTest {
    let directory: String
    let model: AppModel

    func run() async -> Bool {
        let t = Runner(dir: directory, model: model)
        return await t.run()
    }

    /// Client MCP : un relais `--mcp` en fils, lignes JSON lues par un gestionnaire de lecture, protégées par un verrou.
    final class Client: @unchecked Sendable {
        private let process = Process()
        private let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        private let lock = NSLock()
        private var buffer = Data()
        private var lines: [[String: Any]] = []
        private var raw: [String] = []
        private var errBuffer = Data()
        private var nextID = 1

        init?(executable: String, environment: [String: String]) {
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = ["--mcp"]
            process.environment = environment
            process.standardInput = stdin; process.standardOutput = stdout; process.standardError = stderr
            stdout.fileHandleForReading.readabilityHandler = { [weak self] h in
                let d = h.availableData
                guard let self else { return }
                if d.isEmpty { h.readabilityHandler = nil; return }
                self.lock.withLock {
                    self.buffer.append(d)
                    while let nl = self.buffer.firstIndex(of: 0x0a) {
                        let line = self.buffer.subdata(in: self.buffer.startIndex..<nl)
                        self.buffer.removeSubrange(self.buffer.startIndex...nl)
                        self.raw.append(String(decoding: line, as: UTF8.self))
                        if let o = try? JSONSerialization.jsonObject(with: line) as? [String: Any] { self.lines.append(o) }
                    }
                }
            }
            stderr.fileHandleForReading.readabilityHandler = { [weak self] h in
                let d = h.availableData
                guard let self else { return }
                if d.isEmpty { h.readabilityHandler = nil; return }
                self.lock.withLock { self.errBuffer.append(d) }
            }
            do { try process.run() } catch { return nil }
        }

        var pid: Int32 { process.processIdentifier }
        var isRunning: Bool { process.isRunning }
        var exitStatus: Int32? { process.isRunning ? nil : process.terminationStatus }
        var stderrText: String { lock.withLock { String(decoding: errBuffer, as: UTF8.self) } }
        var rawOutput: String { lock.withLock { raw.joined(separator: "\n") } }

        func send(_ object: [String: Any]) {
            guard let d = try? JSONSerialization.data(withJSONObject: object) else { return }
            stdin.fileHandleForWriting.write(d + Data([0x0a]))
        }
        func notify(_ method: String) { send(["jsonrpc": "2.0", "method": method]) }
        /// Envoie une requête, renvoie son identifiant.
        func request(_ method: String, _ params: [String: Any] = [:]) -> Int {
            let id = lock.withLock { defer { nextID += 1 }; return nextID }
            send(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
            return id
        }
        func response(_ id: Int) -> [String: Any]? {
            lock.withLock { lines.first { ($0["id"] as? Int) == id } }
        }
        func terminate() { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        func closeInput() { try? stdin.fileHandleForWriting.close() }
    }

    @MainActor
    final class Runner {
        let dir: String
        let model: AppModel
        private var checks: [(String, Bool, String)] = []
        private var shots: [String] = []
        private var notes: [String: String] = [:]
        private var window: NSWindow?
        private var mcp: MCPFeature { model.mcp }

        init(dir: String, model: AppModel) { self.dir = dir; self.model = model }

        // MARK: Aides

        private func check(_ name: String, _ cond: @autoclosure () async -> Bool, _ detail: String = "") async {
            let ok = await cond()
            checks.append((name, ok, detail))
            FileHandle.standardError.write(Data("[selftest-mcp] \(ok ? "OK " : "KO ") \(name) \(detail)\n".utf8))
        }
        private func wait(_ timeout: Double = 10, _ cond: () -> Bool) async -> Bool {
            let end = Date().addingTimeInterval(timeout)
            while Date() < end { if cond() { return true }; try? await Task.sleep(nanoseconds: 50_000_000) }
            return cond()
        }
        private func sleep(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1e9)) }
        private func text(_ p: Pane) -> String { p.session.engine.text(includingScrollback: true) }
        private var acceptedCount: Int {
            guard let p = ProcessInfo.processInfo.environment["ESCALE_SSHD_LOG"],
                  let s = try? String(contentsOfFile: p, encoding: .utf8) else { return -1 }
            return s.components(separatedBy: "Accepted publickey").count - 1
        }

        private func capture(_ name: String) async {
            guard let win = window else { return }
            win.orderFrontRegardless()
            await sleep(0.8)
            let path = "\(dir)/\(name).png"
            let pr = Process()
            pr.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            pr.arguments = ["-x", path]
            try? pr.run(); pr.waitUntilExit()
            if FileManager.default.fileExists(atPath: path) { shots.append("\(name).png") }
        }

        private func children() -> [String] {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/ps")
            p.arguments = ["-axo", "pid=,ppid=,comm="]
            let pipe = Pipe(); p.standardOutput = pipe
            try? p.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let me = getpid()
            return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line in
                let f = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
                guard f.count == 3, Int32(f[1]) == me else { return nil }
                let name = (String(f[2]) as NSString).lastPathComponent
                return name == "ps" ? nil : "\(f[0]) \(name)"
            }
        }

        private func mode(_ path: String) -> Int {
            (try? FileManager.default.attributesOfItem(atPath: path))?[.posixPermissions] as? Int ?? -1
        }

        /// Appel d'outil : renvoie (isError, texte, structuré). nil si pas de réponse.
        private struct ToolReply { var isError: Bool; var text: String; var structured: [String: Any]; var rpcError: String? }

        private func call(_ c: Client, _ tool: String, _ args: [String: Any], timeout: Double = 40) async -> ToolReply {
            let id = c.request("tools/call", ["name": tool, "arguments": args])
            _ = await wait(timeout) { c.response(id) != nil }
            guard let r = c.response(id) else { return ToolReply(isError: true, text: "", structured: [:], rpcError: "pas de réponse") }
            if let e = r["error"] as? [String: Any] { return ToolReply(isError: true, text: "", structured: [:], rpcError: "\(e["message"] ?? e)") }
            let res = r["result"] as? [String: Any] ?? [:]
            let content = (res["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
            return ToolReply(isError: res["isError"] as? Bool ?? false, text: content,
                             structured: res["structuredContent"] as? [String: Any] ?? [:], rpcError: nil)
        }

        // MARK: Scénario

        func run() async -> Bool {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            guard await wait(15, { model.mainWindow != nil }), let win = model.mainWindow else {
                await check("fenetre_principale", false); return finish()
            }
            window = win
            win.orderFrontRegardless()
            await check("fenetre_principale", true)
            model.connections.graceDelay = 0.5
            _ = await wait(10) { model.library.isLoaded }
            let all = model.library.library.hosts
            func named(_ n: String) -> HostProfile? { all.first { $0.name == n } }
            guard let hRead = named("Hôte lecture"), let hConfirm = named("Hôte confirm"),
                  let hFull = named("Hôte libre"), let hHidden = named("Hôte caché") else {
                await check("hotes_disponibles", false); return finish()
            }
            await check("hotes_acces", hRead.agentAccess == .read && hConfirm.agentAccess == .confirm
                        && hFull.agentAccess == .full && hHidden.agentAccess == .none)
            guard let exe = Bundle.main.executablePath else { await check("executable", false); return finish() }
            let env = ProcessInfo.processInfo.environment
            let socket = mcp.socketPath
            let work = env["ESCALE_MCP_WORK"] ?? dir
            var clients: [Client] = []
            defer { clients.forEach { $0.terminate() } }

            // 1. Relais sans serveur : échec propre ; puis activation
            await check("socket_isole", env["ESCALE_MCP_SOCKET"] == socket && socket.hasPrefix(work), socket)
            await check("avant_activation_pas_en_marche", !mcp.isRunning && !FileManager.default.fileExists(atPath: socket))
            if let early = Client(executable: exe, environment: env) {
                _ = await wait(15) { !early.isRunning }
                await check("relais_echec_propre_sans_serveur", early.exitStatus == 1 && early.stderrText.contains("Escale"),
                            "code \(early.exitStatus.map(String.init) ?? "en cours") \(early.stderrText.prefix(80))")
                early.terminate()
            } else { await check("relais_echec_propre_sans_serveur", false, "lancement impossible") }
            mcp.setEnabled(true)
            await check("serveur_en_marche", await wait(5) { mcp.isRunning }, mcp.serverError ?? "")
            await check("socket_present_0600", mode(socket) == 0o600, String(mode(socket), radix: 8))
            let parent = (socket as NSString).deletingLastPathComponent
            await check("dossier_0700", mode(parent) == 0o700, String(mode(parent), radix: 8))

            // 2. initialize + tools/list via le relais réel
            guard let c = Client(executable: exe, environment: env) else { await check("relais_lance", false); return finish() }
            clients.append(c)
            let initID = c.request("initialize", ["protocolVersion": "2025-06-18", "capabilities": [String: Any](),
                                                  "clientInfo": ["name": "selftest", "version": "1"]])
            await check("initialize_repond", await wait(15) { c.response(initID) != nil }, c.stderrText)
            let initRes = c.response(initID)?["result"] as? [String: Any]
            let serverInfo = initRes?["serverInfo"] as? [String: Any]
            await check("serverInfo_escale", serverInfo?["name"] as? String == "escale", "\(serverInfo ?? [:])")
            c.notify("notifications/initialized")
            let listID = c.request("tools/list")
            _ = await wait(10) { c.response(listID) != nil }
            let toolNames = ((c.response(listID)?["result"] as? [String: Any])?["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
            let expected: Set<String> = ["list_hosts", "connect_host", "list_sessions", "read_terminal", "send_input", "exec", "list_files", "read_file",
                                         "write_file", "list_tunnels", "start_tunnel", "stop_tunnel"]
            await check("douze_outils", toolNames.count == 12 && Set(toolNames) == expected, toolNames.sorted().joined(separator: ","))
            await check("client_compte", await wait(5) { mcp.clientCount >= 1 }, "\(mcp.clientCount)")

            // 3. list_hosts : exactement les trois hôtes exposés, aucun secret, auto_connect=false par défaut
            let lh = await call(c, "list_hosts", [:])
            let hostNames = (lh.structured["hosts"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
            await check("list_hosts_trois_hotes", Set(hostNames) == ["Hôte lecture", "Hôte confirm", "Hôte libre"] && hostNames.count == 3, "\(hostNames)")
            await check("list_hosts_auto_connect_false", (lh.structured["auto_connect"] as? Bool) == false, "\(lh.structured["auto_connect"] ?? "nil")")
            var keyPath = ""
            if case .keyFile(let kp) = hFull.auth { keyPath = kp }
            let rawHosts = c.rawOutput.components(separatedBy: "\n").filter { $0.contains("Hôte libre") && $0.contains("\"result\"") }.joined(separator: "\n")
            await check("list_hosts_aucun_secret", !lh.isError && rawHosts.contains("Hôte libre") && !lh.text.contains("Hôte caché") && !rawHosts.contains("Hôte caché")
                        && !rawHosts.contains("keyFile") && !rawHosts.contains("\"path\"") && (keyPath.isEmpty || !rawHosts.contains(keyPath)), keyPath)

            // 4. exec / connect_host sur un hôte non connecté (autoConnect désactivé) : refus sans confirmation, aucun maître ouvert
            let acc0 = acceptedCount
            var confirmPromptedWhileDisconnected = false
            mcp.confirmationOverride = { _ in confirmPromptedWhileDisconnected = true; return true }
            let dis = await call(c, "exec", ["host": "Hôte libre", "command": "echo MCP-$((6*7))"])
            let disConn = await call(c, "connect_host", ["host": "Hôte libre"])
            let disConfirm = await call(c, "connect_host", ["host": "Hôte confirm"])
            mcp.confirmationOverride = nil
            await sleep(1.0)
            await check("exec_deconnecte_refuse", dis.isError && dis.text.contains("not connected"), dis.text)
            await check("connect_host_deconnecte_refuse", disConn.isError && disConn.text.contains("not connected")
                        && disConfirm.isError && disConfirm.text.contains("not connected") && !confirmPromptedWhileDisconnected, disConfirm.text)
            await check("exec_deconnecte_aucun_maitre", model.connections.existing(hFull.id)?.links.contains { $0.state == .connected } != true
                        && acceptedCount == acc0, "accepted \(acceptedCount) vs \(acc0)")

            // 4b. Connexion à la demande (allowAutoConnect = true) : lecture (sans open_tab), confirmation sur confirm, ouverture + réutilisation sur libre, libération à la coupure
            mcp.setAutoConnect(true)
            let lhAuto = await call(c, "list_hosts", [:])
            await check("list_hosts_auto_connect_true", (lhAuto.structured["auto_connect"] as? Bool) == true)
            let readConnTabDenied = await call(c, "connect_host", ["host": "Hôte lecture", "open_tab": true])
            await check("connect_host_lecture_open_tab_refuse", readConnTabDenied.isError && readConnTabDenied.text.contains("read-only"), readConnTabDenied.text)
            let readConnOK = await call(c, "connect_host", ["host": "Hôte lecture"])
            await check("connect_host_lecture_ok", !readConnOK.isError && (readConnOK.structured["state"] as? String) == "connected", readConnOK.text)
            let jnRefuse0 = mcp.journal.count
            mcp.confirmationOverride = { _ in false }
            let refuseConn = await call(c, "connect_host", ["host": "Hôte confirm"])
            await check("connect_host_confirm_refuse", refuseConn.isError && refuseConn.text.contains("refused"), refuseConn.text)
            let refuseReadAuto = await call(c, "list_files", ["host": "Hôte confirm", "path": "."])
            let refuseEntries = mcp.journal.dropFirst(jnRefuse0)
            await check("list_files_confirm_refuse_sans_doublon_journal", refuseReadAuto.isError && refuseReadAuto.text.contains("refused")
                        && !refuseEntries.contains { if case .failed = $0.outcome { true } else { false } }, refuseReadAuto.text)
            mcp.confirmationOverride = nil
            let autoConn = await call(c, "connect_host", ["host": "Hôte libre"])
            await check("connect_host_libre_ok", !autoConn.isError && (autoConn.structured["state"] as? String) == "connected"
                        && (autoConn.structured["already_connected"] as? Bool) == false && mcp.activeAgentLinkCount == 2, autoConn.text)
            let autoExec = await call(c, "exec", ["host": "Hôte libre", "command": "echo AUTO-$((6*7))"])
            await check("auto_connect_exec_reutilise_maitre", !autoExec.isError && (autoExec.structured["stdout"] as? String)?.contains("AUTO-42") == true, autoExec.text)
            mcp.setAutoConnect(false)
            await check("auto_connect_libere_bail", mcp.activeAgentLinkCount == 0)
            let autoDown = await wait(15) { model.connections.allLinks.allSatisfy { $0.state == .disconnected } }
            await check("auto_connect_maitre_deconnecte", autoDown, model.connections.allLinks.map { "\($0.state)" }.joined(separator: ","))

            // 4c. Configurateur clients IA (agy, Claude Code, Claude Desktop, Codex) dans un faux home isolé
            let fakeHome = URL(fileURLWithPath: "\(work)/fake-home", isDirectory: true)
            try? FileManager.default.createDirectory(at: fakeHome, withIntermediateDirectories: true)
            let aiCfg = AIClientConfigurator(homeDirectory: fakeHome)
            var aiOK = true
            for client in AIClientKind.allCases {
                do {
                    try aiCfg.install(for: client, executablePath: exe)
                    if aiCfg.status(for: client, executablePath: exe) != .configured(executablePath: exe) { aiOK = false }
                    try aiCfg.uninstall(for: client)
                    if aiCfg.status(for: client, executablePath: exe) != .notConfigured { aiOK = false }
                } catch { aiOK = false }
            }
            await check("ai_client_configurator_tous_clients", aiOK)

            // 5. Onglets des hôtes
            let tabFull = model.newTab(hFull), tabRead = model.newTab(hRead), tabConfirm = model.newTab(hConfirm), tabHidden = model.newTab(hHidden)
            let tabs = [tabFull, tabRead, tabConfirm, tabHidden]
            let panes = tabs.flatMap(\.panes)
            await check("panneaux_running", await wait(40) { panes.allSatisfy { $0.status == .running } }, panes.map { "\($0.status)" }.joined(separator: ","))
            let ls = await call(c, "list_sessions", [:])
            let sessions = ls.structured["sessions"] as? [[String: Any]] ?? []
            let sessionHosts = Set(sessions.compactMap { $0["host"] as? String })
            await check("list_sessions_trois_sessions", sessions.count == 3 && sessionHosts == ["Hôte lecture", "Hôte confirm", "Hôte libre"], "\(sessionHosts) \(sessions.count)")
            await check("list_sessions_pas_de_cache", !ls.text.contains("Hôte caché") && !ls.text.contains(tabHidden.panes[0].id.uuidString))
            let paneFull = tabFull.panes[0], paneRead = tabRead.panes[0]
            await check("session_id_correspond", sessions.contains { ($0["session_id"] as? String) == paneFull.id.uuidString && ($0["host"] as? String) == "Hôte libre" })

            // 6. exec : lecture refusée, libre OK, confirm avec refus puis accord
            let jn0 = mcp.journal.count
            let denied = await call(c, "exec", ["host": "Hôte lecture", "command": "echo nope"])
            await check("exec_lecture_refuse", denied.isError && mcp.journal.dropFirst(jn0).contains { if case .denied = $0.outcome { $0.tool == "exec" && $0.hostName == "Hôte lecture" } else { false } },
                        denied.text)
            let ok = await call(c, "exec", ["host": "Hôte libre", "command": "echo MCP-$((6*7))"])
            await check("exec_libre_stdout", !ok.isError && (ok.structured["stdout"] as? String)?.contains("MCP-42") == true && (ok.structured["exit_code"] as? Int) == 0, ok.text)
            await check("exec_libre_journalise", mcp.journal.dropFirst(jn0).contains { $0.tool == "exec" && $0.hostName == "Hôte libre" && $0.outcome == .allowed })
            // Nom ou identifiant : les deux résolvent
            let byID = await call(c, "exec", ["host": hFull.id.uuidString, "command": "exit 3"])
            await check("exec_par_identifiant_code_3", !byID.isError && (byID.structured["exit_code"] as? Int) == 3, byID.text)
            var confirmPromptedAlreadyConnected = false
            mcp.confirmationOverride = { _ in confirmPromptedAlreadyConnected = true; return false }
            let alreadyConnConfirm = await call(c, "connect_host", ["host": "Hôte confirm"])
            await check("connect_host_confirm_deja_connecte_sans_confirmation",
                        !alreadyConnConfirm.isError && (alreadyConnConfirm.structured["already_connected"] as? Bool) == true && !confirmPromptedAlreadyConnected,
                        alreadyConnConfirm.text)
            mcp.confirmationOverride = { _ in false }
            let refused = await call(c, "exec", ["host": "Hôte confirm", "command": "echo CONF-$((2*3))"])
            await check("exec_confirm_refuse_par_utilisateur", refused.isError && refused.text.contains("refused"), refused.text)
            mcp.confirmationOverride = { cf in cf.hostName == "Hôte confirm" && cf.detail.contains("CONF-") }
            let approved = await call(c, "exec", ["host": "Hôte confirm", "command": "echo CONF-$((2*3))"])
            await check("exec_confirm_accepte", !approved.isError && (approved.structured["stdout"] as? String)?.contains("CONF-6") == true, approved.text)
            await check("journal_refus_et_accord", mcp.journal.contains { $0.outcome == .refusedByUser } && mcp.journal.contains { $0.outcome == .approved })
            var execLeft = 0
            for l in model.connections.allLinks { execLeft += await l.transport.execSessionCount }
            await check("exec_aucune_session_residuelle", execLeft == 0, "\(execLeft)")
            await check("aucun_panneau_ni_pending", mcp.pending.isEmpty)

            // 7. send_input + read_terminal
            let sent = await call(c, "send_input", ["session_id": paneFull.id.uuidString, "text": "echo TYPED-$((7*6))", "press_enter": true])
            await check("send_input_ok", !sent.isError, sent.text)
            var terminalText = ""
            _ = await wait(15) {
                terminalText = text(paneFull); return terminalText.contains("TYPED-42\n")
            }
            let rt = await call(c, "read_terminal", ["session_id": paneFull.id.uuidString, "max_lines": 50])
            await check("read_terminal_contient_resultat", !rt.isError && (rt.structured["text"] as? String)?.contains("TYPED-42") == true, String(rt.text.suffix(120)))
            let sentRead = await call(c, "send_input", ["session_id": paneRead.id.uuidString, "text": "echo X", "press_enter": true])
            await check("send_input_lecture_refuse", sentRead.isError)
            let rtRead = await call(c, "read_terminal", ["session_id": paneRead.id.uuidString])
            await check("read_terminal_lecture_permis", !rtRead.isError)
            let rtHidden = await call(c, "read_terminal", ["session_id": tabHidden.panes[0].id.uuidString])
            await check("read_terminal_cache_inconnu", rtHidden.isError && rtHidden.text.contains("unknown"), rtHidden.text)

            // 8. Fichiers
            let fdir = "\(work)/mcpfiles"
            _ = await call(c, "exec", ["host": "Hôte libre", "command": "mkdir -p '\(fdir)' && printf '\\001\\002\\377\\376\\000' > '\(fdir)/bin.dat'"])
            let content = "Été à Zürich — ligne 1\nligne 2 ✓\n"
            let w = await call(c, "write_file", ["host": "Hôte libre", "path": "\(fdir)/note.txt", "content": content])
            await check("write_file_ok", !w.isError && (w.structured["bytes_written"] as? Int) == content.utf8.count, w.text)
            let r = await call(c, "read_file", ["host": "Hôte libre", "path": "\(fdir)/note.txt"])
            await check("read_file_aller_retour", !r.isError && (r.structured["content"] as? String) == content && (r.structured["encoding"] as? String) == "utf8", r.text)
            await check("fichier_sur_disque", (try? String(contentsOfFile: "\(fdir)/note.txt", encoding: .utf8)) == content)
            let lf = await call(c, "list_files", ["host": "Hôte libre", "path": fdir])
            let entries = (lf.structured["entries"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
            await check("list_files_voit_le_fichier", !lf.isError && entries.contains("note.txt") && entries.contains("bin.dat"), "\(entries)")
            let bin = await call(c, "read_file", ["host": "Hôte libre", "path": "\(fdir)/bin.dat"])
            await check("read_file_binaire_base64", !bin.isError && (bin.structured["encoding"] as? String) == "base64"
                        && Data(base64Encoded: bin.structured["content"] as? String ?? "") == Data([1, 2, 0xff, 0xfe, 0]), bin.text)
            let wb = await call(c, "write_file", ["host": "Hôte libre", "path": "\(fdir)/b64.dat", "content": Data([9, 8, 7, 0xfd]).base64EncodedString(), "encoding": "base64"])
            await check("write_file_base64", !wb.isError && (try? Data(contentsOf: URL(fileURLWithPath: "\(fdir)/b64.dat"))) == Data([9, 8, 7, 0xfd]), wb.text)
            let wr = await call(c, "write_file", ["host": "Hôte lecture", "path": "\(fdir)/refuse.txt", "content": "x"])
            await check("write_file_lecture_refuse", wr.isError && !FileManager.default.fileExists(atPath: "\(fdir)/refuse.txt"), wr.text)
            let rr = await call(c, "read_file", ["host": "Hôte lecture", "path": "\(fdir)/note.txt"])
            await check("read_file_lecture_permis", !rr.isError && (rr.structured["content"] as? String) == content, rr.text)

            // 9. Tunnel
            let lt = await call(c, "list_tunnels", ["host": "Hôte libre"])
            let tunnels = lt.structured["tunnels"] as? [[String: Any]] ?? []
            await check("list_tunnels_un_arrete", tunnels.count == 1 && tunnels[0]["state"] as? String == "stopped", lt.text)
            if let tid = tunnels.first?["id"] as? String {
                let st = await call(c, "start_tunnel", ["host": "Hôte libre", "tunnel_id": tid])
                await check("start_tunnel_actif", !st.isError && st.structured["state"] as? String == "active", st.text)
                let lt2 = await call(c, "list_tunnels", ["host": "Hôte libre"])
                await check("list_tunnels_actif", (lt2.structured["tunnels"] as? [[String: Any]])?.first?["state"] as? String == "active", lt2.text)
                let sp = await call(c, "stop_tunnel", ["host": "Hôte libre", "tunnel_id": tid])
                await check("stop_tunnel_arrete", !sp.isError && sp.structured["state"] as? String == "stopped", sp.text)
                let stR = await call(c, "start_tunnel", ["host": "Hôte lecture", "tunnel_id": tid])
                await check("start_tunnel_hote_lecture_refuse", stR.isError, stR.text)
            } else { await check("tunnel_present", false) }

            // 10. Confirmation en attente + déconnexion du client
            mcp.confirmationOverride = nil
            guard let c2 = Client(executable: exe, environment: env) else { await check("relais2_lance", false); return finish() }
            clients.append(c2)
            let init2 = c2.request("initialize", ["protocolVersion": "2025-06-18", "capabilities": [String: Any](), "clientInfo": ["name": "selftest", "version": "1"]])
            _ = await wait(15) { c2.response(init2) != nil }
            c2.notify("notifications/initialized")
            let pendingID = c2.request("tools/call", ["name": "exec", "arguments": ["host": "Hôte confirm", "command": "echo PENDING"]])
            await check("confirmation_en_attente", await wait(15) { mcp.pending.count == 1 }, "\(mcp.pending.count)")
            await check("confirmation_contenu", mcp.pending.first?.detail == "echo PENDING" && mcp.pending.first?.hostName == "Hôte confirm" && mcp.pending.first?.client.hasPrefix("selftest") == true,
                        mcp.pending.first.map { "\($0.client)/\($0.hostName)/\($0.detail)" } ?? "")
            await capture("01-confirmation")
            c2.terminate()
            await check("deconnexion_annule_la_confirmation", await wait(15) { mcp.pending.isEmpty }, "\(mcp.pending.count)")
            await check("pas_de_reponse_apres_deconnexion", c2.response(pendingID) == nil)
            var execLeft2 = 0
            _ = await wait(10) { true }
            for l in model.connections.allLinks { execLeft2 += await l.transport.execSessionCount }
            await check("annulation_aucune_session_exec", execLeft2 == 0, "\(execLeft2)")
            // Le client 1 fonctionne encore après la mort du 2
            let again = await call(c, "list_hosts", [:])
            await check("client1_survit", !again.isError)

            // Client qui ferme stdin proprement : le relais sort
            c.closeInput()
            await check("relais_sort_a_la_fin_de_stdin", await wait(15) { !c.isRunning }, "\(c.exitStatus.map(String.init) ?? "en cours")")

            // 11. Désactivation + nettoyage
            mcp.setEnabled(false)
            await check("serveur_arrete", await wait(10) { !mcp.isRunning && !FileManager.default.fileExists(atPath: socket) }, "\(mcp.isRunning)")
            if let late = Client(executable: exe, environment: env) {
                _ = await wait(15) { !late.isRunning }
                await check("relais_echec_apres_desactivation", late.exitStatus == 1, "\(late.exitStatus.map(String.init) ?? "en cours")")
                late.terminate()
            }
            for t in model.workspace.tabs { model.close(t) }
            await check("tous_onglets_fermes", model.workspace.tabs.isEmpty)
            let down = await wait(30) { model.connections.allLinks.allSatisfy { $0.state == .disconnected } }
            await check("tous_les_maitres_deconnectes", down, model.connections.allLinks.map { "\($0.state)" }.joined(separator: ","))
            var kids: [String] = []
            _ = await wait(15) { kids = children(); return kids.isEmpty }
            await check("aucun_processus_enfant_residuel", kids.isEmpty, kids.joined(separator: ", "))
            return finish()
        }

        private func finish() -> Bool {
            let ok = !checks.isEmpty && checks.allSatisfy { $0.1 }
            let json: [String: Any] = [
                "ok": ok,
                "checks": Dictionary(checks.map { ($0.0, $0.1) }, uniquingKeysWith: { $1 }),
                "details": Dictionary(checks.map { ($0.0, $0.2) }, uniquingKeysWith: { $1 }),
                "failed": checks.filter { !$0.1 }.map(\.0),
                "screenshots": shots,
                "notes": notes,
            ]
            if let d = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
                try? d.write(to: URL(fileURLWithPath: "\(dir)/result.json"))
            }
            return ok
        }
    }
}
