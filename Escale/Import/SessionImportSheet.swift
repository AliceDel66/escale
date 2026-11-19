import SwiftUI
import EscaleCore

/// Feuille d'aperçu de l'import de sessions MobaXterm / PuTTY / Termius / CSV (même présentation que `ImportSheet`).
struct SessionImportSheet: View {
    let model: AppModel
    @Bindable var importer: SessionImportModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(importer.kind.title).font(.headline)
                Text(importer.source.path).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).help(importer.source.path)
                Text("Le fichier est lu sans jamais être modifié. Les mots de passe ne sont jamais importés.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 8)

            if let error = importer.error {
                Text(error).foregroundStyle(.red).padding(20).frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
            } else if importer.sessions.isEmpty {
                Text("Aucune session importable trouvée dans ce fichier.").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                List { ForEach(importer.sessions) { row($0) } }
                    .listStyle(.bordered).padding(.horizontal, 20).frame(minHeight: 180)
            }

            VStack(alignment: .leading, spacing: 2) {
                if let notice = importer.passwordNotice {
                    Label(notice, systemImage: "key.slash").font(.caption).foregroundStyle(.orange)
                }
                ForEach(importer.warnings, id: \.self) { w in
                    Label(w, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20).padding(.top, 8)

            HStack {
                Picker("Dossier", selection: $importer.folderID) {
                    Text("Racine").tag(UUID?.none)
                    ForEach(model.library.allFolderPaths, id: \.id) { Text($0.path).tag(UUID?.some($0.id)) }
                }
                .frame(maxWidth: 280)
                Toggle("Garder les dossiers d'origine", isOn: $importer.keepFolders).toggleStyle(.checkbox)
                Spacer()
                if importer.importableCount > 0 {
                    Button("Tout cocher") { importer.selectAll() }.buttonStyle(.link).controlSize(.small)
                    Button("Tout décocher") { importer.selected = [] }.buttonStyle(.link).controlSize(.small)
                }
            }
            .padding(.horizontal, 20).padding(.top, 10)

            Divider().padding(.top, 12)
            HStack {
                Spacer()
                Button("Annuler", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(importer.selected.isEmpty ? "Importer"
                       : "Importer \(importer.selected.count) hôte\(importer.selected.count > 1 ? "s" : "")") {
                    importer.commit()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(importer.selected.isEmpty)
            }
            .padding(12)
        }
        .frame(width: 620)
    }

    @ViewBuilder private func row(_ s: ImportedSession) -> some View {
        let importable = importer.isImportable(s)
        HStack(alignment: .top, spacing: 8) {
            Toggle("", isOn: Binding(
                get: { importer.selected.contains(s.id) },
                set: { on in if on { importer.selected.insert(s.id) } else { importer.selected.remove(s.id) } }))
                .labelsHidden().disabled(!importable)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Image(systemName: s.connectionProtocol.symbolName).foregroundStyle(.secondary)
                        .help(s.connectionProtocol.localizedDisplayNameKey).accessibilityLabel(s.connectionProtocol.localizedDisplayNameKey)
                    Text(s.name).fontWeight(.medium)
                    if !importable {
                        Text("déjà présent").font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                }
                Text(detail(s)).font(.caption).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .opacity(importable ? 1 : 0.45)
        .accessibilityElement(children: .combine)
    }

    private func detail(_ s: ImportedSession) -> String {
        var parts = [(s.user.map { "\($0)@" } ?? "") + s.host + (s.port.map { ":\($0)" } ?? "")]
        if s.connectionProtocol != .ssh { parts.insert(s.connectionProtocol.localizedDisplayName, at: 0) }
        if let serial = s.serial {
            parts[parts.count - 1] = serial.devicePath.isEmpty ? String(localized: "port à choisir") : serial.devicePath
            parts.append(String(localized: "\(serial.baudRate) bauds"))
        }
        if !s.folderPath.isEmpty { parts.append(String(localized: "Dossier : \(s.folderPath.joined(separator: " / "))")) }
        if !s.jumpHosts.isEmpty { parts.append(String(localized: "Bastion : \(s.jumpHosts.joined(separator: ", "))")) }
        if !s.tunnels.isEmpty {
            parts.append(s.tunnels.count == 1 ? String(localized: "1 tunnel") : String(localized: "\(s.tunnels.count) tunnels"))
        }
        if s.x11Forwarding { parts.append("X11") }
        if !s.tags.isEmpty { parts.append(s.tags.map { "#\($0)" }.joined(separator: " ")) }
        return parts.joined(separator: "  ·  ")
    }
}
