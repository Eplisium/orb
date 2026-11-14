import Foundation

// MARK: - Deny-by-default agent tool policy
//
// One policy gates BOTH advertised definitions and execution. Before this
// existed, the native list was filtered by a computer-access toggle but every
// connected MCP server's tools were appended and callable regardless — a Web
// Only session could still launch a filesystem MCP tool.

/// Capabilities a session may grant. Nothing is implied: a tool is usable only
/// when the capability it requires is explicitly granted, and unknown tools are
/// always denied.
enum ToolCapability: String, Codable, Sendable, CaseIterable {
    /// Network reads only (fetch_url, web_search).
    case web
    /// ORB file tools reading inside the workspace boundary.
    case workspaceRead
    /// ORB file tools writing inside the workspace boundary (implies read).
    case workspaceWrite
    /// Shell execution. A working directory is NOT a sandbox and must never be
    /// described as one; approval is expected per call.
    case approvedTerminal
    /// AppleScript, app launching, URL opening, screen capture, mouse/keyboard.
    case computerControl
    /// ORB-owned memory storage.
    case memory
    /// Task planning.
    case planning
    /// Image generation / speech synthesis (spends credits).
    case mediaGeneration
    /// Every MCP-namespaced tool, further gated by per-server approval.
    case mcp
    /// Inspect and manage ORB itself (sessions, usage, settings, MCP toggles).
    /// Granted only by OP Mode; never part of Computer Access.
    case orbControl
}

/// The single authorization point for the native agent's toolbox.
struct ToolPolicy: Sendable, Equatable {
    let capabilities: Set<ToolCapability>
    /// MCP servers (by collision-free key, as it appears in qualified tool names)
    /// explicitly approved for this session.
    var approvedMCPServers: Set<String>
    /// Workspace-constrained modes resolve every file path through
    /// `WorkspacePathGuard` before any file tool touches it. This boundary
    /// applies to ORB's own file tools only.
    let constrainsFilesystem: Bool

    init(
        capabilities: Set<ToolCapability>,
        approvedMCPServers: Set<String> = [],
        constrainsFilesystem: Bool = false
    ) {
        self.capabilities = capabilities
        self.approvedMCPServers = approvedMCPServers
        self.constrainsFilesystem = constrainsFilesystem
    }

    /// Network only. No local filesystem, no terminal, no computer control,
    /// and no MCP tool of any kind.
    static let webOnly = ToolPolicy(capabilities: [.web, .memory, .planning], constrainsFilesystem: false)

    static let workspaceRead = ToolPolicy(
        capabilities: [.web, .memory, .planning, .workspaceRead], constrainsFilesystem: true
    )

    static let workspaceWrite = ToolPolicy(
        capabilities: [.web, .memory, .planning, .workspaceRead, .workspaceWrite], constrainsFilesystem: true
    )

    static let approvedTerminal = ToolPolicy(
        capabilities: [.web, .memory, .planning, .workspaceRead, .workspaceWrite, .approvedTerminal],
        constrainsFilesystem: true
    )

    /// Everything ORB can do locally; MCP tools still require per-server approval.
    static let computerControl = ToolPolicy(
        capabilities: Set(ToolCapability.allCases).subtracting([.orbControl]), constrainsFilesystem: false
    )

    /// Compatibility mapping for the pre-policy two-level UI switch.
    static func legacy(fullComputerAccess: Bool) -> ToolPolicy {
        fullComputerAccess ? .computerControl : .webOnly
    }

    /// The policy for an interactive Agent run. Enabling an MCP server in
    /// Settings is the per-server approval; every MCP call still prompts
    /// unless the user approves it for the run. Web Only never gains MCP
    /// (it lacks the `.mcp` capability), so the list is ignored there.
    static func agentSession(fullComputerAccess: Bool, mcpServers: [MCPServerConfig], opMode: Bool = false) -> ToolPolicy {
        var policy = legacy(fullComputerAccess: fullComputerAccess)
        // OP Mode adds ORB self-control. It works even in Web Only: it never
        // touches the Mac, only ORB's own data and settings.
        if opMode { policy = policy.adding(.orbControl) }
        guard policy.capabilities.contains(.mcp) else { return policy }
        policy.approvedMCPServers = Set(
            mcpServers.filter(\.isEnabled).map { MCPToolNaming.serverKey($0.name) }
        )
        return policy
    }

    /// Preset for autonomous experiments: build and verify projects in the
    /// workspace with a terminal, without computer control or MCP. Replaces the
    /// previous hardcoded full-access shortcut in the test-suite runner.
    static let projectBuild = ToolPolicy(
        capabilities: [.web, .memory, .planning, .workspaceRead, .workspaceWrite, .approvedTerminal],
        constrainsFilesystem: true
    )

