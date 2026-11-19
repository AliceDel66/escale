import SwiftUI
import AppKit
import EscaleCore

/// Barre d'outils de la fenêtre, sur le modèle de celle de MobaXterm (Session, Split, MultiExec, Tunneling…) :
/// chaque bouton appelle l'action du menu correspondant. Personnalisable (clic droit › Personnaliser la barre d'outils).
struct MainToolbar: CustomizableToolbarContent {
    let model: AppModel

    private var hasTab: Bool { model.workspace.activeTab != nil }
    private var activeSSHHost: HostProfile? {
        guard let tab = model.workspace.activeTab, case .host(let h) = tab.kind, h.connectionProtocol == .ssh else { return nil }
        return h
    }

    var body: some CustomizableToolbarContent {
        // Remplace le bouton système de `NavigationSplitView` (retiré dans `MainWindowView`) : même format que les
        // autres boutons, personnalisable, et lié à `CompactMode.columns` (repli temporaire du mode compact).
        ToolbarItem(id: "barre-laterale", placement: .navigation) {
            let visible = model.compact.sidebarVisible
            Button { model.compact.toggleSidebar() } label: { Label("Barre latérale", systemImage: "sidebar.left") }
                .help(visible ? "Masquer la barre latérale (⌃⌘S)" : "Afficher la barre latérale (⌃⌘S)")
                .accessibilityIdentifier("toolbar-barre-laterale")
        }
        ToolbarItem(id: "session", placement: .automatic) {
            Button { model.editor = .newHost(folder: nil) } label: { Label("Session", systemImage: "plus.rectangle.on.rectangle") }
                .help("Nouvelle session (⌘N)")
        }
        ToolbarItem(id: "terminal", placement: .automatic) {
            Button { model.openLocalTab() } label: { Label("Terminal", systemImage: "terminal") }
                .help("Nouveau terminal local (⌘T)")
        }
        ToolbarItem(id: "connexion-rapide", placement: .automatic) {
            Button { model.focusQuickConnect() } label: { Label("Connexion", systemImage: "bolt") }
                .help("Connexion rapide (⇧⌘K)")
        }
        ToolbarItem(id: "scinder", placement: .automatic) {
            Menu {
                Button("Scinder à droite") { model.splitActivePane(.horizontal) }
                Button("Scinder en bas") { model.splitActivePane(.vertical) }
            } label: { Label("Scinder", systemImage: "rectangle.split.2x1") }
                .disabled(!hasTab)
                .help("Scinder le panneau actif")
        }
        ToolbarItem(id: "multiexec", placement: .automatic) {
            let on = model.multiExec.isBroadcasting
            Button { model.multiExec.toggleBroadcast() } label: {
                Label("MultiExec", systemImage: "dot.radiowaves.left.and.right")
                    .foregroundStyle(on ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
            }
            .disabled(!hasTab)
            .help(on ? "Arrêter la diffusion de la saisie (⌥⌘I)" : "Diffuser la saisie dans plusieurs panneaux (⌥⌘I)")
        }
        ToolbarItem(id: "tunnels", placement: .automatic) {
            Button { model.tunnels.show(host: activeSSHHost?.id) } label: { Label("Tunnels", systemImage: "arrow.left.arrow.right") }
                .help("Tunnels SSH (⇧⌘T)")
        }
        ToolbarItem(id: "fichiers", placement: .automatic) {
            Button { model.sftp.toggle() } label: { Label("Fichiers", systemImage: "folder") }
                .help("Fichiers distants, SFTP (⌥⌘F)")
        }
        ToolbarItem(id: "macros", placement: .automatic) {
            Menu {
                let f = model.macros
                if f.isRecording {
                    Button("Arrêter l'enregistrement") { f.stopRecording() }
                } else {
                    Button("Enregistrer une macro") { f.startRecording() }.disabled(!f.canRecord)
                }
                let list = f.availableMacros
                if !list.isEmpty {
                    Divider()
                    ForEach(list) { m in Button(m.name) { f.play(m) } }
                }
                Divider()
                Button("Gérer les macros…") { f.managerOpen = true }
            } label: { Label("Macros", systemImage: "paperplane") }
                .help("Macros du panneau actif")
        }
        ToolbarItem(id: "x11", placement: .automatic) {
            Button { if let h = activeSSHHost { model.macros.openX11Launcher(h) } } label: { Label("X11", systemImage: "macwindow.on.rectangle") }
                .disabled(activeSSHHost == nil)
                .help("Lancer une application X11 sur l'hôte de l'onglet actif")
        }
        ToolbarItem(id: "agents-ia", placement: .automatic) {
            let on = model.mcp.isRunning
            Button { model.mcp.isSettingsPresented = true } label: {
                Label("Agents IA", systemImage: "sparkles")
                    .foregroundStyle(on ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
            }
            .help("Accès des agents IA — agy, Claude, Codex (MCP)")
        }
        ToolbarItem(id: "importer", placement: .automatic, showsByDefault: false) {
            Menu {
                Button("Depuis ~/.ssh/config…") { model.beginImport() }
                ForEach(SessionImportKind.allCases, id: \.self) { kind in
                    Button(kind.menuTitle) { model.imports.choose(kind) }
                }
            } label: { Label("Importer", systemImage: "square.and.arrow.down") }
                .help("Importer des sessions")
        }
    }
}

/// Affichage « icône et texte » par défaut (la barre de MobaXterm est libellée) ; appliqué une seule fois,
/// le choix de l'utilisateur (clic droit sur la barre) est ensuite conservé par AppKit.
@MainActor
enum ToolbarDefaults {
    private static let key = "escale.toolbar.displayModeApplied"

    static func apply(to window: NSWindow) {
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        // La barre d'outils SwiftUI est installée après l'arrivée de la vue dans la fenêtre.
        DispatchQueue.main.async {
            guard let toolbar = window.toolbar else { return }
            toolbar.displayMode = .iconAndLabel
            UserDefaults.standard.set(true, forKey: key)
        }
    }
}
