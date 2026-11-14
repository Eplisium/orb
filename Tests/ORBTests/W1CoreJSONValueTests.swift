import Foundation
import Testing
@testable import ORB

@Suite("W1 core: JSONValue.jsonText")
struct W1CoreJSONValueTests {
    @Test("top-level strings are escaped and round-trip", arguments: [
        "a\"b\nc", "back\\slash", "tab\there", "quote \" and newline \n", "emoji 🎉 / slash", "nul\u{0}byte", "",
    ])
    func topLevelStringRoundTrips(_ text: String) throws {
        let json = JSONValue.string(text).jsonText
        #expect(JSONValue.parse(json) == .string(text), "jsonText: \(json)")
        #expect(json.hasPrefix("\"") && json.hasSuffix("\""))
    }

    @Test("non-finite numbers become null at top level and when nested", arguments: [
        Double.nan, .infinity, -.infinity,
    ])
    func nonFiniteNumbersAreNull(_ number: Double) throws {
        #expect(JSONValue.number(number).jsonText == "null")
        let nested = JSONValue.object(["value": .number(number), "list": .array([.number(1), .number(number)])])
        let text = nested.jsonText
        #expect(text == #"{"list":[1,null],"value":null}"#)
        #expect(JSONValue.parse(text) != nil)
        // Encodable (wire) path agrees instead of throwing for the whole payload.
        let encoded = try JSONEncoder().encode(nested)
        #expect(JSONValue.parse(String(decoding: encoded, as: UTF8.self)) == JSONValue.parse(text))
    }

    @Test("other fragments are valid JSON")
    func fragments() {
        #expect(JSONValue.number(3).jsonText == "3")
        #expect(JSONValue.number(2.5).jsonText == "2.5")
        #expect(JSONValue.bool(true).jsonText == "true")
        #expect(JSONValue.null.jsonText == "null")
        #expect(JSONValue.parse(JSONValue.number(-0.125).jsonText) == .number(-0.125))
    }

    @Test("objects stay compact, key-sorted, and keep slashes unescaped")
    func objectsUnchanged() {
        let value = JSONValue.object(["b": .string("x/y"), "a": .array([.bool(false), .null])])
        #expect(value.jsonText == #"{"a":[false,null],"b":"x/y"}"#)
    }
}
