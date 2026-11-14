import AppKit
import SwiftUI

/// Actions the focused playground (Chat or Agent) exposes to the menu bar.
/// Each is nil when unavailable, which disables its menu item.
struct ConversationActions {
    var stop: (() -> Void)?
    var regenerate: (() -> Void)?
    var copyLastReply: (() -> Void)?
    var export: (() -> Void)?
    var searchSessions: (() -> Void)?
    /// Opens the playground's model picker.
    var chooseModel: (() -> Void)? = nil
    /// Opens the find bar over the transcript.
    var findInConversation: (() -> Void)? = nil
}

private struct ConversationActionsKey: FocusedValueKey {
    typealias Value = ConversationActions
}

extension FocusedValues {
    var conversationActions: ConversationActions? {
        get { self[ConversationActionsKey.self] }
        set { self[ConversationActionsKey.self] = newValue }
    }
}

/// Shortcuts for the Conversation menu. Chosen to avoid the existing shell
/// shortcuts (⌘N, ⇧⌘N, ⌘F, ⌘K, ⌘R, ⌘/, ⌘0…9, ⇧⌘E) and the Model menu
/// (⌘D, ⇧⌘C, ⌃⌘C, ⌘↩). `ShellShortcuts.allBoundCombos` checks both tables.
/// ⌘F stays the shell's; transcript search uses ⇧⌘F.
enum ConversationShortcuts {
    static let stop = KeyboardShortcut(".", modifiers: .command)
    static let regenerate = KeyboardShortcut("r", modifiers: [.command, .shift])
    static let copyLastReply = KeyboardShortcut("c", modifiers: [.command, .option])
    static let export = KeyboardShortcut("e", modifiers: .command)
    static let searchSessions = KeyboardShortcut("f", modifiers: [.command, .option])
    static let chooseModel = KeyboardShortcut("l", modifiers: .command)
    static let findInConversation = KeyboardShortcut("f", modifiers: [.command, .shift])

    /// Every shortcut above, for the duplicate check.
    static let all = [stop, regenerate, copyLastReply, export, searchSessions, chooseModel, findInConversation]
}

struct ConversationCommands: Commands {
    @FocusedValue(\.conversationActions) private var actions

    var body: some Commands {
        CommandMenu("Conversation") {
            item("Stop Response", actions?.stop, ConversationShortcuts.stop)
            item("Regenerate Response", actions?.regenerate, ConversationShortcuts.regenerate)
            Divider()
            item("Copy Last Reply", actions?.copyLastReply, ConversationShortcuts.copyLastReply)
            item("Export Conversation…", actions?.export, ConversationShortcuts.export)
            Divider()
            item("Choose Model…", actions?.chooseModel, ConversationShortcuts.chooseModel)
            Divider()
            item("Find in Conversation…", actions?.findInConversation, ConversationShortcuts.findInConversation)
            item("Search Sessions", actions?.searchSessions, ConversationShortcuts.searchSessions)
        }
    }

    private func item(_ title: String, _ action: (() -> Void)?, _ shortcut: KeyboardShortcut) -> some View {
        Button(title) { action?() }
            .keyboardShortcut(shortcut)
            .disabled(action == nil)
    }
}

enum ConversationActionLogic {
    /// The newest assistant reply with visible text.
    static func lastReply(in conversation: ChatConversation?) -> String? {
        conversation?.messages.last { $0.role == "assistant" && !$0.content.isEmpty }?.content
    }

    @MainActor
    static func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
