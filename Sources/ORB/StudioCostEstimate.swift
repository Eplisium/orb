import Foundation

/// A pre-run price estimate for a studio (STUDIO-12). Built only from
/// catalog pricing the API publishes; when the price is not known the
/// estimate is `nil` and the UI says so — it never shows `$0` for "unknown".
struct StudioCostEstimate: Equatable, Sendable {
    /// Lowest and highest expected charge in US dollars.
    let low: Double
    let high: Double
    /// What the amount covers, e.g. "2 images" or "8 s at 720p".
    let basis: String

    init(low: Double, high: Double, basis: String) {
        self.low = min(low, high)
        self.high = max(low, high)
        self.basis = basis
    }

    var isRange: Bool { high - low > 0.000_000_5 }

    /// "Estimated ≈ $0.08–$0.12 for 2 images". Always labelled an estimate.
    var label: String {
        let amount = isRange ? "\(Self.dollars(low))–\(Self.dollars(high))" : Self.dollars(low)
        return "Estimated ≈ \(amount) for \(basis)"
    }

    static func dollars(_ value: Double) -> String {
        if value == 0 { return "$0.00" }
        if value < 0.01 { return String(format: "$%.4f", value) }
        if value < 1 { return String(format: "$%.3f", value) }
        return String(format: "$%.2f", value)
    }

    // MARK: Images

    /// Per-image endpoint pricing × image count. Only `output_image` lines
    /// priced per `image` are multiplied; megapixel/token lines depend on
    /// output the user cannot see in advance, so they make the estimate
    /// unknown rather than guessed. Several endpoints (unpinned provider)
    /// yield a min–max range across them.
    static func images(endpoints: [[ImageEndpointPricing]], count: Int, variant: String? = nil) -> StudioCostEstimate? {
        guard count > 0, !endpoints.isEmpty else { return nil }
        var perImage: [Double] = []
        for pricing in endpoints {
            let outputs = pricing.filter { $0.billable == "output_image" }
            guard !outputs.isEmpty else { return nil }
            guard outputs.allSatisfy({ $0.unit == "image" }) else { return nil }
            let matching = variant.flatMap { v in
                let hits = outputs.filter { $0.variant?.caseInsensitiveCompare(v) == .orderedSame }
                return hits.isEmpty ? nil : hits
            } ?? outputs
            perImage.append(contentsOf: matching.map(\.costUSD))
        }
        guard let low = perImage.min(), let high = perImage.max() else { return nil }
        let noun = count == 1 ? "1 image" : "\(count) images"
        return StudioCostEstimate(low: low * Double(count), high: high * Double(count), basis: noun)
    }

    // MARK: Token / character priced modalities

    /// Speech: catalog `pricing.prompt` is USD per input character.
    static func speech(promptPrice: String?, characters: Int) -> StudioCostEstimate? {
        guard characters > 0, let rate = promptPrice.flatMap(Double.init), rate >= 0 else { return nil }
        return StudioCostEstimate(low: rate * Double(characters), high: rate * Double(characters),
                                  basis: characters == 1 ? "1 character" : "\(characters) characters")
    }

    /// Embeddings: `pricing.prompt` is USD per input token. Token counts are
    /// unknown before the call, so the range spans 1 token per 4 characters
    /// (typical English) to 1 token per 2 characters (code, other scripts).
    static func embeddings(promptPrice: String?, characters: Int) -> StudioCostEstimate? {
        guard characters > 0, let rate = promptPrice.flatMap(Double.init), rate >= 0 else { return nil }
        let lowTokens = max(1, characters / 4), highTokens = max(1, (characters + 1) / 2)
        return StudioCostEstimate(low: rate * Double(lowTokens), high: rate * Double(highTokens),
                                  basis: "~\(lowTokens)–\(highTokens) tokens")
    }

    /// Per-1M-token rate line for catalogs priced per token, e.g. "$0.10 / 1M tokens".
    static func perMillionTokens(_ price: String?) -> String? {
        guard let rate = price.flatMap(Double.init), rate >= 0 else { return nil }
        return "\(dollars(rate * 1_000_000)) / 1M tokens"
    }

    // MARK: Video

    /// One parsed `pricing_skus` entry.
    struct VideoSKU: Equatable, Sendable {
        enum Unit: Equatable, Sendable { case perSecond, perVideo }
        let key: String
        let usd: Double
        let unit: Unit
        let resolution: String?
        let audio: Bool?
        /// `text_to_video` / `image_to_video` qualifier, if any.
        let imageToVideo: Bool?
    }

    private static let resolutions = ["360p", "480p", "540p", "720p", "768p", "1080p", "1440p", "2k", "4k"]
    /// SKUs for inputs or special modes the estimator cannot see (reference
    /// clips, continuations, megapixel upscales, input images).
    private static let excludedMarkers = ["long_", "reference", "continuation", "megapixel", "input", "minimum"]

