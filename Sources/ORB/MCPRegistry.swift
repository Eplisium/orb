import Foundation

/// Owns every configured MCP server: persistence, connection lifecycle, tool
/// aggregation, and call routing.
///
/// An actor so the agent runner can resolve tools and dispatch calls
/// concurrently without racing the connection table.
/// Everything a connection advertises, captured by the settings "Test" button.
struct MCPProbeReport: Sendable {
    let serverInfo: String?
    let tools: [MCPToolDescriptor]
    let resources: [MCPResourceDescriptor]
    let prompts: [MCPPromptDescriptor]

    /// One-line summary of the server's full capability surface.
    var summary: String {
        var parts = ["\(tools.count) tool(s)"]
        if !resources.isEmpty { parts.append("\(resources.count) resource(s)") }
        if !prompts.isEmpty { parts.append("\(prompts.count) prompt(s)") }
        return parts.joined(separator: ", ")
    }

    var detail: String {
        var lines: [String] = []
        if !tools.isEmpty {
            lines.append("Tools: " + tools.prefix(6).map(\.toolName).joined(separator: ", "))
        }
        if !resources.isEmpty {
            lines.append("Resources: " + resources.prefix(4).map(\.name).joined(separator: ", "))
        }
        if !prompts.isEmpty {
            lines.append("Prompts: " + prompts.prefix(4).map(\.name).joined(separator: ", "))
        }
        return lines.joined(separator: "\n")
    }
}

/// Result of a consent-driven secret migration for one MCP server (F01
/// step 5). Reported to the settings UI; carries variable NAMES only.
struct MCPSecretMigrationOutcome: Sendable, Equatable {
    let serverName: String
    /// Variables moved into the store by this call.
    let migratedVariables: [String]
    /// Variables that were already keychain references and were left alone.
    let alreadyMigratedVariables: [String]
    /// nil on success; otherwise a diagnostic. On failure the submitted
    /// configs are returned unchanged.
    let error: String?

    var didSucceed: Bool { error == nil }
}

