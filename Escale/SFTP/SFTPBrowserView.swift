import AppKit
import SwiftUI
import UniformTypeIdentifiers
import EscaleCore

/// Élément(s) distant(s) glissé(s). Deux représentations : un fichier téléchargé à la demande (Finder), et un texte
/// interne `escale-remote:` que le navigateur du même hôte reconnaît pour déplacer / copier côté serveur.
struct RemoteDragFile: Transferable, Sendable {
    /// Charge utile interne (voir `SFTPDragPayload`).
    let payload: String
    /// Téléchargement pour le Finder ; nil pour un dossier.
    let fetch: (@Sendable () async throws -> URL)?

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .data) { file in
            guard let fetch = file.fetch else { throw SFTPError.localIO(String(localized: "un dossier ne se glisse pas vers le Finder")) }
            return SentTransferredFile(try await fetch(), allowAccessingOriginalFile: true)
        }
        ProxyRepresentation(exporting: \.payload)
    }
}

/// Charge utile d'un glisser distant → distant : identifiant de la session et chemins (base64, un par ligne).
enum SFTPDragPayload {
    static let prefix = "escale-remote:"

    static func encode(session: UUID, paths: [Data]) -> String {
        prefix + session.uuidString + "\n" + paths.map { $0.base64EncodedString() }.joined(separator: "\n")
    }

    static func decode(_ text: String) -> (session: UUID, paths: [Data])? {
        guard text.hasPrefix(prefix) else { return nil }
        let lines = text.dropFirst(prefix.count).split(separator: "\n").map(String.init)
        guard let first = lines.first, let id = UUID(uuidString: first) else { return nil }
        let paths = lines.dropFirst().compactMap { Data(base64Encoded: $0) }
        return paths.isEmpty ? nil : (id, paths)
    }
}

/// Contenu du volet « Fichiers » de la barre latérale : navigateur de l'hôte de l'onglet actif + file de transferts.
struct SFTPBrowserView: View {
    @Bindable var feature: SFTPFeature

    var body: some View {
        VStack(spacing: 0) {
            if let session = feature.currentSession() {
                SFTPSessionView(feature: feature, session: session)
                    .id(session.id)
            } else {
                ContentUnavailableView {
                    Label("Aucun hôte SSH", systemImage: "folder")
                } description: {
                    Text("Sélectionnez un onglet SSH, ou choisissez « Parcourir les fichiers (SFTP) » dans le menu d'un hôte.")
                }
                .frame(maxHeight: .infinity)
            }
            SFTPActivityView(feature: feature)
        }
        .background(.background)
    }
}

