import AppKit
import SwiftUI
import Observation
import EscaleCore

/// M2 : navigateur SFTP latéral, suivi du dossier du terminal, file de transferts, édition distante.
/// Un navigateur (`SFTPHostSession`) par hôte, chacun sur la connexion maître de l'hôte ; une file de
/// transferts et un gestionnaire d'éditions communs.
@MainActor
@Observable
final class SFTPFeature: AppFeature {
    @ObservationIgnored private(set) weak var model: AppModel?
    var requireModel: AppModel { model! }

    /// Volet « Fichiers » de la barre latérale affiché (à la MobaXterm : le navigateur vit à gauche du terminal).
    var isVisible: Bool {
        get { model?.sidebarTab == .files }
        set { model?.sidebarTab = newValue ? .files : .sessions }
    }
    /// Le navigateur suit le dossier courant du terminal (OSC 7).
    var followTerminal = true

    let transfers = SFTPTransferQueue()
    @ObservationIgnored private(set) var edits: SFTPEditManager!
    @ObservationIgnored private var sessions: [UUID: SFTPHostSession] = [:]
    /// Dernier hôte parcouru : affiché tant que l'onglet actif n'est pas un onglet SSH.
    private(set) var pinnedHostID: UUID?
    /// Racine des fichiers temporaires de l'app (`~/Library/Caches/<bundle>/`) : éditions et glisser-déposer.
    @ObservationIgnored var cachesRoot: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Caches")
        return base.appendingPathComponent(Bundle.main.bundleIdentifier ?? "Escale", isDirectory: true)
    }()
    /// Confirmation de remplacement d'un fichier distant (remplaçable dans les tests).
    @ObservationIgnored var confirmReplace: @MainActor ([String]) async -> Bool = { names in
        let alert = NSAlert()
        alert.messageText = names.count == 1 ? String(localized: "« \(names[0]) » existe déjà sur le serveur") : String(localized: "\(names.count) éléments existent déjà sur le serveur")
        alert.informativeText = String(localized: "Voulez-vous les remplacer ?")
        alert.addButton(withTitle: String(localized: "Remplacer"))
        alert.addButton(withTitle: String(localized: "Annuler"))
        alert.alertStyle = .warning
        return alert.runModal() == .alertFirstButtonReturn
    }

    init() { edits = SFTPEditManager(feature: self) }

    func attach(_ model: AppModel) {
        self.model = model
        // Après une perte et une reconnexion du lien, les navigateurs rouvrent leur canal.
        model.connections.linkObservers["sftp"] = { [weak self] link, event in self?.linkEvent(link, event) }
        trackTerminal()
    }

    func shutdown() async {
        transfers.cancelAll()
        edits.stopAll()
        for s in sessions.values { await s.close() }
        sessions.removeAll()
        try? FileManager.default.removeItem(at: cachesRoot.appendingPathComponent("drag"))
    }

    // MARK: Sessions

    func session(for profile: HostProfile) -> SFTPHostSession {
        if let s = sessions[profile.id], s.profile == profile { return s }
        let s = SFTPHostSession(profile: profile, feature: self)
        sessions[profile.id] = s
        return s
    }

    func existingSession(_ hostID: UUID) -> SFTPHostSession? { sessions[hostID] }

    /// Hôte affiché : celui de l'onglet actif s'il est SSH, sinon le dernier parcouru.
    func currentSession() -> SFTPHostSession? {
        guard let model else { return nil }
        if let tab = model.workspace.activeTab, case .host(let p) = tab.kind { return session(for: p) }
        if let id = pinnedHostID, let h = model.library.host(id) { return session(for: h) }
        return nil
    }

    /// « Parcourir les fichiers (SFTP) » : sélectionne (ou ouvre) l'onglet de l'hôte, affiche le volet, ouvre le canal.
    func browse(_ host: HostProfile) async {
        guard let model else { return }
        pinnedHostID = host.id
        model.connect(host)
        isVisible = true
        widenWindowIfNeeded()
        await session(for: host).open()
    }

    func toggle() {
        isVisible.toggle()
        if isVisible { widenWindowIfNeeded(); if let s = currentSession() { Task { await s.open() } } }
    }

    /// Le navigateur demande une barre latérale plus large que la liste des sessions : sur une fenêtre trop étroite,
    /// on élargit la fenêtre (dans les limites de l'écran) quand le volet s'ouvre.
    func widenWindowIfNeeded() {
        guard let w = model?.mainWindow, let screen = w.screen ?? NSScreen.main else { return }
        let wanted: CGFloat = 1180
        guard w.frame.width < wanted else { return }
        var f = w.frame
        f.size.width = min(wanted, screen.visibleFrame.width)
        f.origin.x = max(screen.visibleFrame.minX, min(f.origin.x, screen.visibleFrame.maxX - f.size.width))
        w.setFrame(f, display: true, animate: false)
    }

    private func linkEvent(_ link: SSHLink, _ event: ConnectionManager.LinkEvent) {
        for s in sessions.values where s.link === link {
            switch event {
            case .lost: s.channelLost()
            case .connected: Task { await s.reopen() }
            case .disconnected: Task { await s.close() }
            }
        }
    }

    // MARK: Suivi du terminal (OSC 7)

    /// Observe le panneau actif et son dossier courant ; chaque changement est relayé au navigateur de l'hôte.
    private func trackTerminal() {
        withObservationTracking {
            _ = followTerminal
            _ = model?.workspace.activeID
            if let pane = model?.workspace.activeTab?.activePane {
                _ = pane.id
                _ = pane.session.workingDirectory
            }
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.terminalChanged()
                self?.trackTerminal()
            }
        }
    }

    private func terminalChanged() {
        guard followTerminal, let pane = model?.workspace.activeTab?.activePane, let host = pane.hostID,
              let s = sessions[host], let dir = pane.session.workingDirectory else { return }
        Task { await s.follow(directory: dir.path) }
    }

    /// Le panneau actif est distant mais n'a encore annoncé aucun dossier : proposer « Activer le suivi ».
    var trackingMissing: Bool {
        guard let pane = model?.workspace.activeTab?.activePane, pane.isRemote, pane.status == .running else { return false }
        return pane.session.workingDirectory == nil
    }

    /// Fonction shell qui émet OSC 7 à chaque invite (bash : PROMPT_COMMAND, zsh : precmd). Espace initial :
    /// la ligne n'entre pas dans l'historique de bash/zsh configurés avec HISTCONTROL=ignorespace.
    static let trackingSnippet = " __escale_osc7() { printf '\\033]7;file://%s%s\\007' \"${HOST:-$HOSTNAME}\" \"${PWD// /%20}\"; }; "
        + "if [ -n \"$ZSH_VERSION\" ]; then precmd_functions+=(__escale_osc7); else PROMPT_COMMAND=\"__escale_osc7${PROMPT_COMMAND:+;$PROMPT_COMMAND}\"; fi; __escale_osc7\r"

    /// Injecte la fonction dans le shell du panneau actif (après accord de l'utilisateur, demandé par l'appelant).
    func injectTracking(in pane: Pane? = nil) {
        guard let pane = pane ?? model?.workspace.activeTab?.activePane, pane.isRemote else { return }
        pane.session.write(Data(Self.trackingSnippet.utf8))
    }

    // MARK: Édition

    func edit(_ item: SFTPItem, in session: SFTPHostSession) async {
        do { try await edits.edit(item, in: session) } catch { session.errorMessage = SFTPMessages.describe(error) }
    }
}

struct SFTPCommands: Commands {
    let model: AppModel
    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Button(model.sftp.isVisible ? "Masquer les fichiers" : "Afficher les fichiers") { model.sftp.toggle() }
                .keyboardShortcut("f", modifiers: [.command, .option])
        }
    }
}

/// Le navigateur est le volet « Fichiers » de la barre latérale (`SidebarView`) : plus d'inspecteur à droite.
struct SFTPScene: ViewModifier {
    let model: AppModel
    func body(content: Content) -> some View { content }
}

/// Contenu du volet « Fichiers ». L'appelant ne le construit que lorsque le volet est choisi : son `.task` ouvre
/// un canal SFTP (une session du maître), ce qui ne doit arriver que sur action de l'utilisateur (invariant 12).
struct SFTPSidebarPane: View {
    let model: AppModel
    var body: some View {
        if model.sftp.isVisible { SFTPBrowserView(feature: model.sftp) }
    }
}

struct SFTPHostMenuItems: View {
    let model: AppModel
    let host: HostProfile
    var body: some View {
        Button("Parcourir les fichiers (SFTP)") { Task { await model.sftp.browse(host) } }
    }
}
