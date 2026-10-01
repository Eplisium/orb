import SwiftUI

// MARK: - App shell model (Phase 2)
//
// Pure, testable description of the shell: sidebar grouping, keyboard
// shortcut table, command routing and launch/restore resolution. Views in
// ContentView / CommandPalette / ORBApp only consume these.

enum ORBShell {
    /// One-line fallback to the old hidden title bar window style.
    static let useHiddenTitleBar = false
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

    static let cheatSheet: [Entry] = [
        Entry(keys: "⌘K", title: "Command palette"),
        Entry(keys: "⌘1…9", title: "Jump to section (sidebar order)"),
        Entry(keys: "⌘N", title: "New chat"),
        Entry(keys: "⇧⌘N", title: "New agent session"),
        Entry(keys: "⌘R", title: "Refresh models"),
        Entry(keys: "⌘F", title: "Find models"),
        Entry(keys: "⌘/", title: "Keyboard shortcuts"),
        Entry(keys: "⌘,", title: "Settings"),
    ]
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
    case openConversation(UUID, PlaygroundMode)

    /// The section the action navigates to, if any.
    var targetSection: SidebarSection? {
        switch self {
        case .section(let s): return s
        case .newChat: return .chat
        case .newAgent: return .agent
        case .selectModel: return .allModels
        case .openConversation(_, let mode): return mode == .chat ? .chat : .agent
        case .refreshModels, .toggleSidebar, .openSettings, .showShortcuts, .showPalette: return nil
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
    func send(_ action: ShellAction) { pending = ShellRequest(action: action) }
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

    static let lowBalanceThreshold = 1.0

    static func make(hasManagementKey: Bool, remaining: Double?, isLoading: Bool, hasError: Bool) -> AccountChipState {
        guard hasManagementKey else {
            return AccountChipState(title: "Account", subtitle: "Add a management key for credits", isLow: false)
        }
        if let remaining {
            let low = remaining < lowBalanceThreshold
            return AccountChipState(
                title: String(format: "$%.2f", remaining),
                subtitle: low ? "Credits low" : "Credits remaining",
                isLow: low
            )
        }
        if isLoading { return AccountChipState(title: "Loading…", subtitle: "Credits", isLow: false) }
        if hasError { return AccountChipState(title: "Account", subtitle: "Credits unavailable", isLow: false) }
        return AccountChipState(title: "Account", subtitle: "Credits", isLow: false)
    }
}
