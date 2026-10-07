import Foundation

// MARK: - Images studio gallery + run summary (pure logic)

enum ImageGallery {
    /// How many previously saved images the studio shows; the rest live in Library.
    static let recentLimit = 24

    /// Saved images to show beside this session's results: newest first,
    /// excluding ones already shown as session cards, capped at `limit`.
    /// `hiddenCount` is how many older saved images only Library shows.
    static func recentSaved(
        _ creations: [SavedCreation],
        excluding shown: Set<UUID>,
        limit: Int = recentLimit
    ) -> (items: [SavedCreation], hiddenCount: Int) {
        let images = creations
            .filter { $0.kind == .image && !shown.contains($0.id) }
            .sorted { $0.createdAt > $1.createdAt }
        return (Array(images.prefix(limit)), max(0, images.count - limit))
    }

    /// Session results stay visible until saved; once saved, they disappear
    /// when the creation is deleted in Library (deletions are reflected).
    static func isVisible(savedID: UUID?, liveIDs: Set<UUID>) -> Bool {
        guard let savedID else { return true }
        return liveIDs.contains(savedID)
    }

    /// Splits `total` images into per-request chunks of at most `perRequest`.
    static func chunks(total: Int, perRequest: Int) -> [Int] {
        let size = max(1, perRequest)
        var result: [Int] = []
        var remaining = max(0, total)
        while remaining > 0 {
            let next = min(size, remaining)
            result.append(next)
            remaining -= next
        }
        return result
    }
}

/// Outcome of one multi-request image run, summarised for the user.
struct ImageRunSummary: Equatable {
    var requested: Int
    var delivered: Int = 0
    var cancelled: Int = 0
    /// Failed image count per distinct error message, in first-seen order.
    var failures: [(message: String, count: Int)] = []

    static func == (lhs: ImageRunSummary, rhs: ImageRunSummary) -> Bool {
        lhs.requested == rhs.requested && lhs.delivered == rhs.delivered && lhs.cancelled == rhs.cancelled
            && lhs.failures.map(\.message) == rhs.failures.map(\.message)
            && lhs.failures.map(\.count) == rhs.failures.map(\.count)
    }

    var failedCount: Int { failures.reduce(0) { $0 + $1.count } }

    mutating func recordFailure(_ message: String, images: Int) {
        if let index = failures.firstIndex(where: { $0.message == message }) {
            failures[index].count += images
        } else {
            failures.append((message, images))
        }
    }

    /// nil when everything requested arrived. Otherwise e.g.
    /// "3 of 4 images failed: Rate limited." or "Cancelled — 2 of 4 images arrived."
    var text: String? {
        let failed = failedCount
        guard failed > 0 || cancelled > 0 else {
            // Providers sometimes return fewer images than asked without an error.
            if delivered < requested && delivered > 0 {
                return "Only \(delivered) of \(requested) images arrived; the provider returned fewer than requested."
            }
            return nil
        }
        var parts: [String] = []
        if failed > 0 {
            let noun = requested == 1 ? "image" : "images"
            let reasons = failures.map { $0.message }.joined(separator: " · ")
            parts.append("\(failed) of \(requested) \(noun) failed: \(reasons)")
        }
        if cancelled > 0 {
            parts.append("Cancelled — \(delivered) of \(requested) arrived")
        }
        return parts.joined(separator: ". ") + (parts.last?.hasSuffix(".") == true ? "" : ".")
    }
}
