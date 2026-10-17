import Foundation
import Testing
@testable import ORB

/// Secret references must identify one (config, variable) pair unambiguously.
/// Sanitized display names are not unique: `prod_api` and `prod-api` both
/// sanitize to `prod-api`. Tests use `InMemoryCredentialStore` only.
@Suite("MCP secret reference identity")
struct MCPSecretReferenceTests {
    private func config(_ name: String, env: [String: String]) -> MCPServerConfig {
        var config = MCPServerConfig(name: name, command: "npx")
        config.env = env
        return config
    }

    @Test("servers whose names sanitize identically get distinct references")
    func punctuationCollidingServersDoNotShareReferences() {
        let a = config("prod_api", env: [:])
        let b = config("prod-api", env: [:])
        #expect(
            MCPServerConfig.secretReference(configID: a.id, variable: "API_KEY")
                != MCPServerConfig.secretReference(configID: b.id, variable: "API_KEY")
        )
    }

    @Test("variables differing only by punctuation get distinct references")
    func punctuationCollidingVariablesDoNotShareReferences() {
        let id = UUID()
        let underscore = MCPServerConfig.secretReference(configID: id, variable: "A_B")
        let dash = MCPServerConfig.secretReference(configID: id, variable: "A-B")
        let dot = MCPServerConfig.secretReference(configID: id, variable: "A.B")
        #expect(Set([underscore, dash, dot]).count == 3)
        // The legacy scheme collapsed them — this is the bug being fixed.
        #expect(
            MCPServerConfig.legacySecretReference(serverName: "s", variable: "A_B")
                == MCPServerConfig.legacySecretReference(serverName: "s", variable: "A-B")
        )
    }

    @Test("references never embed the raw variable name or other config's identity")
    func referenceShape() {
        let id = UUID()
        let reference = MCPServerConfig.secretReference(configID: id, variable: "MY SECRET/TOKEN")
        #expect(reference.hasPrefix("orb-mcp-v2-\(id.uuidString.lowercased())-"))
        #expect(!reference.contains(" "))
        #expect(!reference.contains("/"))
    }

    @Test("migrating prod_api and prod-api keeps both secrets, each under its own reference")
    func collidingServersMigrateWithoutOverwrite() throws {
        let store = InMemoryCredentialStore()
        var configs = [
            config("prod_api", env: ["API_KEY": "secret-underscore"]),
            config("prod-api", env: ["API_KEY": "secret-dash"]),
        ]
        for name in ["prod_api", "prod-api"] {
            let result = MCPRegistry.migrateSecretsToKeychain(
                configs: configs, serverNamed: name, variables: ["API_KEY"], store: store
            )
            #expect(result.outcome.didSucceed)
            configs = result.configs
        }

        let underscore = try #require(configs.first { $0.name == "prod_api" })
        let dash = try #require(configs.first { $0.name == "prod-api" })
        let underscoreRef = try #require(underscore.secretEnv?["API_KEY"])
        let dashRef = try #require(dash.secretEnv?["API_KEY"])
        #expect(underscoreRef != dashRef)
        #expect(store.secret(forReference: underscoreRef) == "secret-underscore")
        #expect(store.secret(forReference: dashRef) == "secret-dash")

        let resolvedA = try MCPConnection.resolvedEnvironment(base: [:], config: underscore, store: store)
        let resolvedB = try MCPConnection.resolvedEnvironment(base: [:], config: dash, store: store)
        #expect(resolvedA["API_KEY"] == "secret-underscore")
        #expect(resolvedB["API_KEY"] == "secret-dash")
    }

    @Test("an already-stored legacy reference still resolves at launch")
    func legacyReferencesStillResolve() throws {
        let store = InMemoryCredentialStore()
        let legacy = MCPServerConfig.legacySecretReference(serverName: "Exa MCP", variable: "EXA_API_KEY")
        #expect(store.saveSecret("legacy-secret", forReference: legacy) == nil)
        var existing = config("Exa MCP", env: ["DEBUG": "1"])
        existing.secretEnv = ["EXA_API_KEY": legacy]

        let resolved = try MCPConnection.resolvedEnvironment(base: [:], config: existing, store: store)
        #expect(resolved["EXA_API_KEY"] == "legacy-secret")
        #expect(resolved["DEBUG"] == "1")
        #expect(!resolved.values.contains(legacy))
    }

    @Test("re-running migration on a legacy-referenced variable leaves it alone")
    func legacyReferencesAreNotRewritten() {
        let store = InMemoryCredentialStore()
        let legacy = MCPServerConfig.legacySecretReference(serverName: "Exa MCP", variable: "EXA_API_KEY")
        _ = store.saveSecret("legacy-secret", forReference: legacy)
        var existing = config("Exa MCP", env: [:])
        existing.secretEnv = ["EXA_API_KEY": legacy]

        let result = MCPRegistry.migrateSecretsToKeychain(
            configs: [existing], serverNamed: "Exa MCP", variables: ["EXA_API_KEY"], store: store
        )
        #expect(result.outcome.didSucceed)
        #expect(result.outcome.alreadyMigratedVariables == ["EXA_API_KEY"])
        #expect(result.configs == [existing])
        #expect(store.secret(forReference: legacy) == "legacy-secret")
    }

    @Test("a new migration does not touch a legacy secret owned by a colliding server")
    func newMigrationLeavesLegacyOwnerAlone() throws {
        let store = InMemoryCredentialStore()
        // `prod_api` migrated earlier under the legacy scheme.
        let legacy = MCPServerConfig.legacySecretReference(serverName: "prod_api", variable: "API_KEY")
        _ = store.saveSecret("owned-by-underscore", forReference: legacy)
        var owner = config("prod_api", env: [:])
        owner.secretEnv = ["API_KEY": legacy]
        let newcomer = config("prod-api", env: ["API_KEY": "owned-by-dash"])

        let result = MCPRegistry.migrateSecretsToKeychain(
            configs: [owner, newcomer], serverNamed: "prod-api", variables: ["API_KEY"], store: store
        )
        #expect(result.outcome.didSucceed)
        #expect(store.secret(forReference: legacy) == "owned-by-underscore")
        let migrated = try #require(result.configs.first { $0.name == "prod-api" })
        let newRef = try #require(migrated.secretEnv?["API_KEY"])
        #expect(newRef != legacy)
        #expect(store.secret(forReference: newRef) == "owned-by-dash")
        #expect(result.configs.first { $0.name == "prod_api" } == owner)
    }

    @Test("migration refuses a reference another config already owns")
    func migrationRefusesForeignOwnedReference() {
        let store = InMemoryCredentialStore()
        let target = config("target", env: ["API_KEY": "target-secret"])
        // Another config (e.g. a pasted duplicate sharing the id) already
        // points at the reference the target would use.
        let contested = MCPServerConfig.secretReference(configID: target.id, variable: "API_KEY")
        _ = store.saveSecret("someone-elses-secret", forReference: contested)
        var other = config("other", env: [:])
        other.secretEnv = ["API_KEY": contested]
        let configs = [target, other]

        let result = MCPRegistry.migrateSecretsToKeychain(
            configs: configs, serverNamed: "target", variables: ["API_KEY"], store: store
        )
        #expect(result.outcome.didSucceed == false)
        #expect(result.configs == configs)
        #expect(store.secret(forReference: contested) == "someone-elses-secret")
    }
}
