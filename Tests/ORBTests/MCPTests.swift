import Foundation
import Testing
@testable import ORB

@Suite("JSON value round-tripping")
struct JSONValueTests {
    @Test("nested schemas survive encode and decode")
    func nestedRoundTrip() throws {
        let source = """
        {"type":"object","properties":{"items":{"type":"array","items":{"type":"string"}},\
        "mode":{"type":"string","enum":["fast","slow"]}},"required":["items"]}
        """
        let value = try #require(JSONValue.parse(source))
        let encoded = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: encoded)
        #expect(decoded == value)
    }

    @Test("booleans do not collapse into numbers")
    func boolsStayBools() throws {
        let value = try #require(JSONValue.parse(#"{"a":true,"b":1}"#))
        #expect(value.objectValue?["a"] == .bool(true))
        #expect(value.objectValue?["b"] == .number(1))
    }

    @Test("malformed text parses to nil")
    func malformed() {
        #expect(JSONValue.parse("{not json") == nil)
    }
}

@Suite("MCP tool naming")
struct MCPToolNamingTests {
    @Test("qualified names round-trip")
    func roundTrip() throws {
        let name = MCPToolNaming.qualify(server: "File System", tool: "read_file")
        let route = try #require(MCPToolNaming.resolve(name))
        #expect(route.server == "File-System")
        #expect(route.tool == "read_file")
    }

    @Test("tool names containing the separator survive")
    func separatorInToolName() throws {
        let name = MCPToolNaming.qualify(server: "srv", tool: "weird__tool")
        let route = try #require(MCPToolNaming.resolve(name))
        #expect(route.tool == "weird__tool")
    }

    @Test("native tool names are not mistaken for MCP tools")
    func nativeNamesRejected() {
        #expect(MCPRegistry.isMCPTool("run_command") == false)
        #expect(MCPRegistry.isMCPTool("read_file") == false)
        #expect(MCPRegistry.isMCPTool("mcp__srv__thing"))
    }
}

@Suite("MCP configuration parsing")
struct MCPConfigTests {
    @Test("standard Claude Desktop config imports")
    func standardConfig() throws {
        let text = """
        {"mcpServers":{"filesystem":{"command":"npx","args":["-y","@modelcontextprotocol/server-filesystem","/tmp"],\
        "env":{"TOKEN":"abc"}}}}
        """
        let configs = try MCPRegistry.parseStandardConfig(text)
        #expect(configs.count == 1)
        #expect(configs[0].name == "filesystem")
        #expect(configs[0].command == "npx")
        #expect(configs[0].args.count == 3)
        #expect(configs[0].env["TOKEN"] == "abc")
    }

    @Test("a bare server map without the wrapper also imports")
    func bareMap() throws {
        let configs = try MCPRegistry.parseStandardConfig(#"{"a":{"command":"uvx","args":[]}}"#)
        #expect(configs.count == 1)
        #expect(configs[0].command == "uvx")
    }

    @Test("a server missing its command is rejected")
    func missingCommand() {
        #expect(throws: MCPError.self) {
            try MCPRegistry.parseStandardConfig(#"{"mcpServers":{"bad":{"args":[]}}}"#)
        }
    }

    @Test("invalid JSON is rejected")
    func invalidJSON() {
        #expect(throws: MCPError.self) {
            try MCPRegistry.parseStandardConfig("nonsense")
        }
    }
}

@Suite("MCP content flattening")
struct MCPContentTests {
    @Test("text blocks join into readable output")
    func textBlocks() throws {
        let result = MCPConnection.flatten(try #require(JSONValue.parse(
            #"{"content":[{"type":"text","text":"line one"},{"type":"text","text":"line two"}]}"#
        )))
        #expect(result.content == "line one\nline two")
        #expect(result.isError == false)
    }

    @Test("isError is propagated so the model can recover")
    func errorFlag() throws {
        let result = MCPConnection.flatten(try #require(JSONValue.parse(
            #"{"isError":true,"content":[{"type":"text","text":"boom"}]}"#
        )))
        #expect(result.isError)
        #expect(result.content == "boom")
    }

    @Test("image and resource blocks degrade to placeholders")
    func nonTextBlocks() throws {
        let result = MCPConnection.flatten(try #require(JSONValue.parse(
            #"{"content":[{"type":"image","mimeType":"image/png"},{"type":"resource","resource":{"uri":"file:///x"}}]}"#
        )))
        #expect(result.content.contains("image/png"))
        #expect(result.content.contains("file:///x"))
    }

    @Test("empty content does not produce a blank tool result")
    func emptyContent() throws {
        let result = MCPConnection.flatten(try #require(JSONValue.parse(#"{"content":[]}"#)))
        #expect(result.content == "(no content)")
    }
}

@Suite("MCP tool definitions")
struct MCPToolDefinitionTests {
    @Test("nested MCP schemas reach OpenRouter unflattened")
    func schemaPassthrough() throws {
        let schema = try #require(JSONValue.parse(
            #"{"type":"object","properties":{"path":{"type":"string"},"opts":{"type":"object","properties":{"deep":{"type":"boolean"}}}},"required":["path"]}"#
        ))
        let descriptor = MCPToolDescriptor(
            serverName: "fs", toolName: "read", description: "Read", inputSchema: schema
        )
        let definition = AgentToolDefinition(function: .init(
            name: descriptor.qualifiedName,
            description: descriptor.description,
            parameters: .raw(descriptor.inputSchema)
        ))
        let encoded = try JSONEncoder().encode(definition)
        let text = String(decoding: encoded, as: UTF8.self)
        // The nested object must survive; a flattening bug would drop it.
        #expect(text.contains("\"deep\""))
        #expect(text.contains("\"opts\""))
    }

    @Test("native tool definitions still encode as flat JSON Schema")
    func nativeStillEncodes() throws {
        let tools = NativeAgentTools.definitions(fullComputerAccess: false)
        let encoded = try JSONEncoder().encode(tools)
        let text = String(decoding: encoded, as: UTF8.self)
        #expect(text.contains("\"type\":\"object\""))
        #expect(text.contains("fetch_url"))
    }
}
