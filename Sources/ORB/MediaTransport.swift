import Foundation

// MARK: - Dedicated media-generation APIs
//
// Chat completions cover text, but OpenRouter ships separate routers for
// image generation (`POST /images`), video (`POST /videos` + polling),
// speech synthesis (`POST /audio/speech`), transcription
// (`POST /audio/transcriptions`), embeddings (`POST /embeddings`), and
// reranking (`POST /rerank`). This service owns all of them so ChatService
// stays focused on the streaming chat loop.

// MARK: - Shared authenticated transport

/// Builds `/api/v1` endpoint URLs and enforces the exact origin policy for
/// caller-supplied polling references.
///
/// Path components and query items are kept strictly separate. Path segments
/// are percent-encoded individually, and a path containing `?` or `#` is
/// rejected instead of being silently folded into the path (which
/// historically produced `/generation%3Fid=…`). `pollingURL(_:base:)`
/// resolves a supplied polling reference (absolute URL, absolute path, or
/// relative reference) and validates it before any credential may be
/// attached.
enum MediaEndpointURL {
    /// Canonical API base for every authenticated media request.
    static let apiBase = URL(string: "https://openrouter.ai/api/v1")!
    static let allowedHost = "openrouter.ai"
    static let allowedPathPrefix = "/api/v1/"

    static func url(path: String, queryItems: [URLQueryItem] = [], base: URL = apiBase) throws -> URL {
        guard !path.isEmpty, !path.contains("?"), !path.contains("#") else {
            throw MediaServiceError.invalidPath(path)
        }
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~!$&'()*+,;=:@")
        let encoded = path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map { segment -> String in
                let raw = String(segment).removingPercentEncoding ?? String(segment)
                return raw.addingPercentEncoding(withAllowedCharacters: allowed) ?? raw
            }
            .joined(separator: "/")
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        if !encoded.isEmpty {
            components.percentEncodedPath = components.percentEncodedPath + "/" + encoded
        }
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        guard let url = components.url else {
            throw MediaServiceError.invalidPath(path)
        }
        return url
    }

    /// Resolves a polling reference against the API base and validates the
    /// exact policy before any credential is attached: HTTPS, host
    /// `openrouter.ai`, standard port, no user info, and a path under
    /// `/api/v1/`. Anything else throws `MediaServiceError.untrustedURL`.
    static func pollingURL(_ reference: String, base: URL = apiBase) throws -> URL {
        let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw MediaServiceError.untrustedURL(reference)
        }
        if let candidate = URL(string: trimmed), candidate.scheme != nil {
            return try validate(candidate, original: reference)
        }
        let resolutionBase = URL(
            string: base.absoluteString.hasSuffix("/") ? base.absoluteString : base.absoluteString + "/"
        )!
        guard let resolved = URL(string: trimmed, relativeTo: resolutionBase) else {
            throw MediaServiceError.untrustedURL(reference)
        }
        return try validate(resolved.absoluteURL, original: reference)
    }

    /// Validates that `url` is an approved API origin. Callers must invoke
    /// this before attaching any bearer credential to a request.
    static func validate(_ url: URL, original: String) throws -> URL {
        func reject() -> MediaServiceError { .untrustedURL(original) }
        guard url.scheme?.lowercased() == "https" else { throw reject() }
        guard url.host?.lowercased() == allowedHost else { throw reject() }
        guard url.port == nil || url.port == 443 else { throw reject() }
        guard url.user == nil, url.password == nil else { throw reject() }
        guard url.path.hasPrefix(allowedPathPrefix), url.path.count > allowedPathPrefix.count else {
            throw reject()
        }
        let segments = url.path.split(separator: "/")
        guard !segments.contains(where: { $0 == "." || $0 == ".." }) else { throw reject() }
        return url
    }
}

/// Minimal authenticated JSON client shared by every dedicated media API.
/// Every method throws `MediaServiceError` — never a raw URL error — so the
/// UI can show one coherent failure shape.
/// `open` only so tests can inject a recording double that overrides
/// `send`; the request builders themselves stay shared with production.
open class MediaTransport: @unchecked Sendable {
    private let session: URLSession
    private let baseURL = MediaEndpointURL.apiBase
    private let apiKeyProvider: @Sendable () throws -> String

    init(session: URLSession = .shared, apiKeyProvider: (@Sendable () throws -> String)? = nil) {
        self.session = session
        self.apiKeyProvider = apiKeyProvider ?? Self.defaultAPIKeyProvider
    }

    private static let defaultAPIKeyProvider: @Sendable () throws -> String = {
        guard let key = KeychainManager.getAPIKey(), !key.isEmpty else {
            throw MediaServiceError.missingAPIKey
        }
        return key
    }

    func apiKey() throws -> String { try apiKeyProvider() }

