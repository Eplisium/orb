import SwiftUI

/// Settings section for network timeouts (Settings → Advanced).
///
/// Edits write through to `NetworkTimeouts` immediately; clamping happens in
/// the store, and the text fields re-clamp on focus loss so pasted values
/// outside the supported range visibly snap to the nearest legal value.
struct NetworkTimeoutsView: View {
    let accent: Color

    @State private var fetchText: String = formatSeconds(NetworkTimeouts.fetch)
    @State private var requestText: String = formatSeconds(NetworkTimeouts.request)
    @State private var validationMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Network Timeouts", systemImage: "clock.badge.exclamationmark")
                .font(.headline)

            Text(
                "Increase these if you're on a slow connection or using long-running "
                + "upstream models. Changes apply to new requests immediately."
            )
            .font(.callout)
            .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Text("Fetch tool")
                    .font(.callout)
                    .frame(width: 110, alignment: .leading)
                TextField("Seconds", text: $fetchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 90)
                Text("seconds (5–300)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Text("API request")
                    .font(.callout)
                    .frame(width: 110, alignment: .leading)
                TextField("Seconds", text: $requestText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 90)
                Text("seconds (30–900)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Button("Reset to Defaults") {
                    NetworkTimeouts.resetToDefaults()
                    fetchText = formatSeconds(NetworkTimeouts.fetch)
                    requestText = formatSeconds(NetworkTimeouts.request)
                    validationMessage = nil
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer()

                if let validationMessage {
                    Text(validationMessage)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Text(
                "Fetch tool: how long the agent's web-page fetch waits before giving up. "
                + "API request: how long OpenRouter calls (including stream setup) may take."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .onChange(of: fetchText) { _, newValue in
            commit(newValue, kind: .fetch)
        }
        .onChange(of: requestText) { _, newValue in
            commit(newValue, kind: .request)
        }
    }

    private enum TimeoutKind {
        case fetch
        case request
    }

    private func commit(_ text: String, kind: TimeoutKind) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let value = Double(trimmed) else {
            validationMessage = trimmed.isEmpty ? nil : "Enter a number of seconds."
            return
        }
        switch kind {
        case .fetch:
            NetworkTimeouts.fetch = value
            fetchText = formatSeconds(NetworkTimeouts.fetch)
        case .request:
            NetworkTimeouts.request = value
            requestText = formatSeconds(NetworkTimeouts.request)
        }
        validationMessage = nil
    }

}

private func formatSeconds(_ value: TimeInterval) -> String {
    value == value.rounded() ? String(Int(value)) : String(value)
}
