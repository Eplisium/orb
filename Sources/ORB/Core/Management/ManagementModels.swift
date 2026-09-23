import Foundation

// W11 read-only management inventory models.
//
// Shapes verified 2026-09-16 against the live OpenAPI specification
// (https://openrouter.ai/openapi.json, server https://openrouter.ai/api/v1):
// the documented list envelopes are `{ "data": [...], "total_count": N }`
// (GET /keys is the exception — its envelope carries `data` only), the
// benchmark and dataset endpoints return `{ "data": [...], "meta": {...} }`,
// and all of these operations paginate with `limit`/`offset` — there is no
// `after` cursor on this inventory.
//
// Every model keeps the full wire item in `raw` (JSONValue) so unknown
// forward-compatible fields survive decoding, and every field the spec does
// not mark required is optional. Items carrying stable IDs are matched by ID
// through the `ManagementList.item(id:by:)` helper — never by array position.

// MARK: - Envelopes

/// Documented list envelope `{ data, total_count }` (e.g. /byok, /guardrails,
/// /workspaces, /organization/members, /observability/destinations). GET /keys
/// returns the same shape without `total_count`, which stays optional here.
struct ManagementList<Item: Decodable & Equatable & Sendable>: Decodable, Equatable, Sendable {
    let data: [Item]?
    let totalCount: Int?

    enum CodingKeys: String, CodingKey {
        case data
        case totalCount = "total_count"
    }

    /// Matches an item by its stable identifier — never by array position.
    /// `keyPath` points at the item's ID field (e.g. `\.hash`, `\.id`).
    /// Overloads cover required (`String`) and tolerant (`String?`) ID fields.
    func item(id: String, by keyPath: KeyPath<Item, String>) -> Item? {
        data?.first { $0[keyPath: keyPath] == id }
    }

    func item(id: String, by keyPath: KeyPath<Item, String?>) -> Item? {
        data?.first { $0[keyPath: keyPath] == id }
    }
}

/// Documented `{ data, meta }` envelope used by /benchmarks and the
/// /datasets endpoints.
struct ManagementPage<Item: Decodable & Equatable & Sendable, Meta: Decodable & Equatable & Sendable>: Decodable, Equatable, Sendable {
    let data: [Item]?
    let meta: Meta?
}

// MARK: - API keys (GET /keys, GET /keys/{hash})

struct ManagementAPIKey: Decodable, Equatable, Sendable {
    /// Stable identity of the key — required by the spec.
    let hash: String
    let label: String?
    let name: String?
    let createdAt: String?
    let updatedAt: String?
    let expiresAt: String?
    let disabled: Bool?
    let limit: Double?
    let limitRemaining: Double?
    let limitReset: String?
    let usage: Double?
    let usageDaily: Double?
    let usageMonthly: Double?
    let usageWeekly: Double?
    let byokUsage: Double?
    let byokUsageDaily: Double?
    let byokUsageMonthly: Double?
    let byokUsageWeekly: Double?
    let includeByokInLimit: Bool?
    let workspaceID: String?
    let creatorUserID: String?
    let externalUser: String?
    /// Full wire item, preserving fields ORB does not model yet.
    let raw: JSONValue?

