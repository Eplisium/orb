import Foundation

// W11 read-only management inventory adapter.
//
// Scope (per the implementation brief §7.7, §10 W11, and Appendix A): typed
// GET adapters for the documented management reads ONLY. This type exposes
// exclusively `get`-shaped operations — create/update/delete/patch are not
// stubbed, commented out, or planned here; mutations are a later, separately
// reviewed work package.
//
// Contract (verified 2026-09-16 against https://openrouter.ai/openapi.json,
// server https://openrouter.ai/api/v1, and the management-key guide
// https://openrouter.ai/docs/guides/overview/auth/management-api-keys.md,
// which states all key-management endpoints "require a Management API key in
// the Authorization header"):
// - Paths implemented here (all GET):
//     /keys, /keys/{hash}, /byok, /byok/{id}, /guardrails, /guardrails/{id},
//     /workspaces, /workspaces/{id}, /organization/members,
//     /observability/destinations, /benchmarks,
//     /datasets/app-rankings, /datasets/rankings-daily, /datasets/session-cost
// - Pagination on this inventory is `limit`/`offset` per the live spec —
//   there is no `after`/`cursor` parameter on any of these operations (the
//   cursor style belongs to the beta batch list, already covered by W10).
// - Credential routing: every request resolves the MANAGEMENT credential via
//   `CredentialRouter`/`CredentialStore`. With no management key configured,
//   no request is built or sent — callers get the typed
//   `.managementKeyRequired` error. The inference key is never consulted and
//   never sent: management keys cannot perform inference, and inference keys
//   cannot read this inventory.
// - 401/403 map to the typed `.managementKeyRejected` with an actionable
//   message ("not authorized" must never read as "no data").

// MARK: - Query-parameter enums (documented values, passed through verbatim)

enum ManagementBenchmarkSource: String, Sendable, Equatable, CaseIterable {
    case artificialAnalysis = "artificial-analysis"
    case designArena = "design-arena"
    case openrouter
}

enum ManagementBenchmarkTaskType: String, Sendable, Equatable, CaseIterable {
    case coding, intelligence, agentic, search
}

enum ManagementBenchmarkType: String, Sendable, Equatable, CaseIterable {
    case gpqaDiamond = "gpqa_diamond"
    case tauBenchVerifiedAirline = "tau_bench_verified_airline"
    case searchBrowsecomp = "search_browsecomp"
    case searchHLE = "search_hle"
    case searchDSQA = "search_dsqa"
    case searchWidesearch = "search_widesearch"
}

enum ManagementBenchmarkSearchSurface: String, Sendable, Equatable, CaseIterable {
    case serverTool = "server-tool"
    case plugin
}

enum ManagementBenchmarkArena: String, Sendable, Equatable, CaseIterable {
    case models, builders, agents
}

enum ManagementDatasetSort: String, Sendable, Equatable, CaseIterable {
    case popular, trending
}

enum ManagementRankingsPeriod: String, Sendable, Equatable, CaseIterable {
    case day, week, month
}

enum ManagementRankingsModality: String, Sendable, Equatable, CaseIterable {
    case text, image
    case imageOutput = "image_output"
    case audio
    case toolCalling = "tool_calling"
}

enum ManagementContextBucket: String, Sendable, Equatable, CaseIterable {
    case bucket1K = "1K"
    case bucket10K = "10K"
    case bucket100K = "100K"
    case bucket1M = "1M"
    case bucket10M = "10M"
}

enum ManagementSessionTurnRange: String, Sendable, Equatable, CaseIterable {
    case oneTurn = "1-turn"
    case twoToNine = "2-9-turns"
    case tenToFortyNine = "10-49-turns"
    case fiftyPlus = "50-plus-turns"
}

// MARK: - Typed error surface

