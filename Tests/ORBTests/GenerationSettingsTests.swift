import Foundation
import Testing
@testable import ORB

/// The request encoder is the highest-risk surface in the OpenRouter
/// integration: a wrong key name or an unintentionally-emitted default silently
/// changes model behavior rather than failing loudly. These tests pin the exact
/// wire format.
@Suite("OpenRouter request encoding")
struct GenerationSettingsEncodingTests {

    /// Encodes a request body the same way the client does and returns the
    /// decoded JSON object for inspection.
    private func encode(_ settings: GenerationSettings) throws -> [String: Any] {
        let request = OpenRouterRequest(
            apiKey: "test-key",
            model: "test/model",
            messages: [.init(role: "user", content: "hi")],
            settings: settings
        )
        let data = try OpenRouterRequestEncoder.encodeBody(request, stream: true)
        return try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }

    @Test("defaults omit every optional parameter")
    func defaultsAreSparse() throws {
        let body = try encode(.default)

        // Only the required fields plus streaming controls should be present.
        // Sending defaults ORB invented would override provider tuning.
        for key in ["top_p", "top_k", "min_p", "top_a", "seed", "stop",
                    "frequency_penalty", "presence_penalty", "repetition_penalty",
                    "reasoning", "provider", "plugins", "transforms", "models"] {
            #expect(body[key] == nil, "expected \(key) to be omitted by default")
        }
        #expect(body["model"] as? String == "test/model")
        #expect(body["stream"] as? Bool == true)
    }

    @Test("sampling parameters use OpenRouter's snake_case keys")
    func samplingKeys() throws {
        var settings = GenerationSettings.default
        settings.temperature = 0.35
        settings.topP = 0.9
        settings.topK = 40
        settings.minP = 0.05
        settings.topA = 0.2
        settings.seed = 1234
        settings.maxTokens = 2048

        let body = try encode(settings)
        #expect(body["temperature"] as? Double == 0.35)
        #expect(body["top_p"] as? Double == 0.9)
        #expect(body["top_k"] as? Int == 40)
        #expect(body["min_p"] as? Double == 0.05)
        #expect(body["top_a"] as? Double == 0.2)
        #expect(body["seed"] as? Int == 1234)
        #expect(body["max_tokens"] as? Int == 2048)
    }

    @Test("penalties and stop sequences encode correctly")
    func penaltiesAndStop() throws {
        var settings = GenerationSettings.default
        settings.frequencyPenalty = 0.5
        settings.presencePenalty = -0.25
        settings.repetitionPenalty = 1.1
        settings.stop = ["\n\nUser:", "END"]

        let body = try encode(settings)
        #expect(body["frequency_penalty"] as? Double == 0.5)
        #expect(body["presence_penalty"] as? Double == -0.25)
        #expect(body["repetition_penalty"] as? Double == 1.1)
        #expect(body["stop"] as? [String] == ["\n\nUser:", "END"])
    }

    @Test("empty stop list is omitted rather than sent empty")
    func emptyStopOmitted() throws {
        var settings = GenerationSettings.default
        settings.stop = []
        #expect(try encode(settings)["stop"] == nil)
    }

    @Test("reasoning effort and budget are mutually exclusive")
    func reasoningExclusivity() throws {
        var settings = GenerationSettings.default
        settings.reasoning.effort = .high
        settings.reasoning.maxTokens = 5000

        let reasoning = try #require(try encode(settings)["reasoning"] as? [String: Any])
        // Effort wins; sending both is rejected upstream.
        #expect(reasoning["effort"] as? String == "high")
        #expect(reasoning["max_tokens"] == nil)
    }

    @Test("reasoning budget encodes when no effort is set")
    func reasoningBudget() throws {
        var settings = GenerationSettings.default
        settings.reasoning.maxTokens = 4096

        let reasoning = try #require(try encode(settings)["reasoning"] as? [String: Any])
        #expect(reasoning["max_tokens"] as? Int == 4096)
        #expect(reasoning["effort"] == nil)
    }

