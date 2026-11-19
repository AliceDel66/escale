import SwiftUI
import AppKit
import EscaleCore

// MARK: - Commandes (menu « Multi-exécution »)

struct MultiExecCommands: Commands {
    let model: AppModel
    var body: some Commands {
        CommandMenu("Multi-exécution") {
            let feature = model.multiExec
            Button(feature.isBroadcasting ? "Arrêter la diffusion de la saisie" : "Diffuser la saisie") { feature.toggleBroadcast() }
                .keyboardShortcut("i", modifiers: [.command, .option])
            Button("Choisir les panneaux à diffuser…") { feature.openBroadcastSheet() }
                .disabled(model.workspace.tabs.isEmpty)
            // Sortie de secours : raccourci de menu, donc jamais transmis au terminal ni diffusé.
            Button("Quitter la diffusion (jamais diffusé)") { feature.stopBroadcast() }
                .keyboardShortcut(.escape, modifiers: [.control, .option])
                .disabled(!feature.isBroadcasting)
            Divider()
            Button("Exécuter une commande sur les hôtes connectés…") { feature.beginGroupExecOnConnected() }
                .disabled(feature.connectedHosts.isEmpty)
            Menu("Exécuter une commande sur l'étiquette") {
                let tags = model.library.library.tagCounts
                if tags.isEmpty { Text("Aucune étiquette") }
                ForEach(tags, id: \.tag) { t in
                    Button("#\(t.tag) (\(t.count))") { feature.beginGroupExec(tag: t.tag) }
                }
            }
            Menu("Exécuter une commande sur le dossier") {
                let folders = model.library.allFolderPaths
                if folders.isEmpty { Text("Aucun dossier") }
                ForEach(folders, id: \.id) { f in
                    Button(f.path) { feature.beginGroupExec(folder: f.id) }
                        .disabled(feature.hosts(inFolder: f.id).isEmpty)
                }
            }
        }
    }
}

// MARK: - Menu de la sélection multiple de la barre latérale

struct MultiExecSelectionMenuItems: View {
    let model: AppModel
    let hosts: [HostProfile]
    var body: some View {
        Button("Exécuter une commande sur \(hosts.count) hôtes…") { model.multiExec.beginGroupExec(hosts: hosts) }
            .disabled(hosts.isEmpty)
    }
}

// MARK: - Menu contextuel d'un dossier de la barre latérale

struct MultiExecFolderMenuItems: View {
    let model: AppModel
    let folder: HostFolder
    var body: some View {
        Button("Exécuter une commande sur ce dossier…") { model.multiExec.beginGroupExec(folder: folder.id) }
            .disabled(model.multiExec.hosts(inFolder: folder.id).isEmpty)
    }
}

// MARK: - Scène : bandeau de diffusion, résultats, feuilles

struct MultiExecScene: ViewModifier {
    let model: AppModel

    func body(content: Content) -> some View {
        let feature = model.multiExec
        content
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    if feature.isBroadcasting { BroadcastBanner(feature: feature) }
                    if let run = feature.execRun { ExecResultsPanel(feature: feature, run: run) }
                }
            }
            .sheet(isPresented: Binding(
                get: { feature.execDraft != nil },
                set: { if !$0 { feature.cancelGroupExecDraft() } })
            ) {
                if feature.execDraft != nil {
                    ExecSheet(feature: feature, draft: Binding(get: { feature.execDraft ?? .init(hosts: []) }, set: { feature.execDraft = $0 }))
                }
            }
            .sheet(isPresented: Binding(
                get: { feature.broadcastSheetOpen },
                set: { if !$0 { feature.closeBroadcastSheet() } })
            ) {
                BroadcastSheet(model: model, feature: feature)
            }
    }
}

/// Bandeau rouge tant que la saisie est diffusée (les panneaux concernés portent aussi une bordure rouge).
private struct BroadcastBanner: View {
    let feature: MultiExecFeature
    var body: some View {
        StatusBanner(tone: .live, icon: .symbol("dot.radiowaves.left.and.right"),
                     title: String(localized: "Diffusion de la saisie vers \(feature.broadcastPaneIDs.count) panneaux"),
                     detail: String(localized: "Sortie sans diffuser la touche : ⌥⌘I, ⌃⌥Échap ou Échap Échap")) {
            Button("Choisir les panneaux…") { feature.openBroadcastSheet() }.buttonStyle(.bannerSecondary)
            Button("Arrêter la diffusion") { feature.stopBroadcast() }.buttonStyle(.bannerPrimary)
                .help("⌥⌘I. Échap Échap rapide : le premier Échap est retenu 0,35 s pour les autres panneaux ; si un second suit, la diffusion s'arrête et aucun des deux n'est envoyé.")
        }
        .accessibilityIdentifier("multiexec-banner")
    }
}

