import Foundation
import Observation
import EscaleCore

/// Une connexion maître (un `OpenSSHTransport`) et son cycle de vie : connexion, perte,
/// reconnexion avec attente croissante, déconnexion différée quand plus aucun onglet ne l'utilise.
@MainActor
@Observable
final class SSHLink {
    enum State: Equatable {
        case disconnected
        case connecting
        case connected
        case failed(String)
        /// `retryIn` : secondes avant la prochaine tentative ; nil pendant une tentative.
        case reconnecting(attempt: Int, retryIn: Int?)
        /// Une saisie est nécessaire pour rétablir la connexion (reconnexion automatique : jamais de feuille ouverte seule).
        case authRequired
        /// L'utilisateur a annulé une invite (ou refusé une clé d'hôte inconnue) : aucune nouvelle tentative automatique.
        case cancelled
        /// Clé d'hôte modifiée : refus définitif (invariant 10), jamais de dialogue de confirmation.
        case hostKeyChanged(String)
    }

    private(set) var state: State = .disconnected
    /// Onglets rattachés (shells lancés ou en attente).
    var tabCount = 0
    private(set) var lastError: String?
    /// Incrémenté à chaque perte détectée : un shell lancé avant (époque différente) appartient à une connexion morte.
    private(set) var epoch = 0

    @ObservationIgnored let transport: OpenSSHTransport
    @ObservationIgnored unowned let manager: ConnectionManager
    @ObservationIgnored let gate: AuthInteractionGate
    @ObservationIgnored let profile: HostProfile
    @ObservationIgnored private var connectTask: Task<Void, Error>?
    @ObservationIgnored private var reconnectTask: Task<Bool, Never>?
    @ObservationIgnored private var graceTask: Task<Void, Never>?
    @ObservationIgnored private var skipWait = false
    @ObservationIgnored private var cancelRequested = false
    /// Nombre de `connect()` effectivement lancés (tests : une seule tentative partagée par tous les onglets).
    @ObservationIgnored private(set) var connectAttempts = 0

    init(profile: HostProfile, manager: ConnectionManager) {
        self.manager = manager
        self.profile = profile
        let gate = AuthInteractionGate(profile: profile, center: manager.dialogs)
        self.gate = gate
        let responder = AppAskpassResponder(
            auth: profile.auth, hostID: profile.id, store: manager.secretStore,
            interaction: { request in await gate.interact(request) })
        // L'app est son propre SSH_ASKPASS (voir `Launcher` : `AskpassClient.runIfRequested()` avant tout AppKit).
        // Délai de réponse plus long que le défaut du cœur (120 s) : l'utilisateur peut chercher un code 2FA.
        let askpass = AskpassConfiguration(
            executablePath: manager.askpassExecutable, responder: responder,
            limits: AskpassServer.Limits(responseTimeout: 290))
        transport = OpenSSHTransport(profile: profile, configuration: .init(ssh: manager.sshOptions(for: profile), askpass: askpass))
    }

    /// Message français d'une erreur, sans contexte d'hôte (journal de ssh pour les erreurs de transport).
    static func describe(_ error: Error) -> String {
        if let a = error as? SSHAuthenticationError { return describe(a, host: nil, knownHostsPath: nil) }
        if let e = error as? SSHTransportError {
            switch e {
            case .masterFailed(let m), .sessionRefused(let m), .subsystemUnavailable(let m), .forwardRefused(let m): return m
            case .notConnected: return String(localized: "connexion non établie")
            }
        }
        return error.localizedDescription
    }

    /// Messages distincts pour chaque `SSHAuthenticationError` (aucun secret : ceux du cœur n'en contiennent pas).
    static func describe(_ error: SSHAuthenticationError, host: String?, knownHostsPath: String?) -> String {
        switch error {
        case .wrongSecret:
            return String(localized: "Secret refusé par le serveur (mot de passe, phrase de passe ou code incorrect).")
        case .cancelled:
            return String(localized: "Authentification annulée.")
        case .hostKeyRejected:
            return String(localized: "Clé d'hôte non approuvée : connexion annulée.")
        case .timedOut:
            return String(localized: "Délai dépassé : aucune réponse à l'invite d'authentification.")
        case .hostKeyChanged:
            let h = host.map { String(localized: " de « \($0) »") } ?? ""
            let f = knownHostsPath.map { String(localized: " Fichier known_hosts concerné : \($0).") } ?? ""
            return String(localized: "La clé d'hôte\(h) a changé : connexion refusée par sécurité (serveur remplacé ou connexion interceptée).\(f)")
        }
    }

