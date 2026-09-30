import AppKit
import SwiftUI

// MARK: - Shared playground constants

enum PlaygroundTheme {
    // One purple for the whole app: the restrained ORB accent from the
    // shared theme; every feature uses it. Red/green/orange stay reserved for
    // status (failed / passed / warning), never for selection or branding.
    static let accent = ORBTheme.accent
    static let agentAccent = ORBTheme.accent
    static let chatAccent = ORBTheme.accent
    static let testAccent = ORBTheme.accent
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

struct MessageTopGeometry: Equatable {
    let top: CGFloat
    let height: CGFloat
}

struct MessageTopOffsetKey: PreferenceKey {
    static var defaultValue = MessageTopGeometry(top: .infinity, height: 0)
    static func reduce(value: inout MessageTopGeometry, nextValue: () -> MessageTopGeometry) {
        value = nextValue()
    }
}

/// Distinguishes an upward scroll (the content origin moves down) from a
/// growing or collapsing reply. Small wheel ticks add up across follow-scroll
/// corrections; layout shrinkage and window resizing must not count as input.
struct MessageScrollIntent {
    private(set) var previousTop: CGFloat?
    private var previousContentHeight: CGFloat?
    private var previousViewportHeight: CGFloat?
    private(set) var upwardDistance: CGFloat = 0

    mutating func observe(top: CGFloat, contentHeight: CGFloat, viewportHeight: CGFloat, threshold: CGFloat) -> Bool {
        guard top.isFinite, contentHeight.isFinite, viewportHeight.isFinite else { return false }
        defer {
            previousTop = top
            previousContentHeight = contentHeight
            previousViewportHeight = viewportHeight
        }
        guard let previousTop, let previousContentHeight, let previousViewportHeight else { return false }
        // At the bottom, collapsing a panel or expanding the window clamps
        // the content origin upward without any wheel input. Discount that
        // layout-driven movement before accumulating manual upward travel.
        let layoutShift = max(0, previousContentHeight - contentHeight)
            + max(0, viewportHeight - previousViewportHeight)
        let upwardStep = max(0, top - previousTop - layoutShift)
        // Automatic follow-scrolls move the origin back down between wheel
        // ticks. Only returning to the bottom (or switching sessions) resets.
        upwardDistance += upwardStep
        return upwardDistance > threshold
    }

    mutating func reset() {
        previousTop = nil
        previousContentHeight = nil
        previousViewportHeight = nil
        upwardDistance = 0
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
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 4) {
                    Text(suggestion.title)
                        .font(.system(size: 12, weight: .semibold))
                    Text(suggestion.subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            .background(Color.primary.opacity(0.032))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.primary.opacity(0.06), lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
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
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Color.primary.opacity(0.045))
            .clipShape(Capsule())
    }
}

// MARK: - Typing Indicator

/// Three gradient dots with a staggered breathing wave and a soft accent
/// glow — the "assistant is composing" affordance shown before the first
/// token arrives.
struct TypingIndicator: View {
    let accent: Color
    @State private var phase = 0.0

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<3) { index in
                Circle()
                    .fill(LinearGradient(
                        colors: [accent, accent.opacity(0.55)],
                        startPoint: .top,
                        endPoint: .bottom
                    ))
                    .frame(width: 6, height: 6)
                    .scaleEffect(scale(index))
                    .opacity(0.35 + 0.65 * scale(index))
                    .shadow(color: accent.opacity(0.35), radius: 2.5)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Assistant is thinking")
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
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
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
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .stroke(toolCall.isExecuting ? accent.opacity(0.35) : Color.primary.opacity(0.07), lineWidth: 0.5)
        }
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

// MARK: - Tool Call Activity Group

/// A collapsed, at-a-glance summary of every tool call an agent made, instead of
/// a tall stack of individual cards. Shows live progress (running/done/failed
/// counts) in the header and expands to the full card list on demand. This is
/// what keeps a 20-tool run from turning into 20 full-height cards.
struct ToolCallActivityGroup: View {
    let toolCalls: [ToolCallDisplay]
    let accent: Color
    @State private var isExpanded = false

