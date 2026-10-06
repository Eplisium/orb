import Foundation

@MainActor
final class APIService: ObservableObject {
    @Published var models: [ModelInfo] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    /// Set when a refresh failed but cached models are being shown (offline).
    @Published var lastRefreshError: String?
    @Published var lastRefresh: Date?
    @Published var endpointsError: String?

    typealias DataLoader = (URL) async throws -> (Data, URLResponse)

    private let modelsURL = URL(string: "https://openrouter.ai/api/v1/models")!
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

    /// Cache the models response for 5 minutes. If the network fails, fall back to cache regardless of age.
    private let cacheMaxAge: TimeInterval = 300

    init(
        cacheURL: URL? = nil,
        dataLoader: @escaping DataLoader = { try await URLSession.shared.data(from: $0) }
    ) {
        self.cacheURL = cacheURL ?? APIService.defaultCacheURL
        self.dataLoader = dataLoader
    }

    func fetchModels() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        errorMessage = nil
        lastRefreshError = nil

        // Try to load from cache first for instant display
        if hasValidCache {
            loadFromCache()
            lastRefresh = cacheDate
        }

        do {
            let (data, response) = try await dataLoader(modelsURL)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                loadCacheFallback(errorDescription: "HTTP error fetching models")
                return
            }

            let decoded = try JSONDecoder().decode(OpenRouterResponse.self, from: data)
            models = Self.catalogOrder(decoded.data)
            lastRefresh = Date()
            saveToCache(data: data)
        } catch {
            loadCacheFallback(errorDescription: "Failed to load: \(error.localizedDescription)")
        }
    }

    // MARK: - Cache

    private var hasValidCache: Bool {
        guard FileManager.default.fileExists(atPath: cacheURL.path),
              let attrs = try? FileManager.default.attributesOfItem(atPath: cacheURL.path),
              let modDate = attrs[.modificationDate] as? Date else {
            return false
        }
        return Date().timeIntervalSince(modDate) < cacheMaxAge
    }

    private var cacheDate: Date? {
        guard FileManager.default.fileExists(atPath: cacheURL.path),
              let attrs = try? FileManager.default.attributesOfItem(atPath: cacheURL.path),
              let modDate = attrs[.modificationDate] as? Date else {
            return nil
        }
        return modDate
    }

    /// Modification date of the cache file whose contents are already in
    /// `models`, so a fallback in the same refresh never decodes it twice.
    private var loadedCacheDate: Date?

    private func loadFromCache() {
        let date = cacheDate
        if let date, date == loadedCacheDate, !models.isEmpty { return }
        guard let data = try? Data(contentsOf: cacheURL),
              let decoded = try? JSONDecoder().decode(OpenRouterResponse.self, from: data) else {
            return
        }
        models = Self.catalogOrder(decoded.data)
        loadedCacheDate = date
    }

    /// Name order with the id as a tiebreak so equal names never shuffle.
    static func catalogOrder(_ list: [ModelInfo]) -> [ModelInfo] {
        list.sorted { $0.name != $1.name ? $0.name < $1.name : $0.id < $1.id }
    }

    private func loadCacheFallback(errorDescription: String) {
        if models.isEmpty { loadFromCache() }
        if !models.isEmpty { lastRefreshError = errorDescription }
        if models.isEmpty {
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
    func loadEndpoints(for modelId: String) async -> Result<[ModelEndpoint], EndpointLoadError> {
        guard let url = Self.endpointsURL(for: modelId) else { return .failure(.invalidModelID) }
        do {
            let (data, response) = try await dataLoader(url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return .failure(.http((response as? HTTPURLResponse)?.statusCode ?? 0))
            }
            let decoded = try JSONDecoder().decode(EndpointResponse.self, from: data)
            let sorted = decoded.data.endpoints.sorted {
                ($0.promptCostPer1M ?? .infinity, $0.baseID) < ($1.promptCostPer1M ?? .infinity, $1.baseID)
            }
            return .success(ModelEndpoint.uniquified(sorted))
        } catch {
            return .failure(.transport(error.localizedDescription))
        }
    }

    func fetchEndpoints(for modelId: String) async -> [ModelEndpoint] {
        endpointsError = nil
        switch await loadEndpoints(for: modelId) {
        case .success(let list): return list
        case .failure(let error):
            endpointsError = error.message
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
