import SwiftUI

// MARK: - ViewModel

@MainActor
final class BrowserViewModel: ObservableObject {
    let api = APIService()
    let db = DatabaseManager.shared

    @Published var searchText = ""
    @Published var sortField: SortField = .created
    @Published var sortOrder: SortOrder = .descending
    @Published var modalityFilter: ModalityFilter = .all
    @Published var providerFilter: String = "All Providers"
    @Published var selectedModel: ModelInfo?
    @Published var showFavoritesOnly = false
    @Published var showNewThisWeek = false
    @Published var copiedModelId: String?

    @Published var favoriteIds: Set<String> = []
    @Published var newThisWeekCount = 0

    // Per-provider endpoints for the selected model
    @Published var endpoints: [ModelEndpoint] = []
    @Published var isLoadingEndpoints = false

    var providerOptions: [String] {
        var set = Set<String>()
        for model in api.models {
            set.insert(model.provider)
        }
        return ["All Providers"] + set.sorted()
    }

    var filteredModels: [ModelInfo] {
        var result = api.models

        if showFavoritesOnly {
            result = result.filter { favoriteIds.contains($0.id) }
        }

        if showNewThisWeek {
            result = result.filter { isNewThisWeek($0) }
        }

        if providerFilter != "All Providers" {
            result = result.filter { $0.provider == providerFilter }
        }

        switch modalityFilter {
        case .all: break
        case .textOnly: result = result.filter { !$0.supportsImages }
        case .multimodal: result = result.filter { $0.supportsImages }
        case .imageOut: result = result.filter { $0.supportsImageOutput }
        case .tools: result = result.filter { $0.supportsTools }
        case .reasoning: result = result.filter { $0.supportsReasoning }
        case .freeOnly: result = result.filter { $0.isFree }
        }

        if !searchText.isEmpty {
            let q = searchText.lowercased()
            result = result.filter {
                $0.id.lowercased().contains(q) ||
                $0.name.lowercased().contains(q) ||
                $0.provider.lowercased().contains(q) ||
                ($0.description?.lowercased().contains(q) ?? false)
            }
        }

        result.sort { a, b in
            let cmp: ComparisonResult
            switch sortField {
            case .name:
                cmp = a.name.localizedCaseInsensitiveCompare(b.name)
            case .contextLength:
                let la = a.contextLength ?? 0
                let lb = b.contextLength ?? 0
                cmp = la == lb ? .orderedSame : (la < lb ? .orderedAscending : .orderedDescending)
            case .promptCost:
                let ca = a.promptCostPer1M ?? -1
                let cb = b.promptCostPer1M ?? -1
                cmp = ca == cb ? .orderedSame : (ca < cb ? .orderedAscending : .orderedDescending)
            case .completionCost:
                let ca = a.completionCostPer1M ?? -1
                let cb = b.completionCostPer1M ?? -1
                cmp = ca == cb ? .orderedSame : (ca < cb ? .orderedAscending : .orderedDescending)
            case .created:
                let da = a.created ?? 0
                let db2 = b.created ?? 0
                cmp = da == db2 ? .orderedSame : (da < db2 ? .orderedAscending : .orderedDescending)
            case .provider:
                cmp = a.provider.localizedCaseInsensitiveCompare(b.provider)
            case .designElo:
                let ea = a.bestDesignElo ?? -1
                let eb = b.bestDesignElo ?? -1
                cmp = ea == eb ? .orderedSame : (ea < eb ? .orderedAscending : .orderedDescending)
            }
            return sortOrder == .ascending ? (cmp == .orderedAscending) : (cmp == .orderedDescending)
        }

        return result
    }

    func loadFavorites() {
        favoriteIds = Set(db.getAllFavorites())
    }

    func toggleFavorite(_ model: ModelInfo) {
        db.toggleFavorite(model.id)
        loadFavorites()
    }