    @Test("excluding reasoning still enables it")
    func reasoningExclude() throws {
        var settings = GenerationSettings.default
        settings.reasoning.exclude = true
        let reasoning = try #require(try encode(settings)["reasoning"] as? [String: Any])
        #expect(reasoning["exclude"] as? Bool == true)
    }

    @Test("provider routing preferences encode")
    func providerRouting() throws {
        var settings = GenerationSettings.default
        settings.provider.order = ["anthropic", "openai"]
        settings.provider.ignore = ["deepinfra"]
        settings.provider.allowFallbacks = false
        settings.provider.requireParameters = true
        settings.provider.sort = .throughput
        settings.provider.dataCollection = .deny

        let provider = try #require(try encode(settings)["provider"] as? [String: Any])
        #expect(provider["order"] as? [String] == ["anthropic", "openai"])
        #expect(provider["ignore"] as? [String] == ["deepinfra"])
        #expect(provider["allow_fallbacks"] as? Bool == false)
        #expect(provider["require_parameters"] as? Bool == true)
        #expect(provider["sort"] as? String == "throughput")
        #expect(provider["data_collection"] as? String == "deny")
    }

    @Test("default provider settings emit no provider block")
    func providerDefaultsOmitted() throws {
        // allowFallbacks defaults to true upstream, so a body containing only
        // that value would be noise.
        #expect(try encode(.default)["provider"] == nil)
    }

    @Test("web search plugin encodes with result count")
    func webSearchPlugin() throws {
        var settings = GenerationSettings.default
        settings.webSearch = true
        settings.webSearchMaxResults = 3

        let plugins = try #require(try encode(settings)["plugins"] as? [[String: Any]])
        let web = try #require(plugins.first { $0["id"] as? String == "web" })
        #expect(web["max_results"] as? Int == 3)
    }

    @Test("fallback models and transforms encode")
    func fallbacksAndTransforms() throws {
        var settings = GenerationSettings.default
        settings.fallbackModels = ["openai/gpt-4o-mini"]
        settings.transforms = ["middle-out"]

        let body = try encode(settings)
        // OpenRouter expects the primary model first, then fallbacks in order.
        #expect(body["models"] as? [String] == ["test/model", "openai/gpt-4o-mini"])
        #expect(body["transforms"] as? [String] == ["middle-out"])
    }

    @Test("usage accounting is requested when enabled")
    func usageAccounting() throws {
        var settings = GenerationSettings.default
        settings.includeUsageAccounting = true
        let usage = try #require(try encode(settings)["usage"] as? [String: Any])
        #expect(usage["include"] as? Bool == true)
    }

    @Test("active summary reflects only non-default parameters")
    func activeSummary() throws {
        #expect(GenerationSettings.default.activeSummary.isEmpty)

        var settings = GenerationSettings.default
        settings.topP = 0.8
        settings.seed = 7
        #expect(settings.activeSummary.count == 2)
    }
}

@Suite("Usage accounting decoding")
struct ChatUsageDecodingTests {

    @Test("cached and reasoning token details decode from nested objects")
    func nestedDetails() throws {
        let json = """
        {
          "prompt_tokens": 1200,
          "completion_tokens": 340,
          "total_tokens": 1540,
          "cost": 0.00123,
          "prompt_tokens_details": { "cached_tokens": 900 },
          "completion_tokens_details": { "reasoning_tokens": 210 }
        }
        """.data(using: .utf8)!

        let usage = try JSONDecoder().decode(ChatUsage.self, from: json)
        #expect(usage.promptTokens == 1200)
        #expect(usage.cost == 0.00123)
        #expect(usage.cachedTokens == 900)
        #expect(usage.reasoningTokens == 210)
    }

    @Test("missing detail objects decode as nil rather than failing")
    func missingDetails() throws {
        let json = """
        { "prompt_tokens": 10, "completion_tokens": 5, "total_tokens": 15 }
        """.data(using: .utf8)!

        let usage = try JSONDecoder().decode(ChatUsage.self, from: json)
        #expect(usage.cachedTokens == nil)
        #expect(usage.reasoningTokens == nil)
        #expect(usage.cost == nil)
    }
}
