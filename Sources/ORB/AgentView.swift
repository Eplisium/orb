import AppKit
import SwiftUI

/// A polished native agent playground — ORB's own function-calling
/// agent that can browse the web, work with files, run commands, automate Mac
/// apps, and control the computer. Completely separate from Chat.
struct AgentView: View {
    @ObservedObject var viewModel: BrowserViewModel
    @StateObject private var chatService = ChatService()

    @State private var messageText = ""
    @State private var selectedModelId = ""
    @State private var fullComputerAccess = true
    @State private var workspace = FileManager.default.homeDirectoryForCurrentUser.path
    @State private var attachments: [URL] = []
    @State private var showSettings = false
    @State private var showModelPicker = false
    @State private var modelSearchText = ""
    @State private var toolCapableOnly = true
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
            if selectedModelId.isEmpty { selectedModelId = preferredModelId }
            viewModel.loadFavorites()
            inputFocused = true
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
                                    accent: accent,
                                    icon: "cpu",
                                    onSelect: {
                                        chatService.selectConversation(conversation)
                                        selectedModelId = conversation.modelId
                                    },
                                    onDelete: { chatService.deleteConversation(conversation) }
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
                formattedCost: chatService.formattedCost
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
            PlaygroundModelPicker(
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
                            PlaygroundMessageView(
                                message: message,
                                isStreaming: chatService.isStreaming && message.id == conversation.messages.last?.id,
                                assistantName: "OpenRouter Agent",
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
                    CapabilityPill(title: "Memory", icon: "brain.head.profile")
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
                Text("This may take a moment while tools finish.")
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
        if let favorite = viewModel.api.models.first(where: { viewModel.favoriteIds.contains($0.id) && $0.supportsTools })?.id {
            return favorite
        }
        if let selected = viewModel.selectedModel, selected.supportsTools { return selected.id }
        if let toolModel = viewModel.api.models.first(where: \.supportsTools)?.id { return toolModel }
        return "openai/gpt-4o"
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
        if chatService.isStreaming { return "Agent working" }
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
        _ = chatService.newConversation(modelId: currentModelId, mode: .agent)
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
                chatService.lastError = "Add your OpenRouter API key in Account before using the Agent."
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
        if panel.runModal() == .OK { attachments.append(contentsOf: panel.urls) }
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

// MARK: - Error Banner

private func errorBanner(_ error: String) -> some View {
    HStack(spacing: 9) {
        Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
        Text(error)
            .font(.system(size: 10, weight: .medium))
            .lineLimit(2)
        Spacer()
        Image(systemName: "xmark")
            .font(.caption)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 8)
    .background(Color.orange.opacity(0.09))
}
