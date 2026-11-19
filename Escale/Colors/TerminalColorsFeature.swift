import SwiftUI
import EscaleCore

/// Couleurs du terminal : thème (palette ANSI, texte, fond, curseur, sélection) et surlignage de la sortie
/// (mots-clés d'état, adresses IPv4, URL ; voir `OutputHighlighter`), à la manière de MobaXterm.
///
/// - Thème : réglage général, appliqué à tous les panneaux ouverts et à chaque nouveau panneau AVANT son premier octet.
/// - Surlignage : réglage général, remplaçable par hôte (menu contextuel). Ne touche que l'affichage : le flux du
///   programme n'est modifié que par l'insertion de couleurs SGR (texte copié, accessibilité et journaux inchangés),
///   jamais sur l'écran alternatif ni sur du texte déjà coloré.
/// - Aucune session ni sonde : simple traitement local du flux déjà reçu (invariant 12).
/// - Préférences dans `UserDefaults` (identifiants de thème et d'hôtes seulement) ; la recette travaille en mémoire.
@MainActor
final class TerminalColorsFeature: ObservableObject, AppFeature {
    static let paneObserverKey = "colors"
    static let themeKey = "escale.terminal.theme"
    static let rulesKey = "escale.terminal.highlight"
    static let hostRulesKey = "escale.terminal.highlight.hosts"

    @Published private(set) var themeID: String = TerminalTheme.system.id
    /// Mots-clés par défaut, comme MobaXterm.
    @Published private(set) var rules: HighlightRuleSet = .keywords
    /// Réglage propre à un hôte (absent : réglage général).
    @Published private(set) var hostRules: [UUID: HighlightRuleSet] = [:]

    private weak var model: AppModel?
    /// Stockage des réglages ; `nil` : en mémoire seulement (recette).
    var defaults: UserDefaults? = .standard

    var theme: TerminalTheme { TerminalTheme.named(themeID) ?? .system }

    func attach(_ model: AppModel) {
        self.model = model
        if model.options.value("selftest-colors") != nil { defaults = nil }
        if let d = defaults {
            if let id = d.string(forKey: Self.themeKey), TerminalTheme.named(id) != nil { themeID = id }
            if let r = d.string(forKey: Self.rulesKey).flatMap(HighlightRuleSet.init(rawValue:)) { rules = r }
            if let dict = d.dictionary(forKey: Self.hostRulesKey) as? [String: String] {
                hostRules = Dictionary(uniqueKeysWithValues: dict.compactMap { k, v in
                    guard let id = UUID(uuidString: k), let r = HighlightRuleSet(rawValue: v) else { return nil }
                    return (id, r)
                })
            }
        }
        model.paneStartObservers[Self.paneObserverKey] = { [weak self] pane in self?.apply(to: pane) }
    }

    func shutdown() async {}

    // MARK: Réglages

    func setTheme(_ id: String) {
        guard TerminalTheme.named(id) != nil, id != themeID else { return }
        themeID = id
        defaults?.set(id, forKey: Self.themeKey)
        applyAll()
    }

    func setRules(_ r: HighlightRuleSet) {
        guard r != rules else { return }
        rules = r
        defaults?.set(r.rawValue, forKey: Self.rulesKey)
        applyAll()
    }

    /// Réglage d'un hôte ; `nil` : revient au réglage général.
    func setRules(_ r: HighlightRuleSet?, host id: UUID) {
        guard hostRules[id] != r else { return }
        hostRules[id] = r
        defaults?.set(Dictionary(uniqueKeysWithValues: hostRules.map { ($0.key.uuidString, $0.value.rawValue) }), forKey: Self.hostRulesKey)
        applyAll()
    }

    func effectiveRules(host id: UUID?) -> HighlightRuleSet { id.flatMap { hostRules[$0] } ?? rules }

    // MARK: Application

    func apply(to pane: Pane) {
        pane.session.engine.apply(theme: theme)
        pane.session.highlightRules = effectiveRules(host: pane.hostID)
    }

    /// Tous les panneaux ouverts, fenêtres détachées comprises.
    func applyAll() {
        guard let model else { return }
        for t in model.workspace.tabs { for p in t.panes { apply(to: p) } }
    }
}

// MARK: - Menus

/// Présentation › Thème du terminal / Coloration de la sortie.
struct TerminalColorsCommands: Commands {
    let model: AppModel
    var body: some Commands {
        CommandGroup(after: .sidebar) { TerminalColorsMenuItems(feature: model.colors) }
    }
}

private struct TerminalColorsMenuItems: View {
    @ObservedObject var feature: TerminalColorsFeature
    var body: some View {
        Divider()
        Menu("Thème du terminal") {
            Picker("Thème du terminal", selection: Binding(get: { feature.themeID }, set: { feature.setTheme($0) })) {
                ForEach(TerminalTheme.all) { Text($0.localizedNameKey).tag($0.id) }
            }
            .pickerStyle(.inline).labelsHidden()
        }
        Menu("Coloration de la sortie") {
            Picker("Coloration de la sortie", selection: Binding(get: { feature.rules }, set: { feature.setRules($0) })) {
                ForEach(HighlightRuleSet.allCases) { Text($0.localizedTitleKey).tag($0) }
            }
            .pickerStyle(.inline).labelsHidden()
        }
    }
}

/// Menu contextuel d'un hôte de terminal : coloration propre à l'hôte ou réglage général.
struct TerminalColorsHostMenuItems: View {
    @ObservedObject var feature: TerminalColorsFeature
    let host: HostProfile
    /// Valeur du sélecteur : `nil` encodé par la chaîne vide (réglage général).
    private var selection: Binding<String> {
        Binding(get: { feature.hostRules[host.id]?.rawValue ?? "" },
                set: { feature.setRules($0.isEmpty ? nil : HighlightRuleSet(rawValue: $0), host: host.id) })
    }
    var body: some View {
        Menu("Coloration de la sortie") {
            Picker("Coloration de la sortie", selection: selection) {
                Text("Réglage général (\(feature.rules.localizedTitle))").tag("")
                Divider()
                ForEach(HighlightRuleSet.allCases) { Text($0.localizedTitleKey).tag($0.rawValue) }
            }
            .pickerStyle(.inline).labelsHidden()
        }
    }
}
