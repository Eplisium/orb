import AppKit
import SwiftUI

/// A polished OpenRouter chat playground with a first-party macOS agent runtime.
struct ChatView: View {
    @ObservedObject var viewModel: BrowserViewModel
    @StateObject private var chatService = ChatService()

    @State private var messageText = ""
    @State private var mode: PlaygroundMode = .agent
    @State private var selectedModelId = ""
    @State private var temperature = 0.7
    @State private var maxTokens: Double = 0
    @State private var fullComputerAccess = true
    @State private var workspace = FileManager.default.homeDirectoryForCurrentUser.path
    @State private var attachments: [URL] = []
    @State private var showSettings = false
    @State private var showModelPicker = false
    @State private var modelSearchText = ""
    @State private var toolCapableOnly = true
    @FocusState private var inputFocused: Bool

    private let accent = Color(red: 0.46, green: 0.38, blue: 0.96)

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
            if selectedModelId.isEmpty { selectedModelId = preferredModelId }
            viewModel.loadFavorites()
            inputFocused = true
        }
        .onChange(of: mode) { _, newMode in
            toolCapableOnly = newMode == .agent
            if newMode == .agent,
               !viewModel.api.models.contains(where: { $0.id == currentModelId && $0.supportsTools }) {
                selectedModelId = preferredModelId
            }
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
                errorBanner(error)
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
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9)
                        .fill(
                            LinearGradient(
                                colors: [accent, Color.blue],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                }
                .frame(width: 30, height: 30)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Playground")
                        .font(.system(size: 14, weight: .semibold))
                    Text(mode == .agent ? "Native Agent" : "OpenRouter Chat")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: newConversation) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(.plain)
                .help("New session")
                .disabled(chatService.isStreaming)
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 12)

            Picker("Mode", selection: $mode) {
                ForEach(PlaygroundMode.allCases) { item in
                    Text(item.rawValue).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.bottom, 12)

            ScrollView {
                LazyVStack(spacing: 6) {
                    if chatService.conversations.isEmpty {
                        emptyConversationList
                    } else {
                        ForEach(chatService.conversations) { conversation in
                            conversationRow(conversation)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
            }

            Spacer(minLength: 0)
            sidebarFooter
        }
        .frame(width: 224)
        .background(.ultraThinMaterial.opacity(0.72))
    }

    private var emptyConversationList: some View {
        VStack(spacing: 10) {
            Image(systemName: "bubble.left.and.sparkles")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(accent.opacity(0.75))
            Text("Your agent sessions\nwill appear here")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 32)
    }

    private func conversationRow(_ conversation: ChatConversation) -> some View {
        let selected = chatService.activeConversation?.id == conversation.id
        return Button {
            chatService.selectConversation(conversation)
            selectedModelId = conversation.modelId
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: mode == .agent ? "cpu" : "bubble.left")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(selected ? accent : .secondary)
                    Text(conversation.title)
                        .font(.system(size: 12, weight: selected ? .semibold : .medium))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                HStack(spacing: 5) {
                    Text(shortModelName(conversation.modelId))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text("\(conversation.messages.count)")
                    Image(systemName: "bubble.left")
                }
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(selected ? accent.opacity(0.14) : Color.primary.opacity(0.025))
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .stroke(selected ? accent.opacity(0.34) : Color.primary.opacity(0.04), lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Delete", role: .destructive) {
                chatService.deleteConversation(conversation)
            }
        }
        .accessibilityLabel("Session, \(conversation.title)")
    }

    private var sidebarFooter: some View {
        VStack(spacing: 9) {
            Rectangle()
                .fill(Color.primary.opacity(0.07))
                .frame(height: 1)
            HStack(spacing: 7) {
                Circle()
                    .fill(agentStatusColor)
                    .frame(width: 7, height: 7)
                    .shadow(color: agentStatusColor.opacity(0.6), radius: 3)
                Text(agentStatusText)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            if let conversation = chatService.activeConversation,
               conversation.totalTokens > 0 {
                HStack {
                    Label("\(conversation.totalTokens)", systemImage: "text.word.spacing")
                    Spacer()
                    Text(chatService.formattedCost(conversation.totalCost))
                }
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 13)
    }

    // MARK: - Header

    private var chatHeader: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(chatService.activeConversation?.title ?? (mode == .agent ? "New Agent Session" : "New Chat"))
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Image(systemName: mode == .agent ? "command" : "bolt.horizontal")
                    Text(mode == .agent ? "Powered by OpenRouterBrowser functions" : "Direct OpenRouter completion")
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 16)

            if mode == .agent {
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
            }

            modelPickerButton

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
            AgentModelPicker(
                models: viewModel.api.models,
                favoriteIds: viewModel.favoriteIds,
                selectedModelId: $selectedModelId,
                searchText: $modelSearchText,
                toolCapableOnly: $toolCapableOnly,
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
                Text("Playground Settings")
                    .font(.headline)
            }

            if mode == .agent {
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
            } else {
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
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 20) {
                        ForEach(conversation.messages) { message in
                            AgentMessageView(
                                message: message,
                                isStreaming: chatService.isStreaming && message.id == conversation.messages.last?.id,
                                assistantName: mode == .agent ? "OpenRouter Agent" : "Assistant",
                                accent: accent
                            )
                            .id(message.id)
                        }

                        if chatService.isStreaming {
                            activityRow
                                .id("activity")
                        }
                    }
                    .frame(maxWidth: 820)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 28)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: conversation.messages.last?.content) { _, _ in
                    scrollToBottom(proxy, conversation: conversation)
                }
                .onChange(of: chatService.isStreaming) { _, _ in
                    scrollToBottom(proxy, conversation: conversation)
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
                    Image(systemName: mode == .agent ? "wand.and.stars.inverse" : "bubble.left.and.bubble.right.fill")
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
                    Text(mode == .agent ? "What should we accomplish?" : "Explore any model")
                        .font(.system(size: 26, weight: .semibold, design: .rounded))
                    Text(welcomeSubtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 570)
                        .lineSpacing(3)
                }

                if mode == .agent {
                    HStack(spacing: 8) {
                        capabilityPill("Files", icon: "doc.text")
                        capabilityPill("Terminal", icon: "terminal")
                        capabilityPill("Web", icon: "globe")
                        capabilityPill("Computer", icon: "desktopcomputer")
                        capabilityPill("Memory", icon: "brain.head.profile")
                    }
                }

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    ForEach(suggestions, id: \.title) { suggestion in
                        suggestionCard(suggestion)
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
                Text(mode == .agent ? "This may take a moment while tools finish." : "Streaming from OpenRouter")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            Spacer()
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
            if !attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(attachments, id: \.self) { file in
                            attachmentChip(file)
                        }
                    }
                    .padding(.horizontal, 2)
                }
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
                    .disabled(mode == .chat || chatService.isStreaming)

                    if mode == .agent {
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
                    }

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

            Text(mode == .agent && fullComputerAccess
                 ? "Full access is on — this app can run commands, edit files, and control this Mac."
                 : "AI can make mistakes. Review important output and actions.")
                .font(.system(size: 9))
                .foregroundStyle(mode == .agent && fullComputerAccess ? Color.orange.opacity(0.85) : Color.secondary)
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

    // MARK: - Small components

    private func capabilityPill(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Color.primary.opacity(0.045))
            .clipShape(Capsule())
    }

    private func suggestionCard(_ suggestion: PlaygroundSuggestion) -> some View {
        Button {
            messageText = suggestion.prompt
            inputFocused = true
        } label: {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: suggestion.icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(accent)
                    .frame(width: 28, height: 28)
                    .background(accent.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                VStack(alignment: .leading, spacing: 4) {
                    Text(suggestion.title)
                        .font(.system(size: 11, weight: .semibold))
                    Text(suggestion.subtitle)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            .background(Color.primary.opacity(0.032))
            .overlay {
                RoundedRectangle(cornerRadius: 11)
                    .stroke(Color.primary.opacity(0.06), lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 11))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func errorBanner(_ error: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(error)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(2)
            Spacer()
            Button {
                chatService.lastError = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.caption)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.09))
    }

    // MARK: - Actions and derived values

    private var preferredModelId: String {
        if mode == .agent {
            if let favorite = viewModel.api.models.first(where: { viewModel.favoriteIds.contains($0.id) && $0.supportsTools })?.id {
                return favorite
            }
            if let selected = viewModel.selectedModel, selected.supportsTools { return selected.id }
            if let toolModel = viewModel.api.models.first(where: \.supportsTools)?.id { return toolModel }
        }
        if let selected = viewModel.selectedModel?.id { return selected }
        return viewModel.api.models.first?.id ?? "openai/gpt-4o"
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
        return mode == .agent ? "Ask the native agent to build, research, organize, or operate your Mac…" : "Message \(shortModelName(currentModelId))…"
    }

    private var abbreviatedWorkspace: String {
        workspace.replacingOccurrences(
            of: FileManager.default.homeDirectoryForCurrentUser.path,
            with: "~"
        )
    }

    private var agentStatusColor: Color {
        if chatService.isStreaming { return .orange }
        if mode == .agent { return KeychainManager.hasAPIKey ? .green : .orange }
        return KeychainManager.hasAPIKey ? .green : .orange
    }

    private var agentStatusText: String {
        if chatService.isStreaming { return "Agent working" }
        if mode == .agent { return KeychainManager.hasAPIKey ? "Native agent ready" : "API key needed" }
        return KeychainManager.hasAPIKey ? "OpenRouter ready" : "API key needed"
    }

    private var welcomeSubtitle: String {
        if mode == .agent {
            return "OpenRouterBrowser now runs its own agent loop and native functions. It can browse the web, work with files, run commands, automate Mac apps, and control your computer."
        }
        return "Chat directly with any model in the OpenRouter catalog. Responses stream live with usage and cost tracking."
    }

    private var suggestions: [PlaygroundSuggestion] {
        if mode == .agent {
            return [
                .init(title: "Build something", subtitle: "Create and verify a working project", icon: "hammer", prompt: "Build a polished project in my current workspace and verify that it works."),
                .init(title: "Organize my Mac", subtitle: "Inspect files and clean up a folder", icon: "folder.badge.gearshape", prompt: "Help me organize the files in my current workspace. Inspect first, then propose and carry out a safe cleanup."),
                .init(title: "Research deeply", subtitle: "Browse, compare, and cite sources", icon: "globe.americas.fill", prompt: "Research a topic for me thoroughly, compare credible sources, and give me a cited brief."),
                .init(title: "Use an application", subtitle: "Operate a Mac app in the background", icon: "macwindow", prompt: "Use the appropriate Mac application to help me complete a task. Ask only if a genuinely necessary detail is missing."),
            ]
        }
        return [
            .init(title: "Compare ideas", subtitle: "Reason through trade-offs", icon: "arrow.triangle.branch", prompt: "Help me compare two approaches and recommend the better one."),
            .init(title: "Write", subtitle: "Draft clear, polished content", icon: "pencil.line", prompt: "Help me draft a polished piece of writing."),
            .init(title: "Explain", subtitle: "Make a complex topic clear", icon: "lightbulb", prompt: "Explain a complex topic clearly with examples."),
            .init(title: "Brainstorm", subtitle: "Generate strong creative options", icon: "sparkles", prompt: "Brainstorm several creative options for me."),
        ]
    }

    private func newConversation() {
        _ = chatService.newConversation(modelId: currentModelId)
        messageText = ""
        attachments = []
        inputFocused = true
    }

    private func sendOrStop() {
        if chatService.isStreaming { chatService.stopStreaming() } else { sendMessage() }
    }

    private func sendMessage() {
        guard canSend else {
            if !KeychainManager.hasAPIKey {
                chatService.lastError = "Add your OpenRouter API key in Account before using the Playground."
            }
            return
        }

        var prompt = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !attachments.isEmpty {
            let paths = attachments.map(\.path).joined(separator: "\n")
            prompt += "\n\nAttached files:\n\(paths)"
        }
        messageText = ""
        attachments = []

        Task {
            if mode == .agent {
                await chatService.sendAgentMessage(
                    prompt,
                    modelId: currentModelId,
                    workspace: workspace,
                    fullComputerAccess: fullComputerAccess
                )
            } else {
                await chatService.sendMessage(
                    prompt,
                    modelId: currentModelId,
                    temperature: temperature,
                    maxTokens: maxTokens > 0 ? Int(maxTokens) : nil
                )
            }
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
        if panel.runModal() == .OK { attachments.append(contentsOf: panel.urls) }
    }

    private func shortModelName(_ modelId: String) -> String {
        modelId.split(separator: "/").last.map(String.init) ?? modelId
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

private struct AgentModelPicker: View {
    let models: [ModelInfo]
    let favoriteIds: Set<String>
    @Binding var selectedModelId: String
    @Binding var searchText: String
    @Binding var toolCapableOnly: Bool
    let accent: Color
    let toggleFavorite: (ModelInfo) -> Void
    let dismiss: () -> Void

    private var sections: [AgentModelSection] {
        AgentModelCatalog.sections(
            models: models,
            favoriteIds: favoriteIds,
            searchText: searchText,
            toolCapableOnly: toolCapableOnly
        )
    }

    private var resultCount: Int { sections.reduce(0) { $0 + $1.models.count } }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Choose a model")
                            .font(.system(size: 15, weight: .semibold))
                        Text("Favorites are always shown first")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("\(resultCount)")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(Color.primary.opacity(0.05))
                        .clipShape(Capsule())
                }

                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search models, providers, or IDs", text: $searchText)
                        .textFieldStyle(.plain)
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color.primary.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 8))

                Toggle(isOn: $toolCapableOnly) {
                    Label("Only models with function calling", systemImage: "wrench.and.screwdriver")
                        .font(.system(size: 10, weight: .medium))
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
            }
            .padding(16)

            Divider()

            if sections.isEmpty {
                ContentUnavailableView(
                    "No matching models",
                    systemImage: "cpu",
                    description: Text("Try another search or include models without function calling.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 7, pinnedViews: [.sectionHeaders]) {
                        ForEach(sections) { section in
                            Section {
                                ForEach(section.models) { model in
                                    modelRow(model)
                                }
                            } header: {
                                HStack {
                                    if section.title == "Favorites" {
                                        Image(systemName: "star.fill")
                                            .foregroundStyle(.yellow)
                                    }
                                    Text(section.title.uppercased())
                                    Spacer()
                                    Text("\(section.models.count)")
                                }
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 7)
                                .background(.regularMaterial)
                            }
                        }
                    }
                    .padding(10)
                }
            }
        }
        .frame(width: 440, height: 540)
    }

    private func modelRow(_ model: ModelInfo) -> some View {
        let selected = selectedModelId == model.id
        let favorite = favoriteIds.contains(model.id)
        return HStack(spacing: 10) {
            Button {
                selectedModelId = model.id
                dismiss()
            } label: {
                HStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 7)
                            .fill(selected ? accent.opacity(0.18) : Color.primary.opacity(0.05))
                        Text(String(model.provider.prefix(1)).uppercased())
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(selected ? accent : .secondary)
                    }
                    .frame(width: 30, height: 30)

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 5) {
                            Text(model.name)
                                .font(.system(size: 11, weight: .semibold))
                                .lineLimit(1)
                            if model.isFree {
                                Text("FREE")
                                    .font(.system(size: 7, weight: .bold))
                                    .foregroundStyle(.green)
                            }
                        }
                        HStack(spacing: 6) {
                            Text(model.provider)
                            Text("•")
                            Text(model.contextLengthFormatted)
                            if model.supportsTools {
                                Image(systemName: "wrench.and.screwdriver")
                            }
                            if model.supportsReasoning {
                                Image(systemName: "brain")
                            }
                        }
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(accent)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                toggleFavorite(model)
            } label: {
                Image(systemName: favorite ? "star.fill" : "star")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(favorite ? Color.yellow : Color.secondary)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(favorite ? "Remove from Favorites" : "Add to Favorites")
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(selected ? accent.opacity(0.10) : Color.primary.opacity(0.025))
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .stroke(selected ? accent.opacity(0.28) : Color.primary.opacity(0.045), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 9))
    }
}

