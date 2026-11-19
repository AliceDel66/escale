import Foundation
import Testing
@testable import EscaleCore

/// Fournisseur factice : un outil de lecture `echo`, un outil d'action `wait` qui attend son annulation.
private actor FakeProvider: MCPToolProvider {
    var calls: [MCPToolCall] = []
    var cancelled = 0

    nonisolated func tools() async -> [MCPToolDefinition] {
        [MCPToolDefinition(name: "echo", title: "Echo", description: "", inputSchema: ["type": "object"], operation: .read),
         MCPToolDefinition(name: "wait", title: "Wait", description: "", inputSchema: ["type": "object"], operation: .action)]
    }

    func call(_ call: MCPToolCall) async -> MCPToolResult {
        calls.append(call)
        if call.name == "wait" {
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(10)) }
            cancelled += 1
            return .error("cancelled")
        }
        do {
            let text = try call.arguments.string("text")
            return .json(["echo": .string(text), "client": .string(call.client.name)])
        } catch let e as MCPArgumentError { return .error(e.message) }
        catch { return .error("\(error)") }
    }
}

private func line(_ v: JSONValue) -> Data { MCPJSON.encode(v) }
private func parse(_ d: Data?) throws -> JSONValue { try MCPJSON.decode(try #require(d)) }

@Suite struct MCPSessionTests {
    @Test func jsonRoundTripKeepsIntegersAndUnicode() throws {
        let v: JSONValue = ["id": 7, "pi": .double(3.5), "s": "é\n\"x\"/", "a": [true, nil], "o": [:]]
        let d = MCPJSON.encode(v)
        #expect(!d.contains(0x0a))   // une seule ligne
        #expect(try MCPJSON.decode(d) == v)
        #expect(JSONValue.double(5).intValue == 5)
        #expect(JSONValue.double(5.5).intValue == nil)
    }

    @Test func initializeNegotiatesVersionAndRecordsClient() async throws {
        let s = MCPSession(provider: FakeProvider(), serverVersion: "1.2.3")
        let r = try parse(await s.handle(line([
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": ["protocolVersion": "2025-03-26", "capabilities": [:], "clientInfo": ["name": "claude-code", "version": "2.0"]],
        ])))
        #expect(r["id"] == 1)
        #expect(r["result"]?["protocolVersion"] == "2025-03-26")
        #expect(r["result"]?["serverInfo"]?["name"] == "escale")
        #expect(r["result"]?["capabilities"]?["tools"] != nil)
        #expect(await s.client.label == "claude-code 2.0")
        // Version inconnue : la plus récente prise en charge.
        let r2 = try parse(await s.handle(line(["jsonrpc": "2.0", "id": "b", "method": "initialize", "params": ["protocolVersion": "1999-01-01"]])))
        #expect(r2["result"]?["protocolVersion"] == .string(MCPSession.supportedProtocolVersions[0]))
        #expect(r2["id"] == "b")
    }

    @Test func notificationsAndResponsesGetNoReply() async throws {
        let s = MCPSession(provider: FakeProvider(), serverVersion: "1")
        #expect(await s.handle(line(["jsonrpc": "2.0", "method": "notifications/initialized"])) == nil)
        #expect(await s.isInitialized)
        #expect(await s.handle(line(["jsonrpc": "2.0", "id": 4, "result": [:]])) == nil)
    }

    @Test func protocolErrors() async throws {
        let s = MCPSession(provider: FakeProvider(), serverVersion: "1")
        #expect(try parse(await s.handle(Data("{not json".utf8)))["error"]?["code"] == .int(MCPSession.RPCError.parse))
        #expect(try parse(await s.handle(line([["jsonrpc": "2.0", "id": 1, "method": "ping"]])))["error"]?["code"]
                == .int(MCPSession.RPCError.invalidRequest))
        #expect(try parse(await s.handle(line(["jsonrpc": "2.0", "id": 1, "method": "resources/list"])))["error"]?["code"]
                == .int(MCPSession.RPCError.methodNotFound))
        #expect(try parse(await s.handle(line(["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": "nope"]])))["error"]?["code"]
                == .int(MCPSession.RPCError.invalidParams))
        #expect(try parse(await s.handle(line(["jsonrpc": "2.0", "id": 3, "method": "ping"])))["result"] == [:])
    }

    @Test func toolsListAndCall() async throws {
        let p = FakeProvider()
        let s = MCPSession(provider: p, serverVersion: "1")
        _ = await s.handle(line(["jsonrpc": "2.0", "id": 0, "method": "initialize", "params": ["clientInfo": ["name": "t"]]]))
        let list = try parse(await s.handle(line(["jsonrpc": "2.0", "id": 1, "method": "tools/list"])))
        let tools = try #require(list["result"]?["tools"]?.arrayValue)
        #expect(tools.map { $0["name"] } == ["echo", "wait"])
        #expect(tools[0]["annotations"]?["readOnlyHint"] == true)
        #expect(tools[1]["annotations"]?["destructiveHint"] == true)

        let ok = try parse(await s.handle(line(["jsonrpc": "2.0", "id": 2, "method": "tools/call",
                                               "params": ["name": "echo", "arguments": ["text": "bonjour"]]])))
        #expect(ok["result"]?["isError"] == false)
        #expect(ok["result"]?["structuredContent"]?["echo"] == "bonjour")
        #expect(ok["result"]?["structuredContent"]?["client"] == "t")
        #expect(ok["result"]?["content"]?.arrayValue?.first?["type"] == "text")

        let bad = try parse(await s.handle(line(["jsonrpc": "2.0", "id": 3, "method": "tools/call",
                                                "params": ["name": "echo", "arguments": ["text": 5]]])))
        #expect(bad["result"]?["isError"] == true)
        #expect(bad["result"]?["content"]?.arrayValue?.first?["text"] == "argument 'text' must be a string")
    }

    @Test func argumentsAreBounded() throws {
        let a = MCPArguments(["n": 5, "big": 900, "f": .double(2.0), "b": "x"])
        #expect(try a.int("n", default: 1, range: 1...10) == 5)
        #expect(try a.int("absent", default: 3, range: 1...10) == 3)
        #expect(try a.int("f", default: 1, range: 1...10) == 2)
        #expect(throws: MCPArgumentError.self) { try a.int("big", default: 1, range: 1...600) }
        #expect(throws: MCPArgumentError.self) { try a.bool("b", default: false) }
        #expect(throws: MCPArgumentError.self) { try a.string("absent") }
    }
}

