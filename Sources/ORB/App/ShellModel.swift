import SwiftUI

// MARK: - App shell model (Phase 2)
//
// Pure, testable description of the shell: sidebar grouping, keyboard
// shortcut table, command routing and launch/restore resolution. Views in
// ContentView / CommandPalette / ORBApp only consume these.

enum ORBShell {
    /// One-line fallback to the old hidden title bar window style.
    static let useHiddenTitleBar = false
    /// The single main window's scene id (`openWindow(id:)`).
    static let mainWindowID = "main"
    static let minimumWindowSize = CGSize(width: 960, height: 640)
    static let startSectionDefaultsKey = "orb.startSection"
    static let sectionStorageKey = "orb.shell.section"
    static let sidebarHiddenStorageKey = "orb.shell.sidebarHidden"
}

/// Sidebar groups in display order. Account is intentionally absent: it
/// lives in the Settings scene and the sidebar footer chip.
enum SidebarGroup: String, CaseIterable, Identifiable {
    case browse, create, evaluate

    var id: String { rawValue }

    var title: String {
        switch self {
        case .browse: return "Browse"
        case .create: return "Create"
        case .evaluate: return "Evaluate"
        }
    }

    var sections: [SidebarSection] {
        switch self {
        case .browse: return [.allModels, .favorites, .newThisWeek]
        case .create: return [.chat, .agent, .images, .video, .speech, .files, .embeddings]
        case .evaluate: return [.testSuite]
        }
    }
}

enum ShellShortcuts {
    /// Every sidebar section in visual order.
    static let sidebarOrder: [SidebarSection] = SidebarGroup.allCases.flatMap(\.sections)

    /// Sections reachable with ⌘1…⌘9.
    static let numberedSections: [SidebarSection] = Array(sidebarOrder.prefix(9))

    static func section(forDigit digit: Int) -> SidebarSection? {
        guard (1...numberedSections.count).contains(digit) else { return nil }
        return numberedSections[digit - 1]
    }

    static func digit(for section: SidebarSection) -> Int? {
        numberedSections.firstIndex(of: section).map { $0 + 1 }
    }

    struct Entry: Equatable {
        let keys: String
        let title: String
    }

    struct EntryGroup: Equatable, Identifiable {
        let title: String
        let entries: [Entry]
        var id: String { title }
    }

    /// The ⌘/ sheet, grouped by menu. Built from `ShortcutCommand` and
    /// `ConversationShortcuts`, the same tables the menus bind, so every
    /// bound chord appears exactly once.
    static var cheatSheetGroups: [EntryGroup] {
        func entry(_ c: ShortcutCommand) -> Entry { Entry(keys: c.combo.display, title: c.title) }
        let conversation: [(KeyboardShortcut, String)] = [
            (ConversationShortcuts.stop, "Stop response"),
            (ConversationShortcuts.regenerate, "Regenerate response"),
            (ConversationShortcuts.copyLastReply, "Copy last reply"),
            (ConversationShortcuts.export, "Export conversation"),
            (ConversationShortcuts.chooseModel, "Choose model"),
            (ConversationShortcuts.findInConversation, "Find in conversation"),
            (ConversationShortcuts.searchSessions, "Search sessions"),
        ]
        return [
            EntryGroup(title: "General", entries: [
                entry(.palette), entry(.find), entry(.refresh), entry(.settings),
                entry(.shortcuts), entry(.lockNow),
            ]),
            EntryGroup(title: "Go", entries:
                [Entry(keys: "⌘1…9", title: "Jump to section (sidebar order)"),
                 entry(.sectionEmbeddings), entry(.sectionTestSuite), entry(.toggleSidebar)]),
            EntryGroup(title: "File", entries: [entry(.newChat), entry(.newAgent)]),
            EntryGroup(title: "Conversation", entries: conversation.map {
                Entry(keys: KeyCombo($0.0).display, title: $0.1)
            }),
            EntryGroup(title: "Model", entries: [
                entry(.toggleFavorite), entry(.copyModelID), entry(.chatWithModel), entry(.openCompare),
            ]),
        ]
    }

    /// Every cheat-sheet row, in display order.
    static var cheatSheet: [Entry] { cheatSheetGroups.flatMap(\.entries) }

    /// Sidebar tooltip: "Embeddings (⌘0)".
    static func sidebarHelp(for section: SidebarSection) -> String {
        shortcutDisplay(for: section).map { "\(section.title) (\($0))" } ?? section.title
    }
}

/// What ⌘F does where you are. macOS users expect Find to search the
/// current context: the model list in a browser section (without leaving
/// Favorites or New This Week), the session list in Chat or Agent, and
/// nothing in sections that have no search.
enum FindTarget: Equatable {
    case browserSearch(SidebarSection)
    case sessionSearch
    case unavailable

    var menuTitle: String {
        switch self {
        case .browserSearch: return "Find Models"
        case .sessionSearch: return "Find Sessions"
        case .unavailable: return "Find"
        }
    }
}

