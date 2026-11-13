import Foundation
import Testing
@testable import ORB

private struct M03ReadySnapshot: Equatable, Sendable {
    let server: String?
    let tools: [String]
    let resources: [String]
    let prompts: [String]

    static let expected = M03ReadySnapshot(
        server: "m03-ready", tools: ["identity"],
        resources: ["fixture://m03"], prompts: ["m03-prompt"]
    )
}

private enum M03ConnectOutcome: Equatable, Sendable {
    case ready(M03ReadySnapshot)
    case cancelled
    case mcp(MCPError)
    case unexpected(String)
}

/// No test-owned continuations to leak on assertion failure or timeout.
private final class M03ConnectProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var didEnter = false
    private var outcome: M03ConnectOutcome?

    var entered: Bool { lock.lock(); defer { lock.unlock() }; return didEnter }
    var result: M03ConnectOutcome? { lock.lock(); defer { lock.unlock() }; return outcome }
    func enter() { lock.lock(); defer { lock.unlock() }; didEnter = true }
    func finish(_ value: M03ConnectOutcome) {
        lock.lock(); defer { lock.unlock() }; outcome = value
    }
}

private extension MCPConnection {
    /// This wrapper and connect() share the SAME actor executor. After enter(),
    /// execution cannot leave this actor until connect suspends or returns.
    /// A later m03OutcomeBarrier call therefore observes a genuinely entered
    /// connect, not a Task that merely announced it was about to hop actors.
    func m03RunConnect(_ probe: M03ConnectProbe) async {
        probe.enter()
        do {
            try await connect()
            probe.finish(.ready(M03ReadySnapshot(
                server: serverInfo, tools: tools.map(\.toolName),
                resources: resources.map(\.uri), prompts: prompts.map(\.name)
            )))
        } catch is CancellationError {
            probe.finish(.cancelled)
        } catch let error as MCPError {
            probe.finish(.mcp(error))
        } catch {
            probe.finish(.unexpected(String(describing: error)))
        }
    }

    func m03OutcomeBarrier(_ probe: M03ConnectProbe) -> M03ConnectOutcome? {
        probe.result
    }

    /// Replace the transport before the old owner's continuation can resume on
    /// this actor. Its eventual catch/cancellation callback must not close ours.
    func m03Restart(_ probe: M03ConnectProbe) async {
        shutdown()
        await m03RunConnect(probe)
    }
}

private func m03Wait(
    _ description: String,
    until predicate: () async throws -> Bool
) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while ContinuousClock.now < deadline {
        if try await predicate() { return }
        await Task.yield()
    }
    throw MCPError.transport("M03 timed out waiting for \(description)")
}

private final class M03ConnectHarness {
    let connection: MCPConnection
    private var callers: [(task: Task<Void, Never>, probe: M03ConnectProbe)] = []

    init(node: String, script: URL, method: String) {
        connection = MCPConnection(
            config: MCPServerConfig(name: "m03-concurrent", command: node, args: [script.path, method]),
            secretStore: InMemoryCredentialStore(), requestTimeout: .seconds(8)
        )
    }

    func start(restarting: Bool = false) -> (task: Task<Void, Never>, probe: M03ConnectProbe) {
        let probe = M03ConnectProbe()
        let connection = connection
        let task = Task {
            if restarting { await connection.m03Restart(probe) }
            else { await connection.m03RunConnect(probe) }
        }
        callers.append((task, probe))
        return (task, probe)
    }

    func waitForEntry(_ probe: M03ConnectProbe) async throws {
        try await m03Wait("caller entry") { probe.entered }
        // Positive actor barrier, NOT an arbitrary settling sleep/yield count.
        _ = await connection.m03OutcomeBarrier(probe)
    }

    func state() async throws -> [String: JSONValue] {
        let response = try await connection.callTool(name: "m03-state", arguments: .object([:]))
        return try #require(JSONValue.parse(response.content)?.objectValue)
    }

    func waitForHeld(_ method: String) async throws {
        try await m03Wait("held \(method)") {
            guard await self.connection.isRunning else { return false }
            return try await self.state()["held"]?.stringValue == method
        }
    }

    func release(fail: Bool = false) async throws {
        try await connection.notify(method: "notifications/m03-release", params: .object(["fail": .bool(fail)]))
    }

    func result(_ probe: M03ConnectProbe) async throws -> M03ConnectOutcome {
        try await m03Wait("connect completion") { probe.result != nil }
        return try #require(probe.result)
    }

