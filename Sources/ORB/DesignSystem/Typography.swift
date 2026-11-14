import SwiftUI
import AppKit

// MARK: - Type scale (Phase 1)
//
// Built on system text styles so user text-size settings apply. macOS maps
// caption/footnote to 10 pt, which is below ORB's 11 pt floor, so the two
// smallest steps use `subheadline` (11) and `callout` (12) instead. A unit
// test checks every step against NSFont.preferredFont.

enum ORBFont {
    enum Style: CaseIterable, Sendable {
        case caption, footnote, body, headline, title3, title2, title

        var textStyle: Font.TextStyle {
            switch self {
            case .caption: return .subheadline
            case .footnote: return .callout
            case .body, .headline: return .body
            case .title3: return .title3
            case .title2: return .title2
            case .title: return .title
            }
        }

        var nsTextStyle: NSFont.TextStyle {
            switch self {
            case .caption: return .subheadline
            case .footnote: return .callout
            case .body, .headline: return .body
            case .title3: return .title3
            case .title2: return .title2
            case .title: return .title1
            }
        }

        var weight: Font.Weight { self == .headline ? .semibold : .regular }

        var font: Font { Font.system(textStyle).weight(weight) }

        /// Default point size at the standard text-size setting.
        var basePointSize: CGFloat { NSFont.preferredFont(forTextStyle: nsTextStyle).pointSize }

        /// Point size at a text scale, never below the 11 pt floor.
        func pointSize(scale: CGFloat) -> CGFloat {
            max(ORBFont.minimumPointSize, (basePointSize * scale).rounded())
        }

        /// The token at a text scale. macOS has no Dynamic Type, so a scaled
        /// token is a fixed-size system font; at scale 1 it is the text style.
        func font(scale: CGFloat, weight override: Font.Weight? = nil, design: Font.Design = .default) -> Font {
            let w = override ?? weight
            if scale == 1 && design == .default { return Font.system(textStyle).weight(w) }
            return Font.system(size: pointSize(scale: scale), weight: w, design: design)
        }
    }

    /// Smallest size permitted anywhere in ORB UI.
    static let minimumPointSize: CGFloat = 11

    static let caption = Style.caption.font
    static let footnote = Style.footnote.font
    static let body = Style.body.font
    static let headline = Style.headline.font
    static let title3 = Style.title3.font
    static let title2 = Style.title2.font
    static let title = Style.title.font
    /// Monospaced, for IDs, code and numbers.
    static let code = Font.system(.callout, design: .monospaced)
}

/// `.orbFont(.body)`: an `ORBFont` token resolved against the environment's
/// text scale (`\.orbTextScale`), so it follows the app's text-size setting
/// wherever that setting is offered. Prefer it to `.font(ORBFont.body)` in
/// new code: the static tokens cannot read the environment.
struct ORBStyledFont: ViewModifier {
    @Environment(\.orbTextScale) private var scale
    let style: ORBFont.Style
    var weight: Font.Weight?
    var design: Font.Design = .default

    func body(content: Content) -> some View {
        content.font(style.font(scale: scale, weight: weight, design: design))
    }
}

extension View {
    func orbFont(_ style: ORBFont.Style, weight: Font.Weight? = nil, design: Font.Design = .default) -> some View {
        modifier(ORBStyledFont(style: style, weight: weight, design: design))
    }
}
