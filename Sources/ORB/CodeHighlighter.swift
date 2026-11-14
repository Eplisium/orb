import Foundation
import SwiftUI
import os

// MARK: - Dependency-free syntax highlighting for code blocks
//
// A small single-pass scanner per language family: keywords, built-in and
// capitalised type names, string/char literals, line and block comments,
// and numbers. It is deliberately lexical (no grammar), which is what every
// chat client does: fast, predictable, and never wrong in a way that hides
// text. Only closed code blocks are highlighted; the streaming open block
// stays plain so colours do not flicker as tokens arrive.

/// What a span of source is, for colouring.
enum CodeTokenKind: String, Equatable, Sendable, CaseIterable {
    case plain, keyword, type, string, comment, number
}

/// A coloured span, in UTF-16 offsets into the source.
struct CodeToken: Equatable, Sendable {
    let kind: CodeTokenKind
    let range: Range<Int>
}

/// Colours for each token kind, built from DesignSystem palette pairs so they
/// adapt to light and dark appearance and meet text contrast on every
/// surface (asserted in `W1ChatUICodeHighlighterTests`).
enum CodeSyntaxPalette {
    static func pair(for kind: CodeTokenKind) -> ORBColorPair? {
        switch kind {
        case .plain: return nil
        case .keyword: return AccentChoice.pink.linkPalette
        case .type: return AccentChoice.teal.linkPalette
        case .string: return AccentChoice.orange.linkPalette
        case .comment: return ORBPalette.textTertiary
        case .number: return ORBPalette.info
        }
    }

    /// Resolved once: `Color(light:dark:)` builds a dynamic NSColor, so the
    /// cached attributed strings still follow appearance changes.
    private static let colors: [CodeTokenKind: Color] = {
        var out: [CodeTokenKind: Color] = [:]
        for kind in CodeTokenKind.allCases { if let pair = pair(for: kind) { out[kind] = pair.color } }
        return out
    }()

    static func color(for kind: CodeTokenKind) -> Color? { colors[kind] }
}

/// Lexical rules for one language family.
struct CodeLanguageSpec: Sendable {
    var name: String
    var keywords: Set<String> = []
    var types: Set<String> = []
    var lineComments: [String] = []
    var blockComment: (open: String, close: String)? = nil
    var quotes: Set<Character> = ["\"", "'"]
    /// `"""` / `'''` multi-line strings (Swift, Python).
    var tripleQuotes = false
    /// Identifiers starting with an uppercase letter colour as types.
    var capitalizedAreTypes = false
    var caseInsensitive = false
    /// `#`-style line comments only start at line start or after whitespace
    /// (shell `$#`, YAML `a#b`).
    var hashCommentNeedsBoundary = false
    /// `@Attribute` / `@annotation` colour as keywords.
    var atAttributes = false
    /// `$var` / `${var}` colour as types (shell, PHP).
    var dollarVariables = false
    /// The identifier right after `<` or `</` is a tag name (HTML/XML).
    var markupTags = false
    /// `key:` at the start of a line colours as a type (YAML).
    var yamlKeys = false
    /// A quoted string followed by `:` is an object key (JSON).
    var stringKeysBeforeColon = false
    /// Extra identifier characters (`$` in JS, `-` in CSS).
    var identifierExtras: Set<Character> = ["_"]
}

enum CodeHighlighter {
    /// Blocks longer than this (UTF-16 units) render plain: tokenising a huge
    /// paste is not worth a long main-thread stall.
    static let maxHighlightedLength = 80_000

    // MARK: Public API

