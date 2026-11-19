import Foundation
import Observation
import EscaleCore

/// Un transfert (un fichier) de la file : envoi ou réception.
@MainActor
@Observable
final class SFTPTransfer: Identifiable {
    enum Direction { case upload, download, relay }
    enum State: Equatable { case queued, running, done, failed(String), cancelled }

    let id = UUID()
    let direction: Direction
    let name: String
    let local: URL
    let remote: Data
    /// Hôte de destination (envoi, réception : l'hôte du transfert ; relais : l'hôte qui reçoit).
    let session: SFTPHostSession
    /// Relais d'un hôte à l'autre : hôte et chemin d'origine (nil sinon).
    let source: SFTPHostSession?
    let sourcePath: Data?

    private(set) var state: State = .queued
    private(set) var bytes: UInt64 = 0
    private(set) var total: UInt64?
    /// Débit lissé en octets par seconde (0 hors transfert).
    private(set) var speed: Double = 0
    private(set) var attempts = 0
    /// Offset de reprise de la tentative courante (0 = départ de zéro) ; sert à afficher « repris à X % ».
    private(set) var resumedFrom: UInt64 = 0
    /// Reprise demandée mais refusée (début différent…) : la raison, pour l'afficher.
    private(set) var restartReason: String?
    /// Interrompu par une perte de lien : repart tout seul à la reconnexion.
    private(set) var interrupted = false
    fileprivate(set) var autoResumes = 0
    var autoResumeCount: Int { autoResumes }
    @ObservationIgnored private var awaitingFirstSnapshot = true

    /// « repris à 42 % » (nil si la tentative est repartie de zéro).
    var resumeText: String? {
        guard resumedFrom > 0 else { return nil }
        guard let t = total, t > 0 else { return String(localized: "repris à \(SFTPFormat.size(resumedFrom))") }
        let pct = min(100, Int((Double(resumedFrom) / Double(t) * 100).rounded()))
        return String(localized: "repris à \(pct) %")
    }

    @ObservationIgnored fileprivate var task: Task<Void, Never>?
    @ObservationIgnored private var sampleDate = Date()
    @ObservationIgnored private var sampleBytes: UInt64 = 0

    init(direction: Direction, name: String, local: URL, remote: Data, session: SFTPHostSession) {
        self.direction = direction; self.name = name; self.local = local; self.remote = remote; self.session = session
        self.source = nil; self.sourcePath = nil
    }

    /// Copie d'un fichier de l'hôte `source` vers l'hôte `session`, en flux (rien n'est écrit sur le disque local).
    init(relayFrom source: SFTPHostSession, path sourcePath: Data, name: String, to remote: Data, on session: SFTPHostSession) {
        self.direction = .relay; self.name = name; self.local = URL(fileURLWithPath: "/dev/null")
        self.remote = remote; self.session = session; self.source = source; self.sourcePath = sourcePath
    }

    var fraction: Double? {
        guard let t = total, t > 0 else { return state == .done ? 1 : nil }
        return min(1, Double(bytes) / Double(t))
    }
    var isFinished: Bool {
        switch state { case .done, .failed, .cancelled: true; default: false }
    }

    fileprivate func begin() {
        state = .running; attempts += 1
        bytes = 0; speed = 0; resumedFrom = 0; restartReason = nil; interrupted = false
        awaitingFirstSnapshot = true
        sampleDate = Date(); sampleBytes = 0
    }

    /// Le cœur émet d'abord un instantané à l'offset de reprise : c'est lui qui donne « repris à X % ».
    fileprivate func update(_ s: SFTPTransferSnapshot) {
        guard state == .running else { return }
        if awaitingFirstSnapshot {
            awaitingFirstSnapshot = false
            if attempts > 1 { resumedFrom = s.bytesTransferred }
        }
        bytes = s.bytesTransferred
        if let t = s.totalBytes { total = t }
        speed = s.bytesPerSecond
    }

