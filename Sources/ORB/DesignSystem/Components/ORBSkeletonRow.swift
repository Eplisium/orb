import SwiftUI

/// Placeholder row for loading lists. The shimmer is skipped under Reduce
/// Motion (a static placeholder remains).
struct ORBSkeletonRow: View {
    var lines = 2
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = -1

    /// Whether the shimmer should animate. Exposed for tests.
    static func shimmers(reduceMotion: Bool) -> Bool { !ORBMotion.shouldReduce(system: reduceMotion) }

    var body: some View {
        HStack(spacing: ORBMetrics.spacingSM) {
            RoundedRectangle(cornerRadius: ORBMetrics.radiusSM).fill(fill).frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: ORBMetrics.spacingXS) {
                ForEach(0..<max(1, lines), id: \.self) { i in
                    RoundedRectangle(cornerRadius: 3).fill(fill)
                        .frame(height: 10)
                        .frame(maxWidth: i == 0 ? .infinity : 160, alignment: .leading)
                }
            }
        }
        .padding(.vertical, ORBMetrics.spacingXS)
        .overlay { shimmer }
        .clipped()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading")
        .onAppear {
            guard Self.shimmers(reduceMotion: reduceMotion) else { return }
            withAnimation(ORBMotion.looping(.linear(duration: 1.4).repeatForever(autoreverses: false), system: reduceMotion)) { phase = 1.5 }
        }
    }

    private var fill: Color { Color.primary.opacity(0.08) }

    @ViewBuilder private var shimmer: some View {
        if Self.shimmers(reduceMotion: reduceMotion) {
            GeometryReader { geo in
                LinearGradient(colors: [.clear, Color.primary.opacity(0.08), .clear],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(width: geo.size.width * 0.5)
                    .offset(x: geo.size.width * phase)
            }
            .allowsHitTesting(false)
        }
    }
}
