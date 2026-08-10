import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A polished OpenRouter chat playground — direct model conversations with
/// streaming, temperature/max-token controls, and live cost tracking.
struct ChatView: View {
    @ObservedObject var viewModel: BrowserViewModel
    @ObservedObject var chatService: ChatService

    @State private var messageText = ""
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
    @FocusState private var inputFocused: Bool

    private let accent = PlaygroundTheme.chatAccent

    /// Folds the two quick-access sliders into the full settings object so the
    /// simple controls and the advanced panel stay in sync.
    private var requestSettings: GenerationSettings {
        var resolved = settings
        resolved.temperature = temperature
        resolved.maxTokens = maxTokens > 0 ? Int(maxTokens) : nil
        return resolved
    }

    var body: some View {
        HStack(spacing: 0) {
            conversationSidebar
            Rectangle()
                .fill(Color.primary.opacity(0.07))
                .frame(width: 1)
            mainArea
        }
        .background(playgroundBackground)
        .task {
            chatService.activateConversation(for: .chat)
            selectedModelId = PlaygroundModelDefaults.initialSelection(
                activeModelId: chatService.activeConversation?.modelId,
                preferredModelId: preferredModelId
            )
            viewModel.loadFavorites()
            inputFocused = true
        }
    }

    // MARK: - Layout

    private var mainArea: some View {
        VStack(spacing: 0) {
            chatHeader
            Rectangle()
                .fill(Color.primary.opacity(0.07))
                .frame(height: 1)
            if let error = chatService.lastError {
                PlaygroundErrorBanner(message: error) { chatService.lastError = nil }
            }
            messageArea
            composer
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
                disabled: chatService.isStreaming
            )

            ScrollView {
                LazyVStack(spacing: 8, pinnedViews: [.sectionHeaders]) {
                    let chatConvs = chatService.conversations.filter { $0.mode == .chat }

                    if chatConvs.isEmpty {
                        EmptyConversationList(accent: accent)
                    } else {
                        Section {
                            ForEach(chatConvs) { conversation in
                                ConversationRow(
                                    conversation: conversation,
                                    isSelected: chatService.activeConversation?.id == conversation.id,
                                    isRunning: chatService.isRunning(conversationID: conversation.id),
                                    accent: accent,
                                    icon: "bubble.left",
                                    onSelect: {
                                        chatService.selectConversation(conversation)
                                        selectedModelId = conversation.modelId
                                    },
                                    onDelete: { chatService.deleteConversation(conversation) },
                                    onExport: { exportConversation(conversation) }
                                )
                            }
                        } header: {
                            sidebarSectionHeader(title: "Chat Sessions", icon: "bubble.left.and.bubble.right", count: chatConvs.count)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
            }

            Spacer(minLength: 0)
            ConversationSidebarFooter(
                statusColor: agentStatusColor,
                statusText: agentStatusText,
                conversation: chatService.activeConversation,
                formattedCost: chatService.formattedCost,
                tokensPerSecond: chatService.tokensPerSecond
            )
        }
        .frame(width: 224)
        .background(.ultraThinMaterial.opacity(0.72))
    }

    private func sidebarSectionHeader(title: String, icon: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(accent)
            Text(title.uppercased())
                .font(.system(size: 9, weight: .bold))
            Text("\(count)")
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Color.primary.opacity(0.06))
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
                Text(chatService.activeConversation?.title ?? "New Chat")
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Image(systemName: "bolt.horizontal")
                    Text("Direct OpenRouter completion")
                }
                .font(.system(size: 10, weight: .medium))
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
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(accent)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(accent.opacity(0.10))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(chatService.isStreaming)
            }

            modelPickerButton

            // Export button
            if let conversation = chatService.activeConversation {
                Button {
                    exportConversation(conversation)
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 28, height: 28)
                        .background(Color.primary.opacity(0.05))
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .help("Export conversation as Markdown")
            }

