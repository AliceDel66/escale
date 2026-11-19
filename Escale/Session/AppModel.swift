import AppKit
import Foundation
import Observation
import SwiftUI
import EscaleCore

/// Demande d'ouverture d'une feuille d'édition.
enum EditorRequest: Identifiable {
    case newHost(folder: UUID?)
    case editHost(HostProfile)
    case newFolder(parent: UUID?)
    case renameFolder(HostFolder)

    var id: String {
        switch self {
        case .newHost(let f): "new-host-\(f?.uuidString ?? "root")"
        case .editHost(let h): "edit-\(h.id)"
        case .newFolder(let p): "new-folder-\(p?.uuidString ?? "root")"
        case .renameFolder(let f): "rename-\(f.id)"
        }
    }
}

/// Suppression en attente de confirmation.
enum DeletionRequest: Identifiable {
    case host(HostProfile)
    case folder(HostFolder)
    var id: UUID { switch self { case .host(let h): h.id; case .folder(let f): f.id } }
}

/// Volets de la barre latérale (les onglets verticaux de MobaXterm : Sessions, Sftp, Tools, Macros).
enum SidebarTab: String, CaseIterable, Identifiable {
    case sessions, files, tools, macros
    var id: String { rawValue }
    var title: String {
        switch self {
        case .sessions: String(localized: "Sessions")
        case .files: String(localized: "Fichiers")
        case .tools: String(localized: "Outils")
        case .macros: String(localized: "Macros")
        }
    }
    var titleKey: LocalizedStringKey {
        switch self {
        case .sessions: "Sessions"
        case .files: "Fichiers"
        case .tools: "Outils"
        case .macros: "Macros"
        }
    }
    var symbolName: String {
        switch self {
        case .sessions: "star"
        case .files: "folder"
        case .tools: "wrench.and.screwdriver"
        case .macros: "paperplane"
        }
    }
}

/// État racine : bibliothèque, connexions, onglets, et orchestration du cycle de vie des shells.
@MainActor
@Observable
final class AppModel {
    /// Identifiant de l'entrée « Terminal local » de la barre latérale.
    static let localTerminalID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    /// Identifiant de la ligne « Connecter à … » (connexion rapide) de la barre latérale.
    static let quickConnectRowID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

    let options: LaunchOptions
    let library: LibraryStore
    let connections: ConnectionManager
    let workspace = Workspace()
    /// Fenêtres d'onglets détachés (`Escale/Views/DetachedWindows.swift`).
    let detached = DetachedWindows()

    var searchText = ""
    /// Volet affiché dans la barre latérale.
    var sidebarTab: SidebarTab = .sessions
    /// Mode compact de la fenêtre (barre d'outils en icônes, barre latérale repliée).
    let compact: CompactMode
    /// Champ « Connexion rapide » actif (⇧⌘K) : le volet Sessions lui donne le focus.
    var quickConnectFocused = false
    /// Sessions ouvertes récemment (page d'accueil) ; fichier `recents.json` à côté de la bibliothèque.
    private(set) var recents = RecentSessionList()
    @ObservationIgnored private var recentsURL: URL?
    var editor: EditorRequest?
    var pendingDeletion: DeletionRequest?
    var collapsedFolders: Set<UUID> = []
    /// Feuille d'import ssh_config ouverte (nil : aucune).
    var importer: ImportModel?
    /// Feuille d'un module ouverte (identifiant libre, nil : aucune) : bloque les dialogues d'authentification.
    var activeFeatureSheet: String?

    // Modules ajoutés après M1 (voir `AppFeature`).
    let sftp = SFTPFeature()
    let tunnels = TunnelFeature()
    let multiExec = MultiExecFeature()
    let macros = MacroFeature()
    let imports = ImportFeature()
    let updates = UpdateFeature()
    let monitoring = MonitoringFeature()
    let colors = TerminalColorsFeature()
    let mcp = MCPFeature()
    let settings = SettingsFeature()
    var features: [any AppFeature] { [sftp, tunnels, multiExec, macros, imports, updates, monitoring, colors, serial, telnet, vnc, rdp, mcp, settings] }

    // Modules de protocoles (V1.2/V2), même contrat `AppFeature`.
    let serial = SerialFeature()
    let telnet = TelnetFeature()
    let vnc = VNCFeature()
    let rdp = RDPFeature()

