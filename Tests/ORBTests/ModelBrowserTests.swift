import Testing
import Foundation
@testable import ORB

private func browserModel(
    id: String,
    name: String = "Model",
    inputs: [String] = ["text"],
    outputs: [String] = ["text"],
    params: [String] = [],
    context: Int? = 128_000,
    prompt: String? = "0.000001",
    completion: String? = "0.000002",
    created: Double? = nil,
    description: String? = nil
) -> ModelInfo {
    ModelInfo(
        id: id, canonicalSlug: nil, huggingFaceId: nil, name: name, created: created,
        description: description, contextLength: context,
        architecture: Architecture(
            modality: "x", inputModalities: inputs, outputModalities: outputs,
            tokenizer: nil, instructType: nil
        ),
        pricing: Pricing(prompt: prompt, completion: completion, inputCacheRead: nil),
        topProvider: nil, supportedParameters: params, reasoning: nil, knowledgeCutoff: nil,
        expirationDate: nil, supportedVoices: nil, benchmarks: nil, perRequestLimits: nil,
        defaultParameters: nil
    )
}

private func freshDefaults() -> UserDefaults {
    let name = "orb.tests.browser.\(UUID().uuidString)"
    let d = UserDefaults(suiteName: name)!
    d.removePersistentDomain(forName: name)
    return d
}

// MARK: - Compound filter logic

@Suite("Phase 4 browser: compound filters")
struct BrowserFilterStateTests {
    private let catalog = [
        browserModel(id: "openai/gpt", params: ["tools", "reasoning"], context: 128_000, prompt: "0.000005"),
        browserModel(id: "openai/mini", params: ["tools"], context: 32_000, prompt: "0.0000001"),
        browserModel(id: "anthropic/claude", inputs: ["text", "image"], params: ["tools"], context: 200_000, prompt: "0.000003"),
        browserModel(id: "meta/free", context: 8_000, prompt: "0", completion: "0"),
        browserModel(id: "x/unknown", context: nil, prompt: nil, completion: nil),
    ]

    private func ids(_ f: BrowserFilterState) -> [String] { catalog.filter(f.matches).map(\.id) }

    @Test("Default state matches everything and is inactive")
    func empty() {
        let f = BrowserFilterState()
        #expect(!f.isActive)
        #expect(ids(f).count == catalog.count)
    }

    @Test("Capabilities combine with AND")
    func capabilitiesAnd() {
        var f = BrowserFilterState()
        f.capabilities = [.tools]
        #expect(Set(ids(f)) == ["openai/gpt", "openai/mini", "anthropic/claude"])
        f.capabilities = [.tools, .reasoning]
        #expect(ids(f) == ["openai/gpt"])
        f.capabilities = [.tools, .imageInput]
        #expect(ids(f) == ["anthropic/claude"])
    }

    @Test("Providers combine with OR, and AND with other facets")
    func providersOr() {
        var f = BrowserFilterState()
        f.providers = ["openai", "meta"]
        #expect(Set(ids(f)) == ["openai/gpt", "openai/mini", "meta/free"])
        f.capabilities = [.reasoning]
        #expect(ids(f) == ["openai/gpt"])
    }

    @Test("Max input price keeps free models, drops unknown prices")
    func price() {
        var f = BrowserFilterState()
        f.maxInputPrice = 1.0
        #expect(Set(ids(f)) == ["openai/mini", "meta/free"])
        f.maxInputPrice = 3.0
        #expect(Set(ids(f)) == ["openai/mini", "meta/free", "anthropic/claude"])
    }

    @Test("Min context is inclusive and drops unknown context")
    func context() {
        var f = BrowserFilterState()
        f.minContext = 128_000
        #expect(Set(ids(f)) == ["openai/gpt", "anthropic/claude"])
    }

    @Test("Free capability matches free models only")
    func free() {
        var f = BrowserFilterState()
        f.capabilities = [.free]
        #expect(ids(f) == ["meta/free"])
    }

