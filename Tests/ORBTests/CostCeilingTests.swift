import Testing
import Foundation
@testable import ORB

@Suite("Cost ceiling progress")
struct CostCeilingTests {
    @Test("Fraction is spend over ceiling, clamped to 0…1")
    func fraction() {
        #expect(CostCeilingProgress(spent: 0.25, ceiling: 1).fraction == 0.25)
        #expect(CostCeilingProgress(spent: 3, ceiling: 1).fraction == 1)
        #expect(CostCeilingProgress(spent: 0, ceiling: 1).fraction == 0)
        #expect(CostCeilingProgress(spent: -1, ceiling: 1).fraction == 0)
    }

    @Test("A missing or invalid ceiling gives no progress to show")
    func invalid() {
        #expect(CostCeilingProgress(spent: 1, ceiling: nil).fraction == nil)
        #expect(CostCeilingProgress(spent: 1, ceiling: 0).fraction == nil)
        #expect(CostCeilingProgress(spent: 1, ceiling: .infinity).fraction == nil)
        #expect(CostCeilingProgress(spent: 1, ceiling: nil).text == "No spend limit")
    }

    @Test("State escalates by words and symbol: ok, near at 80%, reached at 100%")
    func state() {
        #expect(CostCeilingProgress(spent: 0.1, ceiling: 1).state == .ok)
        #expect(CostCeilingProgress(spent: 0.8, ceiling: 1).state == .near)
        #expect(CostCeilingProgress(spent: 1, ceiling: 1).state == .reached)
        #expect(CostCeilingProgress(spent: 1.4, ceiling: 1).state == .reached)
        let symbols = Set(CostCeilingProgress.State.allCases.map(\.symbol))
        #expect(symbols.count == 3)
        #expect(CostCeilingProgress.State.allCases.allSatisfy { !$0.label.isEmpty })
    }

    @Test("Text names both amounts, and says when the limit may have been exceeded")
    func text() {
        #expect(CostCeilingProgress(spent: 0.0123, ceiling: 0.5).text == "$0.0123 of $0.50 limit")
        let over = CostCeilingProgress(spent: 0.62, ceiling: 0.5).text
        #expect(over.contains("over") || over.contains("exceeded"))
    }

    @Test("Spend is a lower bound when any run reported no cost")
    func lowerBound() {
        #expect(CostCeilingProgress(spent: 0.2, ceiling: 1, unreportedRuns: 1).text.hasPrefix("≥ "))
        #expect(!CostCeilingProgress(spent: 0.2, ceiling: 1, unreportedRuns: 0).text.hasPrefix("≥ "))
    }

    @Test("Accessibility value reads the percentage")
    func accessibility() {
        #expect(CostCeilingProgress(spent: 0.5, ceiling: 1).accessibilityValue == "50 percent of the spend limit")
        #expect(CostCeilingProgress(spent: 1, ceiling: nil).accessibilityValue == "No spend limit")
    }
}
