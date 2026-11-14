import AppKit
import Foundation
import LocalAuthentication
import SwiftUI
import Testing

@testable import ORB

// Wave 1, track shell: SHELL-1…14, V-2, CORE-3, CORE-12 (update check),
// CORE-13 (storage & diagnostics). No network, no Keychain, no real
// UserDefaults domain: every dependency is injected.

private func shellW1Defaults() -> UserDefaults {
    UserDefaults(suiteName: "W1ShellTests-\(UUID().uuidString)")!
}

private enum ShellW1Source {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/ORB")

    static func read(_ relative: String) -> String {
        (try? String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)) ?? ""
    }

    static func files(matching predicate: (String) -> Bool) -> [(String, String)] {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        var out: [(String, String)] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            let relative = String(url.path.dropFirst(root.path.count + 1))
            if predicate(relative), let text = try? String(contentsOf: url, encoding: .utf8) {
                out.append((relative, text))
            }
        }
        return out
    }

    /// Settings and App shell files the shell track owns.
    static var settingsAndApp: [(String, String)] {
        files { path in
            path.hasPrefix("App/") || path.hasPrefix("Settings") || path == "UsageSettingsView.swift"
                || path == "NetworkTimeoutsView.swift"
        }
    }
}

// MARK: - SHELL-1 / CORE-3: one main window

@Suite("W1 shell: single main window")
struct ShellW1WindowTests {
    @Test("The main scene is a single-instance Window, not a WindowGroup")
    func singleWindowScene() {
        let app = ShellW1Source.read("ORBApp.swift")
        #expect(app.contains("Window(\"ORB\", id: ORBShell.mainWindowID)"))
        #expect(!app.contains("WindowGroup"), "a WindowGroup opens a second window (and a second ChatService pair) per orb:// link")
        #expect(app.contains("allowsAutomaticWindowTabbing = false"), "window tabs would add windows through the + button")
    }

    @Test("Menu commands reopen the main window before queueing the request")
    func commandsReopenWindow() {
        let app = ShellW1Source.read("ORBApp.swift")
        #expect(app.contains("openWindow(id: ORBShell.mainWindowID)"))
        #expect(ORBShell.mainWindowID == "main")
    }
}

// MARK: - SHELL-2: text size

@Suite("W1 shell: text size")
struct ShellW1TextSizeTests {
    @Test("The text-size control is withdrawn, and no view receives a partial scale")
    func noHalfWorkingControl() {
        #expect(AppearancePrefs.TextSize.isOffered == false)
        for size in AppearancePrefs.TextSize.allCases {
            #expect(size.effectiveScale == 1, "\(size) would scale only part of the UI")
        }
    }

    @Test("Type tokens can resolve against a scale, never below the 11 pt floor")
    func tokensScale() {
        for style in ORBFont.Style.allCases {
            #expect(style.pointSize(scale: 1.3) >= style.pointSize(scale: 1))
            #expect(style.pointSize(scale: 0.5) >= ORBFont.minimumPointSize)
        }
        #expect(ORBFont.Style.body.pointSize(scale: 1.3) > ORBFont.Style.body.pointSize(scale: 1))
    }

    @MainActor
    @Test("`.orbFont(.body)` follows the environment scale")
    func modifierReadsScale() {
        func width(_ scale: CGFloat) -> CGFloat {
            let renderer = ImageRenderer(content: Text("Scaled body text").orbFont(.body).environment(\.orbTextScale, scale).fixedSize())
            return renderer.nsImage?.size.width ?? 0
        }
        #expect(width(1.3) > width(1.0))
    }
}

// MARK: - SHELL-3 / V-2: sign in with OpenRouter anywhere

private final class ShellW1FakeSignIn: OnboardingSignIn, @unchecked Sendable {
    let store: InMemoryCredentialStore
    let fails: Bool
    init(store: InMemoryCredentialStore, fails: Bool = false) { self.store = store; self.fails = fails }
    func begin() throws -> URL { URL(string: "https://openrouter.ai/auth?callback_url=http://127.0.0.1:1/callback")! }
    func complete() async throws {
        if fails { throw NSError(domain: "W1", code: 1, userInfo: [NSLocalizedDescriptionKey: "Exchange failed"]) }
        _ = store.saveSecret("sk-or-v1-fake-test-key-000000000000000000", forReference: CredentialRole.inference.keychainAccount)
    }
    func cancel() {}
}