    /// The highlighted source, or nil when the language is unknown (render
    /// plain). Cached by language plus a content hash.
    static func highlighted(_ source: String, language: String?) -> AttributedString? {
        guard let spec = spec(for: language), !source.isEmpty,
              source.utf16.count <= maxHighlightedLength else { return nil }
        let key = cacheKey(source: source, language: spec.name)
        if let box = cache.object(forKey: key), box.source == source {
            stats.withLock { $0.hits += 1 }
            return box.value
        }
        let value = attributed(source, tokens: tokens(in: source, spec: spec))
        stats.withLock { $0.tokenizations += 1 }
        cache.setObject(Box(source: source, value: value), forKey: key, cost: source.utf8.count)
        return value
    }

    /// Normalises a fence info string (`"Swift title=x"`, `"c++"`, `"tsx"`)
    /// to a language family, or nil when unsupported.
    static func spec(for language: String?) -> CodeLanguageSpec? {
        guard let raw = language?.split(whereSeparator: { $0 == " " || $0 == "{" || $0 == "," }).first else { return nil }
        let name = raw.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard let family = aliases[name] else { return nil }
        return specs[family]
    }

    /// The cached highlight for this exact source, without tokenizing.
    static func cachedValue(_ source: String, language: String?) -> AttributedString? {
        guard let spec = spec(for: language) else { return nil }
        guard let box = cache.object(forKey: cacheKey(source: source, language: spec.name)), box.source == source else { return nil }
        return box.value
    }

    /// Cache counters, for tests and diagnostics.
    struct Stats: Equatable, Sendable { var tokenizations = 0; var hits = 0 }
    static var currentStats: Stats { stats.withLock { $0 } }

    // MARK: Attributed output

    static func attributed(_ source: String, tokens: [CodeToken]) -> AttributedString {
        var result = AttributedString()
        let utf16 = source.utf16
        var cursor = 0
        var cursorIndex = source.startIndex
        for token in tokens where token.kind != .plain {
            if token.range.lowerBound > cursor {
                let start = cursorIndex
                cursorIndex = utf16.index(cursorIndex, offsetBy: token.range.lowerBound - cursor)
                result.append(AttributedString(String(source.unicodeScalars[start..<cursorIndex])))
            }
            let start = cursorIndex
            cursorIndex = utf16.index(cursorIndex, offsetBy: token.range.count)
            var piece = AttributedString(String(source.unicodeScalars[start..<cursorIndex]))
            if let color = CodeSyntaxPalette.color(for: token.kind) { piece.foregroundColor = color }
            result.append(piece)
            cursor = token.range.upperBound
        }
        if cursorIndex < source.endIndex { result.append(AttributedString(String(source.unicodeScalars[cursorIndex...]))) }
        return result
    }

    // MARK: Tokenizer

