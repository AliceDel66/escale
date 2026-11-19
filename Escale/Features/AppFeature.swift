import SwiftUI
import EscaleCore

/// Module ajouté après M1 (SFTP, tunnels, multi-exécution, macros/X11, imports, mises à jour).
/// Chaque module vit dans son dossier et ne s'accroche à l'app que par les points ci-dessous :
/// - `attach` (une fois, à la fin de `AppModel.init`) et `shutdown` (avant la déconnexion des maîtres) ;
/// - ses commandes (`FeatureCommands`), ses scènes (`FeatureScenes` : inspecteur, feuilles, bandeaux),
///   ses entrées de menu d'hôte (`FeatureHostMenuItems`, `FeatureSelectionMenuItems`) ;
/// - les observateurs de liens (`ConnectionManager.linkObservers`) et de saisie (`TerminalSession.inputObservers`) ;
/// - son scénario d'auto-test (`AppModel.featureSelfTests`, option `--selftest-<module> <dossier>`).
@MainActor
protocol AppFeature: AnyObject {
    func attach(_ model: AppModel)
    func shutdown() async
}

/// Commandes de menu de tous les modules.
struct FeatureCommands: Commands {
    let model: AppModel
    var body: some Commands {
        SFTPCommands(model: model)
        TunnelCommands(model: model)
        MultiExecCommands(model: model)
        MacroCommands(model: model)
        ImportCommands(model: model)
        UpdateCommands(model: model)
        MonitoringCommands(model: model)
        TerminalColorsCommands(model: model)
        MCPCommands(model: model)
        SettingsCommands(model: model)
    }
}

/// Inspecteurs, feuilles et bandeaux de tous les modules, appliqués à la fenêtre principale.
/// Une feuille de module renseigne `model.activeFeatureSheet` tant qu'elle est ouverte : les dialogues
/// d'authentification attendent alors sa fermeture (jamais deux feuilles empilées).
struct FeatureScenes: ViewModifier {
    let model: AppModel
    func body(content: Content) -> some View {
        content
            .modifier(SFTPScene(model: model))
            .modifier(TunnelScene(model: model))
            .modifier(MultiExecScene(model: model))
            .modifier(MacroScene(model: model))
            .modifier(ImportScene(model: model))
            .modifier(UpdateScene(model: model))
            .modifier(SerialScene(model: model))
            .modifier(TelnetScene(model: model))
            .modifier(VNCScene(model: model))
            .modifier(RDPScene(model: model))
            .modifier(MCPScene(model: model))
    }
}

/// Entrées du menu contextuel d'un hôte (barre latérale), après « Nouvel onglet ».
struct FeatureHostMenuItems: View {
    let model: AppModel
    let host: HostProfile
    var body: some View {
        switch host.connectionProtocol {
        case .ssh:
            SFTPHostMenuItems(model: model, host: host)
            TunnelHostMenuItems(model: model, host: host)
            MacroHostMenuItems(model: model, host: host)
            MonitoringHostMenuItems(model: model, host: host)
            TerminalColorsHostMenuItems(feature: model.colors, host: host)
        case .serial:
            SerialHostMenuItems(model: model, host: host)
            TerminalColorsHostMenuItems(feature: model.colors, host: host)
        case .telnet:
            TelnetHostMenuItems(model: model, host: host)
            TerminalColorsHostMenuItems(feature: model.colors, host: host)
        case .vnc: VNCHostMenuItems(model: model, host: host)
        case .rdp: RDPHostMenuItems(model: model, host: host)
        }
    }
}

/// Entrées du menu contextuel d'une sélection de plusieurs hôtes.
struct FeatureSelectionMenuItems: View {
    let model: AppModel
    let hosts: [HostProfile]
    var body: some View {
        // Multi-exécution : hôtes SSH seulement (commande par maître ssh).
        MultiExecSelectionMenuItems(model: model, hosts: hosts.filter { $0.connectionProtocol == .ssh })
    }
}

/// Entrées du menu contextuel d'un dossier de la bibliothèque (barre latérale).
struct FeatureFolderMenuItems: View {
    let model: AppModel
    let folder: HostFolder
    var body: some View {
        MultiExecFolderMenuItems(model: model, folder: folder)
    }
}
