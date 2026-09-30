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

@Suite("App lock idle policy")
struct AppLockPolicyTests {
    @Test("idle limit locks only at or past the limit; zero never locks")
    func idleRule() {
        #expect(!AppLockPolicy.shouldLock(idleSeconds: 899, limitMinutes: 15))
        #expect(AppLockPolicy.shouldLock(idleSeconds: 900, limitMinutes: 15))
        #expect(!AppLockPolicy.shouldLock(idleSeconds: 86_400, limitMinutes: 0))
    }

    @Test("stored value defaults to 15 and rejects unoffered values")
    func storedValue() {
        let d = UserDefaults(suiteName: "AppLockPolicy-\(UUID().uuidString)")!
        #expect(AppLockPolicy.idleMinutes(in: d) == 15)
        d.set(5, forKey: AppLockPolicy.idleMinutesKey)
        #expect(AppLockPolicy.idleMinutes(in: d) == 5)
        d.set(7, forKey: AppLockPolicy.idleMinutesKey)
        #expect(AppLockPolicy.idleMinutes(in: d) == 15)
        d.set(0, forKey: AppLockPolicy.idleMinutesKey)
        #expect(AppLockPolicy.idleMinutes(in: d) == 0)
    }
}

@Suite("Price formatting")
struct PriceFormatTests {
    @Test("prices keep two decimals, trim beyond, never show 2.500 vs 2.00 drift")
    func format() {
        #expect(PriceFormat.perMillion(2) == "$2.00")
        #expect(PriceFormat.perMillion(2.5) == "$2.50")
        #expect(PriceFormat.perMillion(0.15) == "$0.15")
        #expect(PriceFormat.perMillion(0.0375) == "$0.0375")
        #expect(PriceFormat.perMillion(0.95) == "$0.95")
    }
}
