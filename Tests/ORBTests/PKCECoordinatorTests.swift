import Foundation
import Testing
@testable import ORB

// PKCE coordinator — service level, per the verified OpenRouter docs:
//
//   Authorize:  https://openrouter.ai/auth?callback_url=<url>&code_challenge=<c>&code_challenge_method=S256
//               (https://openrouter.ai/docs/guides/overview/auth/oauth.md)
//   Callback:   the browser is redirected to callback_url with `code` added.
//               Localhost/127.0.0.1 callbacks on any port are documented.
//   Exchange:   POST https://openrouter.ai/api/v1/auth/keys
//               {code, code_verifier, code_challenge_method} → {key, user_id}
//               (https://openrouter.ai/openapi.json, exchangeAuthCodeForAPIKey)
//
// The docs parameterize the flow by callback URL, NOT by client registration:
// there is no client_id and ORB must never invent one. Correlation uses the
// unpredictable `state` ORB embeds in its own loopback callback_url, consumed
// exactly once. Tests never touch the network: the browser hop is a scripted
// raw loopback socket, and the exchange is a mocked transport. All
// verifier/challenge/state values are deterministic fixtures except the
// generator-shape tests, which only assert unpredictability/charset.

// MARK: - Fixtures and doubles

/// RFC 7636 Appendix B test vector — also the vector used in OpenRouter's
/// own OpenAPI example for `/auth/keys`.
private enum PKCEFixture {
    static let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
    static let challenge = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
    /// Obviously-fake exchanged key. Never a real credential.
    static let exchangedKey = "sk-or-test-fixture-key"
    static let authorizationCode = "auth-code-fixture"
}

/// Records the exchange call and serves a scripted outcome. Never touches
/// the network and never stores the key anywhere.
private final class MockPKCEExchange: PKCEExchangeTransport, @unchecked Sendable {
    struct Call: Equatable {
        let code: String
        let codeVerifier: String
        let codeChallengeMethod: String
    }

    private let lock = NSLock()
    private var calls: [Call] = []
    private let outcome: Result<PKCEKeyExchangeResult, Error>

    init(returns: PKCEKeyExchangeResult) {
        outcome = .success(returns)
    }

    init(fails: Error) {
        outcome = .failure(fails)
    }

    func exchangeAuthorizationCode(code: String, codeVerifier: String, codeChallengeMethod: String) async throws -> PKCEKeyExchangeResult {
        record(Call(code: code, codeVerifier: codeVerifier, codeChallengeMethod: codeChallengeMethod))
        return try outcome.get()
    }

    private func record(_ call: Call) {
        lock.lock()
        defer { lock.unlock() }
        calls.append(call)
    }

    var recordedCalls: [Call] {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }
}

/// A generic error whose description carries secret-shaped material, used to
/// prove the coordinator scrubs it before surfacing.
private struct LoudExchangeError: Error, LocalizedError {
    let payload: String
    var errorDescription: String? { "exchange blew up on \(payload)" }
}

/// Minimal HTTP/1.1 GET over a raw loopback socket — stands in for the
/// browser following OpenRouter's redirect. No URLSession, no ATS, no
/// external network: everything stays on 127.0.0.1.
private enum PKCELoopbackClient {
    static func get(port: UInt16, target: String, host: String) throws -> String {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw NSError(domain: "PKCELoopbackClient", code: Int(errno))
        }
        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else {
            throw NSError(domain: "PKCELoopbackClient", code: Int(errno))
        }

        let request = "GET \(target) HTTP/1.1\r\nHost: \(host)\r\nConnection: close\r\n\r\n"
        let sent = request.withCString { bytes in
            Darwin.send(fd, bytes, strlen(bytes), 0)
        }
        guard sent > 0 else {
            throw NSError(domain: "PKCELoopbackClient", code: Int(errno))
        }

