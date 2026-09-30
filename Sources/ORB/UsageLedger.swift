import Foundation

// MARK: - Permanent usage & cost ledger
//
// Every paid call in the app is recorded once, append-only, in the local
// SQLite database (`usage_events`). Nothing here is ever pruned: lifetime
// totals must survive deleting conversations or saved creations. Cost is
// optional — when a provider does not report one we record the request with
// a NULL cost and surface it as "unpriced", never as $0.

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
}

@MainActor
final class UsageLedger: ObservableObject {
    static let shared = UsageLedger()

    /// Bumps on every write so open Settings views refresh live.
    @Published private(set) var revision = 0
    private let database: () -> DatabaseManager

    init(database: @escaping () -> DatabaseManager = { DatabaseManager.shared }) {
        self.database = database
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
        if database().insertUsageEvent(event) { revision += 1 }
    }

    func record(_ feature: UsageFeature, model: String, usage: ChatUsage?, eventID: String? = nil) {
        record(feature, model: model, cost: usage?.cost, promptTokens: usage?.promptTokens,
               completionTokens: usage?.completionTokens, totalTokens: usage?.totalTokens, eventID: eventID)
    }

    func buckets(_ grouping: UsageGrouping, since: Date? = nil) -> [UsageBucket] {
        database().usageBuckets(grouping, since: since)
    }

    var firstEventDate: Date? { database().usageFirstEventDate() }
}
