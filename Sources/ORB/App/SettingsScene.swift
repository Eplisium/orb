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
                    description: Text("Unlock ORB in its main window to change settings.")
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
    @ObservedObject private var ledger = UsageLedger.shared
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
                    .orbFont(.title3)
                VStack(alignment: .leading, spacing: 1) {
                    Text(state.title).orbFont(.footnote, weight: .semibold).lineLimit(1)
                    Text(state.subtitle).orbFont(.caption).foregroundStyle(.secondary)
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
            account.noteLedgerRevision(ledger.revision)
            if account.hasManagementKey && !account.isLoadingCredits { await account.fetchCredits() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            let revision = account.credentialRevision
            account.refreshManagementKeyPresence()
            // A changed revision is owned by the task above. Focus retries an
            // empty/error state and refreshes a balance older than a minute.
            if revision == account.credentialRevision {
                Task { await account.refreshCreditsIfStale() }
            }
        }
        // ORB just recorded spend: the balance is out of date. Debounced so
        // a burst of requests (an agent run, a batch) is one fetch.
        .task(id: ledger.revision) {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await account.refreshCreditsIfStale(ledgerRevision: ledger.revision)
            // Throttled: try once more when the interval has passed, so the
            // chip settles on the balance after the last request of a burst.
            if account.hasManagementKey, account.balanceLags(ledgerRevision: ledger.revision) {
                try? await Task.sleep(for: .seconds(AccountService.spendRefreshInterval))
                guard !Task.isCancelled else { return }
                await account.refreshCreditsIfStale(ledgerRevision: ledger.revision)
            }
        }
    }
}
