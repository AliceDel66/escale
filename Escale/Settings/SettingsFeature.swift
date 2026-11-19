import AppKit
import Foundation
import Observation
import SwiftUI

/// Langue d'affichage de l'application (persistée dans `UserDefaults`, appliquée au démarrage et à chaud en SwiftUI).
enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system = "system"
    case zhHans = "zh-Hans"
    case en = "en"
    case fr = "fr"

    var id: String { rawValue }

    /// Libellé natif pour les langues explicites (`nil` pour `.system`, localisé via `Suivre le système`).
    var nativeDisplayName: String? {
        switch self {
        case .system: nil
        case .zhHans: "简体中文"
        case .en: "English"
        case .fr: "Français"
        }
    }

    /// Langues système macOS (domaine global, indépendant de l'override `AppleLanguages` de l'app).
    static func systemPreferredLanguages() -> [String] {
        if let langs = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleLanguages"] as? [String],
           !langs.isEmpty {
            return langs
        }
        return Locale.preferredLanguages
    }

    /// Code de langue effectivement pris en charge par l'app (`zh-Hans`, `en` ou `fr`).
    static func resolveSupportedLanguage(from preferred: [String]) -> String {
        for raw in preferred {
            let lower = raw.lowercased()
            if lower.hasPrefix("zh-hans") || lower.hasPrefix("zh-cn") || lower.hasPrefix("zh-sg") || lower == "zh" {
                return "zh-Hans"
            }
            if lower.hasPrefix("en") { return "en" }
            if lower.hasPrefix("fr") { return "fr" }
        }
        return "fr"
    }

    var resolvedLanguageCode: String {
        switch self {
        case .system: Self.resolveSupportedLanguage(from: Self.systemPreferredLanguages())
        case .zhHans: "zh-Hans"
        case .en: "en"
        case .fr: "fr"
        }
    }

    /// `Locale` passée à l'environnement SwiftUI pour actualiser l'interface immédiatement.
    var effectiveLocale: Locale {
        Locale(identifier: resolvedLanguageCode)
    }

    /// Applique `escale.language` à `AppleLanguages` AVANT l'initialisation d'AppKit/SwiftUI (`Launcher.main`).
    /// Ignoré lors des scénarios `--selftest*` pour ne jamais perturber les recettes automatisées.
    static func applyLaunchLanguage(arguments: [String] = CommandLine.arguments, defaults: UserDefaults = .standard) {
        if arguments.contains(where: { $0.hasPrefix("--selftest") }) { return }
        let stored = defaults.string(forKey: SettingsFeature.languageKey).flatMap(AppLanguage.init(rawValue:)) ?? .system
        switch stored {
        case .system:
            defaults.removeObject(forKey: "AppleLanguages")
        case .zhHans, .en, .fr:
            defaults.set([stored.rawValue], forKey: "AppleLanguages")
        }
    }

    /// Chaîne traduite depuis le `.lproj` correspondant à `language` (pour les titres AppKit mis à jour à chaud).
    static func localized(_ key: String, for language: AppLanguage) -> String {
        let code = language.resolvedLanguageCode
        if let path = Bundle.main.path(forResource: code, ofType: "lproj"),
           let bundle = Bundle(path: path) {
            return bundle.localizedString(forKey: key, value: nil, table: nil)
        }
        return Bundle.main.localizedString(forKey: key, value: nil, table: nil)
    }
}

/// Onglets de la fenêtre « Réglages ».
enum SettingsTab: String, CaseIterable, Identifiable, Hashable {
    case general, terminal, aiAgents
    var id: String { rawValue }
}

/// Module « Réglages » (⌘,) : fenêtre macOS dédiée, langue d'interface à chaud + redémarrage propre, apparence et raccourcis.
@MainActor
@Observable
final class SettingsFeature: AppFeature {
    nonisolated static let languageKey = "escale.language"
    nonisolated static let localBannerKey = "escale.localBanner"

    private(set) var language: AppLanguage = .system
    private(set) var launchLanguage: AppLanguage = .system
    private(set) var localBannerEnabled: Bool = true
    var selectedTab: SettingsTab = .general

    @ObservationIgnored private weak var model: AppModel?
    /// Stockage des préférences ; `nil` en auto-test (aucune écriture dans les préférences utilisateur).
    @ObservationIgnored var defaults: UserDefaults? = .standard
    @ObservationIgnored private var windowController: SettingsWindowController?

    /// `Locale` active pour l'ensemble de l'interface SwiftUI.
    var effectiveLocale: Locale {
        if model?.options.isSelfTest == true { return .current }
        return language.effectiveLocale
    }

