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

    /// Link schemes a description may open. Anything else (`file:`,
    /// `javascript:`, custom app schemes) keeps its text but loses the link.
    static let allowedLinkSchemes: Set<String> = ["http", "https", "mailto"]

    /// The detail pane's description: inline Markdown rendered (clickable
    /// links, bold, italics, code) with paragraph breaks kept. Heading
    /// markers, which inline parsing leaves as text, are dropped. Falls back
    /// to plain text if the Markdown can't be parsed.
    static func attributed(_ markdown: String) -> AttributedString {
        let source = markdown.replacingOccurrences(
            of: #"(?m)^\s{0,3}#{1,6}\s+"#, with: "", options: .regularExpression
        )
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        guard var result = try? AttributedString(markdown: source, options: options) else {
            return AttributedString(plain(markdown))
        }
        let links = result.runs.compactMap { run -> (Range<AttributedString.Index>, URL)? in
            run.link.map { (run.range, $0) }
        }
        for (range, url) in links { result[range].link = safeLink(url) }
        return result
    }

    private static let catalogSite = URL(string: "https://openrouter.ai")!

    /// Site-relative links (`/models/openai/gpt-4o`) point at openrouter.ai;
    /// other schemes are dropped.
    static func safeLink(_ url: URL) -> URL? {
        if let scheme = url.scheme?.lowercased() {
            return allowedLinkSchemes.contains(scheme) ? url : nil
        }
        let path = url.relativeString
        guard path.hasPrefix("/"), !path.hasPrefix("//") else { return nil }
        return URL(string: path, relativeTo: catalogSite)?.absoluteURL
    }
}