private struct SFTPSessionView: View {
    @Bindable var feature: SFTPFeature
    @Bindable var session: SFTPHostSession
    @State private var pathText = ""
    @State private var renaming: SFTPItem?
    @State private var renameText = ""
    @State private var creating = false
    @State private var newFolderText = ""
    @State private var deleting: [SFTPItem] = []
    @State private var confirmTracking = false
    /// Mode d'affichage (compact / colonnes) selon la largeur mesurée de la liste.
    private var columns: SFTPColumnsState { .shared }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            pathBar
            followRow
            if let m = session.errorMessage {
                StatusBanner(tone: .warning, icon: .symbol("exclamationmark.triangle.fill"), title: m,
                             layout: .compact, titleLines: nil, onDismiss: { session.errorMessage = nil })
                    .textSelection(.enabled)
            }
            if session.isShellMode, session.isReady {
                StatusBanner(tone: .info, icon: .symbol("terminal"), title: String(localized: "Mode shell (SFTP indisponible)"),
                             detail: session.shellReason.flatMap { $0.isEmpty ? nil : $0 },
                             layout: .compact, titleLines: 1, detailLines: 2)
            }
            if columns.mode.showsColumns {
                SFTPColumnsHeader(sort: $session.sort, mode: columns.mode)
            } else {
                sortBar
            }
            Divider()
            content
        }
        .task(id: session.id) { await session.open() }
        .onChange(of: session.pathString) { _, new in pathText = new }
        .onAppear { pathText = session.pathString }
        .alert("Renommer", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Nom", text: $renameText)
            Button("Renommer") { if let it = renaming { Task { await session.rename(it, to: renameText) } }; renaming = nil }
            Button("Annuler", role: .cancel) { renaming = nil }
        }
        .alert("Nouveau dossier", isPresented: $creating) {
            TextField("Nom du dossier", text: $newFolderText)
            Button("Créer") { Task { await session.makeDirectory(newFolderText) } }
            Button("Annuler", role: .cancel) {}
        }
        .confirmationDialog(deleteTitle, isPresented: Binding(get: { !deleting.isEmpty }, set: { if !$0 { deleting = [] } }), titleVisibility: .visible) {
            Button("Supprimer", role: .destructive) { let l = deleting; deleting = []; Task { await session.delete(l) } }
            Button("Annuler", role: .cancel) { deleting = [] }
        } message: {
            Text("Cette suppression est définitive : le contenu des dossiers est supprimé aussi.")
        }
        .confirmationDialog("Activer le suivi du dossier ?", isPresented: $confirmTracking, titleVisibility: .visible) {
            Button("Envoyer la fonction au shell") { feature.injectTracking() }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Escale tape une fonction dans le shell distant (une fois, pour cette session) qui annonce le dossier courant à chaque invite (séquence OSC 7). Rien n'est écrit sur le serveur.")
        }
    }

    private var deleteTitle: String {
        deleting.count == 1 ? String(localized: "Supprimer « \(deleting[0].name) » ?") : String(localized: "Supprimer \(deleting.count) éléments ?")
    }

    // MARK: En-tête

    private var toolbar: some View {
        HStack(spacing: 4) {
            Text(session.profile.name).font(.headline).lineLimit(1)
            Spacer()
            Button { Task { await session.goBack() } } label: { Image(systemName: "chevron.left") }
                .disabled(session.back.isEmpty).help("Précédent")
            Button { Task { await session.goForward() } } label: { Image(systemName: "chevron.right") }
                .disabled(session.forward.isEmpty).help("Suivant")
            Button { Task { await session.goUp() } } label: { Image(systemName: "arrow.up") }
                .disabled(!session.canGoUp).help("Dossier parent")
            Button { Task { await session.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                .disabled(!session.isReady).help("Actualiser")
            Button { newFolderText = ""; creating = true } label: { Image(systemName: "folder.badge.plus") }
                .disabled(!session.isReady).help("Nouveau dossier")
            Menu {
                Toggle("Afficher les fichiers cachés", isOn: $session.showHidden)
                Picker("Trier par", selection: Binding(get: { session.sort.key }, set: { k in
                    var s = session.sort; if s.key != k { s.toggle(k) }; session.sort = s
                })) {
                    ForEach(SFTPSortKey.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Button("Envoyer des fichiers…") { chooseFilesToUpload() }
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize()
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10).padding(.vertical, 8)
    }

    private var pathBar: some View {
        TextField("Chemin", text: $pathText)
            .textFieldStyle(.roundedBorder)
            .font(.system(.body, design: .monospaced))
            .onSubmit { Task { await session.navigate(to: pathText) } }
            .padding(.horizontal, 10).padding(.bottom, 6)
            .disabled(!session.isReady)
            // Volet étroit : le chemin complet reste lisible au survol.
            .help(pathText)
    }

    /// En-têtes de tri : un clic choisit la colonne, un second clic inverse l'ordre. Dossiers toujours en premier.
    private var sortBar: some View {
        HStack(spacing: 2) {
            ForEach(SFTPSortKey.allCases, id: \.self) { k in
                Button {
                    var s = session.sort; s.toggle(k); session.sort = s
                } label: {
                    HStack(spacing: 3) {
                        Text(k.label)
                        if session.sort.key == k {
                            Image(systemName: session.sort.ascending ? "chevron.up" : "chevron.down").font(.system(size: 8, weight: .bold))
                        }
                    }
                    .font(.caption.weight(session.sort.key == k ? .bold : .regular))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("sftp.sort.\(k.rawValue)")
            }
            Spacer()
        }
        .padding(.horizontal, 8).padding(.bottom, 4)
        .foregroundStyle(.secondary)
    }

    private var followRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Suivre le terminal", isOn: $feature.followTerminal)
                .toggleStyle(.switch).controlSize(.small)
            if feature.followTerminal, feature.trackingMissing {
                HStack(spacing: 6) {
                    Text("Ce shell n'annonce pas son dossier.").font(.caption).foregroundStyle(.secondary)
                    Button("Activer le suivi") { confirmTracking = true }.controlSize(.small)
                }
            }
        }
        .padding(.horizontal, 10).padding(.bottom, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Liste

    @ViewBuilder private var content: some View {
        switch session.state {
        case .idle, .connecting:
            VStack { ProgressView("Ouverture du canal SFTP…") }.frame(maxWidth: .infinity, maxHeight: .infinity)
        case .lost:
            VStack(spacing: 8) {
                ProgressView()
                Text("Connexion perdue — le navigateur reprendra à la reconnexion.").font(.caption).multilineTextAlignment(.center)
            }.padding().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let m):
            ContentUnavailableView {
                Label("SFTP indisponible", systemImage: "exclamationmark.triangle")
            } description: {
                Text(m)
            } actions: {
                Button("Réessayer") { Task { await session.open() } }
            }
        case .ready:
            list
        }
    }

    private var list: some View {
        listBody
            // Largeur de la liste : choisit colonnes ou liste compacte (hystérésis dans `SFTPColumnsMode`).
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { columns.measured($0) }
    }

    private var listBody: some View {
        List(selection: $session.selection) {
            ForEach(session.visibleItems) { item in
                row(item).tag(item.id)
            }
        }
        .listStyle(.inset)
        .overlay {
            if session.visibleItems.isEmpty && !session.isLoading {
                Text("Dossier vide").foregroundStyle(.secondary)
            }
        }
        .contextMenu(forSelectionType: Data.self) { ids in
            menu(for: ids)
        } primaryAction: { ids in
            let items = session.items.filter { ids.contains($0.id) }
            guard items.count == 1, let it = items.first else { return }
            Task { if it.isDirectory { await session.open(it) } else { await feature.edit(it, in: session) } }
        }
        .dropDestination(for: URL.self) { urls, _ in
            Task { await session.upload(urls) }
            return true
        }
        .onDeleteCommand { deleting = session.selectedItems }
    }

    private func rowLabel(_ item: SFTPItem) -> some View {
        HStack(spacing: 8) {
            Image(systemName: item.isDirectory ? "folder.fill" : (item.isSymlink ? "link" : "doc"))
                .foregroundStyle(item.isDirectory ? Color.accentColor : .secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).lineLimit(1).truncationMode(.middle)
                Text("\(item.isDirectory ? "" : SFTPFormat.size(item.size) + " · ")\(SFTPFormat.date(item.modified)) · \(item.permissionText)")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder private func rowContent(_ item: SFTPItem) -> some View {
        if columns.mode.showsColumns { SFTPColumnsRow(item: item, mode: columns.mode) } else { rowLabel(item) }
    }

    private func dragItem(_ item: SFTPItem) -> RemoteDragFile {
        let paths: [Data] = draggedItems(for: item).map { $0.path }
        let payload = SFTPDragPayload.encode(session: session.id, paths: paths)
        if item.isDirectory { return RemoteDragFile(payload: payload, fetch: nil) }
        let s = session
        let fetch: @Sendable () async throws -> URL = { try await s.exportForDrag(item) }
        return RemoteDragFile(payload: payload, fetch: fetch)
    }

    @ViewBuilder private func row(_ item: SFTPItem) -> some View {
        let source = rowContent(item).draggable(dragItem(item))
        if item.isDirectory {
            source
                .dropDestination(for: URL.self) { urls, _ in
                    Task { await session.upload(urls, into: item.path) }
                    return true
                }
                // Distant → distant : déplacer (⌥ : copier) dans ce dossier.
                .dropDestination(for: String.self) { texts, _ in
                    handleRemoteDrop(texts, into: item.path)
                }
        } else {
            source
        }
    }

    /// Si la ligne glissée fait partie de la sélection, toute la sélection suit.
    private func draggedItems(for item: SFTPItem) -> [SFTPItem] {
        session.selection.contains(item.id) ? session.selectedItems : [item]
    }

    private func handleRemoteDrop(_ texts: [String], into directory: Data) -> Bool {
        guard let d = texts.compactMap(SFTPDragPayload.decode).first else { return false }
        let wanted = Set(d.paths)
        if d.session != session.id {
            // Autre hôte : copie en flux vers ce dossier (jamais un déplacement : la source reste intacte).
            guard let origin = feature.existingSession(d.session) else { return false }
            let items = origin.items.filter { wanted.contains($0.id) }
            guard !items.isEmpty else { return false }
            Task { await session.copy(items, from: origin, into: directory) }
            return true
        }
        let items = session.items.filter { wanted.contains($0.id) }
        guard !items.isEmpty else { return false }
        let copy = NSEvent.modifierFlags.contains(.option)
        Task { await session.move(items, into: directory, copy: copy) }
        return true
    }

    @ViewBuilder private func menu(for ids: Set<Data>) -> some View {
        let items = session.items.filter { ids.contains($0.id) }
        if items.isEmpty {
            Button("Nouveau dossier…") { newFolderText = ""; creating = true }
            Button("Envoyer des fichiers…") { chooseFilesToUpload() }
            Button("Actualiser") { Task { await session.refresh() } }
        } else {
            if items.count == 1, let it = items.first {
                if it.isDirectory {
                    Button("Ouvrir") { Task { await session.open(it) } }
                } else {
                    Button("Ouvrir avec l'éditeur") { Task { await feature.edit(it, in: session) } }
                }
            }
            Button("Télécharger dans Téléchargements") { Task { await session.downloadToDownloads(items) } }
            Button("Télécharger vers…") { chooseDownloadFolder(items) }
            if items.count == 1, let it = items.first {
                Button("Renommer…") { renameText = it.name; renaming = it }
            }
            Button("Copier le chemin") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(items.map { SFTPPath.string($0.path) }.joined(separator: "\n"), forType: .string)
            }
            Divider()
            Button("Supprimer…", role: .destructive) { deleting = items }
        }
    }

    private func chooseFilesToUpload() {
        let p = NSOpenPanel()
        p.canChooseFiles = true; p.canChooseDirectories = true; p.allowsMultipleSelection = true
        p.prompt = String(localized: "Envoyer")
        guard p.runModal() == .OK else { return }
        let urls = p.urls
        Task { await session.upload(urls) }
    }

    private func chooseDownloadFolder(_ items: [SFTPItem]) {
        let p = NSOpenPanel()
        p.canChooseFiles = false; p.canChooseDirectories = true; p.canCreateDirectories = true
        p.prompt = String(localized: "Télécharger ici")
        guard p.runModal() == .OK, let url = p.url else { return }
        Task { await session.download(items, to: url) }
    }
}

/// Transferts et éditions en cours (bas de l'inspecteur).
private struct SFTPActivityView: View {
    let feature: SFTPFeature
    @State private var expanded = true

    var body: some View {
        let queue = feature.transfers
        let edits = feature.edits.edits
        if !queue.items.isEmpty || !edits.isEmpty {
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Button { expanded.toggle() } label: {
                        Label("Transferts (\(queue.activeCount) en cours)", systemImage: expanded ? "chevron.down" : "chevron.right")
                    }.buttonStyle(.plain).font(.subheadline.bold())
                    Spacer()
                    if queue.hasFinished { Button("Effacer les terminés") { queue.clearFinished() }.controlSize(.small) }
                }
                if expanded {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(edits) { e in editRow(e) }
                            ForEach(queue.items) { t in transferRow(t, queue: queue) }
                        }
                    }
                    .frame(maxHeight: 190)
                }
            }
            .padding(10)
        }
    }

    private func transferRow(_ t: SFTPTransfer, queue: SFTPTransferQueue) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Image(systemName: t.direction == .upload ? "arrow.up.circle" : (t.direction == .relay ? "arrow.left.arrow.right.circle" : "arrow.down.circle"))
                Text(t.name).lineLimit(1).truncationMode(.middle)
                Spacer()
                switch t.state {
                case .queued, .running:
                    Button { queue.cancel(t) } label: { Image(systemName: "xmark.circle") }.help("Annuler")
                case .failed, .cancelled:
                    Button { queue.retry(t) } label: { Image(systemName: "arrow.clockwise.circle") }.help("Réessayer")
                case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
            }
            .buttonStyle(.borderless).font(.caption)
            switch t.state {
            case .running:
                ProgressView(value: t.fraction)
                Text("\(t.resumeText.map { $0 + " · " } ?? "")\(SFTPFormat.size(t.bytes)) sur \(SFTPFormat.size(t.total)) \(SFTPFormat.speed(t.speed))")
                    .font(.caption2).foregroundStyle(.secondary)
            case .queued: Text("En attente").font(.caption2).foregroundStyle(.secondary)
            case .failed(let m):
                Text(t.interrupted ? String(localized: "\(m) Reprise automatique à la reconnexion.") : m).font(.caption2).foregroundStyle(.red)
            case .cancelled: Text("Annulé").font(.caption2).foregroundStyle(.secondary)
            case .done:
                Text("\(t.resumeText.map { $0 + " · " } ?? "")\(SFTPFormat.size(t.total))").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func editRow(_ e: SFTPEdit) -> some View {
        HStack {
            Image(systemName: "pencil.circle")
            VStack(alignment: .leading, spacing: 1) {
                Text(e.name).lineLimit(1).font(.caption)
                Text(status(e)).font(.caption2).foregroundStyle(e.state.isProblem ? .red : .secondary)
            }
            Spacer()
            if e.state.isProblem { Button("Renvoyer") { feature.edits.resend(e) }.controlSize(.small) }
            Button("Terminer") { feature.edits.stop(e) }.controlSize(.small)
        }
    }

    private func status(_ e: SFTPEdit) -> String {
        switch e.state {
        case .watching: e.uploads == 0 ? String(localized: "Surveillé — enregistrez pour envoyer") : String(localized: "Envoyé \(e.uploads) fois")
        case .uploading: String(localized: "Envoi…")
        case .conflict: String(localized: "Conflit : version distante conservée")
        case .failed(let m): m
        case .stopped: String(localized: "Arrêté")
        }
    }
}

private extension SFTPEdit.State {
    var isProblem: Bool { switch self { case .conflict, .failed: true; default: false } }
}
