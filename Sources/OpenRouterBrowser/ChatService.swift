import Foundation

/// Handles chat completions with streaming support.
@MainActor
final class ChatService: ObservableObject {
    @Published var conversations: [ChatConversation] = []
    @Published var activeConversation: ChatConversation?
    @Published var isStreaming = false
    @Published var streamingContent = ""
    @Published var lastError: String?
    @Published var lastUsage: ChatUsage?

    private var streamTask: Task<Void, Never>?

    private let chatURL = URL(string: "https://openrouter.ai/api/v1/chat/completions")!

    // MARK: - Conversation management

    func newConversation(modelId: String) -> ChatConversation {
        let conv = ChatConversation(modelId: modelId)
        conversations.insert(conv, at: 0)
        activeConversation = conv
        return conv
    }

    func selectConversation(_ conv: ChatConversation) {
        activeConversation = conv
    }

    func deleteConversation(_ conv: ChatConversation) {
        conversations.removeAll { $0.id == conv.id }
        if activeConversation?.id == conv.id {
            activeConversation = conversations.first
        }
    }

    func clearConversations() {
        conversations.removeAll()
        activeConversation = nil
    }

    // MARK: - Send message

    func sendMessage(_ text: String, modelId: String, temperature: Double = 0.7, maxTokens: Int? = nil) async {
        guard let apiKey = KeychainManager.getAPIKey() else {
            lastError = "No API key configured. Go to Settings to add one."
            return
        }

        // Ensure we have an active conversation
        if activeConversation == nil || activeConversation?.modelId != modelId {
            _ = newConversation(modelId: modelId)
        }

        guard var conv = activeConversation else { return }

        // Add user message
        let userMsg = ChatMessage(role: "user", content: text)
        conv.messages.append(userMsg)

        // Auto-title from first message
        if conv.messages.count == 1 {
            conv.title = String(text.prefix(50)) + (text.count > 50 ? "..." : "")
        }

        // Add placeholder assistant message
        let assistantMsg = ChatMessage(role: "assistant", content: "")
        conv.messages.append(assistantMsg)

        activeConversation = conv
        updateConversation(conv)

        // Build request
        let requestMessages = conv.messages.dropLast().map { ["role": $0.role, "content": $0.content] }
        let body: [String: Any] = [
            "model": modelId,
            "messages": requestMessages,
            "stream": true,
            "temperature": temperature,
        ].merging(maxTokens.map { ["max_tokens": $0] } ?? [:]) { _, new in new }

        var request = URLRequest(url: chatURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("OpenRouterBrowser", forHTTPHeaderField: "HTTP-Referer")
        request.setValue("OpenRouterBrowser", forHTTPHeaderField: "X-OpenRouter-Title")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        isStreaming = true
        streamingContent = ""
        lastError = nil

        streamTask = Task {
            do {
                let (bytes, response) = try await URLSession.shared.bytes(for: request)
                guard let http = response as? HTTPURLResponse else {
                    lastError = "Invalid response"
                    isStreaming = false
                    return
                }

                if http.statusCode != 200 {
                    // Read the full error body
                    var errorData = Data()
                    for try await byte in bytes {
                        errorData.append(byte)
                    }
                    let errorStr = String(data: errorData, encoding: .utf8) ?? "HTTP \(http.statusCode)"
                    if let errData = errorStr.data(using: .utf8),
                       let apiErr = try? JSONDecoder().decode(ChatCompletionResponse.self, from: errData) {
                        lastError = apiErr.error?.message ?? "HTTP \(http.statusCode)"
                    } else {
                        lastError = errorStr
                    }
                    isStreaming = false
                    return
                }

                var fullContent = ""

                for try await line in bytes.lines {
                    guard !Task.isCancelled else { break }

                    // SSE format: "data: {...}" or "data: [DONE]"
                    guard line.hasPrefix("data: "),
                          line != "data: [DONE]" else {
                        if line == "data: [DONE]" { break }
                        continue
                    }

                    let jsonStr = String(line.dropFirst(6))
                    guard let jsonData = jsonStr.data(using: .utf8),
                          let chunk = try? JSONDecoder().decode(ChatCompletionResponse.self, from: jsonData) else {
                        continue
                    }

                    // Extract delta content
                    if let delta = chunk.choices?.first?.delta?.content {
                        fullContent += delta
                        streamingContent = fullContent

                        // Update the conversation's last message in real-time
                        if var currentConv = activeConversation,
                           let lastIndex = currentConv.messages.indices.last,
                           currentConv.messages[lastIndex].role == "assistant" {
                            currentConv.messages[lastIndex].content = fullContent
                            activeConversation = currentConv
                        }
                    }

                    // Capture usage from final chunk
                    if let usage = chunk.usage {
                        lastUsage = usage
                        if var currentConv = activeConversation {
                            currentConv.totalCost += (usage.cost ?? 0)
                            currentConv.totalTokens += (usage.totalTokens ?? 0)
                            activeConversation = currentConv
                            updateConversation(currentConv)
                        }
                    }
                }
            } catch {
                if !Task.isCancelled {
                    lastError = error.localizedDescription
                }
            }

            isStreaming = false
            streamingContent = ""
        }
    }

    func stopStreaming() {
        streamTask?.cancel()
        streamTask = nil
        isStreaming = false
        streamingContent = ""
    }

    // MARK: - Helpers

    private func updateConversation(_ conv: ChatConversation) {
        if let idx = conversations.firstIndex(where: { $0.id == conv.id }) {
            conversations[idx] = conv
        }
    }

    func formattedCost(_ cost: Double) -> String {
        if cost < 0.01 {
            return String(format: "$%.4f", cost)
        }
        return String(format: "$%.2f", cost)
    }
}
