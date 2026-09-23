import Foundation
import Testing
@testable import ORB

// MARK: - Fixtures

private func makeWorkspace() throws -> (workspace: URL, outside: URL) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("orb-policy-\(UUID().uuidString)", isDirectory: true)
    let workspace = root.appendingPathComponent("workspace", isDirectory: true)
    let outside = root.appendingPathComponent("outside", isDirectory: true)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    return (workspace, outside)
}

private func toolArguments(_ json: String) -> String { json }

private final class PolicyScriptedClient: OpenRouterClientProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var turns: [[OpenRouterStreamEvent]]

    init(turns: [[OpenRouterStreamEvent]]) { self.turns = turns }

    func stream(_ request: OpenRouterRequest) async throws -> AsyncThrowingStream<OpenRouterStreamEvent, Error> {
        lock.lock()
        let events = turns.isEmpty ? [] : turns.removeFirst()
        lock.unlock()
        return AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }
}

private func toolCallTurn(id: String, name: String, arguments: String) -> [OpenRouterStreamEvent] {
    [
        .toolCallFragment(choiceIndex: 0, toolIndex: 0, id: id, type: "function", name: name, arguments: arguments),
        .finishReason(choiceIndex: 0, reason: "tool_calls"),
    ]
}

private let finalTurn: [OpenRouterStreamEvent] = [
    .contentDelta(choiceIndex: 0, text: "done"),
    .finishReason(choiceIndex: 0, reason: "stop"),
]

// MARK: - Policy decisions

@Suite("Tool policy")
struct ToolPolicyTests {

    @Test("Web Only exposes and executes no MCP tool, including synthetic bridges")
    func webOnlyDeniesMCP() {
        let policy = ToolPolicy.webOnly
        for name in ["mcp__fs__read_file", "mcp__fs__list", "mcp__read_resource", "mcp__get_prompt"] {
            #expect(policy.allowsDefinition(name: name) == false, "\(name) must not be advertised")
            #expect(policy.allowsExecution(name: name) == false, "\(name) must not be executable")
        }
    }

    @Test("MCP tools require the mcp capability AND their server to be approved")
    func mcpRequiresServerApproval() {
        var policy = ToolPolicy.computerControl
        // Even full local capability denies unapproved MCP servers.
        #expect(policy.allowsExecution(name: "mcp__fs__read_file") == false)
        policy.approvedMCPServers = ["fs"]
        #expect(policy.allowsExecution(name: "mcp__fs__read_file"))
        #expect(policy.allowsDefinition(name: "mcp__read_resource") == false) // synthetic bridge has no server
        #expect(policy.allowsExecution(name: "mcp__other__tool") == false)
    }

    @Test("unknown tools are denied by every policy")
    func unknownToolDenied() {
        for policy in [ToolPolicy.webOnly, .workspaceWrite, .approvedTerminal, .computerControl] {
            #expect(policy.allowsExecution(name: "totally_unknown_tool") == false)
        }
    }

    @Test("native tools map to their capabilities")
    func capabilityMapping() {
        #expect(ToolPolicy.webOnly.allowsExecution(name: "fetch_url"))
        #expect(ToolPolicy.webOnly.allowsExecution(name: "web_search"))
        #expect(ToolPolicy.webOnly.allowsExecution(name: "read_file") == false)
        #expect(ToolPolicy.workspaceRead.allowsExecution(name: "read_file"))
        #expect(ToolPolicy.workspaceRead.allowsExecution(name: "write_file") == false)
        #expect(ToolPolicy.workspaceWrite.allowsExecution(name: "write_file"))
        #expect(ToolPolicy.workspaceWrite.allowsExecution(name: "run_command") == false)
        #expect(ToolPolicy.approvedTerminal.allowsExecution(name: "run_command"))
        #expect(ToolPolicy.approvedTerminal.allowsExecution(name: "capture_screen") == false)
        #expect(ToolPolicy.computerControl.allowsExecution(name: "capture_screen"))
        #expect(ToolPolicy.legacy(fullComputerAccess: true).allowsExecution(name: "run_applescript"))
        #expect(ToolPolicy.legacy(fullComputerAccess: false).allowsExecution(name: "run_applescript") == false)
    }

    @Test("high-risk tools require approval even when granted")
    func approvalRequirement() {
        #expect(ToolPolicy.approvedTerminal.requiresApproval(name: "run_command"))
        #expect(ToolPolicy.computerControl.requiresApproval(name: "computer_action"))
        #expect(ToolPolicy.webOnly.requiresApproval(name: "fetch_url") == false)
        #expect(ToolPolicy.workspaceWrite.requiresApproval(name: "write_file") == false)
    }

