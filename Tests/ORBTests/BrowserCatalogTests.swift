import Testing
import Foundation
@testable import ORB

private func fixture(_ name: String) throws -> Data {
    guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures") else {
        throw CocoaError(.fileNoSuchFile)
    }
    return try Data(contentsOf: url)
}

private func liveCatalog() throws -> [ModelInfo] {
    try JSONDecoder().decode(OpenRouterResponse.self, from: fixture("models_live_2026_10")).data
}

@Suite("Wave 1 browser: endpoint identity")
struct EndpointIdentityTests {
    @Test("Two DeepInfra endpoints get distinct, stable ids from their tags")
    func twoDeepInfra() throws {
        let decoded = try JSONDecoder().decode(EndpointResponse.self, from: fixture("endpoints_two_deepinfra"))
        let eps = ModelEndpoint.uniquified(decoded.data.endpoints)
        let deepinfra = eps.filter { $0.providerName == "DeepInfra" }
        #expect(deepinfra.count == 2)
        #expect(Set(deepinfra.map(\.id)) == ["deepinfra/fp4", "deepinfra/turbo"])
        #expect(Set(eps.map(\.id)).count == eps.count)
        // Stable across decodes: no UUIDs.
        let again = ModelEndpoint.uniquified(try JSONDecoder().decode(EndpointResponse.self, from: fixture("endpoints_two_deepinfra")).data.endpoints)
        #expect(again.map(\.id) == eps.map(\.id))
        #expect(deepinfra.map(\.displayName).contains("DeepInfra (turbo)"))
    }

    @Test("Endpoints without a tag fall back to provider+quantization and stay unique")
    func untagged() throws {
        let json = #"{"data":{"id":"a/b","endpoints":[{"provider_name":"X","quantization":"fp8"},{"provider_name":"X","quantization":"fp8"},{"provider_name":"X"}]}}"#
        let eps = ModelEndpoint.uniquified(try JSONDecoder().decode(EndpointResponse.self, from: Data(json.utf8)).data.endpoints)
        #expect(eps.map(\.id) == ["X/fp8", "X/fp8#2", "X"])
    }

    @Test("APIService returns uniquified endpoints and never force-unwraps odd ids")
    @MainActor
    func serviceUniquifies() async throws {
        let data = try fixture("endpoints_two_deepinfra")
        let api = APIService(cacheURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)) { url in
            (data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let eps = await api.fetchEndpoints(for: "deepseek/deepseek-chat-v3.1")
        #expect(Set(eps.map(\.id)).count == eps.count)
        #expect(APIService.endpointsURL(for: "a/b?x=1") == nil)
        #expect(APIService.endpointsURL(for: "../etc") == nil)
        #expect(APIService.endpointsURL(for: "~deepseek/x-latest")?.absoluteString == "https://openrouter.ai/api/v1/models/~deepseek/x-latest/endpoints")
    }
}

@Suite("Wave 1 browser: full pricing")
struct FullPricingTests {
    @Test("Live-shaped catalog decodes every model")
    func decodesAll() throws {
        #expect(try liveCatalog().count == 7)
    }

    @Test("Overrides tiers, cache write, web search decode and format")
    func tiers() throws {
        let m = try #require(try liveCatalog().first { $0.id == "openai/gpt-6.1-sol-pro" })
        let p = try #require(m.pricing)
        #expect(p.inputCacheWrite == "0.0000025")
        #expect(p.webSearch == "0.01")
        #expect(p.overrides?.first?.minPromptTokens == 272_000)
        let tiers = p.tierLines(unit: .perMillion)
        #expect(tiers.first?.title == "Above 272K prompt tokens")
        #expect(tiers.first?.value.hasPrefix("$4 / 1M in · $15 / 1M out") == true)
        let extras = p.extraLines(unit: .perMillion).map(\.title)
        #expect(extras.contains("Cache write"))
        #expect(extras.contains("Web search"))
    }

    @Test("Time-window overrides describe their UTC window")
    func timeWindow() throws {
        let m = try #require(try liveCatalog().first { $0.id == "tencent/hy4-preview" })
        #expect(m.pricing?.tierLines(unit: .perMillion).first?.title == "00:00–16:00 UTC")
        let o = PricingOverride(utcStart: 0, utcEnd: 100, utcDays: ["monday", "friday"], prompt: "0.000001")
        #expect(o.conditionText == "00:00–01:00 UTC (Mon, Fri)")
    }

