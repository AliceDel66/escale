import AppKit
import SwiftUI
import EscaleCore

// MARK: - Confirmation (panneau flottant, sans activer l'app)

/// Panneau flottant des confirmations : visible au-dessus des autres apps (l'utilisateur est souvent dans son
/// terminal ou son éditeur quand l'agent agit), sans prendre le focus, indépendant des feuilles de la fenêtre.
@MainActor
final class MCPConfirmationPanel {
    private unowned let feature: MCPFeature
    private var panel: NSPanel?

    init(feature: MCPFeature) { self.feature = feature }

    func update() {
        guard !feature.pending.isEmpty else {
            panel?.orderOut(nil)
            return
        }
        let p = panel ?? makePanel()
        panel = p
        p.orderFrontRegardless()
        NSApp.requestUserAttention(.informationalRequest)
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 260),
                        styleMask: [.titled, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
        p.title = String(localized: "Action d'un agent")
        p.level = .floating
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = NSHostingView(rootView: MCPConfirmationView(feature: feature))
        if let screen = NSScreen.main?.visibleFrame {
            p.setFrameOrigin(NSPoint(x: screen.maxX - 480, y: screen.maxY - 300))
        }
        return p
    }
}

struct MCPConfirmationView: View {
    let feature: MCPFeature