    /// Chemin du known_hosts concerné : ligne « Offending … key in <chemin>:<n> » de ssh, sinon l'option, sinon le défaut.
    private func knownHostsPath() async -> String {
        let journal = await transport.masterJournal()
        if let re = try? NSRegularExpression(pattern: #"[Oo]ffending \S+ key in (\S+?):\d+"#),
           let m = re.firstMatch(in: journal, range: NSRange(journal.startIndex..., in: journal)),
           let r = Range(m.range(at: 1), in: journal) { return String(journal[r]) }
        return manager.sshOptions.userKnownHostsFile ?? "~/.ssh/known_hosts"
    }

    /// Traduit une erreur de connexion, enregistre `lastError` et fixe l'état dédié.
    private func recordFailure(_ error: Error) async {
        if let a = error as? SSHAuthenticationError {
            switch a {
            case .hostKeyChanged:
                let msg = Self.describe(a, host: profile.host, knownHostsPath: await knownHostsPath())
                lastError = msg; state = .hostKeyChanged(msg)
            case .cancelled, .hostKeyRejected:
                lastError = Self.describe(a, host: nil, knownHostsPath: nil); state = .cancelled
            case .wrongSecret, .timedOut:
                lastError = Self.describe(a, host: nil, knownHostsPath: nil); state = .failed(lastError ?? "")
            }
        } else {
            lastError = Self.describe(error)
            state = .failed(lastError ?? "")
        }
    }

    /// Message à afficher pour une erreur levée par `ensureConnected()` (état déjà enregistré).
    func message(for error: Error) -> String {
        if error is SSHAuthenticationError, let m = lastError { return m }
        return Self.describe(error)
    }

    // MARK: Connexion initiale

    /// Garantit un maître vivant : connecte si besoin (une seule tentative partagée), ou attend une reconnexion en cours.
    func ensureConnected() async throws {
        if case .connected = state { return }
        if reconnectTask != nil {
            if await waitReconnect() { return }
            throw SSHTransportError.masterFailed(lastError ?? String(localized: "reconnexion abandonnée"))
        }
        if let t = connectTask { return try await t.value }
        state = .connecting
        cancelRequested = false
        connectAttempts += 1
        let t = Task {
            await self.manager.prepareX11(for: self.profile, settings: self.transport.configuration.ssh.x11)
            try await self.transport.connect()
        }
        connectTask = t
        do {
            try await t.value
            connectTask = nil
            state = .connected
            manager.notify(self, .connected)
        } catch {
            connectTask = nil
            if cancelRequested { state = .disconnected } else { await recordFailure(error) }
            throw error
        }
    }

    // MARK: Perte et reconnexion

    /// Signale que le maître est mort. Idempotent : tous les onglets partagent la même reconnexion.
    func handleConnectionLost() {
        guard reconnectTask == nil else { return }
        epoch += 1
        cancelRequested = false
        state = .reconnecting(attempt: 1, retryIn: nil)
        manager.notify(self, .lost)
        reconnectTask = Task { await self.reconnectLoop() }
    }

    /// Attend la fin de la reconnexion en cours ; vrai si la connexion est rétablie.
    func waitReconnect() async -> Bool {
        if let t = reconnectTask { return await t.value }
        return state == .connected
    }

    /// « Reconnecter maintenant » : coupe l'attente courante.
    func retryNow() { skipWait = true }

    /// Reconnexion automatique : sans feuille. Un secret mémorisé est réutilisé par le responder ; toute autre
    /// invite met fin à la boucle (état « authentification requise »). Une annulation, un secret refusé, un délai ou
    /// une clé d'hôte modifiée mettent aussi fin à la boucle : jamais de nouvelle tentative automatique.
    private func reconnectLoop() async -> Bool {
        var attempt = 1
        while !Task.isCancelled {
            let delays = manager.reconnectDelays
            let delay = delays.isEmpty ? 1 : delays[min(attempt - 1, delays.count - 1)]
            skipWait = false
            var remaining = delay
            var shown = -1
            while remaining > 0, !skipWait, !Task.isCancelled {
                let secs = Int(remaining.rounded(.up))
                if secs != shown { shown = secs; state = .reconnecting(attempt: attempt, retryIn: secs) }
                try? await Task.sleep(for: .milliseconds(100))
                remaining -= 0.1
            }
            if Task.isCancelled { break }
            state = .reconnecting(attempt: attempt, retryIn: nil)
            connectAttempts += 1
            gate.resetNeedsInput()
            gate.unattended = true
            do {
                await manager.prepareX11(for: profile, settings: transport.configuration.ssh.x11)
                try await transport.connect()
                gate.unattended = false
                if Task.isCancelled { break }
                state = .connected
                lastError = nil
                reconnectTask = nil
                manager.notify(self, .connected)
                return true
            } catch {
                gate.unattended = false
                if Task.isCancelled { break }
                await transport.disconnect()
                if gate.needsInput {
                    lastError = Self.authRequiredMessage
                    state = .authRequired
                    reconnectTask = nil
                    return false
                }
                if error is SSHAuthenticationError {
                    await recordFailure(error)
                    reconnectTask = nil
                    return false
                }
                lastError = Self.describe(error)
                attempt += 1
            }
        }
        await transport.disconnect()
        state = .disconnected
        reconnectTask = nil
        return false
    }

    static var authRequiredMessage: String { String(localized: "Authentification requise") }

    // MARK: Rattachement des onglets

    func cancelGrace() { graceTask?.cancel(); graceTask = nil }

    /// Un onglet libère la connexion ; au dernier, déconnexion après le délai de grâce.
    func release() {
        tabCount = max(0, tabCount - 1)
        guard tabCount == 0 else { return }
        graceTask?.cancel()
        let delay = manager.graceDelay
        graceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, self.tabCount == 0 else { return }
            await self.shutdown()
        }
    }

