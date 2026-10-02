import SwiftUI

// MARK: - ViewModel

@MainActor
final class BrowserViewModel: ObservableObject {
    let api: APIService
    let db: DatabaseManager

    /// `defaults` enables persistence of filters and sort. nil (the default,
    /// and what tests use) keeps everything in memory.
    init(api: APIService? = nil, db: DatabaseManager = DatabaseManager.shared, defaults: UserDefaults? = nil) {
        self.api = api ?? APIService()
        self.db = db
        self.defaults = defaults
        if let defaults, let prefs = BrowserPrefsStore.load(from: defaults) {
            filters = prefs.filters
            sortField = SortField(rawValue: prefs.sortField) ?? .created
            sortOrder = prefs.ascending ? .ascending : .descending
            pinFavorites = prefs.pinFavorites
        }
    }

    private let defaults: UserDefaults?

    private func persistPrefs() {
        guard let defaults else { return }
        BrowserPrefsStore.save(
            BrowserPrefs(filters: filters, sortField: sortField.rawValue, ascending: sortOrder == .ascending, pinFavorites: pinFavorites),
            to: defaults
        )
    }

    @Published var searchText = ""
    @Published var sortField: SortField = .created { didSet { persistPrefs() } }
    @Published var sortOrder: SortOrder = .descending { didSet { persistPrefs() } }
    @Published var filters = BrowserFilterState() { didSet { persistPrefs() } }
    @Published var pinFavorites = true { didSet { persistPrefs() } }

    // Compare selection (Phase 4). Pick order is kept.
    @Published private(set) var compareIDs: [String] = []
    @Published private(set) var compareLimitNotice: String?
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

        if filters.isActive {
            result = result.filter(filters.matches)
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

        if pinFavorites, !favoriteIds.isEmpty {
            // Stable partition: favourites first, chosen order kept inside each half.
            result = result.filter { favoriteIds.contains($0.id) } + result.filter { !favoriteIds.contains($0.id) }
        }

        return result
    }

    var hasActiveRefinements: Bool {
        !searchText.isEmpty || filters.isActive || modalityFilter != .all || providerFilter != "All Providers"
    }

    func clearAllFilters() {
        searchText = ""
        filters.clear()
        modalityFilter = .all
        providerFilter = "All Providers"
    }

    func toggleSortDirection() {
        sortOrder = (sortOrder == .ascending) ? .descending : .ascending
    }

    // MARK: Compare

    var canAddToCompare: Bool { compareIDs.count < TestBatchSelection.maximumModels }

    func isComparing(_ id: String) -> Bool { compareIDs.contains(id) }

    /// Returns whether `id` is selected after the call.
    @discardableResult
    func toggleCompare(_ id: String) -> Bool {
        if let index = compareIDs.firstIndex(of: id) {
            compareIDs.remove(at: index)
            compareLimitNotice = nil
            return false
        }
        guard canAddToCompare else {
            compareLimitNotice = "You can compare up to \(TestBatchSelection.maximumModels) models."
            return false
        }
        compareIDs.append(id)
        compareLimitNotice = nil
        return true
    }

    func clearCompare() {
        compareIDs = []
        compareLimitNotice = nil
    }

    /// Drops IDs that vanished from a loaded catalog (never prunes against an empty one).
    func pruneCompare() {
        guard !api.models.isEmpty else { return }
        let known = Set(api.models.map(\.id))
        compareIDs.removeAll { !known.contains($0) }
    }