    func adding(_ capability: ToolCapability) -> ToolPolicy {
        var copy = ToolPolicy(
            capabilities: capabilities.union([capability]),
            approvedMCPServers: approvedMCPServers,
            constrainsFilesystem: constrainsFilesystem
        )
        copy.approvedMCPServers = approvedMCPServers
        return copy
    }

    func allowsDefinition(name: String) -> Bool {
        allowsExecution(name: name)
    }

    /// Fail closed: unknown names, ungranted capabilities, and unapproved MCP
    /// servers are all denied. A Web Only session therefore neither exposes nor
    /// can execute any MCP tool, including the server-qualified resource/prompt bridges.
    func allowsExecution(name: String) -> Bool {
        if MCPRegistry.isMCPTool(name) {
            guard capabilities.contains(.mcp) else { return false }
            guard let server = MCPToolNaming.resolve(name)?.server else { return false }
            return approvedMCPServers.contains(server)
        }
        guard let capability = Self.requiredCapability(for: name) else { return false }
        return capabilities.contains(capability)
    }

    /// Tools that still need an explicit per-call approval even when the
    /// capability is granted: anything that leaves ORB's own boundary.
    func requiresApproval(name: String) -> Bool {
        let capability: ToolCapability?
        if MCPRegistry.isMCPTool(name) {
            capability = .mcp
        } else {
            capability = Self.requiredCapability(for: name)
        }
        switch capability {
        case .approvedTerminal, .computerControl, .mcp: return true
        default: return false
        }
    }

