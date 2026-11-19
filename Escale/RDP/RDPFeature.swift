import SwiftUI
import AppKit
import UniformTypeIdentifiers
import EscaleCore

/// Module Bureau à distance (RDP) par client externe. Ne s'accroche à l'app que par `attach` (`AppModel.externalOpeners`),
/// `RDPScene`, `RDPHostMenuItems`, `RDPEditorSection` et `--selftest-rdp`.
///
/// Escale ne parle pas RDP : il génère un fichier `.rdp` (dossier privé 0700 du cache) et l'ouvre avec le client de Microsoft
/// (« Windows App »). Aucun mot de passe n'est écrit : le client le demande (invariant 7).
/// Option « via un hôte SSH » : un tunnel `-L 127.0.0.1:<port libre>` est ouvert sur le maître de cet hôte (action de
/// l'utilisateur : il ouvre l'hôte RDP) et le `.rdp` vise ce port. Le tunnel (et le lien maître retenu) reste ouvert tant que
/// l'hôte est marqué ouvert : menu « Fermer le tunnel », ou fin de l'app.
@MainActor
@Observable
final class RDPFeature: AppFeature {
    static let sheetID = "rdp"

    /// Message affiché dans une alerte du module.
    struct Notice: Identifiable, Equatable {
        enum Kind: Equatable { case clientMissing, info, error }
        let id = UUID()
        var kind: Kind
        var title: String
        var message: String
    }

    /// Résultat d'une ouverture réussie.
    struct Opened: Equatable {
        var file: URL
        var content: String
        var tunnelPort: Int?
    }

    private struct OpenTunnel {
        let spec: TunnelSpec
        let controller: TunnelController
        let link: SSHLink
        var port: Int { spec.bindPort }
    }

    @ObservationIgnored private(set) weak var model: AppModel?
    /// Alerte en cours (nil : aucune).
    var notice: Notice? {
        didSet {
            guard let model else { return }
            if notice != nil { if model.activeFeatureSheet == nil { model.activeFeatureSheet = Self.sheetID } }
            else if model.activeFeatureSheet == Self.sheetID { model.activeFeatureSheet = nil }
        }
    }
    /// Port local du tunnel ouvert de chaque hôte RDP « via SSH » (observé par le menu d'hôte).
    private(set) var tunnelPorts: [UUID: Int] = [:]

    /// Recherche du client (injectable : la recette n'a pas de client réel).
    @ObservationIgnored var locator = RDPClientLocator()
    /// Ouvre le `.rdp` avec le client (injectable : la recette enregistre l'URL au lieu de lancer).
    @ObservationIgnored var launcher: @MainActor (_ file: URL, _ app: URL) async throws -> Void = { file, app in
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        _ = try await NSWorkspace.shared.open([file], withApplicationAt: app, configuration: cfg)
    }
    /// Dossier parent des dossiers privés (recette : sous son dossier de résultats).
    @ObservationIgnored var workParent: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Escale/RDP", isDirectory: true)

    @ObservationIgnored private var tunnels: [UUID: OpenTunnel] = [:]
    @ObservationIgnored private var opening: Set<UUID> = []
    @ObservationIgnored private(set) var workDirectory: URL?

    func attach(_ model: AppModel) {
        self.model = model
        model.externalOpeners[.rdp] = { [weak self] host in
            Task { @MainActor in await self?.openFromUI(host) }
        }
        purgeStaleDirectories()
    }

    func shutdown() async {
        for id in Array(tunnels.keys) { await closeTunnel(hostID: id) }
        removeWorkDirectory()
    }

    // MARK: Ouverture

