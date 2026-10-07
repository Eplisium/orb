import AppKit
import Foundation
import Testing
@testable import ORB

// Regression coverage for the 2026-10-07 hands-on UI audit (UI-01 … UI-10).

private func creation(prompt: String?, model: String = "openai/gpt-image-1", checksum: String = "A1B2C3D4E5F6") -> SavedCreation {
    SavedCreation(
        id: UUID(), kind: .image, modelID: model, prompt: prompt, mimeType: "image/png",
        createdAt: Date(timeIntervalSince1970: 1_790_866_800), assetPath: "a1/x", checksum: checksum
    )
}

@Suite("UI audit: appearance boundary (UI-01)")
@MainActor
struct AppearanceBoundaryTests {
    @Test("Each scheme maps to one app-level appearance; System clears the override")
    func mapping() {
        #expect(AppAppearance.appearanceName(for: .system) == nil)
        #expect(AppAppearance.appearanceName(for: .light) == .aqua)
        #expect(AppAppearance.appearanceName(for: .dark) == .darkAqua)
    }

    @Test("System → Light → System and System → Dark → System end with no override on the app or any window")
    func transitionsRestoreSystem() {
        let app = NSApplication.shared
        let original = app.appearance
        defer { app.appearance = original }
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 10, height: 10), styleMask: [], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }

        for explicit in [AppearancePrefs.Scheme.light, .dark] {
            AppAppearance.apply(.system, to: app)
            AppAppearance.apply(explicit, to: app)
            #expect(app.appearance?.name == AppAppearance.appearanceName(for: explicit))
            // A stale per-window override (what SwiftUI's preferredColorScheme
            // used to leave behind) must not survive the next transition.
            window.appearance = NSAppearance(named: explicit == .light ? .aqua : .darkAqua)
            AppAppearance.apply(.system, to: app)
            #expect(app.appearance == nil)
            #expect(window.appearance == nil)
        }
    }
}

@Suite("UI audit: favorites count and selection (UI-02, UI-03)")
struct FavoritesConsistencyTests {
    @Test("Badge counts only favorites the catalog can show; retired IDs are reported, not lost")
    func summary() {
        let s = FavoriteSummary.make(favoriteIds: ["a", "b", "gone/1", "gone/2"], catalogIds: ["a", "b", "c"])
        #expect(s.available == 2)
        #expect(s.unavailableIDs == ["gone/1", "gone/2"])
        #expect(s.stored == 4)
        #expect(s.unavailableNote == "2 unavailable")
        #expect(s.unavailableHelp?.contains("kept, not deleted") == true)
        #expect(s.unavailableHelp?.contains("gone/1") == true)
    }

    @Test("Before the catalog loads, stored favorites are not reported as unavailable")
    func emptyCatalog() {
        let s = FavoriteSummary.make(favoriteIds: ["a", "b"], catalogIds: [])
        #expect(s.available == 2)
        #expect(s.unavailableNote == nil)
    }

    @Test("Favorites header agrees with the badge, and says so when a filter hides some")
    func header() {
        let s = FavoriteSummary.make(favoriteIds: ["a", "b", "c"], catalogIds: ["a", "b", "c", "d"])
        #expect(BrowserListHeader.text(shown: 3, showFavoritesOnly: true, favorites: s, refined: false) == "3 favorites")
        #expect(BrowserListHeader.text(shown: 1, showFavoritesOnly: true, favorites: s, refined: true) == "1 of 3 favorites")
        #expect(BrowserListHeader.text(shown: 12, showFavoritesOnly: false, favorites: s, refined: false) == "12 models")
        #expect(BrowserListHeader.text(shown: 1, showFavoritesOnly: false, favorites: s, refined: false) == "1 model")
    }

    @Test("Switching collection never leaves a model from another collection in detail")
    func reconcile() {
        #expect(SelectionReconciliation.forCollectionChange(selectedID: "x", visibleIDs: ["a", "b"]) == .select("a"))
        #expect(SelectionReconciliation.forCollectionChange(selectedID: "b", visibleIDs: ["a", "b"]) == .keep)
        #expect(SelectionReconciliation.forCollectionChange(selectedID: "x", visibleIDs: []) == .clear)
        #expect(SelectionReconciliation.forCollectionChange(selectedID: nil, visibleIDs: ["a"]) == .keep)
    }
}

