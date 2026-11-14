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

/// The in-app "Animations: Reduce" override, published by `orbAppearance()`.
/// Views combine it with the system flag through `ORBMotion.reduces`.
private struct ORBForcesReducedMotionKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var orbForcesReducedMotion: Bool {
        get { self[ORBForcesReducedMotionKey.self] }
        set { self[ORBForcesReducedMotionKey.self] = newValue }
    }
}

extension ORBMotion {
    /// Reduce Motion as views see it: the OS setting or the in-app override.
    static func reduces(system: Bool, forced: Bool) -> Bool { system || forced }

    /// The animation an `orbAnimation` modifier applies.
    static func resolvedAnimation(_ token: Token, system: Bool, forced: Bool) -> Animation? {
        token.animation(reduceMotion: reduces(system: system, forced: forced))
    }
}

private struct ORBAnimationModifier<V: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.orbForcesReducedMotion) private var forcedReduceMotion
    let token: ORBMotion.Token
    let value: V

    func body(content: Content) -> some View {
        content.animation(ORBMotion.resolvedAnimation(token, system: reduceMotion, forced: forcedReduceMotion), value: value)
    }
}

extension View {
    /// `.animation(_:value:)` using an ORB motion token that honours Reduce Motion.
    func orbAnimation<V: Equatable>(_ token: ORBMotion.Token = .standard, value: V) -> some View {
        modifier(ORBAnimationModifier(token: token, value: value))
    }
}


extension ORBMotion {
    /// Reduce Motion from the OS, or the in-app override set to "Reduce".
    static func shouldReduce(system: Bool, defaults: UserDefaults = .standard) -> Bool {
        AppearancePrefs.load(from: defaults).effectiveReduceMotion(system: system)
    }

    /// Endless pulses and shimmers are removed entirely when motion is reduced.
    static func looping(_ animation: Animation, system: Bool, defaults: UserDefaults = .standard) -> Animation? {
        shouldReduce(system: system, defaults: defaults) ? nil : animation
    }

    /// Short transitions become instant when motion is reduced.
    static func oneShot(_ animation: Animation, system: Bool, defaults: UserDefaults = .standard) -> Animation? {
        shouldReduce(system: system, defaults: defaults) ? nil : animation
    }
}