    /// Ouverture demandée par l'utilisateur : toute erreur devient une alerte.
    func openFromUI(_ host: HostProfile) async {
        do { _ = try await open(host) } catch RDPFeatureError.clientMissing {
            notice = Notice(kind: .clientMissing, title: String(localized: "Client Bureau à distance introuvable"),
                            message: String(localized: "Escale lance le client Bureau à distance de Microsoft (« Windows App »), qui n'est pas installé. Vous pouvez l'installer depuis l'App Store."))
        } catch is CancellationError {
        } catch {
            notice = Notice(kind: .error, title: String(localized: "Impossible d'ouvrir « \(host.name) »"), message: "\(error)")
        }
    }

    /// Génère le `.rdp` (derrière un tunnel SSH si demandé) et l'ouvre avec le client détecté.
    @discardableResult
    func open(_ host: HostProfile) async throws -> Opened {
        let settings = host.rdp ?? RDPSettings()
        if let first = RDPSettings.validationErrors(settings).first { throw RDPFeatureError.invalid(first) }
        guard opening.insert(host.id).inserted else { throw RDPFeatureError.alreadyOpening }
        defer { opening.remove(host.id) }
        guard let app = locator.locate() else { throw RDPFeatureError.clientMissing }

        let port = host.port ?? ConnectionProtocol.rdp.defaultPort ?? 3389
        var address: (host: String, port: Int)?
        var newTunnel = false
        if let via = settings.viaSSHHostID {
            let before = tunnels[host.id]?.port
            let t = try await ensureTunnel(for: host, via: via, port: port)
            newTunnel = before != t.port
            address = ("127.0.0.1", t.port)
        }
        do {
            let content = try RDPFile.generate(host: host, settings: settings, address: address)
            let file = try RDPFile.write(content, named: RDPFile.fileName(for: host), in: try ensureWorkDirectory())
            try await launcher(file, app)
            return Opened(file: file, content: content, tunnelPort: address?.port)
        } catch {
            // Le tunnel n'a servi à rien si le client n'a pas été lancé : on ne le laisse pas ouvert.
            if newTunnel { await closeTunnel(hostID: host.id) }
            throw error
        }
    }

    // MARK: Tunnel

    /// Tunnel actif de l'hôte, réutilisé s'il répond encore, sinon (ré)ouvert.
    private func ensureTunnel(for host: HostProfile, via: UUID, port: Int) async throws -> OpenTunnel {
        if let t = tunnels[host.id] {
            let alive = await t.controller.state(of: t.spec.id) == .active
                && !TunnelPortCheck.isFree(address: "127.0.0.1", port: t.port)
            if alive { return t }
            await closeTunnel(hostID: host.id)
        }
        guard let model, let ssh = model.library.host(via), ssh.connectionProtocol == .ssh else { throw RDPFeatureError.viaHostMissing }
        // Lien maître retenu pour la durée de vie du tunnel (rendu par `closeTunnel`).
        let link = model.connections.connection(for: ssh).acquireLink()
        do {
            try await link.ensureConnected()
            guard let local = RDPTunnel.freeLocalPort() else { throw RDPFeatureError.noLocalPort }
            let spec = RDPTunnel.spec(localPort: local, host: host.host, port: port)
            let controller = TunnelController(transport: link.transport)
            // `start` vérifie l'ouverture par sonde du port (invariant 4), pas par le code de `ssh -O forward`.
            let state = await controller.start(spec)
            guard state == .active else {
                if case .failed(let m) = state { throw RDPFeatureError.tunnel(m) }
                throw RDPFeatureError.tunnel(String(localized: "ouverture impossible"))
            }
            let t = OpenTunnel(spec: spec, controller: controller, link: link)
            tunnels[host.id] = t
            tunnelPorts[host.id] = local
            return t
        } catch {
            link.release()
            if error is RDPFeatureError || error is CancellationError { throw error }
            throw RDPFeatureError.viaSSH(link.message(for: error))
        }
    }

    /// Ferme le tunnel de l'hôte et rend le lien maître.
    func closeTunnel(hostID: UUID) async {
        guard let t = tunnels.removeValue(forKey: hostID) else { return }
        tunnelPorts[hostID] = nil
        _ = await t.controller.stop(t.spec.id)
        t.link.release()
    }