    private var runningCount: Int { toolCalls.filter(\.isExecuting).count }
    private var doneCount: Int { toolCalls.filter { $0.result != nil && !$0.isError }.count }
    private var failedCount: Int { toolCalls.filter { $0.result != nil && $0.isError }.count }
    private var summaryLabel: String {
        if let running = toolCalls.last(where: { $0.isExecuting }) {
            return "Running \(running.name)…"
        }
        if toolCalls.count == 1 { return toolCalls[0].name }
        return "\(toolCalls.count) tool calls"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 7) {
                    if runningCount > 0 {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(accent)
                    } else {
                        Image(systemName: "wrench.and.screwdriver")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(accent)
                    }
                    Text(summaryLabel)
                        .font(.system(size: 11, weight: .semibold))
                    statusSummary
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(toolCalls) { tc in
                        ToolCallCard(toolCall: tc, accent: accent)
                    }
                }
                .padding(.horizontal, 4)
                .padding(.bottom, 4)
            }
        }
        .background(Color.primary.opacity(0.025))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var statusSummary: some View {
        HStack(spacing: 6) {
            if doneCount > 0 {
                status("checkmark.circle.fill", "\(doneCount)", .green)
            }
            if failedCount > 0 {
                status("xmark.circle.fill", "\(failedCount)", .red)
            }
            if runningCount > 1 {
                status("circle.dashed", "\(runningCount)", accent)
            }
        }
        .font(.system(size: 9, design: .monospaced))
        .foregroundStyle(.secondary)
    }

    private func status(_ icon: String, _ text: String, _ color: Color) -> some View {
        HStack(spacing: 2) {
            Image(systemName: icon).foregroundStyle(color)
            Text(text)
        }
    }
}

// MARK: - Message View

struct PlaygroundMessageView: View {
    let message: ChatMessage
    let isStreaming: Bool
    let assistantName: String
    let accent: Color
    var isReasoning: Bool = false
    var onDelete: (() -> Void)?
    var showToolCalls: Bool = false

    @State private var isHovering = false
    @State private var showCopyCheck = false

    private var isUser: Bool { message.role == "user" }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: isUser ? "person.crop.circle" : "sparkle")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isUser ? Color.secondary : accent)
                Text(isUser ? "You" : assistantName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isUser ? Color.secondary : Color.primary)
                Spacer()
                messageActions
                    .opacity(isHovering || showCopyCheck ? 1 : 0)
                    .disabled(isStreaming)
            }
            messageBubble
        }
        .padding(.horizontal, isUser ? 18 : 0)
        .padding(.vertical, isUser ? 15 : 8)
        .background(isUser ? Color.primary.opacity(0.045) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 14))
        .frame(maxWidth: 780, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .center)
        .onHover { isHovering = $0 }
        .contextMenu {
            if !message.content.isEmpty {
                Button("Copy message", systemImage: "doc.on.doc") { copyMessage() }
            }
            if !isStreaming, let onDelete {
                Button("Delete message", systemImage: "trash", role: .destructive) { onDelete() }
            }
        }
        .accessibilityActions {
            if !message.content.isEmpty { Button("Copy message") { copyMessage() } }
            if !isStreaming, let onDelete { Button("Delete message") { onDelete() } }
        }
    }

    private func copyMessage() {
        guard !message.content.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message.content, forType: .string)
        showCopyCheck = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { showCopyCheck = false }
    }

    private var messageActions: some View {
        HStack(spacing: 3) {
            Button(action: copyMessage) {
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

/// Collapsible chain-of-thought panel above an assistant reply.
///
/// While the model thinks, a breathing "Thinking… 8s" pill with a live
/// elapsed timer sits above the streaming reasoning; the panel auto-
/// collapses the moment real content starts and freezes to "Thought for
/// 11s". The header can be tapped to expand/collapse at any time.
struct ReasoningDisclosure: View {
    let text: String
    let accent: Color
    let isStreaming: Bool
    let startedAt: Date?
    let duration: TimeInterval?

    @State private var isExpanded = false
    @State private var userToggled = false
    @State private var breathe = false

    private var effectiveExpansion: Bool {
        userToggled ? isExpanded : isStreaming
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if effectiveExpansion {
                bodyPanel
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: effectiveExpansion)
        .onAppear {
            if isStreaming {
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    breathe = true
                }
            }
        }
        .onChange(of: isStreaming) { _, streaming in
            if streaming {
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    breathe = true
                }
            } else {
                breathe = false
            }
        }
    }

    private var headerTitle: String {
        if let duration { return ThoughtDurationFormatter.summary(duration) }
        return "Thoughts"
    }

    private var header: some View {
        Button {
            isExpanded = !effectiveExpansion
            userToggled = true
        } label: {
            HStack(spacing: 6) {
                if isStreaming {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let elapsed = startedAt.map { (duration ?? 0) + max(0, context.date.timeIntervalSince($0)) }
                        Text(elapsed.map(ThoughtDurationFormatter.live) ?? "Thinking…")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .opacity(breathe ? 1.0 : 0.55)
                    }
                } else {
                    Text(headerTitle)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(effectiveExpansion ? 90 : 0))
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var bodyPanel: some View {
        MarkdownText(content: ReasoningTextFormatter.display(text), accent: accent, showsCursor: isStreaming)
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .lineSpacing(5)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 14)
            .padding(.vertical, 3)
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.primary.opacity(0.12))
                    .frame(width: 2)
            }
    }
}

