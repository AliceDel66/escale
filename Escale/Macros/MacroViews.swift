import SwiftUI
import AppKit
import EscaleCore

// MARK: - Menu « Macros »

/// Raccourci ⌃⌥n appliqué seulement s'il y en a un.
private struct MacroShortcut: ViewModifier {
    let n: Int?
    func body(content: Content) -> some View {
        if let n, Macro.shortcutRange.contains(n), let ch = String(n).first {
            content.keyboardShortcut(KeyEquivalent(ch), modifiers: [.control, .option])
        } else { content }
    }
}

struct MacroCommands: Commands {
    let model: AppModel
    var body: some Commands {
        CommandMenu("Macros") {
            let f = model.macros
            if f.isRecording {
                Button("Arrêter l'enregistrement") { f.stopRecording() }
            } else {
                Button("Enregistrer une macro") { f.startRecording() }.disabled(!f.canRecord)
            }
            Divider()
            let list = f.availableMacros
            if list.isEmpty {
                Text("Aucune macro pour ce panneau")
            } else {
                ForEach(list) { m in
                    Button(m.name) { f.play(m) }.modifier(MacroShortcut(n: m.shortcut))
                }
                Menu("Jouer dans tous les panneaux de l'onglet") {
                    ForEach(list) { m in Button(m.name) { f.play(m, allPanes: true) } }
                }
            }
            Divider()
            Button("Gérer les macros…") { f.managerOpen = true }
        }
    }
}

// MARK: - Feuilles et bandeau

struct MacroScene: ViewModifier {
    let model: AppModel
    func body(content: Content) -> some View {
        let f = model.macros
        content
            .sheet(isPresented: Binding(get: { f.managerOpen }, set: { f.managerOpen = $0 })) { MacroManagerView(feature: f, model: model) }
            .sheet(item: Binding(get: { f.x11Host }, set: { f.x11Host = $0 })) { host in X11LaunchSheet(feature: f, host: host) }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if f.isRecording { MacroRecordingBar(feature: f) }
            }
            .alert(item: Binding(get: { f.notice }, set: { f.notice = $0 })) { n in
                Alert(title: Text(n.title), message: Text(n.message), dismissButton: .default(Text("OK")))
            }
    }
}

private struct MacroRecordingBar: View {
    let feature: MacroFeature
    var body: some View {
        StatusBanner(tone: .live, icon: .symbol("record.circle.fill"),
                     title: String(localized: "Enregistrement de la macro — \(feature.recordedStepCount) étape\(feature.recordedStepCount > 1 ? "s" : "")"),
                     detail: String(localized: "Ne tapez pas de mot de passe : il serait enregistré en clair.")) {
            Button("Abandonner") { feature.stopRecording(keep: false) }.buttonStyle(.bannerSecondary)
            Button("Terminer") { feature.stopRecording() }.buttonStyle(.bannerPrimary)
                .keyboardShortcut(.escape, modifiers: [.control, .option])
                .help("Terminer et enregistrer la macro (⌃⌥Échap)")
        }
    }
}

// MARK: - Menu contextuel d'un hôte

struct MacroHostMenuItems: View {
    let model: AppModel
    let host: HostProfile
    var body: some View {
        Divider()
        Button("Lancer une application X11…") { model.macros.openX11Launcher(host) }
    }
}

// MARK: - Gestionnaire

struct MacroManagerView: View {
    @Bindable var feature: MacroFeature
    let model: AppModel
    @State private var selection: UUID?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    List(selection: $selection) {
                        ForEach(feature.library.macros) { m in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(m.name).fontWeight(.medium)
                                    Spacer()
                                    if let s = m.shortcut { Text("⌃⌥\(s)").font(.caption.monospaced()).foregroundStyle(.secondary) }
                                }
                                Text(scopeLabel(m.scope)).font(.caption).foregroundStyle(.secondary)
                            }
                            .tag(m.id)
                        }
                    }
                    .overlay { if feature.library.macros.isEmpty { Text("Aucune macro").foregroundStyle(.secondary) } }
                    Divider()
                    HStack {
                        Button { selection = nil; feature.newDraft() } label: { Image(systemName: "plus") }.help("Nouvelle macro")
                        Button {
                            if let id = selection { Task { await feature.delete(id); selection = nil } }
                        } label: { Image(systemName: "minus") }.help("Supprimer").disabled(selection == nil)
                        Spacer()
                        Button("Enregistrer…") {
                            feature.managerOpen = false
                            // Laisse la feuille se fermer avant de capturer la saisie du panneau actif.
                            Task { @MainActor in try? await Task.sleep(for: .milliseconds(400)); feature.startRecording() }
                        }
                        .disabled(!feature.canRecord)
                        .help("Capture la saisie du panneau actif jusqu'à l'arrêt")
                    }
                    .padding(8)
                }
                .frame(width: 240)
                Divider()
                Group {
                    if feature.draft != nil {
                        MacroEditorView(feature: feature, model: model)
                    } else {
                        Text("Choisissez une macro ou créez-en une.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(minWidth: 440)
            }
            Divider()
            HStack {
                Text("Les macros sont enregistrées en clair à côté de la bibliothèque : aucun mot de passe.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Fermer") { feature.managerOpen = false }.keyboardShortcut(.cancelAction)
            }
            .padding(10)
        }
        .frame(width: 760, height: 520)
        .onChange(of: selection) { _, id in
            if let id, let m = feature.library.macros.first(where: { $0.id == id }) { feature.edit(m) }
        }
        .onAppear { selection = feature.draftIsNew ? nil : feature.draft?.id }
    }

    private func scopeLabel(_ s: MacroScope) -> String {
        switch s {
        case .global: String(localized: "Tous les hôtes")
        case .host(let id): model.library.library.hosts.first { $0.id == id }.map { String(localized: "Hôte : \($0.name)") } ?? String(localized: "Hôte supprimé")
        }
    }
}

