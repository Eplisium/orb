import Testing
import Foundation
@testable import ORB

private func qm(
    _ id: String,
    name: String? = nil,
    prompt: String? = "0.000001",
    completion: String? = "0.000002",
    params: [String] = [],
    aa: ArtificialAnalysis? = nil,
    maxOut: Int? = nil,
    expires: String? = nil,
    alias: String? = nil,
    created: Double? = nil
) -> ModelInfo {
    var m = ModelInfo(
        id: id, canonicalSlug: nil, huggingFaceId: nil, name: name ?? id, created: created,
        description: nil, contextLength: 1000,
        architecture: Architecture(modality: "text->text", inputModalities: ["text"], outputModalities: ["text"], tokenizer: nil, instructType: nil),
        pricing: Pricing(prompt: prompt, completion: completion, inputCacheRead: nil),
        topProvider: TopProvider(contextLength: nil, maxCompletionTokens: maxOut, isModerated: nil),
        supportedParameters: params, reasoning: nil, knowledgeCutoff: nil, expirationDate: expires,
        supportedVoices: nil, benchmarks: aa.map { Benchmarks(designArena: nil, artificialAnalysis: $0) },
        perRequestLimits: nil, defaultParameters: nil
    )
    m.aliasTarget = alias.map { AliasTarget(name: nil, slug: $0) }
    return m
}

private func freshDefaults() -> UserDefaults {
    let name = "orb.tests.browserq.\(UUID().uuidString)"
    let d = UserDefaults(suiteName: name)!
    d.removePersistentDomain(forName: name)
    return d
}

@Suite("Wave 1 browser: sorting")
struct BrowserSortingTests {
    @Test("Price sort: free first, variable and missing always last, both directions")
    func priceSort() {
        let models = [
            qm("r/router", prompt: "-1", completion: "-1"),
            qm("a/pricey", prompt: "0.00001"),
            qm("a/free", prompt: "0", completion: "0"),
            qm("a/cheap", prompt: "0.0000001"),
            qm("x/none", prompt: nil, completion: nil),
        ]
        let asc = ModelSorter.sorted(models, by: .promptCost, order: .ascending).map(\.id)
        #expect(asc == ["a/free", "a/cheap", "a/pricey", "r/router", "x/none"])
        let desc = ModelSorter.sorted(models, by: .promptCost, order: .descending).map(\.id)
        #expect(desc == ["a/pricey", "a/cheap", "a/free", "r/router", "x/none"])
    }

    @Test("Ties break by id so order is stable")
    func stableTies() {
        let models = [qm("b/x", name: "Same"), qm("a/x", name: "Same"), qm("c/x", name: "Same")]
        #expect(ModelSorter.sorted(models, by: .name, order: .ascending).map(\.id) == ["a/x", "b/x", "c/x"])
        #expect(ModelSorter.sorted(models.reversed(), by: .contextLength, order: .descending).map(\.id) == ["a/x", "b/x", "c/x"])
    }

    @Test("Benchmark, max output and expiring sorts; unknown last")
    func newSorts() {
        let models = [
            qm("a/smart", aa: ArtificialAnalysis(intelligenceIndex: 70, codingIndex: 40, agenticIndex: 10), maxOut: 8000),
            qm("a/coder", aa: ArtificialAnalysis(intelligenceIndex: 50, codingIndex: 60, agenticIndex: 55), maxOut: 64000, expires: "2026-11-01"),
            qm("a/none", expires: "2026-10-20"),
        ]
        #expect(ModelSorter.sorted(models, by: .intelligence, order: .descending).map(\.id) == ["a/smart", "a/coder", "a/none"])
        #expect(ModelSorter.sorted(models, by: .coding, order: .descending).map(\.id) == ["a/coder", "a/smart", "a/none"])
        #expect(ModelSorter.sorted(models, by: .agentic, order: .descending).first?.id == "a/coder")
        #expect(ModelSorter.sorted(models, by: .maxOutput, order: .descending).map(\.id) == ["a/coder", "a/smart", "a/none"])
        #expect(ModelSorter.sorted(models, by: .expiringSoon, order: .ascending).map(\.id) == ["a/none", "a/coder", "a/smart"])
    }

