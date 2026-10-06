import SwiftUI

// MARK: - Chat and Agent chrome components (Phase 5)

struct ConversationSearchField: View {
    @Binding var text: String
    /// Bumped by the Conversation ▸ Search Sessions command to take focus.
    var focusRequest: Int = 0
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
            TextField("Search sessions", text: $text)
                .textFieldStyle(.plain)
                .font(ORBFont.footnote)
                .focused($focused)
                .onChange(of: focusRequest) { _, _ in focused = true }
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
                    .help("Clear search")
                    .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(.orbSurface(0.06), in: RoundedRectangle(cornerRadius: 8))
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
    @State private var sectionsCache = ConversationSectionsCache()

    var body: some View {
        let sections = sectionsCache.sections(conversations, query: query, pinned: pins.ids, pinOrder: pins.order)
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
                                    .orbFont(size: 11, weight: .bold)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text("\(section.items.count)")
                                    .orbFont(size: 11, weight: .semibold, design: .monospaced)
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
        .orbFont(size: 11, weight: .medium)
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
                            Text("/" + entry.name).orbFont(size: 12, weight: .semibold, design: .monospaced)
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
                // ⌘. lives in the Conversation menu (ConversationCommands).
                Button("Cancel run", action: cancel).controlSize(.small)
                    .help("Cancel run (⌘.)")
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
                .orbFont(size: 11, weight: .medium)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .help("Tokens and cost for this session")
        }
    }
}

/// Title that turns into a text field on double-click; Return commits, Escape cancels.
struct EditableTitle: View {
    let title: String
    let commit: (String) -> Void
    @State private var editing = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if editing {
                TextField("Title", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit { finish(save: true) }
                    .onExitCommand { finish(save: false) }
                    .onChange(of: focused) { _, now in if !now && editing { finish(save: true) } }
            } else {
                Text(title)
                    .lineLimit(1)
                    .onTapGesture(count: 2) { begin() }
                    .help("Double-click to rename")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint("Double tap to rename")
                    .accessibilityAction(named: "Rename") { begin() }
            }
        }
        .orbFont(size: 15, weight: .semibold)
    }

    private func begin() { draft = title; editing = true; focused = true }

    private func finish(save: Bool) {
        guard editing else { return }
        editing = false
        if save { commit(draft) }
    }
}

/// Bottom-of-window toast with an Undo button; dismisses itself.
struct UndoToastView: View {
    let message: String
    var symbol: String = "trash"
    let undo: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).accessibilityHidden(true)
            Text(message).font(ORBFont.footnote.weight(.medium))
            Button("Undo", action: undo).buttonStyle(.link).keyboardShortcut("z", modifiers: .command)
            Button { dismiss() } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(.regularMaterial, in: Capsule())
        .overlay { Capsule().stroke(Color.primary.opacity(0.12)) }
        .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
        .padding(.bottom, 16)
        .task(id: message) {
            try? await Task.sleep(for: .seconds(UndoToast.visibleDuration))
            dismiss()
        }
        .accessibilityElement(children: .combine)
    }
}

extension View {
    /// Dashed accent outline while files are dragged over.
    func fileDropHighlight(_ targeted: Bool, accent: Color) -> some View {
        overlay {
            if targeted {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(accent, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .background(accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                    .overlay { Label("Drop to attach", systemImage: "paperclip").font(ORBFont.footnote.weight(.semibold)).foregroundStyle(accent) }
                    .allowsHitTesting(false)
            }
        }
    }
}

/// Modal prompt for one risky tool call. Deny is the default action; Escape denies.
struct ApprovalSheet: View {
    let request: ApprovalCoordinator.Request
    let waiting: Int
    let decide: (ApprovalCoordinator.Decision) -> Void

    var body: some View {
        let p = ApprovalPresentation.make(toolName: request.toolName, server: request.server, summary: request.summary)
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: p.symbol).orbFont(size: 26).foregroundStyle(p.risk == .high ? .red : ORBTheme.warning)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(p.title).font(ORBFont.headline)
                    Label(p.riskWord, systemImage: p.risk == .high ? "exclamationmark.triangle.fill" : "exclamationmark.circle")
                        .font(ORBFont.caption.weight(.semibold))
                        .foregroundStyle(p.risk == .high ? .red : ORBTheme.warning)
                }
            }
            Text("The agent wants to use \(request.toolName).")
                .font(ORBFont.footnote).foregroundStyle(.secondary)
            if let primary = p.primary, let label = p.primaryLabel {
                VStack(alignment: .leading, spacing: 4) {
                    Text(label).font(ORBFont.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ScrollView {
                        Text(primary)
                            .orbFont(size: 12, design: .monospaced)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                    .frame(maxHeight: 160)
                    .background(.orbSurface(0.06), in: RoundedRectangle(cornerRadius: 8))
                }
            }
            DisclosureGroup(p.primary == nil ? "Arguments" : "All arguments") {
                ScrollView {
                    Text(p.displaySummary)
                        .orbFont(size: 12, design: .monospaced)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(maxHeight: 220)
                .background(.orbSurface(0.06), in: RoundedRectangle(cornerRadius: 8))
            }
            .font(ORBFont.caption)
            if p.hiddenCharacters > 0 {
                Label("\(p.hiddenCharacters) characters hidden — too long to display in full", systemImage: "eye.slash")
                    .font(ORBFont.caption.weight(.semibold))
                    .foregroundStyle(ORBTheme.warning)
            }
            if waiting > 0 {
                Text("\(waiting) more waiting").font(ORBFont.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Deny") { decide(.denied) }
                    .keyboardShortcut(.cancelAction)
                Button("Approve for this run") { decide(.approvedForSession) }
                    .help("Allow this tool again without asking until the run ends")
                Button("Approve once") { decide(.approved) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
        .interactiveDismissDisabled()
        .accessibilityElement(children: .contain)
    }
}

/// Observes the presenter directly so the sheet appears the moment a request is queued.
struct ApprovalSheetModifier: ViewModifier {
    @ObservedObject var presenter: ApprovalPresenter

    func body(content: Content) -> some View {
        content.sheet(item: Binding(
            get: { presenter.queue.current },
            // Any dismissal that is not an explicit button press is a denial.
            set: { if $0 == nil, let id = presenter.queue.current?.id { presenter.decide(id, .denied) } }
        )) { request in
            ApprovalSheet(request: request, waiting: presenter.queue.waiting) { presenter.decide(request.id, $0) }
        }
    }
}