    fileprivate func noteOutcome(_ o: SFTPTransferOutcome) {
        resumedFrom = o.resumedFrom
        restartReason = o.restartReason
        total = o.totalBytes
    }

    /// Progression d'un relais (pas d'instantané du cœur : débit lissé calculé ici).
    fileprivate func relayProgress(bytes b: UInt64, total t: UInt64) {
        guard state == .running else { return }
        let now = Date(), dt = now.timeIntervalSince(sampleDate)
        if dt >= 0.5 {
            let inst = b >= sampleBytes ? Double(b - sampleBytes) / dt : 0
            speed = speed == 0 ? inst : speed * 0.6 + inst * 0.4
            sampleDate = now; sampleBytes = b
        }
        bytes = b; total = t
    }

    fileprivate func markInterrupted() { interrupted = true }
    fileprivate func countAutoResume() { autoResumes += 1; interrupted = false }

    fileprivate func finish(_ s: State) {
        state = s; speed = 0
        if s == .done, let t = total { bytes = t }
    }

    fileprivate func resetForRetry() { state = .queued; bytes = 0; speed = 0; interrupted = false }
}

/// File de transferts commune à tous les hôtes : au plus `maxConcurrent` transferts simultanés,
/// les autres attendent. Annulation et nouvelle tentative par transfert.
@MainActor
@Observable
final class SFTPTransferQueue {
    private(set) var items: [SFTPTransfer] = []
    @ObservationIgnored var maxConcurrent = 3

    var activeCount: Int { items.filter { $0.state == .running || $0.state == .queued }.count }
    var failedCount: Int { items.filter { if case .failed = $0.state { true } else { false } }.count }
    var hasFinished: Bool { items.contains { $0.isFinished } }

    func enqueue(_ t: SFTPTransfer) {
        items.append(t)
        pump()
    }

    private func pump() {
        var running = items.filter { $0.state == .running }.count
        for t in items where t.state == .queued && running < maxConcurrent {
            running += 1
            start(t)
        }
    }

    private func start(_ t: SFTPTransfer) {
        t.begin()
        t.task = Task { @MainActor [weak self] in
            await self?.run(t)
        }
    }

    private func run(_ t: SFTPTransfer) async {
        let client = t.session.client
        let relaySource = t.source
        do {
            try await perform(t)
            t.finish(.done)
        } catch {
            var cancelled = Task.isCancelled
            if case SFTPError.cancelled = error { cancelled = true }
            if cancelled {
                // Annulation voulue : on ne laisse pas de fichier partiel (ni local, ni distant).
                if t.direction == .download { try? FileManager.default.removeItem(at: t.local) }
                else if let client { await client.discardPartialUpload(at: t.remote) }
                t.finish(.cancelled)
            } else {
                // Échec : les octets déjà transférés restent en place, « Réessayer » reprend après vérification.
                if SFTPMessages.isChannelLoss(error) {
                    t.markInterrupted()
                    // Relais : la perte peut venir de l'un ou l'autre hôte ; on prévient celui dont le canal est mort.
                    if let src = relaySource, src.state != .ready { src.channelLost() }
                    if t.session.state != .ready || relaySource == nil { t.session.channelLost() }
                }
                t.finish(.failed(SFTPMessages.describe(error)))
            }
        }
        t.task = nil
        t.session.transferFinished(t)
        pump()
    }

    /// Reprise vérifiée du cœur dès la deuxième tentative (« Réessayer », reprise après coupure) ; première tentative
    /// toujours complète, pour ne jamais « reprendre » un fichier distant qu'on a choisi de remplacer.
    private func perform(_ t: SFTPTransfer) async throws {
        guard let client = t.session.client else { throw SFTPError.channelClosed(String(localized: "canal SFTP non ouvert")) }
        if t.direction == .relay { try await relay(t, to: client); return }
        let resume = t.attempts > 1
        let task: SFTPTransferTask = switch t.direction {
        case .download: client.startDownload(remotePath: t.remote, to: t.local, resume: resume, verification: .default)
        case .upload: client.startUpload(localURL: t.local, to: t.remote, resume: resume, verification: .default)
        case .relay: throw SFTPError.localIO(String(localized: "relais traité à part"))
        }
        let pump = Task { @MainActor [weak t] in for await s in task.progress { t?.update(s) } }
        defer { pump.cancel() }
        let outcome = try await withTaskCancellationHandler { try await task.outcome } onCancel: { task.cancel() }
        t.noteOutcome(outcome)
    }