@MainActor
@Suite("W1 shell: reusable OpenRouter sign-in")
struct ShellW1SignInTests {
    @Test("A successful sign-in saves the key, brings ORB forward and confirms")
    func success() async {
        let store = InMemoryCredentialStore()
        var opened: [URL] = []
        var activated = 0
        var announced = 0
        let model = OpenRouterSignInModel(
            credentials: store, makeSignIn: { ShellW1FakeSignIn(store: store) }, reviewMode: false,
            openURL: { opened.append($0) }, activateApp: { activated += 1 }, announceSuccess: { announced += 1 }
        )
        let ok = await model.signIn()
        #expect(ok)
        #expect(opened.count == 1)
        #expect(activated == 1 && announced == 1)
        #expect(model.completedCount == 1)
        #expect(model.phase == .idle)
        let status = KeyStatusModel(store: store, reviewMode: false)
        #expect(status.needsKey == false)
    }

    @Test("A failed exchange shows a message and does not claim success")
    func failure() async {
        let store = InMemoryCredentialStore()
        var activated = 0
        let model = OpenRouterSignInModel(
            credentials: store, makeSignIn: { ShellW1FakeSignIn(store: store, fails: true) }, reviewMode: false,
            openURL: { _ in }, activateApp: { activated += 1 }, announceSuccess: {}
        )
        #expect(await model.signIn() == false)
        #expect(model.failureMessage == "Exchange failed")
        #expect(activated == 0 && model.completedCount == 0)
    }

    @Test("Review mode never starts a browser flow")
    func reviewMode() async {
        var opened = 0
        let model = OpenRouterSignInModel(
            credentials: InMemoryCredentialStore(), makeSignIn: nil, reviewMode: true,
            openURL: { _ in opened += 1 }, activateApp: {}, announceSuccess: {}
        )
        #expect(await model.signIn() == false)
        #expect(opened == 0)
        #expect(model.failureMessage == OnboardingController.reviewModeMessage)
    }

    @Test("Onboarding sign-in brings ORB back to the front on success")
    func onboardingActivates() async {
        let store = InMemoryCredentialStore()
        var activated = 0
        let controller = OnboardingController(
            credentials: store, outcomeStore: UserDefaultsOnboardingStore(defaults: shellW1Defaults()),
            makeSignIn: { ShellW1FakeSignIn(store: store) }, reviewMode: false,
            openURL: { _ in }, activateApp: { activated += 1 }
        )
        await controller.signInWithOpenRouter()
        #expect(controller.flow.hasInferenceKey)
        #expect(activated == 1)
    }

    @Test("Every gated section shows the same banner with Add API Key… and Sign in")
    func needsKeyBanner() {
        for studio in NeedsKeyStudio.allCases {
            let content = NeedsKeyContent.make(for: studio)
            #expect(content.actionTitle == "Add API Key…")
            #expect(content.signInTitle == "Sign in with OpenRouter")
        }
        #expect(NeedsKeyContent.settingsPane == .accounts)
        let gated: [SidebarSection] = [.chat, .agent, .images, .video, .speech, .files, .embeddings]
        #expect(gated.allSatisfy { $0.needsKeyStudio != nil })
        #expect(SidebarSection.allModels.needsKeyStudio == nil)
    }

    @Test("Every “Settings → …” hint in the app names a real Settings tab")
    func breadcrumbsMatchTabs() throws {
        let titles = SettingsPane.allCases.map(\.title)
        let pattern = try NSRegularExpression(pattern: "Settings → ([A-Z][A-Za-z]+(?: & [A-Z][A-Za-z]+)?)")
        for (path, text) in ShellW1Source.files(matching: { _ in true }) {
            let range = NSRange(text.startIndex..., in: text)
            for match in pattern.matches(in: text, range: range) {
                guard let r = Range(match.range(at: 1), in: text) else { continue }
                let name = String(text[r])
                #expect(titles.contains(name), "\(path): “Settings → \(name)” is not a Settings tab (\(titles))")
            }
        }
    }
}

// MARK: - SHELL-4: links

@Suite("W1 shell: OpenRouter links")
struct ShellW1LinkTests {
    @Test("Management keys are created on the management-keys page")
    func managementLink() {
        #expect(OpenRouterLinks.managementKeys.absoluteString == "https://openrouter.ai/settings/management-keys")
        #expect(OpenRouterLinks.keys.path == "/settings/keys")
    }

    @Test("No management copy links to the inference-key page")
    func noWrongLink() {
        for (path, text) in ShellW1Source.settingsAndApp + [("SettingsView.swift", ShellW1Source.read("SettingsView.swift"))] {
            let lines = text.components(separatedBy: .newlines)
            for (index, line) in lines.enumerated() where line.contains("openrouter.ai/settings/keys") {
                let window = lines[max(0, index - 3)...min(lines.count - 1, index + 1)].joined()
                #expect(!window.localizedCaseInsensitiveContains("management"), "\(path):\(index + 1)")
            }
        }
    }
}

// MARK: - SHELL-5: credit freshness

@MainActor
@Suite("W1 shell: sidebar credits stay fresh")
struct ShellW1CreditsTests {
    private final class Clock: @unchecked Sendable { var now = Date(timeIntervalSince1970: 1_000_000) }
    private final class Counter: @unchecked Sendable { var calls = 0 }

