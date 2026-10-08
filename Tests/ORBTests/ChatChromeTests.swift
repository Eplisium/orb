import Testing
import Foundation
@testable import ORB

private func conv(_ title: String, model: String = "openai/gpt", daysAgo: Double = 0, now: Date, mode: PlaygroundMode = .chat) -> ChatConversation {
    ChatConversation(title: title, modelId: model, mode: mode, createdAt: now.addingTimeInterval(-daysAgo * 86_400))
}

private func freshDefaults() -> UserDefaults {
    let name = "orb.tests.chrome.\(UUID().uuidString)"
    let d = UserDefaults(suiteName: name)!
    d.removePersistentDomain(forName: name)
    return d
}

private var calendar: Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(secondsFromGMT: 0)!
    return c
}

// 2026-10-01 15:00 UTC
private let now = Date(timeIntervalSince1970: 1_790_866_800)

// MARK: - Sidebar search, grouping and pinning

@Suite("Phase 5 chrome: conversation list")
struct ConversationListModelTests {
    @Test("Search matches title or model, case-insensitively, and trims whitespace")
    func search() {
        let list = [
            conv("Trip planning", now: now),
            conv("Refactor", model: "anthropic/claude-sonnet", now: now),
            conv("Recipes", now: now),
        ]
        #expect(ConversationListModel.filter(list, query: "  TRIP ").map(\.title) == ["Trip planning"])
        #expect(ConversationListModel.filter(list, query: "claude").map(\.title) == ["Refactor"])
        #expect(ConversationListModel.filter(list, query: "").count == 3)
        #expect(ConversationListModel.filter(list, query: "zzz").isEmpty)
    }

    @Test("Search also finds message text")
    func searchBody() {
        var c = conv("Untitled", now: now)
        c.messages = [ChatMessage(role: "user", content: "How do I bake sourdough?")]
        #expect(ConversationListModel.filter([c], query: "sourdough").count == 1)
    }

    @Test("Sections: Pinned first, then Today, Yesterday, Previous 7 Days, Older; empty ones omitted")
    func sections() {
        let list = [
            conv("a-today", now: now),
            conv("b-yesterday", daysAgo: 1, now: now),
            conv("c-week", daysAgo: 4, now: now),
            conv("d-old", daysAgo: 40, now: now),
            conv("e-pinned-old", daysAgo: 90, now: now),
        ]
        let pinned: Set<UUID> = [list[4].id]
        let sections = ConversationListModel.sections(list, pinned: pinned, now: now, calendar: calendar)
        #expect(sections.map(\.title) == ["Pinned", "Today", "Yesterday", "Previous 7 Days", "Older"])
        #expect(sections[0].items.map(\.title) == ["e-pinned-old"])
        #expect(sections.flatMap(\.items).count == 5, "a pinned item appears once, not twice")
    }

    @Test("Within a section newest first; no pinned section when nothing is pinned")
    func order() {
        let list = [conv("older", daysAgo: 0.2, now: now), conv("newer", daysAgo: 0.1, now: now)]
        let sections = ConversationListModel.sections(list, pinned: [], now: now, calendar: calendar)
        #expect(sections.map(\.title) == ["Today"])
        #expect(sections[0].items.map(\.title) == ["newer", "older"])
    }

    @Test("Pinned items keep the user's pin order, not date order")
    func pinOrder() {
        let a = conv("A", daysAgo: 1, now: now), b = conv("B", daysAgo: 5, now: now), c = conv("C", daysAgo: 2, now: now)
        let order = [b.id, c.id, a.id]
        let sections = ConversationListModel.sections([a, b, c], pinned: Set(order), pinOrder: order, now: now, calendar: calendar)
        #expect(sections[0].items.map(\.title) == ["B", "C", "A"])
    }

    @Test("Search applies inside sections and keeps pinned grouping")
    func searchAndSections() {
        let a = conv("Alpha", now: now), b = conv("Beta", now: now)
        let sections = ConversationListModel.sections([a, b], query: "alp", pinned: [b.id], now: now, calendar: calendar)
        #expect(sections.map(\.title) == ["Today"])
        #expect(sections[0].items.map(\.title) == ["Alpha"])
    }
}

@Suite("Phase 5 chrome: pin store")
struct ConversationPinStoreTests {
    @Test("Toggle pins and unpins, preserving order")
    func toggle() {
        let store = ConversationPinStore(defaults: freshDefaults(), key: "pins")
        let a = UUID(), b = UUID()
        store.toggle(a); store.toggle(b)
        #expect(store.order == [a, b])
        store.toggle(a)
        #expect(store.order == [b])
        #expect(store.isPinned(b))
        #expect(!store.isPinned(a))
    }

    @Test("Pins persist across instances and ignore garbage")
    func persistence() {
        let defaults = freshDefaults()
        let a = UUID()
        ConversationPinStore(defaults: defaults, key: "pins").toggle(a)
        defaults.set(["not-a-uuid", a.uuidString], forKey: "pins")
        #expect(ConversationPinStore(defaults: defaults, key: "pins").order == [a])
    }

