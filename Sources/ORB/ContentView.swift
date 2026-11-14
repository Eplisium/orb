import SwiftUI
import Combine

// MARK: - ViewModel

@MainActor
final class BrowserViewModel: ObservableObject {
    let api: APIService
    let db: DatabaseManager

    /// `defaults` enables persistence of filters, sort and the compare
    /// selection. nil (the default, and what tests use) keeps everything in
    /// memory.
    init(
        api: APIService? = nil, db: DatabaseManager = DatabaseManager.shared, defaults: UserDefaults? = nil,
        notifications: NotificationCenter = .default
    ) {
        self.api = api ?? APIService()
        self.db = db
        self.defaults = defaults
        if let defaults, let prefs = BrowserPrefsStore.load(from: defaults) {
            filters = prefs.filters
            sortField = SortField(rawValue: prefs.sortField) ?? .created
            sortOrder = prefs.ascending ? .ascending : .descending
            pinFavorites = prefs.pinFavorites
            compareIDs = Array((prefs.compareIDs ?? []).prefix(TestBatchSelection.maximumModels))
        }
        restoringPrefs = false
        catalogChanged(self.api.catalog)
        // `$catalog` emits synchronously on willSet with the new value, so the
        // index/version are current before anyone reads `filteredModels`.
        // The browser lists the whole catalog; Chat, Agent and Test Suite
        // read `api.models` (chat-capable only).
        catalogSubscription = self.api.$catalog.dropFirst().sink { [weak self] models in
            MainActor.assumeIsolated { self?.catalogChanged(models) }
        }
        // Views observe this view model, not the service, so the service's
        // loading and error state must republish here to render (a refresh
        // spinner, the offline banner). One-way, so it cannot loop.
        apiSubscription = self.api.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        // Notes are saved after a typing pause; quitting inside that pause
        // must not lose them.
        terminationSubscription = notifications
            .publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.flushPendingNotes() }
            }
    }

    private let defaults: UserDefaults?
    private var restoringPrefs = true
    private var catalogSubscription: AnyCancellable?
    private var apiSubscription: AnyCancellable?
    private var terminationSubscription: AnyCancellable?

    private func persistPrefs() {
        guard let defaults, !restoringPrefs else { return }
        BrowserPrefsStore.save(
            BrowserPrefs(
                filters: filters, sortField: sortField.rawValue, ascending: sortOrder == .ascending,
                pinFavorites: pinFavorites, compareIDs: compareIDs
            ),
            to: defaults
        )
    }

    /// The query actually applied. The search field edits `searchDraft`,
    /// which is debounced into this; setting it directly applies at once.
    @Published var searchText = "" {
        didSet { if searchDraft != searchText { searchDraft = searchText } }
    }
    /// Live text in the search field. Deliberately not published: the field
    /// keeps its own state, so a keystroke re-renders only the field, not
    /// the shell, the detail pane and every row (the debounced commit to
    /// `searchText` is what the list observes).
    var searchDraft = "" {
        didSet { scheduleSearchCommit() }
    }
    @Published var sortField: SortField = .created { didSet { persistPrefs() } }
    @Published var sortOrder: SortOrder = .descending { didSet { persistPrefs() } }
    @Published var filters = BrowserFilterState() { didSet { persistPrefs() } }
    @Published var pinFavorites = true { didSet { persistPrefs() } }

    // Compare selection (Phase 4). Pick order is kept.
    @Published private(set) var compareIDs: [String] = [] { didSet { persistPrefs() } }
    @Published private(set) var compareLimitNotice: String?
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

    // MARK: Search debounce

    static let searchDebounce: Duration = .milliseconds(150)
    private var searchTask: Task<Void, Never>?

    /// Applies the field's text now (Return or ↓ before the debounce fires).
    func commitSearchNow() {
        searchTask?.cancel()
        if searchText != searchDraft { searchText = searchDraft }
    }

    private func scheduleSearchCommit() {
        searchTask?.cancel()
        guard searchDraft != searchText else { return }
        // Clearing applies immediately; typing waits for a pause.
        if searchDraft.isEmpty { searchText = ""; return }
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: Self.searchDebounce)
            guard !Task.isCancelled, let self else { return }
            self.searchText = self.searchDraft
        }
    }

    // MARK: Catalog-derived caches

    private var catalogVersion = 0
    private var searchIndex = ModelSearchIndex([])
    private(set) var providerOptions: [String] = ["All Providers"]
    private var cachedResult: (version: Int, query: BrowserQuery, models: [ModelInfo])?

    /// Batch-only variants in the catalog (hidden unless the filter shows them).
    private(set) var batchVariantCount = 0

    private func catalogChanged(_ models: [ModelInfo]) {
        catalogVersion &+= 1
        searchIndex = ModelSearchIndex(models)
        providerOptions = ["All Providers"] + Set(models.map(\.provider)).sorted()
        batchVariantCount = models.filter(\.isBatchOnly).count
        cachedResult = nil
        rowFactsCache = [:]
        rowFactsUnit = nil
        newThisWeekCount = NewModelCount.distinct(models, isNew: isNewThisWeek)
    }

    /// Models the All Models list can show (batch variants only when asked).
    var listedCatalogCount: Int {
        api.catalog.count - (filters.showBatchVariants ? 0 : batchVariantCount)
    }

    // MARK: Row facts cache

    private var rowFactsCache: [String: ModelRowFacts] = [:]
    private var rowFactsUnit: PriceUnit?
    /// How many times row facts were computed (tests).
    private(set) var rowFactsBuilds = 0

    /// Row text (description cleaning is several regex passes) built once
    /// per model per catalog and price unit, not on every row render.
    func rowFacts(for model: ModelInfo, unit: PriceUnit) -> ModelRowFacts {
        if rowFactsUnit != unit {
            rowFactsCache = [:]
            rowFactsUnit = unit
        }
        if let cached = rowFactsCache[model.id] { return cached }
        rowFactsBuilds += 1
        let facts = ModelRowFacts.make(model, unit: unit)
        rowFactsCache[model.id] = facts
        return facts
    }

    private var currentQuery: BrowserQuery {
        BrowserQuery(
            showFavoritesOnly: showFavoritesOnly, showNewThisWeek: showNewThisWeek,
            favoriteIds: favoriteIds, filters: filters, searchText: searchText,
            sortField: sortField, sortOrder: sortOrder, pinFavorites: pinFavorites
        )
    }

    /// Memoised: recomputed only when the catalog or a query input changes,
    /// so the several reads per render cost one comparison each.
    var filteredModels: [ModelInfo] {
        let query = currentQuery
        if let cached = cachedResult, cached.version == catalogVersion, cached.query == query {
            return cached.models
        }
        let result = query.run(api.catalog, index: searchIndex, isNew: isNewThisWeek)
        cachedResult = (catalogVersion, query, result)
        return result
    }

    var hasActiveRefinements: Bool {
        !searchText.isEmpty || filters.isActive
    }

    func clearAllFilters() {
        searchText = ""
        filters.clear()
    }

    func toggleSortDirection() {
        sortOrder = (sortOrder == .ascending) ? .descending : .ascending
    }

    /// Picks a sort field with its natural direction (e.g. Intelligence high
    /// first, Expiring Soon earliest first).
    func setSort(_ field: SortField) {
        sortField = field
        sortOrder = field.prefersDescending ? .descending : .ascending
    }

    // MARK: Export

    func exportFilteredModels(as format: ModelExportFormat) -> String {
        ModelExport.render(filteredModels, format: format, unit: PriceUnit.load())
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

    func removeFromCompare(_ id: String) {
        compareIDs.removeAll { $0 == id }
        compareLimitNotice = nil
    }

    /// Replaces the selection (deep links), de-duplicated and capped. With a
    /// loaded catalog, ids it doesn't contain are dropped before the cap so
    /// they neither count as selected nor crowd out real models.
    func setCompare(_ ids: [String]) {
        var seen = Set<String>()
        var unique = ids.filter { seen.insert($0).inserted }
        if !api.catalog.isEmpty {
            let known = Set(api.catalog.map(\.id))
            unique.removeAll { !known.contains($0) }
        }
        compareIDs = Array(unique.prefix(TestBatchSelection.maximumModels))
        compareLimitNotice = unique.count > compareIDs.count
            ? "You can compare up to \(TestBatchSelection.maximumModels) models." : nil
    }

    func clearCompare() {
        compareIDs = []
        compareLimitNotice = nil
    }

    /// Drops IDs that vanished from a loaded catalog (never prunes against an empty one).
    func pruneCompare() {
        guard !api.catalog.isEmpty else { return }
        let known = Set(api.catalog.map(\.id))
        guard compareIDs.contains(where: { !known.contains($0) }) else { return }
        compareIDs.removeAll { !known.contains($0) }
    }

    var compareModels: [ModelInfo] {
        let lookup = Dictionary(api.catalog.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return compareIDs.compactMap { lookup[$0] }
    }

    func loadFavorites() {
        favoriteIds = Set(db.getAllFavorites())
    }

    /// Stored favorites resolved against the loaded catalog. The sidebar
    /// badge and the Favorites list header both read this.
    var favoriteSummary: FavoriteSummary {
        FavoriteSummary.make(favoriteIds: favoriteIds, catalogIds: Set(api.catalog.map(\.id)))
    }

    var listHeaderText: String {
        BrowserListHeader.text(
            shown: filteredModels.count, showFavoritesOnly: showFavoritesOnly,
            favorites: favoriteSummary, refined: hasActiveRefinements
        )
    }

    /// True when the detail pane shows a model the current list doesn't
    /// contain (kept while a search or filter hides it).
    var selectionIsOutsideList: Bool {
        guard let selectedModel else { return false }
        return !filteredModels.contains { $0.id == selectedModel.id }
    }

    /// Called after a sidebar collection switch: never leave a model from
    /// another collection in detail.
    func reconcileSelectionForCollectionChange() {
        switch SelectionReconciliation.forCollectionChange(
            selectedID: selectedModel?.id, visibleIDs: filteredModels.map(\.id)
        ) {
        case .keep: break
        case .select(let id): select(id: id)
        case .clear: selectModel(nil)
        }
    }

    /// Last favorite/notes write failure, for tests and the toast.
    @Published private(set) var lastStorageError: String?

    func toggleFavorite(_ model: ModelInfo) {
        toggleFavorite(id: model.id)
    }

    func toggleFavorite(id: String) {
        let makeFavorite = !favoriteIds.contains(id)
        do {
            try db.setFavorite(id, makeFavorite)
            lastStorageError = nil
        } catch {
            lastStorageError = error.localizedDescription
            AppToasts.saveFailed("favorite", reason: error.localizedDescription)
        }
        loadFavorites()
    }

    /// Notes typed but not yet written (the detail view saves after a typing
    /// pause). Not published: it changes on every keystroke.
    private(set) var pendingNotes: (modelID: String, text: String)?

    /// Records the unsaved text for `modelID`; nil means nothing is unsaved.
    func stageNotes(_ text: String?, for modelID: String) {
        if let text {
            pendingNotes = (modelID, text)
        } else if pendingNotes?.modelID == modelID {
            pendingNotes = nil
        }
    }

    /// Writes staged notes now. Runs when the app is about to quit.
    func flushPendingNotes() {
        guard let pending = pendingNotes else { return }
        saveNotes(pending.text, for: pending.modelID)
    }

    /// Persists notes for any model, favorite or not.
    func saveNotes(_ notes: String, for modelId: String) {
        if pendingNotes?.modelID == modelId { pendingNotes = nil }
        do {
            try db.saveNotes(modelId, notes: notes)
            lastStorageError = nil
        } catch {
            lastStorageError = error.localizedDescription
            AppToasts.saveFailed("notes", reason: error.localizedDescription)
        }
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
        beginEndpointTransition(model, useCache: false)
    }

    /// Pause before a selection's `/endpoints` request, so holding ↓ through
    /// the list sends one request for the row it stops on, not one per row.
    /// Cached results (5 min) skip both the pause and the request.
    var endpointFetchDelay: Duration = .milliseconds(120)

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
    private func beginEndpointTransition(_ model: ModelInfo, useCache: Bool = true) {
        endpointTask?.cancel()
        selectedModelId = model.id
        selectedModel = model
        api.endpointsError = nil
        // A model seen in the last few minutes fills in at once, without the
        // empty "Providers (0)" flash.
        if useCache, let cached = api.cachedEndpoints(for: model.endpointsModelID) {
            endpointTask = nil
            endpoints = cached
            isLoadingEndpoints = false
            return
        }
        endpoints = []
        isLoadingEndpoints = true
        let delay = endpointFetchDelay
        endpointTask = Task { [weak self] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
            }
            guard let api = self?.api else { return }
            // The side-effect-free load: the shared error is written below,
            // behind the same guard as the endpoints, so a cancelled or late
            // request for A can never show its failure under B.
            let result = await api.loadEndpoints(for: model.endpointsModelID, useCache: useCache)
            guard let self, !Task.isCancelled, self.selectedModelId == model.id else { return }
            switch result {
            case .success(let list):
                self.endpoints = list
                api.endpointsError = nil
            case .failure(let error):
                self.endpoints = []
                api.endpointsError = error.message
            }
            self.isLoadingEndpoints = false
        }
    }

    /// Id from a deep link that arrived before the catalog loaded.
    private(set) var pendingSelectionID: String?

    /// Selects by id. Before the catalog loads the id is remembered and
    /// applied after the next refresh; returns false only for an id that a
    /// loaded catalog doesn't contain.
    @discardableResult
    func select(id: String) -> Bool {
        if let model = api.catalog.first(where: { $0.id == id }) {
            pendingSelectionID = nil
            selectModel(model)
            return true
        }
        guard api.catalog.isEmpty else { return false }
        pendingSelectionID = id
        return true
    }

    func refresh() async {
        await api.fetchModels()
        if let pending = pendingSelectionID {
            pendingSelectionID = nil
            select(id: pending)
        }
        loadFavorites()
        newThisWeekCount = NewModelCount.distinct(api.catalog, isNew: isNewThisWeek)
        // Refetch the selected model's endpoints explicitly; routing through
        // selectModel would be suppressed by the same-model equality guard.
        // ModelInfo equality is id-only, so take the refreshed value from the
        // catalog or the detail pane keeps the old price, context and expiry.
        if let current = selectedModel {
            beginEndpointTransition(api.catalog.first { $0.id == current.id } ?? current, useCache: false)
        }
        // Restored or deep-linked compare ids the catalog no longer has would
        // otherwise count as selected with no column and no row to remove them.
        pruneCompare()
    }

    /// Why `id` can't be opened in Chat or the Agent, or nil when it can
    /// (ids the catalog doesn't know are let through: it may not be loaded).
    func handoffBlockReason(_ destination: ModelHandoff.Destination, id: String) -> String? {
        guard let model = api.catalog.first(where: { $0.id == id }) else { return nil }
        return ModelHandoff.unavailableReason(destination, for: model)
    }

    /// A catalog older than this is refreshed when ORB becomes active again.
    static let staleCatalogInterval: TimeInterval = 3600

    /// Whether returning to the app should refresh the catalog in the
    /// background (never while a refresh is running or before the first).
    func catalogIsStale(now: Date = Date()) -> Bool {
        guard !api.isLoading, let last = api.lastRefresh else { return false }
        return now.timeIntervalSince(last) > Self.staleCatalogInterval
    }

    func isNewThisWeek(_ model: ModelInfo) -> Bool {
        guard let d = model.createdDate else { return false }
        return d > Date().addingTimeInterval(-7 * 86400)
    }

    /// "Alias of X →", palette and `orb://` model links: show `id` without
    /// touching the user's filters or search. Returns the section to show it
    /// in (the current one when it can contain the model), or nil when a
    /// loaded catalog has no such model. A model the filters hide stays in
    /// detail under the "Not in the current list" banner.
    func reveal(id: String, from current: SidebarSection) -> SidebarSection? {
        let model = api.catalog.first { $0.id == id }
        let target = BrowserReveal.section(
            current: current, isFavorite: favoriteIds.contains(id), isNew: model.map(isNewThisWeek) ?? false
        )
        return select(id: id) ? target : nil
    }
}

