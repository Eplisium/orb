import Foundation
import Testing
@testable import ORB

/// Live end-to-end coverage for MCP's non-tool capabilities: resources and
/// prompts, plus the synthetic tool bridge that makes them reachable by a
/// chat model. Drives a real subprocess — nothing here is stubbed.
@Suite(.serialized)
struct MCPCapabilityTests {
    private static func serverConfig() -> MCPServerConfig? {
        let candidates = ["/Users/rueearth/.local/bin/node", "/usr/local/bin/node", "/opt/homebrew/bin/node"]
        guard let node = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
            ?? ProcessInfo.processInfo.environment["NODE_BINARY"] else { return nil }
        guard let script = Bundle.module.url(
            forResource: "mock-mcp-server", withExtension: "mjs", subdirectory: "Fixtures"
        ) else { return nil }
        return MCPServerConfig(name: "mock", command: node, args: [script.path])
    }

    @Test("advertised capabilities are detected from the handshake")
    func capabilityDetection() async throws {
        guard let config = Self.serverConfig() else { return }
        let connection = MCPConnection(config: config)
        try await connection.connect()
        defer { Task { await connection.shutdown() } }

        #expect(await connection.supportsResources)
        #expect(await connection.supportsPrompts)
    }

    @Test("resources are listed during connect")
    func listsResources() async throws {
        guard let config = Self.serverConfig() else { return }
        let connection = MCPConnection(config: config)
        try await connection.connect()
        defer { Task { await connection.shutdown() } }

        let resources = await connection.resources
        #expect(resources.count == 2)
        #expect(resources.contains { $0.uri == "mock://readme" && $0.name == "Readme" })
    }

    @Test("text resources are read over the wire")
    func readsTextResource() async throws {
        guard let config = Self.serverConfig() else { return }
        let connection = MCPConnection(config: config)
        try await connection.connect()
        defer { Task { await connection.shutdown() } }

        let body = try await connection.readResource(uri: "mock://readme")
        #expect(body == "ORB resource body")
    }

    @Test("binary resources are described rather than inlined as base64")
    func binaryResourceIsDescribed() async throws {
        guard let config = Self.serverConfig() else { return }
        let connection = MCPConnection(config: config)
        try await connection.connect()
        defer { Task { await connection.shutdown() } }

        let body = try await connection.readResource(uri: "mock://binary")
        // Dumping base64 into the conversation would waste context.
        #expect(body.contains("binary resource"))
        #expect(!body.contains("iVBORw0KGgo="))
    }

    @Test("prompt templates and their arguments are listed")
    func listsPrompts() async throws {
        guard let config = Self.serverConfig() else { return }
        let connection = MCPConnection(config: config)
        try await connection.connect()
        defer { Task { await connection.shutdown() } }

        let prompts = await connection.prompts
        let greet = try #require(prompts.first { $0.name == "greet" })
        #expect(greet.arguments.count == 2)
        #expect(greet.arguments.contains { $0.name == "who" && $0.required })
        #expect(greet.arguments.contains { $0.name == "times" && !$0.required })
    }

    @Test("prompt templates expand with supplied arguments")
    func expandsPrompt() async throws {
        guard let config = Self.serverConfig() else { return }
        let connection = MCPConnection(config: config)
        try await connection.connect()
        defer { Task { await connection.shutdown() } }

        let text = try await connection.getPrompt(name: "greet", arguments: ["who": "Zach", "times": "3"])
        #expect(text == "Hello Zach x3")
    }

    // MARK: - Synthetic tool bridge

    /// A chat model can only call tools, so resources and prompts must appear
    /// as tool definitions or they are unreachable in practice.
    @Test("registry publishes synthetic tools for resources and prompts")
    func registryPublishesSyntheticTools() async throws {
        guard let config = Self.serverConfig() else { return }
        var enabled = config
        enabled.isEnabled = true
        MCPRegistry.saveConfigs([enabled])
        defer { MCPRegistry.saveConfigs([]) }

        await MCPRegistry.shared.startEnabledServers()
        defer { Task { await MCPRegistry.shared.shutdownAll() } }

        let names = await MCPRegistry.shared.toolDefinitions().map(\.function.name)
        #expect(names.contains(MCPToolNaming.readResourceTool))
        #expect(names.contains(MCPToolNaming.getPromptTool))
        #expect(names.contains("mcp__mock__echo"))
    }

    @Test("synthetic read_resource routes through to the live server")
    func syntheticReadResourceRoutes() async throws {
        guard let config = Self.serverConfig() else { return }
        var enabled = config
        enabled.isEnabled = true
        MCPRegistry.saveConfigs([enabled])
        defer { MCPRegistry.saveConfigs([]) }

        await MCPRegistry.shared.startEnabledServers()
        defer { Task { await MCPRegistry.shared.shutdownAll() } }

        let result = await MCPRegistry.shared.call(
            qualifiedName: MCPToolNaming.readResourceTool,
            argumentsJSON: #"{"uri":"mock://readme"}"#
        )
        #expect(!result.isError)
        #expect(result.content == "ORB resource body")
    }

    @Test("synthetic get_prompt coerces non-string arguments")
    func syntheticGetPromptCoercesArguments() async throws {
        guard let config = Self.serverConfig() else { return }
        var enabled = config
        enabled.isEnabled = true
        MCPRegistry.saveConfigs([enabled])
        defer { MCPRegistry.saveConfigs([]) }

        await MCPRegistry.shared.startEnabledServers()
        defer { Task { await MCPRegistry.shared.shutdownAll() } }

        // Models frequently emit numbers for numeric-looking arguments; those
        // must be coerced rather than silently dropped.
        let result = await MCPRegistry.shared.call(
            qualifiedName: MCPToolNaming.getPromptTool,
            argumentsJSON: #"{"name":"greet","arguments":{"who":"Zach","times":3}}"#
        )
        #expect(!result.isError)
        #expect(result.content == "Hello Zach x3")
    }

    @Test("unknown resources return a tool error instead of throwing")
    func unknownResourceIsToolError() async throws {
        guard let config = Self.serverConfig() else { return }
        var enabled = config
        enabled.isEnabled = true
        MCPRegistry.saveConfigs([enabled])
        defer { MCPRegistry.saveConfigs([]) }

        await MCPRegistry.shared.startEnabledServers()
        defer { Task { await MCPRegistry.shared.shutdownAll() } }

        let result = await MCPRegistry.shared.call(
            qualifiedName: MCPToolNaming.readResourceTool,
            argumentsJSON: #"{"uri":"mock://missing"}"#
        )
        // An agent run must survive a bad URI.
        #expect(result.isError)
    }

    @Test("missing required arguments are rejected with a clear message")
    func missingArgumentsRejected() async throws {
        let result = await MCPRegistry.shared.call(
            qualifiedName: MCPToolNaming.readResourceTool,
            argumentsJSON: "{}"
        )
        #expect(result.isError)
        #expect(result.content.contains("uri"))
    }
}
