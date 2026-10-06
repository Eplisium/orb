import Foundation
import Testing
@testable import ORB

// MARK: - Test Helpers

private func fixtureData(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

private func model(
    id: String,
    name: String = "Test Model",
    supportsTools: Bool = false,
    supportsImages: Bool = false,
    contextLength: Int = 128_000,
    promptCost: String? = "0.000001",
    completionCost: String? = "0.000002",
    created: Double? = nil,
    description: String? = nil
) -> ModelInfo {
    let inputMods = supportsImages ? ["text", "image"] : ["text"]
    return ModelInfo(
        id: id,
        canonicalSlug: nil,
        huggingFaceId: nil,
        name: name,
        created: created,
        description: description,
        contextLength: contextLength,
        architecture: Architecture(
            modality: supportsImages ? "text+image->text" : "text->text",
            inputModalities: inputMods,
            outputModalities: ["text"],
            tokenizer: nil,
            instructType: nil
        ),
        pricing: Pricing(prompt: promptCost, completion: completionCost, inputCacheRead: nil),
        topProvider: nil,
        supportedParameters: supportsTools ? ["tools"] : [],
        reasoning: nil,
        knowledgeCutoff: nil,
        expirationDate: nil,
        supportedVoices: nil,
        benchmarks: nil,
        perRequestLimits: nil,
        defaultParameters: nil
    )
}

private func tempDir() -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ORBTest-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

// MARK: - Agent Model Catalog Tests

@Suite("Agent model catalog")
struct AgentModelCatalogTests {
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

        // Search by provider
        let byProvider = AgentModelCatalog.sections(models: models, favoriteIds: [], searchText: "openai", toolCapableOnly: true)
        #expect(byProvider.flatMap(\.models).map(\.id) == ["openai/gpt-test"])

        // Search by name
        let byName = AgentModelCatalog.sections(models: models, favoriteIds: [], searchText: "Writer", toolCapableOnly: true)
        #expect(byName.flatMap(\.models).map(\.id) == ["anthropic/claude-test"])

        // Search by id
        let byId = AgentModelCatalog.sections(models: models, favoriteIds: [], searchText: "claude-test", toolCapableOnly: true)
        #expect(byId.flatMap(\.models).map(\.id) == ["anthropic/claude-test"])
    }

    @Test("tool-capable filter excludes non-tool models")
    func toolFilterWorks() {
        let toolModel = model(id: "openai/gpt-4o", supportsTools: true)
        let textModel = model(id: "anthropic/claude", supportsTools: false)

        let sections = AgentModelCatalog.sections(
            models: [toolModel, textModel],
            favoriteIds: [],
            searchText: "",
            toolCapableOnly: true
        )
        let resultIds = sections.flatMap(\.models).map(\.id)
        #expect(resultIds.contains("openai/gpt-4o"))
        #expect(!resultIds.contains("anthropic/claude"))
    }

    @Test("empty search returns all matching models")
    func emptySearchReturnsAll() {
        let models = [
            model(id: "a/model1", supportsTools: true),
            model(id: "b/model2", supportsTools: true),
        ]
        let sections = AgentModelCatalog.sections(models: models, favoriteIds: [], searchText: "", toolCapableOnly: true)
        #expect(sections.flatMap(\.models).count == 2)
    }
}

// MARK: - Native Agent Tools Definition Tests

@Suite("Native agent tools")
struct NativeAgentToolsTests {
    @Test("native agent advertises computer-control functions when access is on")
    func advertisesComputerControlFunctions() {
        let names = Set(NativeAgentTools.definitions(fullComputerAccess: true).map(\.function.name))

        #expect(names.contains("read_file"))
        #expect(names.contains("write_file"))
        #expect(names.contains("list_directory"))
        #expect(names.contains("search_files"))
        #expect(names.contains("run_command"))
        #expect(names.contains("run_applescript"))
        #expect(names.contains("open_application"))
        #expect(names.contains("open_url"))
        #expect(names.contains("capture_screen"))
        #expect(names.contains("computer_action"))
        #expect(names.contains("fetch_url"))
    }