    enum CodingKeys: String, CodingKey {
        case hash, label, name, disabled, limit, usage, raw
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case expiresAt = "expires_at"
        case limitRemaining = "limit_remaining"
        case limitReset = "limit_reset"
        case usageDaily = "usage_daily"
        case usageMonthly = "usage_monthly"
        case usageWeekly = "usage_weekly"
        case byokUsage = "byok_usage"
        case byokUsageDaily = "byok_usage_daily"
        case byokUsageMonthly = "byok_usage_monthly"
        case byokUsageWeekly = "byok_usage_weekly"
        case includeByokInLimit = "include_byok_in_limit"
        case workspaceID = "workspace_id"
        case creatorUserID = "creator_user_id"
        case externalUser = "external_user"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hash = try container.decode(String.self, forKey: .hash)
        label = try container.decodeIfPresent(String.self, forKey: .label)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt)
        updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt)
        expiresAt = try container.decodeIfPresent(String.self, forKey: .expiresAt)
        disabled = try container.decodeIfPresent(Bool.self, forKey: .disabled)
        limit = try container.decodeIfPresent(Double.self, forKey: .limit)
        limitRemaining = try container.decodeIfPresent(Double.self, forKey: .limitRemaining)
        limitReset = try container.decodeIfPresent(String.self, forKey: .limitReset)
        usage = try container.decodeIfPresent(Double.self, forKey: .usage)
        usageDaily = try container.decodeIfPresent(Double.self, forKey: .usageDaily)
        usageMonthly = try container.decodeIfPresent(Double.self, forKey: .usageMonthly)
        usageWeekly = try container.decodeIfPresent(Double.self, forKey: .usageWeekly)
        byokUsage = try container.decodeIfPresent(Double.self, forKey: .byokUsage)
        byokUsageDaily = try container.decodeIfPresent(Double.self, forKey: .byokUsageDaily)
        byokUsageMonthly = try container.decodeIfPresent(Double.self, forKey: .byokUsageMonthly)
        byokUsageWeekly = try container.decodeIfPresent(Double.self, forKey: .byokUsageWeekly)
        includeByokInLimit = try container.decodeIfPresent(Bool.self, forKey: .includeByokInLimit)
        workspaceID = try container.decodeIfPresent(String.self, forKey: .workspaceID)
        creatorUserID = try container.decodeIfPresent(String.self, forKey: .creatorUserID)
        externalUser = try container.decodeIfPresent(String.self, forKey: .externalUser)
        raw = try? JSONValue(from: decoder)
    }
}

// MARK: - BYOK credentials (GET /byok, GET /byok/{id})

struct ManagementBYOKCredential: Decodable, Equatable, Sendable {
    let id: String?
    /// Masked key snippet used by the provider UI for identification —
    /// never the credential itself.
    let label: String?
    let name: String?
    /// Lowercase provider slug (e.g. `openai`, `anthropic`).
    let provider: String?
    let disabled: Bool?
    let isByokOnly: Bool?
    let isFallback: Bool?
    let isRequired: Bool?
    let sortOrder: Int?
    let workspaceID: String?
    let createdAt: String?
    let allowedAPIKeyHashes: [String]?
    let allowedModels: [String]?
    let allowedUserIDs: [String]?
    let raw: JSONValue?

    enum CodingKeys: String, CodingKey {
        case id, label, name, provider, disabled, raw
        case isByokOnly = "is_byok_only"
        case isFallback = "is_fallback"
        case isRequired = "is_required"
        case sortOrder = "sort_order"
        case workspaceID = "workspace_id"
        case createdAt = "created_at"
        case allowedAPIKeyHashes = "allowed_api_key_hashes"
        case allowedModels = "allowed_models"
        case allowedUserIDs = "allowed_user_ids"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id)
        label = try container.decodeIfPresent(String.self, forKey: .label)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        provider = try container.decodeIfPresent(String.self, forKey: .provider)
        disabled = try container.decodeIfPresent(Bool.self, forKey: .disabled)
        isByokOnly = try container.decodeIfPresent(Bool.self, forKey: .isByokOnly)
        isFallback = try container.decodeIfPresent(Bool.self, forKey: .isFallback)
        isRequired = try container.decodeIfPresent(Bool.self, forKey: .isRequired)
        sortOrder = try container.decodeIfPresent(Int.self, forKey: .sortOrder)
        workspaceID = try container.decodeIfPresent(String.self, forKey: .workspaceID)
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt)
        allowedAPIKeyHashes = try container.decodeIfPresent([String].self, forKey: .allowedAPIKeyHashes)
        allowedModels = try container.decodeIfPresent([String].self, forKey: .allowedModels)
        allowedUserIDs = try container.decodeIfPresent([String].self, forKey: .allowedUserIDs)
        raw = try? JSONValue(from: decoder)
    }
}

