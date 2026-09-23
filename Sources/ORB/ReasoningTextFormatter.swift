import Foundation

/// Display-only repair for providers that put line breaks between tiny reasoning
/// fragments. Never apply to answer text, stored transcripts, or reasoning_details.
enum ReasoningTextFormatter {
    static func display(_ source: String) -> String {
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        let prose = lines.map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !isStructure($0) }
        // Only discard suspicious blank breaks when a whole run is fragmented.
        // Normal paragraphs keep their blank lines, even if they are short.
        let fragmented = prose.count >= 6 && prose.filter { $0.count < 24 }.count * 3 >= prose.count * 2
        var output: [String] = []
        var paragraph = ""
        var pendingBlank = false
        var fence: String?

        func flush() {
            if !paragraph.isEmpty { output.append(paragraph); paragraph = "" }
        }

        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let marker = fence {
                output.append(raw)
                if line.hasPrefix(marker) { fence = nil }
                continue
            }
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                flush()
                if pendingBlank { output.append(""); pendingBlank = false }
                fence = String(line.prefix(3))
                output.append(raw)
                continue
            }
            if line.isEmpty { pendingBlank = true; continue }
            if isStructure(line) || raw.hasPrefix("    ") || raw.hasPrefix("\t") {
                flush()
                if pendingBlank { output.append(""); pendingBlank = false }
                output.append(raw)
                continue
            }
            if pendingBlank {
                let sentenceBoundary = paragraph.last.map { ".!?。！？".contains($0) } == true
                if !fragmented || sentenceBoundary || paragraph.isEmpty {
                    flush()
                    if !output.isEmpty { output.append("") }
                }
                pendingBlank = false
            }
            if paragraph.isEmpty {
                paragraph = line
            } else {
                paragraph += separator(previous: paragraph, next: line) + line
            }
            // Honor intentional Markdown hard breaks rather than flattening them.
            if raw.hasSuffix("  ") || raw.hasSuffix("\\") { flush() }
        }
        flush()
        return output.joined(separator: "\n")
    }

    private static func separator(previous: String, next: String) -> String {
        guard let first = next.first else { return "" }
        if ",;:!?)]}".contains(first) || next == "." || next.hasPrefix(". ") { return "" }
        if previous.last.map({ "([{“".contains($0) }) == true { return "" }
        // Rejoin split relative paths (Test\n/tests), not prose + an absolute
        // path ("inspect\n/usr/bin"). Keep the rule deliberately conservative.
        if first == "/", let token = previous.split(separator: " ").last,
           token.contains("/") || previous.dropLast(token.count).contains(String(token) + "/") { return "" }
        return " "
    }

    private static func isStructure(_ line: String) -> Bool {
        if line.hasPrefix("#") || line.hasPrefix(">") || line.hasPrefix("|")
            || line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ")
            || line.hasPrefix("```") || line.hasPrefix("~~~")
            || ["---", "***", "___"].contains(line) { return true }
        let digits = line.prefix { $0.isNumber }
        let rest = line.dropFirst(digits.count)
        return !digits.isEmpty && (rest.hasPrefix(". ") || rest.hasPrefix(") "))
    }
}
