import Testing
import SwiftUI
import Foundation
@testable import ORB

private func freshDefaults() -> UserDefaults {
    let name = "orb.tests.settings.\(UUID().uuidString)"
    let d = UserDefaults(suiteName: name)!
    d.removePersistentDomain(forName: name)
    return d
}

// MARK: - Appearance

@Suite("Phase 7: appearance preferences")
struct AppearancePrefsTests {
    @Test("Defaults follow the system and keep the comfortable density")
    func defaults() {
        let p = AppearancePrefs.load(from: freshDefaults())
        #expect(p.scheme == .system)
        #expect(p.textSize == .standard)
        #expect(p.density == .comfortable)
        #expect(p.reduceMotion == .system)
        #expect(p.preferredColorScheme == nil)
    }

    @Test("Scheme maps to SwiftUI: system is nil so the OS decides")
    func scheme() {
        var p = AppearancePrefs()
        p.scheme = .light; #expect(p.preferredColorScheme == .light)
        p.scheme = .dark; #expect(p.preferredColorScheme == .dark)
        p.scheme = .system; #expect(p.preferredColorScheme == nil)
    }

    @Test("Text sizes step monotonically and the default is the SwiftUI default")
    func textSize() {
        let sizes = AppearancePrefs.TextSize.allCases.map(\.dynamicTypeSize)
        #expect(sizes == sizes.sorted())
        #expect(AppearancePrefs.TextSize.standard.dynamicTypeSize == .large)
        #expect(Set(AppearancePrefs.TextSize.allCases.map(\.title)).count == AppearancePrefs.TextSize.allCases.count)
    }

    @Test("Density changes spacing and row height but never below the 28pt hit target")
    func density() {
        #expect(AppearancePrefs.Density.compact.rowPadding < AppearancePrefs.Density.comfortable.rowPadding)
        #expect(AppearancePrefs.Density.compact.minimumRowHeight >= 28)
        #expect(AppearancePrefs.Density.compact.controlSize == .small)
        #expect(AppearancePrefs.Density.comfortable.controlSize == .regular)
    }

    @Test("Reduce motion override: system defers, on/off force")
    func reduceMotion() {
        var p = AppearancePrefs()
        #expect(p.effectiveReduceMotion(system: true))
        #expect(!p.effectiveReduceMotion(system: false))
        p.reduceMotion = .on
        #expect(p.effectiveReduceMotion(system: false))
        p.reduceMotion = .off
        #expect(p.effectiveReduceMotion(system: true), "the OS accessibility setting is never overridden away")
        #expect(!p.effectiveReduceMotion(system: false))
    }

    @Test("Round trip through defaults and tolerance for garbage")
    func persistence() {
        let d = freshDefaults()
        var p = AppearancePrefs()
        p.scheme = .dark; p.textSize = .xLarge; p.density = .compact; p.reduceMotion = .on
        p.save(to: d)
        #expect(AppearancePrefs.load(from: d) == p)
        d.set("nonsense", forKey: AppearancePrefs.schemeKey)
        d.set("also nonsense", forKey: AppearancePrefs.textSizeKey)
        let q = AppearancePrefs.load(from: d)
        #expect(q.scheme == .system && q.textSize == .standard)
        #expect(q.density == .compact)
    }
}

// MARK: - Settings panes

@Suite("Phase 7: settings panes")
struct SettingsPaneTests {
    @Test("Six panes in the planned order, each with a title and symbol")
    func order() {
        #expect(SettingsPane.allCases.map(\.title) == ["General", "Accounts & Keys", "Usage & Credits", "MCP", "Network", "Advanced"])
        #expect(SettingsPane.allCases.allSatisfy { !$0.symbol.isEmpty })
        #expect(Set(SettingsPane.allCases.map(\.symbol)).count == 6)
    }