private struct PlaygroundSuggestion {
    let title: String
    let subtitle: String
    let icon: String
    let prompt: String
}

private struct AgentMessageView: View {
    let message: ChatMessage
    let isStreaming: Bool
    let assistantName: String
    let accent: Color

    private var isUser: Bool { message.role == "user" }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if isUser {
                Spacer(minLength: 30)
                messageContent
                avatar
            } else {
                avatar
                messageContent
                Spacer(minLength: 30)
            }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    }

    private var messageContent: some View {
        VStack(alignment: isUser ? .trailing : .leading, spacing: 6) {
            Text(isUser ? "You" : assistantName)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
            Group {
                if message.content.isEmpty && isStreaming {
                    HStack(spacing: 5) {
                        ForEach(0..<3) { index in
                            Circle()
                                .fill(accent.opacity(0.75 - Double(index) * 0.17))
                                .frame(width: 5, height: 5)
                        }
                    }
                    .padding(.vertical, 4)
                } else {
                    Text(renderedContent)
                        .font(.system(size: 13))
                        .lineSpacing(3)
                        .textSelection(.enabled)
                }
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 11)
            .background(isUser ? accent.opacity(0.14) : Color.primary.opacity(0.045))
            .overlay {
                RoundedRectangle(cornerRadius: 13)
                    .stroke(isUser ? accent.opacity(0.18) : Color.primary.opacity(0.055), lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 13))
        }
        .frame(maxWidth: 680, alignment: isUser ? .trailing : .leading)
    }

    private var avatar: some View {
        ZStack {
            Circle()
                .fill(isUser ? Color.green.opacity(0.17) : accent.opacity(0.16))
            Image(systemName: isUser ? "person.fill" : "wand.and.stars")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(isUser ? Color.green : accent)
        }
        .frame(width: 30, height: 30)
    }

    private var renderedContent: AttributedString {
        (try? AttributedString(
            markdown: message.content,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(message.content)
    }
}