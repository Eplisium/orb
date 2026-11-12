import Foundation

// MARK: - Explicit approvals
//
// High-risk tools (terminal, computer control, MCP) pass through here even
// when their capability is granted. With no handler installed the coordinator
// fails closed, and a pending approval can always be cancelled — a cancelled
// approval is a denial, never a silent pass.

/// Collects user decisions for risky agent tool calls.
actor ApprovalCoordinator {
    struct Request: Sendable, Identifiable {
        let id: UUID
        let toolName: String
        /// MCP server slug when the tool is namespaced, otherwise nil.
        let server: String?
        /// Redacted argument summary for display.
        let summary: String
    }

    enum Decision: Sendable {
        case approved
        /// Approved now, and remembered so the same tool does not re-prompt until revoked.
        case approvedForSession
        case denied
    }

    private var handler: (@Sendable (Request) async -> Decision)?
    private var pending: [UUID: CheckedContinuation<Decision, Never>] = [:]
    private var sessionApproved: Set<String> = []
    private var handlerTasks: [UUID: Task<Void, Never>] = [:]

    /// Installs the UI responder. Passing nil removes it (and fails closed).
    func setHandler(_ handler: (@Sendable (Request) async -> Decision)?) {
        self.handler = handler
        if handler == nil {
            cancelPending()
            revokeSessionApprovals()
        }
    }

    var pendingRequestIDs: [UUID] {
        Array(pending.keys)
    }

    /// Asks the user. `sessionScope` remembers an approval for the rest of the
    /// session so repeated calls to the same tool do not re-prompt.
    func requestApproval(
        toolName: String,
        server: String? = nil,
        summary: String = "",
        sessionScope: Bool = false
    ) async -> Bool {
        guard !Task.isCancelled else { return false }
        let key = "\(server ?? "")|\(toolName)"
        if sessionApproved.contains(key) { return true }
        guard let handler else { return false }
        let request = Request(id: UUID(), toolName: toolName, server: server, summary: summary)
        let decision = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Decision, Never>) in
                guard !Task.isCancelled else {
                    continuation.resume(returning: .denied)
                    return
                }
                pending[request.id] = continuation
                handlerTasks[request.id] = Task { [handler] in
                    guard !Task.isCancelled else { return }
                    let resolved = await handler(request)
                    await self.fulfill(id: request.id, decision: resolved)
                }
            }
        } onCancel: {
            Task { await self.cancelPending(request.id) }
        }
        guard !Task.isCancelled else { return false }
        if decision == .approvedForSession || (decision == .approved && sessionScope) {
            sessionApproved.insert(key)
        }
        return decision != .denied
    }

    /// Cancels one pending approval, or all of them when no ID is given.
    /// Cancelling resolves the call as denied and the agent receives a tool
    /// error it can act on.
    func cancelPending(_ id: UUID? = nil) {
        let cancelled: [CheckedContinuation<Decision, Never>]
        if let id {
            guard let cont = pending.removeValue(forKey: id) else { return }
            handlerTasks.removeValue(forKey: id)?.cancel()
            cancelled = [cont]
        } else {
            cancelled = Array(pending.values)
            pending.removeAll()
            for task in handlerTasks.values { task.cancel() }
            handlerTasks.removeAll()
        }
        for continuation in cancelled {
            continuation.resume(returning: .denied)
        }
    }

    /// Clears remembered session approvals (e.g. when the user changes policy).
    func revokeSessionApprovals() {
        sessionApproved.removeAll()
    }

    private func fulfill(id: UUID, decision: Decision) {
        handlerTasks.removeValue(forKey: id)
        guard let continuation = pending.removeValue(forKey: id) else { return }
        continuation.resume(returning: decision)
    }
}
