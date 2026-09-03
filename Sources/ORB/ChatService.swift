import Foundation

enum PlaygroundMode: String, CaseIterable, Identifiable, Sendable {
    case agent = "Agent"
    case chat = "Chat"
    var id: String { rawValue }
}

/// App-facing conversation coordinator. Every asynchronous mutation is scoped
/// to the run, conversation, and assistant-message IDs captured at start.
@MainActor
final class ChatService: ObservableObject {
    @Published var conversations: [ChatConversation] = []
    @Published var activeConversation: ChatConversation?
    @Published private(set) var runState = PlaygroundRunState()
    @Published var streamingContent = ""
    @Published var lastError: String?
    @Published var lastUsage: ChatUsage?
    @Published var activityLabel = ""
    @Published var tokensPerSecond: Double = 0

    private(set) var contentPublishCount = 0
    var isStreaming: Bool { runState.isActive }

    // MARK: - Streaming cadence
    //
    // Tuned for perceived snappiness across both fast and slow models. The
    // frame interval is just under one 60Hz frame, so text lands at display
    // rate without queueing redundant redraws; the character threshold makes a
    // burst from a fast model flush early rather than waiting out the timer.

    /// Minimum wall-clock gap between UI publishes during streaming.
    static let streamFrameInterval: Duration = .milliseconds(16)
    /// Safety valve for oversized bursts: if a provider hands us a very large
    /// chunk (or many deltas inside one frame), render rather than hold it.
    ///
    /// Deliberately well above a typical token. A small value here would fire on
    /// nearly every delta and defeat time-based coalescing entirely, producing
    /// hundreds of redundant redraws per response.
    static let streamFlushCharacters = 512
    /// Minimum gap between SQLite checkpoints while a run is in flight.
    static let streamCheckpointInterval: Duration = .milliseconds(750)

    func isRunning(conversationID: UUID) -> Bool {
        runState.isActive && runState.context?.conversationID == conversationID
    }

    func isStreamingMessage(_ messageID: UUID, conversationID: UUID) -> Bool {
        isRunning(conversationID: conversationID) && runState.context?.assistantMessageID == messageID
    }

    private let client: any OpenRouterClientProtocol
    private let store: any ConversationStore
    private let apiKeyProvider: () -> String?
    private var streamTask: Task<Void, Never>?
    private var agentHistories: [UUID: [AgentAPIMessage]] = [:]
    private var agentPendingContent = ""
    private var agentReasoningContent = ""
    private var agentContentCoalescer: StreamPublishCoalescer<String>?
    private var agentReasoningCoalescer: StreamPublishCoalescer<String>?
    private var regenerationBackups: [UUID: ChatMessage] = [:]
    private var lastCheckpoint: ContinuousClock.Instant?

    convenience init() {
        self.init(client: OpenRouterClient(), store: DatabaseConversationStore(), apiKeyProvider: { KeychainManager.getAPIKey() })
    }

    init(
        client: any OpenRouterClientProtocol,
        store: any ConversationStore,
        apiKeyProvider: @escaping () -> String?
    ) {
        self.client = client
        self.store = store
        self.apiKeyProvider = apiKeyProvider
        loadPersistedConversations()
    }

    private func loadPersistedConversations() {
        do {
            try store.recoverInterruptedRecords()
            let records = try store.loadRecords().sorted { $0.conversation.createdAt > $1.conversation.createdAt }
            conversations = records.map(\.conversation)
            agentHistories = Dictionary(uniqueKeysWithValues: records.map { ($0.conversation.id, $0.agentHistory) })
        } catch {
            lastError = "Could not load conversations: \(error.localizedDescription)"
        }
    }

    @discardableResult
    func newConversation(modelId: String, mode: PlaygroundMode = .agent, systemPrompt: String = "") -> ChatConversation {
        if let activeID = activeConversation?.id,
           let index = conversations.firstIndex(where: { $0.id == activeID }),
           conversations[index].mode == mode,
           conversations[index].messages.isEmpty {
            conversations[index].modelId = modelId
            conversations[index].systemPrompt = systemPrompt
            synchronizeActive(activeID)
            persist(activeID)
            return conversations[index]
        }
        let conversation = ChatConversation(modelId: modelId, mode: mode, systemPrompt: systemPrompt)
        conversations.insert(conversation, at: 0)
        activeConversation = conversation
        persist(conversation.id)
        return conversation
    }

    func selectConversation(_ conversation: ChatConversation) {
        activeConversation = conversations.first(where: { $0.id == conversation.id }) ?? conversation
    }

