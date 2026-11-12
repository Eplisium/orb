import SwiftUI

/// Content of the native Settings scene (⌘,). Gated on the app lock so the
/// separate Settings window cannot bypass the lock screen.
struct SettingsSceneView: View {
    @ObservedObject private var lock = AppLock.shared

    var body: some View {
        Group {
            if lock.isUnlocked {
                SettingsView().orbAppearance()
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
    @StateObject private var account: AccountService
    @Environment(\.openSettings) private var openSettings

    init() {
        // Review mode must never consult the Keychain: use an empty store.
        _account = StateObject(wrappedValue: OnboardingGate.isReviewMode()
            ? AccountService(secretStore: InMemoryCredentialStore())
            : AccountService())
    }

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
            SettingsPane.accounts.store()
            openSettings()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: state.systemImage)
                    .foregroundStyle(state.isLow ? ORBTheme.warning : ORBTheme.accent)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 1) {
                    Text(state.title).font(ORBFont.footnote.weight(.semibold)).lineLimit(1)
                    Text(state.subtitle).font(ORBFont.caption).foregroundStyle(.secondary)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
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
        .help(state.help)
        .accessibilityLabel("Account and settings")
        .accessibilityHint(state.help)
        .accessibilityValue(state.accessibilityValue)
        // A replacement keeps presence true, but changes the opaque revision.
        // Refresh immediately rather than waiting for window focus to change.
        .task(id: account.credentialRevision) {
            if account.hasManagementKey && !account.isLoadingCredits { await account.fetchCredits() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            let revision = account.credentialRevision
            account.refreshManagementKeyPresence()
            // A changed revision is owned by the task above. Focus can still
            // retry an empty/error state without launching a duplicate fetch.
            if revision == account.credentialRevision && account.hasManagementKey
                && account.credits == nil && !account.isLoadingCredits {
                Task { await account.fetchCredits() }
            }
        }
    }
}
