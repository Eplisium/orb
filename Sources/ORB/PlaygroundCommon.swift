import AppKit
import SwiftUI

// MARK: - Shared playground constants

enum PlaygroundTheme {
    static let accent = Color(red: 0.46, green: 0.38, blue: 0.96)
    static let agentAccent = Color(red: 0.46, green: 0.38, blue: 0.96)
    static let chatAccent = Color(red: 0.30, green: 0.58, blue: 0.94)
    static let testAccent = Color(red: 0.94, green: 0.42, blue: 0.50)
}

// MARK: - Shared helpers

func shortModelName(_ modelId: String) -> String {
    modelId.split(separator: "/").last.map(String.init) ?? modelId
}

enum PlaygroundModelDefaults {
    static let agentKey = "playground.defaultAgentModelId"
    static let chatKey = "playground.defaultChatModelId"

    static func resolve(
        storedModelId: String,
        availableModelIds: [String],
        fallbackModelId: String
    ) -> String {
        guard !storedModelId.isEmpty else { return fallbackModelId }
        guard !availableModelIds.isEmpty else { return storedModelId }
        return availableModelIds.contains(storedModelId) ? storedModelId : fallbackModelId
    }

    static func initialSelection(activeModelId: String?, preferredModelId: String) -> String {
        activeModelId ?? preferredModelId
    }
}

struct MessageBottomOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = .infinity
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - Suggestion

struct PlaygroundSuggestion {
    let title: String
    let subtitle: String
    let icon: String
    let prompt: String
}

// MARK: - Suggestion Card

struct SuggestionCard: View {
    let suggestion: PlaygroundSuggestion
    let accent: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
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
}

// MARK: - Capability Pill

struct CapabilityPill: View {
    let title: String
    let icon: String

    var body: some View {
        Label(title, systemImage: icon)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Color.primary.opacity(0.045))
            .clipShape(Capsule())
    }
}

// MARK: - Typing Indicator

/// Three dots with a staggered breathing animation — the standard "assistant is
/// composing" affordance. Replaces the previous static dots.
struct TypingIndicator: View {
    let accent: Color
    @State private var phase = 0.0

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3) { index in
                Circle()
                    .fill(accent.opacity(0.75))
                    .frame(width: 5, height: 5)
                    .scaleEffect(scale(index))
                    .opacity(0.45 + 0.55 * scale(index))
            }
        }
        .onAppear {
            withAnimation(.linear(duration: 1.05).repeatForever(autoreverses: false)) {
                phase = 1
            }
        }
    }

    private func scale(_ index: Int) -> Double {
        let offset = Double(index) * 0.22
        let wave = sin((phase - offset) * .pi * 2)
        return 0.75 + 0.25 * max(0, wave)
    }
}

// MARK: - Tool Call Card (expandable)

struct ToolCallCard: View {
    let toolCall: ToolCallDisplay
    let accent: Color
    @State private var isExpanded = false

    private var toolIcon: String {
        switch toolCall.name {
        case "read_file": return "doc.text"
        case "list_directory": return "folder"
        case "search_files": return "magnifyingglass"
        case "write_file": return "square.and.pencil"
        case "run_command": return "terminal"
        case "run_applescript": return "applescript"
        case "open_application": return "app.badge"
        case "open_url": return "globe"
        case "capture_screen": return "camera.viewfinder"
        case "computer_action": return "desktopcomputer"
        case "fetch_url": return "network"
        default: return "wrench.and.screwdriver"
        }
    }

    /// A human-readable one-liner describing what this call actually does, so a
    /// stack of nine `run_command` rows is distinguishable at a glance instead of
    /// requiring the user to expand each one.
    private var subtitle: String {
        let json = toolCall.arguments ?? toolCall.argumentsSummary
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return json.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let preferredKeys = ["command", "path", "script", "url", "query", "pattern", "application", "action"]
        for key in preferredKeys {
            if let value = object[key] as? String, !value.isEmpty {
                return value.replacingOccurrences(of: "\n", with: " ")
            }
        }
        if object.isEmpty { return "no arguments" }
        return object.keys.sorted().joined(separator: ", ")
    }

