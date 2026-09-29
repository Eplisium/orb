import SwiftUI

/// Shared building blocks for the Generate studios (Images, Video, Speech,
/// Files, Embeddings). Keeps spacing, labels, cards, and the primary action
/// identical across studios and lets option grids flex to the column width
/// instead of clipping fixed-size pickers.

struct StudioHeader: View {
    let title: String
    let subtitle: String
    let icon: String
    let accent: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(
                    LinearGradient(colors: [accent, accent.opacity(0.7)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 10)
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 16, weight: .semibold))
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }
}

struct StudioLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(.secondary)
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
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Two flexible columns so paired options share the row evenly.
struct StudioGrid<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12, alignment: .top),
                            GridItem(.flexible(), spacing: 12, alignment: .top)],
                  alignment: .leading, spacing: 12) {
            content()
        }
    }
}

/// Rounded, softly outlined container for a group of related controls.
struct StudioCard<Content: View>: View {
    var title: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title { StudioLabel(title) }
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.07), lineWidth: 0.5) }
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
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .padding(6)
                .accessibilityLabel(accessibilityLabel)
            if text.isEmpty {
                Text(placeholder)
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 11).padding(.vertical, 14)
                    .allowsHitTesting(false)
            }
        }
        .frame(height: height)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.10), lineWidth: 0.5) }
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
            HStack(spacing: 8) {
                if isBusy { ProgressView().controlSize(.small).tint(.white) }
                Text(isBusy ? (busyTitle ?? title) : title).fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .foregroundStyle(.white)
            .background(
                isEnabled
                    ? AnyShapeStyle(LinearGradient(colors: [accent, accent.opacity(0.8)],
                                                   startPoint: .top, endPoint: .bottom))
                    : AnyShapeStyle(Color.gray.opacity(0.4)),
                in: RoundedRectangle(cornerRadius: 10)
            )
            .shadow(color: isEnabled ? accent.opacity(0.25) : .clear, radius: 6, y: 2)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }
}

/// Small pill button for secondary actions (Add, Choose, Export…).
struct StudioChipButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Color.primary.opacity(configuration.isPressed ? 0.12 : 0.06), in: Capsule())
    }
}

/// Dashed empty state shared by every studio canvas.
struct StudioEmptyState: View {
    let icon: String
    let title: String
    let message: String
    let accent: Color

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(accent)
                .frame(width: 84, height: 84)
                .background(accent.opacity(0.10), in: Circle())
            Text(title).font(.system(size: 20, weight: .semibold, design: .rounded))
            Text(message)
                .font(.system(size: 13)).foregroundStyle(.secondary)
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
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: tone == .warning ? "exclamationmark.triangle.fill" : "info.circle")
                .font(.system(size: 10))
                .foregroundStyle(tone == .warning ? Color.orange : Color.secondary)
                .padding(.top, 1)
            Text(text).font(.system(size: 11)).foregroundStyle(tone == .warning ? Color.orange : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