    // MARK: Fichiers

    private func ensureWorkDirectory() throws -> URL {
        if let d = workDirectory, FileManager.default.fileExists(atPath: d.path) { return d }
        let d = try RDPFile.makePrivateDirectory(under: workParent)
        workDirectory = d
        return d
    }

    private func removeWorkDirectory() {
        if let d = workDirectory { try? FileManager.default.removeItem(at: d) }
        workDirectory = nil
    }

    /// Dossiers privés d'une session précédente interrompue (plus d'un jour) : jamais ceux d'une autre instance en cours.
    private func purgeStaleDirectories() {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: workParent, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for u in items where u.lastPathComponent.hasPrefix("rdp-") {
            let date = (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let date, date < Date().addingTimeInterval(-86_400) { try? fm.removeItem(at: u) }
        }
    }

    /// Écrit le `.rdp` de l'hôte (adresse directe : le port d'un tunnel est éphémère) à l'emplacement choisi.
    @discardableResult
    func export(_ host: HostProfile, to url: URL) throws -> String {
        let content = try RDPFile.generate(host: host)
        try Data(content.utf8).write(to: url, options: .atomic)
        return content
    }

    func exportWithPanel(_ host: HostProfile) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = RDPFile.fileName(for: host)
        if let t = UTType(filenameExtension: "rdp") { panel.allowedContentTypes = [t] }
        panel.message = String(localized: "Fichier .rdp sans mot de passe, vers l'adresse enregistrée de l'hôte.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try export(host, to: url) } catch {
            notice = Notice(kind: .error, title: String(localized: "Export impossible"), message: "\(error)")
        }
    }

    /// Ajoute à la bibliothèque l'hôte décrit par un `.rdp` (aucun mot de passe repris).
    @discardableResult
    func importFile(_ url: URL) throws -> RDPImport {
        guard let model else { throw RDPFeatureError.unavailable }
        let r = try RDPFile.load(from: url)
        model.library.upsert(r.host)
        return r
    }

    /// Dépôt d'un `.rdp` sur la fenêtre principale.
    func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let wanted = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !wanted.isEmpty else { return false }
        for p in wanted {
            p.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                guard let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil),
                      url.pathExtension.lowercased() == "rdp" else { return }
                Task { @MainActor in
                    do {
                        let r = try self.importFile(url)
                        self.notice = Notice(kind: .info, title: String(localized: "Hôte « \(r.host.name) » importé"),
                                             message: r.warnings.isEmpty ? String(localized: "Ajouté à la bibliothèque.") : r.warnings.joined(separator: "\n"))
                    } catch {
                        self.notice = Notice(kind: .error, title: String(localized: "Import du fichier .rdp impossible"), message: "\(error)")
                    }
                }
            }
        }
        return true
    }
}

enum RDPFeatureError: Error, CustomStringConvertible {
    case unavailable
    case clientMissing
    case invalid(String)
    case alreadyOpening
    case viaHostMissing
    case noLocalPort
    case tunnel(String)
    case viaSSH(String)

    var description: String {
        switch self {
        case .unavailable: String(localized: "Bureau à distance : module indisponible.")
        case .clientMissing: String(localized: "Le client Bureau à distance de Microsoft (« Windows App ») n'est pas installé.")
        case .invalid(let m): m
        case .alreadyOpening: String(localized: "Ouverture déjà en cours pour cet hôte.")
        case .viaHostMissing: String(localized: "L'hôte SSH intermédiaire n'existe plus : choisissez-en un autre dans l'éditeur.")
        case .noLocalPort: String(localized: "Aucun port local libre pour le tunnel.")
        case .tunnel(let m): String(localized: "Tunnel vers l'hôte RDP impossible : \(m)")
        case .viaSSH(let m): String(localized: "Connexion à l'hôte SSH intermédiaire impossible : \(m)")
        }
    }
}