enum ManagementServiceError: Error, Equatable, LocalizedError {
    /// No management credential is configured. No request was sent — this is
    /// a local, pre-network outcome, and the message points at the fix.
    case managementKeyRequired
    /// 401/403: OpenRouter refused the management credential. The configured
    /// key exists but is invalid or lacks the entitlement for this operation;
    /// that must never be presented as "no data".
    case managementKeyRejected(status: Int, message: String)
    case invalidRequest(String)
    case untrustedURL(String)
    case http(status: Int, message: String)
    case transport(String)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .managementKeyRequired:
            return "Management key required. This account operation needs a management key — add one in Settings → Accounts & Keys. Your inference key still works for chat."
        case .managementKeyRejected(let status, let message):
            return "OpenRouter rejected the management key (HTTP \(status)). Check the key in Account, or its scopes if this specific read is not entitled. \(message)"
        case .invalidRequest(let message):
            return "Could not build the management request: \(message)"
        case .untrustedURL(let url):
            return "Refusing to attach credentials to untrusted URL: \(url)"
        case .http(let status, let message):
            switch status {
            case 429: return "OpenRouter rate limit reached. \(message)"
            case 500...599: return "OpenRouter is temporarily unavailable (HTTP \(status)). \(message)"
            default: return "OpenRouter HTTP \(status): \(message)"
            }
        case .transport(let message):
            return "Network error while contacting OpenRouter: \(message)"
        case .decoding(let message):
            return "Could not decode the OpenRouter management response: \(message)"
        }
    }
}

// MARK: - Service

/// Read-only adapter for OpenRouter's management-key inventory.
///
/// The public surface contains only GET-shaped operations (every method is
/// named `get…`/by its resource read and issues HTTP GET); there are no
/// create/update/delete methods on this type, so a mutation cannot be
/// accidentally routed through it.
struct ManagementService: Sendable {
    /// Documented management API base.
    static let base = URL(string: "https://openrouter.ai/api/v1")!
    static let pathPrefix = "/api/v1"

    typealias DataLoader = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private let profile: CredentialProfile
    private let secretStore: CredentialSecretStore
    private let dataLoader: DataLoader

    init(
        profile: CredentialProfile,
        secretStore: CredentialSecretStore,
        dataLoader: @escaping DataLoader
    ) {
        self.profile = profile
        self.secretStore = secretStore
        self.dataLoader = dataLoader
    }

    // MARK: API keys

    /// GET /keys — list API keys with usage and limits.
    func getKeys(
        includeDisabled: Bool? = nil,
        offset: Int? = nil,
        workspaceID: String? = nil
    ) async throws -> ManagementList<ManagementAPIKey> {
        try await get(
            path: ["keys"],
            query: [
                boolean("include_disabled", includeDisabled),
                integer("offset", offset),
                string("workspace_id", workspaceID),
            ]
        )
    }

    /// GET /keys/{hash} — one key by its stable hash.
    func getKey(hash: String) async throws -> ManagementAPIKey {
        try await getSingle(ManagementAPIKey.self, path: ["keys", hash])
    }

    // MARK: BYOK credentials

    /// GET /byok — list BYOK provider credentials. `label` is a masked
    /// snippet; the credential value itself is write-only upstream and is
    /// never present in responses.
    func getByokCredentials(
        offset: Int? = nil,
        limit: Int? = nil,
        workspaceID: String? = nil,
        provider: String? = nil
    ) async throws -> ManagementList<ManagementBYOKCredential> {
        try await get(
            path: ["byok"],
            query: [
                integer("offset", offset),
                integer("limit", limit),
                string("workspace_id", workspaceID),
                string("provider", provider),
            ]
        )
    }

    /// GET /byok/{id}
    func getByokCredential(id: String) async throws -> ManagementBYOKCredential {
        try await getSingle(ManagementBYOKCredential.self, path: ["byok", id])
    }

    // MARK: Guardrails

    /// GET /guardrails
    func getGuardrails(
        offset: Int? = nil,
        limit: Int? = nil,
        workspaceID: String? = nil
    ) async throws -> ManagementList<ManagementGuardrail> {
        try await get(
            path: ["guardrails"],
            query: [
                integer("offset", offset),
                integer("limit", limit),
                string("workspace_id", workspaceID),
            ]
        )
    }

    /// GET /guardrails/{id}
    func getGuardrail(id: String) async throws -> ManagementGuardrail {
        try await getSingle(ManagementGuardrail.self, path: ["guardrails", id])
    }

    // MARK: Workspaces

    /// GET /workspaces
    func getWorkspaces(
        offset: Int? = nil,
        limit: Int? = nil
    ) async throws -> ManagementList<ManagementWorkspace> {
        try await get(
            path: ["workspaces"],
            query: [integer("offset", offset), integer("limit", limit)]
        )
    }

