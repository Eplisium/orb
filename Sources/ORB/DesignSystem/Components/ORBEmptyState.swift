import SwiftUI

/// Empty / no-results / error state wrapping `ContentUnavailableView`,
/// with an optional primary action.
struct ORBEmptyState: View {
    let title: String
    let systemImage: String
    var message: String?
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            if let message { Text(message) }
        } actions: {
            if let actionTitle, let action {
                Button(actionTitle, action: action).buttonStyle(.borderedProminent).tint(ORBTheme.accent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
