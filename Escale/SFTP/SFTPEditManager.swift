import AppKit
import Foundation
import Observation
import EscaleCore

/// Choix de l'utilisateur quand le fichier distant a changé depuis le téléchargement.
enum SFTPConflictChoice { case overwrite, keepRemote }

/// Empreinte légère d'un fichier local (détecte une sauvegarde, en place ou par remplacement atomique).
private struct FileStamp: Equatable {
    var modified: Date
    var size: UInt64
    var inode: UInt64

    static func of(_ url: URL) -> FileStamp? {
        var st = Darwin.stat()
        guard stat(url.path, &st) == 0 else { return nil }
        let t = st.st_mtimespec
        return FileStamp(modified: Date(timeIntervalSince1970: Double(t.tv_sec) + Double(t.tv_nsec) / 1e9),
                         size: UInt64(st.st_size), inode: UInt64(st.st_ino))
    }
}

/// Une édition distante en cours : fichier temporaire local surveillé, renvoyé au serveur à chaque sauvegarde.
@MainActor
@Observable
final class SFTPEdit: Identifiable {
    enum State: Equatable {
        case watching
        case uploading
        /// Le distant a changé et l'utilisateur a gardé la version distante : « Renvoyer » force l'envoi.
        case conflict
        case failed(String)
        case stopped
    }

    let id = UUID()
    let session: SFTPHostSession
    let remote: Data
    let name: String
    let localURL: URL
    fileprivate(set) var state: State = .watching
    fileprivate(set) var uploads = 0
    fileprivate(set) var lastUpload: Date?

    fileprivate var baseSize: UInt64?
    fileprivate var baseModified: Date?
    fileprivate var knownStamp: FileStamp?
    @ObservationIgnored fileprivate var sources: [DispatchSourceFileSystemObject] = []
    @ObservationIgnored fileprivate var pollTask: Task<Void, Never>?
    @ObservationIgnored fileprivate var debounce: Task<Void, Never>?

    init(session: SFTPHostSession, remote: Data, name: String, localURL: URL) {
        self.session = session; self.remote = remote; self.name = name; self.localURL = localURL
    }

    var directory: URL { localURL.deletingLastPathComponent() }
}

