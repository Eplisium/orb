import Darwin
import Foundation
import Testing
@testable import ORB

@Suite("Native agent tool cancellation")
struct NativeAgentToolCancellationTests {
    private final class SignalRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [pid_t] = []

        func append(_ pid: pid_t) {
            lock.lock()
            storage.append(pid)
            lock.unlock()
        }

        var values: [pid_t] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    private func isRunningProcess(_ pid: pid_t) -> Bool {
        var info = proc_bsdinfo()
        let size = proc_pidinfo(
            pid,
            PROC_PIDTBSDINFO,
            0,
            &info,
            Int32(MemoryLayout<proc_bsdinfo>.size)
        )
        return size > 0 && info.pbi_status != 5 // SZOMB
    }

    @Test("cancel before launch propagates CancellationError")
    func cancelBeforeLaunch() async {
        let task = Task {
            try await NativeAgentTools.runProcessForTesting(command: "sleep 5", launchDelay: .milliseconds(100))
        }
        task.cancel()
        let result = await task.result
        guard case .failure(let error) = result else { Issue.record("Expected cancellation"); return }
        #expect(error is CancellationError)
    }

    @Test("cancel immediately after launch terminates a long command")
    func cancelAfterLaunch() async throws {
        let started = ContinuousClock.now
        let task = Task { try await NativeAgentTools.runProcessForTesting(command: "sleep 10") }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        let result = await task.result
        guard case .failure(let error) = result else { Issue.record("Expected cancellation"); return }
        #expect(error is CancellationError)
        #expect(started.duration(to: .now) < .seconds(2))
    }

    @Test("cancellation signals only the owned process group")
    func cancellationSignalsOnlyProcessGroup() async throws {
        let signals = SignalRecorder()
        let task = Task {
            try await NativeAgentTools.runProcessForTesting(command: "sleep 10") { target, signal in
                signals.append(target)
                return Darwin.kill(target, signal)
            }
        }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        _ = await task.result

        let targets = signals.values
        #expect(!targets.isEmpty)
        #expect(targets.allSatisfy { $0 < 0 })
    }

    @Test("cancellation terminates spawned descendants")
    func cancellationTerminatesDescendants() async throws {
        let pidFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("ORB-descendant-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let task = Task {
            try await NativeAgentTools.runProcessForTesting(
                command: "(trap '' HUP TERM; exec sleep 30) & child=$!; printf '%s %s' $$ $child > \(pidFile.path); wait $child"
            )
        }

        for _ in 0..<200 where !FileManager.default.fileExists(atPath: pidFile.path) {
            try await Task.sleep(for: .milliseconds(5))
        }
        let pids = try String(contentsOf: pidFile, encoding: .utf8).split(separator: " ")
        let parentPID = try #require(pids.first.flatMap { pid_t($0) })
        let childPID = try #require(pids.last.flatMap { pid_t($0) })
        defer { if isRunningProcess(childPID) { Darwin.kill(childPID, SIGKILL) } }
        #expect(Darwin.getpgid(parentPID) == parentPID)
        #expect(Darwin.getpgid(childPID) == parentPID)

        task.cancel()
        guard case .failure(let error) = await task.result else {
            Issue.record("Expected cancellation")
            return
        }
        #expect(error is CancellationError)
        for _ in 0..<100 where isRunningProcess(childPID) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(isRunningProcess(childPID) == false)
    }

    @Test("cancellation after leader exit terminates pipe-owning descendants")
    func cancellationAfterLeaderExitTerminatesDescendants() async throws {
        let pidFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("ORB-exited-leader-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let task = Task {
            try await NativeAgentTools.runProcessForTesting(
                command: "(trap '' HUP TERM; exec sleep 3) & child=$!; printf '%s %s' $$ $child > \(pidFile.path); exit 0"
            )
        }

        for _ in 0..<200 where !FileManager.default.fileExists(atPath: pidFile.path) {
            try await Task.sleep(for: .milliseconds(5))
        }
        let pids = try String(contentsOf: pidFile, encoding: .utf8).split(separator: " ")
        let parentPID = try #require(pids.first.flatMap { pid_t($0) })
        let childPID = try #require(pids.last.flatMap { pid_t($0) })
        defer { if isRunningProcess(childPID) { Darwin.kill(childPID, SIGKILL) } }
        for _ in 0..<200 where isRunningProcess(parentPID) {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(isRunningProcess(childPID))

        let cancelledAt = ContinuousClock.now
        task.cancel()
        guard case .failure(let error) = await task.result else {
            Issue.record("Expected cancellation")
            return
        }
        #expect(error is CancellationError)
        #expect(cancelledAt.duration(to: .now) < .seconds(2))
        for _ in 0..<100 where isRunningProcess(childPID) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(isRunningProcess(childPID) == false)
    }

    @Test("execute does not convert cancellation into tool output")
    func executePropagatesCancellation() async throws {
        let task = Task {
            try await NativeAgentTools.execute(
                name: "run_command",
                argumentsJSON: #"{"command":"sleep 10"}"#,
                workspace: "/tmp",
                fullComputerAccess: true
            )
        }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        guard case .failure(let error) = await task.result else { Issue.record("Expected cancellation"); return }
        #expect(error is CancellationError)
    }

    @Test("cancel after exit is safe")
    func cancelAfterExit() async throws {
        let task = Task { try await NativeAgentTools.runProcessForTesting(command: "true") }
        _ = try await task.value
        task.cancel()
        _ = try await task.value
    }
}
