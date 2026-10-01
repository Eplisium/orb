import SwiftUI

/// ⌘K command palette: fuzzy search over sections, actions, favourite models
/// and recent conversations. Ranking lives in `PaletteIndex`.
struct CommandPaletteView: View {
    let index: PaletteIndex
    let onPick: (ShellAction) -> Void

    @State private var query = ""
    @State private var highlighted: String?
    @FocusState private var fieldFocused: Bool
    @Environment(\.dismiss) private var dismiss

    private var groups: [PaletteGroupResult] { index.results(query: query) }
    private var flat: [PaletteItem] { PaletteIndex.flatten(groups) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search sections, models, conversations, actions…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
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
                                .font(ORBFont.caption.weight(.semibold))
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
        return Button {
            onPick(item.action)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: item.symbol)
                    .frame(width: 20)
                    .foregroundStyle(selected ? Color.white : ORBTheme.accent)
                VStack(alignment: .leading, spacing: 0) {
                    Text(item.title).font(ORBFont.body).lineLimit(1)
                    if let subtitle = item.subtitle {
                        Text(subtitle).font(ORBFont.caption)
                            .foregroundStyle(selected ? Color.white.opacity(0.8) : Color.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                if let shortcut = item.shortcut {
                    Text(shortcut).font(ORBFont.caption)
                        .foregroundStyle(selected ? Color.white.opacity(0.8) : Color.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .foregroundStyle(selected ? Color.white : Color.primary)
            .background(selected ? ORBTheme.accent : Color.clear, in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
            onPick(item.action)
        }
    }
}

/// ⌘/ keyboard shortcut cheat sheet.
struct ShortcutCheatSheet: View {
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Keyboard Shortcuts").font(ORBFont.title3).accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) {
                ForEach(ShellShortcuts.cheatSheet, id: \.keys) { entry in
                    HStack {
                        Text(entry.title).font(ORBFont.body)
                        Spacer()
                        Text(entry.keys)
                            .font(ORBFont.code)
                            .padding(.horizontal, 8).padding(.vertical, 2)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                    }
                    .padding(.vertical, 6)
                    .accessibilityElement(children: .combine)
                    Divider()
                }
            }
            HStack {
                Spacer()
                Button("Done", action: onClose).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 400)
        .onExitCommand(perform: onClose)
    }
}
