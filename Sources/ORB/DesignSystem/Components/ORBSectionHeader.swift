import SwiftUI

/// Small uppercase section label with an optional trailing accessory.
struct ORBSectionHeader<Accessory: View>: View {
    let title: String
    @ViewBuilder var accessory: () -> Accessory

    init(_ title: String, @ViewBuilder accessory: @escaping () -> Accessory) {
        self.title = title
        self.accessory = accessory
    }

    var body: some View {
        HStack {
            Text(title.uppercased())
                .font(ORBFont.caption.weight(.semibold))
                .tracking(0.6)
                .foregroundStyle(ORBTheme.textSecondary)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            accessory()
        }
    }
}

extension ORBSectionHeader where Accessory == EmptyView {
    init(_ title: String) {
        self.init(title) { EmptyView() }
    }
}
