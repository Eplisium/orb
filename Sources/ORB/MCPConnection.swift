import Foundation

// MARK: - Configuration

/// A user-configured MCP server. Mirrors the standard `mcpServers` entry shape
/// used by Claude Desktop and other MCP hosts, so existing configs paste in.
struct MCPServerConfig: Codable, Sendable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var command: String
    var args: [String] = []
    var env: [String: String] = [:]
    var isEnabled: Bool = true
    /// Env variables whose values live in the credential secret store instead
    /// of this config: variable name → store reference (F01 step 5). Optional
    /// so every config persisted before references decodes unchanged, and a
    /// config without migrated secrets re-encodes without the key. The values
    /// are REFERENCES — never secret bytes.
    var secretEnv: [String: String]? = nil

    enum CodingKeys: String, CodingKey {
        case id, name, command, args, env, isEnabled, secretEnv
    }

    /// Deterministic store reference for one server env variable, namespaced
    /// per server+variable so two servers never overwrite each other's secret.
    /// Sanitized to the same character class as tool-name slugs.
    static func secretReference(serverName: String, variable: String) -> String {
        "orb-mcp-\(MCPToolNaming.sanitize(serverName))-\(MCPToolNaming.sanitize(variable))"
    }

    /// Name-based guess that an env variable usually holds a secret. Used ONLY
    /// to preselect the migration consent checkboxes — the user always decides
    /// which variables move.
    static func looksLikeSecret(_ variable: String) -> Bool {
        let upper = variable.uppercased()
        let markers = ["KEY", "TOKEN", "SECRET", "PASSWORD", "PASSWD", "CREDENTIAL", "AUTH"]
        return markers.contains { upper.contains($0) }
    }
}

/// A keychain-referenced secret could not be resolved while building the
/// subprocess environment. Failing closed beats launching the server without
/// its credential — or worse, with the raw reference string as the value.
enum MCPEnvironmentError: LocalizedError, Equatable {
    case missingSecret(server: String, variable: String, reference: String)

    var errorDescription: String? {
        switch self {
        case .missingSecret(let server, let variable, let reference):
            return "MCP server \"\(server)\" could not read the secret for env variable "
                + "\(variable) (reference \(reference)) from the Keychain. "
                + "Re-save the secret or remove the reference in MCP settings."
        }
    }
}

// MARK: - Errors

enum MCPError: LocalizedError, Equatable {
    case launchFailed(String)
    case transport(String)
    case protocolError(String)
    case server(code: Int, message: String)
    case timedOut(String)
    case notConnected

    var errorDescription: String? {
        switch self {
        case .launchFailed(let detail): return "Could not start MCP server: \(detail)"
        case .transport(let detail): return "MCP transport error: \(detail)"
        case .protocolError(let detail): return "MCP protocol error: \(detail)"
        case .server(let code, let message): return "MCP server error \(code): \(message)"
        case .timedOut(let method): return "MCP request timed out: \(method)"
        case .notConnected: return "MCP server is not connected."
        }
    }
}

// MARK: - Tool descriptor

/// A readable resource published by an MCP server (files, DB rows, API docs).
struct MCPResourceDescriptor: Sendable, Equatable, Identifiable {
    let serverName: String
    let uri: String
    let name: String
    let description: String?
    let mimeType: String?
    var id: String { "\(serverName)::\(uri)" }
}

/// A reusable prompt template published by an MCP server.
struct MCPPromptDescriptor: Sendable, Equatable, Identifiable {
    struct Argument: Sendable, Equatable {
        let name: String
        let description: String?
        let required: Bool
    }
    let serverName: String
    let name: String
    let description: String?
    let arguments: [Argument]
    var id: String { "\(serverName)::\(name)" }
}

struct MCPToolDescriptor: Sendable, Equatable {
    let serverName: String
    let toolName: String
    let description: String
    let inputSchema: JSONValue