    /// Ouverture d'un hôte Telnet/série dans un panneau, par protocole (renseigné par le module dans `attach`).
    /// Rend la source d'octets ouverte, ou lève une erreur dont la description est affichée dans le panneau.
    @ObservationIgnored var terminalLaunchers: [ConnectionProtocol: @MainActor (Pane, HostProfile) async throws -> any TerminalByteStream] = [:]
    /// Ouverture d'un hôte VNC/RDP (fenêtre ou app de bureau distant, pas d'onglet), par protocole.
    @ObservationIgnored var externalOpeners: [ConnectionProtocol: @MainActor (HostProfile) -> Void] = [:]
    /// Observateurs du (re)démarrage d'un panneau, par clé de module : appelés avant le lancement du processus,
    /// donc avant son premier octet (couleurs du terminal).
    @ObservationIgnored var paneStartObservers: [String: @MainActor (Pane) -> Void] = [:]

    @ObservationIgnored weak var mainWindow: NSWindow?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var isShuttingDown = false

    init(options: LaunchOptions) {
        self.options = options
        // La recette n'écrit jamais dans les préférences réelles de l'utilisateur.
        compact = CompactMode(defaults: options.value("selftest-compact") != nil
                              ? (UserDefaults(suiteName: CompactSelfTest.defaultsSuite) ?? .standard) : .standard)
        let url = options.libraryPath.map { URL(fileURLWithPath: $0) } ?? LibraryStore.defaultURL
        library = LibraryStore(repository: FileHostRepository(url: url))
        recentsURL = RecentSessionList.url(besideLibrary: url)
        var ssh = OpenSSHOptions(
            configFile: options.sshConfig, userKnownHostsFile: options.knownHosts,
            strictHostKeyChecking: options.knownHosts != nil ? .yes : nil, extraOptions: options.sshOptions)
        // BatchMode reste le défaut du cœur ; le transport le désactive tout seul quand askpass est configuré
        // (toujours le cas ici : `ConnectionManager` branche l'app comme son propre SSH_ASKPASS).
        ssh.batchMode = true
        connections = ConnectionManager(sshOptions: ssh, secretStore: AuthKeychain.makeStore(service: options.keychainService))
        for f in features { f.attach(self) }
        detached.attach(self)
    }

    /// Scénarios d'auto-test des modules : `--selftest-<module> <dossier>`.
    private var featureSelfTests: [(option: String, run: @MainActor (String) async -> Bool)] {
        [
            ("selftest-sftp", { await SFTPSelfTest(directory: $0, model: self).run() }),
            ("selftest-tunnels", { await TunnelSelfTest(directory: $0, model: self).run() }),
            ("selftest-multiexec", { await MultiExecSelfTest(directory: $0, model: self).run() }),
            ("selftest-monitoring", { await MonitoringSelfTest(directory: $0, model: self).run() }),
            ("selftest-macros", { await MacroSelfTest(directory: $0, model: self).run() }),
            ("selftest-import", { await ImportSelfTest(directory: $0, model: self).run() }),
            ("selftest-terminal", { await TerminalSelfTest(directory: $0, model: self).run() }),
            ("selftest-serial", { await SerialSelfTest(directory: $0, model: self).run() }),
            ("selftest-telnet", { await TelnetSelfTest(directory: $0, model: self).run() }),
            ("selftest-vnc", { await VNCSelfTest(directory: $0, model: self).run() }),
            ("selftest-rdp", { await RDPSelfTest(directory: $0, model: self).run() }),
            ("selftest-hosteditor", { await HostEditorSelfTest(directory: $0, model: self).run() }),
            ("selftest-compact", { await CompactSelfTest(directory: $0, model: self).run() }),
            ("selftest-tabs", { await TabsSelfTest(directory: $0, model: self).run() }),
            ("selftest-colors", { await TerminalColorsSelfTest(directory: $0, model: self).run() }),
            ("selftest-mcp", { await MCPSelfTest(directory: $0, model: self).run() }),
        ]
    }

