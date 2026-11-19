import SwiftUI
import EscaleCore

/// Volet Outils : les modules de l'app à portée de clic (tunnels, multi-exécution, X11, imports), comme l'onglet
/// « Tools » de MobaXterm. Chaque ligne appelle la même action que le menu correspondant.
struct ToolsPane: View {
    let model: AppModel

    /// Hôte SSH du panneau actif (cible des outils « par hôte »).
    private var activeSSHHost: HostProfile? {
        guard let tab = model.workspace.activeTab, case .host(let h) = tab.kind, h.connectionProtocol == .ssh else { return nil }
        return h
    }

    var body: some View {
        let multi = model.multiExec
        List {
            Section("Réseau") {
                ToolRow("Tunnels SSH…", symbol: "arrow.left.arrow.right", detail: activeTunnelSummary) { model.tunnels.show(host: activeSSHHost?.id) }
                ToolRow("Application X11…", symbol: "macwindow.on.rectangle",
                        detail: activeSSHHost.map { "sur \($0.name)" } ?? "sélectionnez un onglet SSH") {
                    if let h = activeSSHHost { model.macros.openX11Launcher(h) }
                }
                .disabled(activeSSHHost == nil)
                ToolRow("Fichiers distants (SFTP)", symbol: "folder", detail: "volet Fichiers") { model.sftp.toggle() }
            }
            Section("Agents IA") {
                ToolRow("Agents IA (agy, Claude, Codex)…", symbol: "sparkles", detail: mcpSummary) {
                    model.mcp.isSettingsPresented = true
                }
            }
            Section("Multi-exécution") {
                ToolRow(multi.isBroadcasting ? "Arrêter la diffusion" : "Diffuser la saisie", symbol: "dot.radiowaves.left.and.right",
                        detail: multi.isBroadcasting ? "\(multi.broadcastPaneIDs.count) panneaux" : "même frappe dans plusieurs panneaux") {
                    multi.toggleBroadcast()
                }
                .disabled(model.workspace.tabs.isEmpty)
                ToolRow("Choisir les panneaux…", symbol: "checklist") { multi.openBroadcastSheet() }
                    .disabled(model.workspace.tabs.isEmpty)
                ToolRow("Exécuter une commande…", symbol: "play.rectangle", detail: "sur les hôtes connectés") { multi.beginGroupExecOnConnected() }
            }
            Section("Importer des sessions") {
                ToolRow("Depuis ~/.ssh/config…", symbol: "doc.text") { model.beginImport() }
                ForEach(SessionImportKind.allCases, id: \.self) { kind in
                    ToolRow(verbatim: kind.menuTitle, symbol: "square.and.arrow.down") { model.imports.choose(kind) }
                }
            }
            Section("Application") {
                ToolRow("Gérer les macros…", symbol: "paperplane") { model.macros.managerOpen = true }
                ToolRow("Rechercher les mises à jour…", symbol: "arrow.down.circle") { model.updates.checkForUpdates() }
                    .disabled(!model.updates.canCheckForUpdates)
            }
        }
        .listStyle(.sidebar)
        .environment(\.defaultMinListRowHeight, 24)
    }

    private var activeTunnelSummary: LocalizedStringKey? {
        let n = model.tunnels.states.values.filter(\.isActive).count
        return n == 0 ? nil : (n == 1 ? "1 actif" : "\(n) actifs")
    }

    private var mcpSummary: LocalizedStringKey {
        if model.mcp.isRunning {
            let n = model.mcp.clientCount
            return n == 0 ? "en écoute" : (n == 1 ? "1 client" : "\(n) clients")
        }
        return "désactivé"
    }
}

private struct ToolRow: View {
    let title: LocalizedStringKey
    let symbol: String
    let detail: LocalizedStringKey?
    let action: () -> Void

    init(_ title: LocalizedStringKey, symbol: String, detail: LocalizedStringKey? = nil, action: @escaping () -> Void) {
        self.title = title; self.symbol = symbol; self.detail = detail; self.action = action
    }

    /// Titre déjà résolu (nom d'import, etc.) : affiché tel quel.
    init(verbatim title: String, symbol: String, action: @escaping () -> Void) {
        self.init(LocalizedStringKey(title), symbol: symbol, action: action)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol).foregroundStyle(.tint).frame(width: 18)
                Text(title).lineLimit(1)
                Spacer(minLength: 4)
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Volet Macros : enregistrement et lecture dans le panneau actif.
struct MacrosPane: View {
    let model: AppModel

    var body: some View {
        let f = model.macros
        let list = f.availableMacros
        List {
            Section {
                if f.isRecording {
                    ToolRow("Arrêter l'enregistrement", symbol: "stop.circle.fill", detail: "\(f.recordedStepCount) étapes") { f.stopRecording() }
                } else {
                    ToolRow("Enregistrer une macro", symbol: "record.circle", detail: f.canRecord ? nil : "aucun terminal actif") { f.startRecording() }
                        .disabled(!f.canRecord)
                }
            }
            Section("Macros du panneau actif") {
                if list.isEmpty {
                    Text("Aucune macro").foregroundStyle(.secondary)
                }
                ForEach(list) { m in
                    HStack(spacing: 6) {
                        Button { f.play(m) } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "play.fill").foregroundStyle(.tint).frame(width: 18)
                                Text(m.name).lineLimit(1)
                                Spacer(minLength: 4)
                                if let n = m.shortcut { Text("⌃⌥\(n)").font(.caption).foregroundStyle(.secondary) }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(model.workspace.activeTab == nil)
                        .help("Jouer « \(m.name) » dans le panneau actif")
                    }
                    .contextMenu {
                        Button("Jouer") { f.play(m) }
                        Button("Jouer dans tous les panneaux de l'onglet") { f.play(m, allPanes: true) }
                        Divider()
                        Button("Modifier…") { f.managerOpen = true; f.edit(m) }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .environment(\.defaultMinListRowHeight, 24)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                Button("Gérer les macros…") { f.managerOpen = true }.controlSize(.small)
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(.bar)
        }
    }
}