@Suite("UI audit: truthful copy (UI-04, UI-05, UI-10)")
struct TruthfulCopyTests {
    @Test("Inference-key copy names Chat/Agent/Generate and defers credits to the management key")
    func inference() {
        let text = ManagementKeyPanel.inferenceExplanation
        for feature in ["Chat", "Agent", "Generate"] { #expect(text.contains(feature)) }
        #expect(text.contains("management key"))
        #expect(!text.lowercased().contains("checking credits"))
    }

    @Test("MCP copy states the Computer Access gate and per-call approval, never 'automatically'")
    func mcp() {
        let header = MCPAgentAvailability.header
        #expect(header.contains("Computer Access"))
        #expect(header.contains("approval"))
        #expect(!header.lowercased().contains("automatically"))
        #expect(MCPAgentAvailability.status(isEnabled: false).contains("never offered"))
        #expect(MCPAgentAvailability.status(isEnabled: true).contains("approval"))
    }

    @Test("Policy matches the copy: enabled servers need Computer Access; Web Only gets none")
    func policyAgrees() {
        let server = MCPServerConfig(name: "files", command: "npx")
        let webOnly = ToolPolicy.agentSession(fullComputerAccess: false, mcpServers: [server])
        let computer = ToolPolicy.agentSession(fullComputerAccess: true, mcpServers: [server])
        #expect(webOnly.approvedMCPServers.isEmpty)
        #expect(computer.approvedMCPServers.contains(MCPToolNaming.sanitize("files")))
    }

    @Test("Sidebar account hint fits, with the full explanation in the tooltip")
    func accountChip() {
        let s = AccountChipState.make(hasManagementKey: false, remaining: nil, isLoading: false, hasError: false)
        #expect(s.subtitle.count <= 24)
        #expect(s.help.contains("Accounts & Keys"))
    }
}

@Suite("UI audit: accessibility labels (UI-06)")
struct AccessibilityLabelTests {
    @Test("Sidebar counts read as values with their meaning")
    func sidebar() {
        #expect(SidebarAccessibility.value(count: 12, section: .favorites) == "12 favorites")
        #expect(SidebarAccessibility.value(count: 1, section: .newThisWeek) == "1 new model")
        #expect(SidebarAccessibility.value(count: 0, section: .chat) == "")
    }
}

@Suite("UI audit: usage chart dates (UI-07)")
struct UsageChartDateTests {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0)!
        return c
    }

    @Test("Daily points carry real dates so the axis can format and thin them")
    func dated() {
        let end = Date(timeIntervalSince1970: 1_790_866_800)
        let series = UsageSeries.daily([], days: 30, endingAt: end, calendar: calendar)
        #expect(series.count == 30)
        #expect(series.allSatisfy { $0.date != nil })
        #expect(UsageSeries.shortDate(series.last!.date!, calendar: calendar) == "Oct 1")
    }

    @Test("At most about six axis labels in any window")
    func stride() {
        for days in [1, 7, 14, 30] {
            let labels = Int((Double(days) / Double(UsageSeries.axisStride(days: days))).rounded(.up))
            #expect(labels <= 7, "\(days) days → \(labels) labels")
        }
    }

    @Test("The chart title states its real window, including under All Time")
    func title() {
        #expect(UsageSeries.chartTitle(days: 30, range: .allTime).contains("LAST 30 DAYS"))
        #expect(UsageSeries.chartTitle(days: 30, range: .allTime).contains("ALL-TIME"))
        #expect(UsageSeries.chartTitle(days: 7, range: .bounded) == "SPEND PER DAY · LAST 7 DAYS")
    }
}

@Suite("UI audit: library identity (UI-09)")
struct CreationIdentityTests {
    @Test("Long prompts become short titles at a word boundary; the prompt itself is unchanged")
    func shortTitle() {
        let prompt = "A cinematic photograph of a lighthouse on a rocky coast at golden hour with dramatic clouds, ultra detailed"
        let c = creation(prompt: prompt)
        let title = CreationIdentity.title(for: c)
        #expect(title.count <= CreationIdentity.maxTitleLength + 1)
        #expect(title.hasSuffix("…"))
        #expect(!title.contains("  "))
        #expect(c.prompt == prompt)
    }

    @Test("First sentence wins when it is short enough")
    func sentence() {
        #expect(CreationIdentity.title(for: creation(prompt: "A red fox in snow. Soft light, 85mm.")) == "A red fox in snow")
    }

    @Test("No prompt falls back to kind and model")
    func fallback() {
        #expect(CreationIdentity.title(for: creation(prompt: nil)) == "Image from gpt-image-1")
    }

    @Test("Variants from the same prompt are distinguishable by content tag")
    func variants() {
        let a = creation(prompt: "same", checksum: "aaaaaa111111")
        let b = creation(prompt: "same", checksum: "bbbbbb222222")
        #expect(CreationIdentity.title(for: a) == CreationIdentity.title(for: b))
        #expect(CreationIdentity.variantTag(for: a) == "aaaaaa")
        #expect(CreationIdentity.variantTag(for: a) != CreationIdentity.variantTag(for: b))
        #expect(CreationIdentity.metadata(for: a).hasSuffix("#aaaaaa"))
    }
}
