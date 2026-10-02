import SwiftUI

/// Full-window gate shown until the user performs the one "allow all access"
/// gesture (Touch ID, Apple Watch, or the Mac password). Replaces the legacy
/// keychain password dialog with modern authentication.
struct LockScreenView: View {
    @ObservedObject var lock: AppLock
    let accent: Color
    /// Jump straight to Account so the preference is one click away.
    var onOpenSettings: (() -> Void)? = nil

    /// Deepened accent for the primary button: white on the raw accent is only
    /// ~3.4:1 contrast, this keeps the label comfortably above 4.5:1.
    private let buttonFill = Color(red: 0.34, green: 0.27, blue: 0.69)

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

                    Text("ORB is locked")
                        .orbFont(size: 22, weight: .semibold)
                        .foregroundStyle(.white)

                    VStack(spacing: 6) {
                        Text("Unlock with \(lock.biometricLabel) or your Mac password.")
                            .foregroundStyle(.white.opacity(0.85))
                        Text("Your API keys and sessions stay protected. ORB locks again when your Mac sleeps or locks, or after a period of inactivity.")
                            .orbFont(size: 12)
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    .orbFont(size: 13)
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
                                    .tint(.white)
                            } else {
                                Image(systemName: "lock.open")
                            }
                            Text(lock.isUnlocking ? "Authenticating…" : "Unlock")
                        }
                        .orbFont(size: 13, weight: .semibold)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 10)
                        .background(buttonFill)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.defaultAction)
                    .disabled(lock.isUnlocking)

                    if let failure = lock.lastFailureMessage {
                        Text(failure)
                            .orbFont(size: 11)
                            .foregroundStyle(.red)
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
                                .foregroundStyle(accent)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(accent.opacity(0.12))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
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
                        .foregroundStyle(.white.opacity(0.72))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .padding(.bottom, 16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea())
    }
}
