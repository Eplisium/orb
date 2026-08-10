import Testing
@testable import ORB

@Suite("Playground model defaults")
struct PlaygroundModelDefaultsTests {
    @Test("restored conversation model wins over the mode default")
    func restoredConversationModelWins() {
        #expect(PlaygroundModelDefaults.initialSelection(activeModelId: "saved/model", preferredModelId: "default/model") == "saved/model")
        #expect(PlaygroundModelDefaults.initialSelection(activeModelId: nil, preferredModelId: "default/model") == "default/model")
    }

    @Test("stored default wins when it is available")
    func storedDefaultWins() {
        let resolved = PlaygroundModelDefaults.resolve(
            storedModelId: "provider/default",
            availableModelIds: ["provider/other", "provider/default"],
            fallbackModelId: "provider/fallback"
        )

        #expect(resolved == "provider/default")
    }

    @Test("stored default is usable while the model catalog is loading")
    func storedDefaultWorksBeforeCatalogLoads() {
        let resolved = PlaygroundModelDefaults.resolve(
            storedModelId: "provider/default",
            availableModelIds: [],
            fallbackModelId: "provider/fallback"
        )

        #expect(resolved == "provider/default")
    }

    @Test("unavailable stored default falls back")
    func unavailableDefaultFallsBack() {
        let resolved = PlaygroundModelDefaults.resolve(
            storedModelId: "provider/removed",
            availableModelIds: ["provider/available"],
            fallbackModelId: "provider/available"
        )

        #expect(resolved == "provider/available")
    }
}
