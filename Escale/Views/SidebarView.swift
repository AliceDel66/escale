import SwiftUI
import AppKit
import EscaleCore

/// Barre latérale à volets, sur le modèle des onglets verticaux de MobaXterm : Sessions, Fichiers (SFTP), Outils, Macros.
struct SidebarView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            SidebarTabBar(selection: $model.sidebarTab)
            Divider()
            switch model.sidebarTab {
            case .sessions: SessionsPane(model: model)
            // Construit seulement quand le volet est choisi : son `.task` ouvre un canal SFTP (invariant 12).
            case .files: SFTPSidebarPane(model: model)
            case .tools: ToolsPane(model: model)
            case .macros: MacrosPane(model: model)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { LibraryProblemBanner(library: model.library) }
    }
}

/// Sélecteur de volet : icône + libellé, le volet actif teinté.
private struct SidebarTabBar: View {
    @Binding var selection: SidebarTab

    var body: some View {
        HStack(spacing: 2) {
            ForEach(SidebarTab.allCases) { tab in
                let active = tab == selection
                Button { selection = tab } label: {
                    VStack(spacing: 2) {
                        Image(systemName: tab.symbolName).symbolVariant(active ? .fill : .none)
                            .font(.system(size: 14)).frame(height: 16)
                        Text(tab.titleKey).font(.system(size: 10, weight: active ? .semibold : .regular)).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                    .foregroundStyle(active ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .background(active ? AnyShapeStyle(.tint.opacity(0.14)) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .help(tab.titleKey)
                .accessibilityLabel(tab.titleKey)
                .accessibilityAddTraits(active ? [.isSelected] : [])
                .accessibilityIdentifier("sidebar.tab.\(tab.rawValue)")
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
    }
}

/// Volet Sessions : connexion rapide / recherche, « Terminal local », arborescence dossiers/hôtes avec état de connexion.
private struct SessionsPane: View {
    @Bindable var model: AppModel
    @State private var selection: Set<UUID> = []

    private var searching: Bool { !model.searchText.trimmingCharacters(in: .whitespaces).isEmpty }
    /// Cible de connexion rapide lisible dans la saisie (nil : simple recherche).
    private var quickTarget: QuickConnectTarget? { searching ? QuickConnectTarget.parse(model.searchText) : nil }

    var body: some View {
        List(selection: $selection) {
            if let target = quickTarget {
                Section {
                    Label("Connecter à \(target.display)", systemImage: "bolt.fill")
                        .tag(AppModel.quickConnectRowID)
                        .help("Ouvre une session SSH et l'enregistre dans la bibliothèque (Entrée)")
                }
            }
            if !searching {
                Section {
                    Label("Terminal local", systemImage: "terminal").tag(AppModel.localTerminalID)
                }
            }
            Section("Hôtes") {
                if searching {
                    // Résultats à plat, classés par pertinence (recherche floue du cœur), correspondances surlignées.
                    let found = model.library.searchResults(model.searchText)
                    if found.isEmpty {
                        Text("Aucun résultat").foregroundStyle(.secondary)
                    }
                    ForEach(found, id: \.host.id) { HostRow(model: model, host: $0.host, result: $0).tag($0.host.id) }
                } else if model.library.tree.isEmpty {
                    Text("Aucun hôte enregistré").foregroundStyle(.secondary)
                } else {
                    TreeRows(model: model, nodes: model.library.tree)
                }
            }
        }
        .listStyle(.sidebar)
        .environment(\.defaultMinListRowHeight, 24)
        .searchable(text: $model.searchText, isPresented: $model.quickConnectFocused, placement: .sidebar,
                    prompt: "Connexion rapide ou recherche")
        .onSubmit(of: .search) { submitQuickConnect() }
        .contextMenu(forSelectionType: UUID.self) { ids in
            contextMenu(for: ids)
        } primaryAction: { ids in
            // Double-clic ou Entrée.
            for id in ids {
                if id == AppModel.localTerminalID { model.openLocalTab() }
                else if id == AppModel.quickConnectRowID { if model.quickConnect(model.searchText) { model.searchText = "" } }
                else if let h = model.library.host(id) { model.connect(h) }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                Menu {
                    Button("Nouvel hôte…") { model.editor = .newHost(folder: selectedFolder) }
                    Button("Nouveau dossier…") { model.editor = .newFolder(parent: selectedFolder) }
                    Divider()
                    Button("Importer depuis ~/.ssh/config…") { model.beginImport(destinationFolder: selectedFolder) }
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Ajouter un hôte ou un dossier")
                .accessibilityLabel("Ajouter")
                Spacer()
                Text("\(model.library.library.hosts.count) hôtes").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(.bar)
        }
    }

    /// Entrée dans le champ : une cible explicite (`@`, `:`) ouvre cette cible ; sinon le meilleur résultat de la
    /// recherche, et à défaut la saisie prise comme nom d'hôte.
    private func submitQuickConnect() {
        let text = model.searchText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        let explicit = text.contains("@") || text.contains(":")
        if !explicit, let best = model.library.searchResults(text).first {
            model.connect(best.host)
            model.searchText = ""
        } else if model.quickConnect(text) {
            model.searchText = ""
        } else {
            NSSound.beep()
        }
    }

    private var selectedFolder: UUID? {
        guard let id = selection.first, model.library.folder(id) != nil else { return nil }
        return id
    }

    @ViewBuilder
    private func contextMenu(for ids: Set<UUID>) -> some View {
        if ids.isEmpty {
            Button("Nouvel hôte…") { model.editor = .newHost(folder: nil) }
            Button("Nouveau dossier…") { model.editor = .newFolder(parent: nil) }
            Button("Importer depuis ~/.ssh/config…") { model.beginImport() }
        } else if ids == [AppModel.localTerminalID] {
            Button("Ouvrir un terminal local") { model.openLocalTab() }
        } else if ids == [AppModel.quickConnectRowID] {
            Button("Connecter") { if model.quickConnect(model.searchText) { model.searchText = "" } }
        } else if ids.count == 1, let id = ids.first, let host = model.library.host(id) {
            Button("Connecter") { model.connect(host) }
            if host.connectionProtocol.isTerminal { Button("Nouvel onglet") { model.newTab(host) } }
            if model.connections.existing(host.id)?.tabCount ?? 0 > 0
                || (host.connectionProtocol != .ssh && !model.workspace.tabs(forHost: host.id).isEmpty) {
                Button("Déconnecter") { model.disconnect(host) }
            }
            FeatureHostMenuItems(model: model, host: host)
            Divider()
            Button("Modifier…") { model.editor = .editHost(host) }
            Button("Dupliquer") { model.library.duplicateHost(host.id) }
            Menu("Déplacer vers") {
                Button("Racine") { model.library.moveHost(host.id, to: nil) }.disabled(host.folderID == nil)
                ForEach(model.library.allFolderPaths, id: \.id) { f in
                    Button(f.path) { model.library.moveHost(host.id, to: f.id) }.disabled(host.folderID == f.id)
                }
            }
            Divider()
            Button("Supprimer…", role: .destructive) { model.pendingDeletion = .host(host) }
        } else if ids.count == 1, let id = ids.first, let folder = model.library.folder(id) {
            Button("Nouvel hôte ici…") { model.editor = .newHost(folder: folder.id) }
            Button("Nouveau sous-dossier…") { model.editor = .newFolder(parent: folder.id) }
            Button("Renommer…") { model.editor = .renameFolder(folder) }
            FeatureFolderMenuItems(model: model, folder: folder)
            Divider()
            Button("Supprimer…", role: .destructive) { model.pendingDeletion = .folder(folder) }
        } else {
            // Sélection multiple : seules les actions sans ambiguïté.
            let hosts = ids.compactMap { model.library.host($0) }
            Button("Connecter \(hosts.count) hôtes") { hosts.forEach { model.connect($0) } }.disabled(hosts.isEmpty)
            FeatureSelectionMenuItems(model: model, hosts: hosts)
        }
    }
}

/// Lignes récursives de l'arborescence (dossiers repliables).
private struct TreeRows: View {
    let model: AppModel
    let nodes: [SidebarNode]

    var body: some View {
        ForEach(nodes) { node in
            switch node.kind {
            case .folder(let f):
                DisclosureGroup(isExpanded: Binding(
                    get: { !model.collapsedFolders.contains(f.id) },
                    set: { open in
                        if open { model.collapsedFolders.remove(f.id) } else { model.collapsedFolders.insert(f.id) }
                    })
                ) {
                    TreeRows(model: model, nodes: node.children)
                } label: {
                    Label(f.name, systemImage: "folder")
                }
                .tag(f.id)
            case .host(let h):
                HostRow(model: model, host: h).tag(h.id)
            }
        }
    }
}

/// Texte avec les plages d'une recherche surlignées (plages exprimées dans `text`).
private func highlighted(_ text: String, _ result: HostSearchResult?, _ field: HostSearchField) -> AttributedString {
    var out = AttributedString(text)
    guard let result else { return out }
    for m in result.matches where m.field == field {
        for r in m.ranges {
            guard let ar = Range<AttributedString.Index>(r, in: out) else { continue }
            out[ar].backgroundColor = Color.yellow.opacity(0.4)
            out[ar].font = .body.bold()
        }
    }
    return out
}

private struct HostRow: View {
    let model: AppModel
    let host: HostProfile
    var result: HostSearchResult?

    private var subtitle: AttributedString {
        var s = AttributedString(host.user.map { "\($0)@" } ?? "")
        s.append(highlighted(host.host, result, .host))
        return s
    }

    /// Étiquettes ayant correspondu (sinon une correspondance sur une étiquette resterait invisible).
    private var matchedTags: [AttributedString] {
        guard let result else { return [] }
        return result.matches.compactMap { m in
            if case .tag(let i) = m.field, host.tags.indices.contains(i) { return highlighted("#" + host.tags[i], result, m.field) }
            return nil
        }
    }

    var body: some View {
        let state = model.connections.state(of: host.id)
        HStack(spacing: 6) {
            Image(systemName: host.connectionProtocol.symbolName).foregroundStyle(host.connectionProtocol.tint)
                .frame(width: 18)
                .help(host.connectionProtocol.localizedDisplayNameKey)
            VStack(alignment: .leading, spacing: 1) {
                // Une seule ligne (densité d'une liste de sessions) : nom, puis cible en retrait.
                HStack(spacing: 6) {
                    Text(highlighted(host.name, result, .name)).lineLimit(1).layoutPriority(1)
                    if host.name != host.target || result != nil {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
                if !matchedTags.isEmpty {
                    Text(matchedTags.reduce(AttributedString()) { $0 + $1 + AttributedString(" ") })
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            ConnectionDot(state: state)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(host.name), \(ConnectionDot.label(state))")
    }
}

extension ConnectionProtocol {
    /// Couleur de l'icône du protocole (repère visuel dans les listes, les onglets et la barre d'état).
    var tint: Color {
        switch self {
        case .ssh: .blue
        case .telnet: .purple
        case .serial: .orange
        case .vnc: .green
        case .rdp: .teal
        }
    }
}

/// Pastille d'état de connexion (vide = déconnecté).
struct ConnectionDot: View {
    let state: SSHLink.State

    static func label(_ s: SSHLink.State) -> String {
        switch s {
        case .disconnected: String(localized: "déconnecté")
        case .connecting: String(localized: "connexion en cours")
        case .connected: String(localized: "connecté")
        case .failed(let m): String(localized: "échec : \(m)")
        case .reconnecting: String(localized: "reconnexion en cours")
        case .authRequired: String(localized: "authentification requise")
        case .cancelled: String(localized: "authentification annulée")
        case .hostKeyChanged: String(localized: "clé d'hôte modifiée : connexion refusée")
        }
    }

    var body: some View {
        switch state {
        case .disconnected:
            Circle().strokeBorder(.tertiary, lineWidth: 1).frame(width: 8, height: 8).help("Déconnecté")
        case .connecting, .reconnecting:
            Circle().fill(.orange).frame(width: 8, height: 8).help(Self.label(state))
        case .connected:
            Circle().fill(.green).frame(width: 8, height: 8).help("Connecté")
        case .failed, .hostKeyChanged:
            Circle().fill(.red).frame(width: 8, height: 8).help(Self.label(state))
        case .authRequired, .cancelled:
            Circle().fill(.orange).frame(width: 8, height: 8).help(Self.label(state))
        }
    }
}

/// Bandeau en tête de barre latérale : bibliothèque illisible (rien n'est écrit) ou échec de sauvegarde.
struct LibraryProblemBanner: View {
    let library: LibraryStore

    var body: some View {
        if let problem = library.loadProblem {
            // Barre latérale étroite : boutons empilés sous le message, le plus sûr en principal.
            StatusBanner(tone: .warning, icon: .symbol("exclamationmark.triangle.fill"), title: problem,
                         layout: .compact, titleLines: nil) {
                VStack(alignment: .leading, spacing: 6) {
                    Button("Continuer sans enregistrer") { library.dismissLoadProblem() }.buttonStyle(.bannerPrimary)
                    Button("Repartir d'une bibliothèque vide") { library.startFresh() }.buttonStyle(.bannerSecondary)
                }
            }
        } else if let error = library.lastError {
            StatusBanner(tone: .warning, icon: .symbol("exclamationmark.triangle.fill"), title: error,
                         layout: .compact, titleLines: nil, onDismiss: { library.dismissError() })
        }
    }
}
