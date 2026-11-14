import Foundation
import SwiftUI
import Testing
@testable import ORB

// Wave 1, agent track: approval keys (AGENT-1), argument-aware approval for
// file tools (AGENT-2), approval attention (AGENT-3), approval details and
// scoped session approvals (AGENT-5).

private actor AgentW1Client: OpenRouterClientProtocol {
    var turns: [[OpenRouterStreamEvent]]
    private(set) var requests: [OpenRouterRequest] = []
    init(_ turns: [[OpenRouterStreamEvent]]) { self.turns = turns }
    func stream(_ request: OpenRouterRequest) async throws -> AsyncThrowingStream<OpenRouterStreamEvent, Error> {
        requests.append(request)
        let events = turns.isEmpty ? [.contentDelta(choiceIndex: 0, text: "done"), .finishReason(choiceIndex: 0, reason: "stop")] : turns.removeFirst()
        return AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }
}

private actor AgentW1Counter {
    private(set) var calls: [AssembledAgentToolCall] = []
    private(set) var prompts: [ApprovalCoordinator.Request] = []
    private(set) var events: [NativeAgentEvent] = []
    func record(_ call: AssembledAgentToolCall) { calls.append(call) }
    func prompt(_ request: ApprovalCoordinator.Request) { prompts.append(request) }
    func event(_ event: NativeAgentEvent) { events.append(event) }
}

private func agentW1TempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("orb-w1-agent-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url.resolvingSymlinksInPath()
}

private func agentW1Args(_ object: [String: Any]) -> String {
    String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
}

private func agentW1ToolTurn(_ name: String, _ args: [String: Any], id: String = "c1") -> [OpenRouterStreamEvent] {
    [
        .toolCallFragment(choiceIndex: 0, toolIndex: 0, id: id, type: "function", name: name, arguments: agentW1Args(args)),
        .finishReason(choiceIndex: 0, reason: "tool_calls"),
    ]
}

@Suite("W1 agent: approval sheet keys (AGENT-1)")
struct W1AgentApprovalKeyTests {
    @Test("plain Return never approves; ⌘Return approves once; Escape denies")
    func keyPolicy() {
        #expect(ApprovalSheetKeys.decision(for: .returnKey, command: false) == nil)
        #expect(ApprovalSheetKeys.decision(for: .returnKey, command: true) == .approved)
        #expect(ApprovalSheetKeys.decision(for: .escape, command: false) == .denied)
        #expect(ApprovalSheetKeys.decision(for: .other, command: true) == nil)
    }

    @Test("no approval button is bound to plain Return (the default action)")
    func noDefaultApproveButton() {
        let approve = ApprovalSheetKeys.shortcut(for: .approved)
        #expect(approve?.key == .return)
        #expect(approve?.modifiers == .command)
        #expect(ApprovalSheetKeys.shortcut(for: .approvedForSession) == nil)
        #expect(ApprovalSheetKeys.shortcut(for: .denied) == .cancelAction)
        for decision in [ApprovalCoordinator.Decision.approved, .approvedForSession, .denied] {
            #expect(ApprovalSheetKeys.shortcut(for: decision) != .defaultAction)
        }
    }

    @Test("approve buttons arm only after a short delay")
    func arming() {
        #expect(!ApprovalSheetKeys.isArmed(elapsed: .milliseconds(50)))
        #expect(ApprovalSheetKeys.isArmed(elapsed: .seconds(1)))
    }
}

@Suite("W1 agent: file-tool approval policy (AGENT-2)")
struct W1AgentFilePolicyTests {
    let policy = ToolPolicy.computerControl
    let home = NSHomeDirectory()

    private func requirement(_ name: String, _ args: [String: Any], workspace: String) -> ToolApprovalRequirement? {
        policy.approvalRequirement(name: name, argumentsJSON: agentW1Args(args), workspace: workspace)
    }

    @Test("writes inside the workspace run without asking; outside ask with the full path")
    func writeOutsideWorkspace() throws {
        let workspace = try agentW1TempDir()
        let other = try agentW1TempDir()
        defer { try? FileManager.default.removeItem(at: workspace); try? FileManager.default.removeItem(at: other) }
        #expect(requirement("write_file", ["path": "notes.txt", "content": "x"], workspace: workspace.path) == nil)
        let target = other.appendingPathComponent("out.txt").path
        let outside = try #require(requirement("write_file", ["path": target, "content": "x"], workspace: workspace.path))
        #expect(outside.reason?.contains(target) == true)
        #expect(outside.resolvedPath == target)
        #expect(outside.scopeKey.contains(target))
        // `..` cannot escape silently either.
        #expect(requirement("write_file", ["path": "../\(other.lastPathComponent)/x", "content": ""], workspace: workspace.path) != nil)
    }

