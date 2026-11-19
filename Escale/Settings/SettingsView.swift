import SwiftUI
import AppKit
import EscaleCore

/// Fenêtre « Réglages » native macOS (⌘,) : Général (langue, affichage), Terminal (thème, coloration) et Agents IA (MCP).
struct SettingsView: View {
    let model: AppModel

    var body: some View {
        @Bindable var settings = model.settings
        TabView(selection: $settings.selectedTab) {
            GeneralSettingsTab(model: model)
                .tabItem { Label("Général", systemImage: "gearshape") }
                .tag(SettingsTab.general)

            TerminalSettingsTab(colors: model.colors)
                .tabItem { Label("Terminal", systemImage: "terminal") }
                .tag(SettingsTab.terminal)

            AIAgentsSettingsTab(model: model)
                .tabItem { Label("Agents IA", systemImage: "sparkles") }
                .tag(SettingsTab.aiAgents)
        }
        .frame(width: 540, height: 430)
    }
}

// MARK: - Général

private struct GeneralSettingsTab: View {
    let model: AppModel

    private var settings: SettingsFeature { model.settings }

    var body: some View {
        Form {
            Section("Langue") {
                Picker("Langue de l'interface", selection: Binding(
                    get: { settings.language },
                    set: { settings.setLanguage($0) }
                )) {
                    ForEach(AppLanguage.allCases) { lang in
                        if let native = lang.nativeDisplayName {
                            Text(native).tag(lang)
                        } else {
                            Text("Suivre le système").tag(lang)
                        }
                    }
                }
                Text("L'interface s'actualise immédiatement. Relancez Escale pour mettre à jour la barre des menus et les dialogues système.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if settings.needsRelaunch {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.clockwise.circle.fill")
                            .foregroundStyle(.tint)
                        Text("Certains éléments système nécessitent un redémarrage.")
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Button("Relancer maintenant") {
                            settings.relaunchApplication()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(!settings.canRelaunch)
                    }
                    .padding(.vertical, 4)
                }
            }

            Section("Affichage") {
                VStack(alignment: .leading, spacing: 3) {
                    Toggle("Mode compact", isOn: Binding(
                        get: { model.compact.isOn },
                        set: { model.compact.set($0, model: model) }
                    ))
                    Text("Barre d'outils en icônes seules, barre latérale repliée et barre d'état réduite (⇧⌘M).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Toggle("Bannière d'accueil du terminal local", isOn: Binding(
                        get: { settings.localBannerEnabled },
                        set: { settings.setLocalBannerEnabled($0) }
                    ))
                    Text("Affiche les informations d'accueil à l'ouverture d'un nouveau terminal local.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Terminal

private struct TerminalSettingsTab: View {
    @ObservedObject var colors: TerminalColorsFeature

    var body: some View {
        Form {
            Section("Couleurs et lisibilité") {
                Picker("Thème du terminal", selection: Binding(
                    get: { colors.themeID },
                    set: { colors.setTheme($0) }
                )) {
                    ForEach(TerminalTheme.all) { theme in
                        Text(theme.localizedNameKey).tag(theme.id)
                    }
                }

                LabeledContent("Aperçu") {
                    ThemePreviewSwatch(theme: colors.theme)
                }

                Picker("Coloration de la sortie", selection: Binding(
                    get: { colors.rules },
                    set: { colors.setRules($0) }
                )) {
                    ForEach(HighlightRuleSet.allCases) { rule in
                        Text(rule.localizedTitleKey).tag(rule)
                    }
                }

                Text("Surligne automatiquement les erreurs, avertissements, adresses IP et URL dans la sortie du terminal.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }
}

/// Aperçu compact du fond, du texte et de la palette ANSI du thème sélectionné.
private struct ThemePreviewSwatch: View {
    let theme: TerminalTheme

    private var bg: Color {
        theme.background.map { Color(red: Double($0.red) / 255, green: Double($0.green) / 255, blue: Double($0.blue) / 255) }
            ?? Color(nsColor: .textBackgroundColor)
    }

    private var fg: Color {
        theme.foreground.map { Color(red: Double($0.red) / 255, green: Double($0.green) / 255, blue: Double($0.blue) / 255) }
            ?? Color(nsColor: .textColor)
    }

    var body: some View {
        HStack(spacing: 8) {
            Text("ssh prod")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(fg)
            HStack(spacing: 3) {
                ForEach(1..<7, id: \.self) { i in
                    let c = theme.ansi[i]
                    Circle()
                        .fill(Color(red: Double(c.red) / 255, green: Double(c.green) / 255, blue: Double(c.blue) / 255))
                        .frame(width: 8, height: 8)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(bg, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.separator))
    }
}

// MARK: - Agents IA (MCP)

private struct AIAgentsSettingsTab: View {
    let model: AppModel

    private var mcp: MCPFeature { model.mcp }

    private var sshHosts: [HostProfile] {
        model.library.library.hosts.filter { $0.connectionProtocol == .ssh }
    }

    private var exposedCount: Int {
        sshHosts.filter { $0.agentAccess != .none }.count
    }

    var body: some View {
        Form {
            Section("Accès des agents IA (MCP)") {
                LabeledContent("État") {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(mcp.isRunning ? Color.green : Color.secondary.opacity(0.45))
                            .frame(width: 8, height: 8)
                        Text(statusText)
                            .foregroundStyle(mcp.isRunning ? .primary : .secondary)
                    }
                }

                LabeledContent("Hôtes exposés") {
                    Text("\(exposedCount)/\(sshHosts.count) exposés")
                        .foregroundStyle(.secondary)
                }

                Toggle("Autoriser l'accès des agents", isOn: Binding(
                    get: { mcp.isEnabled },
                    set: { mcp.setEnabled($0) }
                ))

                Toggle("Ouvrir automatiquement la connexion SSH à la demande de l'agent", isOn: Binding(
                    get: { mcp.allowAutoConnect },
                    set: { mcp.setAutoConnect($0) }
                ))

                HStack {
                    Spacer()
                    Button("Ouvrir la configuration des agents IA…") {
                        model.mainWindow?.makeKeyAndOrderFront(nil)
                        model.mcp.isSettingsPresented = true
                    }
                }

                Text("Configurez Antigravity (agy), Claude Code, Claude Desktop ou Codex, gérez les hôtes exposés et consultez le journal.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }

    private var statusText: LocalizedStringKey {
        if mcp.isRunning {
            let n = mcp.clientCount
            return n == 0 ? "en écoute" : (n == 1 ? "1 client" : "\(n) clients")
        }
        return "Désactivé"
    }
}