    @Test("only fetch_url is available when access is off")
    func onlyFetchUrlWithoutAccess() {
        let defs = NativeAgentTools.definitions(fullComputerAccess: false)
        #expect(defs.count == 1)
        #expect(defs[0].function.name == "fetch_url")
    }

    @Test("computer-control functions are unavailable when access is off")
    func computerFunctionsRequireAccess() async throws {
        let result = try await NativeAgentTools.execute(
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
        let directory = tempDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("sample.txt")
        try "native agent ready".write(to: file, atomically: true, encoding: .utf8)

        let arguments = try #require(String(
            data: JSONSerialization.data(withJSONObject: ["path": file.path]),
            encoding: .utf8
        ))
        let result = try await NativeAgentTools.execute(
            name: "read_file",
            argumentsJSON: arguments,
            workspace: directory.path,
            fullComputerAccess: true
        )

        #expect(!result.isError)
        #expect(result.content.contains("native agent ready"))
    }

    @Test("read_file supports offset and limit")
    func readFileOffsetLimit() async throws {
        let directory = tempDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("lines.txt")
        let content = (1...100).map { "line \($0)" }.joined(separator: "\n")
        try content.write(to: file, atomically: true, encoding: .utf8)

        let args = try #require(String(
            data: JSONSerialization.data(withJSONObject: ["path": file.path, "offset": 10, "limit": 5] as [String: Any]),
            encoding: .utf8
        ))
        let result = try await NativeAgentTools.execute(name: "read_file", argumentsJSON: args, workspace: directory.path, fullComputerAccess: true)

        #expect(!result.isError)
        #expect(result.content.contains("10|line 10"))
        #expect(result.content.contains("14|line 14"))
        #expect(!result.content.contains("15|line 15"))
    }

    @Test("write_file creates parent directories")
    func writeFileCreatesDirs() async throws {
        let directory = tempDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        let nestedPath = directory.appendingPathComponent("a/b/c/file.txt").path

        let args = try #require(String(
            data: JSONSerialization.data(withJSONObject: ["path": nestedPath, "content": "hello nested"]),
            encoding: .utf8
        ))
        let result = try await NativeAgentTools.execute(name: "write_file", argumentsJSON: args, workspace: directory.path, fullComputerAccess: true)

        #expect(!result.isError)
        #expect(result.content.contains("Wrote"))
        let written = try String(contentsOfFile: nestedPath, encoding: .utf8)
        #expect(written == "hello nested")
    }

    @Test("list_directory shows files and folders")
    func listDirectoryWorks() async throws {
        let directory = tempDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("subfolder"), withIntermediateDirectories: true)
        try "content".write(to: directory.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)

        let args = try #require(String(
            data: JSONSerialization.data(withJSONObject: ["path": directory.path]),
            encoding: .utf8
        ))
        let result = try await NativeAgentTools.execute(name: "list_directory", argumentsJSON: args, workspace: directory.path, fullComputerAccess: true)

        #expect(!result.isError)
        #expect(result.content.contains("[dir]  subfolder/"))
        #expect(result.content.contains("[file] file.txt"))
    }

    @Test("search_files finds case-insensitive matches")
    func searchFilesWorks() async throws {
        let directory = tempDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        try "Hello World\nfoo bar\nHELLO again".write(to: directory.appendingPathComponent("test.txt"), atomically: true, encoding: .utf8)

        let args = try #require(String(
            data: JSONSerialization.data(withJSONObject: ["path": directory.path, "query": "hello"]),
            encoding: .utf8
        ))
        let result = try await NativeAgentTools.execute(name: "search_files", argumentsJSON: args, workspace: directory.path, fullComputerAccess: true)

        #expect(!result.isError)
        #expect(result.content.contains("Hello World"))
        #expect(result.content.contains("HELLO again"))
        #expect(!result.content.contains("foo bar"))
    }

    @Test("command output is bounded before returning to the model")
    func commandOutputIsBounded() async throws {
        let result = try await NativeAgentTools.execute(
            name: "run_command",
            argumentsJSON: #"{"command":"python3 -c 'print(\"x\" * 150000)'"}"#,
            workspace: FileManager.default.temporaryDirectory.path,
            fullComputerAccess: true
        )

        #expect(result.content.utf8.count < 130_000)
        #expect(result.content.contains("truncated"))
    }

    @Test("run_command captures exit code and stderr")
    func commandCapturesExitCode() async throws {
        let result = try await NativeAgentTools.execute(
            name: "run_command",
            argumentsJSON: #"{"command":"echo ok && echo err >&2 && exit 42"}"#,
            workspace: FileManager.default.temporaryDirectory.path,
            fullComputerAccess: true
        )

        #expect(result.isError)
        #expect(result.content.contains("exit_code: 42"))
        #expect(result.content.contains("ok"))
    }

    @Test("unknown tool returns error")
    func unknownToolReturnsError() async throws {
        let result = try await NativeAgentTools.execute(
            name: "nonexistent_tool",
            argumentsJSON: "{}",
            workspace: "/tmp",
            fullComputerAccess: true
        )
        #expect(result.isError)
        #expect(result.content.contains("Unknown native function"))
    }

    @Test("run_applescript executes basic script")
    func appleScriptWorks() async throws {
        let result = try await NativeAgentTools.execute(
            name: "run_applescript",
            argumentsJSON: #"{"script":"return 1 + 2"}"#,
            workspace: "/tmp",
            fullComputerAccess: true
        )
        #expect(!result.isError)
        #expect(result.content.trimmingCharacters(in: .whitespacesAndNewlines) == "3")
    }
}