@Suite struct MCPPolicyTests {
    @Test func decisionTable() {
        for a in AgentAccess.allCases {
            let r = MCPPolicy.decide(.read, access: a)
            let w = MCPPolicy.decide(.action, access: a)
            switch a {
            case .none:
                if case .deny = r {} else { Issue.record("lecture permise sans accès") }
                if case .deny = w {} else { Issue.record("action permise sans accès") }
            case .read:
                #expect(r == .allow)
                if case .deny = w {} else { Issue.record("action permise en lecture seule") }
            case .confirm: #expect(r == .allow); #expect(w == .confirm)
            case .full: #expect(r == .allow); #expect(w == .allow)
            }
        }
    }

    @Test func catalogClassifiesEveryTool() {
        let defs = MCPCatalog.definitions
        #expect(Set(defs.map(\.name)).count == MCPCatalog.Tool.allCases.count)
        let actions = Set(defs.filter { $0.operation == .action }.map(\.name))
        #expect(actions == ["connect_host", "send_input", "exec", "write_file", "start_tunnel", "stop_tunnel"])
        for d in defs { #expect(d.inputSchema["type"] == "object"); #expect(!d.description.isEmpty) }
    }

    @Test func hostProfileAccessDefaultsToNoneAndRoundTrips() throws {
        let old = #"{"id":"7C0E8A2B-6B7A-4D29-9E57-0C1F2C3D4E5F","name":"a","host":"h"}"#
        #expect(try JSONDecoder().decode(HostProfile.self, from: Data(old.utf8)).agentAccess == AgentAccess.none)
        let future = #"{"id":"7C0E8A2B-6B7A-4D29-9E57-0C1F2C3D4E5F","name":"a","host":"h","agentAccess":"root"}"#
        #expect(try JSONDecoder().decode(HostProfile.self, from: Data(future.utf8)).agentAccess == AgentAccess.none)
        var h = HostProfile(name: "a", host: "h"); h.agentAccess = .confirm
        let back = try JSONDecoder().decode(HostProfile.self, from: JSONEncoder().encode(h))
        #expect(back.agentAccess == .confirm)
    }
}

@Suite(.serialized) struct MCPSocketTests {
    private func tempDir() throws -> String {
        let d = "/tmp/escale-mcp-t-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        return d
    }

