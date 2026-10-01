import SwiftUI
import AppKit

// MARK: - Motion tokens (Phase 1)
//
// Every animation resolves through `animation(reduceMotion:)`, which
// returns nil under Reduce Motion so state changes become instant.

enum ORBMotion {
    enum Token: CaseIterable, Sendable {
        case quick, standard, slow

        var duration: Double {
            switch self {
            case .quick: return 0.15
            case .standard: return 0.25
            case .slow: return 0.40
            }
        }

        func animation(reduceMotion: Bool) -> Animation? {
            reduceMotion ? nil : .easeInOut(duration: duration)
        }
    }

    /// Reduce Motion from the system, for code outside the view tree.
    static var systemReduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    static func animation(_ token: Token, reduceMotion: Bool) -> Animation? {
        token.animation(reduceMotion: reduceMotion)
    }

    /// Opacity-only transitions are fine under Reduce Motion; movement is not.
    static func transition(reduceMotion: Bool, edge: Edge = .bottom) -> AnyTransition {
        reduceMotion ? .opacity : .move(edge: edge).combined(with: .opacity)
    }
}

private struct ORBAnimationModifier<V: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let token: ORBMotion.Token
    let value: V

    func body(content: Content) -> some View {
        content.animation(token.animation(reduceMotion: reduceMotion), value: value)
    }
}

extension View {
    /// `.animation(_:value:)` using an ORB motion token that honours Reduce Motion.
    func orbAnimation<V: Equatable>(_ token: ORBMotion.Token = .standard, value: V) -> some View {
        modifier(ORBAnimationModifier(token: token, value: value))
    }
}