/// The New Models badge counts distinct models: `:batch` variants and
/// `:free` copies of a model listed in the same week are not extra models.
enum NewModelCount {
    static func distinct(_ models: [ModelInfo], isNew: (ModelInfo) -> Bool) -> Int {
        Set(models.filter { !$0.isBatchOnly && isNew($0) }.map { baseID($0.id) }).count
    }

    /// "vendor/model" for "vendor/model:free" (also ":batch", ":extended").
    static func baseID(_ id: String) -> String {
        guard let colon = id.lastIndex(of: ":"), id[..<colon].contains("/") else { return id }
        return String(id[..<colon])
    }
}

// MARK: - Deep links while locked

/// Keeps an `orb://` link that arrives while ORB is locked (the default
/// state at launch) so it can run right after unlock instead of being lost.
/// Only the newest link is kept, and it is handed out once.
struct LockedDeepLinkInbox: Equatable {
    private(set) var held: ShellAction?

    /// Returns the action to perform now, or nil when it was held for unlock.
    mutating func receive(_ action: ShellAction, isUnlocked: Bool) -> ShellAction? {
        guard !isUnlocked else {
            held = nil
            return action
        }
        held = action
        return nil
    }

    /// The held link, if any. Call when the app unlocks.
    mutating func takeAfterUnlock() -> ShellAction? {
        defer { held = nil }
        return held
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
    @StateObject private var agentService = ChatService(loadMode: .agent)
    @StateObject private var chatService = ChatService(loadMode: .chat)
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
    @FocusState private var listFocused: Bool
    @AppStorage(PriceUnit.defaultsKey) private var priceUnit: PriceUnit = .perMillion
    @ObservedObject private var appLock = AppLock.shared
    @ObservedObject private var approvalAttention = ApprovalAttention.shared
    @State private var startedPostUnlockWork = false
    @State private var showOnboarding = false
    @State private var showFilters = false
    @State private var linkInbox = LockedDeepLinkInbox()
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
                    onOpenSettings: {
                        // Security lives in General; without this the window
                        // reopens on whichever pane was used last.
                        SettingsPane.lockSettings.store()
                        openSettings()
                    }
                )
            } else {
                shellView
            }
        }
        .onChange(of: selectedSection, initial: true) { _, section in
            StudioNotifier.shared.currentSection = section.rawValue
            // Menus (⌘F's Find target) act on the visible section.
            shell.currentSection = section
        }
        .onChange(of: appLock.isUnlocked, initial: true) { _, unlocked in
            guard unlocked, !showOnboarding else { return }
            showOnboarding = OnboardingGate.shouldPresent(
                outcome: UserDefaultsOnboardingStore().outcome,
                reviewMode: Self.reviewMode,
                forced: OnboardingGate.isForced()
            )
        }
        // Never over the lock screen: a lock that engages mid-onboarding
        // hides the sheet, and it returns after unlock.
        .sheet(isPresented: Binding(
            get: { showOnboarding && appLock.isUnlocked },
            set: { if !$0, appLock.isUnlocked { showOnboarding = false } }
        )) {
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
                // A link opened while locked runs now, through the normal
                // request path, once the shell is back on screen.
                if let action = linkInbox.takeAfterUnlock() { shell.send(action) }
            }
        }
        .onOpenURL { url in
            guard let link = DeepLink.parse(url) else { return }
            if let action = linkInbox.receive(link.shellAction, isUnlocked: appLock.isUnlocked) {
                shell.send(action)
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
                // Search the collection on screen (Favorites stays Favorites).
                let target = BrowserFind.target(current: selectedSection)
                if target != selectedSection { select(target) }
                searchFocused = true
                focusManager.searchFocused = false
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Stale-while-revalidate: the old list stays up during the refresh.
            guard appLock.isUnlocked, vm.catalogIsStale() else { return }
            Task { await vm.refresh() }
        }
        .onChange(of: vm.selectedModel?.id, initial: true) { _, id in
            shell.focusedModelID = selectedSection.isBrowser ? id : nil
            shell.focusedModelIsFavorite = id.map(vm.favoriteIds.contains) ?? false
            shell.focusedModelIsComparing = id.map(vm.isComparing) ?? false
            shell.focusedModelCanChat = id.map { vm.handoffBlockReason(.chat, id: $0) == nil } ?? true
        }
        .onChange(of: vm.favoriteIds) { _, ids in
            shell.focusedModelIsFavorite = shell.focusedModelID.map(ids.contains) ?? false
        }
        .onChange(of: vm.compareIDs) { _, ids in
            shell.focusedModelIsComparing = shell.focusedModelID.map(ids.contains) ?? false
        }
        .onChange(of: selectedSection) { _, section in
            shell.focusedModelID = section.isBrowser ? vm.selectedModel?.id : nil
        }
        .onChange(of: shell.pending) { _, request in
            guard let request else { return }
            shell.pending = nil
            // Menu commands are ignored while locked; orb:// links are held
            // by `linkInbox` instead and replayed after unlock.
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
                // Only where the catalog is on screen; ⌘R still works anywhere.
                if selectedSection.isBrowser {
                    Button {
                        perform(.refreshModels)
                    } label: {
                        Label("Refresh Models", systemImage: "arrow.clockwise")
                    }
                    .help("Refresh the model catalog from OpenRouter (⌘R)")
                    .disabled(vm.api.isLoading)
                    .accessibilityLabel("Refresh models")
                }

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
            // Record the launch section, but keep the override in force until
            // the user picks a section: window-state restoration can rewrite
            // `storedSection` after this first appearance, which used to
            // silently discard `-orb.startSection` on every relaunch.
            if !launchOverrideApplied {
                storedSection = selectedSection.rawValue
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
        // Library is local and needs no key; FilesView disables remote upload without one.
        case .files: FilesView()
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
        let changed = vm.showFavoritesOnly != effects.showFavoritesOnly
            || vm.showNewThisWeek != effects.showNewThisWeek
        vm.showFavoritesOnly = effects.showFavoritesOnly
        vm.showNewThisWeek = effects.showNewThisWeek
        if changed, section.isBrowser { vm.reconcileSelectionForCollectionChange() }
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
            // Keeps filters, search and (when it can hold the model) the
            // current collection; see BrowserViewModel.reveal.
            if let target = vm.reveal(id: id, from: selectedSection) {
                if target != selectedSection { select(target) }
            } else {
                AppToasts.center.show("No model with id \(id)", kind: .warning, duration: 3)
            }
        case .compareModels(let ids):
            let eligible = CompareHandoff.batchIDs(from: ids, catalog: vm.api.models)
            CompareHandoff.shared.stage(eligible)
            select(.testSuite)
        case .chatWithModel(let id):
            // The Model menu and links can name a batch-only or image model;
            // say why instead of opening a chat that can only fail.
            if let reason = vm.handoffBlockReason(.chat, id: id) {
                AppToasts.center.show(reason, kind: .warning, duration: 4)
                return
            }
            select(.chat)
            _ = chatService.newConversation(modelId: id, mode: .chat)
        case .agentWithModel(let id):
            if let reason = vm.handoffBlockReason(.agent, id: id) {
                AppToasts.center.show(reason, kind: .warning, duration: 4)
                return
            }
            select(.agent)
            _ = agentService.newConversation(modelId: id, mode: .agent)
        case .openConversation(let id, let mode):
            let service = (mode == .chat) ? chatService : agentService
            select(mode == .chat ? .chat : .agent)
            if let conversation = service.conversations.first(where: { $0.id == id }) {
                service.selectConversation(conversation)
            }
        case .toggleFavorite(let id):
            vm.toggleFavorite(id: id)
        case .toggleCompare(let id):
            vm.toggleCompare(id)
        case .copyModelID(let id):
            AppToasts.copy(id, what: "Model ID")
        case .openOnOpenRouter(let id):
            if let url = ModelInfo.openRouterURL(for: id) { NSWorkspace.shared.open(url) }
        case .openCompare:
            if !selectedSection.isBrowser { select(.allModels) }
            activeSheet = .compare
        case .openCompareWith(let ids):
            vm.setCompare(ids)
            if !selectedSection.isBrowser { select(.allModels) }
            activeSheet = .compare
        case .exportModels(let format):
            ModelExportPanel.present(text: vm.exportFilteredModels(as: format), format: format)
        }
    }

    /// Mirrors ChatView/AgentView's own default-model resolution so ⌘N and
    /// the in-view New button create sessions with the same model.
    private func preferredModelId(for mode: PlaygroundMode) -> String {
        let stored = UserDefaults.standard.string(forKey: mode == .chat ? PlaygroundModelDefaults.chatKey : PlaygroundModelDefaults.agentKey) ?? ""
        let recents = ModelRecentsStore().recentIds()
        // The fallbacks use the browser selection only when it can run in
        // the mode (it may be a batch, image or embedding model).
        switch mode {
        case .chat:
            return PlaygroundModelDefaults.resolve(
                storedModelId: stored,
                availableModelIds: vm.api.models.map(\.id),
                fallbackModelId: PlaygroundModelDefaults.chatFallback(
                    models: vm.api.models, favoriteIds: vm.favoriteIds,
                    selectedModelId: vm.selectedModel?.id, recentIds: recents
                )
            )
        case .agent:
            return PlaygroundModelDefaults.resolve(
                storedModelId: stored,
                availableModelIds: vm.api.models.filter(\.supportsTools).map(\.id),
                fallbackModelId: PlaygroundModelDefaults.agentFallback(
                    models: vm.api.models, favoriteIds: vm.favoriteIds,
                    selectedModelId: vm.selectedModel?.id, recentIds: recents
                )
            )
        }
    }

    private var paletteIndex: PaletteIndex {
        let favorites = vm.api.catalog
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
        .accessibilityElement(children: .combine)
        .accessibilityLabel(section.title)
        .accessibilityValue(SidebarAccessibility.value(count: sidebarCount(section), section: section))
    }

    @ViewBuilder
    private func activityBadge(for section: SidebarSection) -> some View {
        if section == .agent {
            if approvalAttention.pendingCount(section: "Agent") > 0 {
                Image(systemName: "exclamationmark.shield.fill")
                    .foregroundStyle(ORBTheme.warning)
                    .help("The agent is waiting for your approval")
                    .accessibilityLabel("Waiting for your approval")
            } else {
                ChatActivityBadge(service: agentService, tint: .secondary)
            }
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
        case .allModels: return vm.listedCatalogCount
        case .favorites: return vm.favoriteSummary.available
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
            hasModels: !vm.api.catalog.isEmpty,
            error: vm.api.errorMessage ?? (vm.api.catalog.isEmpty ? nil : vm.api.lastRefreshError),
            resultCount: vm.filteredModels.count,
            hasRefinements: vm.hasActiveRefinements,
            lastUpdated: vm.api.lastRefresh
        )
    }

    private var searchBar: some View {
        BrowserSearchField(
            appliedText: vm.searchText,
            focus: $searchFocused,
            onDraftChange: { [vm] in vm.searchDraft = $0 },
            onClear: { [vm] in vm.searchText = "" },
            onKey: { key in handleSearchKey(key) }
        )
        .font(ORBFont.body)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.orbSurface(0.06), in: RoundedRectangle(cornerRadius: 9))
        .overlay { RoundedRectangle(cornerRadius: 9).stroke(.orbSurface(0.08), lineWidth: 0.5) }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    /// ↓ / Return / Esc in the search field. Returns whether it was handled.
    private func handleSearchKey(_ key: BrowserSearchKeys.Key) -> Bool {
        vm.commitSearchNow()
        let results = vm.filteredModels
        let selectionVisible = vm.selectedModel.map { selected in results.contains { $0.id == selected.id } } ?? false
        switch BrowserSearchKeys.action(
            for: key, hasQuery: !vm.searchText.isEmpty, resultCount: results.count, selectionVisible: selectionVisible
        ) {
        case .focusList(let selectFirst):
            if selectFirst, let first = results.first { vm.selectModel(first) }
            listFocused = true
            return true
        case .openFirst:
            if let first = results.first { vm.selectModel(first) }
            listFocused = true
            return true
        case .clear:
            vm.searchText = ""
            return true
        case .ignored:
            return false
        }
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
            Text(vm.listHeaderText)
                .font(ORBFont.footnote.weight(.medium))
                .foregroundStyle(.secondary)
            if vm.showFavoritesOnly, let note = vm.favoriteSummary.unavailableNote {
                // A menu, not a bare label: these favorites have no rows (they are not in the catalog),
                // so this is the only place the user can see which ones they are and tidy them up.
                Menu {
                    Section("Not in the current catalog") {
                        ForEach(vm.favoriteSummary.unavailableIDs, id: \.self) { id in
                            Menu(id) {
                                Button("Copy Model ID") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(id, forType: .string)
                                }
                                Button("Remove from Favorites", role: .destructive) { vm.toggleFavorite(id: id) }
                            }
                        }
                    }
                } label: {
                    Label(note, systemImage: "questionmark.circle")
                        .font(ORBFont.caption)
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(vm.favoriteSummary.unavailableHelp ?? "")
                .accessibilityLabel(vm.favoriteSummary.unavailableHelp ?? note)
            }
            Menu {
                ForEach(ModelExportFormat.allCases) { format in
                    Button("Export as \(format.title)…") { perform(.exportModels(format)) }
                }
            } label: {
                Image(systemName: "square.and.arrow.up").font(.caption)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(vm.filteredModels.isEmpty)
            .help("Export the models shown as CSV or JSON")
            .accessibilityLabel("Export model list")
            Spacer()
            // The cached catalog stays on screen while a refresh runs; this
            // spinner is the only sign of it. (Refresh itself is the toolbar
            // button and ⌘R.)
            if vm.api.isLoading {
                ProgressView()
                    .scaleEffect(0.6)
                    .help("Refreshing the catalog…")
                    .accessibilityLabel("Refreshing the catalog")
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
                    .orbFont(size: 36)
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
            let favorites = vm.favoriteIds
            let comparing = Set(vm.compareIDs)
            let anyComparing = !comparing.isEmpty
            let copied = vm.copiedModelId
            let selectedID = vm.selectedModel?.id
            let unit = priceUnit
            let actions = rowActions
            List(vm.filteredModels, selection: $vm.selectedModel) { model in
                ModelRowView(
                    model: model,
                    facts: vm.rowFacts(for: model, unit: unit),
                    isFavorite: favorites.contains(model.id),
                    isComparing: comparing.contains(model.id),
                    anyComparing: anyComparing,
                    isCopied: copied == model.id,
                    isSelected: selectedID == model.id,
                    actions: actions
                )
                .equatable()
                .tag(model)
            }
            .listStyle(.inset)
            .focused($listFocused)
            .accessibilityLabel("Models")
            .onChange(of: vm.selectedModel) { _, newValue in
                vm.selectModel(newValue)
            }
        }
    }

    private var rowActions: ModelRowActions {
        ModelRowActions(
            toggleFavorite: { [vm] in vm.toggleFavorite($0) },
            toggleCompare: { [vm] in vm.toggleCompare($0.id) },
            copyID: { [vm] in vm.copyModelId($0) },
            chat: { [shell] in shell.send(.chatWithModel($0.id)) },
            agent: { [shell] in shell.send(.agentWithModel($0.id)) }
        )
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
                        .orbFont(size: 34, weight: .light)
                        .foregroundStyle(ORBTheme.accent)
                }
                Text("Select a model")
                    .font(.title2.weight(.semibold))
                Text(vm.api.catalog.isEmpty
                     ? "Loading the OpenRouter catalog…"
                     : "\(vm.listedCatalogCount) models from \(max(vm.providerOptions.count - 1, 0)) model authors")
                    .orbFont(size: 13)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Search field

/// The browser search field. It owns the text being typed, so keystrokes
/// re-render only this view; the view model debounces the text into the
/// applied query. ↓ moves into the results, Return opens the top hit, Esc
/// clears the query.
struct BrowserSearchField: View {
    /// The query the list currently applies; external changes (Clear
    /// filters, a deep link) are copied into the field.
    let appliedText: String
    var focus: FocusState<Bool>.Binding
    let onDraftChange: (String) -> Void
    let onClear: () -> Void
    /// Returns whether the key was handled.
    let onKey: (BrowserSearchKeys.Key) -> Bool
    @State private var draft = ""

    var body: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Search models...", text: $draft)
                .textFieldStyle(.plain)
                .focused(focus)
                .accessibilityLabel("Search models")
                .accessibilityHint("Press Down Arrow to move into the results")
                .onSubmit { _ = onKey(.submit) }
                .onKeyPress(.downArrow) { onKey(.down) ? .handled : .ignored }
                .onKeyPress(.escape) { onKey(.escape) ? .handled : .ignored }
            if !draft.isEmpty {
                Button {
                    draft = ""
                    onClear()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
                .accessibilityLabel("Clear search")
            }
        }
        .onAppear { draft = appliedText }
        .onChange(of: draft) { _, value in onDraftChange(value) }
        .onChange(of: appliedText) { _, value in
            // The debounced commit equals the draft; anything else came from
            // outside the field.
            if value != draft { draft = value }
        }
    }
}