    private func service(clock: Clock, counter: Counter) -> AccountService {
        let store = InMemoryCredentialStore()
        _ = store.saveSecret("sk-or-v1-management-test-000000000000000", forReference: CredentialRole.management.keychainAccount)
        let profile = CredentialProfile(managementKeyReference: CredentialRole.management.keychainAccount)
        return AccountService(profile: profile, secretStore: store, dataLoader: { request in
            counter.calls += 1
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(#"{"data":{"total_credits":10.0,"total_usage":2.0}}"#.utf8), response)
        }, now: { clock.now })
    }

    @Test("Within the TTL nothing refetches; after it, focus refetches")
    func ttl() async {
        let clock = Clock(), counter = Counter()
        let account = service(clock: clock, counter: counter)
        await account.fetchCredits()
        #expect(counter.calls == 1)
        clock.now += 30
        #expect(!account.shouldRefreshCredits(now: clock.now))
        await account.refreshCreditsIfStale()
        #expect(counter.calls == 1)
        clock.now += AccountService.creditsTTL
        #expect(account.shouldRefreshCredits(now: clock.now))
        await account.refreshCreditsIfStale()
        #expect(counter.calls == 2)
    }

    @Test("Recorded spend refetches, throttled to one fetch per interval")
    func spend() async {
        let clock = Clock(), counter = Counter()
        let account = service(clock: clock, counter: counter)
        account.noteLedgerRevision(0)
        await account.fetchCredits()
        clock.now += 2
        #expect(!account.shouldRefreshCredits(now: clock.now, ledgerRevision: 1), "too soon after the last fetch")
        #expect(account.balanceLags(ledgerRevision: 1))
        clock.now += AccountService.spendRefreshInterval
        await account.refreshCreditsIfStale(ledgerRevision: 1)
        #expect(counter.calls == 2)
        #expect(!account.balanceLags(ledgerRevision: 1))
        #expect(!account.shouldRefreshCredits(now: clock.now, ledgerRevision: 1))
    }

    @Test("No management key never fetches")
    func noKey() {
        let account = AccountService(profile: CredentialProfile(managementKeyReference: CredentialRole.management.keychainAccount),
                                     secretStore: InMemoryCredentialStore())
        #expect(!account.shouldRefreshCredits(now: Date(), ledgerRevision: 3))
    }

    @Test("The chip writes money with the shared formatter")
    func chipMoney() {
        let state = AccountChipState.make(hasManagementKey: true, remaining: 1234.5, isLoading: false, hasError: false)
        #expect(state.title == "$1,234.50")
    }
}

// MARK: - SHELL-6: ⌘F follows the section

@Suite("W1 shell: Find routing")
struct ShellW1FindTests {
    @Test("Browser sections search in place; Chat/Agent search sessions; others have no Find")
    func routing() {
        #expect(FindRouting.target(for: .favorites, hasSessionSearch: false) == .browserSearch(.favorites))
        #expect(FindRouting.target(for: .newThisWeek, hasSessionSearch: false) == .browserSearch(.newThisWeek))
        #expect(FindRouting.target(for: .chat, hasSessionSearch: true) == .sessionSearch)
        #expect(FindRouting.target(for: .agent, hasSessionSearch: true) == .sessionSearch)
        #expect(FindRouting.target(for: .images, hasSessionSearch: false) == .unavailable)
        #expect(FindRouting.target(for: nil, hasSessionSearch: true) == .sessionSearch)
        #expect(FindRouting.target(for: nil, hasSessionSearch: false) == .browserSearch(.allModels))
    }
}

// MARK: - SHELL-7: App Lock

@MainActor
@Suite("W1 shell: App Lock friction")
struct ShellW1AppLockTests {
    @Test("Cancelling the system prompt is not an error")
    func cancelIsSilent() async {
        let lock = AppLock(defaults: shellW1Defaults(), authenticate: { _ in .cancelled })
        await lock.unlock()
        #expect(!lock.isUnlocked)
        #expect(lock.lastFailureMessage == nil)
        #expect(AppLock.result(for: LAError(.userCancel)) == .cancelled)
        #expect(AppLock.result(for: LAError(.systemCancel)) == .cancelled)
        #expect(AppLock.result(for: LAError(.appCancel)) == .cancelled)
        #expect(AppLock.result(for: LAError(.authenticationFailed)) == .failed)
    }

    @Test("Copy is right with and without Touch ID")
    func copy() {
        #expect(LockCopy.prompt(biometric: "Touch ID") == "Unlock with Touch ID or your Mac password.")
        #expect(LockCopy.prompt(biometric: nil) == "Unlock with your Mac password.")
        #expect(!LockCopy.settingsDescription(biometric: nil).contains("Password or"))
    }

