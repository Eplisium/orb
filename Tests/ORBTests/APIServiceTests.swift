import Foundation
import Testing
@testable import ORB

@Suite("Model catalog cache")
@MainActor
struct APIServiceTests {
    @Test("stale cache is used when the network is unavailable")
    func staleCacheFallback() async throws {
        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("orb-model-cache-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: cacheURL) }
        let fixtureURL = try #require(
            Bundle.module.url(forResource: "models_response", withExtension: "json", subdirectory: "Fixtures")
        )
        try Data(contentsOf: fixtureURL).write(to: cacheURL)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -3_600)],
            ofItemAtPath: cacheURL.path
        )
        let service = APIService(cacheURL: cacheURL) { _ in
            throw URLError(.notConnectedToInternet)
        }

        await service.fetchModels()

        #expect(service.models.count == 3)
        #expect(service.errorMessage == nil)
        #expect(service.lastRefresh != nil)
        #expect(!service.isLoading)
    }
}
