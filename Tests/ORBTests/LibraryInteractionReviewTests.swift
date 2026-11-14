import Foundation
import SQLite3
import Testing
@testable import ORB

/*
 OFFLINE REVIEW REGRESSIONS — parent owns RED/GREEN execution.
 Run: swift test --filter LibraryInteractionReviewTests

 Existing store/service APIs exercise real disposable SQLite + files. No shared
 store, Keychain, live database, URLSession request, build, or paid call is needed.

 Undo tests use the production LibraryUndoPresentation wired into LibraryView.
 Bulk tests use LibraryView's store-aware LibraryExport entry point. These are
 state/IO seam tests, not rendered SwiftUI or live event-loop verification.

 Fix contract:
 - beginUndo must retain the captured removal until successful restore; failed
   restore retains a retryable token while unexpired. Completion/dismissal must
   compare the captured token with the currently displayed token. A replacement
   must never be cleared or receive an old operation's error.
 - remainingDuration = max(0, expiresAt - now), never eight seconds from rendering.
   At the exact durable deadline Undo is disabled/hidden, including late mounting.
 - Video lookup must read authoritative registered Library state (both saved ID
   and remote ID fallback), throwing on load/read/decode failure BEFORE clearing a
   job link or starting a download. A stale empty cache is not proof of absence.
 - Skip exportWrite when the acknowledged export is current and validated. Repair
   a missing export and retry a failed acknowledgement; never skip solely because
   exported_revision matches without validating the actual export/binding.
 - Compiler follow-up (parent verified separately): constrain serialized<T> to
   T: Sendable and retain the correct @MainActor closure/task annotations. Current
   result types are SavedCreation, LibraryRemoval and Void; do not suppress the
   actor-exit Task<T, any Error> diagnostic or conflate it with older warnings.
 - Bulk needs store-aware destination validation (all registered manifests,
   bindings, asset root, catalog and SQLite sidecars, symlink/case aliases) before
   writing. Do not route through the existing overwrite-capable rename exporter:
   preserve exclusive publication even when a target appears after enumeration.
 */

@Suite("Library interaction review", .serialized)
@MainActor
struct LibraryInteractionReviewTests {
    private func fixture() throws -> LibraryReviewFixture {
        try LibraryReviewFixture()
    }

    private func save(_ f: LibraryReviewFixture, text: String = "owned") async throws -> SavedCreation {
        try await f.store.save(Data(text.utf8), mimeType: "text/plain", kind: .transcript,
                               modelID: "offline/review", prompt: nil)
    }

