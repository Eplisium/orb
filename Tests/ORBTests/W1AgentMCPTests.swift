import Foundation
import Testing
@testable import ORB

// Wave 1, agent track: MCP settings and lifecycle (AGENT-8..11, AGENT-14),
// prompt enhancer model fallback (V-5).

/// A tiny stdio MCP server in Python: pages tools/list across two pages,
/// and after a `grow` call announces tools/list_changed with one more tool.
private let agentW1PagingServer = #"""
import json, sys
grown = False
def send(obj):
    sys.stdout.write(json.dumps(obj) + "\n"); sys.stdout.flush()
def tool(name):
    return {"name": name, "description": name, "inputSchema": {"type": "object", "properties": {}}}
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    msg = json.loads(line)
    method = msg.get("method"); mid = msg.get("id")
    if mid is None: continue
    if method == "initialize":
        send({"jsonrpc": "2.0", "id": mid, "result": {"protocolVersion": "2024-11-05", "capabilities": {"tools": {"listChanged": True}}, "serverInfo": {"name": "w1-paging"}}})
    elif method == "tools/list":
        cursor = (msg.get("params") or {}).get("cursor")
        if cursor is None:
            send({"jsonrpc": "2.0", "id": mid, "result": {"tools": [tool("alpha"), tool("beta")], "nextCursor": "page2"}})
        else:
            tools = [tool("gamma")] + ([tool("delta")] if grown else [])
            send({"jsonrpc": "2.0", "id": mid, "result": {"tools": tools}})
    elif method == "tools/call":
        grown = True
        send({"jsonrpc": "2.0", "id": mid, "result": {"content": [{"type": "text", "text": "grown"}]}})
        send({"jsonrpc": "2.0", "method": "notifications/tools/list_changed"})
    else:
        send({"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": "nope"}})
