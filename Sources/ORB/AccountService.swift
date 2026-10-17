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
    /// Bumped whenever the management credential changes or disappears.
    /// In-flight requests capture it and drop their result if it moved, so a
    /// slow response for a replaced/removed key can't publish into the new
    /// (or empty) account state.
    private var credentialGeneration = 0

    private struct FetchFailure: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

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

        let generation = credentialGeneration
        isLoadingCredits = true
        creditsError = nil

        let result: Result<CreditsData, FetchFailure>
        do {
            let (data, response) = try await dataLoader(request)
            if let http = response as? HTTPURLResponse {
                if http.statusCode == 401 {
                    result = .failure(FetchFailure("Management key rejected. Check it in Settings → Accounts & Keys."))
                } else if http.statusCode != 200 {
                    result = .failure(FetchFailure("HTTP \(http.statusCode)"))
                } else {
                    result = .success(try JSONDecoder().decode(CreditsResponse.self, from: data).data)
                }
            } else {
                result = .failure(FetchFailure("Invalid response"))
            }
        } catch {
            result = .failure(FetchFailure(error.localizedDescription))
        }

        // Stale: the credential changed while we waited. The current
        // generation owns the published state and loading flag.
        guard generation == credentialGeneration else { return }
        switch result {
        case .success(let value): credits = value
        case .failure(let failure): creditsError = failure.message
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

        let generation = credentialGeneration
        isLoadingActivity = true
        activityError = nil

        let result: Result<[ActivityItem], FetchFailure>
        do {
            let (data, response) = try await dataLoader(request)
            if let http = response as? HTTPURLResponse {
                if http.statusCode == 401 {
                    result = .failure(FetchFailure("Management key rejected. Check it in Settings → Accounts & Keys."))
                } else if http.statusCode != 200 {
                    result = .failure(FetchFailure("HTTP \(http.statusCode)"))
                } else {
                    let decoded = try JSONDecoder().decode(ActivityResponse.self, from: data)
                    result = .success(decoded.data.sorted { $0.date > $1.date })
                }
            } else {
                result = .failure(FetchFailure("Invalid response"))
            }
        } catch {
            result = .failure(FetchFailure(error.localizedDescription))
        }

        guard generation == credentialGeneration else { return }
        switch result {
        case .success(let value): activity = value
        case .failure(let failure): activityError = failure.message
        }
        isLoadingActivity = false
    }

    // MARK: - Management key lifecycle

    /// Invalidates in-flight requests and clears everything published from
    /// the previous credential, including loading flags (the stale request
    /// will no longer clear them, and a new request sets them itself).
    private func invalidateAccountState() {
        credentialGeneration &+= 1
        credits = nil
        activity = []
        creditsError = nil
        activityError = nil
        isLoadingCredits = false
        isLoadingActivity = false
    }

    private var storeHasManagementKey: Bool {
        profile.managementKeyReference.map { secretStore.hasSecret(forReference: $0) } ?? false
    }

    /// Re-reads (existence-only, prompt-free) whether a management key is
    /// stored, e.g. after it was saved from another window.
    func refreshManagementKeyPresence() {
        let present = storeHasManagementKey
        if present != hasManagementKey { hasManagementKey = present }
        if !present { invalidateAccountState() }
    }

    /// Saves a management key. A failed save leaves the previous key (and its
    /// published data and in-flight requests) intact.
    @discardableResult
    func setManagementKey(_ key: String) -> String? {
        let reference = profile.managementKeyReference ?? CredentialRole.management.keychainAccount
        let error = secretStore.saveSecret(key, forReference: reference)
        if error == nil {
            invalidateAccountState() // new credential = new account data
            hasManagementKey = true
        } else {
            hasManagementKey = storeHasManagementKey // old key may still be there
        }
        return error
    }

    /// Removes the management key. Returns nil on verified removal, or an
    /// error message when the credential may still exist — in which case
    /// nothing is cleared and `hasManagementKey` still reflects reality.
    /// On success published data is cleared immediately and in-flight
    /// requests are invalidated.
    @discardableResult
    func removeManagementKey() -> String? {
        let reference = profile.managementKeyReference ?? CredentialRole.management.keychainAccount
        let deleted = secretStore.deleteSecret(forReference: reference)
        if !deleted || secretStore.hasSecret(forReference: reference) {
            hasManagementKey = storeHasManagementKey
            return "The management key could not be removed from Keychain. It may still be stored."
        }
        invalidateAccountState()
        hasManagementKey = false
        return nil
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
