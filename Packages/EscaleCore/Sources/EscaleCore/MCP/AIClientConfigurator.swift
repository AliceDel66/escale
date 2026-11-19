import Foundation

/// Clients IA pris en charge pour la configuration automatique du serveur MCP d'Escale.
public enum AIClientKind: String, CaseIterable, Identifiable, Sendable, Hashable {
    case antigravity
    case claudeCode = "claude-code"
    case claudeDesktop = "claude-desktop"
    case codex

    public var id: String { rawValue }

    /// Nom lisible du client (noms propres de produits, non localisés).
    public var displayName: String {
        switch self {
        case .antigravity: "Antigravity (agy)"
        case .claudeCode: "Claude Code"
        case .claudeDesktop: "Claude Desktop"
        case .codex: "Codex"
        }
    }

    /// Identifiant court / commande CLI associée.
    public var shortName: String {
        switch self {
        case .antigravity: "agy"
        case .claudeCode: "claude"
        case .claudeDesktop: "claude"
        case .codex: "codex"
        }
    }

    /// Chemin relatif au dossier personnel de l'utilisateur.
    public var relativeConfigPath: String {
        switch self {
        case .antigravity: ".gemini/config/mcp_config.json"
        case .claudeCode: ".claude.json"
        case .claudeDesktop: "Library/Application Support/Claude/claude_desktop_config.json"
        case .codex: ".codex/config.toml"
        }
    }

    /// Chemin abrégé avec `~` pour l'affichage.
    public var displayConfigPath: String { "~/" + relativeConfigPath }

    /// Dossiers ou fichiers indiquant que l'outil est présent sur le poste (relatifs au dossier personnel).
    var presenceMarkers: [String] {
        switch self {
        case .antigravity: [".gemini/config", ".gemini/antigravity"]
        case .claudeCode: [".claude.json", ".claude"]
        case .claudeDesktop: ["Library/Application Support/Claude"]
        case .codex: [".codex"]
        }
    }
}

/// État de la configuration MCP d'Escale dans un client IA.
public enum AIClientStatus: Equatable, Sendable {
    /// Le client n'est pas détecté sur la machine (la configuration reste possible).
    case notInstalled
    /// Le client est détecté, mais l'entrée `escale` est absente.
    case notConfigured
    /// L'entrée `escale` est présente et pointe vers l'exécutable attendu avec `--mcp`.
    case configured(executablePath: String)
    /// L'entrée `escale` existe, mais pointe vers un autre chemin ou d'autres arguments.
    case needsUpdate(existingPath: String)
    /// Le fichier existant n'a pas pu être analysé sans risque d'écrasement.
    case parseError(String)

    public var isConfigured: Bool {
        if case .configured = self { return true }
        return false
    }
}

public enum AIClientConfigError: Error, LocalizedError, Equatable, Sendable {
    case invalidExecutablePath
    case invalidFormat(String)
    case ioFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidExecutablePath: "Invalid Escale executable path"
        case .invalidFormat(let detail): detail
        case .ioFailed(let detail): detail
        }
    }
}

/// Détection et configuration non destructive des clients IA (`agy`, `claude`, `codex`) pour le serveur MCP d'Escale.
/// Injectable par `homeDirectory` afin que les tests n'écrivent jamais dans le dossier personnel réel.
public struct AIClientConfigurator: Sendable {
    public static let serverName = "escale"
    public static let serverArgs = ["--mcp"]

