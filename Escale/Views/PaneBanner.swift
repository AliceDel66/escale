import SwiftUI

/// Bandeau d'état d'un panneau : barre fine HORS de la grille du terminal (au-dessus du moteur),
/// jamais superposée au texte. Hauteur fixée par `PaneHostView` selon la seule largeur (le texte change
/// chaque seconde pendant le décompte : la grille ne doit pas être retaillée pour autant).
struct PaneBanner: View {
    /// Hauteur en mode large (une ligne) et en mode compact (message sur deux lignes, boutons dessous).
    static let height: CGFloat = 32
    static let compactHeight: CGFloat = 70
    /// En dessous de cette largeur de panneau, le bandeau passe en mode compact (message de reconnexion,
    /// « Reconnecter » et « Fermer le panneau » tiennent sur une ligne au-delà).
    static let compactWidth: CGFloat = 560
    static func height(forWidth width: CGFloat) -> CGFloat { width < compactWidth ? compactHeight : height }

    let model: AppModel
    let pane: Pane

    var body: some View {
        GeometryReader { geo in
            StatusBanner(tone: tone, icon: icon, title: pane.bannerMessage ?? "", detail: detail,
                         layout: geo.size.width < Self.compactWidth ? .compact : .wide, fillsHeight: true) {
                actions
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .environment(\.locale, model.settings.effectiveLocale)
    }

    /// Dernière erreur du lien pendant la reconnexion.
    private var detail: String? {
        if case .reconnecting = pane.status { return pane.link?.lastError }
        return nil
    }

    private var tone: BannerTone {
        switch pane.status {
        case .connecting: .info
        case .reconnecting: .warning
        case .failed: .error
        case .ended, .running: .neutral
        }
    }

    private var icon: BannerIcon? {
        switch pane.status {
        case .connecting: .progress
        case .reconnecting: .symbol("wifi.exclamationmark")
        case .failed: .symbol("exclamationmark.triangle.fill")
        case .ended: .symbol("info.circle")
        case .running: nil
        }
    }

    /// Secondaire puis principal (le principal termine la rangée, convention macOS).
    @ViewBuilder private var actions: some View {
        if pane.status == .connecting {
            Button("Annuler") { model.closePane(pane) }.buttonStyle(.bannerSecondary)
        } else {
            Button("Fermer le panneau") { model.closePane(pane) }.buttonStyle(.bannerSecondary)
            switch pane.status {
            case .reconnecting:
                Button("Reconnecter") { model.retry(pane) }.buttonStyle(.bannerPrimary)
                    .help("Reconnecter maintenant sans attendre le décompte")
            case .failed: Button("Réessayer") { model.retry(pane) }.buttonStyle(.bannerPrimary)
            case .ended: Button("Relancer") { model.retry(pane) }.buttonStyle(.bannerPrimary)
            default: EmptyView()
            }
        }
    }
}
