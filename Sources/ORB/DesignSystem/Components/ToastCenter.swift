import SwiftUI
import Observation

enum ORBToastKind: Equatable, Sendable {
    case info, success, warning, error

    var systemImage: String {
        switch self {
        case .info: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    var tint: Color {
        switch self {
        case .info: return ORBTheme.info
        case .success: return ORBTheme.success
        case .warning: return ORBTheme.warning
        case .error: return ORBTheme.danger
        }
    }

    var label: String {
        switch self {
        case .info: return "Info"
        case .success: return "Success"
        case .warning: return "Warning"
        case .error: return "Error"
        }
    }

    /// Errors linger longer; they are the ones people need to read.
    var defaultDuration: TimeInterval { self == .error ? 8 : 4 }
}

struct ORBToastItem: Identifiable, Equatable, Sendable {
    let id: UUID
    let kind: ORBToastKind
    let message: String
}

/// Queue of transient messages. Show with `show(_:kind:)`; the host modifier
/// renders them. Newest last; at most `maxVisible` are kept (oldest evicted).
@MainActor
@Observable
final class ToastCenter {
    private(set) var toasts: [ORBToastItem] = []
    let maxVisible: Int
    @ObservationIgnored private var timers: [UUID: Task<Void, Never>] = [:]

    init(maxVisible: Int = 3) {
        self.maxVisible = max(1, maxVisible)
    }

    @discardableResult
    func show(_ message: String, kind: ORBToastKind = .info, duration: TimeInterval? = nil) -> UUID {
        let item = ORBToastItem(id: UUID(), kind: kind, message: message)
        toasts.append(item)
        while toasts.count > maxVisible { dismiss(toasts[0].id) }
        let seconds = duration ?? kind.defaultDuration
        if seconds > 0 {
            timers[item.id] = Task { [weak self] in
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled else { return }
                self?.dismiss(item.id)
            }
        }
        return item.id
    }

    func dismiss(_ id: UUID) {
        timers.removeValue(forKey: id)?.cancel()
        toasts.removeAll { $0.id == id }
    }

    func dismissAll() {
        for id in toasts.map(\.id) { dismiss(id) }
    }
}

private struct ORBToastHost: ViewModifier {
    let center: ToastCenter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            VStack(spacing: ORBMetrics.spacingXS) {
                ForEach(center.toasts) { toast in
                    ORBToast(item: toast) { center.dismiss(toast.id) }
                        .transition(ORBMotion.transition(reduceMotion: reduceMotion))
                }
            }
            .padding(ORBMetrics.spacingMD)
            .orbAnimation(.standard, value: center.toasts)
        }
        .onChange(of: center.toasts.last) { _, new in
            guard let new else { return }
            // Announce to VoiceOver; toasts vanish before they can be focused.
            if let app = NSApp {
                NSAccessibility.post(element: app, notification: .announcementRequested,
                                     userInfo: [.announcement: "\(new.kind.label): \(new.message)"])
            }
        }
    }
}

extension View {
    /// Renders `center`'s toasts over this view (put it near the root).
    func orbToastHost(_ center: ToastCenter) -> some View {
        modifier(ORBToastHost(center: center))
    }
}
