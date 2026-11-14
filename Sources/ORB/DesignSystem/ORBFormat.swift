import Foundation

// MARK: - Shared value formatting
//
// One money formatter for every account, usage and credits surface, so the
// sidebar chip, Settings and the usage pane can never disagree about how a
// figure is written.

enum ORBMoney {
    /// The placeholder for an unknown amount. Unknown is never shown as zero.
    static let unknown = "—"

    private static func makeFormatter(digits: Int) -> NumberFormatter {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US")
        f.numberStyle = .decimal
        f.usesGroupingSeparator = true
        f.minimumFractionDigits = digits
        f.maximumFractionDigits = digits
        return f
    }

    // Configured once and never mutated afterwards, so concurrent reads are safe.
    private static let cents = makeFormatter(digits: 2)
    private static let subCents = makeFormatter(digits: 4)

    /// `0` → "$0.00", below one cent → four decimals ("$0.0042"),
    /// otherwise two decimals with grouping ("$1,234.50"); nil or
    /// non-finite → "—". Negative amounts keep their sign.
    static func format(_ value: Double?) -> String {
        guard let value, value.isFinite else { return unknown }
        if value == 0 { return "$0.00" }
        let magnitude = abs(value)
        let digits = magnitude < 0.01 ? 4 : 2
        let formatter = digits == 4 ? subCents : cents
        let body = formatter.string(from: NSNumber(value: magnitude)) ?? String(format: "%.\(digits)f", magnitude)
        return (value < 0 ? "-$" : "$") + body
    }
}

// MARK: - Outbound links

/// OpenRouter pages ORB links to. Keys and management keys are created on
/// different pages; sending a user to the wrong one produces a key that the
/// credits endpoint rejects.
enum OpenRouterLinks {
    /// Create inference (API) keys.
    static let keys = URL(string: "https://openrouter.ai/settings/keys")!
    /// Create management keys (credits, activity, administration).
    static let managementKeys = URL(string: "https://openrouter.ai/settings/management-keys")!
    /// Buy credits / see the balance.
    static let credits = URL(string: "https://openrouter.ai/settings/credits")!
    /// Account activity on the website.
    static let activity = URL(string: "https://openrouter.ai/activity")!
}

/// The ORB project on GitHub (public, no credentials involved).
enum ORBProjectLinks {
    static let repository = URL(string: "https://github.com/Eplisium/orb")!
    static let readme = URL(string: "https://github.com/Eplisium/orb#readme")!
    static let issues = URL(string: "https://github.com/Eplisium/orb/issues")!
    static let releases = URL(string: "https://github.com/Eplisium/orb/releases")!
}
