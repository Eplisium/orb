import SwiftUI
import AppKit

/// Full-window gate shown until the user performs the one "allow all access"
/// gesture (Touch ID, Apple Watch, or the Mac password). Replaces the legacy
/// keychain password dialog with modern authentication.
///
/// The system prompt starts by itself once per lock episode while ORB is the
/// active app (at launch, or when you come back after an idle relock), so
/// unlocking is one touch rather than a click and then a touch.
struct LockScreenView: View {
    @ObservedObject var lock: AppLock
    let accent: Color
    /// Opens Settings on the pane that holds the lock preference (the caller
    /// stores `SettingsPane.lockSettings` first), so it is one click away.
    var onOpenSettings: (() -> Void)? = nil
    /// Injected so the view can be rendered in tests without an active app.
    var appIsActive: () -> Bool = { NSApp?.isActive ?? false }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                VStack(spacing: 14) {
                    ZStack {
                        Circle()
                            .fill(accent.opacity(0.18))
                        Circle()
                            .strokeBorder(accent.opacity(0.5), lineWidth: 1)
                        Image(systemName: "lock.fill")
                            .orbFont(size: 32, weight: .medium)
                            .foregroundStyle(accent)
                    }
                    .frame(width: 84, height: 84)
                    .accessibilityHidden(true)

                    // Semantic label colours: the gate sits on the window
                    // background, which is light in the Light appearance.
                    Text("ORB is locked")
                        .orbFont(size: 22, weight: .semibold)
                        .foregroundStyle(.primary)
                        .accessibilityAddTraits(.isHeader)

                    VStack(spacing: 6) {
                        Text(LockCopy.prompt(biometric: lock.biometricName))
                            .orbFont(size: 13)
                            .foregroundStyle(.primary.opacity(0.85))
                        Text("Your API keys and sessions stay protected. ORB locks again when your Mac sleeps or locks, or after a period of inactivity.")
                            .orbFont(size: 12)
                            .foregroundStyle(.secondary)
                    }
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 350)
                }

                VStack(spacing: 12) {
                    Button {
                        Task { await lock.unlock() }
                    } label: {
                        HStack(spacing: 8) {
                            if lock.isUnlocking {
                                ProgressView()
                                    .controlSize(.small)
                                    .tint(ORBTheme.onAccent)
                            } else {
                                Image(systemName: "lock.open")
                            }
                            Text(lock.isUnlocking ? "Authenticating…" : "Unlock")
                        }
                        .orbFont(size: 13, weight: .semibold)
                        // onAccent on the accent fill is contrast-tested
                        // (≥ 4.5:1) for every accent in both appearances.
                        .foregroundStyle(ORBTheme.onAccent)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 10)
                        .background(ORBTheme.accent)
                        .clipShape(RoundedRectangle(cornerRadius: ORBMetrics.radiusMD))
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.defaultAction)
                    .disabled(lock.isUnlocking)

                    if let failure = lock.lastFailureMessage {
                        Label(failure, systemImage: "exclamationmark.triangle.fill")
                            .orbFont(size: 12)
                            .foregroundStyle(ORBTheme.danger)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 360)
                    }

                    if let onOpenSettings {
                        Button {
                            // Changing the setting requires the same proof as
                            // unlocking — the link chains both.
                            Task {
                                await lock.unlock()
                                if lock.isUnlocked { onOpenSettings() }
                            }
                        } label: {
                            Label("Lock settings", systemImage: "gearshape")
                                .orbFont(size: 12, weight: .medium)
                                .foregroundStyle(ORBTheme.accentLink)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(ORBTheme.accentSubtle)
                                .clipShape(RoundedRectangle(cornerRadius: ORBMetrics.radiusSM))
                        }
                        .buttonStyle(.plain)
                        .disabled(lock.isUnlocking)
                        .padding(.top, 8)
                    }
                }
                .padding(.top, 22)
            }

            // Quit is a different action class (termination, not navigation),
            // so it lives away from the unlock cluster.
            VStack {
                Spacer()
                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Text("Quit ORB")
                        .orbFont(size: 12, weight: .medium)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .padding(.bottom, 16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea())
        .task {
            // Let the window finish appearing so the system prompt attaches
            // to a visible ORB window, then ask once.
            try? await Task.sleep(for: .milliseconds(250))
            await lock.autoPromptIfNeeded(appIsActive: appIsActive())
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await lock.autoPromptIfNeeded(appIsActive: true) }
        }
    }
}
