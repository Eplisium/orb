import Foundation

// MARK: - ORB self-control (OP Mode only)
//
// Lets the Agent inspect and manage ORB itself: sessions, usage, settings,
// MCP servers. The capability `.orbControl` is granted ONLY while OP Mode is
// on (see `ToolPolicy.agentSession`), so Web Only/ordinary sessions neither
// see nor can run these tools.
//
// Deliberate limits, because OP Mode removes the approval prompt:
//  - Never reveals secrets: API keys, MCP env values, and Keychain items are
//    not readable through any tool here.
//  - Cannot change its own privileges: OP Mode itself and Computer Access are
//    not settable, and MCP servers cannot be created, only toggled.
//  - Cannot touch the running conversation (delete / prompt edit).

/// What the control tools need from the app. ChatService conforms.
@MainActor
protocol ORBControlHost: AnyObject {
    var controlConversations: [ChatConversation] { get }
    var controlRunningConversationID: UUID? { get }
    func controlRename(_ id: UUID, to title: String) -> Bool
    func controlSetSystemPrompt(_ prompt: String, for id: UUID) -> Bool
    func controlDelete(_ id: UUID) -> Bool
    func controlMCPConfigs() -> [MCPServerConfig]
    func controlSaveMCPConfigs(_ configs: [MCPServerConfig])
    var controlDefaults: UserDefaults { get }
}

enum ORBControlTools {
    static let names: Set<String> = [
        "orb_overview", "orb_list_sessions", "orb_read_session", "orb_search_sessions", "orb_usage",
        "orb_get_settings", "orb_set_setting", "orb_rename_session", "orb_set_session_prompt",
        "orb_delete_session", "orb_list_mcp_servers", "orb_set_mcp_server_enabled",
    ]

    /// Settings the agent may read and change. Privileges (OP Mode, Computer
    /// Access) and anything secret are intentionally absent.
    static let settableKeys: [String: SettingKind] = [
        "playground.requireCommandToSend": .bool,
        "playground.agentTemperatureSet": .bool,
        "playground.agentTemperature": .number(0...2),
        "playground.agentReasoningEffort": .oneOf(["", "minimal", "low", "medium", "high"]),
        "playground.agentWorkspace": .string,
    ]

    enum SettingKind: Equatable {
        case bool, string
        case number(ClosedRange<Double>)
        case oneOf([String])
    }

    static func isORBTool(_ name: String) -> Bool { names.contains(name) }

    // MARK: Definitions

    static func definitions() -> [AgentToolDefinition] {
        func def(_ name: String, _ description: String, _ props: [String: AgentToolProperty] = [:], required: [String] = []) -> AgentToolDefinition {
            AgentToolDefinition(function: .init(
                name: name, description: description,
                parameters: .native(AgentToolParameters(properties: props, required: required))
            ))
        }
        let id = AgentToolProperty(type: "string", description: "Session id from orb_list_sessions (a prefix of 8+ characters is fine).")
        return [
            def("orb_overview", "Summarize ORB: session counts by mode, total tokens and cost, MCP servers, and the session you are running in."),
            def("orb_list_sessions", "List ORB chat/agent sessions, newest first.", [
                "mode": .init(type: "string", description: "Optional: \"chat\" or \"agent\"."),
                "query": .init(type: "string", description: "Optional: only titles containing this text."),
                "limit": .init(type: "integer", description: "Max rows, default 30, up to 200."),
            ]),
            def("orb_read_session", "Read messages from a session (role, time, text, tool calls, usage).", [
                "id": id,
                "limit": .init(type: "integer", description: "Most recent N messages, default 20, up to 100."),
                "max_chars": .init(type: "integer", description: "Per-message character cap, default 1500."),
            ], required: ["id"]),
            def("orb_search_sessions", "Search message text across every session (case-insensitive).", [
                "query": .init(type: "string", description: "Text to find."),
                "limit": .init(type: "integer", description: "Max hits, default 20, up to 100."),
            ], required: ["query"]),
            def("orb_usage", "Token and cost totals, overall and per model."),
            def("orb_get_settings", "Show the ORB settings this agent may read or change."),
            def("orb_set_setting", "Change one ORB setting from orb_get_settings.", [
                "key": .init(type: "string", description: "Setting key."),
                "value": .init(type: "string", description: "New value (true/false, a number, or text)."),
            ], required: ["key", "value"]),
            def("orb_rename_session", "Rename a session.", [
                "id": id, "title": .init(type: "string", description: "New title."),
            ], required: ["id", "title"]),
            def("orb_set_session_prompt", "Set a session's system prompt (not the one currently running).", [
                "id": id, "prompt": .init(type: "string", description: "Full system prompt; empty clears it."),
            ], required: ["id", "prompt"]),
            def("orb_delete_session", "Permanently delete a session (not the one currently running). Cannot be undone.", [
                "id": id,
            ], required: ["id"]),
            def("orb_list_mcp_servers", "List configured MCP servers (name, command, enabled). Secrets are never shown."),
            def("orb_set_mcp_server_enabled", "Enable or disable a configured MCP server; applies from the next run.", [
                "name": .init(type: "string", description: "Server name from orb_list_mcp_servers."),
                "enabled": .init(type: "string", description: "true or false."),
            ], required: ["name", "enabled"]),
        ]
    }

