import CryptoKit
import Foundation
import Security

// MARK: - PKCE authentication (documented OpenRouter OAuth flow)
//
// Verified contract (re-verify the docs before changing anything here):
//
//   - Authorize page: `https://openrouter.ai/auth` with `callback_url`,
//     `code_challenge`, `code_challenge_method=S256`, plus the optional
//     documented `key_label`, `workspace_id`, `required_workspace_id`.
//     Source: https://openrouter.ai/docs/guides/overview/auth/oauth.md
//   - The flow is parameterized by the callback URL, NOT by client
//     registration: the documented parameter set has NO client_id, and ORB
//     must never invent one.
//   - Callback contract: the browser is redirected to `callback_url` with a
//     `code` query parameter. Localhost/127.0.0.1 callbacks on any port are
//     documented (the OpenAPI `callback_url` description names 127.0.0.1
//     explicitly). ORB binds a loopback-only listener on an OS-selected port
//     and registers `http://127.0.0.1:<port>/callback`.
//   - Exchange: `POST https://openrouter.ai/api/v1/auth/keys` with
//     `{code, code_verifier, code_challenge_method}` → `{key, user_id}`
//     (openapi.json, operationId `exchangeAuthCodeForAPIKey`). The request is
//     unauthenticated — no credential exists before the exchange.
//   - Authorization codes expire 10 minutes after issuance.
//
// Correlation is end-to-end ORB-owned: an unpredictable `state` token is
// embedded in ORB's own callback_url and must come back exactly once. Whether
// OpenRouter preserves the query string of `callback_url` on redirect is
// undocumented — if it is ever dropped, the flow fails CLOSED here
// (`.stateMismatch`); an uncorrelated callback can never be accepted.
//
// The exchanged key is delivered ONLY into the injected `CredentialSecretStore`
// under the profile's inference reference. It never enters logs, UserDefaults,
// error messages, or any value returned to callers.

// MARK: - PKCE material (RFC 7636)

/// Unpredictable verifiers/correlation tokens and the S256 challenge.
enum PKCEMaterial {
    /// 32 random bytes (SecRandomCopyBytes) → 43 unpadded base64url chars.
    static func generateVerifier() throws -> String {
        try randomToken()
    }

    /// 32 random bytes for the one-time callback correlation token.
    static func generateState() throws -> String {
        try randomToken()
    }

    /// S256: BASE64URL(SHA256(ASCII(code_verifier))), no padding.
    static func s256Challenge(forVerifier verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    private static func randomToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw PKCEError.verifierGenerationFailed(status)
        }
        return base64URL(Data(bytes))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - Typed errors

/// Every failure of the PKCE flow is one of these cases, and no case carries
/// authorization code, verifier, or key material.
enum PKCEError: Error, Equatable, LocalizedError {
    case verifierGenerationFailed(OSStatus)
    /// A flow is already waiting for its callback; cancel it first.
    case sessionAlreadyActive
    /// Completion was requested before `prepareAuthorization()`.
    case sessionNotStarted
    case listenerUnavailable(String)
    /// The callback's origin (Host header) is not the exact loopback origin
    /// ORB registered.
    case callbackOriginRejected
    /// The callback path is not the documented one ORB registered.
    case callbackPathRejected
    /// The correlation state is missing, duplicated, or wrong.
    case stateMismatch
    /// The callback carried no authorization code.
    case missingCode
    /// A second callback arrived after the correlation state was consumed.
    case replayedCallback
    /// No valid callback arrived within the wait window.
    case callbackTimeout
    /// The listener was stopped while waiting (external stop/cancel).
    case listenerStopped
    /// The code exchange failed. `message` is scrubbed of secret material.
    case exchangeFailed(status: Int, message: String)
    /// The exchange returned 2xx without the documented `{key, user_id}` shape.
    case exchangeResponseInvalid
    /// The credential store refused (or did not retain) the delivered key.
    case keyDeliveryFailed(String)

