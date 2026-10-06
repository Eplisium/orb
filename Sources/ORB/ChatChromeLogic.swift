import Foundation

// MARK: - Chat and Agent chrome logic (Phase 5)
//
// Pure value types behind the header, sidebar and composer. None of this
// touches streaming or agent data flow; views only read it.

// MARK: Sidebar search, grouping and pinning

enum ConversationListModel {
    struct Section: Identifiable, Equatable {
        let title: String
        let items: [ChatConversation]
        var id: String { title }
    }

    /// Matches title, model id, or any message text. Whitespace-trimmed, case-insensitive.
    static func filter(_ conversations: [ChatConversation], query: String) -> [ChatConversation] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return conversations }
        return conversations.filter { c in
            c.title.localizedCaseInsensitiveContains(q)
                || c.modelId.localizedCaseInsensitiveContains(q)
                || c.messages.contains { $0.content.localizedCaseInsensitiveContains(q) }
        }
    }

    /// Pinned first (in `pinOrder`), then date buckets, newest first. Empty buckets are omitted
    /// and a pinned conversation never appears twice.
    static func sections(
        _ conversations: [ChatConversation],
        query: String = "",
        pinned: Set<UUID>,
        pinOrder: [UUID] = [],
        now: Date = .now,
        calendar: Calendar = .current
    ) -> [Section] {
        let visible = filter(conversations, query: query)
        let pinnedItems: [ChatConversation] = {
            let items = visible.filter { pinned.contains($0.id) }
            let rank = Dictionary(uniqueKeysWithValues: pinOrder.enumerated().map { ($1, $0) })
            return items.sorted { (rank[$0.id] ?? Int.max) < (rank[$1.id] ?? Int.max) }
        }()
        var result: [Section] = []
        if !pinnedItems.isEmpty { result.append(Section(title: "Pinned", items: pinnedItems)) }

        let rest = visible.filter { !pinned.contains($0.id) }.sorted { $0.createdAt > $1.createdAt }
        let startOfToday = calendar.startOfDay(for: now)
        let startOfYesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday) ?? startOfToday
        let startOfWeek = calendar.date(byAdding: .day, value: -7, to: startOfToday) ?? startOfToday

        let buckets: [(String, (Date) -> Bool)] = [
            ("Today", { $0 >= startOfToday }),
            ("Yesterday", { $0 >= startOfYesterday && $0 < startOfToday }),
            ("Previous 7 Days", { $0 >= startOfWeek && $0 < startOfYesterday }),
            ("Older", { $0 < startOfWeek }),
        ]
        for (title, test) in buckets {
            let items = rest.filter { test($0.createdAt) }
            if !items.isEmpty { result.append(Section(title: title, items: items)) }
        }
        return result
    }
}

/// Memoizes `ConversationListModel.sections`. The sidebar body re-evaluates
/// on every streamed publish (the conversation array changes), and a search
/// query scans every message's text; recompute only when something the
/// sections depend on changed.
@MainActor
final class ConversationSectionsCache {
    struct Key: Equatable {
        struct Item: Equatable {
            let id: UUID, title: String, modelId: String, createdAt: Date
            let messageCount: Int, lastMessageLength: Int
        }
        let items: [Item]
        let query: String
        let pinned: Set<UUID>
        let pinOrder: [UUID]
        let day: Date
    }

    private(set) var computeCount = 0
    private var key: Key?
    private var value: [ConversationListModel.Section] = []

    func sections(
        _ conversations: [ChatConversation], query: String, pinned: Set<UUID>, pinOrder: [UUID],
        now: Date = .now, calendar: Calendar = .current
    ) -> [ConversationListModel.Section] {
        let searching = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let key = Key(
            items: conversations.map {
                .init(id: $0.id, title: $0.title, modelId: $0.modelId, createdAt: $0.createdAt,
                      messageCount: searching ? $0.messages.count : 0,
                      lastMessageLength: searching ? ($0.messages.last?.content.count ?? 0) : 0)
            },
            query: query, pinned: pinned, pinOrder: pinOrder, day: calendar.startOfDay(for: now)
        )
        if key == self.key { return value }
        computeCount += 1
        self.key = key
        value = ConversationListModel.sections(conversations, query: query, pinned: pinned, pinOrder: pinOrder, now: now, calendar: calendar)
        return value
    }
}

