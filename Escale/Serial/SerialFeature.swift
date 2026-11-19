import SwiftUI
import EscaleCore

/// Module Série (termios). Ne s'accroche à l'app que par `attach` (`AppModel.terminalLaunchers`),
/// `SerialScene`, `SerialHostMenuItems`, `SerialEditorSection` et `--selftest-serial`.
@MainActor
@Observable
final class SerialFeature: AppFeature {
    @ObservationIgnored private(set) weak var model: AppModel?
    /// Ports ouverts, par panneau (références faibles : le panneau garde la vie du flux via sa session).
    @ObservationIgnored private var ports: [UUID: WeakPort] = [:]

    private struct WeakPort { weak var port: SerialPort? }

    func attach(_ model: AppModel) {
        self.model = model
        model.terminalLaunchers[.serial] = { [weak self] pane, host in
            guard let settings = host.serial else { throw SerialPortError.emptyPath }
            let port = try SerialPort(settings: settings)
            self?.ports[pane.id] = WeakPort(port: port)
            return port
        }
    }

    func shutdown() async {
        for p in ports.values { p.port?.kill() }
        ports.removeAll()
    }

    /// Port ouvert du panneau actif de l'hôte (onglet sélectionné d'abord), sinon d'un de ses onglets.
    func openPort(forHost id: UUID) -> SerialPort? {
        guard let model else { return nil }
        ports = ports.filter { $0.value.port != nil }
        let tabs = model.workspace.tabs(forHost: id)
        let ordered = tabs.filter { $0.id == model.workspace.activeTab?.id } + tabs.filter { $0.id != model.workspace.activeTab?.id }
        for tab in ordered {
            let panes = [tab.activePane] + tab.panes.filter { $0.id != tab.activePane.id }
            for pane in panes where pane.hostID == id {
                if let p = ports[pane.id]?.port, p.isOpen { return p }
            }
        }
        return nil
    }
}

/// Feuilles, inspecteurs, bandeaux du module (fenêtre principale) : aucun.
struct SerialScene: ViewModifier {
    let model: AppModel
    func body(content: Content) -> some View { content }
}

/// Entrées du menu contextuel d'un hôte série : BREAK et lignes DTR/RTS du port ouvert de cet hôte.
struct SerialHostMenuItems: View {
    let model: AppModel
    let host: HostProfile
    var body: some View {
        let port = model.serial.openPort(forHost: host.id)
        Divider()
        Button("Envoyer BREAK") { _ = port?.sendBreak() }.disabled(port == nil)
        Button("Basculer DTR") { _ = port?.toggleLine(.dtr) }.disabled(port == nil)
        Button("Basculer RTS") { _ = port?.toggleLine(.rts) }.disabled(port == nil)
    }
}

/// Section de l'éditeur d'hôte quand le protocole est `.serial`.
struct SerialEditorSection: View {
    @Binding var settings: SerialSettings
    let model: AppModel

    @State private var detected: [DetectedSerialPort] = SerialPortDiscovery.list()
    @State private var customBaud = ""

    static let commonBauds = [300, 1200, 2400, 4800, 9600, 19200, 38400, 57600, 115_200, 230_400, 250_000, 460_800, 921_600]
    private static let customTag = -1

    var body: some View {
        Section("Port série") {
            HStack {
                Picker("Port détecté", selection: portSelection) {
                    Text("Saisie libre").tag("")
                    ForEach(portChoices) { Text($0.name).tag($0.path) }
                }
                Button { detected = SerialPortDiscovery.list() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Actualiser la liste des ports").accessibilityLabel("Actualiser")
            }
            TextField("Chemin du périphérique", text: $settings.devicePath, prompt: Text("/dev/cu.usbserial-…"))
        }
        Section("Liaison") {
            Picker("Débit", selection: baudSelection) {
                ForEach(Self.commonBauds, id: \.self) { Text("\($0) bauds").tag($0) }
                Text("Autre…").tag(Self.customTag)
            }
            if !Self.commonBauds.contains(settings.baudRate) || !customBaud.isEmpty {
                TextField("Débit (bauds)", text: Binding(
                    get: { customBaud.isEmpty ? String(settings.baudRate) : customBaud },
                    set: { customBaud = $0; if let v = Int($0.trimmingCharacters(in: .whitespaces)) { settings.baudRate = v } }))
            }
            Picker("Bits de données", selection: $settings.dataBits) { ForEach(5...8, id: \.self) { Text("\($0)").tag($0) } }
            Picker("Parité", selection: $settings.parity) {
                Text("Aucune").tag(SerialSettings.Parity.none); Text("Paire").tag(SerialSettings.Parity.even); Text("Impaire").tag(SerialSettings.Parity.odd)
            }
            Picker("Bits de stop", selection: $settings.stopBits) { Text("1").tag(1); Text("2").tag(2) }
            Picker("Contrôle de flux", selection: $settings.flowControl) {
                Text("Aucun").tag(SerialSettings.FlowControl.none)
                Text("Matériel (RTS/CTS)").tag(SerialSettings.FlowControl.hardware)
                Text("Logiciel (XON/XOFF)").tag(SerialSettings.FlowControl.software)
            }
        }
        Section("Saisie") {
            Picker("Fin de ligne à l'envoi", selection: $settings.lineEnding) {
                Text("CR").tag(SerialLineEnding.cr); Text("LF").tag(SerialLineEnding.lf); Text("CRLF").tag(SerialLineEnding.crlf)
            }
            Toggle("Écho local", isOn: $settings.localEcho)
        }
    }

    /// Ports détectés, plus le port déjà enregistré s'il n'est plus branché (pour ne pas perdre le choix).
    private var portChoices: [DetectedSerialPort] {
        let p = settings.devicePath
        guard !p.isEmpty, !detected.contains(where: { $0.path == p }) else { return detected }
        return detected + [DetectedSerialPort(path: p, name: String(localized: "\((p as NSString).lastPathComponent) (absent)"))]
    }

    private var portSelection: Binding<String> {
        Binding(get: { portChoices.contains { $0.path == settings.devicePath } ? settings.devicePath : "" },
                set: { if !$0.isEmpty { settings.devicePath = $0 } })
    }

    private var baudSelection: Binding<Int> {
        Binding(get: { Self.commonBauds.contains(settings.baudRate) && customBaud.isEmpty ? settings.baudRate : Self.customTag },
                set: { v in
                    if v == Self.customTag { customBaud = String(settings.baudRate) } else { customBaud = ""; settings.baudRate = v }
                })
    }
}
