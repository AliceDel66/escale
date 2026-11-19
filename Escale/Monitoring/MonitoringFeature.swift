import SwiftUI
import AppKit
import Observation
import EscaleCore

/// Monitoring distant : barre fine sous un panneau de terminal SSH (charge, CPU, mémoire, disque, débit réseau,
/// utilisateurs, uptime).
///
/// - Désactivé par défaut. Réglage MÉMORISÉ PAR HÔTE (`UserDefaults`, identifiants d'hôtes) : la barre est un
///   attribut de l'hôte, elle suit donc ses nouveaux panneaux et ses reconnexions. L'ouverture de la session
///   exec découle toujours d'un choix explicite de l'utilisateur (commande de menu, entrée du menu d'hôte ou
///   bouton de la barre) : invariant 12.
/// - UNE session exec longue par panneau surveillé (`OpenSSHTransport.openShellStream` → `batchStreamArguments` :
///   mêmes options que `batchExecArguments`, BatchMode, sans X11, stdin ouvert ; invariant 13). Le transport la
///   compte dans `sessionCount` jusqu'à la fin du processus ; l'arrêt (`stop`) tue ssh, ce qui rend la place.
/// - Maître plein (MaxSessions, invariant 5) : rien n'est ouvert, la barre l'indique discrètement.
@MainActor
@Observable
final class MonitoringFeature: AppFeature {
    static let observerKey = "monitoring"
    static let defaultsKey = "escale.monitoring.hosts"

    enum Phase: Equatable {
        case starting
        case running
        /// Connexion perdue, relance en attente.
        case waiting
        /// Système distant ni Linux ni macOS, ou script sans réponse exploitable.
        case unsupported
        /// Plafond de sessions du maître atteint.
        case busy
        case failed(String)
    }

    @MainActor @Observable
    final class Monitor {
        let paneID: UUID
        let hostID: UUID
        var phase: Phase = .starting
        var snapshot: MonitoringSnapshot?
        /// Relevés reçus depuis le démarrage (tests).
        var samples = 0
        @ObservationIgnored var task: Task<Void, Never>?
        @ObservationIgnored var stream: RemoteExecStream?
        init(paneID: UUID, hostID: UUID) { self.paneID = paneID; self.hostID = hostID }
    }

    @ObservationIgnored private(set) weak var model: AppModel?
    private(set) var monitors: [UUID: Monitor] = [:]
    /// Hôtes dont la barre est demandée.
    private(set) var hosts: Set<UUID> = []
    /// Stockage du réglage ; `nil` : en mémoire seulement (auto-test).
    @ObservationIgnored var defaults: UserDefaults? = .standard
    @ObservationIgnored private var sweepTimer: Timer?

