import AppKit
import Foundation

/// Pure idle-timeout rule, separated from AppKit so it is unit-testable.
enum AppLockPolicy {
    static let idleMinutesKey = "orb.appLock.idleMinutes"
    /// Offered idle limits in minutes; 0 = never auto-lock on idle.
    static let idleChoices = [0, 1, 5, 15, 30, 60]
    static let defaultIdleMinutes = 15

    static func idleMinutes(in defaults: UserDefaults) -> Int {
        guard defaults.object(forKey: idleMinutesKey) != nil else { return defaultIdleMinutes }
        let value = defaults.integer(forKey: idleMinutesKey)
        return idleChoices.contains(value) ? value : defaultIdleMinutes
    }

    static func shouldLock(idleSeconds: TimeInterval, limitMinutes: Int) -> Bool {
        limitMinutes > 0 && idleSeconds >= TimeInterval(limitMinutes) * 60
    }

    static func label(forMinutes minutes: Int) -> String {
        switch minutes {
        case 0: return "Never"
        case 60: return "1 hour"
        case 1: return "1 minute"
        default: return "\(minutes) minutes"
        }
    }
}

/// Re-locks ORB when the Mac locks or sleeps, and after an idle period.
/// Started once from the root view; does nothing when the gate is disabled.
@MainActor
final class AppLockMonitor {
    static let shared = AppLockMonitor()

    private var lastActivity = Date()
    private var eventMonitor: Any?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var started = false

    func start(lock: AppLock, defaults: UserDefaults = .standard) {
        guard !started else { return }
        started = true

        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { lock.lock() }
            })
        }
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { lock.lock() }
        })

        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel, .mouseMoved]
        ) { [weak self] event in
            self?.lastActivity = Date()
            return event
        }

        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, lock.isEnabled, lock.isUnlocked else { return }
                let limit = AppLockPolicy.idleMinutes(in: defaults)
                if AppLockPolicy.shouldLock(idleSeconds: Date().timeIntervalSince(self.lastActivity), limitMinutes: limit) {
                    lock.lock()
                }
            }
        }
    }

    /// Called after a successful unlock so the idle clock starts fresh.
    func noteActivity() { lastActivity = Date() }
}