// MARK: - Guardrails (GET /guardrails, GET /guardrails/{id})

struct ManagementGuardrail: Decodable, Equatable, Sendable {
    let id: String?
    let name: String?
    let description: String?
    let workspaceID: String?
    let createdAt: String?
    let updatedAt: String?
    let limitUSD: Double?
    let resetInterval: String?
    let includeByokInBudgets: Bool?
    let allowedModels: [String]?
    let allowedProviders: [String]?
    let ignoredModels: [String]?
    let ignoredProviders: [String]?
    let allowedDataRegions: [String]?
    let contentFilters: [JSONValue]?
    let contentFilterBuiltins: [JSONValue]?
    let enforceZDR: Bool?
    let enforceZDRAnthropic: Bool?
    let enforceZDRGoogle: Bool?
    let enforceZDROpenAI: Bool?
    let enforceZDRxAI: Bool?
    let enforceZDROther: Bool?
    let enableFreeModelPublication: Bool?
    let enableFreeModelTraining: Bool?
    let enablePaidModelTraining: Bool?
    let raw: JSONValue?

    enum CodingKeys: String, CodingKey {
        case id, name, description, raw
        case workspaceID = "workspace_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case limitUSD = "limit_usd"
        case resetInterval = "reset_interval"
        case includeByokInBudgets = "include_byok_in_budgets"
        case allowedModels = "allowed_models"
        case allowedProviders = "allowed_providers"
        case ignoredModels = "ignored_models"
        case ignoredProviders = "ignored_providers"
        case allowedDataRegions = "allowed_data_regions"
        case contentFilters = "content_filters"
        case contentFilterBuiltins = "content_filter_builtins"
        case enforceZDR = "enforce_zdr"
        case enforceZDRAnthropic = "enforce_zdr_anthropic"
        case enforceZDRGoogle = "enforce_zdr_google"
        case enforceZDROpenAI = "enforce_zdr_openai"
        case enforceZDRxAI = "enforce_zdr_xai"
        case enforceZDROther = "enforce_zdr_other"
        case enableFreeModelPublication = "enable_free_model_publication"
        case enableFreeModelTraining = "enable_free_model_training"
        case enablePaidModelTraining = "enable_paid_model_training"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        workspaceID = try container.decodeIfPresent(String.self, forKey: .workspaceID)
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt)
        updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt)
        limitUSD = try container.decodeIfPresent(Double.self, forKey: .limitUSD)
        resetInterval = try container.decodeIfPresent(String.self, forKey: .resetInterval)
        includeByokInBudgets = try container.decodeIfPresent(Bool.self, forKey: .includeByokInBudgets)
        allowedModels = try container.decodeIfPresent([String].self, forKey: .allowedModels)
        allowedProviders = try container.decodeIfPresent([String].self, forKey: .allowedProviders)
        ignoredModels = try container.decodeIfPresent([String].self, forKey: .ignoredModels)
        ignoredProviders = try container.decodeIfPresent([String].self, forKey: .ignoredProviders)
        allowedDataRegions = try container.decodeIfPresent([String].self, forKey: .allowedDataRegions)
        contentFilters = try container.decodeIfPresent([JSONValue].self, forKey: .contentFilters)
        contentFilterBuiltins = try container.decodeIfPresent([JSONValue].self, forKey: .contentFilterBuiltins)
        enforceZDR = try container.decodeIfPresent(Bool.self, forKey: .enforceZDR)
        enforceZDRAnthropic = try container.decodeIfPresent(Bool.self, forKey: .enforceZDRAnthropic)
        enforceZDRGoogle = try container.decodeIfPresent(Bool.self, forKey: .enforceZDRGoogle)
        enforceZDROpenAI = try container.decodeIfPresent(Bool.self, forKey: .enforceZDROpenAI)
        enforceZDRxAI = try container.decodeIfPresent(Bool.self, forKey: .enforceZDRxAI)
        enforceZDROther = try container.decodeIfPresent(Bool.self, forKey: .enforceZDROther)
        enableFreeModelPublication = try container.decodeIfPresent(Bool.self, forKey: .enableFreeModelPublication)
        enableFreeModelTraining = try container.decodeIfPresent(Bool.self, forKey: .enableFreeModelTraining)
        enablePaidModelTraining = try container.decodeIfPresent(Bool.self, forKey: .enablePaidModelTraining)
        raw = try? JSONValue(from: decoder)
    }
}