/// Persisted, ordered set of pinned conversation IDs. Takes its defaults as a
/// seam so tests never touch the real preferences.
final class ConversationPinStore: ObservableObject {
    private let defaults: UserDefaults
    private let key: String
    @Published private(set) var order: [UUID]

    init(defaults: UserDefaults = .standard, key: String) {
        self.defaults = defaults
        self.key = key
        let raw = defaults.stringArray(forKey: key) ?? []
        var seen = Set<UUID>()
        order = raw.compactMap(UUID.init(uuidString:)).filter { seen.insert($0).inserted }
    }

    var ids: Set<UUID> { Set(order) }

    func isPinned(_ id: UUID) -> Bool { order.contains(id) }

    func toggle(_ id: UUID) {
        if let index = order.firstIndex(of: id) { order.remove(at: index) } else { order.append(id) }
        save()
    }

    /// Moves `id` to sit immediately before `target`. Unknown IDs are a no-op.
    func move(_ id: UUID, before target: UUID) {
        guard id != target, let from = order.firstIndex(of: id), order.contains(target) else { return }
        order.remove(at: from)
        let to = order.firstIndex(of: target) ?? order.endIndex
        order.insert(id, at: to)
        save()
    }

    func prune(existing: Set<UUID>) {
        let kept = order.filter(existing.contains)
        guard kept != order else { return }
        order = kept
        save()
    }

    private func save() { defaults.set(order.map(\.uuidString), forKey: key) }
}

// MARK: Slash commands

enum SlashCommand: Equatable {
    case model(String?)
    case system(String?)
    case clear

    struct Entry: Equatable, Identifiable {
        let name: String
        let summary: String
        var id: String { name }
    }

    static let catalog: [Entry] = [
        Entry(name: "model", summary: "Choose a model"),
        Entry(name: "system", summary: "Set the system prompt"),
        Entry(name: "clear", summary: "Start a new conversation"),
    ]

    /// Only a single-line message that starts with a known command counts, so
    /// file paths and prose are never swallowed.
    static func parse(_ text: String) -> SlashCommand? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("/"), !trimmed.contains("\n") else { return nil }
        let body = trimmed.dropFirst()
        let name = body.prefix { !$0.isWhitespace }
        let argument = body.dropFirst(name.count).trimmingCharacters(in: .whitespaces)
        let arg: String? = argument.isEmpty ? nil : argument
        switch name {
        case "clear": return arg == nil ? .clear : nil
        case "model": return .model(arg)
        case "system": return .system(arg)
        default: return nil
        }
    }

    /// Menu entries while the user is still typing the command word.
    static func suggestions(for text: String) -> [Entry] {
        guard text.hasPrefix("/"), !text.contains(" "), !text.contains("\n") else { return [] }
        let prefix = text.dropFirst().lowercased()
        return catalog.filter { prefix.isEmpty || $0.name.hasPrefix(prefix) }
    }
}

// MARK: Context gauge

struct ContextGauge: Equatable {
    enum Level: Equatable { case normal, warning, critical }

    let usedTokens: Int
    let contextLength: Int

    static func estimateTokens(_ text: String) -> Int { (text.count + 3) / 4 }

    static func make(system: String, messages: [String], draft: String, contextLength: Int?) -> ContextGauge? {
        guard let contextLength, contextLength > 0 else { return nil }
        let used = estimateTokens(system) + messages.reduce(0) { $0 + estimateTokens($1) } + estimateTokens(draft)
        return ContextGauge(usedTokens: used, contextLength: contextLength)
    }

    var fraction: Double { min(1, Double(usedTokens) / Double(contextLength)) }
    var isOver: Bool { usedTokens > contextLength }

    var level: Level {
        if isOver || fraction >= 0.9 { return .critical }
        return fraction >= 0.7 ? .warning : .normal
    }

    var percentText: String { isOver ? "100%+" : "\(Int((fraction * 100).rounded()))%" }

    /// Words and symbols carry the level so colour is never the only signal.
    var statusWord: String {
        switch level {
        case .normal: return "Room left"
        case .warning: return "Getting full"
        case .critical: return "Nearly full"
        }
    }

    var symbol: String {
        switch level {
        case .normal: return "circle.dotted"
        case .warning: return "exclamationmark.circle"
        case .critical: return "exclamationmark.triangle.fill"
        }
    }

    var summary: String { "\(BrowserFormat.context(usedTokens)) / \(BrowserFormat.context(contextLength))" }

    var accessibilityLabel: String {
        "Context window \(percentText) used, \(statusWord). Estimated \(usedTokens) of \(contextLength) tokens."
    }
}

