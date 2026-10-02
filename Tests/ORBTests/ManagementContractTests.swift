import Foundation
import Testing
@testable import ORB

// W11 contract tests for the read-only management inventory adapter.
//
// Fixtures are taken verbatim from the live OpenAPI specification's response
// examples (https://openrouter.ai/openapi.json, retrieved 2026-09-16) and the
// management-key guide
// (https://openrouter.ai/docs/guides/overview/auth/management-api-keys.md,
// "All key management endpoints are under /api/v1/keys and require a
// Management API key in the Authorization header").
//
// This inventory paginates with the documented `limit`/`offset` parameters —
// the spec defines no `after`/`cursor` on any of these operations (cursor
// pagination exists only on the beta batch list, covered by BatchContractTests).

// MARK: - Test double

/// Records every request and serves scripted responses. No network, no
/// Keychain. Separate from `MockMediaTransport` on purpose: the management
/// service must never touch the inference-key transport.
final class MockManagementTransport: @unchecked Sendable {
    enum MockResponse: Sendable {
        case json(String)
        case status(Int, String)
    }

    private let lock = NSLock()
    private var queue: [MockResponse]
    private var recorded: [URLRequest] = []

    init(responses: [MockResponse]) {
        self.queue = responses
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        lock.lock()
        recorded.append(request)
        let response = queue.isEmpty ? MockResponse.json("{}") : queue.removeFirst()
        lock.unlock()
        switch response {
        case .json(let string):
            let http = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (Data(string.utf8), http)
        case .status(let status, let body):
            let http = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil
            )!
            return (Data(body.utf8), http)
        }
    }

    func sentRequests() -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func sentCount() -> Int {
        sentRequests().count
    }
}

// MARK: - Fixtures (verbatim from the live spec's response examples)

private enum ManagementFixtures {
    static let keys = """
    {"data":[{"byok_usage":17.38,"byok_usage_daily":17.38,"byok_usage_monthly":17.38,"byok_usage_weekly":17.38,"created_at":"2025-08-24T10:30:00Z","creator_user_id":"user_2dHFtVWx2n56w6HkM0000000000","disabled":false,"expires_at":"2027-12-31T23:59:59Z","hash":"f01d52606dc8f0a8303a7b5cc3fa07109c2e346cec7c0a16b40de462992ce943","include_byok_in_limit":false,"label":"Production API Key","limit":100,"limit_remaining":74.5,"limit_reset":"monthly","name":"My Production Key","updated_at":"2025-08-24T15:45:00Z","usage":25.5,"usage_daily":25.5,"usage_monthly":25.5,"usage_weekly":25.5,"workspace_id":"0df9e665-d932-5740-b2c7-b52af166bc11"}]}
    """

    static let keySingle = """
    {"data":{"byok_usage":17.38,"byok_usage_daily":17.38,"byok_usage_monthly":17.38,"byok_usage_weekly":17.38,"created_at":"2025-08-24T10:30:00Z","creator_user_id":"user_2dHFtVWx2n56w6HkM0000000000","disabled":false,"expires_at":"2027-12-31T23:59:59Z","hash":"f01d52606dc8f0a8303a7b5cc3fa07109c2e346cec7c0a16b40de462992ce943","include_byok_in_limit":false,"label":"Production API Key","limit":100,"limit_remaining":74.5,"limit_reset":"monthly","name":"My Production Key","updated_at":"2025-08-24T15:45:00Z","usage":25.5,"usage_daily":25.5,"usage_monthly":25.5,"usage_weekly":25.5,"workspace_id":"0df9e665-d932-5740-b2c7-b52af166bc11"}}
    """

    static let byok = """
    {"data":[{"allowed_api_key_hashes":null,"allowed_models":null,"allowed_user_ids":null,"created_at":"2025-08-24T10:30:00Z","disabled":false,"id":"11111111-2222-3333-4444-555555555555","is_byok_only":false,"is_fallback":false,"is_required":false,"label":"sk-...AbCd","name":"Production OpenAI Key","provider":"openai","sort_order":0,"workspace_id":"550e8400-e29b-41d4-a716-446655440000"}],"total_count":1}
    """

    static let byokSingle = """
    {"data":{"allowed_api_key_hashes":null,"allowed_models":null,"allowed_user_ids":null,"created_at":"2025-08-24T10:30:00Z","disabled":false,"id":"11111111-2222-3333-4444-555555555555","is_byok_only":false,"is_fallback":false,"is_required":false,"label":"sk-...AbCd","name":"Production OpenAI Key","provider":"openai","sort_order":0,"workspace_id":"550e8400-e29b-41d4-a716-446655440000"}}
    """