        var response = ""
        var scratch = [UInt8](repeating: 0, count: 4096)
        while response.utf8.count < 64_000 {
            let n = Darwin.recv(fd, &scratch, scratch.count, 0)
            if n <= 0 { break }
            response.append(String(decoding: scratch[0..<n], as: UTF8.self))
        }
        return response
    }

    /// True when nothing accepts connections on the loopback port any more —
    /// proves the callback listener shut down.
    static func isPortClosed(port: UInt16) -> Bool {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result != 0
    }

    /// Polls until the port refuses connections, tolerating the kernel's
    /// sub-millisecond post-close window in which a concurrent SYN can still
    /// complete a handshake against a just-closed listening socket.
    static func waitUntilPortClosed(port: UInt16, deadline: TimeInterval = 1) -> Bool {
        let start = Date()
        while Date().timeIntervalSince(start) < deadline {
            if isPortClosed(port: port) { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return isPortClosed(port: port)
    }
}

/// Shared helpers for the callback-flow suites.
private enum PKCETestSupport {
    static func makeCoordinator(
        keyLabel: String? = nil,
        workspaceID: String? = nil,
        requiredWorkspaceID: String? = nil,
        callbackTimeout: Duration = .seconds(30),
        exchange: MockPKCEExchange? = nil,
        store: InMemoryCredentialStore = InMemoryCredentialStore()
    ) -> PKCECoordinator {
        let profile = CredentialProfile(name: "Test profile")
        let transport = exchange ?? MockPKCEExchange(
            returns: PKCEKeyExchangeResult(key: PKCEFixture.exchangedKey, userID: "user_fixture"))
        return PKCECoordinator(
            store: store,
            profile: profile,
            exchangeTransport: transport,
            callbackTimeout: callbackTimeout,
            keyLabel: keyLabel,
            workspaceID: workspaceID,
            requiredWorkspaceID: requiredWorkspaceID
        )
    }

    /// Parses the generated authorize URL into its registered callback parts.
    static func callbackParts(_ authorizeURL: URL) throws -> (port: UInt16, state: String, challenge: String) {
        let comps = try #require(URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false))
        let items = try #require(comps.queryItems)
        let callbackURLString = try #require(items.first { $0.name == "callback_url" }?.value)
        let callbackURL = try #require(URL(string: callbackURLString))
        let callbackComps = try #require(URLComponents(url: callbackURL, resolvingAgainstBaseURL: false))
        let port = UInt16(try #require(callbackURL.port))
        let state = try #require(callbackComps.queryItems?.first { $0.name == "state" }?.value)
        let challenge = try #require(items.first { $0.name == "code_challenge" }?.value)
        return (port, state, challenge)
    }

    /// The exact GET target the OpenRouter redirect would produce: the
    /// registered callback path plus `code`, with ORB's embedded state intact.
    static func redirectTarget(code: String, state: String) -> String {
        "/callback?code=\(code)&state=\(state)"
    }
}

// MARK: - 1. PKCE material (S256)

@Suite("PKCE material (S256)")
struct PKCEMaterialTests {
    @Test("a fixed verifier yields the exact documented S256 challenge (RFC 7636 / OpenAPI example vector)")
    func s256Fixture() {
        #expect(PKCEMaterial.s256Challenge(forVerifier: PKCEFixture.verifier) == PKCEFixture.challenge)
    }

    @Test("challenge encoding is base64url without padding")
    func challengeIsBase64URL() {
        let base64URLCharacters = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        for verifier in ["a", "orb", PKCEFixture.verifier] {
            let challenge = PKCEMaterial.s256Challenge(forVerifier: verifier)
            #expect(!challenge.isEmpty)
            #expect(challenge.allSatisfy { base64URLCharacters.contains($0) },
                    "challenge must be base64url (no '+', '/', or '=')")
        }
    }

    @Test("generated verifiers are unpredictable: 43-char base64url, never repeated")
    func verifierGenerationShape() throws {
        let base64URLCharacters = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        var seen = Set<String>()
        for _ in 0..<8 {
            let verifier = try PKCEMaterial.generateVerifier()
            // RFC 7636: 32 random octets → 43 unpadded base64url characters.
            #expect(verifier.count == 43)
            #expect(verifier.allSatisfy { base64URLCharacters.contains($0) })
            #expect(!seen.contains(verifier), "verifiers must be unpredictable (never repeated)")
            seen.insert(verifier)
        }
    }

    @Test("generated correlation state is unpredictable base64url too")
    func stateGenerationShape() throws {
        let state = try PKCEMaterial.generateState()
        #expect(state.count == 43)
        #expect(state != (try PKCEMaterial.generateState()))
    }
}

// MARK: - 2. Authorize URL (documented parameters only)

@Suite("PKCE authorize URL")
struct PKCEAuthorizeURLTests {
    @Test("authorize URL is the documented /auth page with callback_url + S256 challenge and NO client_id")
    func authorizeURLShape() throws {
        let coordinator = PKCETestSupport.makeCoordinator()
        let url = try coordinator.prepareAuthorization()

        let comps = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(comps.scheme == "https")
        #expect(comps.host == "openrouter.ai")
        #expect(comps.path == "/auth")

        let items = try #require(comps.queryItems)
        // Verified docs: the flow is parameterized by callback_url, not by
        // client registration. An invented client_id is prohibited.
        #expect(items.filter { $0.name == "client_id" }.isEmpty)
        #expect(items.first { $0.name == "code_challenge_method" }?.value == "S256")
        #expect(items.first { $0.name == "code_challenge" }?.value?.count == 43)

        let callbackURLString = try #require(items.first { $0.name == "callback_url" }?.value)
        let callback = try #require(URL(string: callbackURLString))
        #expect(callback.scheme == "http")
        #expect(callback.host == "127.0.0.1")
        #expect(callback.path == "/callback")
        #expect((callback.port ?? 0) > 1024, "callback port must be OS-selected (ephemeral)")
    }

    @Test("optional documented parameters (key_label, workspace_id) are forwarded only when configured")
    func optionalDocumentedParameters() throws {
        let withOptional = PKCETestSupport.makeCoordinator(keyLabel: "ORB Local", workspaceID: "ws-fixture")
        let configuredComps = try #require(URLComponents(url: try withOptional.prepareAuthorization(), resolvingAgainstBaseURL: false))
        let items = try #require(configuredComps.queryItems)
        #expect(items.first { $0.name == "key_label" }?.value == "ORB Local")
        #expect(items.first { $0.name == "workspace_id" }?.value == "ws-fixture")

        let withoutOptional = PKCETestSupport.makeCoordinator()
        let plainComps = try #require(URLComponents(url: try withoutOptional.prepareAuthorization(), resolvingAgainstBaseURL: false))
        let plain = try #require(plainComps.queryItems)
        #expect(plain.first { $0.name == "key_label" } == nil)
        #expect(plain.first { $0.name == "workspace_id" } == nil)
        #expect(plain.first { $0.name == "required_workspace_id" } == nil)
    }

    @Test("embedding our state: the callback_url carries ORB's correlation token")
    func callbackURLCarriesState() throws {
        let coordinator = PKCETestSupport.makeCoordinator()
        let url = try coordinator.prepareAuthorization()
        let comps = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let callbackURLString = try #require(comps.queryItems?.first { $0.name == "callback_url" }?.value)
        let callbackComps = try #require(URL(string: callbackURLString).flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) })
        let states = (callbackComps.queryItems ?? []).filter { $0.name == "state" }
        #expect(states.count == 1)
        #expect(states.first?.value?.count == 43)
    }

    @Test("a second prepare while a flow is active is refused; cancel() allows a fresh flow")
    func prepareIsOneFlowAtATime() throws {
        let coordinator = PKCETestSupport.makeCoordinator()
        _ = try coordinator.prepareAuthorization()
        #expect(coordinator.isListenerRunning)
        #expect(throws: PKCEError.sessionAlreadyActive) {
            try coordinator.prepareAuthorization()
        }

        coordinator.cancel()
        #expect(!coordinator.isListenerRunning)

        let second = try coordinator.prepareAuthorization()
        #expect(second.scheme == "https")
        #expect(coordinator.isListenerRunning)
        coordinator.cancel()
        #expect(!coordinator.isListenerRunning)
    }
}

