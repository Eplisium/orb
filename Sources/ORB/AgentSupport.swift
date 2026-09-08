import Foundation

// MARK: - Agent support types (Phase D)

private extension Optional where Wrapped == String {
    var nilIfEmpty: String? {
        guard let value = self, !value.isEmpty else { return nil }
        return value
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

extension Optional where Wrapped == String {
    var orbNilIfEmpty: String? {
        guard let value = self, !value.isEmpty else { return nil }
        return value
    }
}

/// Durable agent memories, stored in SQLite so `remember`/`recall` survive
/// restarts. Scoped to nothing — memories are global to the Mac, like the
/// rest of ORB's local data.
struct AgentMemory: Sendable, Equatable {
    let id: String
    let content: String
    let createdAt: Date
}

/// In-memory task board backing the agent's `plan_tasks` tool. The board is
/// intentionally ephemeral: it tracks the current run's checklist, while
/// durable state lives in files and memories.
final class AgentTaskBoard: @unchecked Sendable {
    static let shared = AgentTaskBoard()

    private let lock = NSLock()
    private var items: [[String: String]] = []

    private init() {}

    func replace(with rawItems: [[String: Any]]) {
        lock.lock()
        defer { lock.unlock() }
        items = rawItems.prefix(50).compactMap { item in
            guard let title = item["title"] as? String, !title.isEmpty else { return nil }
            let status = (item["status"] as? String ?? "pending").lowercased()
            let normalized: String
            switch status {
            case "completed", "in_progress", "pending": normalized = status
            default: normalized = "pending"
            }
            return ["title": title, "status": normalized]
        }
    }

    var snapshot: [[String: String]] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }

    var summary: String {
        let current = snapshot
        guard !current.isEmpty else { return "No tasks tracked." }
        return current.map { item in
            let mark: String
            switch item["status"] {
            case "completed": mark = "[x]"
            case "in_progress": mark = "[>]"
            default: mark = "[ ]"
            }
            return "\(mark) \(item["title"] ?? "")"
        }.joined(separator: "\n")
    }
}
