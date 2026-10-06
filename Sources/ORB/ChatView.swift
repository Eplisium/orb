import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A polished OpenRouter chat playground — direct model conversations with
/// streaming, temperature/max-token controls, and live cost tracking.
struct ChatView: View {
    @ObservedObject var viewModel: BrowserViewModel
    @ObservedObject var chatService: ChatService

    @State private var messageText = ""
    @State private var isSelectingSessions = false
    @State private var sessionQuery = ""
    @State private var unread = UnreadTracker()
    @AppStorage("playground.requireCommandToSend") private var requireCommandToSend = false
    @State private var undoSnapshot: [StoredConversation]?
    /// Last edit, for Undo and to carry its attachments into the resend.
    @State private var pendingEdit: ChatService.ConversationEdit?
    /// Attachments of the message being edited; resent unless removed.
    @State private var carriedParts: [MessageContentPart]?
    @State private var dropTargeted = false
    @State private var temperatureIsModelDefault = false
    @StateObject private var pins = ConversationPinStore(key: "orb.pinned.chat")
    @State private var selectedSessionIDs = Set<UUID>()
    @State private var selectedModelId = ""
    @AppStorage(PlaygroundModelDefaults.chatKey) private var defaultModelId = ""
    @State private var temperature = 0.7
    @State private var maxTokens: Double = 0
    @State private var settings = GenerationSettings.default
    @State private var showSettings = false
    @State private var showAdvancedSettings = false
    @State private var showModelPicker = false
    @State private var modelSearchText = ""
    @State private var followsLatest = true
    @State private var attachmentDrafts: [ChatAttachmentDraft] = []
    @State private var attachmentWarnings: [String] = []
    @State private var isPreparingAttachments = false
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

    private let accent = PlaygroundTheme.chatAccent

