import AppKit
import SwiftUI
import Observation
import EscaleCore

/// M3 : gestionnaire de tunnels L/R/D (ouverture, état, rétablissement après reconnexion).
///
/// Un hôte dont au moins un tunnel est voulu (démarré à la main ou `autoStart`) garde son lien maître « retenu »
/// (`tabCount`) : fermer le dernier onglet ne coupe donc pas les tunnels. Le lien est relâché quand plus aucun tunnel
/// n'est voulu, ou quand la connexion est coupée volontairement (`.disconnected`).
@MainActor
@Observable
final class TunnelFeature: AppFeature {
    /// Identifiant de feuille déclaré dans `AppModel.activeFeatureSheet`.
    static let sheetID = "tunnels"

    /// Contexte d'un hôte : le lien qui porte ses tunnels, le contrôleur du cœur et les tunnels voulus.
    @MainActor
    final class HostContext {
        let hostID: UUID
        let link: SSHLink
        let controller: TunnelController
        var wanted: Set<UUID> = []
        init(hostID: UUID, link: SSHLink) {
            self.hostID = hostID; self.link = link
            controller = TunnelController(transport: link.transport)
        }
    }

    @ObservationIgnored private(set) weak var model: AppModel?
    /// État de chaque tunnel connu (clé : identifiant du tunnel). Absent = arrêté.
    private(set) var states: [UUID: TunnelState] = [:]
    /// Port attribué par le serveur à un tunnel `-R 0` ouvert (clé : identifiant du tunnel).
    private(set) var allocatedPorts: [UUID: Int] = [:]
    /// Dernière modification de tunnel actif refusée (le tunnel d'avant reste ouvert) ; effacée au prochain succès ou arrêt.
    private(set) var editErrors: [UUID: String] = [:]
    var isManagerPresented = false
    /// Hôte mis en avant par « Tunnels… » du menu d'hôte (nil : tous les hôtes).
    var focusedHostID: UUID?

    @ObservationIgnored private var contexts: [UUID: HostContext] = [:]
    @ObservationIgnored private var watchdog: Task<Void, Never>?
    @ObservationIgnored private var isShutDown = false
    /// Période de la surveillance du maître (tests : plus courte).
    @ObservationIgnored var watchInterval: Duration = .seconds(3)

    func attach(_ model: AppModel) {
        self.model = model
        model.connections.linkObservers["tunnels"] = { [weak self] link, event in self?.linkEvent(link, event) }
    }

    func shutdown() async {
        isShutDown = true
        watchdog?.cancel(); watchdog = nil
        model?.connections.linkObservers["tunnels"] = nil
    }

    func state(of id: UUID) -> TunnelState { states[id] ?? .stopped }

    // MARK: Fenêtre

    func show(host: UUID? = nil) {
        focusedHostID = host
        isManagerPresented = true
    }

    // MARK: Démarrer / arrêter

    /// Ouvre un tunnel (connecte l'hôte au besoin). Retourne quand l'état est final (`active` ou `failed`).
    @discardableResult
    func start(_ spec: TunnelSpec, on host: HostProfile) async -> TunnelState {
        guard let model, !isShutDown else { return .stopped }
        if state(of: spec.id) == .opening { return .opening }
        states[spec.id] = .opening
        let ctx: HostContext
        if let c = contexts[host.id] { ctx = c } else {
            let conn = model.connections.connection(for: host)
            // `acquireLink` retient le lien (tabCount + 1) : il survit à la fermeture du dernier onglet.
            ctx = HostContext(hostID: host.id, link: conn.acquireLink())
            contexts[host.id] = ctx
        }
        ctx.wanted.insert(spec.id)
        do {
            try await ctx.link.ensureConnected()
        } catch {
            ctx.wanted.remove(spec.id)
            releaseIfIdle(ctx)
            states[spec.id] = .failed(String(localized: "Connexion impossible : \(ctx.link.message(for: error))"))
            return state(of: spec.id)
        }
        startWatchdog()
        var result = await ctx.controller.start(spec)
        // Une réouverture déclenchée par la connexion peut déjà ouvrir ce tunnel : on attend son résultat.
        var waited = 0
        while result == .opening, waited < 400 { try? await Task.sleep(for: .milliseconds(50)); waited += 1; result = await ctx.controller.state(of: spec.id) }
        states[spec.id] = result
        await refreshAllocatedPort(spec.id, ctx)
        editErrors[spec.id] = nil
        if case .failed = result { ctx.wanted.remove(spec.id); releaseIfIdle(ctx) }
        return result
    }

