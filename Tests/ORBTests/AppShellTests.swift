import Testing
import Foundation
@testable import ORB

@Suite("Phase 2 shell: fuzzy matcher")
struct FuzzyMatcherTests {
    @Test("Non-subsequence queries do not match; empty query matches everything")
    func basicMatching() {
        #expect(FuzzyMatcher.score(query: "xyz", in: "Test Suite") == nil)
        #expect(FuzzyMatcher.score(query: "", in: "Anything") == 0)
        #expect(FuzzyMatcher.score(query: "tst", in: "Test Suite") != nil)
        #expect(FuzzyMatcher.score(query: "TEST", in: "test suite") != nil)
    }

    @Test("Exact beats prefix beats word-start beats scattered")
    func rankingOrder() throws {
        let exact = try #require(FuzzyMatcher.score(query: "chat", in: "Chat"))
        let prefix = try #require(FuzzyMatcher.score(query: "chat", in: "Chat history"))
        let wordStart = try #require(FuzzyMatcher.score(query: "chat", in: "New Chat"))
        let scattered = try #require(FuzzyMatcher.score(query: "chat", in: "Check the latest"))
        #expect(exact > prefix)
        #expect(prefix > wordStart)
        #expect(wordStart > scattered)
    }

    @Test("Initial-letter abbreviations match across word boundaries")
    func abbreviation() throws {
        let ts = try #require(FuzzyMatcher.score(query: "ts", in: "Test Suite"))
        let loose = try #require(FuzzyMatcher.score(query: "ts", in: "Settings"))
        #expect(ts > loose)
    }

    @Test("Query order matters")
    func orderMatters() {
        #expect(FuzzyMatcher.score(query: "tset", in: "Test Suite") == nil)
    }
}

@Suite("Phase 2 shell: palette index")
struct PaletteIndexTests {
    private func index(models: Int = 10, conversations: Int = 10) -> PaletteIndex {
        PaletteIndex(
            favoriteModels: (0..<models).map { PaletteModel(id: "p/model-\($0)", name: "Model \($0)") },
            conversations: (0..<conversations).map {
                PaletteConversation(id: UUID(), title: "Talk \($0)", mode: $0.isMultiple(of: 2) ? .chat : .agent,
                                    createdAt: Date(timeIntervalSince1970: Double($0)))
            }
        )
    }

    @Test("Empty query lists every section and action, and caps models/conversations")
    func emptyQueryGroupingAndLimits() {
        let groups = index().results(query: "")
        #expect(groups.map(\.group) == [.sections, .actions, .models, .conversations])
        #expect(groups[0].items.count == ShellShortcuts.sidebarOrder.count)
        #expect(groups[1].items.count == PaletteIndex.actionItems.count)
        #expect(groups[2].items.count == PaletteIndex.emptyQueryLimit)
        #expect(groups[3].items.count == PaletteIndex.emptyQueryLimit)
    }

    @Test("Newest conversations come first")
    func conversationsNewestFirst() {
        let groups = index().results(query: "")
        let titles = groups.first { $0.group == .conversations }!.items.map(\.title)
        #expect(titles.first == "Talk 9")
    }

    @Test("Sections never include Account and follow sidebar order")
    func sectionsOrder() {
        let items = index(models: 0, conversations: 0).results(query: "")[0].items
        #expect(items.compactMap { item -> SidebarSection? in
            if case .section(let s) = item.action { return s } else { return nil }
        } == ShellShortcuts.sidebarOrder)
        #expect(!ShellShortcuts.sidebarOrder.contains(.account))
    }

    @Test("Empty groups are omitted")
    func emptyGroupsOmitted() {
        let groups = index(models: 0, conversations: 0).results(query: "")
        #expect(groups.map(\.group) == [.sections, .actions])
    }

    @Test("Query filters, ranks within groups and caps results")
    func queryFiltering() {
        let groups = index().results(query: "model-")
        #expect(groups.map(\.group) == [.models])
        #expect(groups[0].items.count == PaletteIndex.queryLimit)
        let chat = index().results(query: "chat")
        #expect(chat[0].group == .sections)
        #expect(chat[0].items.first?.title == "Chat")
    }

    @Test("Selecting a favourite model and a conversation yields the right actions")
    func actions() {
        let idx = index(models: 2, conversations: 2)
        let model = idx.results(query: "Model 1").first { $0.group == .models }?.items.first
        #expect(model?.action == .selectModel("p/model-1"))
        let conv = idx.results(query: "Talk 0").first { $0.group == .conversations }?.items.first
        if case .openConversation(_, let mode)? = conv?.action { #expect(mode == .chat) } else { Issue.record("wrong action") }
    }

    @Test("Flat order follows group order")
    func flatten() {
        let flat = PaletteIndex.flatten(index().results(query: ""))
        #expect(flat.first?.group == .sections)
        #expect(flat.count == ShellShortcuts.sidebarOrder.count + PaletteIndex.actionItems.count + 10)
    }

    @Test("No match yields no groups")
    func noMatch() {
        #expect(index().results(query: "zzzzqqq").isEmpty)
    }
}

@Suite("Phase 2 shell: sections, shortcuts, restore")
struct ShellShortcutsTests {
    @Test("Sidebar groups are Browse / Create / Evaluate in the planned order")
    func groups() {
        #expect(SidebarGroup.allCases.map(\.title) == ["Browse", "Create", "Evaluate"])
        #expect(SidebarGroup.browse.sections == [.allModels, .favorites, .newThisWeek])
        #expect(SidebarGroup.create.sections == [.chat, .agent, .images, .video, .speech, .files, .embeddings])
        #expect(SidebarGroup.evaluate.sections == [.testSuite])
    }