    @Test("Every legacy tab lands somewhere, so no deep link is lost")
    func legacy() {
        let map: [(String, SettingsPane)] = [
            ("API Key", .accounts), ("Credits", .usage), ("Usage", .usage), ("Activity", .usage),
            ("Key Info", .accounts), ("Providers", .advanced), ("MCP Servers", .mcp), ("Advanced", .network),
        ]
        for (legacy, pane) in map { #expect(SettingsPane.fromLegacy(legacy) == pane, "\(legacy)") }
        #expect(SettingsPane.fromLegacy("something else") == .general)
    }

    @Test("Last selected pane persists and falls back to General")
    func persistence() {
        let d = freshDefaults()
        #expect(SettingsPane.restore(from: d) == .general)
        SettingsPane.network.store(in: d)
        #expect(SettingsPane.restore(from: d) == .network)
        d.set("gone", forKey: SettingsPane.storageKey)
        #expect(SettingsPane.restore(from: d) == .general)
    }
}

// MARK: - Usage chart data

@Suite("Phase 7: usage series")
struct UsageSeriesTests {
    private func bucket(_ key: String, cost: Double, requests: Int = 1, tokens: Int = 10) -> UsageBucket {
        UsageBucket(key: key, cost: cost, requests: requests, tokens: tokens, unpricedRequests: 0)
    }

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0)!
        return c
    }

    @Test("Daily series fills days with no spend with zero, oldest first, for the whole window")
    func fill() {
        let end = Date(timeIntervalSince1970: 1_790_866_800) // 2026-10-01
        let series = UsageSeries.daily(
            [bucket("2026-10-01", cost: 2), bucket("2026-09-29", cost: 1)],
            days: 5, endingAt: end, calendar: calendar
        )
        #expect(series.map(\.label) == ["2026-09-27", "2026-09-28", "2026-09-29", "2026-09-30", "2026-10-01"])
        #expect(series.map(\.cost) == [0, 0, 1, 0, 2])
    }

    @Test("Days outside the window are dropped")
    func outside() {
        let end = Date(timeIntervalSince1970: 1_790_866_800)
        let series = UsageSeries.daily([bucket("2020-01-01", cost: 9)], days: 3, endingAt: end, calendar: calendar)
        #expect(series.count == 3)
        #expect(series.allSatisfy { $0.cost == 0 })
    }

    @Test("Top models keep N and roll the rest into Other, preserving the total")
    func topModels() {
        let rows = (1...8).map { bucket("m\($0)", cost: Double(9 - $0)) }
        let slices = UsageSeries.topModels(rows, limit: 3)
        #expect(slices.map(\.label) == ["m1", "m2", "m3", "Other"])
        #expect(slices.last?.cost == rows.dropFirst(3).reduce(0) { $0 + $1.cost })
        #expect(abs(slices.reduce(0) { $0 + $1.cost } - rows.reduce(0) { $0 + $1.cost }) < 0.0001)
    }

    @Test("No Other slice when everything fits, and zero-cost models are not charted")
    func noOther() {
        let slices = UsageSeries.topModels([bucket("a", cost: 1), bucket("b", cost: 0)], limit: 5)
        #expect(slices.map(\.label) == ["a"])
    }

    @Test("Accessible summary reads out the total and the peak day")
    func summary() {
        let end = Date(timeIntervalSince1970: 1_790_866_800)
        let series = UsageSeries.daily([bucket("2026-10-01", cost: 2.5), bucket("2026-09-30", cost: 1)], days: 3, endingAt: end, calendar: calendar)
        let text = UsageSeries.accessibilitySummary(series)
        #expect(text.contains("$3.50"))
        #expect(text.contains("2026-10-01"))
        #expect(UsageSeries.accessibilitySummary([]) == "No spend recorded.")
    }
}

// MARK: - Save status and validation

@Suite("Phase 7: save status")
struct SaveStatusTests {
    @Test("Status text and symbol exist for every state, so feedback is never colour only")
    func presentation() {
        let visible: [SaveStatus] = [.saving, .saved, .failed("Disk full")]
        #expect(visible.allSatisfy { !$0.symbol.isEmpty && !$0.text.isEmpty })
        #expect(Set(visible.map(\.symbol)).count == 3)
        #expect(SaveStatus.saved.text == "Saved")
        #expect(SaveStatus.saving.text == "Saving…")
        #expect(SaveStatus.failed("Disk full").text == "Couldn't save: Disk full")
        #expect(SaveStatus.idle.text.isEmpty)
        #expect(SaveStatus.saved.symbol == "checkmark.circle.fill")
        #expect(SaveStatus.failed("x").symbol == "exclamationmark.triangle.fill")
    }

    @Test("Saved fades back to idle after the display time; failures stay until acted on")
    func fade() {
        #expect(SaveStatus.saved.afterDisplayTime == .idle)
        #expect(SaveStatus.failed("x").afterDisplayTime == .failed("x"))
        #expect(SaveStatus.saving.afterDisplayTime == .saving)
    }
}

