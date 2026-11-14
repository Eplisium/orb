import Foundation

// MARK: - Update check (public GitHub releases, no credentials)
//
// "Check for Updates…" and an optional once-a-day background check ask the
// PUBLIC GitHub API for the newest release of Eplisium/orb and compare it with
// this build's CFBundleShortVersionString. Nothing is downloaded or installed:
// a newer release shows a non-modal toast with a link to its page. No token,
// cookie or OpenRouter credential is ever attached. A repository with no
// releases yet (404) is not an error.

/// `MAJOR.MINOR.PATCH[-prerelease]`, tolerant of a leading "v" and of
/// missing minor/patch components ("1.2" == "1.2.0").
struct SemanticVersion: Comparable, Equatable, CustomStringConvertible, Sendable {
    let major: Int
    let minor: Int
    let patch: Int
    /// nil for a release; a prerelease sorts before the same release.
    let prerelease: String?

    init(major: Int, minor: Int = 0, patch: Int = 0, prerelease: String? = nil) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
    }

    init?(_ raw: String) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.first == "v" || text.first == "V" { text.removeFirst() }
        // Build metadata never affects precedence.
        if let plus = text.firstIndex(of: "+") { text = String(text[..<plus]) }
        var pre: String?
        if let dash = text.firstIndex(of: "-") {
            pre = String(text[text.index(after: dash)...])
            text = String(text[..<dash])
            if pre?.isEmpty == true { return nil }
        }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy(\.isASCII), let value = Int(part), value >= 0 else { return nil }
            numbers.append(value)
        }
        while numbers.count < 3 { numbers.append(0) }
        self.init(major: numbers[0], minor: numbers[1], patch: numbers[2], prerelease: pre)
    }

    var description: String {
        "\(major).\(minor).\(patch)" + (prerelease.map { "-\($0)" } ?? "")
    }

    static func < (a: SemanticVersion, b: SemanticVersion) -> Bool {
        if a.major != b.major { return a.major < b.major }
        if a.minor != b.minor { return a.minor < b.minor }
        if a.patch != b.patch { return a.patch < b.patch }
        switch (a.prerelease, b.prerelease) {
        case (nil, nil), (nil, _?): return false
        case (_?, nil): return true
        case let (x?, y?): return comparePrerelease(x, y)
        }
    }

    /// SemVer 2.0 §11: dot-separated identifiers, numeric ones numerically
    /// and below alphanumeric ones; a shorter list sorts first on a tie.
    private static func comparePrerelease(_ a: String, _ b: String) -> Bool {
        let x = a.split(separator: "."), y = b.split(separator: ".")
        for (l, r) in zip(x, y) where l != r {
            switch (Int(l), Int(r)) {
            case let (li?, ri?): return li < ri
            case (_?, nil): return true
            case (nil, _?): return false
            default: return l < r
            }
        }
        return x.count < y.count
    }
}

struct ReleaseInfo: Equatable, Sendable {
    let tag: String
    let version: SemanticVersion
    let name: String
    let pageURL: URL
}

enum UpdateCheckResult: Equatable, Sendable {
    case upToDate(current: String)
    case available(ReleaseInfo)
    /// The repository has no published release yet (HTTP 404).
    case noReleases
    case failed(String)

    var summary: String {
        switch self {
        case .upToDate(let current): return "ORB \(current) is the latest version."
        case .available(let release): return "ORB \(release.version) is available."
        case .noReleases: return "No releases have been published yet."
        case .failed(let reason): return "Couldn't check for updates: \(reason)"
        }
    }
}

/// One unauthenticated GET. Injected so tests never touch the network.
protocol UpdateTransport: Sendable {
    func get(_ request: URLRequest) async throws -> (Data, Int)
}

