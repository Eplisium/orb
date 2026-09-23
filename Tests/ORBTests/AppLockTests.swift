import Foundation
import Testing

@testable import ORB

// MARK: - App lock (Touch ID / password unlock)
//
// AppLock is pure state over injected storage and an injected evaluator, so
// every rule is testable without LAContext, biometrics, or the Keychain.

@MainActor
@Suite("App lock")
struct AppLockTests {

    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "AppLockTests-\(UUID().uuidString)")!
    }

    @Test("unlock is required by default and the app starts locked")
    func defaultIsLocked() {
        let defaults = freshDefaults()
        let lock = AppLock(defaults: defaults, evaluate: { _ in true })
        #expect(AppLock.isEnabled(in: defaults))
        #expect(!lock.isUnlocked)
    }

    @Test("a disabled gate starts unlocked and never locks")
    func disabledStartsUnlocked() async {
        let defaults = freshDefaults()
        defaults.set(false, forKey: AppLock.enabledKey)
        let lock = AppLock(defaults: defaults, evaluate: { _ in true })
        #expect(!lock.isEnabled)
        #expect(lock.isUnlocked)
        lock.lock()
        #expect(lock.isUnlocked)
    }

    @Test("successful authentication unlocks; failure keeps locked with a message")
    func unlockOutcome() async {
        let lock = AppLock(defaults: freshDefaults(), evaluate: { _ in true })
        await lock.unlock()
        #expect(lock.isUnlocked)
        #expect(lock.lastFailureMessage == nil)

        let failing = AppLock(defaults: freshDefaults(), evaluate: { _ in false })
        await failing.unlock()
        #expect(!failing.isUnlocked)
        #expect(failing.lastFailureMessage != nil)
    }

    @Test("the evaluator receives the allow-all-access reason")
    func evaluatorReceivesReason() async {
        var seenReasons: [String] = []
        let lock = AppLock(defaults: freshDefaults(), evaluate: { reason in
            seenReasons.append(reason)
            return true
        })
        await lock.unlock()
        #expect(seenReasons == [AppLock.unlockReason])
    }

    @Test("disabling mid-session opens immediately; re-enabling re-arms for next launch")
    func togglingTheGate() async {
        let defaults = freshDefaults()
        let lock = AppLock(defaults: defaults, evaluate: { _ in true })
        #expect(!lock.isUnlocked)

        lock.setEnabled(false)
        #expect(lock.isUnlocked)

        // Re-arming must not yank the UI away mid-task: still open now,
        // locked on the next construction (next launch).
        lock.setEnabled(true)
        #expect(lock.isUnlocked)
        let relaunched = AppLock(defaults: defaults, evaluate: { _ in true })
        #expect(!relaunched.isUnlocked)
    }

    @Test("locking re-gates an enabled session")
    func lockReGates() async {
        let lock = AppLock(defaults: freshDefaults(), evaluate: { _ in true })
        await lock.unlock()
        #expect(lock.isUnlocked)
        lock.lock()
        #expect(!lock.isUnlocked)
    }
}