    @Test("Undo restore failure leaves the original token available for retry")
    func undoFailureRetainsTokenForRetry() async throws {
        let f = try fixture(); defer { f.cleanUp() }
        let item = try await save(f)
        let removed = try await f.store.removeWithUndo(ids: [item.id])
        var state = LibraryReviewUndoState()
        state.present(removed)
        try f.db.execChecked("CREATE TRIGGER review_reject_restore BEFORE INSERT ON library_creations BEGIN SELECT RAISE(ABORT, 'offline restore fault'); END;")
        let attemptedValue = state.beginUndo(at: f.clock.date)
        let attempted = try #require(attemptedValue)
        do {
            try await f.store.restore(attempted.token)
            Issue.record("Injected restore must fail")
        } catch {
            state.completeUndo(attempted.token, error: error)
        }
        #expect(state.current?.token == removed.token,
                "A failed restore must not consume the only UI handle to a live durable Undo")
        #expect(state.errorMessage != nil)
        #expect(try f.db.libraryRows("SELECT token FROM library_undo;") == [[removed.token.id.uuidString]])
        try f.db.execChecked("DROP TRIGGER review_reject_restore;")
        let retryValue = state.beginUndo(at: f.clock.date)
        let retry = try #require(retryValue, "Retry must remain available")
        try await f.store.restore(retry.token)
        state.completeUndo(retry.token, error: nil)
        #expect(state.current == nil)
        #expect(f.store.creations == [item])
    }

    @Test("Older Undo completion cannot clear or annotate a replacement", arguments: [false, true])
    func oldUndoCompletionCannotClearReplacement(fails: Bool) async throws {
        let f = try fixture(); defer { f.cleanUp() }
        let first = try await save(f, text: "first")
        let second = try await save(f, text: "second")
        let old = try await f.store.removeWithUndo(ids: [first.id])
        var state = LibraryReviewUndoState()
        state.present(old)
        let capturedValue = state.beginUndo(at: f.clock.date)
        let captured = try #require(capturedValue)
        // Deterministic suspension boundary: a newer delete completes before the
        // old restore callback. No unbounded continuations or timing sleeps.
        let replacement = try await f.store.removeWithUndo(ids: [second.id])
        state.present(replacement)
        state.completeUndo(captured.token, error: fails ? CocoaError(.fileWriteUnknown) : nil)
        #expect(state.current?.token == replacement.token)
        #expect(state.errorMessage == nil, "Old operation errors must not describe a newer toast")
        state.dismiss(captured.token)
        #expect(state.current?.token == replacement.token)
    }

    @Test("A delayed toast uses the durable deadline, not a fresh display duration")
    func lateToastUsesDurableExpiry() async throws {
        let f = try fixture(); defer { f.cleanUp() }
        let item = try await save(f)
        let removed = try await f.store.removeWithUndo(ids: [item.id])
        var state = LibraryReviewUndoState()
        f.clock.date = removed.expiresAt.addingTimeInterval(-1)
        state.present(removed)
        #expect(state.remainingDuration(at: f.clock.date) == 1)
        #expect(state.canUndo(at: f.clock.date))
        f.clock.date = removed.expiresAt
        #expect(state.remainingDuration(at: f.clock.date) == 0)
        #expect(!state.canUndo(at: f.clock.date))
        let expiredAttempt = state.beginUndo(at: f.clock.date)
        #expect(expiredAttempt == nil)
        // The storage boundary is already durable and rejects equality. The UI
        // must agree with it rather than promising an impossible eight seconds.
        await #expect(throws: Error.self) { try await f.store.restore(removed.token) }
    }

    @Test("Mounting an already-expired removal never offers Undo")
    func alreadyExpiredToastIsNotRestarted() async throws {
        let f = try fixture(); defer { f.cleanUp() }
        let item = try await save(f)
        let removed = try await f.store.removeWithUndo(ids: [item.id])
        f.clock.date = removed.expiresAt.addingTimeInterval(60)
        var state = LibraryReviewUndoState()
        state.present(removed)
        #expect(state.remainingDuration(at: f.clock.date) == 0)
        #expect(!state.canUndo(at: f.clock.date))
    }

    @Test("Video read failure is not absence, with either empty or populated cache", arguments: [false, true])
    func videoLibraryReadFailurePreservesLink(cached: Bool) async throws {
        let f = try fixture(); defer { f.cleanUp() }
        let remote = "review-read-\(UUID())"
        let writer = try f.secondStore()
        let creation = try await f.saveVideo(in: writer, remoteID: remote)
        if cached { await f.store.retryMaintenance() }
        #expect(f.store.creations.contains { $0.id == creation.id } == cached)
        let (jobs, service, transport) = try f.videoService(remoteID: remote, savedID: creation.id)
        sqlite3_set_authorizer(f.db.db, { _, operation, table, _, _, _ in
            if operation == SQLITE_READ, let table, String(cString: table) == "library_creations" { return SQLITE_DENY }
            return SQLITE_OK
        }, nil)
        defer { sqlite3_set_authorizer(f.db.db, nil, nil) }
        await #expect(throws: Error.self) {
            _ = try await service.downloadAndSave(remoteID: remote, store: f.store)
        }
        #expect(transport.downloadCount == 0)
        #expect(transport.otherRequestCount == 0)
        #expect(jobs.record(remoteID: remote)?.savedCreationID == creation.id)
        #expect(try f.db.loadJobRecordsChecked().first?.savedCreationID == creation.id)
        #expect(service.retainedDownloads.isEmpty)
        #expect(service.downloadingRemoteIDs.isEmpty)
    }

    @Test("A Library that fails authoritative reload must not return its old cached video")
    func videoLibraryLoadFailureRejectsCachedResult() async throws {
        let f = try fixture(); defer { f.cleanUp() }
        let remote = "review-load-\(UUID())"
        let creation = try await f.saveVideo(in: f.store, remoteID: remote)
        let (jobs, service, transport) = try f.videoService(remoteID: remote, savedID: creation.id)
        try f.db.libraryExecute("UPDATE library_creations SET payload=? WHERE creation_id=?;", ["not-json", creation.id.uuidString])
        #expect(throws: Error.self) {
            _ = try SavedCreationsStore(assetStore: f.assets, indexURL: f.index, now: { f.clock.date })
        }
        // Cached payload remains plausible although an actual open now fails.
        #expect(f.store.creations == [creation])
        await #expect(throws: Error.self) {
            _ = try await service.downloadAndSave(remoteID: remote, store: f.store)
        }
        #expect(transport.downloadCount == 0)
        #expect(transport.otherRequestCount == 0)
        #expect(jobs.record(remoteID: remote)?.savedCreationID == creation.id)
        #expect(try f.db.loadJobRecordsChecked().first?.savedCreationID == creation.id)
    }

    @Test("A stale empty snapshot must resolve a committed video before downloading", arguments: [false, true])
    func videoStaleSnapshotUsesAuthoritativeLookup(linked: Bool) async throws {
        let f = try fixture(); defer { f.cleanUp() }
        // A distinct SQLite connection commits the creation after the reader has
        // cached its empty snapshot, just like a second Library window/process.
        let writerDB = DatabaseManager(path: f.databaseURL.path)
        try #require(writerDB.launchFailure == nil)
        let writerAssets = AssetStore(baseDirectory: f.assets.baseDirectory, database: writerDB)
        let writer = try SavedCreationsStore(assetStore: writerAssets, indexURL: f.index, now: { f.clock.date })
        let remote = "review-stale-\(UUID())"
        let creation = try await f.saveVideo(in: writer, remoteID: remote)
        #expect(f.store.creations.isEmpty)
        let (jobs, service, transport) = try f.videoService(remoteID: remote, savedID: linked ? creation.id : nil)
        var recovered: SavedCreation?
        do { recovered = try await service.downloadAndSave(remoteID: remote, store: f.store) }
        catch { Issue.record("Authoritative creation should be reused without download: \(error)") }
        #expect(recovered?.id == creation.id)
        #expect(transport.downloadCount == 0)
        #expect(transport.otherRequestCount == 0)
        #expect(jobs.record(remoteID: remote)?.savedCreationID == creation.id)
        #expect(try f.db.libraryRows("SELECT creation_id FROM library_creations;") == [[creation.id.uuidString]])
    }

    @Test("Unchanged foreground maintenance performs no JSON write or acknowledgement")
    func unchangedMaintenanceDoesNotRewriteJSON() async throws {
        let f = try fixture(); defer { f.cleanUp() }
        _ = try await save(f)
        let original = try Data(contentsOf: f.index)
        let writes = f.faults.exportWrites
        let acknowledgements = f.faults.exportAcknowledgements
        for _ in 0..<3 { await f.store.retryMaintenance() }
        #expect(f.faults.exportWrites == writes)
        #expect(f.faults.exportAcknowledgements == acknowledgements)
        #expect(try Data(contentsOf: f.index) == original)
        #expect(f.store.exportWarning == nil)
    }

    @Test("An idle Library does not invent an export failure from an unnecessary write")
    func unchangedMaintenanceDoesNotInvokeWriteFault() async throws {
        let f = try fixture(); defer { f.cleanUp() }
        _ = try await save(f)
        f.faults.rejectExportWrite = true
        await f.store.retryMaintenance()
        #expect(f.store.exportWarning == nil)
    }

    @Test("Skipping unchanged export must still repair a missing acknowledged JSON file")
    func missingCurrentExportIsRepaired() async throws {
        let f = try fixture(); defer { f.cleanUp() }
        let item = try await save(f)
        let writes = f.faults.exportWrites
        try FileManager.default.removeItem(at: f.index)
        await f.store.retryMaintenance()
        #expect(f.faults.exportWrites > writes)
        #expect(f.store.exportWarning == nil)
        let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: f.index)) as? [String: Any])
        let creations = try #require(object["creations"] as? [[String: Any]])
        #expect(creations.first?["id"] as? String == item.id.uuidString)
    }

    @Test("Bulk export rejects the managed root, descendants, and symlink aliases", arguments: ["root", "child", "alias"])
    func bulkRejectsManagedRoot(kind: String) async throws {
        let f = try fixture(); defer { f.cleanUp() }
        let item = try await save(f)
        let folder: URL
        switch kind {
        case "child":
            folder = f.assets.baseDirectory.appendingPathComponent("exports")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        case "alias":
            folder = f.root.appendingPathComponent("root-alias")
            try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: f.assets.baseDirectory)
        default: folder = f.assets.baseDirectory
        }
        let plan = LibraryExport.plan([item])
        let result = reviewBulkCopy(plan, to: folder, store: f.store)
        #expect(result.written == 0)
        #expect(result.failed.count == 1)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent(plan[0].fileName).path))
        #expect(try await f.store.data(for: item) == Data("owned".utf8))
    }

    @Test("Bulk rejects absent registered metadata and aliases, not just existing files", arguments: ["manifest", "binding", "journal", "manifest-alias", "case-alias"])
    func bulkRejectsManagedMetadata(kind: String) async throws {
        let f = try fixture(); defer { f.cleanUp() }
        let item = try await save(f)
        let otherIndex = f.root.appendingPathComponent("other-library.json")
        _ = try SavedCreationsStore(assetStore: f.assets, indexURL: otherIndex, now: { f.clock.date })
        let target: URL
        switch kind {
        case "binding": target = f.root.appendingPathComponent(".other-library.json.orb-assets")
        case "journal": target = URL(fileURLWithPath: f.databaseURL.path + "-journal")
        default: target = otherIndex
        }
        // Missing compatibility exports/bindings and SQLite's absent transient
        // sidecars are STILL reserved metadata names. Never delete a live WAL.
        if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
        var folder = f.root
        var name = target.lastPathComponent
        if kind == "manifest-alias" {
            folder = f.root.appendingPathComponent("metadata-parent-alias")
            try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: f.root)
        }
        if kind == "case-alias" {
            let sensitive = try f.root.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames
            // Case-distinct names are valid unrelated files on case-sensitive volumes.
            guard sensitive == false else { return }
            name = name.uppercased()
        }
        let result = reviewBulkCopy([.init(creation: item, fileName: name)], to: folder, store: f.store)
        #expect(result.written == 0)
        #expect(result.failed.count == 1)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path))
    }

    @Test("Bulk still numbers ordinary existing exports without overwriting them")
    func bulkSafeExportRemainsExclusive() async throws {
        let f = try fixture(); defer { f.cleanUp() }
        let item = try await save(f)
        let folder = f.root.appendingPathComponent("external")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let plan = LibraryExport.plan([item])
        let original = folder.appendingPathComponent(plan[0].fileName)
        try Data("keep existing".utf8).write(to: original)
        let result = reviewBulkCopy(plan, to: folder, store: f.store)
        #expect(result.written == 1)
        #expect(result.failed.isEmpty)
        #expect(try Data(contentsOf: original) == Data("keep existing".utf8))
        var taken: Set<String> = [plan[0].fileName]
        let numbered = LibraryExport.unique(plan[0].fileName, taken: &taken)
        #expect(try Data(contentsOf: folder.appendingPathComponent(numbered)) == Data("owned".utf8))
    }

    @Test("A file appearing after bulk enumeration must never be overwritten")
    func bulkPublicationRaceStaysExclusive() async throws {
        let f = try fixture(); defer { f.cleanUp() }
        let item = try await save(f)
        let folder = f.root.appendingPathComponent("external")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let plan = LibraryExport.plan([item])
        let target = folder.appendingPathComponent(plan[0].fileName)
        // Existing source callback is the deterministic pre-copy race seam. Keep
        // this test when adding a destination-aware exporter, and reproduce the
        // same race at that exporter's pre-publication boundary as well.
        let result = LibraryExport.copy(plan, to: folder) { creation in
            try Data("racing writer".utf8).write(to: target, options: .withoutOverwriting)
            return try f.store.fileURL(for: creation)
        }
        #expect(result.written == 0)
        #expect(result.failed.count == 1)
        #expect(try Data(contentsOf: target) == Data("racing writer".utf8))
    }

    @Test("Toast duration uses the durable deadline and preserves legacy defaults")
    func toastUsesDurableDeadline() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let toast = UndoToastView(message: "Deleted", token: UUID(), expiresAt: now.addingTimeInterval(1),
                                  undo: {}, dismiss: {})
        #expect(toast.remainingDuration(at: now) == 1)
        #expect(toast.remainingDuration(at: now.addingTimeInterval(1)) == 0)
        #expect(toast.remainingDuration(at: now.addingTimeInterval(60)) == 0)
        let legacy = UndoToastView(message: "Deleted", undo: {}, dismiss: {})
        #expect(legacy.remainingDuration(at: now) == UndoToast.visibleDuration)
    }

    @Test("Old finalization errors cannot annotate a replacement toast")
    func oldDismissalCompletionIsIgnored() async throws {
        let f = try fixture(); defer { f.cleanUp() }
        let first = try await save(f, text: "first"), second = try await save(f, text: "second")
        let old = try await f.store.removeWithUndo(ids: [first.id])
        var state = LibraryUndoPresentation()
        state.present(old)
        let dismissed = state.dismiss(old.token)
        #expect(dismissed)
        let replacement = try await f.store.removeWithUndo(ids: [second.id])
        state.present(replacement)
        let attempt = state.beginUndo(at: f.clock.date)
        #expect(attempt?.token == replacement.token)
        state.completeDismiss(old.token, error: CocoaError(.fileWriteUnknown))
        state.completeUndo(old.token, error: CocoaError(.fileWriteUnknown))
        #expect(state.isRestoring)
        #expect(state.current?.token == replacement.token)
        #expect(state.errorMessage == nil)
    }

    @Test("A current acknowledgement does not hide modified export content")
    func currentExportValidatesContent() async throws {
        let f = try fixture(); defer { f.cleanUp() }
        let item = try await save(f)
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: f.index)) as? [String: Any])
        object["creations"] = []
        try JSONSerialization.data(withJSONObject: object).write(to: f.index)
        let writes = f.faults.exportWrites
        await f.store.retryMaintenance()
        #expect(f.faults.exportWrites == writes + 1)
        #expect(f.store.exportWarning == nil)
        let repaired = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: f.index)) as? [String: Any])
        let creations = try #require(repaired["creations"] as? [[String: Any]])
        #expect(creations.first?["id"] as? String == item.id.uuidString)
    }

    @Test("A missing current binding is repaired without rewriting the verified export")
    func missingCurrentBindingIsRepaired() async throws {
        let f = try fixture(); defer { f.cleanUp() }
        _ = try await save(f)
        let binding = f.root.appendingPathComponent(".creations.json.orb-assets")
        let original = try Data(contentsOf: binding)
        try FileManager.default.removeItem(at: binding)
        let writes = f.faults.exportWrites
        await f.store.retryMaintenance()
        #expect(f.faults.exportWrites == writes)
        #expect(f.store.exportWarning == nil)
        #expect(try Data(contentsOf: binding) == original)
    }

    @Test("An in-flight Undo retains its token and rejects repeated Undo or dismissal")
    func undoBusyRetainsToken() async throws {
        let f = try fixture(); defer { f.cleanUp() }
        let item = try await save(f)
        let removal = try await f.store.removeWithUndo(ids: [item.id])
        var state = LibraryUndoPresentation()
        state.present(removal)
        let first = state.beginUndo(at: f.clock.date)
        #expect(first?.token == removal.token)
        #expect(state.isRestoring)
        #expect(!state.canUndo(at: f.clock.date))
        let repeated = state.beginUndo(at: f.clock.date)
        let dismissed = state.dismiss(removal.token)
        #expect(repeated == nil)
        #expect(!dismissed)
        #expect(state.current?.token == removal.token)
        state.completeUndo(removal.token, error: CocoaError(.fileWriteUnknown))
        #expect(!state.isRestoring)
        #expect(state.canUndo(at: f.clock.date))
    }

    @Test("A stale saved ID falls back to the authoritative remote ID")
    func staleSavedIDFindsRemoteIdentity() async throws {
        let f = try fixture(); defer { f.cleanUp() }
        let remote = "review-fallback-\(UUID())"
        let creation = try await f.saveVideo(in: f.secondStore(), remoteID: remote)
        let (jobs, service, transport) = try f.videoService(remoteID: remote, savedID: UUID())
        let result = try await service.downloadAndSave(remoteID: remote, store: f.store)
        #expect(result.id == creation.id)
        #expect(jobs.record(remoteID: remote)?.savedCreationID == creation.id)
        #expect(transport.downloadCount == 0)
    }

    @Test("Remote-only authoritative read failure cannot start a download")
    func remoteOnlyReadFailure() async throws {
        let f = try fixture(); defer { f.cleanUp() }
        let remote = "review-remote-read-\(UUID())"
        _ = try await f.saveVideo(in: f.secondStore(), remoteID: remote)
        let (_, service, transport) = try f.videoService(remoteID: remote, savedID: nil)
        sqlite3_set_authorizer(f.db.db, { _, operation, table, _, _, _ in
            if operation == SQLITE_READ, let table, String(cString: table) == "library_creations" { return SQLITE_DENY }
            return SQLITE_OK
        }, nil)
        defer { sqlite3_set_authorizer(f.db.db, nil, nil) }
        await #expect(throws: Error.self) { _ = try await service.downloadAndSave(remoteID: remote, store: f.store) }
        #expect(transport.downloadCount == 0)
        #expect(transport.otherRequestCount == 0)
    }

    @Test("Unavailable Library fallback refuses lookup before link clearing or download")
    func unavailableLibraryFallback() async throws {
        let f = try fixture(); defer { f.cleanUp() }
        let remote = "review-unavailable-\(UUID())", savedID = UUID()
        let unavailable = SavedCreationsStore(loadFailure: CocoaError(.fileReadNoPermission), assetStore: f.assets, indexURL: f.index)
        let (jobs, service, transport) = try f.videoService(remoteID: remote, savedID: savedID)
        await #expect(throws: Error.self) { _ = try await service.downloadAndSave(remoteID: remote, store: unavailable) }
        #expect(jobs.record(remoteID: remote)?.savedCreationID == savedID)
        #expect(transport.downloadCount == 0)
    }

    @Test("Retry acknowledges a valid export without rewriting bytes")
    func exportAcknowledgementRetryDoesNotRewrite() async throws {
        let f = try fixture(); defer { f.cleanUp() }
        f.faults.rejectAcknowledgement = true
        let item = try await save(f)
        #expect(f.store.creations.contains(item)) // save committed despite warning
        #expect(f.store.exportWarning != nil)
        let writes = f.faults.exportWrites
        f.faults.rejectAcknowledgement = false
        await f.store.retryMaintenance()
        #expect(f.faults.exportWrites == writes)
        #expect(f.store.exportWarning == nil)
        let acknowledgements = f.faults.exportAcknowledgements
        await f.store.retryMaintenance()
        #expect(f.faults.exportAcknowledgements == acknowledgements)
    }

    @Test("A current revision does not bypass invalid binding validation")
    func currentExportChecksBinding() async throws {
        let f = try fixture(); defer { f.cleanUp() }
        _ = try await save(f)
        let binding = f.root.appendingPathComponent(".creations.json.orb-assets")
        try Data("foreign binding".utf8).write(to: binding)
        let writes = f.faults.exportWrites
        await f.store.retryMaintenance()
        #expect(f.store.exportWarning != nil)
        #expect(f.faults.exportWrites == writes)
        #expect(try Data(contentsOf: binding) == Data("foreign binding".utf8))
    }

    @Test("Store-aware bulk publication preserves a concurrently created destination")
    func storeAwareBulkPublicationRace() async throws {
        let f = try fixture(); defer { f.cleanUp() }
        let item = try await save(f)
        let folder = f.root.appendingPathComponent("external")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let plan = LibraryExport.plan([item])
        let result = LibraryExport.copy(plan, to: folder, store: f.store) { target in
            try Data("racing writer".utf8).write(to: target, options: .withoutOverwriting)
        }
        #expect(result.written == 0)
        #expect(result.failed.count == 1)
        #expect(try Data(contentsOf: folder.appendingPathComponent(plan[0].fileName)) == Data("racing writer".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == [plan[0].fileName])
    }

    @Test("Mounted Library views share one maintenance loop until the last leaves")
    func mountedViewsShareMaintenance() async throws {
        let f = try fixture(); defer { f.cleanUp() }
        let first = UUID(), second = UUID()
        f.store.startForegroundMaintenance(observer: first)
        f.store.startForegroundMaintenance(observer: first)
        let generation = f.store.foregroundMaintenanceGeneration
        f.store.startForegroundMaintenance(observer: second)
        #expect(f.store.foregroundMaintenanceObserverCount == 2)
        #expect(f.store.foregroundMaintenanceGeneration == generation)
        #expect(f.store.isForegroundMaintenanceRunning)
        f.store.stopForegroundMaintenance(observer: first)
        #expect(f.store.isForegroundMaintenanceRunning)
        f.store.stopForegroundMaintenance(observer: second)
        #expect(!f.store.isForegroundMaintenanceRunning)
        // Await any already-enqueued maintenance before fixture cleanup.
        await f.store.retryMaintenance()
    }

    private func reviewBulkCopy(_ plan: [LibraryExport.Entry], to folder: URL,
                                store: SavedCreationsStore) -> (written: Int, failed: [String]) {
        LibraryExport.copy(plan, to: folder, store: store)
    }
}

