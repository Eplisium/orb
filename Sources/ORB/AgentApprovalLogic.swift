import AppKit
import SwiftUI

// MARK: - Approval sheet keys (AGENT-1)

/// Keyboard policy for the approval sheet. Plain Return must never approve:
/// the user is often still typing a follow-up in the composer when the sheet
/// takes key focus, and the next Return would run a command they never read.
/// Only an explicit click or the deliberate ⌘Return approves.
enum ApprovalSheetKeys {
    enum Key: Equatable { case returnKey, escape, other }

    /// What a key press in the sheet does. Nil = nothing.
    static func decision(for key: Key, command: Bool) -> ApprovalCoordinator.Decision? {
        switch key {
        case .escape: return .denied
        case .returnKey: return command ? .approved : nil
        case .other: return nil
        }
    }

    /// The SwiftUI shortcut bound to each button. No button owns plain
    /// Return (`.defaultAction`), so it cannot click anything.
    static func shortcut(for decision: ApprovalCoordinator.Decision) -> KeyboardShortcut? {
        switch decision {
        case .denied: return .cancelAction
        case .approved: return KeyboardShortcut(.return, modifiers: .command)
        case .approvedForSession: return nil
        }
    }

    /// Approve buttons stay disabled briefly after the sheet appears, so a
    /// keystroke already in flight cannot land on them.
    static let armingDelay: Duration = .milliseconds(600)

    static func isArmed(elapsed: Duration) -> Bool { elapsed >= armingDelay }
}

// MARK: - Tool-aware approval details (AGENT-5, AGENT-6)

/// Every security-relevant argument of a risky call, labelled, in the order
/// the user should read them. `ApprovalPresentation` (shared chrome) supplies
/// the risk styling; this adds the fields it cannot know about.
struct ApprovalDetails: Equatable {
    struct Field: Equatable {
        let label: String
        let value: String
        /// Monospaced, scrollable block (commands, scripts, diffs).
        var isBlock = false
    }

    let title: String
    let symbol: String
    let isHighRisk: Bool
    let fields: [Field]
    /// Text for the "allow for this run" button.
    let sessionButtonTitle: String
    let sessionButtonHelp: String

    static func make(_ request: ApprovalCoordinator.Request, workspace: String? = nil) -> ApprovalDetails {
        let base = ApprovalPresentation.make(toolName: request.toolName, server: request.server, summary: request.summary)
        let arguments = JSONValue.parse(request.summary.trimmingCharacters(in: .whitespacesAndNewlines))?.objectValue ?? [:]
        func value(_ key: String) -> String? {
            guard let raw = arguments[key] else { return nil }
            if let text = raw.stringValue { return text.isEmpty ? nil : text }
            if case .null = raw { return nil }
            return raw.jsonText
        }
        var fields: [Field] = []
        if let reason = request.reason { fields.append(.init(label: "Why ORB is asking", value: reason)) }

        var title = base.title
        var symbol = base.symbol
        var high = base.risk == .high
        switch request.toolName {
        case "run_command":
            if let command = value("command") { fields.append(.init(label: "Command", value: command, isBlock: true)) }
            let directory = request.resolvedPath ?? value("working_directory") ?? workspace ?? "the workspace"
            fields.append(.init(label: "Runs in", value: directory))
            if let timeout = value("timeout_seconds") { fields.append(.init(label: "Time limit", value: "\(timeout) s")) }
        case "open_application":
            fields.append(.init(label: "Application", value: value("name") ?? value("application") ?? "(none given)"))
        case "open_url":
            fields.append(.init(label: "URL", value: value("url") ?? "(none given)"))
        case "run_applescript":
            fields.append(.init(label: "Script", value: value("script") ?? "", isBlock: true))
        case "computer_action":
            let action = value("action") ?? "(none)"
            fields.append(.init(label: "Action", value: action))
            switch action.lowercased() {
            case "type": fields.append(.init(label: "Text to type", value: value("text") ?? "", isBlock: true))
            case "key": fields.append(.init(label: "Key", value: value("text") ?? ""))
            case "click": fields.append(.init(label: "Position", value: "x \(value("x") ?? "?"), y \(value("y") ?? "?")"))
            default: break
            }
        case "write_file", "speak_text", "generate_image", "capture_screen":
            title = request.toolName == "write_file" ? "Let the agent write this file?" : "Let the agent save a file here?"
            symbol = "doc.badge.ellipsis"
            high = true
            fields.append(.init(label: "File", value: request.resolvedPath ?? value("path") ?? "(temporary file)"))
            if request.toolName == "write_file", let content = value("content") {
                fields.append(.init(label: "Size", value: ByteCountFormatter.string(fromByteCount: Int64(content.utf8.count), countStyle: .file)
                                    + " · \(UnifiedDiff.lines(content).count) lines"))
            }
            if let prompt = value("prompt") ?? value("text") { fields.append(.init(label: "Content", value: prompt, isBlock: true)) }
            if let preview = request.preview { fields.append(.init(label: "Changes", value: preview, isBlock: true)) }
        case "read_file", "list_directory", "search_files", "view_image":
            title = "Let the agent read a private location?"
            symbol = "lock.doc"
            high = true
            fields.append(.init(label: "Path", value: request.resolvedPath ?? value("path") ?? ""))
            if let query = value("query") { fields.append(.init(label: "Search for", value: query)) }
            if let question = value("question") { fields.append(.init(label: "Question", value: question)) }
        default:
            if let primary = base.primary, let label = base.primaryLabel {
                fields.append(.init(label: label, value: primary, isBlock: label == "Command" || label == "Script"))
            }
            if let server = request.server { fields.append(.init(label: "MCP server", value: server)) }
        }

        let scope = request.scopeLabel ?? "every \(request.toolName) call"
        return ApprovalDetails(
            title: title, symbol: symbol, isHighRisk: high, fields: fields,
            sessionButtonTitle: "Allow \(scope) this run",
            sessionButtonHelp: "Approves \(scope) without asking again until this run ends. Anything else still asks."
        )
    }
}

