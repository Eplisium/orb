import Foundation
import Testing
@testable import ORB

/// B03/B17/B18 regressions. Only the uniquely named local fixture is launched.
/// Registry tests inject an in-memory config source. They never read or replace
/// standard defaults, invoke MCPRegistry.shared, or re-exec SwiftPM's helper.
@Suite(.serialized)
struct MCPBackendFixTests {

    private static var node: String? {
        let candidates = [ProcessInfo.processInfo.environment["NODE_BINARY"]]
            .compactMap { $0 } + [
                NSHomeDirectory() + "/.local/bin/node",
                "/opt/homebrew/bin/node", "/usr/local/bin/node"
            ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static var script: URL? {
        Bundle.module.url(
            forResource: "orb-mcp-backend-fix-fixture", withExtension: "mjs",
            subdirectory: "Fixtures"
        )
    }

    static var fixtureAvailable: Bool { node != nil && script != nil }

    private static func config(name: String = "backend-fixture") throws -> MCPServerConfig {
        MCPServerConfig(
            name: name, command: try #require(node),
            args: [try #require(script).path, "argument-A"],
            env: ["ORB_MCP_FIXTURE_MARKER": "environment-A"]
        )
    }

    // MARK: B03 — identity must survive advertisement, parsing, and policy

    @Test("B03 punctuation-distinct servers cannot advertise the same RPC name",
          arguments: ["prod_api", "prod.api", "prod api"])
    func distinctServerNamesDoNotAlias(otherName: String) throws {
        let first = MCPToolNaming.qualify(server: "prod-api", tool: "echo")
        let second = MCPToolNaming.qualify(server: otherName, tool: "echo")
        #expect(first != second, "Distinct configured servers must not share an RPC identity")
        let firstRoute = try #require(MCPToolNaming.resolve(first))
        let secondRoute = try #require(MCPToolNaming.resolve(second))
        #expect(firstRoute.server != secondRoute.server)
        #expect(firstRoute.tool == "echo")
        #expect(secondRoute.tool == "echo")
        #expect(MCPToolNaming.readResourceTool(server: "prod-api") !=
                MCPToolNaming.readResourceTool(server: otherName))
        #expect(MCPToolNaming.getPromptTool(server: "prod-api") !=
                MCPToolNaming.getPromptTool(server: otherName))
    }

    @Test("B03 approving one server must not authorize a punctuation-colliding server")
    func approvalDoesNotAlias() {
        // This command is metadata only; this test launches nothing.
        let approved = MCPServerConfig(name: "prod_api", command: "unused-fixture-command")
        let policy = ToolPolicy.agentSession(fullComputerAccess: true, mcpServers: [approved])
        let own = MCPToolNaming.qualify(server: "prod_api", tool: "echo")
        let foreign = MCPToolNaming.qualify(server: "prod-api", tool: "echo")
        #expect(policy.allowsDefinition(name: own))
        #expect(policy.allowsExecution(name: own))
        #expect(!policy.allowsDefinition(name: foreign))
        #expect(!policy.allowsExecution(name: foreign))
    }

    @Test("Qualified tool names remain within provider length limits")
    func providerNameLimits() {
        let pairs = [
            ("production_database_reporting", "query"),
            (String(repeating: "long-server-", count: 20), "query"),
            ("server", String(repeating: "long_tool_", count: 20)),
            ("工具", String(repeating: "动作", count: 50))
        ]
        let names = pairs.map { MCPToolNaming.qualify(server: $0.0, tool: $0.1) }
        #expect(Set(names).count == pairs.count)
        for name in names { #expect(name.utf8.count <= 64) }
    }

    @Test("Compacted long tool names route back to their original RPC names",
          .enabled(if: MCPBackendFixTests.fixtureAvailable, "requires Node (or NODE_BINARY)"))
    func compactedNamesRoute() async throws {
        var config = try Self.config(name: "production_database_reporting")
        let tool = String(repeating: "long_tool_", count: 20)
        config.env["ORB_MCP_FIXTURE_LONG_TOOL"] = tool
        let configs = [config]
        let registry = MCPRegistry(configProvider: { configs })
        do {
            await registry.startEnabledServers()
            let qualified = MCPToolNaming.qualify(server: config.name, tool: tool)
            #expect(qualified.utf8.count <= 64)
            let result = await registry.call(qualifiedName: qualified, argumentsJSON: "{}")
            #expect(!result.isError)
            let identity = try JSONDecoder().decode(Identity.self, from: Data(result.content.utf8))
            #expect(identity.argumentMarker == "argument-A")
            await registry.shutdownAll()
        } catch {
            await registry.shutdownAll()
            throw error
        }
    }

    @Test("B03 namespace escaping is distinct and uses ASCII without separators")
    func namespaceEscaping() throws {
        // Include an escape-looking literal and Unicode names, not only spaces.
        let names = ["prod-api", "prod_api", "prod.api", "prod api", "prod__api", "z-70726f645f617069", "工具", "", "z-"]
        let qualified = names.map { MCPToolNaming.qualify(server: $0, tool: "echo__suffix") }
        #expect(Set(qualified).count == names.count)
        for name in qualified {
            let route = try #require(MCPToolNaming.resolve(name))
            #expect(route.tool == "echo__suffix")
            #expect(!route.server.contains("__"))
            #expect(name.utf8.allSatisfy { byte in
                (65...90).contains(byte) || (97...122).contains(byte) ||
                (48...57).contains(byte) || byte == 45 || byte == 95
            })
        }
    }

