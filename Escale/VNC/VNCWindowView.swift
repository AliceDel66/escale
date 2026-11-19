import SwiftUI
import EscaleCore

/// Contenu de la fenêtre d'une connexion VNC : barre d'actions, bureau distant, feuille de mot de passe / états.
struct VNCWindowView: View {
    let session: VNCSession

    var body: some View {
        VStack(spacing: 0) {
            VNCToolbar(session: session)
            Divider()
            ZStack {
                VNCDisplayRepresentable(session: session, scaling: session.scaling, smoothing: session.smoothing)
                VNCOverlay(session: session)
            }
        }
        .frame(minWidth: 480, minHeight: 320)
        .environment(\.locale, session.model.settings.effectiveLocale)
    }
}

struct VNCToolbar: View {
    @Bindable var session: VNCSession

    var body: some View {
        HStack(spacing: 10) {
            Button("Ctrl-Alt-Suppr") { session.sendCtrlAltDelete() }
                .disabled(!session.isConnected || !session.inputEnabled)
                .help("Envoie Ctrl + Alt + Suppr au serveur")
            Button("Envoyer le presse-papiers") { session.sendClipboard() }
                .disabled(!session.isConnected || !session.inputEnabled)
                .help("Envoie le texte copié sur ce Mac au bureau distant (le texte copié à distance arrive ici automatiquement)")
            // Étiquettes à la taille du reste de la barre (le libellé d'un Picker de menu reste en taille normale).
            HStack(spacing: 4) {
                Text("Échelle").fixedSize()
                Picker("Échelle", selection: $session.scaling) {
                    ForEach(VNCScaling.allCases, id: \.self) { Text($0.localizedDisplayNameKey).tag($0) }
                }
                .pickerStyle(.menu).labelsHidden().fixedSize()
            }
            Toggle("Lissage", isOn: $session.smoothing)
                .toggleStyle(.checkbox)
                .help("Interpolation linéaire en agrandissement (par défaut : pixels nets à partir de ×2)")
            Toggle("Lecture seule", isOn: Binding(get: { !session.inputEnabled }, set: { session.inputEnabled = !$0 }))
                .toggleStyle(.checkbox)
            Spacer()
            Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Button("Partage d'écran") { openScreenSharing() }
                .help("Ouvrir ce serveur dans l'app Partage d'écran de macOS (comptes macOS, chiffrement)")
            if session.isConnected {
                Button("Déconnecter") { session.disconnect() }
            } else if case .connecting = session.phase {
                Button("Annuler") { session.disconnect() }
            } else if case .needsCredentials = session.phase {
                Button("Annuler") { session.cancelCredentials() }
            } else {
                Button("Reconnecter") { session.reconnect() }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .controlSize(.small)
        .font(.system(size: 11))
    }

    private var status: String {
        if let n = session.notice { return n }
        guard let info = session.serverInfo, session.isConnected else { return "" }
        let s = session.remoteSize
        return Self.statusText(desktopName: info.name, hostName: session.host.name, size: s)
    }

    /// Le titre de la fenêtre porte le nom de l'hôte (bibliothèque) ; le nom annoncé par le serveur est libellé « Bureau »
    /// et omis quand il est identique.
    static func statusText(desktopName: String, hostName: String, size: CGSize) -> String {
        let dims = String(localized: "\(Int(size.width))×\(Int(size.height))")
        let name = desktopName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty || name == hostName ? dims : String(localized: "Bureau : \(name) — \(dims)")
    }

    private func openScreenSharing() {
        if let url = session.screenSharingURL { NSWorkspace.shared.open(url) }
    }
}

private struct VNCOverlay: View {
    let session: VNCSession

    var body: some View {
        switch session.phase {
        case .connected:
            EmptyView()
        case .connecting(let text):
            card {
                ProgressView().controlSize(.small)
                Text(text).foregroundStyle(.secondary)
            }
        case .needsCredentials:
            VNCCredentialsCard(session: session)
        case .ended(let reason):
            card {
                Text(reason ?? String(localized: "Déconnecté.")).multilineTextAlignment(.center)
            }
        case .failed(let message):
            card {
                Label("Connexion impossible", systemImage: "exclamationmark.triangle").font(.headline)
                Text(message).multilineTextAlignment(.center).textSelection(.enabled)
                Text("Si le serveur exige un compte macOS ou un chiffrement, utilisez « Partage d'écran ».")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 10) { content() }
            .padding(18)
            .frame(maxWidth: 420)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .shadow(radius: 8)
    }
}

/// Feuille de saisie du mot de passe (et du nom d'utilisateur pour Apple Remote Desktop).
private struct VNCCredentialsCard: View {
    @Bindable var session: VNCSession
    @State private var password = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(session.promptKind == .appleRemoteDesktop ? "Compte macOS requis" : "Mot de passe VNC").font(.headline)
            Text(session.host.name).foregroundStyle(.secondary)
            if let error = session.promptError {
                Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            if session.promptKind == .appleRemoteDesktop {
                TextField("Nom d'utilisateur", text: $session.username)
            }
            SecureField("Mot de passe", text: $password)
                .focused($focused)
                .onSubmit(submit)
            Toggle("Mémoriser dans le Trousseau", isOn: $session.rememberPassword)
            HStack {
                Spacer()
                Button("Annuler") { session.cancelCredentials() }.keyboardShortcut(.cancelAction)
                Button("Se connecter", action: submit).keyboardShortcut(.defaultAction)
                    .disabled(session.promptKind == .appleRemoteDesktop && session.username.isEmpty)
            }
        }
        .padding(18)
        .frame(width: 340)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .shadow(radius: 8)
        .onAppear { focused = true; password = "" }
    }

    private func submit() {
        let p = password
        password = ""
        session.submitCredentials(username: session.username, password: p)
    }
}
