import Foundation
import Testing

@testable import ORB

// MARK: - Fixtures

private func model(
    id: String,
    name: String = "Test Model",
    provider: String = "TestProvider",
    contextLength: Int? = 128_000,
    promptCost: String? = "0.000001",
    completionCost: String? = "0.000002",
    created: Double? = nil
) -> ModelInfo {
    ModelInfo(
        id: id,
        canonicalSlug: nil,
        huggingFaceId: nil,
        name: name,
        created: created,
        description: nil,
        contextLength: contextLength,
        architecture: Architecture(
            modality: "text->text",
            inputModalities: ["text"],
            outputModalities: ["text"],
            tokenizer: nil,
            instructType: nil
        ),
        pricing: Pricing(prompt: promptCost ?? "0", completion: completionCost ?? "0", inputCacheRead: nil),
        topProvider: nil,
        supportedParameters: [],
        reasoning: nil,
        knowledgeCutoff: nil,
        expirationDate: nil,
        supportedVoices: nil,
        benchmarks: nil,
        perRequestLimits: nil,
        defaultParameters: nil
    )
}

// MARK: - Model recents

@Suite("Model recents")
struct ModelRecentsLogicTests {

    @Test("recording puts the newest model first and de-duplicates")
    func recordNewestFirstAndDedupes() {
        let t0 = Date(timeIntervalSince1970: 100)
        var entries = ModelRecents.record("a", in: [], now: t0)
        entries = ModelRecents.record("b", in: entries, now: t0.addingTimeInterval(1))
        entries = ModelRecents.record("a", in: entries, now: t0.addingTimeInterval(2))
        #expect(entries.map(\.id) == ["a", "b"])
        #expect(entries.first?.lastUsed == t0.addingTimeInterval(2))
    }

    @Test("history is capped at the limit, oldest dropped")
    func recordCapsAtLimit() {
        var entries: [RecentModel] = []
        for index in 0..<(ModelRecents.limit + 3) {
            entries = ModelRecents.record("m\(index)", in: entries, now: Date(timeIntervalSince1970: Double(index)))
        }
        #expect(entries.count == ModelRecents.limit)
        #expect(entries.first?.id == "m\(ModelRecents.limit + 2)")
    }

    @Test("encode/decode round-trips and corrupt data decodes empty")
    func encodeDecodeRoundTrip() throws {
        let entries = [
            RecentModel(id: "x", lastUsed: Date(timeIntervalSince1970: 1)),
            RecentModel(id: "y", lastUsed: Date(timeIntervalSince1970: 2)),
        ]
        let data = try #require(ModelRecents.encode(entries))
        #expect(ModelRecents.decode(data) == entries)
        #expect(ModelRecents.decode(nil) == [])
        #expect(ModelRecents.decode(Data("not json".utf8)) == [])
    }

    @Test("store persists through UserDefaults and clears")
    func storeRoundTrip() {
        let suiteName = "ModelRecentsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = ModelRecentsStore(defaults: defaults)
        #expect(store.recentIds() == [])
        store.record("z")
        store.record("y")
        #expect(store.recentIds() == ["y", "z"])
        store.clear()
        #expect(store.recentIds() == [])
    }
}

// MARK: - Picker catalog sections and sorting

@Suite("Model picker catalog")
struct ModelCatalogSectionTests {

    private let cheap = model(id: "cheap", name: "Cheap", promptCost: "0.000001")
    private let pricey = model(id: "pricey", name: "Pricey", promptCost: "0.01")
    private let unknown = model(id: "unknown", name: "Unknown Cost", promptCost: nil)

    @Test("defaults keep the classic behavior: favorites then all, alphabetical")
    func defaultsMatchClassicBehavior() {
        let models = [pricey, cheap, unknown]
        let sections = AgentModelCatalog.sections(
            models: models,
            favoriteIds: ["pricey"],
            searchText: "",
            toolCapableOnly: false
        )
        #expect(sections.map(\.title) == ["Favorites", "All models"])
        #expect(sections[0].models.map(\.id) == ["pricey"])
        #expect(sections[1].models.map(\.name) == ["Cheap", "Unknown Cost"])
    }

    @Test("recents get their own section in recency order and nothing is listed twice")
    func recentsSectionIsDisjoint() {
        let models = [cheap, pricey, unknown]
        let sections = AgentModelCatalog.sections(
            models: models,
            favoriteIds: ["pricey"],
            searchText: "",
            toolCapableOnly: false,
            recentIds: ["unknown", "cheap", "pricey"]
        )
        #expect(sections.map(\.title) == ["Favorites", "Recents"])
        // Recency order, favorites excluded from Recents (they live above);
        // everything is claimed, so no "All models" section remains.
        #expect(sections[1].models.map(\.id) == ["unknown", "cheap"])
        // No ID appears twice across sections.
        let allIds = sections.flatMap { $0.models.map(\.id) }
        #expect(Set(allIds).count == allIds.count)
    }

    @Test("search filters recents too")
    func searchFiltersRecents() {
        let models = [cheap, pricey, unknown]
        let sections = AgentModelCatalog.sections(
            models: models,
            favoriteIds: [],
            searchText: "cheap",
            toolCapableOnly: false,
            recentIds: ["unknown", "cheap"]
        )
        #expect(sections.map(\.title) == ["Recents"])
        #expect(sections[0].models.map(\.id) == ["cheap"])
    }

    @Test("sort by input cost ascending puts missing costs last")
    func sortByPromptCostAscending() {
        let sorted = AgentModelCatalog.sort([unknown, pricey, cheap], by: .promptCost, order: .ascending)
        #expect(sorted.map(\.id) == ["cheap", "pricey", "unknown"])
    }

    @Test("descending still keeps missing costs last")
    func sortByPromptCostDescending() {
        let sorted = AgentModelCatalog.sort([unknown, cheap, pricey], by: .promptCost, order: .descending)
        #expect(sorted.map(\.id) == ["pricey", "cheap", "unknown"])
    }

    @Test("sort by context length and date added with direction control")
    func sortOtherFields() {
        let small = model(id: "small", name: "Small", contextLength: 8_000, promptCost: "0")
        let big = model(id: "big", name: "Big", contextLength: 200_000, promptCost: "0")
        #expect(AgentModelCatalog.sort([small, big], by: .contextLength, order: .ascending).map(\.id) == ["small", "big"])
        #expect(AgentModelCatalog.sort([small, big], by: .contextLength, order: .descending).map(\.id) == ["big", "small"])

        let old = model(id: "old", name: "Old", created: 100)
        let new = model(id: "new", name: "New", created: 900)
        #expect(AgentModelCatalog.sort([old, new], by: .created, order: .descending).map(\.id) == ["new", "old"])
    }

    @Test("name sorting honors direction and ties break stably")
    func sortByName() {
        let models = [model(id: "b", name: "Bravo"), model(id: "a", name: "alpha"), model(id: "c", name: "Charlie")]
        #expect(AgentModelCatalog.sort(models, by: .name, order: .ascending).map(\.name) == ["alpha", "Bravo", "Charlie"])
        #expect(AgentModelCatalog.sort(models, by: .name, order: .descending).map(\.name) == ["Charlie", "Bravo", "alpha"])
    }
}