    @Test("Compound: all facets together")
    func compound() {
        let f = BrowserFilterState(
            capabilities: [.tools], maxInputPrice: 4, minContext: 100_000, providers: ["openai", "anthropic"]
        )
        #expect(ids(f) == ["anthropic/claude"])
    }

    @Test("Chips list each active facet, in a stable order, with titles")
    func chips() {
        let f = BrowserFilterState(capabilities: [.tools, .reasoning], maxInputPrice: 2, minContext: 32_000, providers: ["openai"])
        let titles = f.chips.map(\.title)
        #expect(titles.count == 5)
        #expect(titles == f.chips.map(\.title))
        #expect(titles.contains("Tools"))
        #expect(titles.contains("Reasoning"))
        #expect(titles.contains("openai"))
        #expect(titles.contains { $0.contains("$2") })
        #expect(titles.contains { $0.contains("32K") })
    }

    @Test("Removing a chip clears only that facet; clear() resets all")
    func removeAndClear() {
        var f = BrowserFilterState(capabilities: [.tools, .reasoning], maxInputPrice: 2, minContext: 32_000, providers: ["openai", "meta"])
        let toolsChip = f.chips.first { $0.title == "Tools" }!
        f.remove(toolsChip)
        #expect(f.capabilities == [.reasoning])
        f.remove(f.chips.first { $0.title == "openai" }!)
        #expect(f.providers == ["meta"])
        f.remove(f.chips.first { $0.title.contains("$") }!)
        #expect(f.maxInputPrice == nil)
        f.remove(f.chips.first { $0.title.contains("K") }!)
        #expect(f.minContext == nil)
        f.clear()
        #expect(!f.isActive)
        #expect(f.chips.isEmpty)
    }

    @Test("Codable round trip preserves every facet")
    func codable() throws {
        let f = BrowserFilterState(capabilities: [.audio, .free], maxInputPrice: 0.5, minContext: 1_000_000, providers: ["a", "b"])
        let data = try JSONEncoder().encode(f)
        #expect(try JSONDecoder().decode(BrowserFilterState.self, from: data) == f)
    }

    @Test("Unknown stored capability names are dropped, not fatal")
    func tolerantDecode() throws {
        let json = #"{"capabilities":["tools","teleport"],"providers":["x"]}"#
        let f = try JSONDecoder().decode(BrowserFilterState.self, from: Data(json.utf8))
        #expect(f.capabilities == [.tools])
        #expect(f.providers == ["x"])
    }
}

// MARK: - View-model integration and persistence

@MainActor
@Suite("Phase 4 browser: view model")
struct BrowserViewModelFilterTests {
    private func makeVM(defaults: UserDefaults? = nil, models: [ModelInfo] = []) -> BrowserViewModel {
        let vm = BrowserViewModel(db: DatabaseManager(), defaults: defaults)
        vm.api.models = models
        return vm
    }

    @Test("Filters stack with search and provider filter")
    func stacking() {
        let vm = makeVM(models: [
            browserModel(id: "openai/a", name: "Alpha", params: ["tools"]),
            browserModel(id: "openai/b", name: "Beta"),
            browserModel(id: "meta/a", name: "Alpha", params: ["tools"]),
        ])
        vm.filters.capabilities = [.tools]
        #expect(vm.filteredModels.count == 2)
        vm.searchText = "alpha"
        vm.filters.providers = ["meta"]
        #expect(vm.filteredModels.map(\.id) == ["meta/a"])
    }

    @Test("Filters and sort persist across view-model instances")
    func persistence() {
        let defaults = freshDefaults()
        let a = makeVM(defaults: defaults)
        a.filters = BrowserFilterState(capabilities: [.reasoning], maxInputPrice: 2, minContext: 64_000, providers: ["openai"])
        a.sortField = .promptCost
        a.sortOrder = .ascending
        let b = makeVM(defaults: defaults)
        #expect(b.filters == a.filters)
        #expect(b.sortField == .promptCost)
        #expect(b.sortOrder == .ascending)
    }