enum FindRouting {
    /// - Parameters:
    ///   - section: the visible section, when known.
    ///   - hasSessionSearch: a Chat/Agent view is focused and offers
    ///     session search (its `ConversationActions.searchSessions`).
    static func target(for section: SidebarSection?, hasSessionSearch: Bool) -> FindTarget {
        guard let section else {
            // Unknown section: prefer the conversation that has focus.
            return hasSessionSearch ? .sessionSearch : .browserSearch(.allModels)
        }
        if section.isBrowser { return .browserSearch(section) }
        if section == .chat || section == .agent { return hasSessionSearch ? .sessionSearch : .unavailable }
        return .unavailable
    }
}

/// Everything the menu, toolbar and palette can ask the shell to do.
enum ShellAction: Equatable, Hashable {
    case section(SidebarSection)
    case newChat
    case newAgent
    case refreshModels
    case toggleSidebar
    case openSettings
    case showShortcuts
    case showPalette
    case selectModel(String)
    case compareModels([String])
    case chatWithModel(String)
    case agentWithModel(String)
    case openConversation(UUID, PlaygroundMode)
    // Model menu / deep links.
    case toggleFavorite(String)
    case toggleCompare(String)
    case copyModelID(String)
    case openOnOpenRouter(String)
    case openCompare
    case openCompareWith([String])
    case exportModels(ModelExportFormat)

    /// The section the action navigates to, if any.
    var targetSection: SidebarSection? {
        switch self {
        case .section(let s): return s
        case .newChat: return .chat
        case .newAgent: return .agent
        case .selectModel: return .allModels
        case .compareModels: return .testSuite
        case .chatWithModel: return .chat
        case .agentWithModel: return .agent
        case .openConversation(_, let mode): return mode == .chat ? .chat : .agent
        case .openCompare, .openCompareWith: return .allModels
        case .refreshModels, .toggleSidebar, .openSettings, .showShortcuts, .showPalette,
             .toggleFavorite, .toggleCompare, .copyModelID, .openOnOpenRouter, .exportModels: return nil
        }
    }
}

struct ShellRequest: Equatable {
    let id = UUID()
    let action: ShellAction
}

/// Bridge from App-scene commands to ContentView.
@MainActor
final class ShellController: ObservableObject {
    @Published var pending: ShellRequest?
    /// The browser's selected model, mirrored for the Model menu.
    @Published var focusedModelID: String?
    @Published var focusedModelIsFavorite = false
    /// The focused model is in the compare tray (menu reads "Remove from Compare").
    @Published var focusedModelIsComparing = false
    /// False for batch-only / non-text models: the Model menu disables Chat.
    @Published var focusedModelCanChat = true
    /// The main window's visible section (set by ContentView), so menus
    /// can act on the current context. nil until the window reports it.
    @Published var currentSection: SidebarSection?
    func send(_ action: ShellAction) { pending = ShellRequest(action: action) }

    /// Routes an `orb://` URL; returns false (and does nothing) when the
    /// link isn't understood.
    @discardableResult
    func open(_ url: URL) -> Bool {
        guard let link = DeepLink.parse(url) else { return false }
        send(link.shellAction)
        return true
    }
}

enum ShellRestore {
    /// Launch override (`-orb.startSection`) wins, then the stored scene
    /// value, then All Models. Unknown values and the retired Account
    /// section fall through.
    static func resolve(startOverride: String?, stored: String?) -> SidebarSection {
        if let section = valid(startOverride) { return section }
        if let section = valid(stored) { return section }
        return .allModels
    }

    private static func valid(_ raw: String?) -> SidebarSection? {
        guard let raw, let section = SidebarSection(rawValue: raw), section != .account else { return nil }
        return section
    }
}

struct AccountChipState: Equatable {
    var title: String
    var subtitle: String
    var isLow: Bool

    /// Low balance changes the symbol and wording too, never colour alone.
    var systemImage: String { isLow ? "exclamationmark.triangle.fill" : "person.crop.circle.fill" }
    var accessibilityValue: String { "\(title), \(subtitle)" }

    /// Full explanation for the tooltip; the subtitle itself stays short
    /// enough for the default sidebar width.
    var help: String {
        subtitle == AccountChipState.noManagementKeySubtitle
            ? "Add an optional management key in Settings → Accounts & Keys to see credits and activity (⌘,)"
            : "Account and settings (⌘,)"
    }

    static let lowBalanceThreshold = 1.0
    /// Optional setup, phrased as an action rather than an error ("Management key needed" read as broken).
    static let noManagementKeySubtitle = "Add key to see credits"

    static func make(hasManagementKey: Bool, remaining: Double?, isLoading: Bool, hasError: Bool) -> AccountChipState {
        guard hasManagementKey else {
            return AccountChipState(title: "Account", subtitle: noManagementKeySubtitle, isLow: false)
        }
        if let remaining {
            let low = remaining < lowBalanceThreshold
            return AccountChipState(
                title: ORBMoney.format(remaining),
                subtitle: low ? "Credits low" : "Credits remaining",
                isLow: low
            )
        }
        if isLoading { return AccountChipState(title: "Loading…", subtitle: "Credits", isLow: false) }
        if hasError { return AccountChipState(title: "Account", subtitle: "Credits unavailable", isLow: false) }
        return AccountChipState(title: "Account", subtitle: "Credits", isLow: false)
    }
}
