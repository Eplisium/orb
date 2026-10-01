import SwiftUI

/// Content of the native Settings scene (⌘,). Gated on the app lock so the
/// separate Settings window cannot bypass the lock screen.
struct SettingsSceneView: View {
    @ObservedObject private var lock = AppLock.shared

    var body: some View {
        Group {
            if lock.isUnlocked {
                SettingsView()
            } else {
                ContentUnavailableView(
                    "ORB is locked",
                    systemImage: "lock.fill",
                    description: Text("Unlock ORB to change settings.")
                )
            }
        }
        .frame(minWidth: 720, idealWidth: 800, minHeight: 540, idealHeight: 640)
    }
}

/// Sidebar footer: credits at a glance, opens Settings. Neutral when no
/// management key is configured (no network is attempted then).
struct SidebarAccountChip: View {
    @StateObject private var account = AccountService()
    @Environment(\.openSettings) private var openSettings

    private var state: AccountChipState {
        AccountChipState.make(
            hasManagementKey: account.hasManagementKey,
            remaining: account.credits?.remaining,
            isLoading: account.isLoadingCredits,
            hasError: account.creditsError != nil
        )
    }

    var body: some View {
        Button {
            openSettings()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: state.isLow ? "exclamationmark.triangle.fill" : "person.crop.circle.fill")
                    .foregroundStyle(state.isLow ? ORBTheme.warning : ORBTheme.accent)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 1) {
                    Text(state.title).font(ORBFont.footnote.weight(.semibold)).lineLimit(1)
                    Text(state.subtitle).font(ORBFont.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "gearshape").foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .help("Account and settings (⌘,)")
        .accessibilityLabel("Account and settings")
        .accessibilityValue("\(state.title), \(state.subtitle)")
        .task {
            if account.hasManagementKey { await account.fetchCredits() }
        }
    }
}
