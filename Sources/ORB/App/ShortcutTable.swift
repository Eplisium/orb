import SwiftUI

// MARK: - Keyboard shortcut table
//
// Single source for menu key equivalents and the ⌘/ cheat sheet, so the two
// cannot drift and a test can prove there are no duplicates.

struct KeyCombo: Hashable, Sendable {
    struct Modifiers: OptionSet, Hashable, Sendable {
        let rawValue: Int
        static let command = Modifiers(rawValue: 1)
        static let shift = Modifiers(rawValue: 2)
        static let option = Modifiers(rawValue: 4)
        static let control = Modifiers(rawValue: 8)
    }

    /// A single character, or "↩" for Return.
    let key: String
    let modifiers: Modifiers

    var display: String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        return s + (key == "↩" ? "↩" : key.uppercased())
    }

    var keyEquivalent: KeyEquivalent { key == "↩" ? .return : KeyEquivalent(Character(key)) }

    var eventModifiers: EventModifiers {
        var m: EventModifiers = []
        if modifiers.contains(.command) { m.insert(.command) }
        if modifiers.contains(.shift) { m.insert(.shift) }
        if modifiers.contains(.option) { m.insert(.option) }
        if modifiers.contains(.control) { m.insert(.control) }
        return m
    }

    static func cmd(_ key: String) -> KeyCombo { KeyCombo(key: key, modifiers: .command) }
    static func shiftCmd(_ key: String) -> KeyCombo { KeyCombo(key: key, modifiers: [.command, .shift]) }
}

/// Every menu command with a key equivalent.
enum ShortcutCommand: String, CaseIterable, Sendable {
    case palette, refresh, newChat, newAgent, find, shortcuts, settings, toggleSidebar
    case toggleFavorite, copyModelID, chatWithModel, openCompare
    case sectionEmbeddings, sectionTestSuite

    var combo: KeyCombo {
        switch self {
        case .palette: return .cmd("k")
        case .refresh: return .cmd("r")
        case .newChat: return .cmd("n")
        case .newAgent: return .shiftCmd("n")
        case .find: return .cmd("f")
        case .shortcuts: return .cmd("/")
        case .settings: return .cmd(",")
        // Provided by SidebarCommands(); listed so nothing else claims it.
        case .toggleSidebar: return KeyCombo(key: "s", modifiers: [.command, .control])
        case .toggleFavorite: return .cmd("d")
        case .copyModelID: return .shiftCmd("c")
        case .chatWithModel: return .cmd("↩")
        case .openCompare: return KeyCombo(key: "c", modifiers: [.command, .option])
        case .sectionEmbeddings: return .cmd("0")
        case .sectionTestSuite: return .shiftCmd("e")
        }
    }

    var title: String {
        switch self {
        case .palette: return "Command palette"
        case .refresh: return "Refresh models"
        case .newChat: return "New chat"
        case .newAgent: return "New agent session"
        case .find: return "Find models"
        case .shortcuts: return "Keyboard shortcuts"
        case .settings: return "Settings"
        case .toggleSidebar: return "Toggle sidebar"
        case .toggleFavorite: return "Favorite / unfavorite selected model"
        case .copyModelID: return "Copy selected model ID"
        case .chatWithModel: return "Chat with selected model"
        case .openCompare: return "Open Compare"
        case .sectionEmbeddings: return "Embeddings"
        case .sectionTestSuite: return "Test Suite"
        }
    }
}

extension ShellShortcuts {
    /// Sections beyond ⌘1…9 and their dedicated commands.
    static let extraSectionCommands: [(SidebarSection, ShortcutCommand)] = [
        (.embeddings, .sectionEmbeddings),
        (.testSuite, .sectionTestSuite),
    ]

    /// The display string for any section's shortcut.
    static func shortcutDisplay(for section: SidebarSection) -> String? {
        if let digit = digit(for: section) { return "⌘\(digit)" }
        return extraSectionCommands.first { $0.0 == section }?.1.combo.display
    }

    /// Every key combo the menus bind (digits included). Must be unique.
    static var allMenuCombos: [KeyCombo] {
        ShortcutCommand.allCases.map(\.combo)
            + (1...numberedSections.count).map { KeyCombo.cmd(String($0)) }
    }
}

// MARK: - Model menu

/// The "Model" menu, acting on the browser's selected model.
struct ModelCommands: Commands {
    @ObservedObject var shell: ShellController

    var body: some Commands {
        CommandMenu("Model") {
            let id = shell.focusedModelID
            Button(shell.focusedModelIsFavorite ? "Remove from Favorites" : "Add to Favorites") {
                if let id { shell.send(.toggleFavorite(id)) }
            }
            .shortcut(.toggleFavorite)
            .disabled(id == nil)
            Button("Add to Compare") { if let id { shell.send(.toggleCompare(id)) } }
                .disabled(id == nil)
            Button("Open Compare") { shell.send(.openCompare) }
                .shortcut(.openCompare)
            Divider()
            Button("Copy Model ID") { if let id { shell.send(.copyModelID(id)) } }
                .shortcut(.copyModelID)
                .disabled(id == nil)
            Button("Chat with Model") { if let id { shell.send(.chatWithModel(id)) } }
                .shortcut(.chatWithModel)
                .disabled(id == nil)
            Button("Open on OpenRouter") { if let id { shell.send(.openOnOpenRouter(id)) } }
                .disabled(id.flatMap(ModelInfo.openRouterURL(for:)) == nil)
            Divider()
            Menu("Export Model List") {
                ForEach(ModelExportFormat.allCases) { format in
                    Button("As \(format.title)…") { shell.send(.exportModels(format)) }
                }
            }
        }
    }
}

extension View {
    func shortcut(_ command: ShortcutCommand) -> some View {
        keyboardShortcut(command.combo.keyEquivalent, modifiers: command.combo.eventModifiers)
    }
}
