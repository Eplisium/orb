import SwiftUI

/// Icon-only button. `label` (VoiceOver) and `help` (tooltip) are required
/// so no icon button ships unlabeled. Hit target is at least 28 pt.
struct ORBIconButton: View {
    let systemImage: String
    let label: String
    let help: String
    var role: ButtonRole?
    let action: () -> Void

    init(systemImage: String, label: String, help: String, role: ButtonRole? = nil, action: @escaping () -> Void) {
        self.systemImage = systemImage
        self.label = label
        self.help = help
        self.role = role
        self.action = action
    }

    var body: some View {
        Button(role: role, action: action) {
            Image(systemName: systemImage)
                .font(ORBFont.footnote.weight(.medium))
                .frame(width: ORBMetrics.minHitTarget, height: ORBMetrics.minHitTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(ORBTheme.textSecondary)
        .accessibilityLabel(label)
        .help(help)
    }
}
