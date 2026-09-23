import SwiftUI

// MARK: - Application-owned environment (W07)
//
// One @MainActor container the app entry constructs and owns for the whole
// application lifetime. It owns the long-lived controllers that views used to
// create per-instance (or could only reach as bare singletons) and exposes
// read-only references to the existing shared services, so "one app-owned
// controller, not per-view instances" becomes possible (plan 8.2).
//
// This delivery only establishes the container and its ownership: consumers
// keep their current initializers and defaults. Migrating each feature view
// to take its dependencies from here is a separate behavior-preserving step
// for the supervised shell session.

@MainActor
final class AppEnvironment: ObservableObject {
    // MARK: Owned long-lived controllers

    /// The application's durable media-job controller. One instance for the
    /// whole app, persisted through `database`; views must never construct
    /// their own. (VideoGenService still defaults to `JobController.shared`
    /// until it is handed the environment's controller — both persist to the
    /// same database, so no behavior depends on the transition.)
    let jobs: JobController

    /// Fail-closed approval coordinator for risky agent tool calls. The UI
    /// installs its responder on this single instance, so a pending approval
    /// is cancelable exactly once from one place.
    let approvals: ApprovalCoordinator

    // MARK: Read-only references to existing shared services

    /// The database every owned controller persists through. Read-only here:
    /// writes always go through a controller/repository, never directly.
    let database: DatabaseManager

    init(
        database: DatabaseManager = .shared,
        jobs: JobController? = nil,
        approvals: ApprovalCoordinator? = nil
    ) {
        self.database = database
        self.jobs = jobs ?? JobController(database: database)
        self.approvals = approvals ?? ApprovalCoordinator()
    }
}
