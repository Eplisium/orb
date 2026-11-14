import Foundation

@MainActor
final class APIService: ObservableObject {
    /// The whole public catalog, every output modality (text, image, video,
    /// speech, embeddings, batch-only variants…). The model browser lists
    /// this.
    @Published var catalog: [ModelInfo] = [] {
        didSet { chatCatalog = catalog.filter(\.isChatCapable) }
    }

    /// Models that answer `/chat/completions` with text: the subset Chat,
    /// Agent and Test Suite may offer. Batch-only variants and image, video,
    /// speech, embedding and rerank models are excluded.
    var chatModels: [ModelInfo] { chatCatalog }

    /// Same as `chatModels`. Kept under its historical name so every Chat,
    /// Agent and Test Suite consumer keeps getting chat-capable models now
    /// that the browser loads the full catalog. Assigning replaces the whole
    /// catalog (tests and previews set it directly).
    var models: [ModelInfo] {
        get { chatCatalog }
        set { catalog = newValue }
    }

    private var chatCatalog: [ModelInfo] = []

    @Published var isLoading = false
    @Published var errorMessage: String?
    /// Set when a refresh failed but cached models are being shown (offline).
    @Published var lastRefreshError: String?
    @Published var lastRefresh: Date?
    @Published var endpointsError: String?

    typealias DataLoader = (URL) async throws -> (Data, URLResponse)

    /// `/models` defaults to text output only; `output_modalities=all` adds
    /// the embedding, image, video, speech, transcription and rerank models.
    nonisolated static let catalogURL = URL(string: "https://openrouter.ai/api/v1/models?output_modalities=all")!
    /// A captive portal or stalled network must not hold the browser for the
    /// system's 60 s default; the cache is already on screen meanwhile.
    nonisolated static let requestTimeout: TimeInterval = 15

    private let dataLoader: DataLoader

    /// Local cache path for the models list — enables instant startup on subsequent launches.
    private static let defaultCacheURL: URL = {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let appDir = appSupport.appendingPathComponent("ORB", isDirectory: true)
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        return appDir.appendingPathComponent("models_cache.json")
    }()
    private let cacheURL: URL

    /// Clock for the endpoint cache; injectable so tests can age entries.
    var now: () -> Date = Date.init

    init(
        cacheURL: URL? = nil,
        dataLoader: @escaping DataLoader = APIService.defaultLoader
    ) {
        self.cacheURL = cacheURL ?? APIService.defaultCacheURL
        self.dataLoader = dataLoader
    }