    @Test("B03 simultaneous punctuation-distinct servers route to their own process",
          .enabled(if: MCPBackendFixTests.fixtureAvailable, "requires Node (or NODE_BINARY)"),
          .timeLimit(.minutes(1)))
    func distinctServersRouteCorrectly() async throws {
        var first = try Self.config(name: "prod-api")
        first.args[1] = "first-server"
        var second = try Self.config(name: "prod_api")
        second.args[1] = "second-server"
        let configs = [first, second]
        let registry = MCPRegistry(configProvider: { configs })
        do {
            await registry.startEnabledServers()
            let tools = await registry.availableTools()
            #expect(tools.count == 6)
            #expect(Set(tools.map(\.qualifiedName)).count == tools.count)
            let firstResult = try await Self.identity(registry, name: first.name)
            let secondResult = try await Self.identity(registry, name: second.name)
            #expect(firstResult.argumentMarker == "first-server")
            #expect(secondResult.argumentMarker == "second-server")
            #expect(firstResult.instance != secondResult.instance)
            await registry.shutdownAll()
        } catch {
            await registry.shutdownAll()
            throw error
        }
    }

    // MARK: B17 — a full stdin pipe cannot hold cancellation hostage

    @Test("B17 cancellation completes before a stalled reader resumes",
          .enabled(if: MCPBackendFixTests.fixtureAvailable, "requires Node (or NODE_BINARY)"),
          .timeLimit(.minutes(1)))
    func stalledWriteCancellationIsPrompt() async throws {
        try await Self.exerciseStalledWrite(deadline: false)
    }

    @Test("B17 an external request deadline can cancel a stalled stdin write",
          .enabled(if: MCPBackendFixTests.fixtureAvailable, "requires Node (or NODE_BINARY)"),
          .timeLimit(.minutes(1)))
    func stalledWriteHonorsCallerDeadline() async throws {
        // Separate from the native timeout regression: caller cancellation
        // must also cover serialization/queueing/writing, not only replies.
        try await Self.exerciseStalledWrite(deadline: true)
    }