struct URLSessionUpdateTransport: UpdateTransport {
    func get(_ request: URLRequest) async throws -> (Data, Int) {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 15
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    static let latestReleaseURL = URL(string: "https://api.github.com/repos/Eplisium/orb/releases/latest")!
    static let autoCheckKey = "orb.updates.autoCheck"
    static let lastCheckKey = "orb.updates.lastCheck"
    /// The newest version a background check already announced, so the same
    /// release is not toasted every day.
    static let announcedKey = "orb.updates.announcedVersion"
    static let checkInterval: TimeInterval = 24 * 60 * 60

    @Published private(set) var isChecking = false
    @Published private(set) var lastResult: UpdateCheckResult?

    let currentVersion: String
    private let transport: any UpdateTransport
    private let defaults: UserDefaults
    private let now: () -> Date
    private let announce: @MainActor (ReleaseInfo) -> Void
    private let report: @MainActor (UpdateCheckResult) -> Void

    init(
        currentVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0",
        transport: any UpdateTransport = URLSessionUpdateTransport(),
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init,
        announce: @escaping @MainActor (ReleaseInfo) -> Void = UpdateChecker.toastAvailable,
        report: @escaping @MainActor (UpdateCheckResult) -> Void = UpdateChecker.toastResult
    ) {
        self.currentVersion = currentVersion
        self.transport = transport
        self.defaults = defaults
        self.now = now
        self.announce = announce
        self.report = report
    }

    /// Default ON; Settings → General → Updates turns it off.
    var automaticallyChecks: Bool {
        get { defaults.object(forKey: Self.autoCheckKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Self.autoCheckKey); objectWillChange.send() }
    }

    var lastCheckDate: Date? { defaults.object(forKey: Self.lastCheckKey) as? Date }

    func isDue(at date: Date) -> Bool {
        guard automaticallyChecks else { return false }
        guard let last = lastCheckDate else { return true }
        return date.timeIntervalSince(last) >= Self.checkInterval || date < last
    }

    /// "Check for Updates…": always asks, always reports the outcome.
    @discardableResult
    func checkNow() async -> UpdateCheckResult {
        let result = await check()
        report(result)
        return result
    }

    /// Launch/daily check: silent unless a release this Mac hasn't been told
    /// about yet is available. Failures and "no releases" stay quiet.
    @discardableResult
    func checkIfDue() async -> UpdateCheckResult? {
        guard isDue(at: now()) else { return nil }
        let result = await check()
        if case .available(let release) = result,
           defaults.string(forKey: Self.announcedKey) != release.version.description {
            defaults.set(release.version.description, forKey: Self.announcedKey)
            announce(release)
        }
        return result
    }

    /// Runs `checkIfDue` now and then about once a day while ORB is open.
    func startBackgroundChecks() {
        guard backgroundTask == nil else { return }
        backgroundTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkIfDue()
                try? await Task.sleep(for: .seconds(60 * 60))
            }
        }
    }

    private var backgroundTask: Task<Void, Never>?

    func check() async -> UpdateCheckResult {
        if isChecking, let lastResult { return lastResult }
        isChecking = true
        defer { isChecking = false }
        let result = await fetch()
        // Only a completed round trip counts as "checked" for the daily timer.
        if case .failed = result {} else { defaults.set(now(), forKey: Self.lastCheckKey) }
        lastResult = result
        return result
    }

    private func fetch() async -> UpdateCheckResult {
        guard let current = SemanticVersion(currentVersion) else {
            return .failed("this build has no version number")
        }
        var request = URLRequest(url: Self.latestReleaseURL)
        request.httpMethod = "GET"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("ORB/\(currentVersion) (macOS update check)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, status) = try await transport.get(request)
            switch status {
            case 200:
                let release = try Self.parse(data)
                return release.version > current ? .available(release) : .upToDate(current: currentVersion)
            case 404:
                return .noReleases
            case 403, 429:
                return .failed("GitHub is rate-limiting requests. Try again later.")
            default:
                return .failed("GitHub returned HTTP \(status).")
            }
        } catch let error as UpdateParseError {
            return .failed(error.message)
        } catch {
            return .failed("the network request did not complete.")
        }
    }

    struct UpdateParseError: Error, Equatable { let message: String }

    /// Reads `tag_name`, `name` and `html_url`; the page must be on github.com.
    nonisolated static func parse(_ data: Data) throws -> ReleaseInfo {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = object["tag_name"] as? String else {
            throw UpdateParseError(message: "GitHub's reply was not understood.")
        }
        guard let version = SemanticVersion(tag) else {
            throw UpdateParseError(message: "the latest release tag “\(tag.prefix(40))” is not a version number.")
        }
        let fallback = ORBProjectLinks.releases.appendingPathComponent("tag").appendingPathComponent(tag)
        var page = fallback
        if let raw = object["html_url"] as? String, let url = URL(string: raw),
           url.scheme == "https", url.host == "github.com" {
            page = url
        }
        let name = (object["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? tag
        return ReleaseInfo(tag: tag, version: version, name: name, pageURL: page)
    }

    // MARK: Presentation (non-modal)

    static func toastAvailable(_ release: ReleaseInfo) {
        AppToasts.center.show(
            "ORB \(release.version) is available.",
            kind: .info,
            duration: 15,
            link: ORBToastLink(title: "View Release", url: release.pageURL)
        )
    }

    static func toastResult(_ result: UpdateCheckResult) {
        switch result {
        case .available(let release):
            toastAvailable(release)
        case .upToDate, .noReleases:
            AppToasts.center.show(result.summary, kind: .success, duration: 4)
        case .failed:
            AppToasts.center.show(result.summary, kind: .warning)
        }
    }
}
