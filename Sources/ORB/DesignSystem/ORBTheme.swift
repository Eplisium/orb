import SwiftUI

// MARK: - ORB theme (plan 9.3)
//
// Semantic color tokens and the shared status vocabulary. Status is never
// expressed by color alone: every status pairs its canonical label with an
// SF Symbol, so state survives color-vision differences, increased contrast,
// and appearance changes. Pure values plus one small additive view; existing
// views are untouched.

/// The shell's status vocabulary (plan 9.3): Ready, Queued, Running,
/// Waiting for approval, Stopping, Interrupted, Failed, Complete.
enum ORBStatus: String, CaseIterable, Sendable {
    case ready = "Ready"
    case queued = "Queued"
    case running = "Running"
    case waitingForApproval = "Waiting for approval"
    case stopping = "Stopping"
    case interrupted = "Interrupted"
    case failed = "Failed"
    case complete = "Complete"
}

/// Everything a status chip needs to render. `color` is supplementary — the
/// label and symbol carry the meaning.
struct ORBStatusPresentation: Equatable, Sendable {
    let label: String
    let symbolName: String
    let color: Color
}

enum ORBTheme {
    // MARK: Accent — user-selected (`AccentChoice`, key `orb.accent`),
    // default ORB purple. Resolved when drawn, so existing call sites
    // follow the choice whenever their view re-renders.

    static var accent: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let pair = AccentChoice.current().palette
            return (appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? pair.dark : pair.light).nsColor
        })
    }

    /// Deeper variant for accent-coloured text/links.
    static var accentLink: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let pair = AccentChoice.current().linkPalette
            return (appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? pair.dark : pair.light).nsColor
        })
    }

    /// Tinted background for accent-coloured chips and selections.
    static var accentSubtle: Color { accent.opacity(ORBPalette.subtleFillAlpha) }
    /// Foreground for content on a solid accent fill.
    static let onAccent = ORBPalette.onAccent.color

    // MARK: Semantic colour tokens (light/dark pairs in `ORBPalette`)

    static let surface = ORBPalette.surface.color
    static let surfaceRaised = ORBPalette.surfaceRaised.color
    static let surfaceSunken = ORBPalette.surfaceSunken.color
    static let textPrimary = ORBPalette.textPrimary.color
    static let textSecondary = ORBPalette.textSecondary.color
    static let textTertiary = ORBPalette.textTertiary.color
    static let success = ORBPalette.success.color
    static let warning = ORBPalette.warning.color
    static let danger = ORBPalette.danger.color
    static let info = ORBPalette.info.color
    /// Hairline borders; adapts via the primary label colour.
    static let stroke = Color.primary.opacity(0.10)
    static let strokeStrong = Color.primary.opacity(0.18)

    // MARK: Status presentation

    /// Semantic system colors mapped from the status vocabulary. Failed and
    /// Interrupted stay distinct (failure vs. recoverable stop), and no two
    /// statuses share a symbol, so color is never the only signal.
    static func presentation(for status: ORBStatus) -> ORBStatusPresentation {
        switch status {
        case .ready:
            return .init(label: status.rawValue, symbolName: "checkmark.circle", color: .green)
        case .queued:
            return .init(label: status.rawValue, symbolName: "clock", color: .secondary)
        case .running:
            return .init(label: status.rawValue, symbolName: "circle.dotted", color: .blue)
        case .waitingForApproval:
            return .init(label: status.rawValue, symbolName: "hand.raised", color: .orange)
        case .stopping:
            return .init(label: status.rawValue, symbolName: "stop.circle", color: .orange)
        case .interrupted:
            return .init(label: status.rawValue, symbolName: "pause.circle", color: .yellow)
        case .failed:
            return .init(label: status.rawValue, symbolName: "xmark.octagon", color: .red)
        case .complete:
            return .init(label: status.rawValue, symbolName: "checkmark.circle.fill", color: .green)
        }
    }
}

/// Small status chip: SF Symbol + label, combined into one accessibility
/// element so VoiceOver reads the state as a single phrase. Additive
/// component for the shell session; not yet used by existing views.
struct ORBStatusBadge: View {
    let status: ORBStatus

    var body: some View {
        let presentation = ORBTheme.presentation(for: status)
        HStack(spacing: ORBMetrics.spacingXXS) {
            Image(systemName: presentation.symbolName)
            Text(presentation.label)
        }
        .font(ORBFont.footnote)
        .foregroundStyle(presentation.color)
        .accessibilityElement(children: .combine)
    }
}
