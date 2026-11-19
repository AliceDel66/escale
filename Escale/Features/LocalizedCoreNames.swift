import SwiftUI
import EscaleCore

/// Libellés localisés des modèles de `EscaleCore` affichés dans l'interface.
/// `EscaleCore` reste indépendant de `Bundle.main` ; la traduction passe par le catalogue de l'app.
extension ConnectionProtocol {
    var localizedDisplayName: String {
        switch self {
        case .ssh: "SSH"
        case .telnet: "Telnet"
        case .serial: String(localized: "Série")
        case .vnc: "VNC"
        case .rdp: String(localized: "Bureau à distance (RDP)")
        }
    }

    var localizedDisplayNameKey: LocalizedStringKey {
        switch self {
        case .ssh: "SSH"
        case .telnet: "Telnet"
        case .serial: "Série"
        case .vnc: "VNC"
        case .rdp: "Bureau à distance (RDP)"
        }
    }
}

extension TerminalTheme {
    var localizedName: String {
        switch id {
        case "system": String(localized: "Système")
        case "classic": String(localized: "Classique (fond noir)")
        case "solarized-dark": String(localized: "Solarized sombre")
        case "solarized-light": String(localized: "Solarized clair")
        case "tango": String(localized: "Tango sombre")
        case "paper": String(localized: "Papier (clair)")
        default: name
        }
    }

    var localizedNameKey: LocalizedStringKey {
        switch id {
        case "system": "Système"
        case "classic": "Classique (fond noir)"
        case "solarized-dark": "Solarized sombre"
        case "solarized-light": "Solarized clair"
        case "tango": "Tango sombre"
        case "paper": "Papier (clair)"
        default: LocalizedStringKey(name)
        }
    }
}

extension HighlightRuleSet {
    var localizedTitle: String {
        switch self {
        case .off: String(localized: "Désactivé")
        case .keywords: String(localized: "Mots-clés")
        case .keywordsAndNetwork: String(localized: "Mots-clés et réseau")
        }
    }

    var localizedTitleKey: LocalizedStringKey {
        switch self {
        case .off: "Désactivé"
        case .keywords: "Mots-clés"
        case .keywordsAndNetwork: "Mots-clés et réseau"
        }
    }
}

extension RDPSettings.DisplayMode {
    var localizedDisplayNameKey: LocalizedStringKey {
        switch self {
        case .fullScreen: "Plein écran"
        case .window: "Fenêtre (taille dynamique)"
        case .fixedSize: "Taille fixe"
        }
    }
}

extension RDPSettings.AudioMode {
    var localizedDisplayNameKey: LocalizedStringKey {
        switch self {
        case .local: "Sur ce Mac"
        case .remote: "Sur l'ordinateur distant"
        case .none: "Aucun"
        }
    }
}

extension TelnetSettings.LineEnding {
    var localizedDisplayNameKey: LocalizedStringKey {
        switch self {
        case .standard: "Standard (CR NUL)"
        case .crlf: "CR LF"
        case .cr: "CR seul"
        }
    }
}

extension VNCEncodingPreference {
    var localizedDisplayNameKey: LocalizedStringKey {
        switch self {
        case .auto: "Automatique"
        case .zrle: "ZRLE"
        case .hextile: "Hextile"
        case .raw: "Brut (Raw)"
        }
    }
}

extension VNCScaling {
    var localizedDisplayNameKey: LocalizedStringKey {
        switch self {
        case .fit: "Ajuster à la fenêtre"
        case .actual: "100 %"
        }
    }
}
