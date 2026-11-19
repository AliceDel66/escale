import AppKit
import Darwin
import Observation
import EscaleCore

/// Une connexion VNC ouverte dans une fenêtre : tunnel SSH éventuel, client RFB, identifiants, état affiché.
/// Possède tout ce qu'elle ouvre (tunnel, lien SSH retenu, connexion TCP) et le ferme dans `close()`.
@MainActor
@Observable
final class VNCSession: Identifiable {
    enum Phase: Equatable {
        case connecting(String)
        /// Le serveur demande un mot de passe (et un nom d'utilisateur pour Apple Remote Desktop).
        case needsCredentials
        case connected
        /// Fin de session (message : cause, nil pour une déconnexion voulue).
        case ended(String?)
        case failed(String)
    }

    let id = UUID()
    let host: HostProfile
    private(set) var settings: VNCSettings
    @ObservationIgnored unowned let model: AppModel

    private(set) var phase: Phase = .connecting(String(localized: "Connexion…"))
    private(set) var serverInfo: RFBServerInfo?
    /// Taille de l'écran distant (suit `DesktopSize`).
    private(set) var remoteSize = CGSize.zero
    /// Message d'une tentative d'authentification refusée (affiché au-dessus du champ).
    private(set) var promptError: String?
    private(set) var promptKind: RFBAuthRequest.Kind = .vncPassword
    var username = ""
    var scaling: VNCScaling
    /// Saisie autorisée (clavier, souris, presse-papiers) : faux en lecture seule.
    var inputEnabled: Bool
    /// Lissage de l'agrandissement (réglage de la fenêtre, non mémorisé).
    var smoothing = false
    var rememberPassword = true
    private(set) var notice: String?

    /// Presse-papiers local (injectable : l'auto-test n'écrase pas celui de l'utilisateur).
    @ObservationIgnored var pasteboard: NSPasteboard = .general
    @ObservationIgnored weak var display: VNCDisplayView?
    @ObservationIgnored private(set) var client: RFBClient?
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var closing = false

    // Identifiants
    @ObservationIgnored private var credentialContinuation: CheckedContinuation<RFBCredentials?, Never>?
    @ObservationIgnored private var triedStored = false
    @ObservationIgnored private var typedPassword: String?
    @ObservationIgnored private var storedPasswordUsed = false

    // Tunnel SSH
    @ObservationIgnored private var link: SSHLink?
    @ObservationIgnored private var controller: TunnelController?
    @ObservationIgnored private var tunnelSpec: TunnelSpec?
    /// Port local du tunnel (nil : connexion directe).
    @ObservationIgnored private(set) var tunnelPort: Int?

    init(host: HostProfile, model: AppModel) {
        self.host = host
        self.model = model
        let s = host.vnc ?? VNCSettings()
        settings = s
        scaling = s.scaling
        inputEnabled = !s.viewOnly
        username = host.user ?? ""
    }

    var isConnected: Bool { if case .connected = phase { true } else { false } }
    var port: Int { host.port ?? ConnectionProtocol.vnc.defaultPort ?? 5900 }

    // MARK: Cycle de vie

    func start() {
        guard runTask == nil else { return }
        runTask = Task { [weak self] in await self?.run() }
    }

    /// Nouvelle tentative après un échec ou une fin de session.
    func reconnect() {
        guard !closing else { return }
        switch phase {
        case .failed, .ended: break
        default: return
        }
        runTask?.cancel()
        runTask = nil
        triedStored = false
        promptError = nil
        phase = .connecting(String(localized: "Connexion…"))
        start()
    }

    /// Déconnexion voulue : la fenêtre reste ouverte (bouton « Reconnecter »).
    func disconnect() {
        guard !closing else { return }
        runTask?.cancel()
        runTask = nil
        Task { await teardown() }
        phase = .ended(nil)
    }

    /// Fermeture définitive (fenêtre fermée, arrêt de l'app) : tout ce que la session a ouvert est fermé.
    func close() async {
        guard !closing else { return }
        closing = true
        runTask?.cancel()
        runTask = nil
        await teardown()
        phase = .ended(nil)
    }