    /// Coloured spans in source order; gaps are plain text.
    static func tokens(in source: String, spec: CodeLanguageSpec) -> [CodeToken] {
        let chars = Array(source.utf16)
        let n = chars.count
        var out: [CodeToken] = []
        var i = 0
        var lineStart = true
        var previousSignificant: UInt16 = 0 // last non-space code unit
        var insideTag = false // markup: between `<` and `>`

        func at(_ k: Int) -> UInt16 { k < n ? chars[k] : 0 }
        func matches(_ text: String, _ k: Int) -> Bool {
            var j = k
            for unit in text.utf16 {
                guard j < n, chars[j] == unit else { return false }
                j += 1
            }
            return true
        }
        func emit(_ kind: CodeTokenKind, _ start: Int, _ end: Int) {
            guard end > start else { return }
            out.append(CodeToken(kind: kind, range: start..<end))
        }

        let extras = Set(spec.identifierExtras.compactMap { $0.utf16.first })
        // `-`, `:` and `.` may continue an identifier (`font-size`, `xlink:href`)
        // but never start one, so `-5` stays a number and `- key:` a list item.
        let startExtras = extras.subtracting([45, 58, 46])
        func isLetter(_ c: UInt16) -> Bool { (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c > 127 }
        func isIdentStart(_ c: UInt16) -> Bool { isLetter(c) || startExtras.contains(c) }
        func isIdent(_ c: UInt16) -> Bool { isLetter(c) || extras.contains(c) || isDigit(c) }
        func isDigit(_ c: UInt16) -> Bool { c >= 48 && c <= 57 }
        func isSpace(_ c: UInt16) -> Bool { c == 32 || c == 9 }

        while i < n {
            let c = chars[i]
            if c == 10 { lineStart = true; i += 1; continue }
            if isSpace(c) || c == 13 { i += 1; continue }
            let atLineStart = lineStart
            lineStart = false

            // Block comments.
            if let block = spec.blockComment, matches(block.open, i) {
                let start = i
                i += block.open.utf16.count
                while i < n, !matches(block.close, i) { i += 1 }
                i = min(n, i + block.close.utf16.count)
                emit(.comment, start, i)
                previousSignificant = 0
                continue
            }
            // Line comments.
            if let marker = spec.lineComments.first(where: { matches($0, i) }) {
                let boundaryOK = marker != "#" || !spec.hashCommentNeedsBoundary || atLineStart || isSpace(at(i - 1))
                if boundaryOK {
                    let start = i
                    while i < n, chars[i] != 10 { i += 1 }
                    emit(.comment, start, i)
                    continue
                }
            }
            // Strings.
            if let scalar = Unicode.Scalar(c), spec.quotes.contains(Character(scalar)), !spec.markupTags || insideTag {
                let start = i
                if spec.tripleQuotes, at(i + 1) == c, at(i + 2) == c {
                    i += 3
                    while i < n, !(chars[i] == c && at(i + 1) == c && at(i + 2) == c) {
                        i += chars[i] == 92 ? 2 : 1
                    }
                    i = min(n, i + 3)
                } else {
                    i += 1
                    let multiline = c == 96 // backtick template / raw strings
                    while i < n, chars[i] != c {
                        if chars[i] == 10, !multiline { break }
                        i += chars[i] == 92 ? 2 : 1
                    }
                    i = min(n, i + (i < n && chars[i] == c ? 1 : 0))
                }
                let isKey = spec.stringKeysBeforeColon && nextNonSpace(chars, from: i) == 58
                emit(isKey ? .type : .string, start, min(i, n))
                previousSignificant = c
                continue
            }
            // Numbers (not part of an identifier).
            if isDigit(c) || (c == 46 && isDigit(at(i + 1)) && !isIdent(previousSignificant)) {
                let start = i
                i += 1
                while i < n {
                    let d = chars[i]
                    if isIdent(d) { i += 1; continue }
                    if d == 46, isDigit(at(i + 1)) { i += 1; continue }
                    if (d == 43 || d == 45), (chars[i - 1] == 101 || chars[i - 1] == 69), isDigit(at(i + 1)) { i += 1; continue }
                    break
                }
                emit(.number, start, i)
                previousSignificant = 48
                continue
            }
            // Attributes / annotations.
            if spec.atAttributes, c == 64, isIdentStart(at(i + 1)) {
                let start = i
                i += 1
                while i < n, isIdent(chars[i]) { i += 1 }
                emit(.keyword, start, i)
                previousSignificant = 97
                continue
            }
            // Shell / PHP variables.
            if spec.dollarVariables, c == 36 {
                let start = i
                if at(i + 1) == 123 { // ${...}
                    i += 2
                    while i < n, chars[i] != 125, chars[i] != 10 { i += 1 }
                    i = min(n, i + 1)
                    emit(.type, start, i)
                    continue
                }
                if isIdentStart(at(i + 1)) || isDigit(at(i + 1)) {
                    i += 1
                    while i < n, isIdent(chars[i]) { i += 1 }
                    emit(.type, start, i)
                    continue
                }
            }
            // Identifiers and keywords.
            if isIdentStart(c) {
                let start = i
                i += 1
                while i < n, isIdent(chars[i]) { i += 1 }
                let word = String(decoding: chars[start..<i], as: UTF16.self)
                let lookup = spec.caseInsensitive ? word.lowercased() : word
                if spec.markupTags, previousSignificant == 60 || (previousSignificant == 47 && start >= 2 && chars[start - 2] == 60) {
                    emit(.keyword, start, i)
                } else if spec.yamlKeys, atLineStart || isListDash(chars, before: start), nextNonSpace(chars, from: i) == 58 {
                    emit(.type, start, i)
                } else if spec.keywords.contains(lookup) {
                    emit(.keyword, start, i)
                } else if spec.types.contains(lookup) {
                    emit(.type, start, i)
                } else if spec.capitalizedAreTypes, let first = word.unicodeScalars.first,
                          CharacterSet.uppercaseLetters.contains(first) {
                    emit(.type, start, i)
                }
                previousSignificant = 97
                continue
            }
            if c == 60 { insideTag = true } else if c == 62 { insideTag = false }
            previousSignificant = c
            i += 1
        }
        return out
    }

    private static func nextNonSpace(_ chars: [UInt16], from index: Int) -> UInt16 {
        var k = index
        while k < chars.count, chars[k] == 32 || chars[k] == 9 { k += 1 }
        return k < chars.count ? chars[k] : 0
    }

    /// True when only `- ` and indentation precede `index` on its line.
    private static func isListDash(_ chars: [UInt16], before index: Int) -> Bool {
        var k = index - 1
        var sawDash = false
        while k >= 0, chars[k] != 10 {
            let c = chars[k]
            if c == 45 { if sawDash { return false }; sawDash = true } else if c != 32 && c != 9 { return false }
            k -= 1
        }
        return sawDash
    }

    // MARK: Cache

    private final class Box {
        let source: String
        let value: AttributedString
        init(source: String, value: AttributedString) { self.source = source; self.value = value }
    }

    nonisolated(unsafe) private static let cache: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.totalCostLimit = 4_000_000
        return cache
    }()