    // MARK: Workspace path guard

    @Test("path guard allows relative and contained absolute paths")
    func guardAllowsContainedPaths() throws {
        let (workspace, _) = try makeWorkspace()
        let relative = try WorkspacePathGuard.containedURL(forRawPath: "src/main.swift", workspace: workspace.path)
        #expect(relative.standardizedFileURL.path.hasPrefix(workspace.standardizedFileURL.path))
        let inside = try WorkspacePathGuard.containedURL(forRawPath: workspace.path + "/a/../b.txt", workspace: workspace.path)
        #expect(inside.standardizedFileURL.path == workspace.appendingPathComponent("b.txt").standardizedFileURL.path)
    }

    @Test("path guard rejects traversal, outside absolutes, and home paths")
    func guardRejectsEscapes() throws {
        let (workspace, outside) = try makeWorkspace()
        #expect(throws: ToolPolicyError.self) {
            try WorkspacePathGuard.containedURL(forRawPath: "../outside/secret.txt", workspace: workspace.path)
        }
        #expect(throws: ToolPolicyError.self) {
            try WorkspacePathGuard.containedURL(forRawPath: outside.path + "/secret.txt", workspace: workspace.path)
        }
        #expect(throws: ToolPolicyError.self) {
            try WorkspacePathGuard.containedURL(forRawPath: "~/Documents/notes.txt", workspace: workspace.path)
        }
        #expect(throws: ToolPolicyError.self) {
            try WorkspacePathGuard.containedURL(forRawPath: "/etc/hosts", workspace: workspace.path)
        }
    }

    @Test("path guard rejects symlink escapes")
    func guardRejectsSymlinkEscape() throws {
        let (workspace, outside) = try makeWorkspace()
        try Data("outside".utf8).write(to: outside.appendingPathComponent("secret.txt"))
        let link = workspace.appendingPathComponent("leak")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        #expect(throws: ToolPolicyError.self) {
            try WorkspacePathGuard.containedURL(forRawPath: "leak/secret.txt", workspace: workspace.path)
        }
    }

    // MARK: File tools honoring the constraint

    @Test("constrained file tools deny escapes and serve contained paths")
    func constrainedFileTools() async throws {
        let (workspace, outside) = try makeWorkspace()
        try Data("hello".utf8).write(to: workspace.appendingPathComponent("inside.txt"))
        try Data("secret".utf8).write(to: outside.appendingPathComponent("secret.txt"))

        let escapedWrite = try await NativeAgentTools.execute(
            name: "write_file",
            argumentsJSON: toolArguments(#"{"path": "../outside/escaped.txt", "content": "nope"}"#),
            workspace: workspace.path,
            fullComputerAccess: true,
            constrainPathsToWorkspace: true
        )
        #expect(escapedWrite.isError)
        #expect(escapedWrite.content.contains("outside this session's workspace"))
        #expect(FileManager.default.fileExists(atPath: outside.appendingPathComponent("escaped.txt").path) == false)

        let containedRead = try await NativeAgentTools.execute(
            name: "read_file",
            argumentsJSON: toolArguments(#"{"path": "inside.txt"}"#),
            workspace: workspace.path,
            fullComputerAccess: true,
            constrainPathsToWorkspace: true
        )
        #expect(containedRead.isError == false)
        #expect(containedRead.content.contains("hello"))

        // Create a symlink inside the workspace pointing outside, then attempt
        // to write through it.
        let leak = workspace.appendingPathComponent("leak")
        try FileManager.default.createSymbolicLink(at: leak, withDestinationURL: outside)

        let symlinkWrite = try await NativeAgentTools.execute(
            name: "write_file",
            argumentsJSON: toolArguments(#"{"path": "leak/escaped2.txt", "content": "nope"}"#),
            workspace: workspace.path,
            fullComputerAccess: true,
            constrainPathsToWorkspace: true
        )
        #expect(symlinkWrite.isError)
    }

    // MARK: End to end through the runner

    @Test("Web Only runner denies a hallucinated MCP call at execution time")
    func runnerDeniesMCPExecution() async throws {
        let client = PolicyScriptedClient(turns: [
            toolCallTurn(id: "call-1", name: "mcp__fs__read_file", arguments: #"{"path": "/etc/hosts"}"#),
            finalTurn,
        ])
        let result = try await NativeAgentRunner.run(
            prompt: "read the hosts file",
            modelId: "test/model",
            apiKey: "test-key",
            workspace: "/tmp/orb-policy-runner",
            fullComputerAccess: false,
            history: [],
            client: client,
            onEvent: { _ in }
        )
        let denied = result.toolMessages.first { $0.toolCallId == "call-1" }
        #expect(denied?.content.contains("Denied: tool") == true)
        #expect(result.toolCallDisplays.first?.isError == true)
        #expect(result.response == "done")
    }

    @Test("Web Only runner denies a hallucinated native terminal call")
    func runnerDeniesTerminalExecution() async throws {
        let client = PolicyScriptedClient(turns: [
            toolCallTurn(id: "call-2", name: "run_command", arguments: #"{"command": "ls /"}"#),
            finalTurn,
        ])
        let result = try await NativeAgentRunner.run(
            prompt: "list root",
            modelId: "test/model",
            apiKey: "test-key",
            workspace: "/tmp/orb-policy-runner",
            fullComputerAccess: false,
            history: [],
            client: client,
            onEvent: { _ in }
        )
        let denied = result.toolMessages.first { $0.toolCallId == "call-2" }
        #expect(denied?.content.contains("Denied: tool") == true)
    }

    @Test("approved call reaches the executor; denied approval becomes a tool error")
    func runnerHonorsApprovals() async throws {
        let approvals = ApprovalCoordinator()
        await approvals.setHandler { _ in .approved }
        let client = PolicyScriptedClient(turns: [
            toolCallTurn(id: "call-3", name: "run_command", arguments: #"{"command": "echo hi"}"#),
            finalTurn,
        ])
        let executed = try await NativeAgentRunner.run(
            prompt: "echo",
            modelId: "test/model",
            apiKey: "test-key",
            workspace: "/tmp/orb-policy-runner",
            fullComputerAccess: false,
            history: [],
            client: client,
            toolExecutor: { call in
                NativeAgentToolResult(content: "executed \(call.name)", isError: false)
            },
            policy: .projectBuild,
            approvals: approvals,
            onEvent: { _ in }
        )
        #expect(executed.toolMessages.first { $0.toolCallId == "call-3" }?.content.contains("executed") == true)

        await approvals.setHandler { _ in .denied }
        let deniedRun = try await NativeAgentRunner.run(
            prompt: "echo",
            modelId: "test/model",
            apiKey: "test-key",
            workspace: "/tmp/orb-policy-runner",
            fullComputerAccess: false,
            history: [],
            client: PolicyScriptedClient(turns: [
                toolCallTurn(id: "call-4", name: "run_command", arguments: #"{"command": "echo hi"}"#),
                finalTurn,
            ]),
            toolExecutor: { call in
                Issue.record("Executor must not run for a denied approval: \(call.name)")
                return NativeAgentToolResult(content: "must not happen", isError: true)
            },
            policy: .projectBuild,
            approvals: approvals,
            onEvent: { _ in }
        )
        let denied = deniedRun.toolMessages.first { $0.toolCallId == "call-4" }
        #expect(denied?.content.contains("did not approve") == true)
    }

    // MARK: ApprovalCoordinator

    @Test("coordinator fails closed with no handler")
    func coordinatorFailsClosed() async {
        let approvals = ApprovalCoordinator()
        let approved = await approvals.requestApproval(toolName: "run_command", summary: "ls")
        #expect(approved == false)
    }

    @Test("coordinator cancels a pending approval as denied")
    func coordinatorCancelsPending() async throws {
        let approvals = ApprovalCoordinator()
        await approvals.setHandler { _ in
            // Simulates a UI that never answers; cancellation must resolve it.
            try? await Task.sleep(for: .seconds(30))
            return .approved
        }
        let wait = Task { await approvals.requestApproval(toolName: "run_command", summary: "ls") }
        var sawPending = false
        for _ in 0..<200 {
            if !(await approvals.pendingRequestIDs).isEmpty { sawPending = true; break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(sawPending)
        await approvals.cancelPending()
        #expect(await wait.value == false)
    }

    @Test("session-scoped approval is remembered and revocable")
    func coordinatorSessionScope() async {
        let approvals = ApprovalCoordinator()
        let calls = MockCallCounter()
        await approvals.setHandler { _ in
            calls.increment()
            return .approved
        }
        #expect(await approvals.requestApproval(toolName: "run_command", summary: "a", sessionScope: true))
        #expect(await approvals.requestApproval(toolName: "run_command", summary: "b", sessionScope: true))
        #expect(calls.current == 1)
        await approvals.revokeSessionApprovals()
        #expect(await approvals.requestApproval(toolName: "run_command", summary: "c", sessionScope: true))
        #expect(calls.current == 2)
    }
}
