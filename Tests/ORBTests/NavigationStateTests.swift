import Testing
import SwiftUI
@testable import ORB

// MARK: - W07 non-visual core
//
// Covers the extracted navigation routing (AppRouter/AppRoute), the
// application-owned dependency container (AppEnvironment), and the design
// tokens (ORBMetrics/ORBTheme) without launching the app. The existing app
// command suite (AppCommandTests) must keep passing untouched.

@Suite("W07 navigation state")
struct NavigationStateTests {

    // MARK: Route identity

    @Test("Every sidebar section has a unique, stable route identity")
    func routeIdentityCoversEverySection() {
        var seen = Set<String>()
        for section in SidebarSection.allCases {
            let route = AppRouter.route(for: section)
            #expect(route.section == section)
            #expect(route.id == section.rawValue)
            #expect(seen.insert(route.id).inserted, "duplicate route id: \(route.id)")
        }
        #expect(seen.count == SidebarSection.allCases.count)
    }

    @Test("Route derivations reuse the SidebarSection semantics")
    func routeDerivationsMirrorSidebarSection() {
        for section in SidebarSection.allCases {
            let route = AppRouter.route(for: section)
            #expect(route.isBrowser == section.isBrowser)
            #expect(route.isMediaTool == section.isMediaTool)
        }

        // The browser set presents the list + detail layout.
        for section in [SidebarSection.allModels, .favorites, .newThisWeek] {
            #expect(AppRouter.route(for: section).isBrowser)
        }
        #expect(!AppRouter.route(for: .agent).isBrowser)
        #expect(!AppRouter.route(for: .chat).isBrowser)

        // The media tool set.
        for section in [SidebarSection.images, .video, .files, .speech, .embeddings] {
            #expect(AppRouter.route(for: section).isMediaTool)
        }
        #expect(!AppRouter.route(for: .allModels).isMediaTool)
        #expect(!AppRouter.route(for: .testSuite).isMediaTool)
        #expect(!AppRouter.route(for: .account).isMediaTool)
    }

    @Test("Route values are equal per section and distinct across sections")
    func routeEquality() {
        #expect(AppRouter.route(for: .chat) == AppRouter.route(for: .chat))
        #expect(AppRouter.route(for: .agent) != AppRouter.route(for: .chat))
        #expect(AppRouter.route(for: .favorites) != AppRouter.route(for: .newThisWeek))
    }

    // MARK: Filter transitions (showFavoritesOnly / showNewThisWeek)

    @Test("Selecting Favorites turns on only the favorites filter")
    func favoritesTransition() {
        let effects = AppRouter.filterEffects(for: .favorites)
        #expect(effects.showFavoritesOnly)
        #expect(!effects.showNewThisWeek)
    }

    @Test("Selecting New This Week turns on only the new-models filter")
    func newThisWeekTransition() {
        let effects = AppRouter.filterEffects(for: .newThisWeek)
        #expect(!effects.showFavoritesOnly)
        #expect(effects.showNewThisWeek)
    }

    @Test("Leaving the browser for a tool clears both filters")
    func browserToToolsTransition() {
        // Arrive from Favorites so a stale filter would be detectable.
        #expect(AppRouter.filterEffects(for: .favorites).showFavoritesOnly)
        for section in [
            SidebarSection.agent, .chat, .testSuite, .account,
            .images, .video, .files, .speech, .embeddings,
        ] {
            let effects = AppRouter.filterEffects(for: section)
            #expect(!effects.showFavoritesOnly, "stale favorites filter after selecting \(section.rawValue)")
            #expect(!effects.showNewThisWeek, "stale new-models filter after selecting \(section.rawValue)")
        }
    }

