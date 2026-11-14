import Foundation
import Combine

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
    /// Public refresh identity for views; never contains credential bytes.
    @Published private(set) var credentialRevision = UUID()
    /// When `/credits` last answered successfully for the current key.
    @Published private(set) var lastCreditsFetch: Date?

    /// A balance older than this is refetched when ORB regains focus.
    static let creditsTTL: TimeInterval = 60
    /// Spending (a new ledger revision) refetches at most this often.
    static let spendRefreshInterval: TimeInterval = 10
    private var lastLedgerRevisionSeen: Int?

    typealias DataLoader = (URLRequest) async throws -> (Data, URLResponse)

    private let baseURL = "https://openrouter.ai/api/v1"
    private let profile: CredentialProfile
    private let secretStore: CredentialSecretStore
    private let dataLoader: DataLoader
    private let now: () -> Date
    /// Bumped whenever the management credential changes or disappears.
    /// In-flight requests capture it and drop their result if it moved, so a
    /// slow response for a replaced/removed key can't publish into the new
    /// (or empty) account state.
    private var credentialGeneration = 0
    private var observedStoreRevision: UUID?
    private var credentialObservation: AnyCancellable?

    private struct FetchFailure: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    init(
        profile: CredentialProfile = CredentialProfile(
            managementKeyReference: CredentialRole.management.keychainAccount
        ),
        secretStore: CredentialSecretStore = KeychainCredentialStore(),
        dataLoader: @escaping DataLoader = { try await URLSession.shared.data(for: $0) },
        now: @escaping () -> Date = Date.init
    ) {
        self.now = now
        self.profile = profile
        self.secretStore = secretStore
        self.dataLoader = dataLoader
        self.hasManagementKey = profile.managementKeyReference.map {
            secretStore.hasSecret(forReference: $0)
        } ?? false
        if let reference = profile.managementKeyReference, let changes = secretStore.credentialChanges {
            observedStoreRevision = changes.revision(for: reference)
            credentialObservation = changes.publisher.sink { @Sendable [weak self] changedReference in
                guard changedReference == reference else { return }
                // Settings writes happen on the main actor: clear other
                // windows synchronously, before their next render. Background
                // writers hop to it; fetch completion also checks revisions.
                if Thread.isMainThread {
                    MainActor.assumeIsolated { self?.refreshManagementKeyPresence() }
                } else {
                    Task { @MainActor [weak self] in self?.refreshManagementKeyPresence() }
                }
            }
        }
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
        refreshManagementKeyPresence()
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
        refreshManagementKeyPresence()
        guard generation == credentialGeneration else { return }
        switch result {
        case .success(let value):
            credits = value
            lastCreditsFetch = now()
        case .failure(let failure): creditsError = failure.message
        }
        isLoadingCredits = false
    }

    /// Whether the sidebar balance should be refetched now.
    /// - Parameter ledgerRevision: `UsageLedger.revision`; a change means ORB
    ///   just recorded spend, so the balance is out of date — but at most
    ///   once per `spendRefreshInterval`, so a burst of requests is one fetch.
    func shouldRefreshCredits(now date: Date, ledgerRevision: Int? = nil) -> Bool {
        guard hasManagementKey, !isLoadingCredits else { return false }
        guard let last = lastCreditsFetch, credits != nil else { return true }
        let age = date.timeIntervalSince(last)
        if let ledgerRevision, let seen = lastLedgerRevisionSeen, ledgerRevision != seen {
            return age >= Self.spendRefreshInterval || age < 0
        }
        return age >= Self.creditsTTL || age < 0
    }

    /// Records the ledger revision the current balance already reflects.
    func noteLedgerRevision(_ revision: Int) { lastLedgerRevisionSeen = revision }

    /// True while the balance predates spend ORB has recorded since.
    func balanceLags(ledgerRevision: Int) -> Bool {
        lastLedgerRevisionSeen.map { $0 != ledgerRevision } ?? false
    }

    /// Fetches credits when `shouldRefreshCredits` says so.
    func refreshCreditsIfStale(ledgerRevision: Int? = nil) async {
        guard shouldRefreshCredits(now: now(), ledgerRevision: ledgerRevision) else { return }
        if let ledgerRevision { lastLedgerRevisionSeen = ledgerRevision }
        await fetchCredits()
    }

    // MARK: - Activity

    func fetchActivity() async {
        refreshManagementKeyPresence()
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

        refreshManagementKeyPresence()
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
        credentialRevision = UUID()
        credits = nil
        lastCreditsFetch = nil
        activity = []
        creditsError = nil
        activityError = nil
        isLoadingCredits = false
        isLoadingActivity = false
    }

    private var storeHasManagementKey: Bool {
        profile.managementKeyReference.map { secretStore.hasSecret(forReference: $0) } ?? false
    }

    /// Reconciles presence AND the shared store revision. Presence alone
    /// cannot distinguish a replacement account from the previous one.
    func refreshManagementKeyPresence() {
        let revision = profile.managementKeyReference.flatMap {
            secretStore.credentialChanges?.revision(for: $0)
        }
        let present = storeHasManagementKey
        if revision != observedStoreRevision || present != hasManagementKey {
            observedStoreRevision = revision
            invalidateAccountState()
        }
        hasManagementKey = present
    }

    /// Saves a management key. A failed save leaves the previous key (and its
    /// published data and in-flight requests) intact.
    @discardableResult
    func setManagementKey(_ key: String) -> String? {
        let reference = profile.managementKeyReference ?? CredentialRole.management.keychainAccount
        let generation = credentialGeneration
        let error = secretStore.saveSecret(key, forReference: reference)
        if error == nil {
            refreshManagementKeyPresence()
            // Custom stores without a revision source still invalidate the
            // initiating service; observable stores already did so above.
            if generation == credentialGeneration { invalidateAccountState() }
            hasManagementKey = storeHasManagementKey
        } else {
            hasManagementKey = storeHasManagementKey // old key may still be there
        }
        return error
    }

    /// Removes the management key. Returns nil on verified removal, or an
    /// error message when the credential may still exist. A failed write
    /// preserves state; a successful write with uncertain verification still
    /// invalidates old account data through the shared revision source.
    @discardableResult
    func removeManagementKey() -> String? {
        let reference = profile.managementKeyReference ?? CredentialRole.management.keychainAccount
        let generation = credentialGeneration
        let deleted = secretStore.deleteSecret(forReference: reference)
        if !deleted || secretStore.hasSecret(forReference: reference) {
            hasManagementKey = storeHasManagementKey
            return "The management key could not be removed from Keychain. It may still be stored."
        }
        refreshManagementKeyPresence()
        if generation == credentialGeneration { invalidateAccountState() }
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
