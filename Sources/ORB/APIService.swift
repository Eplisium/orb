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
            models = decoded.data.sorted { $0.name < $1.name }
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

    private func loadFromCache() {
        guard let data = try? Data(contentsOf: cacheURL),
              let decoded = try? JSONDecoder().decode(OpenRouterResponse.self, from: data) else {
            return
        }
        models = decoded.data.sorted { $0.name < $1.name }
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
        try? data.write(to: cacheURL)
    }

    // MARK: - Endpoints

    func fetchEndpoints(for modelId: String) async -> [ModelEndpoint] {
        endpointsError = nil
        guard let url = URL(string: "https://openrouter.ai/api/v1/models/\(modelId)/endpoints") else {
            return []
        }
        do {
            let (data, response) = try await dataLoader(url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                endpointsError = "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0) loading providers"
                return []
            }
            let decoded = try JSONDecoder().decode(EndpointResponse.self, from: data)
            return decoded.data.endpoints.sorted { ($0.promptCostPer1M ?? .infinity) < ($1.promptCostPer1M ?? .infinity) }
        } catch {
            endpointsError = "Failed to load providers: \(error.localizedDescription)"
            return []
        }
    }
}
