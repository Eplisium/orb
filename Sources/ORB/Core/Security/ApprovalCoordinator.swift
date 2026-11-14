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
        /// Why this particular call asks (e.g. a write outside the workspace).
        var reason: String? = nil
        /// The resolved absolute path the call touches or runs in.
        var resolvedPath: String? = nil
        /// What "Allow for this run" covers, e.g. "every command in ~/App".
        var scopeLabel: String? = nil
        /// Precomputed preview, e.g. the line diff a `write_file` would make.
        var preview: String? = nil
        /// Sidebar section (raw value) whose run is waiting on this request.
        var section: String = "Agent"
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
    /// Section whose runs this coordinator serves, used for the app-wide
    /// "approval waiting" badge and notification (`ApprovalAttention`).
    let attentionSection: String

    /// Nil = the app-wide `ApprovalAttention.shared`; tests inject their own.
    private let attention: ApprovalAttention?

    init(attentionSection: String = "Agent", attention: ApprovalAttention? = nil) {
        self.attentionSection = attentionSection
        self.attention = attention
    }

    private func attentionTarget() async -> ApprovalAttention {
        if let attention { return attention }
        return await MainActor.run { ApprovalAttention.shared }
    }

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
    /// `scopeKey` narrows what a session approval remembers (for example one
    /// working directory for `run_command`, or one path for a sensitive
    /// file); nil keeps the tool-wide key.
    func requestApproval(
        toolName: String,
        server: String? = nil,
        summary: String = "",
        sessionScope: Bool = false,
        scopeKey: String? = nil,
        scopeLabel: String? = nil,
        reason: String? = nil,
        resolvedPath: String? = nil,
        preview: String? = nil
    ) async -> Bool {
        guard !Task.isCancelled else { return false }
        let key = scopeKey ?? "\(server ?? "")|\(toolName)"
        if sessionApproved.contains(key) { return true }
        guard let handler else { return false }
        let request = Request(
            id: UUID(), toolName: toolName, server: server, summary: summary,
            reason: reason, resolvedPath: resolvedPath, scopeLabel: scopeLabel, preview: preview,
            section: attentionSection
        )
        let attention = await attentionTarget()
        await attention.began(request)
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
        await attention.ended(request.id)
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
