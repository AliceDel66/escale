import SwiftUI
import AppKit
import EscaleCore

/// Validation pure des champs de l'éditeur d'hôte (testable sans interface).
enum HostFormValidation {
    static func isSuspicious(_ s: String) -> Bool { s.hasPrefix("-") }

    static func host(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return String(localized: "L'hôte est obligatoire.") }
        if isSuspicious(t) { return String(localized: "L'hôte ne peut pas commencer par « - ».") }
        if t.contains(where: \.isWhitespace) { return String(localized: "L'hôte ne peut pas contenir d'espace.") }
        return nil
    }
    static func port(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return nil }
        guard let p = Int(t), (1...65535).contains(p) else { return String(localized: "Le port doit être un nombre entre 1 et 65535.") }
        return nil
    }
    static func user(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return nil }
        if isSuspicious(t) { return String(localized: "L'utilisateur ne peut pas commencer par « - ».") }
        if t.contains(where: \.isWhitespace) || t.contains("@") { return "Utilisateur invalide." }
        return nil
    }
    static func keyPath(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return String(localized: "Choisissez un fichier de clé.") }
        if isSuspicious(t) { return String(localized: "Le chemin ne peut pas commencer par « - ».") }
        return nil
    }
    static func jumpHosts(_ s: String) -> String? {
        for j in split(s) {
            if isSuspicious(j) { return String(localized: "Un bastion ne peut pas commencer par « - ».") }
            if j.contains(where: \.isWhitespace) { return String(localized: "Bastions : séparez-les par des virgules, sans espace interne.") }
        }
        return nil
    }
    static func name(_ s: String) -> String? {
        isSuspicious(s.trimmingCharacters(in: .whitespaces)) ? String(localized: "Le nom ne peut pas commencer par « - ».") : nil
    }
    static func split(_ s: String) -> [String] {
        s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

/// Feuille d'édition (ou de création) d'un hôte : bandeau de protocoles, puis réglages en onglets (`HostEditorTab`).
struct HostEditorSheet: View {
    let model: AppModel
    let host: HostProfile?
    let initialFolder: UUID?
    @Environment(\.dismiss) private var dismiss

    @State private var form = HostEditorForm()
    @State private var discoveredKeys: [DiscoveredSSHKey] = []
    @State private var hasStoredSecret = false
    @State private var secretMessage: String?
    @State private var hasStoredPassphrase = false
    @State private var passphraseMessage: String?
    @State private var loaded = false

    private var errors: [String] { form.errors }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                HostEditorBanner(form: form)
                Picker("Onglet", selection: $form.tab) {
                    ForEach(form.tabs, id: \.self) { Text($0.title(for: form.connectionProtocol)).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
            }
            .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 4)

            // Hauteur fixe : la feuille garde la même taille d'un onglet et d'un protocole à l'autre (le contenu défile).
            Form { tabContent }
                .formStyle(.grouped)
                .frame(maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 2) {
                ForEach(errors, id: \.self) { Text($0).font(.caption).foregroundStyle(.red) }
            }
            .frame(maxWidth: .infinity, minHeight: 36, alignment: .topLeading)
            .padding(.horizontal, 20).padding(.vertical, 4)
            Divider()
            HStack {
                Spacer()
                Button("Annuler", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(host == nil ? "Ajouter" : "Enregistrer") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!errors.isEmpty)
            }
            .padding(12)
        }
        .frame(width: 560, height: 640)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            load()
            form.saveAction = { if form.errors.isEmpty { save() } }
            HostEditorForm.current = form
        }
        .onDisappear { if HostEditorForm.current === form { HostEditorForm.current = nil } }
        .navigationTitle(host == nil ? "Nouvel hôte" : "Modifier l'hôte")
    }

    @ViewBuilder private var tabContent: some View {
        switch form.tab {
        case .basic: basicTab
        case .advanced: advancedTab
        case .terminal: StartupCommandEditorSection(text: $form.startupCommand)
        case .network: TunnelEditorSection(tunnels: $form.tunnels)
        case .protocolSettings:
            ProtocolEditorSection(model: model, connectionProtocol: form.connectionProtocol,
                                  serial: $form.serial, telnet: $form.telnet, vnc: $form.vnc, rdp: $form.rdp)
        }
    }

    private var basicTab: some View {
        let p = form.connectionProtocol
        return Group {
            Section {
                TextField("Nom", text: $form.name, prompt: Text(p == .serial ? "Nom du port si vide" : "Identique à l'hôte si vide"))
                if p != .serial {
                    TextField("Hôte", text: $form.hostname, prompt: Text(form.isSSH ? "nom, adresse IP ou alias ssh_config" : "nom ou adresse IP"))
                        .disableAutocorrection(true)
                    TextField("Port", text: $form.port, prompt: Text(p.defaultPort.map(String.init) ?? ""))
                }
                if p != .serial && p != .vnc {
                    TextField("Utilisateur", text: $form.user, prompt: Text(form.isSSH ? "Utilisateur courant" : "facultatif"))
                }
            }
            if form.isSSH {
                sshAuthSection
            }
            Section {
                TextField("Étiquettes", text: $form.tags, prompt: Text("prod, web"))
                Picker("Dossier", selection: $form.folderID) {
                    Text("Racine").tag(UUID?.none)
                    ForEach(model.library.allFolderPaths, id: \.id) { Text($0.path).tag(UUID?.some($0.id)) }
                }
            }
        }
    }

    private var keyDisplayLabel: String {
        form.keyPath.isEmpty ? String(localized: "Aucun fichier choisi") : SSHKeyDiscovery.abbreviatedPath(form.keyPath)
    }

    private var sshAuthSection: some View {
        Section("Authentification") {
            Picker("Méthode", selection: $form.authChoice) {
                Text("Réglages OpenSSH par défaut").tag(HostEditorAuthChoice.defaults)
                Text("Fichier de clé").tag(HostEditorAuthChoice.keyFile)
                Text("Mot de passe (Trousseau)").tag(HostEditorAuthChoice.keychain)
            }
            if form.authChoice == .keyFile {
                LabeledContent("Clé privée") {
                    HStack(spacing: 8) {
                        if !discoveredKeys.isEmpty {
                            Menu {
                                ForEach(discoveredKeys) { key in
                                    Button {
                                        form.keyPath = key.path
                                    } label: {
                                        if form.keyPath == key.path {
                                            Label(key.displayPath, systemImage: "checkmark")
                                        } else {
                                            Text(key.displayPath)
                                        }
                                    }
                                }
                                Divider()
                                Button("Autre fichier…") { chooseKey() }
                            } label: {
                                Text(keyDisplayLabel)
                                    .foregroundStyle(form.keyPath.isEmpty ? .secondary : .primary)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                            .menuStyle(.borderedButton)
                            .help(form.keyPath.isEmpty ? String(localized: "Aucun fichier choisi") : form.keyPath)
                            .frame(maxWidth: 260, alignment: .trailing)
                        } else {
                            // Chemin long : troncature au milieu (début et nom du fichier restent lisibles), chemin complet en infobulle.
                            Text(keyDisplayLabel)
                                .foregroundStyle(form.keyPath.isEmpty ? .secondary : .primary)
                                .lineLimit(1).truncationMode(.middle)
                                .help(form.keyPath.isEmpty ? String(localized: "Aucun fichier choisi") : form.keyPath)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                        Button("Choisir…") { chooseKey() }
                    }
                }
                Text("Si la clé est protégée par une phrase de passe, elle vous sera demandée à la connexion.")
                    .font(.caption).foregroundStyle(.secondary)
                if hasStoredPassphrase {
                    HStack {
                        Label("Une phrase de passe est enregistrée dans le Trousseau.", systemImage: "checkmark.seal")
                            .font(.caption)
                        Spacer()
                        Button("Oublier") { forgetPassphrase() }.controlSize(.small)
                    }
                } else if let m = passphraseMessage {
                    Text(m).font(.caption).foregroundStyle(.secondary)
                }
            }
            if form.authChoice == .keychain {
                Text("Le mot de passe est demandé à la première connexion. La case « Mémoriser dans le Trousseau » l'enregistre, après une connexion réussie.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if hasStoredSecret {
                    HStack {
                        Label("Un mot de passe est enregistré dans le Trousseau.", systemImage: "checkmark.seal")
                            .font(.caption)
                        Spacer()
                        Button("Oublier le mot de passe enregistré") { forgetSecret() }.controlSize(.small)
                    }
                } else if let m = secretMessage {
                    Text(m).font(.caption).foregroundStyle(.secondary)
                }
            }
            if form.authChoice == .defaults {
                Text("Agent ssh, clés par défaut et ~/.ssh/config.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var advancedTab: some View {
        Section {
            TextField("Bastions", text: $form.jumpHosts, prompt: Text("user@bastion:22, autre-bastion"))
        }
        X11EditorSection(isOn: $form.x11Forwarding, detect: { [connections = model.connections] in connections.x11Detect() })
        AgentAccessEditorSection(access: $form.agentAccess)
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        form.load(host: host, initialFolder: initialFolder)
        discoveredKeys = SSHKeyDiscovery.discover()
        if host != nil {
            refreshStoredSecret()
            refreshStoredPassphrase()
        }
    }

    private var account: String { form.account }

    private func refreshStoredSecret() {
        let store = model.connections.secretStore, account = account
        Task { hasStoredSecret = ((try? await store.secret(for: account)) ?? nil) != nil }
    }

    private func forgetSecret() {
        let store = model.connections.secretStore, account = account
        Task {
            do { try await store.removeSecret(for: account); hasStoredSecret = false; secretMessage = String(localized: "Mot de passe oublié.") }
            catch { secretMessage = "Suppression impossible : \(error)" }
        }
    }

    private func refreshStoredPassphrase() {
        let store = model.connections.secretStore, account = form.passphraseAccount
        Task { hasStoredPassphrase = ((try? await store.secret(for: account)) ?? nil) != nil }
    }

    private func forgetPassphrase() {
        let store = model.connections.secretStore, account = form.passphraseAccount
        Task {
            do {
                try await store.removeSecret(for: account)
                hasStoredPassphrase = false
                passphraseMessage = String(localized: "Phrase de passe oubliée.")
            } catch {
                passphraseMessage = "Suppression impossible : \(error)"
            }
        }
    }

    private func chooseKey() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = SSHKeyDiscovery.defaultSSHDirectory
        panel.prompt = String(localized: "Choisir")
        panel.message = String(localized: "Choisissez le fichier de clé privée (il n'est jamais copié ni modifié).")
        if panel.runModal() == .OK, let url = panel.url { form.keyPath = url.path }
    }

    private func save() {
        let h = form.makeProfile(base: host)
        // Méthode quittée ou clé changée : aucun secret enregistré ne doit rester orphelin dans le Trousseau.
        if let old = host {
            let store = model.connections.secretStore, hid = old.id
            if case .keychainPassword = old.auth, form.authChoice != .keychain {
                Task { try? await store.removeSecret(for: AuthKeychain.passwordAccount(for: hid)) }
            }
            if case .keyFile(let oldPath) = old.auth {
                let newPath = form.keyPath.trimmingCharacters(in: .whitespaces)
                if form.authChoice != .keyFile || oldPath != newPath {
                    Task { try? await store.removeSecret(for: AuthKeychain.passphraseAccount(for: hid)) }
                }
            }
        }
        let previousTunnels = host?.tunnels ?? []
        model.library.upsert(h)
        model.tunnels.hostSaved(oldTunnels: previousTunnels, host: h) // modification à chaud des tunnels actifs
        dismiss()
    }
}

/// Création ou renommage d'un dossier.
struct FolderSheet: View {
    let model: AppModel
    let folder: HostFolder?
    let parent: UUID?
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    private var trimmed: String { name.trimmingCharacters(in: .whitespaces) }
    private var error: String? { HostFormValidation.name(name) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(folder == nil ? "Nouveau dossier" : "Renommer le dossier").font(.headline)
            TextField("Nom", text: $name).onSubmit(save)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Annuler", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(folder == nil ? "Créer" : "Renommer", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty || error != nil)
            }
        }
        .padding(20)
        .frame(width: 340)
        .onAppear { name = folder?.name ?? "" }
    }

    private func save() {
        guard !trimmed.isEmpty, error == nil else { return }
        if let f = folder { model.library.renameFolder(f.id, to: trimmed) } else { model.library.addFolder(name: trimmed, parentID: parent) }
        dismiss()
    }
}