// MARK: - API Response Decoding Tests

@Suite("API response decoding")
struct APIDecodingTests {
    @Test("OpenRouter models list decodes")
    func modelsListDecodes() throws {
        let data = try fixtureData("models_response")
        let response = try JSONDecoder().decode(OpenRouterResponse.self, from: data)

        #expect(response.data.count == 3)
        #expect(response.data[0].id == "openai/gpt-4o")
        #expect(response.data[0].name == "GPT-4o")
        #expect(response.data[0].contextLength == 128_000)
        #expect(response.data[0].supportsTools == true)
        #expect(response.data[0].supportsImages == true)
        #expect(response.data[0].provider == "openai")
        #expect(response.data[0].promptCostPer1M == 5.0)
        #expect(response.data[0].completionCostPer1M == 15.0)
    }

    @Test("free model detection works")
    func freeModelDetection() throws {
        let data = try fixtureData("models_response")
        let response = try JSONDecoder().decode(OpenRouterResponse.self, from: data)

        let freeModel = response.data[2]
        #expect(freeModel.id == "meta-llama/llama-3.1-8b-instruct:free")
        #expect(freeModel.isFree == true)

        let paidModel = response.data[0]
        #expect(paidModel.isFree == false)
    }

    @Test("endpoint response decodes with providers")
    func endpointResponseDecodes() throws {
        let data = try fixtureData("endpoints_response")
        let response = try JSONDecoder().decode(EndpointResponse.self, from: data)

        #expect(response.data.id == "openai/gpt-4o")
        #expect(response.data.endpoints.count == 2)
        #expect(response.data.endpoints[0].providerName == "OpenAI")
        #expect(response.data.endpoints[0].promptCostPer1M == 5.0)
        #expect(response.data.endpoints[0].isAvailable == true)
    }

    @Test("credits response decodes")
    func creditsResponseDecodes() throws {
        let data = try fixtureData("credits_response")
        let response = try JSONDecoder().decode(CreditsResponse.self, from: data)

        #expect(response.data.totalCredits == 50.0)
        #expect(response.data.totalUsage == 12.4567)
        #expect(response.data.remaining == 50.0 - 12.4567)
    }

    @Test("activity response decodes")
    func activityResponseDecodes() throws {
        let data = try fixtureData("activity_response")
        let response = try JSONDecoder().decode(ActivityResponse.self, from: data)

        #expect(response.data.count == 2)
        #expect(response.data[0].model == "openai/gpt-4o")
        #expect(response.data[0].usage == 2.3456)
        #expect(response.data[0].requests == 150)
        #expect(response.data[0].promptTokens == 500000)
    }