    /// Coupe tout : tentative en cours, reconnexion, maître.
    func shutdown() async {
        cancelGrace()
        cancelRequested = true
        reconnectTask?.cancel()
        connectTask?.cancel()
        state = .disconnected
        manager.dialogs.cancelAll(forHost: profile.id)
        await transport.disconnect()
        manager.notify(self, .disconnected)
        if let t = reconnectTask { _ = await t.value }
    }

    var isDead: Bool { if case .disconnected = state { true } else { false } }
}

/// Au plus une `HostConnection` par hôte ; elle possède un ou plusieurs liens maîtres
/// (au-delà de 9 shells sur un maître, un second maître est ouvert : invariant 5).
@MainActor
@Observable
final class HostConnection {
    let profile: HostProfile
    private(set) var links: [SSHLink] = []
    @ObservationIgnored unowned let manager: ConnectionManager

    init(profile: HostProfile, manager: ConnectionManager) { self.profile = profile; self.manager = manager }

    var tabCount: Int { links.reduce(0) { $0 + $1.tabCount } }

    /// État agrégé affiché dans la barre latérale.
    var state: SSHLink.State {
        let states = links.map(\.state)
        if let r = states.first(where: { if case .reconnecting = $0 { true } else { false } }) { return r }
        if states.contains(.connecting) { return .connecting }
        if states.contains(.connected) { return .connected }
        if states.contains(.authRequired) { return .authRequired }
        if let h = states.first(where: { if case .hostKeyChanged = $0 { true } else { false } }) { return h }
        if let f = states.first(where: { if case .failed = $0 { true } else { false } }) { return f }
        if states.contains(.cancelled) { return .cancelled }
        return .disconnected
    }

    /// Lien ayant de la place (moins de 9 onglets), sinon un nouveau lien (second maître).
    func acquireLink() -> SSHLink {
        let link = links.first { $0.tabCount < manager.maxShellsPerLink } ?? {
            let l = SSHLink(profile: profile, manager: manager)
            links.append(l)
            return l
        }()
        link.cancelGrace()
        link.tabCount += 1
        return link
    }

    func shutdown() async { for l in links { await l.shutdown() } }
}

@MainActor
@Observable
final class ConnectionManager {
    private(set) var connections: [UUID: HostConnection] = [:]
    /// Options ssh communes (les liens créés ensuite les copient ; les tests les ajustent avant de créer un lien).
    @ObservationIgnored var sshOptions: OpenSSHOptions
    /// Magasin des secrets (Keychain) et exécutable qui sert de `SSH_ASKPASS` (l'app elle-même).
    @ObservationIgnored let secretStore: any SecretStore
    @ObservationIgnored let askpassExecutable: String
    /// File des dialogues d'authentification (un seul affiché à la fois).
    let dialogs = AuthDialogCenter()
    /// Attentes entre tentatives de reconnexion (la dernière valeur se répète).
    @ObservationIgnored var reconnectDelays: [Double] = [1, 2, 5, 10, 30]
    /// Délai de grâce avant déconnexion quand le dernier onglet d'un hôte se ferme.
    @ObservationIgnored var graceDelay: Double = 3
    @ObservationIgnored let maxShellsPerLink = 9
    /// Compteurs (tests) : chaque shell lancé (bail `ShellCommand.lease`) doit être rendu une seule fois.
    /// Événements de cycle de vie d'un lien, pour les modules (tunnels rétablis après reconnexion, SFTP…).
    enum LinkEvent: Equatable { case connected, lost, disconnected }
    /// Observateurs par clé de module (une clé remplace l'observateur précédent).
    @ObservationIgnored var linkObservers: [String: @MainActor (SSHLink, LinkEvent) -> Void] = [:]
    func notify(_ link: SSHLink, _ event: LinkEvent) { for o in linkObservers.values { o(link, event) } }

