import SwiftUI

// MARK: - ViewModel

@MainActor
final class BrowserViewModel: ObservableObject {
    let api: APIService
    let db: DatabaseManager

    init(api: APIService? = nil, db: DatabaseManager = DatabaseManager.shared) {
        self.api = api ?? APIService()
        self.db = db
    }

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

    /// ID of the selection the current endpoint fetch belongs to. The List
    /// binding writes `selectedModel` directly before `selectModel` runs, so
    /// this internal value — not the binding-mutated property — is the
    /// authoritative transition identity.
    private var selectedModelId: String?
    private var endpointTask: Task<Void, Never>?

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
        case .textOnly: result = result.filter { $0.inputModalities == ["text"] }
        case .multimodal: result = result.filter { $0.supportsImages }
        case .imageOut: result = result.filter { $0.supportsImageOutput }
        case .videoIn: result = result.filter { $0.supportsVideoInput }
        case .audio: result = result.filter { $0.supportsAudioInput || $0.supportsAudioOutput }
        case .files: result = result.filter { $0.supportsFileInput }
        case .tools: result = result.filter { $0.supportsTools }
        case .reasoning: result = result.filter { $0.supportsReasoning }
        case .embeddings: result = result.filter { $0.isEmbeddingModel }
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
            deselect()
            return
        }
        // Single owned transition: equality is checked against the ID this
        // view model last transitioned to, so re-selecting the current model
        // never duplicates a fetch.
        guard model.id != selectedModelId else { return }
        beginEndpointTransition(model)
    }

    /// Force-refresh endpoints for the currently selected model (e.g. retry after error).
    func refetchEndpoints() {
        guard let model = selectedModel else { return }
        beginEndpointTransition(model)
    }

    private func deselect() {
        selectedModelId = nil
        endpointTask?.cancel()
        endpointTask = nil
        selectedModel = nil
        endpoints = []
        isLoadingEndpoints = false
    }

    /// One owned fetch per selection transition, cancellable and keyed to the
    /// selected model ID. Results are applied only if the selection still
    /// matches the model the request was started for, so a slow response for
    /// A can never populate B's detail view.
    private func beginEndpointTransition(_ model: ModelInfo) {
        endpointTask?.cancel()
        selectedModelId = model.id
        selectedModel = model
        endpoints = []
        isLoadingEndpoints = true
        endpointTask = Task { [weak self] in
            guard let api = self?.api else { return }
            let eps = await api.fetchEndpoints(for: model.id)
            guard let self, !Task.isCancelled, self.selectedModelId == model.id else { return }
            self.endpoints = eps
            self.isLoadingEndpoints = false
        }
    }

    func refresh() async {
        await api.fetchModels()
        loadFavorites()
        newThisWeekCount = api.models.filter { isNewThisWeek($0) }.count
        // Refetch the selected model's endpoints explicitly; routing through
        // selectModel would be suppressed by the same-model equality guard.
        if let m = selectedModel {
            beginEndpointTransition(m)
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
    case agent = "Agent"
    case chat = "Chat"
    case images = "Images"
    case video = "Video"
    case files = "Files"
    case speech = "Speech"
    case embeddings = "Embeddings"
    case testSuite = "Test Suite"
    case account = "Account"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .allModels: return "square.grid.2x2"
        case .favorites: return "star.fill"
        case .newThisWeek: return "sparkles"
        case .agent: return "wand.and.stars"
        case .chat: return "bubble.left.fill"
        case .images: return "photo.fill"
        case .video: return "video.fill"
        case .files: return "folder.fill"
        case .speech: return "speaker.wave.2.fill"
        case .embeddings: return "chart.dots.scatter"
        case .testSuite: return "checkmark.seal.fill"
        case .account: return "gearshape.fill"
        }
    }

    var isBrowser: Bool {
        self == .allModels || self == .favorites || self == .newThisWeek
    }

    var isMediaTool: Bool {
        switch self {
        case .images, .video, .files, .speech, .embeddings: return true
        default: return false
        }
    }
}

// MARK: - ContentView

struct ContentView: View {
    @StateObject private var vm = BrowserViewModel()
    // Keep independent, root-owned coordinators so an Agent run survives its
    // view disappearing and does not prevent a simultaneous direct Chat run.
    @StateObject private var agentService = ChatService()
    @StateObject private var chatService = ChatService()
    @State private var selectedSection: SidebarSection = .allModels
    @State private var databaseFailure: DatabaseLaunchFailure?
    @EnvironmentObject private var focusManager: FocusManager
    // Application-owned dependencies (W07). Declared now so the injection
    // path is live; consumers keep their current initializers until the
    // supervised shell session migrates them additively.
    @EnvironmentObject private var environment: AppEnvironment
    @FocusState private var searchFocused: Bool
    @ObservedObject private var appLock = AppLock.shared
    @State private var startedPostUnlockWork = false

