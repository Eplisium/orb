import SwiftUI
import AppKit

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
        // One main window (SHELL-1 / CORE-3). `Window` is single-instance:
        // an orb:// link or a menu command reuses it (or reopens it after
        // ⌘W) instead of opening a second window with its own browser model
        // and Chat/Agent services writing the same database.
        Window("ORB", id: ORBShell.mainWindowID) {
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
        }
        .windowToolbarStyle(.unified)
        .handlesExternalEvents(matching: [DeepLink.scheme])
        .commands {
            SidebarCommands()
            ShellCommands(shell: shell, focusManager: focusManager)
            ModelCommands(shell: shell)
            ConversationCommands()
        }

        Settings {
            SettingsSceneView()
        }
    }
}

/// Menu bar commands. Shortcuts are routed through `ShellController`;
/// `ContentView` performs them. While ORB is locked every item that would
/// act on the app is disabled (the lock screen ignores them anyway); only
/// Quit, About and Help stay live. `orb://` links are handled by
/// `ContentView.onOpenURL`, which holds them until unlock.
struct ShellCommands: Commands {
    @ObservedObject var shell: ShellController
    let focusManager: FocusManager
    @ObservedObject var lock: AppLock = .shared
    @ObservedObject var updates: UpdateChecker = .shared
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.conversationActions) private var conversationActions

    private var locked: Bool { lock.isLocked }

    private var findTarget: FindTarget {
        FindRouting.target(for: shell.currentSection, hasSessionSearch: conversationActions?.searchSessions != nil)
    }

    /// Brings the main window back (it may have been closed with ⌘W), then
    /// queues the request for it.
    private func send(_ action: ShellAction) {
        openWindow(id: ORBShell.mainWindowID)
        shell.send(action)
    }

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About ORB") { AboutWindow.show() }
            Button("Check for Updates…") { Task { await updates.checkNow() } }
                .disabled(updates.isChecking)
        }
        CommandGroup(after: .appSettings) {
            Button("Lock ORB") { lock.lock() }
                .shortcut(.lockNow)
                .disabled(locked || !lock.isEnabled)
        }
        CommandGroup(replacing: .newItem) {
            Button("New Chat") { send(.newChat) }
                .shortcut(.newChat)
                .disabled(locked)
            Button("New Agent Session") { send(.newAgent) }
                .shortcut(.newAgent)
                .disabled(locked)
        }
        CommandGroup(after: .textEditing) {
            let target = findTarget
            Button(target.menuTitle) {
                switch target {
                case .browserSearch:
                    openWindow(id: ORBShell.mainWindowID)
                    focusManager.searchFocused = true
                case .sessionSearch:
                    conversationActions?.searchSessions?()
                case .unavailable:
                    break
                }
            }
            .shortcut(.find)
            .disabled(locked || target == .unavailable)
        }
        CommandMenu("Go") {
            Button("Command Palette…") { send(.showPalette) }
                .shortcut(.palette)
                .disabled(locked)
            Button("Refresh Models") { send(.refreshModels) }
                .shortcut(.refresh)
                .disabled(locked)
            Divider()
            ForEach(Array(ShellShortcuts.numberedSections.enumerated()), id: \.offset) { offset, section in
                Button(section.title) { send(.section(section)) }
                    .keyboardShortcut(KeyEquivalent(Character("\(offset + 1)")), modifiers: .command)
                    .disabled(locked)
            }
            ForEach(ShellShortcuts.extraSectionCommands, id: \.1) { section, command in
                Button(section.title) { send(.section(section)) }
                    .shortcut(command)
                    .disabled(locked)
            }
        }
        // Replaces the default "ORB Help" item, which only says help isn't
        // available.
        CommandGroup(replacing: .help) {
            Button("Keyboard Shortcuts") { send(.showShortcuts) }
                .shortcut(.shortcuts)
                .disabled(locked)
            Divider()
            Button("ORB on GitHub") { NSWorkspace.shared.open(ORBProjectLinks.readme) }
            Button("Report an Issue…") { NSWorkspace.shared.open(ORBProjectLinks.issues) }
            Button("Release Notes") { NSWorkspace.shared.open(ORBProjectLinks.releases) }
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
    /// Set the saved colour scheme before the first window draws, so no
    /// window ever renders a frame in the wrong appearance.
    @MainActor
    func applicationWillFinishLaunching(_ notification: Notification) {
        AppAppearance.apply(AppearancePrefs.load().scheme)
        // ORB has one main window: no window tabs, no "+" tab button, no
        // Show Tab Bar / Merge All Windows items.
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Public, unauthenticated release check; silent unless an update exists.
        UpdateChecker.shared.startBackgroundChecks()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        .terminateNow
    }
}
