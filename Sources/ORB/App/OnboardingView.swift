import SwiftUI
import AppKit

// MARK: - First-run onboarding (Phase 3)
//
// Layers, from pure to impure:
//   OnboardingFlow          pure value-type state machine (unit-tested)
//   OnboardingOutcomeStore  persistence seam (UserDefaults in the app)
//   OnboardingGate          "should the sheet show" rules, review-mode aware
//   KeyStatusModel          existence-only inference-key check (never reads secrets)
//   OnboardingController    glue: credentials, PKCE sign-in seam, persistence
//   OnboardingView         SwiftUI sheet
//   NeedsKey*               contextual "add a key" banner for Chat/Agent/Generate
//
// Rules: nothing here may touch the Keychain in review mode
// (`-orb.reviewMode YES`); the app works for browsing with no key at all.

enum OnboardingOutcome: String, Equatable, Sendable {
    case completed, skipped
}

enum OnboardingStep: Int, CaseIterable, Equatable, Sendable {
    case welcome, inferenceKey, managementKey
}

enum SignInPhase: Equatable, Sendable {
    case idle
    case waiting
    case failed(String)
}

// MARK: - State machine

struct OnboardingFlow: Equatable {
    private(set) var step: OnboardingStep = .welcome
    private(set) var outcome: OnboardingOutcome?
    private(set) var hasInferenceKey: Bool
    private(set) var hasManagementKey = false
    private(set) var signIn: SignInPhase = .idle
    private(set) var pasteError: String?

    init(hasInferenceKey: Bool) {
        self.hasInferenceKey = hasInferenceKey
    }

    var stepNumber: Int { step.rawValue + 1 }
    var stepCount: Int { OnboardingStep.allCases.count }
    var isFinished: Bool { outcome != nil }
    var canSkip: Bool { !isFinished }

    var primaryTitle: String {
        switch step {
        case .welcome: return "Get Started"
        case .inferenceKey: return hasInferenceKey ? "Continue" : "Continue without a key"
        case .managementKey: return hasManagementKey ? "Finish" : "Finish without credits"
        }
    }

    mutating func advance() {
        guard !isFinished else { return }
        switch step {
        case .welcome: step = .inferenceKey
        case .inferenceKey: step = .managementKey
        case .managementKey: outcome = .completed
        }
    }

    mutating func back() {
        guard !isFinished, let previous = OnboardingStep(rawValue: step.rawValue - 1) else { return }
        step = previous
    }

    mutating func skip() {
        guard !isFinished else { return }
        outcome = .skipped
    }

    mutating func inferenceKeySaved() {
        guard !isFinished else { return }
        hasInferenceKey = true
        signIn = .idle
        pasteError = nil
    }

    mutating func managementKeySaved() {
        guard !isFinished else { return }
        hasManagementKey = true
    }

    mutating func signInStarted() { if !isFinished { signIn = .waiting } }
    mutating func signInCancelled() { signIn = .idle }
    mutating func signInFailed(_ message: String) { if !isFinished { signIn = .failed(message) } }
    mutating func pasteFailed(_ message: String) { pasteError = message }
}

enum OnboardingCopy {
    static let welcomeTitle = "Welcome to ORB"
    static let welcomeBody = "Browse and compare every OpenRouter model, chat with them, run agents, generate images, video and speech, and test models side by side."
    static let browsingNote = "You can browse models without any key. A key is only needed to chat, run agents or generate."
    static let inferenceExplanation = "An inference key lets ORB send requests on your behalf: chat, agents and generation. It is what you need to get started."
    static let managementExplanation = "A management key is optional. It only unlocks account credits and usage in ORB, and ORB never uses it for chat or generation. Skip this if you do not need a balance display."
    static let storageNote = "Keys are stored in the macOS Keychain on this Mac and never shown again."
}

// MARK: - Persistence seam

protocol OnboardingOutcomeStore: Sendable {
    var outcome: OnboardingOutcome? { get }
    func record(_ outcome: OnboardingOutcome)
    func reset()
}

struct UserDefaultsOnboardingStore: OnboardingOutcomeStore, @unchecked Sendable {
    static let key = "orb.onboarding.outcome"
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var outcome: OnboardingOutcome? {
        defaults.string(forKey: Self.key).flatMap(OnboardingOutcome.init(rawValue:))
    }
    func record(_ outcome: OnboardingOutcome) { defaults.set(outcome.rawValue, forKey: Self.key) }
    func reset() { defaults.removeObject(forKey: Self.key) }
}

enum OnboardingGate {
    static let reviewModeKey = "orb.reviewMode"
    /// `-orb.showOnboarding YES` re-shows the sheet for testing.
    static let forceKey = "orb.showOnboarding"

