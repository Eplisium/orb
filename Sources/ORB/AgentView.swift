import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A polished native agent playground — ORB's own function-calling
/// agent that can browse the web, work with files, run commands, automate Mac
/// apps, and control the computer. Completely separate from Chat.
struct AgentView: View {
    @AppStorage(OPMode.key) private var opMode = false
    @ObservedObject var viewModel: BrowserViewModel
    @ObservedObject var chatService: ChatService

    // Composer drafts and edit state live in the app-lifetime StudioStore:
    // leaving the section rebuilds ContentView, which would otherwise destroy
    // a half-written message, its attachments, and any in-progress edit.
    @StudioState("AgentView.messageText") private var messageText = ""
    @State private var isSelectingSessions = false
    @State private var sessionQuery = ""
    @State private var unread = UnreadTracker()
    @AppStorage("playground.requireCommandToSend") private var requireCommandToSend = false
    @StudioState("AgentView.undoSnapshot") private var undoSnapshot: UndoToastItem<[StoredConversation]>? = nil
    /// The edit in progress. Nothing is removed until it is sent, so it has
    /// no timer: it lasts until Send or Cancel Edit.
    @StudioState("AgentView.pendingEdit") private var pendingEdit: ChatService.ConversationEdit? = nil
    @State private var dropTargeted = false
    @StateObject private var pins = ConversationPinStore(key: "orb.pinned.agent")
    @State private var selectedSessionIDs = Set<UUID>()
    @State private var selectedModelId = ""
    @AppStorage(PlaygroundModelDefaults.agentKey) private var defaultModelId = ""
    @AppStorage("playground.agentFullComputerAccess") private var fullComputerAccess = false
    /// Sampling for Agent runs. Unset = provider default (nothing sent).
    @AppStorage("playground.agentTemperatureSet") private var agentTemperatureSet = false
    @AppStorage("playground.agentTemperature") private var agentTemperature = 0.7
    @AppStorage("playground.agentReasoningEffort") private var agentReasoningEffort = ""
    @AppStorage("playground.agentWorkspace") private var workspace = FileManager.default.homeDirectoryForCurrentUser.path
    @StudioState("AgentView.attachments") private var attachments: [URL] = []
    @State private var isPreparingAttachments = false
    @StudioState("AgentView.attachmentWarnings") private var attachmentWarnings: [String] = []
    @StudioState("AgentView.attachmentContextSummary") private var attachmentContextSummary: String? = nil
    @State private var showSettings = false
    @State private var showMCPSettings = false
    @State private var showModelPicker = false
    @State private var modelSearchText = ""
    @State private var toolCapableOnly = true
    @State private var followsLatest = true
    /// Latest sentinel maxY in the scroll coordinate space. Updated by
    /// onPreferenceChange; read by the scroll decision in onChange.
    @State private var bottomOffset: CGFloat = .infinity
    @State private var scrollIntent = MessageScrollIntent()
    @State private var pendingFollowScroll: Task<Void, Never>?
    /// Throttle gate: last time we issued a programmatic scroll. Prevents
    /// stacking scroll requests faster than ~30fps.
    @State private var lastScrollRequest: ContinuousClock.Instant?
    @FocusState private var inputFocused: Bool
    @State private var searchFocusRequest = 0
    @State private var pasteMonitor = ComposerPasteMonitor()

    private let accent = PlaygroundTheme.agentAccent

    var body: some View {
        HStack(spacing: 0) {
            conversationSidebar
            Rectangle()
                .fill(.orbSurface(0.07))
                .frame(width: 1)
            mainArea
        }
        .background(playgroundBackground)
        .focusedSceneValue(\.conversationActions, conversationActions)
        .onAppear {
            pasteMonitor.install(
                isActive: { inputFocused && !chatService.isStreaming },
                onAttach: { urls in attachPasted(urls) },
                onError: { chatService.lastError = $0 }
            )
        }
        .onDisappear { pasteMonitor.remove() }
        .task {
            chatService.activateConversation(for: .agent)
            if activeEdit == nil { pendingEdit = nil }
            selectedModelId = PlaygroundModelDefaults.initialSelection(
                activeModelId: chatService.activeConversation?.modelId,
                preferredModelId: preferredModelId
            )
            viewModel.loadFavorites()
            inputFocused = true
        }
        .onChange(of: selectedModelId) { _, newValue in
            if !attachments.isEmpty { refreshAttachmentDiagnostics() }
            // A picker change switches this session's model in place.
            if let id = chatService.activeConversation?.id, !newValue.isEmpty {
                chatService.switchModel(newValue, for: id)
            }
        }
        .onChange(of: chatService.activeConversation?.id) { _, _ in
            resetFollowState()
            // An edit belongs to one conversation; leaving it ends the edit
            // (nothing was removed, so nothing needs restoring).
            if activeEdit == nil { pendingEdit = nil }
            // Session switches (sidebar select, delete, branch, activate) must
            // bring the composer's model along; otherwise the next send hands
            // the stale model to prepareActiveConversation, which overwrites
            // the newly active conversation's model with it.
            if let modelId = chatService.activeConversation?.modelId { selectedModelId = modelId }
        }
        .onChange(of: sessionQuery) { _, _ in
            // Selection only ever covers what the filter shows: a hidden
            // session must not ride along into Select All or bulk delete.
            selectedSessionIDs.formIntersection(visibleSessionIDs)
        }
    }

    // MARK: - Layout