// MARK: Presets

enum GenerationPreset: String, CaseIterable, Identifiable {
    case precise, balanced, creative
    var id: String { rawValue }

    var title: String { rawValue.capitalized }

    /// The only field a preset sets. Everything else is left exactly as the user had it.
    var temperature: Double {
        switch self {
        case .precise: return 0.2
        case .balanced: return 0.7
        case .creative: return 1.1
        }
    }

    func applied(to settings: GenerationSettings) -> GenerationSettings {
        var copy = settings
        copy.temperature = temperature
        return copy
    }

    static func matching(temperature: Double?) -> GenerationPreset? {
        guard let temperature else { return nil }
        return allCases.first { abs($0.temperature - temperature) < 0.001 }
    }
}

// MARK: Header meter and run status

enum ConversationMeter {
    static func text(tokens: Int, cost: Double) -> String {
        guard tokens > 0 else { return "No usage yet" }
        let tokenText = tokens < 1000 ? "\(tokens) tokens" : String(format: "%.1fK tokens", Double(tokens) / 1000)
        guard cost > 0 else { return tokenText }
        let money = cost < 0.01 ? String(format: "$%.4f", cost) : String(format: "$%.2f", cost)
        return "\(tokenText) · \(money)"
    }
}

struct RunStatusSummary: Equatable {
    let turns: Int
    let toolCalls: Int
    let failedToolCalls: Int
    let elapsed: TimeInterval

    var elapsedText: String {
        let total = max(0, Int(elapsed))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    var text: String {
        let turnWord = turns == 1 ? "turn" : "turns"
        let toolWord = toolCalls == 1 ? "tool" : "tools"
        var parts = ["\(turns) \(turnWord)", "\(toolCalls) \(toolWord)"]
        if failedToolCalls > 0 { parts.append("\(failedToolCalls) failed") }
        parts.append(elapsedText)
        return parts.joined(separator: " · ")
    }

    /// Counts only messages after the most recent user message (the current run).
    static func make(messages: [ChatMessage], startedAt: Date?, now: Date) -> RunStatusSummary {
        let start = messages.lastIndex { $0.role == "user" }.map { $0 + 1 } ?? 0
        let run = messages[start...]
        let assistants = run.filter { $0.role == "assistant" }
        let calls = assistants.flatMap { $0.toolCalls ?? [] }
        return RunStatusSummary(
            turns: assistants.count,
            toolCalls: calls.count,
            failedToolCalls: calls.filter(\.isError).count,
            elapsed: startedAt.map { now.timeIntervalSince($0) } ?? 0
        )
    }
}

// MARK: Unread while scrolled

struct UnreadTracker: Equatable {
    private(set) var unread = 0
    private var baseline: Int?

    mutating func update(messageCount: Int, followsLatest: Bool) {
        if followsLatest {
            baseline = messageCount
            unread = 0
            return
        }
        let base = min(baseline ?? messageCount, messageCount)
        baseline = base
        unread = max(0, messageCount - base)
    }

    static func jumpLabel(unread: Int) -> String {
        switch unread {
        case ...0: return "Jump to latest"
        case 1: return "1 new message"
        default: return "\(unread) new messages"
        }
    }
}

// MARK: Undo toast

enum UndoToast {
    static let visibleDuration: TimeInterval = 8

    static func message(deleted count: Int) -> String {
        "Deleted \(count) session\(count == 1 ? "" : "s")"
    }
}

// MARK: Quick sampling ("model default" is a real choice)

/// The quick temperature control. nil means "send nothing" so the provider's
/// own default applies; ORB never invents one.
struct QuickSampling: Equatable {
    var temperature: Double?

    var requestTemperature: Double? { temperature }
    var display: String { temperature.map { String(format: "%.2f", $0) } ?? "Model default" }
    /// Where the slider rests while the value is unset.
    var sliderValue: Double { temperature ?? 0.7 }
}

// MARK: Approval presentation

struct ApprovalPresentation: Equatable {
    enum Risk: Equatable { case elevated, high }

    let risk: Risk
    let title: String
    let symbol: String
    let riskWord: String
    /// The key argument in full (the shell command, file path, URL, script),
    /// or nil when the tool has none. Shown prominently, never truncated.
    let primary: String?
    let primaryLabel: String?
    /// Every argument, pretty-printed. Capped only as a rendering guard.
    let displaySummary: String
    /// Characters of `displaySummary` cut by the rendering cap (0 = none).
    let hiddenCharacters: Int

