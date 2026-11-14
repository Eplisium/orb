import AppKit
import SwiftUI

// Split out of PlaygroundCommon.swift for readability.
// Shared playground components live in PlaygroundCommon.swift.

// MARK: - Conversation sidebar helpers

private struct ConversationDeleteIsUndoableKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True when sidebar row deletes go through an undoable path.
    var conversationDeleteIsUndoable: Bool {
        get { self[ConversationDeleteIsUndoableKey.self] }
        set { self[ConversationDeleteIsUndoableKey.self] = newValue }
    }
}

/// Which delete a sidebar row performs: one shared rule so Chat and Agent
/// cannot drift apart again (CHAT-10).
enum ConversationRowDeletePolicy {
    static func needsConfirmation(undoable: Bool) -> Bool { !undoable }
}

struct ConversationSidebarHeader: View {
    let title: String
    let subtitle: String
    let icon: String
    let accent: Color
    let onNew: () -> Void
    let newLabel: String
    let newIcon: String
    let disabled: Bool
    var isSelecting: Bool = false
    var canSelect: Bool = false
    var onToggleSelecting: (() -> Void)?

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
                    .orbFont(size: 13, weight: .bold)
                    .foregroundStyle(.white)
            }
            .frame(width: 30, height: 30)

            // One line each at every width: the 224pt sidebar leaves the
            // text column ~90pt beside Select and New, and a wrapped
            // subtitle made the header two rows tall at 960 (V-7). The full
            // subtitle stays in the tooltip.
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .orbFont(size: 14, weight: .semibold)
                    .lineLimit(1)
                Text(subtitle)
                    .orbFont(size: 11, weight: .medium)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .help("\(title) — \(subtitle)")
            .accessibilityElement(children: .combine)
            Spacer(minLength: 4)
            if let onToggleSelecting {
                Button(isSelecting ? "Done" : "Select") {
                    onToggleSelecting()
                }
                .buttonStyle(.plain)
                .orbFont(size: 11, weight: .semibold)
                .foregroundStyle(isSelecting ? accent : .secondary)
                .fixedSize()
                .disabled(!canSelect && !isSelecting)
                .help(isSelecting ? "Exit selection mode" : "Select multiple sessions")
            }
            Menu {
                Button {
                    onNew()
                } label: {
                    Label(newLabel, systemImage: newIcon)
                }
            } label: {
                Image(systemName: "square.and.pencil")
                    .orbFont(size: 13, weight: .semibold)
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
    var isSelecting: Bool = false
    var isChecked: Bool = false
    var onToggleCheck: (() -> Void)?
    var isPinned: Bool = false
    var onTogglePin: (() -> Void)?
    @State private var showDeleteConfirmation = false
    /// Set by a host whose `onDelete` offers Undo (the toast path the header
    /// and bulk delete use). Then Delete acts at once, with no modal; hosts
    /// still deleting permanently keep the confirmation.
    @Environment(\.conversationDeleteIsUndoable) private var deleteIsUndoable

    var body: some View {
        Button {
            if isSelecting { onToggleCheck?() } else { onSelect() }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    if isSelecting {
                        Image(systemName: isChecked ? "checkmark.circle.fill" : "circle")
                            .orbFont(size: 12)
                            .foregroundStyle(isChecked ? accent : .secondary)
                    }
                    Image(systemName: icon)
                        .orbFont(size: 11, weight: .semibold)
                        .foregroundStyle(isSelected ? accent : .secondary)
                    Text(conversation.title)
                        .orbFont(size: 12, weight: isSelected ? .semibold : .medium)
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
                .orbFont(size: 11, weight: .medium)
                .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .help("\(conversation.title)\n\(conversation.modelId) · \(conversation.messages.count) messages")
            .background((isSelecting ? isChecked : isSelected) ? accent.opacity(0.14) : Color.primary.opacity(0.025))
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .stroke((isSelecting ? isChecked : isSelected) ? accent.opacity(0.34) : Color.primary.opacity(0.04), lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let onTogglePin {
                Button(action: onTogglePin) {
                    Label(isPinned ? "Unpin" : "Pin to Top", systemImage: isPinned ? "pin.slash" : "pin")
                }
            }
            if let onExport {
                Button {
                    onExport()
                } label: {
                    Label("Export as Markdown", systemImage: "square.and.arrow.up")
                }
            }
            Button("Delete", role: .destructive) {
                if ConversationRowDeletePolicy.needsConfirmation(undoable: deleteIsUndoable) { showDeleteConfirmation = true } else { onDelete() }
            }
        }
        .accessibilityLabel("Session, \(conversation.title)\(isPinned ? ", pinned" : "")")
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

/// Bottom bar shown while multi-selecting sessions: Select All / None and Delete.
struct ConversationSelectionBar: View {
    let selectedCount: Int
    let totalCount: Int
    let accent: Color
    let onSelectAll: () -> Void
    let onClear: () -> Void
    let onDelete: () -> Void
    @State private var showConfirm = false

    var body: some View {
        VStack(spacing: 8) {
            Rectangle().fill(.orbSurface(0.07)).frame(height: 1)
            HStack(spacing: 8) {
                Text("\(selectedCount) selected")
                    .orbFont(size: 11, weight: .semibold)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(selectedCount == totalCount ? "Select None" : "Select All") {
                    if selectedCount == totalCount { onClear() } else { onSelectAll() }
                }
                .buttonStyle(.plain)
                .orbFont(size: 11, weight: .medium)
                .foregroundStyle(accent)
            }
            Button(role: .destructive) {
                showConfirm = true
            } label: {
                Label("Delete \(selectedCount)", systemImage: "trash")
                    .orbFont(size: 12, weight: .semibold)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.small)
            .disabled(selectedCount == 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .confirmationDialog(
            "Delete \(selectedCount) session\(selectedCount == 1 ? "" : "s")?",
            isPresented: $showConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete \(selectedCount) Session\(selectedCount == 1 ? "" : "s")", role: .destructive, action: onDelete)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes the selected sessions and all of their messages.")
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
                .fill(.orbSurface(0.07))
                .frame(height: 1)
            HStack(spacing: 7) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                    .shadow(color: statusColor.opacity(0.6), radius: 3)
                Text(statusText)
                    .orbFont(size: 11, weight: .medium)
                    .foregroundStyle(.secondary)
                Spacer()
                if tokensPerSecond > 0 {
                    Text("\(String(format: "%.1f", tokensPerSecond)) tok/s")
                        .orbFont(size: 11, weight: .semibold, design: .monospaced)
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
                .orbFont(size: 11, weight: .medium, design: .monospaced)
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
                .orbFont(size: 24, weight: .light)
                .foregroundStyle(accent.opacity(0.75))
            Text("Your sessions\nwill appear here")
                .orbFont(size: 11)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 32)
    }
}
