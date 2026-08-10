import Foundation

enum PlaygroundRunPhase: Equatable, Sendable {
    case idle
    case connecting
    case streaming
    case executingTool(String)
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
        case .connecting, .streaming, .executingTool, .stopping: true
        default: false
        }
    }
}