    func activateConversation(for mode: PlaygroundMode) {
        guard activeConversation?.mode != mode else { return }
        activeConversation = conversations.first(where: { $0.mode == mode })
    }

    func deleteConversation(_ conversation: ChatConversation) {
        do {
            try store.removeConversation(conversation.id)
        } catch {
            lastError = "Could not delete conversation: \(error.localizedDescription)"
            return
        }
        if isRunning(conversationID: conversation.id) { stopStreaming() }
        conversations.removeAll { $0.id == conversation.id }
        agentHistories[conversation.id] = nil
        if activeConversation?.id == conversation.id {
            activeConversation = conversations.first(where: { $0.mode == conversation.mode })
        }
    }

    func clearConversations() {
        if runState.isActive { stopStreaming() }
        let ids = conversations.map(\.id)
        for id in ids { do { try store.removeConversation(id) } catch { lastError = error.localizedDescription } }
        conversations.removeAll()
        agentHistories.removeAll()
        activeConversation = nil
    }

    func deleteMessage(_ messageID: UUID, from conversation: ChatConversation) {
        guard !isRunning(conversationID: conversation.id) else {
            lastError = "Messages cannot be deleted while this conversation is running. Stop it first."
            return
        }
        guard let index = conversations.firstIndex(where: { $0.id == conversation.id }) else { return }
        do {
            try store.removeMessage(messageID)
        } catch {
            lastError = "Could not delete message: \(error.localizedDescription)"
            return
        }
        conversations[index].messages.removeAll { $0.id == messageID }
        rebuildAgentHistory(for: conversation.id)
        synchronizeActive(conversation.id)
        do { try saveRecord(conversation.id) }
        catch { lastError = "Could not delete message: \(error.localizedDescription)" }
    }

    func updateSystemPrompt(_ prompt: String, for conversation: ChatConversation) {
        guard let index = conversations.firstIndex(where: { $0.id == conversation.id }) else { return }
        conversations[index].systemPrompt = prompt
        synchronizeActive(conversation.id)
        persist(conversation.id)
    }

    func sendMessage(
        _ text: String,
        modelId: String,
        settings: GenerationSettings = .default
    ) {
        _ = startDirectMessage(text, modelId: modelId, settings: settings, appendUser: true)
    }

    private func startDirectMessage(
        _ text: String,
        modelId: String,
        settings: GenerationSettings,
        appendUser: Bool,
        replacingAssistant: ChatMessage? = nil
    ) -> PlaygroundRunContext? {
        guard !isStreaming else { lastError = "A generation is already running."; return nil }
        guard let apiKey = apiKeyProvider(), !apiKey.isEmpty else {
            lastError = "No API key configured. Go to Account to add one."
            return nil
        }
        if activeConversation == nil || activeConversation?.modelId != modelId || activeConversation?.mode != .chat {
            _ = newConversation(modelId: modelId, mode: .chat)
        }
        guard let conversationID = activeConversation?.id,
              let conversationIndex = conversations.firstIndex(where: { $0.id == conversationID }) else { return nil }

        if appendUser {
            conversations[conversationIndex].messages.append(ChatMessage(role: "user", content: text))
            if conversations[conversationIndex].messages.count == 1 {
                conversations[conversationIndex].title = String(text.prefix(44)) + (text.count > 44 ? "…" : "")
            }
        }
        let assistant: ChatMessage
        if let replacingAssistant,
           let assistantIndex = conversations[conversationIndex].messages.firstIndex(where: { $0.id == replacingAssistant.id }) {
            assistant = ChatMessage(id: replacingAssistant.id, role: "assistant", content: "", status: .streaming)
            conversations[conversationIndex].messages[assistantIndex] = assistant
        } else {
            assistant = ChatMessage(role: "assistant", content: "", status: .streaming)
            conversations[conversationIndex].messages.append(assistant)
        }
        synchronizeActive(conversationID)
        persist(conversationID)

        var messages: [AgentAPIMessage] = []
        let conversation = conversations[conversationIndex]
        if !conversation.systemPrompt.isEmpty { messages.append(.init(role: "system", content: conversation.systemPrompt)) }
        messages += conversation.messages.dropLast().filter { $0.role == "user" || $0.role == "assistant" }.map {
            .init(role: $0.role, content: $0.content)
        }

        let context = PlaygroundRunContext(
            runID: UUID(), conversationID: conversationID, assistantMessageID: assistant.id,
            mode: .chat, startedAt: Date()
        )
        if let replacingAssistant { regenerationBackups[context.runID] = replacingAssistant }
        runState = .init(context: context, phase: .connecting)
        activityLabel = "Connecting…"
        streamingContent = ""
        lastError = nil
        lastUsage = nil
        tokensPerSecond = 0
        contentPublishCount = 0
        lastCheckpoint = nil
        let request = OpenRouterRequest(
            apiKey: apiKey, model: modelId, messages: messages,
            settings: settings
        )

        streamTask = Task { [weak self] in
            guard let self else { return }
            await self.consumeDirect(request: request, context: context)
        }
        return context
    }