    @Test("speak_text and generate_image outputs outside the workspace also ask")
    func mediaOutputsAsk() throws {
        let workspace = try agentW1TempDir()
        let other = try agentW1TempDir()
        defer { try? FileManager.default.removeItem(at: workspace); try? FileManager.default.removeItem(at: other) }
        #expect(requirement("speak_text", ["text": "hi", "path": other.appendingPathComponent("a.mp3").path], workspace: workspace.path) != nil)
        #expect(requirement("generate_image", ["prompt": "p", "path": other.appendingPathComponent("a.png").path], workspace: workspace.path) != nil)
        #expect(requirement("generate_image", ["prompt": "p", "path": "art/a.png"], workspace: workspace.path) == nil)
    }

    @Test("a symlink inside the workspace cannot hide an outside target")
    func symlinkEscape() throws {
        let workspace = try agentW1TempDir()
        let other = try agentW1TempDir()
        defer { try? FileManager.default.removeItem(at: workspace); try? FileManager.default.removeItem(at: other) }
        try FileManager.default.createSymbolicLink(at: workspace.appendingPathComponent("link"), withDestinationURL: other)
        let result = try #require(requirement("write_file", ["path": "link/file.txt", "content": ""], workspace: workspace.path))
        #expect(result.resolvedPath == other.appendingPathComponent("file.txt").path)
    }

    @Test("reads of credential stores ask, ordinary reads do not")
    func sensitiveReads() throws {
        let workspace = try agentW1TempDir()
        defer { try? FileManager.default.removeItem(at: workspace) }
        for path in ["~/.ssh/id_ed25519", "~/.aws/credentials", "~/.gnupg/secring.gpg",
                     "~/Library/Keychains/login.keychain-db", "~/Library/Application Support/ORB/orb.sqlite",
                     "~/Library/Application Support/Google/Chrome/Default/Cookies"] {
            let result = requirement("read_file", ["path": path], workspace: workspace.path)
            #expect(result != nil, "\(path) should ask")
            #expect(result?.reason?.contains("credentials") == true)
        }
        #expect(requirement("list_directory", ["path": "~/.ssh"], workspace: workspace.path) != nil)
        #expect(requirement("search_files", ["path": "~/.aws", "query": "key"], workspace: workspace.path) != nil)
        #expect(requirement("read_file", ["path": ".env"], workspace: workspace.path) != nil)
        #expect(requirement("read_file", ["path": "config/.env.production"], workspace: workspace.path) != nil)
        #expect(requirement("read_file", ["path": ".env.example"], workspace: workspace.path) == nil)
        #expect(requirement("read_file", ["path": "README.md"], workspace: workspace.path) == nil)
        #expect(requirement("read_file", ["path": "~/Documents/todo.txt"], workspace: workspace.path) == nil)
    }

    @Test("writes that can run code later ask even inside a home workspace")
    func codeRunningWrites() {
        for path in ["~/.zshrc", "~/Library/LaunchAgents/x.plist", ".git/hooks/pre-commit", "~/.config/fish/config.fish"] {
            #expect(requirement("write_file", ["path": path, "content": ""], workspace: home) != nil, "\(path) should ask")
        }
        #expect(requirement("write_file", ["path": "Projects/app/main.swift", "content": ""], workspace: home) == nil)
    }

    @Test("workspace-constrained modes keep relying on the path guard for outside writes")
    func constrainedModes() throws {
        let workspace = try agentW1TempDir()
        defer { try? FileManager.default.removeItem(at: workspace) }
        #expect(ToolPolicy.projectBuild.approvalRequirement(
            name: "write_file", argumentsJSON: agentW1Args(["path": "a.txt", "content": ""]), workspace: workspace.path
        ) == nil)
    }

    @Test("run_command session approvals are scoped to one working directory")
    func runCommandScope() throws {
        let a = try agentW1TempDir(), b = try agentW1TempDir()
        defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
        let inA = try #require(requirement("run_command", ["command": "ls"], workspace: a.path))
        let inB = try #require(requirement("run_command", ["command": "ls", "working_directory": b.path], workspace: a.path))
        #expect(inA.scopeKey != inB.scopeKey)
        #expect(inA.scopeLabel.contains(SensitivePaths.abbreviated(a.path)))
        #expect(inB.resolvedPath == b.path)
    }
}