// MARK: - Workspaces (GET /workspaces, GET /workspaces/{id})

struct ManagementWorkspace: Decodable, Equatable, Sendable {
    let id: String?
    let name: String?
    let slug: String?
    let description: String?
    let createdAt: String?
    let updatedAt: String?
    let createdBy: String?
    let defaultGuardrailID: String?
    let defaultImageModel: String?
    let defaultTextModel: String?
    let defaultProviderSort: String?
    let includeByokInBudgets: Bool?
    let ioLoggingSamplingRate: Double?
    let ioLoggingAPIKeyIDs: [String]?
    let isObservabilityBroadcastEnabled: Bool?
    let isObservabilityIOLoggingEnabled: Bool?
    let isDataDiscountLoggingEnabled: Bool?
    let raw: JSONValue?

    enum CodingKeys: String, CodingKey {
        case id, name, slug, description, raw
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case createdBy = "created_by"
        case defaultGuardrailID = "default_guardrail_id"
        case defaultImageModel = "default_image_model"
        case defaultTextModel = "default_text_model"
        case defaultProviderSort = "default_provider_sort"
        case includeByokInBudgets = "include_byok_in_budgets"
        case ioLoggingSamplingRate = "io_logging_sampling_rate"
        case ioLoggingAPIKeyIDs = "io_logging_api_key_ids"
        case isObservabilityBroadcastEnabled = "is_observability_broadcast_enabled"
        case isObservabilityIOLoggingEnabled = "is_observability_io_logging_enabled"
        case isDataDiscountLoggingEnabled = "is_data_discount_logging_enabled"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        slug = try container.decodeIfPresent(String.self, forKey: .slug)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt)
        updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt)
        createdBy = try container.decodeIfPresent(String.self, forKey: .createdBy)
        defaultGuardrailID = try container.decodeIfPresent(String.self, forKey: .defaultGuardrailID)
        defaultImageModel = try container.decodeIfPresent(String.self, forKey: .defaultImageModel)
        defaultTextModel = try container.decodeIfPresent(String.self, forKey: .defaultTextModel)
        defaultProviderSort = try container.decodeIfPresent(String.self, forKey: .defaultProviderSort)
        includeByokInBudgets = try container.decodeIfPresent(Bool.self, forKey: .includeByokInBudgets)
        ioLoggingSamplingRate = try container.decodeIfPresent(Double.self, forKey: .ioLoggingSamplingRate)
        ioLoggingAPIKeyIDs = try container.decodeIfPresent([String].self, forKey: .ioLoggingAPIKeyIDs)
        isObservabilityBroadcastEnabled = try container.decodeIfPresent(Bool.self, forKey: .isObservabilityBroadcastEnabled)
        isObservabilityIOLoggingEnabled = try container.decodeIfPresent(Bool.self, forKey: .isObservabilityIOLoggingEnabled)
        isDataDiscountLoggingEnabled = try container.decodeIfPresent(Bool.self, forKey: .isDataDiscountLoggingEnabled)
        raw = try? JSONValue(from: decoder)
    }
}

// MARK: - Organization members (GET /organization/members)

struct ManagementOrganizationMember: Decodable, Equatable, Sendable {
    let id: String?
    let email: String?
    let firstName: String?
    let lastName: String?
    /// Documented values: `org:admin`, `org:member`. Kept a plain string so
    /// future roles decode instead of failing.
    let role: String?
    let raw: JSONValue?

