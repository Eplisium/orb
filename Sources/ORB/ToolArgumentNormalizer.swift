import Foundation

/// Repairs the tool-argument payloads OpenRouter providers actually emit.
///
/// Providers are inconsistent: some omit `arguments` entirely for zero-parameter
/// tools, some send `null`, some double-encode the object as a JSON string, some
/// wrap it in Markdown fences, and some append trailing bytes after the closing
/// brace. Aborting the whole agent run on any of these throws away every other
/// valid tool call in the same turn, which is what produced
/// "invalid JSON arguments for chatcmpl-tool-…" while nine good calls were on
/// screen. Normalize first; only genuinely unrecoverable payloads fail.
enum ToolArgumentNormalizer {
    /// Returns a canonical JSON object string, or `nil` if the payload cannot be
    /// interpreted as a JSON object at all.
    static func normalize(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // Omitted / explicitly null arguments mean "no parameters".
        if text.isEmpty || text == "null" || text == "{}" { return "{}" }

        text = strippingCodeFence(text)

        // Fast path: already a valid object.
        if let object = objectString(from: text) { return object }

        // Double-encoded: the whole object arrived as a JSON *string*.
        if text.hasPrefix("\""),
           let data = text.data(using: .utf8),
           let inner = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? String,
           let object = objectString(from: strippingCodeFence(inner.trimmingCharacters(in: .whitespacesAndNewlines))) {
            return object
        }

        // Trailing bytes after the object, or several concatenated objects from a
        // provider that reused one tool index. Take the first balanced object.
        if let prefix = firstBalancedObject(in: text), let object = objectString(from: prefix) {
            return object
        }

        return nil
    }

    private static func strippingCodeFence(_ text: String) -> String {
        guard text.hasPrefix("```") else { return text }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        lines.removeFirst()
        if lines.last?.trimmingCharacters(in: .whitespaces).hasPrefix("```") == true { lines.removeLast() }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func objectString(from text: String) -> String? {
        guard let data = text.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else { return nil }
        return text
    }

    /// Scans for the first top-level `{...}` while respecting string literals and
    /// escapes, so braces inside argument values do not end the scan early.
    private static func firstBalancedObject(in text: String) -> String? {
        var depth = 0
        var inString = false
        var escaped = false
        var start: String.Index?

        for index in text.indices {
            let character = text[index]
            if inString {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { inString = false }
                continue
            }
            switch character {
            case "\"": inString = true
            case "{":
                if depth == 0 { start = index }
                depth += 1
            case "}":
                guard depth > 0 else { return nil }
                depth -= 1
                if depth == 0, let start {
                    return String(text[start...index])
                }
            default: break
            }
        }
        return nil
    }
}