    @Test("chat delta response decodes")
    func chatDeltaDecodes() throws {
        let data = try fixtureData("chat_delta_response")
        let response = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)

        #expect(response.choices?.first?.delta?.content == "Hello! How can I help you today?")
        #expect(response.choices?.first?.delta?.role == "assistant")
    }

    @Test("agent tool-call response decodes")
    func agentToolCallDecodes() throws {
        let data = try fixtureData("chat_toolcall_response")
        let response = try JSONDecoder().decode(AgentCompletionResponse.self, from: data)

        let calls = response.choices.first?.message.toolCalls ?? []
        #expect(calls.count == 2)
        #expect(calls[0].function.name == "read_file")
        #expect(calls[1].function.name == "run_command")
        #expect(response.usage?.totalTokens == 580)
        #expect(response.usage?.cost == 0.0012)
    }

    @Test("chat error response decodes")
    func chatErrorDecodes() throws {
        let data = try fixtureData("chat_error_response")
        let response = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)

        #expect(response.error?.code == 402)
        #expect(response.error?.message?.contains("Insufficient credits") == true)
        #expect(response.error?.metadata?.providerName == "OpenAI")
    }

    @Test("agent error response decodes without choices")
    func agentErrorDecodes() throws {
        let json = #"{"error":{"code":400,"message":"Model does not support tools"}}"#
        let response = try JSONDecoder().decode(AgentCompletionResponse.self, from: Data(json.utf8))

        #expect(response.choices.isEmpty)
        #expect(response.error?.message == "Model does not support tools")
    }
}

// MARK: - BrowserViewModel Tests

@Suite("BrowserViewModel filtering and sorting")
struct BrowserViewModelTests {
    @MainActor
    private func makeViewModel(models: [ModelInfo]) -> BrowserViewModel {
        let vm = BrowserViewModel()
        vm.api.models = models
        return vm
    }

    @Test("search by model name")
    @MainActor
    func searchByName() {
        let vm = makeViewModel(models: [
            model(id: "a/model1", name: "GPT-4o"),
            model(id: "b/model2", name: "Claude Sonnet"),
        ])
        vm.searchText = "gpt"
        #expect(vm.filteredModels.count == 1)
        #expect(vm.filteredModels[0].id == "a/model1")
    }

    @Test("search by provider")
    @MainActor
    func searchByProvider() {
        let vm = makeViewModel(models: [
            model(id: "openai/gpt-4o", name: "GPT-4o"),
            model(id: "anthropic/claude", name: "Claude"),
        ])
        vm.searchText = "anthropic"
        #expect(vm.filteredModels.count == 1)
        #expect(vm.filteredModels[0].id == "anthropic/claude")
    }

    @Test("modality filter: text only")
    @MainActor
    func textOnlyFilter() {
        let vm = makeViewModel(models: [
            model(id: "a/text", supportsImages: false),
            model(id: "b/vision", supportsImages: true),
        ])
        vm.modalityFilter = .textOnly
        #expect(vm.filteredModels.count == 1)
        #expect(vm.filteredModels[0].id == "a/text")
    }

    @Test("modality filter: multimodal")
    @MainActor
    func multimodalFilter() {
        let vm = makeViewModel(models: [
            model(id: "a/text", supportsImages: false),
            model(id: "b/vision", supportsImages: true),
        ])
        vm.modalityFilter = .multimodal
        #expect(vm.filteredModels.count == 1)
        #expect(vm.filteredModels[0].id == "b/vision")
    }

    @Test("modality filter: tools")
    @MainActor
    func toolsFilter() {
        let vm = makeViewModel(models: [
            model(id: "a/tools", supportsTools: true),
            model(id: "b/notools", supportsTools: false),
        ])
        vm.modalityFilter = .tools
        #expect(vm.filteredModels.count == 1)
        #expect(vm.filteredModels[0].id == "a/tools")
    }