    static func shouldPresent(outcome: OnboardingOutcome?, reviewMode: Bool, forced: Bool) -> Bool {
        if forced { return true }
        return outcome == nil && !reviewMode
    }

    static func isReviewMode(defaults: UserDefaults = .standard) -> Bool { defaults.bool(forKey: reviewModeKey) }
    static func isForced(defaults: UserDefaults = .standard) -> Bool { defaults.bool(forKey: forceKey) }
}

// MARK: - Key status (existence only)

@MainActor
final class KeyStatusModel: ObservableObject {
    /// nil = unknown (review mode: the store is deliberately never consulted).
    @Published private(set) var hasInferenceKey: Bool?
    private let store: any CredentialSecretStore
    private let reviewMode: Bool

    init(
        store: any CredentialSecretStore = KeychainCredentialStore(),
        reviewMode: Bool = OnboardingGate.isReviewMode()
    ) {
        self.store = store
        self.reviewMode = reviewMode
        refresh()
    }

    var needsKey: Bool { NeedsKeyContent.isVisible(hasInferenceKey: hasInferenceKey) }

    func refresh() {
        guard !reviewMode else { hasInferenceKey = nil; return }
        let present = store.hasSecret(forReference: CredentialRole.inference.keychainAccount)
        if hasInferenceKey != present { hasInferenceKey = present }
    }
}

// MARK: - Sign-in seam

protocol OnboardingSignIn: Sendable {
    func begin() throws -> URL
    func complete() async throws
    func cancel()
}

/// Production adapter over the existing `PKCECoordinator`: the key is
/// delivered only into the credential store, never returned.
struct PKCEOnboardingSignIn: OnboardingSignIn {
    private let coordinator: PKCECoordinator
    init(store: any CredentialSecretStore) {
        coordinator = PKCECoordinator(store: store, keyLabel: "ORB")
    }
    func begin() throws -> URL { try coordinator.prepareAuthorization() }
    func complete() async throws { _ = try await coordinator.completeAuthorization() }
    func cancel() { coordinator.cancel() }
}

// MARK: - Controller

@MainActor
final class OnboardingController: ObservableObject {
    @Published private(set) var flow: OnboardingFlow
    @Published var pastedInferenceKey = ""
    @Published var managementDraft = ""
    @Published private(set) var managementError: String?

    private let credentials: any CredentialSecretStore
    private let outcomeStore: any OnboardingOutcomeStore
    private let makeSignIn: () -> any OnboardingSignIn
    private let reviewMode: Bool
    private let openURL: (URL) -> Void
    private var activeSignIn: (any OnboardingSignIn)?
    private var signInTask: Task<Void, Error>?

    static let reviewModeMessage = "Review mode is on: ORB will not read or write the Keychain."

    init(
        credentials: any CredentialSecretStore = KeychainCredentialStore(),
        outcomeStore: any OnboardingOutcomeStore = UserDefaultsOnboardingStore(),
        makeSignIn: (() -> any OnboardingSignIn)? = nil,
        reviewMode: Bool = OnboardingGate.isReviewMode(),
        openURL: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }
    ) {
        self.credentials = credentials
        self.outcomeStore = outcomeStore
        self.makeSignIn = makeSignIn ?? { PKCEOnboardingSignIn(store: credentials) }
        self.reviewMode = reviewMode
        self.openURL = openURL
        let present = reviewMode ? false : credentials.hasSecret(forReference: CredentialRole.inference.keychainAccount)
        self.flow = OnboardingFlow(hasInferenceKey: present)
    }

    // MARK: Navigation

    func advance() {
        flow.advance()
        persistIfFinished()
    }

    func back() { flow.back() }

    func skip() {
        cancelSignIn()
        flow.skip()
        persistIfFinished()
    }

    private func persistIfFinished() {
        guard let outcome = flow.outcome else { return }
        // Idempotent: only the first transition is recorded.
        if outcomeStore.outcome == nil { outcomeStore.record(outcome) }
    }

    // MARK: Sign in with OpenRouter (PKCE)

    func signInWithOpenRouter() async {
        guard !reviewMode else {
            flow.signInFailed(Self.reviewModeMessage)
            return
        }
        guard flow.signIn != .waiting else { return }
        let signIn = makeSignIn()
        let url: URL
        do {
            url = try signIn.begin()
        } catch {
            flow.signInFailed(error.localizedDescription)
            return
        }
        activeSignIn = signIn
        flow.signInStarted()
        openURL(url)
        let task = Task { try await signIn.complete() }
        signInTask = task
        defer { activeSignIn = nil; signInTask = nil }
        do {
            try await task.value
            if credentials.hasSecret(forReference: CredentialRole.inference.keychainAccount) {
                flow.inferenceKeySaved()
            } else {
                flow.signInFailed("Sign-in finished but no key was saved. Paste a key instead.")
            }
        } catch {
            // A user cancel already reset the phase; don't overwrite it.
            guard flow.signIn == .waiting else { return }
            if error is CancellationError { flow.signInCancelled() } else { flow.signInFailed(error.localizedDescription) }
        }
    }

    func cancelSignIn() {
        let wasWaiting = flow.signIn == .waiting
        activeSignIn?.cancel()
        signInTask?.cancel()
        if wasWaiting { flow.signInCancelled() }
    }

    // MARK: Paste fallbacks

    func savePastedInferenceKey() {
        let trimmed = pastedInferenceKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !reviewMode else { flow.pasteFailed(Self.reviewModeMessage); return }
        if let error = credentials.saveSecret(trimmed, forReference: CredentialRole.inference.keychainAccount) {
            flow.pasteFailed(error)
        } else {
            pastedInferenceKey = ""
            flow.inferenceKeySaved()
        }
    }

    func saveManagementKey() {
        let trimmed = managementDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !reviewMode else { managementError = Self.reviewModeMessage; return }
        if let error = credentials.saveSecret(trimmed, forReference: CredentialRole.management.keychainAccount) {
            managementError = error
        } else {
            managementDraft = ""
            managementError = nil
            flow.managementKeySaved()
        }
    }
}