    private var mainArea: some View {
        VStack(spacing: 0) {
            agentHeader
            Rectangle()
                .fill(.orbSurface(0.07))
                .frame(height: 1)
            if let error = chatService.lastError,
               chatService.lastErrorConversationID == nil || chatService.lastErrorConversationID == chatService.activeConversation?.id {
                PlaygroundErrorBanner(message: error) { chatService.lastError = nil }
            }
            if let conversation = chatService.activeConversation,
               chatService.isRunning(conversationID: conversation.id),
               let context = chatService.runState.context {
                AgentRunStatusStrip(
                    messages: conversation.messages,
                    startedAt: context.startedAt,
                    phaseText: { if case .executingTool = chatService.runState.phase { return "Running tool" } else { return "Agent working" } }(),
                    cancel: { chatService.stopStreaming() }
                )
            }
            messageArea
            composer
        }
        .inspector(isPresented: $showSettings) { settingsPopover.inspectorColumnWidth(min: 280, ideal: 320, max: 420) }
        .modifier(ApprovalSheetModifier(presenter: chatService.approvalPresenter))
        .overlay(alignment: .bottom) {
            if let toast = undoSnapshot {
                UndoToastView(
                    message: UndoToast.message(deleted: toast.payload.count),
                    token: toast.id,
                    undo: { chatService.restore(toast.payload); undoSnapshot = nil },
                    dismiss: { undoSnapshot = nil }
                )
                .padding(.bottom, 80)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    private var playgroundBackground: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            RadialGradient(
                colors: [accent.opacity(0.10), .clear],
                center: .topTrailing,
                startRadius: 20,
                endRadius: 620
            )
        }
        .ignoresSafeArea()
    }

    // MARK: - Sidebar

    private var conversationSidebar: some View {
        VStack(spacing: 0) {
            ConversationSidebarHeader(
                title: "Agent",
                subtitle: "Tool-using agent",
                icon: "wand.and.stars",
                accent: accent,
                onNew: { newConversation() },
                newLabel: "New Agent Session",
                newIcon: "wand.and.stars",
                disabled: chatService.isStreaming,
                isSelecting: isSelectingSessions,
                canSelect: chatService.conversations.contains { $0.mode == .agent },
                onToggleSelecting: {
                    isSelectingSessions.toggle()
                    selectedSessionIDs.removeAll()
                }
            )

            ConversationSearchField(text: $sessionQuery, focusRequest: searchFocusRequest)
            ConversationSectionsList(
                conversations: chatService.conversations.filter { $0.mode == .agent },
                query: $sessionQuery,
                pins: pins,
                selectedID: chatService.activeConversation?.id,
                accent: accent,
                icon: "cpu",
                isRunning: { chatService.isRunning(conversationID: $0) },
                onSelect: { conversation in
                    chatService.selectConversation(conversation)
                    selectedModelId = conversation.modelId
                },
                onDelete: { chatService.deleteConversation($0) },
                onExport: { exportConversation($0) },
                isSelecting: isSelectingSessions,
                checked: selectedSessionIDs,
                onToggleCheck: { id in
                    if selectedSessionIDs.contains(id) { selectedSessionIDs.remove(id) } else { selectedSessionIDs.insert(id) }
                }
            )

            Spacer(minLength: 0)
            if isSelectingSessions {
                let allIDs = visibleSessionIDs
                ConversationSelectionBar(
                    selectedCount: selectedSessionIDs.count,
                    totalCount: allIDs.count,
                    accent: accent,
                    onSelectAll: { selectedSessionIDs = allIDs },
                    onClear: { selectedSessionIDs.removeAll() },
                    onDelete: {
                        undoSnapshot = chatService.deleteConversationsUndoable(ids: selectedSessionIDs).map { UndoToastItem($0) }
                        selectedSessionIDs.removeAll()
                        isSelectingSessions = false
                    }
                )
            }
            ConversationSidebarFooter(
                statusColor: agentStatusColor,
                statusText: agentStatusText,
                conversation: chatService.activeConversation,
                formattedCost: chatService.formattedCost,
                tokensPerSecond: chatService.runState.context?.conversationID == chatService.activeConversation?.id ? chatService.tokensPerSecond : 0
            )
        }
        .frame(width: 224)
        .background(.ultraThinMaterial.opacity(0.72))
    }

    private func sidebarSectionHeader(title: String, icon: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .orbFont(size: 11, weight: .semibold)
                .foregroundStyle(accent)
            Text(title.uppercased())
                .orbFont(size: 11, weight: .bold)
            Text("\(count)")
                .orbFont(size: 11, weight: .bold, design: .monospaced)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(.orbSurface(0.06))
                .clipShape(Capsule())
            Spacer()
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial.opacity(0.92))
    }

    // MARK: - Header

