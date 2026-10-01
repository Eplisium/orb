import SwiftUI

/// Rounded, softly outlined container for grouped content.
struct ORBCard<Content: View>: View {
    var title: String?
    var padding: CGFloat = ORBMetrics.spacingMD
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: ORBMetrics.spacingSM) {
            if let title { ORBSectionHeader(title) }
            content()
        }
        .padding(padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ORBTheme.surfaceRaised, in: RoundedRectangle(cornerRadius: ORBMetrics.radiusLG))
        .overlay { RoundedRectangle(cornerRadius: ORBMetrics.radiusLG).stroke(ORBTheme.stroke, lineWidth: 0.5) }
    }
}