    /// Taille des blocs d'un relais : lecture du bloc suivant pendant l'écriture du courant (deux blocs en mémoire au plus).
    static let relayBlock = 1 << 20

    /// Lecture SFTP/shell de l'hôte A puis écriture vers l'hôte B, bloc par bloc. Une nouvelle tentative repart de zéro
    /// (le fichier de destination est tronqué) ; l'annulation est testée à chaque bloc.
    private func relay(_ t: SFTPTransfer, to dest: any RemoteFileSystem) async throws {
        guard let src = t.source?.client, let from = t.sourcePath else { throw SFTPError.channelClosed(String(localized: "canal SFTP source non ouvert")) }
        let total = try await src.attributes(of: from).size ?? 0
        t.relayProgress(bytes: 0, total: total)
        var offset: UInt64 = 0
        var truncate = true
        var pending: Task<Data, Error>? = total > 0 ? Task { try await src.readBlock(from, offset: 0, length: Self.relayBlock) } : nil
        var wrote = false
        defer { pending?.cancel() }
        do {
            if total == 0 { wrote = true; try await dest.writeBlock(t.remote, offset: 0, data: Data(), truncate: true) }
            while let task = pending {
                let block = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
                try Task.checkCancellation()
                guard !block.isEmpty else { pending = nil; break }
                let next = offset + UInt64(block.count)
                pending = next < total ? Task { try await src.readBlock(from, offset: next, length: Self.relayBlock) } : nil
                wrote = true
                try await dest.writeBlock(t.remote, offset: offset, data: block, truncate: truncate)
                truncate = false
                offset = next
                t.relayProgress(bytes: offset, total: total)
            }
            if offset != total { throw SFTPError.localIO(String(localized: "fichier source modifié pendant la copie (\(offset) sur \(total) octets lus)")) }
        } catch {
            // Un relais ne reprend pas : le fichier partiel ne sert à rien. Suppression hors de la tâche (déjà annulée
            // en cas d'annulation, ce qui couperait aussi la commande de nettoyage en mode shell).
            // La lecture d'avance est attendue : sa commande exec (mode shell) doit être refermée avant de rendre la main,
            // sinon `sessionCount` du maître garde une session fantôme un instant.
            pending?.cancel()
            _ = await pending?.result
            pending = nil
            if wrote { await Task { try? await dest.removeFile(t.remote) }.value }
            throw error
        }
    }

    /// Le canal d'un hôte est de retour : les transferts coupés par la perte du lien repartent (cinq fois au plus).
    func resumeInterrupted(for session: SFTPHostSession) {
        for t in items where (t.session === session || t.source === session) && t.interrupted && t.isFinished && t.autoResumes < 5 {
            t.countAutoResume()
            t.resetForRetry()
        }
        pump()
    }

    func cancel(_ t: SFTPTransfer) {
        switch t.state {
        case .queued: t.finish(.cancelled)
        case .running: t.task?.cancel()
        default: break
        }
    }

    func cancelAll() {
        for t in items { cancel(t) }
    }

    func retry(_ t: SFTPTransfer) {
        switch t.state {
        case .failed, .cancelled:
            t.resetForRetry()
            pump()
        default: break
        }
    }

    func clearFinished() { items.removeAll { $0.isFinished } }

    /// Attend la fin de tous les transferts (tests).
    func waitIdle(timeout: Double) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if items.allSatisfy({ $0.isFinished }) { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return items.allSatisfy { $0.isFinished }
    }
}
