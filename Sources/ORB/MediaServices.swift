import Foundation

// MARK: - Shared Generate model catalog

/// The general models route defaults to text unless output_modalities is sent.
/// Optional capability fields distinguish unknown catalog support from false.
struct GenerateCatalogModel: Decodable, Sendable, Identifiable {
    let id: String
    let name: String
    let supportedVoices: [String]?
    let architecture: Architecture?
    struct Architecture: Decodable, Sendable {
        let inputModalities: [String]?
        let outputModalities: [String]?
        enum CodingKeys: String, CodingKey {
            case inputModalities = "input_modalities"
            case outputModalities = "output_modalities"
        }
    }
    var outputModalities: [String]? { architecture?.outputModalities }
    enum CodingKeys: String, CodingKey {
        case id, name, architecture
        case supportedVoices = "supported_voices"
    }
}

@MainActor
final class GenerateModelCatalog {
    private let transport: MediaTransport
    init(transport: MediaTransport = MediaTransport()) { self.transport = transport }

    /// Fetch speech/transcription/rerank through /models, embeddings through
    /// /embeddings/models; omit pagination to receive the full catalog.
    func fetch(outputModalities: [String]) async throws -> [GenerateCatalogModel] {
        guard !outputModalities.isEmpty,
              outputModalities.allSatisfy({ ["speech", "transcription", "rerank", "embeddings"].contains($0) }) else {
            throw MediaServiceError.invalidPath("output_modalities")
        }
        struct List: Decodable { let data: [GenerateCatalogModel] }
        let embeddingsOnly = outputModalities == ["embeddings"]
        let request = try transport.request(
            path: embeddingsOnly ? "embeddings/models" : "models",
            queryItems: embeddingsOnly ? [] : [URLQueryItem(name: "output_modalities", value: outputModalities.joined(separator: ","))]
        )
        return try await transport.send(request, as: List.self).data
    }
}

// MARK: - Embeddings (`POST /embeddings`) + rerank (`POST /rerank`)

struct EmbeddingRequest: Encodable {
    var model: String
    var input: [String]
    var dimensions: Int? = nil
    var inputType: String? = nil
    var encodingFormat: String? = nil

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: EmbedKeys.self)
        try container.encode(model, forKey: .model)
        try container.encode(input, forKey: .input)
        try container.encodeIfPresent(dimensions, forKey: .dimensions)
        try container.encodeIfPresent(inputType, forKey: .inputType)
        try container.encodeIfPresent(encodingFormat, forKey: .encodingFormat)
    }

    private enum EmbedKeys: String, CodingKey {
        case model, input, dimensions
        case inputType = "input_type"
        case encodingFormat = "encoding_format"
    }
}

struct EmbeddingResponse: Decodable {
    struct Item: Decodable {
        let index: Int?
        let embedding: [Double]
    }
    let data: [Item]
    let usage: ImageGenUsage?
    let id: String?
    let model: String?
    let object: String?
}

struct RerankRequest: Encodable {
    var model: String
    var query: String
    var documents: [String]
    var topN: Int? = nil

    enum CodingKeys: String, CodingKey {
        case model, query, documents
        case topN = "top_n"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(model, forKey: .model)
        try container.encode(query, forKey: .query)
        try container.encode(documents, forKey: .documents)
        try container.encodeIfPresent(topN, forKey: .topN)
    }
}

struct RerankResponse: Decodable {
    struct Document: Decodable { let text: String?; let image: String? }
    struct Usage: Decodable {
        let searchUnits: Int?
        let totalTokens: Int?
        let cost: Double?
        enum CodingKeys: String, CodingKey {
            case cost
            case searchUnits = "search_units"
            case totalTokens = "total_tokens"
        }
    }
    struct Item: Decodable {
        let index: Int
        let relevanceScore: Double?
        let document: Document?