    var body: some View {
        Group {
            if !appLock.isUnlocked {
                LockScreenView(
                    lock: appLock,
                    accent: ORBTheme.accent,
                    onOpenSettings: { selectedSection = .account }
                )
            } else if selectedSection.isBrowser {
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
                    if selectedSection == .agent {
                        AgentView(viewModel: vm, chatService: agentService)
                    } else if selectedSection == .chat {
                        ChatView(viewModel: vm, chatService: chatService)
                    } else if selectedSection == .images {
                        ImagesView()
                    } else if selectedSection == .video {
                        VideoView()
                    } else if selectedSection == .files {
                        FilesView()
                    } else if selectedSection == .speech {
                        SpeechView()
                    } else if selectedSection == .embeddings {
                        EmbeddingsView()
                    } else if selectedSection == .testSuite {
                        TestSuiteView(viewModel: vm)
                    } else if selectedSection == .account {
                        SettingsView()
                    }
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .task {
            // With the lock disabled there is no onChange edge — set the
            // legacy-read gate from the initial state too.
            KeychainGate.allowsLegacyReads = appLock.isUnlocked
            if let failure = DatabaseManager.lastLaunchFailure {
                databaseFailure = failure
                DatabaseManager.lastLaunchFailure = nil
            }
            await vm.refresh()
            await startPostUnlockWorkIfNeeded()
        }
        .onChange(of: appLock.isUnlocked) { _, unlocked in
            // Legacy keychain reads (the one prompt-capable operation) are
            // allowed only while unlocked — see KeychainGate.
            KeychainGate.allowsLegacyReads = unlocked
            if unlocked {
                Task { await startPostUnlockWorkIfNeeded() }
            }
        }
        .alert(
            Text(databaseFailure?.title ?? "Database Problem"),
            isPresented: .init(
                get: { databaseFailure != nil },
                set: { if !$0 { databaseFailure = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(databaseFailure?.detail ?? "")
        }
        .onChange(of: focusManager.searchFocused) { _, newValue in
            if newValue {
                selectedSection = .allModels
                searchFocused = true
                focusManager.searchFocused = false
            }
        }
    }

    // MARK: Sidebar

    /// One-time post-unlock side effects: batch-migrate any remaining legacy
    /// keychain items (each prompts once — "Allow" — then the value lives in
    /// prompt-free v2 storage forever), then bring MCP servers up so their
    /// tools register before the first agent run. Never runs while locked.
    private func startPostUnlockWorkIfNeeded() async {
        guard appLock.isUnlocked, !startedPostUnlockWork else { return }
        startedPostUnlockWork = true
        KeychainSecrets.migrateAllLegacy()
        await MCPRegistry.shared.startEnabledServers()
    }

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
                sidebarRow(.agent)
                sidebarRow(.chat)
                sidebarRow(.testSuite)
                sidebarRow(.account)
            }
            // Generate
            Section("Generate") {
                sidebarRow(.images)
                sidebarRow(.video)
                sidebarRow(.files)
                sidebarRow(.speech)
                sidebarRow(.embeddings)
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 220)
        .onChange(of: selectedSection) { _, newValue in
            let effects = AppRouter.filterEffects(for: newValue)
            vm.showFavoritesOnly = effects.showFavoritesOnly
            vm.showNewThisWeek = effects.showNewThisWeek
        }
    }

    @ViewBuilder
    private func sidebarRow(_ section: SidebarSection) -> some View {
        let count = sidebarCount(section)
        let isSelected = (selectedSection == section)
        Button {
            selectedSection = section
            let effects = AppRouter.filterEffects(for: section)
            vm.showFavoritesOnly = effects.showFavoritesOnly
            vm.showNewThisWeek = effects.showNewThisWeek
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
        .foregroundStyle(isSelected ? ORBTheme.accent : Color.primary)
        .font(isSelected ? .body.weight(.semibold) : .body)
        .listRowBackground(isSelected ? ORBTheme.accent.opacity(0.12) : Color.clear)
        .tag(section)
    }

    private func sidebarCount(_ section: SidebarSection) -> Int {
        switch section {
        case .allModels: return vm.api.models.count
        case .favorites: return vm.favoriteIds.count
        case .newThisWeek: return vm.newThisWeekCount
        case .agent, .chat, .testSuite, .account: return 0
        case .images, .video, .files, .speech, .embeddings: return 0
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
            // Wrapping chips, not a segmented picker: 11 tabs in one line
            // overflow the column, forcing horizontal scroll that slides the
            // whole list underneath the sidebar.
            FlowLayout(spacing: 6) {
                ForEach(ModalityFilter.allCases) { f in
                    filterChip(f)
                }
            }

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

    private func filterChip(_ filter: ModalityFilter) -> some View {
        let isSelected = vm.modalityFilter == filter
        return Button {
            vm.modalityFilter = filter
        } label: {
            Text(filter.rawValue)
                .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(isSelected ? ORBTheme.accent.opacity(0.18) : Color.primary.opacity(0.08))
                .foregroundStyle(isSelected ? ORBTheme.accent : Color.primary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("\(filter.rawValue) models")
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
                    .foregroundStyle(.secondary)
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
            VStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(ORBTheme.accent.opacity(0.08))
                        .frame(width: 84, height: 84)
                    Image(systemName: "cpu")
                        .font(.system(size: 34))
                        .foregroundStyle(ORBTheme.accent.opacity(0.75))
                }
                Text("Select a model")
                    .font(.title2.weight(.semibold))
                Text("Browse hundreds of models across " +
                     "\(vm.providerOptions.count - 1) providers on OpenRouter")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
