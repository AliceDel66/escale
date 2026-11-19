import Foundation
import Observation
import EscaleCore

/// Nœud de l'arborescence de la barre latérale.
struct SidebarNode: Identifiable, Hashable {
    enum Kind: Hashable { case folder(HostFolder), host(HostProfile) }
    let kind: Kind
    var children: [SidebarNode]
    var id: UUID {
        switch kind {
        case .folder(let f): f.id
        case .host(let h): h.id
        }
    }
}

/// Bibliothèque d'hôtes observable. Chargée via `HostRepository` (`FileHostRepository` en production), modifiée
/// par les opérations pures de `HostLibrary` (`HostLibraryOperations`), sauvegardée après chaque modification
/// (sauvegardes sérialisées : la dernière écriture est toujours la plus récente).
///
/// Fichier illisible, corrompu ou d'une version future : la bibliothèque reste vide, `loadProblem` explique pourquoi,
/// et AUCUNE sauvegarde n'a lieu tant que l'utilisateur n'a pas choisi « Repartir d'une bibliothèque vide »
/// (le cœur met alors l'ancien fichier de côté sous `<nom>.corrupt-…` au lieu de l'écraser).
@MainActor
@Observable
final class LibraryStore {
    /// Emplacement par défaut : Application Support/Escale/library.json.
    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Escale", isDirectory: true).appendingPathComponent("library.json")
    }

    private(set) var library = HostLibrary()
    private(set) var isLoaded = false
    private(set) var lastError: String?
    /// Message clair si le fichier n'a pas pu être lu ; nil sinon. Tant qu'il est posé, rien n'est écrit.
    private(set) var loadProblem: String?
    /// Chemin du fichier de bibliothèque (affiché dans les messages).
    let fileURL: URL?

    @ObservationIgnored private let repository: any HostRepository
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var savingBlocked = false

    init(repository: any HostRepository) {
        self.repository = repository
        fileURL = (repository as? FileHostRepository)?.url
    }

    func load() async {
        do {
            library = try await repository.load()
        } catch let error as HostRepositoryError {
            // Ancien format sans « version » (dépôt provisoire, recettes) : lu tel quel, converti à la première sauvegarde
            // (le cœur met alors l'ancien fichier de côté, il n'est jamais écrasé).
            if case .corrupted = error, let legacy = legacyLibrary() {
                library = legacy
            } else {
                loadProblem = Self.describe(error)
                savingBlocked = true
            }
        } catch {
            loadProblem = String(localized: "Lecture de la bibliothèque impossible : \(error.localizedDescription)")
            savingBlocked = true
        }
        isLoaded = true
    }

    private func legacyLibrary() -> HostLibrary? {
        guard let url = fileURL, let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], obj["version"] == nil,
              obj["hosts"] != nil || obj["folders"] != nil else { return nil }
        return try? JSONDecoder().decode(HostLibrary.self, from: data)
    }

    static func describe(_ error: HostRepositoryError) -> String {
        switch error {
        case .corrupted(let path, _):
            return String(localized: "La bibliothèque d'hôtes « \(path) » est illisible (fichier corrompu). Le fichier n'a pas été modifié et rien n'y sera écrit tant que vous n'aurez pas choisi de repartir d'une bibliothèque vide.")
        case .unsupportedVersion(let found, let supported):
            return String(localized: "La bibliothèque d'hôtes a été écrite par une version plus récente d'Escale (format \(found), cette version gère jusqu'au format \(supported)). Le fichier n'a pas été modifié et rien n'y sera écrit.")
        case .io(let path, let reason):
            return String(localized: "Lecture de la bibliothèque d'hôtes « \(path) » impossible : \(reason). Le fichier n'a pas été modifié.")
        }
    }

    /// Choix explicite de l'utilisateur : repartir d'une bibliothèque vide. Le fichier existant est mis de côté
    /// (`<nom>.corrupt-…`) par le cœur lors de la prochaine sauvegarde, jamais écrasé.
    func startFresh() {
        library = HostLibrary()
        loadProblem = nil
        savingBlocked = false
        persist()
    }

    /// L'utilisateur a pris connaissance du problème et continue sans enregistrer.
    func dismissLoadProblem() { loadProblem = nil }
    func dismissError() { lastError = nil }

    /// Attend la fin des sauvegardes en cours (tests, fermeture).
    func flush() async { await saveTask?.value }

    private func persist() {
        guard !savingBlocked else { return }
        let snapshot = library
        let previous = saveTask
        let repo = repository
        saveTask = Task { [weak self] in
            await previous?.value
            do { try await repo.save(snapshot) } catch {
                self?.lastError = String(localized: "Sauvegarde de la bibliothèque impossible : \(error.localizedDescription)")
            }
        }
    }

    /// Applique une opération du cœur ; en cas d'erreur elle est signalée et la bibliothèque reste inchangée.
    @discardableResult
    private func apply(_ op: (inout HostLibrary) throws -> Void) -> Bool {
        var copy = library
        do { try op(&copy) } catch {
            lastError = String(localized: "Modification de la bibliothèque refusée : \(error)")
            return false
        }
        library = copy
        persist()
        return true
    }

    // MARK: Lecture

    func host(_ id: UUID) -> HostProfile? { library.hosts.first { $0.id == id } }
    func folder(_ id: UUID) -> HostFolder? { library.folders.first { $0.id == id } }

    /// Arborescence : dossiers d'abord, puis hôtes, chacun trié par nom (tri du cœur).
    var tree: [SidebarNode] { nodes(under: nil, visited: []) }

    private func nodes(under parent: UUID?, visited: Set<UUID>) -> [SidebarNode] {
        let validFolderIDs = Set(library.folders.map(\.id))
        // Un dossier ou un hôte dont le parent n'existe plus (fichier édité à la main) remonte à la racine.
        func orphan(_ p: UUID?) -> Bool { p != nil && !validFolderIDs.contains(p!) }
        var folders = library.childFolders(of: parent)
        var hosts = library.hosts(in: parent)
        if parent == nil {
            folders += library.folders.filter { orphan($0.parentID) }
            hosts += library.hosts.filter { orphan($0.folderID) }
        }
        return folders.filter { !visited.contains($0.id) }
            .map { SidebarNode(kind: .folder($0), children: nodes(under: $0.id, visited: visited.union([$0.id]))) }
            + hosts.map { SidebarNode(kind: .host($0), children: []) }
    }

    /// Chemin lisible d'un dossier (« A / B »).
    func folderPath(_ id: UUID?) -> String {
        guard let id else { return "" }
        return library.folderPath(of: id).map(\.name).joined(separator: " / ")
    }

    var allFolderPaths: [(id: UUID, path: String)] {
        library.folders.map { ($0.id, folderPath($0.id)) }.sorted { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
    }

    /// Hôtes triés par nom (ordre d'entrée de la recherche : à score égal, ordre alphabétique).
    private var hostsByName: [HostProfile] {
        library.hosts.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Recherche floue du cœur : résultats classés avec plages à surligner. Requête vide : liste vide.
    func searchResults(_ query: String) -> [HostSearchResult] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        return HostSearch.search(query, in: hostsByName)
    }

    func search(_ query: String) -> [HostProfile] { searchResults(query).map(\.host) }

    // MARK: Modifications (chacune sauvegarde)

    func upsert(_ host: HostProfile) {
        apply { lib in
            if lib.hosts.contains(where: { $0.id == host.id }) { try lib.updateHost(host) } else { try lib.addHost(host) }
        }
    }

    func deleteHost(_ id: UUID) { apply { try $0.removeHost(id: id) } }

    @discardableResult
    func duplicateHost(_ id: UUID) -> HostProfile? {
        guard var copy = host(id) else { return nil }
        copy.id = UUID()
        copy.name += String(localized: " (copie)")
        // Une copie ne partage pas le secret Trousseau de l'original (compte dérivé de l'identifiant).
        if case .keychainPassword = copy.auth { copy.auth = .keychainPassword(account: AuthKeychain.passwordAccount(for: copy.id)) }
        return apply({ try $0.addHost(copy) }) ? copy : nil
    }

    func moveHost(_ id: UUID, to folderID: UUID?) { apply { try $0.moveHost(id: id, to: folderID) } }

    @discardableResult
    func addFolder(name: String, parentID: UUID?) -> HostFolder? {
        var created: HostFolder?
        apply { created = try $0.addFolder(name: name, parentID: parentID) }
        return created
    }

    func renameFolder(_ id: UUID, to name: String) { apply { try $0.renameFolder(id: id, to: name) } }

    /// Supprime un dossier ; ses hôtes et sous-dossiers remontent au niveau supérieur.
    func deleteFolder(_ id: UUID) { apply { try $0.removeFolder(id: id) } }

    func hostCount(inFolder id: UUID) -> Int { library.hosts.filter { $0.folderID == id }.count }

    // MARK: Import ssh_config

    /// Entrées de `result` absentes de la bibliothèque (le cœur compare l'hôte des profils `.openSSHDefaults`).
    func newEntries(in result: SSHConfigImportResult) -> [SSHConfigEntry] {
        SSHConfigImporter.newEntries(in: result, comparedTo: library)
    }

    /// Ajoute les entrées choisies (doublons ignorés par le cœur) dans `folderID` ; renvoie les hôtes ajoutés.
    @discardableResult
    func importEntries(_ entries: [SSHConfigEntry], from result: SSHConfigImportResult, into folderID: UUID?) -> [HostProfile] {
        var subset = result
        subset.entries = entries
        var added: [HostProfile] = []
        apply { added = SSHConfigImporter.merge(subset, into: &$0, folderID: folderID) }
        return added
    }

    // MARK: Import de sessions (M5 : MobaXterm, PuTTY, CSV)

    /// Fusionne des sessions importées (doublons host+port+user ignorés par le cœur) ; sauvegarde une seule fois.
    @discardableResult
    func importSessions(_ sessions: [ImportedSession], into folderID: UUID?, keepFolders: Bool) -> SessionImportReport {
        var report = SessionImportReport(added: [], createdFolders: [], skippedDuplicates: 0)
        apply { report = SessionImportMerge.merge(sessions, into: &$0, folderID: folderID, keepFolders: keepFolders) }
        return report
    }
}
