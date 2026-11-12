import Foundation
import Testing
@testable import ORB

@Suite("Endpoint literal identity collisions")
struct EndpointIdentityCollisionTests {
    private func response(_ bases: [String], tagged: Bool) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["data": ["id": "fixture/model", "endpoints": bases.map {
            [tagged ? "tag" : "provider_name": $0]
        }]])
    }

    @Test("Generated suffixes reserve literal identities regardless of order", arguments: [true, false])
    func literalSuffixes(tagged: Bool) throws {
        for bases in [["X", "X", "X#2"], ["X#2", "X", "X"],
                      ["X", "X#2", "X", "X#3", "X#2", "X#2#2"]] {
            let decoded = try JSONDecoder().decode(EndpointResponse.self, from: response(bases, tagged: tagged)).data.endpoints
            let endpoints = ModelEndpoint.uniquified(decoded)
            #expect(Set(endpoints.map(\.id)).count == endpoints.count)
            #expect(endpoints.map(\.baseID) == bases)
            for base in Set(bases) {
                #expect(endpoints.first { $0.baseID == base }?.id == base)
            }
            #expect(ModelEndpoint.uniquified(endpoints).map(\.id) == endpoints.map(\.id))
            #expect(ModelEndpoint.uniquified(decoded).map(\.id) == endpoints.map(\.id))
        }
    }

    @Test("Injected API endpoint response cannot publish colliding table identities")
    @MainActor
    func serviceReservesLiteralSuffix() async throws {
        let data = try response(["X", "X", "X#2"], tagged: true)
        let cache = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"] ?? NSHomeDirectory())
            .appendingPathComponent("unused-endpoint-cache-\(UUID().uuidString)")
        let api = APIService(cacheURL: cache) { url in
            (data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let endpoints = await api.fetchEndpoints(for: "fixture/model")
        #expect(endpoints.count == 3)
        #expect(Set(endpoints.map(\.id)).count == endpoints.count)
        #expect(endpoints.first { $0.baseID == "X#2" }?.id == "X#2")
    }
}