    @Test("The lock screen asks by itself once per lock episode, only while ORB is active")
    func autoPrompt() async {
        var calls = 0
        let lock = AppLock(defaults: shellW1Defaults(), authenticate: { _ in calls += 1; return .cancelled })
        #expect(!lock.shouldAutoPrompt(appIsActive: false))
        await lock.autoPromptIfNeeded(appIsActive: true)
        await lock.autoPromptIfNeeded(appIsActive: true)
        #expect(calls == 1, "a cancel must not re-prompt on the next activation")
        await lock.unlock()
        #expect(calls == 2, "the Unlock button still works")
    }

    @Test("Relocking re-arms the automatic prompt")
    func rearm() async {
        var calls = 0
        let lock = AppLock(defaults: shellW1Defaults(), authenticate: { _ in calls += 1; return .success })
        await lock.autoPromptIfNeeded(appIsActive: true)
        #expect(lock.isUnlocked)
        lock.lock()
        #expect(lock.isLocked)
        await lock.autoPromptIfNeeded(appIsActive: true)
        #expect(calls == 2 && lock.isUnlocked)
    }

    @Test("Lock ORB has an unclaimed shortcut and the menus are disabled while locked")
    func lockCommand() {
        #expect(ShortcutCommand.lockNow.combo.display == "⌃⌘L")
        let combos = ShellShortcuts.allBoundCombos
        #expect(Set(combos).count == combos.count)
        let app = ShellW1Source.read("ORBApp.swift")
        #expect(app.contains(".shortcut(.lockNow)"))
        #expect(app.contains(".disabled(locked)"))
        #expect(ShellW1Source.read("App/ShortcutTable.swift").contains("lock.isLocked ? nil : shell.focusedModelID"))
    }
}

// MARK: - SHELL-8: palette

@Suite("W1 shell: command palette")
struct ShellW1PaletteTests {
    private func index() -> PaletteIndex {
        PaletteIndex(
            favoriteModels: [PaletteModel(id: "anthropic/claude-fav", name: "Claude Favourite")],
            conversations: [
                PaletteConversation(id: UUID(), title: "Old but active", mode: .chat,
                                    createdAt: Date(timeIntervalSince1970: 0), lastActivityAt: Date(timeIntervalSince1970: 10_000)),
                PaletteConversation(id: UUID(), title: "Newer, idle", mode: .chat,
                                    createdAt: Date(timeIntervalSince1970: 5_000)),
            ],
            catalogModels: [
                PaletteModel(id: "anthropic/claude-fav", name: "Claude Favourite"),
                PaletteModel(id: "anthropic/claude-sonnet", name: "Claude Sonnet"),
                PaletteModel(id: "openai/gpt-4o", name: "GPT-4o"),
            ]
        )
    }

    @Test("Typing searches the whole catalog, favourites first, without duplicates")
    func catalog() {
        let models = index().results(query: "claude").first { $0.group == .models }?.items ?? []
        #expect(models.map(\.subtitle) == ["anthropic/claude-fav", "anthropic/claude-sonnet"])
        let gpt = index().results(query: "gpt").first { $0.group == .models }?.items.first
        #expect(gpt?.action == .selectModel("openai/gpt-4o"))
        let empty = index().results(query: "").first { $0.group == .models }?.items ?? []
        #expect(empty.count == 1, "an empty query lists favourites only")
    }

    @Test("Recent conversations sort by last activity")
    func recency() {
        let titles = index().results(query: "").first { $0.group == .conversations }?.items.map(\.title)
        #expect(titles == ["Old but active", "Newer, idle"])
    }

    @Test("Palette actions include Compare, Export, Settings panes, Copy Model ID and Lock")
    func actions() {
        var idx = index()
        idx.focusedModelID = "openai/gpt-4o"
        idx.canLock = true
        let actions = idx.results(query: "").first { $0.group == .actions }?.items ?? []
        let ids = Set(actions.map(\.id))
        for id in ["act.compare", "act.export.csv", "act.export.json", "act.settings.accounts", "act.copyModelID", "act.lock", "act.updates"] {
            #expect(ids.contains(id), "missing \(id)")
        }
        #expect(actions.first { $0.id == "act.lock" }?.localCommand == .lock)
        #expect(actions.first { $0.id == "act.settings.usage" }?.localCommand == .openSettingsPane(.usage))
        let plain = index().results(query: "").first { $0.group == .actions }?.items ?? []
        #expect(!plain.contains { $0.id == "act.lock" || $0.id == "act.copyModelID" })
    }