    private var agentHeader: some View {
        HStack(spacing: 12) {
            PlaygroundHeaderTitle(title: chatService.activeConversation?.title ?? "New Agent Session",
                                  subtitle: "Powered by ORB functions", subtitleIcon: "command") { name in
                if let id = chatService.activeConversation?.id { chatService.renameConversation(id, to: name) }
            }

            Spacer(minLength: 16)

            Button {
                fullComputerAccess.toggle()
            } label: {
                HeaderPill(title: fullComputerAccess ? "Computer Access" : "Web Only",
                           systemImage: fullComputerAccess ? "desktopcomputer.and.macbook" : "network",
                           tint: fullComputerAccess ? Color.orange : Color.gray,
                           foreground: fullComputerAccess ? Color.orange : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(fullComputerAccess ? "The native agent may use local functions and control this Mac" : "Only the web fetch function is enabled")
            .disabled(chatService.isStreaming)

            if opMode {
                HeaderPill(title: "OP Mode", systemImage: "bolt.shield.fill", tint: ORBTheme.warning)
                    .help("OP Mode is on: risky tools run without asking, and the agent can inspect and manage ORB itself (sessions, usage, settings, MCP). Change it in Settings > Advanced.")
            }

            ConversationMeterView(conversation: chatService.activeConversation)

            modelPickerButton

            if let conversation = chatService.activeConversation {
                Menu {
                    Button { exportConversation(conversation) } label: { Label("Export as Markdown", systemImage: "square.and.arrow.up") }
                    Button { exportConversationJSON(conversation) } label: { Label("Export as JSON", systemImage: "curlybraces") }
                    Button { _ = chatService.duplicateConversation(conversation.id) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                        .disabled(chatService.isStreaming)
                    Divider()
                    Button(role: .destructive) {
                        undoSnapshot = chatService.deleteConversationsUndoable(ids: [conversation.id]).map { UndoToastItem($0) }
                    } label: { Label("Delete Session", systemImage: "trash") }
                        .disabled(chatService.isRunning(conversationID: conversation.id))
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .orbFont(size: 13, weight: .semibold)
                        .frame(width: 28, height: 28)
                        .background(.orbSurface(0.05))
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("More actions")
                .accessibilityLabel("More actions")
            }

            Button {
                showSettings.toggle()
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .orbFont(size: 12, weight: .semibold)
                    .frame(width: 28, height: 28)
                    .background(.orbSurface(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Session settings")
            .sheet(isPresented: $showMCPSettings) { MCPSettingsView(accent: accent, isEmbedded: false) }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
        .background(.ultraThinMaterial.opacity(0.45))
    }

    private var modelPickerButton: some View {
        Button {
            modelSearchText = ""
            showModelPicker.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "cpu")
                    .foregroundStyle(accent)
                Text(shortModelName(currentModelId))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .orbFont(size: 11, weight: .bold)
                    .foregroundStyle(.tertiary)
            }
            .orbFont(size: 11, weight: .semibold)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(.orbSurface(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .fixedSize()
        .disabled(chatService.isStreaming)
        .popover(isPresented: $showModelPicker, arrowEdge: .bottom) {
            PlaygroundModelPicker(
                models: viewModel.api.models,
                favoriteIds: viewModel.favoriteIds,
                selectedModelId: $selectedModelId,
                searchText: $modelSearchText,
                toolCapableOnly: $toolCapableOnly,
                defaultModelId: $defaultModelId,
                defaultLabel: "Agent",
                accent: accent,
                toggleFavorite: viewModel.toggleFavorite,
                dismiss: { showModelPicker = false }
            )
        }
    }

    private var settingsPopover: some View {
        ScrollView { VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "slider.horizontal.3")
                    .foregroundStyle(accent)
                Text("Agent Settings")
                    .font(.headline)
            }

            VStack(alignment: .leading, spacing: 7) {
                Text("WORKSPACE")
                    .orbFont(size: 11, weight: .bold)
                    .foregroundStyle(.secondary)
                Button(action: chooseWorkspace) {
                    HStack {
                        Image(systemName: "folder.fill")
                            .foregroundStyle(accent)
                        Text(abbreviatedWorkspace)
                            .lineLimit(1)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                    }
                    .padding(8)
                    .background(.orbSurface(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                Text("The native agent runs functions and reads project context from this folder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Toggle("Require ⌘↩ to send", isOn: $requireCommandToSend)
                .font(.caption)
                .help("When on, Return inserts a new line and ⌘↩ sends.")

            Divider()

            VStack(alignment: .leading, spacing: 7) {
                Text("SAMPLING")
                    .orbFont(size: 11, weight: .bold)
                    .foregroundStyle(.secondary)
                Toggle("Override temperature", isOn: $agentTemperatureSet)
                    .font(.caption)
                if agentTemperatureSet {
                    HStack {
                        Slider(value: $agentTemperature, in: 0...2, step: 0.05)
                        Text(String(format: "%.2f", agentTemperature)).font(.caption).monospacedDigit()
                    }
                } else {
                    Text("Model default — no temperature is sent.").font(.caption).foregroundStyle(.secondary)
                }
                Picker("Reasoning effort", selection: $agentReasoningEffort) {
                    Text("Model default").tag("")
                    ForEach(ReasoningSettings.Effort.allCases) { effort in
                        Text(effort.label).tag(effort.rawValue)
                    }
                }
                .font(.caption)
            }

            Divider()

            VStack(alignment: .leading, spacing: 7) {
                Text("SYSTEM PROMPT (OPTIONAL)")
                    .orbFont(size: 11, weight: .bold)
                    .foregroundStyle(.secondary)
                TextEditor(text: Binding(
                    get: { chatService.activeConversation?.systemPrompt ?? "" },
                    set: { value in
                        if let conversation = chatService.activeConversation {
                            chatService.updateSystemPrompt(value, for: conversation)
                        }
                    }
                ))
                .orbFont(size: 11)
                .frame(height: 80)
                .disabled(chatService.activeConversation == nil)
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.primary.opacity(0.10), lineWidth: 1)
                }
                Text("Supplements the built-in agent system prompt.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 7) {
                Text("EXTENSIONS")
                    .orbFont(size: 11, weight: .bold)
                    .foregroundStyle(.secondary)
                Button {
                    showSettings = false
                    showMCPSettings = true
                } label: {
                    HStack {
                        Image(systemName: "puzzlepiece.extension.fill")
                            .foregroundStyle(accent)
                        Text("MCP Servers")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                    }
                    .padding(8)
                    .background(.orbSurface(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                Text("Connect Model Context Protocol servers to add tools.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        }
        .padding(18)
    }

    // MARK: - Messages

    @ViewBuilder
    private var messageArea: some View {
        if let conversation = chatService.activeConversation,
           !conversation.messages.isEmpty {
            let conversationIsRunning = chatService.isRunning(conversationID: conversation.id)
            GeometryReader { viewport in
                ScrollViewReader { proxy in
                    ZStack(alignment: .bottomTrailing) {
                        ScrollView {
                            LazyVStack(spacing: 28) {
                                // Tool results are already rendered inside the
                                // assistant message's tool-call cards (each card
                                // carries its own result when expanded), so the
                                // separate role:"tool" transcript messages are
                                // hidden here to avoid showing every action twice.
                                ForEach(conversation.messages.filter { $0.role != "tool" }) { message in
                                    PlaygroundMessageView(
                                        message: message,
                                        isStreaming: chatService.isStreamingMessage(message.id, conversationID: conversation.id),
                                        assistantName: "OpenRouter Agent",
                                        accent: accent,
                                        isReasoning: chatService.isReasoningMessage(message.id, conversationID: conversation.id),
                                        onDelete: conversationIsRunning
                                            ? nil
                                            : { chatService.deleteMessage(message.id, from: conversation) },
                                        onRegenerate: regenerateAction(for: message, in: conversation, running: conversationIsRunning),
                                        onEdit: conversationIsRunning || message.role != "user"
                                            ? nil
                                            : { beginEdit(message.id, in: conversation.id) },
                                        onBranch: conversationIsRunning
                                            ? nil
                                            : { if let branch = chatService.branchConversation(from: message.id, in: conversation.id) { selectedModelId = branch.modelId } },
                                        showToolCalls: true
                                    )
                                    .equatable()
                                    .id(message.id)
                                }

                                // Always in the tree to prevent LazyVStack
                                // layout thrashing when streaming starts/stops.
                                // maxHeight: nil when running (natural height),
                                // 0 when idle (collapsed) — avoids unbounded
                                // growth that destabilizes scroll calculations.
                                activityRow(isActive: conversationIsRunning)
                                    .opacity(conversationIsRunning ? 1 : 0)
                                    .frame(maxHeight: conversationIsRunning ? nil : 0)
                                    .clipped()
                                    .allowsHitTesting(conversationIsRunning)

                                Color.clear
                                    .frame(height: 1)
                                    .id("agent-message-bottom")
                                    .background {
                                        GeometryReader { bottom in
                                            Color.clear.preference(
                                                key: MessageBottomOffsetKey.self,
                                                value: bottom.frame(in: .named("agent-message-scroll")).maxY
                                            )
                                        }
                                    }
                            }
                            .frame(maxWidth: 820)
                            .padding(.horizontal, 28)
                            .padding(.vertical, 28)
                            .frame(maxWidth: .infinity)
                            .background {
                                GeometryReader { content in
                                    Color.clear.preference(
                                        key: MessageTopOffsetKey.self,
                                        value: MessageTopGeometry(
                                            top: content.frame(in: .named("agent-message-scroll")).minY,
                                            height: content.size.height
                                        )
                                    )
                                }
                            }
                        }
                        .coordinateSpace(name: "agent-message-scroll")
                        .onPreferenceChange(MessageTopOffsetKey.self) { geometry in
                            if scrollIntent.observe(
                                top: geometry.top,
                                contentHeight: geometry.height,
                                viewportHeight: viewport.size.height,
                                threshold: Self.unfollowThreshold
                            ) {
                                followsLatest = false
                                pendingFollowScroll?.cancel()
                                pendingFollowScroll = nil
                            }
                        }
                        .onPreferenceChange(MessageBottomOffsetKey.self) { bottomY in
                            bottomOffset = bottomY
                            updateFollowsLatest(viewportHeight: viewport.size.height)
                        }

                        // Offered whenever the latest message is out of view,
                        // not only while a run streams or a reply arrives.
                        if !followsLatest {
                            Button {
                                scrollIntent.reset()
                                followsLatest = true
                                withAnimation(.easeOut(duration: 0.2)) {
                                    proxy.scrollTo("agent-message-bottom", anchor: .bottom)
                                }
                            } label: {
                                Label(UnreadTracker.jumpLabel(unread: unread.unread), systemImage: "arrow.down")
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .padding(14)
                        }
                    }
                    // Watching only the last message's text missed growth from
                    // new messages, streaming tool cards, and activity-row
                    // changes — so long tool-heavy runs stopped following.
                    .onChange(of: conversation.messages.count) { _, count in
                        unread.update(messageCount: count, followsLatest: followsLatest)
                    }
                    .onChange(of: followsLatest) { _, follows in
                        unread.update(messageCount: conversation.messages.count, followsLatest: follows)
                    }
                    .onChange(of: scrollFollowKey(conversation)) { _, _ in
                        guard followsLatest else { return }
                        requestFollowScroll(proxy)
                    }
                    // Open at the latest message. The follow-scroll above
                    // only reacts to changes, so without this a reopened
                    // session showed its first message.
                    .task(id: conversation.id) { await openAtLatest(proxy) }
                    .onDisappear { pendingFollowScroll?.cancel(); pendingFollowScroll = nil }
                }
            }
        } else {
            welcomeView
        }
    }

    private var welcomeView: some View {
        PlaygroundWelcome(
            icon: "wand.and.stars.inverse",
            title: "What should we accomplish?",
            message: "ORB runs its own agent loop and native functions. It can browse the web, work with files, run commands, automate Mac apps, and control your computer.",
            pills: [
                .init(title: "Files", icon: "doc.text"),
                .init(title: "Terminal", icon: "terminal"),
                .init(title: "Web", icon: "globe"),
                .init(title: "Computer", icon: "desktopcomputer"),
            ],
            suggestions: suggestions,
            accent: accent
        ) { suggestion in
            messageText = suggestion.prompt
            inputFocused = true
        }
    }

    private func activityRow(isActive: Bool) -> some View {
        HStack(spacing: 10) {
            ActivityPulseOrb(accent: accent, isActive: isActive)
                .scaleEffect(0.5)
                .frame(width: 16, height: 16)
            HStack(spacing: 6) {
                Text(chatService.activityLabel)
                    .contentTransition(.opacity)
                if isActive {
                    TimelineView(.periodic(from: .now, by: 1)) { timeline in
                        Text("· \(elapsedText(at: timeline.date))")
                    }
                }
                if let toolCount = activeToolCount, toolCount > 0 {
                    Text("·")
                    Text("^[\(toolCount) tool call](inflect: true)")
                }
            }
            .orbFont(size: 11)
            .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .frame(maxWidth: 780, alignment: .leading)
        .animation(.easeInOut(duration: 0.2), value: chatService.activityLabel)
    }

    private func elapsedText(at date: Date) -> String {
        guard let started = chatService.runState.context?.startedAt else { return "0s" }
        let seconds = max(0, Int(date.timeIntervalSince(started)))
        return seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(seconds % 60)s"
    }

    private var activeToolCount: Int? {
        guard let conversation = chatService.activeConversation,
              let messageID = chatService.runState.context?.assistantMessageID,
              let message = conversation.messages.first(where: { $0.id == messageID }) else { return nil }
        return message.toolCalls?.count
    }

    // MARK: - Composer

    private var composer: some View {
        VStack(spacing: 8) {
            if !attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(attachments, id: \.self) { file in
                            attachmentChip(file)
                        }
                    }
                    .padding(.horizontal, 2)
                }
                if let attachmentContextSummary {
                    Text(attachmentContextSummary)
                        .orbFont(size: 11, design: .monospaced)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if !attachmentWarnings.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(attachmentWarnings, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle")
                    }
                }
                .orbFont(size: 11)
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let active = activeEdit {
                EditBanner(message: ConversationEditCopy.banner(replacing: active.replacedCount), cancel: cancelEdit)
            }

            SlashCommandMenu(entries: SlashCommand.suggestions(for: messageText)) { entry in
                messageText = "/" + entry.name + (entry.name == "clear" ? "" : " ")
            }

            VStack(spacing: 0) {
                TextField(composerPlaceholder, text: $messageText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .orbFont(size: 13)
                    .lineLimit(1...7)
                    .focused($inputFocused)
                    .composerCaretAtEnd(whenFocused: inputFocused)
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
                    .padding(.bottom, 9)
                    .composerReturnKey(requireCommand: requireCommandToSend, send: sendMessage)

                HStack(spacing: 9) {
                    Button(action: chooseAttachments) {
                        Image(systemName: "paperclip")
                            .orbFont(size: 12, weight: .semibold)
                            .frame(width: 25, height: 25)
                            .background(.orbSurface(0.05))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Attach files")
                    .disabled(chatService.isStreaming)

                    Button(action: chooseWorkspace) {
                        HStack(spacing: 5) {
                            Image(systemName: "folder")
                            Text(abbreviatedWorkspace)
                                .lineLimit(1)
                        }
                        .orbFont(size: 11, weight: .medium)
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(workspace)

                    Spacer()

                    if let gauge = contextGauge { ContextGaugeView(gauge: gauge) }

                    Text(ComposerKeyPolicy.hint(requireCommand: requireCommandToSend))
                        .orbFont(size: 11, weight: .medium)
                        .foregroundStyle(.tertiary)

                    Button(action: sendOrStop) {
                        Image(systemName: currentSessionRunning ? "stop.fill" : "arrow.up")
                            .orbFont(size: 11, weight: .bold)
                            .foregroundStyle(.white)
                            .frame(width: 28, height: 28)
                            .background(canSend || currentSessionRunning ? accent : Color.gray.opacity(0.45))
                            .clipShape(Circle())
                            .shadow(color: accent.opacity(canSend ? 0.32 : 0), radius: 5, y: 2)
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend && !currentSessionRunning)
                    .accessibilityLabel(currentSessionRunning ? "Stop Agent run" : "Send Agent message")
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 9)
            }
            .background(.regularMaterial)
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(inputFocused ? accent.opacity(0.55) : Color.primary.opacity(0.10), lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .shadow(color: .black.opacity(0.07), radius: 12, y: 4)
            .fileDropHighlight(dropTargeted, accent: accent)
            .dropDestination(for: URL.self) { urls, _ in handleDrop(urls) } isTargeted: { dropTargeted = $0 }

            Text(fullComputerAccess
                 ? "Full access is on — this app can run commands, edit files, and control this Mac."
                 : "AI can make mistakes. Review important output and actions.")
                .orbFont(size: 11)
                .foregroundStyle(fullComputerAccess ? Color.orange.opacity(0.85) : Color.secondary)
        }
        .frame(maxWidth: 820)
        .padding(.horizontal, 24)
        .padding(.bottom, 15)
        .padding(.top, 8)
        .frame(maxWidth: .infinity)
    }

    private func attachmentChip(_ file: URL) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "doc")
            Text(file.lastPathComponent).lineLimit(1)
            Button {
                attachments.removeAll { $0 == file }
                refreshAttachmentDiagnostics()
            } label: {
                Image(systemName: "xmark")
                    .orbFont(size: 11, weight: .bold)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove attachment")
        }
        .orbFont(size: 11, weight: .medium)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(accent.opacity(0.10))
        .clipShape(Capsule())
    }

    // MARK: - Actions and derived values

    private var preferredModelId: String {
        let fallback: String
        if let favorite = viewModel.api.models.first(where: { viewModel.favoriteIds.contains($0.id) && $0.supportsTools })?.id {
            fallback = favorite
        } else if let selected = viewModel.selectedModel, selected.supportsTools {
            fallback = selected.id
        } else if let toolModel = viewModel.api.models.first(where: \.supportsTools)?.id {
            fallback = toolModel
        } else {
            fallback = "openai/gpt-4o"
        }
        return PlaygroundModelDefaults.resolve(
            storedModelId: defaultModelId,
            availableModelIds: viewModel.api.models.filter(\.supportsTools).map(\.id),
            fallbackModelId: fallback
        )
    }

    private var currentModelId: String {
        selectedModelId.isEmpty ? preferredModelId : selectedModelId
    }

    /// Sessions the sidebar is currently showing (search-filtered). Select All
    /// and the selection count must match the visible list, never every stored
    /// session of the mode.
    private var visibleSessionIDs: Set<UUID> {
        Set(ConversationListModel.filter(
            chatService.conversations.filter { $0.mode == .agent },
            query: sessionQuery
        ).map(\.id))
    }

    private var currentSessionRunning: Bool {
        guard let id = chatService.activeConversation?.id else { return false }
        return chatService.isRunning(conversationID: id)
    }

    private var canSend: Bool {
        let hasText = !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasText && KeychainManager.hasAPIKey && !chatService.isStreaming && !isPreparingAttachments
    }

    private var composerPlaceholder: String {
        if !KeychainManager.hasAPIKey {
            return "Add your OpenRouter API key in Settings → Accounts & Keys…"
        }
        return "Ask the native agent to build, research, organize, or operate your Mac…"
    }

    private var abbreviatedWorkspace: String {
        workspace.replacingOccurrences(
            of: FileManager.default.homeDirectoryForCurrentUser.path,
            with: "~"
        )
    }

    private var agentStatusColor: Color {
        if chatService.isStreaming { return .orange }
        return KeychainManager.hasAPIKey ? .green : .orange
    }

    private var agentStatusText: String {
        if chatService.isStreaming {
            guard let id = chatService.activeConversation?.id,
                  chatService.isRunning(conversationID: id) else {
                return "Agent working in another session"
            }
            return "Agent working"
        }
        return KeychainManager.hasAPIKey ? "Native agent ready" : "API key needed"
    }

    private var suggestions: [PlaygroundSuggestion] {
        [
            .init(title: "Build something", subtitle: "Create and verify a working project", icon: "hammer", prompt: "Build a polished project in my current workspace and verify that it works."),
            .init(title: "Organize my Mac", subtitle: "Inspect files and clean up a folder", icon: "folder.badge.gearshape", prompt: "Help me organize the files in my current workspace. Inspect first, then propose and carry out a safe cleanup."),
            .init(title: "Research deeply", subtitle: "Browse, compare, and cite sources", icon: "globe.americas.fill", prompt: "Research a topic for me thoroughly, compare credible sources, and give me a cited brief."),
            .init(title: "Use an application", subtitle: "Operate a Mac app in the background", icon: "macwindow", prompt: "Use the appropriate Mac application to help me complete a task. Ask only if a genuinely necessary detail is missing."),
        ]
    }

    private func newConversation() {
        selectedModelId = preferredModelId
        _ = chatService.newConversation(modelId: selectedModelId, mode: .agent)
        messageText = ""
        attachments = []
        attachmentWarnings = []
        attachmentContextSummary = nil
        inputFocused = true
    }

    private func sendOrStop() {
        if currentSessionRunning { chatService.stopStreaming() } else { sendMessage() }
    }

    private var contextGauge: ContextGauge? {
        let length = viewModel.api.models.first { $0.id == currentModelId }?.contextLength
        let conversation = chatService.activeConversation
        return ContextGauge.make(
            system: conversation?.systemPrompt ?? "",
            messages: (conversation?.messages ?? []).map(\.content),
            draft: messageText,
            contextLength: length
        )
    }

    /// Handles `/model`, `/system`, `/clear`. Returns true when the text was a command.
    private func runSlashCommand(_ text: String) -> Bool {
        guard let command = SlashCommand.parse(text) else { return false }
        messageText = ""
        switch command {
        case .clear:
            newConversation()
        case .model(let query):
            modelSearchText = query ?? ""
            showModelPicker = true
        case .system(let prompt):
            if let prompt, let conversation = chatService.activeConversation {
                chatService.updateSystemPrompt(prompt, for: conversation)
            } else {
                showSettings = true
            }
        }
        return true
    }

    private func sendMessage() {
        if !currentSessionRunning, runSlashCommand(messageText) { return }
        guard canSend else {
            if !KeychainManager.hasAPIKey {
                chatService.lastError = "Add your OpenRouter API key in Settings → Accounts & Keys before using the Agent."
            }
            return
        }

        // Sending the edit is what replaces the old messages; until then the
        // edit stays cancellable, including when the attachments fail to load.
        let edit = activeEdit?.edit
        let sentText = messageText
        let basePrompt = sentText.trimmingCharacters(in: .whitespacesAndNewlines)
        let sentAttachments = attachments
        let modelId = currentModelId
        let workspace = workspace
        let fullComputerAccess = fullComputerAccess
        let settings = agentSettings
        let limits = attachmentLimits()

        isPreparingAttachments = !sentAttachments.isEmpty
        Task { @MainActor in
            defer { isPreparingAttachments = false }
            var prompt = basePrompt
            // Build a byte-bounded, explicitly untrusted attachment envelope
            // off the main actor. The draft is cleared only after it succeeds.
            if !sentAttachments.isEmpty {
                let result = await Task.detached(priority: .userInitiated) {
                    AgentAttachmentBuilder.build(urls: sentAttachments, perFileByteLimit: limits.perFile, totalByteLimit: limits.total)
                }.value
                attachmentWarnings = result.warnings
                guard !result.includedFiles.isEmpty else {
                    chatService.lastError = (result.warnings.first ?? "None of the selected attachments could be read.") + " Your message was kept."
                    return
                }
                prompt += result.promptSuffix
            }
            if messageText == sentText { messageText = "" }
            attachments.removeAll { sentAttachments.contains($0) }
            if attachments.isEmpty { attachmentContextSummary = nil }
            pendingEdit = nil
            await chatService.sendAgentMessage(
                prompt,
                modelId: modelId,
                workspace: workspace,
                fullComputerAccess: fullComputerAccess,
                settings: settings,
                replacing: edit
            )
        }
    }

    /// Agent attachments are inlined as text, so pasted images are saved and
    /// referenced by path in the prompt (the agent can open them with its
    /// image tool); pasted text files attach normally.
    private func attachPasted(_ urls: [URL]) {
        let images = urls.filter { (UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image)) == true }
        let others = urls.filter { !images.contains($0) }
        if !images.isEmpty {
            let lines = images.map { "[Pasted image: \($0.path)]" }.joined(separator: "\n")
            messageText += (messageText.isEmpty || messageText.hasSuffix("\n") ? "" : "\n") + lines
        }
        if !others.isEmpty {
            attachments.append(contentsOf: others)
            refreshAttachmentDiagnostics()
        }
    }

    private func chooseWorkspace() {
        let panel = NSOpenPanel()
        panel.title = "Choose Agent Workspace"
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: workspace)
        if panel.runModal() == .OK, let url = panel.url { workspace = url.path }
    }

    private func handleDrop(_ urls: [URL]) -> Bool {
        guard !chatService.isStreaming, !urls.isEmpty else { return false }
        attachments.append(contentsOf: urls)
        refreshAttachmentDiagnostics()
        return true
    }

    private func chooseAttachments() {
        let panel = NSOpenPanel()
        panel.title = "Attach Files for the Agent"
        panel.prompt = "Attach"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            attachments.append(contentsOf: panel.urls)
            refreshAttachmentDiagnostics()
        }
    }

    private func beginEdit(_ messageID: UUID, in conversationID: UUID) {
        // Agent attachments are inlined into the prompt text, so the edited
        // text already carries them.
        guard let edit = chatService.beginEdit(from: messageID, in: conversationID) else { return }
        pendingEdit = edit
        messageText = edit.text
        inputFocused = true
    }

    /// The edit in progress, when it belongs to the session on screen and its
    /// message still exists.
    private var activeEdit: (edit: ChatService.ConversationEdit, replacedCount: Int)? {
        guard let edit = pendingEdit, edit.conversationID == chatService.activeConversation?.id,
              let replaced = chatService.messagesReplaced(by: edit) else { return nil }
        return (edit, replaced.count)
    }

    /// Cancel Edit: the session was never changed, so this only puts the
    /// composer back. Text the user rewrote is kept as an ordinary draft.
    private func cancelEdit() {
        if let edit = pendingEdit, messageText == edit.text { messageText = "" }
        pendingEdit = nil
    }

    private var agentSettings: GenerationSettings {
        AgentSamplingPreferences(
            temperature: agentTemperatureSet ? agentTemperature : nil,
            reasoningEffort: agentReasoningEffort
        ).settings
    }

    private func attachmentLimits() -> (perFile: Int, total: Int) {
        let contextLength = viewModel.api.models.first(where: { $0.id == currentModelId })?.contextLength ?? 32_000
        return (16_000, min(80_000, max(12_000, contextLength)))
    }

    private func attachmentBuildResult() -> AgentAttachmentBuildResult {
        let limits = attachmentLimits()
        return AgentAttachmentBuilder.build(urls: attachments, perFileByteLimit: limits.perFile, totalByteLimit: limits.total)
    }

    private func refreshAttachmentDiagnostics() {
        guard !attachments.isEmpty else {
            attachmentWarnings = []
            attachmentContextSummary = nil
            return
        }
        let contextLength = viewModel.api.models.first(where: { $0.id == currentModelId })?.contextLength ?? 32_000
        let result = attachmentBuildResult()
        let estimatedTokens = max(1, (result.includedBytes + 3) / 4)
        attachmentWarnings = result.warnings
        if estimatedTokens >= (contextLength * 3) / 4 {
            attachmentWarnings.append("Attachments may consume most of this model's context window.")
        }
        attachmentContextSummary = "\(result.includedFiles.count) readable file\(result.includedFiles.count == 1 ? "" : "s") · ~\(estimatedTokens.formatted()) tokens of \(contextLength.formatted())"
    }

    /// Agent runs have side effects, so they are never silently replayed.
    private func regenerateAction(for message: ChatMessage, in conversation: ChatConversation, running: Bool) -> (() -> Void)? { nil }

    /// Menu-bar actions for this playground (Conversation menu).
    private var conversationActions: ConversationActions {
        let conversation = chatService.activeConversation
        let regenerate: (() -> Void)? = nil  // Agent runs have side effects; never replayed.
        return ConversationActions(
            stop: currentSessionRunning ? { chatService.stopStreaming() } : nil,
            regenerate: regenerate,
            copyLastReply: ConversationActionLogic.lastReply(in: conversation).map { text in
                { ConversationActionLogic.copyToPasteboard(text) }
            },
            export: conversation.map { conv in { exportConversation(conv) } },
            searchSessions: { searchFocusRequest += 1 }
        )
    }

    private func exportConversationJSON(_ conv: ChatConversation) {
        if let error = ConversationExporter.saveWithPanel(conv, as: .json) { chatService.lastError = error }
    }

    private func exportConversation(_ conv: ChatConversation) {
        if let error = ConversationExporter.saveWithPanel(conv, as: .markdown) { chatService.lastError = error }
    }

    /// Composite key covering every source of content growth during a run:
    /// message count, the streaming text, reasoning length, tool-call count
    /// on the last message, and the activity label. Any change means the view
    /// got taller.
    private func scrollFollowKey(_ conversation: ChatConversation) -> String {
        // Built in typed steps: one array literal with optional chains and a
        // reduce closure exceeds the CI compiler's type-check time limit.
        let last = conversation.messages.last
        let calls = last?.toolCalls ?? []
        var resultLength = 0
        for call in calls { resultLength += call.result?.count ?? 0 }
        let parts: [String] = [
            String(conversation.messages.count),
            String(last?.content.count ?? 0),
            String(last?.reasoning?.count ?? 0),
            String(calls.count),
            String(resultLength),
            chatService.activityLabel
        ]
        return parts.joined(separator: "|")
    }

    /// Hysteresis thresholds for follow behavior. We follow when within
    /// `followThreshold` of the bottom, but require the user to scroll up
    /// past `unfollowThreshold` before we stop following — this prevents
    /// oscillation at the boundary when a large block renders and shifts
    /// the layout by a few points.
    private static let followThreshold: CGFloat = 80
    private static let unfollowThreshold: CGFloat = 200
    /// Minimum gap between programmatic scroll requests. The eye can't tell
    /// the difference for bottom-anchored scroll at 30fps, and halving the
    /// layout pressure prevents frame drops on longer responses.
    private static let scrollThrottle: Duration = .milliseconds(33)

    /// Content growth moves the bottom sentinel without a user scroll; only
    /// the top-origin observer disengages auto-follow.
    private func updateFollowsLatest(viewportHeight: CGFloat) {
        if !followsLatest && bottomOffset - viewportHeight <= Self.followThreshold {
            followsLatest = true
            scrollIntent.reset()
        }
    }

    private func resetFollowState() {
        pendingFollowScroll?.cancel()
        pendingFollowScroll = nil
        followsLatest = true
        scrollIntent.reset()
        bottomOffset = .infinity
        lastScrollRequest = nil
    }

    /// Scrolls a just-opened session to its latest message. Lazy rows are
    /// measured only as they are realized, so the first jump can land short
    /// of the true end; the later passes settle it. They stop as soon as the
    /// user scrolls away.
    private func openAtLatest(_ proxy: ScrollViewProxy) async {
        proxy.scrollTo("agent-message-bottom", anchor: .bottom)
        for delay in [Duration.milliseconds(60), .milliseconds(240)] {
            do { try await Task.sleep(for: delay) } catch { return }
            guard followsLatest else { return }
            proxy.scrollTo("agent-message-bottom", anchor: .bottom)
        }
    }

    /// Issues a throttled, animation-free scroll-to-bottom. Animation is
    /// intentionally omitted during streaming: content is already growing
    /// at frame rate, so animating each scroll request stacks overlapping
    /// animations and can crash NSScrollView under load.
    private func requestFollowScroll(_ proxy: ScrollViewProxy) {
        let now = ContinuousClock.now
        if let last = lastScrollRequest, now - last < Self.scrollThrottle {
            guard pendingFollowScroll == nil else { return }
            let remaining = Self.scrollThrottle - (now - last)
            pendingFollowScroll = Task { @MainActor in
                do { try await Task.sleep(for: remaining) } catch { return }
                pendingFollowScroll = nil
                guard followsLatest else { return }
                lastScrollRequest = .now
                proxy.scrollTo("agent-message-bottom", anchor: .bottom)
            }
            return
        }
        lastScrollRequest = now
        proxy.scrollTo("agent-message-bottom", anchor: .bottom)
    }
}