@Suite("Phase 7: field validation")
struct FieldValidationTests {
    @Test("API key format: empty, whitespace and wrong prefix are explained; a plausible key passes")
    func keyFormat() {
        #expect(KeyFieldValidation.check("") == .empty)
        #expect(KeyFieldValidation.check("   ") == .empty)
        #expect(KeyFieldValidation.check("hello") == .invalid("OpenRouter keys start with “sk-or-”."))
        #expect(KeyFieldValidation.check("sk-or-v1-abc") == .invalid("That key looks too short."))
        #expect(KeyFieldValidation.check("sk-or-v1-" + String(repeating: "a", count: 40)) == .valid)
        #expect(KeyFieldValidation.check("  sk-or-v1-" + String(repeating: "a", count: 40) + "\n") == .valid, "pasted whitespace is tolerated")
    }

    @Test("Messages never echo the key back")
    func noEcho() {
        let secret = "sk-or-v1-SECRETSECRETSECRET"
        if case .invalid(let message) = KeyFieldValidation.check(secret) { #expect(!message.contains("SECRET")) }
        if case .invalid(let message) = KeyFieldValidation.check("nope-SECRET") { #expect(!message.contains("SECRET")) }
    }

    @Test("Numeric ranges: in-range passes, out-of-range is explained with the limits")
    func ranges() {
        #expect(RangeValidation.check("15", in: 1...120, unit: "minutes") == .valid)
        #expect(RangeValidation.check("0", in: 1...120, unit: "minutes") == .invalid("Enter a number from 1 to 120 minutes."))
        #expect(RangeValidation.check("abc", in: 1...120, unit: "minutes") == .invalid("Enter a number from 1 to 120 minutes."))
        #expect(RangeValidation.check("", in: 1...120, unit: "minutes") == .empty)
    }
}

@MainActor
@Suite("Phase 7: render smoke", .serialized)
struct SettingsRenderTests {
    private func notBlank<V: View>(_ view: V, scheme: ColorScheme) -> Bool {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, scheme).background(scheme == .dark ? Color.black : Color.white).frame(width: 520))
        renderer.scale = 1
        guard let tiff = renderer.nsImage?.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return false }
        var seen = Set<UInt32>()
        for x in stride(from: 0, to: rep.pixelsWide, by: 4) {
            for y in stride(from: 0, to: rep.pixelsHigh, by: 4) {
                if let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) {
                    seen.insert(UInt32(c.redComponent * 255) << 16 | UInt32(c.greenComponent * 255) << 8 | UInt32(c.blueComponent * 255))
                }
            }
        }
        return seen.count > 2
    }

    @Test("Appearance section and every save status render in light and dark")
    func renders() {
        for scheme in [ColorScheme.light, .dark] {
            #expect(notBlank(AppearanceSettingsSection(), scheme: scheme))
            for status in [SaveStatus.saving, .saved, .failed("Disk full")] {
                #expect(notBlank(SaveStatusLabel(status: status), scheme: scheme))
            }
        }
    }
}


@Suite("Wave 1 settings: account panels gate on the right key")
struct AccountPanelGatingTests {
    @Test("Credits and activity need the management key; key info needs the inference key")
    func roles() {
        #expect(AccountPanel.credits.requiredRole == .management)
        #expect(AccountPanel.activity.requiredRole == .management)
        #expect(AccountPanel.keyInfo.requiredRole == .inference)
        #expect(!AccountPanel.credits.isAvailable(hasInferenceKey: true, hasManagementKey: false))
        #expect(AccountPanel.credits.isAvailable(hasInferenceKey: false, hasManagementKey: true))
        #expect(!AccountPanel.keyInfo.isAvailable(hasInferenceKey: false, hasManagementKey: true))
        #expect(AccountPanel.keyInfo.isAvailable(hasInferenceKey: true, hasManagementKey: false))
    }

    @Test("Only panels with their key are refreshed")
    func refresh() {
        #expect(AccountPanel.panelsToRefresh(hasInferenceKey: true, hasManagementKey: false) == [.keyInfo])
        #expect(AccountPanel.panelsToRefresh(hasInferenceKey: false, hasManagementKey: true) == [.credits, .activity])
        #expect(AccountPanel.panelsToRefresh(hasInferenceKey: false, hasManagementKey: false).isEmpty)
        #expect(AccountPanel.credits.missingKeyMessage.contains("management key"))
    }
}