    /// GET /workspaces/{id}
    func getWorkspace(id: String) async throws -> ManagementWorkspace {
        try await getSingle(ManagementWorkspace.self, path: ["workspaces", id])
    }

    // MARK: Organization

    /// GET /organization/members
    func getOrganizationMembers(
        offset: Int? = nil,
        limit: Int? = nil
    ) async throws -> ManagementList<ManagementOrganizationMember> {
        try await get(
            path: ["organization", "members"],
            query: [integer("offset", offset), integer("limit", limit)]
        )
    }

    // MARK: Observability

    /// GET /observability/destinations
    func getObservabilityDestinations(
        offset: Int? = nil,
        limit: Int? = nil,
        workspaceID: String? = nil
    ) async throws -> ManagementList<ManagementObservabilityDestination> {
        try await get(
            path: ["observability", "destinations"],
            query: [
                integer("offset", offset),
                integer("limit", limit),
                string("workspace_id", workspaceID),
            ]
        )
    }

    // MARK: Benchmarks

    /// GET /benchmarks — public benchmark data with required attribution in
    /// `meta.citation` when republished.
    func getBenchmarks(
        source: ManagementBenchmarkSource? = nil,
        taskType: ManagementBenchmarkTaskType? = nil,
        benchmarkType: ManagementBenchmarkType? = nil,
        includeRunConfig: Bool? = nil,
        searchEngine: String? = nil,
        searchSurface: ManagementBenchmarkSearchSurface? = nil,
        arena: ManagementBenchmarkArena? = nil,
        category: String? = nil,
        maxResults: Int? = nil
    ) async throws -> ManagementBenchmarks {
        try await get(
            path: ["benchmarks"],
            query: [
                string("source", source?.rawValue),
                string("task_type", taskType?.rawValue),
                string("benchmark_type", benchmarkType?.rawValue),
                boolean("include_run_config", includeRunConfig),
                string("search_engine", searchEngine),
                string("search_surface", searchSurface?.rawValue),
                string("arena", arena?.rawValue),
                string("category", category),
                integer("max_results", maxResults),
            ]
        )
    }

    // MARK: Datasets

    /// GET /datasets/app-rankings — top apps by token usage.
    func getDatasetAppRankings(
        category: String? = nil,
        subcategory: String? = nil,
        sort: ManagementDatasetSort? = nil,
        startDate: String? = nil,
        endDate: String? = nil,
        limit: Int? = nil,
        offset: Int? = nil
    ) async throws -> ManagementPage<ManagementAppRankingsItem, ManagementRankingsMeta> {
        try await get(
            path: ["datasets", "app-rankings"],
            query: [
                string("category", category),
                string("subcategory", subcategory),
                string("sort", sort?.rawValue),
                string("start_date", startDate),
                string("end_date", endDate),
                integer("limit", limit),
                integer("offset", offset),
            ]
        )
    }

    /// GET /datasets/rankings-daily — daily token totals for top models.
    func getDatasetRankingsDaily(
        startDate: String? = nil,
        endDate: String? = nil,
        period: ManagementRankingsPeriod? = nil,
        modality: ManagementRankingsModality? = nil,
        contextBucket: ManagementContextBucket? = nil,
        category: String? = nil,
        languageType: String? = nil
    ) async throws -> ManagementPage<ManagementRankingsDailyItem, ManagementRankingsMeta> {
        try await get(
            path: ["datasets", "rankings-daily"],
            query: [
                string("start_date", startDate),
                string("end_date", endDate),
                string("period", period?.rawValue),
                string("modality", modality?.rawValue),
                string("context_bucket", contextBucket?.rawValue),
                string("category", category),
                string("language_type", languageType),
            ]
        )
    }

    /// GET /datasets/session-cost — cost per session by harness and model.
    func getDatasetSessionCost(
        appSlug: String? = nil,
        model: String? = nil,
        turnRange: ManagementSessionTurnRange? = nil,
        limit: Int? = nil,
        offset: Int? = nil
    ) async throws -> ManagementPage<ManagementSessionCostItem, ManagementSessionCostMeta> {
        try await get(
            path: ["datasets", "session-cost"],
            query: [
                string("app_slug", appSlug),
                string("model", model),
                string("turn_range", turnRange?.rawValue),
                integer("limit", limit),
                integer("offset", offset),
            ]
        )
    }