    private static func exerciseStalledWrite(deadline: Bool) async throws {
        let connection = MCPConnection(config: try config(), secretStore: InMemoryCredentialStore())
        do {
            try await connection.connect()
            let armed = try await connection.callTool(name: "arm_stall", arguments: .object([:]))
            try #require(armed.content == "stdin-paused-for-3000ms")

            // Far above the local pipe capacity, but still small enough to
            // serialize quickly. The fixture resumes reading after 3s even
            // when the connection actor is completely blocked.
            let arguments = JSONValue.object(["payload": .string(String(repeating: "x", count: 4 * 1024 * 1024))])
            let entered = MCPBackendFixEntrySignal()
            let request = Task.detached {
                await entered.markEntered()
                return try await connection.callTool(name: "large_payload", arguments: arguments)
            }
            await entered.waitUntilEntered()

            if deadline {
                let started = ContinuousClock.now
                let timer = Task.detached {
                    try? await Task.sleep(for: .milliseconds(300))
                    if !Task.isCancelled { request.cancel() }
                }
                let outcome = await request.result
                timer.cancel()
                let elapsed = ContinuousClock.now - started
                Self.expectCancellation(outcome)
                #expect(elapsed < .milliseconds(1500),
                        "A 300ms caller deadline must not wait for the fixture's 3s drain")
            } else {
                // Give serialization/write time to fill the pipe. This sleep
                // is outside the connection actor, as is the cancel signal.
                try await Task.sleep(for: .milliseconds(300))
                let started = ContinuousClock.now
                request.cancel()
                let outcome = await request.result
                let elapsed = ContinuousClock.now - started
                Self.expectCancellation(outcome)
                #expect(elapsed < .seconds(1),
                        "Stop must return before the fixture's independent 3s release")
            }
            // Await cleanup, never fire-and-forget it. If this blocks, the
            // fixture still resumes its reader and has a 12s lifetime cap.
            await connection.shutdown()
        } catch {
            await connection.shutdown()
            throw error
        }
    }

    private static func expectCancellation(_ result: Result<NativeAgentToolResult, Error>) {
        switch result {
        case .success:
            Issue.record("A cancelled stalled write must not produce a successful tool result")
        case .failure(let error):
            #expect(error is CancellationError)
        }
    }

    @Test("B17 native timeout includes a stalled stdin write",
          .enabled(if: MCPBackendFixTests.fixtureAvailable, "requires Node (or NODE_BINARY)"),
          .timeLimit(.minutes(1)))
    func stalledWriteHonorsNativeTimeout() async throws {
        let connection = MCPConnection(
            config: try Self.config(), secretStore: InMemoryCredentialStore(),
            requestTimeout: .milliseconds(800)
        )
        do {
            try await connection.connect()
            _ = try await connection.callTool(name: "arm_stall", arguments: .object([:]))
            let started = ContinuousClock.now
            do {
                _ = try await connection.callTool(name: "large_payload", arguments: .object([
                    "payload": .string(String(repeating: "x", count: 4 * 1024 * 1024))
                ]))
                Issue.record("A stalled request must reach its native deadline")
            } catch {
                #expect(error as? MCPError == .timedOut("tools/call"))
            }
            #expect(ContinuousClock.now - started < .milliseconds(1800))
            // A partly written frame cannot be removed safely. Closing the
            // transport prevents its missing tail/newline executing later.
            #expect(await connection.isRunning == false)
            await connection.shutdown()
        } catch {
            await connection.shutdown()
            throw error
        }
    }

    @Test("B17 queued cancellation never executes after the reader resumes",
          .enabled(if: MCPBackendFixTests.fixtureAvailable, "requires Node (or NODE_BINARY)"),
          .timeLimit(.minutes(1)), arguments: [false, true])
    func queuedCancellationDoesNotExecute(notification: Bool) async throws {
        let connection = MCPConnection(config: try Self.config(), secretStore: InMemoryCredentialStore())
        do {
            try await connection.connect()
            _ = try await connection.callTool(name: "arm_stall", arguments: .object([:]))
            let large = Task {
                try await connection.callTool(name: "large_payload", arguments: .object([
                    "payload": .string(String(repeating: "x", count: 4 * 1024 * 1024))
                ]))
            }
            try await Task.sleep(for: .milliseconds(200))
            let queued = Task { () async throws -> NativeAgentToolResult in
                if notification {
                    try await connection.notify(method: "notifications/record_execution", params: .object([:]))
                    return .init(content: "sent", isError: false)
                }
                return try await connection.callTool(name: "record_execution", arguments: .object([:]))
            }
            try await Task.sleep(for: .milliseconds(100))
            let started = ContinuousClock.now
            queued.cancel()
            Self.expectCancellation(await queued.result)
            #expect(ContinuousClock.now - started < .seconds(1))
            _ = try await large.value
            let count = try await connection.callTool(name: "execution_count", arguments: .object([:]))
            #expect(count.content == "0", "A cancelled queued frame must never reach the server")
            #expect(await connection.isRunning)
            await connection.shutdown()
        } catch {
            await connection.shutdown()
            throw error
        }
    }

    @Test("B17 notification writes have cancellation and native deadlines",
          .enabled(if: MCPBackendFixTests.fixtureAvailable, "requires Node (or NODE_BINARY)"),
          .timeLimit(.minutes(1)), arguments: [false, true])
    func stalledNotificationIsBounded(nativeTimeout: Bool) async throws {
        let connection = MCPConnection(
            config: try Self.config(), secretStore: InMemoryCredentialStore(),
            requestTimeout: nativeTimeout ? .milliseconds(800) : .seconds(120)
        )
        do {
            try await connection.connect()
            _ = try await connection.callTool(name: "arm_stall", arguments: .object([:]))
            let started = ContinuousClock.now
            let notification = Task {
                try await connection.notify(method: "notifications/fixture", params: .object([
                    "payload": .string(String(repeating: "x", count: 4 * 1024 * 1024))
                ]))
            }
            if !nativeTimeout {
                try await Task.sleep(for: .milliseconds(300))
                notification.cancel()
            }
            switch await notification.result {
            case .success:
                Issue.record("A stalled notification must not outlive its cancellation/deadline")
            case .failure(let error):
                if nativeTimeout {
                    #expect(error as? MCPError == .timedOut("notifications/fixture"))
                } else {
                    #expect(error is CancellationError)
                }
            }
            #expect(ContinuousClock.now - started < .milliseconds(1800))
            #expect(await connection.isRunning == false)
            await connection.shutdown()
        } catch {
            await connection.shutdown()
            throw error
        }
    }

    @Test("B17 shutdown is prompt while stdin is full",
          .enabled(if: MCPBackendFixTests.fixtureAvailable, "requires Node (or NODE_BINARY)"),
          .timeLimit(.minutes(1)))
    func shutdownWhileWriting() async throws {
        let connection = MCPConnection(config: try Self.config(), secretStore: InMemoryCredentialStore())
        do {
            try await connection.connect()
            _ = try await connection.callTool(name: "arm_stall", arguments: .object([:]))
            let request = Task {
                try await connection.callTool(name: "large_payload", arguments: .object([
                    "payload": .string(String(repeating: "x", count: 4 * 1024 * 1024))
                ]))
            }
            try await Task.sleep(for: .milliseconds(300))
            let started = ContinuousClock.now
            await connection.shutdown()
            #expect(ContinuousClock.now - started < .seconds(1))
            if case .success = await request.result {
                Issue.record("Shutdown must fail a pending write")
            }
            #expect(await connection.isRunning == false)
        } catch {
            await connection.shutdown()
            throw error
        }
    }

    // MARK: B18 — live replacement, not merely persistence

    @Test("B18 same-name config replacement changes the effective live process",
          .enabled(if: MCPBackendFixTests.fixtureAvailable, "requires Node (or NODE_BINARY)"),
          .timeLimit(.minutes(1)))
    func sameNameReplacement() async throws {
        try await Self.exerciseReplacement()
    }

    @Test("B18 command, secret references and UUID changes replace the process",
          .enabled(if: MCPBackendFixTests.fixtureAvailable, "requires Node (or NODE_BINARY)"),
          .timeLimit(.minutes(1)))
    func fullConfigurationReplacement() async throws {
        let source = MCPBackendFixConfigSource()
        let registry = MCPRegistry(configProvider: { source.load() }, connectionFactory: { config in
            let store = InMemoryCredentialStore()
            _ = store.saveSecret("secret-A", forReference: "fixture-reference-A")
            _ = store.saveSecret("secret-B", forReference: "fixture-reference-B")
            return MCPConnection(config: config, secretStore: store)
        })
        do {
            var current = try Self.config()
            current.secretEnv = ["ORB_MCP_FIXTURE_MARKER": "fixture-reference-A"]
            source.replace([current])
            await registry.startEnabledServers()
            let first = try await Self.identity(registry, name: current.name)
            #expect(first.environmentMarker == "secret-A")
            current.secretEnv = ["ORB_MCP_FIXTURE_MARKER": "fixture-reference-B"]
            source.replace([current])
            await registry.startServer(named: current.name)
            let secretChanged = try await Self.identity(registry, name: current.name)
            #expect(secretChanged.environmentMarker == "secret-B")
            #expect(secretChanged.instance != first.instance)

            // Lexically different command, same executable; no shell or external fixture.
            let nodeURL = URL(fileURLWithPath: current.command)
            current.command = nodeURL.deletingLastPathComponent().path + "/./" + nodeURL.lastPathComponent
            source.replace([current])
            await registry.startEnabledServers()
            let commandChanged = try await Self.identity(registry, name: current.name)
            #expect(commandChanged.instance != secretChanged.instance)

            current.id = UUID()
            source.replace([current])
            await registry.startServer(named: current.name)
            let idChanged = try await Self.identity(registry, name: current.name)
            #expect(idChanged.instance != commandChanged.instance)
            await registry.startEnabledServers()
            #expect(try await Self.identity(registry, name: current.name) == idChanged)
            await registry.shutdownAll()
        } catch {
            await registry.shutdownAll()
            throw error
        }
    }

    @Test("B18 targeted reconciliation removes renamed, disabled and deleted connections",
          .enabled(if: MCPBackendFixTests.fixtureAvailable, "requires Node (or NODE_BINARY)"),
          .timeLimit(.minutes(1)))
    func removedRenamedDisabled() async throws {
        let source = MCPBackendFixConfigSource()
        let tracker = MCPBackendFixConnectionTracker()
        let registry = MCPRegistry(configProvider: { source.load() }, connectionFactory: { config in
            await tracker.make(config)
        })
        do {
            var current = try Self.config(name: "before-rename")
            source.replace([current])
            await registry.startEnabledServers()
            let first = try await Self.identity(registry, name: current.name)
            current.name = "after-rename"
            source.replace([current])
            await registry.startServer(named: current.name)
            let renamed = try await Self.identity(registry, name: current.name)
            #expect(renamed.instance != first.instance)
            #expect(await tracker.liveCount() == 1)
            let tools = await registry.availableTools()
            #expect(tools.count == 3)
            #expect(tools.allSatisfy { $0.serverName == current.name })
            let oldCall = await registry.call(
                qualifiedName: MCPToolNaming.qualify(server: "before-rename", tool: "identity"), argumentsJSON: "{}"
            )
            #expect(oldCall.isError)

            current.isEnabled = false
            source.replace([current])
            await registry.startServer(named: current.name)
            #expect(await registry.availableTools().isEmpty)
            #expect(await tracker.liveCount() == 0)
            #expect(await registry.status().allSatisfy { !$0.connected && $0.error == nil })
            current.isEnabled = true
            source.replace([current])
            await registry.startServer(named: current.name)
            #expect(try await Self.identity(registry, name: current.name).instance != renamed.instance)
            source.replace([])
            await registry.startServer(named: current.name)
            #expect(await registry.availableTools().isEmpty)
            #expect(await registry.status().isEmpty)
            #expect(await tracker.liveCount() == 0)
            await registry.shutdownAll()
        } catch {
            await registry.shutdownAll()
            throw error
        }
    }

    @Test("B18 failed replacement stops the previous process and clears obsolete errors",
          .enabled(if: MCPBackendFixTests.fixtureAvailable, "requires Node (or NODE_BINARY)"),
          .timeLimit(.minutes(1)))
    func failedReplacementDoesNotKeepOldProcess() async throws {
        let source = MCPBackendFixConfigSource()
        let tracker = MCPBackendFixConnectionTracker()
        let registry = MCPRegistry(configProvider: { source.load() }, connectionFactory: { config in
            await tracker.make(config)
        })
        do {
            var current = try Self.config()
            source.replace([current])
            await registry.startEnabledServers()
            _ = try await Self.identity(registry, name: current.name)
            current.command = ""
            source.replace([current])
            await registry.startServer(named: current.name)
            #expect(await registry.availableTools().isEmpty)
            let invalid = try #require(await registry.status().first)
            #expect(!invalid.connected)
            #expect(invalid.error == "Command is empty.")
            #expect(await tracker.liveCount() == 0)
            let result = await registry.call(
                qualifiedName: MCPToolNaming.qualify(server: current.name, tool: "identity"), argumentsJSON: "{}"
            )
            #expect(result.isError)

            current.command = try #require(Self.node)
            current.secretEnv = ["ORB_MCP_FIXTURE_MARKER": "fixture-missing-reference"]
            source.replace([current])
            await registry.startEnabledServers()
            let missingSecret = try #require(await registry.status().first)
            #expect(!missingSecret.connected)
            #expect(missingSecret.error != nil)
            #expect(missingSecret.error != "Command is empty.")
            current.isEnabled = false
            source.replace([current])
            await registry.startServer(named: current.name)
            #expect(await registry.status().allSatisfy { !$0.connected && $0.error == nil })
            await registry.shutdownAll()
        } catch {
            await registry.shutdownAll()
            throw error
        }
    }

    @Test("B18 startup completion cannot publish an obsolete config",
          .enabled(if: MCPBackendFixTests.fixtureAvailable, "requires Node (or NODE_BINARY)"),
          .timeLimit(.minutes(1)), arguments: ["replace", "rename", "disable", "remove"])
    func staleStartupCompletion(change: String) async throws {
        let source = MCPBackendFixConfigSource()
        let gate = MCPBackendFixStartupGate()
        let original = try Self.config()
        source.replace([original])
        let registry = MCPRegistry(configProvider: { source.load() }, connectionFactory: { config in
            let connection = MCPConnection(config: config, secretStore: InMemoryCredentialStore())
            // Pause the first real, successful handshake before the registry can
            // publish it. No sleeps or scheduler assumptions in this race.
            if config == original {
                do { try await connection.connect() }
                catch { Issue.record("Local startup fixture failed: \(error)") }
                await gate.pause(connection)
            }
            return connection
        })
        let startup = Task { await registry.startEnabledServers() }
        let obsolete = await gate.waitUntilPaused()
        var replacement = original
        switch change {
        case "replace": replacement.args[1] = "latest-argument"
        case "rename": replacement.name = "latest-name"
        case "disable": replacement.isEnabled = false
        default: break
        }
        source.replace(change == "remove" ? [] : [replacement])
        // A second lifecycle caller must join, never create a duplicate process.
        let joined = Task { await registry.startEnabledServers() }
        await gate.release()
        await startup.value
        await joined.value
        do {
            #expect(await obsolete.isRunning == false)
            if change == "replace" || change == "rename" {
                let latest = try await Self.identity(registry, name: replacement.name)
                #expect(latest.argumentMarker == replacement.args[1])
                let tools = await registry.availableTools()
                #expect(tools.count == 3)
                #expect(tools.allSatisfy { $0.serverName == replacement.name })
                await registry.startServer(named: replacement.name)
                #expect(try await Self.identity(registry, name: replacement.name) == latest)
            } else {
                #expect(await registry.availableTools().isEmpty)
                #expect(await registry.status().allSatisfy { !$0.connected && $0.error == nil })
            }
            await registry.shutdownAll()
        } catch {
            await registry.shutdownAll()
            throw error
        }
    }

    private struct Identity: Decodable, Equatable {
        let instance: String
        let argumentMarker: String
        let environmentMarker: String
    }

    private static func identity(_ registry: MCPRegistry, name: String) async throws -> Identity {
        let result = await registry.call(
            qualifiedName: MCPToolNaming.qualify(server: name, tool: "identity"), argumentsJSON: "{}"
        )
        try #require(!result.isError, "Local fixture must be connected before comparing its identity")
        return try JSONDecoder().decode(Identity.self, from: Data(result.content.utf8))
    }

    private static func exerciseReplacement() async throws {
        let source = MCPBackendFixConfigSource()
        let registry = MCPRegistry(configProvider: { source.load() })
        do {
            var current = try config(name: "replacement-fixture")
            source.replace([current])
            await registry.startEnabledServers()
            let first = try await identity(registry, name: current.name)
            #expect(first.argumentMarker == "argument-A")
            #expect(first.environmentMarker == "environment-A")

            // Repeated starts of an unchanged config must remain idempotent.
            await registry.startServer(named: current.name)
            let unchanged = try await identity(registry, name: current.name)
            #expect(unchanged.instance == first.instance)

            // Preserve UUID to ensure a fix cannot compare only config IDs.
            current.args[1] = "argument-B"
            source.replace([current])
            await registry.startServer(named: current.name)
            let changedArgs = try await identity(registry, name: current.name)
            #expect(changedArgs.argumentMarker == "argument-B")
            #expect(changedArgs.environmentMarker == "environment-A")
            #expect(changedArgs.instance != first.instance)
            let argsTools = await registry.availableTools()
            #expect(argsTools.count == 3)
            #expect(argsTools.allSatisfy { $0.description == "argument-B/environment-A" })

            // The bulk lifecycle entry must reconcile changes as well.
            current.env["ORB_MCP_FIXTURE_MARKER"] = "environment-B"
            source.replace([current])
            await registry.startEnabledServers()
            let changedEnv = try await identity(registry, name: current.name)
            #expect(changedEnv.argumentMarker == "argument-B")
            #expect(changedEnv.environmentMarker == "environment-B")
            #expect(changedEnv.instance != changedArgs.instance)

            // Exercise the standard import parser, which mints a new UUID.
            let importedJSON = JSONValue.object(["mcpServers": .object([
                current.name: .object([
                    "command": .string(current.command),
                    "args": .array([.string(current.args[0]), .string("argument-C")]),
                    "env": .object(["ORB_MCP_FIXTURE_MARKER": .string("environment-C")])
                ])
            ])])
            let imported = try MCPRegistry.parseStandardConfig(importedJSON.jsonText)
            let replacement = try #require(imported.first)
            #expect(replacement.id != current.id)
            source.replace([replacement])
            await registry.startServer(named: replacement.name)
            let final = try await identity(registry, name: replacement.name)
            #expect(final.argumentMarker == "argument-C")
            #expect(final.environmentMarker == "environment-C")
            #expect(final.instance != changedEnv.instance)
            let finalTools = await registry.availableTools()
            #expect(finalTools.count == 3)
            #expect(finalTools.allSatisfy { $0.description == "argument-C/environment-C" })
            await registry.shutdownAll()
        } catch {
            await registry.shutdownAll()
            throw error
        }
    }
}

