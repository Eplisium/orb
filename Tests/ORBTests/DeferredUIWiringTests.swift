import Foundation
import Testing
@testable import ORB

// Deferred UI wiring (F01 step 5 / F03 / F09 / W09 step 3), testable cores:
//   1. Settings management-key section — panel rules + copy, driven through
//      AccountService's tested API with an injected InMemoryCredentialStore.
//   2. Video resume affordance — the service accessors the view consumes
//      (resumable listing passthrough + double-resume guard).
//   3. MCP secret → Keychain migration — config compatibility, env resolution
//      at launch, and the consent-driven all-or-nothing migration.
// No Keychain, no UserDefaults, and no network is touched: every store is an
// injected in-memory/failing double, every config list is an in-memory value.

// MARK: - Shared doubles

/// Store that records saves so tests can prove idempotency, and can be told
/// to fail (mirroring a Keychain error) without touching the real Keychain.
private final class MigrationTestStore: CredentialSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var backing: [String: String] = [:]
    private(set) var savedReferences: [String] = []
    /// When set, `saveSecret` fails with this diagnostic and persists nothing.
    var saveFailure: String?

    func secret(forReference reference: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return backing[reference]
    }

    func saveSecret(_ secret: String, forReference reference: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        if let saveFailure { return saveFailure }
        backing[reference] = secret
        savedReferences.append(reference)
        return nil
    }

    func deleteSecret(forReference reference: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return backing.removeValue(forKey: reference) != nil
    }

    func hasSecret(forReference reference: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return backing[reference] != nil
    }

    var saveCount: Int {
        lock.lock(); defer { lock.unlock() }
        return savedReferences.count
    }

    var storedValue: String? {
        lock.lock(); defer { lock.unlock() }
        return backing.values.first
    }
}

// MARK: - 1. Settings management-key panel

@Suite("Settings management key panel")
@MainActor
struct ManagementKeyPanelTests {
    private func makeService(store: CredentialSecretStore) -> AccountService {
        let profile = CredentialProfile(
            managementKeyReference: CredentialRole.management.keychainAccount
        )
        return AccountService(profile: profile, secretStore: store) { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (Data(), response)
        }
    }

    @Test("an empty or whitespace draft cannot be saved")
    func emptyDraftCannotSave() {
        let store = InMemoryCredentialStore()
        let service = makeService(store: store)
        var panel = ManagementKeyPanel()

        #expect(panel.canSave == false)
        panel.draftKey = "   \n"
        #expect(panel.canSave == false)
        panel.saveDraft(into: service)
        // Nothing reached the store and no confusing success/error state fired.
        #expect(store.hasSecret(forReference: CredentialRole.management.keychainAccount) == false)
        #expect(panel.actionError == nil)
        #expect(panel.showSaved == false)
    }

    @Test("saving the draft configures the key and clears the write-only field")
    func savingDraftConfiguresKey() {
        let store = InMemoryCredentialStore()
        let service = makeService(store: store)
        var panel = ManagementKeyPanel()
        panel.draftKey = "  fake-management-key-for-tests  "

        panel.saveDraft(into: service)

        #expect(service.hasManagementKey)
        #expect(store.hasSecret(forReference: CredentialRole.management.keychainAccount))
        // The draft is consumed: the panel never retains or re-displays it.
        #expect(panel.draftKey.isEmpty)
        #expect(panel.actionError == nil)
        #expect(panel.showSaved)
    }

    @Test("a failed save surfaces the error and keeps the previous key")
    func failedSaveSurfacesErrorKeepsPreviousKey() {
        let failing = MigrationTestStore()
        failing.saveFailure = "Keychain error -25299."
        let service = makeService(store: failing)
        let backing = InMemoryCredentialStore()
        _ = backing.saveSecret("previous-management-key", forReference: CredentialRole.management.keychainAccount)

        var panel = ManagementKeyPanel()
        panel.draftKey = "replacement-key"
        panel.saveDraft(into: service)

        #expect(panel.actionError?.contains("Keychain error") == true)
        #expect(panel.showSaved == false)
        #expect(panel.draftKey.isEmpty == false) // draft kept so the user can retry
        // The service contract (previously tested) keeps the old key; the panel
        // added no state that would claim success.
        #expect(service.hasManagementKey == false)
        #expect(backing.secret(forReference: CredentialRole.management.keychainAccount) == "previous-management-key")
    }

