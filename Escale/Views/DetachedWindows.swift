import SwiftUI
import AppKit
import Observation

/// Registre des fenêtres d'onglets détachés. Détacher ne déplace que l'hébergement de la vue du terminal :
/// le `TerminalTab` reste dans `Workspace.tabs` (compteurs, multi-exécution, macros, SFTP le voient toujours),
/// son moteur, son pty et sa connexion maître ne sont ni recréés ni coupés.
@MainActor
@Observable
final class DetachedWindows {
    private(set) var controllers: [UUID: DetachedWindowController] = [:]
    @ObservationIgnored private weak var model: AppModel?

    var count: Int { controllers.count }

    func attach(_ model: AppModel) {
        self.model = model
        model.workspace.revealDetached = { [weak self] tab in self?.reveal(tab) }
    }

    /// Détache l'onglet dans une nouvelle fenêtre (sans effet s'il l'est déjà ou se ferme).
    @discardableResult
    func detach(_ tab: TerminalTab) -> DetachedWindowController? {
        guard let model, tab.windowID == nil, !tab.isClosing, model.workspace.tabs.contains(where: { $0.id == tab.id }) else { return nil }
        let id = UUID()
        model.workspace.detach(tab, window: id)
        let c = DetachedWindowController(model: model, windowID: id, registry: self)
        controllers[id] = c
        c.show()
        return c
    }

    /// Ramène l'onglet dans la fenêtre principale ; la fenêtre détachée, vide, se ferme d'elle-même.
    func reattach(_ tab: TerminalTab) {
        guard let model, tab.windowID != nil else { return }
        model.workspace.reattach(tab)
        model.mainWindow?.makeKeyAndOrderFront(nil)
        model.focusActivePane()
    }

    /// Onglet de la fenêtre détachée `window` (fenêtre clé, en général).
    func tab(in window: NSWindow?) -> TerminalTab? {
        guard let window, let c = controllers.values.first(where: { $0.window === window }) else { return nil }
        return model?.workspace.tabs(inWindow: c.windowID).first
    }

    func controller(for tab: TerminalTab) -> DetachedWindowController? { tab.windowID.flatMap { controllers[$0] } }

    func reveal(_ tab: TerminalTab) { controller(for: tab)?.reveal() }

    /// Menu « Ramener » : l'onglet de la fenêtre clé s'il est détaché, sinon le dernier onglet détaché.
    func reattachKeyOrLast() {
        guard let model else { return }
        if let t = tab(in: NSApp.keyWindow) { reattach(t); return }
        if let t = model.workspace.tabs.last(where: { $0.windowID != nil }) { reattach(t) }
    }

    /// ⌘W dans une fenêtre détachée : ferme le panneau actif, puis l'onglet (et la fenêtre). Faux hors fenêtre détachée.
    func closeActivePaneInKeyWindow() -> Bool {
        guard let model, let t = tab(in: NSApp.keyWindow) else { return false }
        model.closePane(t.activePane, in: t)
        return true
    }

    fileprivate func forget(_ id: UUID) { controllers[id] = nil }
}

/// Une fenêtre détachée : barre d'onglets propre, titre = hôte, fermeture = fermeture des sessions qu'elle porte.
@MainActor
final class DetachedWindowController: NSObject, NSWindowDelegate {
    let windowID: UUID
    let window: NSWindow
    private let model: AppModel
    private unowned let registry: DetachedWindows
    private var closed = false

    init(model: AppModel, windowID: UUID, registry: DetachedWindows) {
        self.model = model; self.windowID = windowID; self.registry = registry
        window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        super.init()
        let content = NSHostingView(rootView: DetachedWindowView(model: model, windowID: windowID))
        content.sizingOptions = []
        window.contentView = content
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.minSize = NSSize(width: 480, height: 300)
        window.tabbingMode = .disallowed
        let base = model.mainWindow?.frame ?? NSRect(x: 200, y: 200, width: 1000, height: 640)
        let size = NSSize(width: max(560, min(base.width * 0.8, 1100)), height: max(360, min(base.height * 0.85, 760)))
        window.setFrame(NSRect(x: base.minX + 40, y: base.maxY - size.height - 40, width: size.width, height: size.height), display: false)
        track()
    }

    func show() {
        // Recette : la fenêtre passe devant sans prendre le focus ; usage normal : elle devient la fenêtre active.
        if model.options.isSelfTest { window.orderFrontRegardless() } else { window.makeKeyAndOrderFront(nil) }
    }

    func reveal() { window.makeKeyAndOrderFront(nil) }

    /// Titre (hôte), sous-titre (titre annoncé par le terminal) ; la fenêtre se ferme quand elle n'a plus d'onglet.
    private func track() {
        guard !closed else { return }
        var tabs: [TerminalTab] = []
        var title = "", subtitle = ""
        withObservationTracking {
            tabs = model.workspace.tabs(inWindow: windowID)
            if let t = tabs.first { title = t.baseTitle; subtitle = t.displayTitle }
        } onChange: { [weak self] in
            Task { @MainActor in self?.track() }
        }
        if tabs.isEmpty { window.close(); return }
        if window.title != title { window.title = title }
        let sub = subtitle == title ? "" : subtitle
        if window.subtitle != sub { window.subtitle = sub }
    }

