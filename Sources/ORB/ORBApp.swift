import SwiftUI

@main
struct ORBApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var focusManager = FocusManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(focusManager)
                .frame(minWidth: 1100, minHeight: 700)
                .task {
                    // Bring MCP servers up in the background so their tools are
                    // registered before the first agent run.
                    await MCPRegistry.shared.startEnabledServers()
                }
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