        enum CodingKeys: String, CodingKey {
            case index, document
            case relevanceScore = "relevance_score"
        }
    }
    let results: [Item]
    let id: String?
    let model: String?
    let provider: String?
    let usage: Usage?
}

@MainActor
final class EmbeddingService: ObservableObject {
    @Published var isWorking = false
    @Published var lastError: String?

    private let transport: MediaTransport

    init(transport: MediaTransport = MediaTransport()) { self.transport = transport }

    func embed(_ request: EmbeddingRequest) async throws -> EmbeddingResponse {
        guard request.dimensions.map({ $0 > 0 }) ?? true,
              request.encodingFormat == nil || request.encodingFormat == "float" else {
            throw MediaServiceError.invalidUpload("Embeddings require positive dimensions and float encoding for vector decoding.")
        }
        isWorking = true
        defer { isWorking = false }
        let body = try JSONEncoder().encode(request)
        let urlRequest = try transport.request(path: "embeddings", method: "POST", body: body)
        let response: EmbeddingResponse = try await transport.send(urlRequest)
        UsageLedger.shared.record(.embeddings, model: request.model, cost: response.usage?.cost,
                                  promptTokens: response.usage?.promptTokens,
                                  totalTokens: response.usage?.totalTokens)
        return response
    }

    func rerank(_ request: RerankRequest) async throws -> RerankResponse {
        guard !request.documents.isEmpty, request.topN.map({ $0 > 0 }) ?? true else {
            throw MediaServiceError.invalidUpload("Rerank needs documents and a positive top_n.")
        }
        isWorking = true
        defer { isWorking = false }
        let body = try JSONEncoder().encode(request)
        let urlRequest = try transport.request(path: "rerank", method: "POST", body: body)
        let response: RerankResponse = try await transport.send(urlRequest)
        UsageLedger.shared.record(.rerank, model: request.model, cost: response.usage?.cost,
                                  totalTokens: response.usage?.totalTokens)
        return response
    }
}

// MARK: - Files (`/files`)

/// One file in the workspace file list.
struct WorkspaceFile: Codable, Sendable, Identifiable, Hashable {
    let id: String
    let filename: String?
    let mimeType: String?
    let sizeBytes: Int?
    let createdAt: String?
    let downloadable: Bool?

    enum CodingKeys: String, CodingKey {
        case id, filename
        case mimeType = "mime_type"
        case sizeBytes = "size_bytes"
        case createdAt = "created_at"
        case downloadable
    }
}

struct WorkspaceFileList: Decodable {
    let data: [WorkspaceFile]
    let cursor: String?
    let hasMore: Bool?
    let firstID: String?
    let lastID: String?
    enum CodingKeys: String, CodingKey {
        case data, cursor
        case hasMore = "has_more"
        case firstID = "first_id"
        case lastID = "last_id"
    }
}

/// Confirmation returned by `DELETE /api/v1/files/{file_id}`. The live
/// OpenAPI schema (`FileDeleteResponse`) is a oneOf discriminated by
/// `_shape`: OpenRouter/Anthropic return `{_shape, id, type:
/// "file_deleted"}`, OpenAI returns `{_shape, id, object: "file", deleted:
/// true}`. All documented fields are decoded tolerantly; `fileDeleted`
/// normalizes the three shapes.
struct FileDeleteConfirmation: Decodable, Equatable, Sendable {
    let id: String
    let shape: String?
    let type: String?
    let object: String?
    let deleted: Bool?

    enum CodingKeys: String, CodingKey {
        case id, type, object, deleted
        case shape = "_shape"
    }

    var fileDeleted: Bool {
        deleted ?? (type == "file_deleted")
    }
}

@MainActor
final class FileService: ObservableObject {
    /// Documented Files API upload maximum: 100 MiB (104,857,600 bytes).
    /// A larger file is rejected with HTTP 413, so ORB refuses it locally
    /// before any request is sent.
    static let maxUploadBytes = 104_857_600