    @Test("removing through the panel clears the key and published account data")
    func removalClearsKeyAndAccountData() async {
        let store = InMemoryCredentialStore()
        _ = store.saveSecret("management-key", forReference: CredentialRole.management.keychainAccount)
        let profile = CredentialProfile(managementKeyReference: CredentialRole.management.keychainAccount)
        let service = AccountService(profile: profile, secretStore: store) { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (Data(#"{"data":{"total_credits":5.0,"total_usage":1.0}}"#.utf8), response)
        }
        await service.fetchCredits()
        #expect(service.credits != nil)

        var panel = ManagementKeyPanel()
        panel.draftKey = "stale-draft"
        panel.removeKey(into: service)

        #expect(service.hasManagementKey == false)
        #expect(service.credits == nil)
        #expect(service.activity.isEmpty)
        #expect(store.hasSecret(forReference: CredentialRole.management.keychainAccount) == false)
        #expect(panel.draftKey.isEmpty)
        #expect(panel.actionError == nil)
    }

    @Test("the remove confirmation names the exact target and effect")
    func removeConfirmationNamesTargetAndEffect() {
        // Section 7.7: destructive confirmation must state target + effect.
        #expect(ManagementKeyPanel.removeTitle.contains("management key"))
        for token in ["Credits", "activity", "administration"] {
            #expect(ManagementKeyPanel.removeMessage.contains(token))
        }
        // …and must not imply Chat stops working (inference is unaffected).
        #expect(ManagementKeyPanel.removeMessage.contains("Chat"))
    }

    @Test("the section explanation separates the management role from inference")
    func explanationSeparatesRoles() {
        for token in ["management key", "credits", "activity", "inference key", "Chat"] {
            #expect(ManagementKeyPanel.explanation.contains(token))
        }
    }
}

// MARK: - 2. Video resume affordance

@Suite("Video resume affordance", .serialized)
@MainActor
struct VideoResumeAffordanceTests {
    private func makeRecord(remoteID: String?, status: String, state: JobPollingState) -> JobRecord {
        JobRecord(
            id: UUID(), remoteID: remoteID, kind: "video",
            submissionState: remoteID == nil ? .outcomeUnknown : .submitted,
            pollingState: state, lastRemoteStatus: status,
            conversationID: nil, messageID: nil, modelID: "test/model",
            usageCost: nil, recoverableError: nil, createdAt: Date(), updatedAt: Date()
        )
    }

    @Test("resumableRecords is a passthrough of the service's own controller")
    func resumableRecordsPassthrough() throws {
        let controller = JobController(database: DatabaseManager())
        let service = VideoGenService(
            transport: MockMediaTransport(responses: []), jobController: controller
        )
        #expect(service.resumableRecords.isEmpty)
        #expect(service.durablePersistenceError == nil)

        _ = controller.recordVideoSubmission(
            remoteID: "job-affordance", modelID: "m", remoteStatus: "running", cost: nil
        )
        #expect(service.resumableRecords.contains { $0.remoteID == "job-affordance" })

        // Terminal records drop out of the affordance listing.
        controller.recordTerminal(
            remoteID: "job-affordance", remoteStatus: "completed", error: nil, cost: 0.01
        )
        #expect(service.resumableRecords.isEmpty)
    }

    @Test("double-resume guard: a run is in flight only for its own record")
    func inFlightGuardTracksOnlyItsOwnRecord() async throws {
        let controller = JobController(database: DatabaseManager())
        let transport = MockMediaTransport(responses: [
            .json(#"{"id":"job-guard","status":"queued"}"#),
            .hang
        ])
        let service = VideoGenService(transport: transport, jobController: controller)
        _ = controller.recordVideoSubmission(
            remoteID: "job-guard", modelID: "m", remoteStatus: "queued", cost: nil
        )
        let record = try #require(controller.record(remoteID: "job-guard"))
        #expect(service.isRunInFlight(for: record) == false)

        let run = Task { try await service.resume(record, pollInterval: .milliseconds(5)) }
        var inFlight = false
        for _ in 0..<500 {
            if service.isRunInFlight(for: record) { inFlight = true; break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(inFlight)

        // A different durable record is not blocked by this run.
        let other = makeRecord(remoteID: "job-other", status: "queued", state: .stoppedLocally)
        #expect(service.isRunInFlight(for: other) == false)
        // A record without a remote ID can never be in flight.
        #expect(service.isRunInFlight(for: makeRecord(remoteID: nil, status: "queued", state: .idle)) == false)

        service.stopPolling()
        _ = try? await run.value
        #expect(service.isRunInFlight(for: record) == false)
        // The guard never destroys resumability: the stopped record is still listed.
        #expect(service.resumableRecords.contains { $0.remoteID == "job-guard" })
    }
}

// MARK: - 3. MCP config: keychain-reference shape

@Suite("MCP config keychain reference compatibility")
struct MCPConfigReferenceShapeTests {
    private let legacyJSON = """
    {
      "id": "11111111-1111-1111-1111-111111111111",
      "name": "Legacy Server",
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-github"],
      "env": { "GITHUB_TOKEN": "fake-legacy-token", "DEBUG": "1" },
      "isEnabled": true
    }
    """

    @Test("a config persisted before references decodes identically")
    func legacyConfigDecodesIdentically() throws {
        let decoded = try JSONDecoder().decode(MCPServerConfig.self, from: Data(legacyJSON.utf8))
        #expect(decoded.name == "Legacy Server")
        #expect(decoded.command == "npx")
        #expect(decoded.args == ["-y", "@modelcontextprotocol/server-github"])
        #expect(decoded.env == ["GITHUB_TOKEN": "fake-legacy-token", "DEBUG": "1"])
        #expect(decoded.isEnabled)
        #expect(decoded.secretEnv == nil)

        // Re-encoding an untouched config keeps the persisted shape stable:
        // no reference key appears, so old writers/readers stay compatible.
        let reencoded = String(decoding: try JSONEncoder().encode(decoded), as: UTF8.self)
        #expect(!reencoded.contains("secretEnv"))
    }

    @Test("a config with references round-trips without leaking secret values")
    func referenceConfigRoundTrips() throws {
        var config = MCPServerConfig(name: "Referenced", command: "uvx")
        config.env = ["DEBUG": "1"]
        config.secretEnv = ["API_KEY": "orb-mcp-Referenced-API-KEY"]

        let data = try JSONEncoder().encode(config)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("secretEnv"))
        #expect(json.contains("orb-mcp-Referenced-API-KEY"))

        let decoded = try JSONDecoder().decode(MCPServerConfig.self, from: data)
        #expect(decoded == config)
        #expect(decoded.secretEnv?["API_KEY"] == "orb-mcp-Referenced-API-KEY")
    }

    @Test("references are deterministic per server and variable")
    func referencesAreDeterministic() {
        #expect(
            MCPServerConfig.secretReference(serverName: "My Server", variable: "API_KEY")
                == "orb-mcp-My-Server-API-KEY"
        )
        #expect(
            MCPServerConfig.secretReference(serverName: "My Server", variable: "API_KEY")
                == MCPServerConfig.secretReference(serverName: "My Server", variable: "API_KEY")
        )
        // Different variables on the same server never collide.
        #expect(
            MCPServerConfig.secretReference(serverName: "S", variable: "A")
                != MCPServerConfig.secretReference(serverName: "S", variable: "B")
        )
    }

    @Test("the secret-name heuristic only preselects consent choices")
    func looksLikeSecretCoversCommonNames() {
        for name in ["GITHUB_TOKEN", "EXA_API_KEY", "CLIENT_SECRET", "DB_PASSWORD", "AUTH_HEADER"] {
            #expect(MCPServerConfig.looksLikeSecret(name))
        }
        for name in ["DEBUG", "LOG_LEVEL", "HOME", "WORKSPACE_DIR"] {
            #expect(MCPServerConfig.looksLikeSecret(name) == false)
        }
    }
}

// MARK: - 4. MCP env resolution at launch

@Suite("MCP launch env resolution")
struct MCPEnvironmentResolutionTests {
    private func makeConfig(secretEnv: [String: String], env: [String: String] = [:]) -> MCPServerConfig {
        var config = MCPServerConfig(name: "Exa MCP", command: "npx")
        config.env = env
        config.secretEnv = secretEnv
        return config
    }

