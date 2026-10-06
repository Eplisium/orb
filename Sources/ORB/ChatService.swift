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
    @Published var lastError: String? {
        didSet { lastErrorConversationID = nil }
    }
    private(set) var lastErrorConversationID: UUID?
    @Published var lastUsage: ChatUsage?
    @Published var activityLabel = ""
    @Published var tokensPerSecond: Double = 0

    private(set) var contentPublishCount = 0
    private var reasoningActiveRunID: UUID?
    var isStreaming: Bool { runState.isActive }

    // MARK: - Streaming cadence
    //
    // Tuned for perceived snappiness across both fast and slow models: the
    // frame interval sits at roughly two 60Hz frames, the character threshold
    // makes a burst from a fast model flush early rather than waiting out the
    // timer, and the checkpoint interval keeps SQLite writes well below one
    // per second.
    //
    // Why not faster: 16ms publishes re-rendered the whole Markdown tree at
    // display rate AND fired a follow-scroll each frame; on longer answers
    // the layout work exceeded the frame budget and text visibly stuttered.
    // Why not slower: beyond ~50ms the first paint feels laggy on quick
    // answers. 33ms with a 512-character backstop keeps fast model bursts
    // under a display-frame cadence without delaying the first token.
    // The burst tests assert <60 publishes for 1,000 medium-sized deltas.

    /// Minimum wall-clock gap between UI publishes during streaming.
    static let streamFrameInterval: Duration = .milliseconds(33)
    /// Safety valve for unusually large network chunks. This must stay well
    /// above a normal token; a 120-character valve painted 126 times for just
    /// 1,000 medium-sized deltas, bypassing the 33ms cadence.
    static let streamFlushCharacters = 512
    /// Minimum gap between SQLite checkpoints while a run is in flight.
    static let streamCheckpointInterval: Duration = .milliseconds(750)

    func isRunning(conversationID: UUID) -> Bool {
        runState.isActive && runState.context?.conversationID == conversationID
    }

    func isStreamingMessage(_ messageID: UUID, conversationID: UUID) -> Bool {
        isRunning(conversationID: conversationID) && runState.context?.assistantMessageID == messageID
    }

    func isReasoningMessage(_ messageID: UUID, conversationID: UUID) -> Bool {
        isStreamingMessage(messageID, conversationID: conversationID)
            && reasoningActiveRunID == runState.context?.runID
    }

    private let client: any OpenRouterClientProtocol
    private let store: any ConversationStore
    private let apiKeyProvider: () -> String?
    private let agentMaximumTurns: Int
    /// Source of MCP server configs for the Agent tool policy. Injected so
    /// tests never read the user's real MCP settings.
    private let mcpServerProvider: () -> [MCPServerConfig]
    /// The policy handed to the most recent Agent run (diagnostics/tests).
    private(set) var lastAgentPolicy: ToolPolicy?
    /// Risky agent tools (terminal, computer control, MCP) wait here for the user.
    let approvalPresenter = ApprovalPresenter()
    private let approvals = ApprovalCoordinator()
    private var streamTask: Task<Void, Never>?
    private var agentHistories: [UUID: [AgentAPIMessage]] = [:]
    private var agentPendingContent = ""
    private var agentNeedsTurnSeparator = false
    private var agentReasoningContent = ""
    private var agentReasoningDetails: [ReasoningDetail] = []
    private(set) var agentCumulativeUsage: ChatUsage?
    private var agentContentCoalescer: StreamPublishCoalescer<String>?
    private var agentReasoningCoalescer: StreamPublishCoalescer<String>?
    private var agentDetailCoalescer: StreamPublishCoalescer<[ReasoningDetail]>?
    private var agentToolPreviews: [AssembledAgentToolCall] = []
    private var agentToolPreviewCoalescer: StreamPublishCoalescer<[AssembledAgentToolCall]>?
    private var regenerationBackups: [UUID: ChatMessage] = [:]
    private var lastCheckpoint: ContinuousClock.Instant?
    /// Messages created during the current run besides its assistant row
    /// (Agent tool results). Checkpoints upsert exactly these plus the
    /// assistant, never the whole conversation.
    private var runInsertedMessageIDs: Set<UUID> = []
    /// Debounced system-prompt save (the editor writes on every keystroke).
    private var pendingPromptSave: (conversationID: UUID, task: Task<Void, Never>)?
    static let systemPromptSaveDelay: Duration = .milliseconds(600)
    private let loadMode: PlaygroundMode?

    /// `loadMode` limits which persisted sessions (and their messages) load;
    /// the root view owns one service per playground.
    convenience init(loadMode: PlaygroundMode? = nil) {
        self.init(
            client: OpenRouterClient(), store: DatabaseConversationStore(),
            apiKeyProvider: { KeychainManager.getAPIKey() },
            mcpServerProvider: { MCPRegistry.loadConfigs() },
            loadMode: loadMode
        )
    }

    init(
        client: any OpenRouterClientProtocol,
        store: any ConversationStore,
        apiKeyProvider: @escaping () -> String?,
        agentMaximumTurns: Int = 100,
        mcpServerProvider: @escaping () -> [MCPServerConfig] = { [] },
        loadMode: PlaygroundMode? = nil
    ) {
        self.loadMode = loadMode
        self.client = client
        self.store = store
        self.apiKeyProvider = apiKeyProvider
        self.agentMaximumTurns = agentMaximumTurns
        self.mcpServerProvider = mcpServerProvider
        installApprovalHandler()
        loadPersistedConversations()
    }

    private func loadPersistedConversations() {
        do {
            try store.recoverInterruptedRecords()
            let records = try store.loadRecords(mode: loadMode).sorted { $0.conversation.createdAt > $1.conversation.createdAt }
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

    /// Ensures a send has a conversation of the right mode. Changing the
    /// model mid-chat switches the active conversation's model in place
    /// (and persists it) instead of silently starting a new session.
    private func prepareActiveConversation(modelId: String, mode: PlaygroundMode) {
        guard let active = activeConversation, active.mode == mode,
              let index = conversations.firstIndex(where: { $0.id == active.id }) else {
            _ = newConversation(modelId: modelId, mode: mode)
            return
        }
        guard conversations[index].modelId != modelId else { return }
        conversations[index].modelId = modelId
        synchronizeActive(active.id)
        persistMeta(active.id)
    }

    /// Switches the model of an existing conversation (picker change).
    func switchModel(_ modelId: String, for conversationID: UUID) {
        guard !isRunning(conversationID: conversationID),
              let index = conversations.firstIndex(where: { $0.id == conversationID }),
              conversations[index].modelId != modelId else { return }
        conversations[index].modelId = modelId
        synchronizeActive(conversationID)
        persistMeta(conversationID)
    }

    func selectConversation(_ conversation: ChatConversation) {
        flushPendingEdits()
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

    /// Deletes several conversations at once. Stops any running one first.
    /// Returns the number actually removed; failures are reported via `lastError`.
    @discardableResult
    func deleteConversations(ids: Set<UUID>) -> Int {
        guard !ids.isEmpty else { return 0 }
        let targets = conversations.filter { ids.contains($0.id) }
        if targets.contains(where: { isRunning(conversationID: $0.id) }) { stopStreaming() }
        var removed = Set<UUID>()
        var failure: String?
        for conversation in targets {
            do {
                try store.removeConversation(conversation.id)
                removed.insert(conversation.id)
            } catch {
                failure = "Could not delete some conversations: \(error.localizedDescription)"
            }
        }
        let activeMode = activeConversation?.mode
        conversations.removeAll { removed.contains($0.id) }
        for id in removed { agentHistories[id] = nil }
        if let active = activeConversation, removed.contains(active.id) {
            activeConversation = conversations.first(where: { $0.mode == activeMode })
        }
        if let failure { lastError = failure }
        return removed.count
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

    // MARK: - Session management (Phase 5)
    //
    // Everything here is storage-first: the store is written (or the removal
    // succeeds) before the in-memory list changes, so a failure never leaves
    // the UI showing something the database does not have.

    @discardableResult
    func renameConversation(_ id: UUID, to name: String) -> Bool {
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        guard !trimmed.isEmpty, let index = conversations.firstIndex(where: { $0.id == id }) else { return false }
        conversations[index].title = trimmed
        synchronizeActive(id)
        persist(id)
        return true
    }

    /// Full copy with fresh message IDs, selected on success.
    func duplicateConversation(_ id: UUID) -> ChatConversation? {
        guard let source = conversations.first(where: { $0.id == id }) else { return nil }
        return insertCopy(of: source, messages: source.messages, titleSuffix: "(copy)")
    }

    /// Copy of the conversation up to and including `messageID`.
    func branchConversation(from messageID: UUID, in conversationID: UUID) -> ChatConversation? {
        guard let source = conversations.first(where: { $0.id == conversationID }),
              let cut = source.messages.firstIndex(where: { $0.id == messageID }) else { return nil }
        return insertCopy(of: source, messages: Array(source.messages[...cut]), titleSuffix: "(branch)")
    }

    private func insertCopy(of source: ChatConversation, messages: [ChatMessage], titleSuffix: String) -> ChatConversation? {
        var copy = ChatConversation(
            title: "\(source.title) \(titleSuffix)",
            modelId: source.modelId,
            mode: source.mode,
            messages: messages.map { message in
                var m = message
                m.id = UUID()
                // Interrupted/streaming rows are copied as-is but never as live.
                if m.status == .streaming { m.status = .interrupted }
                return m
            },
            systemPrompt: source.systemPrompt
        )
        copy.totalCost = source.totalCost
        copy.totalTokens = source.totalTokens
        conversations.insert(copy, at: 0)
        rebuildAgentHistory(for: copy.id)
        do {
            try saveRecord(copy.id)
        } catch {
            conversations.removeAll { $0.id == copy.id }
            agentHistories[copy.id] = nil
            lastError = "Could not save the new session: \(error.localizedDescription)"
            return nil
        }
        activeConversation = copy
        return copy
    }

    /// Edit-and-resend: drops a user message and everything after it and
    /// returns its text for the composer. Nil (and nothing changed) on failure.
    func truncateConversation(from messageID: UUID, in conversationID: UUID) -> String? {
        guard !isRunning(conversationID: conversationID),
              let index = conversations.firstIndex(where: { $0.id == conversationID }),
              let cut = conversations[index].messages.firstIndex(where: { $0.id == messageID }),
              conversations[index].messages[cut].role == "user" else { return nil }
        let text = conversations[index].messages[cut].content
        let dropped = conversations[index].messages[cut...].map(\.id)
        do {
            for id in dropped { try store.removeMessage(id) }
        } catch {
            lastError = "Could not edit the conversation: \(error.localizedDescription)"
            return nil
        }
        conversations[index].messages.removeSubrange(cut...)
        rebuildAgentHistory(for: conversationID)
        synchronizeActive(conversationID)
        do { try saveRecord(conversationID) } catch { lastError = "Could not edit the conversation: \(error.localizedDescription)" }
        return text
    }

    /// What an edit removed, so the UI can offer Undo, plus the original
    /// attachments so the resend keeps them.
    struct ConversationEdit: Equatable {
        let conversationID: UUID
        let text: String
        let parts: [MessageContentPart]?
        fileprivate let removed: [ChatMessage]
        /// Message count left after the cut; undo requires nothing was added.
        fileprivate let keptCount: Int
        var removedCount: Int { removed.count }
    }

    /// Non-destructive edit: truncates from the user message (as before) but
    /// returns everything needed to undo it and to resend with attachments.
    func beginEdit(from messageID: UUID, in conversationID: UUID) -> ConversationEdit? {
        guard let index = conversations.firstIndex(where: { $0.id == conversationID }),
              let cut = conversations[index].messages.firstIndex(where: { $0.id == messageID }) else { return nil }
        let removed = Array(conversations[index].messages[cut...])
        let parts = conversations[index].messages[cut].parts
        guard let text = truncateConversation(from: messageID, in: conversationID) else { return nil }
        return ConversationEdit(conversationID: conversationID, text: text, parts: parts, removed: removed, keptCount: cut)
    }

    /// Restores the messages an edit removed. Refused once the conversation
    /// moved on (a new message was sent) or while it is running.
    @discardableResult
    func undoEdit(_ edit: ConversationEdit) -> Bool {
        guard !isRunning(conversationID: edit.conversationID),
              let index = conversations.firstIndex(where: { $0.id == edit.conversationID }) else { return false }
        let existing = Set(conversations[index].messages.map(\.id))
        guard conversations[index].messages.count == edit.keptCount,
              !edit.removed.contains(where: { existing.contains($0.id) }) else { return false }
        conversations[index].messages += edit.removed
        rebuildAgentHistory(for: edit.conversationID)
        synchronizeActive(edit.conversationID)
        do { try saveRecord(edit.conversationID) } catch {
            lastError = "Could not undo the edit: \(error.localizedDescription)"
            return false
        }
        return true
    }

    /// Bulk delete that hands back what it removed so the UI can offer Undo.
    /// Only conversations whose removal succeeded are in the snapshot.
    func deleteConversationsUndoable(ids: Set<UUID>) -> [StoredConversation]? {
        let targets = conversations.filter { ids.contains($0.id) }
        let snapshot = targets.map { StoredConversation(conversation: $0, agentHistory: agentHistories[$0.id] ?? []) }
        let removed = deleteConversations(ids: ids)
        guard removed > 0 else { return nil }
        let survivors = Set(conversations.map(\.id))
        let result = snapshot.filter { !survivors.contains($0.conversation.id) }
        return result.isEmpty ? nil : result
    }

    /// Puts deleted conversations back (idempotent) and re-saves them.
    func restore(_ records: [StoredConversation]) {
        let existing = Set(conversations.map(\.id))
        for record in records where !existing.contains(record.conversation.id) {
            conversations.append(record.conversation)
            agentHistories[record.conversation.id] = record.agentHistory
            do { try store.saveRecord(record) }
            catch { lastError = "Could not restore a session: \(error.localizedDescription)" }
        }
        conversations.sort { $0.createdAt > $1.createdAt }
    }

    /// Bound to a TextEditor, so this fires per keystroke. Memory updates
    /// immediately; the conversation row is written once typing pauses (or
    /// when `flushPendingEdits` runs on navigation/send).
    func updateSystemPrompt(_ prompt: String, for conversation: ChatConversation) {
        guard let index = conversations.firstIndex(where: { $0.id == conversation.id }) else { return }
        guard conversations[index].systemPrompt != prompt else { return }
        conversations[index].systemPrompt = prompt
        synchronizeActive(conversation.id)
        if let pending = pendingPromptSave, pending.conversationID != conversation.id { flushPendingEdits() }
        pendingPromptSave?.task.cancel()
        let id = conversation.id
        let task = Task { [weak self] in
            try? await Task.sleep(for: Self.systemPromptSaveDelay)
            guard !Task.isCancelled else { return }
            self?.flushPendingEdits()
        }
        pendingPromptSave = (id, task)
    }

    /// Writes any debounced edit now. Safe to call repeatedly.
    func flushPendingEdits() {
        guard let pending = pendingPromptSave else { return }
        pendingPromptSave = nil
        pending.task.cancel()
        persistMeta(pending.conversationID)
    }

    func sendMessage(
        _ text: String,
        modelId: String,
        settings: GenerationSettings = .default,
        parts: [MessageContentPart]? = nil
    ) {
        _ = startDirectMessage(text, modelId: modelId, settings: settings, appendUser: true, parts: parts)
    }

    private func startDirectMessage(
        _ text: String,
        modelId: String,
        settings: GenerationSettings,
        appendUser: Bool,
        replacingAssistant: ChatMessage? = nil,
        parts: [MessageContentPart]? = nil
    ) -> PlaygroundRunContext? {
        guard !isStreaming else { lastError = "A generation is already running."; return nil }
        guard let apiKey = apiKeyProvider(), !apiKey.isEmpty else {
            lastError = "No API key configured. Go to Account to add one."
            return nil
        }
        ModelRecentsStore().record(modelId)
        flushPendingEdits()
        prepareActiveConversation(modelId: modelId, mode: .chat)
        guard let conversationID = activeConversation?.id,
              let conversationIndex = conversations.firstIndex(where: { $0.id == conversationID }) else { return nil }

        if appendUser {
            let userMessage: ChatMessage
            if let parts, !parts.isEmpty {
                userMessage = ChatMessage(role: "user", content: text, parts: parts)
            } else {
                userMessage = ChatMessage(role: "user", content: text)
            }
            conversations[conversationIndex].messages.append(userMessage)
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
        messages += Self.wireHistory(Array(conversation.messages.dropLast())).map { wireMessage(for: $0) }

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
        runInsertedMessageIDs = []
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
        // Structured reasoning blocks (F07): kept separately from the visible
        // `reasoning` summary so opaque payloads persist for wire fidelity.
        var reasoningDetailBlocks: [ReasoningDetail] = []
        var streamedImages: [ChatImageAttachment] = []
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
        let detailCoalescer = StreamPublishCoalescer<[ReasoningDetail]>(
            interval: Self.streamFrameInterval,
            characterBackstop: Self.streamFlushCharacters
        ) { [weak self] details in
            self?.publishReasoningDetails(details, context: context)
        }
        do {
            let stream = try await StreamArrivalRelay.stream(client, request)
            try Task.checkCancellation()
            guard owns(context.runID) else { return }
            runState.phase = .streaming
            activityLabel = "Streaming…"
            var lastArrival = Date()
            for try await timed in stream {
                try Task.checkCancellation()
                guard owns(context.runID) else { return }
                let event = timed.event
                lastArrival = timed.arrivedAt
                switch event {
                case .contentDelta(let choice, let text) where choice == 0:
                    if !text.isEmpty { freezeReasoningDuration(context, at: timed.arrivedAt) }
                    reasoningCoalescer.flush()
                    fullContent += text
                    contentCoalescer.submit(fullContent, addedCharacters: text.count)
                case .reasoningDelta(let choice, let text) where choice == 0:
                    if !text.isEmpty { markReasoningStarted(context, at: timed.arrivedAt) }
                    contentCoalescer.flush()
                    reasoningContent += text
                    reasoningCoalescer.submit(reasoningContent, addedCharacters: text.count)
                case .reasoningDetails(let choice, let details) where choice == 0:
                    reasoningDetailBlocks += details
                    detailCoalescer.submit(reasoningDetailBlocks, addedCharacters: details.count)
                case .imageDelta(let choice, let imageURL) where choice == 0:
                    // Dedupe: some providers re-emit the same image URL.
                    if !streamedImages.contains(where: { $0.dataURL == imageURL }) {
                        streamedImages.append(ChatImageAttachment(dataURL: imageURL))
                        _ = mutateMessage(context, mutation: { $0.images = streamedImages })
                        synchronizeActive(context.conversationID)
                        checkpoint(context)
                    }
                case .usage(let usage): latestUsage = usage
                case .finishReason(let choice, let reason) where choice == 0: finishReason = reason
                case .apiError(let error):
                    contentCoalescer.flush()
                    reasoningCoalescer.flush()
                    detailCoalescer.flush()
                    if fullContent.isEmpty, restoreRegeneration(context, message: error.message) { return }
                    fail(context: context, message: error.message, status: .failed, finishReason: finishReason, usage: latestUsage)
                    return
                default: break
                }
            }
            freezeReasoningDuration(context, at: lastArrival)
            contentCoalescer.flush()
            reasoningCoalescer.flush()
            detailCoalescer.flush()
            guard owns(context.runID) else { return }
            // Image-only turns (image-output models) are complete even with
            // no text — the images are the answer.
            if fullContent.isEmpty, !streamedImages.isEmpty {
                finish(context: context, status: .complete, finishReason: finishReason, usage: latestUsage)
            } else if fullContent.isEmpty {
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
            detailCoalescer.flush()
            if fullContent.isEmpty, restoreRegeneration(context, message: "Regeneration was cancelled.") { return }
            finish(context: context, status: .interrupted, finishReason: "cancelled", usage: latestUsage)
        } catch {
            guard owns(context.runID) else { return }
            contentCoalescer.flush()
            reasoningCoalescer.flush()
            detailCoalescer.flush()
            if fullContent.isEmpty, restoreRegeneration(context, message: error.localizedDescription) { return }
            fail(context: context, message: error.localizedDescription, status: .interrupted, finishReason: finishReason, usage: latestUsage)
        }
    }

    /// Publishes streamed content. Publishes are already coalesced to frame
    /// cadence upstream (`streamFrameInterval` + `streamFlushCharacters`), so
    /// this stays a direct write: any extra gating here would hold visible
    /// text back and read as "not streaming".
    ///
    /// Checkpointing (SQLite writes) is NOT done here — it stays on its own
    /// 750ms timer via `checkpoint(context)`, because a disk write per frame
    /// janked layout on longer answers.
    private func publish(content: String, context: PlaygroundRunContext) {
        guard owns(context.runID), mutateMessage(context, mutation: { message in
            let delta = String(content.dropFirst(message.content.count))
            message.recordTranscript(.text, text: delta)
            message.content = content
        }) else { return }
        streamingContent = content
        contentPublishCount += 1
        synchronizeActive(context.conversationID)
        checkpoint(context)
    }

    /// Track only active reasoning segments, not time spent showing an answer
    /// or using tools between Agent turns. Each boundary publishes once, while
    /// the many deltas inside a segment remain coalesced by the frame timer.
    ///
    /// Boundaries are stamped with the event's network arrival time, not the
    /// moment the main actor got around to processing it: a busy main actor
    /// drains queued events back to back and would otherwise collapse a long
    /// thinking phase into milliseconds.
    private func markReasoningStarted(_ context: PlaygroundRunContext, at instant: Date = Date()) {
        guard owns(context.runID), reasoningActiveRunID != context.runID else { return }
        reasoningActiveRunID = context.runID
        _ = mutateMessage(context) { message in
            message.reasoningStartedAt = instant
        }
    }

    private func freezeReasoningDuration(_ context: PlaygroundRunContext, at instant: Date = Date()) {
        guard owns(context.runID), reasoningActiveRunID == context.runID else { return }
        reasoningActiveRunID = nil
        _ = mutateMessage(context) { message in
            guard let start = message.reasoningStartedAt else { return }
            message.reasoningDuration = (message.reasoningDuration ?? 0)
                + max(0, instant.timeIntervalSince(start))
        }
    }

    /// Publishes streamed chain-of-thought. Kept separate from `publish` so
    /// reasoning never triggers a SQLite checkpoint — it can be very large and
    /// is not worth persisting on every frame.
    private func publishReasoning(_ reasoning: String, context: PlaygroundRunContext) {
        guard owns(context.runID) else { return }
        _ = mutateMessage(context, mutation: { message in
            let delta = String(reasoning.dropFirst((message.reasoning ?? "").count))
            message.recordTranscript(.reasoning, text: delta)
            message.reasoning = reasoning
        })
        synchronizeActive(context.conversationID)
    }

    /// Opaque reasoning blocks are wire state, not visible text. Coalesce their
    /// model writes alongside display reasoning so dense detail streams cannot
    /// invalidate the full conversation once per token.
    private func publishReasoningDetails(_ details: [ReasoningDetail], context: PlaygroundRunContext) {
        guard owns(context.runID) else { return }
        _ = mutateMessage(context, mutation: { $0.reasoningDetails = details })
    }

    private func finish(
        context: PlaygroundRunContext,
        status: ChatMessageStatus,
        finishReason: String?,
        usage: ChatUsage?
    ) {
        guard owns(context.runID) else { return }
        freezeReasoningDuration(context)
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
        freezeReasoningDuration(context)
        _ = mutateMessage(context, mutation: {
            $0.status = status
            $0.finishReason = finishReason
            $0.errorMessage = message
        })
        lastError = message
        lastErrorConversationID = context.conversationID
        apply(usage: usage, to: context)
        runState.phase = status == .failed ? .failed(message) : .interrupted(message)
        terminalCleanup(context)
    }

    @discardableResult
    private func restoreRegeneration(_ context: PlaygroundRunContext, message: String) -> Bool {
        guard let backup = regenerationBackups.removeValue(forKey: context.runID),
              mutateMessage(context, mutation: { $0 = backup }) else { return false }
        lastError = message
        lastErrorConversationID = context.conversationID
        runState.phase = .failed(message)
        terminalCleanup(context)
        return true
    }

    private func apply(usage: ChatUsage?, to context: PlaygroundRunContext) {
        guard let usage, let index = conversations.firstIndex(where: { $0.id == context.conversationID }) else { return }
        lastUsage = usage
        UsageLedger.shared.record(context.mode == .agent ? .agent : .chat,
                                  model: conversations[index].modelId, usage: usage,
                                  eventID: context.runID.uuidString)
        conversations[index].totalCost += usage.cost ?? 0
        conversations[index].totalTokens += usage.totalTokens ?? 0
        let elapsed = max(Date().timeIntervalSince(context.startedAt), 0.001)
        if let completion = usage.completionTokens {
            tokensPerSecond = Double(completion) / elapsed
        }
        if let messageIndex = conversations[index].messages.firstIndex(where: { $0.id == context.assistantMessageID }) {
            conversations[index].messages[messageIndex].usage = MessageUsage(usage, elapsed: elapsed)
            synchronizeActive(context.conversationID)
        }
    }

    /// Crash-safety snapshot while a run streams: upserts the conversation row
    /// and only the rows this run touches (assistant + inserted tool results).
    /// The full record is written once at start and once at terminal cleanup.
    private func checkpoint(_ context: PlaygroundRunContext, force: Bool = false) {
        guard owns(context.runID) else { return }
        let now = ContinuousClock.now
        if !force, let lastCheckpoint,
           lastCheckpoint.duration(to: now) < Self.streamCheckpointInterval { return }
        guard let conversation = conversations.first(where: { $0.id == context.conversationID }) else { return }
        do {
            try store.saveMessages(
                runInsertedMessageIDs.union([context.assistantMessageID]),
                of: .init(conversation: conversation, agentHistory: agentHistories[context.conversationID] ?? [])
            )
        } catch {
            lastError = "Could not save conversation: \(error.localizedDescription)"
        }
        lastCheckpoint = now
    }

    private func terminalCleanup(_ context: PlaygroundRunContext) {
        denyPendingApprovals()
        reasoningActiveRunID = nil
        regenerationBackups[context.runID] = nil
        agentContentCoalescer?.cancel()
        agentReasoningCoalescer?.cancel()
        agentDetailCoalescer?.cancel()
        agentToolPreviewCoalescer?.cancel()
        agentContentCoalescer = nil
        agentReasoningCoalescer = nil
        agentDetailCoalescer = nil
        agentToolPreviewCoalescer = nil
        agentToolPreviews.removeAll()
        synchronizeActive(context.conversationID)
        persist(context.conversationID)
        streamingContent = ""
        activityLabel = ""
        streamTask = nil
        StudioNotifier.shared.finished(
            section: context.mode.rawValue,
            title: "\(context.mode.rawValue) finished",
            body: conversations.first(where: { $0.id == context.conversationID })?.title ?? "Your run is complete.")
    }

    private func installApprovalHandler() {
        let presenter = approvalPresenter
        let approvals = approvals
        Task {
            await approvals.setHandler { request in
                await presenter.present(request)
            }
        }
    }

    /// A cancelled or finished run never leaves a prompt behind, and a cancelled prompt is a denial.
    private func denyPendingApprovals() {
        approvalPresenter.denyAll()
        let approvals = approvals
        Task {
            await approvals.cancelPending()
            // "Approve for this run" never outlives the run.
            await approvals.revokeSessionApprovals()
        }
    }

    func stopStreaming() {
        guard let context = runState.context, runState.isActive else { return }
        runState.phase = .stopping
        activityLabel = "Stopping…"
        denyPendingApprovals()
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
        fullComputerAccess: Bool,
        settings: GenerationSettings = .agentDefault
    ) async {
        guard !isStreaming else { lastError = "A generation is already running."; return }
        guard let apiKey = apiKeyProvider(), !apiKey.isEmpty else {
            lastError = "Add your OpenRouter API key in Settings → Accounts & Keys before using Agent mode."
            return
        }
        ModelRecentsStore().record(modelId)
        flushPendingEdits()
        prepareActiveConversation(modelId: modelId, mode: .agent)
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
        agentNeedsTurnSeparator = false
        agentReasoningContent = ""
        agentReasoningDetails = []
        agentCumulativeUsage = nil
        agentToolPreviews = []
        lastCheckpoint = nil
        runInsertedMessageIDs = []
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
        agentDetailCoalescer = StreamPublishCoalescer<[ReasoningDetail]>(
            interval: Self.streamFrameInterval,
            characterBackstop: Self.streamFlushCharacters
        ) { [weak self] details in
            self?.publishReasoningDetails(details, context: context)
        }
        agentToolPreviewCoalescer = StreamPublishCoalescer<[AssembledAgentToolCall]>(
            interval: Self.streamFrameInterval,
            characterBackstop: Self.streamFlushCharacters
        ) { [weak self] calls in
            self?.publishAgentToolPreviews(calls, context: context)
        }
        let history = agentHistories[conversationID] ?? []
        let customPrompt = conversations[index].systemPrompt
        let policy = ToolPolicy.agentSession(fullComputerAccess: fullComputerAccess, mcpServers: mcpServerProvider())
        lastAgentPolicy = policy
        streamTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await NativeAgentRunner.run(
                    prompt: text, modelId: modelId, apiKey: apiKey, workspace: workspace,
                    fullComputerAccess: fullComputerAccess, history: history,
                    systemPromptOverride: customPrompt.isEmpty ? nil : customPrompt,
                    client: self.client,
                    maximumTurns: self.agentMaximumTurns,
                    policy: policy,
                    approvals: OPMode.approvals(self.approvals),
                    settings: settings,
                    onEvent: { event in
                        let arrival = NativeAgentRunner.eventArrival ?? Date()
                        await self.receiveAgent(event, context: context, at: arrival)
                    }
                )
                guard self.owns(context.runID) else { return }
                self.flushAgentStreams()
                // Note a force-summarized run so the user knows the answer was
                // capped rather than naturally concluded.
                // Preserve text the user already saw during earlier tool turns;
                // replacing it with only the final turn makes prose disappear.
                let visibleResponse = self.agentPendingContent.hasSuffix(result.response)
                    ? self.agentPendingContent
                    : (self.agentPendingContent.isEmpty ? result.response : self.agentPendingContent + "\n\n" + result.response)
                let body = result.hitToolBudget
                    ? visibleResponse + "\n\n---\n_Note: this run reached its tool-call budget, so the summary above may be incomplete._"
                    : visibleResponse
                _ = self.mutateMessage(context, mutation: { message in
                    message.recordTranscript(.text, text: String(body.dropFirst(message.content.count)))
                    message.content = body
                })
                self.synchronizeActive(context.conversationID)
                self.agentHistories[conversationID] = result.history
                self.finish(
                    context: context,
                    status: result.finishReason == "length" ? .truncated : .complete,
                    finishReason: result.finishReason ?? "stop",
                    usage: result.usage
                )
            } catch is CancellationError {
                guard self.owns(context.runID) else { return }
                self.flushAgentStreams()
                self.rebuildAgentHistory(for: context.conversationID)
                self.finish(context: context, status: .interrupted, finishReason: "cancelled", usage: self.agentCumulativeUsage)
            } catch {
                guard self.owns(context.runID) else { return }
                self.flushAgentStreams()
                self.rebuildAgentHistory(for: context.conversationID)
                self.fail(context: context, message: error.localizedDescription, status: .failed, finishReason: nil, usage: self.agentCumulativeUsage)
            }
        }
    }

    private func receiveAgent(_ event: NativeAgentEvent, context: PlaygroundRunContext, at arrival: Date = Date()) {
        guard owns(context.runID), !Task.isCancelled else { return }
        switch event {
        case .usage(_, let cumulative):
            agentCumulativeUsage = cumulative
        case .modelTurnStarted:
            flushAgentStreams()
            freezeReasoningDuration(context, at: arrival)
            agentToolPreviewCoalescer?.flush()
            agentToolPreviews.removeAll(keepingCapacity: true)
            agentNeedsTurnSeparator = !agentPendingContent.isEmpty
            if runState.phase != .connecting { runState.phase = .connecting }
            activityLabel = "Thinking…"
        case .textDelta(let text):
            agentReasoningCoalescer?.flush()
            agentToolPreviewCoalescer?.flush()
            if !text.isEmpty { freezeReasoningDuration(context, at: arrival) }
            var addedCharacters = text.count
            if agentNeedsTurnSeparator && !text.isEmpty {
                agentPendingContent += "\n\n"
                agentNeedsTurnSeparator = false
                addedCharacters += 2
            }
            agentPendingContent += text
            agentContentCoalescer?.submit(agentPendingContent, addedCharacters: addedCharacters)
            if !text.isEmpty, activityLabel != "Writing response…" { activityLabel = "Writing response…" }
            if runState.phase != .streaming { runState.phase = .streaming }
        case .reasoningDelta(let text):
            agentContentCoalescer?.flush()
            agentToolPreviewCoalescer?.flush()
            if !text.isEmpty { markReasoningStarted(context, at: arrival) }
            agentReasoningContent += text
            agentReasoningCoalescer?.submit(agentReasoningContent, addedCharacters: text.count)
            if !text.isEmpty, activityLabel != "Thinking…" { activityLabel = "Thinking…" }
            if runState.phase != .streaming { runState.phase = .streaming }
        case .reasoningDetails(let details):
            agentReasoningDetails += details
            agentDetailCoalescer?.submit(agentReasoningDetails, addedCharacters: details.count)
        case .toolCallUpdated(let call):
            agentContentCoalescer?.flush()
            agentReasoningCoalescer?.flush()
            freezeReasoningDuration(context, at: arrival)
            let addedCharacters: Int
            if let index = agentToolPreviews.firstIndex(where: { $0.id == call.id }) {
                let previous = agentToolPreviews[index]
                addedCharacters = max(0, call.arguments.count - previous.arguments.count)
                    + max(0, call.name.count - previous.name.count)
                agentToolPreviews[index] = call
            } else {
                addedCharacters = call.arguments.count + call.name.count
                agentToolPreviews.append(call)
            }
            agentToolPreviewCoalescer?.submit(agentToolPreviews, addedCharacters: addedCharacters)
        case .toolExecutionStarted(let call):
            agentToolPreviewCoalescer?.flush()
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
            agentToolPreviewCoalescer?.flush()
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
            activityLabel = "Tool complete · continuing…"
        case .turnFinished:
            flushAgentStreams()
            freezeReasoningDuration(context, at: arrival)
            agentToolPreviewCoalescer?.flush()
        case .finalizing:
            flushAgentStreams()
            freezeReasoningDuration(context, at: arrival)
            // This tool-free summary starts a new model turn without
            // .modelTurnStarted; keep earlier visible prose as its own block.
            agentNeedsTurnSeparator = !agentPendingContent.isEmpty
            if runState.phase != .streaming { runState.phase = .streaming }
            activityLabel = "Wrapping up — summarizing results…"
        case .retrying(let label):
            flushAgentStreams()
            activityLabel = label
            if runState.phase != .connecting { runState.phase = .connecting }
        default: break
        }
    }

    private func publishAgentToolPreviews(_ previews: [AssembledAgentToolCall], context: PlaygroundRunContext) {
        guard owns(context.runID), !previews.isEmpty else { return }
        _ = mutateMessage(context) { message in
            var cards = message.toolCalls ?? []
            for call in previews {
                message.recordTranscriptTool(call.id)
                if let index = cards.firstIndex(where: { $0.id == call.id }) {
                    // Updating arguments must not erase execution/result state.
                    cards[index].name = call.name
                    cards[index].arguments = call.arguments
                    cards[index].argumentsSummary = String(call.arguments.prefix(200))
                } else {
                    cards.append(.init(
                        id: call.id, name: call.name,
                        argumentsSummary: String(call.arguments.prefix(200)),
                        arguments: call.arguments
                    ))
                }
            }
            message.toolCalls = cards
        }
        synchronizeActive(context.conversationID)
        if let last = previews.last { activityLabel = "Calling \(last.name)…" }
    }

    private func publishAgentContent(_ content: String, context: PlaygroundRunContext) {
        guard owns(context.runID) else { return }
        _ = mutateMessage(context, mutation: { message in
            let delta = String(content.dropFirst(message.content.count))
            message.recordTranscript(.text, text: delta)
            message.content = content
        })
        streamingContent = content
        contentPublishCount += 1
        synchronizeActive(context.conversationID)
        checkpoint(context)
    }

    private func flushAgentStreams() {
        agentContentCoalescer?.flush()
        agentReasoningCoalescer?.flush()
        agentDetailCoalescer?.flush()
        agentToolPreviewCoalescer?.flush()
    }

    func exportActiveConversation() -> String? {
        guard let conversation = activeConversation else { return nil }
        return DatabaseManager.shared.exportConversationMarkdown(conversation)
    }

    /// Chat replay history. Failed or empty assistant turns are display-only:
    /// strict providers reject an empty assistant message, and a failed
    /// partial answer is not something the model actually said. Image-only
    /// replies are skipped too: they would replay as an empty string.
    static func wireHistory(_ messages: [ChatMessage]) -> [ChatMessage] {
        var result: [ChatMessage] = []
        for message in messages {
            switch message.role {
            case "assistant":
                guard Self.isReplayableAssistant(message) else { continue }
                result.append(message)
            case "user":
                result.append(message)
            default:
                continue
            }
        }
        return result
    }

    static func isReplayableAssistant(_ message: ChatMessage) -> Bool {
        guard message.role == "assistant" else { return false }
        if message.status == .failed || message.status == .streaming { return false }
        return !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
        runInsertedMessageIDs.insert(message.id)
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
                history.append(wireMessage(for: message))
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
                // Reasoning blocks are stored per *message* (merged across every
                // model turn of the run), so replaying them here would splice
                // unrelated, partly unsigned blocks into one turn and the
                // provider answers HTTP 400. They are a continuity hint only.
                history.append(.init(
                    role: "assistant",
                    content: nil,
                    toolCalls: apiCalls
                ))
                for call in pairedCalls {
                    guard let result = toolResults[call.id] else { continue }
                    history.append(.init(role: "tool", content: result.content, toolCallId: call.id, name: call.name))
                }
            }
            if !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, message.status != .failed {
                history.append(.init(
                    role: "assistant",
                    content: message.content
                ))
            }
        }
        agentHistories[conversationID] = history
    }

    private func persist(_ conversationID: UUID) {
        if pendingPromptSave?.conversationID == conversationID {
            pendingPromptSave?.task.cancel()
            pendingPromptSave = nil
        }
        do { try saveRecord(conversationID) }
        catch { lastError = "Could not save conversation: \(error.localizedDescription)" }
    }

    /// Conversation row only (title/model/prompt/totals) — no message rows.
    private func persistMeta(_ conversationID: UUID) {
        guard let conversation = conversations.first(where: { $0.id == conversationID }) else { return }
        do { try store.saveConversationMeta(.init(conversation: conversation, agentHistory: agentHistories[conversationID] ?? [])) }
        catch { lastError = "Could not save conversation: \(error.localizedDescription)" }
    }

    private func saveRecord(_ conversationID: UUID) throws {
        guard let conversation = conversations.first(where: { $0.id == conversationID }) else { return }
        try store.saveRecord(.init(conversation: conversation, agentHistory: agentHistories[conversationID] ?? []))
    }

    func formattedCost(_ cost: Double) -> String {
        cost < 0.01 ? String(format: "$%.4f", cost) : String(format: "$%.2f", cost)
    }

    // MARK: - Multimodal wire mapping

    /// Maps a UI `ChatMessage` to its wire form. Messages carrying attachment
    /// parts encode as a content-part array (text first, then attachments);
    /// plain messages stay strings so provider cache keys don't churn.
    private func wireMessage(for message: ChatMessage) -> AgentAPIMessage {
        if let parts = message.parts, !parts.isEmpty {
            var all: [MessageContentPart] = []
            if !message.content.isEmpty { all.append(.textPart(message.content)) }
            all += parts
            return .init(role: message.role, parts: all)
        }
        // Reasoning details ride along so chat continuation keeps the same
        // wire state the agent loop does (F07).
        return .init(role: message.role, content: message.content, reasoningDetails: message.reasoningDetails)
    }
}