    private static let stats = OSAllocatedUnfairLock(initialState: Stats())

    private static func cacheKey(source: String, language: String) -> NSString {
        var hasher = Hasher()
        hasher.combine(source)
        return "\(language):\(source.utf16.count):\(hasher.finalize())" as NSString
    }

    // MARK: Languages

    private static let aliases: [String: String] = {
        var map: [String: String] = [:]
        let groups: [String: [String]] = [
            "swift": ["swift"],
            "python": ["python", "py", "python3", "py3", "gyp"],
            "javascript": ["javascript", "js", "jsx", "mjs", "cjs", "node", "typescript", "ts", "tsx", "mts", "cts"],
            "json": ["json", "jsonc", "json5", "geojson"],
            "shell": ["bash", "sh", "shell", "zsh", "console", "shellscript", "shell-session", "fish", "ksh"],
            "go": ["go", "golang"],
            "rust": ["rust", "rs"],
            "c": ["c", "h", "cpp", "c++", "cc", "cxx", "hpp", "hh", "objc", "objective-c", "objectivec", "m", "mm",
                  "java", "kotlin", "kt", "kts", "cs", "csharp", "c#", "dart", "scala"],
            "markup": ["html", "htm", "xml", "xhtml", "svg", "plist", "vue", "xaml"],
            "css": ["css", "scss", "less", "sass"],
            "sql": ["sql", "postgres", "postgresql", "psql", "mysql", "sqlite", "plsql", "tsql"],
            "yaml": ["yaml", "yml"],
            "ruby": ["ruby", "rb"],
            "php": ["php"],
            "toml": ["toml", "ini", "cfg", "conf"],
        ]
        for (family, names) in groups { for name in names { map[name] = family } }
        return map
    }()