    func copyModelId(_ model: ModelInfo) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(model.id, forType: .string)
        copiedModelId = model.id
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if copiedModelId == model.id {
                copiedModelId = nil
            }
        }
    }

    func selectModel(_ model: ModelInfo?) {
        guard let model else {
            selectedModel = nil
            endpoints = []
            return
        }
        // Avoid double-fetch if already selected
        guard selectedModel?.id != model.id else { return }
        selectedModel = model
        fetchEndpointsForSelected()
    }

    /// Force-refresh endpoints for the currently selected model (e.g. retry after error).
    func refetchEndpoints() {
        guard selectedModel != nil else { return }
        fetchEndpointsForSelected()
    }

    private func fetchEndpointsForSelected() {
        guard let model = selectedModel else { return }
        Task {
            isLoadingEndpoints = true
            let eps = await api.fetchEndpoints(for: model.id)
            endpoints = eps
            isLoadingEndpoints = false
        }
    }

    func refresh() async {
        await api.fetchModels()
        loadFavorites()
        newThisWeekCount = api.models.filter { isNewThisWeek($0) }.count
        if let m = selectedModel {
            selectModel(m)
        }
    }

    func isNewThisWeek(_ model: ModelInfo) -> Bool {
        guard let d = model.createdDate else { return false }
        return d > Date().addingTimeInterval(-7 * 86400)
    }
}

// MARK: - Sidebar Section

enum SidebarSection: String, CaseIterable, Identifiable {
    case allModels = "All Models"
    case favorites = "Favorites"
    case newThisWeek = "New This Week"
    case playground = "Playground"
    case account = "Account"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .allModels: return "square.grid.2x2"
        case .favorites: return "star.fill"
        case .newThisWeek: return "sparkles"
        case .playground: return "wand.and.stars"
        case .account: return "gearshape.fill"
        }
    }

    var isBrowser: Bool {
        self == .allModels || self == .favorites || self == .newThisWeek
    }
}

// MARK: - ContentView

struct ContentView: View {
    @StateObject private var vm = BrowserViewModel()
    @State private var selectedSection: SidebarSection = .allModels
    @EnvironmentObject private var focusManager: FocusManager
    @FocusState private var searchFocused: Bool