    func attach(_ model: AppModel) {
        self.model = model
        if let ids = defaults?.stringArray(forKey: Self.defaultsKey) { hosts = Set(ids.compactMap(UUID.init(uuidString:))) }
        sweepTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcile() }
        }
    }

    func shutdown() async {
        sweepTimer?.invalidate(); sweepTimer = nil
        let all = Array(monitors.values)
        for id in Array(monitors.keys) { stop(paneID: id) }
        for m in all { await m.task?.value }
    }

    // MARK: Réglage par hôte

    func isEnabled(host id: UUID) -> Bool { hosts.contains(id) }

    func setEnabled(_ on: Bool, host id: UUID) {
        if on { hosts.insert(id) } else { hosts.remove(id) }
        defaults?.set(hosts.map(\.uuidString).sorted(), forKey: Self.defaultsKey)
        reconcile()
    }

    func toggle(host id: UUID) { setEnabled(!isEnabled(host: id), host: id) }

    /// Panneau SSH actif de l'onglet courant, s'il peut être surveillé (commande de menu).
    var activeSSHPane: Pane? {
        guard let p = model?.workspace.activeTab?.activePane, case .host(let h) = p.kind, h.connectionProtocol == .ssh else { return nil }
        return p
    }
    var activeHostID: UUID? { activeSSHPane?.hostID }

    // MARK: Cycle de vie

    /// Aligne les moniteurs sur les réglages et les panneaux : démarre pour les panneaux SSH en service des hôtes
    /// demandés, arrête pour les panneaux fermés, terminés ou dont l'hôte n'est plus demandé.
    func reconcile() {
        guard let model else { return }
        let panes = model.workspace.tabs.flatMap(\.panes)
        let byID = Dictionary(panes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for (id, m) in monitors {
            guard let p = byID[id], !p.isClosing, hosts.contains(m.hostID) else { stop(paneID: id); continue }
            switch p.status {
            case .ended, .failed: stop(paneID: id)
            default: break
            }
        }
        guard !hosts.isEmpty else { return }
        for p in panes where monitors[p.id] == nil && !p.isClosing && p.status == .running {
            if case .host(let h) = p.kind, h.connectionProtocol == .ssh, hosts.contains(h.id), p.link != nil { start(p, host: h) }
        }
    }

    private func start(_ pane: Pane, host: HostProfile) {
        let m = Monitor(paneID: pane.id, hostID: host.id)
        monitors[pane.id] = m
        m.task = Task { [weak self] in await self?.run(m, pane: pane) }
    }

    /// Arrête le moniteur d'un panneau : tue le ssh de la session exec, ce qui rend la place sur le maître.
    func stop(paneID: UUID) {
        guard let m = monitors.removeValue(forKey: paneID) else { return }
        m.task?.cancel()
        m.stream?.cancel()
    }

    /// Boucle d'un panneau : ouvre le flux, lit les blocs, relance après une coupure (le maître se reconnecte
    /// de lui-même). Fin définitive : système non pris en charge, maître plein, deux flux sans aucun relevé.
    private func run(_ m: Monitor, pane: Pane) async {
        var failures = 0
        while !Task.isCancelled {
            guard let link = pane.link else { m.phase = .failed(String(localized: "connexion absente")); break }
            if case .reconnecting = link.state {
                m.phase = .waiting
                if !(await link.waitReconnect()) { m.phase = .failed(String(localized: "connexion perdue")); break }
                continue
            }
            guard link.state == .connected else { m.phase = .failed(String(localized: "connexion indisponible")); break }
            let stream: RemoteExecStream
            do {
                stream = try await link.transport.openShellStream(MonitoringScript.remoteCommand())
            } catch SSHTransportError.sessionRefused {
                m.phase = .busy; break
            } catch SSHTransportError.notConnected {
                failures += 1
                if failures >= 3 { m.phase = .failed(String(localized: "connexion indisponible")); break }
                m.phase = .waiting
                try? await Task.sleep(for: .seconds(2))
                continue
            } catch {
                m.phase = .failed(SSHLink.describe(error)); break
            }
            if Task.isCancelled { stream.cancel(); _ = await stream.finish(timeout: 3); break }
            m.stream = stream
            var parser = MonitoringStreamParser()
            var calc = MonitoringCalculator()
            var got = false, unsupported = false
            readLoop: while true {
                let data: Data
                do { data = try await stream.read(maxBytes: 16 * 1024) } catch { break }
                if data.isEmpty { break }
                for e in parser.feed(data, now: ProcessInfo.processInfo.systemUptime) {
                    switch e {
                    case .sample(let s):
                        got = true; m.samples += 1
                        m.snapshot = calc.ingest(s)
                        m.phase = .running
                    case .unsupported:
                        unsupported = true; break readLoop
                    }
                }
            }
            stream.cancel()
            _ = await stream.finish(timeout: 3)
            m.stream = nil
            if Task.isCancelled { break }
            if unsupported { m.phase = .unsupported; break }
            failures = got ? 0 : failures + 1
            if failures >= 2 { m.phase = .unsupported; break }
            m.phase = .waiting
            try? await Task.sleep(for: .seconds(3))
        }
    }

    // MARK: Accès pour l'interface et les tests

    func monitor(for paneID: UUID) -> Monitor? { monitors[paneID] }
    var monitorIDs: Set<UUID> { Set(monitors.keys) }
}