    static let guardrails = """
    {"data":[{"allowed_models":null,"allowed_providers":["openai","anthropic","google"],"created_at":"2025-08-24T10:30:00Z","description":"Guardrail for production environment","enforce_zdr":false,"id":"550e8400-e29b-41d4-a716-446655440000","ignored_models":null,"ignored_providers":null,"include_byok_in_budgets":false,"limit_usd":100,"name":"Production Guardrail","reset_interval":"monthly","updated_at":"2025-08-24T15:45:00Z","workspace_id":"0df9e665-d932-5740-b2c7-b52af166bc11"}],"total_count":1}
    """

    static let guardrailSingle = """
    {"data":{"allowed_models":null,"allowed_providers":["openai","anthropic","google"],"content_filter_builtins":[{"action":"redact","label":"[EMAIL]","slug":"email"}],"content_filters":null,"created_at":"2025-08-24T10:30:00Z","description":"Guardrail for production environment","enable_free_model_publication":false,"enable_free_model_training":true,"enable_paid_model_training":true,"enforce_zdr":null,"enforce_zdr_anthropic":true,"enforce_zdr_google":false,"enforce_zdr_openai":true,"enforce_zdr_other":false,"enforce_zdr_xai":false,"id":"550e8400-e29b-41d4-a716-446655440000","ignored_models":null,"ignored_providers":null,"include_byok_in_budgets":false,"limit_usd":100,"name":"Production Guardrail","reset_interval":"monthly","updated_at":"2025-08-24T15:45:00Z","workspace_id":"0df9e665-d932-5740-b2c7-b52af166bc11"}}
    """

    static let workspaces = """
    {"data":[{"created_at":"2025-08-24T10:30:00Z","created_by":"user_abc123","default_guardrail_id":"595d5849-7e86-51fd-a7c0-705c34e4afff","default_image_model":"openai/dall-e-3","default_provider_sort":"price","default_text_model":"openai/gpt-4o","description":"Production environment workspace","id":"550e8400-e29b-41d4-a716-446655440000","include_byok_in_budgets":false,"io_logging_api_key_ids":null,"io_logging_sampling_rate":1,"is_data_discount_logging_enabled":true,"is_observability_broadcast_enabled":false,"is_observability_io_logging_enabled":false,"name":"Production","slug":"production","updated_at":"2025-08-24T15:45:00Z"}],"total_count":1}
    """

    static let workspaceSingle = """
    {"data":{"created_at":"2025-08-24T10:30:00Z","created_by":"user_abc123","default_guardrail_id":"595d5849-7e86-51fd-a7c0-705c34e4afff","default_image_model":"openai/dall-e-3","default_provider_sort":"price","default_text_model":"openai/gpt-4o","description":"Production environment workspace","id":"550e8400-e29b-41d4-a716-446655440000","include_byok_in_budgets":false,"io_logging_api_key_ids":null,"io_logging_sampling_rate":1,"is_data_discount_logging_enabled":true,"is_observability_broadcast_enabled":false,"is_observability_io_logging_enabled":false,"name":"Production","slug":"production","updated_at":"2025-08-24T15:45:00Z"}}
    """

    static let organizationMembers = """
    {"data":[{"email":"jane.doe@example.com","first_name":"Jane","id":"user_2dHFtVWx2n56w6HkM0000000000","last_name":"Doe","role":"org:member"}],"total_count":25}
    """

    static let observabilityDestinations = """
    {"data":[{"api_key_hashes":null,"broadcast_generation_cost":false,"broadcast_generation_identity":false,"broadcast_generation_request_context":false,"config":{"baseUrl":"https://us.cloud.langfuse.com","publicKey":"pk-l...EfGh","secretKey":"sk-l...AbCd"},"created_at":"2025-08-24T10:30:00Z","enabled":true,"filter_rules":null,"id":"99999999-aaaa-bbbb-cccc-dddddddddddd","name":"Production Langfuse","privacy_mode":false,"regions":["global"],"sampling_rate":1,"type":"langfuse","updated_at":"2025-08-24T15:45:00Z","workspace_id":"550e8400-e29b-41d4-a716-446655440000"}],"total_count":1}
    """

