import Testing
import Foundation
@testable import ORB

// MARK: - Test doubles (no Keychain, no network, no real UserDefaults)

/// Counts every call so tests can prove a store was never touched.
final class CountingCredentialStore: CredentialSecretStore, @unchecked Sendable {
    private let inner = InMemoryCredentialStore()
    private let lock = NSLock()
    private(set) var callCount = 0
    private func tick() { lock.lock(); callCount += 1; lock.unlock() }

    func secret(forReference reference: String) -> String? { tick(); return inner.secret(forReference: reference) }
    func saveSecret(_ secret: String, forReference reference: String) -> String? { tick(); return inner.saveSecret(secret, forReference: reference) }
    func deleteSecret(forReference reference: String) -> Bool { tick(); return inner.deleteSecret(forReference: reference) }
    func hasSecret(forReference reference: String) -> Bool { tick(); return inner.hasSecret(forReference: reference) }
    var allSecrets: [String: String] { inner.allSecrets }
}

/// Store that refuses every save, to exercise the failure path.
struct FailingCredentialStore: CredentialSecretStore {
    func secret(forReference reference: String) -> String? { nil }
    func saveSecret(_ secret: String, forReference reference: String) -> String? { "disk full" }
    func deleteSecret(forReference reference: String) -> Bool { false }
    func hasSecret(forReference reference: String) -> Bool { false }
}

final class InMemoryOnboardingStore: OnboardingOutcomeStore, @unchecked Sendable {
    private(set) var outcome: OnboardingOutcome?
    private(set) var recordCount = 0
    func record(_ outcome: OnboardingOutcome) { self.outcome = outcome; recordCount += 1 }
    func reset() { outcome = nil }
}

final class FakeSignIn: OnboardingSignIn, @unchecked Sendable {
    enum Behavior { case succeed(into: CredentialSecretStore), fail(Error), hang }
    var behavior: Behavior
    private(set) var beginCount = 0
    private(set) var cancelCount = 0
    init(_ behavior: Behavior) { self.behavior = behavior }

    func begin() throws -> URL {
        beginCount += 1
        return URL(string: "https://openrouter.ai/auth?callback_url=x")!
    }

    func complete() async throws {
        switch behavior {
        case .succeed(let store):
            _ = store.saveSecret("sk-or-v1-test", forReference: CredentialRole.inference.keychainAccount)
        case .fail(let error):
            throw error
        case .hang:
            try await Task.sleep(for: .seconds(30))
        }
    }

    func cancel() { cancelCount += 1 }
}

