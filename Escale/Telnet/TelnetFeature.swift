import SwiftUI
import EscaleCore

/// Module Telnet. Ne s'accroche à l'app que par `attach` (`AppModel.terminalLaunchers`),
/// `TelnetScene`, `TelnetHostMenuItems`, `TelnetEditorSection` et `--selftest-telnet`.
///
/// Telnet n'est pas chiffré : le login est interactif dans le terminal, rien (identifiant, mot de passe) n'est stocké.
/// Option « via un hôte SSH » : un tunnel `-L` local est ouvert sur le maître de cet hôte (action de l'utilisateur : il
/// ouvre l'hôte Telnet), puis la connexion Telnet se fait sur ce port local ; le tunnel et le lien sont rendus à la fin.
@MainActor
@Observable
final class TelnetFeature: AppFeature {
    @ObservationIgnored private(set) weak var model: AppModel?
    /// Ports locaux des tunnels « via SSH » actuellement ouverts (recette : on sonde qu'ils sont fermés à la fin).
    @ObservationIgnored private(set) var activeTunnelPorts: Set<Int> = []

    func attach(_ model: AppModel) {
        self.model = model
        model.terminalLaunchers[.telnet] = { [weak self] pane, host in
            guard let self else { throw TelnetFeatureError.unavailable }
            return try await self.open(pane: pane, host: host)
        }
    }

    func shutdown() async {}

    /// Ouvre la source d'octets du panneau (directe, ou à travers le maître d'un hôte SSH).
    func open(pane: Pane, host: HostProfile) async throws -> any TerminalByteStream {
        let settings = host.telnet ?? TelnetSettings()
        if let first = TelnetSettings.validationErrors(settings).first { throw TelnetFeatureError.invalid(first) }
        let size = pane.session.engine.size
        let port = host.port ?? ConnectionProtocol.telnet.defaultPort ?? 23
        guard let via = settings.viaSSHHostID else {
            return try await TelnetConnection.open(host: host.host, port: port, settings: settings,
                                                   columns: size.columns, rows: size.rows)
        }
        guard let model, let ssh = model.library.host(via), ssh.connectionProtocol == .ssh else { throw TelnetFeatureError.viaHostMissing }

        // Lien maître retenu pour la durée de la session Telnet (rendu par `TunnelledStream`).
        let link = model.connections.connection(for: ssh).acquireLink()
        do {
            try await link.ensureConnected()
            guard let local = TelnetTunnel.freeLocalPort() else { throw TelnetFeatureError.noLocalPort }
            let spec = TelnetTunnel.spec(localPort: local, host: host.host, port: port)
            let controller = TunnelController(transport: link.transport)
            // `ensureConnected`/`start` vérifient l'ouverture par sonde du port (invariant 4), pas par le code de `ssh -O forward`.
            let state = await controller.start(spec)
            guard state == .active else {
                if case .failed(let m) = state { throw TelnetFeatureError.tunnel(m) }
                throw TelnetFeatureError.tunnel(String(localized: "ouverture impossible"))
            }
            activeTunnelPorts.insert(local)
            do {
                let inner = try await TelnetConnection.open(host: "127.0.0.1", port: local, settings: settings,
                                                            columns: size.columns, rows: size.rows)
                return TunnelledStream(inner: inner, cleanup: { [controller, spec] in
                    await controller.stop(spec.id)
                    await MainActor.run { self.activeTunnelPorts.remove(local); link.release() }
                })
            } catch {
                await controller.stop(spec.id)
                activeTunnelPorts.remove(local)
                throw error
            }
        } catch {
            link.release()
            if error is TelnetError || error is TelnetFeatureError || error is CancellationError { throw error }
            throw TelnetFeatureError.viaSSH(link.message(for: error))
        }
    }
}

enum TelnetFeatureError: Error, CustomStringConvertible {
    case unavailable
    case invalid(String)
    case viaHostMissing
    case noLocalPort
    case tunnel(String)
    case viaSSH(String)

    var description: String {
        switch self {
        case .unavailable: String(localized: "Telnet : module indisponible.")
        case .invalid(let m): m
        case .viaHostMissing: String(localized: "L'hôte SSH intermédiaire n'existe plus : choisissez-en un autre dans l'éditeur.")
        case .noLocalPort: String(localized: "Aucun port local libre pour le tunnel.")
        case .tunnel(let m): String(localized: "Tunnel vers l'hôte Telnet impossible : \(m)")
        case .viaSSH(let m): String(localized: "Connexion à l'hôte SSH intermédiaire impossible : \(m)")
        }
    }
}

/// Flux Telnet porté par un tunnel : à la fin de la session (ou à `kill`), le tunnel est annulé et le lien rendu une fois.
final class TunnelledStream: TerminalByteStream, @unchecked Sendable {
    private let inner: TelnetConnection
    private let cleanupTask: Task<PTYExitStatus, Never>

    init(inner: TelnetConnection, cleanup: @escaping @Sendable () async -> Void) {
        self.inner = inner
        cleanupTask = Task {
            let status = await inner.waitForExit()
            await cleanup()
            return status
        }
    }

    var output: AsyncStream<Data> { inner.output }
    func write(_ data: Data) { inner.write(data) }
    func resize(columns: Int, rows: Int) { inner.resize(columns: columns, rows: rows) }
    func kill() { inner.kill() }
    func waitForExit() async -> PTYExitStatus { await cleanupTask.value }
}

/// Feuilles, inspecteurs, bandeaux du module (fenêtre principale) : aucun.
struct TelnetScene: ViewModifier {
    let model: AppModel
    func body(content: Content) -> some View { content }
}

/// Entrées du menu contextuel d'un hôte Telnet (barre latérale) : aucune propre au protocole.
struct TelnetHostMenuItems: View {
    let model: AppModel
    let host: HostProfile
    var body: some View { EmptyView() }
}

/// Section de l'éditeur d'hôte quand le protocole est `.telnet`.
struct TelnetEditorSection: View {
    @Binding var settings: TelnetSettings
    let model: AppModel

    private var sshHosts: [HostProfile] {
        model.library.library.hosts.filter { $0.connectionProtocol == .ssh }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        Section("Telnet") {
            Label("Telnet n'est pas chiffré : le mot de passe circule en clair.", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.callout)
            Text("L'identifiant et le mot de passe se saisissent dans le terminal à l'invite du serveur ; Escale ne les enregistre pas.")
                .font(.caption).foregroundStyle(.secondary)
            TextField("Type de terminal", text: $settings.terminalType, prompt: Text(TelnetSettings.defaultTerminalType))
            Picker("Touche Entrée", selection: $settings.lineEnding) {
                ForEach(TelnetSettings.LineEnding.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            Stepper(value: $settings.connectTimeout, in: 1...120) {
                Text("Délai de connexion : \(settings.connectTimeout) s")
            }
            Picker("Ouvrir via un hôte SSH", selection: $settings.viaSSHHostID) {
                Text("Non (connexion directe)").tag(UUID?.none)
                ForEach(sshHosts) { Text($0.name).tag(UUID?.some($0.id)) }
            }
            if settings.viaSSHHostID != nil {
                Text("Un tunnel local est ouvert sur la connexion SSH de cet hôte ; le trajet jusqu'à lui est alors chiffré.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
