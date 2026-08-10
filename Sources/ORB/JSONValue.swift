import Foundation

/// A minimal, `Codable` representation of arbitrary JSON.
///
/// Needed because MCP servers publish tool input schemas as free-form JSON
/// Schema — nested objects, arrays, enums, `oneOf`, and so on — which the flat
/// `AgentToolProperty` model cannot represent. Schemas are forwarded to
/// OpenRouter verbatim rather than being lossily flattened.
enum JSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    /// Builds a `JSONValue` from an untyped `JSONSerialization` result.
    init(any value: Any) {
        switch value {
        case is NSNull: self = .null
        case let number as NSNumber:
            // NSNumber erases Bool into a number, so recover it via the ObjC type.
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else {
                self = .number(number.doubleValue)
            }
        case let string as String: self = .string(string)
        case let array as [Any]: self = .array(array.map(JSONValue.init(any:)))
        case let dict as [String: Any]:
            self = .object(dict.mapValues(JSONValue.init(any:)))
        default: self = .null
        }
    }

    /// Parses a JSON string into a value, or nil when malformed.
    static func parse(_ text: String) -> JSONValue? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(
                with: data, options: [.fragmentsAllowed]
              ) else { return nil }
        return JSONValue(any: object)
    }

    /// The untyped form, for handing back to `JSONSerialization`.
    var anyValue: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let value): return value
        case .number(let value): return value
        case .string(let value): return value
        case .array(let value): return value.map(\.anyValue)
        case .object(let value): return value.mapValues(\.anyValue)
        }
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var doubleValue: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    /// Compact JSON text for this value.
    var jsonText: String {
        guard JSONSerialization.isValidJSONObject(anyValue),
              let data = try? JSONSerialization.data(
                withJSONObject: anyValue, options: [.sortedKeys, .withoutEscapingSlashes]
              ) else {
            // Fall back for fragments, which isValidJSONObject rejects.
            switch self {
            case .string(let value): return "\"\(value)\""
            case .number(let value): return String(value)
            case .bool(let value): return String(value)
            case .null: return "null"
            default: return "{}"
            }
        }
        return String(decoding: data, as: UTF8.self)
    }
}