    /// Argument-aware approval decision for one concrete call. Nil = runs
    /// without asking. This is the single place that decides; the runner asks
    /// it immediately before execution (after `allowsExecution`).
    ///
    /// Beyond the always-ask tools (`requiresApproval(name:)`):
    /// - a file tool that WRITES outside the workspace, or into a location
    ///   that runs code or holds credentials (shell rc files, LaunchAgents,
    ///   `.git`, `~/Library`, system folders), asks with the full path;
    /// - a file tool that READS a credential store (`~/.ssh`, `~/.aws`,
    ///   Keychains, ORB's own data, browser profiles, `.env` files) asks
    ///   with the full path, so a prompt-injected page cannot silently read a
    ///   key and hand it to `fetch_url`.
    func approvalRequirement(name: String, argumentsJSON: String, workspace: String) -> ToolApprovalRequirement? {
        let arguments = JSONValue.parse(argumentsJSON)?.objectValue ?? [:]
        func string(_ key: String) -> String? {
            guard let value = arguments[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else { return nil }
            return value
        }
        let alwaysAsk = requiresApproval(name: name)

        if MCPRegistry.isMCPTool(name) {
            let server = MCPToolNaming.resolve(name)?.server ?? ""
            return .init(reason: nil, resolvedPath: nil, scopeKey: "\(server)|\(name)",
                         scopeLabel: "every call to \(name)")
        }

        switch name {
        case "run_command":
            let directory = string("working_directory").map {
                SensitivePaths.resolve($0, workspace: workspace).path
            } ?? SensitivePaths.resolve(workspace, workspace: workspace).path
            return .init(reason: nil, resolvedPath: directory, scopeKey: "run_command|\(directory)",
                         scopeLabel: "every command in \(SensitivePaths.abbreviated(directory))")
        case "computer_action":
            let action = string("action")?.lowercased() ?? "action"
            return .init(reason: nil, resolvedPath: nil, scopeKey: "computer_action|\(action)",
                         scopeLabel: "every computer_action \"\(action)\"")
        default:
            break
        }

        // File tools: decide from the resolved path.
        if let access = Self.fileAccess(for: name) {
            let raw: String? = string("path") ?? (name == "capture_screen" ? nil : "")
            guard let raw else {
                return alwaysAsk ? .init(reason: nil, resolvedPath: nil, scopeKey: "|\(name)",
                                         scopeLabel: "every \(name) call") : nil
            }
            let resolved = SensitivePaths.resolve(raw.isEmpty ? "." : raw, workspace: workspace)
            let path = resolved.path
            let shortPath = SensitivePaths.abbreviated(path)
            let inside = SensitivePaths.isInside(resolved, workspace: workspace)
            // A workspace the user (or ORB itself, for Test Suite projects)
            // deliberately placed in a sensitive area does not make every
            // file inside it ask; anything else sensitive always does.
            let deliberate = inside && SensitivePaths.isSensitiveWrite(SensitivePaths.resolve(workspace, workspace: workspace))
            var reason: String?
            switch access {
            case .read:
                if !deliberate, SensitivePaths.isSensitiveRead(resolved) {
                    reason = "Reads a location that may hold credentials or private data: \(path)"
                }
            case .write:
                if !deliberate, SensitivePaths.isSensitiveWrite(resolved) {
                    reason = "Writes to a location that can run code or holds credentials: \(path)"
                } else if !constrainsFilesystem, !inside {
                    reason = "Writes outside the workspace: \(path)"
                }
            }
            guard alwaysAsk || reason != nil else { return nil }
            // Sensitive or outside-workspace access is remembered per path, so
            // "Allow for this run" never widens to other files.
            let scopeKey = reason == nil ? "|\(name)" : "\(name)|\(path)"
            let scopeLabel = reason == nil ? "every \(name) call" : "\(name) on \(shortPath)"
            return .init(reason: reason, resolvedPath: path, scopeKey: scopeKey, scopeLabel: scopeLabel)
        }

        guard alwaysAsk else { return nil }
        return .init(reason: nil, resolvedPath: nil, scopeKey: "|\(name)", scopeLabel: "every \(name) call")
    }

    enum FileAccess { case read, write }

    /// Native tools that take a model-chosen filesystem `path`.
    static func fileAccess(for name: String) -> FileAccess? {
        switch name {
        case "read_file", "list_directory", "search_files", "view_image": return .read
        case "write_file", "speak_text", "generate_image", "capture_screen": return .write
        default: return nil
        }
    }

    static func requiredCapability(for name: String) -> ToolCapability? {
        switch name {
        case "fetch_url", "web_search": return .web
        case "read_file", "list_directory", "search_files": return .workspaceRead
        case "write_file": return .workspaceWrite
        case "run_command": return .approvedTerminal
        case "run_applescript", "open_application", "open_url", "capture_screen", "computer_action", "view_image":
            return .computerControl
        case "remember", "recall": return .memory
        case "plan_tasks": return .planning
        case "generate_image", "speak_text": return .mediaGeneration
        case _ where ORBControlTools.isORBTool(name): return .orbControl
        default: return nil
        }
    }
}

/// Why one concrete call needs the user's approval, and how far an
/// "Allow for this run" answer may reach.
struct ToolApprovalRequirement: Sendable, Equatable {
    /// Extra, plain-language reason (sensitive or outside-workspace path).
    /// Nil for tools that always ask.
    let reason: String?
    /// The absolute path the call will touch (file tools) or run in
    /// (`run_command`), after `~`, `..` and symlink resolution.
    let resolvedPath: String?
    /// Key under which a session approval is remembered.
    let scopeKey: String
    /// What a session approval covers, e.g. "every command in ~/Project".
    let scopeLabel: String
}

/// Locations the agent must not touch silently, even with Computer Access.
enum SensitivePaths {
    /// Resolves a model path the way the file tools do (tilde, workspace-
    /// relative, `..`), then follows symlinks through the deepest existing
    /// ancestor so a link inside the workspace cannot hide its target.
    static func resolve(_ rawPath: String, workspace: String) -> URL {
        let expanded = NSString(string: rawPath).expandingTildeInPath
        let url: URL
        if expanded.hasPrefix("/") {
            url = URL(fileURLWithPath: expanded).standardizedFileURL
        } else {
            let base = NSString(string: workspace).expandingTildeInPath
            url = URL(fileURLWithPath: base, isDirectory: true).appendingPathComponent(expanded).standardizedFileURL
        }
        return WorkspacePathGuard.resolvingExistingAncestors(of: url)
    }

    static func isInside(_ url: URL, workspace: String) -> Bool {
        let base = resolve(workspace, workspace: workspace).path.lowercased()
        let path = url.path.lowercased()
        return path == base || path.hasPrefix(base.hasSuffix("/") ? base : base + "/")
    }

