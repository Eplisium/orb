import SwiftUI

// MARK: - Settings section chrome
//
// Every Settings pane uses one header style and one status vocabulary, so
// General, Accounts & Keys, Usage & Credits, MCP and Advanced read as one app.

/// Section title for a Settings pane: accent symbol, title-3 semibold title,
/// optional one-line subtitle and trailing accessory (refresh button, badge).
struct SettingsSectionHeader<Accessory: View>: View {
    let title: String
    let symbol: String
    var subtitle: String?
    @ViewBuilder var accessory: () -> Accessory

    init(_ title: String, symbol: String, subtitle: String? = nil,
         @ViewBuilder accessory: @escaping () -> Accessory) {
        self.title = title
        self.symbol = symbol
        self.subtitle = subtitle
        self.accessory = accessory
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: ORBMetrics.spacingXS) {
                Image(systemName: symbol)
                    .foregroundStyle(ORBTheme.accent)
                    .frame(minWidth: 20)
                    .accessibilityHidden(true)
                Text(title)
                    .orbFont(.title3, weight: .semibold)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: ORBMetrics.spacingXS)
                accessory()
            }
            .orbFont(.title3, weight: .semibold)
            if let subtitle {
                Text(subtitle)
                    .orbFont(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

extension SettingsSectionHeader where Accessory == EmptyView {
    init(_ title: String, symbol: String, subtitle: String? = nil) {
        self.init(title, symbol: symbol, subtitle: subtitle) { EmptyView() }
    }
}

/// Small subsection label inside a Settings section ("Top models").
struct SettingsSubheading: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .orbFont(.body, weight: .semibold)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Refresh accessory for a section header: a spinner while loading.
struct SettingsRefreshButton: View {
    let isLoading: Bool
    let help: String
    let action: () -> Void

    var body: some View {
        if isLoading {
            ProgressView().controlSize(.small)
        } else {
            Button(action: action) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help(help)
            .accessibilityLabel(help)
        }
    }
}

/// Configured / missing status row ("Inference key configured · sk-or-…1234").
struct SettingsStatusRow: View {
    enum Tone { case ok, attention, neutral }

    let tone: Tone
    let title: String
    var detail: String?

    private var symbol: String {
        switch tone {
        case .ok: return "checkmark.circle.fill"
        case .attention: return "exclamationmark.circle.fill"
        case .neutral: return "minus.circle"
        }
    }

    private var color: Color {
        switch tone {
        case .ok: return ORBTheme.success
        case .attention: return ORBTheme.warning
        case .neutral: return ORBTheme.textSecondary
        }
    }

    var body: some View {
        HStack(spacing: ORBMetrics.spacingXS) {
            Image(systemName: symbol).foregroundStyle(color).accessibilityHidden(true)
            Text(title).orbFont(.body, weight: .medium)
            Spacer(minLength: ORBMetrics.spacingXS)
            if let detail {
                Text(detail)
                    .orbFont(.footnote, design: .monospaced)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(ORBMetrics.spacingSM)
        .background(.orbSurface(0.04), in: RoundedRectangle(cornerRadius: ORBMetrics.radiusMD))
        .overlay { RoundedRectangle(cornerRadius: ORBMetrics.radiusMD).stroke(.orbSurface(0.07), lineWidth: 0.5) }
        .accessibilityElement(children: .combine)
    }
}

/// Inline notice under a section: a symbol plus words, never colour alone.
struct SettingsNotice: View {
    enum Kind { case info, warning, error }

    let kind: Kind
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    private var symbol: String {
        switch kind {
        case .info: return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    private var tint: Color {
        switch kind {
        case .info: return ORBTheme.info
        case .warning: return ORBTheme.warning
        case .error: return ORBTheme.danger
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: ORBMetrics.spacingXS) {
            Image(systemName: symbol).foregroundStyle(tint).accessibilityHidden(true)
            Text(message)
                .orbFont(.footnote)
                .foregroundStyle(ORBTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let actionTitle, let action {
                Button(actionTitle, action: action).controlSize(.small)
            }
        }
        .padding(ORBMetrics.spacingSM)
        .background(tint.opacity(ORBPalette.subtleFillAlpha), in: RoundedRectangle(cornerRadius: ORBMetrics.radiusSM))
        .accessibilityElement(children: .combine)
    }
}