    /// Modification d'un tunnel actif (appelée à l'enregistrement de la fiche d'hôte) : annule l'ancien, ouvre le nouveau ;
    /// si le nouveau échoue, l'ancien est rétabli et l'erreur est affichée dans le gestionnaire (`editErrors`).
    /// Les tunnels supprimés de l'hôte pendant qu'ils tournent sont fermés.
    func hostSaved(oldTunnels: [TunnelSpec], host: HostProfile) {
        guard !isShutDown, let ctx = contexts[host.id] else { return }
        let kept = Set(host.tunnels.map(\.id))
        let removed = oldTunnels.filter { !kept.contains($0.id) && state(of: $0.id) != .stopped }
        let changed = host.tunnels.filter { t in
            state(of: t.id).isActive && (oldTunnels.first { $0.id == t.id }.map { !$0.sameForwarding(as: t) } ?? false)
        }
        guard !removed.isEmpty || !changed.isEmpty else { return }
        Task { [weak self] in
            for t in removed { await self?.stop(t, on: host) }
            for t in changed { await self?.applyEdit(t, ctx: ctx, host: host) }
        }
    }

    /// Remplace à chaud un tunnel actif par sa version modifiée. Renvoie le résultat (testable sans passer par la fiche).
    @discardableResult
    func applyEdit(_ spec: TunnelSpec, ctx: HostContext, host: HostProfile) async -> TunnelReplaceResult {
        states[spec.id] = .opening
        let r = await ctx.controller.replace(with: spec)
        states[spec.id] = r.state
        await refreshAllocatedPort(spec.id, ctx)
        if let e = r.error {
            editErrors[spec.id] = r.restored
                ? String(localized: "Modification non appliquée : \(e) L'ancien tunnel a été rétabli.")
                : String(localized: "Modification non appliquée : \(e)")
            if !r.state.isActive { ctx.wanted.remove(spec.id) }
            show(host: host.id) // l'erreur doit se voir
        } else { editErrors[spec.id] = nil }
        return r
    }

    /// Variante pour la recette et les appels directs : retrouve le contexte de l'hôte.
    @discardableResult
    func applyEdit(_ spec: TunnelSpec, on host: HostProfile) async -> TunnelReplaceResult? {
        guard let ctx = contexts[host.id] else { return nil }
        return await applyEdit(spec, ctx: ctx, host: host)
    }

    private func refreshAllocatedPort(_ id: UUID, _ ctx: HostContext) async {
        allocatedPorts[id] = await ctx.controller.allocatedPort(of: id)
    }

    /// Ferme un tunnel. Sans effet sur un tunnel arrêté.
    @discardableResult
    func stop(_ spec: TunnelSpec, on host: HostProfile) async -> TunnelState {
        guard let ctx = contexts[host.id] else { states[spec.id] = .stopped; return .stopped }
        ctx.wanted.remove(spec.id)
        let result = await ctx.controller.stop(spec.id)
        states[spec.id] = result
        allocatedPorts[spec.id] = nil; editErrors[spec.id] = nil
        releaseIfIdle(ctx)
        return result
    }

    func stopAll(on host: HostProfile) async {
        for t in host.tunnels where state(of: t.id) != .stopped { await stop(t, on: host) }
    }

    /// Relâche le lien quand plus aucun tunnel n'est voulu.
    private func releaseIfIdle(_ ctx: HostContext) {
        guard ctx.wanted.isEmpty, contexts[ctx.hostID] === ctx else { return }
        contexts[ctx.hostID] = nil
        ctx.link.release()
        if contexts.isEmpty { watchdog?.cancel(); watchdog = nil }
    }

    // MARK: Rétablissement

