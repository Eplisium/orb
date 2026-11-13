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
            await Task.yield()
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
        let startup = MCPHeldTask { await registry.startEnabledServers() }
        do {
            try await waitForHeld("initialize", on: old)
            var replacement = original
            replacement.args[1] = "none"
            replacement.args[2] = "replacement"
            source.replace(replacement)
            _ = try await old.callTool(name: "release", arguments: .object(["fail": .bool(fail)]))
            try await startup.value()
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
            await startup.drain()
            let cleanup = MCPHeldTask { await registry.shutdownAll() }
            await cleanup.drain()
            cleanup.cancel()
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
        let call = MCPHeldTask { await registry.call(qualifiedName: tool, argumentsJSON: args) }
        do {
            try await waitForHeld(method, on: old)
            var replacement = original
            replacement.args[1] = "none"
            replacement.args[2] = "replacement"
            source.replace(replacement)
            _ = try await old.callTool(name: "release", arguments: .object([:]))
            let obsolete = try await call.value()
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
            await call.drain()
            let cleanup = MCPHeldTask { await registry.shutdownAll() }
            await cleanup.drain()
            cleanup.cancel()
            throw error
        }
    }

    @Test("Cancelled registry waiters finish without waiting for held initialize or mutating its result",
          .enabled(if: Self.node != nil, "requires Node"), arguments: ["inventory", "definitions", "resources", "prompts", "status", "start", "targeted-start", "stop", "shutdown", "call"])
    func cancelledLifecycleWaiter(operation: String) async throws {
        let original = try config(holding: "initialize")
        let old = MCPConnection(config: original, secretStore: InMemoryCredentialStore(), requestTimeout: .seconds(8))
        let registry = MCPRegistry(configProvider: { [original] }, connectionFactory: { _ in old })
        let startup = MCPHeldTask { await registry.startEnabledServers() }
        let signal = MCPHeldWaiterSignal()
        var pendingWaiter: MCPHeldTask<Void>?
        do {
            try await waitForHeld("initialize", on: old)
            let waiter = MCPHeldTask {
                await registry.heldWaiter(operation, name: original.name, signal: signal)
            }
            pendingWaiter = waiter
            try await mcpHeldWait("registry waiter entry") { signal.started.value == true }
            #expect(await registry.heldWaiterBarrier(signal) == false,
                    "Waiter must actually suspend behind held initialization")
            waiter.cancel()
            try await waiter.value()
            #expect(signal.finished.value == true, "Cancelled caller must finish before initialize is released")
            try await waitForHeld("initialize", on: old)
            _ = try await old.callTool(name: "release", arguments: .object([:]))
            try await startup.value()
            let status = await registry.status()
            #expect(status.count == 1)
            #expect(status.allSatisfy { $0.connected && $0.error == nil })
            await registry.shutdownAll()
        } catch {
            pendingWaiter?.cancel()
            startup.cancel()
            await old.shutdown() // close first, never await a held RPC first
            await startup.drain()
            await pendingWaiter?.drain()
            let cleanup = MCPHeldTask { await registry.shutdownAll() }
            await cleanup.drain()
            cleanup.cancel()
            throw error
        }
    }

    @Test("Cancelled initial startup remains retryable without publishing a server error",
          .enabled(if: Self.node != nil, "requires Node"))
    func cancelledFirstStartupRetries() async throws {
        let original = try config(holding: "initialize")
        let old = MCPConnection(config: original, secretStore: InMemoryCredentialStore(), requestTimeout: .seconds(8))
        let registry = MCPRegistry(configProvider: { [original] }, connectionFactory: { _ in old })
        let startup = MCPHeldTask { await registry.startEnabledServers() }
        var retry: MCPHeldTask<[MCPToolDescriptor]>?
        do {
            try await waitForHeld("initialize", on: old)
            startup.cancel()
            try await startup.value()
            #expect(await old.isRunning == false)
            #expect(await old.isReady == false)
            #expect(await registry.status().allSatisfy { !$0.connected && $0.error == nil })
            // Same config AND same connection actor: no replacement can hide a
            // poisoned process-presence guard or obsolete owner cleanup.
            let retryTask = MCPHeldTask { await registry.availableTools() }
            retry = retryTask
            try await waitForHeld("initialize", on: old)
            #expect(await old.isReady == false)
            _ = try await old.callTool(name: "release", arguments: .object([:]))
            #expect(try await retryTask.value().count == 1)
            #expect(await old.isReady)
            let status = await registry.status()
            #expect(status.count == 1)
            #expect(status.allSatisfy { $0.connected && $0.error == nil })
            await registry.shutdownAll()
        } catch {
            startup.cancel()
            retry?.cancel()
            await old.shutdown()
            await startup.drain()
            await retry?.drain()
            let cleanup = MCPHeldTask { await registry.shutdownAll() }
            await cleanup.drain()
            cleanup.cancel()
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

/// Completion probes make test teardown bounded even when a lifecycle
/// continuation regresses. No test-owned continuation or unbounded task join.
final class MCPHeldValue<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value?
    var value: Value? { lock.lock(); defer { lock.unlock() }; return storage }
    func store(_ value: Value) { lock.lock(); defer { lock.unlock() }; storage = value }
}

struct MCPHeldTask<Value: Sendable>: Sendable {
    private let result: MCPHeldValue<Value>
    private let task: Task<Void, Never>

    init(_ operation: @escaping @Sendable () async -> Value) {
        let result = MCPHeldValue<Value>()
        self.result = result
        task = Task { result.store(await operation()) }
    }

    func cancel() { task.cancel() }
    func value() async throws -> Value {
        try await mcpHeldWait("task completion") { result.value != nil }
        return try #require(result.value)
    }
    func drain() async {
        do { _ = try await value() }
        catch { Issue.record("Held fixture cleanup did not drain: \(error)") }
    }
}

func mcpHeldWait(_ description: String, until predicate: () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while ContinuousClock.now < deadline {
        if await predicate() { return }
        await Task.yield()
    }
    throw MCPError.transport("Held fixture timed out waiting for \(description)")
}

private final class MCPHeldWaiterSignal: @unchecked Sendable {
    let started = MCPHeldValue<Bool>()
    let finished = MCPHeldValue<Bool>()
}

private extension MCPRegistry {
    /// Announce entry on the operation's own actor, then run until it suspends.
    /// A later actor barrier cannot observe a merely queued cross-actor hop.
    func heldWaiter(_ operation: String, name: String, signal: MCPHeldWaiterSignal) async {
        signal.started.store(true)
        defer { signal.finished.store(true) }
        switch operation {
        case "definitions": #expect(await toolDefinitions().isEmpty)
        case "resources": #expect(await availableResources().isEmpty)
        case "prompts": #expect(await availablePrompts().isEmpty)
        case "status": #expect(await status().isEmpty)
        case "start": await startEnabledServers()
        case "targeted-start": await startServer(named: name)
        case "shutdown": await shutdownAll()
        case "stop": await stopServer(named: name)
        case "call":
            let result = await call(qualifiedName: MCPToolNaming.qualify(server: name, tool: "identity"), argumentsJSON: "{}")
            #expect(result.isError)
        default: #expect(await availableTools().isEmpty)
        }
    }

    func heldWaiterBarrier(_ signal: MCPHeldWaiterSignal) -> Bool {
        signal.finished.value == true
    }
}
