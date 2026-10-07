import Testing
import Foundation
import SQLite3
@testable import ORB

private func cm(_ id: String, prompt: String = "0.000001", cache: String? = nil, pricing: Pricing? = nil, maxOut: Int? = nil, iq: Double? = nil, cutoff: String? = nil, params: [String] = []) -> ModelInfo {
    ModelInfo(
        id: id, canonicalSlug: nil, huggingFaceId: nil, name: "N \(id)", created: nil, description: nil, contextLength: 1000,
        architecture: Architecture(modality: nil, inputModalities: ["text"], outputModalities: ["text"], tokenizer: nil, instructType: nil),
        pricing: pricing ?? Pricing(prompt: prompt, completion: "0.000002", inputCacheRead: cache),
        topProvider: TopProvider(contextLength: nil, maxCompletionTokens: maxOut, isModerated: nil),
        supportedParameters: params, reasoning: nil, knowledgeCutoff: cutoff, expirationDate: nil, supportedVoices: nil,
        benchmarks: iq.map { Benchmarks(designArena: nil, artificialAnalysis: ArtificialAnalysis(intelligenceIndex: $0, codingIndex: nil, agenticIndex: nil)) },
        perRequestLimits: nil, defaultParameters: nil
    )
}

@Suite("Wave 1 browser: compare panel data")
struct ComparePanelDataTests {
    @Test("New rows: max output, cache price, intelligence, cutoff, parameters")
    func rows() {
        let c = ComparisonColumn.make(model: cm("a/1", cache: "0.0000001", maxOut: 64_000, iq: 61.25, cutoff: "2025-06", params: ["tools", "seed"]), endpoints: nil)
        #expect(c.maxOutput == "64K")
        #expect(c.cachePrice == "$0.10 / 1M")
        #expect(c.intelligence == "61.2" || c.intelligence == "61.3")
        #expect(c.knowledgeCutoff == "2025-06")
        #expect(c.parameters == "seed, tools")
        let empty = ComparisonColumn.make(model: cm("a/2"), endpoints: nil)
        var p = Pricing(prompt: "0.000001", completion: "0.000002", inputCacheRead: nil)
        p.overrides = [PricingOverride(minPromptTokens: 200_000, prompt: "0.000002")]
        p.webSearch = "0.01"
        let tiered = cm("a/3", pricing: p)
        let t = ComparisonColumn.make(model: tiered, endpoints: nil)
        #expect(t.pricingTiers.contains("Above 200K prompt tokens: $2 / 1M in"))
        #expect(t.pricingTiers.contains("Web search: $0.01 / request"))
        #expect(empty.pricingTiers == "—")
        #expect(empty.maxOutput == "—" && empty.cachePrice == "—" && empty.intelligence == "—" && empty.parameters == "—")
    }

    @Test("Highlights cover max output and intelligence")
    func highlights() {
        let cols = [cm("a/1", maxOut: 8000, iq: 40), cm("a/2", maxOut: 64000, iq: 70)].map { ComparisonColumn.make(model: $0, endpoints: nil) }
        let best = ComparisonColumn.highlights(cols)
        #expect(best.largestOutputID == "a/2")
        #expect(best.smartestID == "a/2")
    }

    @Test("Markdown and CSV exports have a header plus one line per row")
    func exports() {
        let cols = [cm("a/1"), cm("a|2")].map { ComparisonColumn.make(model: $0, endpoints: nil) }
        let md = ComparisonColumn.markdown(cols)
        let mdLines = md.split(separator: "\n")
        #expect(mdLines.count == 2 + ComparisonColumn.rows.count)
        #expect(mdLines[1].hasPrefix("|---|"))
        #expect(md.contains("a\\|2"))
        let csv = ComparisonColumn.csv(cols).split(separator: "\n")
        #expect(csv.count == 1 + ComparisonColumn.rows.count)
        #expect(csv[1].hasPrefix("Model ID,a/1,a|2"))
    }

    @Test("Endpoints load concurrently with independent results")
    func parallel() async {
        let started = Counter()
        let results = await CompareEndpointLoader.load(
            [(id: "a/ok", endpointsID: "a/ok"), (id: "~a/alias", endpointsID: "a/target"), (id: "a/bad", endpointsID: "a/bad")],
            loader: { id in
                await started.bump()
                // All three must be in flight before any returns.
                let deadline = ContinuousClock.now + .seconds(2)
                while await started.value < 3, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
                if id == "a/bad" { return .failure(.http(500)) }
                return .success([])
            }
        )
        #expect(await started.value == 3)
        #expect((try? results["a/ok"]?.get()) != nil)
        #expect((try? results["~a/alias"]?.get()) != nil)
        #expect(results["a/bad"].map { if case .failure(.http(500)) = $0 { return true } else { return false } } == true)
    }

    @Test("loadEndpoints never writes the shared endpointsError")
    @MainActor
    func noSharedError() async {
        let api = APIService(cacheURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)) { url in
            (Data(), HTTPURLResponse(url: url, statusCode: 503, httpVersion: nil, headerFields: nil)!)
        }
        let r = await api.loadEndpoints(for: "a/b")
        #expect(api.endpointsError == nil)
        if case .failure(.http(503)) = r {} else { Issue.record("expected http 503") }
    }
}

actor Counter {
    var value = 0
    func bump() { value += 1 }
}

@MainActor
@Suite("Wave 1 browser: favorites and notes storage")
struct BrowserStorageTests {
    @Test("Favorites toggle through the checked path; notes save for non-favorites")
    func roundTrip() {
        let db = DatabaseManager()
        let vm = BrowserViewModel(db: db, defaults: nil)
        vm.toggleFavorite(id: "a/1")
        #expect(vm.favoriteIds == ["a/1"])
        #expect(vm.lastStorageError == nil)
        vm.toggleFavorite(id: "a/1")
        #expect(vm.favoriteIds.isEmpty)
        vm.saveNotes("hello", for: "x/not-a-favorite")
        #expect(db.getNotes("x/not-a-favorite") == "hello")
        #expect(vm.lastStorageError == nil)
    }

    @Test("Busy timeout is configured on the connection")
    func busyTimeout() throws {
        let db = DatabaseManager()
        let handle = try #require(db.db)
        var stmt: OpaquePointer?
        #expect(sqlite3_prepare_v2(handle, "PRAGMA busy_timeout;", -1, &stmt, nil) == SQLITE_OK)
        defer { sqlite3_finalize(stmt) }
        #expect(sqlite3_step(stmt) == SQLITE_ROW)
        #expect(sqlite3_column_int(stmt, 0) == DatabaseManager.busyTimeoutMilliseconds)
    }

    @Test("A failed write throws instead of being silently ignored")
    func failureSurfaces() throws {
        let db = DatabaseManager()
        let handle = try #require(db.db)
        #expect(sqlite3_exec(handle, "DROP TABLE model_notes;", nil, nil, nil) == SQLITE_OK)
        #expect(throws: DatabaseManagerError.self) { try db.saveNotes("a/1", notes: "x") }
    }
}