    @Test("Every selection has explicit, deterministic, mutually exclusive filter state")
    func allSectionsProduceDeterministicFilters() {
        for section in SidebarSection.allCases {
            let effects = AppRouter.filterEffects(for: section)
            #expect(
                !(effects.showFavoritesOnly && effects.showNewThisWeek),
                "filters must be mutually exclusive for \(section.rawValue)"
            )
            // Pure function: same input, same output.
            #expect(effects == AppRouter.filterEffects(for: section))
        }
        #expect(AppRouter.filterEffects(for: .favorites) != AppRouter.filterEffects(for: .allModels))
        #expect(AppRouter.filterEffects(for: .newThisWeek) != AppRouter.filterEffects(for: .allModels))
    }

    // MARK: AppEnvironment ownership

    @MainActor
    @Test("AppEnvironment hands out the same controllers on every access")
    func environmentHandsOutSameInstances() {
        let environment = AppEnvironment()
        let jobs = environment.jobs
        let approvals = environment.approvals
        #expect(environment.jobs === jobs)
        #expect(environment.approvals === approvals)
    }

    @MainActor
    @Test("Injected controllers are adopted as-is; separate environments do not share unowned controllers")
    func environmentInjection() {
        let injectedJobs = JobController()
        let injectedApprovals = ApprovalCoordinator()
        let environment = AppEnvironment(jobs: injectedJobs, approvals: injectedApprovals)
        #expect(environment.jobs === injectedJobs)
        #expect(environment.approvals === injectedApprovals)

        let other = AppEnvironment()
        #expect(other.jobs !== injectedJobs)
        #expect(other.approvals !== injectedApprovals)
    }

    @MainActor
    @Test("AppEnvironment persists through its own database reference by default")
    func environmentDatabaseConsistency() {
        let environment = AppEnvironment()
        #expect(environment.database === DatabaseManager.shared)
        // The owned controller is live over that database: a read succeeds.
        _ = environment.jobs.allJobs()
    }

    // MARK: ORBMetrics — documented scale

    @Test("Spacing scale matches the documented 4/8/12/16/24/32 steps")
    func spacingScaleMatchesPlan() {
        let documented: [CGFloat] = [4, 8, 12, 16, 24, 32]
        #expect(ORBMetrics.spacingScale == documented)
        #expect(ORBMetrics.spacingXXS == 4)
        #expect(ORBMetrics.spacingXS == 8)
        #expect(ORBMetrics.spacingSM == 12)
        #expect(ORBMetrics.spacingMD == 16)
        #expect(ORBMetrics.spacingLG == 24)
        #expect(ORBMetrics.spacingXL == 32)
    }

    @Test("Panel radii stay in the documented 10–12 band")
    func radiiStayInDocumentedBand() {
        let band: ClosedRange<CGFloat> = 10...12
        #expect(band.contains(ORBMetrics.cardRadius))
        #expect(band.contains(ORBMetrics.panelRadius))
    }

    @Test("Type sizes match the documented body and caption bands")
    func typeSizesMatchPlan() {
        let bodyBand: ClosedRange<CGFloat> = 13...14
        let captionBand: ClosedRange<CGFloat> = 11...12
        #expect(bodyBand.contains(ORBMetrics.bodySize))
        #expect(bodyBand.contains(ORBMetrics.bodyLargeSize))
        #expect(captionBand.contains(ORBMetrics.captionSize))
        #expect(captionBand.contains(ORBMetrics.captionLargeSize))
    }

    // MARK: ORBTheme — status vocabulary

    @Test("All eight documented status words exist with complete icon + text presentation")
    func statusMappingIsComplete() {
        let documented = Set([
            "Ready", "Queued", "Running", "Waiting for approval",
            "Stopping", "Interrupted", "Failed", "Complete",
        ])
        #expect(Set(ORBStatus.allCases.map(\.rawValue)) == documented)
        #expect(ORBStatus.allCases.count == 8)

        var symbols = Set<String>()
        for status in ORBStatus.allCases {
            let presentation = ORBTheme.presentation(for: status)
            #expect(presentation.label == status.rawValue, "label must be the canonical status word")
            #expect(!presentation.label.isEmpty)
            // Never color alone: every status pairs an SF Symbol with text.
            #expect(!presentation.symbolName.isEmpty, "\(status.rawValue) must pair an SF Symbol")
            #expect(
                symbols.insert(presentation.symbolName).inserted,
                "duplicate symbol '\(presentation.symbolName)' — statuses must not be distinguished by color alone"
            )
        }
        #expect(symbols.count == ORBStatus.allCases.count)
    }

    @Test("Problem and success states keep their distinct semantic colors")
    func statusColorSemantics() {
        // Failure is red, and both success-ish states are green; the symbol
        // (checked above) is what disambiguates Ready from Complete.
        #expect(ORBTheme.presentation(for: .failed).color == .red)
        #expect(ORBTheme.presentation(for: .ready).color == .green)
        #expect(ORBTheme.presentation(for: .complete).color == .green)
        #expect(ORBTheme.presentation(for: .running).color == .blue)
    }
}
