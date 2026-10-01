import SwiftUI

/// Status pill: symbol + label (never colour alone), built on `ORBStatus`.
struct ORBStatusPill: View {
    let status: ORBStatus

    /// Palette-backed tint for each status, contrast-tested on surfaces.
    static func tone(for status: ORBStatus) -> ORBColorPair {
        switch status {
        case .ready, .complete: return ORBPalette.success
        case .queued: return ORBPalette.textSecondary
        case .running: return ORBPalette.info
        case .waitingForApproval, .stopping, .interrupted: return ORBPalette.warning
        case .failed: return ORBPalette.danger
        }
    }

    var body: some View {
        let p = ORBTheme.presentation(for: status)
        let tint = Self.tone(for: status).color
        HStack(spacing: ORBMetrics.spacingXXS) {
            Image(systemName: p.symbolName)
            Text(p.label)
        }
        .font(ORBFont.caption.weight(.medium))
        .foregroundStyle(tint)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(tint.opacity(ORBPalette.subtleFillAlpha), in: Capsule())
        .accessibilityElement(children: .combine)
    }
}
