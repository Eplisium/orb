import AppKit
import SwiftUI

// Split out of PlaygroundCommon.swift for readability.
// Shared playground components live in PlaygroundCommon.swift.

// MARK: - Model Picker

struct PlaygroundModelPicker: View {
    let models: [ModelInfo]
    let favoriteIds: Set<String>
    @Binding var selectedModelId: String
    @Binding var searchText: String
    var toolCapableOnly: Binding<Bool>?
    var defaultModelId: Binding<String>?
    var defaultLabel: String?
    let accent: Color
    let toggleFavorite: (ModelInfo) -> Void
    let dismiss: () -> Void

    @State private var sortField: SortField = .name
    @State private var sortOrder: SortOrder = .ascending
    @State private var recentIds: [String] = []
    /// Keyboard highlight, an index into `ModelPickerKeyboard.flattened`.
    @State private var highlighted = 0
    @FocusState private var searchFocused: Bool

    private var toolFilter: Bool { toolCapableOnly?.wrappedValue ?? false }

    private var sections: [AgentModelSection] {
        AgentModelCatalog.sections(
            models: models,
            favoriteIds: favoriteIds,
            searchText: searchText,
            toolCapableOnly: toolFilter,
            recentIds: recentIds,
            sortField: sortField,
            sortOrder: sortOrder
        )
    }

    private var resultCount: Int { sections.reduce(0) { $0 + $1.models.count } }

    private func move(_ delta: Int, in sections: [AgentModelSection]) -> KeyPress.Result {
        let count = ModelPickerKeyboard.flattened(sections).count
        guard count > 0 else { return .ignored }
        highlighted = ModelPickerKeyboard.moved(highlighted, by: delta, count: count)
        return .handled
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Choose a model")
                            .orbFont(size: 15, weight: .semibold)
                        Text(defaultModelId == nil ? "Favorites first, then your most recent models" : "Pin a model to use it for every new \(defaultLabel ?? "playground") session")
                            .orbFont(size: 11)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("\(resultCount)")
                        .orbFont(size: 11, weight: .semibold, design: .monospaced)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(.orbSurface(0.05))
                        .clipShape(Capsule())
                }

                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search models, providers, or IDs", text: $searchText)
                        .textFieldStyle(.plain)
                        .focused($searchFocused)
                        // Keyboard-only flow: type, ↑/↓ to move the
                        // highlight, Return to pick it, Esc to clear or close.
                        .onSubmit {
                            if let model = ModelPickerKeyboard.selection(in: sections, highlighted: highlighted) { select(model) }
                        }
                        .onKeyPress(.downArrow) { move(1, in: sections) }
                        .onKeyPress(.upArrow) { move(-1, in: sections) }
                        .onKeyPress(.escape) {
                            if searchText.isEmpty { dismiss() } else { searchText = "" }
                            return .handled
                        }
                        .accessibilityHint("Use the up and down arrows to move through results and Return to choose")
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear search")
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(.orbSurface(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 8))

                HStack(spacing: 8) {
                    sortMenu
                    directionButton
                    Spacer()
                }

