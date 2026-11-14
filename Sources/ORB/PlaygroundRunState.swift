import Foundation

enum PlaygroundRunPhase: Equatable, Sendable {
    case idle
    case connecting
    case streaming
    case executingTool(String)
    /// An Agent tool call is waiting for the user's approval; nothing runs
    /// until they decide.
    case awaitingApproval(String)
    case stopping
    case completed
    case failed(String)
    case interrupted(String?)
}

struct PlaygroundRunContext: Equatable, Sendable {
    let runID: UUID
    let conversationID: UUID
    let assistantMessageID: UUID
    let mode: PlaygroundMode
    let startedAt: Date
}

struct PlaygroundRunState: Equatable, Sendable {
    var context: PlaygroundRunContext?
    var phase: PlaygroundRunPhase = .idle

    var isActive: Bool {
        switch phase {
        case .connecting, .streaming, .executingTool, .awaitingApproval, .stopping: true
        default: false
        }
    }
}

extension PlaygroundRunPhase {
    static let awaitingApprovalText = "Waiting for your approval"

    /// Short status for the Agent run strip. A pending approval is not a
    /// running tool: nothing executes until the user decides.
    var agentStatusText: String {
        switch self {
        case .awaitingApproval: Self.awaitingApprovalText
        case .executingTool: "Running tool"
        case .stopping: "Stopping…"
        default: "Agent working"
        }
    }

    var isAwaitingApproval: Bool {
        if case .awaitingApproval = self { return true }
        return false
    }
}
