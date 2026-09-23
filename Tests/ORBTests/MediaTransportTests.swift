import Foundation
import Testing
@testable import ORB

// MARK: - Shared mock fixtures (also used by VideoJobLifecycleTests)

/// Thread-safe counter used to prove credentials are never fetched for
/// rejected URLs.
final class MockCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    var current: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// Collector for `onUpdate` callbacks, safe to close over from a
/// `@Sendable` closure.
final class JobUpdateCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var jobs: [VideoJob] = []

    func append(_ job: VideoJob) {
        lock.lock()
        jobs.append(job)
        lock.unlock()
    }

    var all: [VideoJob] {
        lock.lock()
        defer { lock.unlock() }
        return jobs
    }
}

/// Test double for `MediaTransport`: records every request handed to
/// `send` and serves scripted responses. Makes no network request and
/// never touches the Keychain.
final class MockMediaTransport: MediaTransport, @unchecked Sendable {
    enum MockResponse: Sendable {
        case json(String)
        case hang
        /// Additive (W10): a non-2xx HTTP failure. Mirrors the real
        /// `MediaTransport.send` mapping — the documented error envelope's
        /// `message` becomes the thrown message, falling back to the raw body.
        case status(Int, String)
    }

    /// Scripted response for `sendRaw` overrides (raw downloads).
    enum RawMockResponse: Sendable {
        case bytes(Data, String?)
    }

    private let lock = NSLock()
    private var queue: [MockResponse] = []
    private var rawQueue: [RawMockResponse] = []
    private var recorded: [URLRequest] = []
    private var rawRecorded: [URLRequest] = []
    /// Set right after `super.init`; the provider closure captures the same
    /// instance, so assertions read the live count.
    private(set) var keyCounter: MockCallCounter?

    init(responses: [MockResponse], rawResponses: [RawMockResponse] = []) {
        let counter = MockCallCounter()
        super.init(session: URLSession(configuration: .ephemeral), apiKeyProvider: {
            counter.increment()
            return "test-key"
        })
        keyCounter = counter
        lock.lock()
        queue = responses
        rawQueue = rawResponses
        lock.unlock()
    }

    private func next() -> MockResponse {
        lock.lock()
        defer { lock.unlock() }
        guard !queue.isEmpty else { return .json("{}") }
        return queue.removeFirst()
    }

    private func record(_ request: URLRequest) {
        lock.lock()
        recorded.append(request)
        lock.unlock()
    }

    func sentRequests() -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func sentCount() -> Int {
        sentRequests().count
    }

    /// Every request handed to `sendRaw` (downloads), kept separate from
    /// `sentRequests()` so JSON-flow counts stay untouched.
    func sentRawRequests() -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return rawRecorded
    }

    /// Every `POST /videos` submission, to prove none are duplicated.
    func submissions() -> [URLRequest] {
        sentRequests().filter {
            $0.httpMethod == "POST" && $0.url?.path == "/api/v1/videos"
        }
    }

    override func send<T: Decodable>(_ request: URLRequest, as type: T.Type) async throws -> T {
        record(request)
        switch next() {
        case .json(let string):
            do {
                return try JSONDecoder().decode(T.self, from: Data(string.utf8))
            } catch {
                throw MediaServiceError.decoding("Mock fixture decode failed: \(error)")
            }
        case .status(let status, let body):
            if let value = JSONValue.parse(body),
               let message = value.objectValue?["error"]?.objectValue?["message"]?.stringValue {
                throw MediaServiceError.http(status: status, message: message)
            }
            throw MediaServiceError.http(status: status, message: body)
        case .hang:
            try await Task.sleep(for: .seconds(60))
            throw MediaServiceError.transport("Mock hang was not cancelled.")
        }
    }

    private func nextRaw() -> RawMockResponse {
        lock.lock()
        defer { lock.unlock() }
        guard !rawQueue.isEmpty else { return .bytes(Data(), nil) }
        return rawQueue.removeFirst()
    }

    override func sendRaw(_ request: URLRequest) async throws -> (Data, String?) {
        lock.lock()
        rawRecorded.append(request)
        lock.unlock()
        switch nextRaw() {
        case .bytes(let data, let mime):
            return (data, mime)
        }
    }
}