            Button {
                showSettings.toggle()
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .background(Color.primary.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showSettings) { settingsPopover }
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
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.05))
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
        VStack(alignment: .leading, spacing: 16) {
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
                    Text(String(format: "%.2f", temperature))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: $temperature, in: 0...2, step: 0.05)
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
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                TextEditor(text: Binding(
                    get: { chatService.activeConversation?.systemPrompt ?? "" },
                    set: {
                        if let conv = chatService.activeConversation {
                            chatService.updateSystemPrompt($0, for: conv)
                        }
                    }
                ))
                .font(.system(size: 11))
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
        .padding(18)
        .frame(width: 300)
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
                            LazyVStack(spacing: 16) {
                                ForEach(conversation.messages) { message in
                                    PlaygroundMessageView(
                                        message: message,
                                        isStreaming: chatService.isStreamingMessage(message.id, conversationID: conversation.id),
                                        assistantName: "Assistant",
                                        accent: accent,
                                        onDelete: conversationIsRunning
                                            ? nil
                                            : { chatService.deleteMessage(message.id, from: conversation) }
                                    )
                                    .id(message.id)
                                }

                                // Always in the tree to prevent LazyVStack
                                // layout thrashing when streaming starts/stops.
                                activityRow
                                    .opacity(conversationIsRunning ? 1 : 0)
                                    .frame(maxHeight: conversationIsRunning ? .infinity : 0)
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
                        }
                        .coordinateSpace(name: "chat-message-scroll")
                        .onPreferenceChange(MessageBottomOffsetKey.self) { bottomY in
                            followsLatest = bottomY <= viewport.size.height + 80
                        }

                        if conversationIsRunning && !followsLatest {
                            Button {
                                followsLatest = true
                                proxy.scrollTo("chat-message-bottom", anchor: .bottom)
                            } label: {
                                Label("Jump to latest", systemImage: "arrow.down")
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .padding(14)
                        }
                    }
                    // Watching only the last message's text missed growth from
                    // new messages, streaming tool cards, and activity-row
                    // changes — so long tool-heavy runs stopped following.
                    .onChange(of: scrollFollowKey(conversation)) { _, _ in
                        guard followsLatest else { return }
                        withAnimation(.easeOut(duration: 0.18)) {
                            proxy.scrollTo("chat-message-bottom", anchor: .bottom)
                        }
                    }
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
                        .font(.system(size: 34, weight: .medium))
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
                        .font(.system(size: 26, weight: .semibold, design: .rounded))
                    Text("Chat directly with any model in the OpenRouter catalog. Responses stream live with usage and cost tracking.")
                        .font(.system(size: 13))
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

    private var activityRow: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(accent.opacity(0.12))
                ProgressView()
                    .controlSize(.small)
                    .tint(accent)
            }
            .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(chatService.activityLabel)
                    .font(.system(size: 11, weight: .semibold))
                Text("Streaming from OpenRouter")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                UsageStatsBar(
                    usage: chatService.lastUsage,
                    tokensPerSecond: chatService.tokensPerSecond,
                    accent: accent
                )
            }
            Spacer()
            if chatService.tokensPerSecond > 0 {
                Text("\(String(format: "%.1f", chatService.tokensPerSecond)) tok/s")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.orange.opacity(0.10))
                    .clipShape(Capsule())
            }
            Button("Stop") { chatService.stopStreaming() }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(12)
        .background(Color.primary.opacity(0.035))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Composer

    private var composer: some View {
        VStack(spacing: 8) {
            VStack(spacing: 0) {
                TextField(composerPlaceholder, text: $messageText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .lineLimit(1...7)
                    .focused($inputFocused)
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
                    .padding(.bottom, 9)
                    .onSubmit { sendMessage() }

                HStack(spacing: 9) {
                    Spacer()
                    Text("↩ send")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.tertiary)

                    Button(action: sendOrStop) {
                        Image(systemName: chatService.isStreaming ? "stop.fill" : "arrow.up")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 28, height: 28)
                            .background(canSend || chatService.isStreaming ? accent : Color.gray.opacity(0.45))
                            .clipShape(Circle())
                            .shadow(color: accent.opacity(canSend ? 0.32 : 0), radius: 5, y: 2)
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend && !chatService.isStreaming)
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

            Text("AI can make mistakes. Review important output.")
                .font(.system(size: 9))
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

    private var canSend: Bool {
        let hasText = !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasText && KeychainManager.hasAPIKey && !chatService.isStreaming
    }

    private var composerPlaceholder: String {
        if !KeychainManager.hasAPIKey {
            return "Add your OpenRouter API key in Account…"
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
        inputFocused = true
    }

    private func sendOrStop() {
        if chatService.isStreaming { chatService.stopStreaming() } else { sendMessage() }
    }

    private func sendMessage() {
        guard canSend else {
            if !KeychainManager.hasAPIKey {
                chatService.lastError = "Add your OpenRouter API key in Account before using Chat."
            }
            return
        }

        let prompt = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        messageText = ""

        chatService.sendMessage(
            prompt,
            modelId: currentModelId,
            settings: requestSettings
        )
    }

    private func exportConversation(_ conv: ChatConversation) {
        let markdown = DatabaseManager.shared.exportConversationMarkdown(conv)
        let panel = NSSavePanel()
        panel.title = "Export Conversation"
        panel.nameFieldStringValue = "\(conv.title).md"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try markdown.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                chatService.lastError = "Could not export conversation: \(error.localizedDescription)"
            }
        }
    }


    /// Composite key covering every source of content growth during a run:
    /// message count, the streaming text, reasoning length, tool-call count
    /// on the last message, and the activity label. Any change means the view
    /// got taller.
    private func scrollFollowKey(_ conversation: ChatConversation) -> String {
        let last = conversation.messages.last
        return [
            String(conversation.messages.count),
            String(last?.content.count ?? 0),
            String(last?.reasoning?.count ?? 0),
            String(last?.toolCalls?.count ?? 0),
            String(last?.toolCalls?.reduce(0) { $0 + ($1.result?.count ?? 0) } ?? 0),
            chatService.activityLabel
        ].joined(separator: "|")
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, conversation: ChatConversation) {
        withAnimation(.easeOut(duration: 0.18)) {
            if chatService.isStreaming {
                proxy.scrollTo("activity", anchor: .bottom)
            } else if let last = conversation.messages.last {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }
}