    /// Serveur X11 intégré (`Contents/Helpers/EscaleX11.app`, prioritaire) ; `nil` s'il n'est pas embarqué : XQuartz
    /// installé sert alors de secours. Démarré à la demande, juste avant un maître ou une application X11.
    @ObservationIgnored var x11Server: EmbeddedX11Server?
    /// Dernière erreur de démarrage du serveur intégré (affichée avec la détection).
    @ObservationIgnored private(set) var x11ServerError: String?
    /// M5 : détection de l'affichage X11 et mode « confiance » (injectables : tests et auto-test).
    @ObservationIgnored var x11Detect: () -> X11Detection = { X11Detection.detect() }
    @ObservationIgnored var x11Trusted: () -> Bool = { UserDefaults.standard.bool(forKey: X11Preferences.trustedKey) }

    /// Options ssh d'un hôte : les communes + la redirection X11 quand l'hôte la demande ET que XQuartz est utilisable
    /// (sinon aucune option X11 : jamais de `-X` sans XQuartz).
    func sshOptions(for profile: HostProfile) -> OpenSSHOptions {
        var o = sshOptions
        if profile.x11Forwarding { o.x11 = x11Detect().settings(trusted: x11Trusted()) }
        return o
    }

    /// Démarre le serveur intégré si ces réglages X11 le désignent (sinon rien : XQuartz, ou pas de X11). Bloquant
    /// hors du fil principal. Renvoie le message d'erreur, ou `nil` ; la connexion ssh se fait de toute façon.
    @discardableResult
    func prepareX11(for profile: HostProfile, settings: X11Settings?) async -> String? {
        guard profile.x11Forwarding, let x = settings, let server = x11Server, x.display == server.display else { return nil }
        do {
            try await Task.detached { try server.ensureRunning() }.value
            x11ServerError = nil
            return nil
        } catch {
            let m = (error as? EmbeddedX11Error)?.description ?? error.localizedDescription
            x11ServerError = m
            return m
        }
    }

    @ObservationIgnored var shellsStarted = 0
    @ObservationIgnored var shellsEnded = 0
    /// Compte un shell/exec lancé et sa fin (bail rendu : une seule fois, quelle que soit la cause).
    func trackShell(_ cmd: ShellCommand) {
        shellsStarted += 1
        cmd.lease?.whenReleased { Task { @MainActor [weak self] in self?.shellsEnded += 1 } }
    }

    init(sshOptions: OpenSSHOptions, secretStore: any SecretStore = AuthKeychain.makeStore(service: nil),
         askpassExecutable: String = Bundle.main.executablePath ?? CommandLine.arguments[0]) {
        self.sshOptions = sshOptions
        self.secretStore = secretStore
        self.askpassExecutable = askpassExecutable
        if let bundle = EmbeddedX11Bundle.inside(appBundle: Bundle.main.bundleURL) {
            // Gestionnaire de fenêtres (quartz-wm) actif par défaut ; `defaults write … x11WindowManager -bool NO` le coupe.
            let wm = UserDefaults.standard.object(forKey: "x11WindowManager") as? Bool ?? true
            let server = EmbeddedX11Server(bundle: bundle, runtimeDirectory: EmbeddedX11Server.defaultRuntimeDirectory(), windowManager: wm)
            x11Server = server
            x11Detect = { X11Detection.embedded(server) }
        }
    }

    func connection(for profile: HostProfile) -> HostConnection {
        if let c = connections[profile.id] {
            if c.profile == profile || c.tabCount > 0 { return c }
            Task { await c.shutdown() } // profil modifié et connexion inutilisée : on repart de zéro
        }
        let c = HostConnection(profile: profile, manager: self)
        connections[profile.id] = c
        return c
    }

    func existing(_ hostID: UUID) -> HostConnection? { connections[hostID] }
    func state(of hostID: UUID) -> SSHLink.State { connections[hostID]?.state ?? .disconnected }
    var allLinks: [SSHLink] { connections.values.flatMap(\.links) }

    func shutdownAll() async {
        for c in connections.values { await c.shutdown() }
    }
}
