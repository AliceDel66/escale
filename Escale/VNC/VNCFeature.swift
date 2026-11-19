import AppKit
import SwiftUI
import EscaleCore

/// Module VNC : client RFB natif (`EscaleCore/VNC`), une fenêtre par connexion. Ne s'accroche à l'app que par `attach`
/// (`AppModel.externalOpeners`), `VNCScene`, `VNCHostMenuItems`, `VNCEditorSection` et `--selftest-vnc`.
@MainActor
@Observable
final class VNCFeature: AppFeature {
    @ObservationIgnored private(set) weak var model: AppModel?
    /// Sessions ouvertes, par hôte (une fenêtre par hôte : « Connecter » ramène la fenêtre existante).
    @ObservationIgnored private(set) var sessions: [UUID: VNCSession] = [:]
    @ObservationIgnored private var windows: [UUID: NSWindow] = [:]
    @ObservationIgnored private var delegates: [UUID: VNCWindowDelegate] = [:]
    @ObservationIgnored private var isShutDown = false

    func attach(_ model: AppModel) {
        self.model = model
        model.externalOpeners[.vnc] = { [weak self] host in self?.open(host) }
    }

    func shutdown() async {
        isShutDown = true
        let all = Array(sessions.values)
        for (_, w) in windows { w.delegate = nil; w.orderOut(nil) }
        windows.removeAll(); delegates.removeAll(); sessions.removeAll()
        for s in all { await s.close() }
    }

    // MARK: Ouverture

    /// Ouvre (ou ramène) la fenêtre VNC d'un hôte. `activate: false` : sans prendre le focus (auto-test).
    @discardableResult
    func open(_ host: HostProfile, activate: Bool = true) -> VNCSession? {
        guard let model, !isShutDown else { return nil }
        if let existing = sessions[host.id], let w = windows[host.id] {
            if activate { w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) } else { w.orderFront(nil) }
            return existing
        }
        let session = VNCSession(host: host, model: model)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1024, height: 700),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = host.name
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: VNCWindowView(session: session))
        window.center()
        let delegate = VNCWindowDelegate { [weak self] in self?.windowClosed(host.id) }
        window.delegate = delegate
        sessions[host.id] = session
        windows[host.id] = window
        delegates[host.id] = delegate
        if activate { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) } else { window.orderFront(nil) }
        session.start()
        return session
    }

    func window(for hostID: UUID) -> NSWindow? { windows[hostID] }

    /// Ferme la fenêtre d'un hôte (comme le bouton de fermeture) et attend la fermeture de la connexion.
    func closeWindow(for hostID: UUID) async {
        guard let session = sessions[hostID] else { return }
        let w = windows[hostID]
        sessions[hostID] = nil; windows[hostID] = nil; delegates[hostID] = nil
        w?.delegate = nil
        w?.orderOut(nil)
        await session.close()
    }

    private func windowClosed(_ hostID: UUID) {
        guard let session = sessions.removeValue(forKey: hostID) else { return }
        windows[hostID] = nil
        delegates[hostID] = nil
        Task { await session.close() }
    }

    // MARK: Partage d'écran

    nonisolated static func screenSharingURL(host: String, port: Int) -> URL? {
        var c = URLComponents()
        c.scheme = "vnc"
        c.host = host
        if port != ConnectionProtocol.vnc.defaultPort { c.port = port }
        return c.url
    }

    /// Ouvre le serveur d'un hôte dans l'app Partage d'écran de macOS (repli : comptes macOS, chiffrement Apple).
    func openInScreenSharing(_ host: HostProfile) {
        if let s = sessions[host.id], let url = s.screenSharingURL { NSWorkspace.shared.open(url); return }
        if let url = Self.screenSharingURL(host: host.host, port: host.port ?? ConnectionProtocol.vnc.defaultPort ?? 5900) {
            NSWorkspace.shared.open(url)
        }
    }
}

@MainActor
final class VNCWindowDelegate: NSObject, NSWindowDelegate {
    let onClose: () -> Void
    init(onClose: @escaping () -> Void) { self.onClose = onClose }
    func windowWillClose(_ notification: Notification) { onClose() }
}

/// Feuilles, inspecteurs, bandeaux du module (fenêtre principale) : aucun, chaque connexion a sa propre fenêtre.
struct VNCScene: ViewModifier {
    let model: AppModel
    func body(content: Content) -> some View { content }
}

/// Entrées du menu contextuel d'un hôte de ce protocole (barre latérale).
struct VNCHostMenuItems: View {
    let model: AppModel
    let host: HostProfile
    var body: some View {
        Button("Ouvrir dans Partage d'écran") { model.vnc.openInScreenSharing(host) }
    }
}

/// Section de l'éditeur d'hôte quand le protocole est `.vnc`.
struct VNCEditorSection: View {
    @Binding var settings: VNCSettings
    let model: AppModel

    private var sshHosts: [HostProfile] { model.library.library.hosts.filter { $0.connectionProtocol == .ssh } }

    var body: some View {
        Section("VNC") {
            Picker("Tunnel SSH", selection: $settings.viaSSHHostID) {
                Text("Aucun (connexion directe)").tag(UUID?.none)
                ForEach(sshHosts) { Text($0.name).tag(UUID?.some($0.id)) }
            }
            if settings.viaSSHHostID != nil {
                Text("L'hôte et le port ci-dessus sont ceux du serveur VNC vus depuis l'hôte SSH choisi (souvent 127.0.0.1).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Picker("Encodage", selection: $settings.encoding) {
                ForEach(VNCEncodingPreference.allCases, id: \.self) { Text($0.localizedDisplayNameKey).tag($0) }
            }
            Picker("Échelle", selection: $settings.scaling) {
                ForEach(VNCScaling.allCases, id: \.self) { Text($0.localizedDisplayNameKey).tag($0) }
            }
            Toggle("Lecture seule", isOn: $settings.viewOnly)
            Toggle("Session partagée (ne pas déconnecter les autres clients)", isOn: $settings.shared)
            Text(String(localized: "Le mot de passe est demandé à la connexion ; il peut être mémorisé dans le Trousseau après une connexion réussie. ")
                 + String(localized: "VNC n'est pas chiffré : préférez un tunnel SSH hors réseau de confiance."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