    var body: some View {
        if let c = feature.pending.first {
            VStack(alignment: .leading, spacing: 10) {
                Label {
                    Text("\(c.client) demande : \(Self.title(c.tool))")
                        .font(.headline)
                } icon: { Image(systemName: "sparkles") }
                Text("Hôte : \(c.hostName)").foregroundStyle(.secondary)
                ScrollView {
                    Text(c.detail.isEmpty ? " " : c.detail)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(minHeight: 60, maxHeight: 140)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                HStack {
                    if feature.pending.count > 1 {
                        Text("\(feature.pending.count - 1) autre(s) demande(s) en attente").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Refuser") { feature.respond(c.id, approved: false) }
                        .keyboardShortcut(.cancelAction)
                    Button("Autoriser") { feature.respond(c.id, approved: true) }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
            .frame(width: 460)
        }
    }

    static func title(_ t: MCPCatalog.Tool) -> String {
        switch t {
        case .exec: String(localized: "exécuter une commande")
        case .connectHost: String(localized: "ouvrir la connexion SSH")
        case .sendInput: String(localized: "saisir dans un terminal")
        case .writeFile: String(localized: "écrire un fichier")
        case .startTunnel: String(localized: "ouvrir un tunnel")
        case .stopTunnel: String(localized: "fermer un tunnel")
        case .readFile: String(localized: "lire un fichier")
        case .listFiles: String(localized: "lister un dossier")
        case .readTerminal: String(localized: "lire un terminal")
        case .listTunnels: String(localized: "lister les tunnels")
        case .listHosts: String(localized: "lister les hôtes")
        case .listSessions: String(localized: "lister les sessions")
        }
    }
}

// MARK: - Réglages et journal

struct MCPSettingsView: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    private var feature: MCPFeature { model.mcp }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Accès des agents IA (MCP)").font(.title2.bold())
                Text("Exposez vos hôtes SSH à Antigravity (agy), Claude Code, Claude Desktop ou Codex par le protocole MCP sur un socket local réservé à votre compte.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 8) {
                Toggle("Autoriser l'accès des agents", isOn: Binding(get: { feature.isEnabled }, set: { feature.setEnabled($0) }))
                    .toggleStyle(.switch)

                VStack(alignment: .leading, spacing: 2) {
                    Toggle("Ouvrir automatiquement la connexion SSH à la demande de l'agent",
                           isOn: Binding(get: { feature.allowAutoConnect }, set: { feature.setAutoConnect($0) }))
                        .toggleStyle(.switch)
                    Text("Autorise un agent à connecter un hôte SSH exposé même sans onglet ouvert (avec confirmation sur les hôtes réglés en confirmation).")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 12) {
                    status
                    Spacer()
                    if feature.activeAgentLinkCount > 0 {
                        Button("Déconnecter les liaisons IA (\(feature.activeAgentLinkCount))") {
                            feature.disconnectAgentLinks()
                        }
                        .controlSize(.small)
                    }
                }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    aiClientsBox
                    hostsAccessBox
                    journalBox
                }
                .padding(.trailing, 2)
            }

            HStack {
                Button("Actualiser") { feature.refreshClientStatuses() }
                Spacer()
                Button("Fermer") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 680, height: 740)
        .onAppear { feature.refreshClientStatuses() }
    }

    private var aiClientsBox: some View {
        GroupBox("Outils IA compatibles") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(AIClientKind.allCases) { client in
                    aiClientRow(client)
                    if client != AIClientKind.allCases.last { Divider() }
                }

                Divider()
                HStack(spacing: 8) {
                    Text("Copie manuelle :")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("JSON générique") {
                        feature.copyToPasteboard(feature.jsonConfiguration, label: "JSON")
                    }
                    .controlSize(.small)
                    Button("TOML Codex") {
                        feature.copyToPasteboard(feature.codexTOMLConfiguration, label: "Codex TOML")
                    }
                    .controlSize(.small)
                    Spacer()
                }

                if let msg = feature.clientActionMessage {
                    Label(msg, systemImage: feature.clientActionIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(feature.clientActionIsError ? .orange : .green)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(6)
        }
    }

    @ViewBuilder
    private func aiClientRow(_ client: AIClientKind) -> some View {
        let st = feature.status(for: client)
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(client.displayName).font(.body.weight(.medium))
                Text(client.displayConfigPath)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            statusBadge(st)
            HStack(spacing: 6) {
                switch st {
                case .configured:
                    Button("Retirer") { feature.uninstallClient(client) }
                        .controlSize(.small)
                case .needsUpdate:
                    Button("Mettre à jour") { feature.installClient(client) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                case .notConfigured, .notInstalled:
                    Button("Configurer") { feature.installClient(client) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                case .parseError:
                    Button("Configurer") {}
                        .controlSize(.small)
                        .disabled(true)
                }
                Button("Copier") { feature.copySnippet(for: client) }
                    .controlSize(.small)
                    .help(String(localized: "Copier la commande ou la configuration pour \(client.displayName)"))
            }
        }
    }

    @ViewBuilder
    private func statusBadge(_ st: AIClientStatus) -> some View {
        switch st {
        case .configured:
            Label("Configuré", systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.green)
        case .needsUpdate(let oldPath):
            Label("Chemin différent", systemImage: "exclamationmark.circle.fill")
                .font(.caption).foregroundStyle(.orange)
                .help(oldPath)
        case .notConfigured:
            Text("Non configuré")
                .font(.caption).foregroundStyle(.secondary)
        case .notInstalled:
            Text("Non détecté")
                .font(.caption).foregroundStyle(.tertiary)
        case .parseError(let detail):
            Label("Erreur de lecture", systemImage: "xmark.octagon.fill")
                .font(.caption).foregroundStyle(.red)
                .help(detail)
        }
    }

    private var hostsAccessBox: some View {
        let allHosts = feature.sshHosts
        let exposedCount = allHosts.filter { $0.agentAccess.allowsVisibility }.count
        return GroupBox {
            if allHosts.isEmpty {
                Text("Aucun hôte SSH enregistré dans la bibliothèque.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(allHosts) { host in
                        hostAccessRow(host)
                        if host.id != allHosts.last?.id { Divider() }
                    }
                }
                .padding(6)
            }
        } label: {
            HStack {
                Text("Hôtes SSH et autorisations")
                Spacer()
                Text("\(exposedCount)/\(allHosts.count) exposés")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func hostAccessRow(_ host: HostProfile) -> some View {
        let connState = model.connections.state(of: host.id)
        return HStack(spacing: 10) {
            Circle()
                .fill(Self.connectionDotColor(connState))
                .frame(width: 8, height: 8)
                .help(Self.connectionStateLabel(connState))
            VStack(alignment: .leading, spacing: 1) {
                Text(host.name).lineLimit(1)
                Text(host.port.map { "\(host.target):\($0)" } ?? host.target)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Picker("", selection: Binding(
                get: { host.agentAccess },
                set: { feature.setHostAccess($0, for: host) }
            )) {
                ForEach(AgentAccess.allCases, id: \.self) { access in
                    Text(AgentAccessEditorSection.label(access)).tag(access)
                }
            }
            .labelsHidden()
            .frame(width: 210)
        }
    }

    private var journalBox: some View {
        GroupBox {
            journal
        } label: {
            HStack {
                Text("Journal")
                Spacer()
                Button("Effacer") { feature.clearJournal() }.disabled(feature.journal.isEmpty)
            }
        }
    }

    @ViewBuilder private var status: some View {
        if let e = feature.serverError {
            Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        } else if feature.isRunning {
            Label(feature.clientCount == 0 ? String(localized: "En écoute, aucun agent connecté")
                  : String(localized: "\(feature.clientCount) agent(s) connecté(s)"), systemImage: "dot.radiowaves.left.and.right")
                .foregroundStyle(.green)
        } else {
            Label("Désactivé", systemImage: "pause.circle").foregroundStyle(.secondary)
        }
    }

    private var journal: some View {
        Group {
            if feature.journal.isEmpty {
                Text("Aucune activité enregistrée pour cette session.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80, alignment: .center)
            } else {
                List(feature.journal.reversed()) { e in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(e.date, style: .time).monospacedDigit()
                            Text(e.tool).font(.system(.body, design: .monospaced))
                            if let h = e.hostName { Text(h).foregroundStyle(.secondary) }
                            Spacer()
                            Text(Self.outcome(e.outcome)).foregroundStyle(Self.color(e.outcome))
                        }
                        if !e.summary.isEmpty {
                            Text(e.summary).font(.system(.caption, design: .monospaced)).lineLimit(2).foregroundStyle(.secondary)
                        }
                        Text(e.client).font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                .frame(minHeight: 140, maxHeight: 200)
            }
        }
    }

    private static func connectionDotColor(_ state: SSHLink.State) -> Color {
        switch state {
        case .connected: .green
        case .connecting, .reconnecting: .orange
        case .disconnected, .cancelled: .secondary.opacity(0.45)
        case .authRequired, .failed, .hostKeyChanged: .red
        }
    }

    private static func connectionStateLabel(_ state: SSHLink.State) -> String {
        switch state {
        case .connected: String(localized: "Connecté")
        case .connecting: String(localized: "Connexion en cours")
        case .reconnecting: String(localized: "Reconnexion en cours")
        case .disconnected, .cancelled: String(localized: "Déconnecté")
        case .authRequired: String(localized: "Authentification requise")
        case .failed, .hostKeyChanged: String(localized: "Erreur de connexion")
        }
    }

    static func outcome(_ o: MCPFeature.JournalEntry.Outcome) -> String {
        switch o {
        case .allowed: String(localized: "autorisé")
        case .approved: String(localized: "confirmé")
        case .refusedByUser: String(localized: "refusé")
        case .denied: String(localized: "interdit")
        case .failed(let m): String(localized: "échec : \(m)")
        }
    }

    static func color(_ o: MCPFeature.JournalEntry.Outcome) -> Color {
        switch o {
        case .allowed, .approved: .green
        case .refusedByUser, .denied: .orange
        case .failed: .red
        }
    }
}

// MARK: - Fiche d'hôte

/// Niveau d'accès des agents (onglet Avancé de la fiche d'un hôte SSH).
struct AgentAccessEditorSection: View {
    @Binding var access: AgentAccess

    var body: some View {
        Section {
            Picker("Accès des agents (MCP)", selection: $access) {
                ForEach(AgentAccess.allCases, id: \.self) { a in Text(Self.label(a)).tag(a) }
            }
            Text(Self.help(access)).font(.caption).foregroundStyle(.secondary)
        }
    }

    static func label(_ a: AgentAccess) -> String {
        switch a {
        case .none: String(localized: "Aucun")
        case .read: String(localized: "Lecture seule")
        case .confirm: String(localized: "Actions avec confirmation")
        case .full: String(localized: "Actions sans confirmation")
        }
    }

    static func help(_ a: AgentAccess) -> String {
        switch a {
        case .none: String(localized: "Hôte invisible pour les agents IA.")
        case .read: String(localized: "Les agents lisent les terminaux, fichiers et tunnels, sans rien modifier.")
        case .confirm: String(localized: "Chaque commande, saisie, écriture ou tunnel attend votre accord.")
        case .full: String(localized: "Les agents agissent sans demander (actions journalisées). À réserver aux machines de test.")
        }
    }
}

// MARK: - Commandes et scène

struct MCPCommands: Commands {
    let model: AppModel
    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Button("Accès des agents (MCP)…") { model.mcp.isSettingsPresented = true }
        }
    }
}

struct MCPScene: ViewModifier {
    let model: AppModel
    static let sheetID = "mcp"
    func body(content: Content) -> some View {
        content
            .sheet(isPresented: Binding(get: { model.mcp.isSettingsPresented }, set: { model.mcp.isSettingsPresented = $0 })) {
                MCPSettingsView(model: model)
            }
            .onChange(of: model.mcp.isSettingsPresented) { _, shown in
                if shown { model.activeFeatureSheet = Self.sheetID }
                else if model.activeFeatureSheet == Self.sheetID { model.activeFeatureSheet = nil }
            }
    }
}
