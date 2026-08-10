import Combine
import Testing
@testable import ORB

@Suite("App command routing")
struct AppCommandTests {
    @Test("Find Models command publishes its focus request")
    func findModelsPublishesFocusRequest() {
        let manager = FocusManager()
        var didPublish = false
        let cancellable = manager.objectWillChange.sink { didPublish = true }

        manager.searchFocused = true

        #expect(didPublish)
        withExtendedLifetime(cancellable) {}
    }
}