    private var statusColor: Color {
        if toolCall.isError { return .red }
        if toolCall.isExecuting { return accent }
        if toolCall.result != nil { return .green }
        return .secondary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: toolIcon)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(statusColor)
                        .frame(width: 20, height: 20)
                        .background(statusColor.opacity(0.10))
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                    Text(toolCall.name)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.primary)
                        .layoutPriority(1)
                    Text(subtitle)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    if toolCall.isExecuting {
                        ProgressView().controlSize(.mini)
                    } else if toolCall.result != nil {
                        Image(systemName: toolCall.isError ? "xmark.circle.fill" : "checkmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(toolCall.isError ? Color.red : Color.green)
                    }
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                Divider().padding(.horizontal, 8)
                CodeBlockView(
                    language: "arguments",
                    source: prettyArguments,
                    accent: accent
                )
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                if let result = toolCall.result {
                    CodeBlockView(
                        language: toolCall.isError ? "error" : "output",
                        source: result,
                        accent: toolCall.isError ? .red : accent
                    )
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                }
            }
        }
        .background(Color.primary.opacity(0.028))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(toolCall.isExecuting ? accent.opacity(0.30) : Color.primary.opacity(0.06), lineWidth: 0.5)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    /// Pretty-printed JSON so expanded arguments are readable rather than a
    /// single unwrapped line.
    private var prettyArguments: String {
        let json = toolCall.arguments ?? toolCall.argumentsSummary
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
              ) else { return json }
        return String(decoding: pretty, as: UTF8.self)
    }
}

// MARK: - Tool Result Card (expandable)

struct ToolResultCard: View {
    let message: ChatMessage
    let accent: Color
    @State private var isExpanded = false

    private var toolIcon: String {
        switch message.toolName {
        case "read_file": return "doc.text"
        case "list_directory": return "folder"
        case "search_files": return "magnifyingglass"
        case "write_file": return "square.and.pencil"
        case "run_command": return "terminal"
        case "run_applescript": return "applescript"
        case "open_application": return "app.badge"
        case "open_url": return "globe"
        case "capture_screen": return "camera.viewfinder"
        case "computer_action": return "desktopcomputer"
        case "fetch_url": return "network"
        default: return "wrench.and.screwdriver"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: toolIcon)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .background(Color.orange.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                    Text("\(message.toolName ?? "tool") result")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    let preview = message.content.prefix(80).replacingOccurrences(of: "\n", with: " ")
                    if !isExpanded {
                        Text(preview)
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                Divider().padding(.horizontal, 8)
                CodeBlockView(
                    language: message.toolName ?? "output",
                    source: message.content,
                    accent: accent
                )
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
        }
        .background(Color.orange.opacity(0.035))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.orange.opacity(0.10), lineWidth: 0.5)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Message View

struct PlaygroundMessageView: View {
    let message: ChatMessage
    let isStreaming: Bool
    let assistantName: String
    let accent: Color
    var onDelete: (() -> Void)?
    var showToolCalls: Bool = false

    @State private var isHovering = false
    @State private var showCopyCheck = false

    private var isUser: Bool { message.role == "user" }
    private var isToolResult: Bool { message.role == "tool" }

    var body: some View {
        if isToolResult {
            ToolResultCard(message: message, accent: accent)
                .padding(.horizontal, 4)
        } else {
            HStack(alignment: .top, spacing: 10) {
                if isUser {
                    Spacer(minLength: 60)
                    VStack(alignment: .trailing, spacing: 6) {
                        Text("You")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                            .padding(.trailing, 4)
                        bubbleWithActions
                    }
                    avatar
                } else {
                    avatar
                    VStack(alignment: .leading, spacing: 6) {
                        Text(assistantName)
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                            .padding(.leading, 4)
                        if showToolCalls, let toolCalls = message.toolCalls, !toolCalls.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(toolCalls) { tc in
                                    ToolCallCard(toolCall: tc, accent: accent)
                                }
                            }
                        }
                        bubbleWithActions
                    }
                    Spacer(minLength: 60)
                }
            }
            .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
        }
    }

