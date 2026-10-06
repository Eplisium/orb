import SwiftUI

// MARK: - Model browser components (Phase 4)

/// Sort field menu + a separate direction toggle.
struct BrowserSortControl: View {
    @ObservedObject var vm: BrowserViewModel

    var body: some View {
        HStack(spacing: 2) {
            Menu {
                Picker("Sort by", selection: Binding(get: { vm.sortField }, set: { vm.setSort($0) })) {
                    ForEach(SortField.allCases) { field in Text(field.rawValue).tag(field) }
                }
                .pickerStyle(.inline)
            } label: {
                Label(vm.sortField.rawValue, systemImage: "arrow.up.arrow.down")
                    .font(ORBFont.caption)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Sort field")
            .accessibilityLabel("Sort by \(vm.sortField.rawValue)")

            Button { vm.toggleSortDirection() } label: {
                Image(systemName: vm.sortOrder == .ascending ? "arrow.up" : "arrow.down")
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.borderless)
            .help(vm.sortOrder == .ascending ? "Ascending (click for descending)" : "Descending (click for ascending)")
            .accessibilityLabel(vm.sortOrder == .ascending ? "Sort ascending" : "Sort descending")
        }
    }
}

/// The single "Filters" popover: capabilities, price, context, providers.
struct BrowserFiltersPopover: View {
    @ObservedObject var vm: BrowserViewModel
    @State private var providerSearch = ""

    private var providers: [String] {
        let all = vm.providerOptions.dropFirst()
        guard !providerSearch.isEmpty else { return Array(all) }
        return all.filter { $0.localizedCaseInsensitiveContains(providerSearch) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ORBMetrics.spacingSM) {
            HStack {
                Text("Filters").font(ORBFont.headline)
                Spacer()
                Button("Clear") { vm.filters.clear() }
                    .disabled(!vm.filters.isActive)
            }

            ORBSectionHeader("Capabilities")
            FlowLayout(spacing: 6) {
                ForEach(ModelCapability.allCases) { capability in
                    let on = vm.filters.capabilities.contains(capability)
                    Button {
                        if on { vm.filters.capabilities.remove(capability) } else { vm.filters.capabilities.insert(capability) }
                    } label: {
                        Label(capability.title, systemImage: capability.icon)
                            .font(ORBFont.caption)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(on ? ORBTheme.accent.opacity(0.18) : Color.primary.opacity(0.08), in: Capsule())
                            .foregroundStyle(on ? ORBTheme.accentLink : Color.primary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                    .help("\(on ? "Stop requiring" : "Require") \(capability.title)")
                }
            }

            ORBSectionHeader("Max input price")
            Picker("Max input price", selection: $vm.filters.maxInputPrice) {
                Text("Any").tag(Double?.none)
                ForEach(BrowserFilterState.priceSteps, id: \.self) { step in
                    Text("≤ \(BrowserFormat.price(step)) / 1M").tag(Double?.some(step))
                }
            }
            .labelsHidden()

            ORBSectionHeader("Max output price")
            Picker("Max output price", selection: $vm.filters.maxOutputPrice) {
                Text("Any").tag(Double?.none)
                ForEach(BrowserFilterState.outputPriceSteps, id: \.self) { step in
                    Text("≤ \(BrowserFormat.price(step)) / 1M").tag(Double?.some(step))
                }
            }
            .labelsHidden()

            ORBSectionHeader("Min context")
            Picker("Min context", selection: $vm.filters.minContext) {
                Text("Any").tag(Int?.none)
                ForEach(BrowserFilterState.contextSteps, id: \.self) { step in
                    Text("≥ \(BrowserFormat.context(step))").tag(Int?.some(step))
                }
            }
            .labelsHidden()

            ORBSectionHeader("Required parameters")
            FlowLayout(spacing: 6) {
                ForEach(BrowserFilterState.filterableParameters, id: \.self) { parameter in
                    let on = vm.filters.requiredParameters.contains(parameter)
                    Button {
                        if on { vm.filters.requiredParameters.remove(parameter) } else { vm.filters.requiredParameters.insert(parameter) }
                    } label: {
                        Text(parameter)
                            .orbFont(size: 11, design: .monospaced)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(on ? ORBTheme.accent.opacity(0.18) : Color.primary.opacity(0.08), in: Capsule())
                            .foregroundStyle(on ? ORBTheme.accentLink : Color.primary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                    .help("\(on ? "Stop requiring" : "Require") the \(parameter) request parameter")
                }
            }

            Toggle("Hide expired models", isOn: $vm.filters.hideExpired)
                .toggleStyle(.checkbox).font(ORBFont.footnote)
            Toggle("Hide aliases (~…-latest)", isOn: $vm.filters.hideAliases)
                .toggleStyle(.checkbox).font(ORBFont.footnote)

            ORBSectionHeader("Providers")
            TextField("Find a provider", text: $providerSearch)
                .textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(providers, id: \.self) { provider in
                        Toggle(provider, isOn: Binding(
                            get: { vm.filters.providers.contains(provider) },
                            set: { on in
                                if on { vm.filters.providers.insert(provider) } else { vm.filters.providers.remove(provider) }
                            }
                        ))
                        .toggleStyle(.checkbox)
                        .font(ORBFont.footnote)
                    }
                }
            }
            .frame(height: 130)
        }
        .padding(ORBMetrics.spacingMD)
        .frame(width: 340)
    }
}

/// Row of active-filter chips with × and "Clear all".
struct ActiveFilterChips: View {
    @ObservedObject var vm: BrowserViewModel

    var body: some View {
        let chips = vm.filters.chips
        if !chips.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(chips) { chip in
                        Button { vm.filters.remove(chip) } label: {
                            HStack(spacing: 4) {
                                Text(chip.title)
                                Image(systemName: "xmark").orbFont(size: 11, weight: .semibold)
                            }
                            .font(ORBFont.caption)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(ORBTheme.accentSubtle, in: Capsule())
                            .foregroundStyle(ORBTheme.accentLink)
                        }
                        .buttonStyle(.plain)
                        .help("Remove filter: \(chip.title)")
                        .accessibilityLabel("Remove filter \(chip.title)")
                    }
                    Button("Clear all") { vm.clearAllFilters() }
                        .buttonStyle(.link)
                        .font(ORBFont.caption)
                }
            }
        }
    }
}

