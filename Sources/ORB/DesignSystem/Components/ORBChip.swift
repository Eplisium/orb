import SwiftUI

/// Compact selectable pill (filter, tag). Selection is signalled by a
/// checkmark and a filled background, not by colour alone.
struct ORBChip: View {
    let title: String
    var systemImage: String?
    var isSelected = false
    var action: (() -> Void)?

    var body: some View {
        if let action {
            Button(action: action) { label }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
        } else {
            label
        }
    }

    private var label: some View {
        HStack(spacing: ORBMetrics.spacingXXS) {
            if isSelected {
                Image(systemName: "checkmark").font(ORBFont.caption.weight(.bold))
            } else if let systemImage {
                Image(systemName: systemImage).font(ORBFont.caption)
            }
            Text(title).font(ORBFont.caption.weight(.medium)).lineLimit(1)
        }
        .foregroundStyle(isSelected ? ORBTheme.accentLink : ORBTheme.textSecondary)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(isSelected ? ORBTheme.accentSubtle : Color.primary.opacity(0.06), in: Capsule())
        .overlay { Capsule().stroke(isSelected ? ORBTheme.accent.opacity(0.5) : .clear, lineWidth: 1) }
        .contentShape(Capsule())
    }
}

/// Wrapping group of chips using the app's `FlowLayout`.
struct ORBChipGroup<Content: View>: View {
    var spacing: CGFloat = ORBMetrics.spacingXS
    @ViewBuilder var content: () -> Content

    var body: some View {
        FlowLayout(spacing: spacing) { content() }
    }
}