/// Choix des panneaux à diffuser.
private struct BroadcastSheet: View {
    let model: AppModel
    let feature: MultiExecFeature
    @State private var mode = 0   // 0 onglet actif, 1 tous les onglets, 2 sélection

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Diffuser la saisie").font(.title3.bold())
            Picker("Cible", selection: $mode) {
                Text("Panneaux de l'onglet actif").tag(0)
                Text("Tous les onglets").tag(1)
                Text("Sélection").tag(2)
            }
            .pickerStyle(.radioGroup)
            if mode == 2 {
                List {
                    ForEach(model.workspace.tabs) { tab in
                        Section(tab.displayTitle) {
                            ForEach(tab.panes) { p in
                                Toggle(p.displayTitle, isOn: Binding(
                                    get: { feature.sheetSelection.contains(p.id) },
                                    set: { on in if on { feature.sheetSelection.insert(p.id) } else { feature.sheetSelection.remove(p.id) } }))
                            }
                        }
                    }
                }
                .frame(height: 200)
            }
            Text("La saisie d'un panneau du groupe est envoyée telle quelle (touches spéciales et collage compris) aux autres. Les panneaux concernés ont une bordure rouge.")
                .font(.caption).foregroundStyle(.secondary)
            if let e = problem { Text(e).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Annuler", role: .cancel) { feature.closeBroadcastSheet() }.keyboardShortcut(.cancelAction)
                Button("Diffuser") { start() }.keyboardShortcut(.defaultAction).disabled(problem != nil)
            }
        }
        .padding(20).frame(width: 440)
    }

    private var scope: MultiExecFeature.BroadcastScope? {
        switch mode {
        case 0: model.workspace.activeTab.map { .tab($0.id) }
        case 1: .allTabs
        default: .panes(feature.sheetSelection)
        }
    }
    private var problem: String? {
        guard let s = scope else { return String(localized: "Aucun onglet ouvert.") }
        return feature.members(of: s).count < 2 ? String(localized: "Il faut au moins deux panneaux.") : nil
    }
    private func start() {
        guard let s = scope else { return }
        feature.closeBroadcastSheet()
        feature.startBroadcast(s)
    }
}

/// Feuille « Exécuter une commande… » : cibles, commande commune, commande propre à chaque hôte, historique.
private struct ExecSheet: View {
    let feature: MultiExecFeature
    @Binding var draft: MultiExecFeature.ExecDraft
    @State private var perHost = false