    /// The message bubble with action buttons embedded inside its hover zone.
    /// Actions appear at the top-trailing corner of the bubble itself — no dead gap.
    private var bubbleWithActions: some View {
        messageBubble
            .overlay(alignment: isUser ? .topTrailing : .topLeading) {
                if isHovering && !isStreaming {
                    messageActions
                        .padding(6)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.12)) { isHovering = hovering }
            }
    }

    private var messageActions: some View {
        HStack(spacing: 3) {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(message.content, forType: .string)
                showCopyCheck = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { showCopyCheck = false }
            } label: {
                Image(systemName: showCopyCheck ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(showCopyCheck ? .green : .secondary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help("Copy message")

            if let onDelete {
                Button {
                    onDelete()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.red.opacity(0.7))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .help("Delete message")
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
    }
}

/// Compact per-run accounting: speed, tokens, cache savings, and cost.
///
/// Cached and reasoning tokens are only shown when non-zero — they are
/// provider-specific and would otherwise be noise on models that never
/// report them.
struct UsageStatsBar: View {
    let usage: ChatUsage?
    let tokensPerSecond: Double
    let accent: Color

    var body: some View {
        if let usage, hasContent(usage) {
            HStack(spacing: 5) {
                if tokensPerSecond > 0 {
                    stat("speedometer", String(format: "%.0f tok/s", tokensPerSecond))
                }
                if let prompt = usage.promptTokens, prompt > 0 {
                    stat("arrow.up", "\(prompt) in")
                }
                if let completion = usage.completionTokens, completion > 0 {
                    stat("arrow.down", "\(completion) out")
                }
                if let cached = usage.cachedTokens, cached > 0 {
                    stat("bolt.fill", "\(cached) cached")
                }
                if let reasoning = usage.reasoningTokens, reasoning > 0 {
                    stat("brain", "\(reasoning) thinking")
                }
                if let cost = usage.cost, cost > 0 {
                    stat("dollarsign.circle", formatCost(cost))
                }
            }
            .font(.system(size: 9, design: .monospaced))
            .foregroundStyle(.secondary)
        }
    }

    private func hasContent(_ usage: ChatUsage) -> Bool {
        (usage.totalTokens ?? 0) > 0 || (usage.cost ?? 0) > 0 || tokensPerSecond > 0
    }

    private func stat(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 2) {
            Image(systemName: icon).font(.system(size: 8))
            Text(text)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(accent.opacity(0.08), in: Capsule())
    }

    /// Per-request costs are often far below a cent, so a flat 2-decimal
    /// format would render everything as "$0.00".
    private func formatCost(_ cost: Double) -> String {
        if cost < 0.01 { return String(format: "$%.5f", cost) }
        return String(format: "$%.4f", cost)
    }
}

/// Collapsible "thinking" panel shown above an assistant reply.
///
/// Auto-expands while reasoning is the only thing streaming so the user sees
/// progress, then collapses once real content starts arriving.
struct ReasoningDisclosure: View {
    let text: String
    let accent: Color
    let isStreaming: Bool

    @State private var isExpanded = false
    @State private var userToggled = false

    private var effectiveExpansion: Bool {
        userToggled ? isExpanded : isStreaming
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                userToggled = true
                isExpanded.toggle()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "brain")
                        .font(.system(size: 9))
                    Text(isStreaming ? "Thinking…" : "Reasoning")
                        .font(.system(size: 10, weight: .medium))
                    Text("\(text.count) chars")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .rotationEffect(.degrees(effectiveExpansion ? 90 : 0))
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            if effectiveExpansion {
                ScrollView {
                    Text(text)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                // Long chains of thought must not push the answer off screen.
                .frame(maxHeight: 220)
                .background(accent.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
            }
        }
        .animation(.easeInOut(duration: 0.16), value: effectiveExpansion)
    }
}

extension PlaygroundMessageView {
    private var messageBubble: some View {
        VStack(alignment: isUser ? .trailing : .leading, spacing: 6) {
            // Reasoning arrives before visible content, so rendering it here
            // gives immediate feedback on thinking models instead of a long
            // silent gap.
            if !isUser, let reasoning = message.reasoning, !reasoning.isEmpty {
                ReasoningDisclosure(
                    text: reasoning,
                    accent: accent,
                    isStreaming: isStreaming && message.content.isEmpty
                )
            }

            Group {
                if message.content.isEmpty && isStreaming && (message.reasoning?.isEmpty ?? true) {
                    TypingIndicator(accent: accent)
                        .padding(.vertical, 4)
                } else if isUser {
                    Text(message.content)
                        .font(.system(size: 13))
                        .lineSpacing(3)
                        .textSelection(.enabled)
                } else {
                    // Full block-level Markdown, including during streaming, so
                    // code fences and lists never appear as raw syntax.
                    MarkdownText(content: message.content, accent: accent, showsCursor: isStreaming)
                        .font(.system(size: 13))
                        .lineSpacing(3)
                        .textSelection(.enabled)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(isUser ? accent.opacity(0.14) : Color.primary.opacity(0.045))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(isUser ? accent.opacity(0.18) : Color.primary.opacity(0.055), lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 14))

            if !isUser, !isStreaming, message.status != .complete {
                HStack(spacing: 5) {
                    Image(systemName: message.status == .failed ? "exclamationmark.triangle.fill" : "pause.circle")
                    Text(messageStatusText)
                    if let error = message.errorMessage, !error.isEmpty {
                        Text("· \(error)").lineLimit(2)
                    }
                }
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(message.status == .failed ? Color.orange : Color.secondary)
            }
        }
        .frame(maxWidth: 680, alignment: isUser ? .trailing : .leading)
    }

    private var avatar: some View {
        ZStack {
            Circle()
                .fill(isUser ? Color.green.opacity(0.14) : accent.opacity(0.13))
            Image(systemName: isUser ? "person.fill" : "wand.and.stars")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(isUser ? Color.green.opacity(0.85) : accent.opacity(0.85))
        }
        .frame(width: 28, height: 28)
        .padding(.top, 14)
    }

    private var messageStatusText: String {
        switch message.status {
        case .complete: return "Complete"
        case .streaming: return "Streaming"
        case .failed: return "Failed"
        case .interrupted: return "Interrupted"
        case .truncated: return "Stopped at the model's output limit"
        }
    }
}

// MARK: - Error Banner

/// Shared inline error banner for Agent and Chat.
///
/// Presents a short human-readable headline with the raw technical detail behind
/// a disclosure, instead of dumping an internal string like
/// "invalid JSON arguments for chatcmpl-tool-…" across the top of the window.
struct PlaygroundErrorBanner: View {
    let message: String
    let onDismiss: () -> Void
    @State private var showsDetail = false

    /// Maps known failure shapes to plain language plus a suggested next step.
    private var summary: (headline: String, hint: String?) {
        let lowered = message.lowercased()
        if lowered.contains("api key") || lowered.contains("401") {
            return ("OpenRouter rejected your API key", "Update it in Account.")
        }
        if lowered.contains("credits") || lowered.contains("402") {
            return ("Your OpenRouter credits are exhausted", "Add credits, then retry.")
        }
        if lowered.contains("rate limit") || lowered.contains("429") {
            return ("Rate limited by OpenRouter", "Wait a moment, then retry.")
        }
        if lowered.contains("tool call") || lowered.contains("json arguments") {
            return ("The model sent a malformed tool call", "Retry, or switch to a model with stronger function-calling support.")
        }
        if lowered.contains("truncated") {
            return ("The model ran out of output room mid-tool-call", "Retry, or raise the max-tokens limit.")
        }
        if lowered.contains("tool-call limit") {
            return ("The agent hit its tool-call limit", "Ask a narrower question or split the task.")
        }
        if lowered.contains("network") || lowered.contains("timed out") || lowered.contains("idle") {
            return ("Lost connection to OpenRouter", "Check your network, then retry.")
        }
        return ("Something went wrong", nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(summary.headline)
                        .font(.system(size: 11, weight: .semibold))
                    if let hint = summary.hint {
                        Text(hint)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { showsDetail.toggle() }
                } label: {
                    Text(showsDetail ? "Hide details" : "Details")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(message, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Copy error details")
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Dismiss error")
            }

            if showsDetail {
                Text(message)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color.primary.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(Color.orange.opacity(0.09))
    }
}

// MARK: - Model Picker

struct PlaygroundModelPicker: View {
    let models: [ModelInfo]
    let favoriteIds: Set<String>
    @Binding var selectedModelId: String
    @Binding var searchText: String
    var toolCapableOnly: Binding<Bool>?
    var defaultModelId: Binding<String>?
    var defaultLabel: String?
    let accent: Color
    let toggleFavorite: (ModelInfo) -> Void
    let dismiss: () -> Void

    private var toolFilter: Bool { toolCapableOnly?.wrappedValue ?? false }

    private var sections: [AgentModelSection] {
        AgentModelCatalog.sections(
            models: models,
            favoriteIds: favoriteIds,
            searchText: searchText,
            toolCapableOnly: toolFilter
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
                        Text(defaultModelId == nil ? "Favorites are always shown first" : "Pin a model to use it for every new \(defaultLabel ?? "playground") session")
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

                if let toolCapableOnly {
                    Toggle(isOn: toolCapableOnly) {
                        Label("Only models with function calling", systemImage: "wrench.and.screwdriver")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                }
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
        let isDefault = defaultModelId?.wrappedValue == model.id
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

            if let defaultModelId {
                Button {
                    defaultModelId.wrappedValue = isDefault ? "" : model.id
                } label: {
                    Image(systemName: isDefault ? "pin.fill" : "pin")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isDefault ? accent : Color.secondary)
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isDefault ? "Clear \(defaultLabel ?? "playground") default" : "Set as \(defaultLabel ?? "playground") default")
            }

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

// MARK: - Conversation sidebar helpers

struct ConversationSidebarHeader: View {
    let title: String
    let subtitle: String
    let icon: String
    let accent: Color
    let onNew: () -> Void
    let newLabel: String
    let newIcon: String
    let disabled: Bool

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 9)
                    .fill(
                        LinearGradient(
                            colors: [accent, .blue],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                Button {
                    onNew()
                } label: {
                    Label(newLabel, systemImage: newIcon)
                }
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(.plain)
            .help("New session")
            .disabled(disabled)
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }
}

struct ConversationRow: View {
    let conversation: ChatConversation
    let isSelected: Bool
    var isRunning: Bool = false
    let accent: Color
    let icon: String
    let onSelect: () -> Void
    let onDelete: () -> Void
    var onExport: (() -> Void)?
    @State private var showDeleteConfirmation = false

    var body: some View {
        Button {
            onSelect()
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: icon)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(isSelected ? accent : .secondary)
                    Text(conversation.title)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if isRunning {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(accent)
                            .help("This session is running")
                    }
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
            .background(isSelected ? accent.opacity(0.14) : Color.primary.opacity(0.025))
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .stroke(isSelected ? accent.opacity(0.34) : Color.primary.opacity(0.04), lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let onExport {
                Button {
                    onExport()
                } label: {
                    Label("Export as Markdown", systemImage: "square.and.arrow.up")
                }
            }
            Button("Delete", role: .destructive) {
                showDeleteConfirmation = true
            }
        }
        .accessibilityLabel("Session, \(conversation.title)")
        .confirmationDialog(
            "Delete “\(conversation.title)”?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete Session", role: .destructive, action: onDelete)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes the session and all of its messages.")
        }
    }
}

struct ConversationSidebarFooter: View {
    let statusColor: Color
    let statusText: String
    let conversation: ChatConversation?
    let formattedCost: (Double) -> String
    var tokensPerSecond: Double = 0

    var body: some View {
        VStack(spacing: 9) {
            Rectangle()
                .fill(Color.primary.opacity(0.07))
                .frame(height: 1)
            HStack(spacing: 7) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                    .shadow(color: statusColor.opacity(0.6), radius: 3)
                Text(statusText)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                if tokensPerSecond > 0 {
                    Text("\(String(format: "%.1f", tokensPerSecond)) tok/s")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.10))
                        .clipShape(Capsule())
                }
            }
            if let conversation, conversation.totalTokens > 0 {
                HStack {
                    Label("\(conversation.totalTokens)", systemImage: "text.word.spacing")
                    Spacer()
                    Text(formattedCost(conversation.totalCost))
                }
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 13)
    }
}

struct EmptyConversationList: View {
    let accent: Color

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "bubble.left.and.sparkles")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(accent.opacity(0.75))
            Text("Your sessions\nwill appear here")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 32)
    }
}