    private func linkEvent(_ link: SSHLink, _ event: ConnectionManager.LinkEvent) {
        guard !isShutDown, let model else { return }
        switch event {
        case .connected:
            if let ctx = contexts.values.first(where: { $0.link === link }) {
                reopen(ctx)
            } else if let host = model.library.host(link.profile.id),
                      host.tunnels.contains(where: \.autoStart),
                      model.connections.existing(host.id)?.links.first === link {
                // Hôte connecté par un onglet : ses tunnels `autoStart` s'ouvrent, et la connexion est retenue.
                link.tabCount += 1; link.cancelGrace()
                let ctx = HostContext(hostID: host.id, link: link)
                contexts[host.id] = ctx
                startWatchdog()
                reopen(ctx)
            }
        case .lost:
            guard let ctx = contexts.values.first(where: { $0.link === link }) else { return }
            markStopped(ctx)
        case .disconnected:
            guard let ctx = contexts.values.first(where: { $0.link === link }) else { return }
            markStopped(ctx)
            ctx.wanted.removeAll()
            contexts[ctx.hostID] = nil
            link.tabCount = max(0, link.tabCount - 1) // lien déjà coupé : pas de nouveau délai de grâce
            if contexts.isEmpty { watchdog?.cancel(); watchdog = nil }
        }
    }

    /// Tunnels d'un hôte (bibliothèque) à rouvrir : voulus, ou `autoStart`.
    private func specsToReopen(_ ctx: HostContext) -> [TunnelSpec] {
        guard let host = model?.library.host(ctx.hostID) else { return [] }
        let specs = host.tunnels.filter { ctx.wanted.contains($0.id) || $0.autoStart }
        for s in specs { ctx.wanted.insert(s.id) }
        return specs
    }

    private func markStopped(_ ctx: HostContext) {
        let ids = Set(model?.library.host(ctx.hostID)?.tunnels.map(\.id) ?? []).union(ctx.wanted)
        for id in ids where states[id] != nil { states[id] = .stopped }
        for id in ids { allocatedPorts[id] = nil }
        Task { await ctx.controller.connectionLost() }
    }

    private func reopen(_ ctx: HostContext) {
        let specs = specsToReopen(ctx)
        guard !specs.isEmpty else { return }
        for s in specs { states[s.id] = .opening }
        Task { [weak self] in
            for s in specs {
                let r = await ctx.controller.start(s)
                self?.states[s.id] = r
                await self?.refreshAllocatedPort(s.id, ctx)
                if case .failed = r { ctx.wanted.remove(s.id) }
            }
        }
    }

    // MARK: Surveillance

    /// Sans onglet pour s'en apercevoir, la mort du maître n'est détectée que par une sonde périodique.
    private func startWatchdog() {
        guard watchdog == nil else { return }
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: self?.watchInterval ?? .seconds(3))
                guard let self, !Task.isCancelled else { return }
                for ctx in Array(self.contexts.values) where ctx.link.state == .connected {
                    if await !ctx.link.transport.isAlive(), ctx.link.state == .connected { ctx.link.handleConnectionLost() }
                }
            }
        }
    }
}

// MARK: - Commandes, scène, menu d'hôte

struct TunnelCommands: Commands {
    let model: AppModel
    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Button("Tunnels…") { model.tunnels.show() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
        }
    }
}

struct TunnelScene: ViewModifier {
    let model: AppModel
    func body(content: Content) -> some View {
        content
            .sheet(isPresented: Binding(
                get: { model.tunnels.isManagerPresented },
                set: { model.tunnels.isManagerPresented = $0 })
            ) { TunnelManagerView(model: model) }
            .onChange(of: model.tunnels.isManagerPresented) { _, shown in
                if shown { model.activeFeatureSheet = TunnelFeature.sheetID }
                else if model.activeFeatureSheet == TunnelFeature.sheetID { model.activeFeatureSheet = nil }
            }
    }
}

struct TunnelHostMenuItems: View {
    let model: AppModel
    let host: HostProfile
    var body: some View {
        Button("Tunnels…") { model.tunnels.show(host: host.id) }
    }
}
