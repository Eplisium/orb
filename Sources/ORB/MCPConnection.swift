import Darwin
import Foundation
import CryptoKit

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
    /// Optional folder the server starts in (`cwd` in imported configs).
    var workingDirectory: String? = nil

    enum CodingKeys: String, CodingKey {
        case id, name, command, args, env, isEnabled, secretEnv
        case workingDirectory = "cwd"
    }

    /// Prefix of every reference minted by the current scheme.
    static let secretReferencePrefix = "orb-mcp-v2-"

    /// Collision-resistant store reference for one env variable of one config.
    ///
    /// Built from the config's stable `id` (UUID) plus the variable name
    /// encoded as unpadded base64url of its UTF-8 bytes. The encoding is
    /// injective and its alphabet has no `-` delimiter ambiguity with the UUID
    /// (fixed 36 chars), so two configs — or two variables differing only by
    /// punctuation (`prod_api` vs `prod-api`, `A_B` vs `A-B`) — never share a
    /// reference. Renaming a server does not orphan its secrets.
    static func secretReference(configID: UUID, variable: String) -> String {
        let encoded = Data(variable.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "\(secretReferencePrefix)\(configID.uuidString.lowercased())-\(encoded)"
    }

    /// The pre-UUID reference scheme (sanitized names). NOT collision-safe:
    /// `prod_api` and `prod-api` map to the same value. Kept only so configs
    /// that already store such references keep resolving — `secretEnv` values
    /// are opaque and are looked up verbatim at launch. Never used to mint a
    /// new reference.
    static func legacySecretReference(serverName: String, variable: String) -> String {
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

    /// Synthetic tools bridging MCP's non-tool capabilities (resources,
    /// prompts) into the tool-calling interface a chat model can use.
    /// Bridges are SERVER-QUALIFIED (`mcp__<server>__read_resource`) so they
    /// parse with `resolve`, flow through the same per-server policy approval
    /// as any MCP tool, and route only to that server.
    enum Bridge: Equatable, Sendable {
        case readResource
        case getPrompt

        var toolName: String {
            switch self {
            case .readResource: return "read_resource"
            case .getPrompt: return "get_prompt"
            }
        }
    }

    static func readResourceTool(server: String) -> String {
        qualify(server: server, tool: Bridge.readResource.toolName)
    }

    static func getPromptTool(server: String) -> String {
        qualify(server: server, tool: Bridge.getPrompt.toolName)
    }

    /// The bridge a bare tool name (the part after the server) denotes, if any.
    static func bridge(forTool tool: String) -> Bridge? {
        switch tool {
        case Bridge.readResource.toolName: return .readResource
        case Bridge.getPrompt.toolName: return .getPrompt
        default: return nil
        }
    }

    static func qualify(server: String, tool: String) -> String {
        "\(prefix)\(separator)\(serverKey(server))\(separator)\(toolKey(tool))"
    }

    /// Splits a qualified name back into its server and tool parts.
    static func resolve(_ qualified: String) -> (server: String, tool: String)? {
        let parts = qualified.components(separatedBy: separator)
        guard parts.count >= 3, parts[0] == prefix else { return nil }
        // The tool name itself may contain the separator; the server slug cannot.
        return (parts[1], parts.dropFirst(2).joined(separator: separator))
    }

    /// Bounded, collision-resistant identity. Reserve z- so a literal digest
    /// cannot impersonate a compacted name. Server + tool + separators fit the
    /// common 64-byte provider function-name limit. Secret references retain
    /// their separate legacy naming and are never changed here.
    static func serverKey(_ value: String) -> String {
        boundedKey(value, limit: 27, underscores: false)
    }

    static func toolKey(_ value: String) -> String {
        boundedKey(value, limit: 30, underscores: true)
    }

    private static func boundedKey(_ value: String, limit: Int, underscores: Bool) -> String {
        let safe = !value.isEmpty && value.utf8.count <= limit && !value.hasPrefix("z-") && value.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) ||
            (48...57).contains($0) || $0 == 45 || (underscores && $0 == 95)
        }
        if safe { return value }
        return "z-h" + SHA256.hash(data: Data(value.utf8)).prefix(12)
            .map { String(format: "%02x", $0) }.joined()
    }

    /// Legacy credential references only. Never use for RPC identity.
    static func sanitize(_ value: String) -> String {
        let allowed = value.map { character -> Character in
            character.isLetter || character.isNumber ? character : "-"
        }
        return String(allowed)
    }
}

