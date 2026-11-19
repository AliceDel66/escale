import Foundation
import EscaleCore

/// Un élément du dossier distant affiché dans le navigateur.
/// Les chemins restent des octets (`Data`) : un nom non UTF-8 reste adressable.
struct SFTPItem: Identifiable, Hashable, Sendable {
    let name: String
    let path: Data
    var isDirectory: Bool
    var isSymlink: Bool
    var size: UInt64?
    var modified: Date?
    var permissions: UInt32?

    var id: Data { path }

    /// Droits façon `ls` (« rwxr-xr-x »).
    var permissionText: String {
        guard let p = permissions else { return "—" }
        let bits = Array("rwxrwxrwx")
        var out = ""
        for i in 0..<9 { out.append(p & (1 << UInt32(8 - i)) != 0 ? bits[i] : "-") }
        return out
    }
}

/// Opérations sur les chemins distants (POSIX, en octets).
enum SFTPPath {
    static func join(_ dir: Data, _ name: Data) -> Data {
        var d = dir
        if d.last != UInt8(ascii: "/") { d.append(UInt8(ascii: "/")) }
        d.append(name)
        return d
    }
    static func join(_ dir: Data, _ name: String) -> Data { join(dir, Data(name.utf8)) }

    static func parent(_ path: Data) -> Data {
        var p = path
        while p.count > 1, p.last == UInt8(ascii: "/") { p.removeLast() }
        guard let i = p.lastIndex(of: UInt8(ascii: "/")) else { return Data("/".utf8) }
        let idx = p.distance(from: p.startIndex, to: i)
        return idx == 0 ? Data("/".utf8) : Data(p.prefix(idx))
    }

    static func lastComponent(_ path: Data) -> String {
        var p = path
        while p.count > 1, p.last == UInt8(ascii: "/") { p.removeLast() }
        guard let i = p.lastIndex(of: UInt8(ascii: "/")) else { return String(decoding: p, as: UTF8.self) }
        return String(decoding: p.suffix(from: p.index(after: i)), as: UTF8.self)
    }

    static func string(_ path: Data) -> String { String(decoding: path, as: UTF8.self) }

    /// Sans barre finale (sauf la racine).
    static func normalized(_ path: Data) -> Data {
        var p = path
        while p.count > 1, p.last == UInt8(ascii: "/") { p.removeLast() }
        return p
    }

    /// `path` est `ancestor` ou un de ses descendants.
    static func isInside(_ path: Data, of ancestor: Data) -> Bool {
        let p = normalized(path), a = normalized(ancestor)
        if p == a { return true }
        return p.starts(with: a + Data("/".utf8))
    }
}

/// Colonne de tri du navigateur.
enum SFTPSortKey: String, CaseIterable, Sendable {
    case name, size, date
    var label: String { switch self { case .name: String(localized: "Nom"); case .size: String(localized: "Taille"); case .date: String(localized: "Date") } }
}

/// Tri de la liste : dossiers d'abord, puis la colonne choisie (le nom départage les égalités).
struct SFTPSort: Equatable, Sendable {
    var key: SFTPSortKey = .name
    var ascending = true

    private static let keyDefault = "escale.sftp.sortKey", orderDefault = "escale.sftp.sortAscending"

    static var stored: SFTPSort {
        let d = UserDefaults.standard
        let k = d.string(forKey: keyDefault).flatMap(SFTPSortKey.init(rawValue:)) ?? .name
        let a = d.object(forKey: orderDefault) as? Bool ?? true
        return SFTPSort(key: k, ascending: a)
    }

    func save() {
        UserDefaults.standard.set(key.rawValue, forKey: Self.keyDefault)
        UserDefaults.standard.set(ascending, forKey: Self.orderDefault)
    }

    /// Un clic sur l'en-tête de la colonne courante inverse l'ordre ; sur une autre colonne, ordre naturel
    /// (croissant pour le nom, décroissant pour la taille et la date : le plus gros / récent d'abord).
    mutating func toggle(_ k: SFTPSortKey) {
        if key == k { ascending.toggle() } else { key = k; ascending = (k == .name) }
    }

    func sorted(_ items: [SFTPItem]) -> [SFTPItem] {
        items.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            let byName = a.name.localizedStandardCompare(b.name)
            switch key {
            case .name:
                return ascending ? byName == .orderedAscending : byName == .orderedDescending
            case .size:
                // Les dossiers n'ont pas de taille : ils restent triés par nom.
                if a.isDirectory { return byName == .orderedAscending }
                let x = a.size ?? 0, y = b.size ?? 0
                if x != y { return ascending ? x < y : x > y }
                return byName == .orderedAscending
            case .date:
                let x = a.modified ?? .distantPast, y = b.modified ?? .distantPast
                if x != y { return ascending ? x < y : x > y }
                return byName == .orderedAscending
            }
        }
    }
}

/// Textes français des erreurs SFTP / transport.
@MainActor
enum SFTPMessages {
    static func describe(_ error: Error) -> String {
        if let e = error as? SFTPError {
            switch e {
            case .status(let code, let message):
                switch code {
                case .noSuchFile: return String(localized: "Introuvable sur le serveur.")
                case .permissionDenied: return String(localized: "Permission refusée par le serveur.")
                case .opUnsupported: return String(localized: "Opération non supportée par le serveur.")
                case .failure: return message.isEmpty ? String(localized: "Le serveur a refusé l'opération.") : message
                default: return message.isEmpty ? String(localized: "Erreur SFTP (\(String(describing: code))).") : message
                }
            case .protocolViolation(let m): return String(localized: "Réponse SFTP inattendue : \(m)")
            case .channelClosed: return String(localized: "Canal SFTP fermé (connexion perdue).")
            case .negotiationTimeout: return String(localized: "Le serveur SFTP ne répond pas.")
            case .unsupportedVersion(let v): return String(localized: "Version SFTP \(v) non supportée.")
            case .localIO(let m): return m
            case .invalidResumeOffset(let m): return m
            case .cancelled: return String(localized: "Annulé.")
            case .requestTimeout(let s): return String(localized: "Le serveur SFTP n'a pas répondu en \(Int(s.rounded())) s.")
            }
        }
        if let t = error as? SSHTransportError {
            switch t {
            case .subsystemUnavailable(let m): return String(localized: "Sous-système SFTP indisponible : \(m)")
            case .sessionRefused(let m): return String(localized: "Session refusée : \(m)")
            case .notConnected: return String(localized: "Connexion non établie.")
            case .masterFailed(let m): return m
            case .forwardRefused(let m): return m
            }
        }
        return SSHLink.describe(error)
    }

    /// Le canal est mort : la session doit se rouvrir.
    static func isChannelLoss(_ error: Error) -> Bool {
        if case SFTPError.channelClosed = error { return true }
        if case SSHTransportError.notConnected = error { return true }
        return false
    }
}

enum SFTPFormat {
    static func size(_ bytes: UInt64?) -> String {
        guard let b = bytes else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(clamping: b), countStyle: .file)
    }
    static func speed(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond > 0 else { return "" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .file) + "/s"
    }
    static func date(_ d: Date?) -> String {
        guard let d else { return "—" }
        return d.formatted(.dateTime.day().month(.abbreviated).year().hour().minute())
    }
    /// Date courte localisée pour la colonne « Date » (ex. 14/11/2026 09:41).
    static func shortDate(_ d: Date?) -> String {
        guard let d else { return "—" }
        return d.formatted(date: .numeric, time: .shortened)
    }
}
