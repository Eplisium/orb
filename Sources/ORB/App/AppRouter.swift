import SwiftUI

// MARK: - Navigation routing (W07)
//
// Route identity and transition logic for the app shell, extracted from
// ContentView so it can be tested without launching the app. These are
// decisions only: ContentView keeps owning its `selectedSection` state and
// consults these helpers for the derivations and side effects, so behavior
// stays identical while the logic becomes unit-testable. The supervised
// shell session can adopt `AppRoute` as the List selection currency later.

/// One stable navigation destination in the shell. Wraps a `SidebarSection`
/// (the selection currency the sidebar List already uses) with the
/// derivations the shell needs to lay out the workspace. The derivations
/// delegate to `SidebarSection`'s own computed properties — there is exactly
/// one definition of "browser" and "media tool", never a divergent copy.
struct AppRoute: Equatable, Hashable, Identifiable {
    let section: SidebarSection

    /// Stable identifier derived from the section's raw value, which is
    /// unique per case.
    var id: String { section.rawValue }

    /// Model-browser sections present a list + detail layout.
    var isBrowser: Bool { section.isBrowser }

    /// Media-creation sections (images/video/files/speech/embeddings).
    var isMediaTool: Bool { section.isMediaTool }
}

/// The browser-filter side effects a section selection must produce.
/// Explicit for every section: selecting any non-favorites section turns the
/// favorites filter off, so no stale filter can survive a transition.
struct AppFilterEffects: Equatable, Sendable {
    var showFavoritesOnly: Bool
    var showNewThisWeek: Bool
}

enum AppRouter {
    /// Route identity for a sidebar section.
    static func route(for section: SidebarSection) -> AppRoute {
        AppRoute(section: section)
    }

    /// The pure transition function for a section selection: computes the
    /// browser-filter side effects (previously duplicated inline in
    /// ContentView's `onChange(of: selectedSection)` and `sidebarRow`) from
    /// the section alone. Deterministic and side-effect free; the caller
    /// applies the result to the browser view model.
    static func filterEffects(for section: SidebarSection) -> AppFilterEffects {
        AppFilterEffects(
            showFavoritesOnly: section == .favorites,
            showNewThisWeek: section == .newThisWeek
        )
    }
}