struct OfflineBanner: View {
    let since: Date?
    let retry: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi.slash").accessibilityHidden(true)
            Text(BrowserListState.offlineBannerText(since: since))
                .font(ORBFont.caption)
                .lineLimit(2)
            Spacer(minLength: 4)
            Button("Retry", action: retry).font(ORBFont.caption)
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
        .background(ORBTheme.warning.opacity(0.15))
        .accessibilityElement(children: .combine)
    }
}

struct SkeletonModelList: View {
    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<9, id: \.self) { _ in
                ORBSkeletonRow(lines: 3).padding(.horizontal, 14)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading models")
    }
}

struct NoResultsView: View {
    @ObservedObject var vm: BrowserViewModel

    var body: some View {
        let suggestions = NoResultsSuggestions.make(search: vm.searchText, filters: vm.filters)
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .orbFont(size: 34).foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text("No models match").font(ORBFont.headline)
            Text("Nothing fits your search and filters.")
                .font(ORBFont.footnote).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(suggestions) { suggestion in
                    Button(suggestion.title) { apply(suggestion.kind) }
                        .buttonStyle(.link)
                        .font(ORBFont.footnote)
                }
            }
            if suggestions.isEmpty {
                Button("Clear all filters") { vm.clearAllFilters() }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func apply(_ kind: NoResultsSuggestion.Kind) {
        switch kind {
        case .clearSearch: vm.searchText = ""
        case .removeMaxPrice: vm.filters.maxInputPrice = nil
        case .removeMaxOutputPrice: vm.filters.maxOutputPrice = nil
        case .removeMinContext: vm.filters.minContext = nil
        case .clearParameters: vm.filters.requiredParameters = []
        case .showExpired: vm.filters.hideExpired = false
        case .showAliases: vm.filters.hideAliases = false
        case .clearProviders: vm.filters.providers = []
        case .removeCapability(let c): vm.filters.capabilities.remove(c)
        case .clearAll: vm.clearAllFilters()
        }
    }
}

/// Bar shown under the list while models are selected for comparison.
struct CompareBar: View {
    @ObservedObject var vm: BrowserViewModel
    let open: () -> Void

    var body: some View {
        if !vm.compareIDs.isEmpty {
            VStack(spacing: 2) {
                Divider()
                HStack {
                    Text("\(vm.compareIDs.count) selected").font(ORBFont.footnote)
                    if let notice = vm.compareLimitNotice {
                        Text(notice).font(ORBFont.caption).foregroundStyle(ORBTheme.warning)
                    }
                    Spacer()
                    Button("Clear") { vm.clearCompare() }
                    Button("Compare") { open() }
                        .buttonStyle(.borderedProminent)
                        .tint(ORBTheme.accent)
                        .disabled(vm.compareIDs.count < 2)
                        .help(vm.compareIDs.count < 2 ? "Select at least two models" : "Compare side by side")
                }
                .padding(.horizontal, 14).padding(.vertical, 6)
            }
            .background(.bar)
        }
    }
}

/// Side-by-side comparison. Latency/throughput come from each model's
/// endpoints, fetched concurrently on demand (public endpoint, no key).
struct ComparePanel: View {
    @ObservedObject var vm: BrowserViewModel
    let onTestSuite: ([String]) -> Void
    let onClose: () -> Void
    @AppStorage(PriceUnit.defaultsKey) private var priceUnit: PriceUnit = .perMillion
    @State private var endpointResults: [String: Result<[ModelEndpoint], EndpointLoadError>] = [:]

