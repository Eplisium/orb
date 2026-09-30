import Testing
@testable import ORB

@MainActor
struct StudioStoreTests {
    @Test func boxReturnsSameInstanceSoStateSurvivesViewRecreation() {
        let store = StudioStore()
        let first: StudioBox<Int> = store.box("k") { 1 }
        first.value = 42
        let second: StudioBox<Int> = store.box("k") { 999 }
        #expect(first === second)
        #expect(second.value == 42)
    }

    @Test func distinctKeysAreIndependent() {
        let store = StudioStore()
        let a: StudioBox<String> = store.box("a") { "x" }
        let b: StudioBox<String> = store.box("b") { "y" }
        a.value = "changed"
        #expect(b.value == "y")
    }

    @Test func lateWriteFromInFlightTaskLandsInStore() async {
        let store = StudioStore()
        let results: StudioBox<[String]> = store.box("results") { [] }
        // A "view" that started work and then disappeared: only the box is retained.
        let task = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(20))
            results.value.append("image")
        }
        await task.value
        let reopened: StudioBox<[String]> = store.box("results") { [] }
        #expect(reopened.value == ["image"])
    }
}
