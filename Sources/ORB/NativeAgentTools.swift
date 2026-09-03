import Darwin
import Foundation

/// Native functions owned and executed by ORB.
/// Full-access tools intentionally run with the current user's permissions.
enum NativeAgentTools {
    typealias ProcessSignalSender = @Sendable (pid_t, Int32) -> Int32

    static func definitions(fullComputerAccess: Bool) -> [AgentToolDefinition] {
        var tools = [definition(
            name: "fetch_url",
            description: "Fetch the text content of an HTTP or HTTPS URL.",
            properties: [
                "url": .init(type: "string", description: "The absolute HTTP or HTTPS URL to fetch."),
            ],
            required: ["url"]
        )]
        guard fullComputerAccess else { return tools }

        tools += [
            definition(
                name: "read_file",
                description: "Read a UTF-8 text file from the Mac. Paths may be absolute or relative to the workspace.",
                properties: [
                    "path": .init(type: "string", description: "File path."),
                    "offset": .init(type: "integer", description: "Optional one-based starting line."),
                    "limit": .init(type: "integer", description: "Optional maximum number of lines, up to 2000."),
                ],
                required: ["path"]
            ),
            definition(
                name: "list_directory",
                description: "List files and folders in a directory on the Mac.",
                properties: [
                    "path": .init(type: "string", description: "Directory path, absolute or relative to the workspace."),
                ],
                required: ["path"]
            ),
            definition(
                name: "search_files",
                description: "Recursively search text files for a case-insensitive query.",
                properties: [
                    "path": .init(type: "string", description: "Directory to search."),
                    "query": .init(type: "string", description: "Text to find."),
                ],
                required: ["path", "query"]
            ),
            definition(
                name: "write_file",
                description: "Create or completely overwrite a UTF-8 text file. Creates parent directories.",
                properties: [
                    "path": .init(type: "string", description: "Destination file path."),
                    "content": .init(type: "string", description: "Complete file contents."),
                ],
                required: ["path", "content"]
            ),
            definition(
                name: "run_command",
                description: "Run a zsh command on the Mac and return stdout, stderr, and exit status. Use for builds, scripts, and system operations.",
                properties: [
                    "command": .init(type: "string", description: "Shell command to run."),
                    "working_directory": .init(type: "string", description: "Optional working directory; defaults to the selected workspace."),
                ],
                required: ["command"]
            ),
            definition(
                name: "run_applescript",
                description: "Run AppleScript for native macOS application automation. System Events actions require Accessibility permission.",
                properties: [
                    "script": .init(type: "string", description: "AppleScript source to execute."),
                ],
                required: ["script"]
            ),
            definition(
                name: "open_application",
                description: "Launch or activate a macOS application by name.",
                properties: [
                    "name": .init(type: "string", description: "Application name, such as Safari or Notes."),
                ],
                required: ["name"]
            ),
            definition(
                name: "open_url",
                description: "Open a URL using its default macOS application.",
                properties: [
                    "url": .init(type: "string", description: "URL to open."),
                ],
                required: ["url"]
            ),
            definition(
                name: "capture_screen",
                description: "Capture the current macOS screen to a PNG file and return its path. Use before coordinate-based computer actions.",
                properties: [
                    "path": .init(type: "string", description: "Optional destination PNG path."),
                ]
            ),
            definition(
                name: "computer_action",
                description: "Control the Mac with a trusted mouse click, text entry, or keyboard key. Capture the screen before coordinate clicks. Requires macOS Accessibility permission.",
                properties: [
                    "action": .init(type: "string", description: "One of: click, type, key."),
                    "x": .init(type: "number", description: "Screen x coordinate for click."),
                    "y": .init(type: "number", description: "Screen y coordinate for click."),
                    "text": .init(type: "string", description: "Text for the type action, or key name for key: return, tab, escape, space, delete, left, right, up, down."),
                ],
                required: ["action"]
            ),
        ]
        return tools
    }

    static func execute(
        name: String,
        argumentsJSON: String,
        workspace: String,
        fullComputerAccess: Bool
    ) async throws -> NativeAgentToolResult {
        if name != "fetch_url", !fullComputerAccess {
            return .init(content: "Computer Access is off. Enable it before using \(name).", isError: true)
        }

        guard let data = argumentsJSON.data(using: .utf8),
              let arguments = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .init(content: "Invalid JSON arguments for \(name).", isError: true)
        }

