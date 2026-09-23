import Foundation
import Testing
@testable import ORB

@Suite("Request settings validation")
struct RequestValidationTests {

    private func schemaSettings(name: String, schemaJSON: String?) -> GenerationSettings {
        var settings = GenerationSettings()
        let schema: JSONValue
        if let schemaJSON {
            schema = JSONValue.parse(schemaJSON) ?? .null
        } else {
            schema = .null
        }
        settings.responseFormat = .jsonSchema(name: name, schema: schema, strict: true)
        return settings
    }

    @Test("a blank schema name blocks submission instead of being dropped")
    func blankNameThrows() {
        let settings = schemaSettings(name: "   ", schemaJSON: #"{"type":"object"}"#)
        #expect(throws: GenerationSettingsValidationError.invalidResponseFormat("the schema name is blank")) {
            try settings.validatedStrict()
        }
    }

    @Test("a non-object schema blocks submission instead of being dropped")
    func nonObjectSchemaThrows() {
        let settings = schemaSettings(name: "result", schemaJSON: #"[1,2,3]"#)
        #expect(throws: GenerationSettingsValidationError.invalidResponseFormat("the schema is not a JSON object")) {
            try settings.validatedStrict()
        }
    }

    @Test("a valid schema survives strict validation with its constraint intact")
    func validSchemaIntact() throws {
        let settings = schemaSettings(name: "result", schemaJSON: #"{"type":"object"}"#)
        let validated = try settings.validatedStrict()
        guard case .jsonSchema(let name, let schema, let strict) = validated.responseFormat else {
            Issue.record("Structured output must not be dropped by validation.")
            return
        }
        #expect(name == "result")
        #expect(schema.objectValue != nil)
        #expect(strict == true)
    }

    @Test("structured output is never silently weakened at the wire encoder")
    func wireEncoderFailsClosed() throws {
        let settings = schemaSettings(name: "", schemaJSON: #"{"type":"object"}"#)
        let request = OpenRouterRequest(
            apiKey: "test-key",
            model: "test/model",
            messages: [.init(role: "user", content: "hi")],
            settings: settings
        )
        // Encoding IS the request boundary: it must throw, not strip the
        // constraint and send an unconstrained paid call.
        #expect(throws: GenerationSettingsValidationError.self) {
            try OpenRouterRequestEncoder.encodeBody(request, stream: true)
        }
    }

    @Test("ordinary clamps and exclusivity still apply")
    func ordinaryClampsStillApply() throws {
        var settings = GenerationSettings()
        settings.temperature = 9
        settings.reasoning.effort = .high
        settings.reasoning.maxTokens = 2048
        let validated = try settings.validatedStrict()
        #expect(validated.temperature == 2)
        // effort and maxTokens are mutually exclusive; effort wins.
        #expect(validated.reasoning.maxTokens == nil)
        #expect(validated.reasoning.effort == .high)
    }

    @Test("a broken schema still clamps-then-throws only for the constraint")
    func brokenSchemaDoesNotMaskOtherValues() {
        var settings = schemaSettings(name: "result", schemaJSON: nil)
        settings.temperature = 99
        #expect(throws: GenerationSettingsValidationError.self) {
            try settings.validatedStrict()
        }
    }
}