    // MARK: Execution

    @MainActor
    static func execute(name: String, argumentsJSON: String, host: ORBControlHost) -> NativeAgentToolResult {
        let args = (argumentsJSON.data(using: .utf8))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        func string(_ key: String) -> String? {
            if let s = args[key] as? String { return s }
            if let n = args[key] as? NSNumber { return n.stringValue }
            return nil
        }
        func int(_ key: String, default value: Int, max cap: Int) -> Int {
            let raw = (args[key] as? Int) ?? Int(string(key) ?? "") ?? value
            return min(max(raw, 1), cap)
        }
        func ok(_ text: String) -> NativeAgentToolResult { .init(content: text, isError: false) }
        func fail(_ text: String) -> NativeAgentToolResult { .init(content: text, isError: true) }
        func resolve() -> ORBResolution {
            guard let raw = string("id")?.lowercased(), raw.count >= 8 else {
                return .failure(fail("Provide a session id (8+ characters) from orb_list_sessions."))
            }
            let matches = host.controlConversations.filter { $0.id.uuidString.lowercased().hasPrefix(raw) }
            switch matches.count {
            case 1: return .success(matches[0])
            case 0: return .failure(fail("No session matches \(raw)."))
            default: return .failure(fail("\(matches.count) sessions match \(raw); use a longer prefix."))
            }
        }

        let all = host.controlConversations
        switch name {
        case "orb_overview":
            let chats = all.filter { $0.mode == .chat }.count
            let agents = all.filter { $0.mode == .agent }.count
            let tokens = all.reduce(0) { $0 + $1.totalTokens }
            let cost = all.reduce(0) { $0 + $1.totalCost }
            let servers = host.controlMCPConfigs()
            let running = host.controlRunningConversationID.map { String($0.uuidString.prefix(8)) } ?? "none"
            return ok("""
            Sessions: \(all.count) (\(chats) chat, \(agents) agent)
            Total tokens: \(tokens.formatted()), total cost: $\(String(format: "%.4f", cost))
            MCP servers: \(servers.count) (\(servers.filter(\.isEnabled).count) enabled)
            You are running in session: \(running)
            """)

        case "orb_list_sessions":
            let mode = string("mode")?.lowercased()
            let query = string("query")?.lowercased()
            let rows = all
                .filter { mode == nil || $0.mode.rawValue.lowercased() == mode }
                .filter { query == nil || $0.title.lowercased().contains(query!) }
                .sorted { ($0.messages.last?.createdAt ?? $0.createdAt) > ($1.messages.last?.createdAt ?? $1.createdAt) }
                .prefix(int("limit", default: 30, max: 200))
            guard !rows.isEmpty else { return ok("No sessions.") }
            return ok(rows.map(line).joined(separator: "\n"))

        case "orb_read_session":
            switch resolve() {
            case .failure(let result): return result
            case .success(let conversation):
                let limit = int("limit", default: 20, max: 100)
                let cap = int("max_chars", default: 1500, max: 20_000)
                let shown = conversation.messages.suffix(limit)
                var out = "\(line(conversation))\nSystem prompt: \(conversation.systemPrompt.isEmpty ? "(none)" : clip(conversation.systemPrompt, 500))\n"
                if shown.count < conversation.messages.count { out += "(showing last \(shown.count) of \(conversation.messages.count) messages)\n" }
                for message in shown {
                    out += "\n[\(message.role)] \(message.createdAt.formatted(date: .abbreviated, time: .standard))\n"
                    out += clip(message.content, cap) + "\n"
                    for call in message.toolCalls ?? [] { out += "  tool \(call.name)\(call.isError ? " (error)" : ""): \(clip(call.argumentsSummary, 200))\n" }
                    if let usage = message.usage, !usage.summary.isEmpty { out += "  usage: \(usage.summary)\n" }
                }
                return ok(out)
            }

        case "orb_search_sessions":
            guard let query = string("query")?.lowercased(), !query.isEmpty else { return fail("Provide a query.") }
            let limit = int("limit", default: 20, max: 100)
            var hits: [String] = []
            outer: for conversation in all {
                for message in conversation.messages where message.content.lowercased().contains(query) {
                    hits.append("\(conversation.id.uuidString.prefix(8)) \"\(conversation.title)\" [\(message.role)]: \(snippet(message.content, around: query))")
                    if hits.count >= limit { break outer }
                }
            }
            return ok(hits.isEmpty ? "No matches." : hits.joined(separator: "\n"))

        case "orb_usage":
            var perModel: [String: (tokens: Int, cost: Double, sessions: Int)] = [:]
            for conversation in all {
                var entry = perModel[conversation.modelId] ?? (0, 0, 0)
                entry.tokens += conversation.totalTokens; entry.cost += conversation.totalCost; entry.sessions += 1
                perModel[conversation.modelId] = entry
            }
            let rows = perModel.sorted { $0.value.cost > $1.value.cost }
                .map { "\($0.key): \($0.value.tokens.formatted()) tokens, $\(String(format: "%.4f", $0.value.cost)), \($0.value.sessions) sessions" }
            return ok(rows.isEmpty ? "No usage yet." : rows.joined(separator: "\n"))

        case "orb_get_settings":
            let defaults = host.controlDefaults
            let rows = settableKeys.keys.sorted().map { key -> String in
                let value = defaults.object(forKey: key).map { "\($0)" } ?? "(default)"
                return "\(key) = \(value)  [\(describe(settableKeys[key]!))]"
            }
            return ok(rows.joined(separator: "\n"))

        case "orb_set_setting":
            guard let key = string("key"), let kind = settableKeys[key] else {
                return fail("That setting is not changeable here. Allowed: \(settableKeys.keys.sorted().joined(separator: ", ")).")
            }
            guard let raw = string("value") else { return fail("Provide a value.") }
            switch coerce(raw, kind) {
            case .failure(let error): return fail(error.message)
            case .success(let value):
                host.controlDefaults.set(value, forKey: key)
                return ok("\(key) set to \(value).")
            }

        case "orb_rename_session":
            switch resolve() {
            case .failure(let result): return result
            case .success(let conversation):
                guard let title = string("title") else { return fail("Provide a title.") }
                return host.controlRename(conversation.id, to: title) ? ok("Renamed.") : fail("Could not rename.")
            }

        case "orb_set_session_prompt":
            switch resolve() {
            case .failure(let result): return result
            case .success(let conversation):
                if conversation.id == host.controlRunningConversationID { return fail("That is the session you are running in.") }
                return host.controlSetSystemPrompt(string("prompt") ?? "", for: conversation.id) ? ok("System prompt updated.") : fail("Could not update.")
            }

        case "orb_delete_session":
            switch resolve() {
            case .failure(let result): return result
            case .success(let conversation):
                if conversation.id == host.controlRunningConversationID { return fail("That is the session you are running in.") }
                return host.controlDelete(conversation.id) ? ok("Deleted \"\(conversation.title)\".") : fail("Could not delete.")
            }

        case "orb_list_mcp_servers":
            let rows = host.controlMCPConfigs().map { "\($0.name) — \($0.isEnabled ? "enabled" : "disabled") — \($0.command)" }
            return ok(rows.isEmpty ? "No MCP servers configured." : rows.joined(separator: "\n"))

        case "orb_set_mcp_server_enabled":
            guard let serverName = string("name"), let flag = string("enabled")?.lowercased(), ["true", "false"].contains(flag) else {
                return fail("Provide name and enabled (true/false).")
            }
            var configs = host.controlMCPConfigs()
            guard let index = configs.firstIndex(where: { $0.name == serverName }) else { return fail("No MCP server named \(serverName).") }
            configs[index].isEnabled = flag == "true"
            host.controlSaveMCPConfigs(configs)
            return ok("\(serverName) is now \(flag == "true" ? "enabled" : "disabled"); applies from the next run.")

        default:
            return fail("Unknown ORB function: \(name)")
        }
    }

