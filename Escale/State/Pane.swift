import Foundation
import Observation
import EscaleCore

/// Un panneau : une feuille de l'arbre d'un onglet. Un moteur de terminal (via `session`) et le
/// processus pty courant ; c'est lui qui porte l'état de connexion, le bandeau et la reconnexion.
@MainActor
@Observable
final class Pane: Identifiable {
    enum Kind: Equatable {
        case local(command: [String]?)
        case host(HostProfile)
    }
    enum Status: Equatable {
        case connecting
        case running
        case reconnecting
        case ended(PTYExitStatus)
        case failed(String)

        /// Gravité croissante, pour « pire état » d'un onglet.
        var severity: Int {
            switch self {
            case .running: 0
            case .ended: 1
            case .connecting: 2
            case .reconnecting: 3
            case .failed: 4
            }
        }
    }

    let id = UUID()
    let kind: Kind
    let baseTitle: String
    let session: TerminalSession
    var status: Status = .connecting
    /// Connexion maître qui porte ce shell (panneaux SSH uniquement).
    var link: SSHLink?
    var isClosing = false
    /// Époque de la connexion au lancement du shell courant (voir `SSHLink.epoch`).
    @ObservationIgnored var launchEpoch = 0
    @ObservationIgnored var startTask: Task<Void, Never>?

    init(kind: Kind, baseTitle: String, session: TerminalSession = TerminalSession()) {
        self.kind = kind; self.baseTitle = baseTitle; self.session = session
        session.engine.accessibilityLabel = String(localized: "Terminal — \(baseTitle)")
    }

    var hostID: UUID? { if case .host(let h) = kind { h.id } else { nil } }
    var isRemote: Bool { hostID != nil }
    var displayTitle: String { session.title.isEmpty ? baseTitle : session.title }

    /// Message du bandeau non modal ; nil quand le panneau fonctionne normalement.
    var bannerMessage: String? {
        switch status {
        case .running: return nil
        case .connecting: return String(localized: "Connexion à \(baseTitle)…")
        case .failed(let m): return String(localized: "Échec de la connexion : \(m)")
        case .ended: return session.statusText
        case .reconnecting:
            if case .reconnecting(let attempt, let retryIn)? = link?.state {
                if let s = retryIn { return String(localized: "Connexion perdue — nouvelle tentative dans \(s) s") }
                return String(localized: "Connexion perdue — reconnexion en cours (tentative \(attempt))…")
            }
            return String(localized: "Connexion perdue — reconnexion…")
        }
    }
}