// MARK: - 3. Callback validation (fail closed, one-shot correlation)

@Suite("PKCE callback validation")
struct PKCECallbackValidationTests {
    @Test("happy validation returns the code and consumes the state: a second callback with the SAME state is a replay")
    func replayIsRejected() throws {
        let coordinator = PKCETestSupport.makeCoordinator()
        let url = try coordinator.prepareAuthorization()
        let parts = try PKCETestSupport.callbackParts(url)

        let request = PKCECallbackRequest(
            hostHeader: "127.0.0.1:\(parts.port)",
            path: "/callback",
            queryItems: [
                URLQueryItem(name: "code", value: PKCEFixture.authorizationCode),
                URLQueryItem(name: "state", value: parts.state),
            ]
        )
        #expect(try coordinator.validateCallback(request) == PKCEFixture.authorizationCode)

        // One-time correlation: the exact same callback again must fail.
        #expect(throws: PKCEError.replayedCallback) {
            try coordinator.validateCallback(request)
        }
        coordinator.cancel()
    }

    @Test("wrong origin (Host header) is rejected before anything else")
    func wrongOriginRejected() throws {
        let coordinator = PKCETestSupport.makeCoordinator()
        let url = try coordinator.prepareAuthorization()
        let parts = try PKCETestSupport.callbackParts(url)

        let request = PKCECallbackRequest(
            hostHeader: "evil.example.com:1",
            path: "/callback",
            queryItems: [
                URLQueryItem(name: "code", value: PKCEFixture.authorizationCode),
                URLQueryItem(name: "state", value: parts.state),
            ]
        )
        #expect(throws: PKCEError.callbackOriginRejected) {
            try coordinator.validateCallback(request)
        }
        // A missing Host header is also an origin failure.
        let anonymous = PKCECallbackRequest(hostHeader: nil, path: "/callback", queryItems: request.queryItems)
        #expect(throws: PKCEError.callbackOriginRejected) {
            try coordinator.validateCallback(anonymous)
        }
        coordinator.cancel()
    }

    @Test("wrong path is rejected")
    func wrongPathRejected() throws {
        let coordinator = PKCETestSupport.makeCoordinator()
        let url = try coordinator.prepareAuthorization()
        let parts = try PKCETestSupport.callbackParts(url)

        let request = PKCECallbackRequest(
            hostHeader: "127.0.0.1:\(parts.port)",
            path: "/elsewhere",
            queryItems: [
                URLQueryItem(name: "code", value: PKCEFixture.authorizationCode),
                URLQueryItem(name: "state", value: parts.state),
            ]
        )
        #expect(throws: PKCEError.callbackPathRejected) {
            try coordinator.validateCallback(request)
        }
        coordinator.cancel()
    }

    @Test("state mismatch (and duplicated state) is rejected")
    func stateMismatchRejected() throws {
        let coordinator = PKCETestSupport.makeCoordinator()
        let url = try coordinator.prepareAuthorization()
        let parts = try PKCETestSupport.callbackParts(url)

        let wrongState = PKCECallbackRequest(
            hostHeader: "127.0.0.1:\(parts.port)",
            path: "/callback",
            queryItems: [
                URLQueryItem(name: "code", value: PKCEFixture.authorizationCode),
                URLQueryItem(name: "state", value: String(parts.state.reversed())),
            ]
        )
        #expect(throws: PKCEError.stateMismatch) {
            try coordinator.validateCallback(wrongState)
        }

        // The state is NOT consumed by a failed validation... but a duplicated
        // state parameter can never validate either.
        let duplicated = PKCECallbackRequest(
            hostHeader: "127.0.0.1:\(parts.port)",
            path: "/callback",
            queryItems: [
                URLQueryItem(name: "code", value: PKCEFixture.authorizationCode),
                URLQueryItem(name: "state", value: parts.state),
                URLQueryItem(name: "state", value: parts.state),
            ]
        )
        #expect(throws: PKCEError.stateMismatch) {
            try coordinator.validateCallback(duplicated)
        }

        // Missing state: same typed failure.
        let noState = PKCECallbackRequest(
            hostHeader: "127.0.0.1:\(parts.port)",
            path: "/callback",
            queryItems: [URLQueryItem(name: "code", value: PKCEFixture.authorizationCode)]
        )
        #expect(throws: PKCEError.stateMismatch) {
            try coordinator.validateCallback(noState)
        }
        coordinator.cancel()
    }

    @Test("a missing or empty code is rejected")
    func missingCodeRejected() throws {
        let coordinator = PKCETestSupport.makeCoordinator()
        let url = try coordinator.prepareAuthorization()
        let parts = try PKCETestSupport.callbackParts(url)

        let noCode = PKCECallbackRequest(
            hostHeader: "127.0.0.1:\(parts.port)",
            path: "/callback",
            queryItems: [URLQueryItem(name: "state", value: parts.state)]
        )
        #expect(throws: PKCEError.missingCode) {
            try coordinator.validateCallback(noCode)
        }

        let emptyCode = PKCECallbackRequest(
            hostHeader: "127.0.0.1:\(parts.port)",
            path: "/callback",
            queryItems: [
                URLQueryItem(name: "code", value: ""),
                URLQueryItem(name: "state", value: parts.state),
            ]
        )
        #expect(throws: PKCEError.missingCode) {
            try coordinator.validateCallback(emptyCode)
        }
        coordinator.cancel()
    }
}