/// Human phrasing for chain-of-thought timing — pure, unit-tested.
enum ThoughtDurationFormatter {
    /// "Thinking… 4s" / "Thinking… 1m 12s" — live phase.
    static func live(_ seconds: TimeInterval) -> String {
        "Thinking… \(duration(seconds))"
    }

    /// "Thought for 8s" / "Thought for 1m" — finished phase.
    static func summary(_ seconds: TimeInterval) -> String {
        "Thought for \(duration(seconds))"
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(max(total, 1))s" }
        let minutes = total / 60
        let rest = total % 60
        return rest == 0 ? "\(minutes)m" : "\(minutes)m \(rest)s"
    }
}

/// Pulsing accent orb for the run-activity row while the agent works.
struct ActivityPulseOrb: View {
    let accent: Color
    let isActive: Bool
    @State private var breathing = false

    var body: some View {
        ZStack {
            Circle()
                .fill(accent.opacity(breathing ? 0.18 : 0.08))
                .scaleEffect(breathing ? 1.0 : 0.82)
            Circle()
                .fill(accent.opacity(0.3))
                .frame(width: 12, height: 12)
            Circle()
                .fill(accent)
                .frame(width: 7, height: 7)
                .shadow(color: accent.opacity(0.5), radius: 3)
        }
        .frame(width: 32, height: 32)
        .onAppear { updateAnimation(isActive) }
        .onChange(of: isActive) { _, active in updateAnimation(active) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Working")
    }

    private func updateAnimation(_ active: Bool) {
        if active {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                breathing = true
            }
        } else {
            breathing = false
        }
    }
}

extension PlaygroundMessageView {
    private var messageBubble: some View {
        VStack(alignment: .leading, spacing: 12) {
            if isUser {
                Text(message.content)
                    .font(.system(size: 14))
                    .lineSpacing(5)
                    .textSelection(.enabled)
                if let parts = message.parts, !parts.isEmpty {
                    SentAttachmentsLabel(count: parts.count)
                }
            } else {
                transcriptBody
                if let images = message.images, !images.isEmpty {
                    AssistantImageRow(images: images, accent: accent)
                }
                if message.displayTranscript.isEmpty && isStreaming {
                    TypingIndicator(accent: accent).padding(.vertical, 4)
                }
            }
            if !isUser, !isStreaming, message.status != .complete {
                Label {
                    Text(messageStatusText)
                    if let error = message.errorMessage, !error.isEmpty { Text(error).lineLimit(2) }
                } icon: {
                    Image(systemName: message.status == .failed ? "exclamationmark.triangle" : "pause.circle")
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(message.status == .failed ? Color.orange : Color.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Consecutive tool segments collapse into one run so a 9-call burst reads
    /// as a single quiet line instead of nine stacked cards.
    private enum TranscriptItem: Identifiable {
        case segment(MessageTranscriptSegment)
        case tools(id: UUID, calls: [ToolCallDisplay])
        var id: UUID {
            switch self {
            case .segment(let s): return s.id
            case .tools(let id, _): return id
            }
        }
    }

    private func transcriptItems(_ segments: [MessageTranscriptSegment]) -> [TranscriptItem] {
        var items: [TranscriptItem] = []
        for segment in segments {
            if segment.kind == .tool {
                guard showToolCalls,
                      let call = message.toolCalls?.first(where: { $0.id == segment.toolCallID }) else { continue }
                if case .tools(let id, let calls)? = items.last {
                    items[items.count - 1] = .tools(id: id, calls: calls + [call])
                } else {
                    items.append(.tools(id: segment.id, calls: [call]))
                }
            } else {
                items.append(.segment(segment))
            }
        }
        return items
    }

    private var transcriptBody: some View {
        let segments = message.displayTranscript
        let items = transcriptItems(segments)
        let reasoningCount = segments.filter { $0.kind == .reasoning }.count
        return VStack(alignment: .leading, spacing: 12) {
            ForEach(items) { item in
                switch item {
                case .segment(let segment):
                    switch segment.kind {
                    case .reasoning:
                        ReasoningDisclosure(
                            text: segment.text,
                            accent: accent,
                            isStreaming: isReasoning && segment.id == segments.last?.id,
                            startedAt: message.reasoningStartedAt,
                            duration: reasoningCount == 1 ? message.reasoningDuration : nil
                        )
                    case .text:
                        MarkdownText(content: segment.text, accent: accent,
                                     showsCursor: isStreaming && !isReasoning && segment.id == segments.last?.id)
                            .font(.system(size: 14))
                            .lineSpacing(6)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    case .tool:
                        EmptyView()
                    }
                case .tools(_, let calls):
                    if calls.count == 1 {
                        ToolCallCard(toolCall: calls[0], accent: accent)
                    } else {
                        ToolCallActivityGroup(toolCalls: calls, accent: accent)
                    }
                }
            }
        }
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