    private static let specs: [String: CodeLanguageSpec] = [
        "swift": CodeLanguageSpec(
            name: "swift",
            keywords: ["associatedtype", "class", "deinit", "enum", "extension", "fileprivate", "func", "import", "init",
                       "inout", "internal", "let", "open", "operator", "private", "precedencegroup", "protocol", "public",
                       "rethrows", "static", "struct", "subscript", "typealias", "var", "break", "case", "catch", "continue",
                       "default", "defer", "do", "else", "fallthrough", "for", "guard", "if", "in", "repeat", "return",
                       "throw", "switch", "where", "while", "as", "is", "nil", "self", "Self", "super", "throws", "true",
                       "false", "try", "async", "await", "actor", "some", "any", "mutating", "nonmutating", "override",
                       "final", "lazy", "weak", "unowned", "convenience", "required", "dynamic", "indirect", "get", "set",
                       "willSet", "didSet", "nonisolated", "isolated", "consuming", "borrowing", "macro", "package"],
            types: [],
            lineComments: ["//"], blockComment: ("/*", "*/"),
            quotes: ["\""], tripleQuotes: true, capitalizedAreTypes: true, atAttributes: true
        ),
        "python": CodeLanguageSpec(
            name: "python",
            keywords: ["False", "None", "True", "and", "as", "assert", "async", "await", "break", "class", "continue",
                       "def", "del", "elif", "else", "except", "finally", "for", "from", "global", "if", "import", "in",
                       "is", "lambda", "nonlocal", "not", "or", "pass", "raise", "return", "try", "while", "with",
                       "yield", "match", "case", "self", "cls"],
            types: ["int", "str", "float", "bool", "list", "dict", "set", "tuple", "bytes", "object", "type", "print",
                    "len", "range", "open", "super", "isinstance", "enumerate", "zip", "map", "filter"],
            lineComments: ["#"], quotes: ["\"", "'"], tripleQuotes: true, capitalizedAreTypes: true, atAttributes: true
        ),
        "javascript": CodeLanguageSpec(
            name: "javascript",
            keywords: ["abstract", "as", "async", "await", "break", "case", "catch", "class", "const", "continue",
                       "debugger", "declare", "default", "delete", "do", "else", "enum", "export", "extends", "false",
                       "finally", "for", "from", "function", "get", "if", "implements", "import", "in", "instanceof",
                       "interface", "keyof", "let", "namespace", "new", "null", "of", "private", "protected", "public",
                       "readonly", "return", "satisfies", "set", "static", "super", "switch", "this", "throw", "true",
                       "try", "type", "typeof", "undefined", "var", "void", "while", "with", "yield"],
            types: ["string", "number", "boolean", "any", "unknown", "never", "object", "symbol", "bigint", "console",
                    "window", "document", "Promise", "Array", "Object", "Map", "Set", "JSON", "Math"],
            lineComments: ["//"], blockComment: ("/*", "*/"),
            quotes: ["\"", "'", "`"], capitalizedAreTypes: true, atAttributes: true, identifierExtras: ["_", "$"]
        ),
        "json": CodeLanguageSpec(
            name: "json", keywords: ["true", "false", "null"],
            lineComments: ["//"], blockComment: ("/*", "*/"), quotes: ["\""], stringKeysBeforeColon: true
        ),
        "shell": CodeLanguageSpec(
            name: "shell",
            keywords: ["if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done", "case", "esac", "in",
                       "function", "return", "export", "local", "readonly", "declare", "unset", "source", "alias",
                       "set", "shift", "exit", "break", "continue", "select", "time", "trap", "eval", "exec"],
            types: ["echo", "printf", "cd", "ls", "grep", "sed", "awk", "cat", "curl", "git", "sudo", "brew", "npm",
                    "swift", "make", "docker", "python3", "pip", "mkdir", "rm", "cp", "mv", "chmod", "test", "read"],
            lineComments: ["#"], quotes: ["\"", "'", "`"], hashCommentNeedsBoundary: true,
            dollarVariables: true, identifierExtras: ["_"]
        ),
        "go": CodeLanguageSpec(
            name: "go",
            keywords: ["break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough", "for",
                       "func", "go", "goto", "if", "import", "interface", "map", "package", "range", "return", "select",
                       "struct", "switch", "type", "var", "nil", "true", "false", "iota"],
            types: ["bool", "byte", "complex64", "complex128", "error", "float32", "float64", "int", "int8", "int16",
                    "int32", "int64", "rune", "string", "uint", "uint8", "uint16", "uint32", "uint64", "uintptr",
                    "any", "make", "new", "len", "cap", "append", "panic", "recover"],
            lineComments: ["//"], blockComment: ("/*", "*/"), quotes: ["\"", "'", "`"], capitalizedAreTypes: true
        ),
        "rust": CodeLanguageSpec(
            name: "rust",
            keywords: ["as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum", "extern",
                       "false", "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod", "move", "mut", "pub",
                       "ref", "return", "self", "Self", "static", "struct", "super", "trait", "true", "type", "unsafe",
                       "use", "where", "while", "macro_rules"],
            types: ["i8", "i16", "i32", "i64", "i128", "isize", "u8", "u16", "u32", "u64", "u128", "usize", "f32",
                    "f64", "bool", "char", "str", "String", "Vec", "Option", "Result", "Box", "Some", "None", "Ok", "Err"],
            // `'` is a lifetime as often as a char literal; leave it plain.
            lineComments: ["//"], blockComment: ("/*", "*/"), quotes: ["\""], capitalizedAreTypes: true
        ),
        "c": CodeLanguageSpec(
            name: "c",
            keywords: ["auto", "break", "case", "catch", "class", "const", "constexpr", "continue", "default", "delete",
                       "do", "else", "enum", "explicit", "extern", "false", "final", "finally", "for", "friend", "goto",
                       "if", "import", "inline", "interface", "namespace", "new", "noexcept", "nullptr", "null",
                       "operator", "override", "package", "private", "protected", "public", "register", "return",
                       "sizeof", "static", "struct", "super", "switch", "template", "this", "throw", "throws", "true",
                       "try", "typedef", "typename", "union", "using", "virtual", "volatile", "while", "extends",
                       "implements", "instanceof", "abstract", "synchronized", "transient", "fun", "val", "var",
                       "when", "object", "companion", "data", "sealed", "is", "in", "out", "suspend", "lateinit",
                       "nil", "YES", "NO", "self", "async", "await", "readonly", "record", "yield", "let"],
            types: ["void", "int", "char", "short", "long", "float", "double", "signed", "unsigned", "bool", "boolean",
                    "byte", "size_t", "int8_t", "int16_t", "int32_t", "int64_t", "uint8_t", "uint16_t", "uint32_t",
                    "uint64_t", "std", "string", "id", "instancetype", "BOOL", "Unit", "Any"],
            lineComments: ["//"], blockComment: ("/*", "*/"), quotes: ["\"", "'"],
            capitalizedAreTypes: true, atAttributes: true
        ),
        "markup": CodeLanguageSpec(
            name: "markup", blockComment: ("<!--", "-->"), quotes: ["\"", "'"],
            markupTags: true, identifierExtras: ["_", "-", ":"]
        ),
        "css": CodeLanguageSpec(
            name: "css",
            keywords: ["important", "media", "import", "keyframes", "supports", "font-face", "from", "to", "and",
                       "not", "only", "root", "hover", "focus", "active", "before", "after", "inherit", "initial",
                       "unset", "none", "auto"],
            lineComments: [], blockComment: ("/*", "*/"), quotes: ["\"", "'"], identifierExtras: ["_", "-"]
        ),
        "sql": CodeLanguageSpec(
            name: "sql",
            keywords: ["select", "from", "where", "and", "or", "not", "insert", "into", "values", "update", "set",
                       "delete", "create", "table", "index", "view", "drop", "alter", "add", "column", "primary", "key",
                       "foreign", "references", "join", "inner", "left", "right", "outer", "full", "on", "as", "group",
                       "by", "order", "having", "limit", "offset", "union", "all", "distinct", "null", "is", "in",
                       "like", "between", "exists", "case", "when", "then", "else", "end", "default", "unique",
                       "check", "constraint", "if", "begin", "commit", "rollback", "transaction", "with", "returning",
                       "asc", "desc", "true", "false", "cascade", "pragma", "trigger", "replace", "conflict", "do",
                       "nothing", "count", "sum", "avg", "min", "max", "coalesce"],
            types: ["int", "integer", "bigint", "smallint", "text", "varchar", "char", "real", "float", "double",
                    "numeric", "decimal", "boolean", "bool", "date", "timestamp", "timestamptz", "blob", "json",
                    "jsonb", "uuid", "serial"],
            lineComments: ["--"], blockComment: ("/*", "*/"), quotes: ["'", "\"", "`"], caseInsensitive: true
        ),
        "yaml": CodeLanguageSpec(
            name: "yaml",
            keywords: ["true", "false", "null", "yes", "no", "on", "off", "~"],
            lineComments: ["#"], quotes: ["\"", "'"], hashCommentNeedsBoundary: true,
            yamlKeys: true, stringKeysBeforeColon: true, identifierExtras: ["_", "-", "."]
        ),
        "toml": CodeLanguageSpec(
            name: "toml", keywords: ["true", "false"],
            lineComments: ["#", ";"], quotes: ["\"", "'"], tripleQuotes: true,
            identifierExtras: ["_", "-"]
        ),
        "ruby": CodeLanguageSpec(
            name: "ruby",
            keywords: ["alias", "and", "begin", "break", "case", "class", "def", "defined?", "do", "else", "elsif",
                       "end", "ensure", "false", "for", "if", "in", "module", "next", "nil", "not", "or", "redo",
                       "rescue", "retry", "return", "self", "super", "then", "true", "undef", "unless", "until",
                       "when", "while", "yield", "require", "attr_accessor", "attr_reader", "puts"],
            lineComments: ["#"], quotes: ["\"", "'", "`"], capitalizedAreTypes: true
        ),
        "php": CodeLanguageSpec(
            name: "php",
            keywords: ["abstract", "and", "array", "as", "break", "case", "catch", "class", "clone", "const",
                       "continue", "declare", "default", "do", "echo", "else", "elseif", "empty", "enum", "extends",
                       "false", "final", "finally", "fn", "for", "foreach", "function", "global", "if", "implements",
                       "include", "instanceof", "interface", "isset", "match", "namespace", "new", "null", "or",
                       "print", "private", "protected", "public", "readonly", "require", "require_once", "return",
                       "static", "switch", "throw", "trait", "true", "try", "unset", "use", "while", "yield"],
            types: ["int", "string", "bool", "float", "void", "mixed", "self", "parent"],
            lineComments: ["//", "#"], blockComment: ("/*", "*/"), quotes: ["\"", "'"],
            capitalizedAreTypes: true, dollarVariables: true
        ),
    ]
}

// MARK: - Horizontal scroll affordance

/// Whether a horizontally scrolling code block has hidden content on either
/// side. Scroll bars hide themselves on trackpad Macs, so long lines need a
/// visible hint that they continue.
struct CodeScrollAffordance: Equatable {
    var contentMinX: CGFloat = 0
    var contentWidth: CGFloat = 0
    var viewportWidth: CGFloat = 0

    /// Points of slack before an edge counts as clipped (sub-pixel layout).
    static let tolerance: CGFloat = 1

    var overflows: Bool { contentWidth > viewportWidth + Self.tolerance }
    var showsLeadingFade: Bool { overflows && contentMinX < -Self.tolerance }
    var showsTrailingFade: Bool { overflows && contentMinX + contentWidth > viewportWidth + Self.tolerance }
}
