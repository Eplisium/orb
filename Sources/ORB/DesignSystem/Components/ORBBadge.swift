import SwiftUI

/// Small count/label badge (e.g. "New", "3").
struct ORBBadge: View {
    enum Tone: CaseIterable, Sendable { case neutral, accent, success, warning, danger }

    let text: String
    var tone: Tone = .neutral

    var body: some View {
        Text(text)
            .font(ORBFont.caption.weight(.semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(foreground.opacity(ORBPalette.subtleFillAlpha), in: Capsule())
    }

    private var foreground: Color {
        switch tone {
        case .neutral: return ORBTheme.textSecondary
        case .accent: return ORBTheme.accentLink
        case .success: return ORBTheme.success
        case .warning: return ORBTheme.warning
        case .danger: return ORBTheme.danger
        }
    }
}