// MARK: - Needs-key content (Chat / Agent / Generate)

enum NeedsKeyStudio: CaseIterable, Equatable {
    case chat, agent, generate
}

struct NeedsKeyContent: Equatable {
    var title: String
    var message: String
    var systemImage: String
    var actionTitle: String

    static func make(for studio: NeedsKeyStudio) -> NeedsKeyContent {
        switch studio {
        case .chat:
            return NeedsKeyContent(
                title: "Add a key to start chatting",
                message: "Chat sends your messages to OpenRouter, so it needs an inference API key. Your past conversations stay readable without one.",
                systemImage: "bubble.left.and.text.bubble.right",
                actionTitle: "Open Settings"
            )
        case .agent:
            return NeedsKeyContent(
                title: "Add a key to run the agent",
                message: "The agent calls models and tools through OpenRouter, so it needs an inference API key before it can work.",
                systemImage: "wand.and.stars",
                actionTitle: "Open Settings"
            )
        case .generate:
            return NeedsKeyContent(
                title: "Add a key to generate",
                message: "Images, video, speech and embeddings are generated through OpenRouter and need an inference API key.",
                systemImage: "photo.on.rectangle.angled",
                actionTitle: "Open Settings"
            )
        }
    }

    /// Only when the key is KNOWN missing: unknown (review mode) never nags.
    static func isVisible(hasInferenceKey: Bool?) -> Bool { hasInferenceKey == false }
}

extension SidebarSection {
    var needsKeyStudio: NeedsKeyStudio? {
        switch self {
        case .chat: return .chat
        case .agent: return .agent
        case .images, .video, .speech, .files, .embeddings: return .generate
        default: return nil
        }
    }
}

/// Wraps an existing studio view; adds the banner above it and nothing else.
struct NeedsKeyGate<Content: View>: View {
    let studio: NeedsKeyStudio
    @ViewBuilder var content: () -> Content
    @StateObject private var status = KeyStatusModel()
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 0) {
            if status.needsKey {
                NeedsKeyBanner(content: .make(for: studio)) { SettingsPane.accounts.store(); openSettings() }
            }
            content()
        }
        .onAppear { status.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            status.refresh()
        }
    }
}