    static let benchmarks = """
    {"data":[{"agentic_index":58.3,"coding_index":65.8,"display_name":"GPT-4o","intelligence_index":71.2,"model_permaslug":"openai/gpt-4o","pricing":{"completion":"0.00001","prompt":"0.0000025"},"source":"artificial-analysis"},{"accuracy":0.72,"accuracy_stddev":0.03,"avg_cost_per_task":0.002,"benchmark_type":"gpqa_diamond","display_name":"GPT-4o","last_run_timestamp":"2026-06-03T12:00:00Z","model_permaslug":"openai/gpt-4o","source":"openrouter","total_tasks":300}],"meta":{"as_of":"2026-06-03T12:00:00Z","citation":null,"model_count":1,"source":null,"source_url":null,"task_type":null,"version":"v1"}}
    """

    static let appRankings = """
    {"data":[{"app_id":12345,"app_name":"Cline","rank":1,"total_requests":4321,"total_tokens":"12345678"}],"meta":{"as_of":"2026-05-12T02:00:00.000Z","end_date":"2026-05-11","start_date":"2026-05-05","version":"v1"}}
    """

    static let rankingsDaily = """
    {"data":[{"date":"2026-05-11","model_permaslug":"openai/gpt-4o","total_tokens":"987654321"}],"meta":{"as_of":"2026-05-12T02:00:00.000Z","end_date":"2026-05-11","start_date":"2026-05-05","version":"v1"}}
    """

    static let sessionCost = """
    {"data":[{"app_name":"Hermes Agent","app_slug":"hermes-agent","median_session_cost_usd":1.74,"model_permaslug":"anthropic/claude-4.8-opus","turn_range":"10-49-turns"}],"meta":{"as_of":"2026-05-12T02:00:00.000Z","version":"v1","window_days":30,"window_end_date":"2026-05-11"}}
    """

    /// Every fixture, so tests can drive the whole inventory in loops.
    static var all: [(name: String, json: String)] {
        [
            ("keys", keys), ("keySingle", keySingle), ("byok", byok),
            ("byokSingle", byokSingle), ("guardrails", guardrails),
            ("guardrailSingle", guardrailSingle), ("workspaces", workspaces),
            ("workspaceSingle", workspaceSingle),
            ("organizationMembers", organizationMembers),
            ("observabilityDestinations", observabilityDestinations),
            ("benchmarks", benchmarks), ("appRankings", appRankings),
            ("rankingsDaily", rankingsDaily), ("sessionCost", sessionCost),
        ]
    }
}

@Suite("Management inventory contract")
struct ManagementContractTests {

    private func makeService(
        responses: [MockManagementTransport.MockResponse] = [],
        store: InMemoryCredentialStore? = nil
    ) -> (ManagementService, MockManagementTransport, InMemoryCredentialStore) {
        let mock = MockManagementTransport(responses: responses)
        let store = store ?? {
            let configured = InMemoryCredentialStore()
            _ = configured.saveSecret(
                "management-secret", forReference: CredentialRole.management.keychainAccount
            )
            return configured
        }()
        let service = ManagementService(
            profile: CredentialProfile(
                managementKeyReference: CredentialRole.management.keychainAccount
            ),
            secretStore: store,
            dataLoader: { try await mock.data(for: $0) }
        )
        return (service, mock, store)
    }

