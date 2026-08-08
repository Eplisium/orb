import Foundation

@MainActor
final class APIService: ObservableObject {
    @Published var models: [ModelInfo] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var lastRefresh: Date?

    private let url = URL(string: "https://openrouter.ai/api/v1/models")!

    func fetchModels() async {
        isLoading = true
        errorMessage = nil

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                errorMessage = "HTTP error fetching models"
                isLoading = false
                return
            }

            let decoded = try JSONDecoder().decode(OpenRouterResponse.self, from: data)
            models = decoded.data.sorted { $0.name < $1.name }
            lastRefresh = Date()
        } catch {
            errorMessage = "Failed to load: \(error.localizedDescription)"
        }

        isLoading = false
    }

    func fetchEndpoints(for modelId: String) async -> [ModelEndpoint] {
        guard let url = URL(string: "https://openrouter.ai/api/v1/models/\(modelId)/endpoints") else {
            return []
        }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return [] }
            let decoded = try JSONDecoder().decode(EndpointResponse.self, from: data)
            return decoded.data.endpoints.sorted { ($0.promptCostPer1M ?? .infinity) < ($1.promptCostPer1M ?? .infinity) }
        } catch {
            return []
        }
    }

    // Cross-reference multiple endpoints in parallel (capped to avoid hammering)
    func fetchEndpoints(_ modelIds: [String], max: Int = 6) async -> [ModelEndpoint] {
        let ids = Array(modelIds.prefix(max))
        var all: [ModelEndpoint] = []
        for id in ids {
            let eps = await fetchEndpoints(for: id)
            if !eps.isEmpty {
                all.append(contentsOf: eps)
            }
        }
        return all
    }
}
