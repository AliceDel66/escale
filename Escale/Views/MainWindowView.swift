import SwiftUI
import AppKit
import EscaleCore

/// Fenêtre principale : barre d'outils, barre latérale à volets, zone de détail (onglets de terminaux, accueil, barre d'état).
struct MainWindowView: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationSplitView(columnVisibility: Binding(get: { model.compact.columns }, set: { model.compact.columns = $0 })) {
            SidebarView(model: model)
                // Assez large pour le volet Fichiers (navigateur SFTP), qui vit dans la barre latérale.
                .navigationSplitViewColumnWidth(min: 250, ideal: 290, max: 560)
                // Bouton système remplacé par « Barre latérale » de `MainToolbar`.
                .toolbar(removing: .sidebarToggle)
        } detail: {
            DetailView(model: model)
        }
        .toolbar(id: "principal") { MainToolbar(model: model) }
        // Changer de volet (menu, barre d'outils, raccourci) ou appeler la connexion rapide rouvre une barre latérale repliée.
        // En mode compact, cela rouvre la barre latérale temporairement (voir `CompactMode.revealSidebar`).
        .onChange(of: model.sidebarTab) { _, _ in model.compact.revealSidebar() }
        .onChange(of: model.quickConnectFocused) { _, focused in if focused { model.compact.revealSidebar() } }
        .onChange(of: model.compact.columns) { _, _ in model.compact.columnsChanged() }
        .onChange(of: model.workspace.mainTabs.count) { old, new in model.compact.tabsChanged(from: old, to: new) }
        .navigationTitle(model.workspace.activeTab?.displayTitle ?? "Escale")
        .navigationSubtitle(subtitle)
        .sheet(item: $model.editor) { request in
            switch request {
            case .newHost(let folder): HostEditorSheet(model: model, host: nil, initialFolder: folder)
            case .editHost(let h): HostEditorSheet(model: model, host: h, initialFolder: h.folderID)
            case .newFolder(let parent): FolderSheet(model: model, folder: nil, parent: parent)
            case .renameFolder(let f): FolderSheet(model: model, folder: f, parent: f.parentID)
            }
        }
        .sheet(item: $model.importer) { importer in
            ImportSheet(model: model, importer: importer)
        }
        // Une seule feuille à la fois : une demande d'authentification attend que l'éditeur, l'import ou la
        // confirmation de suppression soit fermé (la demande reste en tête de file, rien n'est perdu).
        .sheet(item: Binding(
            get: { otherSheetOpen ? nil : model.connections.dialogs.current },
            set: { _ in } // fermée uniquement par ses boutons (`AuthDialogCenter.resolve`)
        )) { dialog in
            AuthDialogView(dialog: dialog, center: model.connections.dialogs)
        }
        .confirmationDialog(deletionTitle, isPresented: Binding(
            get: { model.pendingDeletion != nil }, set: { if !$0 { model.pendingDeletion = nil } }),
            titleVisibility: .visible, presenting: model.pendingDeletion
        ) { request in
            Button("Supprimer", role: .destructive) {
                switch request {
                case .host(let h): model.deleteHost(h)
                case .folder(let f): model.library.deleteFolder(f.id)
                }
            }
            Button("Annuler", role: .cancel) {}
        } message: { request in
            switch request {
            case .host(let h): Text("« \(h.name) » sera retiré de la bibliothèque et ses onglets ouverts seront fermés.")
            case .folder(let f): Text("Le dossier « \(f.name) » sera supprimé ; les hôtes qu'il contient remontent au niveau supérieur.")
            }
        }
        .background(WindowAccessor { model.mainWindow = $0; ToolbarDefaults.apply(to: $0); model.compact.applyToolbar(to: $0) })
        .modifier(FeatureScenes(model: model))
        .environment(\.locale, model.settings.effectiveLocale)
    }

    private var otherSheetOpen: Bool {
        model.editor != nil || model.importer != nil || model.pendingDeletion != nil || model.activeFeatureSheet != nil
    }

    private var subtitle: String {
        guard let tab = model.workspace.activeTab, case .host(let h) = tab.kind else { return "" }
        return h.target
    }

    private var deletionTitle: String {
        switch model.pendingDeletion {
        case .host(let h): String(localized: "Supprimer l'hôte « \(h.name) » ?")
        case .folder(let f): String(localized: "Supprimer le dossier « \(f.name) » ?")
        case nil: ""
        }
    }
}

/// Donne accès à la `NSWindow` hôte (captures de l'auto-test).
struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void
    func makeNSView(context: Context) -> NSView {
        let v = Probe()
        v.onWindow = onWindow
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
    final class Probe: NSView {
        var onWindow: ((NSWindow) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let w = window { onWindow?(w) }
        }
    }
}
