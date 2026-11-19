import SwiftUI
import Observation
import EscaleCore

/// Préférences X11 (UserDefaults) : mode « confiance » (`ForwardX11Trusted=yes`), désactivé par défaut.
enum X11Preferences {
    static let trustedKey = "escale.x11.trusted"
}

/// Message affiché dans une alerte de la fenêtre principale.
struct MacroNotice: Identifiable, Equatable {
    let id = UUID()
    var title: String
    var message: String
}

/// Résultat d'un « Lancer une application X11 ».
enum X11LaunchOutcome: Equatable {
    /// Le programme tourne encore après le délai d'observation (cas normal d'une application graphique) ;
    /// `output` : ce qui a déjà été lu (un refus de redirection X11 y apparaît même si le programme continue).
    case running(pid: Int32, output: String)
    /// Le programme s'est terminé pendant le délai d'observation (échec ou commande courte).
    case exited(code: Int32, output: String)
    case failed(String)
}

/// M5 : macros (séquences de saisie rejouables) et redirection X11 via XQuartz.
///
/// - Macros : bibliothèque JSON à côté de `library.json` ; enregistrement par `TerminalSession.inputObservers["macros"]` ;
///   lecture par `TerminalSession.write` (aucun écho aux observateurs : ni rediffusion, ni ré-enregistrement).
/// - X11 : `ConnectionManager.sshOptions(for:)` ajoute la redirection au maître ; `launchX11` lance la commande
///   sur ce maître par un client secondaire (`OpenSSHTransport.execCommand`, invariant 2).
@MainActor
@Observable
final class MacroFeature: AppFeature {
    static let observerKey = "macros"
    static let sheetID = "macros"

    @ObservationIgnored private(set) weak var model: AppModel?
    private(set) var library = MacroLibrary()
    private(set) var isLoaded = false
    var notice: MacroNotice?

    /// Gestionnaire de macros ouvert (feuille) : renseigne `model.activeFeatureSheet`.
    var managerOpen = false { didSet { syncSheet() } }
    /// Hôte pour lequel la feuille « Lancer une application X11 » est ouverte.
    var x11Host: HostProfile? { didSet { syncSheet() } }
    /// Macro en cours d'édition (copie de travail) et vrai si elle n'est pas encore dans la bibliothèque.
    var draft: Macro?
    var draftIsNew = false

    // MARK: Enregistrement
    private(set) var isRecording = false
    /// Nombre d'étapes capturées (affiché dans le bandeau).
    private(set) var recordedStepCount = 0
    @ObservationIgnored private var recorder = MacroRecorder()
    @ObservationIgnored private weak var recordingPane: Pane?

    @ObservationIgnored private var repository: FileMacroRepository?
    @ObservationIgnored private var playTasks: [UUID: [Task<Int, Never>]] = [:]
    @ObservationIgnored private var x11Processes: [Int32: Process] = [:]

    func attach(_ model: AppModel) {
        self.model = model
        let libraryURL = model.options.libraryPath.map { URL(fileURLWithPath: $0) } ?? LibraryStore.defaultURL
        repository = FileMacroRepository(url: FileMacroRepository.url(besideLibrary: libraryURL))
        Task { @MainActor in await self.load() }
        // X11 demandé mais inutilisable (XQuartz absent, serveur intégré en échec) : un mot dans le terminal, sans bloquer la connexion.
        model.connections.linkObservers[Self.observerKey] = { [weak self] link, event in
            guard event == .connected, link.profile.x11Forwarding, let self, let model = self.model else { return }
            let detection = model.connections.x11Detect()
            // Serveur intégré qui n'a pas pu démarrer : la connexion fonctionne, l'affichage non.
            let notice = !detection.isReady ? detection.explanation
                : (detection.embedded ? model.connections.x11ServerError : nil)
            guard let notice else { return }
            for pane in model.workspace.tabs.flatMap(\.panes) where pane.link === link {
                pane.session.appendNotice(String(localized: "X11 non activé : ") + notice)
            }
        }
    }

    func shutdown() async {
        if isRecording { stopRecording(keep: false) }
        for ts in playTasks.values { for t in ts { t.cancel() } }
        // Applications X11 lancées : arrêt par pid (jamais par motif).
        for p in x11Processes.values where p.isRunning { p.terminate() }
        x11Processes.removeAll()
    }

    private func syncSheet() {
        guard let model else { return }
        if managerOpen || x11Host != nil { model.activeFeatureSheet = Self.sheetID }
        else if model.activeFeatureSheet == Self.sheetID { model.activeFeatureSheet = nil }
    }

    // MARK: Bibliothèque

    func load() async {
        guard let repository else { return }
        do { library = try await repository.load(); isLoaded = true }
        catch {
            isLoaded = true
            notice = MacroNotice(title: String(localized: "Macros illisibles"), message: Self.describe(error))
        }
    }