    @Test("Default view model never reads or writes persisted preferences")
    func isolation() {
        let vm = makeVM()
        vm.filters.capabilities = [.tools]
        let other = makeVM()
        #expect(!other.filters.isActive)
    }

    @Test("Corrupt persisted data falls back to defaults")
    func corrupt() {
        let defaults = freshDefaults()
        defaults.set(Data("nope".utf8), forKey: BrowserPrefsStore.key)
        let vm = makeVM(defaults: defaults)
        #expect(!vm.filters.isActive)
        #expect(vm.sortField == .created)
    }

    @Test("Clear all resets facets and the search text")
    func clearAll() {
        let vm = makeVM(models: [browserModel(id: "a/x")])
        vm.filters.capabilities = [.tools]
        vm.searchText = "zzz"
        vm.filters.providers = ["a"]
        vm.clearAllFilters()
        #expect(!vm.filters.isActive)
        #expect(vm.searchText.isEmpty)
        #expect(!vm.hasActiveRefinements)
    }

    @Test("Has-active-refinements covers search and facets")
    func refinements() {
        let vm = makeVM()
        #expect(!vm.hasActiveRefinements)
        vm.searchText = "x"
        #expect(vm.hasActiveRefinements)
        vm.searchText = ""
        vm.filters.minContext = 1
        #expect(vm.hasActiveRefinements)
    }

    @Test("Sort field and direction are independent controls")
    func sortSplit() {
        let vm = makeVM(models: [
            browserModel(id: "a/small", name: "A", context: 8_000),
            browserModel(id: "a/big", name: "B", context: 200_000),
        ])
        vm.sortField = .contextLength
        vm.sortOrder = .descending
        #expect(vm.filteredModels.map(\.id) == ["a/big", "a/small"])
        vm.toggleSortDirection()
        #expect(vm.sortOrder == .ascending)
        #expect(vm.sortField == .contextLength)
        #expect(vm.filteredModels.map(\.id) == ["a/small", "a/big"])
    }

    @Test("Provider options for the popover come from the catalog, sorted")
    func providers() {
        let vm = makeVM(models: [browserModel(id: "zed/a"), browserModel(id: "alpha/a"), browserModel(id: "alpha/b")])
        #expect(vm.providerOptions == ["All Providers", "alpha", "zed"])
    }

    @Test("Pinned favourites sort to the top without breaking the chosen order")
    func pinnedFavourites() {
        let vm = makeVM(models: [
            browserModel(id: "a/one", name: "One"),
            browserModel(id: "a/two", name: "Two"),
            browserModel(id: "a/three", name: "Three"),
        ])
        vm.sortField = .name
        vm.sortOrder = .ascending
        vm.favoriteIds = ["a/two"]
        vm.pinFavorites = true
        #expect(vm.filteredModels.map(\.id) == ["a/two", "a/one", "a/three"])
        vm.pinFavorites = false
        #expect(vm.filteredModels.map(\.id) == ["a/one", "a/three", "a/two"])
    }
}

// MARK: - Compare selection and panel data

@MainActor
@Suite("Phase 4 browser: compare")
struct BrowserCompareTests {
    private func vm() -> BrowserViewModel { BrowserViewModel(db: DatabaseManager(), defaults: nil) }

    @Test("Toggle adds and removes; selection keeps pick order")
    func toggle() {
        let v = vm()
        #expect(v.toggleCompare("a/1"))
        #expect(v.toggleCompare("a/2"))
        #expect(v.compareIDs == ["a/1", "a/2"])
        #expect(v.toggleCompare("a/1") == false)
        #expect(v.compareIDs == ["a/2"])
        #expect(v.isComparing("a/2"))
    }