    @Test("Selected rows use onAccent, which passes 4.5:1 on every accent", arguments: ORBAppearance.allCases)
    func selectedContrast(appearance: ORBAppearance) {
        for accent in AccentChoice.allCases {
            let ratio = ORBRGB.contrast(ORBPalette.onAccent.rgb(appearance), accent.palette.rgb(appearance))
            #expect(ratio >= 4.5, "\(accent) \(appearance): \(ratio)")
        }
        let palette = ShellW1Source.read("App/CommandPalette.swift")
        #expect(!palette.contains("Color.white"))
        #expect(palette.contains(".onHover"))
    }
}

// MARK: - SHELL-9: money

@Suite("W1 shell: money formatting")
struct ShellW1MoneyTests {
    @Test("One formatter: zero, sub-cent, unknown, grouping, sign")
    func format() {
        #expect(ORBMoney.format(0) == "$0.00")
        #expect(ORBMoney.format(nil) == "—")
        #expect(ORBMoney.format(.nan) == "—")
        #expect(ORBMoney.format(0.0042) == "$0.0042")
        #expect(ORBMoney.format(12.4) == "$12.40")
        #expect(ORBMoney.format(1234.5) == "$1,234.50")
        #expect(ORBMoney.format(-3) == "-$3.00")
        #expect(UsageSettingsView.money(0) == "$0.00")
        #expect(UsageSettingsView.money(0.0042) == "$0.0042")
    }

    @Test("Settings has no private currency formatter and labels its data sources")
    func singleFormatter() {
        let settings = ShellW1Source.read("SettingsView.swift")
        #expect(!settings.contains("func formatCurrency"))
        #expect(!settings.contains("String(format: \"$"))
        #expect(settings.contains("OpenRouter Account · Last 30 Days"))
        #expect(UsageSettingsView.title == "Recorded on this Mac")
    }
}

// MARK: - SHELL-10: settings consistency

@Suite("W1 shell: settings consistency")
struct ShellW1SettingsTests {
    @Test("Settings and App files use tokens: no raw colours, no hand-sized headers")
    func tokensOnly() throws {
        let raw = try NSRegularExpression(pattern: #"Color\.(red|green|orange|blue|purple)\b|\.foregroundStyle\(\.(red|green|orange|blue|purple)\)|Color\(red:|orbFont\(size: 17|\.font\(\.title3\.weight|\.font\(\.headline\)"#)
        for (path, text) in ShellW1Source.settingsAndApp + [("SettingsView.swift", ShellW1Source.read("SettingsView.swift"))] {
            let hits = raw.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
            #expect(hits == 0, "\(path) has \(hits) raw colour/header styles")
        }
    }

    @Test("Five tabs; Network folded into Advanced; stale values still land")
    func panes() {
        #expect(SettingsPane.allCases.map(\.title) == ["General", "Accounts & Keys", "Usage & Credits", "MCP", "Advanced"])
        #expect(SettingsPane.network.visiblePane == .advanced)
        let d = shellW1Defaults()
        SettingsPane.network.store(in: d)
        #expect(SettingsPane.restore(from: d) == .advanced)
        #expect(SettingsPane.fromLegacy("Network") == .advanced)
    }

    @Test("Both Remove Key buttons are bordered destructive buttons")
    func removeButtons() {
        let settings = ShellW1Source.read("SettingsView.swift")
        #expect(settings.components(separatedBy: "Button(\"Remove Key\", role: .destructive)").count - 1 == 3)
        #expect(!settings.contains(".foregroundStyle(.red)"))
    }
}

// MARK: - SHELL-11: shortcuts and Help

@Suite("W1 shell: shortcut sheet and Help menu")
struct ShellW1ShortcutSheetTests {
    @Test("The sheet lists every bound chord, including the Conversation menu, once")
    func complete() {
        let keys = ShellShortcuts.cheatSheet.map(\.keys)
        #expect(Set(keys).count == keys.count)
        for combo in ShellShortcuts.allBoundCombos where !(1...9).contains(Int(combo.key) ?? 0) || combo.modifiers != .command {
            #expect(keys.contains(combo.display), "missing \(combo.display)")
        }
        #expect(keys.contains("⌘."))
        #expect(keys.contains("⌥⌘F"))
        #expect(ShellShortcuts.cheatSheetGroups.map(\.title).contains("Conversation"))
    }

    @Test("Sidebar tooltips show every section's shortcut")
    func tooltips() {
        #expect(ShellShortcuts.sidebarHelp(for: .embeddings) == "Embeddings (⌘0)")
        #expect(ShellShortcuts.sidebarHelp(for: .testSuite) == "Test Suite (⇧⌘E)")
        #expect(ShellShortcuts.sidebarHelp(for: .chat).hasSuffix("(⌘\(ShellShortcuts.digit(for: .chat)!))"))
    }

    @Test("Help replaces the empty ORB Help item and links to the project")
    func help() {
        let app = ShellW1Source.read("ORBApp.swift")
        #expect(app.contains("CommandGroup(replacing: .help)"))
        #expect(ORBProjectLinks.readme.absoluteString.hasPrefix("https://github.com/Eplisium/orb"))
        #expect(ShellW1Source.read("App/CommandPalette.swift").contains("ScrollView"))
    }
}

// MARK: - SHELL-12: key panels

@Suite("W1 shell: key panels")
struct ShellW1KeyPanelTests {
    private let validKey = "sk-or-v1-" + String(repeating: "a", count: 40)