    private var warning: String? { feature.secretWarning(draft.command, overrides: draft.overrides) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Exécuter une commande sur \(draft.hosts.count) hôtes").font(.title3.bold())
                Spacer()
                targetsMenu
            }
            Text("\(draft.source) : " + draft.hosts.map(\.name).joined(separator: ", "))
                .font(.caption).foregroundStyle(.secondary).lineLimit(3)
            HStack(alignment: .top) {
                TextField("Commande commune", text: $draft.command, axis: .vertical)
                    .lineLimit(2...6).font(.system(.body, design: .monospaced)).textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("multiexec-command")
                historyMenu
            }
            Text("Variables : {host} (adresse), {user}, {name} (nom dans la bibliothèque), échappées pour le shell.")
                .font(.caption).foregroundStyle(.secondary)
            if let w = warning {
                Label(w, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("multiexec-secret-warning")
            }
            DisclosureGroup("Commande propre à chaque hôte (facultatif)", isExpanded: $perHost) {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(draft.hosts) { h in
                            HStack {
                                Text(h.name).frame(width: 110, alignment: .leading).lineLimit(1)
                                TextField("(commande commune)", text: Binding(
                                    get: { draft.overrides[h.id] ?? "" },
                                    set: { draft.overrides[h.id] = $0 }))
                                    .font(.system(.caption, design: .monospaced)).textFieldStyle(.roundedBorder)
                                Button { remove(h) } label: { Image(systemName: "minus.circle") }
                                    .buttonStyle(.borderless).help("Retirer cet hôte des cibles")
                                    .disabled(draft.hosts.count < 2)
                            }
                        }
                    }
                }
                .frame(maxHeight: 150)
                if let h = draft.hosts.first, !draft.command.isEmpty || draft.overrides[h.id] != nil {
                    Text(String(localized: "Aperçu pour \(h.name) : ") + MultiExecFeature.resolvedCommand(common: draft.command, overrides: draft.overrides, host: h))
                        .font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Picker("Délai maximal", selection: $draft.timeout) {
                Text("10 s").tag(10.0); Text("30 s").tag(30.0); Text("1 min").tag(60.0); Text("5 min").tag(300.0)
            }
            .pickerStyle(.segmented)
            Text("Exécution non interactive (sans terminal) sur la connexion de chaque hôte ; les hôtes non connectés sont connectés d'abord.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Annuler", role: .cancel) { feature.cancelGroupExecDraft() }.keyboardShortcut(.cancelAction)
                Button("Exécuter") {
                    feature.startGroupExec(command: draft.command, timeout: draft.timeout, hosts: draft.hosts, overrides: draft.overrides)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(draft.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20).frame(width: 560)
    }

    private func remove(_ h: HostProfile) {
        feature.retarget(draft.hosts.filter { $0.id != h.id }, source: draft.source + String(localized: " (modifiée)"))
    }

    private var targetsMenu: some View {
        Menu("Cibles") {
            Button("Hôtes connectés") { feature.retarget(feature.connectedHosts, source: String(localized: "Hôtes connectés")) }
                .disabled(feature.connectedHosts.isEmpty)
            if let lib = feature.model?.library {
                Menu("Dossier (récursif)") {
                    ForEach(lib.allFolderPaths, id: \.id) { f in
                        Button(f.path) { feature.retarget(feature.hosts(inFolder: f.id), source: String(localized: "Dossier « \(f.path) »")) }
                            .disabled(feature.hosts(inFolder: f.id).isEmpty)
                    }
                }
                Menu("Étiquette") {
                    ForEach(lib.library.tagCounts, id: \.tag) { t in
                        Button("#\(t.tag) (\(t.count))") { feature.retarget(feature.hosts(withTag: t.tag), source: String(localized: "Étiquette #\(t.tag)")) }
                    }
                }
            }
        }
        .menuStyle(.borderlessButton).fixedSize()
    }

    private var historyMenu: some View {
        Menu {
            if feature.history.entries.isEmpty { Text("Aucune commande récente") }
            ForEach(feature.history.entries) { e in
                Button(e.command.replacingOccurrences(of: "\n", with: " ")) { draft.command = e.command }
            }
            if !feature.history.entries.isEmpty {
                Divider()
                Button("Effacer l'historique") { feature.clearHistory() }
            }
        } label: { Image(systemName: "clock.arrow.circlepath") }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("Dernières commandes groupées (jamais celles qui contiennent un mot de passe)")
        .accessibilityLabel("Historique")
    }
}

/// Résultats par hôte : état, code de sortie, durée, sorties (tronquées), copier, relancer.
private struct ExecResultsPanel: View {
    let feature: MultiExecFeature
    let run: MultiExecFeature.ExecRun

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                if run.isRunning { ProgressView().controlSize(.small) }
                Text("$ \(run.command)").font(.system(.body, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                Spacer()
                Text(run.isRunning ? "\(run.finishedCount)/\(run.rows.count) terminés"
                     : run.failedCount == 0 ? "Tous réussis" : "\(run.failedCount) en échec")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Relancer") { feature.rerun() }.disabled(run.isRunning).controlSize(.small)
                Button("Copier tout") { feature.copy(feature.reportText(run)) }.disabled(run.isRunning).controlSize(.small)
                Button("Exporter…") { feature.presentExport(run) }.disabled(run.isRunning).controlSize(.small)
                Button("Fermer") { feature.closeResults() }.disabled(run.isRunning).controlSize(.small)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(run.rows) { row in ExecRowView(feature: feature, row: row) }
                }
            }
            .frame(maxHeight: 240)
        }
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .accessibilityIdentifier("multiexec-results")
    }
}

private struct ExecRowView: View {
    let feature: MultiExecFeature
    let row: MultiExecFeature.ExecRow
    @State private var expanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Button { expanded.toggle() } label: { Image(systemName: expanded ? "chevron.down" : "chevron.right").frame(width: 12) }
                    .buttonStyle(.plain)
                icon
                Text(row.host.name).fontWeight(.medium)
                Text(statusText).foregroundStyle(.secondary).font(.caption)
                Spacer()
                if let r = row.result {
                    Text(String(format: "%.1f s", r.duration)).font(.caption).foregroundStyle(.secondary)
                    Button { feature.copy(GroupExecReport.text(command: "", entries: [(row.host.name, r)])) } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.borderless).help("Copier le résultat de cet hôte")
                }
            }
            if expanded, let r = row.result {
                if !r.stdout.isEmpty { output(r.stdout + (r.stdoutTruncated ? String(localized: "\n[tronquée]") : ""), error: false) }
                if !r.stderr.isEmpty { output(r.stderr + (r.stderrTruncated ? String(localized: "\n[tronquée]") : ""), error: true) }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 4)
    }

    private func output(_ text: String, error: Bool) -> some View {
        Text(text).font(.system(.caption, design: .monospaced)).foregroundStyle(error ? Color.red : Color.primary)
            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 30)
    }

    @ViewBuilder private var icon: some View {
        switch row.phase {
        case .waiting: Image(systemName: "clock").foregroundStyle(.secondary)
        case .connecting, .running: ProgressView().controlSize(.mini)
        case .done:
            if row.result?.isSuccess == true { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
            else { Image(systemName: "xmark.octagon.fill").foregroundStyle(.red) }
        }
    }

    private var statusText: String {
        switch row.phase {
        case .waiting: String(localized: "en attente")
        case .connecting: String(localized: "connexion…")
        case .running: String(localized: "exécution…")
        case .done: row.result?.summary ?? ""
        }
    }
}