// MARK: - 4. End-to-end flow over a real loopback listener (no external network)

@Suite("PKCE loopback flow", .serialized)
struct PKCELoopbackFlowTests {
    @Test("happy path: scripted callback → exchange → key delivered ONLY to the injected store; listener shuts down")
    func happyPathDeliversKeyToStoreOnly() async throws {
        let store = InMemoryCredentialStore()
        let exchange = MockPKCEExchange(
            returns: PKCEKeyExchangeResult(key: PKCEFixture.exchangedKey, userID: "user_fixture"))
        let coordinator = PKCETestSupport.makeCoordinator(exchange: exchange, store: store)
        let url = try coordinator.prepareAuthorization()
        let parts = try PKCETestSupport.callbackParts(url)

        // Scripted browser hop: the exact GET the OpenRouter redirect
        // produces on the registered loopback origin.
        let response = try PKCELoopbackClient.get(
            port: parts.port,
            target: PKCETestSupport.redirectTarget(code: PKCEFixture.authorizationCode, state: parts.state),
            host: "127.0.0.1:\(parts.port)")
        #expect(response.contains("200 OK"))

        let reference = try await coordinator.completeAuthorization()
        #expect(reference == "openrouter-api-key") // the profile's inference reference, never the key

        // The key went to the injected store under the inference reference…
        #expect(store.secret(forReference: "openrouter-api-key") == PKCEFixture.exchangedKey)
        // …and nowhere else: no management entry, and the return value is the
        // reference, not the secret.
        #expect(!store.hasSecret(forReference: "openrouter-management-key"))
        #expect(reference != PKCEFixture.exchangedKey)

        // The exchange saw the documented method and the exact scripted code.
        let call = try #require(exchange.recordedCalls.first)
        #expect(call.code == PKCEFixture.authorizationCode)
        #expect(call.codeChallengeMethod == "S256")
        // The verifier the exchange received hashes (S256) to the challenge
        // embedded in the authorize URL.
        #expect(PKCEMaterial.s256Challenge(forVerifier: call.codeVerifier) == parts.challenge)

        // The listener always shuts down: nothing accepts on the port any more.
        #expect(!coordinator.isListenerRunning)
        #expect(PKCELoopbackClient.waitUntilPortClosed(port: parts.port))
    }

