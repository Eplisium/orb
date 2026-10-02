import AppKit

/// App-wide toast entry points (Phase 8). One shared `ToastCenter` is hosted at
/// the root of the main window; everything else calls these helpers.
@MainActor
enum AppToasts {
    static let center = ToastCenter()

    static func copy(_ text: String, what: String, center: ToastCenter = AppToasts.center,
                     pasteboard: NSPasteboard = .general) {
        guard !text.isEmpty else { return }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        center.show("\(what) copied", kind: .success, duration: 2)
    }

    static func saved(_ what: String, center: ToastCenter = AppToasts.center) {
        center.show("\(what) saved", kind: .success, duration: 2)
    }

    static func saveFailed(_ what: String, reason: String, center: ToastCenter = AppToasts.center) {
        center.show("Couldn't save \(what): \(reason)", kind: .error)
    }

    /// Only final or attention-worthy job states toast; progress ticks stay quiet.
    static func jobFinished(_ state: JobPollingState, kind: String, center: ToastCenter = AppToasts.center) {
        switch state {
        case .completed:
            center.show("Your \(kind) is ready", kind: .success)
        case .failed:
            center.show("The \(kind) job failed", kind: .error)
        case .expired:
            center.show("The \(kind) result expired at the provider", kind: .error)
        case .cancelled:
            center.show("The \(kind) job was cancelled", kind: .warning)
        case .stoppedLocally:
            center.show("Stopped checking the \(kind) job. It may still be running at the provider.", kind: .warning)
        case .idle, .polling:
            break
        }
    }
}
