import Testing
@testable import ORB

@Suite("Test catalog boundaries")
struct TestCatalogBoundaryTests {
    @Test("legacy catalog remains stable and supplemental probes have explicit text mode")
    func stableCatalog() {
        #expect(TestCatalog.allScenarios.count == 22)
        #expect(TestCategory.allCases.count == 10)
        #expect(TestCatalog.availableScenarios.count == 28)
        #expect(TestCatalog.scenarios(in: .securityAuditing).contains { $0.id == "llm-instruction-hierarchy" })
        #expect(TestCatalog.edgeCaseScenarios.count == 6)
        let legacy = Set(TestCatalog.allScenarios.map(\.id))
        let supplemental = Set(TestCatalog.edgeCaseScenarios.map(\.id))
        #expect(legacy.count == 22)
        #expect(supplemental.count == 6)
        #expect(legacy.isDisjoint(with: supplemental))
        #expect(TestCatalog.allScenarios.allSatisfy { $0.evaluationMode == .projectBuild })
        #expect(TestCatalog.edgeCaseScenarios.allSatisfy {
            $0.evaluationMode == .textResponse && !$0.evaluationCriteria.isEmpty && $0.expectedArtifacts.isEmpty
        })
        for scenario in TestCatalog.edgeCaseScenarios {
            #expect(TestCatalog.scenario(id: scenario.id)?.id == scenario.id)
        }
        #expect(TestCatalog.scenario(id: "llm-long-context-retrieval")?.userPrompt.count ?? 0 > 5_000)
        #expect(TestCatalog.scenario(id: "llm-calibrated-refusal")?.allowsRefusal == true)
    }
}