    enum CodingKeys: String, CodingKey {
        case id, email, role, raw
        case firstName = "first_name"
        case lastName = "last_name"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id)
        email = try container.decodeIfPresent(String.self, forKey: .email)
        firstName = try container.decodeIfPresent(String.self, forKey: .firstName)
        lastName = try container.decodeIfPresent(String.self, forKey: .lastName)
        role = try container.decodeIfPresent(String.self, forKey: .role)
        raw = try? JSONValue(from: decoder)
    }
}

// MARK: - Observability destinations (GET /observability/destinations)

/// The spec models destinations as a `oneOf` discriminator on `type` with 17
/// provider-specific variants (langfuse, datadog, s3, webhook, …). ORB keeps
/// the common documented fields typed and carries the provider-specific
/// `config` and everything else verbatim in `raw` — the read-only inventory
/// never needs to interpret secret-bearing config values.
struct ManagementObservabilityDestination: Decodable, Equatable, Sendable {
    let id: String?
    let name: String?
    let type: String?
    let workspaceID: String?
    let enabled: Bool?
    let privacyMode: Bool?
    let samplingRate: Double?
    let regions: [String]?
    let createdAt: String?
    let updatedAt: String?
    let broadcastGenerationCost: Bool?
    let broadcastGenerationIdentity: Bool?
    let broadcastGenerationRequestContext: Bool?
    /// Provider-specific destination configuration (kept verbatim; may
    /// contain masked secret shapes the UI must not display raw).
    let config: JSONValue?
    let filterRules: JSONValue?
    let apiKeyHashes: [String]?
    let raw: JSONValue?

    enum CodingKeys: String, CodingKey {
        case id, name, type, enabled, regions, config, raw
        case workspaceID = "workspace_id"
        case privacyMode = "privacy_mode"
        case samplingRate = "sampling_rate"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case broadcastGenerationCost = "broadcast_generation_cost"
        case broadcastGenerationIdentity = "broadcast_generation_identity"
        case broadcastGenerationRequestContext = "broadcast_generation_request_context"
        case filterRules = "filter_rules"
        case apiKeyHashes = "api_key_hashes"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        workspaceID = try container.decodeIfPresent(String.self, forKey: .workspaceID)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled)
        privacyMode = try container.decodeIfPresent(Bool.self, forKey: .privacyMode)
        samplingRate = try container.decodeIfPresent(Double.self, forKey: .samplingRate)
        regions = try container.decodeIfPresent([String].self, forKey: .regions)
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt)
        updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt)
        broadcastGenerationCost = try container.decodeIfPresent(Bool.self, forKey: .broadcastGenerationCost)
        broadcastGenerationIdentity = try container.decodeIfPresent(Bool.self, forKey: .broadcastGenerationIdentity)
        broadcastGenerationRequestContext = try container.decodeIfPresent(Bool.self, forKey: .broadcastGenerationRequestContext)
        config = try container.decodeIfPresent(JSONValue.self, forKey: .config)
        filterRules = try container.decodeIfPresent(JSONValue.self, forKey: .filterRules)
        apiKeyHashes = try container.decodeIfPresent([String].self, forKey: .apiKeyHashes)
        raw = try? JSONValue(from: decoder)
    }
}

// MARK: - Benchmarks (GET /benchmarks)

struct ManagementBenchmarks: Decodable, Equatable, Sendable {
    struct Meta: Decodable, Equatable, Sendable {
        let asOf: String?
        /// Required attribution when republishing; nil when results span
        /// multiple sources (attribute each item by its `source`).
        let citation: String?
        let modelCount: Int?
        let source: String?
        let sourceURL: String?
        let taskType: String?
        let version: String?

        enum CodingKeys: String, CodingKey {
            case citation, source, version
            case asOf = "as_of"
            case modelCount = "model_count"
            case sourceURL = "source_url"
            case taskType = "task_type"
        }
    }

    /// The spec's benchmark items are a `oneOf` across four source-specific
    /// shapes (artificial-analysis, design-arena, openrouter, search). The
    /// fields shared by every variant are typed; the source-specific rest is
    /// preserved in `raw`.
    struct Item: Decodable, Equatable, Sendable {
        let source: String?
        let modelPermaslug: String?
        let displayName: String?
        let raw: JSONValue?