    @Test("Output-cost sort uses completion price")
    func outputSort() {
        let models = [qm("a/1", completion: "0.00003"), qm("a/2", completion: "0.000001")]
        #expect(ModelSorter.sorted(models, by: .completionCost, order: .ascending).map(\.id) == ["a/2", "a/1"])
    }
}

@Suite("Wave 1 browser: new filters and prefs")
struct BrowserNewFilterTests {
    @Test("Required parameters AND together")
    func params() {
        let models = [qm("a/1", params: ["seed", "structured_outputs"]), qm("a/2", params: ["seed"])]
        var f = BrowserFilterState()
        f.requiredParameters = ["seed"]
        #expect(models.filter(f.matches).count == 2)
        f.requiredParameters = ["seed", "structured_outputs"]
        #expect(models.filter(f.matches).map(\.id) == ["a/1"])
        #expect(f.chips.contains { $0.kind == .parameter("structured_outputs") })
    }

    @Test("Max output price, hide expired, hide aliases")
    func hides() {
        let models = [
            qm("a/old", expires: "2000-01-01"),
            qm("~a/latest", alias: "a/real"),
            qm("a/pricey", completion: "0.0001"),
            qm("a/free", prompt: "0", completion: "0"),
        ]
        var f = BrowserFilterState(hideExpired: true)
        #expect(!models.filter(f.matches).map(\.id).contains("a/old"))
        f = BrowserFilterState(hideAliases: true)
        #expect(!models.filter(f.matches).map(\.id).contains("~a/latest"))
        f = BrowserFilterState(maxOutputPrice: 5)
        #expect(models.filter(f.matches).map(\.id).contains("a/free"))
        #expect(!models.filter(f.matches).map(\.id).contains("a/pricey"))
        var g = f
        g.remove(g.chips[0])
        #expect(!g.isActive)
    }

    @Test("Prefs saved by older builds still decode; new fields default")
    func legacyPrefs() throws {
        let old = #"{"filters":{"capabilities":["tools"],"providers":["openai"],"maxInputPrice":2},"sortField":"Input Cost","ascending":true,"pinFavorites":false}"#
        let prefs = try JSONDecoder().decode(BrowserPrefs.self, from: Data(old.utf8))
        #expect(prefs.filters.capabilities == [.tools])
        #expect(prefs.filters.requiredParameters.isEmpty)
        #expect(!prefs.filters.hideExpired && !prefs.filters.hideAliases)
        #expect(prefs.compareIDs == nil)
        #expect(SortField(rawValue: prefs.sortField) == .promptCost)
    }

    @Test("New fields round-trip")
    func roundTrip() throws {
        let f = BrowserFilterState(maxOutputPrice: 10, requiredParameters: ["seed"], hideExpired: true, hideAliases: true)
        let back = try JSONDecoder().decode(BrowserFilterState.self, from: JSONEncoder().encode(f))
        #expect(back == f)
    }
}

@MainActor
@Suite("Wave 1 browser: view model caching, search and compare persistence")
struct BrowserViewModelWave1Tests {
    private func vm(_ models: [ModelInfo], defaults: UserDefaults? = nil) -> BrowserViewModel {
        let v = BrowserViewModel(db: DatabaseManager(), defaults: defaults)
        v.api.models = models
        return v
    }

    @Test("filteredModels is cached until an input or the catalog changes")
    func cached() {
        let v = vm([qm("a/1"), qm("a/2")])
        let first = v.filteredModels
        #expect(v.filteredModels == first)
        v.api.models = [qm("a/1"), qm("a/2"), qm("a/3")]
        #expect(v.filteredModels.count == 3)
        v.searchText = "a/3"
        #expect(v.filteredModels.map(\.id) == ["a/3"])
        #expect(v.providerOptions == ["All Providers", "a"])
    }