/// Cooperatively waits until `condition` holds or the timeout elapses.
func waitForCondition(
    timeout: Duration = .seconds(5),
    _ condition: @Sendable () -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

@Suite("Media transport URL building", .serialized)
@MainActor
struct MediaTransportTests {
    // MARK: Endpoint URL builder (path/query separation)

    @Test("generation query is kept out of the path")
    func generationQuerySeparation() throws {
        let url = try MediaEndpointURL.url(
            path: "generation",
            queryItems: [URLQueryItem(name: "id", value: "gen-test")]
        )
        #expect(url.absoluteString == "https://openrouter.ai/api/v1/generation?id=gen-test")
        #expect(url.path == "/api/v1/generation")
        #expect(url.query == "id=gen-test")
    }

    @Test("query values are percent-encoded")
    func queryPercentEncoding() throws {
        let url = try MediaEndpointURL.url(
            path: "generation",
            queryItems: [URLQueryItem(name: "id", value: "gen 1&x=2")]
        )
        #expect(url.query == "id=gen%201%26x%3D2")
        #expect(url.path == "/api/v1/generation")
    }

    @Test("path containing '?' or '#' is rejected instead of mis-encoded")
    func queryInPathRejected() {
        #expect(throws: MediaServiceError.self) {
            try MediaEndpointURL.url(path: "generation?id=gen-test")
        }
        #expect(throws: MediaServiceError.self) {
            try MediaEndpointURL.url(path: "generation#fragment")
        }
    }

    @Test("path segments are percent-encoded")
    func pathSegmentEncoding() throws {
        let url = try MediaEndpointURL.url(path: "videos/job 1")
        #expect(url.path == "/api/v1/videos/job 1")
        #expect(url.absoluteString == "https://openrouter.ai/api/v1/videos/job%201")
    }

    @Test("transport request builder attaches auth only to approved URLs")
    func transportRequestBuilder() throws {
        let transport = MockMediaTransport(responses: [])
        let request = try transport.request(
            path: "generation",
            queryItems: [URLQueryItem(name: "id", value: "gen-test")]
        )
        #expect(request.url?.absoluteString == "https://openrouter.ai/api/v1/generation?id=gen-test")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
        #expect(throws: MediaServiceError.self) {
            try transport.request(path: "generation?id=gen-test")
        }
    }

    // MARK: Generation lookup captured end to end

    @Test("generation lookup requests the exact documented path and query")
    func generationLookupCapture() async throws {
        let transport = MockMediaTransport(responses: [
            .json(#"{"data":{"id":"gen-test","model":"openai/gpt-4o","total_cost":0.01}}"#)
        ])
        let service = GenerationService(transport: transport)
        let payload = try await service.fetch(id: "gen-test")
        #expect(payload.totalCost == 0.01)

        let requests = transport.sentRequests()
        #expect(requests.count == 1)
        let url = try #require(requests.first?.url)
        #expect(url.path == "/api/v1/generation")
        #expect(url.query == "id=gen-test")
        #expect(url.absoluteString == "https://openrouter.ai/api/v1/generation?id=gen-test")
        #expect(!url.absoluteString.contains("%3F"))
        #expect(requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
        #expect(url.query?.contains("Bearer") != true)
    }

    // MARK: Polling URL origin policy

    @Test("absolute polling URL on the approved origin resolves to itself")
    func absoluteValidPollingURL() throws {
        let url = try MediaEndpointURL.pollingURL("https://openrouter.ai/api/v1/videos/job-test")
        #expect(url.absoluteString == "https://openrouter.ai/api/v1/videos/job-test")
    }

    @Test("relative and absolute-path polling references resolve against the API base")
    func relativeResolution() throws {
        let relative = try MediaEndpointURL.pollingURL("videos/job-test")
        #expect(relative.absoluteString == "https://openrouter.ai/api/v1/videos/job-test")
        let absolutePath = try MediaEndpointURL.pollingURL("/api/v1/videos/job-test")
        #expect(absolutePath.absoluteString == "https://openrouter.ai/api/v1/videos/job-test")
    }

    @Test("foreign-origin polling URLs are rejected")
    func foreignOriginRejected() {
        #expect(throws: MediaServiceError.self) {
            try MediaEndpointURL.pollingURL("https://evil.example/api/v1/videos/job-test")
        }
        #expect(throws: MediaServiceError.self) {
            try MediaEndpointURL.pollingURL("//evil.example/api/v1/videos/job-test")
        }
    }

    @Test("http downgrade polling URLs are rejected")
    func httpDowngradeRejected() {
        #expect(throws: MediaServiceError.self) {
            try MediaEndpointURL.pollingURL("http://openrouter.ai/api/v1/videos/job-test")
        }
    }

    @Test("other schemes, ports, credentials, and empty paths are rejected")
    func miscRejections() {
        #expect(throws: MediaServiceError.self) {
            try MediaEndpointURL.pollingURL("https://openrouter.ai/other/videos/job-test")
        }
        #expect(throws: MediaServiceError.self) {
            try MediaEndpointURL.pollingURL("https://openrouter.ai/api/v1/")
        }
        #expect(throws: MediaServiceError.self) {
            try MediaEndpointURL.pollingURL("ftp://openrouter.ai/api/v1/videos/job-test")
        }
        #expect(throws: MediaServiceError.self) {
            try MediaEndpointURL.pollingURL("")
        }
        #expect(throws: MediaServiceError.self) {
            try MediaEndpointURL.pollingURL("https://openrouter.ai:8443/api/v1/videos/job-test")
        }
        #expect(throws: MediaServiceError.self) {
            try MediaEndpointURL.pollingURL("https://user:pass@openrouter.ai/api/v1/videos/job-test")
        }
    }

    @Test("dot-segment escapes are rejected")
    func dotSegmentRejected() {
        #expect(throws: MediaServiceError.self) {
            try MediaEndpointURL.pollingURL("https://openrouter.ai/api/v1/../admin")
        }
    }

    @Test("request(url:) validates the origin before fetching or attaching credentials")
    func authNotAttachedToUnapprovedOrigin() {
        let transport = MockMediaTransport(responses: [])
        let evil = URL(string: "https://evil.example/api/v1/videos/x")!
        #expect(throws: MediaServiceError.self) {
            try transport.request(url: evil)
        }
        let downgrade = URL(string: "http://openrouter.ai/api/v1/videos/x")!
        #expect(throws: MediaServiceError.self) {
            try transport.request(url: downgrade)
        }
        // Neither URL ever reached the credential provider.
        #expect(transport.keyCounter?.current == 0)
        #expect(transport.sentRequests().isEmpty)
    }
}