    @Test("Save is enabled only for a well-formed key, in both panels")
    func validation() {
        var management = ManagementKeyPanel()
        management.draftKey = "abc"
        #expect(!management.canSave)
        #expect(management.formatHint != nil)
        management.draftKey = validKey
        #expect(management.canSave)
        #expect(management.formatHint == nil)

        var inference = InferenceKeyPanel()
        inference.draft = "abc"
        #expect(!inference.canSave)
        inference.draft = validKey
        #expect(inference.canSave)
    }

    @Test("Removing the key shows “Key removed” until the next save")
    func removed() {
        var panel = InferenceKeyPanel()
        panel.reload(hasKey: true, masked: "sk-or-v1-••••••••aaaa")
        #expect(panel.hasKey && panel.maskedKey == "sk-or-v1-••••••••aaaa")
        panel.didRemove(success: true)
        #expect(panel.status == .removed && panel.statusTitle == "Key removed")
        panel.reload(hasKey: false, masked: nil)
        #expect(panel.status == .removed, "a reload must not hide the confirmation")
        panel.didSave(masked: "x")
        #expect(panel.hasKey && panel.draft.isEmpty)
    }

    @Test("A failed removal keeps the key and explains")
    func removeFails() {
        var panel = InferenceKeyPanel()
        panel.reload(hasKey: true, masked: nil)
        panel.didRemove(success: false)
        #expect(panel.hasKey)
        #expect(panel.actionError != nil)
    }

    @Test("The pane never reads the secret during a redraw")
    func noSecretReadsInBody() {
        let settings = ShellW1Source.read("SettingsView.swift")
        #expect(settings.components(separatedBy: "KeychainManager.maskedKey").count - 1 == 2, "only reload/save read the masked key")
        #expect(!settings.contains("SettingsTab"), "dead tab enum removed")
    }
}

// MARK: - SHELL-13: PKCE callback page

@Suite("W1 shell: PKCE callback page")
struct ShellW1CallbackPageTests {
    @Test("The page hands back to ORB and never claims success before the exchange")
    func neutral() {
        let page = PKCECallbackPage.response(parsed: true)
        #expect(page.status == "200 OK")
        #expect(page.html.contains(PKCECallbackPage.returnTitle))
        #expect(!page.html.localizedCaseInsensitiveContains("success"))
        #expect(!page.html.localizedCaseInsensitiveContains("signed in"))
        #expect(page.html.contains("window.close()"))
        #expect(page.html.contains("prefers-color-scheme:dark"))
    }

    @Test("An unparseable request gets a 400 page")
    func badRequest() {
        let page = PKCECallbackPage.response(parsed: false)
        #expect(page.status == "400 Bad Request")
        #expect(page.html.contains(PKCECallbackPage.badRequestTitle))
        #expect(!page.html.contains("window.close()"))
    }
}

// MARK: - SHELL-14: motion override

@Suite("W1 shell: Reduce Motion override")
struct ShellW1MotionTests {
    @Test("“Reduce” turns orbAnimation off even when the system allows motion")
    func forcedReduce() {
        #expect(ORBMotion.resolvedAnimation(.standard, system: false, forced: true) == nil)
        #expect(ORBMotion.resolvedAnimation(.standard, system: true, forced: false) == nil)
        #expect(ORBMotion.resolvedAnimation(.standard, system: false, forced: false) != nil)
        #expect(ORBMotion.reduces(system: false, forced: true))
    }

