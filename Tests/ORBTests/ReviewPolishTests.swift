import Foundation
import Security
import Testing
@testable import ORB

@Suite("Review mode never reaches the Keychain")
struct ReviewModeKeychainTests {
    private let account = "review-mode-test-account"

    @Test("the review backend reads nothing and refuses every write")
    func reviewBackendIsInert() {
        let backend = ReviewModeKeychainBackend()
        #expect(KeychainSecrets.read(account, backend: backend) == nil)
        #expect(KeychainSecrets.exists(account, backend: backend) == false)
        // A refused save reports an error instead of claiming success.
        #expect(KeychainSecrets.save(account, "sk-or-test", backend: backend) != nil)
        #expect(KeychainSecrets.read(account, backend: backend) == nil)
        #expect(KeychainSecrets.legacyAccounts(backend: backend).isEmpty)
    }

    @Test("the default backend follows the review-mode flag")
    func defaultBackendFollowsFlag() throws {
        let name = "orb.tests.review.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }

        #expect(KeychainSecrets.defaultBackend(defaults: defaults) is SystemKeychainBackend)
        defaults.set(true, forKey: KeychainSecrets.reviewModeKey)
        #expect(KeychainSecrets.defaultBackend(defaults: defaults) is ReviewModeKeychainBackend)
    }

    @Test("both review-mode flags name the same defaults key")
    func reviewModeKeysAgree() {
        #expect(KeychainSecrets.reviewModeKey == OnboardingGate.reviewModeKey)
    }
}

@Suite("Polish: copy, welcome layout and default model")
struct ReviewPolishTests {
    @Test("embedded error text never produces a double full stop")
    func errorFragment() {
        #expect(ErrorCopy.fragment("Add your key first.") == "Add your key first")
        #expect(ErrorCopy.fragment("  timed out..  \n") == "timed out")
        #expect(ErrorCopy.fragment("HTTP 503") == "HTTP 503")
        #expect(ErrorCopy.fragment("v1.2") == "v1.2")
        #expect(ErrorCopy.fragment("") == "")
    }

    @Test("welcome suggestions lay out two per row, in order")
    func welcomeRows() {
        func card(_ title: String) -> PlaygroundSuggestion {
            PlaygroundSuggestion(title: title, subtitle: "", icon: "star", prompt: "")
        }
        let titles = { (rows: [[PlaygroundSuggestion]]) in rows.map { $0.map(\.title) } }
        #expect(titles(PlaygroundWelcome.rows([])) == [])
        #expect(titles(PlaygroundWelcome.rows(["a", "b", "c", "d"].map(card))) == [["a", "b"], ["c", "d"]])
        #expect(titles(PlaygroundWelcome.rows(["a", "b", "c"].map(card))) == [["a", "b"], ["c"]])
    }

    @Test("chat falls back to a favourite before any other model")
    func chatFallbackOrder() {
        let catalog = ["a/first", "b/second", "c/third"]
        #expect(PlaygroundModelDefaults.chatFallback(
            catalogIds: catalog, favoriteIds: ["c/third", "b/second"], selectedModelId: "a/first") == "b/second")
        #expect(PlaygroundModelDefaults.chatFallback(
            catalogIds: catalog, favoriteIds: [], selectedModelId: "c/third") == "c/third")
        #expect(PlaygroundModelDefaults.chatFallback(
            catalogIds: catalog, favoriteIds: ["gone/model"], selectedModelId: nil) == "a/first")
        #expect(PlaygroundModelDefaults.chatFallback(
            catalogIds: [], favoriteIds: [], selectedModelId: nil) == "openai/gpt-4o")
        #expect(PlaygroundModelDefaults.chatFallback(
            catalogIds: catalog + ["openai/gpt-4o"], favoriteIds: [], selectedModelId: nil) == "openai/gpt-4o")
    }
}
