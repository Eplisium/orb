import Foundation
import Testing
@testable import ORB

/// End-to-end tests that spawn a real stdio MCP server subprocess and drive it
/// through the actual `MCPConnection`. These exercise process launch, JSON-RPC
/// framing, the initialize handshake, and tools/list + tools/call for real —
/// none of it is stubbed.
@Suite(.serialized)
struct MCPLiveConnectionTests {
    /// Resolves the mock server, skipping if node is unavailable.
    private static func serverConfig() -> MCPServerConfig? {
        let candidates = [NSHomeDirectory() + "/.local/bin/node", "/usr/local/bin/node", "/opt/homebrew/bin/node"]
        guard let node = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
            ?? ProcessInfo.processInfo.environment["NODE_BINARY"] else { return nil }
        guard let script = Bundle.module.url(
            forResource: "mock-mcp-server", withExtension: "mjs", subdirectory: "Fixtures"
        ) else { return nil }
        return MCPServerConfig(name: "mock", command: node, args: [script.path])
    }

    /// Tests that need the Node mock server report as skipped (not passed) when
    /// Node is not installed.
    static var nodeAvailable: Bool { serverConfig() != nil }

    @Test("connects, handshakes, and lists tools over real stdio", .enabled(if: MCPLiveConnectionTests.nodeAvailable, "requires node (or NODE_BINARY) for the mock MCP server"))
    func connectAndList() async throws {
        let config = try #require(Self.serverConfig())
        let connection = MCPConnection(config: config)
        try await connection.connect()
        defer { Task { await connection.shutdown() } }

        let tools = await connection.tools
        #expect(tools.count == 2)
        #expect(tools.contains { $0.toolName == "echo" })
        #expect(await connection.serverInfo == "mock-mcp")

        // Nested schema must arrive intact, not flattened.
        let echo = try #require(tools.first { $0.toolName == "echo" })
        let properties = echo.inputSchema.objectValue?["properties"]?.objectValue
        #expect(properties?["opts"]?.objectValue?["properties"] != nil)
        #expect(echo.qualifiedName == "mcp__mock__echo")
    }

    @Test("calls a tool and receives its result", .enabled(if: MCPLiveConnectionTests.nodeAvailable, "requires node (or NODE_BINARY) for the mock MCP server"))
    func callTool() async throws {
        let config = try #require(Self.serverConfig())
        let connection = MCPConnection(config: config)
        try await connection.connect()
        defer { Task { await connection.shutdown() } }

        let result = try await connection.callTool(
            name: "echo",
            arguments: .object(["message": .string("hello orb")])
        )
        #expect(result.content == "hello orb")
        #expect(result.isError == false)
    }

    @Test("nested arguments reach the server unmodified", .enabled(if: MCPLiveConnectionTests.nodeAvailable, "requires node (or NODE_BINARY) for the mock MCP server"))
    func nestedArguments() async throws {
        let config = try #require(Self.serverConfig())
        let connection = MCPConnection(config: config)
        try await connection.connect()
        defer { Task { await connection.shutdown() } }

        let result = try await connection.callTool(
            name: "echo",
            arguments: .object([
                "message": .string("MiXeD"),
                "opts": .object(["mode": .string("upper")])
            ])
        )
        // Only possible if the nested object survived serialization.
        #expect(result.content == "MIXED")
    }

    @Test("a tool-level error is surfaced without killing the connection", .enabled(if: MCPLiveConnectionTests.nodeAvailable, "requires node (or NODE_BINARY) for the mock MCP server"))
    func toolError() async throws {
        let config = try #require(Self.serverConfig())
        let connection = MCPConnection(config: config)
        try await connection.connect()
        defer { Task { await connection.shutdown() } }

        let failure = try await connection.callTool(name: "fail", arguments: .object([:]))
        #expect(failure.isError)
        #expect(failure.content == "intentional failure")

        // Connection must still be usable afterwards.
        let after = try await connection.callTool(
            name: "echo", arguments: .object(["message": .string("still alive")])
        )
        #expect(after.content == "still alive")
    }

    @Test("a JSON-RPC error response throws rather than returning bad data", .enabled(if: MCPLiveConnectionTests.nodeAvailable, "requires node (or NODE_BINARY) for the mock MCP server"))
    func protocolError() async throws {
        let config = try #require(Self.serverConfig())
        let connection = MCPConnection(config: config)
        try await connection.connect()
        defer { Task { await connection.shutdown() } }

        await #expect(throws: MCPError.self) {
            _ = try await connection.callTool(name: "does_not_exist", arguments: .object([:]))
        }
    }

    @Test("concurrent calls are matched to their own responses", .enabled(if: MCPLiveConnectionTests.nodeAvailable, "requires node (or NODE_BINARY) for the mock MCP server"))
    func concurrentCalls() async throws {
        let config = try #require(Self.serverConfig())
        let connection = MCPConnection(config: config)
        try await connection.connect()
        defer { Task { await connection.shutdown() } }

        // Request/response correlation by id is the easiest thing to get wrong.
        let results = try await withThrowingTaskGroup(of: (Int, String).self) { group in
            for index in 0..<12 {
                group.addTask {
                    let result = try await connection.callTool(
                        name: "echo", arguments: .object(["message": .string("msg-\(index)")])
                    )
                    return (index, result.content)
                }
            }
            var collected: [Int: String] = [:]
            for try await (index, content) in group { collected[index] = content }
            return collected
        }
        #expect(results.count == 12)
        for index in 0..<12 {
            #expect(results[index] == "msg-\(index)")
        }
    }

    @Test("the registry exposes MCP tools as OpenRouter definitions", .enabled(if: MCPLiveConnectionTests.nodeAvailable, "requires node (or NODE_BINARY) for the mock MCP server"))
    func registryProbe() async throws {
        let config = try #require(Self.serverConfig())
        let outcome = await MCPRegistry.shared.probe(config)
        switch outcome {
        case .success(let report):
            #expect(report.tools.count == 2)
            #expect(report.tools.contains { $0.qualifiedName == "mcp__mock__echo" })
            // The probe now reports the whole capability surface.
            #expect(report.summary.contains("2 tool(s)"))
        case .failure(let error):
            Issue.record("probe failed: \(error.localizedDescription)")
        }
    }

    @Test("a bad command fails cleanly instead of hanging")
    func badCommand() async {
        let config = MCPServerConfig(name: "broken", command: "/nonexistent/binary-xyz", args: [])
        let outcome = await MCPRegistry.shared.probe(config)
        if case .success = outcome {
            Issue.record("expected a failure for a nonexistent command")
        }
    }
}
