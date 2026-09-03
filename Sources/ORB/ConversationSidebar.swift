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
    @State private var showDeleteConfirmation = false

    var body: some View {
        Button {
            onSelect()
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
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
            .background(isSelected ? accent.opacity(0.14) : Color.primary.opacity(0.025))
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .stroke(isSelected ? accent.opacity(0.34) : Color.primary.opacity(0.04), lineWidth: 1)
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
