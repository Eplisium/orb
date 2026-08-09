import Foundation

/// Service for authenticated OpenRouter API calls: credits, activity, generation stats.
@MainActor
final class AccountService: ObservableObject {
    @Published var credits: CreditsData?
    @Published var activity: [ActivityItem] = []
    @Published var isLoadingCredits = false
    @Published var isLoadingActivity = false
    @Published var creditsError: String?
    @Published var activityError: String?

    private let baseURL = "https://openrouter.ai/api/v1"

    /// Build an authenticated URLRequest.
    private func authenticatedRequest(url: URL, method: String = "GET") -> URLRequest? {
        guard let key = KeychainManager.getAPIKey() else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("OpenRouterBrowser", forHTTPHeaderField: "HTTP-Referer")
        request.setValue("OpenRouterBrowser", forHTTPHeaderField: "X-OpenRouter-Title")
        return request
    }

    // MARK: - Credits

    func fetchCredits() async {
        guard let url = URL(string: "\(baseURL)/credits"),
              let request = authenticatedRequest(url: url) else {
            creditsError = "No API key configured"
            return
        }

        isLoadingCredits = true
        creditsError = nil

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                creditsError = "Invalid response"
                isLoadingCredits = false
                return
            }

            if http.statusCode == 401 {
                creditsError = "Invalid API key"
                isLoadingCredits = false
                return
            }

            guard http.statusCode == 200 else {
                creditsError = "HTTP \(http.statusCode)"
                isLoadingCredits = false
                return
            }

            let decoded = try JSONDecoder().decode(CreditsResponse.self, from: data)
            credits = decoded.data
        } catch {
            creditsError = error.localizedDescription
        }

        isLoadingCredits = false
    }

    // MARK: - Activity

    func fetchActivity() async {
        guard let url = URL(string: "\(baseURL)/activity"),
              let request = authenticatedRequest(url: url) else {
            activityError = "No API key configured"
            return
        }

        isLoadingActivity = true
        activityError = nil

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                activityError = "Invalid response"
                isLoadingActivity = false
                return
            }

            if http.statusCode == 401 {
                activityError = "Invalid API key"
                isLoadingActivity = false
                return
            }

            guard http.statusCode == 200 else {
                activityError = "HTTP \(http.statusCode)"
                isLoadingActivity = false
                return
            }

            let decoded = try JSONDecoder().decode(ActivityResponse.self, from: data)
            activity = decoded.data.sorted { $0.date > $1.date }
        } catch {
            activityError = error.localizedDescription
        }

        isLoadingActivity = false
    }

    // MARK: - Computed summaries

    var totalSpend: Double {
        activity.reduce(0) { $0 + $1.usage }
    }

    var totalRequests: Int {
        activity.reduce(0) { $0 + $1.requests }
    }

    var topModels: [(model: String, usage: Double, requests: Int)] {
        var dict: [String: (usage: Double, requests: Int)] = [:]
        for item in activity {
            let existing = dict[item.model] ?? (0, 0)
            dict[item.model] = (existing.0 + item.usage, existing.1 + item.requests)
        }
        return dict.map { (model: $0.key, usage: $0.value.usage, requests: $0.value.requests) }
            .sorted { $0.usage > $1.usage }
    }

    var dailySpend: [(date: String, amount: Double)] {
        var dict: [String: Double] = [:]
        for item in activity {
            dict[item.date, default: 0] += item.usage
        }
        return dict.map { (date: $0.key, amount: $0.value) }
            .sorted { $0.date > $1.date }
    }
}