    /// Vrai lorsque la langue choisie diffère de celle chargée par AppKit au démarrage (menus/dialogues système).
    var needsRelaunch: Bool {
        language.resolvedLanguageCode != launchLanguage.resolvedLanguageCode
    }

    /// Vrai lorsque l'app tourne depuis un bundle `.app` relançable.
    var canRelaunch: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    func attach(_ model: AppModel) {
        self.model = model
        if model.options.isSelfTest {
            defaults = nil
            return
        }
        let stored = defaults?.string(forKey: Self.languageKey).flatMap(AppLanguage.init(rawValue:)) ?? .system
        language = stored
        launchLanguage = stored
        localBannerEnabled = defaults?.object(forKey: Self.localBannerKey) as? Bool ?? true
    }

    func shutdown() async {
        windowController?.close()
        windowController = nil
    }

    // MARK: Préférences

    func setLanguage(_ newValue: AppLanguage) {
        guard newValue != language else { return }
        language = newValue
        defaults?.set(newValue.rawValue, forKey: Self.languageKey)
        switch newValue {
        case .system:
            defaults?.removeObject(forKey: "AppleLanguages")
        case .zhHans, .en, .fr:
            defaults?.set([newValue.rawValue], forKey: "AppleLanguages")
        }
        windowController?.updateTitle(for: newValue)
    }

    func setLocalBannerEnabled(_ on: Bool) {
        guard on != localBannerEnabled else { return }
        localBannerEnabled = on
        defaults?.set(on, forKey: Self.localBannerKey)
    }

    // MARK: Fenêtre Réglages

    func show(tab: SettingsTab? = nil) {
        guard let model else { return }
        if let tab { selectedTab = tab }
        if windowController == nil {
            windowController = SettingsWindowController(model: model) { [weak self] in
                self?.windowController = nil
            }
        }
        windowController?.updateTitle(for: language)
        windowController?.show()
    }

    /// ⌘W : ferme la fenêtre Réglages si c'est elle qui a le focus (sans fermer d'onglet de terminal).
    func closeIfKeyWindow() -> Bool {
        guard let w = windowController?.window, w === NSApp.keyWindow else { return false }
        w.performClose(nil)
        return true
    }

    /// Relance proprement l'application après fermeture complète des maîtres SSH (`AppDelegate.applicationShouldTerminate`).
    func relaunchApplication() {
        let appURL = Bundle.main.bundleURL
        guard appURL.pathExtension == "app" else { return }
        let pid = ProcessInfo.processInfo.processIdentifier
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = [
            "-c",
            "i=0; while kill -0 \"$1\" 2>/dev/null && [ \"$i\" -lt 100 ]; do sleep 0.1; i=$((i+1)); done; /usr/bin/open \"$2\"",
            "--",
            String(pid),
            appURL.path,
        ]
        task.standardInput = FileHandle.nullDevice
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()
        NSApp.terminate(nil)
    }
}

// MARK: - Commandes (Escale › Réglages… ⌘,)

struct SettingsCommands: Commands {
    let model: AppModel
    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Réglages…") { model.settings.show() }
                .keyboardShortcut(",", modifiers: .command)
        }
    }
}

// MARK: - Contrôleur de fenêtre natif macOS

@MainActor
private final class SettingsWindowController: NSObject, NSWindowDelegate {
    let window: NSWindow
    private let onClose: @MainActor () -> Void

    init(model: AppModel, onClose: @escaping @MainActor () -> Void) {
        self.onClose = onClose
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 430),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        super.init()
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.delegate = self
        let hosting = NSHostingView(rootView: SettingsWindowRootView(model: model))
        hosting.sizingOptions = []
        window.contentView = hosting
        updateTitle(for: model.settings.language)
        if let main = model.mainWindow {
            let x = main.frame.midX - window.frame.width / 2
            let y = main.frame.midY - window.frame.height / 2
            window.setFrameOrigin(NSPoint(x: x, y: y))
        } else {
            window.center()
        }
    }

    func updateTitle(for language: AppLanguage) {
        window.title = AppLanguage.localized("Réglages", for: language)
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        window.delegate = nil
        window.orderOut(nil)
        window.close()
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}

/// Enveloppe qui suit `model.settings.effectiveLocale` pour ré-injecter la locale SwiftUI à chaud.
private struct SettingsWindowRootView: View {
    let model: AppModel
    var body: some View {
        SettingsView(model: model)
            .environment(\.locale, model.settings.effectiveLocale)
    }
}
