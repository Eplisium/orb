import Foundation

/// Coalesces high-frequency streamed values to a display-frame cadence while
/// guaranteeing a trailing publish if the provider pauses after a small delta.
@MainActor
final class StreamPublishCoalescer<Value> {
    private let interval: Duration
    private let characterBackstop: Int
    private let publish: (Value) -> Void

    private var latestValue: Value?
    private var pendingCharacters = 0
    private var lastPublish: ContinuousClock.Instant?
    private var trailingTask: Task<Void, Never>?

    init(
        interval: Duration,
        characterBackstop: Int,
        publish: @escaping (Value) -> Void
    ) {
        self.interval = interval
        self.characterBackstop = characterBackstop
        self.publish = publish
    }

    func submit(_ value: Value, addedCharacters: Int) {
        latestValue = value
        pendingCharacters += max(0, addedCharacters)

        let now = ContinuousClock.now
        guard let lastPublish else {
            publishNow(at: now)
            return
        }

        let elapsed = lastPublish.duration(to: now)
        if elapsed >= interval || pendingCharacters >= characterBackstop {
            publishNow(at: now)
            return
        }

        guard trailingTask == nil else { return }
        let delay = interval - elapsed
        trailingTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            self?.publishNow(at: .now)
        }
    }

    func flush() {
        guard pendingCharacters > 0, latestValue != nil else { return }
        publishNow(at: .now)
    }

    func cancel() {
        trailingTask?.cancel()
        trailingTask = nil
        latestValue = nil
        pendingCharacters = 0
        lastPublish = nil
    }

    private func publishNow(at now: ContinuousClock.Instant) {
        guard let latestValue else { return }
        trailingTask?.cancel()
        trailingTask = nil
        pendingCharacters = 0
        lastPublish = now
        publish(latestValue)
    }
}