    private func queryValues(_ url: URL, _ name: String) -> [String] {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return [] }
        return (components.queryItems ?? []).filter { $0.name == name }.compactMap { $0.value }
    }

    // MARK: (a) every GET hits the exact documented path with the management key

    @Test("every documented read hits its exact /api/v1 path with method GET and the management key")
    func documentedPathsAndRouting() async throws {
        let (service, mock, _) = makeService(responses: ManagementFixtures.all.map { .json($0.json) })

        _ = try await service.getKeys()
        _ = try await service.getKey(hash: "f01d52606dc8f0a8303a7b5cc3fa07109c2e346cec7c0a16b40de462992ce943")
        _ = try await service.getByokCredentials()
        _ = try await service.getByokCredential(id: "11111111-2222-3333-4444-555555555555")
        _ = try await service.getGuardrails()
        _ = try await service.getGuardrail(id: "550e8400-e29b-41d4-a716-446655440000")
        _ = try await service.getWorkspaces()
        _ = try await service.getWorkspace(id: "550e8400-e29b-41d4-a716-446655440000")
        _ = try await service.getOrganizationMembers()
        _ = try await service.getObservabilityDestinations()
        _ = try await service.getBenchmarks()
        _ = try await service.getDatasetAppRankings()
        _ = try await service.getDatasetRankingsDaily()
        _ = try await service.getDatasetSessionCost()

        let requests = mock.sentRequests()
        #expect(requests.count == 14)

        let expectedPaths: [String] = [
            "/api/v1/keys",
            "/api/v1/keys/f01d52606dc8f0a8303a7b5cc3fa07109c2e346cec7c0a16b40de462992ce943",
            "/api/v1/byok",
            "/api/v1/byok/11111111-2222-3333-4444-555555555555",
            "/api/v1/guardrails",
            "/api/v1/guardrails/550e8400-e29b-41d4-a716-446655440000",
            "/api/v1/workspaces",
            "/api/v1/workspaces/550e8400-e29b-41d4-a716-446655440000",
            "/api/v1/organization/members",
            "/api/v1/observability/destinations",
            "/api/v1/benchmarks",
            "/api/v1/datasets/app-rankings",
            "/api/v1/datasets/rankings-daily",
            "/api/v1/datasets/session-cost",
        ]
        for (request, expected) in zip(requests, expectedPaths) {
            let url = try #require(request.url)
            #expect(url.host == "openrouter.ai")
            #expect(url.path == expected)
            #expect(url.absoluteString.hasPrefix("https://openrouter.ai/api/v1/"))
            #expect(request.httpMethod == "GET")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer management-secret")
        }
    }

    // MARK: (g) GET-only surface

    @Test("the entire public surface issues GET requests with no body")
    func getOnlySurface() async throws {
        let (service, mock, _) = makeService(responses: ManagementFixtures.all.map { .json($0.json) })

        _ = try await service.getKeys()
        _ = try await service.getKey(hash: "h")
        _ = try await service.getByokCredentials()
        _ = try await service.getByokCredential(id: "b")
        _ = try await service.getGuardrails()
        _ = try await service.getGuardrail(id: "g")
        _ = try await service.getWorkspaces()
        _ = try await service.getWorkspace(id: "w")
        _ = try await service.getOrganizationMembers()
        _ = try await service.getObservabilityDestinations()
        _ = try await service.getBenchmarks()
        _ = try await service.getDatasetAppRankings()
        _ = try await service.getDatasetRankingsDaily()
        _ = try await service.getDatasetSessionCost()

        for request in mock.sentRequests() {
            #expect(request.httpMethod == "GET")
            #expect(request.httpBody == nil)
            #expect(request.value(forHTTPHeaderField: "Content-Type") == nil)
        }
        // Structural guarantee: the type exposes only read-named operations
        // (getKeys/getKey/getByokCredentials/…); no create/update/delete
        // method exists to call, so a mutation cannot be routed through it.
    }

    // MARK: (b) absent management credential sends nothing

    @Test("no management key: every read throws the typed error and ZERO requests are sent")
    func absentManagementKeySendsNothing() async {
        // An inference key IS configured — the adapter must still refuse
        // rather than fall back to it.
        let store = InMemoryCredentialStore()
        _ = store.saveSecret("inference-secret", forReference: CredentialRole.inference.keychainAccount)
        let (service, mock, _) = makeService(store: store)

        func capturedError(_ operation: () async throws -> Void) async -> ManagementServiceError {
            do {
                try await operation()
                Issue.record("expected managementKeyRequired, but no error was thrown")
                return .invalidRequest("no error thrown")
            } catch let error as ManagementServiceError {
                return error
            } catch {
                Issue.record("unexpected error type: \(error)")
                return .invalidRequest("unexpected error type")
            }
        }

        var errors: [ManagementServiceError] = []
        errors.append(await capturedError { try await service.getKeys() })
        errors.append(await capturedError { try await service.getKey(hash: "h") })
        errors.append(await capturedError { try await service.getByokCredentials() })
        errors.append(await capturedError { try await service.getByokCredential(id: "b") })
        errors.append(await capturedError { try await service.getGuardrails() })
        errors.append(await capturedError { try await service.getGuardrail(id: "g") })
        errors.append(await capturedError { try await service.getWorkspaces() })
        errors.append(await capturedError { try await service.getWorkspace(id: "w") })
        errors.append(await capturedError { try await service.getOrganizationMembers() })
        errors.append(await capturedError { try await service.getObservabilityDestinations() })
        errors.append(await capturedError { try await service.getBenchmarks() })
        errors.append(await capturedError { try await service.getDatasetAppRankings() })
        errors.append(await capturedError { try await service.getDatasetRankingsDaily() })
        errors.append(await capturedError { try await service.getDatasetSessionCost() })

        for error in errors {
            #expect(error == .managementKeyRequired)
            #expect(error.errorDescription?.contains("Management key required") == true)
            #expect(error.errorDescription?.contains("add one in Settings") == true)
        }
        #expect(errors.count == 14)
        // Not a single network call — and never with the inference key.
        #expect(mock.sentCount() == 0)
    }

    @Test("a profile with no management reference also fails locally with zero requests")
    func profileWithoutManagementReferenceSendsNothing() async {
        let mock = MockManagementTransport(responses: [.json(ManagementFixtures.keys)])
        let service = ManagementService(
            profile: CredentialProfile(), // managementKeyReference == nil
            secretStore: InMemoryCredentialStore(),
            dataLoader: { try await mock.data(for: $0) }
        )
        await #expect {
            _ = try await service.getKeys()
        } throws: { error in
            (error as? ManagementServiceError) == .managementKeyRequired
        }
        #expect(mock.sentCount() == 0)
    }

    // MARK: (c) fixture decoding from the live spec examples

    @Test("spec example fixtures decode with their documented values")
    func fixtureDecoding() async throws {
        let (service, mock, _) = makeService(responses: ManagementFixtures.all.map { .json($0.json) })

        let keys = try await service.getKeys()
        #expect(keys.totalCount == nil) // /keys documents no total_count
        let key = try #require(keys.data?.first)
        #expect(key.hash == "f01d52606dc8f0a8303a7b5cc3fa07109c2e346cec7c0a16b40de462992ce943")
        #expect(key.name == "My Production Key")
        #expect(key.limit == 100)
        #expect(key.limitRemaining == 74.5)
        #expect(key.usage == 25.5)
        #expect(key.byokUsage == 17.38)
        #expect(key.disabled == false)
        #expect(key.workspaceID == "0df9e665-d932-5740-b2c7-b52af166bc11")

        let singleKey = try await service.getKey(hash: "h")
        #expect(singleKey == key) // identical spec example
        #expect(singleKey.limitReset == "monthly")

        let byok = try await service.getByokCredentials()
        #expect(byok.totalCount == 1)
        let credential = try #require(byok.data?.first)
        #expect(credential.id == "11111111-2222-3333-4444-555555555555")
        #expect(credential.provider == "openai")
        // The label is a MASKED snippet — the credential value is write-only
        // upstream and must never appear in a response model.
        #expect(credential.label == "sk-...AbCd")
        #expect(credential.sortOrder == 0)

        let singleCredential = try await service.getByokCredential(id: "b")
        #expect(singleCredential == credential)

        let guardrails = try await service.getGuardrails()
        #expect(guardrails.totalCount == 1)
        let guardrail = try #require(guardrails.data?.first)
        #expect(guardrail.limitUSD == 100)
        #expect(guardrail.resetInterval == "monthly")
        #expect(guardrail.allowedProviders == ["openai", "anthropic", "google"])

        let singleGuardrail = try await service.getGuardrail(id: "g")
        #expect(singleGuardrail.enforceZDRAnthropic == true)
        #expect(singleGuardrail.enforceZDRGoogle == false)
        let builtins = try #require(singleGuardrail.contentFilterBuiltins)
        #expect(builtins.first?.objectValue?["slug"]?.stringValue == "email")

        let workspaces = try await service.getWorkspaces()
        #expect(workspaces.totalCount == 1)
        let workspace = try #require(workspaces.data?.first)
        #expect(workspace.slug == "production")
        #expect(workspace.defaultTextModel == "openai/gpt-4o")
        #expect(workspace.ioLoggingSamplingRate == 1)

        let singleWorkspace = try await service.getWorkspace(id: "w")
        #expect(singleWorkspace == workspace)

        let members = try await service.getOrganizationMembers()
        #expect(members.totalCount == 25)
        let member = try #require(members.data?.first)
        #expect(member.role == "org:member")
        #expect(member.firstName == "Jane")

        let destinations = try await service.getObservabilityDestinations()
        #expect(destinations.totalCount == 1)
        let destination = try #require(destinations.data?.first)
        #expect(destination.type == "langfuse")
        #expect(destination.enabled == true)
        #expect(destination.samplingRate == 1)
        #expect(destination.regions == ["global"])
        #expect(destination.config?.objectValue?["baseUrl"]?.stringValue == "https://us.cloud.langfuse.com")

        let benchmarks = try await service.getBenchmarks()
        #expect(benchmarks.data?.count == 2)
        #expect(benchmarks.meta?.version == "v1")
        #expect(benchmarks.meta?.modelCount == 1)
        #expect(benchmarks.meta?.citation == nil)
        let aa = try #require(benchmarks.data?.first)
        #expect(aa.source == "artificial-analysis")
        #expect(aa.modelPermaslug == "openai/gpt-4o")
        // The openrouter-source variant carries entirely different fields —
        // both variants decode because unknown fields are preserved in raw.
        let orItem = try #require(benchmarks.data?.last)
        #expect(orItem.source == "openrouter")
        #expect(orItem.raw?.objectValue?["benchmark_type"]?.stringValue == "gpqa_diamond")

        let appRankings = try await service.getDatasetAppRankings()
        let app = try #require(appRankings.data?.first)
        #expect(app.appID == 12345)
        #expect(app.appName == "Cline")
        #expect(app.rank == 1)
        // total_tokens is a DECIMAL STRING in the documented contract.
        #expect(app.totalTokens == "12345678")
        #expect(appRankings.meta?.startDate == "2026-05-05")
        #expect(appRankings.meta?.endDate == "2026-05-11")

        let daily = try await service.getDatasetRankingsDaily()
        let dailyItem = try #require(daily.data?.first)
        #expect(dailyItem.date == "2026-05-11")
        #expect(dailyItem.totalTokens == "987654321")

        let sessionCost = try await service.getDatasetSessionCost()
        let cost = try #require(sessionCost.data?.first)
        #expect(cost.appSlug == "hermes-agent")
        #expect(cost.medianSessionCostUSD == 1.74)
        #expect(cost.turnRange == "10-49-turns")
        #expect(sessionCost.meta?.windowDays == 30)
        #expect(sessionCost.meta?.windowEndDate == "2026-05-11")

        // All 14 scripted fixtures were consumed exactly once.
        #expect(mock.sentCount() == 14)
    }

    // MARK: (d) documented pagination and filter parameters serialize

    @Test("limit/offset pagination and resource filters serialize exactly as documented")
    func paginationAndFilters() async throws {
        let (service, mock, _) = makeService(responses: Array(repeating: .json(ManagementFixtures.keys), count: 14))

        _ = try await service.getKeys(includeDisabled: true, offset: 100, workspaceID: "ws-1")
        _ = try await service.getByokCredentials(offset: 5, limit: 10, workspaceID: "ws-1", provider: "openai")
        _ = try await service.getGuardrails(limit: 25, workspaceID: "ws-2")
        _ = try await service.getWorkspaces(offset: 50, limit: 2)
        _ = try await service.getOrganizationMembers(offset: 25, limit: 100)
        _ = try await service.getObservabilityDestinations(workspaceID: "ws-3")
        _ = try await service.getBenchmarks(
            source: .artificialAnalysis,
            taskType: .agentic,
            benchmarkType: .gpqaDiamond,
            includeRunConfig: true,
            searchEngine: "brave",
            searchSurface: .serverTool,
            arena: .builders,
            category: "coding",
            maxResults: 20
        )
        _ = try await service.getDatasetAppRankings(
            category: "coding", subcategory: "cli-agent", sort: .trending,
            startDate: "2026-05-05", endDate: "2026-05-11", limit: 50, offset: 10
        )
        _ = try await service.getDatasetRankingsDaily(
            startDate: "2026-05-05", endDate: "2026-05-11", period: .week,
            modality: .toolCalling, contextBucket: .bucket1M,
            category: "programming", languageType: "programming"
        )
        _ = try await service.getDatasetSessionCost(
            appSlug: "hermes-agent", model: "anthropic/claude-4.8-opus",
            turnRange: .tenToFortyNine, limit: 20, offset: 5
        )
        // Unset parameters are omitted entirely — "parameter absent", not "".
        _ = try await service.getKeys()
        _ = try await service.getBenchmarks()
        _ = try await service.getDatasetRankingsDaily()

        let requests = mock.sentRequests()
        #expect(requests.count == 13)

        func query(_ index: Int, _ name: String) -> [String] {
            guard let url = requests[index].url else { return [] }
            return queryValues(url, name)
        }

        // GET /keys: include_disabled, offset, workspace_id.
        #expect(query(0, "include_disabled") == ["true"])
        #expect(query(0, "offset") == ["100"])
        #expect(query(0, "workspace_id") == ["ws-1"])
        // GET /byok: offset, limit, workspace_id, provider.
        #expect(query(1, "offset") == ["5"])
        #expect(query(1, "limit") == ["10"])
        #expect(query(1, "workspace_id") == ["ws-1"])
        #expect(query(1, "provider") == ["openai"])
        // GET /guardrails, /workspaces, /organization/members, /observability.
        #expect(query(2, "limit") == ["25"])
        #expect(query(2, "workspace_id") == ["ws-2"])
        #expect(query(3, "offset") == ["50"])
        #expect(query(3, "limit") == ["2"])
        #expect(query(4, "offset") == ["25"])
        #expect(query(4, "limit") == ["100"])
        #expect(query(5, "workspace_id") == ["ws-3"])
        // GET /benchmarks documented filters.
        #expect(query(6, "source") == ["artificial-analysis"])
        #expect(query(6, "task_type") == ["agentic"])
        #expect(query(6, "benchmark_type") == ["gpqa_diamond"])
        #expect(query(6, "include_run_config") == ["true"])
        #expect(query(6, "search_engine") == ["brave"])
        #expect(query(6, "search_surface") == ["server-tool"])
        #expect(query(6, "arena") == ["builders"])
        #expect(query(6, "category") == ["coding"])
        #expect(query(6, "max_results") == ["20"])
        // Dataset filters.
        #expect(query(7, "category") == ["coding"])
        #expect(query(7, "subcategory") == ["cli-agent"])
        #expect(query(7, "sort") == ["trending"])
        #expect(query(7, "start_date") == ["2026-05-05"])
        #expect(query(7, "end_date") == ["2026-05-11"])
        #expect(query(7, "limit") == ["50"])
        #expect(query(7, "offset") == ["10"])
        #expect(query(8, "period") == ["week"])
        #expect(query(8, "modality") == ["tool_calling"])
        #expect(query(8, "context_bucket") == ["1M"])
        #expect(query(8, "language_type") == ["programming"])
        #expect(query(9, "app_slug") == ["hermes-agent"])
        #expect(query(9, "model") == ["anthropic/claude-4.8-opus"])
        #expect(query(9, "turn_range") == ["10-49-turns"])
        // Unset filters are absent, not empty strings.
        #expect(query(10, "include_disabled") == [])
        #expect(query(10, "offset") == [])
        #expect(query(11, "source") == [])
        #expect(query(12, "period") == [])
        // No stray '=' percent-encoding in the query.
        let firstURL = try #require(requests[0].url)
        let components = try #require(URLComponents(url: firstURL, resolvingAgainstBaseURL: false))
        let rawQuery = try #require(components.percentEncodedQuery)
        #expect(rawQuery.contains("%3D") == false)
    }

    @Test("list totals decode and items match by ID, never by array position")
    func matchByIDNotPosition() async throws {
        // Deliberately out of alphabetical/hash order.
        let fixture = """
        {"data":[
          {"hash":"aaaa","name":"Second","usage":2.0},
          {"hash":"zzzz","name":"First","usage":1.0},
          {"hash":"mmmm","name":"Third","usage":3.0}
        ]}
        """
        let (service, _, _) = makeService(responses: [.json(fixture)])
        let keys = try await service.getKeys()
        #expect(keys.data?.count == 3)

        let first = try #require(keys.item(id: "zzzz", by: \.hash))
        #expect(first.name == "First")
        let third = try #require(keys.item(id: "mmmm", by: \.hash))
        #expect(third.name == "Third")
        #expect(keys.item(id: "missing", by: \.hash) == nil)

        let byokFixture = """
        {"data":[
          {"id":"b-2","provider":"anthropic"},
          {"id":"b-1","provider":"openai"}
        ],"total_count":2}
        """
        let (service2, _, _) = makeService(responses: [.json(byokFixture)])
        let byok = try await service2.getByokCredentials()
        let openai = try #require(byok.item(id: "b-1", by: \.id))
        #expect(openai.provider == "openai")
        #expect(byok.totalCount == 2)
    }

    // MARK: (e) 401/403 map to typed credential-role errors

    @Test("401 and 403 map to the typed management-key rejection with an actionable message")
    func credentialRejections() async {
        let (service401, _, _) = makeService(responses: [
            .status(401, #"{"error":{"message":"Invalid management key"}}"#),
        ])
        await #expect {
            _ = try await service401.getKeys()
        } throws: { error in
            error as? ManagementServiceError == .managementKeyRejected(
                status: 401, message: "Invalid management key"
            )
        }

        let (service403, _, _) = makeService(responses: [
            .status(403, #"{"error":{"message":"Key lacks the required scope"}}"#),
        ])
        do {
            _ = try await service403.getGuardrails()
            Issue.record("expected a rejection")
        } catch let error as ManagementServiceError {
            #expect(error == .managementKeyRejected(status: 403, message: "Key lacks the required scope"))
            // Actionable: points at the fix and never reads as "no data".
            let text = error.errorDescription ?? ""
            #expect(text.contains("HTTP 403"))
            #expect(text.contains("management key"))
        } catch {
            Issue.record("unexpected error type: \(error)")
        }

        // Other statuses stay generic typed HTTP failures.
        let (service500, _, _) = makeService(responses: [
            .status(500, #"{"error":{"message":"boom"}}"#),
        ])
        await #expect {
            _ = try await service500.getWorkspaces()
        } throws: { error in
            error as? ManagementServiceError == .http(status: 500, message: "boom")
        }
    }

    // MARK: (f) unknown optional fields never break decoding

    @Test("unknown forward-compatible fields decode and survive in raw")
    func unknownFieldsTolerated() async throws {
        let fixture = """
        {"data":[{
          "hash":"h1","name":"Future Key","usage":1.5,
          "unknown_future_field":{"nested":[1,2,3],"flag":true},
          "another_new_string":"x","yet_a_new_number":42
        }],"total_count":1,"unknown_envelope_field":"kept"}
        """
        let (service, _, _) = makeService(responses: [.json(fixture)])
        let keys = try await service.getKeys()
        let key = try #require(keys.data?.first)
        #expect(key.hash == "h1")
        #expect(key.name == "Future Key")
        // The unknown item field survives in the preserved raw item.
        #expect(key.raw?.objectValue?["unknown_future_field"]?.objectValue?["flag"]?.boolValue == true)
        #expect(key.raw?.objectValue?["yet_a_new_number"]?.doubleValue == 42)
        #expect(key.raw?.objectValue?["another_new_string"]?.stringValue == "x")

        // Same tolerance on the observability destination's oneOf variants:
        // a destination type ORB has never seen still decodes.
        let unknownDestination = """
        {"data":[{"id":"d1","type":"brand-new-vendor","name":"New","workspace_id":"w1"}],"total_count":1}
        """
        let (service2, _, _) = makeService(responses: [.json(unknownDestination)])
        let destinations = try await service2.getObservabilityDestinations()
        #expect(destinations.data?.first?.type == "brand-new-vendor")
    }

    // MARK: URL policy and secret hygiene

    @Test("path segments are percent-encoded and the key never appears in any URL")
    func segmentEncodingAndSecretHygiene() async throws {
        let (service, mock, _) = makeService(responses: [
            .json(ManagementFixtures.workspaceSingle),
            .json(ManagementFixtures.byokSingle),
        ])
        _ = try await service.getWorkspace(id: "ws 1&x")
        // A segment containing a slash is rejected before any request.
        _ = try? await service.getByokCredential(id: "id/with..dots")
        let requests = mock.sentRequests()
        #expect(requests.count == 1) // the second call never sent a request

        let url = try #require(requests.first?.url)
        #expect(url.path == "/api/v1/workspaces/ws 1&x")
        #expect(url.absoluteString == "https://openrouter.ai/api/v1/workspaces/ws%201%26x")

        // The management key rides only in the Authorization header.
        for request in requests {
            #expect(request.url?.query?.contains("Bearer") != true)
            #expect(!request.url!.absoluteString.contains("management-secret"))
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer management-secret")
        }
    }

    @Test("traversal segments and empty IDs are rejected before any credential work")
    func maliciousSegmentsRejected() async {
        let (service, mock, _) = makeService(responses: [])
        for bad in ["..", ".", "", "a/b", "a?b", "a#b"] {
            await #expect {
                _ = try await service.getWorkspace(id: bad)
            } throws: { error in
                if case ManagementServiceError.untrustedURL = error as? ManagementServiceError ?? .invalidRequest("other") { return true }
                return false
            }
        }
        #expect(mock.sentCount() == 0)
    }

    // MARK: Decoding failure is typed

    @Test("a 200 response with an unparseable body maps to the typed decoding error")
    func malformedBodyMapsToDecoding() async {
        let (service, _, _) = makeService(responses: [.json("{oops not json")])
        await #expect {
            _ = try await service.getKeys()
        } throws: { error in
            if case ManagementServiceError.decoding = error as? ManagementServiceError ?? .invalidRequest("other") { return true }
            return false
        }
    }
}
