import Foundation

// MARK: - Recently used models
//
// The Chat/Agent model picker surfaces recently used models. The list logic
// is pure (records in, records out) so it is unit-testable; persistence is a
// thin UserDefaults facade that tests replace with a throwaway suite.

struct RecentModel: Codable, Equatable {
    let id: String
    let lastUsed: Date
}

enum ModelRecents {
    /// Maximum remembered models. Small on purpose: the picker shows these as
    /// a quick-access strip, not a history log.
    static let limit = 8

    /// Records `id` as used at `now`: newest first, de-duplicated, capped.
    static func record(
        _ id: String,
        in entries: [RecentModel],
        now: Date = Date(),
        limit: Int = limit
    ) -> [RecentModel] {
        var updated = entries.filter { $0.id != id }
        updated.insert(RecentModel(id: id, lastUsed: now), at: 0)
        return Array(updated.prefix(limit))
    }

    /// Model IDs, newest first.
    static func ids(in entries: [RecentModel]) -> [String] {
        entries.map(\.id)
    }

    static func encode(_ entries: [RecentModel]) -> Data? {
        try? JSONEncoder().encode(entries)
    }

    /// Tolerant decode: missing or corrupt data is simply an empty history.
    static func decode(_ data: Data?) -> [RecentModel] {
        guard let data else { return [] }
        return (try? JSONDecoder().decode([RecentModel].self, from: data)) ?? []
    }
}

/// UserDefaults-backed store used by the UI and ChatService.
struct ModelRecentsStore {
    private let defaults: UserDefaults
    private let key = "playground.recentModelIds"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func record(_ id: String) {
        let entries = ModelRecents.record(id, in: load())
        defaults.set(ModelRecents.encode(entries), forKey: key)
    }

    func recentIds() -> [String] {
        ModelRecents.ids(in: load())
    }

    func clear() {
        defaults.removeObject(forKey: key)
    }

    private func load() -> [RecentModel] {
        ModelRecents.decode(defaults.data(forKey: key))
    }
}