    // MARK: Helpers

    private static func line(_ conversation: ChatConversation) -> String {
        "\(conversation.id.uuidString.prefix(8)) | \(conversation.mode.rawValue) | \(clip(conversation.title, 60)) | \(conversation.modelId) | \(conversation.messages.count) msgs | \(conversation.totalTokens.formatted()) tok | $\(String(format: "%.4f", conversation.totalCost))"
    }

    private static func clip(_ text: String, _ limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit)) + "… [\(text.count - limit) more characters]" : text
    }

    private static func snippet(_ text: String, around lowerQuery: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        guard let range = flat.lowercased().range(of: lowerQuery) else { return clip(flat, 160) }
        let start = flat.index(range.lowerBound, offsetBy: -60, limitedBy: flat.startIndex) ?? flat.startIndex
        let end = flat.index(range.upperBound, offsetBy: 60, limitedBy: flat.endIndex) ?? flat.endIndex
        return String(flat[start..<end])
    }

    private static func describe(_ kind: SettingKind) -> String {
        switch kind {
        case .bool: return "true/false"
        case .string: return "text"
        case .number(let range): return "number \(range.lowerBound)–\(range.upperBound)"
        case .oneOf(let options): return options.map { $0.isEmpty ? "\"\"" : $0 }.joined(separator: " | ")
        }
    }

    static func coerce(_ raw: String, _ kind: SettingKind) -> Result<Any, ORBControlError> {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .bool:
            switch text.lowercased() {
            case "true", "yes", "on", "1": return .success(true)
            case "false", "no", "off", "0": return .success(false)
            default: return .failure(.init(message: "Expected true or false."))
            }
        case .number(let range):
            guard let value = Double(text), range.contains(value) else {
                return .failure(.init(message: "Expected a number from \(range.lowerBound) to \(range.upperBound)."))
            }
            return .success(value)
        case .oneOf(let options):
            guard options.contains(text.lowercased()) else {
                return .failure(.init(message: "Expected one of: \(options.map { $0.isEmpty ? "\"\"" : $0 }.joined(separator: ", "))."))
            }
            return .success(text.lowercased())
        case .string:
            return .success(text)
        }
    }
}

