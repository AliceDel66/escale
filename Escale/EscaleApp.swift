import SwiftUI
import AppKit
import EscaleCore

/// Vrai point d'entrée. L'app est son propre `SSH_ASKPASS` : quand ssh la relance avec ESCALE_ASKPASS_SOCKET et
/// ESCALE_ASKPASS_TOKEN, elle répond à l'invite et quitte AVANT toute initialisation AppKit/SwiftUI
/// (ni fenêtre, ni icône de Dock). Sans ces variables, `runIfRequested()` ne fait rien et l'app démarre normalement.
@main
enum Launcher {
    static func main() {
        AskpassClient.runIfRequested()
        // `Escale --mcp` : relais stdio du client MCP vers l'app en service (voir `MCPRelay`), sans AppKit.
        MCPRelay.runIfRequested()
        // Langue utilisateur (`escale.language`) appliquée avant la mise en cache de `Bundle.main.preferredLocalizations`.
        AppLanguage.applyLaunchLanguage()
        EscaleApp.main()
    }
}

struct EscaleApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model: AppModel

    init() {
        let m = AppModel(options: LaunchOptions.parse(CommandLine.arguments))
        _model = State(initialValue: m)
        AppDelegate.model = m
    }

    var body: some Scene {
        Window("Escale", id: "main") {
            MainWindowView(model: model)
                .environment(\.locale, model.settings.effectiveLocale)
                .frame(minWidth: 760, minHeight: 440)
                .task { await model.start() }
        }
        .defaultSize(width: 1180, height: 720)
        .commands {
            EscaleCommands(model: model)
            PaneCommands(model: model)
            FeatureCommands(model: model)
        }
    }
}

struct EscaleCommands: Commands {
    let model: AppModel

    var body: some Commands {
        // Fichier : remplace « Nouvelle fenêtre » (fenêtre unique) et « Fermer ».
        CommandGroup(replacing: .newItem) {
            Button("Nouveau terminal local") { model.openLocalTab() }.keyboardShortcut("t")
            Button("Nouvel hôte…") { model.editor = .newHost(folder: nil) }.keyboardShortcut("n")
            Button("Nouveau dossier…") { model.editor = .newFolder(parent: nil) }
            Button("Connexion rapide…") { model.focusQuickConnect() }.keyboardShortcut("k", modifiers: [.command, .shift])
            Divider()
            Button("Importer depuis ~/.ssh/config…") { model.beginImport() }
        }
        CommandGroup(replacing: .saveItem) {
            Button("Fermer l'onglet") {
                // Fenêtre Réglages active : ⌘W la ferme sans toucher aux onglets de terminaux.
                if model.settings.closeIfKeyWindow() { return }
                // Dernier onglet fermé : Cmd-W ferme alors la fenêtre.
                // Fenêtre détachée active : ⌘W ferme son panneau actif, puis son onglet et la fenêtre.
                if model.detached.closeActivePaneInKeyWindow() { return }
                if model.workspace.activeTab != nil { model.closeActiveTab() } else { NSApp.keyWindow?.performClose(nil) }
            }
            .keyboardShortcut("w")
        }
        // Présentation : volets de la barre latérale et page d'accueil.
        CommandGroup(after: .sidebar) {
            Button(model.compact.sidebarVisible ? "Masquer la barre latérale" : "Afficher la barre latérale") {
                model.compact.toggleSidebar()
            }
            .keyboardShortcut("s", modifiers: [.command, .control])
            Divider()
            Button("Accueil") { model.showHome() }.keyboardShortcut("h", modifiers: [.command, .shift])
            // Sans raccourci : ⌃chiffre appartient au terminal et à Mission Control.
            ForEach(SidebarTab.allCases) { tab in
                Button("Volet \(tab.title)") { model.sidebarTab = tab }
            }
        }
        CommandMenu("Onglets") {
            Button("Onglet suivant") { model.workspace.selectNext() }.keyboardShortcut("]", modifiers: [.command, .shift])
            Button("Onglet précédent") { model.workspace.selectPrevious() }.keyboardShortcut("[", modifiers: [.command, .shift])
            Divider()
            ForEach(1...9, id: \.self) { i in
                Button("Onglet \(i)") { model.workspace.select(index: i - 1) }
                    .keyboardShortcut(KeyEquivalent(Character("\(i)")), modifiers: .command)
            }
            DetachedTabMenuItems(model: model)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var model: AppModel?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Quitter : tous les pty tués et tous les maîtres déconnectés avant la sortie (aucun ssh résiduel).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model = Self.model else { return .terminateNow }
        Task { @MainActor in
            await model.shutdown()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