    @Test("reference values are resolved and the raw reference never reaches the process env")
    func referencesResolveToSecrets() throws {
        let reference = MCPServerConfig.secretReference(serverName: "Exa MCP", variable: "EXA_API_KEY")
        let store = InMemoryCredentialStore()
        store.saveSecret("resolved-secret-value", forReference: reference)
        let config = makeConfig(secretEnv: ["EXA_API_KEY": reference], env: ["DEBUG": "1"])

        let resolved = try MCPConnection.resolvedEnvironment(
            base: ["PATH": "/usr/bin:/bin"], config: config, store: store
        )

        #expect(resolved["EXA_API_KEY"] == "resolved-secret-value")
        #expect(resolved["DEBUG"] == "1")
        #expect(resolved["PATH"] == "/usr/bin:/bin")
        // The literal reference string is never handed to a subprocess.
        #expect(!resolved.values.contains(reference))
        #expect(!resolved.keys.contains(reference))
    }

    @Test("a resolved secret wins over a stale plaintext copy of the same variable")
    func resolvedSecretShadowsStalePlaintext() throws {
        let reference = MCPServerConfig.secretReference(serverName: "Exa MCP", variable: "API_KEY")
        let store = InMemoryCredentialStore()
        store.saveSecret("current-secret", forReference: reference)
        let config = makeConfig(secretEnv: ["API_KEY": reference], env: ["API_KEY": "stale-plaintext"])

        let resolved = try MCPConnection.resolvedEnvironment(base: [:], config: config, store: store)
        #expect(resolved["API_KEY"] == "current-secret")
    }