struct ORBControlError: Error { let message: String }

/// Session lookup outcome (a tool result is not an Error, so no Result<>).
enum ORBResolution {
    case success(ChatConversation)
    case failure(NativeAgentToolResult)
}

// MARK: - ChatService conformance

extension ChatService: ORBControlHost {
    var controlConversations: [ChatConversation] { conversations }
    var controlRunningConversationID: UUID? { runState.isActive ? runState.context?.conversationID : nil }
    var controlDefaults: UserDefaults { .standard }

    func controlRename(_ id: UUID, to title: String) -> Bool { renameConversation(id, to: title) }

    func controlSetSystemPrompt(_ prompt: String, for id: UUID) -> Bool {
        guard let conversation = conversations.first(where: { $0.id == id }) else { return false }
        updateSystemPrompt(prompt, for: conversation)
        flushPendingEdits()
        return true
    }

    func controlDelete(_ id: UUID) -> Bool {
        guard let conversation = conversations.first(where: { $0.id == id }) else { return false }
        deleteConversation(conversation)
        return !conversations.contains { $0.id == id }
    }

    func controlMCPConfigs() -> [MCPServerConfig] { mcpServerProvider() }
    func controlSaveMCPConfigs(_ configs: [MCPServerConfig]) { MCPRegistry.saveConfigs(configs) }
}
