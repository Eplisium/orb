import Foundation

/// Separately billed helper requests. This is budget metadata, NEVER a second
/// ledger charge: each helper has already recorded its own usage event.
struct AgentHelperUsage: Sendable, Equatable {
    var knownCostSubtotal = 0.0
    var requestCount = 0
    var unpricedRequestCount = 0
    var isComplete: Bool { unpricedRequestCount == 0 }
}

/// Task-local to one executor invocation, so concurrent runs and unrelated
/// Generate requests cannot leak charges into each other's comparison budget.
/// Ledger calls are synchronous on MainActor; the lock also permits injected
/// executors to read the completed snapshot from another actor.
final class AgentHelperUsageCollector: @unchecked Sendable {
    @TaskLocal static var current: AgentHelperUsageCollector?
    private let lock = NSLock()
    private var seenIDs: Set<String> = []
    private var usage = AgentHelperUsage()

    func record(_ event: UsageEvent) {
        lock.lock()
        defer { lock.unlock() }
        guard seenIDs.insert(event.id).inserted else { return }
        usage.requestCount += event.requests
        if let cost = event.cost, cost.isFinite, cost >= 0,
           (usage.knownCostSubtotal + cost).isFinite {
            usage.knownCostSubtotal += cost
        } else {
            usage.unpricedRequestCount += event.requests
        }
    }

    var snapshot: AgentHelperUsage {
        lock.lock()
        defer { lock.unlock() }
        return usage
    }
}

/// Model-turn usage only. Paid helper requests have separate ledger entries;
/// folding them into this value would double-count the caller's ledger record.
/// A missing usage frame is a completed, unpriced turn, not an empty accumulator.
struct AgentUsageAccumulator {
    private(set) var value: ChatUsage?
    private var unpricedRequests = 0
    private var requests = 0
    private var knownCost = 0.0

    mutating func append(_ usage: ChatUsage?) {
        requests += usage?.accountedRequestCount ?? 1
        unpricedRequests += usage?.unpricedRequests ?? 1
        let subtotal = usage?.knownCostSubtotal ?? 0
        if (knownCost + subtotal).isFinite {
            knownCost += subtotal
        } else {
            unpricedRequests = requests
        }
        let previous = value
        func sum(_ a: Int?, _ b: Int?) -> Int? {
            guard a != nil || b != nil else { return nil }
            let (total, overflow) = (a ?? 0).addingReportingOverflow(b ?? 0)
            return overflow ? nil : total
        }
        var combined = ChatUsage(
            promptTokens: sum(previous?.promptTokens, usage?.promptTokens),
            completionTokens: sum(previous?.completionTokens, usage?.completionTokens),
            totalTokens: sum(previous?.totalTokens, usage?.totalTokens),
            cost: unpricedRequests > 0 ? nil : knownCost
        )
        combined.costSubtotal = knownCost
        combined.requestCount = requests
        combined.unpricedRequestCount = unpricedRequests
        combined.cachedTokens = sum(previous?.cachedTokens, usage?.cachedTokens)
        combined.reasoningTokens = sum(previous?.reasoningTokens, usage?.reasoningTokens)
        combined.audioTokens = sum(previous?.audioTokens, usage?.audioTokens)
        combined.videoTokens = sum(previous?.videoTokens, usage?.videoTokens)
        combined.serverToolCallsExecuted = sum(previous?.serverToolCallsExecuted, usage?.serverToolCallsExecuted)
        combined.serverToolCallsRequested = sum(previous?.serverToolCallsRequested, usage?.serverToolCallsRequested)
        combined.isBYOK = previous == nil ? usage?.isBYOK
            : previous?.isBYOK == usage?.isBYOK ? previous?.isBYOK : nil
        value = combined
    }
}