    @Test("sort by context length ascending")
    @MainActor
    func sortByContextLength() {
        let vm = makeViewModel(models: [
            model(id: "a/small", contextLength: 8000),
            model(id: "b/large", contextLength: 128000),
        ])
        vm.sortField = .contextLength
        vm.sortOrder = .ascending
        #expect(vm.filteredModels[0].id == "a/small")
        #expect(vm.filteredModels[1].id == "b/large")
    }

    @Test("sort by prompt cost descending")
    @MainActor
    func sortByCost() {
        let vm = makeViewModel(models: [
            model(id: "a/cheap", promptCost: "0.000001"),
            model(id: "b/expensive", promptCost: "0.000010"),
        ])
        vm.sortField = .promptCost
        vm.sortOrder = .descending
        #expect(vm.filteredModels[0].id == "b/expensive")
    }

    @Test("favorites only filter")
    @MainActor
    func favoritesOnlyFilter() {
        let vm = makeViewModel(models: [
            model(id: "a/fav"),
            model(id: "b/notfav"),
        ])
        vm.favoriteIds = ["a/fav"]
        vm.showFavoritesOnly = true
        #expect(vm.filteredModels.count == 1)
        #expect(vm.filteredModels[0].id == "a/fav")
    }

    @Test("provider filter")
    @MainActor
    func providerFilter() {
        let vm = makeViewModel(models: [
            model(id: "openai/gpt-4o"),
            model(id: "anthropic/claude"),
        ])
        vm.providerFilter = "openai"
        #expect(vm.filteredModels.count == 1)
        #expect(vm.filteredModels[0].id == "openai/gpt-4o")
    }

    @Test("combined search and modality filter")
    @MainActor
    func combinedFilters() {
        let vm = makeViewModel(models: [
            model(id: "openai/gpt-4o", name: "GPT-4o", supportsTools: true),
            model(id: "openai/gpt-3.5", name: "GPT-3.5", supportsTools: false),
            model(id: "anthropic/claude", name: "Claude", supportsTools: true),
        ])
        vm.searchText = "gpt"
        vm.modalityFilter = .tools
        #expect(vm.filteredModels.count == 1)
        #expect(vm.filteredModels[0].id == "openai/gpt-4o")
    }

    @Test("isNewThisWeek returns true for recent models")
    @MainActor
    func newThisWeek() {
        let vm = BrowserViewModel()
        let recentModel = model(id: "a/new", created: Date().timeIntervalSince1970 - 86400) // 1 day ago
        let oldModel = model(id: "b/old", created: Date().timeIntervalSince1970 - 30 * 86400) // 30 days ago

        #expect(vm.isNewThisWeek(recentModel) == true)
        #expect(vm.isNewThisWeek(oldModel) == false)
    }
}

// MARK: - DatabaseManager Tests

@Suite("DatabaseManager", .serialized)
struct DatabaseManagerTests {
    @Test("add and check favorite")
    func addAndCheckFavorite() {
        let db = DatabaseManager.shared
        // Clean up first
        db.removeFavorite("test/model-1")
        defer { db.removeFavorite("test/model-1") }

        #expect(db.isFavorite("test/model-1") == false)
        db.addFavorite("test/model-1")
        #expect(db.isFavorite("test/model-1") == true)
    }

    @Test("toggle favorite")
    func toggleFavorite() {
        let db = DatabaseManager.shared
        db.removeFavorite("test/toggle")
        defer { db.removeFavorite("test/toggle") }

        db.toggleFavorite("test/toggle")
        #expect(db.isFavorite("test/toggle") == true)
        db.toggleFavorite("test/toggle")
        #expect(db.isFavorite("test/toggle") == false)
    }

    @Test("get all favorites returns added favorites")
    func getAllFavorites() {
        let db = DatabaseManager.shared
        db.removeFavorite("test/all-1")
        db.removeFavorite("test/all-2")
        defer {
            db.removeFavorite("test/all-1")
            db.removeFavorite("test/all-2")
        }

        db.addFavorite("test/all-1")
        db.addFavorite("test/all-2")
        let favs = db.getAllFavorites()
        #expect(favs.contains("test/all-1"))
        #expect(favs.contains("test/all-2"))
    }

