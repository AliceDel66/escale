import SwiftUI
import EscaleCore

/// Barre d'état sous les terminaux : session du panneau actif, dossier courant, tunnels, X11, diffusion.
/// Ne lit que de l'état déjà connu de l'app : aucune session n'est ouverte pour la remplir (invariant 12).
struct StatusBarView: View {
    static let height: CGFloat = 22
    /// Hauteur en mode compact (texte réduit, sans dossier courant ni compteurs).
    static let compactHeight: CGFloat = 18
    private var compact: Bool { model.compact.isOn }
    let model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            if let tab = model.workspace.activeTab, !model.workspace.showsHome {
                paneItems(tab.activePane)
            } else {
                Text("Prêt").foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if !compact { globalItems }
        }
        .font(.system(size: compact ? 10 : 11))
        .lineLimit(1)
        .padding(.horizontal, 10)
        .frame(height: compact ? Self.compactHeight : Self.height)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Barre d'état")
    }

    @ViewBuilder
    private func paneItems(_ pane: Pane) -> some View {
        switch pane.kind {
        case .local:
            Label("Terminal local", systemImage: "terminal").labelStyle(.titleAndIcon)
        case .host(let h):
            Label {
                Text(h.connectionProtocol == .serial ? h.name : "\(h.connectionProtocol.localizedDisplayName) · \(h.target)\(h.port.map { ":\($0)" } ?? "")")
            } icon: {
                Image(systemName: h.connectionProtocol.symbolName).foregroundStyle(h.connectionProtocol.tint)
            }
            .labelStyle(.titleAndIcon)
            .help(h.name)
        }
        StatusText(status: pane.status)
        if !compact, let dir = pane.session.workingDirectory {
            Divider().frame(height: 12)
            Label(dir.path, systemImage: "folder").labelStyle(.titleAndIcon)
                .foregroundStyle(.secondary).truncationMode(.head)
                .help("Dossier courant annoncé par le shell")
        }
        if case .host(let h) = pane.kind, h.connectionProtocol == .ssh {
            let active = h.tunnels.filter { model.tunnels.state(of: $0.id).isActive }.count
            if active > 0 {
                Divider().frame(height: 12)
                Button { model.tunnels.show(host: h.id) } label: {
                    Label(active == 1 ? "1 tunnel" : "\(active) tunnels", systemImage: "arrow.left.arrow.right").labelStyle(.titleAndIcon)
                }
                .buttonStyle(.plain).help("Tunnels actifs sur cet hôte")
            }
            if h.x11Forwarding {
                Divider().frame(height: 12)
                Text("X11").foregroundStyle(.secondary).help("Redirection X11 demandée pour cet hôte")
            }
        }
    }

    @ViewBuilder
    private var globalItems: some View {
        if model.multiExec.isBroadcasting {
            Label("Diffusion : \(model.multiExec.broadcastPaneIDs.count) panneaux", systemImage: "dot.radiowaves.left.and.right")
                .labelStyle(.titleAndIcon).foregroundStyle(.red)
        }
        if model.macros.isRecording {
            Label("Enregistrement", systemImage: "record.circle").labelStyle(.titleAndIcon).foregroundStyle(.red)
        }
        let tabs = model.workspace.tabs
        if !tabs.isEmpty {
            let panes = tabs.reduce(0) { $0 + $1.panes.count }
            Text(tabs.count == 1 ? "1 onglet" : "\(tabs.count) onglets").foregroundStyle(.secondary)
            if panes != tabs.count { Text("\(panes) panneaux").foregroundStyle(.secondary) }
        }
    }
}

private struct StatusText: View {
    let status: Pane.Status

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var color: Color {
        switch status {
        case .running: .green
        case .connecting, .reconnecting: .orange
        case .failed: .red
        case .ended: .gray
        }
    }

    private var label: LocalizedStringKey {
        switch status {
        case .running: "actif"
        case .connecting: "connexion…"
        case .reconnecting: "reconnexion…"
        case .failed: "échec"
        case .ended: "terminé"
        }
    }
}