private actor MCPBackendFixConnectionTracker {
    private var connections: [MCPConnection] = []

    func make(_ config: MCPServerConfig) -> MCPConnection {
        let connection = MCPConnection(config: config, secretStore: InMemoryCredentialStore())
        connections.append(connection)
        return connection
    }

    func liveCount() async -> Int {
        var count = 0
        for connection in connections {
            if await connection.isRunning { count += 1 }
        }
        return count
    }
}

/// Deterministic suspension between a handshake and publication to the registry.
private actor MCPBackendFixStartupGate {
    private var connection: MCPConnection?
    private var observer: CheckedContinuation<MCPConnection, Never>?
    private var continuation: CheckedContinuation<Void, Never>?

    func pause(_ connection: MCPConnection) async {
        self.connection = connection
        observer?.resume(returning: connection)
        observer = nil
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilPaused() async -> MCPConnection {
        if let connection { return connection }
        return await withCheckedContinuation { observer = $0 }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

/// Only immutable config snapshots leave the lock. No persistence or secrets.
private final class MCPBackendFixConfigSource: @unchecked Sendable {
    private let lock = NSLock()
    private var configs: [MCPServerConfig] = []

    func load() -> [MCPServerConfig] {
        lock.lock()
        defer { lock.unlock() }
        return configs
    }

    func replace(_ value: [MCPServerConfig]) {
        lock.lock()
        defer { lock.unlock() }
        configs = value
    }
}

/// A signal outside the connection actor, so a blocked actor cannot prevent
/// the test's cancellation clock from starting. Does not inspect private state.
private actor MCPBackendFixEntrySignal {
    private var entered = false
    private var waiter: CheckedContinuation<Void, Never>?

    func markEntered() {
        entered = true
        waiter?.resume()
        waiter = nil
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { waiter = $0 }
    }
}