    private func persist() async -> Bool {
        guard let repository else { return false }
        do { try await repository.save(library); return true }
        catch { notice = MacroNotice(title: String(localized: "Enregistrement impossible"), message: Self.describe(error)); return false }
    }

    static func describe(_ error: Error) -> String {
        switch error as? MacroRepositoryError {
        case .corrupted(let path, _)?: String(localized: "Le fichier \(path) est illisible ; il sera mis de côté au prochain enregistrement.")
        case .unsupportedVersion(let found, let supported)?: String(localized: "Fichier de macros de version \(found) (cette version d'Escale lit jusqu'à \(supported)).")
        case .io(let path, let reason)?: "\(path) : \(reason)"
        case nil: error.localizedDescription
        }
    }

    /// Valide puis enregistre la macro en cours d'édition. Renvoie les problèmes bloquants (vide : enregistrée).
    @discardableResult
    func saveDraft() async -> [MacroIssue] {
        guard let m = draft else { return [] }
        let blocking = library.validate(m).filter { $0.severity == .error }
        guard blocking.isEmpty else { return blocking }
        var cleaned = m
        cleaned.name = m.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let before = library
        library.upsert(cleaned)
        if await persist() { draft = cleaned; draftIsNew = false; return [] }
        library = before
        return [MacroIssue(.error, String(localized: "Enregistrement impossible sur le disque."))]
    }

    func delete(_ id: UUID) async {
        library.remove(id)
        if draft?.id == id { draft = nil }
        _ = await persist()
    }

    func newDraft(scope: MacroScope? = nil) {
        draft = Macro(name: String(localized: "Nouvelle macro"), steps: [.text("")], scope: scope ?? .global)
        draftIsNew = true
    }

    func edit(_ macro: Macro) { draft = macro; draftIsNew = false }

    // MARK: Panneau actif

    var activePane: Pane? { model?.workspace.activeTab?.activePane }
    var activeHostID: UUID? { activePane?.hostID }
    /// Macros proposées pour le panneau actif.
    var availableMacros: [Macro] { library.macros(forHost: activeHostID) }

    // MARK: Lecture

    /// Variables `{host}`/`{user}`/`{name}` d'un panneau : son hôte, ou le terminal local.
    func variables(for pane: Pane) -> [String: String] {
        MacroPlayback.values(for: pane.hostID.flatMap { id in model?.library.library.hosts.first { $0.id == id } })
    }

    /// Rejoue la macro dans le panneau actif (ou dans tous les panneaux en cours d'exécution de l'onglet actif).
    /// Renvoie la tâche de lecture (nombre d'actions exécutées, tous panneaux confondus) pour qui veut l'attendre.
    @discardableResult
    func play(_ macro: Macro, allPanes: Bool = false) -> Task<Int, Never>? {
        guard let tab = model?.workspace.activeTab else { return nil }
        let panes = allPanes ? tab.panes : [tab.activePane]
        let targets = panes.filter { $0.session.state == .running }
        guard !targets.isEmpty else {
            notice = MacroNotice(title: String(localized: "Macro « \(macro.name) »"), message: String(localized: "Le panneau actif n'a pas de session en cours."))
            return nil
        }
        let token = UUID()
        let tasks = targets.map { pane in
            let values = variables(for: pane)
            return Task { @MainActor in await MacroPlayback.play(macro, values: values, send: { pane.session.write($0) }) }
        }
        playTasks[token] = tasks
        return Task { @MainActor [weak self] in
            var total = 0
            for t in tasks { total += await t.value }
            self?.playTasks[token] = nil
            return total
        }
    }

    /// ⌃⌥n : la macro liée à ce raccourci pour l'hôte du panneau actif.
    @discardableResult
    func playShortcut(_ n: Int) -> Task<Int, Never>? {
        guard let m = library.macro(forShortcut: n, host: activeHostID) else { return nil }
        return play(m)
    }

    // MARK: Enregistrement

    var canRecord: Bool { !isRecording && activePane?.session.state == .running }

    /// Capture la saisie du panneau actif jusqu'à `stopRecording`.
    @discardableResult
    func startRecording() -> Bool {
        guard canRecord, let pane = activePane else { return false }
        recorder = MacroRecorder()
        recordedStepCount = 0
        recordingPane = pane
        isRecording = true
        pane.session.inputObservers[Self.observerKey] = { [weak self] bytes in
            guard let self, self.isRecording else { return }
            self.recorder.feed(bytes)
            self.recordedStepCount = self.recorder.result.count
        }
        return true
    }

