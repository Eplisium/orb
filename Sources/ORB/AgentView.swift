import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A polished native agent playground — ORB's own function-calling
/// agent that can browse the web, work with files, run commands, automate Mac
/// apps, and control the computer. Completely separate from Chat.
struct AgentView: View {
    @ObservedObject var viewModel: BrowserViewModel
    @ObservedObject var chatService: ChatService

    @State private var messageText = ""
    @State private var selectedModelId = ""
    @AppStorage(PlaygroundModelDefaults.agentKey) private var defaultModelId = ""
    @AppStorage("playground.agentFullComputerAccess") private var fullComputerAccess = false
    @AppStorage("playground.agentWorkspace") private var workspace = FileManager.default.homeDirectoryForCurrentUser.path
    @State private var attachments: [URL] = []
    @State private var attachmentWarnings: [String] = []
    @State private var attachmentContextSummary: String?
    @State private var showSettings = false
    @State private var showMCPSettings = false
    @State private var showModelPicker = false
    @State private var modelSearchText = ""
    @State private var toolCapableOnly = true
    @State private var followsLatest = true
    /// Latest sentinel maxY in the scroll coordinate space. Updated by
    /// onPreferenceChange; read by the scroll decision in onChange.
    @State private var bottomOffset: CGFloat = .infinity
    /// Throttle gate: last time we issued a programmatic scroll. Prevents
    /// stacking scroll requests faster than ~30fps.
    @State private var lastScrollRequest: ContinuousClock.Instant?
    /// Drives the live elapsed-time readout in the activity row.
    @State private var activityTick = Date()
    private let activityTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    @FocusState private var inputFocused: Bool