    @Published var files: [WorkspaceFile] = []
    @Published var isLoading = false
    @Published var lastError: String?

    private let transport: MediaTransport

    init(transport: MediaTransport = MediaTransport()) { self.transport = transport }

    /// Return a page with its opaque cursor instead of silently dropping pagination.
    func listPage(cursor: String? = nil, limit: Int? = nil) async throws -> WorkspaceFileList {
        guard limit.map({ (1...1000).contains($0) }) ?? true else {
            throw MediaServiceError.invalidUpload("File page limit must be 1 through 1000.")
        }
        var query: [URLQueryItem] = []
        if let limit { query.append(URLQueryItem(name: "limit", value: String(limit))) }
        if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        return try await transport.send(transport.request(path: "files", queryItems: query))
    }

    /// `GET /files/{file_id}` returns a direct FileResponse (no data envelope).
    func getMetadata(id: String) async throws -> WorkspaceFile {
        guard !id.isEmpty, !id.contains("/"), !id.contains("?"), !id.contains("#") else {
            throw MediaServiceError.invalidPath(id)
        }
        return try await transport.send(transport.request(path: "files/\(id)"))
    }

    func fetchFiles() async {
        guard !isLoading else { return }
        isLoading = true
        lastError = nil
        defer { isLoading = false }
        do {
            let list = try await listPage()
            files = list.data
        } catch is CancellationError {
            // Leave prior files in place; a cancelled refresh is not an error.
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Uploads raw bytes as multipart/form-data. Returns the stored file.
    /// Uploads are validated client-side before any request: the Files API
    /// rejects empty files with 400 and files over 100 MiB with 413, so ORB
    /// refuses both locally with a clear message.
    func upload(filename: String, mimeType: String, data: Data) async throws -> WorkspaceFile {
        guard !data.isEmpty else {
            throw MediaServiceError.invalidUpload(
                "\"\(filename)\" is empty; the Files API rejects empty files."
            )
        }
        guard data.count <= Self.maxUploadBytes else {
            throw MediaServiceError.invalidUpload(
                "\"\(filename)\" is \(data.count) bytes and exceeds the 100 MiB upload limit (104,857,600 bytes)."
            )
        }
        let boundary = "ORB-\(UUID().uuidString)"
        var body = Data()
        func append(_ text: String) { body.append(Data(text.utf8)) }
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"\(Self.safeMultipartFilename(filename))\"\r\n")
        append("Content-Type: \(mimeType)\r\n\r\n")
        body.append(data)
        append("\r\n--\(boundary)--\r\n")

        var request = try transport.request(path: "files", method: "POST")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return try await transport.send(request)
    }

    private static func safeMultipartFilename(_ name: String) -> String {
        name.replacingOccurrences(of: "\\", with: "_")
            .replacingOccurrences(of: "\"", with: "_")
            .replacingOccurrences(of: "\r", with: "_")
            .replacingOccurrences(of: "\n", with: "_")
    }

    /// Deletes a workspace file (`DELETE /api/v1/files/{file_id}`).
    /// Deletion is irreversible, so the service refuses to act without an
    /// explicit `confirming: true` — the view layer must only pass it after
    /// the user confirmed the exact target. The local list is updated only
    /// after the confirmed request succeeds.
    @discardableResult
    func delete(id: String, confirming: Bool) async throws -> FileDeleteConfirmation {
        guard confirming else {
            throw MediaServiceError.deleteNotConfirmed(id)
        }
        let request = try transport.request(path: "files/\(id)", method: "DELETE")
        let confirmation: FileDeleteConfirmation = try await transport.send(request)
        files.removeAll { $0.id == id }
        return confirmation
    }

    /// Downloads raw bytes for server-side files (uploads return 400).
    func downloadContent(id: String) async throws -> (Data, String?) {
        let request = try transport.request(path: "files/\(id)/content")
        return try await transport.sendRaw(request)
    }
}

// MARK: - Generation metadata (`GET /generation`)

/// Per-request metadata for a completed generation (`gen-…` id).
struct GenerationMetadata: Decodable {
    struct Payload: Decodable {
        let id: String?
        let model: String?
        let providerName: String?
        let finishReason: String?
        let totalCost: Double?
        let tokensPrompt: Int?
        let tokensCompletion: Int?
        let latency: Int?
        let streamed: Bool?