    @Test("a callback with a mismatched state fails closed and stops the listener")
    func stateMismatchFailsClosed() async throws {
        let store = InMemoryCredentialStore()
        let exchange = MockPKCEExchange(returns: PKCEKeyExchangeResult(key: "sk-or-should-never-arrive", userID: nil))
        let coordinator = PKCETestSupport.makeCoordinator(exchange: exchange, store: store)
        let url = try coordinator.prepareAuthorization()
        let parts = try PKCETestSupport.callbackParts(url)

        _ = try PKCELoopbackClient.get(
            port: parts.port,
            target: PKCETestSupport.redirectTarget(code: PKCEFixture.authorizationCode, state: "wrong-state-token"),
            host: "127.0.0.1:\(parts.port)")

        do {
            _ = try await coordinator.completeAuthorization()
            Issue.record("Expected the mismatched-state callback to fail.")
        } catch let error as PKCEError {
            #expect(error == .stateMismatch)
        }
        #expect(store.allSecrets.isEmpty)
        #expect(exchange.recordedCalls.isEmpty)
        #expect(!coordinator.isListenerRunning)
        #expect(PKCELoopbackClient.waitUntilPortClosed(port: parts.port))
    }

    @Test("a wrong-origin callback (forged Host) fails closed and stops the listener")
    func wrongOriginFailsClosed() async throws {
        let store = InMemoryCredentialStore()
        let exchange = MockPKCEExchange(returns: PKCEKeyExchangeResult(key: "sk-or-should-never-arrive", userID: nil))
        let coordinator = PKCETestSupport.makeCoordinator(exchange: exchange, store: store)
        let url = try coordinator.prepareAuthorization()
        let parts = try PKCETestSupport.callbackParts(url)

        _ = try PKCELoopbackClient.get(
            port: parts.port,
            target: PKCETestSupport.redirectTarget(code: PKCEFixture.authorizationCode, state: parts.state),
            host: "evil.example.com:1")

        do {
            _ = try await coordinator.completeAuthorization()
            Issue.record("Expected the forged-origin callback to fail.")
        } catch let error as PKCEError {
            #expect(error == .callbackOriginRejected)
        }
        #expect(store.allSecrets.isEmpty)
        #expect(exchange.recordedCalls.isEmpty)
        #expect(!coordinator.isListenerRunning)
    }