    nonisolated static func defaultLoader(_ url: URL) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: url)
        request.timeoutInterval = requestTimeout
        return try await URLSession.shared.data(for: request)
    }

    /// Stale-while-revalidate: whatever catalog is cached is shown at once,
    /// however old (its age is in `lastRefresh`: "Updated 3 days ago"),
    /// then the network refresh replaces it. `isLoading` stays true for the
    /// background refresh so the list can show a quiet progress indicator.
    func fetchModels() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        errorMessage = nil
        lastRefreshError = nil

        if catalog.isEmpty {
            loadFromCache()
            if !catalog.isEmpty { lastRefresh = cacheDate }
        }

        do {
            let (data, response) = try await dataLoader(Self.catalogURL)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                loadCacheFallback(errorDescription: "HTTP error fetching models")
                return
            }

            let decoded = try JSONDecoder().decode(OpenRouterResponse.self, from: data)
            catalog = Self.catalogOrder(decoded.data)
            lastRefresh = Date()
            saveToCache(data: data)
        } catch {
            loadCacheFallback(errorDescription: "Failed to load: \(error.localizedDescription)")
        }
    }

    // MARK: - Cache

    private var cacheDate: Date? {
        guard FileManager.default.fileExists(atPath: cacheURL.path),
              let attrs = try? FileManager.default.attributesOfItem(atPath: cacheURL.path),
              let modDate = attrs[.modificationDate] as? Date else {
            return nil
        }
        return modDate
    }

    /// Modification date of the cache file whose contents are already in
    /// `catalog`, so a fallback in the same refresh never decodes it twice.
    private var loadedCacheDate: Date?

    private func loadFromCache() {
        let date = cacheDate
        if let date, date == loadedCacheDate, !catalog.isEmpty { return }
        guard let data = try? Data(contentsOf: cacheURL),
              let decoded = try? JSONDecoder().decode(OpenRouterResponse.self, from: data) else {
            return
        }
        catalog = Self.catalogOrder(decoded.data)
        loadedCacheDate = date
    }

    /// Name order with the id as a tiebreak so equal names never shuffle.
    static func catalogOrder(_ list: [ModelInfo]) -> [ModelInfo] {
        list.sorted { $0.name != $1.name ? $0.name < $1.name : $0.id < $1.id }
    }

    private func loadCacheFallback(errorDescription: String) {
        if catalog.isEmpty { loadFromCache() }
        if !catalog.isEmpty { lastRefreshError = errorDescription }
        if catalog.isEmpty {
            errorMessage = errorDescription
        } else if lastRefresh == nil {
            lastRefresh = cacheDate
        }
    }

    private func saveToCache(data: Data) {
        try? data.write(to: cacheURL, options: .atomic)
        loadedCacheDate = cacheDate
    }

    // MARK: - Endpoints

    /// Successful `/endpoints` results stay fresh this long, so arrowing back
    /// to a model or opening Compare reuses them instead of refetching.
    static let endpointCacheTTL: TimeInterval = 300
    private var endpointCache: [String: (fetched: Date, endpoints: [ModelEndpoint])] = [:]

    /// A fresh cached result for `modelId`, or nil.
    func cachedEndpoints(for modelId: String) -> [ModelEndpoint]? {
        guard let entry = endpointCache[modelId] else { return nil }
        guard now().timeIntervalSince(entry.fetched) < Self.endpointCacheTTL else {
            endpointCache[modelId] = nil
            return nil
        }
        return entry.endpoints
    }

    /// Public `/models/{id}/endpoints` URL; nil for ids that cannot form a
    /// safe path (never force-unwrapped).
    nonisolated static func endpointsURL(for modelId: String) -> URL? {
        guard !modelId.isEmpty, !modelId.contains(".."), !modelId.contains("?"), !modelId.contains("#") else { return nil }
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "?#")
        guard let path = modelId.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "https://openrouter.ai/api/v1/models/\(path)/endpoints")
    }

    /// Side-effect-free endpoint load (does not touch `endpointsError`), so
    /// concurrent callers (Compare) cannot overwrite each other's errors.
    /// A fresh cached success is returned without a request unless
    /// `useCache` is false (Retry, catalog refresh).
    func loadEndpoints(for modelId: String, useCache: Bool = true) async -> Result<[ModelEndpoint], EndpointLoadError> {
        if useCache, let cached = cachedEndpoints(for: modelId) { return .success(cached) }
        guard let url = Self.endpointsURL(for: modelId) else { return .failure(.invalidModelID) }
        do {
            let (data, response) = try await dataLoader(url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return .failure(.http((response as? HTTPURLResponse)?.statusCode ?? 0))
            }
            let decoded = try JSONDecoder().decode(EndpointResponse.self, from: data)
            // Cheapest input first. A real $0 ranks first; variable and
            // unknown prices have no ranking price and go last.
            let sorted = decoded.data.endpoints.sorted {
                ($0.rankingInputPrice ?? .infinity, $0.baseID) < ($1.rankingInputPrice ?? .infinity, $1.baseID)
            }
            let list = ModelEndpoint.uniquified(sorted)
            endpointCache[modelId] = (now(), list)
            return .success(list)
        } catch {
            return .failure(.transport(error.localizedDescription))
        }
    }

    func fetchEndpoints(for modelId: String) async -> [ModelEndpoint] {
        endpointsError = nil
        switch await loadEndpoints(for: modelId) {
        case .success(let list): return list
        case .failure(let error):
            // A cancelled request belongs to a selection the user already
            // left; reporting it would show an error under another model.
            if !Task.isCancelled { endpointsError = error.message }
            return []
        }
    }

    /// Aliases (`~vendor/...-latest`) have no endpoints of their own; load
    /// the target's instead.
    func fetchEndpoints(for model: ModelInfo) async -> [ModelEndpoint] {
        await fetchEndpoints(for: model.endpointsModelID)
    }
}

enum EndpointLoadError: Error, Equatable {
    case invalidModelID
    case http(Int)
    case transport(String)

    var message: String {
        switch self {
        case .invalidModelID: return "This model id can't be looked up"
        case .http(let code): return "HTTP \(code) loading providers"
        case .transport(let detail): return "Failed to load providers: \(detail)"
        }
    }
}
