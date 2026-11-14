import Foundation
import Testing
@testable import ORB

// Wave 1, agent track: run_command limits and quit cleanup (AGENT-4),
// write previews (AGENT-6), cut-off tool calls (AGENT-7), truthful prompt
// and copy (AGENT-12), streamed fetch_url (AGENT-13), list_directory
// notice (AGENT-14).

private actor AgentW1ToolClient: OpenRouterClientProtocol {
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

private actor AgentW1ToolLog {
    private(set) var calls: [String] = []
    private(set) var events: [NativeAgentEvent] = []
    private(set) var outputs: [String] = []
    func call(_ name: String) { calls.append(name) }
    func event(_ event: NativeAgentEvent) { events.append(event) }
    func output(_ text: String) { outputs.append(text) }
}

private final class AgentW1Lines: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func append(_ text: String) { lock.lock(); items.append(text); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
}

private func agentW1ToolDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("orb-w1-tools-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url.resolvingSymlinksInPath()
}

private func agentW1ToolJSON(_ object: [String: Any]) -> String {
    String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
}

@Suite("W1 agent: run_command limits (AGENT-4)", .serialized)
struct W1AgentRunCommandTests {
    @Test("timeout_seconds defaults to 120 and is clamped to 1…1800")
    func timeoutClamp() {
        #expect(NativeAgentTools.commandTimeout(nil) == 120)
        #expect(NativeAgentTools.commandTimeout(30) == 30)
        #expect(NativeAgentTools.commandTimeout(2.2) == 3)
        #expect(NativeAgentTools.commandTimeout("45") == 45)
        #expect(NativeAgentTools.commandTimeout(0) == 120)
        #expect(NativeAgentTools.commandTimeout(-5) == 120)
        #expect(NativeAgentTools.commandTimeout(99_999) == 1800)
        let schema = NativeAgentTools.definitions(fullComputerAccess: true).first { $0.function.name == "run_command" }
        #expect(schema.map { String(describing: $0) }?.contains("timeout_seconds") == true)
    }

    @Test("a command past its limit is stopped and returns its partial output")
    func timesOutWithPartialOutput() async throws {
        let start = ContinuousClock.now
        let result = try await NativeAgentTools.runCommandForTesting(
            command: "echo started-w1; sleep 30; echo never", timeout: .seconds(1)
        )
        #expect(result.timedOut)
        #expect(result.stdout.contains("started-w1"))
        #expect(!result.stdout.contains("never"))
        #expect(ContinuousClock.now - start < .seconds(10))
    }

    @Test("the tool result says it timed out and how to give it longer")
    func timeoutMessage() async throws {
        let result = try await NativeAgentTools.execute(
            name: "run_command",
            argumentsJSON: agentW1ToolJSON(["command": "echo partial-w1; sleep 20", "timeout_seconds": 1]),
            workspace: NSTemporaryDirectory(), fullComputerAccess: true
        )
        #expect(result.isError)
        #expect(result.content.hasPrefix("Timed out"))
        #expect(result.content.contains("partial-w1"))
        #expect(result.content.contains("timeout_seconds"))
    }

    @Test("live output reaches the relay while the command runs")
    func liveOutput() async throws {
        let lines = AgentW1Lines()
        let result = try await NativeAgentTools.runCommandForTesting(
            command: "echo tick-w1; sleep 0.4; echo tock-w1", timeout: .seconds(20),
            onOutput: { lines.append($0) }
        )
        #expect(!result.timedOut)
        #expect(lines.all.contains { $0.contains("tick-w1") })
        #expect(lines.all.last?.contains("tock-w1") == true)
    }

    @Test("terminateAllRunningProcesses stops a running command group")
    func terminateAll() async throws {
        let start = ContinuousClock.now
        let task = Task { try await NativeAgentTools.runCommandForTesting(command: "sleep 40", timeout: .seconds(60)) }
        for _ in 0..<300 where NativeAgentTools.runningProcessGroupCount == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(NativeAgentTools.runningProcessGroupCount > 0)
        NativeAgentTools.terminateAllRunningProcesses(grace: 0.1)
        let result = try await task.value
        #expect(result.exitCode != 0)
        #expect(ContinuousClock.now - start < .seconds(15))
        for _ in 0..<100 where NativeAgentTools.runningProcessGroupCount > 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(NativeAgentTools.runningProcessGroupCount == 0)
    }

    @Test("the runner forwards live output before the tool result")
    func runnerForwardsOutput() async throws {
        let client = AgentW1ToolClient([[
            .toolCallFragment(choiceIndex: 0, toolIndex: 0, id: "o1", type: "function", name: "read_file", arguments: #"{"path":"a"}"#),
            .finishReason(choiceIndex: 0, reason: "tool_calls"),
        ]])
        let log = AgentW1ToolLog()
        _ = try await NativeAgentRunner.run(
            prompt: "go", modelId: "m", apiKey: "k", workspace: NSTemporaryDirectory(), fullComputerAccess: true,
            history: [], client: client,
            toolExecutor: { _ in
                ToolOutputRelay.current?("line one")
                ToolOutputRelay.current?("line two")
                return .init(content: "final", isError: false)
            },
            policy: .computerControl, onEvent: { await log.event($0) }
        )
        let events = await log.events
        let lastOutput = events.lastIndex { if case .toolOutput = $0 { return true }; return false }
        let result = events.firstIndex { if case .toolResult = $0 { return true }; return false }
        #expect(lastOutput != nil && result != nil && lastOutput! < result!)
    }
}

@Suite("W1 agent: write previews (AGENT-6)")
struct W1AgentWritePreviewTests {
    @Test("UnifiedDiff counts added and removed lines with context")
    func diff() {
        let result = UnifiedDiff.make(old: "a\nb\nc\nd\n", new: "a\nB\nc\nd\ne\n")
        #expect(result.added == 2)
        #expect(result.removed == 1)
        #expect(result.text.contains("-b"))
        #expect(result.text.contains("+B"))
        #expect(result.text.contains("+e"))
        #expect(result.text.hasPrefix("@@ -1,"))
        #expect(UnifiedDiff.make(old: "same\n", new: "same\n").text.isEmpty)
        #expect(UnifiedDiff.make(old: "", new: "x\ny").added == 2)
    }

    @Test("a long diff is capped with a notice")
    func cappedDiff() {
        let old = (0..<500).map { "line \($0)" }.joined(separator: "\n")
        let new = (0..<500).map { "LINE \($0)" }.joined(separator: "\n")
        let result = UnifiedDiff.make(old: old, new: new, maxLines: 40)
        #expect(result.added == 500 && result.removed == 500)
        #expect(result.text.contains("more diff lines not shown"))
    }

    @Test("write_file reports created vs modified with real line counts")
    func writeFileReport() async throws {
        let dir = try agentW1ToolDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("app.ts").path
        let created = try await NativeAgentTools.execute(
            name: "write_file", argumentsJSON: agentW1ToolJSON(["path": path, "content": "one\ntwo\n"]),
            workspace: dir.path, fullComputerAccess: true
        )
        #expect(created.content.hasPrefix("Created \(path)"))
        #expect(created.content.contains("2 lines"))
        let modified = try await NativeAgentTools.execute(
            name: "write_file", argumentsJSON: agentW1ToolJSON(["path": path, "content": "one\n2\nthree\n"]),
            workspace: dir.path, fullComputerAccess: true
        )
        #expect(modified.content.hasPrefix("Modified \(path): +2 −1 lines"))
        #expect(modified.content.contains("-two"))
        #expect(modified.content.contains("+three"))
    }

    @Test("the approval preview for an overwrite is a diff against the current file")
    func approvalPreview() throws {
        let dir = try agentW1ToolDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("f.txt")
        try "old\n".write(to: url, atomically: true, encoding: .utf8)
        let call = AssembledAgentToolCall(index: 0, id: "w", type: "function", name: "write_file",
                                          arguments: agentW1ToolJSON(["path": url.path, "content": "new\n"]))
        let preview = try #require(NativeAgentRunner.approvalPreview(for: call, resolvedPath: url.path))
        #expect(preview.hasPrefix("Overwrites existing file · +1 −1 lines"))
        #expect(preview.contains("-old") && preview.contains("+new"))
        // Nothing was written by computing the preview.
        #expect(try String(contentsOf: url, encoding: .utf8) == "old\n")
    }

    @Test("a write_file card shows the file, not one line of escaped JSON")
    func cardPreview() throws {
        let args = agentW1ToolJSON(["path": "src/app.ts", "content": "import x\nconsole.log(x)\n"])
        let before = try #require(ToolCallReadablePreview.make(toolName: "write_file", argumentsJSON: args, result: nil))
        #expect(before.language == "ts")
        #expect(before.body == "import x\nconsole.log(x)\n")
        #expect(before.header.contains("2 lines"))
        let after = try #require(ToolCallReadablePreview.make(
            toolName: "write_file", argumentsJSON: args, result: "Modified /p/src/app.ts: +1 −0 lines (now 2 lines, 24 bytes).\n@@ -1,1 +1,2 @@\n import x\n+console.log(x)"
        ))
        #expect(after.language == "diff")
        #expect(after.header.hasPrefix("Modified"))
        #expect(after.body.hasPrefix("@@"))
        #expect(ToolCallReadablePreview.make(toolName: "run_command", argumentsJSON: #"{"command":"ls -la"}"#, result: nil)?.body == "ls -la")
    }
}

