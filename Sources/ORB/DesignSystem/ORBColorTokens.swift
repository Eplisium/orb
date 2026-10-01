import SwiftUI
import AppKit

// MARK: - Colour primitives and semantic palette (Phase 1)
//
// Colours are defined in code as light/dark pairs so contrast can be unit
// tested without rendering. `Color(light:dark:)` wraps an NSColor dynamic
// provider, so the same token resolves per-appearance at draw time.

/// sRGB triple (0...1) with WCAG 2.x relative luminance / contrast helpers.
struct ORBRGB: Equatable, Sendable {
    let r: Double, g: Double, b: Double

    init(_ r: Double, _ g: Double, _ b: Double) {
        self.r = r; self.g = g; self.b = b
    }

    var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: 1) }

    /// WCAG relative luminance.
    var luminance: Double {
        func lin(_ c: Double) -> Double {
            c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }

    /// This colour drawn at `alpha` over an opaque `background`.
    func blended(over background: ORBRGB, alpha: Double) -> ORBRGB {
        ORBRGB(r * alpha + background.r * (1 - alpha),
               g * alpha + background.g * (1 - alpha),
               b * alpha + background.b * (1 - alpha))
    }

    /// WCAG contrast ratio, 1...21, order-independent.
    static func contrast(_ a: ORBRGB, _ b: ORBRGB) -> Double {
        let (hi, lo) = (max(a.luminance, b.luminance), min(a.luminance, b.luminance))
        return (hi + 0.05) / (lo + 0.05)
    }
}

enum ORBAppearance: CaseIterable, Sendable {
    case light, dark
}

/// A semantic colour with an explicit value per appearance.
struct ORBColorPair: Equatable, Sendable {
    let light: ORBRGB
    let dark: ORBRGB

    func rgb(_ appearance: ORBAppearance) -> ORBRGB {
        appearance == .light ? light : dark
    }

    var color: Color { Color(light: light, dark: dark) }
}

extension Color {
    /// Appearance-adaptive colour from fixed light/dark values.
    init(light: ORBRGB, dark: ORBRGB) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark.nsColor : light.nsColor
        })
    }
}

/// Raw palette values. `ORBTheme` exposes these as `Color`s; tests assert
/// contrast directly on the RGB data.
enum ORBPalette {
    // Surfaces
    static let surface = ORBColorPair(light: .init(0.97, 0.97, 0.98), dark: .init(0.11, 0.11, 0.12))
    static let surfaceRaised = ORBColorPair(light: .init(1, 1, 1), dark: .init(0.16, 0.16, 0.18))
    static let surfaceSunken = ORBColorPair(light: .init(0.95, 0.95, 0.96), dark: .init(0.08, 0.08, 0.09))

    // Text
    static let textPrimary = ORBColorPair(light: .init(0.07, 0.07, 0.08), dark: .init(0.96, 0.96, 0.97))
    static let textSecondary = ORBColorPair(light: .init(0.33, 0.33, 0.36), dark: .init(0.70, 0.70, 0.73))
    static let textTertiary = ORBColorPair(light: .init(0.40, 0.40, 0.43), dark: .init(0.62, 0.62, 0.65))

    // Status (usable as text on surfaces and as the tint of a pill)
    static let success = ORBColorPair(light: .init(0.05, 0.42, 0.20), dark: .init(0.40, 0.85, 0.55))
    static let warning = ORBColorPair(light: .init(0.58, 0.30, 0.00), dark: .init(1.00, 0.72, 0.30))
    static let danger = ORBColorPair(light: .init(0.74, 0.12, 0.12), dark: .init(1.00, 0.45, 0.42))
    static let info = ORBColorPair(light: .init(0.04, 0.34, 0.78), dark: .init(0.40, 0.65, 1.00))

    /// Text/icons placed on a solid accent fill. White on light-mode
    /// accents, near-black on the lighter dark-mode accents.
    static let onAccent = ORBColorPair(light: .init(1, 1, 1), dark: .init(0.05, 0.05, 0.06))

    /// Opacity of a tint when used as a subtle background.
    static let subtleFillAlpha = 0.12

    /// Every (foreground, background) text pairing that must reach
    /// `minimumTextContrast` in both appearances.
    static let minimumTextContrast = 4.5

    static let textPairs: [(name: String, foreground: ORBColorPair, background: ORBColorPair)] = {
        let surfaces: [(String, ORBColorPair)] = [("surface", surface), ("surfaceRaised", surfaceRaised), ("surfaceSunken", surfaceSunken)]
        let texts: [(String, ORBColorPair)] = [("textPrimary", textPrimary), ("textSecondary", textSecondary), ("textTertiary", textTertiary)]
        let statuses: [(String, ORBColorPair)] = [("success", success), ("warning", warning), ("danger", danger), ("info", info)]
        var pairs: [(String, ORBColorPair, ORBColorPair)] = []
        for (tn, t) in texts + statuses {
            for (sn, s) in surfaces { pairs.append(("\(tn) on \(sn)", t, s)) }
        }
        return pairs
    }()
}

// MARK: - Accent choice (Settings > Appearance, persisted as `orb.accent`)

/// Curated accent set. Each carries a light and a dark variant so accent
/// text/links and `onAccent` fills pass contrast in both appearances.
enum AccentChoice: String, CaseIterable, Identifiable, Sendable {
    case purple, blue, teal, green, orange, pink, red, graphite

    /// `@AppStorage` key.
    static let storageKey = "orb.accent"
    static let `default`: AccentChoice = .purple

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .graphite: return "Graphite"
        default: return rawValue.capitalized
        }
    }

    var palette: ORBColorPair {
        switch self {
        // Light purple is the original ORB accent.
        case .purple: return .init(light: .init(0.45, 0.36, 0.82), dark: .init(0.68, 0.60, 1.00))
        case .blue: return .init(light: .init(0.05, 0.38, 0.85), dark: .init(0.40, 0.65, 1.00))
        case .teal: return .init(light: .init(0.00, 0.45, 0.48), dark: .init(0.30, 0.80, 0.80))
        case .green: return .init(light: .init(0.08, 0.48, 0.25), dark: .init(0.40, 0.82, 0.50))
        case .orange: return .init(light: .init(0.70, 0.33, 0.00), dark: .init(1.00, 0.62, 0.25))
        case .pink: return .init(light: .init(0.78, 0.15, 0.45), dark: .init(1.00, 0.50, 0.70))
        case .red: return .init(light: .init(0.76, 0.15, 0.15), dark: .init(1.00, 0.45, 0.42))
        case .graphite: return .init(light: .init(0.35, 0.35, 0.40), dark: .init(0.72, 0.72, 0.78))
        }
    }

    /// Darker (light mode) variant for accent-coloured text and links.
    var linkPalette: ORBColorPair {
        let l = palette.light
        return .init(light: .init(l.r * 0.85, l.g * 0.85, l.b * 0.85), dark: palette.dark)
    }

    /// Resolves a stored raw value, falling back to the default for
    /// missing or unknown strings.
    init(stored: String?) {
        self = stored.flatMap(AccentChoice.init(rawValue:)) ?? .default
    }

    /// The persisted choice. Reads UserDefaults at call time.
    static func current(_ defaults: UserDefaults = .standard) -> AccentChoice {
        AccentChoice(stored: defaults.string(forKey: storageKey))
    }
}