    private let accent = PlaygroundTheme.agentAccent

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
            chatService.activateConversation(for: .agent)
            selectedModelId = PlaygroundModelDefaults.initialSelection(
                activeModelId: chatService.activeConversation?.modelId,
                preferredModelId: preferredModelId
            )
            viewModel.loadFavorites()
            inputFocused = true
        }
        .onChange(of: selectedModelId) { _, _ in
            if !attachments.isEmpty { refreshAttachmentDiagnostics() }
        }
    }

    // MARK: - Layout

    private var mainArea: some View {
        VStack(spacing: 0) {
            agentHeader
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
                subtitle: "Native function-calling agent",
                icon: "wand.and.stars",
                accent: accent,
                onNew: { newConversation() },
                newLabel: "New Agent Session",
                newIcon: "wand.and.stars",
                disabled: chatService.isStreaming
            )

            ScrollView {
                LazyVStack(spacing: 8, pinnedViews: [.sectionHeaders]) {
                    let agentConvs = chatService.conversations.filter { $0.mode == .agent }

                    if agentConvs.isEmpty {
                        EmptyConversationList(accent: accent)
                    } else {
                        Section {
                            ForEach(agentConvs) { conversation in
                                ConversationRow(
                                    conversation: conversation,
                                    isSelected: chatService.activeConversation?.id == conversation.id,
                                    isRunning: chatService.isRunning(conversationID: conversation.id),
                                    accent: accent,
                                    icon: "cpu",
                                    onSelect: {
                                        chatService.selectConversation(conversation)
                                        selectedModelId = conversation.modelId
                                    },
                                    onDelete: { chatService.deleteConversation(conversation) },
                                    onExport: { exportConversation(conversation) }
                                )
                            }
                        } header: {
                            sidebarSectionHeader(title: "Agent Sessions", icon: "wand.and.stars", count: agentConvs.count)
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

    private var agentHeader: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(chatService.activeConversation?.title ?? "New Agent Session")
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Image(systemName: "command")
                    Text("Powered by ORB functions")
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 16)

            Button {
                fullComputerAccess.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: fullComputerAccess ? "desktopcomputer.and.macbook" : "network")
                    Text(fullComputerAccess ? "Computer Access" : "Web Only")
                }
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(fullComputerAccess ? Color.orange : Color.secondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background((fullComputerAccess ? Color.orange : Color.gray).opacity(0.11))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .help(fullComputerAccess ? "The native agent may use local functions and control this Mac" : "Only the web fetch function is enabled")
            .disabled(chatService.isStreaming)

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
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "slider.horizontal.3")
                    .foregroundStyle(accent)
                Text("Agent Settings")
                    .font(.headline)
            }

            VStack(alignment: .leading, spacing: 7) {
                Text("WORKSPACE")
                    .font(.system(size: 9, weight: .bold))
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
                    .background(Color.primary.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                Text("The native agent runs functions and reads project context from this folder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 7) {
                Text("SYSTEM PROMPT (OPTIONAL)")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                TextEditor(text: Binding(
                    get: { chatService.activeConversation?.systemPrompt ?? "" },
                    set: { value in
                        if let conversation = chatService.activeConversation {
                            chatService.updateSystemPrompt(value, for: conversation)
                        }
                    }
                ))
                .font(.system(size: 11))
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
                    .font(.system(size: 9, weight: .bold))
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
                    .background(Color.primary.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                Text("Connect Model Context Protocol servers to add tools.")
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
                                        assistantName: "OpenRouter Agent",
                                        accent: accent,
                                        onDelete: conversationIsRunning
                                            ? nil
                                            : { chatService.deleteMessage(message.id, from: conversation) },
                                        showToolCalls: true
                                    )
                                    .id(message.id)
                                }

                                // Always in the tree to prevent LazyVStack
                                // layout thrashing when streaming starts/stops.
                                // maxHeight: nil when running (natural height),
                                // 0 when idle (collapsed) — avoids unbounded
                                // growth that destabilizes scroll calculations.
                                activityRow
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
                        }
                        .coordinateSpace(name: "agent-message-scroll")
                        .onPreferenceChange(MessageBottomOffsetKey.self) { bottomY in
                            bottomOffset = bottomY
                            updateFollowsLatest(viewportHeight: viewport.size.height)
                        }

                        if conversationIsRunning && !followsLatest {
                            Button {
                                followsLatest = true
                                withAnimation(.easeOut(duration: 0.2)) {
                                    proxy.scrollTo("agent-message-bottom", anchor: .bottom)
                                }
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
                        requestFollowScroll(proxy)
                    }
                    // Reset follow state when switching conversations so a new
                    // session always starts pinned to the bottom.
                    .onChange(of: conversation.id) { _, _ in
                        followsLatest = true
                        bottomOffset = .infinity
                        lastScrollRequest = nil
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
                    Image(systemName: "wand.and.stars.inverse")
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
                    Text("What should we accomplish?")
                        .font(.system(size: 26, weight: .semibold, design: .rounded))
                    Text("ORB runs its own agent loop and native functions. It can browse the web, work with files, run commands, automate Mac apps, and control your computer.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 570)
                        .lineSpacing(3)
                }

                HStack(spacing: 8) {
                    CapabilityPill(title: "Files", icon: "doc.text")
                    CapabilityPill(title: "Terminal", icon: "terminal")
                    CapabilityPill(title: "Web", icon: "globe")
                    CapabilityPill(title: "Computer", icon: "desktopcomputer")
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
                Circle().fill(accent.opacity(0.12))
                ProgressView()
                    .controlSize(.small)
                    .tint(accent)
            }
            .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 3) {
                Text(chatService.activityLabel)
                    .font(.system(size: 11, weight: .semibold))
                    .contentTransition(.opacity)
                // Real progress signal instead of a static reassurance string.
                HStack(spacing: 6) {
                    Text(elapsedText)
                    if let toolCount = activeToolCount, toolCount > 0 {
                        Text("·")
                        Text("^[\(toolCount) tool call](inflect: true)")
                    }
                }
                .font(.system(size: 9, design: .monospaced))
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
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(accent.opacity(0.18), lineWidth: 0.5)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .animation(.easeInOut(duration: 0.2), value: chatService.activityLabel)
        .onReceive(activityTimer) { activityTick = $0 }
    }

    private var elapsedText: String {
        guard let started = chatService.runState.context?.startedAt else { return "0s" }
        let seconds = max(0, Int(activityTick.timeIntervalSince(started)))
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
                        .font(.system(size: 9, design: .monospaced))
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
                .font(.system(size: 9))
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

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
                    Button(action: chooseAttachments) {
                        Image(systemName: "paperclip")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 25, height: 25)
                            .background(Color.primary.opacity(0.05))
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
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(workspace)

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

            Text(fullComputerAccess
                 ? "Full access is on — this app can run commands, edit files, and control this Mac."
                 : "AI can make mistakes. Review important output and actions.")
                .font(.system(size: 9))
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
                    .font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
        }
        .font(.system(size: 9, weight: .medium))
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

    private var canSend: Bool {
        let hasText = !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasText && KeychainManager.hasAPIKey && !chatService.isStreaming
    }

    private var composerPlaceholder: String {
        if !KeychainManager.hasAPIKey {
            return "Add your OpenRouter API key in Account…"
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
        if chatService.isStreaming { chatService.stopStreaming() } else { sendMessage() }
    }

    private func sendMessage() {
        guard canSend else {
            if !KeychainManager.hasAPIKey {
                chatService.lastError = "Add your OpenRouter API key in Account before using the Agent."
            }
            return
        }

        var prompt = messageText.trimmingCharacters(in: .whitespacesAndNewlines)

        // Build a byte-bounded, explicitly untrusted attachment envelope.
        if !attachments.isEmpty {
            let result = attachmentBuildResult()
            attachmentWarnings = result.warnings
            guard !result.includedFiles.isEmpty else {
                chatService.lastError = result.warnings.first ?? "None of the selected attachments could be read."
                return
            }
            prompt += result.promptSuffix
        }

        messageText = ""
        attachments = []
        attachmentContextSummary = nil

        Task {
            await chatService.sendAgentMessage(
                prompt,
                modelId: currentModelId,
                workspace: workspace,
                fullComputerAccess: fullComputerAccess
            )
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

    private func attachmentBuildResult() -> AgentAttachmentBuildResult {
        let contextLength = viewModel.api.models.first(where: { $0.id == currentModelId })?.contextLength ?? 32_000
        return AgentAttachmentBuilder.build(
            urls: attachments,
            perFileByteLimit: 16_000,
            totalByteLimit: min(80_000, max(12_000, contextLength))
        )
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

    /// Updates `followsLatest` using hysteresis: once following, stay
    /// following until the user scrolls well past the follow threshold.
    private func updateFollowsLatest(viewportHeight: CGFloat) {
        let distance = bottomOffset - viewportHeight
        if followsLatest {
            // Already following — only unfollow if user scrolled well past.
            if distance > Self.unfollowThreshold {
                followsLatest = false
            }
        } else {
            // Not following — refollow if we're near the bottom.
            if distance <= Self.followThreshold {
                followsLatest = true
            }
        }
    }

    /// Issues a throttled, animation-free scroll-to-bottom. Animation is
    /// intentionally omitted during streaming: content is already growing
    /// at frame rate, so animating each scroll request stacks overlapping
    /// animations and can crash NSScrollView under load.
    private func requestFollowScroll(_ proxy: ScrollViewProxy) {
        let now = ContinuousClock.now
        if let last = lastScrollRequest, now - last < Self.scrollThrottle {
            return
        }
        lastScrollRequest = now
        proxy.scrollTo("agent-message-bottom", anchor: .bottom)
    }
}