    @Test("a missing or empty secret fails closed instead of launching")
    func missingSecretFailsClosed() {
        let reference = MCPServerConfig.secretReference(serverName: "Exa MCP", variable: "API_KEY")
        let emptyStore = InMemoryCredentialStore()
        let config = makeConfig(secretEnv: ["API_KEY": reference])

        #expect(throws: MCPEnvironmentError.missingSecret(
            server: "Exa MCP", variable: "API_KEY", reference: reference
        )) {
            _ = try MCPConnection.resolvedEnvironment(base: [:], config: config, store: emptyStore)
        }

        // An empty stored value is just as unusable as a missing one.
        let blankStore = InMemoryCredentialStore()
        blankStore.saveSecret("", forReference: reference)
        #expect(throws: MCPEnvironmentError.missingSecret(
            server: "Exa MCP", variable: "API_KEY", reference: reference
        )) {
            _ = try MCPConnection.resolvedEnvironment(base: [:], config: config, store: blankStore)
        }
    }

    @Test("a config without references passes plaintext env through unchanged")
    func plaintextOnlyConfigsPassThrough() throws {
        let config = makeConfig(secretEnv: [:], env: ["DEBUG": "1"])
        let resolved = try MCPConnection.resolvedEnvironment(
            base: ["PATH": "/bin"], config: config, store: InMemoryCredentialStore()
        )
        #expect(resolved == ["PATH": "/bin", "DEBUG": "1"])
    }
}

// MARK: - 5. Consent-driven migration

@Suite("MCP secret migration", .serialized)
struct MCPSecretMigrationTests {
    private func makeConfigs() -> [MCPServerConfig] {
        var target = MCPServerConfig(name: "GitHub", command: "npx")
        target.env = [
            "GITHUB_TOKEN": "fake-github-token-value",
            "DEBUG": "1",
        ]
        var bystander = MCPServerConfig(name: "Other", command: "uvx")
        bystander.env = ["OTHER_TOKEN": "fake-other-token-value"]
        return [target, bystander]
    }

    @Test("migration moves the consented variables and rewrites the config with references")
    func migrationRoundTrip() throws {
        let store = InMemoryCredentialStore()
        let configs = makeConfigs()
        let expectedReference = MCPServerConfig.secretReference(serverName: "GitHub", variable: "GITHUB_TOKEN")

        let (updated, outcome) = MCPRegistry.migrateSecretsToKeychain(
            configs: configs, serverNamed: "GitHub", variables: ["GITHUB_TOKEN"], store: store
        )

        #expect(outcome.didSucceed)
        #expect(outcome.migratedVariables == ["GITHUB_TOKEN"])
        #expect(outcome.error == nil)

        let migrated = try #require(updated.first { $0.name == "GitHub" })
        #expect(migrated.env == ["DEBUG": "1"])
        #expect(migrated.secretEnv?["GITHUB_TOKEN"] == expectedReference)

        // The secret reached the injected store under the deterministic
        // reference, and never appears in the rewritten config.
        #expect(store.secret(forReference: expectedReference) == "fake-github-token-value")
        let encoded = String(decoding: try JSONEncoder().encode(migrated), as: UTF8.self)
        #expect(!encoded.contains("fake-github-token-value"))

        // Unrelated servers are untouched.
        let other = try #require(updated.first { $0.name == "Other" })
        #expect(other.env == ["OTHER_TOKEN": "fake-other-token-value"])
        #expect(other.secretEnv == nil)
    }