private func makeDefaults() -> UserDefaults {
    let name = "orb.tests.onboarding.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

// MARK: - Pure state machine

@Suite("Phase 3 onboarding: state machine")
struct OnboardingFlowTests {
    @Test("Starts at welcome and walks welcome → inference key → management key → done")
    func happyPath() {
        var flow = OnboardingFlow(hasInferenceKey: false)
        #expect(flow.step == .welcome)
        #expect(flow.stepNumber == 1)
        #expect(flow.stepCount == 3)
        flow.advance()
        #expect(flow.step == .inferenceKey)
        flow.advance()
        #expect(flow.step == .managementKey)
        #expect(flow.outcome == nil)
        flow.advance()
        #expect(flow.outcome == .completed)
    }

    @Test("Back never goes before welcome and is a no-op once finished")
    func backBounds() {
        var flow = OnboardingFlow(hasInferenceKey: false)
        flow.back()
        #expect(flow.step == .welcome)
        flow.advance(); flow.advance()
        flow.back()
        #expect(flow.step == .inferenceKey)
        flow.skip()
        flow.back()
        #expect(flow.step == .inferenceKey)
        #expect(flow.outcome == .skipped)
    }

    @Test("Skip is available on every step and records skipped")
    func skipAnywhere() {
        for advances in 0...2 {
            var flow = OnboardingFlow(hasInferenceKey: false)
            for _ in 0..<advances { flow.advance() }
            #expect(flow.canSkip)
            flow.skip()
            #expect(flow.outcome == .skipped)
        }
    }

    @Test("The app does not require a key: the key step can be continued without one")
    func keyStepNotBlocking() {
        var flow = OnboardingFlow(hasInferenceKey: false)
        flow.advance()
        #expect(flow.primaryTitle == "Continue without a key")
        flow.advance()
        #expect(flow.step == .managementKey)
    }

    @Test("Primary titles reflect state; management step is optional")
    func titles() {
        var flow = OnboardingFlow(hasInferenceKey: false)
        #expect(flow.primaryTitle == "Get Started")
        flow.advance()
        flow.inferenceKeySaved()
        #expect(flow.hasInferenceKey)
        #expect(flow.primaryTitle == "Continue")
        flow.advance()
        #expect(flow.primaryTitle == "Finish without credits")
        flow.managementKeySaved()
        #expect(flow.primaryTitle == "Finish")
    }

    @Test("Finished flows ignore further input")
    func finishedIsTerminal() {
        var flow = OnboardingFlow(hasInferenceKey: true)
        flow.skip()
        flow.advance()
        flow.inferenceKeySaved()
        #expect(flow.outcome == .skipped)
        #expect(flow.step == .welcome)
    }

    @Test("Sign-in phases: idle → waiting → failed/succeeded, and cancel returns to idle")
    func signInPhases() {
        var flow = OnboardingFlow(hasInferenceKey: false)
        #expect(flow.signIn == .idle)
        flow.signInStarted()
        #expect(flow.signIn == .waiting)
        flow.signInFailed("Timed out")
        #expect(flow.signIn == .failed("Timed out"))
        #expect(!flow.hasInferenceKey)
        flow.signInStarted()
        flow.signInCancelled()
        #expect(flow.signIn == .idle)
        flow.signInStarted()
        flow.inferenceKeySaved()
        #expect(flow.signIn == .idle)
        #expect(flow.hasInferenceKey)
    }

    @Test("Paste errors are cleared by a successful save")
    func pasteErrorClears() {
        var flow = OnboardingFlow(hasInferenceKey: false)
        flow.pasteFailed("boom")
        #expect(flow.pasteError == "boom")
        flow.inferenceKeySaved()
        #expect(flow.pasteError == nil)
    }

    @Test("Explanatory copy names both roles and the browsing fallback")
    func copy() {
        #expect(OnboardingCopy.inferenceExplanation.localizedCaseInsensitiveContains("chat"))
        #expect(OnboardingCopy.managementExplanation.localizedCaseInsensitiveContains("credits"))
        #expect(OnboardingCopy.managementExplanation.localizedCaseInsensitiveContains("never"))
        #expect(OnboardingCopy.browsingNote.localizedCaseInsensitiveContains("browse"))
    }
}

// MARK: - Persistence seam

@Suite("Phase 3 onboarding: persisted outcome")
struct OnboardingOutcomeStoreTests {
    @Test("UserDefaults store round-trips completed and skipped in an injected suite")
    func roundTrip() {
        let defaults = makeDefaults()
        let store = UserDefaultsOnboardingStore(defaults: defaults)
        #expect(store.outcome == nil)
        store.record(.skipped)
        #expect(store.outcome == .skipped)
        #expect(UserDefaultsOnboardingStore(defaults: defaults).outcome == .skipped)
        store.record(.completed)
        #expect(store.outcome == .completed)
        store.reset()
        #expect(store.outcome == nil)
    }

    @Test("Unknown stored values are treated as not onboarded")
    func garbage() {
        let defaults = makeDefaults()
        defaults.set("nonsense", forKey: UserDefaultsOnboardingStore.key)
        #expect(UserDefaultsOnboardingStore(defaults: defaults).outcome == nil)
    }

    @Test("Gate: shows once, never after an outcome, never in review mode, forceable")
    func gate() {
        #expect(OnboardingGate.shouldPresent(outcome: nil, reviewMode: false, forced: false))
        #expect(!OnboardingGate.shouldPresent(outcome: .completed, reviewMode: false, forced: false))
        #expect(!OnboardingGate.shouldPresent(outcome: .skipped, reviewMode: false, forced: false))
        #expect(!OnboardingGate.shouldPresent(outcome: nil, reviewMode: true, forced: false))
        #expect(OnboardingGate.shouldPresent(outcome: .completed, reviewMode: false, forced: true))
    }

    @Test("Review mode and forced flags read from injected defaults")
    func launchFlags() {
        let defaults = makeDefaults()
        #expect(!OnboardingGate.isReviewMode(defaults: defaults))
        defaults.set(true, forKey: OnboardingGate.reviewModeKey)
        #expect(OnboardingGate.isReviewMode(defaults: defaults))
        #expect(OnboardingGate.reviewModeKey == "orb.reviewMode")
        defaults.set(true, forKey: OnboardingGate.forceKey)
        #expect(OnboardingGate.isForced(defaults: defaults))
    }
}

// MARK: - Key status + Keychain isolation

@MainActor
@Suite("Phase 3 onboarding: key status and review mode")
struct KeyStatusTests {
    @Test("Reports present/absent inference key from the injected store")
    func presence() {
        let store = InMemoryCredentialStore()
        let status = KeyStatusModel(store: store, reviewMode: false)
        #expect(status.hasInferenceKey == false)
        #expect(status.needsKey)
        _ = store.saveSecret("sk", forReference: CredentialRole.inference.keychainAccount)
        status.refresh()
        #expect(status.hasInferenceKey == true)
        #expect(!status.needsKey)
    }

    @Test("Review mode never touches the credential store and never claims a key is missing")
    func reviewModeNoKeychain() {
        let store = CountingCredentialStore()
        let status = KeyStatusModel(store: store, reviewMode: true)
        status.refresh()
        #expect(store.callCount == 0)
        #expect(status.hasInferenceKey == nil)
        #expect(!status.needsKey)
    }

    @Test("Review-mode controller never reads or writes credentials, even when asked to save")
    func reviewModeController() {
        let store = CountingCredentialStore()
        let controller = OnboardingController(
            credentials: store,
            outcomeStore: InMemoryOnboardingStore(),
            makeSignIn: { FakeSignIn(.hang) },
            reviewMode: true,
            openURL: { _ in }
        )
        controller.pastedInferenceKey = "sk-or-v1-abc"
        controller.savePastedInferenceKey()
        controller.managementDraft = "sk-or-mgmt"
        controller.saveManagementKey()
        #expect(store.callCount == 0)
        #expect(store.allSecrets.isEmpty)
        #expect(controller.flow.pasteError != nil)
    }

    @Test("Review-mode sign-in is refused without starting a listener")
    func reviewModeSignIn() async {
        let fake = FakeSignIn(.hang)
        let controller = OnboardingController(
            credentials: CountingCredentialStore(),
            outcomeStore: InMemoryOnboardingStore(),
            makeSignIn: { fake },
            reviewMode: true,
            openURL: { _ in }
        )
        await controller.signInWithOpenRouter()
        #expect(fake.beginCount == 0)
        if case .failed = controller.flow.signIn {} else { Issue.record("expected failed phase") }
    }

    @Test("Initial flow seeds hasInferenceKey from the store outside review mode only")
    func seeding() {
        let store = InMemoryCredentialStore()
        _ = store.saveSecret("sk", forReference: CredentialRole.inference.keychainAccount)
        let live = OnboardingController(
            credentials: store, outcomeStore: InMemoryOnboardingStore(),
            makeSignIn: { FakeSignIn(.hang) }, reviewMode: false, openURL: { _ in }
        )
        #expect(live.flow.hasInferenceKey)
        let review = OnboardingController(
            credentials: store, outcomeStore: InMemoryOnboardingStore(),
            makeSignIn: { FakeSignIn(.hang) }, reviewMode: true, openURL: { _ in }
        )
        #expect(!review.flow.hasInferenceKey)
    }
}

// MARK: - Controller behavior

@MainActor
@Suite("Phase 3 onboarding: controller")
struct OnboardingControllerTests {
    private func make(
        credentials: CredentialSecretStore = InMemoryCredentialStore(),
        outcome: InMemoryOnboardingStore = InMemoryOnboardingStore(),
        signIn: FakeSignIn = FakeSignIn(.hang),
        opened: OpenedURLs = OpenedURLs()
    ) -> OnboardingController {
        OnboardingController(
            credentials: credentials,
            outcomeStore: outcome,
            makeSignIn: { signIn },
            reviewMode: false,
            openURL: { opened.urls.append($0) }
        )
    }

    final class OpenedURLs { var urls: [URL] = [] }

    @Test("Sign in opens the authorize URL, then succeeds when the key lands in the store")
    func signInSuccess() async {
        let store = InMemoryCredentialStore()
        let opened = OpenedURLs()
        let fake = FakeSignIn(.succeed(into: store))
        let controller = make(credentials: store, signIn: fake, opened: opened)
        await controller.signInWithOpenRouter()
        #expect(opened.urls.count == 1)
        #expect(opened.urls.first?.host == "openrouter.ai")
        #expect(controller.flow.hasInferenceKey)
        #expect(controller.flow.signIn == .idle)
    }

    @Test("Sign-in failure is reported and leaves paste fallback usable")
    func signInFailure() async {
        let controller = make(signIn: FakeSignIn(.fail(PKCEError.callbackTimeout)))
        await controller.signInWithOpenRouter()
        guard case .failed(let message) = controller.flow.signIn else {
            Issue.record("expected failed"); return
        }
        #expect(message.contains("Timed out"))
        #expect(!controller.flow.hasInferenceKey)
        controller.pastedInferenceKey = "  sk-or-v1-paste0123456789abcdef0123456789  "
        controller.savePastedInferenceKey()
        #expect(controller.flow.hasInferenceKey)
    }

    @Test("Cancelling a pending sign-in cancels the coordinator and returns to idle")
    func signInCancel() async {
        let fake = FakeSignIn(.hang)
        let controller = make(signIn: fake)
        let task = Task { await controller.signInWithOpenRouter() }
        for _ in 0..<200 where controller.flow.signIn != .waiting { await Task.yield() }
        #expect(controller.flow.signIn == .waiting)
        controller.cancelSignIn()
        await task.value
        #expect(fake.cancelCount >= 1)
        #expect(controller.flow.signIn == .idle)
    }

    @Test("Pasted inference key is trimmed, stored under the inference account, then cleared")
    func pasteInference() {
        let store = InMemoryCredentialStore()
        let controller = make(credentials: store)
        controller.pastedInferenceKey = "  sk-or-v1-0123456789abcdef0123456789abcdef \n"
        controller.savePastedInferenceKey()
        #expect(store.allSecrets == [CredentialRole.inference.keychainAccount: "sk-or-v1-0123456789abcdef0123456789abcdef"])
        #expect(controller.pastedInferenceKey.isEmpty)
        #expect(controller.flow.hasInferenceKey)
    }

    @Test("Empty paste is ignored; a failing store surfaces an error and keeps the draft out of state")
    func pasteEdgeCases() {
        let empty = make()
        empty.pastedInferenceKey = "   "
        empty.savePastedInferenceKey()
        #expect(!empty.flow.hasInferenceKey)
        #expect(empty.flow.pasteError == nil)

        let failing = make(credentials: FailingCredentialStore())
        failing.pastedInferenceKey = "sk-or-v1-0123456789abcdef0123456789abcdef"
        failing.savePastedInferenceKey()
        #expect(!failing.flow.hasInferenceKey)
        #expect(failing.flow.pasteError == "disk full")
    }

    @Test("Management key goes to the DISTINCT management account, never the inference one")
    func managementKeyRole() {
        let store = InMemoryCredentialStore()
        let controller = make(credentials: store)
        controller.managementDraft = " sk-or-v1-mgmt0123456789abcdef0123456789ab "
        controller.saveManagementKey()
        #expect(store.allSecrets == [CredentialRole.management.keychainAccount: "sk-or-v1-mgmt0123456789abcdef0123456789ab"])
        #expect(controller.managementDraft.isEmpty)
        #expect(controller.flow.hasManagementKey)
        #expect(!controller.flow.hasInferenceKey)
    }

    @Test("Finishing persists the outcome exactly once; skip persists skipped")
    func persistence() {
        let outcome = InMemoryOnboardingStore()
        let controller = make(outcome: outcome)
        controller.advance(); controller.advance(); controller.advance()
        #expect(outcome.outcome == .completed)
        #expect(outcome.recordCount == 1)
        controller.skip()
        #expect(outcome.recordCount == 1)

        let skipped = InMemoryOnboardingStore()
        let c2 = make(outcome: skipped)
        c2.skip()
        #expect(skipped.outcome == .skipped)
    }

    @Test("Skipping mid-sign-in stops the listener")
    func skipCancelsSignIn() async {
        let fake = FakeSignIn(.hang)
        let controller = make(signIn: fake)
        let task = Task { await controller.signInWithOpenRouter() }
        for _ in 0..<200 where controller.flow.signIn != .waiting { await Task.yield() }
        controller.skip()
        await task.value
        #expect(fake.cancelCount >= 1)
        #expect(controller.flow.outcome == .skipped)
    }
}

// MARK: - Needs-key empty states

@Suite("Phase 3: needs-key empty states")
struct NeedsKeyContentTests {
    @Test("Every keyed studio has distinct, non-empty copy and the Settings action")
    func content() {
        var titles = Set<String>()
        for studio in NeedsKeyStudio.allCases {
            let c = NeedsKeyContent.make(for: studio)
            #expect(!c.title.isEmpty)
            #expect(!c.message.isEmpty)
            #expect(c.actionTitle == "Open Settings")
            #expect(!c.systemImage.isEmpty)
            titles.insert(c.title)
        }
        #expect(titles.count == NeedsKeyStudio.allCases.count)
    }

    @Test("Copy mentions the inference key role, not the management key")
    func roleWording() {
        for studio in NeedsKeyStudio.allCases {
            let c = NeedsKeyContent.make(for: studio)
            #expect(c.message.localizedCaseInsensitiveContains("key"))
            #expect(!c.message.localizedCaseInsensitiveContains("management"))
        }
    }

    @Test("Banner shows only when the key is known to be missing")
    func visibility() {
        #expect(NeedsKeyContent.isVisible(hasInferenceKey: false))
        #expect(!NeedsKeyContent.isVisible(hasInferenceKey: true))
        #expect(!NeedsKeyContent.isVisible(hasInferenceKey: nil))
    }
}

// MARK: - Credits chip

@Suite("Phase 3: credits chip low-balance state")
struct CreditsChipTintTests {
    private func chip(_ remaining: Double?, key: Bool = true) -> AccountChipState {
        AccountChipState.make(hasManagementKey: key, remaining: remaining, isLoading: false, hasError: false)
    }

    @Test("Threshold is strict: exactly the threshold is not low; just below is")
    func threshold() {
        #expect(!chip(AccountChipState.lowBalanceThreshold).isLow)
        #expect(chip(AccountChipState.lowBalanceThreshold - 0.01).isLow)
        #expect(chip(0).isLow)
        #expect(!chip(250).isLow)
    }

    @Test("Low state is never colour-only: distinct symbol and wording")
    func notColourOnly() {
        let low = chip(0.25)
        let ok = chip(25)
        #expect(low.systemImage != ok.systemImage)
        #expect(low.subtitle == "Credits low")
        #expect(ok.subtitle == "Credits remaining")
        #expect(low.accessibilityValue.contains("low"))
    }

    @Test("Without a management key the chip is neutral even if a stale balance is passed")
    func neutralWithoutKey() {
        let s = chip(0, key: false)
        #expect(!s.isLow)
        #expect(s.title == "Account")
    }
}

@MainActor
@Suite("Wave 1 onboarding: key validation before save")
struct OnboardingKeyValidationTests {
    private func make(_ store: CredentialSecretStore) -> OnboardingController {
        OnboardingController(
            credentials: store, outcomeStore: InMemoryOnboardingStore(),
            makeSignIn: { FakeSignIn(.hang) }, reviewMode: false, openURL: { _ in }
        )
    }

    @Test("Malformed pasted keys are rejected without touching the store")
    func rejectsMalformed() {
        let store = CountingCredentialStore()
        let controller = make(store)
        let baseline = store.callCount
        for bad in ["hello", "sk-or-short", "sk-ant-0123456789abcdef0123456789abcdef"] {
            controller.pastedInferenceKey = bad
            controller.savePastedInferenceKey()
            #expect(controller.flow.pasteError != nil)
            #expect(!controller.flow.hasInferenceKey)
            #expect(controller.pastedInferenceKey == bad, "draft kept for correction")
            controller.managementDraft = bad
            controller.saveManagementKey()
            #expect(!controller.flow.hasManagementKey)
        }
        #expect(store.callCount == baseline)
        #expect(store.allSecrets.isEmpty)
    }
}
