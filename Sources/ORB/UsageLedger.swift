import Foundation

// MARK: - Append-only usage & cost ledger
//
// Successfully saved events survive deleting conversations or creations.
// Failed writes remain pending IN MEMORY for explicit retry; quitting before
// retry succeeds loses those events. This is not a durable outbox or a promise
// of complete lifetime accounting. Missing provider cost is stored as NULL
// and surfaced as "unpriced", never as a known $0.

struct UsageEvent: Equatable, Sendable {
    var id: String = UUID().uuidString
    var timestamp = Date()
    let feature: String
    let modelID: String
    var cost: Double?
    var promptTokens: Int?
    var completionTokens: Int?
    var totalTokens: Int?
    var requests = 1
}

struct UsageBucket: Identifiable, Equatable, Sendable {
    let key: String
    let cost: Double
    let requests: Int
    let tokens: Int
    /// Requests whose provider reported no cost (their spend is unknown).
    let unpricedRequests: Int
    var id: String { key }
}

enum UsageGrouping {
    case feature, model, day, month

    var expression: String {
        switch self {
        case .feature: "feature"
        case .model: "model_id"
        case .day: "date(timestamp, 'unixepoch', 'localtime')"
        case .month: "strftime('%Y-%m', timestamp, 'unixepoch', 'localtime')"
        }
    }

    var order: String {
        switch self {
        case .feature, .model: "SUM(COALESCE(cost, 0)) DESC, SUM(requests) DESC"
        case .day, .month: "k DESC"
        }
    }
}

/// Where in the app the spend happened. Raw values are stored, so never rename.
enum UsageFeature: String, CaseIterable, Sendable {
    case chat = "Chat"
    case agent = "Agent"
    case images = "Images"
    case video = "Video"
    case speech = "Speech"
    case transcription = "Transcription"
    case embeddings = "Embeddings"
    case rerank = "Rerank"
    case testSuite = "Test Suite"
    case promptEnhance = "Prompt Enhance"
    case agentVision = "Agent Vision"
    case agentWebSearch = "Agent Web Search"
}

@MainActor
final class UsageLedger: ObservableObject {
    static let shared = UsageLedger()

    /// Bumps on every write so open Settings views refresh live.
    @Published private(set) var revision = 0
    /// Original events, including generated IDs and timestamps, retained until
    /// SQLite accepts them. This queue intentionally does not claim durability.
    @Published private(set) var pendingEvents: [UsageEvent] = []
    @Published private(set) var persistenceError: String?

    var persistenceWarning: String? {
        guard !pendingEvents.isEmpty else { return nil }
        let noun = pendingEvents.count == 1 ? "usage event" : "usage events"
        return "\(pendingEvents.count) \(noun) could not be saved. Totals may be incomplete. Pending events are kept only until ORB quits; retry saving before closing the app."
    }

    private let database: () -> DatabaseManager
    private let recordEvent: (UsageEvent) throws -> Void

    init(database: @escaping () -> DatabaseManager = { DatabaseManager.shared },
         recordEvent: ((UsageEvent) throws -> Void)? = nil) {
        self.database = database
        self.recordEvent = recordEvent ?? { try database().insertUsageEventChecked($0) }
    }

    /// Records one event. `eventID` makes it idempotent (e.g. a chat run id or
    /// remote video job id), so retries and resumes cannot double count.
    func record(_ feature: UsageFeature, model: String, cost: Double?,
                promptTokens: Int? = nil, completionTokens: Int? = nil, totalTokens: Int? = nil,
                requests: Int = 1, eventID: String? = nil) {
        var event = UsageEvent(feature: feature.rawValue, modelID: model.isEmpty ? "unknown" : model,
                               cost: cost, promptTokens: promptTokens,
                               completionTokens: completionTokens, totalTokens: totalTokens,
                               requests: requests)
        if let eventID { event.id = "\(feature.rawValue):\(eventID)" }
        // Match SQLite's first-write-wins semantics even while an event is
        // pending: redelivery must not overwrite its original billing details.
        let original = pendingEvents.first(where: { $0.id == event.id }) ?? event
        // Observed once at recording, not retry/persistence: provider spend
        // still happened when SQLite rejects the write.
        AgentHelperUsageCollector.current?.record(original)
        persist(original)
    }

    /// Retry the existing values, never reconstruct events or generate new IDs.
    /// A partially successful pass removes only the rows accepted by SQLite.
    func retryPendingEvents() {
        for event in pendingEvents { persist(event) }
    }

    private func persist(_ event: UsageEvent) {
        do {
            try recordEvent(event)
            pendingEvents.removeAll { $0.id == event.id }
            if pendingEvents.isEmpty { persistenceError = nil }
            revision += 1
        } catch {
            if !pendingEvents.contains(where: { $0.id == event.id }) {
                pendingEvents.append(event)
            }
            persistenceError = error.localizedDescription
        }
    }

    func record(_ feature: UsageFeature, model: String, usage: ChatUsage?, eventID: String? = nil) {
        let requests = usage?.accountedRequestCount ?? 1
        let unpriced = usage?.unpricedRequests ?? 1
        let priced = requests - unpriced
        let subtotal = usage?.knownCostSubtotal ?? 0
        // Split a mixed aggregate into stable, independently retryable rows.
        // Tokens live on only one row; request counts sum to the actual turns.
        // Helpers are never part of this model-only usage value.
        let id = eventID ?? UUID().uuidString
        let hasPricedRow = priced > 0 || subtotal > 0
        if hasPricedRow {
            record(feature, model: model, cost: subtotal, promptTokens: usage?.promptTokens,
                   completionTokens: usage?.completionTokens, totalTokens: usage?.totalTokens,
                   requests: priced, eventID: id)
        }
        if unpriced > 0 {
            record(feature, model: model, cost: nil,
                   promptTokens: hasPricedRow ? nil : usage?.promptTokens,
                   completionTokens: hasPricedRow ? nil : usage?.completionTokens,
                   totalTokens: hasPricedRow ? nil : usage?.totalTokens,
                   requests: unpriced, eventID: hasPricedRow ? "\(id):unpriced" : id)
        }
    }

    func buckets(_ grouping: UsageGrouping, since: Date? = nil) -> [UsageBucket] {
        database().usageBuckets(grouping, since: since)
    }

    var firstEventDate: Date? { database().usageFirstEventDate() }
}
