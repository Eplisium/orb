import Foundation
import Testing

@testable import ORB

// MARK: - Test Suite user input
//
// Pure prompt composition: the user's optional run input is layered on top
// of the scenario prompt, and a run without input stays byte-identical to
// the stock prompt. Deterministic and offline: no network, no Keychain, no
// agent loop.

@Suite("Test Suite user input")
struct TestUserInputTests {

    @Test("no input leaves the scenario prompt byte-identical")
    func noInputKeepsBase() {
        #expect(TestPromptComposer.compose(base: "Build a thing.", userInput: nil) == "Build a thing.")
        #expect(TestPromptComposer.compose(base: "Build a thing.", userInput: "") == "Build a thing.")
    }

    @Test("whitespace-only input is treated as no input")
    func whitespaceOnlyInputIgnored() {
        #expect(TestPromptComposer.compose(base: "Build a thing.", userInput: "  \n\t ") == "Build a thing.")
    }

    @Test("user input is appended under its own heading")
    func inputAppended() {
        let composed = TestPromptComposer.compose(base: "Build a thing.", userInput: "Use a dark theme.")
        #expect(composed == "Build a thing.\n\nUser input for this run:\nUse a dark theme.")
    }

    @Test("input is trimmed before appending")
    func inputTrimmed() {
        let composed = TestPromptComposer.compose(base: "Base", userInput: "  keep it short  ")
        #expect(composed.hasSuffix("User input for this run:\nkeep it short"))
        #expect(!composed.contains("short  "))
    }

    @Test("the base prompt always comes first")
    func baseFirst() {
        let composed = TestPromptComposer.compose(base: "Base prompt.", userInput: "Extra.")
        #expect(composed.hasPrefix("Base prompt."))
    }
}
