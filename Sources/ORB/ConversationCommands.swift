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
/// shortcuts (⌘N, ⇧⌘N, ⌘F, ⌘K, ⌘R, ⌘/, ⌘1…9, ⇧⌘C) and the Model menu
/// (⌘D, ⇧⌘C, ⌘↩, ⌘K).
enum ConversationShortcuts {
    static let stop = KeyboardShortcut(".", modifiers: .command)
    static let regenerate = KeyboardShortcut("r", modifiers: [.command, .shift])
    static let copyLastReply = KeyboardShortcut("c", modifiers: [.command, .option])
    static let export = KeyboardShortcut("e", modifiers: .command)
    static let searchSessions = KeyboardShortcut("f", modifiers: [.command, .option])
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
