import Foundation

enum PlaygroundMode: String, CaseIterable, Identifiable {
    case agent = "Agent"
    case chat = "Chat"

    var id: String { rawValue }
}

/// Handles direct OpenRouter chat and the app's native function-calling agent.
@MainActor
final class ChatService: ObservableObject {
    @Published var conversations: [ChatConversation] = []
    @Published var activeConversation: ChatConversation?
    @Published var isStreaming = false
    @Published var streamingContent = ""
    @Published var lastError: String?
    @Published var lastUsage: ChatUsage?
    @Published var activityLabel = ""

    private var streamTask: Task<Void, Never>?
    private var agentHistories: [UUID: [AgentAPIMessage]] = [:]
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
        agentHistories.removeValue(forKey: conv.id)
        if activeConversation?.id == conv.id {
            activeConversation = conversations.first
        }
    }

    func clearConversations() {
        conversations.removeAll()
        agentHistories.removeAll()
        activeConversation = nil
    }

    // MARK: - Direct OpenRouter chat

    func sendMessage(
        _ text: String,
        modelId: String,
        temperature: Double = 0.7,
        maxTokens: Int? = nil
    ) async {
        guard let apiKey = KeychainManager.getAPIKey() else {
            lastError = "No API key configured. Go to Account to add one."
            return
        }

        if activeConversation == nil || activeConversation?.modelId != modelId {
            _ = newConversation(modelId: modelId)
        }
        guard var conv = activeConversation else { return }

        conv.messages.append(ChatMessage(role: "user", content: text))
        if conv.messages.count == 1 {
            conv.title = String(text.prefix(44)) + (text.count > 44 ? "…" : "")
        }
        conv.messages.append(ChatMessage(role: "assistant", content: ""))
        activeConversation = conv
        updateConversation(conv)

        let requestMessages = conv.messages.dropLast().map {
            ["role": $0.role, "content": $0.content]
        }
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
        activityLabel = "Generating response…"
        streamingContent = ""
        lastError = nil

        streamTask = Task {
            do {
                let (bytes, response) = try await URLSession.shared.bytes(for: request)
                guard let http = response as? HTTPURLResponse else {
                    lastError = "OpenRouter returned an invalid response."
                    finishRun()
                    return
                }

                if http.statusCode != 200 {
                    var errorData = Data()
                    for try await byte in bytes { errorData.append(byte) }
                    let errorText = String(data: errorData, encoding: .utf8) ?? "HTTP \(http.statusCode)"
                    if let data = errorText.data(using: .utf8),
                       let apiError = try? JSONDecoder().decode(ChatCompletionResponse.self, from: data) {
                        lastError = apiError.error?.message ?? "HTTP \(http.statusCode)"
                    } else {
                        lastError = errorText
                    }
                    finishRun()
                    return
                }

                var fullContent = ""
                for try await line in bytes.lines {
                    guard !Task.isCancelled else { break }
                    guard line.hasPrefix("data: "), line != "data: [DONE]" else {
                        if line == "data: [DONE]" { break }
                        continue
                    }

                    let json = String(line.dropFirst(6))
                    guard let data = json.data(using: .utf8),
                          let chunk = try? JSONDecoder().decode(ChatCompletionResponse.self, from: data) else {
                        continue
                    }

                    if let delta = chunk.choices?.first?.delta?.content {
                        fullContent += delta
                        streamingContent = fullContent
                        if var current = activeConversation,
                           let lastIndex = current.messages.indices.last,
                           current.messages[lastIndex].role == "assistant" {
                            current.messages[lastIndex].content = fullContent
                            activeConversation = current
                            updateConversation(current)
                        }
                    }

                    if let usage = chunk.usage {
                        lastUsage = usage
                        if var current = activeConversation {
                            current.totalCost += usage.cost ?? 0
                            current.totalTokens += usage.totalTokens ?? 0
                            activeConversation = current
                            updateConversation(current)
                        }
                    }
                }
            } catch {
                if !Task.isCancelled { lastError = error.localizedDescription }
            }
            finishRun()
        }
    }

    // MARK: - Native OpenRouter agent

    /// Runs OpenRouterBrowser's own function-calling loop directly against
    /// OpenRouter. No Hermes process or external agent runtime is involved.
    func sendAgentMessage(
        _ text: String,
        modelId: String,
        workspace: String,
        fullComputerAccess: Bool
    ) async {
        guard let apiKey = KeychainManager.getAPIKey(), !apiKey.isEmpty else {
            lastError = "Add your OpenRouter API key in Account before using Agent mode."
            return
        }

        if activeConversation == nil || activeConversation?.modelId != modelId {
            _ = newConversation(modelId: modelId)
        }
        guard var conv = activeConversation else { return }

        conv.messages.append(ChatMessage(role: "user", content: text))
        if conv.messages.count == 1 {
            conv.title = String(text.prefix(44)) + (text.count > 44 ? "…" : "")
        }
        conv.messages.append(ChatMessage(role: "assistant", content: ""))
        activeConversation = conv
        updateConversation(conv)

        isStreaming = true
        activityLabel = "Thinking…"
        lastError = nil
        let history = agentHistories[conv.id] ?? []
        let conversationId = conv.id

        streamTask = Task {
            do {
                let result = try await NativeAgentRunner.run(
                    prompt: text,
                    modelId: modelId,
                    apiKey: apiKey,
                    workspace: workspace,
                    fullComputerAccess: fullComputerAccess,
                    history: history,
                    onActivity: { label in
                        self.activityLabel = label
                    }
                )
                guard !Task.isCancelled else { return }
                agentHistories[conversationId] = result.history
                lastUsage = result.usage
                if var current = activeConversation,
                   current.id == conversationId,
                   let lastIndex = current.messages.indices.last {
                    current.messages[lastIndex].content = result.response
                    current.totalCost += result.usage?.cost ?? 0
                    current.totalTokens += result.usage?.totalTokens ?? 0
                    activeConversation = current
                    updateConversation(current)
                }
            } catch is CancellationError {
                // Keep the partial conversation visible after cancellation.
            } catch {
                lastError = error.localizedDescription
                if var current = activeConversation,
                   let lastIndex = current.messages.indices.last,
                   current.messages[lastIndex].content.isEmpty {
                    current.messages[lastIndex].content = "The agent couldn’t complete that request: \(error.localizedDescription)"
                    activeConversation = current
                    updateConversation(current)
                }
            }
            finishRun()
        }
    }

    func stopStreaming() {
        streamTask?.cancel()
        streamTask = nil
        finishRun()
    }

    // MARK: - Helpers

    private func finishRun() {
        isStreaming = false
        streamingContent = ""
        activityLabel = ""
    }

    private func updateConversation(_ conv: ChatConversation) {
        if let index = conversations.firstIndex(where: { $0.id == conv.id }) {
            conversations[index] = conv
        }
    }

    func formattedCost(_ cost: Double) -> String {
        cost < 0.01 ? String(format: "$%.4f", cost) : String(format: "$%.2f", cost)
    }
}