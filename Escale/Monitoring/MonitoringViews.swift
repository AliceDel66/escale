import SwiftUI
import AppKit
import EscaleCore

// MARK: - Commande de menu (menu Présentation)

struct MonitoringCommands: Commands {
    let model: AppModel
    var body: some Commands {
        CommandGroup(after: .sidebar) {
            let feature = model.monitoring
            let host = feature.activeHostID
            Button(host.map { feature.isEnabled(host: $0) } == true ? "Masquer le monitoring distant" : "Afficher le monitoring distant") {
                if let host { feature.toggle(host: host) }
            }
            .keyboardShortcut("u", modifiers: [.command, .option])
            .disabled(host == nil)
        }
    }
}

/// Entrée du menu contextuel d'un hôte SSH (barre latérale) : active ou coupe la barre pour cet hôte.
struct MonitoringHostMenuItems: View {
    let model: AppModel
    let host: HostProfile
    var body: some View {
        Button(model.monitoring.isEnabled(host: host.id) ? "Masquer le monitoring distant" : "Afficher le monitoring distant") {
            model.monitoring.toggle(host: host.id)
        }
    }
}

// MARK: - Barre

/// Barre fine sous le terminal (hors de la grille), sobre : valeurs en police à chasse fixe, sans fioriture.
/// Les éléments les moins utiles disparaissent d'abord quand le panneau est étroit.
struct MonitoringBar: View {
    static let height: CGFloat = 22

    let feature: MonitoringFeature
    let monitor: MonitoringFeature.Monitor
    let hostName: String

    /// Un élément de la barre : symbole, étiquette courte, valeur, infobulle.
    struct Item: Identifiable {
        let id: String
        let symbol: String
        let label: String
        let value: String
        let help: String
    }

    /// Éléments d'un instantané, par ordre de priorité décroissante (le dernier disparaît en premier).
    static func items(_ s: MonitoringSnapshot) -> [Item] {
        let memValue: String
        if let u = s.memUsed, let t = s.memTotal { memValue = "\(MonitoringFormat.bytes(u)) / \(MonitoringFormat.bytes(t))" } else { memValue = "—" }
        let disk = s.diskPercent.map { "\($0) %" } ?? "—"
        let diskHelp: String
        if let u = s.diskUsed, let t = s.diskTotal { diskHelp = String(localized: "Disque de / : \(MonitoringFormat.bytes(u)) utilisés sur \(MonitoringFormat.bytes(t))") } else { diskHelp = String(localized: "Disque de /") }
        return [
            Item(id: "cpu", symbol: "cpu", label: "CPU", value: MonitoringFormat.percent(s.cpuPercent), help: String(localized: "Processeur (moyenne depuis le relevé précédent)")),
            Item(id: "mem", symbol: "memorychip", label: String(localized: "Mém"), value: memValue, help: String(localized: "Mémoire utilisée / totale (hors cache)")),
            Item(id: "load", symbol: "gauge.with.dots.needle.33percent", label: String(localized: "Charge"), value: MonitoringFormat.load(s.load1), help: String(localized: "Charge moyenne sur 1 minute")),
            Item(id: "disk", symbol: "internaldrive", label: String(localized: "Disque"), value: disk, help: diskHelp),
            Item(id: "net", symbol: "arrow.up.arrow.down", label: String(localized: "Réseau"),
                 value: "↓ \(MonitoringFormat.rate(s.netInRate))  ↑ \(MonitoringFormat.rate(s.netOutRate))",
                 help: String(localized: "Débit réseau entrant et sortant (interfaces physiques)")),
            Item(id: "users", symbol: "person.2", label: String(localized: "Util."), value: s.users.map(String.init) ?? "—", help: String(localized: "Utilisateurs connectés")),
            Item(id: "up", symbol: "clock", label: String(localized: "Actif"), value: MonitoringFormat.uptime(s.uptime), help: String(localized: "Durée depuis le démarrage du serveur")),
        ]
    }

    /// Texte exact de la barre (tests, accessibilité).
    static func summary(_ s: MonitoringSnapshot) -> String {
        items(s).map { "\($0.label) \($0.value)" }.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 0) {
            content
            Spacer(minLength: 4)
            Button { feature.setEnabled(false, host: monitor.hostID) } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Masquer le monitoring distant de \(hostName)")
            .accessibilityLabel("Masquer le monitoring distant")
            .padding(.horizontal, 8)
        }
        .padding(.leading, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .font(.system(size: 11, design: .monospaced))
        .background(Color(white: 0.11))
        .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.12)).frame(height: 1) }
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Monitoring distant de \(hostName)")
    }

    @ViewBuilder private var content: some View {
        switch monitor.phase {
        case .running:
            if let s = monitor.snapshot { metrics(s) } else { message(String(localized: "Monitoring distant…"), spinner: true) }
        case .starting: message(String(localized: "Monitoring distant…"), spinner: true)
        case .waiting:
            if let s = monitor.snapshot { metrics(s).opacity(0.45) } else { message(String(localized: "Monitoring en pause (connexion perdue)"), spinner: false) }
        case .unsupported: message(String(localized: "Monitoring indisponible sur ce système"), spinner: false)
        case .busy: message(String(localized: "Monitoring indisponible : sessions du serveur épuisées"), spinner: false)
        case .failed(let m): message(String(localized: "Monitoring indisponible : \(m)"), spinner: false)
        }
    }

    private func message(_ text: String, spinner: Bool) -> some View {
        HStack(spacing: 6) {
            if spinner { ProgressView().controlSize(.mini).scaleEffect(0.7) }
            Text(text).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
        }
    }

    /// `ViewThatFits` retire d'abord l'uptime, puis les utilisateurs, etc. ; l'ordre garde CPU et mémoire en dernier.
    private func metrics(_ s: MonitoringSnapshot) -> some View {
        let all = Self.items(s)
        return ViewThatFits(in: .horizontal) {
            row(Array(all.prefix(7)))
            row(Array(all.prefix(6)))
            row(Array(all.prefix(5)))
            row(Array(all.prefix(4)))
            row(Array(all.prefix(3)))
            row(Array(all.prefix(2)))
            row(Array(all.prefix(1)))
        }
    }

    private func row(_ items: [Item]) -> some View {
        HStack(spacing: 14) {
            ForEach(items) { i in
                HStack(spacing: 4) {
                    Image(systemName: i.symbol).font(.system(size: 10)).foregroundStyle(.secondary)
                    ZStack(alignment: .leading) {
                        // Débit : gabarit invisible de la valeur la plus large, pour que « — » (premier relevé) puis
                        // « 211 Ko/s » ne décalent pas les éléments suivants d'une barre à l'autre.
                        if i.id == "net" { Text("↓ 999,9 Ko/s  ↑ 999,9 Ko/s").lineLimit(1).fixedSize().hidden() }
                        Text(i.value).lineLimit(1).fixedSize()
                    }
                }
                .help("\(i.label) — \(i.help)")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(i.label) \(i.value)")
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}
