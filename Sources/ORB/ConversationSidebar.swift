import AppKit
import SwiftUI

// Split out of PlaygroundCommon.swift for readability.
// Shared playground components live in PlaygroundCommon.swift.

// MARK: - Conversation sidebar helpers

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
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let onToggleSelecting {
                Button(isSelecting ? "Done" : "Select") {
                    onToggleSelecting()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isSelecting ? accent : .secondary)
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
                    .font(.system(size: 13, weight: .semibold))
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
    @State private var showDeleteConfirmation = false

    var body: some View {
        Button {
            if isSelecting { onToggleCheck?() } else { onSelect() }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    if isSelecting {
                        Image(systemName: isChecked ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 12))
                            .foregroundStyle(isChecked ? accent : .secondary)
                    }
                    Image(systemName: icon)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(isSelected ? accent : .secondary)
                    Text(conversation.title)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
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
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background((isSelecting ? isChecked : isSelected) ? accent.opacity(0.14) : Color.primary.opacity(0.025))
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .stroke((isSelecting ? isChecked : isSelected) ? accent.opacity(0.34) : Color.primary.opacity(0.04), lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let onExport {
                Button {
                    onExport()
                } label: {
                    Label("Export as Markdown", systemImage: "square.and.arrow.up")
                }
            }
            Button("Delete", role: .destructive) {
                showDeleteConfirmation = true
            }
        }
        .accessibilityLabel("Session, \(conversation.title)")
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
            Rectangle().fill(Color.primary.opacity(0.07)).frame(height: 1)
            HStack(spacing: 8) {
                Text("\(selectedCount) selected")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(selectedCount == totalCount ? "Select None" : "Select All") {
                    if selectedCount == totalCount { onClear() } else { onSelectAll() }
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(accent)
            }
            Button(role: .destructive) {
                showConfirm = true
            } label: {
                Label("Delete \(selectedCount)", systemImage: "trash")
                    .font(.system(size: 12, weight: .semibold))
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
                .fill(Color.primary.opacity(0.07))
                .frame(height: 1)
            HStack(spacing: 7) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                    .shadow(color: statusColor.opacity(0.6), radius: 3)
                Text(statusText)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                if tokensPerSecond > 0 {
                    Text("\(String(format: "%.1f", tokensPerSecond)) tok/s")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
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
                .font(.system(size: 9, weight: .medium, design: .monospaced))
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
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(accent.opacity(0.75))
            Text("Your sessions\nwill appear here")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 32)
    }
}
