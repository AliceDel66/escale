import SwiftUI
import EscaleCore

/// Onglets du dialogue de session (façon « Session settings » de MobaXterm). Les onglets dépendent du protocole.
enum HostEditorTab: Hashable, CaseIterable {
    case basic, advanced, terminal, network
    /// Réglages propres au protocole non SSH (Série, Telnet, VNC, RDP), tels que les décrit `ProtocolEditorSection`.
    case protocolSettings

    /// Onglets proposés pour un protocole : SSH a les quatre groupes, les autres protocoles « Basique » + leurs réglages.
    static func tabs(for p: ConnectionProtocol) -> [HostEditorTab] {
        p == .ssh ? [.basic, .advanced, .terminal, .network] : [.basic, .protocolSettings]
    }

    func title(for p: ConnectionProtocol) -> String {
        switch self {
        case .basic: String(localized: "Basique")
        case .advanced: String(localized: "Avancé")
        case .terminal: String(localized: "Terminal")
        case .network: String(localized: "Réseau")
        case .protocolSettings: HostEditorBanner.shortName(p)
        }
    }

    var symbolName: String {
        switch self {
        case .basic: "person.text.rectangle"
        case .advanced: "gearshape.2"
        case .terminal: "terminal"
        case .network: "arrow.left.arrow.right"
        case .protocolSettings: "slider.horizontal.3"
        }
    }
}

/// Méthode d'authentification choisie dans l'éditeur (traduite en `HostProfile.Auth` à l'enregistrement).
enum HostEditorAuthChoice: Hashable { case defaults, keyFile, keychain }

/// État de la feuille d'édition d'hôte : tous les champs du dialogue, leur chargement, leur validation et la
/// construction du profil. Séparé de la vue pour que la recette `--selftest-hosteditor` puisse la piloter.
@MainActor @Observable
final class HostEditorForm {
    var name = ""
    var hostname = ""
    var port = ""
    var user = ""
    var authChoice: HostEditorAuthChoice = .defaults
    var keyPath = ""
    var jumpHosts = ""
    var tags = ""
    var folderID: UUID?
    var tunnels: [TunnelSpec] = []
    var x11Forwarding = false
    var agentAccess: AgentAccess = .none
    var startupCommand = ""
    var connectionProtocol: ConnectionProtocol = .ssh
    var serial = SerialSettings()
    var telnet = TelnetSettings()
    var vnc = VNCSettings()
    var rdp = RDPSettings()
    /// Onglet affiché.
    var tab: HostEditorTab = .basic
    /// Identifiant de l'hôte (celui de l'hôte édité, ou un nouvel identifiant) : le compte Trousseau en dérive.
    var hostID = UUID()

    /// Enregistrement demandé par la recette (même chemin que le bouton « Enregistrer »), posé par la feuille.
    var saveAction: (() -> Void)?

    /// Formulaire actuellement affiché (recette `--selftest-hosteditor` uniquement).
    static weak var current: HostEditorForm?

    var isSSH: Bool { connectionProtocol == .ssh }
    var tabs: [HostEditorTab] { HostEditorTab.tabs(for: connectionProtocol) }

    /// Changement de protocole par le bandeau : l'onglet courant est conservé s'il existe encore, sinon « Basique ».
    func selectProtocol(_ p: ConnectionProtocol) {
        connectionProtocol = p
        if !tabs.contains(tab) { tab = .basic }
    }

    func load(host h: HostProfile?, initialFolder: UUID?) {
        folderID = initialFolder
        guard let h else { return }
        hostID = h.id
        name = h.name; hostname = h.host; port = h.port.map(String.init) ?? ""; user = h.user ?? ""
        jumpHosts = h.jumpHosts.joined(separator: ", "); tags = h.tags.joined(separator: ", ")
        tunnels = h.tunnels; x11Forwarding = h.x11Forwarding; agentAccess = h.agentAccess; startupCommand = h.startupCommand ?? ""
        connectionProtocol = h.connectionProtocol
        serial = h.serial ?? SerialSettings(); telnet = h.telnet ?? TelnetSettings()
        vnc = h.vnc ?? VNCSettings(); rdp = h.rdp ?? RDPSettings()
        switch h.auth {
        case .openSSHDefaults: authChoice = .defaults
        case .keyFile(let p): authChoice = .keyFile; keyPath = p
        case .keychainPassword: authChoice = .keychain
        }
    }