@Suite("W1 agent: cut-off tool calls (AGENT-7)")
struct W1AgentTruncatedCallTests {
    private func cutOff(_ id: String) -> [OpenRouterStreamEvent] {
        [
            .toolCallFragment(choiceIndex: 0, toolIndex: 0, id: id, type: "function", name: "write_file",
                              arguments: #"{"path":"big.txt","content":"aaaa"#),
            .finishReason(choiceIndex: 0, reason: "length"),
        ]
    }

    @Test("a call cut off by the output limit becomes a tool error and the run continues")
    func recovers() async throws {
        let client = AgentW1ToolClient([cutOff("t1"), [
            .contentDelta(choiceIndex: 0, text: "split it"), .finishReason(choiceIndex: 0, reason: "stop"),
        ]])
        let log = AgentW1ToolLog()
        let result = try await NativeAgentRunner.run(
            prompt: "write", modelId: "m", apiKey: "k", workspace: NSTemporaryDirectory(), fullComputerAccess: true,
            history: [], client: client,
            toolExecutor: { call in await log.call(call.name); return .init(content: "ran", isError: false) },
            policy: .computerControl, missingApproval: .autoApprove, onEvent: { _ in }
        )
        #expect(result.response == "split it")
        #expect(await log.calls.isEmpty)
        let toolMessage = try #require(result.toolMessages.first)
        #expect(toolMessage.content.contains("cut off by the model's output limit"))
        #expect(toolMessage.content.contains("smaller write_file calls"))
        // The partial payload is not replayed upstream.
        let requests = await client.requests
        let replayed = requests.last?.messages.compactMap(\.toolCalls).flatMap { $0 }.first
        #expect(replayed?.function.arguments == "{}")
    }

    @Test("a model that keeps overflowing still stops with a clear error")
    func bounded() async {
        let client = AgentW1ToolClient([cutOff("a"), cutOff("b"), cutOff("c"), cutOff("d")])
        await #expect(throws: NativeAgentError.self) {
            _ = try await NativeAgentRunner.run(
                prompt: "write", modelId: "m", apiKey: "k", workspace: NSTemporaryDirectory(), fullComputerAccess: true,
                history: [], client: client, toolExecutor: { _ in .init(content: "", isError: false) },
                policy: .computerControl, missingApproval: .autoApprove, onEvent: { _ in }
            )
        }
    }
}

