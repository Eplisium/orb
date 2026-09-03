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
                        Text(defaultModelId == nil ? "Favorites are always shown first" : "Pin a model to use it for every new \(defaultLabel ?? "playground") session")
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
        let isDefault = defaultModelId?.wrappedValue == model.id
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

            if let defaultModelId {
                Button {
                    defaultModelId.wrappedValue = isDefault ? "" : model.id
                } label: {
                    Image(systemName: isDefault ? "pin.fill" : "pin")
                        .font(.system(size: 11, weight: .semibold))
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