    @Test("Every section except Account appears exactly once in the sidebar")
    func coverage() {
        let order = ShellShortcuts.sidebarOrder
        #expect(Set(order).count == order.count)
        #expect(Set(order) == Set(SidebarSection.allCases).subtracting([.account]))
    }

    @Test("Cmd+1…9 map to the first nine sections in sidebar order")
    func digitMapping() {
        #expect(ShellShortcuts.numberedSections.count == 9)
        #expect(ShellShortcuts.numberedSections == Array(ShellShortcuts.sidebarOrder.prefix(9)))
        #expect(ShellShortcuts.section(forDigit: 1) == .allModels)
        #expect(ShellShortcuts.section(forDigit: 4) == .chat)
        #expect(ShellShortcuts.section(forDigit: 9) == .files)
        #expect(ShellShortcuts.section(forDigit: 0) == nil)
        #expect(ShellShortcuts.section(forDigit: 10) == nil)
        #expect(ShellShortcuts.digit(for: .agent) == 5)
        #expect(ShellShortcuts.digit(for: .embeddings) == nil)
    }

    @Test("Cmd+N / Cmd+Shift+N map to chat and agent sessions")
    func newSessionMapping() {
        #expect(ShellAction.newChat.targetSection == .chat)
        #expect(ShellAction.newAgent.targetSection == .agent)
        #expect(ShellAction.section(.images).targetSection == .images)
        #expect(ShellAction.refreshModels.targetSection == nil)
        #expect(ShellAction.selectModel("a/b").targetSection == .allModels)
        #expect(ShellAction.openConversation(UUID(), .agent).targetSection == .agent)
    }

    @Test("Cheat sheet lists every global shortcut once")
    func cheatSheet() {
        let keys = ShellShortcuts.cheatSheet.map(\.keys)
        #expect(Set(keys).count == keys.count)
        for needed in ["⌘K", "⌘N", "⇧⌘N", "⌘R", "⌘F", "⌘/", "⌘,", "⌘1…9"] {
            #expect(keys.contains(needed), "missing \(needed)")
        }
    }

    @Test("Restore: valid stored value wins, unknown/Account fall back, launch override wins")
    func restore() {
        #expect(ShellRestore.resolve(startOverride: nil, stored: "Chat") == .chat)
        #expect(ShellRestore.resolve(startOverride: nil, stored: "Nope") == .allModels)
        #expect(ShellRestore.resolve(startOverride: nil, stored: "") == .allModels)
        #expect(ShellRestore.resolve(startOverride: nil, stored: nil) == .allModels)
        #expect(ShellRestore.resolve(startOverride: nil, stored: "Account") == .allModels)
        #expect(ShellRestore.resolve(startOverride: "Video", stored: "Chat") == .video)
        #expect(ShellRestore.resolve(startOverride: "Bogus", stored: "Chat") == .chat)
    }

    @Test("Filter effects unchanged for the regrouped sections")
    func filterEffectsUnchanged() {
        #expect(AppRouter.filterEffects(for: .favorites).showFavoritesOnly)
        #expect(AppRouter.filterEffects(for: .newThisWeek).showNewThisWeek)
        for s in ShellShortcuts.sidebarOrder where s != .favorites && s != .newThisWeek {
            #expect(AppRouter.filterEffects(for: s) == AppFilterEffects(showFavoritesOnly: false, showNewThisWeek: false))
        }
    }

    @Test("Titles are the display names and the hidden-title-bar fallback flag is off")
    func titlesAndFlag() {
        #expect(SidebarSection.newThisWeek.title == "New Models")
        #expect(ORBShell.useHiddenTitleBar == false)
        #expect(ORBShell.minimumWindowSize.width == 960 && ORBShell.minimumWindowSize.height == 640)
    }
}

@Suite("Phase 2 shell: account chip")
struct AccountChipStateTests {
    @Test("No management key → neutral state that opens Settings")
    func noKey() {
        let s = AccountChipState.make(hasManagementKey: false, remaining: nil, isLoading: false, hasError: false)
        #expect(s.title == "Account")
        #expect(s.subtitle == "Add key to see credits")
        #expect(s.help.contains("management key"))
    }

    @Test("Loaded credits are formatted; loading and error are distinct")
    func states() {
        #expect(AccountChipState.make(hasManagementKey: true, remaining: 12.346, isLoading: false, hasError: false).title == "$12.35")
        #expect(AccountChipState.make(hasManagementKey: true, remaining: nil, isLoading: true, hasError: false).title == "Loading…")
        #expect(AccountChipState.make(hasManagementKey: true, remaining: nil, isLoading: false, hasError: true).subtitle == "Credits unavailable")
        #expect(AccountChipState.make(hasManagementKey: true, remaining: -1, isLoading: false, hasError: false).isLow)
    }
}

@MainActor
@Suite("Phase 2 shell: controller")
struct ShellControllerTests {
    @Test("Sending publishes a request that can be consumed once")
    func sendConsume() {
        let c = ShellController()
        c.send(.newChat)
        #expect(c.pending?.action == .newChat)
        c.pending = nil
        #expect(c.pending == nil)
    }

    @Test("Two identical sends are distinct requests")
    func distinct() {
        let c = ShellController()
        c.send(.refreshModels)
        let first = c.pending
        c.send(.refreshModels)
        #expect(first != c.pending)
    }
}