    var errorDescription: String? {
        switch self {
        case .verifierGenerationFailed(let status):
            return "Could not generate PKCE material (Security error \(status))."
        case .sessionAlreadyActive:
            return "An OpenRouter connection is already waiting for authorization. Cancel it before starting again."
        case .sessionNotStarted:
            return "No OpenRouter connection is in progress."
        case .listenerUnavailable(let reason):
            return "Could not start the local callback listener: \(reason)"
        case .callbackOriginRejected:
            return "The OpenRouter callback came from an unexpected origin and was refused."
        case .callbackPathRejected:
            return "The OpenRouter callback arrived on an unexpected path and was refused."
        case .stateMismatch:
            return "The OpenRouter callback could not be correlated with this sign-in attempt and was refused."
        case .missingCode:
            return "The OpenRouter callback carried no authorization code."
        case .replayedCallback:
            return "This OpenRouter callback was already used. Start the sign-in again."
        case .callbackTimeout:
            return "Timed out waiting for the OpenRouter authorization. Start the sign-in again."
        case .listenerStopped:
            return "The OpenRouter sign-in was stopped."
        case .exchangeFailed(let status, let message):
            return "OpenRouter rejected the authorization exchange (HTTP \(status)): \(message)"
        case .exchangeResponseInvalid:
            return "OpenRouter's exchange response could not be understood."
        case .keyDeliveryFailed(let reason):
            return "The OpenRouter key could not be stored securely: \(reason)"
        }
    }
}

// MARK: - Redaction

enum PKCESecretRedactor {
    /// Replaces every occurrence of the supplied secret material with
    /// "[redacted]". Applied to any error text that could echo request or
    /// response content — authorization codes, verifiers, and keys must
    /// never appear in surfaced messages or logs.
    static func redact(_ message: String, secrets: [String]) -> String {
        var result = message
        for secret in secrets where !secret.isEmpty {
            result = result.replacingOccurrences(of: secret, with: "[redacted]")
        }
        return result
    }
}

// MARK: - Callback wire shape

/// One parsed HTTP callback request, as the loopback listener saw it.
struct PKCECallbackRequest: Equatable, Sendable {
    /// Raw `Host` header value (e.g. "127.0.0.1:51423"), if present.
    var hostHeader: String?
    /// Request-target path ("" when even the request line was unparseable).
    var path: String
    var queryItems: [URLQueryItem]
}

// MARK: - Exchange transport

/// The documented exchange result: `{key, user_id}`.
struct PKCEKeyExchangeResult: Equatable, Sendable {
    let key: String
    let userID: String?
}

/// Injectable seam for `POST /auth/keys`. Tests inject a mock; production
/// uses `OpenRouterPKCEExchangeTransport`.
protocol PKCEExchangeTransport: Sendable {
    func exchangeAuthorizationCode(
        code: String,
        codeVerifier: String,
        codeChallengeMethod: String
    ) async throws -> PKCEKeyExchangeResult
}

/// Documented exchange endpoint:
/// `POST https://openrouter.ai/api/v1/auth/keys` with
/// `{code, code_verifier, code_challenge_method}` → `{key, user_id}`.
///
/// Deliberately unauthenticated: no Authorization header is attached (the
/// whole point of the exchange is that no credential exists yet), and no
/// HTTP-Referer is sent (F12: attribution needs an owner-approved URL).
struct OpenRouterPKCEExchangeTransport: PKCEExchangeTransport {
    static let endpoint = URL(string: "https://openrouter.ai/api/v1/auth/keys")!