struct NeedsKeyBanner: View {
    let content: NeedsKeyContent
    let action: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: ORBMetrics.spacingSM) {
            Image(systemName: content.systemImage)
                .font(.title2)
                .foregroundStyle(ORBTheme.accent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(content.title).font(ORBFont.headline)
                Text(content.message)
                    .font(ORBFont.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: ORBMetrics.spacingSM)
            Button(content.actionTitle, action: action)
                .buttonStyle(.borderedProminent)
                .tint(ORBTheme.accent)
                .help("Open Settings to add your OpenRouter API key")
        }
        .padding(ORBMetrics.spacingSM)
        .background(ORBTheme.accentSubtle)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Sheet

struct OnboardingView: View {
    @StateObject private var controller: OnboardingController
    let onFinish: () -> Void

    @MainActor
    init(controller: OnboardingController? = nil, onFinish: @escaping () -> Void) {
        _controller = StateObject(wrappedValue: controller ?? OnboardingController())
        self.onFinish = onFinish
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                switch controller.flow.step {
                case .welcome: welcomeStep
                case .inferenceKey: inferenceStep
                case .managementKey: managementStep
                }
            }
            .padding(ORBMetrics.spacingLG)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider()
            footer
        }
        .frame(width: 560, height: 520)
        .interactiveDismissDisabled()
        .onChange(of: controller.flow.outcome) { _, outcome in
            if outcome != nil { onFinish() }
        }
    }

    private var header: some View {
        HStack {
            Text("Step \(controller.flow.stepNumber) of \(controller.flow.stepCount)")
                .font(ORBFont.footnote)
                .foregroundStyle(.secondary)
            Spacer()
            HStack(spacing: 6) {
                ForEach(OnboardingStep.allCases, id: \.self) { step in
                    Circle()
                        .fill(step.rawValue <= controller.flow.step.rawValue ? ORBTheme.accent : Color.primary.opacity(0.15))
                        .frame(width: 8, height: 8)
                }
            }
            .accessibilityHidden(true)
        }
        .padding(.horizontal, ORBMetrics.spacingLG)
        .padding(.vertical, ORBMetrics.spacingSM)
    }

    // MARK: Steps

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: ORBMetrics.spacingMD) {
            Image(systemName: "sparkles")
                .orbFont(size: 36)
                .foregroundStyle(ORBTheme.accent)
                .accessibilityHidden(true)
            Text(OnboardingCopy.welcomeTitle).font(ORBFont.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text(OnboardingCopy.welcomeBody).font(ORBFont.body)
            ORBCard {
                Label(OnboardingCopy.browsingNote, systemImage: "checkmark.seal")
                    .font(ORBFont.footnote)
            }
        }
    }

    private var inferenceStep: some View {
        VStack(alignment: .leading, spacing: ORBMetrics.spacingMD) {
            Text("Add your inference key").font(ORBFont.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text(OnboardingCopy.inferenceExplanation).font(ORBFont.body)

            if controller.flow.hasInferenceKey {
                Label("Key saved", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(ORBTheme.success)
                    .font(ORBFont.headline)
            } else {
                signInControls
                Divider()
                Text("Or paste a key").font(ORBFont.footnote.weight(.semibold))
                HStack {
                    SecureField("sk-or-v1-…", text: $controller.pastedInferenceKey)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { controller.savePastedInferenceKey() }
                        .accessibilityLabel("Inference API key")
                    Button("Save Key") { controller.savePastedInferenceKey() }
                        .disabled(controller.pastedInferenceKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if let error = controller.flow.pasteError {
                    Text(error).font(ORBFont.caption).foregroundStyle(ORBTheme.danger)
                }
            }
            Text(OnboardingCopy.storageNote).font(ORBFont.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var signInControls: some View {
        switch controller.flow.signIn {
        case .waiting:
            HStack(spacing: ORBMetrics.spacingXS) {
                ProgressView().controlSize(.small)
                Text("Waiting for you to approve in your browser…").font(ORBFont.footnote)
                Spacer()
                Button("Cancel") { controller.cancelSignIn() }
            }
        case .idle, .failed:
            Button {
                Task { await controller.signInWithOpenRouter() }
            } label: {
                Label("Sign in with OpenRouter", systemImage: "person.badge.key")
            }
            .buttonStyle(.borderedProminent)
            .tint(ORBTheme.accent)
            .controlSize(.large)
            .help("Opens openrouter.ai in your browser to create a key for ORB")
            if case .failed(let message) = controller.flow.signIn {
                Text(message).font(ORBFont.caption).foregroundStyle(ORBTheme.danger)
            }
        }
    }

    private var managementStep: some View {
        VStack(alignment: .leading, spacing: ORBMetrics.spacingMD) {
            Text("Credits and usage (optional)").font(ORBFont.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text(OnboardingCopy.managementExplanation).font(ORBFont.body)
            if controller.flow.hasManagementKey {
                Label("Management key saved", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(ORBTheme.success)
                    .font(ORBFont.headline)
            } else {
                HStack {
                    SecureField("Management key", text: $controller.managementDraft)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { controller.saveManagementKey() }
                        .accessibilityLabel("Management API key")
                    Button("Save Key") { controller.saveManagementKey() }
                        .disabled(controller.managementDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if let error = controller.managementError {
                    Text(error).font(ORBFont.caption).foregroundStyle(ORBTheme.danger)
                }
            }
            Text("You can add or change either key later in Settings.")
                .font(ORBFont.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Button("Skip for now") { controller.skip() }
                .help("Close setup. You can add keys any time in Settings (⌘,)")
            Spacer()
            if controller.flow.step != .welcome {
                Button("Back") { controller.back() }
            }
            Button(controller.flow.primaryTitle) { controller.advance() }
                .buttonStyle(.borderedProminent)
                .tint(ORBTheme.accent)
                .keyboardShortcut(.defaultAction)
        }
        .padding(ORBMetrics.spacingMD)
    }
}