private typealias LibraryReviewUndoState = LibraryUndoPresentation

@MainActor
private final class LibraryReviewClock {
    var date = Date(timeIntervalSince1970: 1_800_000_000)
}

@MainActor
private final class LibraryReviewFaults {
    var exportWrites = 0
    var exportAcknowledgements = 0
    var rejectExportWrite = false
    var rejectAcknowledgement = false
    func hit(_ phase: LibraryOwnershipPhase) throws {
        if phase == .exportWrite {
            exportWrites += 1
            if rejectExportWrite { throw CocoaError(.fileWriteNoPermission) }
        }
        if phase == .exportAcknowledgement {
            exportAcknowledgements += 1
            if rejectAcknowledgement { throw CocoaError(.fileWriteNoPermission) }
        }
    }
}

@MainActor
private final class LibraryReviewFixture {
    let root: URL
    let databaseURL: URL
    let index: URL
    let db: DatabaseManager
    let assets: AssetStore
    let clock: LibraryReviewClock
    let faults: LibraryReviewFaults
    let store: SavedCreationsStore

    init() throws {
        root = ORBTestScratch.root.appendingPathComponent("ORB-library-review-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        databaseURL = root.appendingPathComponent("catalog.sqlite3")
        index = root.appendingPathComponent("creations.json")
        db = DatabaseManager(path: databaseURL.path)
        try #require(db.launchFailure == nil)
        assets = AssetStore(baseDirectory: root.appendingPathComponent("Assets"), database: db)
        let clock = LibraryReviewClock(), faults = LibraryReviewFaults()
        self.clock = clock; self.faults = faults
        store = try SavedCreationsStore(assetStore: assets, indexURL: index,
                                        now: { clock.date }, failpoint: { try faults.hit($0) })
    }
    func cleanUp() { try? FileManager.default.removeItem(at: root) }
    func secondStore() throws -> SavedCreationsStore {
        try SavedCreationsStore(assetStore: assets, indexURL: index, now: { self.clock.date })
    }
    func saveVideo(in store: SavedCreationsStore, remoteID: String) async throws -> SavedCreation {
        let file = root.appendingPathComponent("download-\(UUID()).mp4")
        try Data("offline-video-\(remoteID)".utf8).write(to: file)
        return try await store.save(fileAt: file, mimeType: "video/mp4", kind: .video,
                                    modelID: "offline/video", prompt: nil, videoRemoteID: remoteID)
    }
    func videoService(remoteID: String, savedID: UUID?) throws -> (JobController, VideoGenService, LibraryReviewOfflineTransport) {
        let jobs = JobController(database: db)
        try #require(jobs.recordVideoSubmission(remoteID: remoteID, modelID: "offline/video", remoteStatus: "completed") != nil)
        if let savedID { jobs.recordSavedCreation(remoteID: remoteID, creationID: savedID) }
        let transport = LibraryReviewOfflineTransport()
        let service = VideoGenService(transport: transport, jobController: jobs,
                                      retryPolicy: PollRetryPolicy(maxConsecutiveFailures: 0,
                                                                   baseDelay: .milliseconds(1), maxDelay: .milliseconds(1)))
        return (jobs, service, transport)
    }
}

private final class LibraryReviewOfflineTransport: MediaTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var downloads = 0
    private var requests = 0
    var downloadCount: Int { lock.withLock { downloads } }
    var otherRequestCount: Int { lock.withLock { requests } }
    init() {
        super.init(session: URLSession(configuration: .ephemeral), apiKeyProvider: { "offline-test-key" })
    }
    override func downloadToFile(_ request: URLRequest) async throws -> (URL, String?) {
        lock.withLock { downloads += 1 }
        throw URLError(.notConnectedToInternet)
    }
    override func send<T: Decodable>(_ request: URLRequest, as type: T.Type) async throws -> T {
        lock.withLock { requests += 1 }
        throw URLError(.notConnectedToInternet)
    }
    override func sendRaw(_ request: URLRequest) async throws -> (Data, String?) {
        lock.withLock { requests += 1 }
        throw URLError(.notConnectedToInternet)
    }
}