    private let send: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    init(
        send: @escaping @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse) = { request in
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw PKCEError.exchangeFailed(status: 0, message: "OpenRouter returned a non-HTTP response.")
            }
            return (data, http)
        }
    ) {
        self.send = send
    }

    func exchangeAuthorizationCode(
        code: String,
        codeVerifier: String,
        codeChallengeMethod: String
    ) async throws -> PKCEKeyExchangeResult {
        var request = URLRequest(url: Self.endpoint, timeoutInterval: NetworkTimeouts.request)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("ORB", forHTTPHeaderField: "X-OpenRouter-Title")
        let body = PKCEKeyExchangeBody(
            code: code,
            codeVerifier: codeVerifier,
            codeChallengeMethod: codeChallengeMethod
        )
        request.httpBody = try JSONEncoder().encode(body)

        let (data, http) = try await send(request)
        guard (200..<300).contains(http.statusCode) else {
            // Surface the server's own envelope message; the coordinator
            // scrubs it of any secret material before it reaches a user.
            let envelope = AdapterHTTPErrorEnvelope.parse(status: http.statusCode, data: data)
            throw PKCEError.exchangeFailed(status: http.statusCode, message: envelope.message)
        }
        struct Payload: Decodable {
            let key: String
            let userID: String?

            enum CodingKeys: String, CodingKey {
                case key
                case userID = "user_id"
            }
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            throw PKCEError.exchangeResponseInvalid
        }
        return PKCEKeyExchangeResult(key: payload.key, userID: payload.userID)
    }

    /// Documented request body shape.
    struct PKCEKeyExchangeBody: Encodable {
        let code: String
        let codeVerifier: String
        let codeChallengeMethod: String

        enum CodingKeys: String, CodingKey {
            case code
            case codeVerifier = "code_verifier"
            case codeChallengeMethod = "code_challenge_method"
        }
    }
}

// MARK: - Loopback callback listener

/// Loopback-only HTTP listener for the OAuth callback.
///
/// Binds `127.0.0.1` on an OS-selected port (the port is never published
/// anywhere but the registered callback URL), accepts connections on a
/// dedicated thread, and delivers the first parseable HTTP request to the
/// waiter. Connections that carry no parseable HTTP head (e.g. speculative
/// browser preconnects) are closed without affecting the flow; the first
/// parseable request decides the flow's outcome.
final class PKCELoopbackListener: @unchecked Sendable {
    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var port: UInt16?
    private var waiter: CheckedContinuation<PKCECallbackRequest, Error>?
    private var pendingRequest: PKCECallbackRequest?
    private var waitFinished = false