    /// Parses one SKU. Returns nil for keys whose unit is not a recognised
    /// per-second or per-video price (e.g. token-priced `video_tokens`).
    static func parseVideoSKU(key: String, value: String) -> VideoSKU? {
        guard let raw = Double(value.trimmingCharacters(in: .whitespaces)), raw >= 0, raw.isFinite else { return nil }
        let lower = key.lowercased()
        guard !excludedMarkers.contains(where: { lower.contains($0) }) else { return nil }
        let usd = lower.hasPrefix("cents_") ? raw / 100 : raw
        let unit: VideoSKU.Unit
        if lower == "generate" || lower == "per_video" || lower == "per_generation" {
            unit = .perVideo
        } else if lower.contains("duration_seconds") || lower.contains("per_second") || lower.contains("output_second") {
            unit = .perSecond
        } else {
            return nil
        }
        let resolution = resolutions.first { lower.hasSuffix("_" + $0) || lower.contains("_" + $0 + "_") }
        let audio: Bool? = lower.contains("without_audio") ? false : (lower.contains("with_audio") ? true : nil)
        let i2v: Bool? = lower.contains("image_to_video") ? true : (lower.contains("text_to_video") ? false : nil)
        return VideoSKU(key: key, usd: usd, unit: unit, resolution: resolution, audio: audio, imageToVideo: i2v)
    }

    /// Estimates a video job from SKU pricing × duration. `audio` is the
    /// effective audio choice (nil = model default, unknown). Returns nil
    /// when no SKU applies or a per-second price has no duration.
    static func video(skus: [String: String]?, durationSeconds: Int?, resolution: String?,
                      audio: Bool?, usesFrames: Bool) -> StudioCostEstimate? {
        guard let skus, !skus.isEmpty else { return nil }
        var candidates = skus.compactMap { parseVideoSKU(key: $0.key, value: $0.value) }
        guard !candidates.isEmpty else { return nil }
        // Mode qualifier: keep SKUs for this mode or with no qualifier.
        let byMode = candidates.filter { $0.imageToVideo == nil || $0.imageToVideo == usesFrames }
        if !byMode.isEmpty { candidates = byMode }
        if let audio {
            let byAudio = candidates.filter { $0.audio == audio }
            if !byAudio.isEmpty { candidates = byAudio }
        }
        let wanted = resolution?.lowercased()
        if let wanted, candidates.contains(where: { $0.resolution == wanted }) {
            candidates = candidates.filter { $0.resolution == wanted }
        } else if candidates.contains(where: { $0.resolution == nil }) {
            // The unsuffixed SKU is the model's default tier.
            candidates = candidates.filter { $0.resolution == nil }
        }
        var costs: [Double] = []
        for sku in candidates {
            switch sku.unit {
            case .perVideo: costs.append(sku.usd)
            case .perSecond:
                guard let durationSeconds, durationSeconds > 0 else { continue }
                costs.append(sku.usd * Double(durationSeconds))
            }
        }
        guard var low = costs.min(), var high = costs.max() else { return nil }
        if let minimum = skus.first(where: { $0.key.lowercased().contains("minimum") }),
           let raw = Double(minimum.value) {
            let floor = minimum.key.lowercased().hasPrefix("minimum_cents") ? raw / 100 : raw
            low = max(low, floor); high = max(high, floor)
        }
        var basis = durationSeconds.map { "\($0) s" } ?? "1 video"
        if let resolution, !resolution.isEmpty { basis += " at \(resolution)" }
        return StudioCostEstimate(low: low, high: high, basis: basis)
    }

    /// Human-readable SKU rates with units, e.g. "$0.10/s (720p)" or
    /// "$0.50 / video". Unrecognised keys stay verbatim, labelled "rate".
    static func videoRateLines(_ skus: [String: String]?) -> [String] {
        guard let skus else { return [] }
        return skus.sorted { $0.key < $1.key }.map { key, value in
            guard let sku = parseVideoSKU(key: key, value: value) else { return "\(key): \(value) (rate)" }
            let amount = dollars(sku.usd)
            var qualifiers: [String] = []
            if let r = sku.resolution { qualifiers.append(r) }
            if let a = sku.audio { qualifiers.append(a ? "with audio" : "no audio") }
            if let i = sku.imageToVideo { qualifiers.append(i ? "image→video" : "text→video") }
            let suffix = qualifiers.isEmpty ? "" : " (\(qualifiers.joined(separator: ", ")))"
            return sku.unit == .perSecond ? "\(amount)/s\(suffix)" : "\(amount) / video\(suffix)"
        }
    }
}
