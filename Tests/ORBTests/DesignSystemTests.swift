import Testing
import SwiftUI
import AppKit
@testable import ORB

@Suite("Design system tokens")
struct DesignSystemTests {

    // MARK: Contrast helper

    @Test("Contrast helper matches WCAG reference values")
    func contrastReference() {
        let black = ORBRGB(0, 0, 0), white = ORBRGB(1, 1, 1)
        #expect(abs(ORBRGB.contrast(black, white) - 21) < 0.001)
        #expect(abs(ORBRGB.contrast(white, white) - 1) < 0.001)
        // #767676 on white is the canonical ~4.54:1 AA threshold grey.
        let grey = ORBRGB(118.0 / 255, 118.0 / 255, 118.0 / 255)
        #expect(abs(ORBRGB.contrast(grey, white) - 4.54) < 0.01)
        #expect(ORBRGB.contrast(black, grey) == ORBRGB.contrast(grey, black))
    }

    @Test("Blending at alpha 0/1 returns background/foreground")
    func blending() {
        let a = ORBRGB(1, 0, 0), b = ORBRGB(0, 0, 1)
        #expect(a.blended(over: b, alpha: 1) == a)
        #expect(a.blended(over: b, alpha: 0) == b)
    }

    // MARK: Semantic text pairs

    @Test("Every text token pair reaches 4.5:1 in light and dark", arguments: ORBAppearance.allCases)
    func textPairsContrast(appearance: ORBAppearance) {
        #expect(!ORBPalette.textPairs.isEmpty)
        for pair in ORBPalette.textPairs {
            let ratio = ORBRGB.contrast(pair.foreground.rgb(appearance), pair.background.rgb(appearance))
            #expect(ratio >= ORBPalette.minimumTextContrast, "\(pair.name) \(appearance): \(ratio)")
        }
    }

    @Test("Text on the subtle status tint stays readable", arguments: ORBAppearance.allCases)
    func tintedFillContrast(appearance: ORBAppearance) {
        // Badges/pills draw the foreground over foreground@12% on a surface.
        let fgs = [ORBPalette.success, ORBPalette.warning, ORBPalette.danger, ORBPalette.info, ORBPalette.textSecondary]
        for fg in fgs {
            for surface in [ORBPalette.surface, ORBPalette.surfaceRaised] {
                let f = fg.rgb(appearance), s = surface.rgb(appearance)
                let fill = f.blended(over: s, alpha: ORBPalette.subtleFillAlpha)
                #expect(ORBRGB.contrast(f, fill) >= 4.5)
            }
        }
    }

    @Test("Status pill tones pass on every status", arguments: ORBAppearance.allCases)
    func statusPillTones(appearance: ORBAppearance) {
        for status in ORBStatus.allCases {
            let f = ORBStatusPill.tone(for: status).rgb(appearance)
            let s = ORBPalette.surfaceRaised.rgb(appearance)
            let fill = f.blended(over: s, alpha: ORBPalette.subtleFillAlpha)
            #expect(ORBRGB.contrast(f, fill) >= 4.5, "\(status)")
        }
    }

    // MARK: Accents

    @Test("Curated accent set is 6-8 with the ORB purple default")
    func accentSet() {
        #expect((6...8).contains(AccentChoice.allCases.count))
        #expect(AccentChoice.default == .purple)
        #expect(AccentChoice.storageKey == "orb.accent")
        #expect(Set(AccentChoice.allCases.map(\.id)).count == AccentChoice.allCases.count)
        // Default keeps the original ORB purple in light mode.
        #expect(AccentChoice.purple.palette.light == ORBRGB(0.45, 0.36, 0.82))
    }

    @Test("Stored accent falls back to default for missing/unknown values")
    func accentFallback() {
        #expect(AccentChoice(stored: nil) == .purple)
        #expect(AccentChoice(stored: "chartreuse") == .purple)
        #expect(AccentChoice(stored: "teal") == .teal)
        let suite = UserDefaults(suiteName: "orb.tests.accent.\(UUID().uuidString)")!
        #expect(AccentChoice.current(suite) == .purple)
        suite.set("orange", forKey: AccentChoice.storageKey)
        #expect(AccentChoice.current(suite) == .orange)
    }

    @Test("Every accent passes 4.5:1 as text on all surfaces", arguments: ORBAppearance.allCases)
    func accentOnSurfaces(appearance: ORBAppearance) {
        for accent in AccentChoice.allCases {
            let a = accent.palette.rgb(appearance)
            for surface in [ORBPalette.surface, ORBPalette.surfaceRaised, ORBPalette.surfaceSunken] {
                let r = ORBRGB.contrast(a, surface.rgb(appearance))
                #expect(r >= 4.5, "\(accent) \(appearance) on surface: \(r)")
            }
        }
    }

    @Test("Accent link variant and accent-subtle chips pass", arguments: ORBAppearance.allCases)
    func accentLinkAndChip(appearance: ORBAppearance) {
        for accent in AccentChoice.allCases {
            let link = accent.linkPalette.rgb(appearance)
            let s = ORBPalette.surfaceRaised.rgb(appearance)
            #expect(ORBRGB.contrast(link, s) >= 4.5, "\(accent) link")
            let fill = link.blended(over: s, alpha: ORBPalette.subtleFillAlpha)
            #expect(ORBRGB.contrast(link, fill) >= 4.5, "\(accent) link on subtle")
        }
    }

    @Test("onAccent text passes on every solid accent fill", arguments: ORBAppearance.allCases)
    func onAccentContrast(appearance: ORBAppearance) {
        for accent in AccentChoice.allCases {
            let r = ORBRGB.contrast(ORBPalette.onAccent.rgb(appearance), accent.palette.rgb(appearance))
            #expect(r >= 4.5, "\(accent) \(appearance) onAccent: \(r)")
        }
    }