    /// Arrête la capture. `keep` : ouvre l'éditeur sur la macro obtenue (sinon la saisie est abandonnée).
    func stopRecording(keep: Bool = true) {
        guard isRecording else { return }
        isRecording = false
        recordingPane?.session.inputObservers[Self.observerKey] = nil
        let steps = recorder.result
        let hostID = recordingPane?.hostID
        recordingPane = nil
        recorder = MacroRecorder()
        guard keep else { return }
        guard !steps.isEmpty else {
            notice = MacroNotice(title: String(localized: "Enregistrement vide"), message: String(localized: "Aucune saisie n'a été capturée."))
            return
        }
        draft = Macro(name: String(localized: "Macro enregistrée"), steps: steps, scope: hostID.map { .host($0) } ?? .global)
        draftIsNew = true
        managerOpen = true
    }

    // MARK: X11

    var x11Detection: X11Detection { model?.connections.x11Detect() ?? X11Detection() }

    func openX11Launcher(_ host: HostProfile) { x11Host = host }

    /// Lance `command` sur l'hôte, sur la connexion maître existante (ouverte au besoin), avec la redirection X11.
    /// Attend `settle` secondes : un programme qui s'arrête dans ce délai est rapporté avec sa sortie d'erreur.
    func launchX11(host: HostProfile, command: String, settle: Double = 1.5) async -> X11LaunchOutcome {
        guard let model else { return .failed(String(localized: "Application indisponible.")) }
        let cmd: String
        switch X11LaunchCommand.validate(command) {
        case .failure(let e): return .failed(e.message)
        case .success(let c): cmd = c
        }
        guard host.x11Forwarding else {
            return .failed(String(localized: "La redirection X11 est désactivée pour « \(host.name) » : activez-la dans l'édition de l'hôte."))
        }
        let detection = model.connections.x11Detect()
        guard detection.isReady else { return .failed(detection.explanation) }

        let link = model.connections.connection(for: host).acquireLink()
        guard link.profile.x11Forwarding else {
            link.release()
            return .failed(String(localized: "Cette connexion a été ouverte avant l'activation de X11 : fermez les onglets de l'hôte, puis relancez."))
        }
        guard link.transport.configuration.ssh.x11 != nil else {
            link.release()
            return .failed(String(localized: "Cette connexion a été ouverte sans X11 (aucun serveur X disponible) : fermez les onglets de l'hôte, puis relancez."))
        }
        let shell: ShellCommand
        do {
            try await link.ensureConnected()
            // Serveur intégré arrêté depuis la connexion (menu « Quitter » de l'app X11) : relancé ici.
            if let e = await model.connections.prepareX11(for: link.profile, settings: link.transport.configuration.ssh.x11) {
                link.release()
                return .failed(e)
            }
            shell = try await link.transport.execCommand(remoteCommand: cmd)
        } catch {
            link.release()
            return .failed(link.message(for: error))
        }
        model.connections.trackShell(shell)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell.executable)
        process.arguments = shell.arguments
        process.environment = ProcessInfo.processInfo.environment.merging(shell.environment) { _, new in new }
        let sink = OutputSink()
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil } else { sink.append(d) }
        }
        process.terminationHandler = { [weak self] p in
            let pid = p.processIdentifier
            Task { @MainActor in
                pipe.fileHandleForReading.readabilityHandler = nil
                shell.lease?.release()
                link.release()
                self?.x11Processes[pid] = nil
            }
        }
        do { try process.run() } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            shell.lease?.release()
            link.release()
            return .failed(String(localized: "lancement de ssh impossible : \(error.localizedDescription)"))
        }
        x11Processes[process.processIdentifier] = process

        let end = Date().addingTimeInterval(settle)
        while process.isRunning, Date() < end { try? await Task.sleep(for: .milliseconds(50)) }
        if process.isRunning { return .running(pid: process.processIdentifier, output: sink.text) }
        try? await Task.sleep(for: .milliseconds(100)) // laisse lire la fin de la sortie
        return .exited(code: process.terminationStatus, output: sink.text)
    }

    /// Lance depuis la feuille et affiche l'éventuel problème.
    func launchFromSheet(host: HostProfile, command: String) {
        Task { @MainActor in
            let outcome = await launchX11(host: host, command: command)
            switch outcome {
            case .running(_, let output):
                // Refus déjà écrit par ssh : signalé quand même, le programme continue (fermer l'alerte ne l'arrête pas).
                if let d = X11LaunchDiagnostic.refusalWhileRunning(output: output) {
                    notice = MacroNotice(title: d.title, message: d.message)
                }
            case .failed(let m): notice = MacroNotice(title: String(localized: "Application X11"), message: m)
            case .exited(let code, let output):
                let d = X11LaunchDiagnostic.diagnose(code: code, output: output)
                notice = MacroNotice(title: d.title, message: d.message)
            }
        }
    }
}

/// Tampon de sortie d'un processus (4 Ko au plus), alimenté hors acteur principal.
private final class OutputSink: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ d: Data) { lock.withLock { if data.count < 4096 { data.append(d.prefix(4096 - data.count)) } } }
    var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
}