    /// Binds the loopback listener and starts the accept loop. Returns the
    /// OS-selected port.
    func start() throws -> UInt16 {
        lock.lock()
        defer { lock.unlock() }
        if let port { return port }

        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw PKCEError.listenerUnavailable("socket() failed (errno \(errno)).")
        }
        var yes: Int32 = 1
        _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0 // OS-selected port
        addr.sin_addr.s_addr = inet_addr("127.0.0.1") // loopback only: the callback is never reachable off-device
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0, Darwin.listen(fd, 8) == 0 else {
            let code = errno
            close(fd)
            throw PKCEError.listenerUnavailable("could not bind a loopback callback port (errno \(code)).")
        }

        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        let selected = UInt16(bigEndian: bound.sin_port)
        port = selected
        listenFD = fd
        Thread.detachNewThread { [weak self] in
            self?.acceptLoop(fd: fd)
        }
        return selected
    }

    /// Awaits the first parsed callback request. Exactly one of {delivery,
    /// stop, timeout} resolves the wait.
    func awaitRequest() async throws -> PKCECallbackRequest {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if waitFinished {
                lock.unlock()
                continuation.resume(throwing: PKCEError.listenerStopped)
                return
            }
            if let pending = pendingRequest {
                waitFinished = true
                lock.unlock()
                continuation.resume(returning: pending)
                return
            }
            waiter = continuation
            lock.unlock()
        }
    }

    /// Delivers a parsed request from a connection thread. The request is
    /// stored even when no waiter exists yet, so the callback may arrive
    /// before `awaitRequest` is entered.
    func deliver(_ request: PKCECallbackRequest) {
        lock.lock()
        if waitFinished {
            lock.unlock()
            return
        }
        if let waiter {
            waitFinished = true
            self.waiter = nil
            lock.unlock()
            waiter.resume(returning: request)
            return
        }
        pendingRequest = request
        lock.unlock()
    }

    /// Resolves any pending wait with `error` and closes the listening
    /// socket (idempotent; used for timeout, stop, and cancellation).
    func failWait(_ error: Error) {
        lock.lock()
        waitFinished = true
        let waiter = self.waiter
        self.waiter = nil
        let fd = listenFD
        listenFD = -1
        lock.unlock()
        if fd >= 0 { close(fd) }
        waiter?.resume(throwing: error)
    }

    func stop() {
        failWait(PKCEError.listenerStopped)
    }

    var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return listenFD == -1
    }

    // MARK: Accept loop and connection handling (listener thread pool)

    private func acceptLoop(fd: Int32) {
        while true {
            var clientAddr = sockaddr()
            var clientLen = socklen_t(MemoryLayout<sockaddr>.size)
            let client = Darwin.accept(fd, &clientAddr, &clientLen)
            guard client >= 0 else { break } // listener closed → loop exits
            Thread.detachNewThread { [weak self] in
                self?.handle(client: client)
            }
        }
    }

    private func handle(client: Int32) {
        defer { close(client) }
        guard let head = Self.readRequestHead(client: client) else {
            // No parseable HTTP head (preconnect, port probe): not a
            // callback. The flow keeps waiting for the real redirect.
            return
        }
        let request = Self.parse(head)
        if request == nil {
            Self.respond(client, status: "400 Bad Request", body: "ORB could not parse this request.")
        } else {
            Self.respond(
                client,
                status: "200 OK",
                body: "ORB received the OpenRouter callback. You can close this window and return to ORB."
            )
        }
        // Fail closed on an unparseable head too: the empty path can never
        // match the registered callback path.
        deliver(request ?? PKCECallbackRequest(hostHeader: nil, path: "", queryItems: []))
    }

    /// Reads the request head with a bounded deadline so a silent client can
    /// never wedge the flow. Returns nil when no complete head arrives.
    private static func readRequestHead(client: Int32, deadline: TimeInterval = 3) -> String? {
        var tv = timeval(tv_sec: 1, tv_usec: 0)
        _ = Darwin.setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var buffer = Data()
        let start = Date()
        var scratch = [UInt8](repeating: 0, count: 4096)
        while Date().timeIntervalSince(start) < deadline {
            let received = Darwin.recv(client, &scratch, scratch.count, 0)
            if received > 0 {
                buffer.append(contentsOf: scratch[0..<received])
                if buffer.count >= 16_384 { break }
                if let text = String(data: buffer, encoding: .utf8),
                   text.contains("\r\n\r\n") {
                    return text
                }
                continue
            }
            if received == 0 { return nil } // EOF before a complete head
            if errno == EAGAIN || errno == EWOULDBLOCK { continue } // receive timeout: poll to the deadline
            return nil
        }
        return buffer.isEmpty ? nil : String(data: buffer, encoding: .utf8)
    }

    /// Best-effort parse of an HTTP/1.1 head: request line + Host header.
    /// Returns nil when even the request line is missing.
    static func parse(_ head: String) -> PKCECallbackRequest? {
        // Swift fuses CRLF into a single grapheme Character, so a naive
        // split on "\n" never matches HTTP line endings — normalize first.
        let normalized = head.replacingOccurrences(of: "\r\n", with: "\n")
        var lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).makeIterator()
        guard let rawLine = lines.next() else { return nil }
        let requestLine = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 3 else { return nil }
        let target = String(parts[1])

        var host: String?
        for rawHeader in lines {
            let header = rawHeader.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !header.isEmpty, let colon = header.firstIndex(of: ":") else { continue }
            let name = header[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            if name == "host" {
                host = header[header.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                break
            }
        }

        // Origin form ("/callback?…") is what browsers send; absolute form
        // ("http://…") is accepted because proxies may rewrite it.
        if target.hasPrefix("/") {
            guard let comps = URLComponents(string: "http://loopback.invalid" + target) else { return nil }
            return PKCECallbackRequest(hostHeader: host, path: comps.path, queryItems: comps.queryItems ?? [])
        }
        guard let comps = URLComponents(string: target), comps.scheme != nil, comps.host != nil else {
            return nil
        }
        return PKCECallbackRequest(hostHeader: host, path: comps.path, queryItems: comps.queryItems ?? [])
    }

    private static func respond(_ client: Int32, status: String, body: String) {
        let bodyBytes = Data(body.utf8)
        let head = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(bodyBytes.count)\r\nConnection: close\r\n\r\n"
        var payload = Data(head.utf8)
        payload.append(bodyBytes)
        payload.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                _ = Darwin.send(client, base, raw.count, 0)
            }
        }
    }
}