actor MCPRegistry {
    static let shared = MCPRegistry()

    /// Defaults remain production-backed; tests supply an isolated in-memory source.
    private let configProvider: @Sendable () -> [MCPServerConfig]
    /// Injectable construction also permits deterministic suspended-startup tests.
    private let connectionFactory: @Sendable (MCPServerConfig) async -> MCPConnection

    init(
        configProvider: @escaping @Sendable () -> [MCPServerConfig] = { MCPRegistry.loadConfigs() },
        connectionFactory: @escaping @Sendable (MCPServerConfig) async -> MCPConnection = { MCPConnection(config: $0) }
    ) {
        self.configProvider = configProvider
        self.connectionFactory = connectionFactory
    }

    private var connections: [String: MCPConnection] = [:]
    /// Exact launch snapshots, not just names/UUIDs. Never log these (env may
    /// contain plaintext credentials). A replacement UUID is a new identity.
    private var connectedConfigs: [String: MCPServerConfig] = [:]
    private var lastErrors: [String: String] = [:]
    private var failedConfigs: [String: MCPServerConfig] = [:]
    private var didLoad = false

    private static let defaultsKey = "orb.mcp.servers"

    // MARK: - Configuration persistence

    nonisolated static func loadConfigs() -> [MCPServerConfig] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let configs = try? JSONDecoder().decode([MCPServerConfig].self, from: data) else {
            return []
        }
        return configs
    }

    nonisolated static func saveConfigs(_ configs: [MCPServerConfig]) {
        guard let data = try? JSONEncoder().encode(configs) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
        NotificationCenter.default.post(name: configsDidChange, object: nil)
    }

    /// Posted after `saveConfigs`, so an open settings view picks up a change
    /// made elsewhere (e.g. OP Mode disabling a server) instead of later
    /// overwriting it with its stale copy.
    nonisolated static let configsDidChange = Notification.Name("ORBMCPConfigsDidChange")

    /// Imports a standard `mcpServers` JSON blob (Claude Desktop format) so
    /// users can paste an existing configuration.
    static func parseStandardConfig(_ text: String) throws -> [MCPServerConfig] {
        try parseStandardConfigReport(text).configs
    }

    /// Import result: the local (stdio) servers ORB can run, plus one plain
    /// note per entry it skipped.
    struct ImportReport: Equatable {
        var configs: [MCPServerConfig]
        var warnings: [String]
    }

    /// Like `parseStandardConfig`, but a remote (URL / HTTP / SSE) entry is
    /// skipped with a note instead of failing the whole paste, `disabled`
    /// imports as off, and `cwd` is kept. An entry with neither a command nor
    /// a URL is still an error, as is a paste with nothing ORB can run.
    static func parseStandardConfigReport(_ text: String) throws -> ImportReport {
        guard let root = JSONValue.parse(text)?.objectValue else {
            throw MCPError.protocolError("Configuration is not valid JSON.")
        }
        // Accept both a bare map and one wrapped in "mcpServers".
        let servers = root["mcpServers"]?.objectValue ?? root
        guard !servers.isEmpty else {
            throw MCPError.protocolError("No servers found. Expected an \"mcpServers\" object.")
        }
        var configs: [MCPServerConfig] = []
        var warnings: [String] = []
        for name in servers.keys.sorted() {
            guard let entry = servers[name]?.objectValue else {
                throw MCPError.protocolError("Server \"\(name)\" is missing a \"command\".")
            }
            let transport = entry["type"]?.stringValue?.lowercased() ?? entry["transport"]?.stringValue?.lowercased()
            let isRemote = entry["url"] != nil || entry["serverUrl"] != nil
                || ["http", "sse", "streamable-http", "streamablehttp"].contains(transport ?? "")
            guard let command = entry["command"]?.stringValue, !command.isEmpty else {
                if isRemote {
                    warnings.append("Skipped \"\(name)\": it is a remote (URL) server, and ORB only runs local command-line servers.")
                    continue
                }
                throw MCPError.protocolError("Server \"\(name)\" is missing a \"command\".")
            }
            var env: [String: String] = [:]
            entry["env"]?.objectValue?.forEach { key, value in
                if let string = value.stringValue { env[key] = string }
            }
            var config = MCPServerConfig(
                name: name,
                command: command,
                args: entry["args"]?.arrayValue?.compactMap(\.stringValue) ?? [],
                env: env
            )
            if entry["disabled"]?.boolValue == true { config.isEnabled = false }
            if let cwd = entry["cwd"]?.stringValue, !cwd.isEmpty { config.workingDirectory = cwd }
            configs.append(config)
        }
        guard !configs.isEmpty else {
            throw MCPError.protocolError(
                "Nothing to import: every server in this configuration is a remote (URL) server, and ORB only runs local command-line servers."
            )
        }
        return ImportReport(configs: configs, warnings: warnings)
    }

    // MARK: - Settings helpers

    /// Why `name` cannot be used for the config `id`, or nil when it can.
    /// Names are routing keys (tool names are qualified by them), so two
    /// servers whose keys collide would silently shadow each other.
    nonisolated static func nameError(for name: String, id: UUID, in configs: [MCPServerConfig]) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Give this server a name." }
        // Case-insensitive too: "GitHub" next to "github" is never intended.
        let key = MCPToolNaming.serverKey(trimmed).lowercased()
        if configs.contains(where: { $0.id != id && MCPToolNaming.serverKey($0.name).lowercased() == key }) {
            return "Another server already uses this name. Names must be unique."
        }
        return nil
    }

    /// A name for a new row that does not collide with an existing one.
    nonisolated static func uniqueName(_ base: String, in configs: [MCPServerConfig]) -> String {
        let keys = Set(configs.map { MCPToolNaming.serverKey($0.name).lowercased() })
        if !keys.contains(MCPToolNaming.serverKey(base).lowercased()) { return base }
        var index = 2
        while keys.contains(MCPToolNaming.serverKey("\(base) \(index)").lowercased()) { index += 1 }
        return "\(base) \(index)"
    }

    /// Deletes every Keychain secret a removed config referenced. Returns the
    /// variables whose secret could not be verified as removed.
    @discardableResult
    nonisolated static func deleteSecrets(of config: MCPServerConfig, store: CredentialSecretStore) -> [String] {
        (config.secretEnv ?? [:]).sorted { $0.key < $1.key }.compactMap { variable, reference in
            store.deleteSecret(forReference: reference) ? nil : variable
        }
    }

    /// Stores `value` as a secret env variable of `config`: the store gets
    /// the value, the config gets only a reference (never plaintext env).
    /// Returns the updated config, or an error string when the save failed.
    nonisolated static func settingSecretEnv(
        _ variable: String, value: String, in config: MCPServerConfig, store: CredentialSecretStore
    ) -> (config: MCPServerConfig, error: String?) {
        let key = variable.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return (config, "Enter a variable name.") }
        guard !value.isEmpty else { return (config, "Enter a value.") }
        let reference = config.secretEnv?[key] ?? MCPServerConfig.secretReference(configID: config.id, variable: key)
        if let error = store.saveSecret(value, forReference: reference) { return (config, error) }
        var updated = config
        updated.env[key] = nil
        var secrets = updated.secretEnv ?? [:]
        secrets[key] = reference
        updated.secretEnv = secrets
        return (updated, nil)
    }

    /// Removes one secret env variable (reference and stored value).
    nonisolated static func removingSecretEnv(
        _ variable: String, from config: MCPServerConfig, store: CredentialSecretStore
    ) -> MCPServerConfig {
        var updated = config
        if let reference = updated.secretEnv?[variable] { _ = store.deleteSecret(forReference: reference) }
        updated.secretEnv?[variable] = nil
        if updated.secretEnv?.isEmpty == true { updated.secretEnv = nil }
        return updated
    }

    // MARK: - Secret migration (F01 step 5)

    /// Moves the consented env variables of one server from plaintext config
    /// into `store`, returning the rewritten config list.
    ///
    /// Consent-driven by contract: nothing runs unless the caller (the
    /// settings UI) passes explicit variable names — nothing migrates
    /// automatically, and a server without an explicit migration keeps working
    /// exactly as before. All-or-nothing per server: every requested variable
    /// is validated first, then saved; if any save fails, the returned configs
    /// are the input unchanged (the store may already hold earlier saves —
    /// harmless, since a retry overwrites the same config-owned references,
    /// which are keyed by the config's UUID and never shared with another
    /// server). References already present in `secretEnv`, including legacy
    /// sanitized-name ones, are left untouched and keep resolving.
    /// Idempotent: variables already carrying a reference are reported back
    /// and never re-saved, because their plaintext value no longer exists.
    /// Configs carry references only — no secret value is ever written into a
    /// config, a log, or UserDefaults.
    nonisolated static func migrateSecretsToKeychain(
        configs: [MCPServerConfig],
        serverNamed name: String,
        variables: [String],
        store: CredentialSecretStore
    ) -> (configs: [MCPServerConfig], outcome: MCPSecretMigrationOutcome) {
        guard let index = configs.firstIndex(where: { $0.name == name }) else {
            return (
                configs,
                MCPSecretMigrationOutcome(
                    serverName: name, migratedVariables: [],
                    alreadyMigratedVariables: [],
                    error: "Server \"\(name)\" is no longer configured."
                )
            )
        }
        var config = configs[index]
        var migrated: [String] = []
        var alreadyMigrated: [String] = []

        // Phase 1 — validate every requested variable before touching the
        // store, so an unknown name cannot leave partial writes behind.
        for variable in variables.sorted() {
            if config.secretEnv?[variable] != nil {
                alreadyMigrated.append(variable)
            } else if config.env[variable] == nil {
                return (
                    configs,
                    MCPSecretMigrationOutcome(
                        serverName: name, migratedVariables: [],
                        alreadyMigratedVariables: [],
                        error: "Env variable \(variable) is not configured for \"\(name)\"."
                    )
                )
            }
        }

        // Never write to a reference some OTHER config already owns (legacy
        // sanitized-name references can be shared by punctuation-colliding
        // servers, and ids can be duplicated by pasted configs).
        let foreignReferences = Set(
            configs.enumerated().filter { $0.offset != index }
                .flatMap { ($0.element.secretEnv ?? [:]).values }
        )
        for variable in variables.sorted() where config.secretEnv?[variable] == nil {
            let reference = MCPServerConfig.secretReference(configID: config.id, variable: variable)
            if foreignReferences.contains(reference) {
                return (
                    configs,
                    MCPSecretMigrationOutcome(
                        serverName: name, migratedVariables: [],
                        alreadyMigratedVariables: [],
                        error: "The Keychain reference for \(variable) is already used by another MCP server; nothing was changed."
                    )
                )
            }
        }

        // Phase 2 — save all plaintext values, aborting on the first failure.
        for variable in variables.sorted() where config.secretEnv?[variable] == nil {
            let reference = MCPServerConfig.secretReference(configID: config.id, variable: variable)
            guard let value = config.env[variable] else { continue }  // Phase 1 verified presence.
            if let error = store.saveSecret(value, forReference: reference) {
                return (
                    configs,
                    MCPSecretMigrationOutcome(
                        serverName: name, migratedVariables: [],
                        alreadyMigratedVariables: [],
                        error: "Could not store \(variable): \(error)"
                    )
                )
            }
            migrated.append(variable)
        }

        // Phase 3 — rewrite the config only after every save succeeded.
        var secretEnv = config.secretEnv ?? [:]
        for variable in migrated {
            secretEnv[variable] = MCPServerConfig.secretReference(configID: config.id, variable: variable)
            config.env[variable] = nil
        }
        config.secretEnv = secretEnv.isEmpty ? nil : secretEnv
        var updated = configs
        updated[index] = config
        return (
            updated,
            MCPSecretMigrationOutcome(
                serverName: name, migratedVariables: migrated,
                alreadyMigratedVariables: alreadyMigrated, error: nil
            )
        )
    }

    /// UserDefaults-backed variant for callers that do not hold the config
    /// list. The settings view migrates its own in-memory list instead, so a
    /// user's concurrent edits are never overwritten. Loads the persisted
    /// configs, migrates one server, and saves only on success.
    nonisolated static func migrateSecretsToKeychain(
        serverNamed name: String,
        variables: [String],
        store: CredentialSecretStore = KeychainCredentialStore()
    ) -> MCPSecretMigrationOutcome {
        let configs = loadConfigs()
        let (updated, outcome) = migrateSecretsToKeychain(
            configs: configs, serverNamed: name, variables: variables, store: store
        )
        if outcome.didSucceed { saveConfigs(updated) }
        return outcome
    }

    // MARK: - Lifecycle

    /// True while a startup pass or a targeted lifecycle change owns the
    /// connection table. The actor is reentrant: without this gate a second
    /// start (launch startup + first agent run, or Reconnect All mid-startup)
    /// would race the first pass, create two connections for one config, and
    /// orphan the earlier child process when the later assignment overwrote it.
    private var workInFlight = false
    private var workWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    /// Suspends until no lifecycle work owns the connection table, then owns it.
    /// Cancellation only releases this caller; it never cancels the owner.
    private func beginWork() async -> Bool {
        while workInFlight {
            guard !Task.isCancelled else { return false }
            await waitForWork()
        }
        guard !Task.isCancelled else { return false }
        workInFlight = true
        return true
    }

    private func waitForWork() async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled { continuation.resume() }
                else { workWaiters[id] = continuation }
            }
        } onCancel: {
            Task { await self.cancelWorkWaiter(id) }
        }
    }

    private func cancelWorkWaiter(_ id: UUID) {
        workWaiters.removeValue(forKey: id)?.resume()
    }

    /// Releases the table and wakes every waiter; each re-checks the gate, so
    /// queued work serializes instead of overlapping.
    private func endWork() {
        workInFlight = false
        let waiters = workWaiters
        workWaiters = [:]
        for waiter in waiters.values { waiter.resume() }
    }

    /// Waits for in-flight lifecycle work without taking ownership. Every
    /// read and dispatch entry point joins an in-flight pass so a run that
    /// starts during launch startup sees all of its servers, not just the
    /// ones connected so far.
    private func joinWork() async -> Bool {
        while workInFlight {
            guard !Task.isCancelled else { return false }
            await waitForWork()
        }
        return !Task.isCancelled
    }

    private func ensureStarted() async -> Bool {
        guard await joinWork() else { return false }
        // A joined initial pass may have been cancelled by its owner. A fresh
        // caller must retry rather than accepting that partial pass as loaded.
        if !didLoad { await startEnabledServers() }
        return !Task.isCancelled
    }

    /// Reconciles every enabled server under the existing lifecycle gate.
    /// Reload after suspension: persistence can change independently of this
    /// actor while a process is handshaking or shutting down.
    func startEnabledServers() async {
        guard await beginWork() else { return }
        defer { endWork() }
        await reconcileLocked()
        if !Task.isCancelled { didLoad = true }
    }

    /// A targeted start also reconciles already-live rows, including a renamed
    /// config's old key. Unrelated stopped rows are not newly started.
    private func reconcileLocked(named name: String? = nil) async {
        let previouslyLiveNames = Set(connections.keys)
        let previouslyLiveIDs = Set(connectedConfigs.values.map(\.id))
        var requestedID: UUID?
        while !Task.isCancelled {
            let snapshot = configProvider()
            if requestedID == nil, let name {
                requestedID = snapshot.first { $0.name == name }?.id
            }
            // Names are routing keys. Match the first persisted row consistently,
            // including a disabled first row, rather than launching duplicates.
            var desired: [String: MCPServerConfig] = [:]
            for config in snapshot where desired[config.name] == nil {
                desired[config.name] = config
            }
            for (key, connection) in connections {
                guard let config = desired[key], config.isEnabled,
                      connectedConfigs[key] == config else {
                    connections[key] = nil
                    connectedConfigs[key] = nil
                    lastErrors[key] = nil
                    failedConfigs[key] = nil
                    await connection.shutdown()
                    continue
                }
            }
            for key in Array(lastErrors.keys)
                where desired[key]?.isEnabled != true || desired[key] != failedConfigs[key] {
                lastErrors[key] = nil
                failedConfigs[key] = nil
            }
            for config in snapshot where config.isEnabled && desired[config.name] == config {
                if let name, config.name != name && config.id != requestedID
                    && !previouslyLiveNames.contains(config.name) && !previouslyLiveIDs.contains(config.id) { continue }
                await connectLocked(config)
            }
            // No await between this check and returning/releasing the gate.
            // Changed configs are attempted on the next pass, never published
            // from an obsolete startup completion.
            if configProvider() == snapshot { return }
        }
    }

    private func isDesired(_ config: MCPServerConfig) -> Bool {
        config.isEnabled && configProvider().first(where: { $0.name == config.name }) == config
    }

    /// Check both identity and launch inputs after every cross-actor read/RPC.
    /// A late result from a replaced process must not describe the new server.
    private func isCurrentConnection(_ connection: MCPConnection, named name: String) -> Bool {
        guard connections[name] === connection, let config = connectedConfigs[name] else { return false }
        return isDesired(config)
    }

    /// Caller holds the lifecycle gate. Equality includes command, ordered args,
    /// environment values, secret references, enabled state, name and UUID.
    private func connectLocked(_ config: MCPServerConfig) async {
        guard !Task.isCancelled, isDesired(config) else { return }
        if let existing = connections[config.name] {
            let running = await existing.isRunning
            if running && connectedConfigs[config.name] == config && isDesired(config) { return }
            connections[config.name] = nil
            connectedConfigs[config.name] = nil
            await existing.shutdown()
        }
        guard !Task.isCancelled, isDesired(config) else { return }
        guard !config.command.isEmpty else {
            lastErrors[config.name] = "Command is empty."
            failedConfigs[config.name] = config
            return
        }
        let connection = await connectionFactory(config)
        guard !Task.isCancelled, isDesired(config) else {
            await connection.shutdown()
            return
        }
        do {
            try await connection.connect()
            try Task.checkCancellation()
            guard isDesired(config) else {
                await connection.shutdown()
                return
            }
            connections[config.name] = connection
            connectedConfigs[config.name] = config
            lastErrors[config.name] = nil
            failedConfigs[config.name] = nil
        } catch {
            await connection.shutdown()
            // A failed OLD handshake must not become the new row's error.
            if !Task.isCancelled, isDesired(config) {
                lastErrors[config.name] = error.localizedDescription
                failedConfigs[config.name] = config
            }
        }
    }

    /// Settings enable/add/import takes effect without a relaunch. Missing or
    /// disabled targets also reconcile, instead of leaving the old process live.
    func startServer(named name: String) async {
        guard await beginWork() else { return }
        defer { endWork() }
        await reconcileLocked(named: name)
    }

    /// Shuts down a single server's connection (settings disable/remove).
    func stopServer(named name: String) async {
        guard await beginWork() else { return }
        defer { endWork() }
        connectedConfigs[name] = nil
        if let existing = connections.removeValue(forKey: name) {
            await existing.shutdown()
        }
        lastErrors[name] = nil
        failedConfigs[name] = nil
    }

    func shutdownAll() async {
        guard await beginWork() else { return }
        defer { endWork() }
        let dying = connections
        connections.removeAll()
        connectedConfigs.removeAll()
        for (_, connection) in dying { await connection.shutdown() }
    }

    /// Verifies a single configuration by connecting and listing its tools.
    /// Used by the settings UI's "Test" button.
    func probe(_ config: MCPServerConfig) async -> Result<MCPProbeReport, Error> {
        let connection = MCPConnection(config: config)
        do {
            try await connection.connect()
            let report = MCPProbeReport(
                serverInfo: await connection.serverInfo,
                tools: await connection.tools,
                resources: await connection.resources,
                prompts: await connection.prompts
            )
            await connection.shutdown()
            return .success(report)
        } catch {
            await connection.shutdown()
            return .failure(error)
        }
    }

    // MARK: - Tools

    func availableTools() async -> [MCPToolDescriptor] {
        guard await ensureStarted() else { return [] }
        let snapshot = connections
        var all: [MCPToolDescriptor] = []
        for (_, connection) in snapshot {
            guard await connection.isRunning else { continue }
            all += await connection.tools
        }
        let currentNames = Set(snapshot.compactMap { name, connection in
            isCurrentConnection(connection, named: name) ? name : nil
        })
        return all.filter { currentNames.contains($0.serverName) }.sorted { $0.qualifiedName < $1.qualifiedName }
    }

    /// OpenRouter-shaped tool definitions for every connected MCP server.
    ///
    /// Beyond each server's own tools, resources and prompts are surfaced as
    /// synthetic tools. MCP exposes those over separate JSON-RPC methods, but a
    /// chat model can only call tools — without this bridge the agent could see
    /// a server's resources but never read one.
    func toolDefinitions() async -> [AgentToolDefinition] {
        guard await ensureStarted() else { return [] }
        let snapshot = connections
        var definitions = await availableTools().map { descriptor in
            AgentToolDefinition(function: .init(
                name: descriptor.qualifiedName,
                description: "[\(descriptor.serverName)] \(descriptor.description)",
                parameters: .raw(descriptor.inputSchema)
            ))
        }

        // One bridge pair per server that publishes resources/prompts. Names
        // are server-qualified so policy approval and routing are per server.
        // A server's own tool of the same name wins; the bridge is skipped.
        let realTools = Set(await availableTools().map(\.qualifiedName))
        let resources = await availableResources()
        for (server, entries) in Dictionary(grouping: resources, by: \.serverName).sorted(by: { $0.key < $1.key }) {
            let name = MCPToolNaming.readResourceTool(server: server)
            guard !realTools.contains(name) else { continue }
            let catalog = entries.prefix(40).map { "\($0.uri) — \($0.name)" }.joined(separator: "; ")
            definitions.append(AgentToolDefinition(function: .init(
                name: name,
                description: "[\(server)] Read a resource published by this MCP server. Available: \(catalog)",
                parameters: .raw(.object([
                    "type": .string("object"),
                    "properties": .object([
                        "uri": .object([
                            "type": .string("string"),
                            "description": .string("The resource URI to read.")
                        ])
                    ]),
                    "required": .array([.string("uri")])
                ]))
            )))
        }

        let prompts = await availablePrompts()
        for (server, entries) in Dictionary(grouping: prompts, by: \.serverName).sorted(by: { $0.key < $1.key }) {
            let name = MCPToolNaming.getPromptTool(server: server)
            guard !realTools.contains(name) else { continue }
            let catalog = entries.prefix(40)
                .map { "\($0.name) — \($0.description ?? "no description")" }
                .joined(separator: "; ")
            definitions.append(AgentToolDefinition(function: .init(
                name: name,
                description: "[\(server)] Expand a prompt template from this MCP server. Available: \(catalog)",
                parameters: .raw(.object([
                    "type": .string("object"),
                    "properties": .object([
                        "name": .object([
                            "type": .string("string"),
                            "description": .string("The prompt template name.")
                        ]),
                        "arguments": .object([
                            "type": .string("object"),
                            "description": .string("String arguments for the template.")
                        ])
                    ]),
                    "required": .array([.string("name")])
                ]))
            )))
        }

        let currentKeys = Set(snapshot.compactMap { name, connection in
            isCurrentConnection(connection, named: name) ? MCPToolNaming.serverKey(name) : nil
        })
        return definitions.filter { definition in
            guard let route = MCPToolNaming.resolve(definition.function.name) else { return false }
            return currentKeys.contains(route.server)
        }
    }

    // MARK: - Resources and prompts

    func availableResources() async -> [MCPResourceDescriptor] {
        guard await ensureStarted() else { return [] }
        let snapshot = connections
        var all: [MCPResourceDescriptor] = []
        for (_, connection) in snapshot {
            guard await connection.isRunning else { continue }
            all += await connection.resources
        }
        let currentNames = Set(snapshot.compactMap { name, connection in
            isCurrentConnection(connection, named: name) ? name : nil
        })
        return all.filter { currentNames.contains($0.serverName) }.sorted { $0.id < $1.id }
    }

    func availablePrompts() async -> [MCPPromptDescriptor] {
        guard await ensureStarted() else { return [] }
        let snapshot = connections
        var all: [MCPPromptDescriptor] = []
        for (_, connection) in snapshot {
            guard await connection.isRunning else { continue }
            all += await connection.prompts
        }
        let currentNames = Set(snapshot.compactMap { name, connection in
            isCurrentConnection(connection, named: name) ? name : nil
        })
        return all.filter { currentNames.contains($0.serverName) }.sorted { $0.id < $1.id }
    }

    /// Reads a resource by URI from ONE server's connection. URIs are
    /// server-defined, so a bridge only ever reads from the server whose name
    /// it carries.
    private func readResource(uri: String, from connection: MCPConnection) async -> NativeAgentToolResult {
        guard await connection.resources.contains(where: { $0.uri == uri }) else {
            return .init(content: "No resource \(uri) is published by MCP server \"\(await connection.name)\".", isError: true)
        }
        let server = await connection.name
        guard isCurrentConnection(connection, named: server) else { return Self.obsoleteConnectionResult }
        do {
            let text = try await connection.readResource(uri: uri)
            return .init(content: text.isEmpty ? "(empty resource)" : text, isError: false)
        } catch {
            return .init(content: "Failed to read \(uri): \(error.localizedDescription)", isError: true)
        }
    }

    private func expandPrompt(name: String, arguments: [String: String], from connection: MCPConnection) async -> NativeAgentToolResult {
        guard await connection.prompts.contains(where: { $0.name == name }) else {
            return .init(content: "No prompt \(name) is published by MCP server \"\(await connection.name)\".", isError: true)
        }
        let server = await connection.name
        guard isCurrentConnection(connection, named: server) else { return Self.obsoleteConnectionResult }
        do {
            let text = try await connection.getPrompt(name: name, arguments: arguments)
            return .init(content: text.isEmpty ? "(empty prompt)" : text, isError: false)
        } catch {
            return .init(content: "Failed to expand \(name): \(error.localizedDescription)", isError: true)
        }
    }

    /// Live status per config id, for the settings rows. A row whose saved
    /// config differs from what is running reports `needsApply`.
    struct RowStatus: Equatable, Sendable {
        var connected: Bool
        var toolCount: Int
        var error: String?
        /// Enabled, but the running process was launched from an older
        /// version of this row (edited since), or it is not running yet.
        var needsApply: Bool
    }

    func rowStatuses() async -> [UUID: RowStatus] {
        guard await joinWork() else { return [:] }
        var rows: [UUID: RowStatus] = [:]
        for config in configProvider() where rows[config.id] == nil {
            let launchedKey = connectedConfigs.first { $0.value.id == config.id }?.key
            let connection = launchedKey.flatMap { connections[$0] }
            let running = await connection?.isRunning ?? false
            let launched = launchedKey.flatMap { connectedConfigs[$0] }
            let upToDate = launched == config
            let connected = running && upToDate && isDesired(config)
            let tools = connected ? (await connection?.tools.count ?? 0) : 0
            let terminationError = upToDate ? await connection?.lastError : nil
            let failure = failedConfigs[config.name] == config && isDesired(config) ? lastErrors[config.name] : nil
            let error = connected ? nil : (terminationError ?? failure)
            let needsApply = config.isEnabled && !connected && error == nil && launched != nil && !upToDate
            rows[config.id] = RowStatus(connected: connected, toolCount: tools, error: error, needsApply: needsApply)
        }
        return rows
    }

    /// Stops the server launched from config `id`, whatever name it ran
    /// under (the row may have been renamed since).
    func stopServer(id: UUID) async {
        guard await beginWork() else { return }
        defer { endWork() }
        for (key, config) in connectedConfigs where config.id == id {
            connectedConfigs[key] = nil
            if let existing = connections.removeValue(forKey: key) { await existing.shutdown() }
            lastErrors[key] = nil
            failedConfigs[key] = nil
        }
    }

    /// True while a process launched from config `id` is registered.
    func isRunning(id: UUID) async -> Bool {
        guard let key = connectedConfigs.first(where: { $0.value.id == id })?.key,
              let connection = connections[key] else { return false }
        return await connection.isRunning
    }

    func status() async -> [(name: String, toolCount: Int, connected: Bool, error: String?)] {
        guard await joinWork() else { return [] }
        var rows: [(String, Int, Bool, String?)] = []
        for config in configProvider() {
            let connection = connections[config.name]
            let running = await connection?.isRunning ?? false
            let tools = running ? (await connection?.tools.count ?? 0) : 0
            let terminationError = await connection?.lastError
            let current = connection.map { isCurrentConnection($0, named: config.name) } ?? false
            let connected = running && current
            let failure = failedConfigs[config.name] == config && isDesired(config) ? lastErrors[config.name] : nil
            let error = connected ? nil : ((current ? terminationError : nil) ?? failure)
            rows.append((config.name, connected ? tools : 0, connected, error))
        }
        return rows
    }

    // MARK: - Dispatch

    /// True when this tool name belongs to an MCP server (including its
    /// server-qualified resource/prompt bridges).
    nonisolated static func isMCPTool(_ name: String) -> Bool {
        MCPToolNaming.resolve(name) != nil
    }

    func call(qualifiedName: String, argumentsJSON: String) async -> NativeAgentToolResult {
        guard await ensureStarted() else {
            return .init(content: "MCP call cancelled.", isError: true)
        }
        guard let route = MCPToolNaming.resolve(qualifiedName) else {
            return .init(content: "Unknown MCP tool \(qualifiedName).", isError: true)
        }
        let parsed = JSONValue.parse(argumentsJSON)?.objectValue ?? [:]
        let bridge = MCPToolNaming.bridge(forTool: route.tool)

        // Match the same collision-free key used by advertisement and policy.
        let matches = connections.filter { name, _ in
            MCPToolNaming.serverKey(name) == route.server
        }
        guard matches.count <= 1 else {
            return .init(content: "Ambiguous MCP server identity; no call was dispatched.", isError: true)
        }
        let match = matches.first
        guard let connection = match?.value else {
            if let bridge, let invalid = Self.invalidBridgeArguments(bridge, parsed) { return invalid }
            let detail = lastErrors
                .first { key, _ in
                    MCPToolNaming.serverKey(key) == route.server
                        && (failedConfigs[key].map { isDesired($0) } ?? false)
                }
                .map { " (\($0.value))" } ?? ""
            return .init(
                content: "MCP server \"\(route.server)\" is not connected\(detail).",
                isError: true
            )
        }
        guard let match, isCurrentConnection(connection, named: match.key) else {
            return Self.obsoleteConnectionResult
        }
        let result = await callConnected(connection, named: match.key, route: route, argumentsJSON: argumentsJSON)
        guard isCurrentConnection(connection, named: match.key) else {
            return Self.obsoleteConnectionResult
        }
        return result
    }

    private static var obsoleteConnectionResult: NativeAgentToolResult {
        .init(content: "MCP server configuration changed or the connection was stopped; the obsolete result was discarded.", isError: true)
    }

    private func callConnected(
        _ connection: MCPConnection,
        named name: String,
        route: (server: String, tool: String),
        argumentsJSON: String
    ) async -> NativeAgentToolResult {
        let parsed = JSONValue.parse(argumentsJSON)?.objectValue ?? [:]
        let bridge = MCPToolNaming.bridge(forTool: route.tool)
        // A crashed server must not receive calls (or advertise tools); say
        // why the connection is gone instead of failing per call.
        guard await connection.isRunning else {
            let serverName = await connection.name
            let detail = await connection.lastError ?? ""
            return .init(
                content: "MCP server \"\(serverName)\" is not connected.\(detail.isEmpty ? "" : " \(detail)")",
                isError: true
            )
        }

        // A real tool of the same name on that server takes precedence over
        // the synthetic bridge.
        let matchingTools = await connection.tools.filter { MCPToolNaming.toolKey($0.toolName) == route.tool }
        guard matchingTools.count <= 1 else {
            return .init(content: "Ambiguous MCP tool identity; no call was dispatched.", isError: true)
        }
        let realTool = matchingTools.first
        let hasRealTool = realTool != nil
        guard isCurrentConnection(connection, named: name) else { return Self.obsoleteConnectionResult }
        if let bridge, !hasRealTool {
            if let invalid = Self.invalidBridgeArguments(bridge, parsed) { return invalid }
            switch bridge {
            case .readResource:
                return await readResource(uri: parsed["uri"]?.stringValue ?? "", from: connection)
            case .getPrompt:
                var arguments: [String: String] = [:]
                parsed["arguments"]?.objectValue?.forEach { key, value in
                    // Templates take strings; coerce numbers/bools rather than
                    // dropping arguments the model reasonably supplied.
                    if let string = value.stringValue {
                        arguments[key] = string
                    } else if let number = value.doubleValue {
                        // `Int(exactly:)`: a whole number like 1e30 has no Int
                        // representation and must not trap.
                        if number == number.rounded(), let exact = Int(exactly: number) {
                            arguments[key] = String(exact)
                        } else {
                            arguments[key] = String(number)
                        }
                    } else if let flag = value.boolValue {
                        arguments[key] = String(flag)
                    }
                }
                return await expandPrompt(name: parsed["name"]?.stringValue ?? "", arguments: arguments, from: connection)
            }
        }

        let arguments = JSONValue.parse(argumentsJSON) ?? .object([:])
        do {
            guard let realTool else {
                return .init(content: "Unknown MCP tool on the connected server.", isError: true)
            }
            return try await connection.callTool(name: realTool.toolName, arguments: arguments)
        } catch {
            return .init(content: "MCP call failed: \(error.localizedDescription)", isError: true)
        }
    }

    private static func invalidBridgeArguments(_ bridge: MCPToolNaming.Bridge, _ parsed: [String: JSONValue]) -> NativeAgentToolResult? {
        switch bridge {
        case .readResource:
            guard let uri = parsed["uri"]?.stringValue, !uri.isEmpty else {
                return .init(content: "read_resource requires a \"uri\" argument.", isError: true)
            }
        case .getPrompt:
            guard let name = parsed["name"]?.stringValue, !name.isEmpty else {
                return .init(content: "get_prompt requires a \"name\" argument.", isError: true)
            }
        }
        return nil
    }
}
