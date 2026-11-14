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

/// Bottom bar holding a studio's primary action; attach it with
/// `.safeAreaInset(edge: .bottom, spacing: 0)` so it stays visible however
/// tall the form above it grows.
struct StudioPinnedFooter<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) { content }
            .padding(.horizontal, 18).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.bar)
            // A fixed-height rule rather than `Divider()`: inside a safe-area
            // inset a Divider takes the vertical axis and draws a hairline
            // straight down through the button.
            .overlay(alignment: .top) {
                Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1)
            }
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

// MARK: - Shared studio scaffold (V-3)

/// The left control column every studio uses: header + scrolling controls,
/// with the primary action pinned in a footer that is always on screen.
/// Errors belong at the top of `footer` (STUDIO-2), never at the end of the
/// scrolling form where they can render below the fold.
struct StudioControlColumn<Controls: View, Footer: View>: View {
    static var width: CGFloat { 340 }
    @ViewBuilder var controls: Controls
    @ViewBuilder var footer: Footer

    init(@ViewBuilder controls: () -> Controls, @ViewBuilder footer: () -> Footer) {
        self.controls = controls()
        self.footer = footer()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) { controls }
                .padding(18)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            StudioPinnedFooter { footer }
        }
        .frame(width: Self.width)
        .background(.ultraThinMaterial.opacity(0.72))
    }
}

/// Control column + hairline + results pane: the layout shared by Images,
/// Video, Speech and Embeddings (Files hosts the Library full-width).
struct StudioScaffold<Controls: View, Footer: View, Results: View>: View {
    @ViewBuilder var controls: Controls
    @ViewBuilder var footer: Footer
    @ViewBuilder var results: Results

    init(@ViewBuilder controls: () -> Controls, @ViewBuilder footer: () -> Footer,
         @ViewBuilder results: () -> Results) {
        self.controls = controls(); self.footer = footer(); self.results = results()
    }

    var body: some View {
        HStack(spacing: 0) {
            StudioControlColumn { controls } footer: { footer }
            Rectangle().fill(.orbSurface(0.07)).frame(width: 1)
            results
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))
        }
    }
}

/// Heading for a results/history pane section.
struct StudioSectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(ORBFont.caption.weight(.bold))
            .foregroundStyle(ORBTheme.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