        enum CodingKeys: String, CodingKey {
            case id, model, latency, streamed
            case providerName = "provider_name"
            case finishReason = "finish_reason"
            case totalCost = "total_cost"
            case tokensPrompt = "tokens_prompt"
            case tokensCompletion = "tokens_completion"
        }
    }
    let data: Payload
}

@MainActor
final class GenerationService: ObservableObject {
    private let transport: MediaTransport

    init(transport: MediaTransport = MediaTransport()) { self.transport = transport }

    func fetch(id: String) async throws -> GenerationMetadata.Payload {
        let request = try transport.request(
            path: "generation",
            queryItems: [URLQueryItem(name: "id", value: id)]
        )
        let response: GenerationMetadata = try await transport.send(request)
        return response.data
    }
}

// MARK: - Providers, key info, usage accounting

/// One row of `GET /providers`.
struct ProviderInfo: Codable, Sendable, Identifiable, Hashable {
    let name: String
    let slug: String

    var id: String { slug }

    enum CodingKeys: String, CodingKey { case name, slug }
}

struct ProviderList: Decodable {
    let data: [ProviderInfo]
}

/// `GET /key` — info about the current API key (limits, usage).
struct KeyInfo: Decodable {
    let label: String?
    let usage: Double?
    let limit: Double?
    let limitRemaining: Double?
    let limitReset: String?
    let usageDaily: Double?
    let usageWeekly: Double?
    let usageMonthly: Double?
    let isFreeTier: Bool?
    let isProvisioningKey: Bool?
    let isManagementKey: Bool?
    let expiresAt: String?

    enum CodingKeys: String, CodingKey {
        case label, usage, limit
        case limitRemaining = "limit_remaining"
        case limitReset = "limit_reset"
        case usageDaily = "usage_daily"
        case usageWeekly = "usage_weekly"
        case usageMonthly = "usage_monthly"
        case isFreeTier = "is_free_tier"
        case isProvisioningKey = "is_provisioning_key"
        case isManagementKey = "is_management_key"
        case expiresAt = "expires_at"
    }
}

@MainActor
final class DirectoryService: ObservableObject {
    @Published var providers: [ProviderInfo] = []
    @Published var keyInfo: KeyInfo?
    @Published var lastError: String?

    private let transport: MediaTransport

    init(transport: MediaTransport = MediaTransport()) { self.transport = transport }

    func fetchProviders() async {
        do {
            // Public endpoint, but MediaTransport requires a key; fall back to
            // an unauthenticated fetch when none is configured.
            if KeychainManager.getAPIKey() == nil {
                let url = URL(string: "https://openrouter.ai/api/v1/providers")!
                let (data, _) = try await URLSession.shared.data(from: url)
                providers = try JSONDecoder().decode(ProviderList.self, from: data).data
            } else {
                let request = try transport.request(path: "providers")
                let list: ProviderList = try await transport.send(request)
                providers = list.data
            }
        } catch is CancellationError {
            // Leave prior providers in place; a cancelled refresh is not an error.
        } catch {
            lastError = error.localizedDescription
        }
    }

    func fetchKeyInfo() async {
        do {
            let request = try transport.request(path: "key")
            struct Envelope: Decodable { let data: KeyInfo }
            keyInfo = try await transport.send(request, as: Envelope.self).data
        } catch is CancellationError {
            // Leave prior key info in place; a cancelled refresh is not an error.
        } catch {
            lastError = error.localizedDescription
        }
    }
}
