import AppKit
import SwiftUI

// MARK: - Shared playground constants

enum PlaygroundTheme {
    static let accent = Color(red: 0.46, green: 0.38, blue: 0.96)
    static let agentAccent = Color(red: 0.46, green: 0.38, blue: 0.96)
    static let chatAccent = Color(red: 0.30, green: 0.58, blue: 0.94)
    static let testAccent = Color(red: 0.94, green: 0.42, blue: 0.50)
}

// MARK: - Shared helpers

func shortModelName(_ modelId: String) -> String {
    modelId.split(separator: "/").last.map(String.init) ?? modelId
}

// MARK: - Suggestion

struct PlaygroundSuggestion {
    let title: String
    let subtitle: String
    let icon: String
    let prompt: String
}

// MARK: - Suggestion Card

struct SuggestionCard: View {
    let suggestion: PlaygroundSuggestion
    let accent: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: suggestion.icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(accent)
                    .frame(width: 28, height: 28)
                    .background(accent.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                VStack(alignment: .leading, spacing: 4) {
                    Text(suggestion.title)
                        .font(.system(size: 11, weight: .semibold))
                    Text(suggestion.subtitle)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            .background(Color.primary.opacity(0.032))
            .overlay {
                RoundedRectangle(cornerRadius: 11)
                    .stroke(Color.primary.opacity(0.06), lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 11))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Capability Pill

struct CapabilityPill: View {
    let title: String
    let icon: String

    var body: some View {
        Label(title, systemImage: icon)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Color.primary.opacity(0.045))
            .clipShape(Capsule())
    }
}

// MARK: - Message View

struct PlaygroundMessageView: View {
    let message: ChatMessage
    let isStreaming: Bool
    let assistantName: String
    let accent: Color

    private var isUser: Bool { message.role == "user" }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if isUser {
                Spacer(minLength: 30)
                messageContent
                avatar
            } else {
                avatar
                messageContent
                Spacer(minLength: 30)
            }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    }

    private var messageContent: some View {
        VStack(alignment: isUser ? .trailing : .leading, spacing: 6) {
            Text(isUser ? "You" : assistantName)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
            Group {
                if message.content.isEmpty && isStreaming {
                    HStack(spacing: 5) {
                        ForEach(0..<3) { index in
                            Circle()
                                .fill(accent.opacity(0.75 - Double(index) * 0.17))
                                .frame(width: 5, height: 5)
                        }
                    }
                    .padding(.vertical, 4)
                } else {
                    Text(renderedContent)
                        .font(.system(size: 13))
                        .lineSpacing(3)
                        .textSelection(.enabled)
                }
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 11)
            .background(isUser ? accent.opacity(0.14) : Color.primary.opacity(0.045))
            .overlay {
                RoundedRectangle(cornerRadius: 13)
                    .stroke(isUser ? accent.opacity(0.18) : Color.primary.opacity(0.055), lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 13))
        }
        .frame(maxWidth: 680, alignment: isUser ? .trailing : .leading)
    }

    private var avatar: some View {
        ZStack {
            Circle()
                .fill(isUser ? Color.green.opacity(0.17) : accent.opacity(0.16))
            Image(systemName: isUser ? "person.fill" : "wand.and.stars")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(isUser ? Color.green : accent)
        }
        .frame(width: 30, height: 30)
    }

    private var renderedContent: AttributedString {
        (try? AttributedString(
            markdown: message.content,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(message.content)
    }
}

// MARK: - Model Picker

struct PlaygroundModelPicker: View {
    let models: [ModelInfo]
    let favoriteIds: Set<String>
    @Binding var selectedModelId: String
    @Binding var searchText: String
    var toolCapableOnly: Binding<Bool>?
    let accent: Color
    let toggleFavorite: (ModelInfo) -> Void
    let dismiss: () -> Void

    private var toolFilter: Bool { toolCapableOnly?.wrappedValue ?? false }

    private var sections: [AgentModelSection] {
        AgentModelCatalog.sections(
            models: models,
            favoriteIds: favoriteIds,
            searchText: searchText,
            toolCapableOnly: toolFilter
        )
    }

    private var resultCount: Int { sections.reduce(0) { $0 + $1.models.count } }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Choose a model")
                            .font(.system(size: 15, weight: .semibold))
                        Text("Favorites are always shown first")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("\(resultCount)")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(Color.primary.opacity(0.05))
                        .clipShape(Capsule())
                }

                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search models, providers, or IDs", text: $searchText)
                        .textFieldStyle(.plain)
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color.primary.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 8))

                if let toolCapableOnly {
                    Toggle(isOn: toolCapableOnly) {
                        Label("Only models with function calling", systemImage: "wrench.and.screwdriver")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                }
            }
            .padding(16)

            Divider()

            if sections.isEmpty {
                ContentUnavailableView(
                    "No matching models",
                    systemImage: "cpu",
                    description: Text("Try another search or include models without function calling.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 7, pinnedViews: [.sectionHeaders]) {
                        ForEach(sections) { section in
                            Section {
                                ForEach(section.models) { model in
                                    modelRow(model)
                                }
                            } header: {
                                HStack {
                                    if section.title == "Favorites" {
                                        Image(systemName: "star.fill")
                                            .foregroundStyle(.yellow)
                                    }
                                    Text(section.title.uppercased())
                                    Spacer()
                                    Text("\(section.models.count)")
                                }
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 7)
                                .background(.regularMaterial)
                            }
                        }
                    }
                    .padding(10)
                }
            }
        }
        .frame(width: 440, height: 540)
    }

    private func modelRow(_ model: ModelInfo) -> some View {
        let selected = selectedModelId == model.id
        let favorite = favoriteIds.contains(model.id)
        return HStack(spacing: 10) {
            Button {
                selectedModelId = model.id
                dismiss()
            } label: {
                HStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 7)
                            .fill(selected ? accent.opacity(0.18) : Color.primary.opacity(0.05))
                        Text(String(model.provider.prefix(1)).uppercased())
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(selected ? accent : .secondary)
                    }
                    .frame(width: 30, height: 30)

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 5) {
                            Text(model.name)
                                .font(.system(size: 11, weight: .semibold))
                                .lineLimit(1)
                            if model.isFree {
                                Text("FREE")
                                    .font(.system(size: 7, weight: .bold))
                                    .foregroundStyle(.green)
                            }
                        }
                        HStack(spacing: 6) {
                            Text(model.provider)
                            Text("•")
                            Text(model.contextLengthFormatted)
                            if model.supportsTools {
                                Image(systemName: "wrench.and.screwdriver")
                            }
                            if model.supportsReasoning {
                                Image(systemName: "brain")
                            }
                        }
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(accent)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                toggleFavorite(model)
            } label: {
                Image(systemName: favorite ? "star.fill" : "star")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(favorite ? Color.yellow : Color.secondary)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(favorite ? "Remove from Favorites" : "Add to Favorites")
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(selected ? accent.opacity(0.10) : Color.primary.opacity(0.025))
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .stroke(selected ? accent.opacity(0.28) : Color.primary.opacity(0.045), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 9))
    }
}

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
    let accent: Color
    let icon: String
    let onSelect: () -> Void
    let onDelete: () -> Void

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
            Button("Delete", role: .destructive) {
                onDelete()
            }
        }
        .accessibilityLabel("Session, \(conversation.title)")
    }
}

struct ConversationSidebarFooter: View {
    let statusColor: Color
    let statusText: String
    let conversation: ChatConversation?
    let formattedCost: (Double) -> String

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
