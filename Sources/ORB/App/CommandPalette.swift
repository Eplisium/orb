import SwiftUI
import AppKit

/// ⌘K command palette: fuzzy search over sections, actions, the model
/// catalog (favourites first) and conversations by last activity. Ranking
/// lives in `PaletteIndex`.
struct CommandPaletteView: View {
    let index: PaletteIndex
    let onPick: (ShellAction) -> Void

    @State private var query = ""
    @State private var highlighted: String?
    @FocusState private var fieldFocused: Bool
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var lock = AppLock.shared

    private var effectiveIndex: PaletteIndex {
        var index = index
        index.canLock = lock.isEnabled && lock.isUnlocked
        return index
    }

    private var groups: [PaletteGroupResult] { effectiveIndex.results(query: query) }
    private var flat: [PaletteItem] { PaletteIndex.flatten(groups) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search sections, models, conversations, actions…", text: $query)
                    .textFieldStyle(.plain)
                    .orbFont(.title3)
                    .focused($fieldFocused)
                    .onSubmit { pickHighlighted() }
                    .accessibilityLabel("Command palette search")
            }
            .padding(14)
            Divider()
            resultsList
        }
        .frame(width: 560, height: 420)
        .onAppear {
            fieldFocused = true
            highlighted = flat.first?.id
        }
        .onChange(of: query) { _, _ in highlighted = flat.first?.id }
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onExitCommand { dismiss() }
    }

    @ViewBuilder
    private var resultsList: some View {
        if groups.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2, pinnedViews: []) {
                        ForEach(groups, id: \.group) { result in
                            Text(result.group.rawValue)
                                .orbFont(.caption, weight: .semibold)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 14)
                                .padding(.top, 10)
                                .padding(.bottom, 2)
                                .accessibilityAddTraits(.isHeader)
                            ForEach(result.items) { item in
                                row(item).id(item.id)
                            }
                        }
                    }
                    .padding(.vertical, 6)
                }
                .onChange(of: highlighted) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
            }
        }
    }

    private func row(_ item: PaletteItem) -> some View {
        let selected = item.id == highlighted
        // onAccent on the accent fill is contrast-tested (≥ 4.5:1) for every
        // accent in both appearances; plain white is not in Dark mode.
        let primary: Color = selected ? ORBTheme.onAccent : ORBTheme.textPrimary
        let secondary: Color = selected ? ORBTheme.onAccent.opacity(0.85) : ORBTheme.textSecondary
        return Button {
            pick(item)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: item.symbol)
                    .frame(width: 20)
                    .foregroundStyle(selected ? ORBTheme.onAccent : ORBTheme.accent)
                VStack(alignment: .leading, spacing: 0) {
                    Text(item.title).orbFont(.body).lineLimit(1)
                    if let subtitle = item.subtitle {
                        Text(subtitle).orbFont(.caption)
                            .foregroundStyle(secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer()
                if let shortcut = item.shortcut {
                    Text(shortcut).orbFont(.caption)
                        .foregroundStyle(secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .foregroundStyle(primary)
            .background(selected ? ORBTheme.accent : Color.clear, in: RoundedRectangle(cornerRadius: ORBMetrics.radiusMD))
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // The pointer and the arrow keys move one highlight.
        .onHover { inside in if inside { highlighted = item.id } }
        .accessibilityLabel([item.group.rawValue, item.title, item.subtitle].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func move(_ delta: Int) {
        let items = flat
        guard !items.isEmpty else { return }
        let current = items.firstIndex { $0.id == highlighted } ?? (delta > 0 ? -1 : items.count)
        let next = min(max(current + delta, 0), items.count - 1)
        highlighted = items[next].id
    }

    private func pickHighlighted() {
        let items = flat
        if let item = items.first(where: { $0.id == highlighted }) ?? items.first {
            pick(item)
        }
    }

    private func pick(_ item: PaletteItem) {
        switch item.localCommand {
        case nil:
            onPick(item.action)
        case .lock?:
            dismiss()
            lock.lock()
        case .openSettingsPane(let pane)?:
            pane.store()
            onPick(.openSettings)
        case .checkForUpdates?:
            dismiss()
            Task { await UpdateChecker.shared.checkNow() }
        }
    }
}

/// ⌘/ keyboard shortcut cheat sheet, grouped by menu. Scrolls, so it fits
/// the 640-pt minimum window however many shortcuts there are.
struct ShortcutCheatSheet: View {
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Keyboard Shortcuts")
                .orbFont(.title3, weight: .semibold)
                .accessibilityAddTraits(.isHeader)
                .padding([.horizontal, .top], 20)
                .padding(.bottom, 12)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(ShellShortcuts.cheatSheetGroups) { group in
                        VStack(alignment: .leading, spacing: 0) {
                            Text(group.title)
                                .orbFont(.caption, weight: .semibold)
                                .foregroundStyle(.secondary)
                                .accessibilityAddTraits(.isHeader)
                                .padding(.bottom, 4)
                            ForEach(group.entries, id: \.keys) { entry in
                                HStack {
                                    Text(entry.title).orbFont(.body)
                                    Spacer()
                                    Text(entry.keys)
                                        .font(ORBFont.code)
                                        .padding(.horizontal, 8).padding(.vertical, 2)
                                        .background(.quaternary, in: RoundedRectangle(cornerRadius: ORBMetrics.radiusSM))
                                }
                                .padding(.vertical, 5)
                                .accessibilityElement(children: .combine)
                                Rectangle().fill(ORBTheme.stroke).frame(height: 1)
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            }
            .frame(maxHeight: 460)
            Rectangle().fill(ORBTheme.stroke).frame(height: 1)
            HStack {
                Button("ORB on GitHub") { NSWorkspace.shared.open(ORBProjectLinks.readme) }
                Spacer()
                Button("Done", action: onClose).keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 440)
        .onExitCommand(perform: onClose)
    }
}
