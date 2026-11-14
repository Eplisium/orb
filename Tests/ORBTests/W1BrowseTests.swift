import Foundation
import Testing
@testable import ORB

// MARK: - Fixtures (file-scope names prefixed W1Browse to stay unique)

private func w1BrowseFixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

/// Seven live catalog entries (fetched from `/models?output_modalities=all`):
/// gpt-4o, gpt-4o-mini, gemini-2.5-flash, relace-apply-3 (description
/// mentions GPT-4o), a `:batch` variant, an embedding and an image model.
private func w1BrowseCatalog() throws -> [ModelInfo] {
    try JSONDecoder().decode(OpenRouterResponse.self, from: w1BrowseFixture("w1_browse_catalog")).data
}

private func w1BrowseModel(
    _ id: String, name: String? = nil, description: String? = nil, outputs: [String] = ["text"],
    params: [String] = [], routes: [String]? = nil, created: Double? = nil
) -> ModelInfo {
    ModelInfo(
        id: id, canonicalSlug: nil, huggingFaceId: nil, name: name ?? id, created: created,
        description: description, contextLength: 128_000,
        architecture: Architecture(
            modality: nil, inputModalities: ["text"], outputModalities: outputs, tokenizer: nil, instructType: nil
        ),
        pricing: Pricing(prompt: "0.000001", completion: "0.000002", inputCacheRead: nil),
        topProvider: nil, supportedParameters: params, reasoning: nil, knowledgeCutoff: nil,
        expirationDate: nil, supportedVoices: nil, benchmarks: nil, perRequestLimits: nil, defaultParameters: nil,
        apiEndpoints: routes.map(LossyStringList.init)
    )
}

private func w1BrowseTempURL() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("w1-browse-\(UUID().uuidString).json")
}