    /// Builds a request for an already-validated absolute URL. The origin
    /// policy is re-checked here so the bearer token can never be attached
    /// to an unapproved origin; validation happens before the credential is
    /// fetched and attached.
    func request(url: URL, method: String = "GET", body: Data? = nil) throws -> URLRequest {
        let approved = try MediaEndpointURL.validate(url, original: url.absoluteString)
        var request = URLRequest(url: approved, timeoutInterval: NetworkTimeouts.request)
        request.httpMethod = method
        request.setValue("Bearer \(try apiKey())", forHTTPHeaderField: "Authorization")
        // F12: no HTTP-Referer is sent — optional URL attribution stays
        // omitted until there is an owner-approved URL. The documented
        // display name is kept.
        request.setValue("ORB", forHTTPHeaderField: "X-OpenRouter-Title")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    /// Builds a request from a canonical path plus explicit query items.
    /// Path components and query items stay strictly separate: `path` must
    /// not contain `?` or `#`, and query values are percent-encoded.
    func request(path: String, queryItems: [URLQueryItem] = [], method: String = "GET", body: Data? = nil) throws -> URLRequest {
        try request(url: MediaEndpointURL.url(path: path, queryItems: queryItems, base: baseURL), method: method, body: body)
    }

    /// Sends the request and decodes a `Decodable` body, mapping HTTP
    /// failures to typed `MediaServiceError` cases.
    open func send<T: Decodable>(_ request: URLRequest, as type: T.Type = T.self) async throws -> T {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            // A locally-cancelled request must surface as CancellationError,
            // never as a transport failure.
            throw CancellationError()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw MediaServiceError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw MediaServiceError.transport("Invalid response from OpenRouter.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw MediaServiceError.http(status: http.statusCode, message: Self.errorMessage(from: data))
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw MediaServiceError.decoding(error.localizedDescription)
        }
    }

    /// Sends the request and returns raw bytes (audio/video downloads).
    /// `open` so tests can capture credential-free download requests.
    open func sendRaw(_ request: URLRequest) async throws -> (Data, String?) {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            // A locally-cancelled request must surface as CancellationError,
            // never as a transport failure.
            throw CancellationError()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw MediaServiceError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw MediaServiceError.transport("Invalid response from OpenRouter.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw MediaServiceError.http(status: http.statusCode, message: Self.errorMessage(from: data))
        }
        return (data, http.value(forHTTPHeaderField: "Content-Type"))
    }

    private static func errorMessage(from data: Data) -> String {
        if let envelope = try? JSONDecoder().decode(MediaErrorEnvelope.self, from: data) {
            return envelope.error.message
        }
        let text = String(decoding: data.prefix(512), as: UTF8.self)
        return text.isEmpty ? "Unknown error" : text
    }
}

private struct MediaErrorEnvelope: Decodable {
    struct Body: Decodable { let message: String }
    let error: Body
}

enum MediaServiceError: Error, LocalizedError, Equatable {
    case missingAPIKey
    /// A request path contained query/fragment separators (`?`/`#`); paths
    /// and query items must be supplied separately.
    case invalidPath(String)
    /// A caller-supplied polling URL failed the exact origin policy.
    case untrustedURL(String)
    case http(status: Int, message: String)
    case transport(String)
    case decoding(String)
    /// A media/file request was rejected locally (before any request was
    /// sent) — e.g. an empty or oversized file upload.
    case invalidUpload(String)
    /// A destructive operation was invoked without the explicit
    /// confirmation the service layer requires.
    case deleteNotConfirmed(String)
    /// A durable job record cannot be resumed (no remote ID, or already
    /// terminal).
    case resumeUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Add your OpenRouter API key in Settings → Accounts & Keys first."
        case .http(let status, let message):
            switch status {
            case 401: return "OpenRouter rejected the API key. Check it in Settings → Accounts & Keys. \(message)"
            case 402: return "OpenRouter credits are exhausted. Add credits, then try again. \(message)"
            case 429: return "OpenRouter rate limit reached. Try again shortly. \(message)"
            default: return "OpenRouter HTTP \(status): \(message)"
            }
        case .transport(let message):
            return "Network error while contacting OpenRouter: \(message)"
        case .decoding(let message):
            return "Could not understand OpenRouter's response: \(message)"
        case .invalidPath(let path):
            return "Invalid API path \"\(path)\": supply the path and query items separately (paths cannot contain '?' or '#')."
        case .invalidUpload(let message):
            return message
        case .deleteNotConfirmed(let id):
            return "Deleting file \(id) requires explicit confirmation. Deletion is irreversible."
        case .resumeUnavailable(let reason):
            return "This job cannot be resumed: \(reason)"
        case .untrustedURL(let reference):
            return "Refusing to send credentials to an unapproved URL: \(reference). Only HTTPS URLs on openrouter.ai with a path under /api/v1/ are allowed."
        }
    }
}
