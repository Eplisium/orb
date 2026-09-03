import Foundation

/// User-configurable network timeouts, persisted to `UserDefaults`.
///
/// All three previously-hardcoded timeouts (fetch tool, OpenRouter request,
/// client connect) now read from here, so slow networks or long-running
/// upstream calls can be tuned in Settings → Advanced without a rebuild.
enum NetworkTimeouts {
    static let defaultFetch: TimeInterval = 30
    static let defaultRequest: TimeInterval = 120
    static let minFetch: TimeInterval = 5
    static let minRequest: TimeInterval = 30
    static let maxFetch: TimeInterval = 300
    static let maxRequest: TimeInterval = 900

    private static let fetchKey = "network.fetchTimeout"
    private static let requestKey = "network.requestTimeout"

    /// Timeout for the agent's `fetch_url` tool, in seconds.
    static var fetch: TimeInterval {
        get {
            let stored = UserDefaults.standard.double(forKey: fetchKey)
            guard stored > 0 else { return defaultFetch }
            return min(max(stored, minFetch), maxFetch)
        }
        set {
            let clamped = min(max(newValue, minFetch), maxFetch)
            UserDefaults.standard.set(clamped, forKey: fetchKey)
        }
    }

    /// Request timeout for OpenRouter API calls (including SSE setup),
    /// in seconds. Long-lived streams are separately protected by the
    /// client's resource timeout, which stays at one hour.
    static var request: TimeInterval {
        get {
            let stored = UserDefaults.standard.double(forKey: requestKey)
            guard stored > 0 else { return defaultRequest }
            return min(max(stored, minRequest), maxRequest)
        }
        set {
            let clamped = min(max(newValue, minRequest), maxRequest)
            UserDefaults.standard.set(clamped, forKey: requestKey)
        }
    }

    /// Resets both values to their defaults.
    static func resetToDefaults() {
        UserDefaults.standard.removeObject(forKey: fetchKey)
        UserDefaults.standard.removeObject(forKey: requestKey)
    }
}