// MARK: - Éditeur

struct MacroEditorView: View {
    @Bindable var feature: MacroFeature
    let model: AppModel
    @State private var errors: [MacroIssue] = []

    private var draft: Binding<Macro> {
        Binding(get: { feature.draft ?? Macro(name: "") }, set: { feature.draft = $0; errors = [] })
    }

    private var warnings: [MacroIssue] {
        guard let d = feature.draft else { return [] }
        return feature.library.validate(d).filter { $0.severity == .warning }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Form {
                TextField("Nom", text: draft.name)
                Picker("Portée", selection: draft.scope) {
                    Text("Tous les hôtes").tag(MacroScope.global)
                    ForEach(model.library.library.hosts.sorted { $0.name < $1.name }) { h in Text("Hôte : \(h.name)").tag(MacroScope.host(h.id)) }
                }
                Picker("Raccourci", selection: draft.shortcut) {
                    Text("Aucun").tag(Int?.none)
                    ForEach(Array(Macro.shortcutRange), id: \.self) { Text("⌃⌥\($0)").tag(Int?.some($0)) }
                }
            }
            .formStyle(.columns)

            HStack {
                Text("Étapes").font(.headline)
                Spacer()
                Menu("Ajouter") {
                    Button("Texte") { feature.draft?.steps.append(.text("")) }
                    Button("Attente") { feature.draft?.steps.append(.wait(milliseconds: 500)) }
                    Menu("Touche") { ForEach(MacroKey.allCases, id: \.self) { k in Button(k.label) { feature.draft?.steps.append(.key(k)) } } }
                }
                .fixedSize()
            }
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(Array((feature.draft?.steps ?? []).enumerated()), id: \.offset) { i, _ in
                        StepRow(step: stepBinding(i), index: i, count: feature.draft?.steps.count ?? 0,
                                move: { d in move(i, d) }, remove: { feature.draft?.steps.remove(at: i); errors = [] })
                    }
                }
            }
            .frame(maxHeight: .infinity)
            Text("Dans un texte, un retour à la ligne est envoyé comme la touche Entrée. Variables : {host} (adresse), {user}, {name} (nom de l'hôte ; terminal local : localhost, utilisateur courant, « Terminal local »), remplacées à la lecture et échappées pour le shell.").font(.caption).foregroundStyle(.secondary)

            ForEach(Array((errors + warnings).enumerated()), id: \.offset) { _, issue in
                Label(issue.message, systemImage: issue.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(issue.severity == .error ? .red : .orange)
            }
            HStack {
                Button("Essayer dans le panneau actif") {
                    if let d = feature.draft { feature.managerOpen = false; Task { @MainActor in try? await Task.sleep(for: .milliseconds(400)); feature.play(d) } }
                }
                .disabled(feature.activePane?.session.state != .running)
                Spacer()
                Button("Annuler") { feature.draft = nil; errors = [] }
                Button("Enregistrer") { Task { errors = await feature.saveDraft() } }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
    }

    private func stepBinding(_ i: Int) -> Binding<MacroStep> {
        Binding(get: { feature.draft?.steps.indices.contains(i) == true ? feature.draft!.steps[i] : .text("") },
                set: { v in if feature.draft?.steps.indices.contains(i) == true { feature.draft?.steps[i] = v; errors = [] } })
    }

    private func move(_ i: Int, _ d: Int) {
        guard var steps = feature.draft?.steps, steps.indices.contains(i), steps.indices.contains(i + d) else { return }
        steps.swapAt(i, i + d)
        feature.draft?.steps = steps
    }
}