    @Test("Image/audio/reasoning extras appear; unit switch rescales")
    func extras() throws {
        let m = try #require(try liveCatalog().first { $0.id == "google/gemini-3.8-flash" })
        let lines = m.pricing!.extraLines(unit: .perMillion)
        #expect(lines.map(\.title).contains("Image in"))
        #expect(lines.map(\.title).contains("Reasoning"))
        #expect(lines.first { $0.title == "Image in" }?.value == "$0.75 / 1M")
        #expect(m.pricing!.extraLines(unit: .perThousand).first { $0.title == "Image in" }?.value == "$0.00075 / 1K")
    }

    @Test("Bad field types are dropped instead of failing the catalog")
    func tolerant() throws {
        let json = #"{"prompt":"0.000001","completion":2e-6,"discount":"0.1","overrides":[{"prompt":"x"},42]}"#
        let p = try JSONDecoder().decode(Pricing.self, from: Data(json.utf8))
        #expect(p.prompt == "0.000001")
        #expect(p.completion != nil)
        #expect(p.discount == 0.1)
        #expect(p.overrides?.count == 1)
    }

    @Test("Pricing round-trips through the cache encoder")
    func roundTrip() throws {
        let m = try #require(try liveCatalog().first { $0.id == "openai/gpt-6.1-sol-pro" })
        let data = try JSONEncoder().encode(m.pricing)
        #expect(try JSONDecoder().decode(Pricing.self, from: data) == m.pricing)
    }
}

@Suite("Wave 1 browser: aliases and expiry")
struct AliasAndExpiryTests {
    @Test("alias_target decodes; alias endpoints load from the target slug")
    func alias() throws {
        let m = try #require(try liveCatalog().first { $0.id == "~deepseek/deepseek-pro-latest" })
        #expect(m.isAlias)
        #expect(!m.isUnofficial)
        #expect(m.aliasTarget?.slug == "deepseek/deepseek-v4-pro-0813")
        #expect(m.endpointsModelID == "deepseek/deepseek-v4-pro-0813")
    }

    @Test("Alias endpoint fetch requests the target id")
    @MainActor
    func aliasFetch() async throws {
        let m = try #require(try liveCatalog().first { $0.isAlias })
        let box = URLBox()
        let api = APIService(cacheURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)) { url in
            await box.set(url)
            return (Data(#"{"data":{"id":"x","endpoints":[]}}"#.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        _ = await api.fetchEndpoints(for: m)
        #expect(await box.url?.path.contains("deepseek/deepseek-v4-pro-0813") == true)
    }

    @Test("Plain YYYY-MM-DD expiration parses; expired only after the day ends")
    func expiry() throws {
        let m = try #require(try liveCatalog().first { $0.expirationDate != nil })
        #expect(m.expirationDate == "2026-12-31")
        let utc = TimeZone(identifier: "UTC")!
        var cal = Calendar(identifier: .gregorian); cal.timeZone = utc
        let midday = cal.date(from: DateComponents(year: 2026, month: 12, day: 31, hour: 12))!
        let after = cal.date(from: DateComponents(year: 2027, month: 1, day: 1, hour: 0, minute: 1))!
        let early = cal.date(from: DateComponents(year: 2026, month: 12, day: 11, hour: 12))!
        #expect(!m.hasExpired(now: midday))
        #expect(m.hasExpired(now: after))
        #expect(m.expirationWarning(now: midday) == "Expires today")
        #expect(m.expirationWarning(now: early) == "Expires in 20 days")
        #expect(m.expirationWarning(now: cal.date(from: DateComponents(year: 2026, month: 10, day: 1))!) == nil)
    }

    @Test("Knowledge cutoff never force-unwraps")
    func cutoff() throws {
        let catalog = try liveCatalog()
        for m in catalog { _ = m.knowledgeCutoffFormatted }
        #expect(catalog.contains { $0.knowledgeCutoffFormatted == "N/A" } || catalog.allSatisfy { $0.knowledgeCutoff?.isEmpty == false })
    }

    @Test("OpenRouter page URL is built safely")
    func pageURL() {
        #expect(ModelInfo.openRouterURL(for: "openai/gpt-4o")?.absoluteString == "https://openrouter.ai/openai/gpt-4o")
        #expect(ModelInfo.openRouterURL(for: "") == nil)
        #expect(ModelInfo.openRouterURL(for: "a b") == nil)
        #expect(ModelInfo.openRouterURL(for: "a/../../x") == nil)
    }
}

actor URLBox {
    var url: URL?
    func set(_ u: URL) { url = u }
}
