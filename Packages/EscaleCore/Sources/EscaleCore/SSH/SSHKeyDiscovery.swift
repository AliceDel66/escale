import Foundation

/// Clé privée SSH découverte localement (lecture seule, aucun contenu de clé conservé).
public struct DiscoveredSSHKey: Identifiable, Hashable, Sendable {
    public var id: String { path }
    /// Chemin absolu du fichier de clé privée.
    public let path: String
    /// Nom du fichier (ex. `id_ed25519`).
    public let filename: String
    /// Chemin abrégé pour l'affichage (ex. `~/.ssh/id_ed25519`).
    public let displayPath: String
    /// Vrai si le fichier compagnon `<nom>.pub` existe à côté.
    public let hasPublicKey: Bool

    public init(path: String, filename: String, displayPath: String, hasPublicKey: Bool) {
        self.path = path
        self.filename = filename
        self.displayPath = displayPath
        self.hasPublicKey = hasPublicKey
    }
}

/// Découverte en lecture seule des clés privées SSH locales (invariant 8 : aucune écriture dans `~/.ssh`).
public enum SSHKeyDiscovery {
    /// Taille maximale acceptée pour un fichier de clé privée (64 Kio).
    static let maxKeyFileSize = 64 * 1024

    /// Noms standard placés en tête de liste dans l'ordre de préférence moderne.
    private static let standardOrder: [String: Int] = [
        "id_ed25519": 0,
        "id_ecdsa": 1,
        "id_rsa": 2,
        "id_dsa": 3,
    ]

    /// Fichiers connus de `~/.ssh` qui ne sont jamais des clés privées.
    private static let excludedNames: Set<String> = [
        "known_hosts",
        "known_hosts.old",
        "authorized_keys",
        "authorized_keys2",
        "config",
        "environment",
        "rc",
        ".DS_Store",
    ]

    /// Suffixes écartés (clés publiques, certificats, sauvegardes).
    private static let excludedSuffixes: [String] = [
        "-cert.pub",
        ".pub",
        ".cert",
        ".bak",
        ".old",
        "~",
    ]

    /// Dossier SSH par défaut de l'utilisateur courant (`~/.ssh`).
    public static var defaultSSHDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent(".ssh", isDirectory: true)
    }

    /// Abrège un chemin situé sous le dossier utilisateur en `~/.…` pour l'affichage.
    public static func abbreviatedPath(_ path: String, homeDirectory: String = NSHomeDirectory()) -> String {
        let home = homeDirectory.hasSuffix("/") ? String(homeDirectory.dropLast()) : homeDirectory
        guard !home.isEmpty else { return path }
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    /// Scanne un dossier en lecture seule et renvoie les clés privées SSH candidates, triées.
    public static func discover(in directory: URL = defaultSSHDirectory) -> [DiscoveredSSHKey] {
        let fm = FileManager.default
        guard let filenames = try? fm.contentsOfDirectory(atPath: directory.path) else {
            return []
        }

        let home = NSHomeDirectory()
        var found: [DiscoveredSSHKey] = []

        for filename in filenames {
            if isExcludedName(filename) { continue }
            let entry = directory.appendingPathComponent(filename)

            // Résout un lien symbolique éventuel, puis vérifie qu'il s'agit bien d'un fichier ordinaire
            // de taille raisonnable avant toute lecture (évite sockets, tubes nommés et dossiers).
            let resolved = entry.resolvingSymlinksInPath()
            guard let values = try? resolved.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey]),
                  values.isRegularFile == true,
                  values.isDirectory != true,
                  let fileSize = values.fileSize,
                  fileSize <= maxKeyFileSize else {
                continue
            }

            let pubPath = entry.path + ".pub"
            var pubIsDir: ObjCBool = false
            let hasPublicKey = fm.fileExists(atPath: pubPath, isDirectory: &pubIsDir) && !pubIsDir.boolValue

            // Candidate retenue si un `.pub` compagnon existe ou si l'en-tête ressemble à une clé privée PEM/OpenSSH.
            guard hasPublicKey || looksLikePrivateKeyHeader(at: resolved) else { continue }

            let fullPath = entry.path
            found.append(DiscoveredSSHKey(
                path: fullPath,
                filename: filename,
                displayPath: abbreviatedPath(fullPath, homeDirectory: home),
                hasPublicKey: hasPublicKey
            ))
        }

        return found.sorted(by: sortOrder)
    }

    private static func isExcludedName(_ filename: String) -> Bool {
        if filename.isEmpty || excludedNames.contains(filename) { return true }
        for suffix in excludedSuffixes where filename.hasSuffix(suffix) {
            return true
        }
        return false
    }

    /// Lit au plus 128 octets en lecture seule pour vérifier l'en-tête PEM/OpenSSH, sans jamais exposer le contenu.
    private static func looksLikePrivateKeyHeader(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 128), !data.isEmpty else { return false }
        let prefix = String(decoding: data, as: UTF8.self)
        guard prefix.hasPrefix("-----BEGIN ") else { return false }
        if prefix.hasPrefix("-----BEGIN PUBLIC")
            || prefix.hasPrefix("-----BEGIN SSH2 PUBLIC")
            || prefix.hasPrefix("-----BEGIN CERTIFICATE") {
            return false
        }
        return true
    }

    private static func sortOrder(_ lhs: DiscoveredSSHKey, _ rhs: DiscoveredSSHKey) -> Bool {
        let lp = standardOrder[lhs.filename]
        let rp = standardOrder[rhs.filename]
        switch (lp, rp) {
        case let (l?, r?): return l < r
        case (_?, nil): return true
        case (nil, _?): return false
        case (nil, nil):
            let cmp = lhs.filename.localizedCaseInsensitiveCompare(rhs.filename)
            if cmp != .orderedSame { return cmp == .orderedAscending }
            return lhs.filename < rhs.filename
        }
    }
}