    private var columns: [ComparisonColumn] {
        vm.compareModels.map { model in
            let endpoints = (try? endpointResults[model.id]?.get())
            return ComparisonColumn.make(model: model, endpoints: endpoints, unit: priceUnit)
        }
    }

    private var failedNames: [String] {
        vm.compareModels.compactMap { model in
            if case .failure = endpointResults[model.id] { return model.name }
            return nil
        }
    }

    var body: some View {
        let cols = columns
        let best = ComparisonColumn.highlights(cols)
        VStack(alignment: .leading, spacing: ORBMetrics.spacingSM) {
            HStack {
                Text("Compare models").font(ORBFont.title3.weight(.semibold))
                Spacer()
                Menu {
                    Button("Copy as Markdown") { AppToasts.copy(ComparisonColumn.markdown(cols), what: "Comparison") }
                    Button("Copy as CSV") { AppToasts.copy(ComparisonColumn.csv(cols), what: "Comparison") }
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .fixedSize()
                .disabled(cols.isEmpty)
                .help("Copy this comparison as a Markdown table or CSV")
                Button("Run in Test Suite") { onTestSuite(vm.compareIDs) }
                    .help("Open Test Suite → Compare Models with these selected")
                Button("Done", action: onClose).keyboardShortcut(.cancelAction)
            }
            if cols.isEmpty {
                ORBEmptyState(title: "Nothing to compare", systemImage: "rectangle.split.3x1",
                              message: "Add models with the checkbox on each row.",
                              actionTitle: nil, action: nil)
            } else {
                ScrollView([.horizontal, .vertical]) {
                    Grid(alignment: .topLeading, horizontalSpacing: 20, verticalSpacing: 10) {
                        GridRow {
                            Text("")
                            ForEach(cols) { col in
                                HStack(alignment: .top, spacing: 4) {
                                    Text(col.name).font(ORBFont.headline).lineLimit(2)
                                    Spacer(minLength: 2)
                                    Button { vm.removeFromCompare(col.id) } label: {
                                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                    .help("Remove \(col.name) from the comparison")
                                    .accessibilityLabel("Remove \(col.name) from comparison")
                                }
                                .frame(width: 170, alignment: .leading)
                            }
                        }
                        ForEach(Array(ComparisonColumn.rows.enumerated()), id: \.offset) { _, row in
                            self.row(row.title, cols, highlight: highlight(for: row.title, best), value: row.value)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            Text("Latency and throughput are the best of each model's providers over the last 30 minutes. “—” means no data.")
                .font(ORBFont.caption).foregroundStyle(.secondary)
            if !failedNames.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "wifi.exclamationmark").foregroundStyle(.orange)
                    Text("Couldn't load providers for \(failedNames.joined(separator: ", ")).")
                        .font(ORBFont.caption).foregroundStyle(.secondary)
                    Button("Retry") { Task { await load(retryFailed: true) } }.font(ORBFont.caption)
                }
            }
        }
        .padding(ORBMetrics.spacingLG)
        .frame(minWidth: 680, minHeight: 460)
        .task(id: vm.compareIDs) { await load(retryFailed: false) }
    }

    private func highlight(for title: String, _ best: ComparisonColumn.Highlights) -> String? {
        switch title {
        case "Input price": return best.cheapestInputID
        case "Context": return best.largestContextID
        case "Max output": return best.largestOutputID
        case "Intelligence": return best.smartestID
        default: return nil
        }
    }

    private func load(retryFailed: Bool) async {
        let pending = vm.compareModels.filter { model in
            switch endpointResults[model.id] {
            case .none: return true
            case .failure: return retryFailed
            case .success: return false
            }
        }
        guard !pending.isEmpty else { return }
        let api = vm.api
        let results = await CompareEndpointLoader.load(
            pending.map { (id: $0.id, endpointsID: $0.endpointsModelID) },
            loader: { id in await api.loadEndpoints(for: id) }
        )
        endpointResults.merge(results) { _, new in new }
    }

    private func row(_ title: String, _ cols: [ComparisonColumn], highlight: String? = nil, value: @escaping (ComparisonColumn) -> String) -> some View {
        GridRow {
            Text(title).font(ORBFont.footnote).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
            ForEach(cols) { col in
                HStack(spacing: 4) {
                    Text(value(col)).font(ORBFont.footnote).textSelection(.enabled)
                        .lineLimit(title == "Parameters" ? 6 : 2)
                    if highlight == col.id {
                        Image(systemName: "checkmark.seal.fill").foregroundStyle(ORBTheme.success)
                            .help("Best in this comparison").accessibilityLabel("Best")
                    }
                }
                .frame(width: 170, alignment: .leading)
            }
        }
    }
}