    // MARK: Plumbing

    /// GET-only request construction. Every public method funnels through
    /// here with `httpMethod` fixed to GET; nothing else exists on this type.
    private func get<Item: Decodable>(
        path: [String],
        query: [URLQueryItem?]
    ) async throws -> Item {
        try await execute(try buildRequest(path: path, query: query.compactMap { $0 }))
    }

    /// Unwraps the documented `{ "data": … }` single-item envelope.
    private func getSingle<Item: Decodable>(
        _: Item.Type,
        path: [String]
    ) async throws -> Item {
        let envelope = try await get(path: path, query: []) as ManagementSingle<Item>
        return envelope.data
    }

    private func buildRequest(path: [String], query: [URLQueryItem]) throws -> URLRequest {
        // Validate the exact URL BEFORE any credential work so the management
        // key can never be attached to an unapproved origin.
        var url: URL
        do {
            url = try AdapterURL.validate(Self.base, pathPrefix: Self.pathPrefix, allowCollectionRoot: true)
            for segment in path {
                url = try AdapterURL.url(url, appendingSegment: segment, pathPrefix: Self.pathPrefix)
            }
            if !query.isEmpty {
                guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
                    throw ManagementServiceError.untrustedURL(url.absoluteString)
                }
                components.queryItems = query
                guard let withQuery = components.url else {
                    throw ManagementServiceError.untrustedURL(url.absoluteString)
                }
                url = try AdapterURL.validate(withQuery, pathPrefix: Self.pathPrefix, allowCollectionRoot: true)
            }
        } catch let error as AdapterURLError {
            // The shared URL policy's typed failure maps onto this service's
            // error surface; the raw segment/URL is kept for the diagnostic.
            switch error {
            case .untrustedURL(let url): throw ManagementServiceError.untrustedURL(url)
            }
        }

        // Management credential only — CredentialRouter reads the management
        // reference and nothing else, so there is no code path that could
        // fall back to the inference key.
        guard let key = CredentialRouter.secret(for: .management, profile: profile, store: secretStore) else {
            throw ManagementServiceError.managementKeyRequired
        }
        var request = URLRequest(url: url, timeoutInterval: NetworkTimeouts.request)
        request.httpMethod = "GET"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        // F12: no HTTP-Referer until an owner-approved URL exists.
        request.setValue("ORB", forHTTPHeaderField: "X-OpenRouter-Title")
        return request
    }

    private func execute<Item: Decodable>(_ request: URLRequest) async throws -> Item {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await dataLoader(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ManagementServiceError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw ManagementServiceError.transport("Invalid response from OpenRouter.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let envelope = AdapterHTTPErrorEnvelope.parse(status: http.statusCode, data: data)
            switch http.statusCode {
            case 401, 403:
                throw ManagementServiceError.managementKeyRejected(status: http.statusCode, message: envelope.message)
            default:
                throw ManagementServiceError.http(status: http.statusCode, message: envelope.message)
            }
        }
        do {
            return try JSONDecoder().decode(Item.self, from: data)
        } catch {
            throw ManagementServiceError.decoding(String(describing: error))
        }
    }

    // MARK: Query helpers

    private func string(_ name: String, _ value: String?) -> URLQueryItem? {
        guard let value, !value.isEmpty else { return nil }
        return URLQueryItem(name: name, value: value)
    }

    private func integer(_ name: String, _ value: Int?) -> URLQueryItem? {
        guard let value else { return nil }
        return URLQueryItem(name: name, value: String(value))
    }

    private func boolean(_ name: String, _ value: Bool?) -> URLQueryItem? {
        guard let value else { return nil }
        return URLQueryItem(name: name, value: value ? "true" : "false")
    }
}

// MARK: - Single-item envelope protocol

/// Types shaped `{ "data": … }` for single-resource GET responses
/// (/keys/{hash}, /byok/{id}, /guardrails/{id}, /workspaces/{id}).
protocol SingleDataEnvelope {
    associatedtype Item: Decodable
    var data: Item { get }
}

/// The documented single-resource envelope.
struct ManagementSingle<Item: Decodable & Sendable>: Decodable, Sendable, SingleDataEnvelope {
    let data: Item
}
