import SwiftUI

/// A single toast bubble. Use `ToastCenter` + `.orbToastHost(_:)` to show them.
struct ORBToast: View {
    let item: ORBToastItem
    var onDismiss: () -> Void

    var body: some View {
        HStack(spacing: ORBMetrics.spacingSM) {
            Image(systemName: item.kind.systemImage).foregroundStyle(item.kind.tint)
            Text(item.message).font(ORBFont.footnote).foregroundStyle(ORBTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            ORBIconButton(systemImage: "xmark", label: "Dismiss notification", help: "Dismiss", action: onDismiss)
        }
        .padding(.horizontal, ORBMetrics.spacingSM).padding(.vertical, ORBMetrics.spacingXS)
        .frame(maxWidth: 420)
        .background(ORBTheme.surfaceRaised, in: RoundedRectangle(cornerRadius: ORBMetrics.radiusMD))
        .overlay { RoundedRectangle(cornerRadius: ORBMetrics.radiusMD).stroke(ORBTheme.strokeStrong, lineWidth: 0.5) }
        .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
        .accessibilityElement(children: .combine)
    }
}
