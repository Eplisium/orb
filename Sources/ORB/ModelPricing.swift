import Foundation

// MARK: - Price unit + the one price formatter
//
// Every catalog price is USD per token. Views pick a display unit (per 1M or
// per 1K tokens, a user setting) and format through `PriceDisplay` so the
// list, detail, compare panel and exports never disagree.

enum PriceUnit: String, CaseIterable, Codable, Identifiable, Sendable {
    case perMillion, perThousand

    static let defaultsKey = "orb.browser.priceUnit"

    var id: String { rawValue }
    var tokens: Double { self == .perMillion ? 1_000_000 : 1_000 }
    var suffix: String { self == .perMillion ? "1M" : "1K" }
    var title: String { self == .perMillion ? "Per 1M tokens" : "Per 1K tokens" }

    static func load(from defaults: UserDefaults = .standard) -> PriceUnit {
        defaults.string(forKey: defaultsKey).flatMap(PriceUnit.init(rawValue:)) ?? .perMillion
    }
}

enum PriceDisplay {
    /// Parses a catalog price string; negative sentinels ("-1" = variable
    /// router pricing) and garbage give nil.
    static func perToken(_ raw: String?) -> Double? {
        guard let raw, let value = Double(raw), value >= 0, value.isFinite else { return nil }
        return value
    }

    /// Bare amount in `unit`: "$3", "$0.15", "$0.0375".
    static func amount(perToken: Double, unit: PriceUnit) -> String {
        let scaled = perToken * unit.tokens
        if scaled == scaled.rounded() { return "$" + String(format: "%.0f", scaled) }
        // Per-1K prices are 1000× smaller, so keep three more decimals.
        let decimals = unit == .perMillion ? 4 : 7
        if scaled > 0, scaled < pow(10, Double(-decimals)) { return "$" + String(format: "%.2g", scaled) }
        return trimmed(scaled, decimals: decimals)
    }

    /// At least two decimals, trailing zeros trimmed beyond that.
    private static func trimmed(_ value: Double, decimals: Int) -> String {
        var text = String(format: "%.\(decimals)f", value)
        while text.hasSuffix("0"), let dot = text.firstIndex(of: "."),
              text.distance(from: dot, to: text.endIndex) > 3 {
            text.removeLast()
        }
        return "$" + text
    }

    /// "$3 / 1M".
    static func text(perToken: Double, unit: PriceUnit) -> String {
        "\(amount(perToken: perToken, unit: unit)) / \(unit.suffix)"
    }

    /// Same as `text` but for a raw catalog string; nil when unusable.
    static func text(_ raw: String?, unit: PriceUnit) -> String? {
        perToken(raw).map { text(perToken: $0, unit: unit) }
    }

    /// Per-request USD (web search, request fee): "$0.01".
    static func flat(_ raw: String?) -> String? {
        guard let value = perToken(raw), value > 0 else { return nil }
        return PriceFormat.perMillion(value)
    }
}

// MARK: - Extra price lines and tiers

struct PriceLine: Equatable, Identifiable, Sendable {
    let title: String
    let value: String
    var id: String { title }
}

extension Pricing {
    /// Prices beyond input/output, in a fixed order, skipping absent/zero.
    func extraLines(unit: PriceUnit) -> [PriceLine] {
        var lines: [PriceLine] = []
        func token(_ title: String, _ raw: String?) {
            guard let v = PriceDisplay.perToken(raw), v > 0 else { return }
            lines.append(PriceLine(title: title, value: PriceDisplay.text(perToken: v, unit: unit)))
        }
        token("Cache read", inputCacheRead)
        token("Cache write", inputCacheWrite)
        token("Cache write (1h)", inputCacheWrite1h)
        token("Reasoning", internalReasoning)
        token("Image in", image)
        token("Image out", imageOutput)
        token("Audio in", audio)
        token("Audio out", audioOutput)
        token("Audio cache", inputAudioCache)
        if let s = PriceDisplay.flat(webSearch) { lines.append(PriceLine(title: "Web search", value: "\(s) / request")) }
        if let s = PriceDisplay.flat(request) { lines.append(PriceLine(title: "Per request", value: s)) }
        if let discount, discount > 0 {
            lines.append(PriceLine(title: "Discount", value: "\(Int((discount * 100).rounded()))%"))
        }
        return lines
    }

    /// One line per override tier, e.g. "Above 272K prompt tokens" →
    /// "$4 / 1M in · $15 / 1M out".
    func tierLines(unit: PriceUnit) -> [PriceLine] {
        (overrides ?? []).enumerated().compactMap { index, tier in
            var parts: [String] = []
            if let p = PriceDisplay.text(tier.prompt, unit: unit) { parts.append("\(p) in") }
            if let c = PriceDisplay.text(tier.completion, unit: unit) { parts.append("\(c) out") }
            if let r = PriceDisplay.text(tier.inputCacheRead, unit: unit) { parts.append("\(r) cache read") }
            guard !parts.isEmpty else { return nil }
            let title = tier.conditionText.isEmpty ? "Tier \(index + 1)" : tier.conditionText
            return PriceLine(title: title, value: parts.joined(separator: " · "))
        }
    }
}

extension PricingOverride {
    /// "Above 272K prompt tokens", "00:00–16:00 UTC (Mon–Fri)".
    var conditionText: String {
        var parts: [String] = []
        if let min = minPromptTokens { parts.append("Above \(BrowserFormat.context(min)) prompt tokens") }
        if utcStart != nil || utcEnd != nil {
            func hhmm(_ v: Int?) -> String {
                guard let v else { return "…" }
                return String(format: "%02d:%02d", v / 100, v % 100)
            }
            var window = "\(hhmm(utcStart))–\(hhmm(utcEnd)) UTC"
            if let days = utcDays, !days.isEmpty {
                window += " (" + days.map { String($0.prefix(3)).capitalized }.joined(separator: ", ") + ")"
            }
            parts.append(window)
        }
        return parts.joined(separator: ", ")
    }
}
