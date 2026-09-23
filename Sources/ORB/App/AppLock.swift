import Foundation
import LocalAuthentication

/// Session-scoped app unlock: one "allow all access" gesture at launch with
/// Touch ID, Apple Watch, or the Mac password (`LAContext` with
/// `.deviceOwnerAuthentication`, so the password fallback always works).
///
/// This replaces the legacy keychain dialog (which demanded the *login
/// keychain* password and reappeared after every rebuild). It is a
/// convenience/privacy gate, not a security boundary — the real protections
/// are the user's login session and FileVault. Session-scoped by design:
/// every app launch asks once.
@MainActor
final class AppLock: ObservableObject {
    static let enabledKey = "orb.appLock.enabled"
    static let unlockReason = "Unlock ORB and allow access to your API keys and sessions."

    /// Shared instance used by the app; tests build their own with injected
    /// storage and evaluation.
    static let shared = AppLock()

    @Published private(set) var isUnlocked: Bool
    @Published var lastFailureMessage: String?

    private let defaults: UserDefaults
    private let evaluate: (String) async -> Bool

    /// - Parameters:
    ///   - defaults: where the "require unlock" preference lives.
    ///   - evaluate: performs the authentication. Injected in tests; the app
    ///     default uses a fresh `LAContext` per evaluation.
    init(
        defaults: UserDefaults = .standard,
        evaluate: @escaping (String) async -> Bool = { reason in
            let context = LAContext()
            do {
                return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            } catch {
                return false
            }
        }
    ) {
        self.defaults = defaults
        self.evaluate = evaluate
        self.isUnlocked = !Self.isEnabled(in: defaults)
    }

    /// Default ON: the app asks once at launch. Settings → Security turns it off.
    static func isEnabled(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? true
    }

    var isEnabled: Bool { Self.isEnabled(in: defaults) }

    func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.enabledKey)
        objectWillChange.send()
        // Disabling the gate opens immediately; re-enabling re-arms for the
        // next launch instead of yanking the UI away mid-task.
        if !enabled { isUnlocked = true }
    }

    /// The "Unlock — Allow All Access" action. Pure state: post-unlock side
    /// effects (keychain migration, MCP startup) are owned by the view layer
    /// so this type stays unit-testable.
    func unlock() async {
        lastFailureMessage = nil
        let ok = await evaluate(Self.unlockReason)
        if ok {
            isUnlocked = true
        } else {
            lastFailureMessage = "Authentication failed. Try again."
        }
    }

    func lock() {
        guard isEnabled else { return }
        isUnlocked = false
    }

    /// Human label for the auth method ("Touch ID", "Face ID", or "Password").
    var biometricLabel: String {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return "Password"
        }
        switch context.biometryType {
        case .touchID: return "Touch ID"
        case .faceID: return "Face ID"
        case .opticID: return "Optic ID"
        case .none: return "Password"
        @unknown default: return "Password"
        }
    }
}