    var account: String { AuthKeychain.passwordAccount(for: hostID) }
    var passphraseAccount: String { AuthKeychain.passphraseAccount(for: hostID) }

    var errors: [String] {
        var e: [String] = []
        // Série : pas d'hôte réseau (le port série est dans la section du module).
        let needsHost = connectionProtocol != .serial
        [HostFormValidation.name(name), needsHost ? HostFormValidation.host(hostname) : nil,
         needsHost ? HostFormValidation.port(port) : nil, HostFormValidation.user(user)].forEach { if let m = $0 { e.append(m) } }
        e += ProtocolEditorSection.errors(connectionProtocol, serial: serial, telnet: telnet, vnc: vnc, rdp: rdp)
        guard isSSH else { return e }
        [authChoice == .keyFile ? HostFormValidation.keyPath(keyPath) : nil,
         HostFormValidation.jumpHosts(jumpHosts)].forEach { if let m = $0 { e.append(m) } }
        if let m = StartupCommand.validationMessage(startupCommand) { e.append(m) }
        e += TunnelValidation.listErrors(tunnels) + tunnels.filter { !TunnelValidation.errors($0).isEmpty }.map { String(localized: "Tunnel « \($0.title) » invalide.") }
        return e
    }

    /// Profil à enregistrer : `base` (l'hôte édité) mis à jour avec les champs du formulaire.
    func makeProfile(base: HostProfile?) -> HostProfile {
        let hostTrim = hostname.trimmingCharacters(in: .whitespaces)
        let nameTrim = name.trimmingCharacters(in: .whitespaces)
        let userTrim = user.trimmingCharacters(in: .whitespaces)
        let auth: HostProfile.Auth = switch authChoice {
        case .defaults: .openSSHDefaults
        case .keyFile: .keyFile(path: keyPath.trimmingCharacters(in: .whitespaces))
        case .keychain: .keychainPassword(account: account)
        }
        var h = base ?? HostProfile(id: hostID, name: "", host: "")
        h.connectionProtocol = connectionProtocol
        h.serial = connectionProtocol == .serial ? serial : nil
        h.telnet = connectionProtocol == .telnet ? telnet : nil
        h.vnc = connectionProtocol == .vnc ? vnc : nil
        h.rdp = connectionProtocol == .rdp ? rdp : nil
        // Série : le « hôte » affiché est le périphérique (barre latérale, recherche).
        let isSerial = connectionProtocol == .serial
        let shownHost = isSerial ? serial.devicePath : hostTrim
        h.name = !nameTrim.isEmpty ? nameTrim : (isSerial ? (shownHost as NSString).lastPathComponent : hostTrim)
        h.host = shownHost
        h.port = isSerial ? nil : Int(port.trimmingCharacters(in: .whitespaces))
        h.user = userTrim.isEmpty ? nil : userTrim
        h.auth = auth
        h.jumpHosts = HostFormValidation.split(jumpHosts)
        h.tags = HostFormValidation.split(tags)
        h.folderID = folderID
        h.tunnels = tunnels
        h.x11Forwarding = x11Forwarding
        // Protocoles non SSH : jamais exposés aux agents.
        h.agentAccess = connectionProtocol == .ssh ? agentAccess : .none
        h.startupCommand = StartupCommand.normalized(startupCommand)
        return h
    }
}

/// Bandeau d'icônes de protocoles en tête du dialogue : sélection exclusive.
struct HostEditorBanner: View {
    @Bindable var form: HostEditorForm

    static func shortName(_ p: ConnectionProtocol) -> String { p == .rdp ? "RDP" : p.localizedDisplayName }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(ConnectionProtocol.allCases, id: \.self) { p in
                let selected = form.connectionProtocol == p
                Button { form.selectProtocol(p) } label: {
                    VStack(spacing: 4) {
                        Image(systemName: p.symbolName).font(.system(size: 26, weight: .regular))
                            .frame(height: 30)
                        Text(p == .rdp ? LocalizedStringKey("RDP") : p.localizedDisplayNameKey).font(.callout)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 8)
                    .foregroundStyle(selected ? Color.accentColor : Color.primary)
                    .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.accentColor.opacity(0.15) : Color.clear))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: selected ? 1.5 : 1))
                    .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .help(p.localizedDisplayNameKey)
                .accessibilityLabel(p.localizedDisplayNameKey)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }
}