    private func consumeDirect(request: OpenRouterRequest, context: PlaygroundRunContext) async {
        var fullContent = ""
        var reasoningContent = ""
        var latestUsage: ChatUsage?
        var finishReason: String?
        let contentCoalescer = StreamPublishCoalescer<String>(
            interval: Self.streamFrameInterval,
            characterBackstop: Self.streamFlushCharacters
        ) { [weak self] content in
            self?.publish(content: content, context: context)
        }
        let reasoningCoalescer = StreamPublishCoalescer<String>(
            interval: Self.streamFrameInterval,
            characterBackstop: Self.streamFlushCharacters
        ) { [weak self] reasoning in
            self?.publishReasoning(reasoning, context: context)
        }
        do {
            let stream = try await client.stream(request)
            guard owns(context.runID) else { return }
            runState.phase = .streaming
            activityLabel = "Streaming…"
            for try await event in stream {
                try Task.checkCancellation()
                guard owns(context.runID) else { return }
                switch event {
                case .contentDelta(let choice, let text) where choice == 0:
                    fullContent += text
                    contentCoalescer.submit(fullContent, addedCharacters: text.count)
                case .reasoningDelta(let choice, let text) where choice == 0:
                    reasoningContent += text
                    reasoningCoalescer.submit(reasoningContent, addedCharacters: text.count)
                case .usage(let usage): latestUsage = usage
                case .finishReason(let choice, let reason) where choice == 0: finishReason = reason
                case .apiError(let error):
                    contentCoalescer.flush()
                    reasoningCoalescer.flush()
                    if fullContent.isEmpty, restoreRegeneration(context, message: error.message) { return }
                    fail(context: context, message: error.message, status: .failed, finishReason: finishReason, usage: latestUsage)
                    return
                default: break
                }
            }
            contentCoalescer.flush()
            reasoningCoalescer.flush()
            guard owns(context.runID) else { return }
            if fullContent.isEmpty {
                if restoreRegeneration(context, message: "The model returned no supported output.") { return }
                fail(context: context, message: "The model returned no supported output.", status: .failed, finishReason: finishReason, usage: latestUsage)
            } else {
                let status: ChatMessageStatus = finishReason == "length" ? .truncated : .complete
                finish(context: context, status: status, finishReason: finishReason, usage: latestUsage)
            }
        } catch is CancellationError {
            guard owns(context.runID) else { return }
            contentCoalescer.flush()
            reasoningCoalescer.flush()
            if fullContent.isEmpty, restoreRegeneration(context, message: "Regeneration was cancelled.") { return }
            finish(context: context, status: .interrupted, finishReason: "cancelled", usage: latestUsage)
        } catch {
            guard owns(context.runID) else { return }
            contentCoalescer.flush()
            reasoningCoalescer.flush()
            if fullContent.isEmpty, restoreRegeneration(context, message: error.localizedDescription) { return }
            fail(context: context, message: error.localizedDescription, status: .interrupted, finishReason: finishReason, usage: latestUsage)
        }
    }

    private func publish(content: String, context: PlaygroundRunContext) {
        guard owns(context.runID), mutateMessage(context, mutation: { $0.content = content }) else { return }
        streamingContent = content
        contentPublishCount += 1
        synchronizeActive(context.conversationID)
        checkpoint(context)
    }

    /// Publishes streamed chain-of-thought. Kept separate from `publish` so
    /// reasoning never triggers a SQLite checkpoint — it can be very large and
    /// is not worth persisting on every frame.
    private func publishReasoning(_ reasoning: String, context: PlaygroundRunContext) {
        guard owns(context.runID) else { return }
        _ = mutateMessage(context, mutation: { $0.reasoning = reasoning })
        synchronizeActive(context.conversationID)
    }