    @Test("Selection is capped at the Test Suite batch limit")
    func cap() {
        let v = vm()
        for i in 0..<TestBatchSelection.maximumModels { _ = v.toggleCompare("m/\(i)") }
        #expect(v.compareIDs.count == TestBatchSelection.maximumModels)
        #expect(v.canAddToCompare == false)
        let added = v.toggleCompare("m/extra")
        #expect(added == false)
        #expect(!v.compareIDs.contains("m/extra"))
        #expect(v.compareLimitNotice != nil)
    }

    @Test("Compare models resolve from the catalog and drop vanished IDs")
    func resolve() {
        let v = vm()
        v.api.models = [browserModel(id: "a/1"), browserModel(id: "a/2")]
        _ = v.toggleCompare("a/2"); _ = v.toggleCompare("gone/9"); _ = v.toggleCompare("a/1")
        #expect(v.compareModels.map(\.id) == ["a/2", "a/1"])
        v.pruneCompare()
        #expect(v.compareIDs == ["a/2", "a/1"])
    }

    @Test("Clear compare empties the selection and the notice")
    func clear() {
        let v = vm()
        _ = v.toggleCompare("a/1")
        v.clearCompare()
        #expect(v.compareIDs.isEmpty)
        #expect(v.compareLimitNotice == nil)
    }

    @Test("Comparison column formats price, context, modalities and endpoint stats")
    func column() {
        let m = browserModel(id: "a/m", name: "M", inputs: ["text", "image"], outputs: ["text"], context: 200_000, prompt: "0.000003", completion: "0.000015")
        let c = ComparisonColumn.make(model: m, endpoints: nil)
        #expect(c.id == "a/m")
        #expect(c.inputPrice == "$3 / 1M")
        #expect(c.outputPrice == "$15 / 1M")
        #expect(c.context == "200K")
        #expect(c.inputModalities == "text, image")
        #expect(c.outputModalities == "text")
        #expect(c.latency == "—")
        #expect(c.throughput == "—")
    }

    @Test("Free and unpriced models are labelled distinctly")
    func prices() {
        let free = ComparisonColumn.make(model: browserModel(id: "a/f", prompt: "0", completion: "0"), endpoints: nil)
        #expect(free.inputPrice == "Free")
        let variable = ComparisonColumn.make(model: browserModel(id: "a/v", context: nil, prompt: nil, completion: nil), endpoints: nil)
        #expect(variable.inputPrice == "Variable")
        #expect(variable.context == "N/A")
    }

    @Test("Best-of highlights: cheapest input, largest context, ignoring unknowns")
    func best() {
        let cols = [
            ComparisonColumn.make(model: browserModel(id: "a/1", context: 8_000, prompt: "0.000005"), endpoints: nil),
            ComparisonColumn.make(model: browserModel(id: "a/2", context: 200_000, prompt: "0.000001"), endpoints: nil),
            ComparisonColumn.make(model: browserModel(id: "a/3", context: nil, prompt: nil), endpoints: nil),
        ]
        let best = ComparisonColumn.highlights(cols)
        #expect(best.cheapestInputID == "a/2")
        #expect(best.largestContextID == "a/2")
        #expect(ComparisonColumn.highlights([cols[2]]).cheapestInputID == nil)
        #expect(ComparisonColumn.highlights([cols[0]]).cheapestInputID == nil, "a single column has nothing to beat")
    }

    @Test("Endpoint latency and throughput use the best available endpoint")
    func endpointStats() throws {
        let json = """
        [{"provider_name":"A","latency_last_30m":900,"throughput_last_30m":40,"status":0},
         {"provider_name":"B","latency_last_30m":400,"throughput_last_30m":85,"status":0},
         {"provider_name":"C","status":0}]
        """
        let eps = try JSONDecoder().decode([ModelEndpoint].self, from: Data(json.utf8))
        let c = ComparisonColumn.make(model: browserModel(id: "a/m"), endpoints: eps)
        #expect(c.latency == "400 ms")
        #expect(c.throughput == "85 tok/s")
    }