    /// Lit des lignes JSON sur `fd` jusqu'à en avoir `count` (ou l'échéance).
    private func readLines(_ fd: Int32, count: Int, timeout: TimeInterval = 5) -> [JSONValue] {
        var buf = Data(), out: [JSONValue] = []
        var chunk = [UInt8](repeating: 0, count: 4096)
        let end = Date().addingTimeInterval(timeout)
        while out.count < count && Date() < end {
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&p, 1, 50) > 0 else { continue }
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { break }
            buf.append(contentsOf: chunk[0..<n])
            while let nl = buf.firstIndex(of: 0x0a) {
                if let v = try? MCPJSON.decode(Data(buf[buf.startIndex..<nl])) { out.append(v) }
                buf = Data(buf[(nl + 1)...])
            }
        }
        return out
    }

    private func send(_ fd: Int32, _ v: JSONValue) {
        var d = MCPJSON.encode(v); d.append(0x0a)
        _ = d.withUnsafeBytes { write(fd, $0.baseAddress!, d.count) }
    }

    @Test func serverOverSocketWithPrivateDirectory() async throws {
        let base = try tempDir()
        defer { try? FileManager.default.removeItem(atPath: base) }
        let path = "\(base)/agent/mcp.sock"
        let provider = FakeProvider()
        let server = MCPSocketServer(socketPath: path) { id in MCPSession(provider: provider, serverVersion: "t", connectionID: id) }
        try server.start()
        defer { server.stop() }

        var st = stat()
        #expect(lstat("\(base)/agent", &st) == 0 && st.st_mode & 0o777 == 0o700)
        #expect(lstat(path, &st) == 0 && st.st_mode & 0o777 == 0o600 && (st.st_mode & S_IFMT) == S_IFSOCK)
        // Une seconde instance refuse de voler le socket vivant.
        let other = MCPSocketServer(socketPath: path) { MCPSession(provider: provider, serverVersion: "t", connectionID: $0) }
        #expect(throws: MCPSocketServer.StartError.inUse) { try other.start() }

        let fd = MCPRelay.connect(path)
        #expect(fd >= 0)
        defer { close(fd) }
        send(fd, ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["clientInfo": ["name": "sock"]]])
        send(fd, ["jsonrpc": "2.0", "method": "notifications/initialized"])
        send(fd, ["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": "echo", "arguments": ["text": "l1\nl2"]]])
        let replies = readLines(fd, count: 2)
        #expect(replies.count == 2)
        #expect(replies.first { $0["id"] == 2 }?["result"]?["structuredContent"]?["echo"] == "l1\nl2")
        #expect(server.connectionCount == 1)
    }

    @Test func disconnectCancelsPendingCalls() async throws {
        let base = try tempDir()
        defer { try? FileManager.default.removeItem(atPath: base) }
        let path = "\(base)/mcp.sock"
        let provider = FakeProvider()
        let server = MCPSocketServer(socketPath: path) { MCPSession(provider: provider, serverVersion: "t", connectionID: $0) }
        try server.start()
        defer { server.stop() }
        let fd = MCPRelay.connect(path)
        send(fd, ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": "wait"]])
        let end = Date().addingTimeInterval(5)
        while await provider.calls.isEmpty && Date() < end { try await Task.sleep(for: .milliseconds(20)) }
        close(fd)
        while await provider.cancelled == 0 && Date() < end { try await Task.sleep(for: .milliseconds(20)) }
        #expect(await provider.cancelled == 1)
        while server.connectionCount > 0 && Date() < end { try await Task.sleep(for: .milliseconds(20)) }
        #expect(server.connectionCount == 0)
    }

    @Test func staleSocketIsReplacedAndStopRemovesIt() throws {
        let base = try tempDir()
        defer { try? FileManager.default.removeItem(atPath: base) }
        let provider = FakeProvider()
        // Socket mort (fichier socket sans écoute, app plantée) : remplacé au démarrage.
        let dead = "\(base)/dead.sock"
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = try #require(UnixSocket.makeAddress(dead))
        _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        close(fd)   // fichier socket sans écoute
        let s2 = MCPSocketServer(socketPath: dead) { MCPSession(provider: provider, serverVersion: "t", connectionID: $0) }
        try s2.start()
        #expect(MCPSocketServer.canConnect(dead))
        s2.stop()
        #expect(!FileManager.default.fileExists(atPath: dead))
        // Un fichier ordinaire à la place du socket n'est jamais supprimé.
        let plain = "\(base)/plain.sock"
        FileManager.default.createFile(atPath: plain, contents: Data("x".utf8))
        let s3 = MCPSocketServer(socketPath: plain) { MCPSession(provider: provider, serverVersion: "t", connectionID: $0) }
        #expect(throws: MCPSocketServer.StartError.self) { try s3.start() }
        #expect(FileManager.default.fileExists(atPath: plain))
    }

    @Test func relayPumpsBothWays() async throws {
        let base = try tempDir()
        defer { try? FileManager.default.removeItem(atPath: base) }
        let path = "\(base)/mcp.sock"
        let provider = FakeProvider()
        let server = MCPSocketServer(socketPath: path) { MCPSession(provider: provider, serverVersion: "t", connectionID: $0) }
        try server.start()
        defer { server.stop() }
        var inPipe: [Int32] = [0, 0], outPipe: [Int32] = [0, 0]
        #expect(pipe(&inPipe) == 0 && pipe(&outPipe) == 0)
        let sock = MCPRelay.connect(path)
        let (inR, outW) = (inPipe[0], outPipe[1])
        let t = Thread { MCPRelay.pump(input: inR, output: outW, socket: sock); close(sock); close(outW) }
        t.start()
        send(inPipe[1], ["jsonrpc": "2.0", "id": 9, "method": "ping"])
        let r = readLines(outPipe[0], count: 1)
        #expect(r.first?["id"] == 9)
        #expect(r.first?["result"] == [:])
        close(inPipe[1])   // fin de stdin : le relais se termine quand l'app ferme la connexion
        var chunk = [UInt8](repeating: 0, count: 16)
        let end = Date().addingTimeInterval(5)
        var eof = false
        while Date() < end {
            var p = pollfd(fd: outPipe[0], events: Int16(POLLIN), revents: 0)
            if poll(&p, 1, 50) > 0 { if read(outPipe[0], &chunk, 16) <= 0 { eof = true; break } }
        }
        #expect(eof)
        close(outPipe[0]); close(inR)
    }

    @Test func endpointHonoursEnvironment() {
        #expect(MCPEndpoint.socketPath(environment: ["ESCALE_MCP_SOCKET": "/tmp/x.sock"]) == "/tmp/x.sock")
        #expect(MCPEndpoint.socketPath(environment: [:]).hasSuffix("/Escale/agent/mcp.sock"))
    }
}
