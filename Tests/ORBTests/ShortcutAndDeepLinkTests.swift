import Testing
import Foundation
@testable import ORB

@Suite("Wave 1 shell: shortcut table")
struct ShortcutTableTests {
    @Test("No two menu commands share a key combination")
    func noDuplicates() {
        let combos = ShellShortcuts.allMenuCombos
        var seen: [KeyCombo: Int] = [:]
        for c in combos { seen[c, default: 0] += 1 }
        let dupes = seen.filter { $0.value > 1 }.map(\.key.display)
        #expect(dupes.isEmpty, "duplicate shortcuts: \(dupes)")
    }

    @Test("System-reserved and text-editing combos are not claimed")
    func reserved() {
        let reserved: Set<KeyCombo> = [
            .cmd("c"), .cmd("v"), .cmd("x"), .cmd("z"), .cmd("a"), .shiftCmd("z"),
            .cmd("q"), .cmd("w"), .cmd("h"), .cmd("m"), .cmd("t"), .cmd("."),
        ]
        let claimed = Set(ShellShortcuts.allMenuCombos)
        #expect(claimed.isDisjoint(with: reserved))
    }

    @Test("Every sidebar section has a shortcut, including Embeddings and Test Suite")
    func everySection() {
        for section in ShellShortcuts.sidebarOrder {
            #expect(ShellShortcuts.shortcutDisplay(for: section) != nil, "\(section.title) has no shortcut")
        }
        #expect(ShellShortcuts.shortcutDisplay(for: .embeddings) == "⌘0")
        #expect(ShellShortcuts.shortcutDisplay(for: .testSuite) == "⇧⌘E")
    }

    @Test("Model menu shortcuts and the cheat sheet agree")
    func cheatSheet() {
        #expect(ShortcutCommand.toggleFavorite.combo.display == "⌘D")
        #expect(ShortcutCommand.copyModelID.combo.display == "⇧⌘C")
        #expect(ShortcutCommand.chatWithModel.combo.display == "⌘↩")
        let keys = ShellShortcuts.cheatSheet.map(\.keys)
        #expect(Set(keys).count == keys.count)
        for command in ShortcutCommand.allCases {
            #expect(keys.contains(command.combo.display))
        }
    }
}

@Suite("Wave 1 shell: orb:// deep links")
struct DeepLinkTests {
    private func parse(_ s: String) -> DeepLink? { URL(string: s).flatMap(DeepLink.parse) }

    @Test("Model links keep slashes and colons in ids")
    func model() {
        #expect(parse("orb://model/openai/gpt-4o") == .model("openai/gpt-4o"))
        #expect(parse("orb://model/meta-llama/llama-3:free") == .model("meta-llama/llama-3:free"))
        #expect(parse("orb://model/~deepseek/deepseek-pro-latest") == .model("~deepseek/deepseek-pro-latest"))
        #expect(parse("ORB://MODEL/openai/gpt-4o") == .model("openai/gpt-4o"))
        #expect(parse("orb:model/openai/gpt-4o") == .model("openai/gpt-4o"))
    }

    @Test("Chat links with and without a model")
    func chat() {
        #expect(parse("orb://chat?model=anthropic/claude-sonnet") == .chat(model: "anthropic/claude-sonnet"))
        #expect(parse("orb://chat?model=anthropic%2Fclaude-sonnet") == .chat(model: "anthropic/claude-sonnet"))
        #expect(parse("orb://chat") == .chat(model: nil))
        #expect(parse("orb://chat?model=bad id") == nil)
    }

    @Test("Compare links split, de-duplicate and drop invalid ids")
    func compare() {
        #expect(parse("orb://compare?ids=a/1,b/2,a/1") == .compare(["a/1", "b/2"]))
        #expect(parse("orb://compare?ids=a/1,,nope,../x") == .compare(["a/1"]))
        #expect(parse("orb://compare?ids=") == nil)
        #expect(parse("orb://compare") == nil)
    }

    @Test("Wrong scheme, unknown verbs and hostile ids are rejected")
    func rejects() {
        #expect(parse("https://model/openai/gpt-4o") == nil)
        #expect(parse("orb://delete/everything") == nil)
        #expect(parse("orb://model/") == nil)
        #expect(parse("orb://model/openai/../../etc") == nil)
        #expect(parse("orb://model/javascript:alert(1)") == nil)
        #expect(parse("orb://model/" + String(repeating: "a/", count: 200)) == nil)
    }

    @Test("Canonical URLs round-trip")
    func roundTrip() {
        for link: DeepLink in [.model("openai/gpt-4o"), .chat(model: "a/b:free"), .chat(model: nil), .compare(["a/1", "b/2"])] {
            #expect(link.url.flatMap(DeepLink.parse) == link, "\(link)")
        }
    }

    @Test("Links map to shell actions")
    @MainActor
    func actions() {
        #expect(DeepLink.model("a/b").shellAction == .selectModel("a/b"))
        #expect(DeepLink.chat(model: nil).shellAction == .newChat)
        #expect(DeepLink.chat(model: "a/b").shellAction == .chatWithModel("a/b"))
        #expect(DeepLink.compare(["a/b"]).shellAction == .openCompareWith(["a/b"]))
        let shell = ShellController()
        #expect(shell.open(URL(string: "orb://model/a/b")!))
        #expect(shell.pending?.action == .selectModel("a/b"))
        #expect(!shell.open(URL(string: "orb://nope")!))
    }

    @Test("A model link before the catalog loads is applied after refresh")
    @MainActor
    func pendingSelection() {
        let vm = BrowserViewModel(db: DatabaseManager(), defaults: nil)
        #expect(vm.select(id: "a/b"))
        #expect(vm.pendingSelectionID == "a/b")
    }
}