@Suite("W1 agent: truthful prompt and copy (AGENT-12)")
struct W1AgentPromptTests {
    @Test("the Web Only system prompt lists only tools that are offered")
    func webOnlyPrompt() async throws {
        let client = AgentW1ToolClient([])
        _ = try await NativeAgentRunner.run(
            prompt: "hi", modelId: "m", apiKey: "k", workspace: NSTemporaryDirectory(), fullComputerAccess: false,
            history: [], client: client, policy: .webOnly, onEvent: { _ in }
        )
        let system = try #require(await client.requests.first?.messages.first?.content)
        #expect(!system.contains("run_command"))
        #expect(!system.contains("write_file"))
        #expect(!system.contains("computer_action"))
        #expect(system.contains("fetch_url"))
        #expect(system.contains("Computer Access must be turned on"))
    }

    @Test("the full prompt still lists the local toolbox")
    func fullPrompt() {
        let prompt = NativeAgentRunner.systemPrompt(workspace: "/tmp", fullComputerAccess: true)
        #expect(prompt.contains("run_command"))
        #expect(prompt.contains("view_image"))
        #expect(!prompt.contains("Computer Access must be turned on"))
    }

    @Test("Web Only help names everything it enables; the workspace note is accurate")
    func copy() {
        let web = AgentAccessCopy.help(fullComputerAccess: false)
        #expect(web.contains("search the web"))
        #expect(web.contains("memories"))
        #expect(!web.contains("Only the web fetch"))
        #expect(!AgentAccessCopy.workspaceNote.contains("project context"))
        #expect(AgentAccessCopy.workspaceNote.contains("every Agent session"))
        #expect(AgentAccessCopy.help(fullComputerAccess: true).contains("approval"))
    }
}

