import Foundation
import Testing
@testable import OpenRouterBrowser

@Suite("Native OpenRouter agent")
struct NativeAgentTests {
    @Test("favorite models are promoted ahead of the rest")
    func favoriteModelsArePromoted() {
        let favorite = model(id: "openai/favorite", name: "Favorite", supportsTools: true)
        let other = model(id: "anthropic/other", name: "Other", supportsTools: true)

        let sections = AgentModelCatalog.sections(
            models: [other, favorite],
            favoriteIds: [favorite.id],
            searchText: "",
            toolCapableOnly: true
        )

        #expect(sections.map(\.title) == ["Favorites", "Tool-capable models"])
        #expect(sections[0].models.map(\.id) == [favorite.id])
        #expect(sections[1].models.map(\.id) == [other.id])
    }

    @Test("model search matches names, ids, and providers")
    func modelSearchMatchesUsefulFields() {
        let models = [
            model(id: "openai/gpt-test", name: "Fast Reasoner", supportsTools: true),
            model(id: "anthropic/claude-test", name: "Writer", supportsTools: true),
        ]

        let sections = AgentModelCatalog.sections(
            models: models,
            favoriteIds: [],
            searchText: "openai",
            toolCapableOnly: true
        )

        #expect(sections.flatMap(\.models).map(\.id) == ["openai/gpt-test"])
    }

    @Test("native agent advertises computer-control functions")
    func advertisesComputerControlFunctions() {
        let names = Set(NativeAgentTools.definitions(fullComputerAccess: true).map(\.function.name))

        #expect(names.contains("read_file"))
        #expect(names.contains("write_file"))
        #expect(names.contains("run_command"))
        #expect(names.contains("run_applescript"))
        #expect(names.contains("open_application"))
        #expect(names.contains("capture_screen"))
        #expect(names.contains("computer_action"))
    }

    @Test("computer-control functions are unavailable when access is off")
    func computerFunctionsRequireAccess() async {
        let result = await NativeAgentTools.execute(
            name: "run_command",
            argumentsJSON: #"{"command":"pwd"}"#,
            workspace: FileManager.default.homeDirectoryForCurrentUser.path,
            fullComputerAccess: false
        )

        #expect(result.isError)
        #expect(result.content.contains("Computer Access is off"))
    }

    @Test("read_file returns actual file contents")
    func readFileReturnsContents() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("sample.txt")
        try "native agent ready".write(to: file, atomically: true, encoding: .utf8)

        let arguments = try #require(String(
            data: JSONSerialization.data(withJSONObject: ["path": file.path]),
            encoding: .utf8
        ))
        let result = await NativeAgentTools.execute(
            name: "read_file",
            argumentsJSON: arguments,
            workspace: directory.path,
            fullComputerAccess: true
        )

        #expect(!result.isError)
        #expect(result.content.contains("native agent ready"))
    }

    @Test("command output is bounded before returning to the model")
    func commandOutputIsBounded() async {
        let result = await NativeAgentTools.execute(
            name: "run_command",
            argumentsJSON: #"{"command":"python3 -c 'print(\"x\" * 150000)'"}"#,
            workspace: FileManager.default.temporaryDirectory.path,
            fullComputerAccess: true
        )

        #expect(result.content.utf8.count < 130_000)
        #expect(result.content.contains("truncated"))
    }

    @Test("OpenRouter tool-call responses decode")
    func toolCallResponsesDecode() throws {
        let json = #"{"choices":[{"message":{"role":"assistant","content":null,"tool_calls":[{"id":"call_1","type":"function","function":{"name":"read_file","arguments":"{\"path\":\"/tmp/a\"}"}}]},"finish_reason":"tool_calls"}]}"#

        let response = try JSONDecoder().decode(
            AgentCompletionResponse.self,
            from: Data(json.utf8)
        )

        #expect(response.choices.first?.message.toolCalls?.first?.function.name == "read_file")
    }

    @Test("OpenRouter error envelopes decode without choices")
    func errorEnvelopesDecode() throws {
        let json = #"{"error":{"code":400,"message":"Model does not support tools"}}"#
        let response = try JSONDecoder().decode(AgentCompletionResponse.self, from: Data(json.utf8))

        #expect(response.choices.isEmpty)
        #expect(response.error?.message == "Model does not support tools")
    }

    @Test("real OpenRouter agent can invoke an app-owned function")
    @MainActor
    func realAgentInvokesNativeFunction() async throws {
        guard ProcessInfo.processInfo.environment["RUN_OPENROUTER_INTEGRATION"] == "1" else { return }
        let apiKey = try #require(KeychainManager.getAPIKey())
        let workspace = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .path

        let result = try await NativeAgentRunner.run(
            prompt: "Use read_file to inspect Package.swift, then reply with only the package name.",
            modelId: "deepseek/deepseek-v4-flash-0731",
            apiKey: apiKey,
            workspace: workspace,
            fullComputerAccess: true,
            history: [],
            onActivity: { _ in }
        )

        #expect(result.toolNames.contains("read_file"))
        #expect(result.response.localizedCaseInsensitiveContains("OpenRouterBrowser"))
    }

    private func model(id: String, name: String, supportsTools: Bool) -> ModelInfo {
        ModelInfo(
            id: id,
            canonicalSlug: nil,
            huggingFaceId: nil,
            name: name,
            created: nil,
            description: nil,
            contextLength: 128_000,
            architecture: Architecture(
                modality: "text->text",
                inputModalities: ["text"],
                outputModalities: ["text"],
                tokenizer: nil,
                instructType: nil
            ),
            pricing: Pricing(prompt: "0.000001", completion: "0.000002", inputCacheRead: nil),
            topProvider: nil,
            supportedParameters: supportsTools ? ["tools"] : [],
            reasoning: nil,
            knowledgeCutoff: nil,
            expirationDate: nil,
            supportedVoices: nil,
            benchmarks: nil
        )
    }
}