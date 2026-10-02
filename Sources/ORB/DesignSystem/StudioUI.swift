import SwiftUI

/// Shared building blocks for the Generate studios (Images, Video, Speech,
/// Files, Embeddings). Keeps spacing, labels, cards, and the primary action
/// identical across studios and lets option grids flex to the column width
/// instead of clipping fixed-size pickers.

struct StudioHeader<Trailing: View>: View {
    let title: String
    let subtitle: String
    let icon: String
    let accent: Color
    @ViewBuilder var trailing: Trailing

    init(title: String, subtitle: String, icon: String, accent: Color, @ViewBuilder trailing: () -> Trailing) {
        self.title = title; self.subtitle = subtitle; self.icon = icon; self.accent = accent
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: ORBMetrics.spacingSM) {
            Image(systemName: icon)
                .font(ORBFont.body.weight(.semibold))
                .foregroundStyle(ORBTheme.onAccent)
                .frame(width: 36, height: 36)
                .background(accent, in: RoundedRectangle(cornerRadius: ORBMetrics.radiusMD))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(ORBFont.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
                Text(subtitle).font(ORBFont.caption).foregroundStyle(ORBTheme.textSecondary)
            }
            Spacer(minLength: 0)
            trailing
        }
    }
}

extension StudioHeader where Trailing == EmptyView {
    init(title: String, subtitle: String, icon: String, accent: Color) {
        self.init(title: title, subtitle: subtitle, icon: icon, accent: accent) { EmptyView() }
    }
}

struct StudioLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(ORBFont.caption.weight(.semibold))
            .tracking(0.6)
            .foregroundStyle(ORBTheme.textSecondary)
    }
}

/// Label + control stacked, control stretched to the available width.
struct StudioField<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(ORBFont.caption.weight(.medium)).foregroundStyle(ORBTheme.textSecondary)
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Two flexible columns so paired options share the row evenly.
struct StudioGrid<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: ORBMetrics.spacingSM, alignment: .top),
                            GridItem(.flexible(), spacing: ORBMetrics.spacingSM, alignment: .top)],
                  alignment: .leading, spacing: ORBMetrics.spacingSM) {
            content()
        }
    }
}

/// Rounded, softly outlined container for a group of related controls.
struct StudioCard<Content: View>: View {
    var title: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        ORBCard(title: title, content: content)
    }
}

struct StudioPromptEditor: View {
    @Binding var text: String
    let placeholder: String
    let accessibilityLabel: String
    var height: CGFloat = 112

    var body: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $text)
                .font(ORBFont.body)
                .scrollContentBackground(.hidden)
                .padding(6)
                .accessibilityLabel(accessibilityLabel)
            if text.isEmpty {
                Text(placeholder)
                    .font(ORBFont.body)
                    .foregroundStyle(ORBTheme.textTertiary)
                    .padding(.horizontal, 11).padding(.vertical, 14)
                    .allowsHitTesting(false)
            }
        }
        .frame(height: height)
        .background(ORBTheme.surfaceSunken, in: RoundedRectangle(cornerRadius: ORBMetrics.radiusMD))
        .overlay { RoundedRectangle(cornerRadius: ORBMetrics.radiusMD).stroke(ORBTheme.stroke, lineWidth: 0.5) }
    }
}

struct StudioPrimaryButton: View {
    let title: String
    var busyTitle: String?
    var isBusy = false
    let isEnabled: Bool
    let accent: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: ORBMetrics.spacingXS) {
                if isBusy { ProgressView().controlSize(.small) }
                Text(isBusy ? (busyTitle ?? title) : title).font(ORBFont.body.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .foregroundStyle(isEnabled ? ORBTheme.onAccent : ORBTheme.textSecondary)
            .background(
                isEnabled ? AnyShapeStyle(accent) : AnyShapeStyle(Color.gray.opacity(0.25)),
                in: RoundedRectangle(cornerRadius: ORBMetrics.radiusMD)
            )
            .shadow(color: isEnabled ? accent.opacity(0.25) : .clear, radius: 6, y: 2)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }
}

/// Small pill button for secondary actions (Add, Choose, Export…).
struct StudioChipButtonStyle: ButtonStyle {
    var isSelected = false
    var accent: Color = ORBTheme.accent

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(ORBFont.caption.weight(isSelected ? .semibold : .medium))
            .foregroundStyle(ORBTheme.textPrimary)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(isSelected ? accent.opacity(0.18) : Color.primary.opacity(configuration.isPressed ? 0.12 : 0.06), in: Capsule())
            // A ring as well as a tint, so selection is not colour alone.
            .overlay(Capsule().stroke(isSelected ? accent : .clear, lineWidth: 1.5))
    }
}

/// Dashed empty state shared by every studio canvas.
struct StudioEmptyState: View {
    let icon: String
    let title: String
    let message: String
    let accent: Color

    var body: some View {
        VStack(spacing: ORBMetrics.spacingSM) {
            Image(systemName: icon)
                .font(.system(.largeTitle, weight: .light))
                .foregroundStyle(accent)
                .frame(width: 84, height: 84)
                .background(accent.opacity(ORBPalette.subtleFillAlpha), in: Circle())
                .accessibilityHidden(true)
            Text(title).font(ORBFont.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
            Text(message)
                .font(ORBFont.body).foregroundStyle(ORBTheme.textSecondary)
                .multilineTextAlignment(.center).frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct StudioNotice: View {
    enum Tone { case info, warning }
    let text: String
    var tone: Tone = .info

    var body: some View {
        let tint = tone == .warning ? ORBTheme.warning : ORBTheme.textSecondary
        HStack(alignment: .top, spacing: ORBMetrics.spacingXXS + 2) {
            Image(systemName: tone == .warning ? "exclamationmark.triangle.fill" : "info.circle")
                .font(ORBFont.caption)
                .foregroundStyle(tint)
                .padding(.top, 1)
                .accessibilityHidden(true)
            Text(text).font(ORBFont.caption).foregroundStyle(tint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
