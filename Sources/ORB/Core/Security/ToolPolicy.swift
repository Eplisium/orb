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
}

/// The single authorization point for the native agent's toolbox.
struct ToolPolicy: Sendable, Equatable {
    let capabilities: Set<ToolCapability>
    /// MCP servers (by sanitized slug, as it appears in qualified tool names)
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
    static let computerControl = ToolPolicy(capabilities: Set(ToolCapability.allCases), constrainsFilesystem: false)

    /// Compatibility mapping for the pre-policy two-level UI switch.
    static func legacy(fullComputerAccess: Bool) -> ToolPolicy {
        fullComputerAccess ? .computerControl : .webOnly
    }

    /// The policy for an interactive Agent run. Enabling an MCP server in
    /// Settings is the per-server approval; every MCP call still prompts
    /// unless the user approves it for the run. Web Only never gains MCP
    /// (it lacks the `.mcp` capability), so the list is ignored there.
    static func agentSession(fullComputerAccess: Bool, mcpServers: [MCPServerConfig]) -> ToolPolicy {
        var policy = legacy(fullComputerAccess: fullComputerAccess)
        guard policy.capabilities.contains(.mcp) else { return policy }
        policy.approvedMCPServers = Set(
            mcpServers.filter(\.isEnabled).map { MCPToolNaming.sanitize($0.name) }
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

    func allowsDefinition(name: String) -> Bool {
        allowsExecution(name: name)
    }

    /// Fail closed: unknown names, ungranted capabilities, and unapproved MCP
    /// servers are all denied. A Web Only session therefore neither exposes nor
    /// can execute any MCP tool, including the synthetic resource/prompt bridges.
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
        default: return nil
        }
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

    private static func resolvingExistingAncestors(of url: URL) -> URL {
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