    private func finish(
        context: PlaygroundRunContext,
        status: ChatMessageStatus,
        finishReason: String?,
        usage: ChatUsage?
    ) {
        guard owns(context.runID) else { return }
        _ = mutateMessage(context, mutation: {
            $0.status = status
            $0.finishReason = finishReason
        })
        apply(usage: usage, to: context)
        runState.phase = status == .complete ? .completed : .interrupted(finishReason)
        terminalCleanup(context)
    }

    private func fail(
        context: PlaygroundRunContext,
        message: String,
        status: ChatMessageStatus,
        finishReason: String?,
        usage: ChatUsage?
    ) {
        guard owns(context.runID) else { return }
        _ = mutateMessage(context, mutation: {
            $0.status = status
            $0.finishReason = finishReason
            $0.errorMessage = message
        })
        lastError = message
        apply(usage: usage, to: context)
        runState.phase = status == .failed ? .failed(message) : .interrupted(message)
        terminalCleanup(context)
    }

    @discardableResult
    private func restoreRegeneration(_ context: PlaygroundRunContext, message: String) -> Bool {
        guard let backup = regenerationBackups.removeValue(forKey: context.runID),
              mutateMessage(context, mutation: { $0 = backup }) else { return false }
        lastError = message
        runState.phase = .failed(message)
        terminalCleanup(context)
        return true
    }

    private func apply(usage: ChatUsage?, to context: PlaygroundRunContext) {
        guard let usage, let index = conversations.firstIndex(where: { $0.id == context.conversationID }) else { return }
        lastUsage = usage
        conversations[index].totalCost += usage.cost ?? 0
        conversations[index].totalTokens += usage.totalTokens ?? 0
        if let completion = usage.completionTokens {
            let elapsed = max(Date().timeIntervalSince(context.startedAt), 0.001)
            tokensPerSecond = Double(completion) / elapsed
        }
    }

    private func checkpoint(_ context: PlaygroundRunContext, force: Bool = false) {
        guard owns(context.runID) else { return }
        let now = ContinuousClock.now
        if !force, let lastCheckpoint,
           lastCheckpoint.duration(to: now) < Self.streamCheckpointInterval { return }
        persist(context.conversationID)
        lastCheckpoint = now
    }

    private func terminalCleanup(_ context: PlaygroundRunContext) {
        regenerationBackups[context.runID] = nil
        synchronizeActive(context.conversationID)
        persist(context.conversationID)
        streamingContent = ""
        activityLabel = ""
        streamTask = nil
    }

    func stopStreaming() {
        guard let context = runState.context, runState.isActive else { return }
        runState.phase = .stopping
        activityLabel = "Stopping…"
        streamTask?.cancel()
        // The task owns the final interrupted transition and persistence.
        if streamTask == nil { finish(context: context, status: .interrupted, finishReason: "cancelled", usage: nil) }
    }

    func regenerateLastResponse(modelId: String, settings: GenerationSettings = .default) async {
        guard !isStreaming else { return }
        guard let apiKey = apiKeyProvider(), !apiKey.isEmpty else {
            lastError = "No API key configured. Go to Account to add one."
            return
        }
        guard let conversationID = activeConversation?.id,
              let index = conversations.firstIndex(where: { $0.id == conversationID }),
              let assistantIndex = conversations[index].messages.lastIndex(where: { $0.role == "assistant" }),
              let userIndex = conversations[index].messages[..<assistantIndex].lastIndex(where: { $0.role == "user" }) else { return }
        let previousAssistant = conversations[index].messages[assistantIndex]
        let prompt = conversations[index].messages[userIndex].content
        conversations[index].modelId = modelId
        synchronizeActive(conversationID)
        _ = startDirectMessage(
            prompt,
            modelId: modelId,
            settings: settings,
            appendUser: false,
            replacingAssistant: previousAssistant
        )
    }

    // MARK: - Agent (streamed by NativeAgentRunner)