    @Test("Hand-off to Test Suite keeps only eligible text models, capped, de-duplicated")
    func handoff() {
        let catalog = [
            browserModel(id: "a/1"), browserModel(id: "a/2"),
            browserModel(id: "img/x", outputs: ["image"]),
        ]
        let ids = CompareHandoff.batchIDs(from: ["a/1", "img/x", "a/1", "missing/z", "a/2"], catalog: catalog)
        #expect(ids == ["a/1", "a/2"])
    }

    @Test("Hand-off box is single-use")
    func handoffBox() {
        let box = CompareHandoff()
        #expect(box.take() == nil)
        box.stage(["a/1"])
        #expect(box.take() == ["a/1"])
        #expect(box.take() == nil)
        box.stage([])
        #expect(box.take() == nil, "staging nothing stages nothing")
    }

    @Test("Shell action for compare targets the Test Suite; chat/agent hand-offs target their sections")
    func shellActions() {
        #expect(ShellAction.compareModels(["a/1"]).targetSection == .testSuite)
        #expect(ShellAction.chatWithModel("a/1").targetSection == .chat)
        #expect(ShellAction.agentWithModel("a/1").targetSection == .agent)
    }
}

// MARK: - Presentation state

@Suite("Phase 4 browser: list state")
struct BrowserListStateTests {
    @Test("Loading with no models shows skeleton rows")
    func loading() {
        #expect(BrowserListState.resolve(isLoading: true, hasModels: false, error: nil, resultCount: 0, hasRefinements: false, lastUpdated: nil) == .skeleton)
    }

    @Test("Error with no cached models is a hard error; with cache it is an offline banner")
    func errorVsOffline() {
        let when = Date(timeIntervalSince1970: 1_000)
        #expect(BrowserListState.resolve(isLoading: false, hasModels: false, error: "boom", resultCount: 0, hasRefinements: false, lastUpdated: nil) == .error("boom"))
        #expect(BrowserListState.resolve(isLoading: false, hasModels: true, error: "boom", resultCount: 5, hasRefinements: false, lastUpdated: when) == .list(offlineSince: when))
    }

    @Test("Refreshing with cached models keeps showing the list")
    func refreshKeepsList() {
        #expect(BrowserListState.resolve(isLoading: true, hasModels: true, error: nil, resultCount: 3, hasRefinements: false, lastUpdated: nil) == .list(offlineSince: nil))
    }

    @Test("Zero results with refinements is no-results; without is empty catalog")
    func noResults() {
        #expect(BrowserListState.resolve(isLoading: false, hasModels: true, error: nil, resultCount: 0, hasRefinements: true, lastUpdated: nil) == .noResults)
        #expect(BrowserListState.resolve(isLoading: false, hasModels: true, error: nil, resultCount: 0, hasRefinements: false, lastUpdated: nil) == .emptySection)
    }

    @Test("Offline banner text names the cache time and is hidden when unknown")
    func bannerText() {
        let text = BrowserListState.offlineBannerText(since: Date(timeIntervalSince1970: 0))
        #expect(text.hasPrefix("Offline: showing cached models from"))
        #expect(BrowserListState.offlineBannerText(since: nil) == "Offline: showing cached models")
    }

    @Test("No-results suggestions prefer removing the narrowest active facet and never repeat")
    func suggestions() {
        var f = BrowserFilterState(capabilities: [.reasoning], maxInputPrice: 1, minContext: nil, providers: [])
        let s = NoResultsSuggestions.make(search: "gpt", filters: f)
        #expect(!s.isEmpty)
        #expect(Set(s.map(\.id)).count == s.count)
        #expect(s.contains { $0.kind == .clearSearch })
        #expect(s.contains { $0.kind == .removeMaxPrice })
        #expect(s.contains { $0.kind == .clearAll })
        f.clear()
        #expect(NoResultsSuggestions.make(search: "", filters: f).isEmpty)
    }
}