"""#

private let agentW1Python = "/usr/bin/python3"

private func agentW1PythonWorks() -> Bool {
    guard FileManager.default.isExecutableFile(atPath: agentW1Python) else { return false }
    // /usr/bin/python3 is a shim that can lack a real interpreter.
    let process = Process()
    process.executableURL = URL(fileURLWithPath: agentW1Python)
    process.arguments = ["-c", "print(1)"]
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    do { try process.run() } catch { return false }
    process.waitUntilExit()
    return process.terminationStatus == 0
}

private func agentW1ServerScript() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("orb-w1-mcp-\(UUID().uuidString).py")
    try agentW1PagingServer.write(to: url, atomically: true, encoding: .utf8)
    return url
}

private final class AgentW1ConfigBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: [MCPServerConfig]
    init(_ value: [MCPServerConfig]) { self.value = value }
    var configs: [MCPServerConfig] {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
}

enum AgentW1Env {
    static let python = agentW1PythonWorks()
}

@Suite("W1 agent: MCP import and settings logic (AGENT-8, AGENT-10)")
struct W1AgentMCPSettingsLogicTests {
    @Test("remote URL servers are skipped with a note, local ones import")
    func mixedImport() throws {
        let json = #"""
        {"mcpServers": {
          "files": {"command": "npx", "args": ["-y", "server-fs"], "cwd": "~/proj", "disabled": true},
          "remote": {"url": "https://mcp.example.com/sse"},
          "http": {"type": "http", "serverUrl": "https://x"}
        }}
        """#
        let report = try MCPRegistry.parseStandardConfigReport(json)
        #expect(report.configs.map(\.name) == ["files"])
        #expect(report.configs.first?.isEnabled == false)
        #expect(report.configs.first?.workingDirectory == "~/proj")
        #expect(report.warnings.count == 2)
        #expect(report.warnings.allSatisfy { $0.contains("remote (URL) server") })
        // The legacy entry point imports the same local servers instead of failing.
        #expect(try MCPRegistry.parseStandardConfig(json).map(\.name) == ["files"])
    }

    @Test("a paste with only remote servers explains why nothing imported")
    func onlyRemote() {
        #expect(throws: MCPError.self) {
            try MCPRegistry.parseStandardConfigReport(#"{"a":{"url":"https://x"}}"#)
        }
        // An entry with neither a command nor a URL is still an error.
        #expect(throws: MCPError.self) {
            try MCPRegistry.parseStandardConfigReport(#"{"a":{"args":[]}, "b":{"command":"x"}}"#)
        }
    }

    @Test("cwd round-trips through the saved config")
    func cwdCodable() throws {
        var config = MCPServerConfig(name: "n", command: "c")
        config.workingDirectory = "/tmp/w1"
        let decoded = try JSONDecoder().decode(MCPServerConfig.self, from: JSONEncoder().encode(config))
        #expect(decoded.workingDirectory == "/tmp/w1")
        let legacy = try JSONDecoder().decode(MCPServerConfig.self, from: Data(#"{"id":"\#(UUID().uuidString)","name":"x","command":"y","args":[],"env":{},"isEnabled":true}"#.utf8))
        #expect(legacy.workingDirectory == nil)
    }

    @Test("duplicate names are rejected inline and new rows get a unique name")
    func names() {
        let a = MCPServerConfig(name: "New Server", command: "x")
        let b = MCPServerConfig(name: "github", command: "y")
        #expect(MCPRegistry.nameError(for: "GitHub", id: UUID(), in: [a, b]) != nil)
        #expect(MCPRegistry.nameError(for: "github", id: b.id, in: [a, b]) == nil)
        #expect(MCPRegistry.nameError(for: "  ", id: UUID(), in: [a]) != nil)
        #expect(MCPRegistry.uniqueName("New Server", in: [a]) == "New Server 2")
        #expect(MCPRegistry.uniqueName("Other", in: [a]) == "Other")
    }

    @Test("a secret env value goes to the store; the config keeps only a reference")
    func secretEnv() {
        let store = InMemoryCredentialStore()
        var config = MCPServerConfig(name: "gh", command: "npx")
        config.env["GITHUB_PERSONAL_ACCESS_TOKEN"] = "stale-plaintext"
        let result = MCPRegistry.settingSecretEnv("GITHUB_PERSONAL_ACCESS_TOKEN", value: "w1-fake-token", in: config, store: store)
        #expect(result.error == nil)
        let reference = try? #require(result.config.secretEnv?["GITHUB_PERSONAL_ACCESS_TOKEN"])
        #expect(reference?.hasPrefix(MCPServerConfig.secretReferencePrefix) == true)
        #expect(result.config.env["GITHUB_PERSONAL_ACCESS_TOKEN"] == nil)
        #expect(!String(decoding: (try? JSONEncoder().encode(result.config)) ?? Data(), as: UTF8.self).contains("w1-fake-token"))
        #expect(reference.flatMap { store.secret(forReference: $0) } == "w1-fake-token")

        let removed = MCPRegistry.removingSecretEnv("GITHUB_PERSONAL_ACCESS_TOKEN", from: result.config, store: store)
        #expect(removed.secretEnv == nil)
        #expect(reference.flatMap { store.secret(forReference: $0) } == nil)
    }

    @Test("edits classify into toggle vs relaunch-needed")
    func rowEdits() {
        let base = MCPServerConfig(name: "a", command: "x")
        var toggled = base; toggled.isEnabled = false
        var renamed = base; renamed.name = "b"
        var envEdit = base; envEdit.env["K"] = "v"
        #expect(MCPRowEdit.classify(old: base, new: base) == .unchanged)
        #expect(MCPRowEdit.classify(old: base, new: toggled) == .toggled)
        #expect(MCPRowEdit.classify(old: base, new: renamed) == .launchInputsChanged)
        #expect(MCPRowEdit.classify(old: base, new: envEdit) == .launchInputsChanged)
    }

    @Test("status text reflects live state")
    func statusText() {
        #expect(MCPRowStatusText.text(for: .init(connected: true, toolCount: 1, error: nil, needsApply: false), isEnabled: true) == "✓ Connected — 1 tool")
        #expect(MCPRowStatusText.text(for: .init(connected: false, toolCount: 0, error: "boom", needsApply: false), isEnabled: true) == "boom")
        #expect(MCPRowStatusText.text(for: .init(connected: false, toolCount: 0, error: nil, needsApply: false), isEnabled: false).hasPrefix("Off"))
    }

    @Test("removing a server deletes its Keychain references through the store")
    func removalDeletesSecrets() async {
        let store = InMemoryCredentialStore()
        var config = MCPServerConfig(name: "w1-remove", command: "")
        config = MCPRegistry.settingSecretEnv("API_KEY", value: "w1-secret", in: config, store: store).config
        let reference = config.secretEnv?["API_KEY"] ?? ""
        #expect(store.secret(forReference: reference) == "w1-secret")
        let registry = MCPRegistry(configProvider: { [] })
        let failed = await MCPServerRemoval.finish(config, registry: registry, store: store)
        #expect(failed.isEmpty)
        #expect(store.secret(forReference: reference) == nil)
        #expect(MCPServerRemoval.confirmationMessage(for: config).contains("1 Keychain value"))
    }
}

@Suite("W1 agent: MCP connection diagnostics and lists (AGENT-9, AGENT-14)", .serialized)
struct W1AgentMCPConnectionTests {
    @Test("a server that dies explains itself with its stderr")
    func stderrInFailure() async {
        let config = MCPServerConfig(name: "w1-boom", command: "/bin/sh", args: ["-c", "echo boom-reason-w1 >&2; exit 1"])
        let connection = MCPConnection(config: config, secretStore: InMemoryCredentialStore())
        do {
            try await connection.connect()
            Issue.record("expected the connection to fail")
        } catch {
            #expect(error.localizedDescription.contains("boom-reason-w1"))
        }
        await connection.shutdown()
    }

    @Test("initialize fails fast when a server never answers")
    func initializeTimeout() async {
        let config = MCPServerConfig(name: "w1-silent", command: "/bin/sleep", args: ["30"])
        let connection = MCPConnection(config: config, secretStore: InMemoryCredentialStore(),
                                       requestTimeout: .seconds(120), initializeTimeout: .milliseconds(600))
        let start = ContinuousClock.now
        do {
            try await connection.connect()
            Issue.record("expected a timeout")
        } catch {
            #expect(error.localizedDescription.contains("initialize"))
        }
        #expect(ContinuousClock.now - start < .seconds(15))
        await connection.shutdown()
    }

    @Test("a probe can be cancelled")
    func probeCancel() async {
        let registry = MCPRegistry(configProvider: { [] })
        let config = MCPServerConfig(name: "w1-hang", command: "/bin/sleep", args: ["30"])
        let start = ContinuousClock.now
        let task = Task { await registry.probe(config) }
        try? await Task.sleep(for: .milliseconds(300))
        task.cancel()
        let outcome = await task.value
        if case .success = outcome { Issue.record("a cancelled probe must not succeed") }
        #expect(ContinuousClock.now - start < .seconds(15))
    }

    @Test("tools/list follows nextCursor and refreshes on list_changed",
          .enabled(if: AgentW1Env.python, "requires a working /usr/bin/python3"))
    func pagingAndListChanged() async throws {
        let script = try agentW1ServerScript()
        defer { try? FileManager.default.removeItem(at: script) }
        let config = MCPServerConfig(name: "w1-paging", command: agentW1Python, args: [script.path])
        let connection = MCPConnection(config: config, secretStore: InMemoryCredentialStore())
        try await connection.connect()
        #expect(await connection.tools.map(\.toolName) == ["alpha", "beta", "gamma"])
        _ = try await connection.callTool(name: "alpha", arguments: .object([:]))
        for _ in 0..<300 where await connection.tools.count < 4 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await connection.tools.map(\.toolName) == ["alpha", "beta", "gamma", "delta"])
        #expect(await connection.listRefreshCount == 1)
        await connection.shutdown()
    }

    @Test("rowStatuses reports live state by id, and stopServer(id:) stops a renamed row's process",
          .enabled(if: AgentW1Env.python, "requires a working /usr/bin/python3"))
    func statusAndStopByID() async throws {
        let script = try agentW1ServerScript()
        defer { try? FileManager.default.removeItem(at: script) }
        let config = MCPServerConfig(name: "w1-live", command: agentW1Python, args: [script.path])
        let box = AgentW1ConfigBox([config])
        let registry = MCPRegistry(
            configProvider: { box.configs },
            connectionFactory: { MCPConnection(config: $0, secretStore: InMemoryCredentialStore()) }
        )
        await registry.startServer(named: "w1-live")
        let live = try #require(await registry.rowStatuses()[config.id])
        #expect(live.connected)
        #expect(live.toolCount == 3)

        var renamed = config
        renamed.name = "w1-renamed"
        box.configs = [renamed]
        let stale = try #require(await registry.rowStatuses()[config.id])
        #expect(!stale.connected)
        #expect(stale.needsApply)

        await registry.stopServer(id: config.id)
        #expect(!(await registry.isRunning(id: config.id)))
        await registry.shutdownAll()
    }
}

@MainActor
private final class AgentW1ControlHost: ORBControlHost {
    var configs: [MCPServerConfig]
    var stopped: [String] = []
    let defaults = UserDefaults(suiteName: "orb-w1-agent-\(UUID().uuidString)")!
    init(_ configs: [MCPServerConfig]) { self.configs = configs }
    var controlConversations: [ChatConversation] { [] }
    var controlRunningConversationID: UUID? { nil }
    func controlRename(_ id: UUID, to title: String) -> Bool { false }
    func controlSetSystemPrompt(_ prompt: String, for id: UUID) -> Bool { false }
    func controlDelete(_ id: UUID) -> Bool { false }
    func controlMCPConfigs() -> [MCPServerConfig] { configs }
    func controlSaveMCPConfigs(_ configs: [MCPServerConfig]) { self.configs = configs }
    func controlStopMCPServer(named name: String) { stopped.append(name) }
    var controlDefaults: UserDefaults { defaults }
}

@Suite("W1 agent: OP Mode MCP toggle (AGENT-11)")
@MainActor
struct W1AgentORBControlTests {
    private func call(_ args: [String: String], _ host: AgentW1ControlHost) -> NativeAgentToolResult {
        let json = String(decoding: try! JSONSerialization.data(withJSONObject: args), as: UTF8.self)
        return ORBControlTools.execute(name: "orb_set_mcp_server_enabled", argumentsJSON: json, host: host)
    }

    @Test("the agent cannot enable a server the user turned off")
    func enableRefused() {
        let host = AgentW1ControlHost([MCPServerConfig(name: "files", command: "x", isEnabled: false)])
        let result = call(["name": "files", "enabled": "true"], host)
        #expect(result.isError)
        #expect(result.content.contains("Only you can enable"))
        #expect(host.configs.first?.isEnabled == false)
    }

    @Test("disabling saves and stops the server now")
    func disableStops() {
        let host = AgentW1ControlHost([MCPServerConfig(name: "files", command: "x", isEnabled: true)])
        let result = call(["name": "files", "enabled": "false"], host)
        #expect(!result.isError)
        #expect(result.content.contains("stopped"))
        #expect(host.configs.first?.isEnabled == false)
        #expect(host.stopped == ["files"])
    }
}

@Suite("W1 agent: prompt enhancer model (V-5)")
struct W1AgentPromptEnhancerTests {
    private func model(_ id: String, completion: String = "0.000001", outputs: [String] = ["text"]) -> ModelInfo {
        let json = """
        {"id":"\(id)","name":"\(id)","pricing":{"prompt":"0.0000005","completion":"\(completion)"},
         "architecture":{"modality":"text->text","input_modalities":["text"],"output_modalities":\(outputs.description)}}
        """
        return try! JSONDecoder().decode(ModelInfo.self, from: Data(json.utf8))
    }

    @Test("pinned Agent model, then Chat default, then a fast catalog model")
    func order() {
        let catalog = [model("a/cheap", completion: "0.0000001"), model("google/gemini-2.5-flash-lite"), model("x/pinned"), model("y/chat")]
        #expect(PromptEnhancer.resolveModel(pinnedAgent: "x/pinned", chatDefault: "y/chat", catalog: catalog) == "x/pinned")
        #expect(PromptEnhancer.resolveModel(pinnedAgent: "", chatDefault: "y/chat", catalog: catalog) == "y/chat")
        #expect(PromptEnhancer.resolveModel(pinnedAgent: "", chatDefault: "", catalog: catalog) == "google/gemini-2.5-flash-lite")
        // A pinned id that left the catalog is skipped.
        #expect(PromptEnhancer.resolveModel(pinnedAgent: "gone/model", chatDefault: "", catalog: catalog) == "google/gemini-2.5-flash-lite")
    }

    @Test("without a known fast model, the cheapest paid text-only model is used")
    func cheapest() {
        let catalog = [model("b/pricey", completion: "0.00001"), model("a/cheap", completion: "0.0000002"),
                       model("img/maker", completion: "0.00000001", outputs: ["image"]),
                       model("z/embed-small", completion: "0.00000001"), model("f/free:free", completion: "0")]
        #expect(PromptEnhancer.resolveModel(pinnedAgent: "", chatDefault: "", catalog: catalog) == "a/cheap")
    }

    @Test("never empty: no pin and no catalog falls back to a fast default")
    func fallback() {
        #expect(PromptEnhancer.resolveModel(pinnedAgent: "", chatDefault: "") == PromptEnhancer.fallbackModel)
        #expect(!PromptEnhancer.fallbackModel.isEmpty)
        #expect(PromptEnhancer.modelLabel(pinnedAgent: "", chatDefault: "", resolved: "google/gemini-2.5-flash-lite") == "gemini-2.5-flash-lite (fast default)")
    }
}
