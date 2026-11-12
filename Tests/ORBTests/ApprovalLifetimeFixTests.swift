import Foundation
import Testing
@testable import ORB

@Suite("Approval lifetime regressions")
struct ApprovalLifetimeFixTests {
    @Test("Cancellation before a delayed handler presents cannot create a stale sheet")
    @MainActor
    func delayedPresentation() async throws {
        let coordinator = ApprovalCoordinator()
        let presenter = ApprovalPresenter()
        let gate = ApprovalDelayGate()
        await coordinator.setHandler { request in
            await gate.wait()
            let decision = await presenter.present(request)
            await gate.finished()
            return decision
        }
        let task = Task { await coordinator.requestApproval(toolName: "run_command") }
        for _ in 0..<1000 {
            if await gate.started { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(await gate.started)
        task.cancel()
        #expect(await task.value == false)
        presenter.denyAll()
        await gate.release()
        for _ in 0..<1000 {
            if await gate.didFinish { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(await gate.didFinish)
        #expect(presenter.queue.current == nil)
        #expect(await coordinator.pendingRequestIDs.isEmpty)
        presenter.denyAll()
    }
}

private actor ApprovalDelayGate {
    var started = false
    var didFinish = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        started = true
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
    func finished() { didFinish = true }
}
