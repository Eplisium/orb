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

    private var connections: [String: MCPConnection] = [:]
    private var lastErrors: [String: String] = [:]
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
    }

    /// Imports a standard `mcpServers` JSON blob (Claude Desktop format) so
    /// users can paste an existing configuration.
    static func parseStandardConfig(_ text: String) throws -> [MCPServerConfig] {
        guard let root = JSONValue.parse(text)?.objectValue else {
            throw MCPError.protocolError("Configuration is not valid JSON.")
        }
        // Accept both a bare map and one wrapped in "mcpServers".
        let servers = root["mcpServers"]?.objectValue ?? root
        guard !servers.isEmpty else {
            throw MCPError.protocolError("No servers found. Expected an \"mcpServers\" object.")
        }
        return try servers.keys.sorted().map { name in
            guard let entry = servers[name]?.objectValue,
                  let command = entry["command"]?.stringValue, !command.isEmpty else {
                throw MCPError.protocolError("Server \"\(name)\" is missing a \"command\".")
            }
            var env: [String: String] = [:]
            entry["env"]?.objectValue?.forEach { key, value in
                if let string = value.stringValue { env[key] = string }
            }
            return MCPServerConfig(
                name: name,
                command: command,
                args: entry["args"]?.arrayValue?.compactMap(\.stringValue) ?? [],
                env: env
            )
        }
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

    /// Connects every enabled server. Failures are recorded per server rather
    /// than thrown, so one broken server cannot disable the whole agent.
    func startEnabledServers() async {
        didLoad = true
        let configs = Self.loadConfigs().filter(\.isEnabled)
        let active = Set(configs.map(\.name))

        for (name, connection) in connections where !active.contains(name) {
            await connection.shutdown()
            connections[name] = nil
        }

        for config in configs {
            if let existing = connections[config.name], await existing.isRunning { continue }
            let connection = MCPConnection(config: config)
            do {
                try await connection.connect()
                connections[config.name] = connection
                lastErrors[config.name] = nil
            } catch {
                await connection.shutdown()
                lastErrors[config.name] = error.localizedDescription
            }
        }
    }

    func shutdownAll() async {
        for (_, connection) in connections { await connection.shutdown() }
        connections.removeAll()
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
        if !didLoad { await startEnabledServers() }
        var all: [MCPToolDescriptor] = []
        for (_, connection) in connections {
            all += await connection.tools
        }
        return all.sorted { $0.qualifiedName < $1.qualifiedName }
    }

    /// OpenRouter-shaped tool definitions for every connected MCP server.
    ///
    /// Beyond each server's own tools, resources and prompts are surfaced as
    /// synthetic tools. MCP exposes those over separate JSON-RPC methods, but a
    /// chat model can only call tools — without this bridge the agent could see
    /// a server's resources but never read one.
    func toolDefinitions() async -> [AgentToolDefinition] {
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

        return definitions
    }

    // MARK: - Resources and prompts

    func availableResources() async -> [MCPResourceDescriptor] {
        if !didLoad { await startEnabledServers() }
        var all: [MCPResourceDescriptor] = []
        for (_, connection) in connections {
            all += await connection.resources
        }
        return all.sorted { $0.id < $1.id }
    }

    func availablePrompts() async -> [MCPPromptDescriptor] {
        if !didLoad { await startEnabledServers() }
        var all: [MCPPromptDescriptor] = []
        for (_, connection) in connections {
            all += await connection.prompts
        }
        return all.sorted { $0.id < $1.id }
    }

    /// Reads a resource by URI from ONE server's connection. URIs are
    /// server-defined, so a bridge only ever reads from the server whose name
    /// it carries.
    private func readResource(uri: String, from connection: MCPConnection) async -> NativeAgentToolResult {
        guard await connection.resources.contains(where: { $0.uri == uri }) else {
            return .init(content: "No resource \(uri) is published by MCP server \"\(await connection.name)\".", isError: true)
        }
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
        do {
            let text = try await connection.getPrompt(name: name, arguments: arguments)
            return .init(content: text.isEmpty ? "(empty prompt)" : text, isError: false)
        } catch {
            return .init(content: "Failed to expand \(name): \(error.localizedDescription)", isError: true)
        }
    }

    func status() async -> [(name: String, toolCount: Int, error: String?)] {
        var rows: [(String, Int, String?)] = []
        for config in Self.loadConfigs() {
            let tools = await connections[config.name]?.tools.count ?? 0
            rows.append((config.name, tools, lastErrors[config.name]))
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
        guard let route = MCPToolNaming.resolve(qualifiedName) else {
            return .init(content: "Unknown MCP tool \(qualifiedName).", isError: true)
        }
        let parsed = JSONValue.parse(argumentsJSON)?.objectValue ?? [:]
        let bridge = MCPToolNaming.bridge(forTool: route.tool)

        // The qualified name carries a sanitized server slug, so match on that.
        let match = connections.first { name, _ in
            MCPToolNaming.sanitize(name) == route.server
        }
        guard let connection = match?.value else {
            if let bridge, let invalid = Self.invalidBridgeArguments(bridge, parsed) { return invalid }
            let detail = lastErrors[route.server].map { " (\($0))" } ?? ""
            return .init(
                content: "MCP server \"\(route.server)\" is not connected\(detail).",
                isError: true
            )
        }

        // A real tool of the same name on that server takes precedence over
        // the synthetic bridge.
        let hasRealTool = await connection.tools.contains { $0.toolName == route.tool }
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
                        arguments[key] = number == number.rounded()
                            ? String(Int(number))
                            : String(number)
                    } else if let flag = value.boolValue {
                        arguments[key] = String(flag)
                    }
                }
                return await expandPrompt(name: parsed["name"]?.stringValue ?? "", arguments: arguments, from: connection)
            }
        }

        let arguments = JSONValue.parse(argumentsJSON) ?? .object([:])
        do {
            return try await connection.callTool(name: route.tool, arguments: arguments)
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