@Suite("W1 agent: runner enforcement (AGENT-2, AGENT-3, AGENT-5)", .serialized)
@MainActor
struct W1AgentRunnerApprovalTests {
    @Test("a denied write outside the workspace never reaches the executor")
    func deniedWriteNotExecuted() async throws {
        let workspace = try agentW1TempDir(), other = try agentW1TempDir()
        defer { try? FileManager.default.removeItem(at: workspace); try? FileManager.default.removeItem(at: other) }
        let target = other.appendingPathComponent("evil.txt").path
        let client = AgentW1Client([agentW1ToolTurn("write_file", ["path": target, "content": "x"])])
        let counter = AgentW1Counter()
        let approvals = ApprovalCoordinator(attention: ApprovalAttention())
        await approvals.setHandler { request in
            await counter.prompt(request)
            return .denied
        }
        let result = try await NativeAgentRunner.run(
            prompt: "go", modelId: "m", apiKey: "k", workspace: workspace.path, fullComputerAccess: true,
            history: [], client: client,
            toolExecutor: { call in await counter.record(call); return .init(content: "ran", isError: false) },
            policy: .computerControl, approvals: approvals, onEvent: { await counter.event($0) }
        )
        #expect(await counter.calls.isEmpty)
        let prompts = await counter.prompts
        #expect(prompts.count == 1)
        #expect(prompts.first?.resolvedPath == target)
        #expect(prompts.first?.reason?.contains("outside the workspace") == true)
        #expect(result.toolCallDisplays.first?.isError == true)
        #expect(!FileManager.default.fileExists(atPath: target))
        let events = await counter.events
        #expect(events.contains { if case .awaitingApproval = $0 { return true }; return false })
        #expect(!events.contains { if case .toolExecutionStarted = $0 { return true }; return false })
    }

    @Test("with no approval UI a sensitive read is denied, an ordinary read runs unprompted")
    func missingApprovalDeniesSensitive() async throws {
        let workspace = try agentW1TempDir()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let client = AgentW1Client([
            agentW1ToolTurn("read_file", ["path": "~/.ssh/id_ed25519"], id: "secret"),
            agentW1ToolTurn("read_file", ["path": "notes.txt"], id: "plain"),
        ])
        let counter = AgentW1Counter()
        _ = try await NativeAgentRunner.run(
            prompt: "go", modelId: "m", apiKey: "k", workspace: workspace.path, fullComputerAccess: true,
            history: [], client: client,
            toolExecutor: { call in await counter.record(call); return .init(content: "ok", isError: false) },
            policy: .computerControl, approvals: nil, missingApproval: .deny, onEvent: { _ in }
        )
        #expect(await counter.calls.map(\.id) == ["plain"])
    }

    @Test("awaitingApproval comes before toolExecutionStarted for an approved call")
    func eventOrder() async throws {
        let workspace = try agentW1TempDir()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let client = AgentW1Client([agentW1ToolTurn("run_command", ["command": "true"])])
        let counter = AgentW1Counter()
        let approvals = ApprovalCoordinator(attention: ApprovalAttention())
        await approvals.setHandler { _ in .approved }
        _ = try await NativeAgentRunner.run(
            prompt: "go", modelId: "m", apiKey: "k", workspace: workspace.path, fullComputerAccess: true,
            history: [], client: client,
            toolExecutor: { call in await counter.record(call); return .init(content: "ok", isError: false) },
            policy: .computerControl, approvals: approvals, onEvent: { await counter.event($0) }
        )
        let events = await counter.events
        let waiting = events.firstIndex { if case .awaitingApproval = $0 { return true }; return false }
        let started = events.firstIndex { if case .toolExecutionStarted = $0 { return true }; return false }
        #expect(waiting != nil && started != nil && waiting! < started!)
        #expect(await counter.calls.count == 1)
    }

    @Test("Allow-for-this-run on run_command covers one folder, not every command")
    func scopedSessionApproval() async throws {
        let a = try agentW1TempDir(), b = try agentW1TempDir()
        defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
        let client = AgentW1Client([
            agentW1ToolTurn("run_command", ["command": "ls"], id: "1"),
            agentW1ToolTurn("run_command", ["command": "pwd"], id: "2"),
            agentW1ToolTurn("run_command", ["command": "ls", "working_directory": b.path], id: "3"),
        ])
        let counter = AgentW1Counter()
        let approvals = ApprovalCoordinator(attention: ApprovalAttention())
        await approvals.setHandler { request in
            await counter.prompt(request)
            return .approvedForSession
        }
        _ = try await NativeAgentRunner.run(
            prompt: "go", modelId: "m", apiKey: "k", workspace: a.path, fullComputerAccess: true,
            history: [], client: client,
            toolExecutor: { call in await counter.record(call); return .init(content: "ok", isError: false) },
            policy: .computerControl, approvals: approvals, onEvent: { _ in }
        )
        #expect(await counter.calls.count == 3)
        let prompts = await counter.prompts
        #expect(prompts.count == 2, "the second command in the same folder must not ask again")
        #expect(prompts.last?.resolvedPath == b.path)
        #expect(prompts.first?.scopeLabel?.contains("every command in") == true)
    }

