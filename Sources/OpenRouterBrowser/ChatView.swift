import SwiftUI

/// Full chat playground: send messages to any model with streaming responses.
struct ChatView: View {
    @ObservedObject var viewModel: BrowserViewModel
    @StateObject private var chatService = ChatService()
    @State private var messageText = ""
    @State private var temperature: Double = 0.7
    @State private var maxTokens: Double = 0 // 0 = no limit
    @State private var showSettings = false
    @FocusState private var inputFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            // Sidebar: conversations list
            conversationSidebar

            Divider()

            // Main chat area
            VStack(spacing: 0) {
                chatHeader
                Divider()
                messageArea
                Divider()
                inputBar
            }
        }
        .task {
            inputFocused = true
        }
    }

    // MARK: - Conversation Sidebar

    private var conversationSidebar: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Conversations")
                    .font(.headline)
                Spacer()
                Button {
                    _ = chatService.newConversation(modelId: viewModel.selectedModel?.id ?? "openai/gpt-4o")
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.plain)
                .help("New conversation")
            }
            .padding(12)

            Divider()

            // List
            if chatService.conversations.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                    Text("No conversations yet")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxHeight: .infinity)
            } else {
                List(chatService.conversations, selection: Binding(
                    get: { chatService.activeConversation?.id },
                    set: { id in
                        if let id, let conv = chatService.conversations.first(where: { $0.id == id }) {
                            chatService.selectConversation(conv)
                        }
                    }
                )) { conv in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(conv.title)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                        HStack(spacing: 6) {
                            Text(conv.modelId.split(separator: "/").last.map(String.init) ?? conv.modelId)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer()
                            Text("\(conv.messages.count)")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.vertical, 2)
                    .contextMenu {
                        Button("Delete", role: .destructive) {
                            chatService.deleteConversation(conv)
                        }
                    }
                    .tag(conv.id)
                }
                .listStyle(.sidebar)
            }

            Divider()

            // Stats footer
            if let conv = chatService.activeConversation, conv.totalCost > 0 {
                HStack {
                    Label(chatService.formattedCost(conv.totalCost), systemImage: "dollarsign.circle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Spacer()
                    Label("\(conv.totalTokens) tokens", systemImage: "text.word.spacing")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(8)
            }
        }
        .frame(width: 200)
    }

    // MARK: - Chat Header

    private var chatHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                if let conv = chatService.activeConversation {
                    Text(conv.title)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    Text(conv.modelId)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                } else {
                    Text("Chat Playground")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Select a model to start chatting")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            // Model selector
            Menu {
                ForEach(viewModel.api.models.prefix(50), id: \.id) { model in
                    Button {
                        _ = chatService.newConversation(modelId: model.id)
                    } label: {
                        HStack {
                            Text(model.name)
                            if model.isFree {
                                Text("FREE").font(.caption2).foregroundStyle(.green)
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "cpu")
                    Text(chatService.activeConversation?.modelId.split(separator: "/").last.map(String.init) ?? "Select Model")
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 8))
                }
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.quaternary.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            // Settings toggle
            Button {
                showSettings.toggle()
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showSettings) {
                chatSettingsPopover
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Settings Popover

    private var chatSettingsPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Chat Settings")
                .font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Temperature")
                        .font(.subheadline)
                    Spacer()
                    Text(String(format: "%.2f", temperature))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Slider(value: $temperature, in: 0...2, step: 0.05)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Max Tokens")
                        .font(.subheadline)
                    Spacer()
                    Text(maxTokens == 0 ? "Auto" : "\(Int(maxTokens))")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Slider(value: $maxTokens, in: 0...16384, step: 256)
            }
        }
        .padding(16)
        .frame(width: 260)
    }

    // MARK: - Message Area

    @ViewBuilder
    private var messageArea: some View {
        if let conv = chatService.activeConversation {
            if conv.messages.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.system(size: 36))
                        .foregroundStyle(.tertiary)
                    Text("Start a conversation")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text("Type a message below to chat with \(conv.modelId)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(conv.messages) { msg in
                                MessageBubble(message: msg, isStreaming: chatService.isStreaming && msg.id == conv.messages.last?.id)
                                    .id(msg.id)
                            }

                            // Streaming indicator
                            if chatService.isStreaming {
                                HStack(spacing: 6) {
                                    ProgressView()
                                        .scaleEffect(0.6)
                                    Text("Generating...")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Button("Stop") {
                                        chatService.stopStreaming()
                                    }
                                    .font(.caption)
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
                                .padding(.horizontal, 16)
                            }
                        }
                        .padding(12)
                    }
                    .onChange(of: conv.messages.last?.content) { _, _ in
                        if let lastId = conv.messages.last?.id {
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo(lastId, anchor: .bottom)
                            }
                        }
                    }
                }
            }
        } else {
            VStack(spacing: 12) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.system(size: 48))
                    .foregroundStyle(.tertiary)
                Text("Chat Playground")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("Select a model or start a new conversation")
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Input Bar

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            // Key status indicator
            if !KeychainManager.hasAPIKey {
                Image(systemName: "key.slash")
                    .foregroundStyle(.orange)
                    .help("No API key — go to Settings")
            }

            TextField("Type a message...", text: $messageText, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .focused($inputFocused)
                .onSubmit {
                    sendMessage()
                }

            Button {
                sendMessage()
            } label: {
                Image(systemName: chatService.isStreaming ? "stop.circle.fill" : "arrow.up.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(canSend ? .blue : .gray)
            }
            .buttonStyle(.plain)
            .disabled(!canSend && !chatService.isStreaming)
        }
        .padding(12)
    }

    private var canSend: Bool {
        !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && KeychainManager.hasAPIKey
        && !chatService.isStreaming
        && chatService.activeConversation != nil
    }

    private func sendMessage() {
        guard canSend else {
            if !KeychainManager.hasAPIKey {
                chatService.lastError = "No API key configured. Go to Settings to add one."
            }
            return
        }

        let text = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        messageText = ""
        let modelId = chatService.activeConversation?.modelId ?? viewModel.selectedModel?.id ?? "openai/gpt-4o"

        Task {
            await chatService.sendMessage(
                text,
                modelId: modelId,
                temperature: temperature,
                maxTokens: maxTokens > 0 ? Int(maxTokens) : nil
            )
        }
    }
}

// MARK: - Message Bubble

struct MessageBubble: View {
    let message: ChatMessage
    var isStreaming: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if message.role == "assistant" {
                // Assistant avatar
                Image(systemName: "cpu")
                    .font(.system(size: 12))
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(.blue)
                    .clipShape(Circle())
            }

            if message.role == "assistant" { Spacer() }

            VStack(alignment: message.role == "user" ? .trailing : .leading, spacing: 4) {
                Text(message.role == "user" ? "You" : "Assistant")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)

                Text(message.content.isEmpty && isStreaming ? "..." : message.content)
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .padding(10)
                    .background(message.role == "user" ? Color.blue.opacity(0.15) : Color.gray.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }

            if message.role == "user" {
                // User avatar
                Image(systemName: "person.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(.green)
                    .clipShape(Circle())
            }

            if message.role == "user" { Spacer() }
        }
    }
}