// MARK: - Coordinator

/// One PKCE sign-in flow against OpenRouter:
///
/// 1. `prepareAuthorization()` — starts the loopback listener on an
///    OS-selected port and returns the documented authorize URL to open in
///    the user's browser.
/// 2. `completeAuthorization()` — waits (bounded) for the callback, validates
///    origin/path/state fail-closed with one-time correlation, exchanges the
///    code, and delivers the key ONLY to the injected credential store under
///    the profile's inference reference. Returns the reference, never the key.
///
/// Every outcome — success, typed failure, timeout, cancellation — shuts the
/// listener down.
final class PKCECoordinator: @unchecked Sendable {
    static let authorizeBase = URL(string: "https://openrouter.ai/auth")!
    static let callbackHost = "127.0.0.1"
    static let callbackPath = "/callback"
    static let codeChallengeMethod = "S256"
    /// Matches the documented 10-minute authorization-code expiry.
    static let defaultCallbackTimeout = Duration.seconds(600)

    private let store: any CredentialSecretStore
    private let profile: CredentialProfile
    private let exchangeTransport: any PKCEExchangeTransport
    private let callbackTimeout: Duration
    private let keyLabel: String?
    private let workspaceID: String?
    private let requiredWorkspaceID: String?

    private let lock = NSLock()
    private var listener: PKCELoopbackListener?
    private var callbackPort: UInt16?
    private var sessionVerifier: String?
    private var sessionState: String?
    private var stateConsumed = false

    init(
        store: any CredentialSecretStore,
        profile: CredentialProfile = CredentialProfile(),
        exchangeTransport: any PKCEExchangeTransport = OpenRouterPKCEExchangeTransport(),
        callbackTimeout: Duration = PKCECoordinator.defaultCallbackTimeout,
        keyLabel: String? = nil,
        workspaceID: String? = nil,
        requiredWorkspaceID: String? = nil
    ) {
        self.store = store
        self.profile = profile
        self.exchangeTransport = exchangeTransport
        self.callbackTimeout = callbackTimeout
        self.keyLabel = keyLabel
        self.workspaceID = workspaceID
        self.requiredWorkspaceID = requiredWorkspaceID
    }

    deinit {
        listener?.stop()
    }

