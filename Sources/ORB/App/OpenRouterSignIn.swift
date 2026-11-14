import SwiftUI
import AppKit

// MARK: - Sign in with OpenRouter (PKCE), reusable
//
// Onboarding is no longer the only way in: Settings → Accounts & Keys and
// every needs-key banner offer the same one-click flow. One shared model
// means two entry points can never run two browser flows at once, and every
// entry point shows the same "waiting for your browser" state.

@MainActor
final class OpenRouterSignInModel: ObservableObject {
    /// The app-wide flow used by Settings and the needs-key banners.
    static let shared = OpenRouterSignInModel()

    @Published private(set) var phase: SignInPhase = .idle
    /// Bumped after every successful sign-in, so key-status views refresh.
    @Published private(set) var completedCount = 0

    private let credentials: any CredentialSecretStore
    private let makeSignIn: () -> any OnboardingSignIn
    private let reviewMode: Bool
    private let openURL: (URL) -> Void
    private let activateApp: () -> Void
    private let announceSuccess: () -> Void
    private var active: (any OnboardingSignIn)?
    private var task: Task<Void, Error>?

    static let successMessage = "Signed in with OpenRouter. Your key is saved in the Keychain."

    init(
        credentials: any CredentialSecretStore = KeychainCredentialStore(),
        makeSignIn: (() -> any OnboardingSignIn)? = nil,
        reviewMode: Bool = OnboardingGate.isReviewMode(),
        openURL: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) },
        activateApp: (() -> Void)? = nil,
        announceSuccess: (() -> Void)? = nil
    ) {
        self.credentials = credentials
        self.makeSignIn = makeSignIn ?? { PKCEOnboardingSignIn(store: credentials) }
        self.reviewMode = reviewMode
        self.openURL = openURL
        self.activateApp = activateApp ?? { OpenRouterSignInModel.bringORBToFront() }
        self.announceSuccess = announceSuccess ?? {
            AppToasts.center.show(OpenRouterSignInModel.successMessage, kind: .success)
        }
    }

    var isWaiting: Bool { phase == .waiting }

    var failureMessage: String? {
        if case .failed(let message) = phase { return message }
        return nil
    }

    /// Opens the browser, waits for the callback, and on success brings ORB
    /// back to the front and confirms with a toast. Returns true when a key
    /// was saved. A second call while waiting does nothing.
    @discardableResult
    func signIn() async -> Bool {
        guard !reviewMode else {
            phase = .failed(OnboardingController.reviewModeMessage)
            return false
        }
        guard phase != .waiting else { return false }
        let signIn = makeSignIn()
        let url: URL
        do {
            url = try signIn.begin()
        } catch {
            phase = .failed(error.localizedDescription)
            return false
        }
        active = signIn
        phase = .waiting
        openURL(url)
        let flow = Task { try await signIn.complete() }
        task = flow
        defer { active = nil; task = nil }
        do {
            try await flow.value
            guard credentials.hasSecret(forReference: CredentialRole.inference.keychainAccount) else {
                phase = .failed("Sign-in finished but no key was saved. Paste a key instead.")
                return false
            }
            phase = .idle
            completedCount += 1
            activateApp()
            announceSuccess()
            return true
        } catch {
            // A user cancel already reset the phase; don't overwrite it.
            guard phase == .waiting else { return false }
            phase = error is CancellationError ? .idle : .failed(error.localizedDescription)
            return false
        }
    }

    func cancel() {
        let wasWaiting = phase == .waiting
        active?.cancel()
        task?.cancel()
        if wasWaiting { phase = .idle }
    }

    func clearFailure() {
        if case .failed = phase { phase = .idle }
    }

    /// The browser had focus while the user approved; return them to ORB.
    static func bringORBToFront() {
        NSApp.activate()
        (NSApp.mainWindow ?? NSApp.windows.first { $0.canBecomeMain && $0.isVisible })?.makeKeyAndOrderFront(nil)
    }
}

/// The "Sign in with OpenRouter" control, with its waiting and failure states.
struct OpenRouterSignInButton: View {
    @ObservedObject var model: OpenRouterSignInModel
    var prominent = true
    var controlSize: ControlSize = .regular

    var body: some View {
        VStack(alignment: .leading, spacing: ORBMetrics.spacingXXS) {
            if model.isWaiting {
                HStack(spacing: ORBMetrics.spacingXS) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for you to approve in your browser…")
                        .orbFont(.footnote)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Cancel") { model.cancel() }
                        .controlSize(.small)
                }
            } else {
                button
                    .controlSize(controlSize)
                    .help("Opens openrouter.ai in your browser to create a key for ORB. No copy and paste needed.")
            }
            if let message = model.failureMessage {
                Text(message)
                    .orbFont(.caption)
                    .foregroundStyle(ORBTheme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var button: some View {
        let label = Label("Sign in with OpenRouter", systemImage: "person.badge.key")
        if prominent {
            Button { Task { await model.signIn() } } label: { label }
                .buttonStyle(.borderedProminent)
                .tint(ORBTheme.accent)
        } else {
            Button { Task { await model.signIn() } } label: { label }
                .buttonStyle(.bordered)
        }
    }
}
