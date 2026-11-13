import Foundation

/// The view's Undo handle is consumed only by a successful restore or an explicit,
/// non-busy dismissal. Every asynchronous callback carries its removal generation.
struct LibraryUndoPresentation {
    private(set) var current: LibraryRemoval?
    private(set) var errorMessage: String?
    private(set) var isRestoring = false
    private var generation: LibraryUndoToken?

    mutating func present(_ removal: LibraryRemoval) {
        current = removal
        generation = removal.token
        isRestoring = false
        errorMessage = nil
    }

    func remainingDuration(at now: Date) -> TimeInterval {
        guard let current else { return 0 }
        return max(0, current.expiresAt.timeIntervalSince(now))
    }

    func canUndo(at now: Date) -> Bool {
        current != nil && !isRestoring && remainingDuration(at: now) > 0
    }

    mutating func beginUndo(at now: Date) -> LibraryRemoval? {
        guard canUndo(at: now), let current else { return nil }
        isRestoring = true
        errorMessage = nil
        return current
    }

    mutating func completeUndo(_ token: LibraryUndoToken, error: Error?) {
        guard current?.token == token, isRestoring else { return }
        isRestoring = false
        if let error {
            errorMessage = "Couldn't restore: \(error.localizedDescription)"
        } else {
            current = nil
            errorMessage = nil
        }
    }

    @discardableResult
    mutating func dismiss(_ token: LibraryUndoToken) -> Bool {
        guard current?.token == token, !isRestoring else { return false }
        current = nil
        errorMessage = nil
        return true
    }

    mutating func completeDismiss(_ token: LibraryUndoToken, error: Error?) {
        guard generation == token, current == nil else { return }
        if let error { errorMessage = "Cleanup needs retry: \(error.localizedDescription)" }
    }

    mutating func clearError() { errorMessage = nil }
}