        do {
            switch name {
            case "fetch_url":
                return try await fetchURL(arguments)
            case "read_file":
                return try readFile(arguments, workspace: workspace)
            case "list_directory":
                return try listDirectory(arguments, workspace: workspace)
            case "search_files":
                return try searchFiles(arguments, workspace: workspace)
            case "write_file":
                return try writeFile(arguments, workspace: workspace)
            case "run_command":
                return try await runCommand(arguments, workspace: workspace)
            case "run_applescript":
                return try await runAppleScript(arguments)
            case "open_application":
                return try await openApplication(arguments)
            case "open_url":
                return try await openURL(arguments)
            case "capture_screen":
                return try await captureScreen(arguments, workspace: workspace)
            case "computer_action":
                return try await computerAction(arguments)
            default:
                return .init(content: "Unknown native function: \(name)", isError: true)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .init(content: "\(name) failed: \(error.localizedDescription)", isError: true)
        }
    }

    private static func definition(
        name: String,
        description: String,
        properties: [String: AgentToolProperty],
        required: [String] = []
    ) -> AgentToolDefinition {
        AgentToolDefinition(function: .init(
            name: name,
            description: description,
            parameters: .native(AgentToolParameters(properties: properties, required: required))
        ))
    }

    private static func resolvedPath(_ rawPath: String, workspace: String) -> URL {
        let expanded = NSString(string: rawPath).expandingTildeInPath
        if expanded.hasPrefix("/") { return URL(fileURLWithPath: expanded).standardizedFileURL }
        return URL(fileURLWithPath: workspace, isDirectory: true)
            .appendingPathComponent(expanded)
            .standardizedFileURL
    }

    private static func readFile(
        _ arguments: [String: Any],
        workspace: String
    ) throws -> NativeAgentToolResult {
        guard let rawPath = arguments["path"] as? String else {
            throw ToolError.missing("path")
        }
        let url = resolvedPath(rawPath, workspace: workspace)
        let text = try String(contentsOf: url, encoding: .utf8)
        let lines = text.components(separatedBy: .newlines)
        let offset = max((arguments["offset"] as? Int ?? 1) - 1, 0)
        let limit = min(max(arguments["limit"] as? Int ?? 400, 1), 2000)
        guard offset < lines.count else {
            return .init(content: "File has \(lines.count) lines; offset is past the end.", isError: false)
        }
        let end = min(offset + limit, lines.count)
        let numbered = lines[offset..<end].enumerated().map {
            "\(offset + $0.offset + 1)|\($0.element)"
        }.joined(separator: "\n")
        return .init(
            content: "path: \(url.path)\nlines: \(lines.count)\n\(numbered)",
            isError: false
        )
    }