    // MARK: NSWindowDelegate

    /// Fermer la fenêtre ferme ses onglets (pty tués, maître libéré) ; la fenêtre principale n'a pas de
    /// confirmation à la fermeture d'un onglet, celle-ci non plus.
    func windowWillClose(_ notification: Notification) {
        guard !closed else { return }
        closed = true
        for t in model.workspace.tabs(inWindow: windowID) { model.close(t) }
        window.delegate = nil
        registry.forget(windowID)
    }
}

extension PaneHostTab {
    /// Instantané d'un onglet pour `PaneHost`, partagé par la fenêtre principale (`DetailView`) et les fenêtres
    /// détachées : bandeaux et barre de monitoring suivent l'onglet quand il change de fenêtre.
    @MainActor init(snapshotOf tab: TerminalTab, model: AppModel) {
        self.init(tab: tab, layout: tab.layout,
                  bannerIDs: Set(tab.panes.filter { $0.bannerMessage != nil }.map(\.id)),
                  monitorIDs: Set(tab.panes.map(\.id).filter { model.monitoring.monitors[$0] != nil }))
    }
}

/// Contenu d'une fenêtre détachée : sa barre d'onglets et les panneaux de l'onglet (même `PaneHost` que la fenêtre principale).
struct DetachedWindowView: View {
    let model: AppModel
    let windowID: UUID

    var body: some View {
        let tabs = model.workspace.tabs(inWindow: windowID)
        VStack(spacing: 0) {
            DetachedTabBar(model: model, tabs: tabs)
            Divider()
            PaneHost(model: model, tabs: tabs.map { PaneHostTab(snapshotOf: $0, model: model) }, activeID: tabs.first?.id)
        }
        .environment(\.locale, model.settings.effectiveLocale)
    }
}

/// Barre d'onglets de la fenêtre détachée : l'onglet (pastille d'état, titre), « Ramener » et fermeture.
private struct DetachedTabBar: View {
    let model: AppModel
    let tabs: [TerminalTab]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(tabs) { tab in
                HStack(spacing: 6) {
                    icon(tab).frame(width: 16)
                    Text(tab.displayTitle).lineLimit(1).truncationMode(.middle).font(.callout)
                    if tab.panes.count > 1 {
                        Text("\(tab.panes.count)").font(.caption2).foregroundStyle(.secondary)
                            .accessibilityLabel("\(tab.panes.count) panneaux")
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                .overlay(alignment: .bottom) { Capsule().fill(.tint).frame(height: 2).padding(.horizontal, 10) }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits([.isSelected, .isButton])
                .contextMenu {
                    Button("Ramener dans la fenêtre principale") { model.detached.reattach(tab) }
                    Divider()
                    Button("Fermer l'onglet") { model.close(tab) }
                }
            }
            Spacer(minLength: 8)
            if let tab = tabs.first {
                Button { model.detached.reattach(tab) } label: { Image(systemName: "rectangle.on.rectangle.angled") }
                    .buttonStyle(.borderless)
                    .help("Ramener dans la fenêtre principale")
                    .accessibilityLabel("Ramener dans la fenêtre principale")
                Button { model.close(tab) } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help("Fermer l'onglet")
                    .accessibilityLabel("Fermer \(tab.displayTitle)")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 32)
        .background(.bar)
    }

    @ViewBuilder private func icon(_ tab: TerminalTab) -> some View {
        let base = Group {
            if case .host(let h) = tab.kind {
                Image(systemName: h.connectionProtocol.symbolName).foregroundStyle(h.connectionProtocol.tint)
            } else {
                Image(systemName: "terminal").foregroundStyle(.secondary)
            }
        }.font(.system(size: 10))
        base.overlay(alignment: .bottomTrailing) { dot(tab.status).offset(x: 4, y: 3) }
    }

    @ViewBuilder private func dot(_ status: TerminalTab.Status) -> some View {
        switch status {
        case .running: Circle().fill(.green).frame(width: 6, height: 6)
        case .connecting, .reconnecting: Circle().fill(.orange).frame(width: 6, height: 6)
        case .failed: Circle().fill(.red).frame(width: 6, height: 6)
        case .ended: Circle().fill(.gray).frame(width: 6, height: 6)
        }
    }
}

/// Entrées du menu « Onglets » pour les onglets détachables (état relu via `PaneMenuState`, observé par SwiftUI).
struct DetachedTabMenuItems: View {
    let model: AppModel
    @ObservedObject private var state = PaneMenuState.shared

    var body: some View {
        Group {
            Divider()
            Button("Détacher l'onglet dans une nouvelle fenêtre") {
                if let t = model.workspace.activeTab { model.detached.detach(t) }
            }
            .disabled(!state.hasTab)
            Button("Ramener dans la fenêtre principale") { model.detached.reattachKeyOrLast() }
                .disabled(!state.hasDetached)
        }
    }
}
