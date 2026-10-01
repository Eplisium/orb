import SwiftUI

// MARK: - ORB metrics (plan 9.3)
//
// The numeric half of the design tokens: spacing scale, panel radii, and
// type sizes. Pure values — no view state, no appearance lookups, so they
// are trivially unit-testable. Existing views keep their current pixel
// values; adopting these tokens view by view belongs to the supervised
// shell session.

enum ORBMetrics {
    // MARK: Spacing scale (pt): 4, 8, 12, 16, 24, 32

    static let spacingXXS: CGFloat = 4
    static let spacingXS: CGFloat = 8
    static let spacingSM: CGFloat = 12
    static let spacingMD: CGFloat = 16
    static let spacingLG: CGFloat = 24
    static let spacingXL: CGFloat = 32

    /// The full spacing scale in ascending order. Views pick from these
    /// steps instead of inventing intermediate values.
    static let spacingScale: [CGFloat] = [
        spacingXXS, spacingXS, spacingSM, spacingMD, spacingLG, spacingXL,
    ]

    // MARK: Corner radii scale (Phase 1): 6 / 10 / 14

    static let radiusSM: CGFloat = 6
    static let radiusMD: CGFloat = 10
    static let radiusLG: CGFloat = 14
    static let radiusScale: [CGFloat] = [radiusSM, radiusMD, radiusLG]

    /// Minimum interactive hit target.
    static let minHitTarget: CGFloat = 28

    // MARK: Corner radii (pt). Panels/cards stay in the documented 10–12
    // band; controls keep their native shape.

    /// Cards and grouped content surfaces.
    static let cardRadius: CGFloat = 10
    /// Panels and elevated sheets.
    static let panelRadius: CGFloat = 12

    // MARK: Type sizes (pt). Body 13–14; captions 11–12. The plan retires
    // the widespread 9–10 pt informational text for important content.

    static let bodySize: CGFloat = 13
    static let bodyLargeSize: CGFloat = 14
    static let captionSize: CGFloat = 11
    static let captionLargeSize: CGFloat = 12
}