    var compareModels: [ModelInfo] {
        let lookup = Dictionary(api.models.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return compareIDs.compactMap { lookup[$0] }
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
    /// Sidebar label — short enough never to truncate next to a count badge.
    var title: String { self == .newThisWeek ? "New Models" : rawValue }
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
        case .account: return "person.crop.circle.fill"
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
    @StateObject private var vm = BrowserViewModel(defaults: .standard)
    // Keep independent, root-owned coordinators so an Agent run survives its
    // view disappearing and does not prevent a simultaneous direct Chat run.
    @StateObject private var agentService = ChatService()
    @StateObject private var chatService = ChatService()
    /// Last section, restored per window scene. `-orb.startSection <name>`
    /// (launch argument / defaults override) still wins on first appearance.
    @SceneStorage(ORBShell.sectionStorageKey) private var storedSection = ""
    @SceneStorage(ORBShell.sidebarHiddenStorageKey) private var sidebarHidden = false
    @State private var launchOverrideApplied = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var databaseFailure: DatabaseLaunchFailure?
    @State private var activeSheet: ShellSheet?
    @EnvironmentObject private var focusManager: FocusManager
    @EnvironmentObject private var shell: ShellController
    // Application-owned dependencies (W07).
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.openSettings) private var openSettings
    @FocusState private var searchFocused: Bool
    @ObservedObject private var appLock = AppLock.shared
    @State private var startedPostUnlockWork = false
    @State private var showOnboarding = false
    @State private var showFilters = false
    /// `-orb.reviewMode YES`: screenshot review — never touch legacy Keychain items.
    private static let reviewMode = UserDefaults.standard.bool(forKey: "orb.reviewMode")

    private static var startOverride: String? {
        UserDefaults.standard.string(forKey: ORBShell.startSectionDefaultsKey)
    }

    enum ShellSheet: String, Identifiable {
        case palette, shortcuts, compare
        var id: String { rawValue }
    }

    private var selectedSection: SidebarSection {
        ShellRestore.resolve(
            startOverride: launchOverrideApplied ? nil : Self.startOverride,
            stored: storedSection
        )
    }

    private var sectionBinding: Binding<SidebarSection?> {
        Binding(
            get: { selectedSection },
            set: { if let new = $0 { select(new) } }
        )
    }

    var body: some View {
        Group {
            if !appLock.isUnlocked {
                LockScreenView(
                    lock: appLock,
                    accent: ORBTheme.accent,
                    onOpenSettings: { openSettings() }
                )
            } else {
                shellView
            }
        }
        .onChange(of: selectedSection, initial: true) { _, section in
            StudioNotifier.shared.currentSection = section.rawValue
        }
        .onChange(of: appLock.isUnlocked, initial: true) { _, unlocked in
            guard unlocked, !showOnboarding else { return }
            showOnboarding = OnboardingGate.shouldPresent(
                outcome: UserDefaultsOnboardingStore().outcome,
                reviewMode: Self.reviewMode,
                forced: OnboardingGate.isForced()
            )
        }
        .sheet(isPresented: $showOnboarding) {
            OnboardingView { showOnboarding = false }
        }
        .task {
            AppLockMonitor.shared.start(lock: appLock)
            // With the lock disabled there is no onChange edge — set the
            // legacy-read gate from the initial state too.
            KeychainGate.allowsLegacyReads = appLock.isUnlocked && !Self.reviewMode
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
            KeychainGate.allowsLegacyReads = unlocked && !Self.reviewMode
            if unlocked { AppLockMonitor.shared.noteActivity() }
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
                select(.allModels)
                searchFocused = true
                focusManager.searchFocused = false
            }
        }
        .onChange(of: shell.pending) { _, request in
            guard let request else { return }
            shell.pending = nil
            guard appLock.isUnlocked else { return }
            perform(request.action)
        }
    }

    // MARK: Shell

