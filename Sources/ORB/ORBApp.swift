import SwiftUI

@main
struct ORBApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var focusManager = FocusManager()
    @StateObject private var shell = ShellController()
    // Application-owned dependencies (W07): one container for the app's
    // lifetime, handed to the view tree so features can stop creating
    // per-view controller instances.
    @StateObject private var environment = AppEnvironment()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .orbAppearance()
                .environmentObject(focusManager)
                .environmentObject(shell)
                .environmentObject(environment)
                .frame(
                    minWidth: ORBShell.minimumWindowSize.width,
                    minHeight: ORBShell.minimumWindowSize.height
                )
                .background(WindowChromeConfigurator(hideTitleBar: ORBShell.useHiddenTitleBar))
                .onOpenURL { shell.open($0) }
        }
        .windowToolbarStyle(.unified)
        .handlesExternalEvents(matching: [DeepLink.scheme])
        .commands {
            SidebarCommands()
            ShellCommands(shell: shell, focusManager: focusManager)
            ModelCommands(shell: shell)
        }

        Settings {
            SettingsSceneView()
        }
    }
}

/// Menu bar commands. Shortcuts are routed through `ShellController`;
/// `ContentView` performs them (and ignores them while locked).
struct ShellCommands: Commands {
    @ObservedObject var shell: ShellController
    let focusManager: FocusManager

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About ORB") { AboutWindow.show() }
        }
        CommandGroup(replacing: .newItem) {
            Button("New Chat") { shell.send(.newChat) }
                .shortcut(.newChat)
            Button("New Agent Session") { shell.send(.newAgent) }
                .shortcut(.newAgent)
        }
        CommandGroup(after: .textEditing) {
            Button("Find Models") { focusManager.searchFocused = true }
                .shortcut(.find)
        }
        CommandMenu("Go") {
            Button("Command Palette…") { shell.send(.showPalette) }
                .shortcut(.palette)
            Button("Refresh Models") { shell.send(.refreshModels) }
                .shortcut(.refresh)
            Divider()
            ForEach(Array(ShellShortcuts.numberedSections.enumerated()), id: \.offset) { offset, section in
                Button(section.title) { shell.send(.section(section)) }
                    .keyboardShortcut(KeyEquivalent(Character("\(offset + 1)")), modifiers: .command)
            }
            ForEach(ShellShortcuts.extraSectionCommands, id: \.1) { section, command in
                Button(section.title) { shell.send(.section(section)) }
                    .shortcut(command)
            }
        }
        CommandGroup(after: .help) {
            Button("Keyboard Shortcuts") { shell.send(.showShortcuts) }
                .shortcut(.shortcuts)
        }
    }
}

/// Applies the hidden-title-bar fallback (`ORBShell.useHiddenTitleBar`) at
/// the NSWindow level so the scene can keep a single, unconditional style.
struct WindowChromeConfigurator: NSViewRepresentable {
    let hideTitleBar: Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { apply(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { apply(nsView.window) }
    }

    private func apply(_ window: NSWindow?) {
        guard let window, hideTitleBar else { return }
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
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