// MARK: - Line diff (AGENT-6)

/// A small, dependency-free line diff for write previews and results.
enum UnifiedDiff {
    struct Result: Equatable {
        let added: Int
        let removed: Int
        /// Unified-style hunks (`@@`, ` `, `+`, `-`), capped with a notice.
        let text: String
    }

    static func lines(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    private enum Op: Equatable { case same(String), add(String), remove(String) }

    /// Above this many cells the middle section is shown as replaced
    /// wholesale instead of running the quadratic LCS.
    static let lcsCellLimit = 2_000_000

    static func make(old: String, new: String, context: Int = 2, maxLines: Int = 120) -> Result {
        let a = lines(old), b = lines(new)
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix,
              a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        let midA = Array(a[prefix..<(a.count - suffix)])
        let midB = Array(b[prefix..<(b.count - suffix)])

        var ops: [Op] = a[0..<prefix].map { .same($0) }
        if midA.count * midB.count <= lcsCellLimit {
            ops += lcs(midA, midB)
        } else {
            ops += midA.map { .remove($0) } + midB.map { .add($0) }
        }
        ops += a[(a.count - suffix)...].map { .same($0) }

        let added = ops.filter { if case .add = $0 { return true }; return false }.count
        let removed = ops.filter { if case .remove = $0 { return true }; return false }.count
        guard added + removed > 0 else { return Result(added: 0, removed: 0, text: "") }

        // Group changes into hunks with `context` unchanged lines around them.
        var keep = [Bool](repeating: false, count: ops.count)
        for (index, op) in ops.enumerated() {
            if case .same = op { continue }
            for j in max(0, index - context)...min(ops.count - 1, index + context) { keep[j] = true }
        }
        var output: [String] = []
        var oldLine = 1, newLine = 1
        var index = 0
        while index < ops.count {
            guard keep[index] else {
                if case .same = ops[index] { oldLine += 1; newLine += 1 }
                index += 1
                continue
            }
            var end = index
            while end < ops.count, keep[end] { end += 1 }
            let slice = ops[index..<end]
            let oldCount = slice.filter { if case .add = $0 { return false }; return true }.count
            let newCount = slice.filter { if case .remove = $0 { return false }; return true }.count
            output.append("@@ -\(oldLine),\(oldCount) +\(newLine),\(newCount) @@")
            for op in slice {
                switch op {
                case .same(let line): output.append(" " + line); oldLine += 1; newLine += 1
                case .remove(let line): output.append("-" + line); oldLine += 1
                case .add(let line): output.append("+" + line); newLine += 1
                }
            }
            index = end
        }
        var text: String
        if output.count > maxLines {
            text = output.prefix(maxLines).joined(separator: "\n")
                + "\n… \(output.count - maxLines) more diff lines not shown …"
        } else {
            text = output.joined(separator: "\n")
        }
        if text.count > 12_000 { text = String(text.prefix(12_000)) + "\n… diff truncated …" }
        return Result(added: added, removed: removed, text: text)
    }

    private static func lcs(_ a: [String], _ b: [String]) -> [Op] {
        let n = a.count, m = b.count
        guard n > 0 else { return b.map { .add($0) } }
        guard m > 0 else { return a.map { .remove($0) } }
        var table = [Int](repeating: 0, count: (n + 1) * (m + 1))
        let width = m + 1
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                table[i * width + j] = a[i] == b[j]
                    ? table[(i + 1) * width + j + 1] + 1
                    : max(table[(i + 1) * width + j], table[i * width + j + 1])
            }
        }
        var ops: [Op] = []
        var i = 0, j = 0
        while i < n, j < m {
            if a[i] == b[j] { ops.append(.same(a[i])); i += 1; j += 1 }
            else if table[(i + 1) * width + j] >= table[i * width + j + 1] { ops.append(.remove(a[i])); i += 1 }
            else { ops.append(.add(b[j])); j += 1 }
        }
        while i < n { ops.append(.remove(a[i])); i += 1 }
        while j < m { ops.append(.add(b[j])); j += 1 }
        return ops
    }

    /// Preview of what writing `content` to `url` would change, or nil when
    /// the existing file is unreadable/too large to compare.
    static func preview(writing content: String, to url: URL) -> (summary: String, diff: String)? {
        let existing: String?
        if FileManager.default.fileExists(atPath: url.path) {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size <= 2_000_000, let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            existing = text
        } else {
            existing = nil
        }
        let newLines = lines(content).count
        guard let existing else {
            return ("New file · \(newLines) line\(newLines == 1 ? "" : "s")", "")
        }
        let diff = make(old: existing, new: content)
        if diff.added + diff.removed == 0 { return ("Overwrites with identical content", "") }
        return ("Overwrites existing file · +\(diff.added) −\(diff.removed) lines", diff.text)
    }
}

