import Testing
import AppKit
@testable import ORB

@MainActor
@Suite("Phase 8: app toasts")
struct AppToastTests {
    private func pasteboard() -> NSPasteboard { NSPasteboard(name: .init("orb.tests.\(UUID().uuidString)")) }

    @Test("Copy writes the text and confirms with a success toast naming what was copied")
    func copy() {
        let center = ToastCenter(), board = pasteboard()
        AppToasts.copy("hello", what: "Message", center: center, pasteboard: board)
        #expect(board.string(forType: .string) == "hello")
        #expect(center.toasts.last?.kind == .success)
        #expect(center.toasts.last?.message == "Message copied")
    }

    @Test("Copying nothing does not clobber the clipboard or toast")
    func copyEmpty() {
        let center = ToastCenter(), board = pasteboard()
        board.setString("keep", forType: .string)
        AppToasts.copy("", what: "Message", center: center, pasteboard: board)
        #expect(board.string(forType: .string) == "keep")
        #expect(center.toasts.isEmpty)
    }

    @Test("Job events: done is success, failed is an error that states the outcome, stop is a warning")
    func jobs() {
        let center = ToastCenter()
        AppToasts.jobFinished(.completed, kind: "video", center: center)
        #expect(center.toasts.last?.kind == .success)
        #expect(center.toasts.last?.message == "Your video is ready")
        AppToasts.jobFinished(.failed, kind: "video", center: center)
        #expect(center.toasts.last?.kind == .error)
        AppToasts.jobFinished(.expired, kind: "video", center: center)
        #expect(center.toasts.last?.kind == .error)
        AppToasts.jobFinished(.stoppedLocally, kind: "video", center: center)
        #expect(center.toasts.last?.kind == .warning)
        #expect(center.toasts.last?.message.localizedCaseInsensitiveContains("may still") == true)
    }

    @Test("Non-final states produce no toast")
    func quiet() {
        let center = ToastCenter()
        AppToasts.jobFinished(.polling, kind: "video", center: center)
        AppToasts.jobFinished(.idle, kind: "video", center: center)
        #expect(center.toasts.isEmpty)
    }

    @Test("Saved and failed-to-save toasts")
    func saved() {
        let center = ToastCenter()
        AppToasts.saved("Settings", center: center)
        #expect(center.toasts.last?.message == "Settings saved")
        AppToasts.saveFailed("Settings", reason: "Disk full", center: center)
        #expect(center.toasts.last?.kind == .error)
        #expect(center.toasts.last?.message == "Couldn't save Settings: Disk full")
    }
}
