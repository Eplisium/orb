import Foundation

/// Model catalog descriptions are Markdown (`[per the docs](https://…)`, `**bold**`, `` `code` ``).
/// Compact captions render them as plain text so raw link syntax never leaks into the UI.
enum CatalogDescriptionText {
    static func plain(_ markdown: String) -> String {
        var s = markdown
        // Images first (![alt](url) -> alt), then links ([text](url) -> text).
        s = s.replacingOccurrences(of: #"!\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        // Unmatched "[text" from a description the catalog truncated mid-link.
        s = s.replacingOccurrences(of: #"\[([^\]\(]*)$"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(\*\*|__)(.+?)\1"#, with: "$2", options: .regularExpression)
        s = s.replacingOccurrences(of: #"`([^`]+)`"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?m)^\s{0,3}(#{1,6}\s+|[-*+]\s+)"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