    private static func listDirectory(
        _ arguments: [String: Any],
        workspace: String
    ) throws -> NativeAgentToolResult {
        guard let rawPath = arguments["path"] as? String else {
            throw ToolError.missing("path")
        }
        let url = resolvedPath(rawPath, workspace: workspace)
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey]
        let entries = try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ).sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
        let output = try entries.prefix(500).map { entry -> String in
            let values = try entry.resourceValues(forKeys: keys)
            return values.isDirectory == true
                ? "[dir]  \(entry.lastPathComponent)/"
                : "[file] \(entry.lastPathComponent)  \(values.fileSize ?? 0) bytes"
        }.joined(separator: "\n")
        return .init(content: "path: \(url.path)\n\(output)", isError: false)
    }

    private static func searchFiles(
        _ arguments: [String: Any],
        workspace: String
    ) throws -> NativeAgentToolResult {
        guard let rawPath = arguments["path"] as? String else { throw ToolError.missing("path") }
        guard let query = arguments["query"] as? String, !query.isEmpty else { throw ToolError.missing("query") }
        let root = resolvedPath(rawPath, workspace: workspace)
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw ToolError.message("Could not enumerate \(root.path)")
        }
        var matches: [String] = []
        var visited = 0
        var unreadable = 0
        var skippedTooLarge = 0
        var hitVisitLimit = false
        var hitMatchLimit = false
        for case let file as URL in enumerator {
            visited += 1
            if visited > 5_000 { hitVisitLimit = true; break }
            if matches.count >= 100 { hitMatchLimit = true; break }
            let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true else { continue }
            if (values?.fileSize ?? 0) > 2_000_000 { skippedTooLarge += 1; continue }
            guard let text = try? String(contentsOf: file, encoding: .utf8) else {
                unreadable += 1
                continue
            }
            for (index, line) in text.components(separatedBy: .newlines).enumerated() where line.localizedCaseInsensitiveContains(query) {
                matches.append("\(file.path):\(index + 1): \(line.prefix(300))")
                if matches.count >= 100 { hitMatchLimit = true; break }
            }
        }
        var notes: [String] = []
        if unreadable > 0 { notes.append("\(unreadable) file(s) could not be read as UTF-8 text") }
        if skippedTooLarge > 0 { notes.append("\(skippedTooLarge) file(s) skipped for exceeding the 2 MB size limit") }
        if hitVisitLimit { notes.append("stopped after scanning 5,000 files") }
        if hitMatchLimit { notes.append("stopped at 100 matches — refine the query or path to see more") }
        var content = matches.isEmpty ? "No matches found." : matches.joined(separator: "\n")
        if !notes.isEmpty {
            content += "\n\n[Search notes] " + notes.joined(separator: "; ") + "."
        }
        return .init(content: content, isError: false)
    }

    private static func writeFile(
        _ arguments: [String: Any],
        workspace: String
    ) throws -> NativeAgentToolResult {
        guard let rawPath = arguments["path"] as? String else { throw ToolError.missing("path") }
        guard let content = arguments["content"] as? String else { throw ToolError.missing("content") }
        let url = resolvedPath(rawPath, workspace: workspace)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return .init(content: "Wrote \(content.utf8.count) bytes to \(url.path)", isError: false)
    }

    private static func runCommand(
        _ arguments: [String: Any],
        workspace: String
    ) async throws -> NativeAgentToolResult {
        guard let command = arguments["command"] as? String, !command.isEmpty else {
            throw ToolError.missing("command")
        }
        let workingDirectory: String
        if let raw = arguments["working_directory"] as? String {
            workingDirectory = resolvedPath(raw, workspace: workspace).path
        } else {
            workingDirectory = workspace
        }
        let result = try await runProcess(
            executable: "/bin/zsh",
            arguments: ["-lc", command],
            workingDirectory: workingDirectory
        )
        let stdout = bounded(result.stdout)
        let stderr = bounded(result.stderr)
        return .init(
            content: "exit_code: \(result.exitCode)\nstdout:\n\(stdout)\nstderr:\n\(stderr)",
            isError: result.exitCode != 0
        )
    }

    private static func bounded(_ value: String, byteLimit: Int = 60_000) -> String {
        let data = Data(value.utf8)
        guard data.count > byteLimit else { return value }
        return String(decoding: data.prefix(byteLimit), as: UTF8.self)
            + "\n… output truncated (\(data.count - byteLimit) bytes omitted) …"
    }

    private static func runAppleScript(_ arguments: [String: Any]) async throws -> NativeAgentToolResult {
        guard let script = arguments["script"] as? String, !script.isEmpty else {
            throw ToolError.missing("script")
        }
        let result = try await runProcess(executable: "/usr/bin/osascript", arguments: ["-e", script])
        return .init(content: result.stdout.isEmpty ? result.stderr : result.stdout, isError: result.exitCode != 0)
    }

    private static func openApplication(_ arguments: [String: Any]) async throws -> NativeAgentToolResult {
        guard let name = arguments["name"] as? String, !name.isEmpty else { throw ToolError.missing("name") }
        let result = try await runProcess(executable: "/usr/bin/open", arguments: ["-a", name])
        return .init(content: result.exitCode == 0 ? "Opened \(name)." : result.stderr, isError: result.exitCode != 0)
    }

    private static func openURL(_ arguments: [String: Any]) async throws -> NativeAgentToolResult {
        guard let value = arguments["url"] as? String, URL(string: value) != nil else { throw ToolError.missing("url") }
        let result = try await runProcess(executable: "/usr/bin/open", arguments: [value])
        return .init(content: result.exitCode == 0 ? "Opened \(value)." : result.stderr, isError: result.exitCode != 0)
    }

    private static func captureScreen(
        _ arguments: [String: Any],
        workspace: String
    ) async throws -> NativeAgentToolResult {
        let defaultPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("ORB-\(UUID().uuidString).png").path
        let rawPath = arguments["path"] as? String ?? defaultPath
        let path = resolvedPath(rawPath, workspace: workspace).path
        let result = try await runProcess(executable: "/usr/sbin/screencapture", arguments: ["-x", path])
        return .init(content: result.exitCode == 0 ? "Screenshot saved to \(path)" : result.stderr, isError: result.exitCode != 0)
    }

    private static func computerAction(_ arguments: [String: Any]) async throws -> NativeAgentToolResult {
        guard let action = arguments["action"] as? String else { throw ToolError.missing("action") }
        let script: String
        switch action.lowercased() {
        case "click":
            guard let x = number(arguments["x"]), let y = number(arguments["y"]) else {
                throw ToolError.message("click requires numeric x and y coordinates")
            }
            script = "tell application \"System Events\" to click at {\(Int(x)), \(Int(y))}"
        case "type":
            guard let text = arguments["text"] as? String else { throw ToolError.missing("text") }
            script = "tell application \"System Events\" to keystroke \"\(appleScriptEscaped(text))\""
        case "key":
            guard let key = (arguments["text"] as? String)?.lowercased() else { throw ToolError.missing("text") }
            let keyCodes = [
                "return": 36, "enter": 36, "tab": 48, "space": 49,
                "delete": 51, "escape": 53, "left": 123, "right": 124,
                "down": 125, "up": 126,
            ]
            guard let code = keyCodes[key] else {
                throw ToolError.message("Unsupported key. Use return, tab, escape, space, delete, left, right, up, or down.")
            }
            script = "tell application \"System Events\" to key code \(code)"
        default:
            throw ToolError.message("Unsupported computer action: \(action)")
        }
        let result = try await runProcess(executable: "/usr/bin/osascript", arguments: ["-e", script])
        return .init(
            content: result.exitCode == 0 ? "Completed computer action: \(action)" : result.stderr,
            isError: result.exitCode != 0
        )
    }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? NSNumber { return value.doubleValue }
        return nil
    }

    private static func appleScriptEscaped(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    private static func fetchURL(_ arguments: [String: Any]) async throws -> NativeAgentToolResult {
        guard let value = arguments["url"] as? String,
              let url = URL(string: value),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            throw ToolError.message("A valid HTTP or HTTPS url is required.")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = NetworkTimeouts.fetch
        request.setValue("ORB/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let capped = data.prefix(120_000)
        let text = String(data: capped, encoding: .utf8) ?? "<binary response: \(data.count) bytes>"
        return .init(content: "HTTP \(status)\n\(text)", isError: !(200..<400).contains(status))
    }

    private struct ProcessResult: Sendable {
        let stdout: String
        let stderr: String
        let exitCode: Int32
    }

    private final class ProcessBox: @unchecked Sendable {
        private let lock = NSLock()
        private let sendSignal: ProcessSignalSender
        private var pid: pid_t?
        private var cancelled = false
        private var forceKillDeadline: ContinuousClock.Instant?

        init(sendSignal: @escaping ProcessSignalSender = { Darwin.kill($0, $1) }) {
            self.sendSignal = sendSignal
        }

        func store(_ pid: pid_t) {
            lock.lock()
            self.pid = pid
            if cancelled {
                signalProcessGroup(pid, signal: SIGTERM)
                forceKillDeadline = ContinuousClock.now.advanced(by: .milliseconds(500))
            }
            lock.unlock()
        }

        func terminate() {
            lock.lock()
            cancelled = true
            if let pid {
                signalProcessGroup(pid, signal: SIGTERM)
                if forceKillDeadline == nil {
                    forceKillDeadline = ContinuousClock.now.advanced(by: .milliseconds(500))
                }
            }
            lock.unlock()
        }

        private func signalProcessGroup(_ pid: pid_t, signal: Int32) {
            guard pid > 0 else { return }
            _ = sendSignal(-pid, signal)
        }

        func waitForExit(
            _ expectedPID: pid_t,
            pipesClosed: @Sendable () -> Bool
        ) throws -> Int32 {
            while true {
                lock.lock()
                guard pid == expectedPID else {
                    lock.unlock()
                    throw POSIXError(.ECHILD)
                }

                if let deadline = forceKillDeadline {
                    let remaining = ContinuousClock.now.duration(to: deadline)
                    if remaining > .zero {
                        lock.unlock()
                        let parts = remaining.components
                        let seconds = Double(parts.seconds) + Double(parts.attoseconds) / 1e18
                        Thread.sleep(forTimeInterval: min(0.005, seconds))
                        continue
                    }
                    signalProcessGroup(expectedPID, signal: SIGKILL)
                    forceKillDeadline = nil
                }

                if cancelled {
                    var status: Int32 = 0
                    let result = Darwin.waitpid(expectedPID, &status, 0)
                    if result == expectedPID {
                        pid = nil
                        lock.unlock()
                        let signal = status & 0x7f
                        return signal == 0 ? (status >> 8) & 0xff : 128 + signal
                    }
                    let code = errno
                    pid = nil
                    lock.unlock()
                    throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
                }

                var info = siginfo_t()
                let observed = Darwin.waitid(
                    P_PID,
                    id_t(expectedPID),
                    &info,
                    WEXITED | WNOHANG | WNOWAIT
                )
                if observed == -1, errno != EINTR {
                    let code = errno
                    pid = nil
                    lock.unlock()
                    throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
                }
                guard info.si_pid == expectedPID, pipesClosed() else {
                    lock.unlock()
                    Thread.sleep(forTimeInterval: 0.005)
                    continue
                }

                var status: Int32 = 0
                let result = Darwin.waitpid(expectedPID, &status, 0)
                if result == expectedPID {
                    pid = nil
                    lock.unlock()
                    let signal = status & 0x7f
                    return signal == 0 ? (status >> 8) & 0xff : 128 + signal
                }
                let code = errno
                pid = nil
                lock.unlock()
                throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
            }
        }

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }
    }

    private final class BoundedPipeCollector: @unchecked Sendable {
        private let lock = NSLock()
        private let limit: Int
        private var data = Data()
        private var omitted = 0
        private var eof = false

        init(limit: Int = 60_000) { self.limit = limit }

        func append(_ chunk: Data) {
            lock.lock()
            guard !chunk.isEmpty else {
                eof = true
                lock.unlock()
                return
            }
            let remaining = max(0, limit - data.count)
            data.append(chunk.prefix(remaining))
            omitted += max(0, chunk.count - remaining)
            lock.unlock()
        }

        var reachedEOF: Bool {
            lock.lock()
            defer { lock.unlock() }
            return eof
        }

        var output: String {
            lock.lock()
            defer { lock.unlock() }
            let value = String(decoding: data, as: UTF8.self)
            return omitted == 0 ? value : value + "\n… output truncated (at least \(omitted) bytes omitted) …"
        }
    }

    private static func spawn(
        executable: String,
        arguments: [String],
        workingDirectory: String?,
        outputPipe: Pipe,
        errorPipe: Pipe
    ) throws -> pid_t {
        var fileActions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&fileActions) == 0,
              posix_spawnattr_init(&attributes) == 0 else {
            throw POSIXError(.ENOMEM)
        }
        defer {
            posix_spawn_file_actions_destroy(&fileActions)
            posix_spawnattr_destroy(&attributes)
        }

        let outputRead = outputPipe.fileHandleForReading.fileDescriptor
        let outputWrite = outputPipe.fileHandleForWriting.fileDescriptor
        let errorRead = errorPipe.fileHandleForReading.fileDescriptor
        let errorWrite = errorPipe.fileHandleForWriting.fileDescriptor
        posix_spawn_file_actions_addclose(&fileActions, outputRead)
        posix_spawn_file_actions_addclose(&fileActions, errorRead)
        posix_spawn_file_actions_adddup2(&fileActions, outputWrite, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, errorWrite, STDERR_FILENO)
        posix_spawn_file_actions_addclose(&fileActions, outputWrite)
        posix_spawn_file_actions_addclose(&fileActions, errorWrite)
        if let workingDirectory {
            posix_spawn_file_actions_addchdir_np(&fileActions, workingDirectory)
        }

        let flags = Int16(POSIX_SPAWN_SETPGROUP)
        guard posix_spawnattr_setflags(&attributes, flags) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0 else {
            throw POSIXError(.EINVAL)
        }

        let argumentStrings = [executable] + arguments
        var argv = argumentStrings.map { strdup($0) } + [nil]
        let environmentStrings = ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" }
        var envp = environmentStrings.map { strdup($0) } + [nil]
        defer {
            argv.compactMap { $0 }.forEach { free($0) }
            envp.compactMap { $0 }.forEach { free($0) }
        }

        var pid: pid_t = 0
        let status = argv.withUnsafeMutableBufferPointer { argvBuffer in
            envp.withUnsafeMutableBufferPointer { envBuffer in
                posix_spawn(
                    &pid,
                    executable,
                    &fileActions,
                    &attributes,
                    argvBuffer.baseAddress!,
                    envBuffer.baseAddress!
                )
            }
        }
        guard status == 0 else { throw POSIXError(POSIXErrorCode(rawValue: status) ?? .EIO) }
        return pid
    }

    private static func runProcess(
        executable: String,
        arguments: [String],
        workingDirectory: String? = nil,
        launchDelay: Duration = .zero,
        sendSignal: @escaping ProcessSignalSender = { Darwin.kill($0, $1) }
    ) async throws -> ProcessResult {
        let box = ProcessBox(sendSignal: sendSignal)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        if launchDelay != .zero {
                            Thread.sleep(forTimeInterval: Double(launchDelay.components.seconds) + Double(launchDelay.components.attoseconds) / 1e18)
                        }
                        if box.isCancelled { throw CancellationError() }
                        let outputPipe = Pipe()
                        let errorPipe = Pipe()
                        let output = BoundedPipeCollector()
                        let errors = BoundedPipeCollector()
                        outputPipe.fileHandleForReading.readabilityHandler = { output.append($0.availableData) }
                        errorPipe.fileHandleForReading.readabilityHandler = { errors.append($0.availableData) }
                        defer {
                            outputPipe.fileHandleForReading.readabilityHandler = nil
                            errorPipe.fileHandleForReading.readabilityHandler = nil
                            try? outputPipe.fileHandleForReading.close()
                            try? errorPipe.fileHandleForReading.close()
                        }
                        let pid = try spawn(
                            executable: executable,
                            arguments: arguments,
                            workingDirectory: workingDirectory,
                            outputPipe: outputPipe,
                            errorPipe: errorPipe
                        )
                        try? outputPipe.fileHandleForWriting.close()
                        try? errorPipe.fileHandleForWriting.close()
                        box.store(pid)
                        if box.isCancelled { box.terminate() }
                        let exitCode = try box.waitForExit(pid) {
                            output.reachedEOF && errors.reachedEOF
                        }
                        if box.isCancelled { throw CancellationError() }
                        outputPipe.fileHandleForReading.readabilityHandler = nil
                        errorPipe.fileHandleForReading.readabilityHandler = nil
                        output.append((try? outputPipe.fileHandleForReading.readToEnd()) ?? Data())
                        errors.append((try? errorPipe.fileHandleForReading.readToEnd()) ?? Data())
                        continuation.resume(returning: ProcessResult(
                            stdout: output.output,
                            stderr: errors.output,
                            exitCode: exitCode
                        ))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            box.terminate()
        }
    }

    static func runProcessForTesting(
        command: String,
        launchDelay: Duration = .zero,
        sendSignal: @escaping ProcessSignalSender = { Darwin.kill($0, $1) }
    ) async throws -> Int32 {
        try await runProcess(
            executable: "/bin/zsh",
            arguments: ["-lc", command],
            launchDelay: launchDelay,
            sendSignal: sendSignal
        ).exitCode
    }

    private enum ToolError: LocalizedError {
        case missing(String)
        case message(String)
        var errorDescription: String? {
            switch self {
            case .missing(let name): return "Missing required argument: \(name)"
            case .message(let message): return message
            }
        }
    }
}