    @Test("The appearance modifier publishes the override and the toast host honours it")
    func wiring() {
        #expect(ShellW1Source.read("SettingsLogic.swift").contains(".environment(\\.orbForcesReducedMotion"))
        #expect(ShellW1Source.read("DesignSystem/Components/ToastCenter.swift").contains("forcedReduceMotion"))
        #expect(!ShellW1Source.read("SettingsLogic.swift").contains(".dynamicTypeSize("), "dynamicTypeSize is a no-op for macOS text")
    }
}

// MARK: - CORE-12: update check

private final class ShellW1Transport: UpdateTransport, @unchecked Sendable {
    var status: Int
    var body: Data
    var requests: [URLRequest] = []
    var fails = false
    init(status: Int, body: String) { self.status = status; self.body = Data(body.utf8) }
    func get(_ request: URLRequest) async throws -> (Data, Int) {
        requests.append(request)
        if fails { throw URLError(.notConnectedToInternet) }
        return (body, status)
    }
}

private let shellW1ReleaseJSON = #"""
{"tag_name":"v1.4.0","name":"ORB 1.4","html_url":"https://github.com/Eplisium/orb/releases/tag/v1.4.0","draft":false,"prerelease":false}
"""#

@MainActor
@Suite("W1 shell: update check")
struct ShellW1UpdateTests {
    private final class Box: @unchecked Sendable { var announced: [ReleaseInfo] = []; var reported: [UpdateCheckResult] = []; var now = Date(timeIntervalSince1970: 2_000_000) }

    private func checker(_ transport: ShellW1Transport, version: String = "1.3.2", defaults: UserDefaults = shellW1Defaults(), box: Box) -> UpdateChecker {
        UpdateChecker(currentVersion: version, transport: transport, defaults: defaults, now: { box.now },
                      announce: { box.announced.append($0) }, report: { box.reported.append($0) })
    }

    @Test("Semantic versions compare numerically, tolerate v and short forms, rank prereleases first")
    func semver() {
        #expect(SemanticVersion("v1.10.0")! > SemanticVersion("1.9.9")!)
        #expect(SemanticVersion("1.2")! == SemanticVersion("1.2.0")!)
        #expect(SemanticVersion("1.0.0-beta.2")! < SemanticVersion("1.0.0")!)
        #expect(SemanticVersion("1.0.0-beta.2")! < SemanticVersion("1.0.0-beta.10")!)
        #expect(SemanticVersion("1.0.0-alpha")! < SemanticVersion("1.0.0-alpha.1")!)
        #expect(SemanticVersion("1.0.0+build.5")! == SemanticVersion("1.0.0")!)
        #expect(SemanticVersion("banana") == nil)
        #expect(SemanticVersion("1.2.3.4") == nil)
        #expect(SemanticVersion("") == nil)
    }

    @Test("A newer release is reported with its GitHub page, over an unauthenticated GET")
    func available() async {
        let transport = ShellW1Transport(status: 200, body: shellW1ReleaseJSON)
        let box = Box()
        let result = await checker(transport, box: box).checkNow()
        guard case .available(let release) = result else { Issue.record("expected available, got \(result)"); return }
        #expect(release.version == SemanticVersion("1.4.0"))
        #expect(release.pageURL.absoluteString == "https://github.com/Eplisium/orb/releases/tag/v1.4.0")
        #expect(box.reported == [result])
        let request = transport.requests.first
        #expect(request?.url == UpdateChecker.latestReleaseURL)
        #expect(request?.url?.absoluteString == "https://api.github.com/repos/Eplisium/orb/releases/latest")
        #expect(request?.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request?.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(request?.httpMethod == "GET")
    }

    @Test("Same or older is up to date")
    func upToDate() async {
        let box = Box()
        let same = await checker(ShellW1Transport(status: 200, body: shellW1ReleaseJSON), version: "1.4.0", box: box).check()
        #expect(same == .upToDate(current: "1.4.0"))
        let newer = await checker(ShellW1Transport(status: 200, body: shellW1ReleaseJSON), version: "2.0", box: box).check()
        #expect(newer == .upToDate(current: "2.0"))
    }

    @Test("No releases yet (404) is silent in the background and not an error")
    func noReleases() async {
        let box = Box()
        let c = checker(ShellW1Transport(status: 404, body: #"{"message":"Not Found"}"#), box: box)
        let result = await c.checkIfDue()
        #expect(result == .noReleases)
        #expect(box.announced.isEmpty && box.reported.isEmpty)
        #expect(c.lastCheckDate != nil, "a completed round trip counts for the daily timer")
    }

    @Test("Background checks run daily, announce a release once, and respect the toggle")
    func daily() async {
        let defaults = shellW1Defaults()
        let box = Box()
        let transport = ShellW1Transport(status: 200, body: shellW1ReleaseJSON)
        let c = checker(transport, defaults: defaults, box: box)
        #expect(c.automaticallyChecks, "default on")
        await c.checkIfDue()
        #expect(box.announced.count == 1)
        box.now += 60 * 60
        #expect(await c.checkIfDue() == nil, "not due within a day")
        box.now += UpdateChecker.checkInterval
        await c.checkIfDue()
        #expect(transport.requests.count == 2)
        #expect(box.announced.count == 1, "the same release is announced once")
        c.automaticallyChecks = false
        box.now += UpdateChecker.checkInterval * 2
        #expect(!c.isDue(at: box.now))
    }

    @Test("Network failures and odd payloads fail quietly in the background")
    func failures() async {
        let box = Box()
        let offline = ShellW1Transport(status: 200, body: "")
        offline.fails = true
        let c = checker(offline, box: box)
        if case .failed = await c.checkIfDue() ?? .noReleases {} else { Issue.record("expected failure") }
        #expect(box.announced.isEmpty && box.reported.isEmpty)
        #expect(c.lastCheckDate == nil, "a failed check retries on the next hourly tick")
        let limited = await checker(ShellW1Transport(status: 403, body: "{}"), box: box).check()
        if case .failed(let why) = limited { #expect(why.contains("rate")) } else { Issue.record("expected failure") }
        let garbage = await checker(ShellW1Transport(status: 200, body: #"{"tag_name":"nightly"}"#), box: box).check()
        if case .failed = garbage {} else { Issue.record("expected failure") }
    }

    @Test("A release page outside github.com is replaced with the project's own")
    func pageHost() throws {
        let json = #"{"tag_name":"1.5.0","html_url":"https://evil.example/download"}"#
        let release = try UpdateChecker.parse(Data(json.utf8))
        #expect(release.pageURL.host == "github.com")
        #expect(release.pageURL.path.hasSuffix("/releases/tag/1.5.0"))
    }

    @Test("Check for Updates… lives in the app menu")
    func menu() {
        #expect(ShellW1Source.read("ORBApp.swift").contains("Button(\"Check for Updates…\")"))
    }
}

// MARK: - CORE-13: storage & diagnostics

@Suite("W1 shell: storage & diagnostics")
struct ShellW1StorageTests {
    private func tempSupport() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("W1ShellStorage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("Sizes cover the database, WAL, media and recovery backups; missing parts are zero")
    func measure() throws {
        let support = try tempSupport()
        defer { try? FileManager.default.removeItem(at: support) }
        let locations = StorageLocations.inside(support)
        #expect(StorageReport.measure(locations) == StorageReport())

        try Data(count: 4096).write(to: locations.database)
        try Data(count: 1000).write(to: locations.wal)
        try FileManager.default.createDirectory(at: locations.assets.appendingPathComponent("a/b"), withIntermediateDirectories: true)
        try Data(count: 300).write(to: locations.assets.appendingPathComponent("a/b/one.png"))
        try Data(count: 200).write(to: locations.assets.appendingPathComponent("two.mp4"))
        let backup = locations.recoveryBackups.appendingPathComponent("20261114-1")
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        try Data(count: 50).write(to: backup.appendingPathComponent("favorites.sqlite3"))

        let report = StorageReport.measure(locations)
        #expect(report.databaseBytes == 4096)
        #expect(report.walBytes == 1000)
        #expect(report.assetsBytes == 500 && report.assetFileCount == 2)
        #expect(report.recoveryBackupBytes == 50 && report.recoveryBackupCount == 1)
        #expect(report.totalBytes == 4096 + 1000 + 500 + 50)
    }

    @Test("Locations match the app's real layout")
    func layout() {
        let support = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ORB")
        let locations = StorageLocations.inside(support)
        #expect(locations.database.lastPathComponent == "favorites.sqlite3")
        #expect(locations.wal.lastPathComponent == "favorites.sqlite3-wal")
        #expect(locations.assets.lastPathComponent == "Assets")
        #expect(locations.recoveryBackups == DatabaseRecoveryBackup.container(for: locations.database))
    }

    @Test("Diagnostics hold versions, counts and sizes — no keys, paths or content")
    func diagnostics() {
        let env = DiagnosticsSummary.Environment(
            appVersion: "1.3.2", build: "42", macOS: "15.1.0", architecture: "arm64",
            appLockEnabled: true, automaticUpdateChecks: true, hasInferenceKey: true, hasManagementKey: nil
        )
        var report = StorageReport()
        report.databaseBytes = 2_000_000
        report.assetFileCount = 3
        let text = DiagnosticsSummary.make(env, storage: report)
        #expect(text.contains("ORB 1.3.2 (42)"))
        #expect(text.contains("macOS 15.1.0"))
        #expect(text.contains("Inference key configured: yes"))
        #expect(text.contains("Management key configured: unknown"))
        #expect(text.contains("Saved media: 3 files"))
        #expect(!text.contains("sk-or"))
        #expect(!text.contains(NSHomeDirectory()))
        #expect(!text.contains("/"), "no file paths at all")
    }

    @MainActor
    @Test("Measuring runs through the injected measurer")
    func model() async {
        let locations = StorageLocations.inside(URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("nope-\(UUID().uuidString)"))
        let model = StorageDiagnosticsModel(locations: locations, measure: { _ in
            var r = StorageReport(); r.databaseBytes = 7; return r
        })
        await model.refresh()
        #expect(model.report?.databaseBytes == 7)
        #expect(!model.isMeasuring)
    }
}

// MARK: - Toast links

@MainActor
@Suite("W1 shell: toast links")
struct ShellW1ToastTests {
    @Test("A toast can carry one link button")
    func link() {
        let center = ToastCenter()
        let url = URL(string: "https://github.com/Eplisium/orb/releases")!
        center.show("ORB 2.0 is available.", kind: .info, duration: 0, link: ORBToastLink(title: "View Release", url: url))
        #expect(center.toasts.first?.link == ORBToastLink(title: "View Release", url: url))
        center.show("plain", duration: 0)
        #expect(center.toasts.last?.link == nil)
    }
}