    /// Environnement du fils : celui de l'app + TERM/COLORTERM (+ LANG UTF-8 si absent, cas Finder).
    static func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "Escale"
        if env["LANG"] == nil && env["LC_ALL"] == nil { env["LANG"] = "en_US.UTF-8" }
        return env
    }

    private static func resolve(_ name: String) -> String {
        if name.contains("/") { return name }
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        for dir in path.split(separator: ":") {
            let c = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: c) { return c }
        }
        return name
    }

    // MARK: Démarrage

    /// Appelé une fois par la fenêtre : charge la bibliothèque puis lance l'éventuel scénario ou `--command`.
    func start() async {
        guard !started else { return }
        started = true
        await library.load()
        loadRecents()
        if let test = featureSelfTests.first(where: { options.value($0.option) != nil }),
           let dir = options.value(test.option) {
            Task { @MainActor in
                let ok = await test.run(dir)
                await self.shutdown()
                exit(ok ? 0 : 1)
            }
        } else if let dir = options.selftestPanesDirectory {
            let runner = PanesSelfTest(directory: dir, model: self)
            Task { @MainActor in
                let ok = await runner.run()
                await self.shutdown()
                exit(ok ? 0 : 1)
            }
        } else if let dir = options.selftestAuthDirectory {
            let runner = AuthSelfTest(directory: dir, model: self)
            Task { @MainActor in
                let ok = await runner.run()
                await self.shutdown()
                exit(ok ? 0 : 1)
            }
        } else if let dir = options.selftestSSHDirectory {
            let runner = SSHSelfTest(directory: dir, model: self)
            Task { @MainActor in
                let ok = await runner.run()
                await self.shutdown()
                exit(ok ? 0 : 1)
            }
        } else if let dir = options.selftestDirectory {
            let tab = openLocalTab(command: ["/bin/zsh", "-f", "-i"]) // shell reproductible, sans rc utilisateur
            let runner = SelfTest(directory: dir, model: self, tab: tab)
            Task { @MainActor in
                let ok = await runner.run()
                await self.shutdown()
                exit(ok ? 0 : 1)
            }
        } else if let cmd = options.command {
            openLocalTab(command: cmd)
        }
    }

    // MARK: Ouverture d'onglets

    @discardableResult
    func openLocalTab(command: [String]? = nil) -> TerminalTab {
        let title = command.map { ($0[0] as NSString).lastPathComponent } ?? String(localized: "Terminal local")
        let tab = TerminalTab(kind: .local(command: command), baseTitle: title)
        workspace.add(tab)
        start(tab)
        return tab
    }

    /// « Connecter » : réutilise l'onglet existant de l'hôte s'il y en a un, sinon en ouvre un.
    func connect(_ host: HostProfile) {
        guard host.connectionProtocol.isTerminal else { openExternal(host); return }
        if let t = workspace.tabs(forHost: host.id).first { workspace.select(t.id) } else { newTab(host) }
    }

    /// VNC/RDP : confié au module du protocole (aucun onglet).
    func openExternal(_ host: HostProfile) {
        if let open = externalOpeners[host.connectionProtocol] { noteRecent(host); open(host) }
    }

    /// Onglet d'un hôte de terminal (SSH, Telnet, série). Les appelants écartent VNC/RDP (`connect`, menus).
    @discardableResult
    func newTab(_ host: HostProfile) -> TerminalTab {
        // Plusieurs onglets du même hôte : « Hôte », « Hôte 2 », « Hôte 3 »… (titres distinguables).
        var n = workspace.tabs(forHost: host.id).count + 1
        while workspace.tabs.contains(where: { $0.hostID == host.id && $0.baseTitle == (n == 1 ? host.name : "\(host.name) \(n)") }) { n += 1 }
        let tab = TerminalTab(kind: .host(host), baseTitle: n == 1 ? host.name : "\(host.name) \(n)")
        noteRecent(host)
        workspace.add(tab)
        start(tab)
        return tab
    }

    /// Nouvel onglet identique (même hôte, ou même commande locale).
    @discardableResult
    func duplicate(_ tab: TerminalTab) -> TerminalTab {
        switch tab.kind {
        case .host(let h): newTab(library.host(h.id) ?? h)
        case .local(let command): openLocalTab(command: command)
        }
    }

    func closeOthers(_ tab: TerminalTab) {
        for t in workspace.mainTabs where t.id != tab.id { close(t) }
    }

    // MARK: Accueil, connexion rapide, sessions récentes

    /// Affiche la page d'accueil par-dessus les onglets ; le terminal masqué ne doit plus recevoir la saisie.
    func showHome() {
        guard !workspace.mainTabs.isEmpty else { return }
        workspace.showsHome = true
        mainWindow?.makeFirstResponder(nil)
    }

    /// Rend le clavier au panneau actif (retour depuis l'accueil).
    func focusActivePane() { workspace.activeTab?.activePane.session.engine.focus() }

    /// Affiche le volet Sessions et donne le focus au champ « Connexion rapide ».
    func focusQuickConnect() {
        sidebarTab = .sessions
        quickConnectFocused = true
    }

    /// « Connexion rapide » : `[utilisateur@]hôte[:port]`. Un hôte SSH identique de la bibliothèque est réutilisé ;
    /// sinon la session est enregistrée à la racine (comme MobaXterm, toute session ouverte est gardée), ce qui lui
    /// donne le même cycle de vie qu'un hôte ordinaire (Trousseau nettoyé à la suppression, invariant 7).
    /// Faux si la saisie n'est pas une cible valide.
    @discardableResult
    func quickConnect(_ text: String) -> Bool {
        guard let target = QuickConnectTarget.parse(text) else { return false }
        if let known = library.library.hosts.first(where: { target.matches($0) }) {
            connect(known)
        } else {
            let profile = target.makeProfile()
            library.upsert(profile)
            // Enregistrement refusé : rien n'est ouvert (un hôte hors bibliothèque laisserait un secret orphelin
            // dans le Trousseau) ; le motif est affiché par le bandeau de la bibliothèque.
            guard let saved = library.host(profile.id) else { return true }
            connect(saved)
        }
        return true
    }

    /// Hôtes récents encore présents dans la bibliothèque, du plus récent au plus ancien.
    var recentHosts: [(host: HostProfile, date: Date)] {
        recents.entries.compactMap { e in library.host(e.hostID).map { ($0, e.date) } }
    }

    func clearRecents() { recents.clear(); saveRecents() }

    private func loadRecents() {
        guard let url = recentsURL else { return }
        recents = RecentSessionList.load(from: url)
    }

    private func noteRecent(_ host: HostProfile) {
        guard library.host(host.id) != nil else { return }
        recents.record(host.id)
        recents.prune(keeping: Set(library.library.hosts.map(\.id)))
        saveRecents()
    }

    private func saveRecents() {
        guard let url = recentsURL else { return }
        let snapshot = recents
        Task.detached(priority: .utility) { try? snapshot.save(to: url) }
    }

    /// Démarre (ou relance) le shell de chaque panneau de l'onglet.
    func start(_ tab: TerminalTab) { for p in tab.panes { start(p) } }

    func start(_ pane: Pane) {
        pane.startTask?.cancel()
        pane.status = .connecting
        for o in paneStartObservers.values { o(pane) }
        pane.startTask = Task { await self.run(pane) }
    }

    /// Fermeture d'un onglet : tue le pty (le bail du PTYProcess rend la place une seule fois)
    /// et libère la connexion (déconnexion différée si c'était le dernier).
    func close(_ tab: TerminalTab) {
        guard !tab.isClosing else { return }
        tab.isClosing = true
        workspace.remove(tab)
        for p in tab.panes { teardown(p) }
    }

    /// Arrête un panneau : tâche de démarrage, pty (le gestionnaire de fin compte le shell) et lien maître.
    private func teardown(_ pane: Pane) {
        pane.isClosing = true
        pane.startTask?.cancel()
        pane.session.kill()
        if let link = pane.link { pane.link = nil; link.release() }
    }

    /// Cmd-W : ferme le panneau actif, puis l'onglet quand il n'en reste plus.
    func closeActiveTab() { closeActivePane() }

    func closeActivePane() { if let t = workspace.activeTab { closePane(t.activePane, in: t) } }

    /// Ferme un panneau (le frère reprend la place) ; le dernier panneau ferme l'onglet.
    func closePane(_ pane: Pane, in tab: TerminalTab) {
        guard !pane.isClosing else { return }
        if tab.removePane(pane.id) { teardown(pane) } else { close(tab) }
    }

    func closePane(_ pane: Pane) {
        if let t = workspace.tabs.first(where: { $0.pane(pane.id) != nil }) { closePane(pane, in: t) }
    }

    /// Scinde le panneau actif : le nouveau panneau ouvre un shell sur le même hôte (même maître, sans nouvelle
    /// authentification) ou un terminal local si l'origine est locale.
    @discardableResult
    func splitActivePane(_ axis: PaneAxis) -> Pane? {
        guard let t = workspace.activeTab, !t.isClosing else { return nil }
        let p = t.splitActive(axis)
        start(p)
        return p
    }

    func disconnect(_ host: HostProfile) {
        for t in workspace.tabs(forHost: host.id) { close(t) }
        if let c = connections.existing(host.id) { Task { await c.shutdown() } }
    }

    func deleteHost(_ host: HostProfile) {
        disconnect(host)
        library.deleteHost(host.id)
        // Le secret Trousseau d'un hôte supprimé ne doit pas lui survivre (invariant 7).
        let store = connections.secretStore
        Task { _ = await AuthKeychain.forgetAll(hostID: host.id, store: store) }
    }

    // MARK: Import ssh_config

    /// Ouvre la feuille d'import (source : `--ssh-config-import-source` sinon ~/.ssh/config, lu en lecture seule).
    func beginImport(destinationFolder: UUID? = nil) {
        let source = options.sshConfigImportSource.map { URL(fileURLWithPath: $0) } ?? ImportModel.defaultSource
        let m = ImportModel(library: library, source: source)
        m.folderID = destinationFolder
        importer = m
    }

    // MARK: Cycle de vie d'un shell

    private func run(_ tab: Pane) async {
        switch tab.kind {
        case .local(let command):
            launchLocal(tab, command: command)
        case .host(let profile) where profile.connectionProtocol != .ssh:
            await launchStream(tab, profile: profile)
        case .host(let profile):
            let conn = connections.connection(for: profile)
            let link = tab.link ?? conn.acquireLink()
            tab.link = link
            await launchRemote(tab, link: link)
        }
    }

    private var showsLocalBanner: Bool {
        if let v = options.value("local-banner") { return v == "on" }
        if options.isSelfTest { return false }
        return settings.localBannerEnabled
    }

    private func launchLocal(_ tab: Pane, command: [String]?) {
        let (exe, args): (String, [String])
        if let cmd = command { (exe, args) = (Self.resolve(cmd[0]), Array(cmd.dropFirst())) } else {
            (exe, args) = (ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh", ["-l"])
        }
        let s = tab.session.engine.size
        // Bannière d'accueil (façon MobaXterm) : shell interactif seulement, au premier lancement de l'écran (pas à
        // la relance ni pour une commande), écrite dans l'écran et non envoyée au shell. Absente des recettes, sauf
        // `--local-banner on` ; désactivable par `defaults write <bundle> escale.localBanner -bool NO`.
        if command == nil, tab.session.state == .idle, showsLocalBanner {
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
            tab.session.engine.feed(Data(WelcomeBanner.render(columns: s.columns, version: version,
                                                              shell: URL(fileURLWithPath: exe).lastPathComponent).utf8))
        }
        do {
            let p = try PTYProcess(executable: exe, arguments: args, environment: Self.environment(),
                                   columns: s.columns, rows: s.rows, currentDirectory: NSHomeDirectory())
            tab.session.attach(p) { [weak tab] status in
                guard let tab, !tab.isClosing else { return }
                tab.status = .ended(status)
            }
            tab.status = .running
        } catch {
            tab.status = .failed(String(localized: "lancement de \(exe) impossible : \(error.localizedDescription)"))
        }
    }

    /// Telnet, série : source d'octets ouverte par le module du protocole ; pas de maître ssh ni de reconnexion.
    private func launchStream(_ tab: Pane, profile: HostProfile) async {
        guard let launcher = terminalLaunchers[profile.connectionProtocol] else {
            tab.status = .failed(String(localized: "Protocole \(profile.connectionProtocol.localizedDisplayName) non pris en charge."))
            return
        }
        do {
            let stream = try await launcher(tab, profile)
            if tab.isClosing || Task.isCancelled { stream.kill(); return }
            tab.session.attach(stream) { [weak tab] status in
                guard let tab, !tab.isClosing else { return }
                tab.status = .ended(status)
            }
            tab.status = .running
        } catch {
            if tab.isClosing || Task.isCancelled { return }
            tab.status = .failed((error as? CustomStringConvertible)?.description ?? error.localizedDescription)
        }
    }

    /// Connexion (si besoin) puis shell distant dans un pty ; reprend en boucle si le maître meurt entre-temps.
    private func launchRemote(_ tab: Pane, link: SSHLink) async {
        var attempts = 0
        while !tab.isClosing, !Task.isCancelled {
            do {
                try await link.ensureConnected()
                if tab.isClosing { return }
                let cmd = try await link.transport.shellCommand()
                connections.trackShell(cmd)
                var env = Self.environment()
                for (k, v) in cmd.environment { env[k] = v }
                let s = tab.session.engine.size
                let p: PTYProcess
                do {
                    p = try PTYProcess(executable: cmd.executable, arguments: cmd.arguments, environment: env,
                                       columns: s.columns, rows: s.rows, lease: cmd.lease)
                } catch {
                    // Le bail est déjà rendu par PTYProcess (échec de lancement).
                    tab.status = .failed(String(localized: "lancement de ssh impossible : \(error.localizedDescription)"))
                    return
                }
                tab.launchEpoch = link.epoch
                tab.session.attach(p, watchX11Refusal: link.profile.x11Forwarding) { [weak self, weak tab] status in
                    guard let self, let tab else { return }
                    Task { await self.remoteShellEnded(tab, link: link, status: status) }
                }
                tab.status = .running
                sendStartupCommand(for: tab)
                return
            } catch SSHTransportError.notConnected where attempts < 3 {
                // Le maître est mort sans que personne ne s'en soit aperçu : même chemin qu'une coupure.
                attempts += 1
                tab.status = .reconnecting
                link.handleConnectionLost()
                _ = await link.waitReconnect()
            } catch {
                if tab.isClosing || Task.isCancelled { return }
                tab.status = .failed(link.message(for: error))
                return
            }
        }
    }

    /// Fin d'un shell distant (appelée une fois par processus).
    private func remoteShellEnded(_ tab: Pane, link: SSHLink, status: PTYExitStatus) async {
        // La place du maître est rendue par le bail du PTYProcess : rien à décrémenter ici.
        if tab.isClosing || isShuttingDown { return }
        let alive = await link.transport.isAlive()
        let lost = !alive || link.epoch != tab.launchEpoch
        guard lost else { tab.status = .ended(status); return }
        // Connexion tombée : l'écran est conservé, tous les onglets du maître partagent une seule reconnexion.
        tab.status = .reconnecting
        link.handleConnectionLost()
        let ok = await link.waitReconnect()
        if tab.isClosing || isShuttingDown { return }
        // « Authentification requise », secret refusé, annulation, clé d'hôte modifiée : message du lien, bouton « Réessayer ».
        guard ok else { tab.status = .failed(link.lastError ?? String(localized: "reconnexion abandonnée")); return }
        let stamp = Date.now.formatted(.iso8601.year().month().day().dateSeparator(.dash).time(includingFractionalSeconds: false).timeSeparator(.colon).dateTimeSeparator(.space))
        tab.session.appendSeparator(String(localized: "Connexion rétablie le \(stamp)"))
        await launchRemote(tab, link: link)
    }

    /// « Reconnecter maintenant » (bandeau) ou « Réessayer » (échec).
    func retry(_ tab: Pane) {
        switch tab.status {
        case .reconnecting: tab.link?.retryNow()
        case .failed, .ended: start(tab)
        default: break
        }
    }

    // MARK: Arrêt

    /// Tue tous les pty et déconnecte tous les maîtres (aucun ssh résiduel).
    func shutdown() async {
        isShuttingDown = true
        for t in workspace.tabs { t.isClosing = true; for p in t.panes { p.isClosing = true; p.startTask?.cancel(); p.session.kill() } }
        for f in features { await f.shutdown() }
        await connections.shutdownAll()
        // Serveur X11 intégré : arrêté par son pid (jamais par motif), dossier privé supprimé.
        connections.x11Server?.stop()
        // Laisse les gestionnaires de fin de pty compter leurs shells.
        for _ in 0..<40 where connections.shellsEnded < connections.shellsStarted {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }
}