    func sendAgentMessage(
        _ text: String,
        modelId: String,
        workspace: String,
        fullComputerAccess: Bool
    ) async {
        guard !isStreaming else { lastError = "A generation is already running."; return }
        guard let apiKey = apiKeyProvider(), !apiKey.isEmpty else {
            lastError = "Add your OpenRouter API key in Account before using Agent mode."
            return
        }
        if activeConversation == nil || activeConversation?.modelId != modelId || activeConversation?.mode != .agent {
            _ = newConversation(modelId: modelId, mode: .agent)
        }
        guard let conversationID = activeConversation?.id,
              let index = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        conversations[index].messages.append(ChatMessage(role: "user", content: text))
        if conversations[index].messages.count == 1 { conversations[index].title = String(text.prefix(44)) }
        let assistant = ChatMessage(role: "assistant", content: "", status: .streaming)
        conversations[index].messages.append(assistant)
        synchronizeActive(conversationID)
        persist(conversationID)
        let context = PlaygroundRunContext(runID: UUID(), conversationID: conversationID, assistantMessageID: assistant.id, mode: .agent, startedAt: Date())
        runState = .init(context: context, phase: .connecting)
        activityLabel = "Thinking…"
        lastError = nil
        streamingContent = ""
        tokensPerSecond = 0
        contentPublishCount = 0
        agentPendingContent = ""
        agentReasoningContent = ""
        lastCheckpoint = nil
        agentContentCoalescer = StreamPublishCoalescer<String>(
            interval: Self.streamFrameInterval,
            characterBackstop: Self.streamFlushCharacters
        ) { [weak self] content in
            self?.publishAgentContent(content, context: context)
        }
        agentReasoningCoalescer = StreamPublishCoalescer<String>(
            interval: Self.streamFrameInterval,
            characterBackstop: Self.streamFlushCharacters
        ) { [weak self] reasoning in
            self?.publishReasoning(reasoning, context: context)
        }
        let history = agentHistories[conversationID] ?? []
        let customPrompt = conversations[index].systemPrompt
        streamTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await NativeAgentRunner.run(
                    prompt: text, modelId: modelId, apiKey: apiKey, workspace: workspace,
                    fullComputerAccess: fullComputerAccess, history: history,
                    systemPromptOverride: customPrompt.isEmpty ? nil : customPrompt,
                    client: self.client,
                    onEvent: { event in await self.receiveAgent(event, context: context) }
                )
                guard self.owns(context.runID) else { return }
                self.flushAgentStreams()
                // Note a force-summarized run so the user knows the answer was
                // capped rather than naturally concluded.
                let body = result.hitToolBudget
                    ? result.response + "\n\n---\n_Note: this run reached its tool-call budget, so the summary above may be incomplete._"
                    : result.response
                _ = self.mutateMessage(context, mutation: { $0.content = body })
                self.synchronizeActive(context.conversationID)
                self.agentHistories[conversationID] = result.history
                self.finish(context: context, status: .complete, finishReason: "stop", usage: result.usage)
            } catch is CancellationError {
                guard self.owns(context.runID) else { return }
                self.flushAgentStreams()
                self.rebuildAgentHistory(for: context.conversationID)
                self.finish(context: context, status: .interrupted, finishReason: "cancelled", usage: nil)
            } catch {
                guard self.owns(context.runID) else { return }
                self.flushAgentStreams()
                self.rebuildAgentHistory(for: context.conversationID)
                self.fail(context: context, message: error.localizedDescription, status: .failed, finishReason: nil, usage: nil)
            }
        }
    }

    private func receiveAgent(_ event: NativeAgentEvent, context: PlaygroundRunContext) {
        guard owns(context.runID) else { return }
        switch event {
        case .textDelta(let text):
            agentPendingContent += text
            agentContentCoalescer?.submit(agentPendingContent, addedCharacters: text.count)
            runState.phase = .streaming
        case .reasoningDelta(let text):
            agentReasoningContent += text
            agentReasoningCoalescer?.submit(agentReasoningContent, addedCharacters: text.count)
        case .toolCallUpdated(let call):
            _ = mutateMessage(context, mutation: { message in
                var calls = message.toolCalls ?? []
                let display = ToolCallDisplay(
                    id: call.id,
                    name: call.name,
                    argumentsSummary: String(call.arguments.prefix(200)),
                    arguments: call.arguments
                )
                if let i = calls.firstIndex(where: { $0.id == call.id }) { calls[i] = display } else { calls.append(display) }
                message.toolCalls = calls
            })
            synchronizeActive(context.conversationID)
            activityLabel = "Calling \(call.name)…"
        case .toolExecutionStarted(let call):
            _ = mutateMessage(context, mutation: { message in
                guard var calls = message.toolCalls,
                      let index = calls.firstIndex(where: { $0.id == call.id }) else { return }
                calls[index].isExecuting = true
                message.toolCalls = calls
            })
            synchronizeActive(context.conversationID)
            runState.phase = .executingTool(call.name)
            activityLabel = "Running \(call.name)…"
        case .toolResult(let call, let result):
            _ = mutateMessage(context, mutation: { message in
                guard var calls = message.toolCalls,
                      let index = calls.firstIndex(where: { $0.id == call.id }) else { return }
                calls[index].result = result.content
                calls[index].isError = result.isError
                calls[index].isExecuting = false
                message.toolCalls = calls
            })
            insertMessage(ChatMessage(role: "tool", content: result.content, toolCallId: call.id, toolName: call.name), before: context.assistantMessageID, conversationID: context.conversationID)
            // Persist on the same time budget as streamed content instead of
            // forcing a SQLite write per tool result — a tool-heavy run would
            // otherwise hit the disk once per call. The final state is always
            // flushed by terminalCleanup at completion.
            checkpoint(context)
        case .finalizing:
            runState.phase = .streaming
            activityLabel = "Wrapping up — summarizing results…"
        default: break
        }
    }

    private func publishAgentContent(_ content: String, context: PlaygroundRunContext) {
        guard owns(context.runID) else { return }
        _ = mutateMessage(context, mutation: { $0.content = content })
        streamingContent = content
        contentPublishCount += 1
        synchronizeActive(context.conversationID)
        checkpoint(context)
    }

    private func flushAgentStreams() {
        agentContentCoalescer?.flush()
        agentReasoningCoalescer?.flush()
    }

    func exportActiveConversation() -> String? {
        guard let conversation = activeConversation else { return nil }
        return DatabaseManager.shared.exportConversationMarkdown(conversation)
    }

    private func owns(_ runID: UUID) -> Bool { runState.context?.runID == runID }

    private func mutateMessage(_ context: PlaygroundRunContext, mutation: (inout ChatMessage) -> Void) -> Bool {
        guard let conversationIndex = conversations.firstIndex(where: { $0.id == context.conversationID }),
              let messageIndex = conversations[conversationIndex].messages.firstIndex(where: { $0.id == context.assistantMessageID }) else { return false }
        mutation(&conversations[conversationIndex].messages[messageIndex])
        return true
    }

    private func insertMessage(_ message: ChatMessage, before messageID: UUID, conversationID: UUID) {
        guard let conversationIndex = conversations.firstIndex(where: { $0.id == conversationID }),
              let messageIndex = conversations[conversationIndex].messages.firstIndex(where: { $0.id == messageID }) else { return }
        conversations[conversationIndex].messages.insert(message, at: messageIndex)
        synchronizeActive(conversationID)
    }

    private func synchronizeActive(_ conversationID: UUID) {
        guard activeConversation?.id == conversationID,
              let conversation = conversations.first(where: { $0.id == conversationID }) else { return }
        activeConversation = conversation
    }

    private func rebuildAgentHistory(for conversationID: UUID) {
        guard let conversation = conversations.first(where: { $0.id == conversationID }) else { return }
        let toolResults = conversation.messages.reduce(into: [String: ChatMessage]()) { results, message in
            guard message.role == "tool", let id = message.toolCallId, results[id] == nil else { return }
            results[id] = message
        }
        var history: [AgentAPIMessage] = []
        for message in conversation.messages {
            if message.role == "user" {
                history.append(.init(role: "user", content: message.content))
                continue
            }
            guard message.role == "assistant" else { continue }
            let pairedCalls = (message.toolCalls ?? []).filter { toolResults[$0.id] != nil }
            if !pairedCalls.isEmpty {
                let apiCalls = pairedCalls.map { call in
                    AgentToolCall(
                        id: call.id,
                        type: "function",
                        function: .init(name: call.name, arguments: call.arguments ?? call.argumentsSummary)
                    )
                }
                history.append(.init(role: "assistant", content: nil, toolCalls: apiCalls))
                for call in pairedCalls {
                    guard let result = toolResults[call.id] else { continue }
                    history.append(.init(role: "tool", content: result.content, toolCallId: call.id, name: call.name))
                }
            }
            if !message.content.isEmpty {
                history.append(.init(role: "assistant", content: message.content))
            }
        }
        agentHistories[conversationID] = history
    }

    private func persist(_ conversationID: UUID) {
        do { try saveRecord(conversationID) }
        catch { lastError = "Could not save conversation: \(error.localizedDescription)" }
    }

    private func saveRecord(_ conversationID: UUID) throws {
        guard let conversation = conversations.first(where: { $0.id == conversationID }) else { return }
        try store.saveRecord(.init(conversation: conversation, agentHistory: agentHistories[conversationID] ?? []))
    }

    func formattedCost(_ cost: Double) -> String {
        cost < 0.01 ? String(format: "$%.4f", cost) : String(format: "$%.2f", cost)
    }
}