        enum CodingKeys: String, CodingKey {
            case source, raw
            case modelPermaslug = "model_permaslug"
            case displayName = "display_name"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            source = try container.decodeIfPresent(String.self, forKey: .source)
            modelPermaslug = try container.decodeIfPresent(String.self, forKey: .modelPermaslug)
            displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
            raw = try? JSONValue(from: decoder)
        }
    }

    let data: [Item]?
    let meta: Meta?
}

// MARK: - Datasets (GET /datasets/…)

/// Meta shared by /datasets/app-rankings and /datasets/rankings-daily.
struct ManagementRankingsMeta: Decodable, Equatable, Sendable {
    let asOf: String?
    let startDate: String?
    let endDate: String?
    let version: String?

    enum CodingKeys: String, CodingKey {
        case version
        case asOf = "as_of"
        case startDate = "start_date"
        case endDate = "end_date"
    }
}

/// `total_tokens` is a decimal STRING in the documented contract so 64-bit
/// values are not truncated — it is deliberately not a Double here.
struct ManagementAppRankingsItem: Decodable, Equatable, Sendable {
    let appID: Int?
    let appName: String?
    let rank: Int?
    let totalRequests: Int?
    let totalTokens: String?
    let raw: JSONValue?

    enum CodingKeys: String, CodingKey {
        case rank, raw
        case appID = "app_id"
        case appName = "app_name"
        case totalRequests = "total_requests"
        case totalTokens = "total_tokens"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        appID = try container.decodeIfPresent(Int.self, forKey: .appID)
        appName = try container.decodeIfPresent(String.self, forKey: .appName)
        rank = try container.decodeIfPresent(Int.self, forKey: .rank)
        totalRequests = try container.decodeIfPresent(Int.self, forKey: .totalRequests)
        totalTokens = try container.decodeIfPresent(String.self, forKey: .totalTokens)
        raw = try? JSONValue(from: decoder)
    }
}

struct ManagementRankingsDailyItem: Decodable, Equatable, Sendable {
    let date: String?
    let modelPermaslug: String?
    let totalTokens: String?
    let raw: JSONValue?

    enum CodingKeys: String, CodingKey {
        case date, raw
        case modelPermaslug = "model_permaslug"
        case totalTokens = "total_tokens"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        date = try container.decodeIfPresent(String.self, forKey: .date)
        modelPermaslug = try container.decodeIfPresent(String.self, forKey: .modelPermaslug)
        totalTokens = try container.decodeIfPresent(String.self, forKey: .totalTokens)
        raw = try? JSONValue(from: decoder)
    }
}

struct ManagementSessionCostMeta: Decodable, Equatable, Sendable {
    let asOf: String?
    let version: String?
    let windowDays: Int?
    let windowEndDate: String?

    enum CodingKeys: String, CodingKey {
        case version
        case asOf = "as_of"
        case windowDays = "window_days"
        case windowEndDate = "window_end_date"
    }
}

struct ManagementSessionCostItem: Decodable, Equatable, Sendable {
    let appSlug: String?
    let appName: String?
    let modelPermaslug: String?
    let turnRange: String?
    let medianSessionCostUSD: Double?
    let raw: JSONValue?

    enum CodingKeys: String, CodingKey {
        case raw
        case appSlug = "app_slug"
        case appName = "app_name"
        case modelPermaslug = "model_permaslug"
        case turnRange = "turn_range"
        case medianSessionCostUSD = "median_session_cost_usd"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        appSlug = try container.decodeIfPresent(String.self, forKey: .appSlug)
        appName = try container.decodeIfPresent(String.self, forKey: .appName)
        modelPermaslug = try container.decodeIfPresent(String.self, forKey: .modelPermaslug)
        turnRange = try container.decodeIfPresent(String.self, forKey: .turnRange)
        medianSessionCostUSD = try container.decodeIfPresent(Double.self, forKey: .medianSessionCostUSD)
        raw = try? JSONValue(from: decoder)
    }
}