private struct StepRow: View {
    @Binding var step: MacroStep
    let index: Int
    let count: Int
    let move: (Int) -> Void
    let remove: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            switch step {
            case .text:
                Image(systemName: "text.cursor").frame(width: 18).padding(.top, 4)
                TextEditor(text: Binding(get: { if case .text(let t) = step { t } else { "" } }, set: { step = .text($0) }))
                    .font(.body.monospaced()).frame(height: 50)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(.quaternary))
            case .wait:
                Image(systemName: "timer").frame(width: 18)
                Stepper(value: Binding(get: { if case .wait(let m) = step { m } else { 0 } }, set: { step = .wait(milliseconds: $0) }),
                        in: 0...Macro.maxWaitMilliseconds, step: 100) {
                    Text("Attendre \(waitMs) ms")
                }
            case .key:
                Image(systemName: "keyboard").frame(width: 18)
                Picker("Touche", selection: Binding(get: { if case .key(let k) = step { k } else { .tab } }, set: { step = .key($0) })) {
                    ForEach(MacroKey.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .labelsHidden().fixedSize()
            }
            Spacer(minLength: 0)
            Button { move(-1) } label: { Image(systemName: "chevron.up") }.disabled(index == 0).buttonStyle(.borderless)
            Button { move(1) } label: { Image(systemName: "chevron.down") }.disabled(index >= count - 1).buttonStyle(.borderless)
            Button(role: .destructive) { remove() } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
        }
    }

    private var waitMs: Int { if case .wait(let m) = step { m } else { 0 } }
}

// MARK: - X11 : feuille de lancement et section de l'éditeur d'hôte

struct X11LaunchSheet: View {
    let feature: MacroFeature
    let host: HostProfile
    @State private var command = X11LaunchCommand.defaultCommand
    @State private var detection = X11Detection()

    private var error: String? {
        if !host.x11Forwarding { return String(localized: "La redirection X11 est désactivée pour cet hôte : activez-la dans son édition, puis rouvrez ses onglets.") }
        if !detection.isReady { return detection.explanation }
        if case .failure(let e) = X11LaunchCommand.validate(command) { return e.message }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Lancer une application X11 sur « \(host.name) »").font(.headline)
            TextField("Commande", text: $command, prompt: Text(X11LaunchCommand.defaultCommand))
                .textFieldStyle(.roundedBorder)
                .onSubmit { launch() }
            Text(detection.embedded ? "La commande s'exécute sur l'hôte et s'affiche sur ce Mac (serveur X11 intégré)."
                 : "La commande s'exécute sur l'hôte et s'affiche dans XQuartz sur ce Mac.").font(.caption).foregroundStyle(.secondary)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange)
                if !detection.isReady { Button("Installer XQuartz (xquartz.org)") { NSWorkspace.shared.open(X11Detection.installURL) } }
            }
            HStack {
                Spacer()
                Button("Annuler") { feature.x11Host = nil }.keyboardShortcut(.cancelAction)
                Button("Lancer") { launch() }.keyboardShortcut(.defaultAction).disabled(error != nil)
            }
        }
        .padding(18)
        .frame(width: 460)
        .onAppear { detection = feature.x11Detection }
    }

    private func launch() {
        guard error == nil else { return }
        let h = host, c = command
        feature.x11Host = nil // ferme la feuille avant une éventuelle invite d'authentification
        feature.launchFromSheet(host: h, command: c)
    }
}

/// Section X11 de la feuille d'édition d'hôte.
struct X11EditorSection: View {
    @Binding var isOn: Bool
    /// Détection de l'app (serveur intégré prioritaire) ; à défaut, XQuartz seul.
    var detect: () -> X11Detection = { X11Detection.detect() }
    @AppStorage(X11Preferences.trustedKey) private var trusted = false
    @State private var detection = X11Detection()

    var body: some View {
        Section {
            Toggle("Redirection X11", isOn: $isOn)
            Text(detection.embedded ? "Affiche sur ce Mac les applications graphiques lancées sur l'hôte (xeyes, éditeurs…), sans rien installer."
                 : "Affiche sur ce Mac les applications graphiques lancées sur l'hôte (xeyes, éditeurs…). Nécessite XQuartz.")
                .font(.caption).foregroundStyle(.secondary)
            Label(detection.explanation, systemImage: detection.isReady ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(detection.isReady ? .green : .orange)
            if !detection.isReady {
                Button("Installer XQuartz (xquartz.org)") { NSWorkspace.shared.open(X11Detection.installURL) }
            }
            if isOn {
                Toggle("Mode confiance (ForwardX11Trusted)", isOn: $trusted)
                Text("Désactivé par défaut : les programmes distants passent par l'extension SECURITY d'X11. Activé, un hôte compromis peut lire l'écran et le clavier de ce Mac. Réglage commun à tous les hôtes ; s'applique à la prochaine connexion.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear { detection = detect() }
    }
}
