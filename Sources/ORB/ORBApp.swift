import SwiftUI

@main
struct ORBApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var focusManager = FocusManager()
    // Application-owned dependencies (W07): one container for the app's
    // lifetime, handed to the view tree so features can stop creating
    // per-view controller instances.
    @StateObject private var environment = AppEnvironment()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(focusManager)
                .environmentObject(environment)
                .frame(minWidth: 1100, minHeight: 700)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .textEditing) {
                Button("Find Models") {
                    focusManager.searchFocused = true
                }
                .keyboardShortcut("f", modifiers: .command)
            }
        }
    }
}

/// Simple bridge to allow the App scene's `.commands` to focus the search field in ContentView.
final class FocusManager: ObservableObject {
    @Published var searchFocused = false
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        .terminateNow
    }
}