    @Test("Move reorders pinned items")
    func move() {
        let store = ConversationPinStore(defaults: freshDefaults(), key: "pins")
        let ids = (0..<3).map { _ in UUID() }
        ids.forEach(store.toggle)
        store.move(ids[2], before: ids[0])
        #expect(store.order == [ids[2], ids[0], ids[1]])
        store.move(ids[2], before: UUID())
        #expect(store.order == [ids[2], ids[0], ids[1]], "unknown target is a no-op")
    }

    @Test("Prune drops IDs for conversations that no longer exist")
    func prune() {
        let store = ConversationPinStore(defaults: freshDefaults(), key: "pins")
        let keep = UUID(), gone = UUID()
        store.toggle(keep); store.toggle(gone)
        store.prune(existing: [keep])
        #expect(store.order == [keep])
    }
}

// MARK: - Composer: slash commands, gauge

@Suite("Phase 5 chrome: slash commands")
struct SlashCommandTests {
    @Test("Recognises /model, /system, /clear with arguments")
    func parse() {
        #expect(SlashCommand.parse("/clear") == .clear)
        #expect(SlashCommand.parse("  /clear  ") == .clear)
        #expect(SlashCommand.parse("/model") == .model(nil))
        #expect(SlashCommand.parse("/model gpt") == .model("gpt"))
        #expect(SlashCommand.parse("/system Be terse.") == .system("Be terse."))
        #expect(SlashCommand.parse("/system") == .system(nil))
    }

    @Test("Ordinary text, paths and unknown commands are not commands")
    func notCommands() {
        #expect(SlashCommand.parse("hello") == nil)
        #expect(SlashCommand.parse("/Users/me/file.txt please read") == nil)
        #expect(SlashCommand.parse("/unknown") == nil)
        #expect(SlashCommand.parse("say /clear") == nil)
        #expect(SlashCommand.parse("") == nil)
    }

    @Test("Multi-line messages are never commands")
    func multiline() {
        #expect(SlashCommand.parse("/clear\nand more") == nil)
    }

    @Test("Suggestions filter by prefix while typing a bare command")
    func suggestions() {
        #expect(SlashCommand.suggestions(for: "/").count == SlashCommand.catalog.count)
        #expect(SlashCommand.suggestions(for: "/m").map(\.name) == ["model"])
        #expect(SlashCommand.suggestions(for: "/model foo").isEmpty)
        #expect(SlashCommand.suggestions(for: "hi").isEmpty)
    }
}

@Suite("Phase 5 chrome: context gauge")
struct ContextGaugeTests {
    @Test("Token estimate is ceil(chars / 4) and zero for empty")
    func estimate() {
        #expect(ContextGauge.estimateTokens("") == 0)
        #expect(ContextGauge.estimateTokens("abcd") == 1)
        #expect(ContextGauge.estimateTokens("abcde") == 2)
    }

    @Test("Used counts system prompt, messages and the draft")
    func used() {
        let g = ContextGauge.make(system: "abcd", messages: ["abcdefgh"], draft: "abcd", contextLength: 100)
        #expect(g?.usedTokens == 1 + 2 + 1)
    }

    @Test("Levels switch at 70% and 90% and always carry wording, not just colour")
    func levels() {
        let ok = ContextGauge.make(system: "", messages: [String(repeating: "a", count: 4 * 50)], draft: "", contextLength: 100)!
        let warn = ContextGauge.make(system: "", messages: [String(repeating: "a", count: 4 * 75)], draft: "", contextLength: 100)!
        let crit = ContextGauge.make(system: "", messages: [String(repeating: "a", count: 4 * 95)], draft: "", contextLength: 100)!
        #expect(ok.level == .normal && warn.level == .warning && crit.level == .critical)
        #expect(ok.accessibilityLabel.contains("50%"))
        #expect(warn.statusWord == "Getting full")
        #expect(crit.statusWord == "Nearly full")
        #expect(ok.statusWord.isEmpty == false)
        #expect(Set([ok.symbol, warn.symbol, crit.symbol]).count == 3, "symbols differ per level")
    }

    @Test("Fraction is clamped to 1 and over-limit is critical")
    func overflow() {
        let g = ContextGauge.make(system: "", messages: [String(repeating: "a", count: 4000)], draft: "", contextLength: 100)!
        #expect(g.fraction == 1)
        #expect(g.level == .critical)
        #expect(g.percentText == "100%+")
    }

    @Test("Unknown or zero context length hides the gauge")
    func unknown() {
        #expect(ContextGauge.make(system: "", messages: [], draft: "x", contextLength: nil) == nil)
        #expect(ContextGauge.make(system: "", messages: [], draft: "x", contextLength: 0) == nil)
    }

    @Test("Summary text is compact and uses thousands suffixes")
    func summary() {
        let g = ContextGauge.make(system: "", messages: [String(repeating: "a", count: 4 * 2_000)], draft: "", contextLength: 128_000)!
        #expect(g.summary == "2K / 128K")
    }
}

// MARK: - Presets and cost meter