    @Test("a wrong-path callback fails closed and stops the listener")
    func wrongPathFailsClosed() async throws {
        let store = InMemoryCredentialStore()
        let coordinator = PKCETestSupport.makeCoordinator(store: store)
        let url = try coordinator.prepareAuthorization()
        let parts = try PKCETestSupport.callbackParts(url)

        _ = try PKCELoopbackClient.get(
            port: parts.port,
            target: "/attacker?code=\(PKCEFixture.authorizationCode)&state=\(parts.state)",
            host: "127.0.0.1:\(parts.port)")

        do {
            _ = try await coordinator.completeAuthorization()
            Issue.record("Expected the wrong-path callback to fail.")
        } catch let error as PKCEError {
            #expect(error == .callbackPathRejected)
        }
        #expect(store.allSecrets.isEmpty)
        #expect(!coordinator.isListenerRunning)
    }

    @Test("a callback missing the code fails closed and stops the listener")
    func missingCodeFailsClosed() async throws {
        let store = InMemoryCredentialStore()
        let coordinator = PKCETestSupport.makeCoordinator(store: store)
        let url = try coordinator.prepareAuthorization()
        let parts = try PKCETestSupport.callbackParts(url)

        _ = try PKCELoopbackClient.get(
            port: parts.port,
            target: "/callback?state=\(parts.state)",
            host: "127.0.0.1:\(parts.port)")

        do {
            _ = try await coordinator.completeAuthorization()
            Issue.record("Expected the code-less callback to fail.")
        } catch let error as PKCEError {
            #expect(error == .missingCode)
        }
        #expect(store.allSecrets.isEmpty)
        #expect(!coordinator.isListenerRunning)
        #expect(PKCELoopbackClient.waitUntilPortClosed(port: parts.port))
    }