    /// True while a callback listener is bound (a flow is in progress).
    var isListenerRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return listener != nil
    }

    // MARK: Step 1 — authorize URL

    /// Starts the loopback listener and builds the documented authorize URL.
    /// The verifier, S256 challenge, and correlation state are generated here
    /// with `SecRandomCopyBytes` and kept for step 2.
    func prepareAuthorization() throws -> URL {
        let fresh = PKCELoopbackListener()
        let port: UInt16
        do {
            port = try fresh.start()
        } catch {
            throw error
        }

        lock.lock()
        guard listener == nil else {
            lock.unlock()
            fresh.stop()
            throw PKCEError.sessionAlreadyActive
        }
        listener = fresh
        callbackPort = port
        stateConsumed = false
        lock.unlock()

        do {
            let verifier = try PKCEMaterial.generateVerifier()
            let state = try PKCEMaterial.generateState()
            let challenge = PKCEMaterial.s256Challenge(forVerifier: verifier)
            lock.lock()
            sessionVerifier = verifier
            sessionState = state
            lock.unlock()
            return try Self.authorizeURL(
                callbackPort: port,
                state: state,
                challenge: challenge,
                keyLabel: keyLabel,
                workspaceID: workspaceID,
                requiredWorkspaceID: requiredWorkspaceID
            )
        } catch {
            finishSession(matching: fresh)
            throw error
        }
    }

    /// Builds the documented authorize URL. Documented parameters only —
    /// there is deliberately no client_id (the flow is parameterized by the
    /// callback URL, and inventing an app registration is prohibited).
    static func authorizeURL(
        callbackPort: UInt16,
        state: String,
        challenge: String,
        keyLabel: String?,
        workspaceID: String?,
        requiredWorkspaceID: String?
    ) throws -> URL {
        var callback = URLComponents()
        callback.scheme = "http"
        callback.host = callbackHost
        callback.port = Int(callbackPort)
        callback.path = callbackPath
        // ORB's own one-time correlation token rides in the callback URL it
        // registered — nothing about OpenRouter's behavior is assumed beyond
        // the documented redirect + `code`.
        callback.queryItems = [URLQueryItem(name: "state", value: state)]
        guard let callbackURL = callback.url else {
            throw PKCEError.listenerUnavailable("could not build the loopback callback URL.")
        }

        var auth = URLComponents(url: authorizeBase, resolvingAgainstBaseURL: false)!
        var items = [
            URLQueryItem(name: "callback_url", value: callbackURL.absoluteString),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: codeChallengeMethod),
        ]
        if let keyLabel { items.append(URLQueryItem(name: "key_label", value: keyLabel)) }
        if let workspaceID { items.append(URLQueryItem(name: "workspace_id", value: workspaceID)) }
        if let requiredWorkspaceID {
            items.append(URLQueryItem(name: "required_workspace_id", value: requiredWorkspaceID))
        }
        auth.queryItems = items
        guard let url = auth.url else {
            throw PKCEError.listenerUnavailable("could not build the authorize URL.")
        }
        return url
    }

    // MARK: Step 2 — callback, exchange, delivery

    /// Waits for the browser callback (bounded by the timeout), validates it
    /// fail-closed, exchanges the code, and stores the resulting key under
    /// the profile's inference reference. Returns the credential REFERENCE —
    /// never the key.
    @discardableResult
    func completeAuthorization() async throws -> String {
        let snapshot = sessionSnapshot()
        guard let activeListener = snapshot.listener, let verifier = snapshot.verifier else {
            throw PKCEError.sessionNotStarted
        }
        defer { finishSession(matching: activeListener) }

        // A stale callback can never be accepted later: bound the wait.
        let timeout = DispatchWorkItem { activeListener.failWait(PKCEError.callbackTimeout) }
        DispatchQueue.global().asyncAfter(
            deadline: .now() + Self.timeInterval(for: callbackTimeout),
            execute: timeout
        )
        defer { timeout.cancel() }

        let wire: PKCECallbackRequest
        do {
            wire = try await withTaskCancellationHandler {
                try await activeListener.awaitRequest()
            } onCancel: {
                // A cancelled caller must not leave a bound listener behind.
                activeListener.stop()
            }
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw error
        }

        // Exactly one callback is ever accepted: stop listening before any
        // validation so a replayed callback cannot even reach ORB.
        activeListener.stop()

        let code = try validateCallback(wire)

        let result: PKCEKeyExchangeResult
        do {
            result = try await exchangeTransport.exchangeAuthorizationCode(
                code: code,
                codeVerifier: verifier,
                codeChallengeMethod: Self.codeChallengeMethod
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Self.redactExchangeError(error, secrets: [code, verifier])
        }
        return try deliverKey(result.key)
    }

    /// Stops the listener and clears the session so a new flow can start.
    func cancel() {
        lock.lock()
        let active = listener
        lock.unlock()
        guard let active else { return }
        finishSession(matching: active)
    }

    // MARK: Callback validation (fail closed, one-shot correlation)

    /// Validates a callback against the registered session. The checks run
    /// in fail-closed order: replay first, then origin, path, correlation,
    /// and only then the code. Success consumes the correlation state — the
    /// SECOND call, even with a perfectly matching callback, is a replay.
    func validateCallback(_ request: PKCECallbackRequest) throws -> String {
        lock.lock()
        defer { lock.unlock() }
        guard let port = callbackPort, let state = sessionState else {
            throw PKCEError.sessionNotStarted
        }
        guard !stateConsumed else {
            throw PKCEError.replayedCallback
        }

        // 1. Origin: exactly the loopback origin ORB registered. The listener
        //    only speaks plaintext HTTP on 127.0.0.1, so scheme and host are
        //    pinned by construction; the Host header must match exactly.
        let expectedHost = "\(Self.callbackHost):\(port)"
        guard let host = request.hostHeader?
            .trimmingCharacters(in: .whitespaces)
            .lowercased(),
            host == expectedHost else {
            throw PKCEError.callbackOriginRejected
        }

        // 2. Path: exactly the documented callback path ORB registered.
        guard request.path == Self.callbackPath else {
            throw PKCEError.callbackPathRejected
        }

        // 3. One-time correlation: ORB's state token, present exactly once,
        //    matching exactly.
        let states = request.queryItems.filter { $0.name == "state" }.compactMap(\.value)
        guard states.count == 1, states[0] == state else {
            throw PKCEError.stateMismatch
        }

        // 4. The authorization code, present exactly once.
        let codes = request.queryItems.filter { $0.name == "code" }.compactMap(\.value)
        guard codes.count == 1, !codes[0].isEmpty else {
            throw PKCEError.missingCode
        }

        stateConsumed = true
        return codes[0]
    }

    // MARK: Delivery

    /// Delivers the exchanged key ONLY into the injected credential store,
    /// under the profile's inference reference. The write is verified by
    /// re-reading the store; the key never appears in any error, log, or
    /// returned value.
    private func deliverKey(_ key: String) throws -> String {
        let reference = profile.inferenceKeyReference
        if let failure = store.saveSecret(key, forReference: reference) {
            throw PKCEError.keyDeliveryFailed(PKCESecretRedactor.redact(failure, secrets: [key]))
        }
        guard store.hasSecret(forReference: reference) else {
            throw PKCEError.keyDeliveryFailed("the credential store did not retain the new key.")
        }
        return reference
    }

    // MARK: Session bookkeeping

    private struct SessionSnapshot {
        let listener: PKCELoopbackListener?
        let verifier: String?
    }

    /// Synchronous lock scope (NSLock.unlock is unavailable in async contexts).
    private func sessionSnapshot() -> SessionSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return SessionSnapshot(listener: listener, verifier: sessionVerifier)
    }

    private func finishSession(matching finished: PKCELoopbackListener) {
        finished.stop()
        lock.lock()
        if listener === finished {
            listener = nil
            callbackPort = nil
            sessionVerifier = nil
            sessionState = nil
            stateConsumed = false
        }
        lock.unlock()
    }

    /// Scrubs the code and verifier out of any exchange error before it can
    /// surface (7.2: redact authorization and key material from errors).
    private static func redactExchangeError(_ error: Error, secrets: [String]) -> PKCEError {
        switch error {
        case let pkceError as PKCEError:
            if case .exchangeFailed(let status, let message) = pkceError {
                return .exchangeFailed(status: status, message: PKCESecretRedactor.redact(message, secrets: secrets))
            }
            return pkceError
        default:
            return .exchangeFailed(
                status: 0,
                message: PKCESecretRedactor.redact(error.localizedDescription, secrets: secrets)
            )
        }
    }

    private static func timeInterval(for duration: Duration) -> TimeInterval {
        let components = duration.components
        return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
    }
}