@Suite("W1 agent: list_directory notice (AGENT-14)")
struct W1AgentListDirectoryTests {
    @Test("a listing past 500 entries says how many were left out")
    func notice() async throws {
        let dir = try agentW1ToolDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        for index in 0..<600 {
            FileManager.default.createFile(atPath: dir.appendingPathComponent(String(format: "f%04d.txt", index)).path, contents: nil)
        }
        let result = try await NativeAgentTools.execute(
            name: "list_directory", argumentsJSON: agentW1ToolJSON(["path": dir.path]),
            workspace: dir.path, fullComputerAccess: true
        )
        #expect(result.content.contains("and 100 more entries"))
        #expect(result.content.contains("first 500 of 600"))
        #expect(!result.content.contains("f0599.txt"))
    }
}

// MARK: - fetch_url streaming (AGENT-13)

/// Serves an endless-looking 50 MB body in small chunks and counts how much
/// was actually handed to URLSession before the reader stopped.
final class AgentW1HugeBodyProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var bytesServed = 0
    nonisolated(unsafe) static var contentType = "text/plain"
    private let stopLock = NSLock()
    private var stopped = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let total = 50 * 1024 * 1024
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": Self.contentType, "Content-Length": "\(total)"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let chunk = Data(repeating: UInt8(ascii: "a"), count: 64 * 1024)
        DispatchQueue.global().async { [self] in
            var sent = 0
            while sent < total {
                stopLock.lock(); let done = stopped; stopLock.unlock()
                if done { return }
                client?.urlProtocol(self, didLoad: chunk)
                sent += chunk.count
                Self.bytesServed = sent
                Thread.sleep(forTimeInterval: 0.002)
            }
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
        stopLock.lock(); stopped = true; stopLock.unlock()
    }
}

@Suite("W1 agent: fetch_url streaming (AGENT-13)", .serialized)
struct W1AgentFetchTests {
    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AgentW1HugeBodyProtocol.self]
        return URLSession(configuration: configuration)
    }

    @Test("a huge body stops at the cap without being downloaded")
    func capped() async throws {
        AgentW1HugeBodyProtocol.bytesServed = 0
        AgentW1HugeBodyProtocol.contentType = "text/plain"
        let result = try await NativeAgentTools.fetchURLForTesting("https://w1.example.test/huge", session: session())
        #expect(!result.isError)
        #expect(result.content.contains("response truncated after \(NativeAgentTools.fetchByteCap) bytes"))
        #expect(result.content.count < NativeAgentTools.fetchByteCap + 500)
        try await Task.sleep(for: .milliseconds(100))
        #expect(AgentW1HugeBodyProtocol.bytesServed < 3 * 1024 * 1024)
    }

    @Test("a binary content type is reported without reading the body")
    func binaryType() async throws {
        AgentW1HugeBodyProtocol.bytesServed = 0
        AgentW1HugeBodyProtocol.contentType = "video/mp4"
        let result = try await NativeAgentTools.fetchURLForTesting("https://w1.example.test/movie", session: session())
        #expect(result.content.contains("<binary response: video/mp4"))
        #expect(AgentW1HugeBodyProtocol.bytesServed < 3 * 1024 * 1024)
        AgentW1HugeBodyProtocol.contentType = "text/plain"
    }

    @Test("text detection tolerates a character split by the cap and rejects NUL bytes")
    func textDetection() {
        let euro = Data("ab€".utf8)
        #expect(FetchBody.looksLikeText(euro.dropLast(1), truncated: true))
        #expect(!FetchBody.looksLikeText(euro.dropLast(1), truncated: false))
        #expect(!FetchBody.looksLikeText(Data([0x41, 0x00, 0x42]), truncated: false))
        #expect(FetchBody.isBinaryMIME("image/png"))
        #expect(!FetchBody.isBinaryMIME("image/svg+xml"))
        #expect(!FetchBody.isBinaryMIME("text/html; charset=utf-8"))
    }
}