    @Test("stale callbacks are rejected by timeout, and the listener shuts down")
    func callbackTimeoutFailsClosed() async throws {
        let store = InMemoryCredentialStore()
        let exchange = MockPKCEExchange(returns: PKCEKeyExchangeResult(key: "sk-or-should-never-arrive", userID: nil))
        let coordinator = PKCETestSupport.makeCoordinator(
            callbackTimeout: .milliseconds(150), exchange: exchange, store: store)
        let url = try coordinator.prepareAuthorization()
        let parts = try PKCETestSupport.callbackParts(url)

        // No callback is ever sent.
        do {
            _ = try await coordinator.completeAuthorization()
            Issue.record("Expected the wait to time out.")
        } catch let error as PKCEError {
            #expect(error == .callbackTimeout)
        }
        #expect(store.allSecrets.isEmpty)
        #expect(exchange.recordedCalls.isEmpty)
        #expect(!coordinator.isListenerRunning)
        #expect(PKCELoopbackClient.waitUntilPortClosed(port: parts.port))

        // A late (stale) callback after the timeout is simply refused —
        // nothing is listening and no wait exists to resolve.
        #expect(throws: (any Error).self) {
            try PKCELoopbackClient.get(
                port: parts.port,
                target: PKCETestSupport.redirectTarget(code: PKCEFixture.authorizationCode, state: parts.state),
                host: "127.0.0.1:\(parts.port)")
        }
    }

    @Test("an exchange failure surfaces a typed error, stores nothing, and stops the listener")
    func exchangeFailureStoresNothing() async throws {
        let store = InMemoryCredentialStore()
        let exchange = MockPKCEExchange(fails: PKCEError.exchangeFailed(status: 403, message: "Invalid code or code_verifier"))
        let coordinator = PKCETestSupport.makeCoordinator(exchange: exchange, store: store)
        let url = try coordinator.prepareAuthorization()
        let parts = try PKCETestSupport.callbackParts(url)

        _ = try PKCELoopbackClient.get(
            port: parts.port,
            target: PKCETestSupport.redirectTarget(code: PKCEFixture.authorizationCode, state: parts.state),
            host: "127.0.0.1:\(parts.port)")

        do {
            _ = try await coordinator.completeAuthorization()
            Issue.record("Expected the exchange to fail.")
        } catch let error as PKCEError {
            #expect(error == .exchangeFailed(status: 403, message: "Invalid code or code_verifier"))
        }
        #expect(store.allSecrets.isEmpty)
        #expect(!coordinator.isListenerRunning)
        #expect(PKCELoopbackClient.waitUntilPortClosed(port: parts.port))
    }

    @Test("exchange errors never echo the authorization code or verifier")
    func exchangeErrorsAreRedacted() async throws {
        let store = InMemoryCredentialStore()
        let exchange = MockPKCEExchange(fails: LoudExchangeError(payload: PKCEFixture.authorizationCode))
        let coordinator = PKCETestSupport.makeCoordinator(exchange: exchange, store: store)
        let url = try coordinator.prepareAuthorization()
        let parts = try PKCETestSupport.callbackParts(url)

        _ = try PKCELoopbackClient.get(
            port: parts.port,
            target: PKCETestSupport.redirectTarget(code: PKCEFixture.authorizationCode, state: parts.state),
            host: "127.0.0.1:\(parts.port)")

        do {
            _ = try await coordinator.completeAuthorization()
            Issue.record("Expected the exchange to fail.")
        } catch let error as PKCEError {
            #expect(error == .exchangeFailed(status: 0, message: "exchange blew up on [redacted]"))
            let description = error.localizedDescription
            #expect(!description.contains(PKCEFixture.authorizationCode))
            #expect(!description.contains(PKCEFixture.exchangedKey))
        }
        #expect(store.allSecrets.isEmpty)
    }
}

// MARK: - 5. Production exchange transport (documented wire shape)