    private func teardown() async {
        credentialContinuation?.resume(returning: nil)
        credentialContinuation = nil
        let c = client
        client = nil
        if let c { await c.disconnect() }
        if let spec = tunnelSpec, let controller { _ = await controller.stop(spec.id) }
        tunnelSpec = nil
        controller = nil
        tunnelPort = nil
        if let l = link { l.release(); link = nil }
    }

    // MARK: Connexion

    private func run() async {
        while !Task.isCancelled && !closing {
            do {
                let endpoint = try await resolveEndpoint()
                phase = .connecting(String(localized: "Connexion à \(endpoint.host):\(endpoint.port)…"))
                let transport = try await RFBNetworkTransport.connect(host: endpoint.host, port: endpoint.port)
                let client = RFBClient(transport: transport, configuration: RFBConfiguration(settings: settings))
                self.client = client
                let info = try await client.connect(credentials: { [weak self] request in
                    await self?.askCredentials(request)
                })
                if Task.isCancelled || closing { await client.disconnect(); return }
                serverInfo = info
                remoteSize = CGSize(width: info.width, height: info.height)
                phase = .connected
                promptError = nil
                await rememberPasswordIfNeeded()
                display?.sessionDidConnect()
                await consume(client)
                return
            } catch let error as RFBError {
                await dropClient()
                if case .authenticationFailed(let m) = error {
                    // Le serveur ferme après un refus : on se reconnecte pour une nouvelle saisie.
                    promptError = storedPasswordUsed ? String(localized: "Le mot de passe enregistré a été refusé. \(m)") : m
                    typedPassword = nil
                    continue
                }
                if error == .authenticationCancelled { phase = .ended(String(localized: "Authentification annulée.")); return }
                if Task.isCancelled || closing { return }
                phase = .failed(error.description)
                return
            } catch {
                await dropClient()
                if Task.isCancelled || closing { return }
                phase = .failed(Self.message(error))
                return
            }
        }
    }

    private func dropClient() async {
        let c = client
        client = nil
        if let c { await c.disconnect() }
    }

    private static func message(_ error: Error) -> String {
        if error is RFBError || error is VNCSessionError { return String(describing: error) }
        return error.localizedDescription
    }

    private func consume(_ client: RFBClient) async {
        for await event in client.events {
            switch event {
            case .updated: display?.framebufferChanged()
            case .resized(let w, let h):
                remoteSize = CGSize(width: w, height: h)
                display?.remoteSizeChanged()
            case .cursor(let c): display?.setRemoteCursor(c)
            case .clipboard(let text):
                guard inputEnabled else { continue }
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
            case .bell: NSSound.beep()
            case .disconnected(let err):
                if closing { return }
                self.client = nil
                if let err, err != .connectionClosed { phase = .failed(err.description) }
                else { phase = .ended(err == nil ? nil : String(localized: "Le serveur a fermé la connexion.")) }
                if let spec = tunnelSpec, let controller { _ = await controller.stop(spec.id); tunnelSpec = nil; tunnelPort = nil }
                return
            }
        }
    }

    // MARK: Identifiants

    private var storedAccount: String { VNCSettings.passwordAccount(for: host.id) }

    private func askCredentials(_ request: RFBAuthRequest) async -> RFBCredentials? {
        promptKind = request.kind
        // Première tentative : le mot de passe du Trousseau, sans rien demander.
        if !triedStored {
            triedStored = true
            if let secret = try? await model.connections.secretStore.secret(for: storedAccount), !secret.isEmpty,
               request.kind == .vncPassword || !username.isEmpty {
                storedPasswordUsed = true
                return RFBCredentials(username: username, password: secret.string)
            }
        }
        storedPasswordUsed = false
        phase = .needsCredentials
        return await withCheckedContinuation { credentialContinuation = $0 }
    }

    /// Validation de la feuille de mot de passe.
    func submitCredentials(username: String? = nil, password: String) {
        guard let c = credentialContinuation else { return }
        credentialContinuation = nil
        if let username { self.username = username }
        typedPassword = password
        phase = .connecting(String(localized: "Authentification…"))
        c.resume(returning: RFBCredentials(username: self.username, password: password))
    }

    /// Annulation de la feuille de mot de passe.
    func cancelCredentials() {
        guard let c = credentialContinuation else { return }
        credentialContinuation = nil
        c.resume(returning: nil)
    }