private func w1BrowseOK(_ url: URL, _ data: Data) -> (Data, URLResponse) {
    (data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
}

/// Counts requests per URL and answers every endpoints request at once.
final class W1BrowseCountingLoader: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    var catalog = Data(#"{"data":[]}"#.utf8)

    func count(containing key: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return urls.filter { $0.absoluteString.contains(key) }.count
    }

    func handle(_ url: URL) -> (Data, URLResponse) {
        lock.lock(); urls.append(url); lock.unlock()
        if url == APIService.catalogURL { return w1BrowseOK(url, catalog) }
        let body = #"{"data":{"id":"x","name":"X","endpoints":[{"provider_name":"P","pricing":{"prompt":"0.1","completion":"0.2"}}]}}"#
        return w1BrowseOK(url, Data(body.utf8))
    }
}

@MainActor
private func w1BrowseWait(timeout: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

@MainActor
private func w1BrowseVM(_ models: [ModelInfo]) -> BrowserViewModel {
    let api = APIService(cacheURL: w1BrowseTempURL()) { url in
        (Data(), HTTPURLResponse(url: url, statusCode: 500, httpVersion: nil, headerFields: nil)!)
    }
    api.catalog = models
    return BrowserViewModel(api: api, db: DatabaseManager())
}

// MARK: - BROWSE-1 latency / throughput shapes

@Suite("W1 browse: endpoint percentile stats")
struct W1BrowsePercentileTests {
    @Test("Object-shaped percentiles decode; p50 is shown")
    func objectShape() throws {
        let json = #"""
        {"data":{"id":"openai/gpt-4o","name":"GPT-4o","endpoints":[
          {"provider_name":"OpenAI","status":0,
           "latency_last_30m":{"p50":25.5,"p75":31,"p90":48,"p99":120},
           "throughput_last_30m":{"p50":88.2,"p75":80,"p90":70,"p99":40}}]}}
        """#
        let response = try JSONDecoder().decode(EndpointResponse.self, from: Data(json.utf8))
        let ep = try #require(response.data.endpoints.first)
        #expect(ep.latencyLast30m?.p50 == 25.5)
        #expect(ep.latencyLast30m?.p99 == 120)
        #expect(EndpointPerformance.latencyText(ep.latencyLast30m) == "26 ms")
        #expect(EndpointPerformance.throughputText(ep.throughputLast30m) == "88 tok/s")
        #expect(EndpointPerformance.help(ep.latencyLast30m, unit: "ms", what: "Latency").contains("p90 48"))
    }

    @Test("The legacy bare-number shape still decodes as the median")
    func legacyNumber() throws {
        let json = #"[{"provider_name":"A","latency_last_30m":900,"throughput_last_30m":40}]"#
        let eps = try JSONDecoder().decode([ModelEndpoint].self, from: Data(json.utf8))
        #expect(eps[0].latencyLast30m?.p50 == 900)
        #expect(eps[0].throughputLast30m?.typical == 40)
    }

    @Test("An unexpected shape becomes nil instead of failing the whole response")
    func unknownShapeIsLenient() throws {
        let json = #"""
        {"data":{"id":"m","name":"M","endpoints":[
          {"provider_name":"Odd","latency_last_30m":"fast","throughput_last_30m":[1,2],
           "status":"ok","context_length":"lots","uptime_last_1d":"99.5","pricing":{"prompt":"0.1","completion":"0.2"}},
          {"provider_name":"Normal","latency_last_30m":null,"throughput_last_30m":null,"status":0}]}}
        """#
        let response = try JSONDecoder().decode(EndpointResponse.self, from: Data(json.utf8))
        #expect(response.data.endpoints.count == 2)
        let odd = response.data.endpoints[0]
        #expect(odd.providerName == "Odd")
        #expect(odd.latencyLast30m == nil)
        #expect(odd.throughputLast30m == nil)
        #expect(odd.status == nil)
        #expect(odd.contextLength == nil)
        #expect(odd.uptimeLast1d == 99.5)
        #expect(odd.pricing?.prompt == "0.1")
    }

    @Test("Anonymous (null) stats are reported as unavailable, with an explanation")
    func anonymousNull() throws {
        let response = try JSONDecoder().decode(EndpointResponse.self, from: w1BrowseFixture("endpoints_two_deepinfra"))
        #expect(EndpointPerformance.hasStats(response.data.endpoints) == false)
        #expect(EndpointPerformance.latencyText(nil) == nil)
        #expect(EndpointPerformance.help(nil, unit: "ms", what: "Latency") == EndpointPerformance.unavailableHelp)
        #expect(EndpointPerformance.unavailableHelp.contains("signed-in"))
    }

    @Test("The endpoints fixture uses the live percentile shape")
    func fixtureShape() throws {
        let response = try JSONDecoder().decode(EndpointResponse.self, from: w1BrowseFixture("endpoints_response"))
        #expect(response.data.endpoints[0].latencyLast30m == PercentileStats(p50: 1200, p75: 1400, p90: 1800, p99: 2600))
        #expect(response.data.endpoints[1].latencyLast30m == nil)
        #expect(EndpointPerformance.hasStats(response.data.endpoints))
    }

    @Test("Compare uses the best median across providers")
    func compareMedian() throws {
        let eps = [
            ModelEndpoint(name: nil, modelId: nil, providerName: "A", contextLength: nil, maxCompletionTokens: nil,
                          pricing: nil, quantization: nil, latencyLast30m: PercentileStats(p50: 900, p99: 2000),
                          throughputLast30m: PercentileStats(p50: 40), uptimeLast5m: nil, uptimeLast30m: nil,
                          uptimeLast1d: nil, supportsImplicitCaching: nil, status: 0),
            ModelEndpoint(name: nil, modelId: nil, providerName: "B", contextLength: nil, maxCompletionTokens: nil,
                          pricing: nil, quantization: nil, latencyLast30m: PercentileStats(p50: 400.4),
                          throughputLast30m: PercentileStats(p50: 85), uptimeLast5m: nil, uptimeLast30m: nil,
                          uptimeLast1d: nil, supportsImplicitCaching: nil, status: 0),
        ]
        let column = ComparisonColumn.make(model: w1BrowseModel("a/m"), endpoints: eps)
        #expect(column.latency == "400 ms")
        #expect(column.throughput == "85 tok/s")
    }
}

// MARK: - BROWSE-2 / BROWSE-4 full catalog, chat subset, batch variants

@Suite("W1 browse: full catalog and chat-capable subset")
@MainActor
struct W1BrowseCatalogTests {
    @Test("The catalog request asks for every output modality")
    func catalogURL() {
        let query = URLComponents(url: APIService.catalogURL, resolvingAgainstBaseURL: false)?.queryItems
        #expect(query?.contains(URLQueryItem(name: "output_modalities", value: "all")) == true)
        #expect(APIService.requestTimeout <= 15)
    }

    @Test("Live routes classify chat, batch, embedding and image models")
    func classification() throws {
        let catalog = try w1BrowseCatalog()
        func m(_ id: String) throws -> ModelInfo { try #require(catalog.first { $0.id == id }) }
        #expect(try m("openai/gpt-4o").isChatCapable)
        #expect(try m("google/gemini-4-hydrogen:batch").isBatchOnly)
        #expect(try m("google/gemini-4-hydrogen:batch").supportsChatCompletions == false)
        #expect(try m("cohere/embed-5-fast").isChatCapable == false)
        #expect(try m("cohere/embed-5-fast").isEmbeddingModel)
        #expect(try m("recraft/recraft-v4.1-flash-v2").isChatCapable == false)
    }

    @Test("Caches without the endpoints field fall back to the id")
    func oldCacheFallback() {
        #expect(w1BrowseModel("a/x").supportsChatCompletions)
        #expect(w1BrowseModel("a/x:batch").isBatchOnly)
        #expect(w1BrowseModel("a/x", routes: ["/api/v1/batches"]).isBatchOnly)
        #expect(w1BrowseModel("a/x", routes: []).supportsChatCompletions, "an empty list is treated as unknown")
    }

    @Test("A changed endpoints shape never fails the catalog decode")
    func lenientRoutes() throws {
        let json = #"{"data":[{"id":"a/1","name":"One","endpoints":{"unexpected":true}},{"id":"a/2","name":"Two","endpoints":["/api/v1/chat/completions"]}]}"#
        let models = try JSONDecoder().decode(OpenRouterResponse.self, from: Data(json.utf8)).data
        #expect(models.map(\.id) == ["a/1", "a/2"])
        #expect(models[0].supportsChatCompletions)
    }

    @Test("api.models keeps chat semantics while api.catalog has everything")
    func chatSubset() throws {
        let api = APIService(cacheURL: w1BrowseTempURL()) { url in throw URLError(.notConnectedToInternet) }
        api.catalog = try w1BrowseCatalog()
        #expect(api.catalog.count == 7)
        #expect(api.chatModels.map(\.id).sorted() == ["google/gemini-2.5-flash", "openai/gpt-4o", "openai/gpt-4o-mini", "relace/relace-apply-3"])
        #expect(api.models == api.chatModels)
        #expect(!api.models.contains { $0.id == "cohere/embed-5-fast" })
        #expect(!api.models.contains { $0.isBatchOnly })
        // Assigning through the old name still replaces the catalog.
        api.models = [w1BrowseModel("a/only")]
        #expect(api.catalog.map(\.id) == ["a/only"])
    }

    @Test("fetchModels decodes the full catalog from output_modalities=all")
    func fetchFull() async throws {
        let data = try w1BrowseFixture("w1_browse_catalog")
        let seen = W1BrowseCountingLoader()
        seen.catalog = data
        let api = APIService(cacheURL: w1BrowseTempURL()) { url in seen.handle(url) }
        await api.fetchModels()
        #expect(seen.count(containing: "output_modalities=all") == 1)
        #expect(api.catalog.count == 7)
        #expect(api.models.count == 4)
    }

    @Test("The Embeddings filter finds embedding models in the full catalog")
    func embeddingsFilter() throws {
        let vm = w1BrowseVM(try w1BrowseCatalog())
        vm.filters.capabilities = [.embeddings]
        #expect(vm.filteredModels.map(\.id) == ["cohere/embed-5-fast"])
    }

    @Test("Batch variants are hidden by default, shown on request, and never a filter chip")
    func batchToggle() throws {
        let vm = w1BrowseVM(try w1BrowseCatalog())
        #expect(!vm.filteredModels.contains { $0.isBatchOnly })
        #expect(vm.listedCatalogCount == 6)
        #expect(vm.batchVariantCount == 1)
        vm.filters.showBatchVariants = true
        #expect(vm.filteredModels.contains { $0.id == "google/gemini-4-hydrogen:batch" })
        #expect(vm.listedCatalogCount == 7)
        #expect(vm.filters.isActive == false)
        vm.filters.clear()
        #expect(vm.filters.showBatchVariants, "Clear keeps the display preference")
    }

    @Test("The batch preference round-trips and old prefs default to hidden")
    func batchPersistence() throws {
        var state = BrowserFilterState()
        state.showBatchVariants = true
        let data = try JSONEncoder().encode(state)
        #expect(try JSONDecoder().decode(BrowserFilterState.self, from: data).showBatchVariants)
        #expect(try JSONDecoder().decode(BrowserFilterState.self, from: Data("{}".utf8)).showBatchVariants == false)
    }

    @Test("A favorited batch variant still shows in Favorites")
    func favoriteBatch() throws {
        var query = BrowserQuery()
        query.showFavoritesOnly = true
        query.favoriteIds = ["google/gemini-4-hydrogen:batch"]
        let catalog = try w1BrowseCatalog()
        let result = query.run(catalog, index: ModelSearchIndex(catalog), isNew: { _ in false })
        #expect(result.map(\.id) == ["google/gemini-4-hydrogen:batch"])
    }

    @Test("New Models counts distinct models: no :batch, no :free duplicates")
    func newCount() {
        let now = Date().timeIntervalSince1970
        let models = [
            w1BrowseModel("a/m", created: now), w1BrowseModel("a/m:free", created: now),
            w1BrowseModel("a/m:batch", routes: ["/api/v1/batches"], created: now),
            w1BrowseModel("b/n", created: now), w1BrowseModel("c/old", created: now - 30 * 86400),
        ]
        let vm = w1BrowseVM(models)
        #expect(vm.newThisWeekCount == 2)
        #expect(NewModelCount.baseID("a/m:free") == "a/m")
        #expect(NewModelCount.baseID("plain") == "plain")
    }

    @Test("Test Suite hand-off drops batch-only variants")
    func handoffDropsBatch() throws {
        let catalog = try w1BrowseCatalog()
        let api = APIService(cacheURL: w1BrowseTempURL()) { _ in throw URLError(.notConnectedToInternet) }
        api.catalog = catalog
        let ids = CompareHandoff.batchIDs(from: ["openai/gpt-4o", "google/gemini-4-hydrogen:batch"], catalog: api.models)
        #expect(ids == ["openai/gpt-4o"])
    }
}

// MARK: - BROWSE-3 relevance

@Suite("W1 browse: search relevance")
@MainActor
struct W1BrowseSearchTests {
    @Test("gpt-4o ranks the exact model first, then its prefix match, then description-only")
    func exactFirst() throws {
        let vm = w1BrowseVM(try w1BrowseCatalog())
        vm.searchText = "gpt-4o"
        let ids = vm.filteredModels.map(\.id)
        #expect(ids.first == "openai/gpt-4o")
        #expect(ids.prefix(2) == ["openai/gpt-4o", "openai/gpt-4o-mini"])
        let relace = try #require(ids.firstIndex(of: "relace/relace-apply-3"))
        #expect(relace > 1, "a description-only match ranks below name matches")
    }

    @Test("mini ranks *-mini above gemini-*")
    func miniNotGemini() throws {
        let models = [
            w1BrowseModel("google/gemini-2.5-flash", name: "Google: Gemini 2.5 Flash", created: 3),
            w1BrowseModel("google/gemini-3-pro", name: "Google: Gemini 3 Pro", created: 2),
            w1BrowseModel("openai/gpt-4o-mini", name: "OpenAI: GPT-4o-mini", created: 1),
        ]
        let vm = w1BrowseVM(models)
        vm.searchText = "mini"
        #expect(vm.filteredModels.first?.id == "openai/gpt-4o-mini")
        #expect(vm.filteredModels.count == 3)
    }

    @Test("gemini flash puts the model named for both words first")
    func multiWord() {
        let models = [
            w1BrowseModel("x/other", name: "Other", description: "Beats Gemini on flash benchmarks", created: 5),
            w1BrowseModel("google/gemini-3-pro", name: "Google: Gemini 3 Pro", description: "Not flash", created: 4),
            w1BrowseModel("google/gemini-2.5-flash", name: "Google: Gemini 2.5 Flash", created: 1),
        ]
        let vm = w1BrowseVM(models)
        vm.searchText = "gemini flash"
        #expect(vm.filteredModels.first?.id == "google/gemini-2.5-flash")
        #expect(vm.filteredModels.last?.id == "x/other")
    }

    @Test("Searching ranks matches above pinned favorites; no query keeps the chosen sort")
    func favoritesDoNotOutrank() {
        let models = [w1BrowseModel("z/fav", name: "Fav", description: "mentions alpha", created: 9),
                      w1BrowseModel("a/alpha", name: "Alpha", created: 1)]
        let vm = w1BrowseVM(models)
        vm.favoriteIds = ["z/fav"]
        vm.searchText = "alpha"
        #expect(vm.filteredModels.map(\.id) == ["a/alpha", "z/fav"])
        vm.searchText = ""
        #expect(vm.filteredModels.map(\.id) == ["z/fav", "a/alpha"])
    }

    @Test("Tier order: exact > prefix > word start > substring > provider > description")
    func tiers() {
        let index = ModelSearchIndex([
            w1BrowseModel("v/flash", name: "Flash"),
            w1BrowseModel("v/flash-lite", name: "Flash Lite"),
            w1BrowseModel("v/super-flash", name: "Super Flash"),
            w1BrowseModel("v/superflashy", name: "Superflashy"),
            w1BrowseModel("flash/x", name: "X"),
            w1BrowseModel("v/y", name: "Y", description: "flash"),
        ])
        let order = ["v/flash", "v/flash-lite", "v/super-flash", "v/superflashy", "flash/x", "v/y"]
        let models = order.reversed().map { w1BrowseModel($0, name: nil) }
        let ranked = ModelSearchRanker.ranked(models, query: "flash", index: index)
        #expect(ranked.map(\.id) == order)
    }
}

// MARK: - BROWSE-5 stale-while-revalidate

@Suite("W1 browse: cached catalog at launch")
@MainActor
struct W1BrowseLaunchCacheTests {
    @Test("A day-old cache is on screen before the network answers")
    func staleCacheFirst() async throws {
        let cache = w1BrowseTempURL()
        defer { try? FileManager.default.removeItem(at: cache) }
        try w1BrowseFixture("w1_browse_catalog").write(to: cache)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -86_400)], ofItemAtPath: cache.path)
        let gate = W1BrowseGate()
        let api = APIService(cacheURL: cache) { url in
            await gate.wait()
            return w1BrowseOK(url, Data(#"{"data":[{"id":"fresh/model","name":"Fresh"}]}"#.utf8))
        }
        let refresh = Task { await api.fetchModels() }
        let shown = await w1BrowseWait { api.catalog.count == 7 }
        #expect(shown)
        #expect(api.isLoading, "the background refresh is still running")
        #expect(api.lastRefresh != nil)
        await gate.open()
        await refresh.value
        #expect(api.catalog.map(\.id) == ["fresh/model"])
        #expect(!api.isLoading)
    }
}

@Suite("W1 browse: refresh on return")
@MainActor
struct W1BrowseStaleTests {
    @Test("Only a catalog older than an hour is refreshed on activation")
    func stale() {
        let vm = w1BrowseVM([])
        #expect(vm.catalogIsStale() == false, "no refresh has happened yet")
        let now = Date()
        vm.api.lastRefresh = now.addingTimeInterval(-600)
        #expect(vm.catalogIsStale(now: now) == false)
        vm.api.lastRefresh = now.addingTimeInterval(-BrowserViewModel.staleCatalogInterval - 1)
        #expect(vm.catalogIsStale(now: now))
        vm.api.isLoading = true
        #expect(vm.catalogIsStale(now: now) == false)
    }
}

actor W1BrowseGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

// MARK: - BROWSE-6 Markdown descriptions

@Suite("W1 browse: description Markdown")
struct W1BrowseDescriptionTests {
    @Test("Links become link runs without literal brackets; bold renders")
    func linkRun() throws {
        let text = CatalogDescriptionText.attributed("Built on [GLM](https://x.example/glm) and **fast**.")
        #expect(String(text.characters) == "Built on GLM and fast.")
        let linkRun = try #require(text.runs.first { $0.link != nil })
        #expect(String(text[linkRun.range].characters) == "GLM")
        #expect(linkRun.link?.absoluteString == "https://x.example/glm")
        let bold = text.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true }
        #expect(bold)
    }

    @Test("Site-relative links point at openrouter.ai; unsafe schemes lose the link")
    func linkSafety() {
        let relative = CatalogDescriptionText.attributed("See [GPT-4 Omni](/models/openai/gpt-4o).")
        #expect(relative.runs.compactMap(\.link).first?.absoluteString == "https://openrouter.ai/models/openai/gpt-4o")
        let unsafe = CatalogDescriptionText.attributed("[run](javascript:alert(1)) [file](file:///etc/passwd)")
        #expect(unsafe.runs.allSatisfy { $0.link == nil })
        #expect(String(unsafe.characters).contains("run"))
    }

    @Test("Paragraph breaks survive and headings lose their markers")
    func paragraphs() {
        let text = String(CatalogDescriptionText.attributed("# Title\nFirst\n\nSecond").characters)
        #expect(text == "Title\nFirst\n\nSecond")
    }
}

// MARK: - BROWSE-7 / 8 / 13 navigation and keys

@Suite("W1 browse: find, reveal and search keys")
@MainActor
struct W1BrowseNavigationTests {
    @Test("⌘F searches the collection on screen")
    func findTarget() {
        #expect(BrowserFind.target(current: .favorites) == .favorites)
        #expect(BrowserFind.target(current: .newThisWeek) == .newThisWeek)
        #expect(BrowserFind.target(current: .allModels) == .allModels)
        #expect(BrowserFind.target(current: .chat) == .allModels)
    }

    @Test("Revealing a model keeps filters, search and a compatible section")
    func revealKeepsState() throws {
        let vm = w1BrowseVM(try w1BrowseCatalog())
        vm.filters.capabilities = [.tools]
        vm.filters.maxInputPrice = 2
        vm.searchText = "gemini"
        vm.favoriteIds = ["openai/gpt-4o"]
        let filters = vm.filters

        #expect(vm.reveal(id: "openai/gpt-4o", from: .favorites) == .favorites)
        #expect(vm.filters == filters)
        #expect(vm.searchText == "gemini")
        #expect(vm.selectedModel?.id == "openai/gpt-4o")

        #expect(vm.reveal(id: "cohere/embed-5-fast", from: .favorites) == .allModels)
        #expect(vm.selectedModel?.id == "cohere/embed-5-fast")
        #expect(vm.selectionIsOutsideList, "the banner explains a model the filters hide")
        #expect(vm.reveal(id: "missing/model", from: .allModels) == nil)
        #expect(vm.filters == filters)
    }

    @Test("Search keys: ↓ enters the list, Return opens the top hit, Esc clears a query")
    func keys() {
        #expect(BrowserSearchKeys.action(for: .down, hasQuery: true, resultCount: 3) == .focusList(selectFirst: true))
        #expect(BrowserSearchKeys.action(for: .down, hasQuery: false, resultCount: 3, selectionVisible: true) == .focusList(selectFirst: false))
        #expect(BrowserSearchKeys.action(for: .down, hasQuery: true, resultCount: 0) == .ignored)
        #expect(BrowserSearchKeys.action(for: .submit, hasQuery: true, resultCount: 2) == .openFirst)
        #expect(BrowserSearchKeys.action(for: .escape, hasQuery: true, resultCount: 2) == .clear)
        #expect(BrowserSearchKeys.action(for: .escape, hasQuery: false, resultCount: 2) == .ignored)
    }

    @Test("commitSearchNow applies the draft without waiting for the debounce")
    func commitNow() {
        let vm = w1BrowseVM([w1BrowseModel("a/alpha"), w1BrowseModel("a/beta")])
        vm.searchDraft = "beta"
        #expect(vm.searchText.isEmpty)
        vm.commitSearchNow()
        #expect(vm.searchText == "beta")
        #expect(vm.filteredModels.map(\.id) == ["a/beta"])
    }
}

// MARK: - BROWSE-9 / BROWSE-4 hand-off availability

@Suite("W1 browse: Chat and Agent availability")
struct W1BrowseHandoffTests {
    @Test("Agent needs tools; Chat stays available")
    func agentNeedsTools() {
        let plain = w1BrowseModel("a/plain")
        #expect(ModelHandoff.available(for: plain) == [.chat])
        #expect(ModelHandoff.unavailableReason(.agent, for: plain)?.contains("tool") == true)
        #expect(ModelHandoff.available(for: w1BrowseModel("a/tools", params: ["tools"])) == [.chat, .agent])
    }

    @Test("Batch, image and embedding models offer neither")
    func nonChat() throws {
        let catalog = try w1BrowseCatalog()
        for id in ["google/gemini-4-hydrogen:batch", "cohere/embed-5-fast", "recraft/recraft-v4.1-flash-v2"] {
            let model = try #require(catalog.first { $0.id == id })
            #expect(ModelHandoff.available(for: model).isEmpty, "\(id)")
        }
        let batch = try #require(catalog.first { $0.isBatchOnly })
        #expect(ModelHandoff.unavailableReason(.chat, for: batch)?.contains("Batch API") == true)
    }

    @Test("Menu and link hand-offs are refused for models that can't run there")
    @MainActor
    func shellGuard() throws {
        let vm = w1BrowseVM(try w1BrowseCatalog())
        #expect(vm.handoffBlockReason(.chat, id: "openai/gpt-4o") == nil)
        #expect(vm.handoffBlockReason(.agent, id: "openai/gpt-4o") == nil)
        #expect(vm.handoffBlockReason(.chat, id: "google/gemini-4-hydrogen:batch") != nil)
        #expect(vm.handoffBlockReason(.agent, id: "relace/relace-apply-3") != nil)
        #expect(vm.handoffBlockReason(.chat, id: "not/loaded") == nil)
    }
}

// MARK: - BROWSE-10 endpoint cache and debounce

@Suite("W1 browse: endpoint cache")
@MainActor
struct W1BrowseEndpointCacheTests {
    private func vm(_ loader: W1BrowseCountingLoader) -> BrowserViewModel {
        let api = APIService(cacheURL: w1BrowseTempURL()) { url in loader.handle(url) }
        return BrowserViewModel(api: api, db: DatabaseManager())
    }

    @Test("Select A, B, then A again: two requests, and A fills in at once")
    func reselectUsesCache() async {
        let loader = W1BrowseCountingLoader()
        let v = vm(loader)
        v.endpointFetchDelay = .zero
        let a = w1BrowseModel("a/one"), b = w1BrowseModel("a/two")
        v.selectModel(a)
        #expect(await w1BrowseWait { v.endpoints.count == 1 && !v.isLoadingEndpoints })
        v.selectModel(b)
        #expect(await w1BrowseWait { loader.count(containing: "a/two") == 1 && !v.isLoadingEndpoints })
        v.selectModel(a)
        #expect(v.endpoints.count == 1, "served synchronously from the cache")
        #expect(!v.isLoadingEndpoints)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(loader.count(containing: "/endpoints") == 2)
    }

    @Test("Arrowing through ten rows inside the pause sends one request")
    func debounce() async {
        let loader = W1BrowseCountingLoader()
        let v = vm(loader)
        v.endpointFetchDelay = .milliseconds(150)
        for i in 0..<10 { v.selectModel(w1BrowseModel("a/m\(i)")) }
        #expect(await w1BrowseWait { v.endpoints.count == 1 })
        try? await Task.sleep(for: .milliseconds(200))
        #expect(loader.count(containing: "/endpoints") == 1)
        #expect(loader.count(containing: "a/m9") == 1)
    }

    @Test("Retry and catalog refresh bypass the cache")
    func retryBypasses() async {
        let loader = W1BrowseCountingLoader()
        let v = vm(loader)
        v.endpointFetchDelay = .zero
        v.selectModel(w1BrowseModel("a/one"))
        #expect(await w1BrowseWait { v.endpoints.count == 1 && !v.isLoadingEndpoints })
        v.refetchEndpoints()
        #expect(await w1BrowseWait { loader.count(containing: "a/one") == 2 })
    }

    @Test("Cache entries expire")
    func ttl() async {
        var clock = Date()
        let loader = W1BrowseCountingLoader()
        let api = APIService(cacheURL: w1BrowseTempURL()) { url in loader.handle(url) }
        api.now = { clock }
        _ = await api.loadEndpoints(for: "a/b")
        #expect(api.cachedEndpoints(for: "a/b") != nil)
        clock = clock.addingTimeInterval(APIService.endpointCacheTTL + 1)
        #expect(api.cachedEndpoints(for: "a/b") == nil)
    }
}

// MARK: - BROWSE-11 row facts cache

@Suite("W1 browse: row facts cache")
@MainActor
struct W1BrowseRowFactsTests {
    @Test("Row facts are built once per model and catalog, and again on a unit change")
    func cached() {
        let models = [w1BrowseModel("a/one", description: "**Bold** first line"), w1BrowseModel("a/two")]
        let vm = w1BrowseVM(models)
        let first = vm.rowFacts(for: models[0], unit: .perMillion)
        _ = vm.rowFacts(for: models[0], unit: .perMillion)
        _ = vm.rowFacts(for: models[1], unit: .perMillion)
        #expect(vm.rowFactsBuilds == 2)
        #expect(first.oneLiner == "Bold first line")
        _ = vm.rowFacts(for: models[0], unit: .perThousand)
        #expect(vm.rowFactsBuilds == 3)
        vm.api.catalog = models
        _ = vm.rowFacts(for: models[0], unit: .perThousand)
        #expect(vm.rowFactsBuilds == 4, "a new catalog invalidates the cache")
    }
}

// MARK: - BROWSE-12 detail correctness

@Suite("W1 browse: detail pane facts")
struct W1BrowseDetailFactsTests {
    @Test("Max output uses the shared formatter (1.8M, not 1800K)")
    func maxOutput() {
        #expect(BrowserFormat.context(1_800_000) == "1.8M")
        #expect(BrowserFormat.context(16_384) == "16K")
    }

    @Test("Uptime is a percentage; 1 means a 1% outage")
    func uptime() {
        #expect(EndpointUptime.label(1) == "Uptime 1.0%")
        #expect(EndpointUptime.label(99.95) == "Uptime 99.9%")
    }

    @Test("A missing status is neutral, not a red dot, and every state has words")
    func status() {
        #expect(EndpointStatusPresentation(status: nil) == .unknown)
        #expect(EndpointStatusPresentation(status: 0) == .available)
        #expect(EndpointStatusPresentation(status: -2) == .degraded(-2))
        #expect(EndpointStatusPresentation(status: -2).label == "Degraded (status -2)")
        #expect(EndpointStatusPresentation(status: nil).label == "Status not reported")
    }
}

// MARK: - BROWSE-14 snippets

@Suite("W1 browse: API snippets")
struct W1BrowseSnippetTests {
    private let keyPattern = try! Regex(#"sk-or-[A-Za-z0-9-]{8,}|sk-[A-Za-z0-9]{20,}"#)

    @Test("Every language uses the exact id and only the key placeholder")
    func placeholderOnly() throws {
        let model = w1BrowseModel("openai/gpt-4o", params: ["tools"])
        for language in ModelSnippet.Language.allCases {
            let snippet = try #require(ModelSnippet.render(model: model, language: language))
            #expect(snippet.contains("\"openai/gpt-4o\""), "\(language)")
            #expect(snippet.contains("OPENROUTER_API_KEY"), "\(language)")
            #expect(snippet.contains(keyPattern) == false, "\(language)")
            #expect(snippet.contains("chat/completions") || language == .python, "\(language)")
            #expect(snippet.contains("tools"), "\(language)")
        }
        #expect(ModelSnippet.render(model: model, language: .curl)?.contains("$OPENROUTER_API_KEY") == true)
    }

    @Test("reasoning appears only for reasoning-capable models")
    func reasoningOnlyWhenSupported() throws {
        let plain = w1BrowseModel("a/plain")
        let thinker = w1BrowseModel("a/think", params: ["reasoning"])
        for language in ModelSnippet.Language.allCases {
            #expect(try #require(ModelSnippet.render(model: plain, language: language)).contains("reasoning") == false)
            #expect(try #require(ModelSnippet.render(model: thinker, language: language)).contains("reasoning"))
            #expect(try #require(ModelSnippet.render(model: plain, language: language)).contains("tools") == false)
        }
    }

    @Test("Embedding models get an embeddings request; batch and image models get none")
    func kinds() throws {
        let catalog = try w1BrowseCatalog()
        let embed = try #require(catalog.first { $0.id == "cohere/embed-5-fast" })
        #expect(ModelSnippet.render(model: embed, language: .curl)?.contains("/embeddings") == true)
        #expect(ModelSnippet.render(model: try #require(catalog.first { $0.isBatchOnly }), language: .curl) == nil)
        #expect(ModelSnippet.render(model: try #require(catalog.first { $0.id == "recraft/recraft-v4.1-flash-v2" }), language: .curl) == nil)
    }

    @Test("A quote in the id can't break out of the shell string")
    func shellSafe() throws {
        let snippet = try #require(ModelSnippet.render(model: w1BrowseModel("a/it's"), language: .curl))
        #expect(snippet.contains(#"it'\''s"#))
    }
}

// MARK: - V-6 / V-10 row presentation

@Suite("W1 browse: row title and accessibility")
struct W1BrowseRowPresentationTests {
    @Test("Title drops the author prefix; slug and author are separate")
    func title() throws {
        let catalog = try w1BrowseCatalog()
        let batch = try #require(catalog.first { $0.isBatchOnly })
        let facts = ModelRowFacts.make(batch)
        #expect(facts.title == "Gemini 4 Hydrogen (batch)")
        #expect(facts.slug == "gemini-4-hydrogen:batch")
        #expect(facts.author == "Google")
        #expect(ModelDisplayName.title(name: "Plain Name", fallback: "x") == "Plain Name")
        #expect(ModelDisplayName.title(name: "", fallback: "slug") == "slug")
        #expect(ModelDisplayName.title(name: "Ratio 1:2 model", fallback: "x") == "Ratio 1:2 model")
    }

    @Test("The row label names the model, author and batch state")
    func label() throws {
        let batch = try #require(try w1BrowseCatalog().first { $0.isBatchOnly })
        let label = ModelRowAccessibility.label(batch, isFavorite: true, isComparing: false)
        #expect(label == "Gemini 4 Hydrogen (batch), by Google, Batch API only, favorite")
    }

    @Test("Unknown providers get a stable palette slot")
    func palette() {
        #expect(ProviderPalette.slot(for: "relace", count: 11) == ProviderPalette.slot(for: "Relace", count: 11))
        let slots = Set(["relace", "cohere-x", "recraft", "arcee-ai", "inflection", "thudm"].map { ProviderPalette.slot(for: $0, count: 11) })
        #expect(slots.count > 1)
        #expect(ProviderPalette.slot(for: "x", count: 0) == 0)
    }
}
