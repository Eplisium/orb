import Foundation
import Testing
@testable import ORB

private final class MCPHeldConfigSource: @unchecked Sendable {
    private let lock = NSLock()
    private var configs: [MCPServerConfig]
    init(_ config: MCPServerConfig) { configs = [config] }
    func load() -> [MCPServerConfig] { lock.lock(); defer { lock.unlock() }; return configs }
    func replace(_ config: MCPServerConfig) { lock.lock(); defer { lock.unlock() }; configs = [config] }
}

@Suite("MCP held initialize and RPC replacement", .serialized)
struct MCPHeldResponseTests {
    private static var node: String? {
        ([ProcessInfo.processInfo.environment["NODE_BINARY"]].compactMap { $0 } + ["/opt/homebrew/bin/node", "/usr/local/bin/node"])
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func config(holding method: String) throws -> MCPServerConfig {
        let script = try #require(Bundle.module.url(forResource: "orb-mcp-held-response-fixture", withExtension: "mjs", subdirectory: "Fixtures"))
        return MCPServerConfig(name: "held-fixture", command: try #require(Self.node), args: [script.path, method, "original"])
    }

    private func waitForHeld(_ method: String, on connection: MCPConnection) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if await connection.isRunning,
               let state = try? await connection.callTool(name: "state", arguments: .object([:])), state.content == method { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw MCPError.transport("Fixture did not receive held request")
    }

    @Test("Actual delayed initialize success/error cannot publish obsolete launch inputs",
          .enabled(if: Self.node != nil, "requires Node"), arguments: [false, true])
    func replacedInitialize(fail: Bool) async throws {
        let original = try config(holding: "initialize")
        let source = MCPHeldConfigSource(original)
        let old = MCPConnection(config: original, secretStore: InMemoryCredentialStore(), requestTimeout: .seconds(8))
        let registry = MCPRegistry(configProvider: { source.load() }, connectionFactory: { config in
            config == original ? old : MCPConnection(config: config, secretStore: InMemoryCredentialStore(), requestTimeout: .seconds(8))
        })
        let startup = Task { await registry.startEnabledServers() }
        do {
            try await waitForHeld("initialize", on: old)
            var replacement = original
            replacement.args[1] = "none"
            replacement.args[2] = "replacement"
            source.replace(replacement)
            _ = try await old.callTool(name: "release", arguments: .object(["fail": .bool(fail)]))
            await startup.value
            #expect(await old.isRunning == false)
            let status = try #require(await registry.status().first)
            #expect(status.connected)
            #expect(status.error == nil)
            let result = await registry.call(qualifiedName: MCPToolNaming.qualify(server: original.name, tool: "identity"), argumentsJSON: "{}")
            #expect(!result.isError)
            #expect(result.content == "replacement")
            #expect(await registry.availableTools().allSatisfy { $0.description == "replacement" })
            await registry.shutdownAll()
        } catch {
            startup.cancel()
            await old.shutdown()
            await startup.value
            await registry.shutdownAll()
            throw error
        }
    }

    @Test("Actual delayed tools/resources/prompts results are rejected after config replacement",
          .enabled(if: Self.node != nil, "requires Node"), arguments: ["tools/call", "resources/read", "prompts/get"])
    func replacedRPC(method: String) async throws {
        let original = try config(holding: method)
        let source = MCPHeldConfigSource(original)
        let old = MCPConnection(config: original, secretStore: InMemoryCredentialStore(), requestTimeout: .seconds(8))
        let registry = MCPRegistry(configProvider: { source.load() }, connectionFactory: { config in
            config == original ? old : MCPConnection(config: config, secretStore: InMemoryCredentialStore(), requestTimeout: .seconds(8))
        })
        await registry.startEnabledServers()
        let tool: String
        let args: String
        switch method {
        case "resources/read": tool = MCPToolNaming.readResourceTool(server: original.name); args = #"{"uri":"fixture://identity"}"#
        case "prompts/get": tool = MCPToolNaming.getPromptTool(server: original.name); args = #"{"name":"identity"}"#
        default: tool = MCPToolNaming.qualify(server: original.name, tool: "identity"); args = "{}"
        }
        let call = Task { await registry.call(qualifiedName: tool, argumentsJSON: args) }
        do {
            try await waitForHeld(method, on: old)
            var replacement = original
            replacement.args[1] = "none"
            replacement.args[2] = "replacement"
            source.replace(replacement)
            _ = try await old.callTool(name: "release", arguments: .object([:]))
            let obsolete = await call.value
            #expect(obsolete.isError)
            #expect(obsolete.content.contains("obsolete result was discarded"))
            await registry.startServer(named: original.name)
            let current = await registry.call(qualifiedName: tool, argumentsJSON: args)
            #expect(!current.isError)
            #expect(current.content.contains("replacement"))
            #expect(await old.isRunning == false)
            await registry.shutdownAll()
        } catch {
            call.cancel()
            await old.shutdown()
            _ = await call.value
            await registry.shutdownAll()
            throw error
        }
    }

    @Test("Cancelled registry waiters finish without waiting for held initialize or mutating its result",
          .enabled(if: Self.node != nil, "requires Node"), arguments: ["inventory", "definitions", "resources", "prompts", "status", "start", "targeted-start", "stop", "shutdown", "call"])
    func cancelledLifecycleWaiter(operation: String) async throws {
        let original = try config(holding: "initialize")
        let old = MCPConnection(config: original, secretStore: InMemoryCredentialStore(), requestTimeout: .seconds(8))
        let registry = MCPRegistry(configProvider: { [original] }, connectionFactory: { _ in old })
        let startup = Task { await registry.startEnabledServers() }
        let signal = MCPHeldWaiterSignal()
        var pendingWaiter: Task<Void, Never>?
        do {
            try await waitForHeld("initialize", on: old)
            let waiter = Task {
                await signal.markStarted()
                switch operation {
                case "definitions": #expect(await registry.toolDefinitions().isEmpty)
                case "resources": #expect(await registry.availableResources().isEmpty)
                case "prompts": #expect(await registry.availablePrompts().isEmpty)
                case "status": #expect(await registry.status().isEmpty)
                case "start": await registry.startEnabledServers()
                case "targeted-start": await registry.startServer(named: original.name)
                case "shutdown": await registry.shutdownAll()
                case "stop": await registry.stopServer(named: original.name)
                case "call":
                    let result = await registry.call(qualifiedName: MCPToolNaming.qualify(server: original.name, tool: "identity"), argumentsJSON: "{}")
                    #expect(result.isError)
                default: #expect(await registry.availableTools().isEmpty)
                }
                await signal.markFinished()
            }
            pendingWaiter = waiter
            while !(await signal.started) { await Task.yield() }
            // Exercise a suspended waiter, not only a task cancelled before entry.
            try await Task.sleep(for: .milliseconds(30))
            waiter.cancel()
            let deadline = ContinuousClock.now + .seconds(1)
            while !(await signal.finished) && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(await signal.finished, "Cancelled caller must finish before initialize is released")
            _ = try await old.callTool(name: "release", arguments: .object([:]))
            await startup.value
            await waiter.value
            #expect(await registry.status().allSatisfy { $0.connected && $0.error == nil })
            await registry.shutdownAll()
        } catch {
            pendingWaiter?.cancel()
            startup.cancel()
            await old.shutdown()
            await startup.value
            await pendingWaiter?.value
            await registry.shutdownAll()
            throw error
        }
    }

    @Test("Cancelled initial startup remains retryable without publishing a server error",
          .enabled(if: Self.node != nil, "requires Node"))
    func cancelledFirstStartupRetries() async throws {
        let original = try config(holding: "initialize")
        let source = MCPHeldConfigSource(original)
        let old = MCPConnection(config: original, secretStore: InMemoryCredentialStore(), requestTimeout: .seconds(8))
        let registry = MCPRegistry(configProvider: { source.load() }, connectionFactory: { config in
            config == original ? old : MCPConnection(config: config, secretStore: InMemoryCredentialStore(), requestTimeout: .seconds(8))
        })
        let startup = Task { await registry.startEnabledServers() }
        do {
            try await waitForHeld("initialize", on: old)
            startup.cancel()
            await startup.value
            #expect(await old.isRunning == false)
            #expect(await registry.status().allSatisfy { !$0.connected && $0.error == nil })
            var ready = original
            ready.args[1] = "none"
            source.replace(ready)
            #expect(await registry.availableTools().count == 1)
            #expect(await registry.status().allSatisfy { $0.connected && $0.error == nil })
            await registry.shutdownAll()
        } catch {
            startup.cancel()
            await old.shutdown()
            await startup.value
            await registry.shutdownAll()
            throw error
        }
    }

    @Test("Literal computed compact keys cannot impersonate their original server or tool")
    func compactLiteralImpersonation() {
        let server = String(repeating: "long-server-", count: 10)
        let tool = String(repeating: "long_tool_", count: 10)
        let serverKey = MCPToolNaming.serverKey(server)
        let toolKey = MCPToolNaming.toolKey(tool)
        #expect(serverKey.hasPrefix("z-"))
        #expect(toolKey.hasPrefix("z-"))
        #expect(MCPToolNaming.serverKey(serverKey) != serverKey)
        #expect(MCPToolNaming.toolKey(toolKey) != toolKey)
        let policy = ToolPolicy.agentSession(fullComputerAccess: true, mcpServers: [MCPServerConfig(name: server, command: "unused-fixture")])
        let own = MCPToolNaming.qualify(server: server, tool: tool)
        let impersonator = MCPToolNaming.qualify(server: serverKey, tool: tool)
        #expect(policy.allowsExecution(name: own))
        #expect(!policy.allowsExecution(name: impersonator))
        #expect(!policy.allowsDefinition(name: impersonator))
        #expect(MCPToolNaming.qualify(server: server, tool: toolKey) != own)
    }
}

private actor MCPHeldWaiterSignal {
    var started = false
    var finished = false
    func markStarted() { started = true }
    func markFinished() { finished = true }
}