    @Test("a pending approval is observable app-wide and posts one notice")
    func attention() async throws {
        let attention = ApprovalAttention()
        let notices = AgentW1Notices()
        attention.notify = { section, title, _ in notices.items.append((section, title)) }
        let approvals = ApprovalCoordinator(attentionSection: "Agent", attention: attention)
        let gate = AgentW1Gate()
        await approvals.setHandler { _ in await gate.wait() }
        let task = Task { await approvals.requestApproval(toolName: "run_command", summary: "{}") }
        for _ in 0..<200 where attention.pendingCount == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(attention.pendingCount == 1)
        #expect(attention.pendingCount(section: "Agent") == 1)
        #expect(attention.pendingCount(section: "Test Suite") == 0)
        #expect(notices.items.count == 1)
        #expect(notices.items.first?.0 == "Agent")
        await gate.open(.approved)
        #expect(await task.value)
        #expect(attention.pendingCount == 0)
    }

    @Test("ApprovalPresenter exposes how many requests wait")
    func presenterCount() async {
        let presenter = ApprovalPresenter()
        #expect(presenter.pendingCount == 0)
        let request = ApprovalCoordinator.Request(id: UUID(), toolName: "run_command", server: nil, summary: "{}")
        let task = Task { await presenter.present(request) }
        for _ in 0..<100 where presenter.pendingCount == 0 { await Task.yield() }
        #expect(presenter.pendingCount == 1)
        presenter.decide(request.id, .denied)
        #expect(await task.value == .denied)
        #expect(presenter.pendingCount == 0)
    }
}

@MainActor
private final class AgentW1Notices {
    var items: [(String, String)] = []
}

private actor AgentW1Gate {
    private var continuation: CheckedContinuation<ApprovalCoordinator.Decision, Never>?
    private var decided: ApprovalCoordinator.Decision?
    func wait() async -> ApprovalCoordinator.Decision {
        if let decided { return decided }
        return await withCheckedContinuation { continuation = $0 }
    }
    func open(_ decision: ApprovalCoordinator.Decision) {
        decided = decision
        continuation?.resume(returning: decision)
        continuation = nil
    }
}

@Suite("W1 agent: approval details (AGENT-5)")
struct W1AgentApprovalDetailTests {
    private func request(_ tool: String, _ args: [String: Any], path: String? = nil, scope: String? = nil) -> ApprovalCoordinator.Request {
        .init(id: UUID(), toolName: tool, server: nil, summary: agentW1Args(args), resolvedPath: path, scopeLabel: scope)
    }

    private func value(_ details: ApprovalDetails, _ label: String) -> String? {
        details.fields.first { $0.label == label }?.value
    }

    @Test("run_command shows the command and where it runs")
    func runCommand() {
        let details = ApprovalDetails.make(request("run_command", ["command": "rm -rf build", "working_directory": "/tmp/x"],
                                                   path: "/private/tmp/x", scope: "every command in /private/tmp/x"))
        #expect(value(details, "Command") == "rm -rf build")
        #expect(value(details, "Runs in") == "/private/tmp/x")
        #expect(details.sessionButtonTitle == "Allow every command in /private/tmp/x this run")
        #expect(details.sessionButtonHelp.contains("Anything else still asks"))
    }

    @Test("app name, URL and typed text are shown, not hidden in raw JSON")
    func otherArguments() {
        #expect(value(ApprovalDetails.make(request("open_application", ["name": "Terminal"])), "Application") == "Terminal")
        #expect(value(ApprovalDetails.make(request("open_url", ["url": "https://example.com/a"])), "URL") == "https://example.com/a")
        let typing = ApprovalDetails.make(request("computer_action", ["action": "type", "text": "sudo rm -rf /"]))
        #expect(value(typing, "Action") == "type")
        #expect(value(typing, "Text to type") == "sudo rm -rf /")
        let script = ApprovalDetails.make(request("run_applescript", ["script": "tell app \"Finder\" to quit"]))
        #expect(value(script, "Script")?.contains("Finder") == true)
    }

    @Test("a sensitive write shows the path, size and the reason it asks")
    func writeDetails() {
        var req = request("write_file", ["path": "/tmp/a.txt", "content": "one\ntwo\n"], path: "/private/tmp/a.txt")
        req.reason = "Writes outside the workspace: /private/tmp/a.txt"
        req.preview = "New file · 2 lines"
        let details = ApprovalDetails.make(req)
        #expect(details.isHighRisk)
        #expect(value(details, "File") == "/private/tmp/a.txt")
        #expect(value(details, "Size")?.contains("2 lines") == true)
        #expect(value(details, "Why ORB is asking")?.contains("outside the workspace") == true)
        #expect(value(details, "Changes") == "New file · 2 lines")
    }
}
