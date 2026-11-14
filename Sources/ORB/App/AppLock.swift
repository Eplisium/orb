import Foundation
import LocalAuthentication

/// What one authentication attempt produced. Cancelling the system prompt is
/// not a failure: the user changed their mind and gets no error text.
enum AppLockAuthResult: Equatable, Sendable {
    case success
    case cancelled
    case failed
    /// No way to authenticate on this Mac (no password/biometrics policy).
    case unavailable
}

/// Copy for the lock screen and the Security settings, worded for Macs with
/// and without biometrics ("Unlock with Touch ID or your Mac password." /
/// "Unlock with your Mac password.").
enum LockCopy {
    /// - Parameter biometric: "Touch ID" etc., or nil when the Mac has none.
    static func prompt(biometric: String?) -> String {
        if let biometric { return "Unlock with \(biometric) or your Mac password." }
        return "Unlock with your Mac password."
    }

    static func settingsDescription(biometric: String?) -> String {
        let method = biometric.map { "\($0) or your Mac password" } ?? "your Mac password"
        return "ORB asks for \(method) at launch and locks again when your Mac sleeps or locks. Keys are stored in the Keychain for this Mac only, readable by ORB alone — no Keychain password prompts."
    }

    static let failed = "That didn't work. Try again — the prompt also accepts your Mac password."
    static let unavailable = "This Mac can't verify you right now. Set a login password in System Settings, or turn off the lock in Settings."
}

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
    @Published private(set) var isUnlocking = false
    @Published var lastFailureMessage: String?

    private let defaults: UserDefaults
    private let authenticate: (String) async -> AppLockAuthResult
    /// The lock screen asks once by itself per lock episode; after that (for
    /// example after a cancel) the user clicks Unlock. Prevents a
    /// prompt → cancel → app re-activates → prompt loop.
    private var autoPromptedThisEpisode = false

    /// - Parameters:
    ///   - defaults: where the "require unlock" preference lives.
    ///   - authenticate: performs the authentication. Injected in tests; the
    ///     app default uses a fresh `LAContext` per evaluation.
    init(
        defaults: UserDefaults = .standard,
        authenticate: @escaping (String) async -> AppLockAuthResult = AppLock.systemAuthenticate
    ) {
        self.defaults = defaults
        self.authenticate = authenticate
        self.isUnlocked = !Self.isEnabled(in: defaults)
    }

    /// Boolean evaluator (true = success, false = failure), for callers that
    /// do not distinguish a cancel.
    convenience init(defaults: UserDefaults = .standard, evaluate: @escaping (String) async -> Bool) {
        self.init(defaults: defaults, authenticate: { reason in await evaluate(reason) ? .success : .failed })
    }

    /// `.deviceOwnerAuthentication` always offers the Mac password as a
    /// fallback in the system prompt — there is no password-only LAPolicy.
    nonisolated static func systemAuthenticate(_ reason: String) async -> AppLockAuthResult {
        let context = LAContext()
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) ? .success : .failed
        } catch {
            return result(for: error)
        }
    }

    /// Maps a LocalAuthentication error. Every cancel flavour is silent.
    nonisolated static func result(for error: Error) -> AppLockAuthResult {
        guard let la = error as? LAError else { return .failed }
        switch la.code {
        case .userCancel, .appCancel, .systemCancel: return .cancelled
        case .passcodeNotSet, .notInteractive: return .unavailable
        default: return .failed
        }
    }

    /// Default ON: the app asks once at launch. Settings → General → Security turns it off.
    static func isEnabled(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? true
    }

    var isEnabled: Bool { Self.isEnabled(in: defaults) }

    /// True while the gate is up: menu commands and the palette are inert.
    var isLocked: Bool { !isUnlocked }

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
        guard !isUnlocking, !isUnlocked else { return }
        lastFailureMessage = nil
        isUnlocking = true
        let result = await authenticate(Self.unlockReason)
        isUnlocking = false
        switch result {
        case .success:
            isUnlocked = true
        case .cancelled:
            lastFailureMessage = nil
        case .failed:
            lastFailureMessage = LockCopy.failed
        case .unavailable:
            lastFailureMessage = LockCopy.unavailable
        }
    }

    /// Whether the lock screen should start authentication by itself now.
    /// Only while ORB is the active app, and once per lock episode.
    func shouldAutoPrompt(appIsActive: Bool) -> Bool {
        isEnabled && !isUnlocked && !isUnlocking && appIsActive && !autoPromptedThisEpisode
    }

    /// Called when the lock screen appears and when ORB becomes active.
    func autoPromptIfNeeded(appIsActive: Bool) async {
        guard shouldAutoPrompt(appIsActive: appIsActive) else { return }
        autoPromptedThisEpisode = true
        await unlock()
    }

    func lock() {
        guard isEnabled, isUnlocked else { return }
        isUnlocked = false
        lastFailureMessage = nil
        autoPromptedThisEpisode = false
    }

    /// "Touch ID", "Face ID" or "Optic ID"; nil when the Mac has no usable
    /// biometrics (the password still works).
    var biometricName: String? {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return nil }
        switch context.biometryType {
        case .touchID: return "Touch ID"
        case .faceID: return "Face ID"
        case .opticID: return "Optic ID"
        case .none: return nil
        @unknown default: return nil
        }
    }

    /// Human label for the auth method ("Touch ID", "Face ID", or "Password").
    var biometricLabel: String { biometricName ?? "Password" }
}