@Suite("Phase 5 chrome: presets")
struct GenerationPresetTests {
    @Test("Preset temperatures are ordered and within range")
    func ordering() {
        let t = GenerationPreset.allCases.map(\.temperature)
        #expect(t == t.sorted())
        #expect(t.allSatisfy { (0...2).contains($0) })
        #expect(GenerationPreset.allCases.map(\.title) == ["Precise", "Balanced", "Creative"])
    }

    @Test("Applying a preset changes only sampling fields")
    func apply() {
        var s = GenerationSettings.default
        s.webSearch = true
        s.seed = 7
        s.reasoning.effort = .high
        let out = GenerationPreset.creative.applied(to: s)
        #expect(out.temperature == GenerationPreset.creative.temperature)
        #expect(out.webSearch && out.seed == 7 && out.reasoning.effort == .high)
    }

    @Test("Matching recognises a preset by temperature, nil otherwise")
    func matching() {
        #expect(GenerationPreset.matching(temperature: GenerationPreset.precise.temperature) == .precise)
        #expect(GenerationPreset.matching(temperature: 0.123) == nil)
    }
}

@Suite("Phase 5 chrome: header meter and run status")
struct HeaderMeterTests {
    @Test("Cost meter text: tokens always, cost only when known")
    func meter() {
        #expect(ConversationMeter.text(tokens: 0, cost: 0) == "No usage yet")
        #expect(ConversationMeter.text(tokens: 1_234, cost: 0) == "1.2K tokens")
        #expect(ConversationMeter.text(tokens: 1_234, cost: 0.0042) == "1.2K tokens · $0.0042")
        #expect(ConversationMeter.text(tokens: 900, cost: 1.5) == "900 tokens · $1.50")
    }

    @Test("Compact meter keeps the single most useful figure for narrow headers")
    func compactMeter() {
        #expect(ConversationMeter.compactText(tokens: 0, cost: 0) == nil)
        #expect(ConversationMeter.compactText(tokens: 18_300, cost: 0) == "18.3K")
        #expect(ConversationMeter.compactText(tokens: 18_300, cost: 0.0098) == "$0.0098")
        #expect(ConversationMeter.compactText(tokens: 900, cost: 1.5) == "$1.50")
    }

    @Test("Run status counts assistant turns and tool calls and reports elapsed")
    func runStatus() {
        var call = ToolCallDisplay(id: "1", name: "run_command", argumentsSummary: "ls")
        var assistant1 = ChatMessage(role: "assistant", content: "x")
        assistant1.toolCalls = [call, call]
        call.isError = true
        var assistant2 = ChatMessage(role: "assistant", content: "y")
        assistant2.toolCalls = [call]
        let msgs = [ChatMessage(role: "user", content: "go"), assistant1, ChatMessage(role: "tool", content: "r"), assistant2]
        let start = Date(timeIntervalSince1970: 1_000)
        let s = RunStatusSummary.make(messages: msgs, startedAt: start, now: Date(timeIntervalSince1970: 1_000 + 75))
        #expect(s.turns == 2)
        #expect(s.toolCalls == 3)
        #expect(s.failedToolCalls == 1)
        #expect(s.elapsedText == "1:15")
        #expect(s.text.contains("2 turns") && s.text.contains("3 tools"))
    }

    @Test("Singular wording and no start time")
    func singular() {
        let msgs = [ChatMessage(role: "assistant", content: "x")]
        let s = RunStatusSummary.make(messages: msgs, startedAt: nil, now: .now)
        #expect(s.text.hasPrefix("1 turn"))
        #expect(s.elapsedText == "0:00")
    }

    @Test("Only the current run's messages count: messages before the last user message are ignored")
    func currentRunOnly() {
        let msgs = [
            ChatMessage(role: "user", content: "old"), ChatMessage(role: "assistant", content: "a"),
            ChatMessage(role: "user", content: "new"), ChatMessage(role: "assistant", content: "b"),
        ]
        #expect(RunStatusSummary.make(messages: msgs, startedAt: nil, now: .now).turns == 1)
    }
}

// MARK: - Scroll affordance

@Suite("Phase 5 chrome: unread-while-scrolled")
struct UnreadIndicatorTests {
    @Test("Counts messages added after the user scrolled away; resets when following")
    func counting() {
        var u = UnreadTracker()
        u.update(messageCount: 5, followsLatest: true)
        #expect(u.unread == 0)
        u.update(messageCount: 5, followsLatest: false)
        u.update(messageCount: 7, followsLatest: false)
        #expect(u.unread == 2)
        u.update(messageCount: 7, followsLatest: true)
        #expect(u.unread == 0)
    }

    @Test("Deleting messages never produces a negative count")
    func shrink() {
        var u = UnreadTracker()
        u.update(messageCount: 5, followsLatest: false)
        u.update(messageCount: 3, followsLatest: false)
        #expect(u.unread == 0)
        u.update(messageCount: 4, followsLatest: false)
        #expect(u.unread == 1)
    }

    @Test("Jump label pluralises")
    func label() {
        #expect(UnreadTracker.jumpLabel(unread: 0) == "Jump to latest")
        #expect(UnreadTracker.jumpLabel(unread: 1) == "1 new message")
        #expect(UnreadTracker.jumpLabel(unread: 3) == "3 new messages")
    }
}