/// Édition distante : « Ouvrir avec l'éditeur ». Téléchargement dans un dossier temporaire de l'app
/// (`~/Library/Caches/<bundle>/edit/…`), ouverture par l'application par défaut, surveillance du fichier,
/// renvoi à chaque sauvegarde avec détection de conflit.
@MainActor
@Observable
final class SFTPEditManager {
    private(set) var edits: [SFTPEdit] = []
    @ObservationIgnored unowned let feature: SFTPFeature
    /// Ouvre le fichier dans l'éditeur (remplaçable dans les tests : aucune application tierce lancée).
    @ObservationIgnored var opener: @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) }
    /// Demande quoi faire si le distant a changé depuis le téléchargement.
    @ObservationIgnored var resolveConflict: @MainActor (SFTPEdit) async -> SFTPConflictChoice = { edit in
        let alert = NSAlert()
        alert.messageText = String(localized: "« \(edit.name) » a changé sur le serveur")
        alert.informativeText = String(localized: "Le fichier distant a été modifié depuis son téléchargement. Écraser la version distante par votre version locale ?")
        alert.addButton(withTitle: String(localized: "Écraser le distant"))
        alert.addButton(withTitle: String(localized: "Garder le distant"))
        alert.alertStyle = .warning
        return alert.runModal() == .alertFirstButtonReturn ? .overwrite : .keepRemote
    }
    /// Délais (tests : plus courts).
    @ObservationIgnored var debounceDelay: Double = 0.4
    @ObservationIgnored var pollInterval: Double = 1.0

    init(feature: SFTPFeature) { self.feature = feature }

    var root: URL { feature.cachesRoot.appendingPathComponent("edit", isDirectory: true) }

    /// Télécharge puis ouvre. Si le fichier est déjà en édition, le rouvre simplement.
    @discardableResult
    func edit(_ item: SFTPItem, in session: SFTPHostSession) async throws -> SFTPEdit {
        if let e = edits.first(where: { $0.session === session && $0.remote == item.path && $0.state != .stopped }) {
            opener(e.localURL)
            return e
        }
        guard let client = session.client else { throw SFTPError.channelClosed(String(localized: "canal SFTP non ouvert")) }
        let dir = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let local = dir.appendingPathComponent(item.name)
        let attrs = try await client.attributes(of: item.path)
        try await client.download(item.path, to: local)
        let e = SFTPEdit(session: session, remote: item.path, name: item.name, localURL: local)
        e.baseSize = attrs.size
        e.baseModified = attrs.modificationTime
        e.knownStamp = FileStamp.of(local)
        edits.append(e)
        watch(e)
        opener(local)
        return e
    }

    func stop(_ e: SFTPEdit) {
        e.state = .stopped
        e.pollTask?.cancel(); e.debounce?.cancel()
        for s in e.sources { s.cancel() }
        e.sources.removeAll()
        try? FileManager.default.removeItem(at: e.directory)
        edits.removeAll { $0.id == e.id }
    }

    func stopAll() { for e in edits { stop(e) } }

    /// Envoi forcé (après un conflit gardé côté distant, ou un échec).
    func resend(_ e: SFTPEdit) { Task { await sync(e, force: true) } }

    // MARK: Surveillance

    private func watch(_ e: SFTPEdit) {
        arm(e)
        e.pollTask = Task { @MainActor [weak self, weak e] in
            // Filet de sécurité : certains éditeurs remplacent le fichier d'une façon qui échappe aux sources.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64((self?.pollInterval ?? 1) * 1e9))
                guard let self, let e, e.state != .stopped else { return }
                if FileStamp.of(e.localURL) != e.knownStamp { self.scheduleSync(e) }
            }
        }
    }

    /// (Re)crée les sources sur le dossier et sur le fichier : une sauvegarde en place touche le fichier,
    /// un remplacement atomique (TextEdit, vim…) touche le dossier et change l'inode.
    private func arm(_ e: SFTPEdit) {
        for s in e.sources { s.cancel() }
        e.sources.removeAll()
        for (path, mask) in [(e.directory.path, DispatchSource.FileSystemEvent([.write, .rename, .delete])),
                             (e.localURL.path, DispatchSource.FileSystemEvent([.write, .extend, .attrib, .rename, .delete]))] {
            let fd = open(path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: mask, queue: .main)
            src.setEventHandler { [weak self, weak e] in
                Task { @MainActor in
                    guard let self, let e, e.state != .stopped else { return }
                    self.scheduleSync(e)
                    // Fichier remplacé : l'ancien descripteur ne suit plus rien, on se réarme.
                    if src.data.contains(.rename) || src.data.contains(.delete) {
                        try? await Task.sleep(nanoseconds: 150_000_000)
                        if e.state != .stopped { self.arm(e) }
                    }
                }
            }
            src.setCancelHandler { close(fd) }
            src.resume()
            e.sources.append(src)
        }
    }

    private func scheduleSync(_ e: SFTPEdit) {
        e.debounce?.cancel()
        e.debounce = Task { @MainActor [weak self, weak e] in
            try? await Task.sleep(nanoseconds: UInt64((self?.debounceDelay ?? 0.4) * 1e9))
            guard !Task.isCancelled, let self, let e else { return }
            // L'envoi tourne dans sa propre tâche : un nouvel événement (réarmement, autre sauvegarde) annule
            // seulement l'attente, jamais un transfert en cours.
            Task { @MainActor in await self.sync(e, force: false) }
        }
    }

    /// Renvoie le fichier si son contenu local a changé depuis le dernier envoi.
    private func sync(_ e: SFTPEdit, force: Bool) async {
        guard e.state != .stopped, e.state != .uploading else { return }
        guard var stamp = FileStamp.of(e.localURL) else { return }
        if !force, stamp == e.knownStamp { return }
        // Sauvegarde en cours d'écriture : on attend que l'empreinte soit stable.
        try? await Task.sleep(nanoseconds: 200_000_000)
        if let again = FileStamp.of(e.localURL) {
            if again != stamp { stamp = again }
        }
        e.state = .uploading
        defer { if e.state == .uploading { e.state = .watching } }
        do {
            guard let client = e.session.client else { throw SFTPError.channelClosed(String(localized: "canal SFTP non ouvert")) }
            if !force, let remote = try? await client.attributes(of: e.remote),
               remote.modificationTime != e.baseModified || remote.size != e.baseSize {
                if await resolveConflict(e) == .keepRemote {
                    e.knownStamp = stamp
                    e.state = .conflict
                    return
                }
            }
            try await client.upload(e.localURL, to: e.remote)
            let after = try? await client.attributes(of: e.remote)
            e.baseSize = after?.size
            e.baseModified = after?.modificationTime
            e.knownStamp = stamp
            e.uploads += 1
            e.lastUpload = Date()
            e.state = .watching
        } catch {
            e.knownStamp = stamp // pas de boucle d'échecs : une nouvelle sauvegarde ou « Renvoyer » relance
            if SFTPMessages.isChannelLoss(error) { e.session.channelLost() }
            e.state = .failed(SFTPMessages.describe(error))
        }
        // Une autre sauvegarde est arrivée pendant l'envoi.
        if let now = FileStamp.of(e.localURL), now != e.knownStamp, e.state == .watching { scheduleSync(e) }
    }
}