    @Test("notes save and retrieve")
    func notesSaveAndRetrieve() {
        let db = DatabaseManager.shared
        let modelID = "test/notes-\(UUID().uuidString)"
        defer { db.removeFavorite(modelID) }

        db.addFavorite(modelID)
        #expect(db.getNotes(modelID) == "")

        db.setNotes(modelID, notes: "Great model for coding")
        #expect(db.getNotes(modelID) == "Great model for coding")

        db.setNotes(modelID, notes: "Updated notes")
        #expect(db.getNotes(modelID) == "Updated notes")
    }

    @Test("model notes survive unfavorite and refavorite")
    func notesSurviveFavoriteToggle() {
        let db = DatabaseManager.shared
        let modelID = "test/notes-toggle-\(UUID().uuidString)"
        defer { db.removeFavorite(modelID) }

        db.addFavorite(modelID)
        db.setNotes(modelID, notes: "Keep this note")
        db.removeFavorite(modelID)
        db.addFavorite(modelID)

        #expect(db.getNotes(modelID) == "Keep this note")
    }

    @Test("duplicate favorite insert is ignored")
    func duplicateInsertIgnored() {
        let db = DatabaseManager.shared
        db.removeFavorite("test/dup")
        defer { db.removeFavorite("test/dup") }

        db.addFavorite("test/dup")
        db.addFavorite("test/dup") // should not crash
        #expect(db.isFavorite("test/dup") == true)
    }

    @Test("conversation save and load")
    func conversationSaveAndLoad() {
        let db = DatabaseManager.shared
        let id = UUID()
        var conv = ChatConversation(id: id, modelId: "openai/gpt-4o", mode: .chat, systemPrompt: "Be helpful")
        conv.title = "Test Conversation"
        conv.totalCost = 0.05
        conv.totalTokens = 1000

        db.saveConversation(conv)
        defer { db.deleteConversation(id) }

        let loaded = db.loadConversations()
        let found = loaded.first { $0.conversation.id == id }
        #expect(found != nil)
        #expect(found?.conversation.title == "Test Conversation")
        #expect(found?.conversation.modelId == "openai/gpt-4o")
        #expect(found?.conversation.systemPrompt == "Be helpful")
        #expect(found?.conversation.totalCost == 0.05)
        #expect(found?.conversation.totalTokens == 1000)
    }

    @Test("message save and load")
    func messageSaveAndLoad() {
        let db = DatabaseManager.shared
        let convId = UUID()
        var conv = ChatConversation(id: convId, modelId: "test/model", mode: .chat)
        db.saveConversation(conv)
        defer { db.deleteConversation(convId) }

        var msg = ChatMessage(role: "user", content: "Hello world")
        db.saveMessage(msg, conversationId: convId, sortOrder: 0)

        var assistantMsg = ChatMessage(role: "assistant", content: "Hi there!")
        assistantMsg.toolCalls = [ToolCallDisplay(id: "call_1", name: "read_file", argumentsSummary: "path: /tmp")]
        db.saveMessage(assistantMsg, conversationId: convId, sortOrder: 1)

        var toolMsg = ChatMessage(role: "tool", content: "file contents here")
        toolMsg.toolCallId = "call_1"
        toolMsg.toolName = "read_file"
        db.saveMessage(toolMsg, conversationId: convId, sortOrder: 2)

        let messages = db.loadMessages(for: convId)
        #expect(messages.count == 3)
        #expect(messages[0].role == "user")
        #expect(messages[0].content == "Hello world")
        #expect(messages[1].role == "assistant")
        #expect(messages[1].toolCalls?.count == 1)
        #expect(messages[1].toolCalls?.first?.name == "read_file")
        #expect(messages[2].role == "tool")
        #expect(messages[2].toolCallId == "call_1")
        #expect(messages[2].toolName == "read_file")
    }

