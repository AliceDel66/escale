import Foundation
import Testing
@testable import EscaleCore

@Suite struct AIClientConfiguratorTests {
    private let defaultExe = "/Applications/Escale.app/Contents/MacOS/Escale"

    private func makeTempHome() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("escale-ai-cfg-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func posixMode(of url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? Int ?? -1
    }

    @Test func antigravityHandlesEmptyFileAndPreservesExistingServers() throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let cfg = AIClientConfigurator(homeDirectory: home)
        let url = cfg.configURL(for: .antigravity)

        #expect(cfg.status(for: .antigravity, executablePath: defaultExe) == .notInstalled)

        // Simuler le fichier vide réel (~/.gemini/config/mcp_config.json de 0 octet).
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: Data())
        #expect(cfg.status(for: .antigravity, executablePath: defaultExe) == .notConfigured)

        // Pré-remplir avec un autre serveur et une clé racine.
        let initial = """
        {
          "customSetting": true,
          "mcpServers": {
            "sqlite": { "command": "sqlite-mcp", "args": ["/tmp/db.sqlite"] }
          }
        }
        """
        try Data(initial.utf8).write(to: url)
        #expect(cfg.status(for: .antigravity, executablePath: defaultExe) == .notConfigured)

        try cfg.install(for: .antigravity, executablePath: defaultExe)
        #expect(cfg.status(for: .antigravity, executablePath: defaultExe) == .configured(executablePath: defaultExe))

        // Vérifier que les autres clés et serveurs sont intacts.
        let obj = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(obj["customSetting"] as? Bool == true)
        let servers = try #require(obj["mcpServers"] as? [String: Any])
        #expect(servers["sqlite"] != nil)
        let escale = try #require(servers["escale"] as? [String: Any])
        #expect(escale["command"] as? String == defaultExe)
        #expect(escale["args"] as? [String] == ["--mcp"])

        // Chemin différent -> needsUpdate puis mise à jour.
        let altExe = "/Users/dev/Build/Escale.app/Contents/MacOS/Escale"
        #expect(cfg.status(for: .antigravity, executablePath: altExe) == .needsUpdate(existingPath: defaultExe))
        try cfg.install(for: .antigravity, executablePath: altExe)
        #expect(cfg.status(for: .antigravity, executablePath: altExe) == .configured(executablePath: altExe))

        // Retrait : conserve `sqlite` et `customSetting`.
        try cfg.uninstall(for: .antigravity)
        #expect(cfg.status(for: .antigravity, executablePath: altExe) == .notConfigured)
        let after = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(after["customSetting"] as? Bool == true)
        let serversAfter = try #require(after["mcpServers"] as? [String: Any])
        #expect(serversAfter["sqlite"] != nil)
        #expect(serversAfter["escale"] == nil)
    }

    @Test func claudeCodeWritesStdioTypeAndPreservesTopLevelState() throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let cfg = AIClientConfigurator(homeDirectory: home)
        let url = cfg.configURL(for: .claudeCode)

        let existing = """
        {
          "numStartups": 42,
          "projects": { "/tmp/demo": { "allowedTools": ["Bash"] } },
          "mcpServers": {
            "other": { "type": "stdio", "command": "npx", "args": ["-y", "demo"] }
          }
        }
        """
        try Data(existing.utf8).write(to: url)
        #expect(cfg.status(for: .claudeCode, executablePath: defaultExe) == .notConfigured)

        try cfg.install(for: .claudeCode, executablePath: defaultExe)
        #expect(cfg.status(for: .claudeCode, executablePath: defaultExe) == .configured(executablePath: defaultExe))

        let obj = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(obj["numStartups"] as? Int == 42)
        #expect((obj["projects"] as? [String: Any])?["/tmp/demo"] != nil)
        let servers = try #require(obj["mcpServers"] as? [String: Any])
        #expect(servers["other"] != nil)
        let escale = try #require(servers["escale"] as? [String: Any])
        #expect(escale["type"] as? String == "stdio")
        #expect(escale["command"] as? String == defaultExe)
        #expect(escale["args"] as? [String] == ["--mcp"])

        try cfg.uninstall(for: .claudeCode)
        #expect(cfg.status(for: .claudeCode, executablePath: defaultExe) == .notConfigured)
        let after = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(after["numStartups"] as? Int == 42)
        #expect((after["mcpServers"] as? [String: Any])?["other"] != nil)
    }

    @Test func claudeDesktopCreatesParentDirWithPrivatePermissions() throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let cfg = AIClientConfigurator(homeDirectory: home)
        let url = cfg.configURL(for: .claudeDesktop)

        #expect(cfg.status(for: .claudeDesktop, executablePath: defaultExe) == .notInstalled)
        try cfg.install(for: .claudeDesktop, executablePath: defaultExe)
        #expect(cfg.status(for: .claudeDesktop, executablePath: defaultExe) == .configured(executablePath: defaultExe))
        #expect(posixMode(of: url) == 0o600)
    }

    @Test func invalidJSONRefusesOverwrite() throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let cfg = AIClientConfigurator(homeDirectory: home)
        let url = cfg.configURL(for: .antigravity)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let broken = "{ not valid json"
        try Data(broken.utf8).write(to: url)

        if case .parseError = cfg.status(for: .antigravity, executablePath: defaultExe) {} else {
            Issue.record("Expected parseError for malformed JSON")
        }
        #expect(throws: AIClientConfigError.self) {
            try cfg.install(for: .antigravity, executablePath: defaultExe)
        }
        // Fichier d'origine non modifié.
        #expect(try String(contentsOf: url, encoding: .utf8) == broken)
    }

    @Test func codexTOMLInstallUpdateAndUninstallNonDestructive() throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let cfg = AIClientConfigurator(homeDirectory: home)
        let url = cfg.configURL(for: .codex)

        #expect(cfg.status(for: .codex, executablePath: defaultExe) == .notInstalled)

        // Fichier existant avec commentaires, réglages globaux, autre serveur MCP et tableau de tables.
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let existing = """
        # Configuration Codex utilisateur
        model = "gpt-5"
        approval_policy = "on-request"

        [mcp_servers.docs]
        command = "npx"
        args = ["-y", "docs-mcp"]

        [[profiles]]
        name = "fast"
        """
        try existing.write(to: url, atomically: true, encoding: .utf8)
        #expect(cfg.status(for: .codex, executablePath: defaultExe) == .notConfigured)

        try cfg.install(for: .codex, executablePath: defaultExe)
        #expect(cfg.status(for: .codex, executablePath: defaultExe) == .configured(executablePath: defaultExe))

        let installed = try String(contentsOf: url, encoding: .utf8)
        #expect(installed.contains("# Configuration Codex utilisateur"))
        #expect(installed.contains("model = \"gpt-5\""))
        #expect(installed.contains("[mcp_servers.docs]"))
        #expect(installed.contains("[[profiles]]"))
        #expect(installed.contains("[mcp_servers.escale]"))

        // Mise à jour chirurgicale avec args multi-lignes, clé supplémentaire et sous-table [mcp_servers.escale.env].
        let customEscale = """
        # Top comment
        model = "gpt-5"

        [mcp_servers."escale"]
        # Keep this comment
        command = '/old/path/Escale'
        args = [
          "--old",
        ]
        startup_timeout_sec = 20

        [mcp_servers.escale.env]
        FOO = "bar"

        [mcp_servers.other]
        command = "other-bin"
        args = []
        """
        try customEscale.write(to: url, atomically: true, encoding: .utf8)
        #expect(cfg.status(for: .codex, executablePath: defaultExe) == .needsUpdate(existingPath: "/old/path/Escale"))

        let spaceExe = "/Applications/My \"Escale\" App/Contents/MacOS/Escale"
        try cfg.install(for: .codex, executablePath: spaceExe)
        #expect(cfg.status(for: .codex, executablePath: spaceExe) == .configured(executablePath: spaceExe))

        let updated = try String(contentsOf: url, encoding: .utf8)
        #expect(updated.contains("# Keep this comment"))
        #expect(updated.contains("startup_timeout_sec = 20"))
        #expect(updated.contains("[mcp_servers.escale.env]"))
        #expect(updated.contains("FOO = \"bar\""))
        #expect(updated.contains("[mcp_servers.other]"))

        // Retrait : supprime [mcp_servers."escale"] et [mcp_servers.escale.env], préserve le reste.
        try cfg.uninstall(for: .codex)
        #expect(cfg.status(for: .codex, executablePath: spaceExe) == .notConfigured)
        let after = try String(contentsOf: url, encoding: .utf8)
        #expect(after.contains("# Top comment"))
        #expect(after.contains("model = \"gpt-5\""))
        #expect(after.contains("[mcp_servers.other]"))
        #expect(!after.contains("escale"))
        #expect(!after.contains("FOO = \"bar\""))
    }

    @Test func codexFreshInstallAndInvalidTOMLHandling() throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let cfg = AIClientConfigurator(homeDirectory: home)
        let url = cfg.configURL(for: .codex)

        try cfg.install(for: .codex, executablePath: defaultExe)
        #expect(cfg.status(for: .codex, executablePath: defaultExe) == .configured(executablePath: defaultExe))
        #expect(posixMode(of: url) == 0o600)

        // Chemin invalide avec retour à la ligne refusé.
        #expect(throws: AIClientConfigError.invalidExecutablePath) {
            try cfg.install(for: .codex, executablePath: "/tmp/bad\npath")
        }

        // TOML malformé -> parseError, refus d'écrasement.
        let malformed = "[mcp_servers.escale\ncommand = \"x\"\n"
        try malformed.write(to: url, atomically: true, encoding: .utf8)
        if case .parseError = cfg.status(for: .codex, executablePath: defaultExe) {} else {
            Issue.record("Expected parseError for malformed TOML")
        }
        #expect(throws: AIClientConfigError.self) {
            try cfg.install(for: .codex, executablePath: defaultExe)
        }
        #expect(try String(contentsOf: url, encoding: .utf8) == malformed)
    }

    @Test func copySnippetsCoverAllClients() {
        let exe = "/Applications/Escale.app/Contents/MacOS/Escale"
        let agy = AIClientConfigurator.copySnippet(for: .antigravity, executablePath: exe)
        #expect(agy.contains("\"mcpServers\"") && agy.contains("\"escale\"") && agy.contains("\"--mcp\""))

        let claude = AIClientConfigurator.copySnippet(for: .claudeCode, executablePath: exe)
        #expect(claude.contains("claude mcp add") && claude.contains("escale") && claude.contains("--mcp"))

        let desktop = AIClientConfigurator.copySnippet(for: .claudeDesktop, executablePath: exe)
        #expect(desktop.contains("\"mcpServers\"") && desktop.contains(exe))

        let codex = AIClientConfigurator.copySnippet(for: .codex, executablePath: exe)
        #expect(codex.contains("codex mcp add") && codex.contains("escale") && codex.contains("--mcp"))

        let toml = AIClientConfigurator.codexTOMLSnippet(executablePath: exe)
        #expect(toml.contains("[mcp_servers.escale]") && toml.contains("args = [\"--mcp\"]"))
    }
}