    /// One NavigationSplitView for every section: the sidebar is never
    /// rebuilt; only the detail changes. Browser sections lay out the model
    /// list and model detail side by side inside the detail column.
    private var shellView: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
        } detail: {
            detailContent
                .navigationTitle(selectedSection.title)
        }
        .navigationSplitViewStyle(.balanced)
        .orbToastHost(AppToasts.center)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    perform(.refreshModels)
                } label: {
                    Label("Refresh Models", systemImage: "arrow.clockwise")
                }
                .help("Refresh models from OpenRouter (⌘R)")
                .disabled(vm.api.isLoading)
                .accessibilityLabel("Refresh models")

                Button {
                    perform(.showPalette)
                } label: {
                    Label("Command Palette", systemImage: "command")
                }
                .help("Command palette (⌘K)")
                .accessibilityLabel("Open command palette")
            }
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .palette:
                CommandPaletteView(index: paletteIndex) { action in
                    activeSheet = nil
                    perform(action)
                }
            case .shortcuts:
                ShortcutCheatSheet { activeSheet = nil }
            case .compare:
                ComparePanel(
                    vm: vm,
                    onTestSuite: { ids in activeSheet = nil; perform(.compareModels(ids)) },
                    onClose: { activeSheet = nil }
                )
            }
        }
        .onAppear {
            if !launchOverrideApplied {
                storedSection = selectedSection.rawValue
                launchOverrideApplied = true
            }
            columnVisibility = sidebarHidden ? .detailOnly : .all
            applyFilterEffects(for: selectedSection)
        }
        .onChange(of: columnVisibility) { _, visibility in
            sidebarHidden = (visibility == .detailOnly)
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        switch selectedSection {
        case .allModels, .favorites, .newThisWeek:
            HSplitView {
                modelListColumn
                    .frame(minWidth: 340, idealWidth: 440, maxWidth: 560)
                detailColumn
                    .frame(minWidth: 320, maxWidth: .infinity)
            }
        case .agent: NeedsKeyGate(studio: .agent) { AgentView(viewModel: vm, chatService: agentService) }
        case .chat: NeedsKeyGate(studio: .chat) { ChatView(viewModel: vm, chatService: chatService) }
        case .images: NeedsKeyGate(studio: .generate) { ImagesView() }
        case .video: NeedsKeyGate(studio: .generate) { VideoView() }
        case .files: NeedsKeyGate(studio: .generate) { FilesView() }
        case .speech: NeedsKeyGate(studio: .generate) { SpeechView() }
        case .embeddings: NeedsKeyGate(studio: .generate) { EmbeddingsView() }
        case .testSuite: TestSuiteView(viewModel: vm)
        case .account:
            // Retired from the sidebar; kept only so persisted values decode.
            SettingsView()
        }
    }

    // MARK: Actions

    private func select(_ section: SidebarSection) {
        guard section != .account else { openSettings(); return }
        storedSection = section.rawValue
        launchOverrideApplied = true
        applyFilterEffects(for: section)
    }

    private func applyFilterEffects(for section: SidebarSection) {
        let effects = AppRouter.filterEffects(for: section)
        vm.showFavoritesOnly = effects.showFavoritesOnly
        vm.showNewThisWeek = effects.showNewThisWeek
    }

    private func perform(_ action: ShellAction) {
        switch action {
        case .section(let section):
            select(section)
        case .newChat:
            select(.chat)
            _ = chatService.newConversation(modelId: preferredModelId(for: .chat), mode: .chat)
        case .newAgent:
            select(.agent)
            _ = agentService.newConversation(modelId: preferredModelId(for: .agent), mode: .agent)
        case .refreshModels:
            Task { await vm.refresh() }
        case .toggleSidebar:
            columnVisibility = (columnVisibility == .detailOnly) ? .all : .detailOnly
        case .openSettings:
            openSettings()
        case .showShortcuts:
            activeSheet = .shortcuts
        case .showPalette:
            activeSheet = .palette
        case .selectModel(let id):
            select(.allModels)
            vm.searchText = ""
            vm.clearAllFilters()
            if let model = vm.api.models.first(where: { $0.id == id }) {
                vm.selectModel(model)
            }
        case .compareModels(let ids):
            let eligible = CompareHandoff.batchIDs(from: ids, catalog: vm.api.models)
            CompareHandoff.shared.stage(eligible)
            select(.testSuite)
        case .chatWithModel(let id):
            select(.chat)
            _ = chatService.newConversation(modelId: id, mode: .chat)
        case .agentWithModel(let id):
            select(.agent)
            _ = agentService.newConversation(modelId: id, mode: .agent)
        case .openConversation(let id, let mode):
            let service = (mode == .chat) ? chatService : agentService
            select(mode == .chat ? .chat : .agent)
            if let conversation = service.conversations.first(where: { $0.id == id }) {
                service.selectConversation(conversation)
            }
        }
    }

    /// Mirrors ChatView/AgentView's own default-model resolution so ⌘N and
    /// the in-view New button create sessions with the same model.
    private func preferredModelId(for mode: PlaygroundMode) -> String {
        let key = (mode == .chat) ? PlaygroundModelDefaults.chatKey : PlaygroundModelDefaults.agentKey
        let fallback = vm.selectedModel?.id ?? vm.api.models.first?.id ?? "openai/gpt-4o"
        return PlaygroundModelDefaults.resolve(
            storedModelId: UserDefaults.standard.string(forKey: key) ?? "",
            availableModelIds: vm.api.models.map(\.id),
            fallbackModelId: fallback
        )
    }

    private var paletteIndex: PaletteIndex {
        let favorites = vm.api.models
            .filter { vm.favoriteIds.contains($0.id) }
            .map { PaletteModel(id: $0.id, name: $0.name) }
        let chats = chatService.conversations.filter { $0.mode == .chat }
        let agents = agentService.conversations.filter { $0.mode == .agent }
        let conversations = (chats + agents).map {
            PaletteConversation(id: $0.id, title: $0.title, mode: $0.mode, createdAt: $0.createdAt)
        }
        return PaletteIndex(favoriteModels: favorites, conversations: conversations)
    }

    /// One-time post-unlock side effects: batch-migrate any remaining legacy
    /// keychain items (each prompts once — "Allow" — then the value lives in
    /// prompt-free v2 storage forever), then bring MCP servers up so their
    /// tools register before the first agent run. Never runs while locked.
    private func startPostUnlockWorkIfNeeded() async {
        guard appLock.isUnlocked, !startedPostUnlockWork else { return }
        startedPostUnlockWork = true
        if !Self.reviewMode { KeychainSecrets.migrateAllLegacy() }
        await MCPRegistry.shared.startEnabledServers()
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: sectionBinding) {
            ForEach(SidebarGroup.allCases) { group in
                Section(group.title) {
                    ForEach(group.sections) { section in
                        sidebarRow(section)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .tint(ORBTheme.accent)
        .navigationSplitViewColumnWidth(min: 196, ideal: 208, max: 250)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            SidebarAccountChip()
        }
    }

    private func sidebarRow(_ section: SidebarSection) -> some View {
        Label {
            HStack(spacing: 6) {
                Text(section.title).lineLimit(1)
                Spacer(minLength: 4)
                activityBadge(for: section)
            }
        } icon: {
            Image(systemName: section.icon)
        }
        .badge(sidebarCount(section))
        .tag(section)
        .help(sidebarHelp(section))
    }

    @ViewBuilder
    private func activityBadge(for section: SidebarSection) -> some View {
        if section == .agent {
            ChatActivityBadge(service: agentService, tint: .secondary)
        } else if section == .chat {
            ChatActivityBadge(service: chatService, tint: .secondary)
        } else {
            SidebarActivityBadge(section: section, tint: .secondary)
        }
    }

    private func sidebarHelp(_ section: SidebarSection) -> String {
        guard let digit = ShellShortcuts.digit(for: section) else { return section.title }
        return "\(section.title) (⌘\(digit))"
    }

    private func sidebarCount(_ section: SidebarSection) -> Int {
        switch section {
        case .allModels: return vm.api.models.count
        case .favorites: return vm.favoriteIds.count
        case .newThisWeek: return vm.newThisWeekCount
        default: return 0
        }
    }

    // MARK: Model List Column

    private var modelListColumn: some View {
        VStack(spacing: 0) {
            searchBar
            filterRow
            ActiveFilterChips(vm: vm)
                .padding(.horizontal, 14)
                .padding(.bottom, 6)
            statusBar
            Divider()
            if case .list(let offlineSince?) = listState {
                OfflineBanner(since: offlineSince) { Task { await vm.refresh() } }
            }
            modelList
            CompareBar(vm: vm) { activeSheet = .compare }
        }
    }

    private var listState: BrowserListState {
        BrowserListState.resolve(
            isLoading: vm.api.isLoading,
            hasModels: !vm.api.models.isEmpty,
            error: vm.api.errorMessage ?? (vm.api.models.isEmpty ? nil : vm.api.lastRefreshError),
            resultCount: vm.filteredModels.count,
            hasRefinements: vm.hasActiveRefinements,
            lastUpdated: vm.api.lastRefresh
        )
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
                .help("Clear search")
                .accessibilityLabel("Clear search")
            }
        }
        .font(ORBFont.body)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
        .overlay { RoundedRectangle(cornerRadius: 9).stroke(Color.primary.opacity(0.08), lineWidth: 0.5) }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    /// One compact row: Filters popover, sort field + direction, pin toggle.
    private var filterRow: some View {
        HStack(spacing: 8) {
            Button { showFilters.toggle() } label: {
                Label(vm.filters.isActive ? "Filters (\(vm.filters.chips.count))" : "Filters",
                      systemImage: "line.3.horizontal.decrease.circle\(vm.filters.isActive ? ".fill" : "")")
                    .font(ORBFont.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Filter by capability, price, context and provider")
            .popover(isPresented: $showFilters, arrowEdge: .bottom) { BrowserFiltersPopover(vm: vm) }

            Spacer()

            Toggle(isOn: $vm.pinFavorites) {
                Image(systemName: vm.pinFavorites ? "pin.fill" : "pin")
            }
            .toggleStyle(.button)
            .buttonStyle(.borderless)
            .help(vm.pinFavorites ? "Favorites are pinned to the top" : "Pin favorites to the top")
            .accessibilityLabel("Pin favorites to the top")

            BrowserSortControl(vm: vm)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 6)
    }

    private var statusBar: some View {
        HStack {
            Text("\(vm.filteredModels.count) models")
                .font(ORBFont.footnote.weight(.medium))
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
                .accessibilityLabel("Refresh models")
            }
            if let ts = vm.api.lastRefresh {
                Text("Updated \(ts.formatted(.relative(presentation: .named)))")
                    .font(ORBFont.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var modelList: some View {
        switch listState {
        case .skeleton:
            SkeletonModelList()
        case .error(let error):
            VStack(spacing: 12) {
                Image(systemName: "wifi.exclamationmark")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(error)
                    .foregroundStyle(.secondary)
                Button("Retry") { Task { await vm.refresh() } }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .noResults:
            NoResultsView(vm: vm)
        case .emptySection:
            VStack(spacing: 12) {
                Image(systemName: vm.showFavoritesOnly ? "star" : "tray")
                    .font(.system(size: 36))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
                Text(vm.showFavoritesOnly ? "No favorites yet" : (vm.showNewThisWeek ? "Nothing new this week" : "No models"))
                    .font(ORBFont.headline)
                    .foregroundStyle(.secondary)
                Text(vm.showFavoritesOnly ? "Star models to add them here"
                     : (vm.showNewThisWeek ? "No models were added in the last 7 days" : "Refresh to load the catalog"))
                    .font(ORBFont.caption)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .list:
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
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(ORBTheme.accent)
                }
                Text("Select a model")
                    .font(.title2.weight(.semibold))
                Text(vm.api.models.isEmpty
                     ? "Loading the OpenRouter catalog…"
                     : "\(vm.api.models.count) models across \(max(vm.providerOptions.count - 1, 0)) providers")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