                if let toolCapableOnly {
                    Toggle(isOn: toolCapableOnly) {
                        Label("Only models with function calling", systemImage: "wrench.and.screwdriver")
                            .orbFont(size: 11, weight: .medium)
                    }
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                }
            }
            .padding(16)

            Divider()

            if let empty = AgentModelCatalog.emptyState(catalogIsEmpty: models.isEmpty, hasResults: !sections.isEmpty) {
                // An empty catalog is not a failed search: say which it is.
                ContentUnavailableView(
                    empty.title,
                    systemImage: empty == .catalogNotLoaded ? "arrow.clockwise" : "cpu",
                    description: Text(empty.guidance(toolCapableOnly: toolFilter))
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let rows = ModelPickerKeyboard.flattened(sections)
                let highlightedRow = rows.indices.contains(highlighted) ? rows[highlighted].rowID : nil
                ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 7, pinnedViews: [.sectionHeaders]) {
                        ForEach(sections) { section in
                            Section {
                                ForEach(section.models) { model in
                                    let rowID = ModelPickerKeyboard.rowID(section: section, model: model)
                                    modelRow(model, isHighlighted: rowID == highlightedRow)
                                        .id(rowID)
                                }
                            } header: {
                                HStack {
                                    if section.title == "Favorites" {
                                        Image(systemName: "star.fill")
                                            .foregroundStyle(.yellow)
                                    } else if section.title == "Recents" {
                                        Image(systemName: "clock.arrow.circlepath")
                                            .foregroundStyle(.secondary)
                                    }
                                    Text(section.title.uppercased())
                                    Spacer()
                                    Text("\(section.models.count)")
                                }
                                .orbFont(size: 11, weight: .bold)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 7)
                                .background(.regularMaterial)
                            }
                        }
                    }
                    .padding(10)
                }
                .onChange(of: highlighted) { _, index in
                    let rows = ModelPickerKeyboard.flattened(sections)
                    if rows.indices.contains(index) { proxy.scrollTo(rows[index].rowID) }
                }
                }
            }
        }
        .frame(width: 440, height: 540)
        .onAppear {
            recentIds = ModelRecentsStore().recentIds()
            searchFocused = true
        }
        .onChange(of: searchText) { _, _ in highlighted = 0 }
        .onChange(of: sortField) { _, _ in highlighted = 0 }
        .onChange(of: sortOrder) { _, _ in highlighted = 0 }
    }

    private func select(_ model: ModelInfo) {
        selectedModelId = model.id
        dismiss()
    }

    // MARK: - Sorting controls

    private var sortMenu: some View {
        Menu {
            ForEach(SortField.allCases) { field in
                Button {
                    sortField = field
                } label: {
                    if sortField == field {
                        Label(field.rawValue, systemImage: "checkmark")
                    } else {
                        Text(field.rawValue)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.up.arrow.down")
                Text("Sort: \(sortField.rawValue)")
            }
            .orbFont(size: 11, weight: .medium)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.orbSurface(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Sort models by name, context, cost, date added, provider, or Elo")
    }

    private var directionButton: some View {
        Button {
            sortOrder = (sortOrder == .ascending) ? .descending : .ascending
        } label: {
            Image(systemName: sortOrder == .ascending ? "arrow.up" : "arrow.down")
                .orbFont(size: 11, weight: .semibold)
                .frame(width: 24, height: 24)
                .background(.orbSurface(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(sortOrder == .ascending ? "Ascending (click for descending)" : "Descending (click for ascending)")
    }

    private func modelRow(_ model: ModelInfo, isHighlighted: Bool = false) -> some View {
        let selected = selectedModelId == model.id
        let favorite = favoriteIds.contains(model.id)
        let isDefault = defaultModelId?.wrappedValue == model.id
        return HStack(spacing: 10) {
            Button {
                select(model)
            } label: {
                HStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 7)
                            .fill(selected ? accent.opacity(0.18) : Color.primary.opacity(0.05))
                        Text(String(model.provider.prefix(1)).uppercased())
                            .orbFont(size: 11, weight: .bold)
                            .foregroundStyle(selected ? accent : .secondary)
                    }
                    .frame(width: 30, height: 30)

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 5) {
                            Text(model.name)
                                .orbFont(size: 11, weight: .semibold)
                                .lineLimit(1)
                            if model.isFree {
                                Text("FREE")
                                    .orbFont(size: 11, weight: .bold)
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
                        .orbFont(size: 11, weight: .medium)
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

            if let defaultModelId {
                Button {
                    defaultModelId.wrappedValue = isDefault ? "" : model.id
                } label: {
                    Image(systemName: isDefault ? "pin.fill" : "pin")
                        .orbFont(size: 11, weight: .semibold)
                        .foregroundStyle(isDefault ? accent : Color.secondary)
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isDefault ? "Clear \(defaultLabel ?? "playground") default" : "Set as \(defaultLabel ?? "playground") default")
            }

            Button {
                toggleFavorite(model)
            } label: {
                Image(systemName: favorite ? "star.fill" : "star")
                    .orbFont(size: 11, weight: .semibold)
                    .foregroundStyle(favorite ? Color.yellow : Color.secondary)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(favorite ? "Remove from Favorites" : "Add to Favorites")
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(selected ? accent.opacity(0.10) : isHighlighted ? accent.opacity(0.06) : Color.primary.opacity(0.025))
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .stroke(isHighlighted ? accent.opacity(0.65) : selected ? accent.opacity(0.28) : Color.primary.opacity(0.045),
                        lineWidth: isHighlighted ? 1.5 : 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .accessibilityAddTraits(isHighlighted ? .isSelected : [])
    }
}

/// Keyboard navigation over the picker's sectioned results. A model can
/// appear in more than one section (a favorite that is also recent), so rows
/// are identified by section and model.
enum ModelPickerKeyboard {
    struct Row: Equatable {
        let rowID: String
        let model: ModelInfo

        static func == (lhs: Row, rhs: Row) -> Bool { lhs.rowID == rhs.rowID }
    }

    static func rowID(section: AgentModelSection, model: ModelInfo) -> String { "\(section.id)|\(model.id)" }

    static func flattened(_ sections: [AgentModelSection]) -> [Row] {
        sections.flatMap { section in section.models.map { Row(rowID: rowID(section: section, model: $0), model: $0) } }
    }

    /// Moves the highlight, stopping at the first and last rows.
    static func moved(_ index: Int, by delta: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return min(max(min(index, count - 1) + delta, 0), count - 1)
    }

    /// What Return picks: the highlighted row, else the first result.
    static func selection(in sections: [AgentModelSection], highlighted: Int) -> ModelInfo? {
        let rows = flattened(sections)
        guard !rows.isEmpty else { return nil }
        return rows[min(max(highlighted, 0), rows.count - 1)].model
    }
}