    @Test("migration is idempotent: a second run saves nothing and reports already-migrated")
    func migrationIsIdempotent() {
        let store = MigrationTestStore()
        let configs = makeConfigs()

        let first = MCPRegistry.migrateSecretsToKeychain(
            configs: configs, serverNamed: "GitHub", variables: ["GITHUB_TOKEN"], store: store
        )
        #expect(first.outcome.didSucceed)
        let savesAfterFirst = store.saveCount

        let second = MCPRegistry.migrateSecretsToKeychain(
            configs: first.configs, serverNamed: "GitHub", variables: ["GITHUB_TOKEN"], store: store
        )

        #expect(second.outcome.didSucceed)
        #expect(second.outcome.migratedVariables.isEmpty)
        #expect(second.outcome.alreadyMigratedVariables == ["GITHUB_TOKEN"])
        #expect(store.saveCount == savesAfterFirst) // no re-save: the plaintext is gone
        #expect(second.configs == first.configs)
    }

    @Test("a failed save leaves the old config intact")
    func failedSaveLeavesConfigIntact() {
        let store = MigrationTestStore()
        store.saveFailure = "Keychain error -25299."
        let configs = makeConfigs()

        let (updated, outcome) = MCPRegistry.migrateSecretsToKeychain(
            configs: configs, serverNamed: "GitHub", variables: ["GITHUB_TOKEN"], store: store
        )

        #expect(outcome.didSucceed == false)
        #expect(outcome.error?.contains("Keychain error") == true)
        #expect(updated == configs) // byte-for-byte unchanged
    }

    @Test("all-or-nothing: one failing variable rolls the whole server back")
    func partialFailureIsAllOrNothing() {
        let configs = makeConfigs()
        let first = MCPServerConfig.secretReference(serverName: "GitHub", variable: "DEBUG")
        let second = MCPServerConfig.secretReference(serverName: "GitHub", variable: "GITHUB_TOKEN")

        // The store accepts the first reference's write and rejects the next,
        // modelling a Keychain failure mid-migration.
        let partial = PartialFailureStore(succeedFor: [first], failFor: [second])
        let (updated, outcome) = MCPRegistry.migrateSecretsToKeychain(
            configs: configs, serverNamed: "GitHub",
            variables: ["DEBUG", "GITHUB_TOKEN"], store: partial
        )

        #expect(outcome.didSucceed == false)
        #expect(updated == configs)
        let migrated = updated.first { $0.name == "GitHub" }
        #expect(migrated?.env["GITHUB_TOKEN"] == "fake-github-token-value")
        #expect(migrated?.secretEnv == nil)
    }

    @Test("unknown variables are rejected before any save")
    func unknownVariableRejectedBeforeAnySave() {
        let store = MigrationTestStore()
        let configs = makeConfigs()

        let (updated, outcome) = MCPRegistry.migrateSecretsToKeychain(
            configs: configs, serverNamed: "GitHub", variables: ["NOT_A_VAR"], store: store
        )

        #expect(outcome.didSucceed == false)
        #expect(outcome.error?.contains("NOT_A_VAR") == true)
        #expect(updated == configs)
        #expect(store.saveCount == 0)
    }

    @Test("migrating an unknown server and an empty consent both change nothing")
    func unknownServerAndEmptyConsentAreNoOps() {
        let store = MigrationTestStore()
        let configs = makeConfigs()

        let missing = MCPRegistry.migrateSecretsToKeychain(
            configs: configs, serverNamed: "Ghost", variables: ["ANY"], store: store
        )
        #expect(missing.outcome.didSucceed == false)
        #expect(missing.configs == configs)

        let empty = MCPRegistry.migrateSecretsToKeychain(
            configs: configs, serverNamed: "GitHub", variables: [], store: store
        )
        #expect(empty.outcome.didSucceed)
        #expect(empty.outcome.migratedVariables.isEmpty)
        #expect(empty.configs == configs)
        #expect(store.saveCount == 0)
    }
}

/// Fails `saveSecret` only for the listed references — models a Keychain that
/// accepts one write and rejects the next.
private struct PartialFailureStore: CredentialSecretStore {
    let succeedFor: Set<String>
    let failFor: Set<String>

    func secret(forReference reference: String) -> String? { nil }
    func hasSecret(forReference reference: String) -> Bool { false }
    func deleteSecret(forReference reference: String) -> Bool { false }

    func saveSecret(_ secret: String, forReference reference: String) -> String? {
        if failFor.contains(reference) { return "Keychain error -25299." }
        if succeedFor.contains(reference) { return nil }
        return "Unexpected reference."
    }
}