    /// Folds the two quick-access sliders into the full settings object so the
    /// simple controls and the advanced panel stay in sync.
    private var requestSettings: GenerationSettings {
        var resolved = settings
        resolved.temperature = QuickSampling(temperature: temperatureIsModelDefault ? nil : temperature).requestTemperature
        resolved.maxTokens = maxTokens > 0 ? Int(maxTokens) : nil
        return resolved
    }

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
                onAttach: { urls in _ = attachFiles(urls) },
                onError: { chatService.lastError = $0 }
            )
        }
        .onDisappear { pasteMonitor.remove() }
        .task {
            chatService.activateConversation(for: .chat)
            selectedModelId = PlaygroundModelDefaults.initialSelection(
                activeModelId: chatService.activeConversation?.modelId,
                preferredModelId: preferredModelId
            )
            viewModel.loadFavorites()
            inputFocused = true
        }
        .onChange(of: selectedModelId) { _, newValue in
            // A picker change switches this session's model in place.
            if let id = chatService.activeConversation?.id, !newValue.isEmpty {
                chatService.switchModel(newValue, for: id)
            }
        }
        .onChange(of: chatService.activeConversation?.id) { _, _ in resetFollowState() }
    }

    // MARK: - Layout

    private var mainArea: some View {
        VStack(spacing: 0) {
            chatHeader
            Rectangle()
                .fill(.orbSurface(0.07))
                .frame(height: 1)
            if let error = chatService.lastError,
               chatService.lastErrorConversationID == nil || chatService.lastErrorConversationID == chatService.activeConversation?.id {
                PlaygroundErrorBanner(message: error) { chatService.lastError = nil }
            }
            messageArea
            composer
        }
        .inspector(isPresented: $showSettings) { settingsPopover.inspectorColumnWidth(min: 280, ideal: 320, max: 420) }
        .overlay(alignment: .bottom) {
            if let snapshot = undoSnapshot {
                UndoToastView(
                    message: UndoToast.message(deleted: snapshot.count),
                    undo: { chatService.restore(snapshot); undoSnapshot = nil },
                    dismiss: { undoSnapshot = nil }
                )
                .padding(.bottom, 80)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if let edit = pendingEdit {
                UndoToastView(
                    message: UndoToast.editMessage(removed: edit.removedCount),
                    symbol: "pencil",
                    undo: { undoEdit(edit) },
                    dismiss: { pendingEdit = nil }
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
                colors: [accent.opacity(0.08), .clear],
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
                title: "Chat",
                subtitle: "Direct OpenRouter completion",
                icon: "bubble.left.fill",
                accent: accent,
                onNew: { newConversation() },
                newLabel: "New Chat",
                newIcon: "bubble.left",
                disabled: chatService.isStreaming,
                isSelecting: isSelectingSessions,
                canSelect: chatService.conversations.contains { $0.mode == .chat },
                onToggleSelecting: {
                    isSelectingSessions.toggle()
                    selectedSessionIDs.removeAll()
                }
            )

            ConversationSearchField(text: $sessionQuery, focusRequest: searchFocusRequest)
            ConversationSectionsList(
                conversations: chatService.conversations.filter { $0.mode == .chat },
                query: $sessionQuery,
                pins: pins,
                selectedID: chatService.activeConversation?.id,
                accent: accent,
                icon: "bubble.left",
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
                let allIDs = Set(chatService.conversations.filter { $0.mode == .chat }.map(\.id))
                ConversationSelectionBar(
                    selectedCount: selectedSessionIDs.count,
                    totalCount: allIDs.count,
                    accent: accent,
                    onSelectAll: { selectedSessionIDs = allIDs },
                    onClear: { selectedSessionIDs.removeAll() },
                    onDelete: {
                        undoSnapshot = chatService.deleteConversationsUndoable(ids: selectedSessionIDs)
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

    private var chatHeader: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                EditableTitle(title: chatService.activeConversation?.title ?? "New Chat") { name in
                    if let id = chatService.activeConversation?.id { chatService.renameConversation(id, to: name) }
                }
                HStack(spacing: 5) {
                    Image(systemName: "bolt.horizontal")
                    Text("Direct OpenRouter completion")
                }
                .orbFont(size: 11, weight: .medium)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 16)

            // Regenerate button
            if let conv = chatService.activeConversation,
               !chatService.isStreaming,
               conv.messages.last?.role == "assistant" {
                Button {
                    Task {
                        await chatService.regenerateLastResponse(
                            modelId: currentModelId,
                            settings: requestSettings
                        )
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                        Text("Regenerate")
                    }
                    .orbFont(size: 11, weight: .semibold)
                    .foregroundStyle(accent)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(accent.opacity(0.10))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(chatService.isStreaming)
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
                        undoSnapshot = chatService.deleteConversationsUndoable(ids: [conversation.id])
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
            .sheet(isPresented: $showAdvancedSettings) {
                AdvancedSettingsView(accent: accent, settings: $settings)
            }
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
                toolCapableOnly: nil,
                defaultModelId: $defaultModelId,
                defaultLabel: "Chat",
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
                Text("Chat Settings")
                    .font(.headline)
            }

            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text("Temperature")
                    Spacer()
                    Text(QuickSampling(temperature: temperatureIsModelDefault ? nil : temperature).display)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                PresetPicker(temperature: Binding(get: { temperature }, set: { temperature = $0; temperatureIsModelDefault = false }), accent: accent)
                Slider(value: Binding(get: { temperature }, set: { temperature = $0; temperatureIsModelDefault = false }), in: 0...2, step: 0.05)
                    .disabled(temperatureIsModelDefault)
                Toggle("Use model default (send no temperature)", isOn: $temperatureIsModelDefault)
                    .font(.caption)
                HStack {
                    Text("Max tokens")
                    Spacer()
                    Text(maxTokens == 0 ? "Auto" : "\(Int(maxTokens))")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: $maxTokens, in: 0...16384, step: 256)
                }
                .font(.subheadline)

                Toggle("Require ⌘↩ to send", isOn: $requireCommandToSend)
                .font(.caption)
                .help("When on, Return inserts a new line and ⌘↩ sends.")

            Divider()

                VStack(alignment: .leading, spacing: 7) {
                Button {
                    showSettings = false
                    showAdvancedSettings = true
                } label: {
                    HStack {
                        Label("All Parameters", systemImage: "slider.horizontal.below.rectangle")
                        Spacer()
                        if !settings.activeSummary.isEmpty {
                            Text("\(settings.activeSummary.count)")
                                .font(.caption2.monospacedDigit())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(accent.opacity(0.2), in: Capsule())
                        }
                        Image(systemName: "chevron.right").font(.caption2)
                    }
                }
                .buttonStyle(.plain)
                if !settings.activeSummary.isEmpty {
                    Text(settings.activeSummary.joined(separator: " · "))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                } else {
                    Text("Sampling, reasoning, routing, fallbacks, and web search.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                }
                .font(.subheadline)

            Divider()

            VStack(alignment: .leading, spacing: 7) {
                Text("SYSTEM PROMPT (OPTIONAL)")
                    .orbFont(size: 11, weight: .bold)
                    .foregroundStyle(.secondary)
                TextEditor(text: Binding(
                    get: { chatService.activeConversation?.systemPrompt ?? "" },
                    set: {
                        if let conv = chatService.activeConversation {
                            chatService.updateSystemPrompt($0, for: conv)
                        }
                    }
                ))
                .orbFont(size: 11)
                .frame(height: 80)
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.primary.opacity(0.10), lineWidth: 1)
                }
                Text("Prepended as a system message to every request.")
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
                                ForEach(conversation.messages) { message in
                                    PlaygroundMessageView(
                                        message: message,
                                        isStreaming: chatService.isStreamingMessage(message.id, conversationID: conversation.id),
                                        assistantName: "Assistant",
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
                                            : { if let branch = chatService.branchConversation(from: message.id, in: conversation.id) { selectedModelId = branch.modelId } }
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
                                    .id("chat-message-bottom")
                                    .background {
                                        GeometryReader { bottom in
                                            Color.clear.preference(
                                                key: MessageBottomOffsetKey.self,
                                                value: bottom.frame(in: .named("chat-message-scroll")).maxY
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
                                            top: content.frame(in: .named("chat-message-scroll")).minY,
                                            height: content.size.height
                                        )
                                    )
                                }
                            }
                        }
                        .coordinateSpace(name: "chat-message-scroll")
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

                        if !followsLatest && (conversationIsRunning || unread.unread > 0) {
                            Button {
                                scrollIntent.reset()
                                followsLatest = true
                                withAnimation(.easeOut(duration: 0.2)) {
                                    proxy.scrollTo("chat-message-bottom", anchor: .bottom)
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
                    .onDisappear { pendingFollowScroll?.cancel(); pendingFollowScroll = nil }
                }
            }
        } else {
            welcomeView
        }
    }

    private var welcomeView: some View {
        ScrollView {
            VStack(spacing: 22) {
                ZStack {
                    Circle()
                        .fill(accent.opacity(0.10))
                        .frame(width: 104, height: 104)
                    Circle()
                        .stroke(accent.opacity(0.18), lineWidth: 1)
                        .frame(width: 82, height: 82)
                    Image(systemName: "bubble.left.and.bubble.right.fill")
                        .orbFont(size: 34, weight: .medium)
                        .foregroundStyle(
                            LinearGradient(
                                colors: [accent, .blue],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }

                VStack(spacing: 8) {
                    Text("Explore any model")
                        .orbFont(size: 26, weight: .semibold, design: .rounded)
                    Text("Chat directly with any model in the OpenRouter catalog. Responses stream live with usage and cost tracking.")
                        .orbFont(size: 13)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 570)
                        .lineSpacing(3)
                }

                HStack(spacing: 8) {
                    CapabilityPill(title: "Streaming", icon: "bolt.horizontal")
                    CapabilityPill(title: "Temperature", icon: "thermometer")
                    CapabilityPill(title: "Cost Tracking", icon: "dollarsign.circle")
                    CapabilityPill(title: "Markdown", icon: "text.alignleft")
                }

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    ForEach(suggestions, id: \.title) { suggestion in
                        SuggestionCard(suggestion: suggestion, accent: accent) {
                            messageText = suggestion.prompt
                            inputFocused = true
                        }
                    }
                }
                .frame(maxWidth: 650)
            }
            .padding(.horizontal, 30)
            .padding(.top, 58)
            .padding(.bottom, 30)
            .frame(maxWidth: .infinity)
        }
    }

    private func activityRow(isActive: Bool) -> some View {
        HStack(spacing: 10) {
            ActivityPulseOrb(accent: accent, isActive: isActive)
                .scaleEffect(0.5)
                .frame(width: 16, height: 16)
            Text(chatService.activityLabel)
                .orbFont(size: 11, weight: .medium)
                .foregroundStyle(.secondary)
                .contentTransition(.opacity)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .frame(maxWidth: 780, alignment: .leading)
    }

    // MARK: - Composer

    private var composer: some View {
        VStack(spacing: 8) {
            if !attachmentDrafts.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(attachmentDrafts) { draft in
                            AttachmentDraftChip(draft: draft) {
                                attachmentDrafts.removeAll { $0.id == draft.id }
                                refreshAttachmentWarnings()
                            }
                        }
                    }
                    .padding(.horizontal, 2)
                }
            }

            if let carried = carriedParts, !carried.isEmpty {
                HStack(spacing: 6) {
                    Label("\(carried.count) attachment\(carried.count == 1 ? "" : "s") from the original message", systemImage: "paperclip")
                        .orbFont(size: 11)
                        .foregroundStyle(.secondary)
                    Button { carriedParts = nil } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Remove original attachments")
                    Spacer()
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

            SlashCommandMenu(entries: SlashCommand.suggestions(for: messageText)) { entry in
                messageText = "/" + entry.name + (entry.name == "clear" ? "" : " ")
            }

            VStack(spacing: 0) {
                TextField(composerPlaceholder, text: $messageText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .orbFont(size: 13)
                    .lineLimit(1...7)
                    .focused($inputFocused)
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
                    .padding(.bottom, 9)
                    .onSubmit { if ComposerKeyPolicy.shouldSend(command: NSEvent.modifierFlags.contains(.command), shift: NSEvent.modifierFlags.contains(.shift), requireCommand: requireCommandToSend) { sendMessage() } }

                HStack(spacing: 9) {
                    Button(action: chooseAttachments) {
                        Image(systemName: "paperclip")
                            .orbFont(size: 12, weight: .semibold)
                            .frame(width: 25, height: 25)
                            .background(.orbSurface(0.05))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Attach images, audio, video, or documents")
                    .disabled(chatService.isStreaming)

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
                    .accessibilityLabel(currentSessionRunning ? "Stop Chat response" : "Send Chat message")
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

            Text("AI can make mistakes. Review important output.")
                .orbFont(size: 11)
                .foregroundStyle(Color.secondary)
        }
        .frame(maxWidth: 820)
        .padding(.horizontal, 24)
        .padding(.bottom, 15)
        .padding(.top, 8)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Actions and derived values

    private var preferredModelId: String {
        let fallback = viewModel.selectedModel?.id ?? viewModel.api.models.first?.id ?? "openai/gpt-4o"
        return PlaygroundModelDefaults.resolve(
            storedModelId: defaultModelId,
            availableModelIds: viewModel.api.models.map(\.id),
            fallbackModelId: fallback
        )
    }

    private var currentModelId: String {
        selectedModelId.isEmpty ? preferredModelId : selectedModelId
    }

    private var currentSessionRunning: Bool {
        guard let id = chatService.activeConversation?.id else { return false }
        return chatService.isRunning(conversationID: id)
    }

    private var canSend: Bool {
        let hasText = !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return (hasText || !attachmentDrafts.isEmpty) && KeychainManager.hasAPIKey
            && !chatService.isStreaming && !isPreparingAttachments
    }

    private var composerPlaceholder: String {
        if !KeychainManager.hasAPIKey {
            return "Add your OpenRouter API key in Settings → Accounts & Keys…"
        }
        return "Message \(shortModelName(currentModelId))…"
    }

    private var agentStatusColor: Color {
        if chatService.isStreaming { return .orange }
        return KeychainManager.hasAPIKey ? .green : .orange
    }

    private var agentStatusText: String {
        if chatService.isStreaming {
            guard let id = chatService.activeConversation?.id,
                  chatService.isRunning(conversationID: id) else {
                return "Generating in another session…"
            }
            return "Generating…"
        }
        return KeychainManager.hasAPIKey ? "OpenRouter ready" : "API key needed"
    }

    private var suggestions: [PlaygroundSuggestion] {
        [
            .init(title: "Compare ideas", subtitle: "Reason through trade-offs", icon: "arrow.triangle.branch", prompt: "Help me compare two approaches and recommend the better one."),
            .init(title: "Write", subtitle: "Draft clear, polished content", icon: "pencil.line", prompt: "Help me draft a polished piece of writing."),
            .init(title: "Explain", subtitle: "Make a complex topic clear", icon: "lightbulb", prompt: "Explain a complex topic clearly with examples."),
            .init(title: "Brainstorm", subtitle: "Generate strong creative options", icon: "sparkles", prompt: "Brainstorm several creative options for me."),
        ]
    }

    private func newConversation() {
        selectedModelId = preferredModelId
        _ = chatService.newConversation(modelId: selectedModelId, mode: .chat)
        messageText = ""
        attachmentDrafts = []
        attachmentWarnings = []
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
                chatService.lastError = "Add your OpenRouter API key in Settings → Accounts & Keys before using Chat."
            }
            return
        }

        let sentText = messageText
        let prompt = sentText.trimmingCharacters(in: .whitespacesAndNewlines)
        let drafts = attachmentDrafts
        let modelId = currentModelId
        let settings = requestSettings
        let carried = carriedParts ?? []
        carriedParts = nil
        pendingEdit = nil
        guard drafts.isEmpty else {
            // Build parts first (off-main); the draft is cleared only once the
            // attachments were read, so a failed read never loses the text.
            isPreparingAttachments = true
            Task { @MainActor in
                defer { isPreparingAttachments = false }
                do {
                    let wireParts = try await ChatAttachmentBuilder.buildParts(for: drafts)
                    clearComposer(ifUnchanged: sentText, drafts: drafts)
                    chatService.sendMessage(prompt, modelId: modelId, settings: settings, parts: carried + wireParts)
                } catch {
                    if !carried.isEmpty, carriedParts == nil { carriedParts = carried }
                    chatService.lastError = "Could not read attachments: \(error.localizedDescription). Your message was kept."
                }
            }
            return
        }
        clearComposer(ifUnchanged: sentText, drafts: drafts)
        chatService.sendMessage(prompt, modelId: modelId, settings: settings, parts: carried.isEmpty ? nil : carried)
    }

    private func beginEdit(_ messageID: UUID, in conversationID: UUID) {
        guard let edit = chatService.beginEdit(from: messageID, in: conversationID) else { return }
        pendingEdit = edit
        messageText = edit.text
        carriedParts = edit.parts
        inputFocused = true
    }

    private func undoEdit(_ edit: ChatService.ConversationEdit) {
        if chatService.undoEdit(edit) {
            if messageText == edit.text { messageText = "" }
            carriedParts = nil
        }
        pendingEdit = nil
    }

    /// Clears what was sent, keeping anything typed while attachments loaded.
    private func clearComposer(ifUnchanged sentText: String, drafts: [ChatAttachmentDraft]) {
        if messageText == sentText { messageText = "" }
        let sentIDs = Set(drafts.map(\.id))
        attachmentDrafts.removeAll { sentIDs.contains($0.id) }
        if attachmentDrafts.isEmpty { attachmentWarnings = [] }
    }

    private func handleDrop(_ urls: [URL]) -> Bool {
        guard !chatService.isStreaming, !urls.isEmpty else { return false }
        return attachFiles(urls)
    }

    /// Shared by drop and ⌘V paste.
    private func attachFiles(_ urls: [URL]) -> Bool {
        let result = ChatAttachmentBuilder.classify(urls: urls)
        attachmentDrafts.append(contentsOf: result.drafts)
        refreshAttachmentWarnings(extra: result.warnings)
        return !result.drafts.isEmpty
    }

    private func chooseAttachments() {
        let panel = NSOpenPanel()
        panel.title = "Attach Files for Chat"
        panel.prompt = "Attach"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = ChatAttachmentPanelTypes.allowed
        if panel.runModal() == .OK {
            let result = ChatAttachmentBuilder.classify(urls: panel.urls)
            attachmentDrafts.append(contentsOf: result.drafts)
            refreshAttachmentWarnings(extra: result.warnings)
        }
    }

    private func refreshAttachmentWarnings(extra: [String] = []) {
        var warnings = extra
        let model = viewModel.api.models.first { $0.id == currentModelId }
        warnings += AttachmentCapability.warnings(model: model, drafts: attachmentDrafts)
        attachmentWarnings = warnings
    }

    private func regenerateAction(for message: ChatMessage, in conversation: ChatConversation, running: Bool) -> (() -> Void)? {
        guard !running, message.role == "assistant", conversation.messages.last?.id == message.id else { return nil }
        return {
            Task { await chatService.regenerateLastResponse(modelId: currentModelId, settings: requestSettings) }
        }
    }

    /// Menu-bar actions for this playground (Conversation menu).
    private var conversationActions: ConversationActions {
        let conversation = chatService.activeConversation
        let regenerate: (() -> Void)? = {
            guard let conversation, let last = conversation.messages.last else { return nil }
            return regenerateAction(for: last, in: conversation, running: currentSessionRunning)
        }()
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
        let last = conversation.messages.last
        var segments: [String] = []
        segments.append(String(conversation.messages.count))
        segments.append(String(last?.content.count ?? 0))
        segments.append(String(last?.reasoning?.count ?? 0))
        segments.append(String(last?.toolCalls?.count ?? 0))
        segments.append(String(last?.toolCalls?.reduce(0) { $0 + ($1.result?.count ?? 0) } ?? 0))
        segments.append(String(last?.images?.count ?? 0))
        segments.append(chatService.activityLabel)
        return segments.joined(separator: "|")
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

    /// Content growth can move the bottom sentinel by hundreds of points with
    /// no user input; only the top-origin observer disengages auto-follow.
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

    /// Issues a throttled, animation-free scroll-to-bottom. Animation is
    /// intentionally omitted during streaming: content is already growing
    /// at frame rate, so animating each scroll request stacks overlapping
    /// animations and can crash NSScrollView under load.
    ///
    /// NOTE: the throttle constant lives here (not in ChatService) because it
    /// gates *layout work* (scrollTo forces a full LazyVStack layout), not
    /// data publishes. Streaming at 33ms frames with 33ms scrolls is fine;
    /// dropping this to ~16ms re-introduces the stutter users reported.
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
                proxy.scrollTo("chat-message-bottom", anchor: .bottom)
            }
            return
        }
        lastScrollRequest = now
        proxy.scrollTo("chat-message-bottom", anchor: .bottom)
    }
}