    @Test("delete conversation removes messages")
    func deleteConversationRemovesMessages() {
        let db = DatabaseManager.shared
        let convId = UUID()
        let conv = ChatConversation(id: convId, modelId: "test/model", mode: .chat)
        db.saveConversation(conv)
        db.saveMessage(ChatMessage(role: "user", content: "test"), conversationId: convId, sortOrder: 0)

        db.deleteConversation(convId)

        let loaded = db.loadConversations()
        #expect(loaded.first { $0.conversation.id == convId } == nil)
        let messages = db.loadMessages(for: convId)
        #expect(messages.isEmpty)
    }

    @Test("delete individual message")
    func deleteIndividualMessage() {
        let db = DatabaseManager.shared
        let convId = UUID()
        let conv = ChatConversation(id: convId, modelId: "test/model", mode: .chat)
        db.saveConversation(conv)
        defer { db.deleteConversation(convId) }

        var msg1 = ChatMessage(role: "user", content: "first")
        db.saveMessage(msg1, conversationId: convId, sortOrder: 0)
        var msg2 = ChatMessage(role: "assistant", content: "second")
        db.saveMessage(msg2, conversationId: convId, sortOrder: 1)

        db.deleteMessage(msg1.id)
        let messages = db.loadMessages(for: convId)
        #expect(messages.count == 1)
        #expect(messages[0].content == "second")
    }

    @Test("export conversation as markdown")
    func exportMarkdown() {
        let conv = ChatConversation(modelId: "openai/gpt-4o", mode: .chat)
        var conv2 = conv
        conv2.title = "Test Export"
        conv2.messages = [
            ChatMessage(role: "user", content: "What is Swift?"),
            ChatMessage(role: "assistant", content: "Swift is a programming language."),
        ]
        conv2.totalTokens = 150
        conv2.totalCost = 0.001

        let md = DatabaseManager.shared.exportConversationMarkdown(conv2)
        #expect(md.contains("# Test Export"))
        #expect(md.contains("openai/gpt-4o"))
        #expect(md.contains("**You**:"))
        #expect(md.contains("What is Swift?"))
        #expect(md.contains("**Assistant**:"))
        #expect(md.contains("Swift is a programming language."))
        #expect(md.contains("Tokens:** 150"))
    }

    @Test("test results save and load")
    func testResultsSaveAndLoad() {
        let db = DatabaseManager.shared
        let result = TestRunResult(
            id: UUID(),
            scenarioId: "test-scenario",
            scenarioTitle: "Test Scenario",
            category: .webDevelopment,
            modelId: "openai/gpt-4o",
            response: "Test response",
            promptTokens: 100,
            completionTokens: 50,
            totalTokens: 150,
            cost: 0.001,
            latencyMs: 500,
            success: true,
            errorMessage: nil,
            outputPath: "/tmp/test",
            timestamp: Date()
        )

        db.saveTestResult(result)
        defer { db.deleteTestResult(result.id) }

        let loaded = db.loadTestResults()
        let found = loaded.first { $0.id == result.id }
        #expect(found != nil)
        #expect(found?.scenarioTitle == "Test Scenario")
        #expect(found?.success == true)
        #expect(found?.totalTokens == 150)
    }
}

// MARK: - ChatMessage Model Tests

@Suite("ChatMessage model")
struct ChatMessageTests {
    @Test("ChatMessage equality is by id")
    func equalityById() {
        let id = UUID()
        var msg1 = ChatMessage(role: "user", content: "hello")
        msg1.id = id
        var msg2 = ChatMessage(role: "user", content: "hello")
        msg2.id = id
        #expect(msg1 == msg2)
    }

    @Test("ChatMessage with different ids are not equal")
    func differentIdsNotEqual() {
        let msg1 = ChatMessage(role: "user", content: "hello")
        let msg2 = ChatMessage(role: "user", content: "hello")
        #expect(msg1 != msg2)
    }