    /// Rendering guard for pathological payloads (e.g. a whole file being
    /// written). Anything cut is announced, never silently dropped.
    static let displayLimit = 20_000

    static func make(toolName: String, server: String?, summary: String) -> ApprovalPresentation {
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let object = JSONValue.parse(trimmed)?.objectValue
        let (primaryLabel, primary) = primaryArgument(toolName: toolName, arguments: object)
        let pretty = object.map { prettyJSON(.object($0)) } ?? trimmed
        let hidden = max(0, pretty.count - displayLimit)
        let shown = pretty.isEmpty ? "No arguments." : String(pretty.prefix(displayLimit))
        func build(_ risk: Risk, _ title: String, _ symbol: String, _ word: String) -> ApprovalPresentation {
            .init(risk: risk, title: title, symbol: symbol, riskWord: word,
                  primary: primary, primaryLabel: primaryLabel,
                  displaySummary: shown, hiddenCharacters: hidden)
        }
        switch toolName {
        case "run_command":
            return build(.high, "Run a command on this Mac?", "terminal.fill", "High risk")
        case "run_applescript", "computer_action", "open_application", "open_url", "capture_screen", "view_image":
            return build(.high, "Let the agent control this Mac?", "desktopcomputer.trianglebadge.exclamationmark", "High risk")
        default:
            let name = server ?? "an MCP server"
            return build(.elevated, "Allow a tool from \(name)?", "puzzlepiece.extension.fill", "Needs review")
        }
    }

    private static func prettyJSON(_ value: JSONValue) -> String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: value.anyValue, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) else { return value.jsonText }
        return String(decoding: data, as: UTF8.self)
    }

    private static let primaryKeys: [(key: String, label: String)] = [
        ("command", "Command"), ("script", "Script"), ("path", "Path"), ("url", "URL"),
        ("application", "Application"), ("app", "Application"), ("action", "Action"), ("uri", "URI"),
    ]

    private static func primaryArgument(toolName: String, arguments: [String: JSONValue]?) -> (String?, String?) {
        guard let arguments else { return (nil, nil) }
        for candidate in primaryKeys {
            if let value = arguments[candidate.key]?.stringValue, !value.isEmpty {
                return (candidate.label, value)
            }
        }
        return (nil, nil)
    }
}

/// Prompts show one at a time, in arrival order.
struct ApprovalQueue {
    private var requests: [ApprovalCoordinator.Request] = []

    var current: ApprovalCoordinator.Request? { requests.first }
    var waiting: Int { max(0, requests.count - 1) }

    mutating func enqueue(_ request: ApprovalCoordinator.Request) { requests.append(request) }
    mutating func resolve(_ id: UUID) { requests.removeAll { $0.id == id } }
}

// MARK: Composer keys

enum ComposerKeyPolicy {
    /// Shift-Return is always a newline. With `requireCommand`, plain Return is too.
    static func shouldSend(command: Bool, shift: Bool, requireCommand: Bool) -> Bool {
        if shift { return false }
        return requireCommand ? command : true
    }

    static func hint(requireCommand: Bool) -> String {
        requireCommand ? "⌘↩ send · ↩ new line" : "↩ send · ⇧↩ new line"
    }
}

// MARK: Approval presenter

/// Bridges `ApprovalCoordinator` (an actor) to the UI. The coordinator's
/// handler awaits `present`; the sheet calls `decide`. Anything still open
/// when a run stops is denied, so nothing is ever approved by default.
@MainActor
final class ApprovalPresenter: ObservableObject {
    @Published private(set) var queue = ApprovalQueue()
    private var waiting: [UUID: CheckedContinuation<ApprovalCoordinator.Decision, Never>] = [:]

    func present(_ request: ApprovalCoordinator.Request) async -> ApprovalCoordinator.Decision {
        await withCheckedContinuation { continuation in
            waiting[request.id] = continuation
            queue.enqueue(request)
        }
    }

    func decide(_ id: UUID, _ decision: ApprovalCoordinator.Decision) {
        guard let continuation = waiting.removeValue(forKey: id) else { return }
        queue.resolve(id)
        continuation.resume(returning: decision)
    }

    func denyAll() {
        let pending = waiting
        waiting.removeAll()
        queue = ApprovalQueue()
        for continuation in pending.values { continuation.resume(returning: .denied) }
    }
}