/// Alerte du module (client absent : bouton vers l'App Store) et dépôt d'un `.rdp` pour l'importer.
struct RDPScene: ViewModifier {
    let model: AppModel
    func body(content: Content) -> some View {
        let feature = model.rdp
        content
            .onDrop(of: [.fileURL], isTargeted: nil) { feature.handleDrop($0) }
            .alert(feature.notice?.title ?? "", isPresented: Binding(
                get: { feature.notice != nil }, set: { if !$0 { feature.notice = nil } }), presenting: feature.notice) { n in
                if n.kind == .clientMissing {
                    Button("Ouvrir l'App Store") { NSWorkspace.shared.open(RDPClientLocator.appStoreURL) }
                    Button("Annuler", role: .cancel) {}
                } else {
                    Button("OK", role: .cancel) {}
                }
            } message: { n in
                Text(n.message)
            }
    }
}

/// Entrées du menu contextuel d'un hôte RDP (barre latérale).
struct RDPHostMenuItems: View {
    let model: AppModel
    let host: HostProfile
    var body: some View {
        Button("Exporter le fichier .rdp…") { model.rdp.exportWithPanel(host) }
        if let port = model.rdp.tunnelPorts[host.id] {
            Button("Fermer le tunnel (127.0.0.1:\(String(port)))") { Task { await model.rdp.closeTunnel(hostID: host.id) } }
        }
    }
}

/// Section de l'éditeur d'hôte quand le protocole est `.rdp`.
struct RDPEditorSection: View {
    @Binding var settings: RDPSettings
    let model: AppModel

    private var sshHosts: [HostProfile] {
        model.library.library.hosts.filter { $0.connectionProtocol == .ssh }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        Section("Bureau à distance") {
            Text("Escale ouvre cet hôte avec le client Bureau à distance de Microsoft (« Windows App »). L'identifiant et le mot de passe sont demandés par ce client ; Escale ne les enregistre pas.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Affichage", selection: $settings.displayMode) {
                ForEach(RDPSettings.DisplayMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            if settings.displayMode == .fixedSize {
                Stepper(value: $settings.width, in: RDPSettings.minDimension...RDPSettings.maxDimension, step: 40) {
                    Text("Largeur : \(settings.width) px")
                }
                Stepper(value: $settings.height, in: RDPSettings.minDimension...RDPSettings.maxDimension, step: 40) {
                    Text("Hauteur : \(settings.height) px")
                }
            }
            Toggle("Utiliser tous les écrans", isOn: $settings.multiMonitor)
            Toggle("Partager le presse-papiers", isOn: $settings.redirectClipboard)
            Picker("Son", selection: $settings.audio) {
                ForEach(RDPSettings.AudioMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            Toggle("Laisser le client demander les identifiants", isOn: $settings.promptForCredentials)
            TextField("Passerelle Bureau à distance", text: $settings.gatewayHostname, prompt: Text("Aucune"))
            folders
            Picker("Ouvrir via un hôte SSH", selection: $settings.viaSSHHostID) {
                Text("Non (connexion directe)").tag(UUID?.none)
                ForEach(sshHosts) { Text($0.name).tag(UUID?.some($0.id)) }
            }
            if settings.viaSSHHostID != nil {
                Text("Un tunnel local est ouvert sur la connexion SSH de cet hôte tant que l'hôte reste ouvert (menu « Fermer le tunnel »). Le client peut signaler un nom de certificat différent : l'adresse visée est 127.0.0.1.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var folders: some View {
        ForEach(settings.sharedFolders.indices, id: \.self) { i in
            HStack {
                Image(systemName: "folder")
                Text(settings.sharedFolders[i]).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button { settings.sharedFolders.remove(at: i) } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
            }
        }
        Button("Partager un dossier…") {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
            if panel.runModal() == .OK, let p = panel.url?.path, !settings.sharedFolders.contains(p) { settings.sharedFolders.append(p) }
        }
    }
}