    @Test("ToolCallDisplay codable round-trip")
    func toolCallDisplayCodable() throws {
        let display = ToolCallDisplay(id: "call_1", name: "read_file", argumentsSummary: #"{"path":"/tmp"}"#)
        let data = try JSONEncoder().encode(display)
        let decoded = try JSONDecoder().decode(ToolCallDisplay.self, from: data)
        #expect(decoded.id == "call_1")
        #expect(decoded.name == "read_file")
        #expect(decoded.argumentsSummary == #"{"path":"/tmp"}"#)
    }

    @Test("ChatMessage with tool calls codable round-trip")
    func chatMessageWithToolCallsCodable() throws {
        var msg = ChatMessage(role: "assistant", content: "Let me check")
        msg.toolCalls = [
            ToolCallDisplay(id: "c1", name: "read_file", argumentsSummary: "path: /tmp"),
            ToolCallDisplay(id: "c2", name: "run_command", argumentsSummary: "command: ls"),
        ]
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: data)
        #expect(decoded.toolCalls?.count == 2)
        #expect(decoded.toolCalls?[0].name == "read_file")
        #expect(decoded.toolCalls?[1].name == "run_command")
    }
}

// MARK: - ModelInfo Computed Properties Tests

@Suite("ModelInfo computed properties")
struct ModelInfoTests {
    @Test("context length formatting")
    func contextLengthFormatting() {
        let m1 = model(id: "a/m", contextLength: 8000)
        #expect(m1.contextLengthFormatted == "8K")

        let m2 = model(id: "b/m", contextLength: 128000)
        #expect(m2.contextLengthFormatted == "128K")

        let m3 = model(id: "c/m", contextLength: 1000000)
        #expect(m3.contextLengthFormatted == "1.0M")

        let m4 = model(id: "d/m", contextLength: 2000000)
        #expect(m4.contextLengthFormatted == "2.0M")
    }

    @Test("provider extraction from id")
    func providerExtraction() {
        let m = model(id: "openai/gpt-4o")
        #expect(m.provider == "openai")
        #expect(m.modelSlug == "gpt-4o")
    }

    @Test("unofficial provider detection")
    func unofficialDetection() {
        let official = model(id: "openai/gpt-4o")
        #expect(official.isUnofficial == false)

        var unofficial = model(id: "~provider/model")
        #expect(unofficial.isUnofficial == true)
    }

    @Test("cost per million tokens")
    func costPerMillion() {
        let m = model(id: "a/m", promptCost: "0.000005", completionCost: "0.000015")
        #expect(m.promptCostPer1M == 5.0)
        #expect(m.completionCostPer1M == 15.0)
    }
}

// MARK: - Native Agent Runner Tests

@Suite("Native agent runner")
struct NativeAgentRunnerTests {
    @Test("system prompt includes workspace and access info")
    func systemPromptIncludesInfo() {
        let prompt = NativeAgentRunner.systemPrompt(workspace: "/Users/test/project", fullComputerAccess: true)
        #expect(prompt.contains("/Users/test/project"))
        #expect(prompt.contains("enabled"))
        #expect(prompt.contains("ORB Agent"))
    }

    @Test("system prompt shows disabled when access is off")
    func systemPromptDisabled() {
        let prompt = NativeAgentRunner.systemPrompt(workspace: "/tmp", fullComputerAccess: false)
        #expect(prompt.contains("disabled"))
    }

    @Test("tool-call responses decode from fixture")
    func toolCallResponsesDecode() throws {
        let data = try fixtureData("chat_toolcall_response")
        let response = try JSONDecoder().decode(AgentCompletionResponse.self, from: data)

        #expect(response.choices.first?.message.toolCalls?.first?.function.name == "read_file")
    }

    @Test(
        "real OpenRouter agent can invoke an app-owned function",
        .enabled(
            if: ProcessInfo.processInfo.environment["RUN_OPENROUTER_INTEGRATION"] == "1",
            "Live, paid OpenRouter call; set RUN_OPENROUTER_INTEGRATION=1 to run"
        )
    )
    @MainActor
    func realAgentInvokesNativeFunction() async throws {
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
        #expect(result.response.localizedCaseInsensitiveContains("ORB"))
    }
}
