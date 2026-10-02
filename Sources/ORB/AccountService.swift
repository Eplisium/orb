import Foundation

/// Service for authenticated OpenRouter API calls: credits and activity.
///
/// Credential roles are explicit: credits and activity are management-key
/// operations per OpenRouter's current contract, and inference keys are
/// prohibited from them. When no management key is configured the panels lock
/// with an actionable message and inference (chat) is unaffected.
@MainActor
final class AccountService: ObservableObject {
    @Published var credits: CreditsData?
    @Published var activity: [ActivityItem] = []
    @Published var isLoadingCredits = false
    @Published var isLoadingActivity = false
    @Published var creditsError: String?
    @Published var activityError: String?
    @Published var hasManagementKey = false

    typealias DataLoader = (URLRequest) async throws -> (Data, URLResponse)

    private let baseURL = "https://openrouter.ai/api/v1"
    private let profile: CredentialProfile
    private let secretStore: CredentialSecretStore
    private let dataLoader: DataLoader

    init(
        profile: CredentialProfile = CredentialProfile(
            managementKeyReference: CredentialRole.management.keychainAccount
        ),
        secretStore: CredentialSecretStore = KeychainCredentialStore(),
        dataLoader: @escaping DataLoader = { try await URLSession.shared.data(for: $0) }
    ) {
        self.profile = profile
        self.secretStore = secretStore
        self.dataLoader = dataLoader
        self.hasManagementKey = profile.managementKeyReference.map {
            secretStore.hasSecret(forReference: $0)
        } ?? false
    }

    // MARK: - Role-routed requests

    /// Builds a request authorized for the given role's secret. Returns nil
    /// when the role has no key configured — callers must surface an
    /// actionable message instead of falling back to another role's key.
    private func authenticatedRequest(url: URL, method: String = "GET", role: CredentialRole) -> URLRequest? {
        guard let key = CredentialRouter.secret(for: role, profile: profile, store: secretStore) else {
            return nil
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // F12: no HTTP-Referer until an owner-approved URL exists.
        request.setValue("ORB", forHTTPHeaderField: "X-OpenRouter-Title")
        return request
    }

    // MARK: - Credits

    func fetchCredits() async {
        guard let url = URL(string: "\(baseURL)/credits"),
              let request = authenticatedRequest(url: url, role: .management) else {
            credits = nil
            creditsError = "Management key required. Account-wide credits need a management key — add one in Settings → Accounts & Keys. Your inference key still works for chat."
            return
        }

        isLoadingCredits = true
        creditsError = nil

        do {
            let (data, response) = try await dataLoader(request)
            guard let http = response as? HTTPURLResponse else {
                creditsError = "Invalid response"
                isLoadingCredits = false
                return
            }

            if http.statusCode == 401 {
                creditsError = "Management key rejected. Check it in Settings → Accounts & Keys."
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
              let request = authenticatedRequest(url: url, role: .management) else {
            activity = []
            activityError = "Management key required. Usage history needs a management key — add one in Settings → Accounts & Keys. Your inference key still works for chat."
            return
        }

        isLoadingActivity = true
        activityError = nil

        do {
            let (data, response) = try await dataLoader(request)
            guard let http = response as? HTTPURLResponse else {
                activityError = "Invalid response"
                isLoadingActivity = false
                return
            }

            if http.statusCode == 401 {
                activityError = "Management key rejected. Check it in Settings → Accounts & Keys."
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

    // MARK: - Management key lifecycle

    /// Re-reads (existence-only, prompt-free) whether a management key is
    /// stored, e.g. after it was saved from another window.
    func refreshManagementKeyPresence() {
        let present = profile.managementKeyReference.map { secretStore.hasSecret(forReference: $0) } ?? false
        if present != hasManagementKey { hasManagementKey = present }
        if !present { credits = nil }
    }

    /// Saves a management key. A failed save leaves the previous key intact.
    @discardableResult
    func setManagementKey(_ key: String) -> String? {
        let reference = profile.managementKeyReference ?? CredentialRole.management.keychainAccount
        let error = secretStore.saveSecret(key, forReference: reference)
        hasManagementKey = (error == nil)
        return error
    }

    /// Removes the management key and immediately clears published account
    /// data so nothing from the removed credential flashes on screen.
    func removeManagementKey() {
        let reference = profile.managementKeyReference ?? CredentialRole.management.keychainAccount
        _ = secretStore.deleteSecret(forReference: reference)
        hasManagementKey = false
        credits = nil
        activity = []
        creditsError = nil
        activityError = nil
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