// MARK: - Approval attention (AGENT-3)

/// App-wide view of approvals waiting for the user, so the sidebar can badge
/// the Agent item and a notification can reach someone in another app. The
/// sheet itself still lives with the run's own presenter.
@MainActor
final class ApprovalAttention: ObservableObject {
    static let shared = ApprovalAttention()

    @Published private(set) var pending: [UUID: ApprovalCoordinator.Request] = [:]
    var pendingCount: Int { pending.count }

    /// Requests waiting on runs that belong to one sidebar section.
    func pendingCount(section: String) -> Int {
        pending.values.filter { $0.section == section }.count
    }

    /// Posts the "approval needed" notification. `StudioNotifier` stays
    /// silent while the app is active on that section (the sheet is already
    /// on screen) and never prompts from tests. Injectable for tests.
    var notify: @MainActor (_ section: String, _ title: String, _ body: String) -> Void = { section, title, body in
        StudioNotifier.shared.finished(section: section, title: title, body: body)
    }

    func began(_ request: ApprovalCoordinator.Request) {
        pending[request.id] = request
        let (title, body) = Self.notice(for: request)
        notify(request.section, title, body)
    }

    func ended(_ id: UUID) {
        pending[id] = nil
    }

    nonisolated static func notice(for request: ApprovalCoordinator.Request) -> (title: String, body: String) {
        ("Agent needs your approval", "It wants to use \(request.toolName). Open ORB to approve or deny; the run waits until you do.")
    }
}

extension ApprovalPresenter {
    /// Requests waiting in this presenter (the visible one plus any queued).
    var pendingCount: Int { queue.current == nil ? 0 : queue.waiting + 1 }
}

// MARK: - write_file results and cards (AGENT-6)

