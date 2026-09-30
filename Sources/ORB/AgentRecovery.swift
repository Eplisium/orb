import Foundation

/// How the agent loop reacts when a model turn fails mid-run. A long task must
/// survive a network blip or a provider hiccup instead of dying and forcing
/// the user to type "continue" (which then replays history that may itself be
/// the cause of the next failure).
enum AgentTurnRecovery {
    enum Action: Equatable {
        /// Wait, then re-send the same turn.
        case retry(after: Duration)
        /// Re-send once with replayed reasoning blocks removed.
        case stripReasoning
        case fail
    }

    /// Attempts per turn before giving up (≈ 1.5 minutes of total waiting).
    static let maxTransientRetries = 6
    private static let delays: [Duration] = [.seconds(2), .seconds(4), .seconds(8), .seconds(15), .seconds(25), .seconds(35)]

    static func action(for error: Error, transientAttempts: Int, strippedAlready: Bool, canStrip: Bool,
                       hasVisibleOutput: Bool) -> Action {
        if error is CancellationError { return .fail }
        // Text already streamed to the user would duplicate on a re-send.
        guard !hasVisibleOutput else { return .fail }
        if isTransient(error) {
            guard transientAttempts < maxTransientRetries else { return .fail }
            return .retry(after: delays[min(transientAttempts, delays.count - 1)])
        }
        // HTTP 400 "Provider returned error" after a resume is most often the
        // provider rejecting replayed reasoning blocks (unsigned, spliced from
        // several turns). They are a continuity hint only, so drop them once.
        if case OpenRouterClientError.http(let status, _, _) = error, status == 400, canStrip, !strippedAlready {
            return .stripReasoning
        }
        return .fail
    }

    static func isTransient(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            return transientURLCodes.contains(urlError.code)
        }
        guard let client = error as? OpenRouterClientError else { return false }
        switch client {
        case .abruptEOF, .idleTimeout: return true
        case .http(let status, _, _): return [408, 429, 500, 502, 503, 504, 520, 522, 524, 529].contains(status)
        case .transport(let message):
            let text = message.lowercased()
            return ["tls", "secure connection", "connection was lost", "network connection",
                    "timed out", "could not connect", "offline", "not connected", "dns",
                    "cannot find host", "connection reset", "broken pipe", "ssl"].contains { text.contains($0) }
        default: return false
        }
    }

    private static let transientURLCodes: Set<URLError.Code> = [
        .timedOut, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .networkConnectionLost,
        .notConnectedToInternet, .secureConnectionFailed, .serverCertificateHasBadDate,
        .cannotLoadFromNetwork, .resourceUnavailable, .internationalRoamingOff
    ]

    static func label(for error: Error, attempt: Int) -> String {
        "Connection problem — retrying (\(attempt)/\(maxTransientRetries))…"
    }

    static func strippingReasoning(_ messages: [AgentAPIMessage]) -> [AgentAPIMessage] {
        messages.map {
            $0.reasoningDetails == nil ? $0 : AgentAPIMessage(
                role: $0.role, content: $0.content, parts: $0.parts, toolCalls: $0.toolCalls,
                toolCallId: $0.toolCallId, name: $0.name, images: $0.images, reasoningDetails: nil)
        }
    }
}