    @Test("ORBTheme.accent follows the persisted choice")
    func themeAccentFollowsChoice() {
        let key = AccentChoice.storageKey
        let previous = UserDefaults.standard.object(forKey: key)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        func resolved(_ appearance: NSAppearance.Name) -> NSColor {
            var out = NSColor.clear
            NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
                out = NSColor(ORBTheme.accent).usingColorSpace(.sRGB)!
            }
            return out
        }
        for choice in AccentChoice.allCases {
            UserDefaults.standard.set(choice.rawValue, forKey: key)
            for (name, ap) in [(NSAppearance.Name.aqua, ORBAppearance.light), (.darkAqua, .dark)] {
                let c = resolved(name), expect = choice.palette.rgb(ap)
                #expect(abs(Double(c.redComponent) - expect.r) < 0.01, "\(choice) \(ap)")
                #expect(abs(Double(c.greenComponent) - expect.g) < 0.01)
                #expect(abs(Double(c.blueComponent) - expect.b) < 0.01)
            }
        }
    }

    // MARK: Type scale

    @Test("Type scale never drops below the 11pt floor")
    func fontFloor() {
        #expect(ORBFont.minimumPointSize == 11)
        for style in ORBFont.Style.allCases {
            #expect(style.basePointSize >= ORBFont.minimumPointSize, "\(style): \(style.basePointSize)")
        }
    }

    @Test("Type scale is non-decreasing from caption to title")
    func fontOrdering() {
        let sizes = [ORBFont.Style.caption, .footnote, .body, .title3, .title2, .title].map(\.basePointSize)
        #expect(sizes == sizes.sorted())
    }

    // MARK: Spacing / radius

    @Test("Spacing and radius scales")
    func spacingRadius() {
        #expect(ORBMetrics.spacingScale == [4, 8, 12, 16, 24, 32])
        #expect(ORBMetrics.radiusScale == [6, 10, 14])
        #expect(ORBMetrics.minHitTarget >= 28)
    }

    // MARK: Motion

    @Test("Motion tokens resolve to nil under Reduce Motion")
    func motionReduce() {
        for token in ORBMotion.Token.allCases {
            #expect(token.animation(reduceMotion: true) == nil)
            #expect(token.animation(reduceMotion: false) != nil)
            #expect(ORBMotion.animation(token, reduceMotion: true) == nil)
        }
        let d = ORBMotion.Token.allCases.map(\.duration)
        #expect(d == d.sorted() && d.allSatisfy { $0 > 0 && $0 < 1 })
    }

    @Test("Skeleton shimmer is disabled under Reduce Motion")
    func skeletonShimmer() {
        #expect(ORBSkeletonRow.shimmers(reduceMotion: false))
        #expect(!ORBSkeletonRow.shimmers(reduceMotion: true))
    }

    // MARK: Toasts

    @MainActor
    @Test("ToastCenter queues, caps and dismisses")
    func toastQueue() {
        let c = ToastCenter(maxVisible: 2)
        let a = c.show("a", kind: .info, duration: 0)
        _ = c.show("b", kind: .success, duration: 0)
        _ = c.show("c", kind: .error, duration: 0)
        #expect(c.toasts.map(\.message) == ["b", "c"])
        #expect(!c.toasts.contains { $0.id == a })
        c.dismiss(c.toasts[0].id)
        #expect(c.toasts.map(\.message) == ["c"])
        c.dismissAll()
        #expect(c.toasts.isEmpty)
    }

    @MainActor
    @Test("ToastCenter auto-dismisses after its duration")
    func toastAutoDismiss() async {
        let c = ToastCenter()
        c.show("x", duration: 0.05)
        #expect(c.toasts.count == 1)
        let deadline = ContinuousClock.now + .seconds(2)
        while !c.toasts.isEmpty && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(c.toasts.isEmpty)
    }

    @Test("Errors linger longer than other toasts")
    func toastDurations() {
        #expect(ORBToastKind.error.defaultDuration > ORBToastKind.info.defaultDuration)
        let symbols = Set(ORBToastKind.allCasesForTest.map(\.systemImage))
        #expect(symbols.count == 4)
        for s in symbols { #expect(NSImage(systemSymbolName: s, accessibilityDescription: nil) != nil, "\(s)") }
    }

    @Test("Status pill symbols exist and are distinct")
    func statusSymbols() {
        var seen = Set<String>()
        for s in ORBStatus.allCases {
            let name = ORBTheme.presentation(for: s).symbolName
            #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil, "\(name)")
            #expect(seen.insert(name).inserted)
        }
    }

    // MARK: Views construct

    @MainActor
    @Test("Shared components build and render")
    func componentsRender() {
        let gallery = VStack {
            ORBCard(title: "Card") { Text("x") }
            ORBChipGroup { ORBChip(title: "A", isSelected: true, action: {}); ORBChip(title: "B") }
            ORBSectionHeader("Section")
            ORBEmptyState(title: "None", systemImage: "tray", message: "m", actionTitle: "Go", action: {})
            ORBSkeletonRow()
            ORBToast(item: .init(id: UUID(), kind: .info, message: "hi"), onDismiss: {})
            ORBIconButton(systemImage: "plus", label: "Add", help: "Add item", action: {})
            ORBBadge(text: "New", tone: .accent)
            ORBStatusPill(status: .running)
            StudioNotice(text: "n", tone: .warning)
        }.frame(width: 400, height: 800)
        let renderer = ImageRenderer(content: gallery)
        #expect(renderer.cgImage != nil)
    }
}

extension ORBToastKind {
    static let allCasesForTest: [ORBToastKind] = [.info, .success, .warning, .error]
}