/// Cancellation is signalled synchronously from any executor, while all pipe
/// ownership and continuation bookkeeping remain isolated to MCPConnection.
/// The last few KB a server wrote to stderr. Setup failures ("npm ERR! 404",
/// "TOKEN is required", Python tracebacks) are only ever reported there.
final class MCPStderrTail: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var data = Data()

    init(limit: Int = 4_096) { self.limit = limit }

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        data.append(chunk)
        if data.count > limit { data = Data(data.suffix(limit)) }
        lock.unlock()
    }

    func reset() { lock.lock(); data.removeAll(); lock.unlock() }

    /// The last `lines` non-empty lines, each trimmed; empty when silent.
    func lastLines(_ lines: Int = 5) -> String {
        lock.lock()
        let text = String(decoding: data, as: UTF8.self)
        lock.unlock()
        return text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .suffix(lines)
            .joined(separator: "\n")
    }

    /// `message`, followed by the stderr tail when there is one.
    func annotate(_ message: String) -> String {
        let tail = lastLines()
        return tail.isEmpty ? message : message + "\nServer output:\n" + tail
    }
}

private final class MCPWriteCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
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
    /// Process presence is transport liveness, not completed discovery. The
    /// initiating caller owns this identity; later callers only own waiters.
    // Mutable fields are accessed only on this actor; onCancel uses only the
    // thread-safe cancellation flag and passes the identity back to the actor.
    private final class StartupAttempt: @unchecked Sendable {
        let process = Process()
        let cancellation = MCPWriteCancellation()
        var result: Result<Void, Error>?
        var joiners: [UUID: CheckedContinuation<Void, Error>] = [:]
    }
    private var startup: StartupAttempt?
    private(set) var isReady = false
    private var stdinHandle: FileHandle?
    private struct PendingRequest {
        let method: String
        let expectsReply: Bool
        let deadline: ContinuousClock.Instant
        let cancellation: MCPWriteCancellation
        let continuation: CheckedContinuation<JSONValue, Error>
    }
    private struct OutboundFrame {
        let id: Int
        let data: Data
        var offset = 0
    }
    private var pending: [Int: PendingRequest] = [:]
    private var outbound: [OutboundFrame] = []
    private var writerPump: Task<Void, Never>?
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
    /// Why the connection is not usable, when a running server died on us.
    /// Cleared by a successful `connect()`.
    private(set) var lastError: String?

    /// Per-request ceiling. MCP tools can be slow (network, browsers), but an
    /// unbounded wait would hang the whole agent run.
    private let requestTimeout: Duration
    /// `initialize` answers in well under a second from a healthy server; a
    /// server that never answers it should fail fast, not after two minutes.
    private let initializeTimeout: Duration
    private let stderrTail = MCPStderrTail()
    /// Most pages followed for one `*/list` call (`nextCursor`).
    static let maximumListPages = 20

    init(
        config: MCPServerConfig,
        secretStore: CredentialSecretStore = KeychainCredentialStore(),
        requestTimeout: Duration = .seconds(120),
        initializeTimeout: Duration = .seconds(30)
    ) {
        self.config = config
        self.secretStore = secretStore
        self.requestTimeout = requestTimeout
        self.initializeTimeout = min(initializeTimeout, requestTimeout)
    }

    /// The server's recent stderr, for diagnostics.
    var recentStderr: String { stderrTail.lastLines(10) }

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
        try Task.checkCancellation()
        if let startup {
            try await joinStartup(startup)
            return
        }
        if isReady, process?.isRunning == true { return }
        // A process can have exited before its termination callback arrives.
        if process != nil { shutdown() }
        let attempt = StartupAttempt()
        startup = attempt
        let cancellation = attempt.cancellation
        try await withTaskCancellationHandler {
            do {
                try await startTransport(attempt)
                try checkStartupTransport(attempt)
                isReady = true
                finishStartup(attempt, with: .success(()))
            } catch {
                // Shutdown may already have resolved this exact attempt while
                // its owner was suspended. Do not replace that terminal result
                // or close a newer transport started on the same actor.
                var failure: Error
                if case .failure(let resolved)? = attempt.result {
                    failure = resolved
                } else {
                    failure = cancellation.isCancelled ? CancellationError() : error
                }
                if !(failure is CancellationError) {
                    // Give the user the server's own explanation. A brief
                    // pause lets a dying server's last stderr line arrive.
                    if stderrTail.lastLines().isEmpty { try? await Task.sleep(for: .milliseconds(150)) }
                    failure = Self.withServerOutput(failure, tail: stderrTail)
                }
                if startup === attempt { closeTransport(with: failure) }
                if !(failure is CancellationError) { lastError = failure.localizedDescription }
                throw failure
            }
        } onCancel: {
            cancellation.cancel()
            Task { await self.cancelStartup(attempt) }
        }
    }

    private func joinStartup(_ attempt: StartupAttempt) async throws {
        let id = UUID()
        let cancellation = MCPWriteCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard !cancellation.isCancelled, !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if let result = attempt.result {
                    continuation.resume(with: result)
                } else {
                    attempt.joiners[id] = continuation
                }
            }
            try Task.checkCancellation()
        } onCancel: {
            cancellation.cancel()
            Task { await self.cancelStartupJoiner(id, in: attempt) }
        }
    }

    private func cancelStartupJoiner(_ id: UUID, in attempt: StartupAttempt) {
        attempt.joiners.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }

    private func cancelStartup(_ attempt: StartupAttempt) {
        guard startup === attempt else { return }
        closeTransport(with: CancellationError())
    }

    private func finishStartup(_ attempt: StartupAttempt, with result: Result<Void, Error>) {
        guard attempt.result == nil else { return }
        attempt.result = result
        if startup === attempt { startup = nil }
        let joiners = attempt.joiners.values
        attempt.joiners.removeAll()
        for continuation in joiners { continuation.resume(with: result) }
    }

    private func startTransport(_ attempt: StartupAttempt) async throws {
        try Task.checkCancellation()
        isShuttingDown = false
        lastError = nil
        stderrTail.reset()

        let task = attempt.process
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
        if let directory = config.workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines), !directory.isEmpty {
            task.currentDirectoryURL = URL(fileURLWithPath: NSString(string: directory).expandingTildeInPath, isDirectory: true)
        }

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
            for await chunk in chunks {
                guard !Task.isCancelled else { return }
                await self?.ingest(chunk, from: task)
            }
        }
        stdoutSink = chunkSink
        // Drain stderr so a chatty server cannot fill the pipe buffer and
        // block, keeping only a short tail to explain failures.
        let tail = stderrTail
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            tail.append(handle.availableData)
        }
        task.terminationHandler = { [weak self] terminated in
            Task { await self?.handleTermination(terminated) }
        }

        process = task
        do {
            try task.run()
        } catch {
            throw MCPError.launchFailed("\(config.command): \(error.localizedDescription)")
        }

        stdinHandle = stdinPipe.fileHandleForWriting
        let fd = stdinPipe.fileHandleForWriting.fileDescriptor
        let flags = fcntl(fd, F_GETFL)
        guard flags != -1,
              fcntl(fd, F_SETFL, flags | O_NONBLOCK) != -1,
              fcntl(fd, F_SETNOSIGPIPE, 1) != -1 else {
            throw MCPError.transport("Could not configure nonblocking MCP stdin")
        }

        let initResult = try await send(
            method: "initialize",
            timeout: initializeTimeout,
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
        try checkStartupTransport(attempt)
        serverInfo = initResult.objectValue?["serverInfo"]?.objectValue?["name"]?.stringValue
        // Record what the server actually supports so we never call a method it
        // doesn't implement (many servers error rather than returning empty).
        let capabilities = initResult.objectValue?["capabilities"]?.objectValue ?? [:]
        supportsResources = capabilities["resources"] != nil
        supportsPrompts = capabilities["prompts"] != nil

        try await notify(method: "notifications/initialized", params: .object([:]))
        try checkStartupTransport(attempt)
        let discoveredTools = try await listTools()
        try checkStartupTransport(attempt)
        tools = discoveredTools
        // Ordinary optional RPC failures are tolerated, but cancellation or a
        // closed/replaced transport must never publish successful startup.
        if supportsResources {
            let discoveredResources = (try? await listResources()) ?? []
            try checkStartupTransport(attempt)
            resources = discoveredResources
        }
        if supportsPrompts {
            let discoveredPrompts = (try? await listPrompts()) ?? []
            try checkStartupTransport(attempt)
            prompts = discoveredPrompts
        }
        try checkStartupTransport(attempt)
    }

    private func checkStartupTransport(_ attempt: StartupAttempt) throws {
        if let result = attempt.result { try result.get() }
        try Task.checkCancellation()
        guard !attempt.cancellation.isCancelled else { throw CancellationError() }
        guard startup === attempt, process === attempt.process,
              attempt.process.isRunning else { throw MCPError.notConnected }
    }

    func shutdown() {
        closeTransport(with: MCPError.notConnected)
    }

    private func closeTransport(with error: Error) {
        if let startup { finishStartup(startup, with: .failure(error)) }
        isReady = false
        isShuttingDown = true
        for (_, request) in pending {
            request.continuation.resume(throwing: error)
        }
        pending.removeAll()
        outbound.removeAll()
        writerPump?.cancel()
        writerPump = nil
        stdoutSink?.finish()
        stdoutSink = nil
        stdoutPump?.cancel()
        stdoutPump = nil
        stdinHandle?.closeFile()
        (process?.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        (process?.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        if let process, process.isRunning { process.terminate() }
        process = nil
        stdinHandle = nil
        readBuffer.removeAll()
        tools = []
        resources = []
        prompts = []
        supportsResources = false
        supportsPrompts = false
        serverInfo = nil
    }

    private func handleTermination(_ terminated: Process) {
        // A late callback from a closed transport must not tear down a newly
        // connected process on this same actor.
        guard process === terminated, !isShuttingDown else { return }
        let status = terminated.terminationStatus
        let error = MCPError.transport(stderrTail.annotate("server exited unexpectedly (exit code \(status))"))
        closeTransport(with: error)
        lastError = stderrTail.annotate("MCP server \"\(config.name)\" exited unexpectedly (exit code \(status)).")
    }

    /// Appends the server's stderr tail to a startup failure.
    static func withServerOutput(_ error: Error, tail: MCPStderrTail) -> Error {
        guard !tail.lastLines().isEmpty else { return error }
        switch error {
        case MCPError.launchFailed(let detail): return MCPError.launchFailed(tail.annotate(detail))
        case MCPError.transport(let detail):
            return detail.contains("Server output:") ? error : MCPError.transport(tail.annotate(detail))
        case MCPError.timedOut(let method): return MCPError.transport(tail.annotate("request timed out: \(method)"))
        case MCPError.notConnected: return MCPError.transport(tail.annotate("server stopped during startup"))
        case MCPError.protocolError(let detail): return MCPError.protocolError(tail.annotate(detail))
        case MCPError.server(let code, let message): return MCPError.server(code: code, message: tail.annotate(message))
        default: return error
        }
    }

    /// Follows `nextCursor` across pages of one list method.
    private func listAllPages(method: String, key: String) async throws -> [JSONValue]? {
        var entries: [JSONValue] = []
        var cursor: String?
        var sawArray = false
        for _ in 0..<Self.maximumListPages {
            let params: JSONValue = cursor.map { .object(["cursor": .string($0)]) } ?? .object([:])
            let result = try await send(method: method, params: params)
            if let page = result.objectValue?[key]?.arrayValue {
                sawArray = true
                entries += page
            }
            guard let next = result.objectValue?["nextCursor"]?.stringValue, !next.isEmpty, next != cursor else { break }
            cursor = next
        }
        return sawArray ? entries : nil
    }

    // MARK: Requests

    func listResources() async throws -> [MCPResourceDescriptor] {
        guard let entries = try await listAllPages(method: "resources/list", key: "resources") else { return [] }
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
        guard let entries = try await listAllPages(method: "prompts/list", key: "prompts") else { return [] }
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
        guard let entries = try await listAllPages(method: "tools/list", key: "tools") else {
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

    private func send(method: String, timeout: Duration? = nil, params: JSONValue) async throws -> JSONValue {
        let id = nextID
        nextID += 1
        let envelope = JSONValue.object([
            "jsonrpc": .string("2.0"),
            "id": .number(Double(id)),
            "method": .string(method),
            "params": params
        ])
        return try await exchange(id: id, method: method, envelope: envelope, expectsReply: true, timeout: timeout)
    }

    /// One absolute deadline covers encoding, waiting for the ordered writer,
    /// the write itself, and the response. Notifications/replies use this same
    /// path, but finish when their complete frame has reached the pipe.
    private func exchange(
        id: Int, method: String, envelope: JSONValue, expectsReply: Bool, timeout: Duration? = nil
    ) async throws -> JSONValue {
        try Task.checkCancellation()
        guard process?.isRunning == true else { throw MCPError.notConnected }
        let deadline = ContinuousClock.now + (timeout ?? requestTimeout)
        let cancellation = MCPWriteCancellation()
        let timer = Task { [weak self] in
            try? await Task.sleep(until: deadline, clock: .continuous)
            guard !Task.isCancelled else { return }
            await self?.fail(id: id, with: MCPError.timedOut(method))
        }
        defer { timer.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<JSONValue, Error>) in
                // The cancellation handler may have run before registration.
                guard !cancellation.isCancelled, !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                var data = Data(envelope.jsonText.utf8)
                data.append(0x0A)
                guard ContinuousClock.now < deadline else {
                    continuation.resume(throwing: MCPError.timedOut(method))
                    return
                }
                // Register BEFORE any bytes are written, including tiny frames
                // whose reply may arrive immediately.
                pending[id] = PendingRequest(
                    method: method, expectsReply: expectsReply, deadline: deadline,
                    cancellation: cancellation, continuation: continuation
                )
                outbound.append(OutboundFrame(id: id, data: data))
                if writerPump == nil {
                    writerPump = Task { [weak self] in
                        guard let self else { return }
                        await self.pumpWrites()
                    }
                }
            }
        } onCancel: {
            // Synchronous flag stops queued frames even before the actor gets
            // to the cancellation task. Never perform I/O in this handler.
            cancellation.cancel()
            Task { await self.fail(id: id, with: CancellationError()) }
        }
    }

    /// Bounded nonblocking syscalls keep the connection actor responsive. There
    /// is exactly one writer and only its head frame can make progress; JSON
    /// lines never interleave. EAGAIN sleeps cooperatively rather than holding
    /// a thread (or an actor) waiting for a stalled server to drain stdin.
    private func pumpWrites() async {
        while !Task.isCancelled {
            guard let frame = outbound.first else {
                writerPump = nil
                return
            }
            guard let request = pending[frame.id] else {
                outbound.removeFirst()
                continue
            }
            if request.cancellation.isCancelled {
                fail(id: frame.id, with: CancellationError())
                continue
            }
            if ContinuousClock.now >= request.deadline {
                fail(id: frame.id, with: MCPError.timedOut(request.method))
                continue
            }
            guard let handle = stdinHandle else {
                shutdown()
                return
            }
            let remaining = min(frame.data.count - frame.offset, 16 * 1024)
            let written = frame.data.withUnsafeBytes { bytes in
                Darwin.write(handle.fileDescriptor, bytes.baseAddress!.advanced(by: frame.offset), remaining)
            }
            if written > 0 {
                outbound[0].offset += written
                if outbound[0].offset == frame.data.count {
                    outbound.removeFirst()
                    if !request.expectsReply {
                        pending.removeValue(forKey: frame.id)?.continuation.resume(returning: .object([:]))
                    }
                }
                await Task.yield()
            } else if written < 0 && errno == EINTR {
                await Task.yield()
            } else if written == 0 || errno == EAGAIN || errno == EWOULDBLOCK {
                try? await Task.sleep(for: .milliseconds(5))
            } else {
                let error = MCPError.transport("Could not write MCP stdin (errno \(errno))")
                closeTransport(with: error)
                lastError = error.localizedDescription
                return
            }
        }
    }

    /// Removing an untouched frame is safe. Removing half a JSON line is NOT:
    /// sending its tail could execute a cancelled call, and skipping the tail
    /// would splice the next message into malformed JSON. Close the transport
    /// in that case, aborting all outstanding calls without sending a newline.
    /// Already-sent calls receive a bounded, best-effort cancel notification.
    private func fail(id: Int, with error: Error) {
        guard let request = pending.removeValue(forKey: id) else { return }
        request.continuation.resume(throwing: error)
        if let index = outbound.firstIndex(where: { $0.id == id }) {
            let partial = outbound[index].offset > 0
            outbound.remove(at: index)
            if partial {
                closeTransport(with: error)
                lastError = "MCP connection closed after an interrupted partial write; reconnect to continue."
            }
            return
        }
        // initialize MUST NOT receive notifications/cancelled (MCP spec).
        guard request.expectsReply, request.method != "initialize",
              let expected = process, expected.isRunning else { return }
        let reason = error is CancellationError ? "Cancelled by client" : "Request timed out"
        Task { [weak self] in
            try? await self?.notifyIfCurrent(expected, method: "notifications/cancelled", params: .object([
                "requestId": .number(Double(id)), "reason": .string(reason)
            ]))
        }
    }

    private func notifyIfCurrent(_ expected: Process, method: String, params: JSONValue) async throws {
        guard process === expected else { return }
        try await notify(method: method, params: params)
    }

    private func replyIfCurrent(_ expected: Process, reply: JSONValue, method: String) async throws {
        guard process === expected else { return }
        try await writeMessage(reply, method: method)
    }

    // Internal rather than private so transport tests exercise the real
    // notification path (including initialized/cancelled notifications).
    func notify(method: String, params: JSONValue) async throws {
        try await writeMessage(.object([
            "jsonrpc": .string("2.0"),
            "method": .string(method),
            "params": params
        ]), method: method)
    }

    private func writeMessage(_ envelope: JSONValue, method: String) async throws {
        let id = nextID
        nextID += 1
        _ = try await exchange(id: id, method: method, envelope: envelope, expectsReply: false)
    }

    /// Accumulates stdout and dispatches each complete newline-delimited message.
    private func ingest(_ data: Data, from expected: Process) {
        guard process === expected else { return }
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

        // A message WITH a method is a server-initiated request or
        // notification, never a response. Matching pending requests on any
        // numeric id let a server keepalive ping carrying id 5 resolve ORB's
        // own pending id 5 with an empty result — and the ping went unanswered,
        // so servers with ping timeouts dropped the connection.
        if let method = message["method"]?.stringValue {
            handleServerMessage(method: method, message: message)
            return
        }

        // Only method-less messages are responses. `Int(exactly:)` because a
        // server-supplied id outside Int's range must be ignored, not trap.
        guard let idValue = message["id"], case .number(let rawID) = idValue,
              let id = Int(exactly: rawID),
              let request = pending[id], request.expectsReply,
              !outbound.contains(where: { $0.id == id }) else { return }
        if request.cancellation.isCancelled {
            fail(id: id, with: CancellationError())
            return
        }
        if ContinuousClock.now >= request.deadline {
            fail(id: id, with: MCPError.timedOut(request.method))
            return
        }
        pending[id] = nil
        let continuation = request.continuation

        if let error = message["error"]?.objectValue {
            let rawCode = error["code"].flatMap { value -> Double? in
                if case .number(let number) = value { return number }
                return nil
            }
            let code = rawCode.flatMap { Int(exactly: $0) } ?? 0
            let text = error["message"]?.stringValue ?? "unknown error"
            continuation.resume(throwing: MCPError.server(code: code, message: text))
            return
        }
        continuation.resume(returning: message["result"] ?? .object([:]))
    }

    /// Answers a server-initiated JSON-RPC message. Requests carry an id and
    /// get a reply (`ping` is answered with an empty result per the spec, any
    /// other method with "method not found"); notifications (no id) are
    /// informational only.
    private func handleServerMessage(method: String, message: [String: JSONValue]) {
        guard let id = message["id"], let expected = process, expected.isRunning else {
            if message["id"] == nil { handleNotification(method) }
            return
        }
        let reply: JSONValue
        if method == "ping" {
            reply = .object(["jsonrpc": .string("2.0"), "id": id, "result": .object([:])])
        } else {
            reply = .object([
                "jsonrpc": .string("2.0"),
                "id": id,
                "error": .object([
                    "code": .number(-32601),
                    "message": .string("Method not found: \(method)")
                ])
            ])
        }
        Task { [weak self] in
            try? await self?.replyIfCurrent(expected, reply: reply, method: "reply/" + method)
        }
    }

    /// Servers that change their surface at runtime announce it; re-list so
    /// new tools appear without Reconnect All.
    private func handleNotification(_ method: String) {
        guard isReady, startup == nil, let expected = process, expected.isRunning else { return }
        switch method {
        case "notifications/tools/list_changed":
            Task { [weak self] in await self?.refreshList(.tools, expected: expected) }
        case "notifications/resources/list_changed" where supportsResources:
            Task { [weak self] in await self?.refreshList(.resources, expected: expected) }
        case "notifications/prompts/list_changed" where supportsPrompts:
            Task { [weak self] in await self?.refreshList(.prompts, expected: expected) }
        default:
            break
        }
    }

    private enum ListKind { case tools, resources, prompts }

    /// Count of completed list refreshes triggered by notifications (tests).
    private(set) var listRefreshCount = 0

    private func refreshList(_ kind: ListKind, expected: Process) async {
        guard process === expected, isReady else { return }
        switch kind {
        case .tools:
            guard let fresh = try? await listTools(), process === expected else { return }
            tools = fresh
        case .resources:
            guard let fresh = try? await listResources(), process === expected else { return }
            resources = fresh
        case .prompts:
            guard let fresh = try? await listPrompts(), process === expected else { return }
            prompts = fresh
        }
        listRefreshCount += 1
    }
}