    /// Mémorisation dans le Trousseau, seulement après une connexion réussie (invariant 11).
    private func rememberPasswordIfNeeded() async {
        defer { typedPassword = nil }
        guard rememberPassword, let pw = typedPassword, !pw.isEmpty else { return }
        do { try await model.connections.secretStore.setSecret(Secret(pw), for: storedAccount) }
        catch { notice = String(localized: "Mot de passe non enregistré dans le Trousseau (\(error)).") }
    }

    // MARK: Tunnel SSH

    private func resolveEndpoint() async throws -> (host: String, port: Int) {
        guard let viaID = settings.viaSSHHostID else { return (host.host, port) }
        guard let via = model.library.host(viaID), via.connectionProtocol == .ssh else {
            throw VNCSessionError(String(localized: "L'hôte SSH du tunnel n'existe plus dans la bibliothèque."))
        }
        // Reconnexion : l'ancien tunnel est fermé avant d'en ouvrir un nouveau.
        if let spec = tunnelSpec, let controller { _ = await controller.stop(spec.id); tunnelSpec = nil }
        phase = .connecting(String(localized: "Connexion SSH à \(via.name)…"))
        let link: SSHLink
        if let l = self.link { link = l } else {
            link = model.connections.connection(for: via).acquireLink()
            self.link = link
        }
        do { try await link.ensureConnected() } catch { throw VNCSessionError(String(localized: "Tunnel SSH : \(link.message(for: error))")) }
        let controller = self.controller ?? TunnelController(transport: link.transport)
        self.controller = controller
        guard let local = Self.freeLocalPort() else { throw VNCSessionError(String(localized: "Aucun port local libre pour le tunnel.")) }
        let spec = TunnelSpec(kind: .local, bindPort: local, destinationHost: host.host, destinationPort: port, name: "VNC \(host.name)")
        phase = .connecting(String(localized: "Ouverture du tunnel vers \(host.host):\(port)…"))
        let state = await controller.start(spec)
        guard state == .active else {
            if case .failed(let m) = state { throw VNCSessionError(String(localized: "Tunnel SSH : \(m)")) }
            throw VNCSessionError(String(localized: "Tunnel SSH non établi."))
        }
        tunnelSpec = spec
        tunnelPort = local
        return ("127.0.0.1", local)
    }

    /// Port TCP local libre (liaison sur 0 puis relâché : la fenêtre de course est négligeable, `TunnelController` revérifie).
    nonisolated static func freeLocalPort() -> Int? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else { return nil }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let got = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        return got == 0 ? Int(UInt16(bigEndian: addr.sin_port)) : nil
    }

    // MARK: Entrées

    private var canSend: Bool { inputEnabled && isConnected && client != nil }

    func sendKey(_ keysym: UInt32, down: Bool) { if canSend { client?.sendKey(keysym: keysym, down: down) } }

    func sendPointer(x: Int, y: Int, buttons: UInt8) { if canSend { client?.sendPointer(x: x, y: y, buttons: buttons) } }

    /// Ctrl-Alt-Suppr : enfoncées dans l'ordre, relâchées dans l'ordre inverse.
    func sendCtrlAltDelete() {
        guard canSend else { return }
        let keys = [RFBKeysym.controlL, RFBKeysym.altL, RFBKeysym.delete]
        for k in keys { sendKey(k, down: true) }
        for k in keys.reversed() { sendKey(k, down: false) }
    }

    /// Envoie le texte du presse-papiers local au serveur.
    @discardableResult
    func sendClipboard() -> Bool {
        guard canSend, let text = pasteboard.string(forType: .string), !text.isEmpty else { return false }
        client?.sendClipboard(text)
        return true
    }

    func requestFullUpdate() {
        guard isConnected, remoteSize.width > 0 else { return }
        client?.requestFullUpdate(width: Int(remoteSize.width), height: Int(remoteSize.height))
    }

    /// Framebuffer courant (nil hors connexion).
    var framebuffer: RFBFramebuffer? { client?.framebuffer }

    // MARK: Partage d'écran

    /// URL `vnc://` de ce serveur (via le tunnel quand il existe).
    var screenSharingURL: URL? { VNCFeature.screenSharingURL(host: tunnelPort != nil ? "127.0.0.1" : host.host, port: tunnelPort ?? port) }
}

struct VNCSessionError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}
