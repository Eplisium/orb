import Foundation

/// One structured block of OpenRouter's `reasoning_details` array.
///
/// OpenRouter returns chain-of-thought as an ordered array of typed blocks
/// rather than a single string. Some blocks are opaque — provider signatures
/// and encrypted payloads — and must never be rendered as display text, but
/// every block must survive
/// stream decode → domain message → persistence → next request encoding
/// with its exact values, because providers that require reasoning
/// continuity verify those signatures on the following tool turn.
/// (Plan finding F07; docs: reasoning-tokens.md — "pass the reasoning
/// details back unmodified during tool continuation".)
struct ReasoningDetail: Codable, Sendable, Equatable {
    var id: String?
    var type: String?
    var format: String?
    /// Plain chain-of-thought text. Displayable.
    var text: String?
    /// Human-readable summary of the thinking. Displayable.
    var summary: String?
    /// Provider signature over the reasoning. Opaque — never display text.
    var signature: String?
    /// Provider-encrypted reasoning payload. Opaque — never display text.
    var data: String?
    var index: Int?
    /// Unknown extra keys, preserved verbatim so a provider's additional
    /// metadata survives the round trip untouched.
    var extra: [String: JSONValue]

    /// Known fields plus a dynamic key so unknown extra fields re-encode with
    /// their original key names. (The compiler-synthesized
    /// `init?(stringValue:)` only matches case names, which silently dropped
    /// provider-specific keys on the way back out.)
    private enum CodingKeys: CodingKey {
        case id, type, format, text, summary, signature, data, index, extra
        case dynamic(String)

        var stringValue: String {
            switch self {
            case .id: return "id"
            case .type: return "type"
            case .format: return "format"
            case .text: return "text"
            case .summary: return "summary"
            case .signature: return "signature"
            case .data: return "data"
            case .index: return "index"
            case .extra: return "extra"
            case .dynamic(let key): return key
            }
        }

        init?(stringValue: String) {
            switch stringValue {
            case "id": self = .id
            case "type": self = .type
            case "format": self = .format
            case "text": self = .text
            case "summary": self = .summary
            case "signature": self = .signature
            case "data": self = .data
            case "index": self = .index
            case "extra": self = .extra
            default: self = .dynamic(stringValue)
            }
        }

        var intValue: Int? { nil }
        init?(intValue: Int) { return nil }
    }

    init(
        id: String? = nil,
        type: String? = nil,
        format: String? = nil,
        text: String? = nil,
        summary: String? = nil,
        signature: String? = nil,
        data: String? = nil,
        index: Int? = nil,
        extra: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.type = type
        self.format = format
        self.text = text
        self.summary = summary
        self.signature = signature
        self.data = data
        self.index = index
        self.extra = extra
    }

    /// Display-safe text for this block: only human-readable thinking.
    /// Signatures and encrypted payloads are deliberately excluded so an
    /// opaque blob can never surface as reasoning text in the UI.
    var displayText: String? {
        if let text, !text.isEmpty { return text }
        if let summary, !summary.isEmpty { return summary }
        return nil
    }

    /// True when the block carries only opaque payload and nothing that
    /// should ever be shown to a user.
    var isOpaqueOnly: Bool {
        displayText == nil
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Fields may arrive in unexpected shapes on some providers; coerce
        // only matching types so a malformed value degrades to nil (and is
        // preserved verbatim in `extra`) instead of failing the whole stream.
        id = (try? container.decodeIfPresent(String.self, forKey: .id)) ?? nil
        type = (try? container.decodeIfPresent(String.self, forKey: .type)) ?? nil
        format = (try? container.decodeIfPresent(String.self, forKey: .format)) ?? nil
        text = (try? container.decodeIfPresent(String.self, forKey: .text)) ?? nil
        summary = (try? container.decodeIfPresent(String.self, forKey: .summary)) ?? nil
        signature = (try? container.decodeIfPresent(String.self, forKey: .signature)) ?? nil
        data = (try? container.decodeIfPresent(String.self, forKey: .data)) ?? nil
        index = (try? container.decodeIfPresent(Int.self, forKey: .index)) ?? nil

        var extra: [String: JSONValue] = [:]
        if let whole = try? decoder.singleValueContainer().decode(JSONValue.self),
           case .object(let object) = whole {
            let known: Set<String> = ["id", "type", "format", "text", "summary", "signature", "data", "index"]
            extra = object.filter { !known.contains($0.key) }
        }
        self.extra = extra
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(id, forKey: .id)
        try container.encodeIfPresent(type, forKey: .type)
        try container.encodeIfPresent(format, forKey: .format)
        try container.encodeIfPresent(text, forKey: .text)
        try container.encodeIfPresent(summary, forKey: .summary)
        try container.encodeIfPresent(signature, forKey: .signature)
        try container.encodeIfPresent(data, forKey: .data)
        try container.encodeIfPresent(index, forKey: .index)
        // Unknown keys are re-emitted so the block the provider gave us comes
        // back structurally identical on the next request.
        for key in extra.keys.sorted() {
            guard let codingKey = CodingKeys(stringValue: key), let value = extra[key] else { continue }
            try container.encode(value, forKey: codingKey)
        }
    }
}