    /// Namespaced name exposed to the model. MCP servers can publish colliding
    /// tool names, and the namespace also tells ORB which server to route a call
    /// back to. `__` is used because OpenRouter restricts tool names to
    /// `[A-Za-z0-9_-]`.
    var qualifiedName: String {
        MCPToolNaming.qualify(server: serverName, tool: toolName)
    }
}

enum MCPToolNaming {
    static let separator = "__"
    static let prefix = "mcp"

    /// Synthetic tools bridging MCP's non-tool capabilities into the
    /// tool-calling interface a chat model can actually use.
    static let readResourceTool = "mcp__read_resource"
    static let getPromptTool = "mcp__get_prompt"

    static func isSynthetic(_ name: String) -> Bool {
        name == readResourceTool || name == getPromptTool
    }

    static func qualify(server: String, tool: String) -> String {
        "\(prefix)\(separator)\(sanitize(server))\(separator)\(tool)"
    }

    /// Splits a qualified name back into its server and tool parts.
    static func resolve(_ qualified: String) -> (server: String, tool: String)? {
        let parts = qualified.components(separatedBy: separator)
        guard parts.count >= 3, parts[0] == prefix else { return nil }
        // The tool name itself may contain the separator; the server slug cannot.
        return (parts[1], parts.dropFirst(2).joined(separator: separator))
    }

    static func sanitize(_ value: String) -> String {
        let allowed = value.map { character -> Character in
            character.isLetter || character.isNumber ? character : "-"
        }
        return String(allowed)
    }
}

// MARK: - Connection