    static func abbreviated(_ path: String) -> String {
        let home = homePath
        if path == home { return "~" }
        if path.lowercased().hasPrefix(home.lowercased() + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    private static var homePath: String {
        URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().path
    }

    /// Paths relative to home, compared case-insensitively (APFS default).
    static let homeReadPrefixes: [String] = [
        ".ssh", ".aws", ".gnupg", ".netrc", ".git-credentials", ".docker", ".kube", ".azure",
        ".config/gh", ".config/gcloud", ".npmrc", ".pypirc", ".gem/credentials", ".password-store",
        "Library/Keychains", "Library/Application Support/ORB", "Library/Cookies", "Library/Safari",
        "Library/Messages", "Library/Mail", "Library/Containers/com.apple.Safari",
        "Library/Application Support/Google/Chrome", "Library/Application Support/BraveSoftware",
        "Library/Application Support/Firefox", "Library/Application Support/Microsoft Edge",
        "Library/Application Support/Arc", "Library/Application Support/com.apple.TCC",
    ]

    static let systemReadPrefixes = ["/Library/Keychains", "/private/var/db", "/private/etc/master.passwd"]

    /// System folders. `/private/var` (temp folders) is deliberately absent:
    /// writes there are judged by the workspace rule instead.
    static let systemWritePrefixes = [
        "/System", "/Library", "/Applications", "/usr", "/bin", "/sbin", "/etc", "/private/etc", "/opt",
    ]

    private static func relativeToHome(_ url: URL) -> String? {
        let home = homePath.lowercased()
        let path = url.path.lowercased()
        guard path.hasPrefix(home + "/") else { return nil }
        return String(url.path.dropFirst(homePath.count + 1))
    }

    private static func matches(_ path: String, prefix: String) -> Bool {
        let path = path.lowercased(), prefix = prefix.lowercased()
        return path == prefix || path.hasPrefix(prefix + "/")
    }

    /// Credential stores and private app data.
    static func isSensitiveRead(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        if name == ".env" || (name.hasPrefix(".env.")
            && ![".env.example", ".env.sample", ".env.template"].contains(name)) { return true }
        if ["id_rsa", "id_dsa", "id_ecdsa", "id_ed25519"].contains(where: { name.hasPrefix($0) }) { return true }
        if [".p12", ".pfx", ".keychain", ".keychain-db"].contains(where: { name.hasSuffix($0) }) { return true }
        if systemReadPrefixes.contains(where: { matches(url.path, prefix: $0) }) { return true }
        guard let relative = relativeToHome(url) else { return false }
        return homeReadPrefixes.contains { matches(relative, prefix: $0) }
    }

    /// Places where a written file can run code later (shell startup files,
    /// LaunchAgents, git hooks/config) or alter credentials and app data.
    static func isSensitiveWrite(_ url: URL) -> Bool {
        if isSensitiveRead(url) { return true }
        let components = url.pathComponents.map { $0.lowercased() }
        if components.contains(".git") { return true }
        if let relative = relativeToHome(url) {
            // Any dotfile or dot-folder directly in home (~/.zshrc, ~/.config…).
            if relative.hasPrefix(".") { return true }
            if matches(relative, prefix: "Library") { return true }
            return false
        }
        if url.path == homePath { return false }
        return systemWritePrefixes.contains { matches(url.path, prefix: $0) }
    }
}

enum ToolPolicyError: Error, LocalizedError, Equatable {
    case pathOutsideWorkspace(path: String, workspace: String)

    var errorDescription: String? {
        switch self {
        case .pathOutsideWorkspace(let path, let workspace):
            return "Access denied: \"\(path)\" is outside this session's workspace (\(workspace))."
        }
    }
}

/// Resolves model-supplied paths for workspace-constrained modes. Tilde
/// expansion, `..` traversal, and symlink resolution are all checked against
/// the real filesystem before any file tool touches the path. This confines
/// ORB's file tools; it is not, and must never be presented as, shell sandboxing.
enum WorkspacePathGuard {
    static func containedURL(forRawPath rawPath: String, workspace: String) throws -> URL {
        let expanded = NSString(string: rawPath).expandingTildeInPath
        let url: URL
        if expanded.hasPrefix("/") {
            url = URL(fileURLWithPath: expanded).standardizedFileURL
        } else {
            url = URL(fileURLWithPath: workspace, isDirectory: true)
                .appendingPathComponent(expanded)
                .standardizedFileURL
        }
        let base = URL(fileURLWithPath: workspace, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        // Foundation only fully resolves symlinks when the final component
        // exists, so walk up to the deepest existing ancestor (typically the
        // symlinked directory itself), resolve it, and re-append the rest.
        let candidate = resolvingExistingAncestors(of: url).path
        guard candidate == base || candidate.hasPrefix(base + "/") else {
            throw ToolPolicyError.pathOutsideWorkspace(path: rawPath, workspace: base)
        }
        return url
    }

    static func resolvingExistingAncestors(of url: URL) -> URL {
        var check = url
        var missing: [String] = []
        while !FileManager.default.fileExists(atPath: check.path) {
            missing.insert(check.lastPathComponent, at: 0)
            let parent = check.deletingLastPathComponent()
            guard parent.path != check.path else { break }
            check = parent
        }
        return missing.reduce(check.resolvingSymlinksInPath()) {
            $0.appendingPathComponent($1)
        }
    }
}
