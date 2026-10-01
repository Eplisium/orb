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