/// A live connection to a single MCP server over stdio, speaking JSON-RPC 2.0
/// with newline-delimited framing (the transport used by every stdio MCP server).
///
/// An actor because the runner issues concurrent `callTool` requests and the
/// pending-request table plus the write handle must not race.
actor MCPConnection {
    private let config: MCPServerConfig
    /// Injected secret store used to resolve `secretEnv` references at launch.
    /// Production uses the Keychain-backed store; tests inject fakes.
    private let secretStore: CredentialSecretStore
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var stdoutPump: Task<Void, Never>?
    private var stdoutSink: AsyncStream<Data>.Continuation?
    private var nextID = 1
    private var readBuffer = Data()
    private var isShuttingDown = false
    private(set) var tools: [MCPToolDescriptor] = []
    private(set) var resources: [MCPResourceDescriptor] = []
    private(set) var prompts: [MCPPromptDescriptor] = []
    private(set) var supportsResources = false
    private(set) var supportsPrompts = false
    private(set) var serverInfo: String?

    /// Per-request ceiling. MCP tools can be slow (network, browsers), but an
    /// unbounded wait would hang the whole agent run.
    private let requestTimeout: Duration = .seconds(120)

    init(config: MCPServerConfig, secretStore: CredentialSecretStore = KeychainCredentialStore()) {
        self.config = config
        self.secretStore = secretStore
    }

    var name: String { config.name }
    var isRunning: Bool { process?.isRunning ?? false }

    // MARK: Environment resolution

    /// Builds the subprocess environment. Plaintext env is applied first, then
    /// every `secretEnv` reference is resolved through `store`, so a resolved
    /// secret wins over a stale plaintext copy of the same variable. A missing
    /// or empty secret throws instead of launching: the raw reference string
    /// must never reach the process environment.
    static func resolvedEnvironment(
        base: [String: String],
        config: MCPServerConfig,
        store: CredentialSecretStore
    ) throws -> [String: String] {
        var environment = base
        config.env.forEach { environment[$0.key] = $0.value }
        for (variable, reference) in (config.secretEnv ?? [:]).sorted(by: { $0.key < $1.key }) {
            guard let secret = store.secret(forReference: reference), !secret.isEmpty else {
                throw MCPEnvironmentError.missingSecret(
                    server: config.name, variable: variable, reference: reference
                )
            }
            environment[variable] = secret
        }
        return environment
    }

    // MARK: Lifecycle

    func connect() async throws {
        guard process == nil else { return }

        let task = Process()
        // Resolve via a login shell so `npx`, `uvx`, and friends are found even
        // though a GUI app inherits a minimal PATH.
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        let argv = ([config.command] + config.args)
            .map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            .joined(separator: " ")
        task.arguments = ["-lc", "exec \(argv)"]

        let environment: [String: String]
        do {
            environment = try Self.resolvedEnvironment(
                base: ProcessInfo.processInfo.environment,
                config: config,
                store: secretStore
            )
        } catch let error as MCPEnvironmentError {
            throw MCPError.launchFailed(error.localizedDescription)
        }
        task.environment = environment

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        task.standardInput = stdinPipe
        task.standardOutput = stdoutPipe
        task.standardError = stderrPipe

        // One ordered consumer: a Task per chunk could run out of order and
        // splice JSON-RPC lines together.
        let (chunks, chunkSink) = AsyncStream<Data>.makeStream()
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            chunkSink.yield(data)
        }
        stdoutPump = Task { [weak self] in
            for await chunk in chunks { await self?.ingest(chunk) }
        }
        stdoutSink = chunkSink
        // Drain stderr so a chatty server cannot fill the pipe buffer and block.
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }
        task.terminationHandler = { [weak self] _ in
            Task { await self?.handleTermination() }
        }

        do {
            try task.run()
        } catch {
            throw MCPError.launchFailed("\(config.command): \(error.localizedDescription)")
        }

        process = task
        stdinHandle = stdinPipe.fileHandleForWriting

        let initResult = try await send(
            method: "initialize",
            params: .object([
                "protocolVersion": .string("2024-11-05"),
                // Advertise every capability ORB can consume so servers expose
                // their full surface, not just tools.
                "capabilities": .object([
                    "tools": .object([:]),
                    "resources": .object([:]),
                    "prompts": .object([:])
                ]),
                "clientInfo": .object([
                    "name": .string("ORB"),
                    "version": .string("1.0.0")
                ])
            ])
        )
        serverInfo = initResult.objectValue?["serverInfo"]?.objectValue?["name"]?.stringValue
        // Record what the server actually supports so we never call a method it
        // doesn't implement (many servers error rather than returning empty).
        let capabilities = initResult.objectValue?["capabilities"]?.objectValue ?? [:]
        supportsResources = capabilities["resources"] != nil
        supportsPrompts = capabilities["prompts"] != nil

        try await notify(method: "notifications/initialized", params: .object([:]))
        tools = try await listTools()
        // Resources and prompts are optional; a server that advertises them but
        // fails the call should not take down an otherwise working connection.
        if supportsResources { resources = (try? await listResources()) ?? [] }
        if supportsPrompts { prompts = (try? await listPrompts()) ?? [] }
    }

    func shutdown() {
        isShuttingDown = true
        for (_, continuation) in pending {
            continuation.resume(throwing: MCPError.notConnected)
        }
        pending.removeAll()
        stdoutSink?.finish()
        stdoutSink = nil
        stdoutPump?.cancel()
        stdoutPump = nil
        stdinHandle?.closeFile()
        process?.terminate()
        process = nil
        stdinHandle = nil
        tools = []
        resources = []
        prompts = []
    }

    private func handleTermination() {
        guard !isShuttingDown else { return }
        for (_, continuation) in pending {
            continuation.resume(throwing: MCPError.transport("server exited unexpectedly"))
        }
        pending.removeAll()
        process = nil
    }

    // MARK: Requests

    func listResources() async throws -> [MCPResourceDescriptor] {
        let result = try await send(method: "resources/list", params: .object([:]))
        guard let entries = result.objectValue?["resources"]?.arrayValue else { return [] }
        return entries.compactMap { entry in
            guard let object = entry.objectValue,
                  let uri = object["uri"]?.stringValue else { return nil }
            return MCPResourceDescriptor(
                serverName: config.name,
                uri: uri,
                name: object["name"]?.stringValue ?? uri,
                description: object["description"]?.stringValue,
                mimeType: object["mimeType"]?.stringValue
            )
        }
    }

    /// Reads a resource and flattens it to text the model can consume.
    func readResource(uri: String) async throws -> String {
        let result = try await send(
            method: "resources/read",
            params: .object(["uri": .string(uri)])
        )
        guard let contents = result.objectValue?["contents"]?.arrayValue else { return "" }
        return contents.compactMap { entry -> String? in
            guard let object = entry.objectValue else { return nil }
            if let text = object["text"]?.stringValue { return text }
            // Binary blobs cannot be inlined; describe them instead of
            // dumping base64 into the conversation.
            if object["blob"] != nil {
                let mime = object["mimeType"]?.stringValue ?? "application/octet-stream"
                return "[binary resource: \(mime)]"
            }
            return nil
        }.joined(separator: "\n\n")
    }

    func listPrompts() async throws -> [MCPPromptDescriptor] {
        let result = try await send(method: "prompts/list", params: .object([:]))
        guard let entries = result.objectValue?["prompts"]?.arrayValue else { return [] }
        return entries.compactMap { entry in
            guard let object = entry.objectValue,
                  let name = object["name"]?.stringValue else { return nil }
            let arguments = (object["arguments"]?.arrayValue ?? []).compactMap { raw -> MCPPromptDescriptor.Argument? in
                guard let argument = raw.objectValue,
                      let argumentName = argument["name"]?.stringValue else { return nil }
                return .init(
                    name: argumentName,
                    description: argument["description"]?.stringValue,
                    required: argument["required"]?.boolValue ?? false
                )
            }
            return MCPPromptDescriptor(
                serverName: config.name,
                name: name,
                description: object["description"]?.stringValue,
                arguments: arguments
            )
        }
    }

    /// Expands a prompt template into concrete message text.
    func getPrompt(name: String, arguments: [String: String]) async throws -> String {
        let mapped = arguments.mapValues { JSONValue.string($0) }
        let result = try await send(
            method: "prompts/get",
            params: .object(["name": .string(name), "arguments": .object(mapped)])
        )
        guard let messages = result.objectValue?["messages"]?.arrayValue else { return "" }
        return messages.compactMap { entry -> String? in
            guard let object = entry.objectValue else { return nil }
            let content = object["content"]
            if let text = content?.objectValue?["text"]?.stringValue { return text }
            if let text = content?.stringValue { return text }
            return nil
        }.joined(separator: "\n\n")
    }

    func listTools() async throws -> [MCPToolDescriptor] {
        let result = try await send(method: "tools/list", params: .object([:]))
        guard let entries = result.objectValue?["tools"]?.arrayValue else {
            throw MCPError.protocolError("tools/list did not return a tools array")
        }
        return entries.compactMap { entry in
            guard let object = entry.objectValue,
                  let name = object["name"]?.stringValue else { return nil }
            return MCPToolDescriptor(
                serverName: config.name,
                toolName: name,
                description: object["description"]?.stringValue ?? "MCP tool \(name)",
                inputSchema: object["inputSchema"] ?? .object([
                    "type": .string("object"),
                    "properties": .object([:])
                ])
            )
        }
    }

    func callTool(name: String, arguments: JSONValue) async throws -> NativeAgentToolResult {
        let result = try await send(
            method: "tools/call",
            params: .object(["name": .string(name), "arguments": arguments])
        )
        return Self.flatten(result)
    }

    /// Converts an MCP content array into plain text for the model.
    static func flatten(_ result: JSONValue) -> NativeAgentToolResult {
        let object = result.objectValue
        let isError = object?["isError"]?.boolValue ?? false
        guard let content = object?["content"]?.arrayValue else {
            return .init(content: result.jsonText, isError: isError)
        }
        let parts: [String] = content.compactMap { item in
            guard let entry = item.objectValue else { return nil }
            switch entry["type"]?.stringValue {
            case "text":
                return entry["text"]?.stringValue
            case "image":
                let mime = entry["mimeType"]?.stringValue ?? "image"
                return "[image content: \(mime)]"
            case "resource":
                let uri = entry["resource"]?.objectValue?["uri"]?.stringValue ?? "unknown"
                return "[resource: \(uri)]"
            default:
                return entry["text"]?.stringValue
            }
        }
        let text = parts.joined(separator: "\n")
        return .init(content: text.isEmpty ? "(no content)" : text, isError: isError)
    }

    // MARK: JSON-RPC plumbing

    private func send(method: String, params: JSONValue) async throws -> JSONValue {
        guard process?.isRunning == true else { throw MCPError.notConnected }
        let id = nextID
        nextID += 1

        let envelope = JSONValue.object([
            "jsonrpc": .string("2.0"),
            "id": .number(Double(id)),
            "method": .string(method),
            "params": params
        ])

        let timeout = requestTimeout
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            await self?.fail(id: id, with: MCPError.timedOut(method))
        }
        defer { timer.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            // Register BEFORE writing, on the actor: a fast server's reply can
            // otherwise arrive before the continuation exists and be dropped,
            // leaving the call to hang until the timeout.
            Task { await self.registerAndWrite(id: id, envelope: envelope, continuation: continuation) }
        }
    }

    private func registerAndWrite(id: Int, envelope: JSONValue, continuation: CheckedContinuation<JSONValue, Error>) {
        guard process?.isRunning == true else {
            continuation.resume(throwing: MCPError.notConnected)
            return
        }
        pending[id] = continuation
        do {
            try write(envelope)
        } catch {
            pending[id] = nil
            continuation.resume(throwing: error)
        }
    }

    /// Resolves one pending request with an error (timeout). No-op when the
    /// reply already arrived.
    private func fail(id: Int, with error: Error) {
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func notify(method: String, params: JSONValue) async throws {
        try write(.object([
            "jsonrpc": .string("2.0"),
            "method": .string(method),
            "params": params
        ]))
    }

    private func write(_ value: JSONValue) throws {
        guard let handle = stdinHandle else { throw MCPError.notConnected }
        var data = Data(value.jsonText.utf8)
        data.append(0x0A)
        do {
            try handle.write(contentsOf: data)
        } catch {
            throw MCPError.transport(error.localizedDescription)
        }
    }

    /// Accumulates stdout and dispatches each complete newline-delimited message.
    private func ingest(_ data: Data) {
        readBuffer.append(data)
        while let newline = readBuffer.firstIndex(of: 0x0A) {
            let line = readBuffer[readBuffer.startIndex..<newline]
            readBuffer.removeSubrange(readBuffer.startIndex...newline)
            guard !line.isEmpty else { continue }
            dispatch(String(decoding: line, as: UTF8.self))
        }
    }

    private func dispatch(_ line: String) {
        // Servers sometimes emit non-JSON banner text on stdout; ignore it.
        guard let message = JSONValue.parse(line)?.objectValue else { return }
        guard let idValue = message["id"], case .number(let rawID) = idValue else { return }
        let id = Int(rawID)
        guard let continuation = pending.removeValue(forKey: id) else { return }

        if let error = message["error"]?.objectValue {
            let code = Int(error["code"].flatMap { value -> Double? in
                if case .number(let number) = value { return number }
                return nil
            } ?? 0)
            let text = error["message"]?.stringValue ?? "unknown error"
            continuation.resume(throwing: MCPError.server(code: code, message: text))
            return
        }
        continuation.resume(returning: message["result"] ?? .object([:]))
    }
}
