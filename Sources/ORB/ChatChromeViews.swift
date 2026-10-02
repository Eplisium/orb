import SwiftUI

// MARK: - Chat and Agent chrome components (Phase 5)

struct ConversationSearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
            TextField("Search sessions", text: $text)
                .textFieldStyle(.plain)
                .font(ORBFont.footnote)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
                    .help("Clear search")
                    .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }
}

/// Date-grouped, pin-aware session list shared by Chat and Agent.
struct ConversationSectionsList: View {
    let conversations: [ChatConversation]
    @Binding var query: String
    @ObservedObject var pins: ConversationPinStore
    let selectedID: UUID?
    let accent: Color
    let icon: String
    let isRunning: (UUID) -> Bool
    let onSelect: (ChatConversation) -> Void
    let onDelete: (ChatConversation) -> Void
    let onExport: (ChatConversation) -> Void
    var isSelecting = false
    var checked: Set<UUID> = []
    let onToggleCheck: (UUID) -> Void

    var body: some View {
        let sections = ConversationListModel.sections(conversations, query: query, pinned: pins.ids, pinOrder: pins.order)
        ScrollView {
            LazyVStack(spacing: 8, pinnedViews: [.sectionHeaders]) {
                if conversations.isEmpty {
                    EmptyConversationList(accent: accent)
                } else if sections.isEmpty {
                    VStack(spacing: 6) {
                        Text("No sessions match “\(query)”").font(ORBFont.footnote).foregroundStyle(.secondary)
                        Button("Clear search") { query = "" }.buttonStyle(.link).font(ORBFont.footnote)
                    }
                    .padding(.top, 24)
                } else {
                    ForEach(sections) { section in
                        Section {
                            ForEach(section.items) { conversation in
                                ConversationRow(
                                    conversation: conversation,
                                    isSelected: selectedID == conversation.id,
                                    isRunning: isRunning(conversation.id),
                                    accent: accent,
                                    icon: section.title == "Pinned" ? "pin.fill" : icon,
                                    onSelect: { onSelect(conversation) },
                                    onDelete: { onDelete(conversation) },
                                    onExport: { onExport(conversation) },
                                    isSelecting: isSelecting,
                                    isChecked: checked.contains(conversation.id),
                                    onToggleCheck: { onToggleCheck(conversation.id) },
                                    isPinned: pins.isPinned(conversation.id),
                                    onTogglePin: { pins.toggle(conversation.id) }
                                )
                                .draggable(conversation.id.uuidString)
                                .dropDestination(for: String.self) { items, _ in
                                    guard section.title == "Pinned", pins.isPinned(conversation.id),
                                          let raw = items.first, let id = UUID(uuidString: raw), pins.isPinned(id)
                                    else { return false }
                                    pins.move(id, before: conversation.id)
                                    return true
                                }
                            }
                        } header: {
                            HStack {
                                Text(section.title.uppercased())
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text("\(section.items.count)")
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 4).padding(.vertical, 5)
                            .background(.ultraThinMaterial.opacity(0.92))
                            .accessibilityAddTraits(.isHeader)
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 12)
        }
    }
}

/// Estimated context use. Words and a symbol accompany the colour.
struct ContextGaugeView: View {
    let gauge: ContextGauge

    private var tint: Color {
        switch gauge.level {
        case .normal: return .secondary
        case .warning: return ORBTheme.warning
        case .critical: return .red
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: gauge.symbol)
            ProgressView(value: gauge.fraction).frame(width: 46).tint(tint)
            Text(gauge.level == .normal ? gauge.summary : "\(gauge.statusWord) · \(gauge.summary)")
                .monospacedDigit()
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(tint)
        .help("Estimated from text length, not exact. Context window: \(gauge.contextLength) tokens.")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(gauge.accessibilityLabel)
    }
}

struct SlashCommandMenu: View {
    let entries: [SlashCommand.Entry]
    let pick: (SlashCommand.Entry) -> Void

    var body: some View {
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(entries) { entry in
                    Button { pick(entry) } label: {
                        HStack {
                            Text("/" + entry.name).font(.system(size: 12, weight: .semibold, design: .monospaced))
                            Text(entry.summary).font(ORBFont.caption).foregroundStyle(.secondary)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                }
            }
            .padding(.vertical, 4)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.1)) }
        }
    }
}

/// Precise / Balanced / Creative plus "Model default" which omits temperature.
struct PresetPicker: View {
    @Binding var temperature: Double
    let accent: Color

    var body: some View {
        HStack(spacing: 6) {
            ForEach(GenerationPreset.allCases) { preset in
                let on = GenerationPreset.matching(temperature: temperature) == preset
                Button { temperature = preset.temperature } label: {
                    Text(preset.title)
                        .font(ORBFont.caption.weight(.medium))
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(on ? accent.opacity(0.2) : Color.primary.opacity(0.06), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
                .help("\(preset.title): temperature \(String(format: "%.1f", preset.temperature))")
            }
        }
    }
}

/// Pinned strip for an Agent run: turns, tools, failures, elapsed, cancel.
struct AgentRunStatusStrip: View {
    let messages: [ChatMessage]
    let startedAt: Date?
    let phaseText: String
    let cancel: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let s = RunStatusSummary.make(messages: messages, startedAt: startedAt, now: context.date)
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(phaseText).font(ORBFont.footnote.weight(.semibold))
                Text(s.text).font(ORBFont.footnote).monospacedDigit().foregroundStyle(.secondary)
                if s.failedToolCalls > 0 {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(ORBTheme.warning)
                        .accessibilityLabel("\(s.failedToolCalls) tool calls failed")
                }
                Spacer()
                Button("Cancel run", action: cancel).controlSize(.small)
                    .keyboardShortcut(".", modifiers: .command)
            }
            .padding(.horizontal, 18).padding(.vertical, 6)
            .background(ORBTheme.accentSubtle)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Agent running. \(s.text)")
        }
    }
}

struct ConversationMeterView: View {
    let conversation: ChatConversation?

    var body: some View {
        if let conversation {
            Text(ConversationMeter.text(tokens: conversation.totalTokens, cost: conversation.totalCost))
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .help("Tokens and cost for this session")
        }
    }
}
