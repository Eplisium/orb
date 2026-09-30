import SwiftUI
import UserNotifications

// MARK: - App-lifetime studio state
//
// Studio pages (Images, Video, Speech, Embeddings, Files, Test Suite) used to
// keep their services and results in view-local @State / @StateObject, so
// leaving the page destroyed both the UI *and* the place where an in-flight
// request could deliver its result. Everything here lives for the whole app
// session instead: views are only windows onto it, and running work keeps
// going (and lands its results) while you are on another page.

/// Observable holder for one piece of persisted view state.
@MainActor
final class StudioBox<Value>: ObservableObject {
    @Published var value: Value
    init(_ value: Value) { self.value = value }
}

@MainActor
final class StudioStore {
    static let shared = StudioStore()
    private var boxes: [String: Any] = [:]

    func box<Value>(_ key: String, initial: () -> Value) -> StudioBox<Value> {
        if let existing = boxes[key] as? StudioBox<Value> { return existing }
        let created = StudioBox(initial())
        boxes[key] = created
        return created
    }
}

/// Drop-in replacement for `@State` that survives the view being removed.
/// Closures captured by a running `Task` keep writing to the same box, so a
/// result that arrives while you are on another page is waiting when you return.
@MainActor
@propertyWrapper
struct StudioState<Value>: DynamicProperty {
    @ObservedObject private var box: StudioBox<Value>

    init(wrappedValue: @autoclosure () -> Value, _ key: String) {
        _box = ObservedObject(wrappedValue: StudioStore.shared.box(key, initial: wrappedValue))
    }

    var wrappedValue: Value {
        get { box.value }
        nonmutating set { box.value = newValue }
    }

    var projectedValue: Binding<Value> {
        Binding(get: { box.value }, set: { box.value = $0 })
    }
}

/// One long-lived service per studio, shared by its view and the sidebar.
@MainActor
final class StudioServices {
    static let shared = StudioServices()
    let images = ImageGenService()
    let video = VideoGenService()
    let speech = SpeechService()
    let embeddings = EmbeddingService()
    let files = FileService()
    let testRunner = TestRunner()
}

// MARK: - Completion notifications

/// Posts a macOS notification when background work finishes while you are on
/// a different page or in another app. Silent when you are already looking at it.
@MainActor
final class StudioNotifier {
    static let shared = StudioNotifier()
    /// Raw value of the section currently on screen (set by ContentView).
    var currentSection = ""
    private var requested = false

    func finished(section: String, title: String, body: String) {
        let appIsActive = NSApp?.isActive ?? false
        if appIsActive && currentSection == section { return }
        guard Bundle.main.bundleIdentifier != nil, !ProcessInfo.processInfo.processName.contains("xctest") else { return }
        let center = UNUserNotificationCenter.current()
        if !requested {
            requested = true
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}

// MARK: - Sidebar activity indicator

/// Small spinner shown on a sidebar row while that page has work in flight.
struct SidebarActivityBadge: View {
    let section: SidebarSection
    let tint: Color

    var body: some View {
        switch section {
        case .images: ImagesBadge(tint: tint)
        case .video: VideoBadge(tint: tint)
        case .speech: SpeechBadge(tint: tint)
        case .embeddings: EmbeddingsBadge(tint: tint)
        case .files: FilesBadge(tint: tint)
        case .testSuite: TestBadge(tint: tint)
        default: EmptyView()
        }
    }
}

private struct BusyDot: View {
    let busy: Bool
    let tint: Color
    var body: some View {
        if busy { ProgressView().controlSize(.mini).tint(tint).scaleEffect(0.7).frame(width: 14, height: 14) }
    }
}

private struct ImagesBadge: View {
    @ObservedObject var service = StudioServices.shared.images
    let tint: Color
    var body: some View { BusyDot(busy: service.isGenerating, tint: tint) }
}
private struct VideoBadge: View {
    @ObservedObject var service = StudioServices.shared.video
    let tint: Color
    var body: some View { BusyDot(busy: service.isPolling, tint: tint) }
}
private struct SpeechBadge: View {
    @ObservedObject var service = StudioServices.shared.speech
    let tint: Color
    var body: some View { BusyDot(busy: service.isWorking, tint: tint) }
}
private struct EmbeddingsBadge: View {
    @ObservedObject var service = StudioServices.shared.embeddings
    let tint: Color
    var body: some View { BusyDot(busy: service.isWorking, tint: tint) }
}
private struct FilesBadge: View {
    @ObservedObject var service = StudioServices.shared.files
    let tint: Color
    var body: some View { BusyDot(busy: service.isLoading, tint: tint) }
}
private struct TestBadge: View {
    @ObservedObject var runner = StudioServices.shared.testRunner
    let tint: Color
    var body: some View { BusyDot(busy: runner.isRunning, tint: tint) }
}

/// Chat / Agent row badge: observes the root-owned chat service directly.
struct ChatActivityBadge: View {
    @ObservedObject var service: ChatService
    let tint: Color
    var body: some View { BusyDot(busy: service.runState.isActive, tint: tint) }
}