@Suite("Phase 4 browser: row facts")
struct BrowserRowFactsTests {
    @Test("Row facts: context, price in/out, capability icons with names")
    func facts() {
        let m = browserModel(id: "openai/gpt", inputs: ["text", "image"], params: ["tools", "reasoning"], context: 1_000_000, prompt: "0.000002", completion: "0.00001", description: "A model.\nSecond line.")
        let r = ModelRowFacts.make(m)
        #expect(r.context == "1.0M")
        #expect(r.price == "$2 in · $10 out")
        #expect(r.oneLiner == "A model.")
        #expect(r.capabilities.map(\.name).contains("Tools"))
        #expect(r.capabilities.allSatisfy { !$0.icon.isEmpty })
        #expect(r.avatarLetter == "O")
    }

    @Test("Free and missing price wording")
    func priceWording() {
        #expect(ModelRowFacts.make(browserModel(id: "a/f", prompt: "0", completion: "0")).price == "Free")
        #expect(ModelRowFacts.make(browserModel(id: "a/v", prompt: nil, completion: nil)).price == "Variable price")
    }

    @Test("Compact price fits narrow rows: input/output without words")
    func compactPrice() {
        let m = browserModel(id: "openai/gpt", prompt: "0.000002", completion: "0.00001")
        #expect(ModelRowFacts.make(m).compactPrice == "$2/$10")
        #expect(ModelRowFacts.make(browserModel(id: "a/f", prompt: "0", completion: "0")).compactPrice == "Free")
        #expect(ModelRowFacts.make(browserModel(id: "a/v", prompt: nil, completion: nil)).compactPrice == "Varies")
    }

    @Test("Unofficial providers drop the tilde for the avatar letter")
    func avatar() {
        #expect(ModelRowFacts.make(browserModel(id: "~anthropic/x")).avatarLetter == "A")
    }

    @Test("Capability list is shared by the filter and the row")
    func sharedCapabilities() {
        let m = browserModel(id: "a/x", params: ["tools"])
        #expect(ModelCapability.tools.matches(m))
        #expect(!ModelCapability.reasoning.matches(m))
        #expect(ModelRowFacts.make(m).capabilities.map(\.name) == ["Tools"])
    }

    @Test("Every capability has a distinct title and icon")
    func capabilityMetadata() {
        let titles = ModelCapability.allCases.map(\.title)
        let icons = ModelCapability.allCases.map(\.icon)
        #expect(Set(titles).count == titles.count)
        #expect(Set(icons).count == icons.count)
    }
}

// MARK: - Offline state from the real APIService

@MainActor
@Suite("Phase 4 browser: offline fallback signal")
struct BrowserOfflineSignalTests {
    private func modelsJSON() -> Data {
        Data(#"{"data":[{"id":"a/x","name":"X"}]}"#.utf8)
    }

    @Test("A failed refresh with cached models sets lastRefreshError but not errorMessage")
    func offlineWithCache() async throws {
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("orb-offline-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: cache) }
        try modelsJSON().write(to: cache)
        // Age the cache so the loader is actually consulted.
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: cache.path)
        let api = APIService(cacheURL: cache) { _ in throw URLError(.notConnectedToInternet) }
        await api.fetchModels()
        #expect(api.models.count == 1)
        #expect(api.errorMessage == nil)
        #expect(api.lastRefreshError != nil)
        let state = BrowserListState.resolve(
            isLoading: false, hasModels: true, error: api.lastRefreshError,
            resultCount: 1, hasRefinements: false, lastUpdated: api.lastRefresh
        )
        if case .list(let since) = state { #expect(since != nil) } else { Issue.record("expected list") }
    }

    @Test("A successful refresh clears the offline signal")
    func recovers() async throws {
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("orb-offline-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: cache) }
        let data = modelsJSON()
        var fail = true
        let api = APIService(cacheURL: cache) { url in
            if fail { throw URLError(.notConnectedToInternet) }
            return (data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        try data.write(to: cache)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: cache.path)
        await api.fetchModels()
        #expect(api.lastRefreshError != nil)
        fail = false
        await api.fetchModels()
        #expect(api.lastRefreshError == nil)
    }
}
