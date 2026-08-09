import Foundation

@MainActor
final class APIService: ObservableObject {
    @Published var models: [ModelInfo] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var lastRefresh: Date?
    @Published var endpointsError: String?

    private let modelsURL = URL(string: "https://openrouter.ai/api/v1/models")!

    /// Local cache path for the models list — enables instant startup on subsequent launches.
    private let cacheURL: URL = {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("OpenRouterBrowser", isDirectory: true)
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        return appDir.appendingPathComponent("models_cache.json")
    }()

    /// Cache the models response for 5 minutes. If the network fails, fall back to cache regardless of age.
    private let cacheMaxAge: TimeInterval = 300

    func fetchModels() async {
        isLoading = true
        errorMessage = nil

        // Try to load from cache first for instant display
        if hasValidCache {
            loadFromCache()
            lastRefresh = cacheDate
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: modelsURL)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                if models.isEmpty {
                    errorMessage = "HTTP error fetching models"
                }
                isLoading = false
                return
            }

            let decoded = try JSONDecoder().decode(OpenRouterResponse.self, from: data)
            models = decoded.data.sorted { $0.name < $1.name }
            lastRefresh = Date()
            saveToCache(data: data)
        } catch {
            if models.isEmpty {
                errorMessage = "Failed to load: \(error.localizedDescription)"
            }
            // If we have cached data, silently keep it — no error shown
        }

        isLoading = false
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
            let (data, response) = try await URLSession.shared.data(from: url)
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