    func cleanup() async {
        // Run on success AND thrown #require/timeouts. Close transport before
        // joining callers, so no fixture response is required during teardown.
        for caller in callers { caller.task.cancel() }
        await connection.shutdown()
        do {
            try await m03Wait("cleanup of all direct connect callers") {
                self.callers.allSatisfy { $0.probe.result != nil }
            }
            // Each terminal probe is the caller's last action. Do not add an
            // unbounded task join to an otherwise deadline-bounded teardown.
        } catch {
            // Never unconditionally await a broken lifecycle continuation.
            Issue.record("M03 cleanup could not drain callers: \(error)")
        }
    }
}

@Suite("M03 direct concurrent MCPConnection.connect", .serialized)
struct MCPConcurrentConnectTests {
    private static var node: String? {
        // Explicit opt-in path; do not depend on GUI/login-shell PATH or nvm.
        guard let path = ProcessInfo.processInfo.environment["NODE_BINARY"],
              FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return path
    }

    private func withHarness(
        holding method: String = "initialize",
        _ body: (M03ConnectHarness) async throws -> Void
    ) async throws {
        let script = try #require(Bundle.module.url(
            forResource: "orb-mcp-concurrent-connect-fixture", withExtension: "mjs", subdirectory: "Fixtures"
        ))
        let harness = M03ConnectHarness(node: try #require(Self.node), script: script, method: method)
        do {
            try await body(harness)
            await harness.cleanup()
        } catch {
            await harness.cleanup()
            throw error
        }
    }

    @Test("Second direct caller waits for all startup discovery, not merely a running process",
          .enabled(if: Self.node != nil, "requires executable NODE_BINARY"),
          arguments: ["initialize", "tools/list", "resources/list", "prompts/list"])
    func joinsActualReadiness(method: String) async throws {
        try await withHarness(holding: method) { harness in
            let first = harness.start()
            try await harness.waitForHeld(method)
            let second = harness.start()
            try await harness.waitForEntry(second.probe)
            #expect(await harness.connection.m03OutcomeBarrier(first.probe) == nil)
            #expect(await harness.connection.isRunning)
            #expect(await harness.connection.isReady == false)
            #expect(await harness.connection.m03OutcomeBarrier(second.probe) == nil,
                    "A running subprocess is not a completed connect")
            let held = try await harness.state()
            #expect(held["held"]?.stringValue == method)
            #expect(held["initializeCount"] == .number(1))

            try await harness.release()
            #expect(try await harness.result(first.probe) == .ready(.expected))
            // Snapshot was captured at RETURN, not after the other task finished.
            #expect(try await harness.result(second.probe) == .ready(.expected))
            #expect(await harness.connection.isReady)
            let ready = try await harness.state()
            #expect(ready["initializeCount"] == .number(1))
            #expect(ready["initializedCount"] == .number(1))
            let repeatCaller = harness.start()
            #expect(try await harness.result(repeatCaller.probe) == .ready(.expected))
            #expect(try await harness.state()["initializeCount"] == .number(1))
        }
    }

    @Test("All direct callers receive the held mandatory startup error; same actor can retry",
          .enabled(if: Self.node != nil, "requires executable NODE_BINARY"),
          arguments: ["initialize", "tools/list"])
    func sharesFailureAndRetries(method: String) async throws {
        try await withHarness(holding: method) { harness in
            let first = harness.start()
            try await harness.waitForHeld(method)
            let second = harness.start()
            try await harness.waitForEntry(second.probe)
            #expect(await harness.connection.m03OutcomeBarrier(second.probe) == nil)
            try await harness.release(fail: true)
            let expected = M03ConnectOutcome.mcp(.server(code: -32603, message: "m03 held startup failure"))
            #expect(try await harness.result(first.probe) == expected)
            #expect(try await harness.result(second.probe) == expected)
            #expect(await harness.connection.isRunning == false,
                    "A failed startup must not leave process != nil as false readiness")
            #expect(await harness.connection.tools.isEmpty)
            // No explicit shutdown to repair production state before retry.
            let retry = harness.start()
            try await harness.waitForHeld(method)
            #expect(await harness.connection.m03OutcomeBarrier(retry.probe) == nil)
            try await harness.release()
            #expect(try await harness.result(retry.probe) == .ready(.expected))
        }
    }

    @Test("Cancelling a joined caller detaches promptly without cancelling the startup owner",
          .enabled(if: Self.node != nil, "requires executable NODE_BINARY"),
          arguments: ["initialize", "tools/list", "resources/list", "prompts/list"])
    func cancelledJoinerDoesNotOwnStartup(method: String) async throws {
        try await withHarness(holding: method) { harness in
            let first = harness.start()
            try await harness.waitForHeld(method)
            let second = harness.start()
            try await harness.waitForEntry(second.probe)
            #expect(await harness.connection.m03OutcomeBarrier(second.probe) == nil)
            second.task.cancel()
            #expect(try await harness.result(second.probe) == .cancelled)
            #expect(await harness.connection.m03OutcomeBarrier(first.probe) == nil)
            #expect(try await harness.state()["held"]?.stringValue == method)
            let third = harness.start()
            try await harness.waitForEntry(third.probe)
            #expect(await harness.connection.m03OutcomeBarrier(third.probe) == nil)
            try await harness.release()
            #expect(try await harness.result(first.probe) == .ready(.expected))
            #expect(try await harness.result(third.probe) == .ready(.expected))
            #expect(second.probe.result == .cancelled)
        }
    }

    @Test("Cancelling the original startup owner fails its joiners and permits a fresh attempt",
          .enabled(if: Self.node != nil, "requires executable NODE_BINARY"),
          arguments: ["initialize", "tools/list", "resources/list", "prompts/list"])
    func cancelledOwnerUnwindsAttempt(method: String) async throws {
        // Preserve current initiating-caller cancellation semantics; joining
        // callers do not gain authority to cancel the transport they joined.
        try await withHarness(holding: method) { harness in
            let first = harness.start()
            try await harness.waitForHeld(method)
            let second = harness.start()
            try await harness.waitForEntry(second.probe)
            #expect(await harness.connection.m03OutcomeBarrier(second.probe) == nil)
            first.task.cancel()
            #expect(try await harness.result(first.probe) == .cancelled)
            #expect(try await harness.result(second.probe) == .cancelled)
            #expect(await harness.connection.isRunning == false)
            #expect(await harness.connection.isReady == false)
            #expect(await harness.connection.serverInfo == nil)
            #expect(await harness.connection.supportsResources == false)
            #expect(await harness.connection.supportsPrompts == false)
            let retry = harness.start()
            try await harness.waitForHeld(method)
            #expect(await harness.connection.m03OutcomeBarrier(retry.probe) == nil)
            try await harness.release()
            #expect(try await harness.result(retry.probe) == .ready(.expected))
        }
    }

    @Test("Obsolete startup cleanup cannot close an immediately restarted transport",
          .enabled(if: Self.node != nil, "requires executable NODE_BINARY"),
          arguments: ["initialize", "resources/list", "prompts/list"])
    func immediateRestartKeepsProcessIdentity(method: String) async throws {
        try await withHarness(holding: method) { harness in
            let owner = harness.start()
            try await harness.waitForHeld(method)
            let joiner = harness.start()
            try await harness.waitForEntry(joiner.probe)
            let replacement = harness.start(restarting: true)
            try await harness.waitForEntry(replacement.probe)
            owner.task.cancel() // late onCancel must also retain old identity
            #expect(try await harness.result(owner.probe) == .mcp(.notConnected))
            #expect(try await harness.result(joiner.probe) == .mcp(.notConnected))
            try await harness.waitForHeld(method)
            #expect(await harness.connection.isRunning)
            #expect(await harness.connection.isReady == false)
            #expect(await harness.connection.m03OutcomeBarrier(replacement.probe) == nil)
            try await harness.release()
            #expect(try await harness.result(replacement.probe) == .ready(.expected))
            #expect(await harness.connection.isReady)
        }
    }

    @Test("Shutdown fails both held callers and a new attempt on the same actor still initializes",
          .enabled(if: Self.node != nil, "requires executable NODE_BINARY"),
          arguments: ["initialize", "prompts/list"])
    func shutdownUnwindsJoiners(method: String) async throws {
        try await withHarness(holding: method) { harness in
            let first = harness.start()
            try await harness.waitForHeld(method)
            let second = harness.start()
            try await harness.waitForEntry(second.probe)
            #expect(await harness.connection.m03OutcomeBarrier(second.probe) == nil)
            await harness.connection.shutdown()
            #expect(try await harness.result(first.probe) == .mcp(.notConnected))
            #expect(try await harness.result(second.probe) == .mcp(.notConnected))
            #expect(await harness.connection.tools.isEmpty)
            #expect(await harness.connection.resources.isEmpty)
            #expect(await harness.connection.prompts.isEmpty)
            #expect(await harness.connection.isRunning == false)

            let retry = harness.start()
            try await harness.waitForHeld(method)
            let retryJoiner = harness.start()
            try await harness.waitForEntry(retryJoiner.probe)
            #expect(await harness.connection.m03OutcomeBarrier(retryJoiner.probe) == nil)
            try await harness.release()
            #expect(try await harness.result(retry.probe) == .ready(.expected))
            #expect(try await harness.result(retryJoiner.probe) == .ready(.expected))
        }
    }
}