/// The text `write_file` returns: what happened, sizes, and a capped diff.
enum WriteFileReport {
    static func make(writing content: String, to url: URL, maxDiffLines: Int = 60) -> String {
        let bytes = content.utf8.count
        let lineCount = UnifiedDiff.lines(content).count
        let size = "\(lineCount) line\(lineCount == 1 ? "" : "s"), \(bytes) bytes"
        guard FileManager.default.fileExists(atPath: url.path) else {
            return "Created \(url.path) (\(size))."
        }
        let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard fileSize <= 2_000_000, let existing = try? String(contentsOf: url, encoding: .utf8) else {
            return "Overwrote \(url.path) (\(size)). The previous file was not compared (binary or larger than 2 MB)."
        }
        let diff = UnifiedDiff.make(old: existing, new: content, maxLines: maxDiffLines)
        if diff.added + diff.removed == 0 {
            return "Rewrote \(url.path) with identical content (\(size))."
        }
        return "Modified \(url.path): +\(diff.added) −\(diff.removed) lines (now \(size)).\n\(diff.text)"
    }
}

/// A readable expanded view for a tool card, instead of one line of escaped
/// JSON. `ToolCallCard` (PlaygroundCommon) renders `body` as a code block in
/// `language` when this returns non-nil.
struct ToolCallReadablePreview: Equatable {
    let header: String
    let language: String
    let body: String

    static func make(toolName: String, argumentsJSON: String, result: String?) -> ToolCallReadablePreview? {
        guard let arguments = JSONValue.parse(argumentsJSON)?.objectValue else { return nil }
        switch toolName {
        case "write_file":
            guard let path = arguments["path"]?.stringValue else { return nil }
            let content = arguments["content"]?.stringValue ?? ""
            let lines = UnifiedDiff.lines(content).count
            let size = ByteCountFormatter.string(fromByteCount: Int64(content.utf8.count), countStyle: .file)
            // After the call ran, its result carries the diff; show that.
            if let result, result.hasPrefix("Modified "), let newline = result.firstIndex(of: "\n") {
                return .init(header: String(result[..<newline]), language: "diff",
                             body: String(result[result.index(after: newline)...]))
            }
            let header = result.flatMap { $0.hasPrefix("Created ") || $0.hasPrefix("Rewrote ") || $0.hasPrefix("Overwrote ") ? $0 : nil }
                ?? "\(path) · \(lines) line\(lines == 1 ? "" : "s") · \(size)"
            let language = URL(fileURLWithPath: path).pathExtension.lowercased()
            let capped = content.count > 20_000 ? String(content.prefix(20_000)) + "\n… \(content.count - 20_000) more characters …" : content
            return .init(header: header, language: language.isEmpty ? "text" : language, body: capped)
        case "run_command":
            guard let command = arguments["command"]?.stringValue else { return nil }
            let directory = arguments["working_directory"]?.stringValue
            return .init(header: directory.map { "in \($0)" } ?? "in the workspace", language: "sh", body: command)
        case "run_applescript":
            guard let script = arguments["script"]?.stringValue else { return nil }
            return .init(header: "AppleScript", language: "applescript", body: script)
        default:
            return nil
        }
    }
}

// MARK: - fetch_url body classification (AGENT-13)

enum FetchBody {
    /// Content types that are never useful as text to the model.
    static func isBinaryMIME(_ mime: String) -> Bool {
        let type = mime.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        if type.isEmpty { return false }
        if ["image/", "video/", "audio/", "font/"].contains(where: { type.hasPrefix($0) }) {
            return type != "image/svg+xml"
        }
        return ["application/octet-stream", "application/zip", "application/gzip", "application/x-gzip",
                "application/pdf", "application/x-apple-diskimage", "application/x-iso9660-image",
                "application/x-tar", "application/vnd.rar", "application/x-7z-compressed",
                "application/x-msdownload", "application/wasm"].contains(type)
    }

    /// Strict UTF-8 without NUL bytes. When the body was cut off, up to three
    /// trailing bytes of an incomplete character are ignored.
    static func looksLikeText(_ data: Data, truncated: Bool) -> Bool {
        if data.isEmpty { return true }
        if data.contains(0) { return false }
        if String(data: data, encoding: .utf8) != nil { return true }
        guard truncated else { return false }
        for drop in 1...3 where data.count > drop {
            if String(data: data.dropLast(drop), encoding: .utf8) != nil { return true }
        }
        return false
    }
}