    public let homeDirectory: URL

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeDirectory = homeDirectory
    }

    /// Emplacement complet du fichier de configuration pour un client donné.
    public func configURL(for client: AIClientKind) -> URL {
        homeDirectory.appendingPathComponent(client.relativeConfigPath)
    }

    /// Indique si le client (ou son dossier de configuration) est détecté dans `homeDirectory`.
    public func isClientDetected(_ client: AIClientKind) -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: configURL(for: client).path) { return true }
        return client.presenceMarkers.contains { marker in
            fm.fileExists(atPath: homeDirectory.appendingPathComponent(marker).path)
        }
    }

    /// Extrait ou commande CLI à copier dans le presse-papiers pour déclarer Escale manuellement.
    public static func copySnippet(for client: AIClientKind, executablePath: String) -> String {
        switch client {
        case .antigravity, .claudeDesktop:
            return jsonSnippet(executablePath: executablePath)
        case .claudeCode:
            return "claude mcp add --scope user \(serverName) -- \(ShellQuote.word(executablePath)) --mcp"
        case .codex:
            return "codex mcp add \(serverName) -- \(ShellQuote.word(executablePath)) --mcp"
        }
    }

    /// Extrait JSON générique (`mcpServers.escale`) compatible avec la majorité des clients MCP.
    public static func jsonSnippet(executablePath: String) -> String {
        let escaped = escapeJSONString(executablePath)
        return """
            {
              "mcpServers": {
                "\(serverName)": {
                  "command": "\(escaped)",
                  "args": ["--mcp"]
                }
              }
            }
            """
    }

    /// Extrait TOML pour Codex (`~/.codex/config.toml`).
    public static func codexTOMLSnippet(executablePath: String) -> String {
        let escaped = CodexTOML.escapeBasicString(executablePath)
        return """
            [mcp_servers.\(serverName)]
            command = "\(escaped)"
            args = ["--mcp"]
            """
    }

    // MARK: Inspection

    public func status(for client: AIClientKind, executablePath: String) -> AIClientStatus {
        let url = configURL(for: client)
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            return isClientDetected(client) ? .notConfigured : .notInstalled
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            return .parseError(error.localizedDescription)
        }
        let raw = String(decoding: data, as: UTF8.self)
        if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .notConfigured
        }
        switch client {
        case .antigravity, .claudeCode, .claudeDesktop:
            return inspectJSON(data: data, expectedExecutable: executablePath)
        case .codex:
            return inspectCodexTOML(raw, expectedExecutable: executablePath)
        }
    }

    // MARK: Installation / Mise à jour / Retrait

    /// Installe ou met à jour l'entrée `escale` dans le fichier du client sans altérer ses autres réglages.
    public func install(for client: AIClientKind, executablePath: String) throws {
        try validateExecutablePath(executablePath)
        let url = configURL(for: client)
        switch client {
        case .antigravity, .claudeCode, .claudeDesktop:
            try upsertJSON(at: url, includeStdioType: client == .claudeCode, executablePath: executablePath)
        case .codex:
            try upsertCodexTOML(at: url, executablePath: executablePath)
        }
    }

    /// Retire uniquement l'entrée `escale` du fichier du client (les autres serveurs et réglages sont conservés).
    public func uninstall(for client: AIClientKind) throws {
        let url = configURL(for: client)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        switch client {
        case .antigravity, .claudeCode, .claudeDesktop:
            try removeJSON(at: url)
        case .codex:
            try removeCodexTOML(at: url)
        }
    }

    // MARK: JSON (Antigravity, Claude Code, Claude Desktop)

    private func inspectJSON(data: Data, expectedExecutable: String) -> AIClientStatus {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .parseError("Expected a JSON object")
        }
        guard let serversAny = root["mcpServers"] else { return .notConfigured }
        guard let servers = serversAny as? [String: Any] else {
            return .parseError("Expected 'mcpServers' to be a JSON object")
        }
        guard let entryAny = servers[Self.serverName] else { return .notConfigured }
        guard let entry = entryAny as? [String: Any] else {
            return .parseError("Expected 'mcpServers.escale' to be a JSON object")
        }
        let command = entry["command"] as? String ?? ""
        let args = entry["args"] as? [String] ?? []
        if command == expectedExecutable && args == Self.serverArgs {
            return .configured(executablePath: command)
        }
        return .needsUpdate(existingPath: command)
    }

    private func readJSONObject(at url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        let text = String(decoding: data, as: UTF8.self)
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [:] }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIClientConfigError.invalidFormat("Invalid JSON root object in \(url.lastPathComponent)")
        }
        return obj
    }

    private func upsertJSON(at url: URL, includeStdioType: Bool, executablePath: String) throws {
        var root = try readJSONObject(at: url)
        var servers: [String: Any]
        if let existing = root["mcpServers"] {
            guard let dict = existing as? [String: Any] else {
                throw AIClientConfigError.invalidFormat("Expected 'mcpServers' to be a JSON object")
            }
            servers = dict
        } else {
            servers = [:]
        }
        var entry: [String: Any] = (servers[Self.serverName] as? [String: Any]) ?? [:]
        if includeStdioType {
            entry["type"] = "stdio"
        }
        entry["command"] = executablePath
        entry["args"] = Self.serverArgs
        servers[Self.serverName] = entry
        root["mcpServers"] = servers

        var data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        data.append(0x0a)
        try atomicWrite(data, to: url)
    }

    private func removeJSON(at url: URL) throws {
        var root = try readJSONObject(at: url)
        guard let existing = root["mcpServers"] else { return }
        guard var servers = existing as? [String: Any] else {
            throw AIClientConfigError.invalidFormat("Expected 'mcpServers' to be a JSON object")
        }
        guard servers.removeValue(forKey: Self.serverName) != nil else { return }
        root["mcpServers"] = servers

        var data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        data.append(0x0a)
        try atomicWrite(data, to: url)
    }

    // MARK: TOML (Codex)

    private func inspectCodexTOML(_ content: String, expectedExecutable: String) -> AIClientStatus {
        do {
            guard let parsed = try CodexTOML.readServer(content, name: Self.serverName) else {
                return .notConfigured
            }
            if parsed.command == expectedExecutable && parsed.args == Self.serverArgs {
                return .configured(executablePath: parsed.command)
            }
            return .needsUpdate(existingPath: parsed.command)
        } catch let e as AIClientConfigError {
            return .parseError(e.errorDescription ?? "\(e)")
        } catch {
            return .parseError(error.localizedDescription)
        }
    }

    private func upsertCodexTOML(at url: URL, executablePath: String) throws {
        let existing: String
        if FileManager.default.fileExists(atPath: url.path) {
            existing = try String(contentsOf: url, encoding: .utf8)
        } else {
            existing = ""
        }
        let updated = try CodexTOML.upsertServer(existing, name: Self.serverName, command: executablePath, args: Self.serverArgs)
        try atomicWrite(Data(updated.utf8), to: url)
    }

    private func removeCodexTOML(at url: URL) throws {
        let existing = try String(contentsOf: url, encoding: .utf8)
        guard let updated = try CodexTOML.removeServer(existing, name: Self.serverName) else { return }
        try atomicWrite(Data(updated.utf8), to: url)
    }

    // MARK: Validation & écriture atomique

    private func validateExecutablePath(_ path: String) throws {
        guard !path.isEmpty,
              !path.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else {
            throw AIClientConfigError.invalidExecutablePath
        }
    }

    private func atomicWrite(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            throw AIClientConfigError.ioFailed("Cannot create directory \(dir.path): \(error.localizedDescription)")
        }
        // Conserver les permissions existantes, ou 0600 pour un fichier nouvellement créé.
        let mode: mode_t = {
            if let attrs = try? fm.attributesOfItem(atPath: url.path),
               let posix = attrs[.posixPermissions] as? Int {
                return mode_t(posix & 0o777)
            }
            return 0o600
        }()

        let tmpURL = dir.appendingPathComponent(".\(url.lastPathComponent).escale-\(UUID().uuidString).tmp")
        let fd = open(tmpURL.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, mode)
        guard fd >= 0 else {
            throw AIClientConfigError.ioFailed("Cannot create temporary file: \(String(cString: strerror(errno)))")
        }
        let writeOK: Bool = data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return true }
            var written = 0
            while written < raw.count {
                let n = write(fd, base.advanced(by: written), raw.count - written)
                if n < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                written += n
            }
            return true
        }
        let syncOK = fsync(fd) == 0
        let closeOK = close(fd) == 0
        guard writeOK, syncOK, closeOK else {
            let reason = String(cString: strerror(errno))
            unlink(tmpURL.path)
            throw AIClientConfigError.ioFailed("Write failed: \(reason)")
        }
        _ = chmod(tmpURL.path, mode)
        if rename(tmpURL.path, url.path) != 0 {
            let reason = String(cString: strerror(errno))
            unlink(tmpURL.path)
            throw AIClientConfigError.ioFailed("Atomic replace failed: \(reason)")
        }
    }

    private static func escapeJSONString(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

// MARK: - Éditeur TOML chirurgical pour Codex (`~/.codex/config.toml`)

/// Manipulation ciblée des sections `[mcp_servers.<name>]` sans modifier les autres réglages ni les commentaires.
enum CodexTOML {
    struct ServerEntry: Equatable {
        let command: String
        let args: [String]
    }

    private struct Section {
        let path: [String]
        let isArrayOfTables: Bool
        let headerLine: Int
        /// Indice de fin exclusif (ligne du prochain en-tête de table, ou fin de fichier).
        let endLine: Int
    }

    static func escapeBasicString(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            switch ch {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\t": out += "\\t"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            default: out.append(ch)
            }
        }
        return out
    }

    static func readServer(_ content: String, name: String) throws -> ServerEntry? {
        let lines = splitLines(content)
        let sections = try parseSections(lines)
        guard let sec = sections.first(where: { !$0.isArrayOfTables && $0.path == ["mcp_servers", name] }) else {
            return nil
        }
        let body = Array(lines[(sec.headerLine + 1)..<sec.endLine])
        var command: String?
        var args: [String]?
        var idx = 0
        while idx < body.count {
            let stripped = stripComment(body[idx]).trimmingCharacters(in: .whitespaces)
            if stripped.isEmpty { idx += 1; continue }
            guard let (key, rawValue) = splitKeyValue(stripped) else { idx += 1; continue }
            if key == "command" {
                command = try parseStringValue(rawValue)
                idx += 1
            } else if key == "args" {
                let (parsed, nextIdx) = try parseStringArray(startingWith: rawValue, body: body, lineIndex: idx)
                args = parsed
                idx = nextIdx
            } else {
                idx += 1
            }
        }
        return ServerEntry(command: command ?? "", args: args ?? [])
    }

    static func upsertServer(_ content: String, name: String, command: String, args: [String]) throws -> String {
        let usesCRLF = content.contains("\r\n")
        let newline = usesCRLF ? "\r\n" : "\n"
        let cmdLine = "command = \"\(escapeBasicString(command))\""
        let argsRendered = args.map { "\"\(escapeBasicString($0))\"" }.joined(separator: ", ")
        let argsLine = "args = [\(argsRendered)]"

        if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "[mcp_servers.\(name)]\(newline)\(cmdLine)\(newline)\(argsLine)\(newline)"
        }

        var lines = splitLines(content)
        let sections = try parseSections(lines)

        if let sec = sections.first(where: { !$0.isArrayOfTables && $0.path == ["mcp_servers", name] }) {
            let bodyStart = sec.headerLine + 1
            let bodyEnd = sec.endLine
            var newBody: [String] = []
            var replacedCommand = false
            var replacedArgs = false
            var idx = bodyStart
            while idx < bodyEnd {
                let line = lines[idx]
                let stripped = stripComment(line).trimmingCharacters(in: .whitespaces)
                if let (key, rawValue) = splitKeyValue(stripped) {
                    if key == "command" {
                        if !replacedCommand {
                            newBody.append(cmdLine)
                            replacedCommand = true
                        }
                        idx += 1
                        continue
                    } else if key == "args" {
                        let (_, nextOffset) = try parseStringArray(startingWith: rawValue, body: Array(lines[bodyStart..<bodyEnd]), lineIndex: idx - bodyStart)
                        if !replacedArgs {
                            newBody.append(argsLine)
                            replacedArgs = true
                        }
                        idx = bodyStart + nextOffset
                        continue
                    }
                }
                newBody.append(line)
                idx += 1
            }
            // Insérer les clés manquantes avant les lignes vides de fin de section.
            var insertPos = newBody.count
            while insertPos > 0 && newBody[insertPos - 1].trimmingCharacters(in: .whitespaces).isEmpty {
                insertPos -= 1
            }
            var toInsert: [String] = []
            if !replacedCommand { toInsert.append(cmdLine) }
            if !replacedArgs { toInsert.append(argsLine) }
            if !toInsert.isEmpty {
                newBody.insert(contentsOf: toInsert, at: insertPos)
            }
            lines.replaceSubrange(bodyStart..<bodyEnd, with: newBody)
            return lines.joined(separator: newline) + newline
        }

        // Nouvelle section en fin de fichier, précédée d'une ligne vide si nécessaire.
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeLast()
        }
        if !lines.isEmpty { lines.append("") }
        lines.append("[mcp_servers.\(name)]")
        lines.append(cmdLine)
        lines.append(argsLine)
        return lines.joined(separator: newline) + newline
    }

    /// Supprime `[mcp_servers.<name>]` ainsi que ses sous-tables `[mcp_servers.<name>.*]`. Renvoie `nil` si absent.
    static func removeServer(_ content: String, name: String) throws -> String? {
        let usesCRLF = content.contains("\r\n")
        let newline = usesCRLF ? "\r\n" : "\n"
        var lines = splitLines(content)
        let sections = try parseSections(lines)
        let matching = sections.filter {
            $0.path.count >= 2 && $0.path[0] == "mcp_servers" && $0.path[1] == name
        }
        guard !matching.isEmpty else { return nil }

        // Retirer de la fin vers le début pour préserver les indices.
        for sec in matching.reversed() {
            lines.removeSubrange(sec.headerLine..<sec.endLine)
        }
        // Nettoyer les lignes vides multiples en début/fin.
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeFirst()
        }
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeLast()
        }
        if lines.isEmpty { return "" }
        return lines.joined(separator: newline) + newline
    }

    // MARK: Analyse TOML minimale

    private static func splitLines(_ content: String) -> [String] {
        let normalized = content.replacingOccurrences(of: "\r\n", with: "\n")
        var lines = normalized.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    private static func parseSections(_ lines: [String]) throws -> [Section] {
        var headers: [(path: [String], isArray: Bool, line: Int)] = []
        var bracketDepth = 0
        for (i, line) in lines.enumerated() {
            let trimmed = stripComment(line).trimmingCharacters(in: .whitespaces)
            if bracketDepth > 0 {
                bracketDepth = max(0, bracketDepth + arrayBracketDelta(trimmed))
                continue
            }
            if trimmed.hasPrefix("[") {
                let (path, isArray) = try parseTableHeader(trimmed)
                headers.append((path, isArray, i))
            } else if let (_, rawVal) = splitKeyValue(trimmed), rawVal.hasPrefix("[") {
                bracketDepth = max(0, arrayBracketDelta(rawVal))
            }
        }
        var out: [Section] = []
        for idx in headers.indices {
            let end = idx + 1 < headers.count ? headers[idx + 1].line : lines.count
            out.append(Section(path: headers[idx].path, isArrayOfTables: headers[idx].isArray,
                               headerLine: headers[idx].line, endLine: end))
        }
        return out
    }

    private static func parseTableHeader(_ trimmed: String) throws -> ([String], Bool) {
        let isArray = trimmed.hasPrefix("[[")
        let inner: Substring
        if isArray {
            guard trimmed.hasSuffix("]]"), trimmed.count >= 4 else {
                throw AIClientConfigError.invalidFormat("Malformed TOML array table header: \(trimmed)")
            }
            inner = trimmed.dropFirst(2).dropLast(2)
        } else {
            guard trimmed.hasSuffix("]"), trimmed.count >= 2 else {
                throw AIClientConfigError.invalidFormat("Malformed TOML table header: \(trimmed)")
            }
            inner = trimmed.dropFirst(1).dropLast(1)
        }
        let segments = try parseDottedKey(String(inner))
        guard !segments.isEmpty else {
            throw AIClientConfigError.invalidFormat("Empty TOML table header")
        }
        return (segments, isArray)
    }

    private static func parseDottedKey(_ raw: String) throws -> [String] {
        var segments: [String] = []
        var i = raw.startIndex
        let end = raw.endIndex
        while i < end {
            while i < end && (raw[i] == " " || raw[i] == "\t") { i = raw.index(after: i) }
            if i >= end { break }
            if raw[i] == "\"" || raw[i] == "'" {
                let (val, next) = try parseQuoted(raw, from: i)
                segments.append(val)
                i = next
            } else {
                let start = i
                while i < end && raw[i] != "." && raw[i] != " " && raw[i] != "\t" {
                    i = raw.index(after: i)
                }
                let seg = String(raw[start..<i])
                guard !seg.isEmpty else {
                    throw AIClientConfigError.invalidFormat("Invalid TOML key segment")
                }
                segments.append(seg)
            }
            while i < end && (raw[i] == " " || raw[i] == "\t") { i = raw.index(after: i) }
            if i < end {
                guard raw[i] == "." else {
                    throw AIClientConfigError.invalidFormat("Unexpected character '\(raw[i])' in TOML header")
                }
                i = raw.index(after: i)
            }
        }
        return segments
    }

    private static func splitKeyValue(_ stripped: String) -> (String, String)? {
        guard !stripped.isEmpty, !stripped.hasPrefix("[") else { return nil }
        var inQuote: Character?
        var escaped = false
        for idx in stripped.indices {
            let ch = stripped[idx]
            if let q = inQuote {
                if q == "\"" && escaped { escaped = false; continue }
                if q == "\"" && ch == "\\" { escaped = true; continue }
                if ch == q { inQuote = nil }
                continue
            }
            if ch == "\"" || ch == "'" { inQuote = ch; continue }
            if ch == "=" {
                let k = stripped[..<idx].trimmingCharacters(in: .whitespaces)
                let v = stripped[stripped.index(after: idx)...].trimmingCharacters(in: .whitespaces)
                return (k, v)
            }
        }
        return nil
    }

    private static func stripComment(_ line: String) -> String {
        var inQuote: Character?
        var escaped = false
        for idx in line.indices {
            let ch = line[idx]
            if let q = inQuote {
                if q == "\"" && escaped { escaped = false; continue }
                if q == "\"" && ch == "\\" { escaped = true; continue }
                if ch == q { inQuote = nil }
                continue
            }
            if ch == "\"" || ch == "'" { inQuote = ch; continue }
            if ch == "#" { return String(line[..<idx]) }
        }
        return line
    }

    private static func arrayBracketDelta(_ s: String) -> Int {
        var delta = 0
        var inQuote: Character?
        var escaped = false
        for ch in s {
            if let q = inQuote {
                if q == "\"" && escaped { escaped = false; continue }
                if q == "\"" && ch == "\\" { escaped = true; continue }
                if ch == q { inQuote = nil }
                continue
            }
            if ch == "\"" || ch == "'" { inQuote = ch; continue }
            if ch == "[" { delta += 1 }
            else if ch == "]" { delta -= 1 }
        }
        return delta
    }

    private static func parseQuoted(_ s: String, from start: String.Index) throws -> (String, String.Index) {
        let quote = s[start]
        var i = s.index(after: start)
        let end = s.endIndex
        var out = ""
        if quote == "'" {
            while i < end {
                if s[i] == "'" { return (out, s.index(after: i)) }
                out.append(s[i])
                i = s.index(after: i)
            }
            throw AIClientConfigError.invalidFormat("Unterminated TOML literal string")
        }
        while i < end {
            let ch = s[i]
            if ch == "\"" { return (out, s.index(after: i)) }
            if ch == "\\" {
                i = s.index(after: i)
                guard i < end else { throw AIClientConfigError.invalidFormat("Unterminated escape in TOML string") }
                switch s[i] {
                case "\\": out.append("\\")
                case "\"": out.append("\"")
                case "n": out.append("\n")
                case "r": out.append("\r")
                case "t": out.append("\t")
                default: out.append(s[i])
                }
                i = s.index(after: i)
                continue
            }
            out.append(ch)
            i = s.index(after: i)
        }
        throw AIClientConfigError.invalidFormat("Unterminated TOML basic string")
    }

    private static func parseStringValue(_ raw: String) throws -> String {
        let t = raw.trimmingCharacters(in: .whitespaces)
        guard let first = t.first, first == "\"" || first == "'" else {
            throw AIClientConfigError.invalidFormat("Expected TOML string value for command")
        }
        let (val, next) = try parseQuoted(t, from: t.startIndex)
        guard t[next...].trimmingCharacters(in: .whitespaces).isEmpty else {
            throw AIClientConfigError.invalidFormat("Unexpected trailing characters in TOML string")
        }
        return val
    }

    private static func parseStringArray(startingWith firstValue: String, body: [String], lineIndex: Int) throws -> ([String], Int) {
        var combined = firstValue
        var depth = arrayBracketDelta(firstValue)
        var nextIndex = lineIndex + 1
        guard firstValue.hasPrefix("[") else {
            throw AIClientConfigError.invalidFormat("Expected TOML array for args")
        }
        while depth > 0 {
            guard nextIndex < body.count else {
                throw AIClientConfigError.invalidFormat("Unterminated TOML array for args")
            }
            let part = stripComment(body[nextIndex]).trimmingCharacters(in: .whitespaces)
            combined += " " + part
            depth += arrayBracketDelta(part)
            nextIndex += 1
        }
        let trimmed = combined.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("["), trimmed.hasSuffix("]") else {
            throw AIClientConfigError.invalidFormat("Malformed TOML array for args")
        }
        let inner = String(trimmed.dropFirst().dropLast())
        var items: [String] = []
        var i = inner.startIndex
        let end = inner.endIndex
        while i < end {
            while i < end && (inner[i] == " " || inner[i] == "\t" || inner[i] == "," || inner[i] == "\n") {
                i = inner.index(after: i)
            }
            if i >= end { break }
            guard inner[i] == "\"" || inner[i] == "'" else {
                throw AIClientConfigError.invalidFormat("Expected string item in TOML args array")
            }
            let (val, next) = try parseQuoted(inner, from: i)
            items.append(val)
            i = next
        }
        return (items, nextIndex)
    }
}
