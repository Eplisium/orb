import Foundation
import Testing
@testable import ORB

@Suite("Agent helper billing completeness")
struct AgentHelperAccountingTests {
    @Test("Vision records one attempted request on success, failure, or cancellation", arguments: ["success", "failure", "cancel", "priced"])
    func visionUsage(outcome: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = directory.appendingPathComponent("fixture.png")
        try Data([0x89, 0x50, 0x4e, 0x47]).write(to: image)
        let sink = HelperAccountingSink()
        let usage = outcome == "priced" ? ChatUsage(promptTokens: 1, completionTokens: 2, totalTokens: 3, cost: 0.02) : nil
        do {
            let result = try await NativeAgentTools.describeImage(
                ["path": image.path], workspace: directory.path,
                client: HelperAccountingClient(usage: usage, outcome: outcome), credential: { "fixture" },
                recordUsage: { await sink.append($0) })
            #expect(outcome == "success" || outcome == "priced")
            #expect(result.content == "Fixture answer.")
        } catch {
            #expect(outcome == "failure" || outcome == "cancel")
            if outcome == "cancel" { #expect(error is CancellationError) }
        }
        let values = await sink.values
        #expect(values.count == 1)
        #expect(values.first! == usage)
    }

    @Test("Search without usage records unknown on every attempted outcome", arguments: ["success", "failure", "cancel"])
    func searchMissingUsage(outcome: String) async {
        let sink = HelperAccountingSink()
        do {
            _ = try await NativeAgentTools.agentWebSearch(["query": "fixture"],
                client: HelperAccountingClient(usage: nil, outcome: outcome), credential: { "fixture" },
                recordUsage: { await sink.append($0) })
            #expect(outcome == "success")
        } catch { #expect(outcome != "success") }
        let values = await sink.values
        #expect(values.count == 1)
        #expect(values.first! == nil)
    }

    @Test("Cancelling an in-flight helper records nil once even when iteration ends normally", arguments: [false, true])
    func cancelledHelper(vision: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = directory.appendingPathComponent("fixture.png")
        try Data([0x89, 0x50, 0x4e, 0x47]).write(to: image)
        let client = HelperAccountingHangingClient()
        let sink = HelperAccountingSink()
        let task = Task {
            do {
                if vision {
                    _ = try await NativeAgentTools.describeImage(["path": image.path], workspace: directory.path,
                        client: client, credential: { "fixture" }, recordUsage: { await sink.append($0) })
                } else {
                    _ = try await NativeAgentTools.agentWebSearch(["query": "fixture"],
                        client: client, credential: { "fixture" }, recordUsage: { await sink.append($0) })
                }
                return false
            } catch { return error is CancellationError }
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !(await client.started), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        let started = await client.started
        task.cancel()
        #expect(started)
        #expect(await task.value)
        let values = await sink.values
        #expect(values.count == 1)
        #expect(values.first! == nil)
    }

    @Test("Helper totals reach run budget metadata but not model ledger spend", arguments: [true, false])
    @MainActor func helperRunBudget(known: Bool) async throws {
        var events: [String: UsageEvent] = [:]
        let ledger = UsageLedger(recordEvent: { event in events[event.id] = event })
        let helper = ChatUsage(promptTokens: 1, completionTokens: 2, totalTokens: 3, cost: known ? 0.5 : nil)
        let result = try await NativeAgentRunner.run(prompt: "fixture", modelId: "mock", apiKey: "fixture",
            workspace: FileManager.default.temporaryDirectory.path, fullComputerAccess: false, history: [],
            client: HelperAccountingModelClient(), toolExecutor: { _ in
                try await NativeAgentTools.agentWebSearch(["query": "fixture"],
                    client: HelperAccountingClient(usage: helper, outcome: "success"), credential: { "fixture" },
                    recordUsage: { usage in
                        await ledger.record(.agentWebSearch, model: "helper", usage: usage, eventID: "helper")
                    })
            }, policy: .projectBuild, onEvent: { _ in })
        #expect(result.usage?.cost == 0.25)
        #expect(result.usage?.requestCount == 2)
        #expect(result.helperUsage.requestCount == 1)
        #expect(result.helperUsage.unpricedRequestCount == (known ? 0 : 1))
        #expect(result.reportedTotalCost == (known ? 0.75 : nil))
        #expect(result.knownTotalCostSubtotal == (known ? 0.75 : 0.25))
        ledger.record(.testSuite, model: "mock", usage: result.usage, eventID: "run")
        #expect(events.count == 2)
        #expect(events.values.compactMap(\.cost).reduce(0, +) == (known ? 0.75 : 0.25))
        #expect(events.values.reduce(0) { $0 + $1.requests } == 3)
    }

    @Test("Partial model usage survives the full runner and final summary", arguments: [false, true])
    func partialModelRun(forcedSummary: Bool) async throws {
        let result = try await NativeAgentRunner.run(prompt: "fixture", modelId: "mock", apiKey: "fixture",
            workspace: FileManager.default.temporaryDirectory.path, fullComputerAccess: false, history: [],
            client: HelperAccountingModelClient(firstUnpriced: true), maximumTurns: forcedSummary ? 1 : 2,
            toolExecutor: { _ in .init(content: "fixture", isError: false) },
            policy: .projectBuild, onEvent: { _ in })
        #expect(result.usage?.cost == nil)
        #expect(result.usage?.knownCostSubtotal == 0.125)
        #expect(result.usage?.requestCount == 2)
        #expect(result.usage?.unpricedRequestCount == 1)
        #expect(result.reportedTotalCost == nil)
        #expect(result.knownTotalCostSubtotal == 0.125)
        #expect(result.hitToolBudget == forcedSummary)
    }

    @Test("Model failure publishes received cost before propagating the error")
    func failedModelUsage() async {
        let sink = HelperAccountingSink()
        do {
            _ = try await NativeAgentRunner.run(prompt: "fixture", modelId: "mock", apiKey: "fixture",
                workspace: FileManager.default.temporaryDirectory.path, fullComputerAccess: false, history: [],
                client: HelperAccountingClient(usage: .init(promptTokens: 1, completionTokens: 2, totalTokens: 3, cost: 0.125), outcome: "fatal"),
                onEvent: { event in if case .usage(_, let usage) = event { await sink.append(usage) } })
            Issue.record("Expected failure")
        } catch {}
        let usage = await sink.values.last ?? nil
        #expect(usage?.knownCostSubtotal == 0.125)
        #expect(usage?.requestCount == 1)
    }

    @Test("Media helpers account unknown failures without duplicating service ledger events", arguments: [false, true])
    @MainActor func mediaHelperAccounting(serviceRecords: Bool) async {
        var events: [UsageEvent] = []
        let ledger = UsageLedger(recordEvent: { events.append($0) })
        let collector = AgentHelperUsageCollector()
        do {
            try await AgentHelperUsageCollector.$current.withValue(collector) {
                try await NativeAgentTools.accountedMediaHelper(recordUnknown: {
                    await ledger.record(.speech, model: "fixture", cost: nil)
                }) { () async throws -> Void in
                    if serviceRecords {
                        await ledger.record(.speech, model: "fixture", cost: 0.125)
                    }
                    throw URLError(.badServerResponse)
                }
            }
            Issue.record("Expected failure")
        } catch {}
        #expect(events.count == 1)
        #expect(collector.snapshot.requestCount == 1)
        #expect(collector.snapshot.knownCostSubtotal == (serviceRecords ? 0.125 : 0))
        #expect(collector.snapshot.unpricedRequestCount == (serviceRecords ? 0 : 1))
    }

    @Test("ChatService persists a partial model subtotal without inventing a full price")
    @MainActor func conversationSubtotal() async throws {
        var events: [UsageEvent] = []
        let ledger = UsageLedger(recordEvent: { events.append($0) })
        let store = HelperAccountingConversationStore()
        let service = ChatService(client: HelperAccountingModelClient(firstUnpriced: true, toolName: "read_file"),
            store: store, apiKeyProvider: { "fixture" }, usageLedger: ledger)
        await service.sendAgentMessage("fixture", modelId: "mock", workspace: FileManager.default.temporaryDirectory.path,
            fullComputerAccess: false)
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while service.isStreaming, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        #expect(!service.isStreaming)
        let conversation = try #require(service.activeConversation)
        #expect(conversation.totalCost == 0.125)
        #expect(conversation.messages.last?.usage?.cost == nil)
        #expect(conversation.messages.last?.usage?.knownCostSubtotal == 0.125)
        #expect(store.records[conversation.id]?.conversation.totalCost == 0.125)
        #expect(events.compactMap(\.cost).reduce(0, +) == 0.125)
        #expect(events.reduce(0) { $0 + $1.requests } == 2)
        #expect(events.filter { $0.cost == nil }.reduce(0) { $0 + $1.requests } == 1)
    }

    @Test("Cancelled model usage reaches ChatService terminal persistence")
    @MainActor func cancelledModelPersistence() async throws {
        var events: [UsageEvent] = []
        let ledger = UsageLedger(recordEvent: { events.append($0) })
        let usage = ChatUsage(promptTokens: 1, completionTokens: 2, totalTokens: 3, cost: 0.125)
        let service = ChatService(client: HelperAccountingHangingClient(usage: usage),
            store: HelperAccountingConversationStore(), apiKeyProvider: { "fixture" }, usageLedger: ledger)
        await service.sendAgentMessage("fixture", modelId: "mock", workspace: FileManager.default.temporaryDirectory.path,
            fullComputerAccess: false)
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while service.streamingContent.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        service.stopStreaming()
        while service.isStreaming, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        #expect(!service.isStreaming)
        #expect(service.activeConversation?.messages.last?.status == .interrupted)
        #expect(service.activeConversation?.totalCost == 0.125)
        #expect(events.compactMap(\.cost).reduce(0, +) == 0.125)
        #expect(events.reduce(0) { $0 + $1.requests } == 1)
    }

    @Test("Helper budgets retain failed ledger writes and ignore storage retries")
    @MainActor func helperLedgerRetry() {
        var reject = true
        var saved: [String: UsageEvent] = [:]
        let ledger = UsageLedger(recordEvent: { event in
            if reject { throw CocoaError(.fileWriteUnknown) }
            if saved[event.id] == nil { saved[event.id] = event }
        })
        let collector = AgentHelperUsageCollector()
        AgentHelperUsageCollector.$current.withValue(collector) {
            ledger.record(.agentWebSearch, model: "fixture", cost: 0.125, eventID: "helper")
            #expect(ledger.pendingEvents.count == 1)
            #expect(collector.snapshot.knownCostSubtotal == 0.125)
            reject = false
            ledger.retryPendingEvents()
            ledger.record(.agentWebSearch, model: "fixture", cost: 0.125, eventID: "helper")
        }
        #expect(ledger.pendingEvents.isEmpty)
        #expect(saved.count == 1)
        #expect(collector.snapshot.requestCount == 1)
        #expect(collector.snapshot.knownCostSubtotal == 0.125)
        #expect(collector.snapshot.isComplete)
    }

    @Test("Default result construction remains compatible and has no helpers")
    func legacyResult() {
        let result = NativeAgentRunResult(response: "fixture", history: [],
            usage: ChatUsage(promptTokens: nil, completionTokens: nil, totalTokens: nil, cost: 0),
            toolNames: [], toolCallDisplays: [], toolMessages: [])
        #expect(result.reportedTotalCost == 0)
        #expect(result.helperUsage.requestCount == 0)
    }
}

@MainActor private final class HelperAccountingConversationStore: ConversationStore {
    var records: [UUID: StoredConversation] = [:]
    func loadRecords() throws -> [StoredConversation] { Array(records.values) }
    func saveRecord(_ record: StoredConversation) throws { records[record.conversation.id] = record }
    func removeConversation(_ id: UUID) throws { records[id] = nil }
    func removeMessage(_ id: UUID) throws {}
    func recoverInterruptedRecords() throws {}
}

private actor HelperAccountingHangingClient: OpenRouterClientProtocol {
    let usage: ChatUsage?
    init(usage: ChatUsage? = nil) { self.usage = usage }
    private(set) var started = false
    private var continuation: AsyncThrowingStream<OpenRouterStreamEvent, Error>.Continuation?
    func stream(_ request: OpenRouterRequest) async throws -> AsyncThrowingStream<OpenRouterStreamEvent, Error> {
        let pair = AsyncThrowingStream<OpenRouterStreamEvent, Error>.makeStream()
        continuation = pair.continuation
        if let usage { pair.continuation.yield(.usage(usage)) }
        pair.continuation.yield(.contentDelta(choiceIndex: 0, text: "Pending"))
        started = true
        return pair.stream
    }
}

private actor HelperAccountingSink {
    var values: [ChatUsage?] = []
    func append(_ usage: ChatUsage?) { values.append(usage) }
}

private struct HelperAccountingClient: OpenRouterClientProtocol {
    let usage: ChatUsage?
    let outcome: String
    func stream(_ request: OpenRouterRequest) async throws -> AsyncThrowingStream<OpenRouterStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            if let usage { continuation.yield(.usage(usage)) }
            switch outcome {
            case "fatal": continuation.finish(throwing: URLError(.badURL))
            case "failure": continuation.finish(throwing: URLError(.networkConnectionLost))
            case "cancel": continuation.finish(throwing: CancellationError())
            default:
                continuation.yield(.contentDelta(choiceIndex: 0, text: "Fixture answer."))
                continuation.finish()
            }
        }
    }
}

private actor HelperAccountingModelClient: OpenRouterClientProtocol {
    let firstUnpriced: Bool
    private var turn = 0
    let toolName: String
    init(firstUnpriced: Bool = false, toolName: String = "web_search") {
        self.firstUnpriced = firstUnpriced
        self.toolName = toolName
    }
    func stream(_ request: OpenRouterRequest) async throws -> AsyncThrowingStream<OpenRouterStreamEvent, Error> {
        turn += 1
        let first = turn == 1
        let omitUsage = first && firstUnpriced
        let toolName = self.toolName
        return AsyncThrowingStream { continuation in
            if !omitUsage {
                continuation.yield(.usage(ChatUsage(promptTokens: 1, completionTokens: 2, totalTokens: 3, cost: 0.125)))
            }
            if first {
                continuation.yield(.toolCallFragment(choiceIndex: 0, toolIndex: 0, id: "fixture", type: "function", name: toolName, arguments: "{}"))
            } else {
                continuation.yield(.contentDelta(choiceIndex: 0, text: "Done."))
            }
            continuation.finish()
        }
    }
}