    @Test("Search matches every term across id/name/provider/description")
    func multiTerm() {
        let v = vm([qm("openai/gpt-x", name: "GPT X"), qm("meta/llama", name: "Llama")])
        v.searchText = "openai  x"
        #expect(v.filteredModels.map(\.id) == ["openai/gpt-x"])
        v.searchText = "LLAMA"
        #expect(v.filteredModels.map(\.id) == ["meta/llama"])
    }

    @Test("Search field draft is debounced into the applied query; clearing is immediate")
    func debounce() async throws {
        let v = vm([qm("a/alpha"), qm("a/beta")])
        v.searchDraft = "alpha"
        #expect(v.searchText.isEmpty)
        let deadline = ContinuousClock.now + .seconds(2)
        while v.searchText != "alpha", ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(v.filteredModels.map(\.id) == ["a/alpha"])
        v.searchDraft = ""
        #expect(v.searchText.isEmpty)
        v.searchText = "beta"
        #expect(v.searchDraft == "beta")
    }

    @Test("Picking a sort uses its natural direction")
    func naturalDirection() {
        let v = vm([])
        v.setSort(.intelligence)
        #expect(v.sortOrder == .descending)
        v.setSort(.expiringSoon)
        #expect(v.sortOrder == .ascending)
    }

    @Test("Compare selection persists and restores, capped")
    func comparePersist() {
        let d = freshDefaults()
        let a = vm([], defaults: d)
        a.toggleCompare("a/1"); a.toggleCompare("a/2")
        let b = vm([], defaults: d)
        #expect(b.compareIDs == ["a/1", "a/2"])
        b.removeFromCompare("a/1")
        #expect(vm([], defaults: d).compareIDs == ["a/2"])
        b.setCompare(["x/1", "x/1", "x/2", "x/3", "x/4", "x/5", "x/6"])
        #expect(b.compareIDs.count == TestBatchSelection.maximumModels)
        #expect(b.compareIDs.first == "x/1" && Set(b.compareIDs).count == b.compareIDs.count)
    }

    @Test("Export renders the filtered list as CSV and JSON")
    func export() throws {
        let v = vm([qm("a/one", name: "One, \"quoted\""), qm("a/free", prompt: "0", completion: "0")])
        let csv = ModelExport.render(v.filteredModels, format: .csv, unit: .perMillion)
        let lines = csv.split(separator: "\n")
        #expect(lines.count == 3)
        #expect(lines[0].hasPrefix("id,name,provider"))
        #expect(csv.contains("\"One, \"\"quoted\"\"\""))
        let json = ModelExport.render(v.filteredModels, format: .json, unit: .perMillion)
        let rows = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]]
        #expect(rows?.count == 2)
        let one = rows?.first { $0["id"] as? String == "a/one" }
        #expect(one?["input_price"] as? Double == 1)
        #expect(ModelExport.csvField("=SUM(A1)") == "'=SUM(A1)")
    }
}

@Suite("Wave 1 browser: price unit")
struct PriceUnitTests {
    @Test("One formatter for both units")
    func units() {
        #expect(PriceDisplay.text(perToken: 0.000003, unit: .perMillion) == "$3 / 1M")
        #expect(PriceDisplay.text(perToken: 0.000003, unit: .perThousand) == "$0.003 / 1K")
        #expect(PriceDisplay.amount(perToken: 0.00000015, unit: .perMillion) == "$0.15")
        #expect(PriceDisplay.perToken("-1") == nil)
        #expect(PriceDisplay.perToken("abc") == nil)
        let d = freshDefaults()
        #expect(PriceUnit.load(from: d) == .perMillion)
        d.set("perThousand", forKey: PriceUnit.defaultsKey)
        #expect(PriceUnit.load(from: d) == .perThousand)
    }

    @Test("Row facts follow the unit")
    func rowFacts() {
        let m = qm("a/x", prompt: "0.000003", completion: "0.000015")
        #expect(ModelRowFacts.make(m).price == "$3 in · $15 out")
        #expect(ModelRowFacts.make(m, unit: .perThousand).price == "$0.003 in · $0.015 out /1K")
    }
}
