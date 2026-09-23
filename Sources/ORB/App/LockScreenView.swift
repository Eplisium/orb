import SwiftUI

/// Full-window gate shown until the user performs the one "allow all access"
/// gesture (Touch ID, Apple Watch, or the Mac password). Replaces the legacy
/// keychain password dialog with modern authentication.
struct LockScreenView: View {
    @ObservedObject var lock: AppLock
    let accent: Color

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(accent.opacity(0.10))
                    .frame(width: 96, height: 96)
                Image(systemName: "lock.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(accent)
            }

            Text("ORB is locked")
                .font(.title2.weight(.semibold))

            Text("Use \(lock.biometricLabel) or your Mac password to unlock and allow full access to your keys and sessions.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            Button {
                Task { await lock.unlock() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: lock.biometricLabel == "Touch ID" ? "touchid" : "lock.open")
                    Text("Unlock — Allow All Access")
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(accent)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)

            if let failure = lock.lastFailureMessage {
                Text(failure)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Text("Turn this off in Settings → API Key → Security.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea())
    }
}
