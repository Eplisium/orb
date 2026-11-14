import Foundation
import Testing
@testable import ORB

/// Image/audio catalog entries price tokens at zero and charge per image,
/// image token or request instead; the browser must not call them "Free".
@Suite("W1 browse: media model pricing in rows")
struct W1MediaPricingRowTests {
    private func model(_ id: String, pricing: [String: String], context: Int? = 4096,
                       output: [String] = ["image"]) throws -> ModelInfo {
        var json: [String: Any] = [
            "id": id, "name": id,
            "architecture": ["input_modalities": ["text"], "output_modalities": output],
            "pricing": pricing,
        ]
        if let context { json["context_length"] = context }
        return try JSONDecoder().decode(ModelInfo.self, from: JSONSerialization.data(withJSONObject: json))
    }

    @Test("Per-image pricing is shown, not Free")
    func perImage() throws {
        let m = try model("acme/painter", pricing: ["prompt": "0", "completion": "0", "image": "0.04"])
        #expect(!m.isFree)
        let facts = ModelRowFacts.make(m)
        #expect(facts.price.contains("per image"))
        #expect(facts.price.contains("0.04"))
    }

    @Test("Image-output token pricing is shown, not Free")
    func imageOutputTokens() throws {
        let m = try model("acme/imagetok", pricing: ["prompt": "0", "completion": "0", "image_output": "0.00003"])
        #expect(!m.isFree)
        #expect(ModelRowFacts.make(m).price.contains("image out"))
    }

    @Test("Per-request pricing is shown, not Free")
    func perRequest() throws {
        let m = try model("acme/decider", pricing: ["prompt": "0", "completion": "0", "request": "0.01"], output: ["text"])
        #expect(!m.isFree)
        #expect(ModelRowFacts.make(m).price.contains("per request"))
    }

    @Test("Truly free and :free models stay Free")
    func stillFree() throws {
        #expect(try model("acme/zero", pricing: ["prompt": "0", "completion": "0"], output: ["text"]).isFree)
        #expect(try model("acme/paid:free", pricing: ["prompt": "0", "completion": "0", "image": "0.04"]).isFree)
    }

    @Test("A zero context length is not shown as \"0 ctx\"")
    func zeroContext() throws {
        let m = try model("acme/noctx", pricing: ["prompt": "0", "completion": "0", "image": "0.04"], context: 0)
        #expect(ModelRowFacts.make(m).context == "N/A")
    }
}