    var body: some View {
        Group {
            if selectedSection.isBrowser {
                NavigationSplitView {
                    sidebar
                } content: {
                    modelListColumn
                } detail: {
                    detailColumn
                }
            } else {
                NavigationSplitView {
                    sidebar
                } detail: {
                    if selectedSection == .playground {
                        ChatView(viewModel: vm)
                    } else if selectedSection == .account {
                        SettingsView()
                    }
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .task {
            await vm.refresh()
        }
        .onChange(of: focusManager.searchFocused) { _, newValue in
            if newValue {
                searchFocused = true
                focusManager.searchFocused = false
            }
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: $selectedSection) {
            // Browser sections
            Section("Browse") {
                sidebarRow(.allModels)
                sidebarRow(.favorites)
                sidebarRow(.newThisWeek)
            }
            // Tools
            Section("Tools") {
                sidebarRow(.playground)
                sidebarRow(.account)
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 220)
        .onChange(of: selectedSection) { _, newValue in
            vm.showFavoritesOnly = (newValue == .favorites)
            vm.showNewThisWeek = (newValue == .newThisWeek)
        }
    }

    @ViewBuilder
    private func sidebarRow(_ section: SidebarSection) -> some View {
        let count = sidebarCount(section)
        let isSelected = (selectedSection == section)
        Button {
            selectedSection = section
            vm.showFavoritesOnly = (section == .favorites)
            vm.showNewThisWeek = (section == .newThisWeek)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: section.icon)
                    .font(.system(size: 12))
                Text(section.rawValue)
                Spacer()
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
            .padding(.vertical, 3)
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
        .font(isSelected ? .body.weight(.semibold) : .body)
        .listRowBackground(isSelected ? Color.accentColor.opacity(0.12).opacity(0.5) : Color.clear)
        .tag(section)
    }

    private func sidebarCount(_ section: SidebarSection) -> Int {
        switch section {
        case .allModels: return vm.api.models.count
        case .favorites: return vm.favoriteIds.count
        case .newThisWeek: return vm.newThisWeekCount
        case .playground, .account: return 0
        }
    }

    // MARK: Model List Column

    private var modelListColumn: some View {
        VStack(spacing: 0) {
            searchBar
            filterBar
            statusBar
            Divider()
            modelList
        }
        .navigationSplitViewColumnWidth(min: 380, ideal: 460, max: 580)
    }

    private var searchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search models...", text: $vm.searchText)
                .textFieldStyle(.plain)
                .focused($searchFocused)
            if !vm.searchText.isEmpty {
                Button { vm.searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    private var filterBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Filter", selection: $vm.modalityFilter) {
                ForEach(ModalityFilter.allCases) { f in
                    Text(f.rawValue).tag(f)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            HStack {
                // Provider filter
                Menu {
                    Picker("Provider", selection: $vm.providerFilter) {
                        ForEach(vm.providerOptions, id: \.self) { p in
                            Text(p).tag(p)
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "building.2")
                        Text(vm.providerFilter)
                            .lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 9))
                    }
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.quaternary.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                Spacer()

                // Sort menu
                Menu {
                    ForEach(SortField.allCases) { field in
                        Button {
                            if vm.sortField == field {
                                vm.sortOrder = vm.sortOrder == .ascending ? .descending : .ascending
                            } else {
                                vm.sortField = field
                                vm.sortOrder = .ascending
                            }
                        } label: {
                            HStack {
                                Text(field.rawValue)
                                if vm.sortField == field {
                                    Image(systemName: vm.sortOrder == .ascending ? "arrow.up" : "arrow.down")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.up.arrow.down")
                        Text(vm.sortField.rawValue)
                            .font(.caption)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.quaternary.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }

    private var statusBar: some View {
        HStack {
            Text("\(vm.filteredModels.count) models")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if vm.api.isLoading {
                ProgressView()
                    .scaleEffect(0.6)
            } else {
                Button { Task { await vm.refresh() } } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .help("Refresh models from OpenRouter")
            }
            if let ts = vm.api.lastRefresh {
                Text("Updated \(ts.formatted(.relative(presentation: .named)))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var modelList: some View {
        if vm.api.isLoading && vm.api.models.isEmpty {
            VStack(spacing: 12) {
                ProgressView()
                Text("Loading models from OpenRouter...")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = vm.api.errorMessage {
            VStack(spacing: 12) {
                Image(systemName: "wifi.exclamationmark")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text(error)
                    .foregroundStyle(.secondary)
                Button("Retry") { Task { await vm.refresh() } }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if vm.filteredModels.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 36))
                    .foregroundStyle(.tertiary)
                Text("No models found")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                if !vm.searchText.isEmpty {
                    Text("Try a different search term or clear filters")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else if vm.showFavoritesOnly {
                    Text("Star models with the star icon to add them here")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else if vm.showNewThisWeek {
                    Text("No models were added in the last 7 days")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    Text("Try changing your filters")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(vm.filteredModels, selection: $vm.selectedModel) { model in
                ModelRowView(model: model, viewModel: vm)
                    .tag(model)
            }
            .listStyle(.inset)
            .onChange(of: vm.selectedModel) { _, newValue in
                vm.selectModel(newValue)
            }
        }
    }

    // MARK: Detail

    @ViewBuilder
    private var detailColumn: some View {
        if let model = vm.selectedModel {
            ModelDetailView(model: model, viewModel: vm)
        } else {
            VStack(spacing: 16) {
                Image(systemName: "cpu")
                    .font(.system(size: 48))
                    .foregroundStyle(.tertiary)
                Text("Select a model")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("Browse hundreds of models across " +
                     "\(vm.providerOptions.count - 1) providers on OpenRouter")
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