@Suite("OpenRouter PKCE exchange transport")
struct OpenRouterPKCEExchangeTests {
    private final class CapturedRequestBox: @unchecked Sendable {
        var request: URLRequest?
    }

    private func makeTransport(
        statusCode: Int = 200,
        body: String
    ) -> (OpenRouterPKCEExchangeTransport, CapturedRequestBox) {
        let box = CapturedRequestBox()
        let transport = OpenRouterPKCEExchangeTransport(send: { request in
            box.request = request
            let response = HTTPURLResponse(
                url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
            return (Data(body.utf8), response)
        })
        return (transport, box)
    }

    @Test("POSTs the documented JSON shape to /api/v1/auth/keys with no Authorization and no HTTP-Referer")
    func exchangeShape() async throws {
        let (transport, box) = makeTransport(
            body: #"{"key":"sk-or-fixture","user_id":"user_fixture"}"#
        )
        let result = try await transport.exchangeAuthorizationCode(
            code: "auth-code-fixture", codeVerifier: "verifier-fixture", codeChallengeMethod: "S256")
        #expect(result.key == "sk-or-fixture")
        #expect(result.userID == "user_fixture")

        let request = try #require(box.request)
        #expect(request.url?.absoluteString == "https://openrouter.ai/api/v1/auth/keys")
        #expect(request.httpMethod == "POST")
        // Unauthenticated by design: no credential exists before the exchange.
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        // F12: attribution is the documented display name only — no invented referer.
        #expect(request.value(forHTTPHeaderField: "HTTP-Referer") == nil)
        #expect(request.value(forHTTPHeaderField: "X-OpenRouter-Title") == "ORB")

        struct WireBody: Decodable {
            let code: String
            let code_verifier: String
            let code_challenge_method: String
        }
        let body = try #require(request.httpBody)
        let wire = try JSONDecoder().decode(WireBody.self, from: body)
        #expect(wire.code == "auth-code-fixture")
        #expect(wire.code_verifier == "verifier-fixture")
        #expect(wire.code_challenge_method == "S256")
    }

    @Test("HTTP errors map to the typed failure with the server's envelope message")
    func httpErrorMapping() async throws {
        let (transport, _) = makeTransport(
            statusCode: 403,
            body: #"{"error":{"code":403,"message":"Invalid code or code_verifier"}}"#
        )
        do {
            _ = try await transport.exchangeAuthorizationCode(
                code: "auth-code-fixture", codeVerifier: "verifier-fixture", codeChallengeMethod: "S256")
            Issue.record("Expected the 403 to throw.")
        } catch let error as PKCEError {
            #expect(error == .exchangeFailed(status: 403, message: "Invalid code or code_verifier"))
        }
    }

    @Test("a 200 with an unexpected body fails as invalid instead of fabricating a key")
    func malformedSuccessBody() async throws {
        let (transport, _) = makeTransport(body: #"{"nope":true}"#)
        do {
            _ = try await transport.exchangeAuthorizationCode(
                code: "auth-code-fixture", codeVerifier: "verifier-fixture", codeChallengeMethod: "S256")
            Issue.record("Expected the malformed body to throw.")
        } catch let error as PKCEError {
            #expect(error == .exchangeResponseInvalid)
        }
    }
}

// MARK: - 6. Redactor

@Suite("PKCE secret redaction")
struct PKCESecretRedactorTests {
    @Test("every secret occurrence is replaced with [redacted]")
    func redactsAllSecrets() {
        let message = "code=auth-code-fixture verifier=abc key=sk-or-test-fixture-key end"
        let redacted = PKCESecretRedactor.redact(
            message, secrets: ["auth-code-fixture", "abc", "sk-or-test-fixture-key"])
        #expect(redacted == "code=[redacted] verifier=[redacted] key=[redacted] end")
    }

    @Test("empty secrets are ignored and clean messages pass through")
    func passthrough() {
        #expect(PKCESecretRedactor.redact("all good", secrets: ["", "x"]) == "all good")
    }
}
