import Foundation
import Testing
@testable import ORB

/*
 OFFLINE REGRESSIONS — lead owns compilation and RED/GREEN execution.
 Filter: swift test --filter JobRecoveryPathProtectionTests

 Tests inject the real AssetStore recoveryDirectory parameter. Single/bulk
 export and post-commit source consumption exercise the shared production guard.

 All IO uses explicitly injected UUID scratch paths and disposable SQLite.
 The recovery root intentionally is NOT the asset root's sibling, preventing a
 hardcoded sibling-path guess from standing in for the proposed configuration.
 No shared service, credentials, network, production recovery directory or DB.
 */

@Suite("Job recovery managed-path protection", .serialized)
@MainActor
struct JobRecoveryPathProtectionTests {
    @Test("Single export preserves journal entries and the stable lock inode",
          arguments: ["entry", "lock"], [false, true])
    func singleExportRejectsRecoveryFile(kind: String, rawData: Bool) async throws {
        let f = try JobRecoveryPathFixture(); defer { f.cleanUp() }
        let pending = try f.seedPending()
        let creation = try await f.saveOrdinaryCreation()
        let target = kind == "entry" ? f.entry(pending.id) : f.recovery.appendingPathComponent(".lock")
        let bytes = try Data(contentsOf: target)
        let inode = try f.inode(target)
        expectManagedDestination {
            if rawData { try f.store.export(data: Data("must not replace recovery".utf8), to: target) }
            else { try f.store.export(creation, to: target) }
        }
        #expect(try Data(contentsOf: target) == bytes)
        #expect(try f.inode(target) == inode, "Replacing an empty .lock can split the flock coordination domain")
        try f.expectPendingEnvelope(pending)
    }

    @Test("Single export rejects both leaf and ancestor symlink aliases",
          arguments: ["leaf", "parent", "case"])
    func singleExportRejectsRecoveryAliases(alias: String) async throws {
        let f = try JobRecoveryPathFixture(); defer { f.cleanUp() }
        let pending = try f.seedPending()
        let entry = f.entry(pending.id)
        let bytes = try Data(contentsOf: entry)
        let target: URL
        switch alias {
        case "leaf":
            target = f.root.appendingPathComponent("outside-entry-alias.json")
            try FileManager.default.createSymbolicLink(at: target, withDestinationURL: entry)
        case "parent":
            let parent = try f.alias(to: f.recovery)
            target = parent.appendingPathComponent(entry.lastPathComponent)
        default:
            let sensitive = try f.root.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames
            // Case-distinct paths are not aliases on case-sensitive volumes.
            guard sensitive == false else { return }
            target = f.recovery.deletingLastPathComponent().appendingPathComponent("JOBRECOVERY")
                .appendingPathComponent(entry.lastPathComponent.lowercased())
        }
        expectManagedDestination { try f.store.export(data: Data("unrelated export".utf8), to: target) }
        #expect(try Data(contentsOf: entry) == bytes)
        #expect(try Data(contentsOf: target) == bytes)
        if alias == "leaf" {
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: target.path) == entry.path)
        }
    }

    @Test("Absent entries and nested paths remain reserved, including through ancestor aliases",
          arguments: ["entry", "lock", "nested", "absent-root"])
    func missingRecoveryPathsFailWithManagedDestination(kind: String) async throws {
        let f = try JobRecoveryPathFixture(); defer { f.cleanUp() }
        _ = try await f.saveOrdinaryCreation()
        if kind != "absent-root" {
            try FileManager.default.createDirectory(at: f.recovery, withIntermediateDirectories: true)
        }
        // Alias an EXISTING ancestor, not the nonexistent final directory. This
        // catches Foundation resolvingSymlinksInPath's missing-suffix limitation.
        let parentAlias = try f.alias(to: f.recovery.deletingLastPathComponent())
        let aliasedRoot = parentAlias.appendingPathComponent(f.recovery.lastPathComponent)
        let suffix: String
        switch kind {
        case "entry": suffix = "\(UUID().uuidString).json"
        case "lock": suffix = ".lock"
        default: suffix = "missing/also-missing/export.json"
        }
        let target = aliasedRoot.appendingPathComponent(suffix)
        try #require(!FileManager.default.fileExists(atPath: target.path))
        // An incidental ENOENT from staging is NOT protection. Validate and
        // exercise the exporter, requiring the specific managed-destination error.
        expectManagedDestination { _ = try f.store.validateExportDestination(target) }
        expectManagedDestination { try f.store.export(data: Data("export".utf8), to: target) }
        #expect(!FileManager.default.fileExists(atPath: target.path))
        if kind == "absent-root" {
            #expect(!FileManager.default.fileExists(atPath: f.recovery.path))
        }
    }

    @Test("Bulk refuses the recovery folder, descendants and directory aliases before staging",
          arguments: ["root", "descendant", "alias", "descendant-alias"])
    func bulkExportRejectsRecoveryTree(kind: String) async throws {
        let f = try JobRecoveryPathFixture(); defer { f.cleanUp() }
        let pending = try f.seedPending()
        let before = try Data(contentsOf: f.entry(pending.id))
        let creation = try await f.saveOrdinaryCreation()
        let actual: URL
        if kind.contains("descendant") {
            actual = f.recovery.appendingPathComponent("reserved-subdirectory")
            try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: true)
        } else { actual = f.recovery }
        let folder = kind.contains("alias") ? try f.alias(to: actual) : actual
        let names = try FileManager.default.contentsOfDirectory(atPath: actual.path).sorted()
        var publicationCalls = 0
        let result = LibraryExport.copy(LibraryExport.plan([creation]), to: folder, store: f.store,
                                         beforePublication: { _ in publicationCalls += 1 })
        #expect(result.written == 0)
        #expect(result.failed.count == 1)
        #expect(publicationCalls == 0, "Reject managed destinations before any staged publication")
        #expect(try FileManager.default.contentsOfDirectory(atPath: actual.path).sorted() == names)
        #expect(try Data(contentsOf: f.entry(pending.id)) == before)
        #expect(try await f.store.data(for: creation) == Data("ordinary creation".utf8))
    }

    @Test("Committed raw and Library file saves must not consume a recovery envelope",
          arguments: ["asset", "library"], [false, true])
    func fileSavePreservesRecoveryAfterCommit(writer: String, parentAlias: Bool) async throws {
        let f = try JobRecoveryPathFixture(); defer { f.cleanUp() }
        let pending = try f.seedPending()
        let entry = f.entry(pending.id)
        let original = try Data(contentsOf: entry)
        let parent = parentAlias ? try f.alias(to: f.recovery) : f.recovery
        let source = parent.appendingPathComponent(entry.lastPathComponent)
        if writer == "asset" {
            let saved = try await f.assets.store(fileAt: source, mimeType: "application/json")
            #expect(try await f.assets.data(for: saved) == original)
            // An independent connection proves the metadata committed; preservation
            // on a failed transaction would not exercise the vulnerable cleanup.
            let reopened = DatabaseManager(path: f.databaseURL.path)
            try #require(reopened.launchFailure == nil)
            #expect(try reopened.loadAssetRecordsChecked(checksum: saved.checksum).contains { $0.id == saved.id })
        } else {
            let saved = try await f.store.save(fileAt: source, mimeType: "application/json",
                                              kind: .transcript, modelID: "offline/recovery-boundary", prompt: nil)
            let reopenedDB = DatabaseManager(path: f.databaseURL.path)
            try #require(reopenedDB.launchFailure == nil)
            let reopenedAssets = jobRecoveryProtectedAssets(baseDirectory: f.assets.baseDirectory,
                database: reopenedDB, recoveryDirectory: f.recovery)
            let reopened = try SavedCreationsStore(assetStore: reopenedAssets, indexURL: f.index)
            #expect(reopened.creations.contains { $0.id == saved.id })
            #expect(try await reopened.data(for: saved) == original)
        }
        try #require(FileManager.default.fileExists(atPath: entry.path),
                     "Successful save consumed the only crash-durable pending job envelope")
        #expect(try Data(contentsOf: entry) == original)
        #expect(FileManager.default.fileExists(atPath: source.path))
        try f.expectPendingEnvelope(pending)
    }

    @Test("Dedupe also preserves a recovery source after a successful asset commit")
    func deduplicatedSavePreservesRecoveryEntry() async throws {
        let f = try JobRecoveryPathFixture(); defer { f.cleanUp() }
        let pending = try f.seedPending()
        let entry = f.entry(pending.id)
        let original = try Data(contentsOf: entry)
        let first = try await f.assets.store(original, mimeType: "application/json")
        let duplicate = try await f.assets.store(fileAt: entry, mimeType: "application/json")
        #expect(duplicate.id == first.id)
        #expect(try await f.assets.data(for: duplicate) == original)
        try #require(FileManager.default.fileExists(atPath: entry.path), "Dedupe is not permission to consume managed metadata")
        #expect(try Data(contentsOf: entry) == original)
        try f.expectPendingEnvelope(pending)
    }

    @Test("Recovery-like sibling names remain valid external destinations and consumable inputs",
          arguments: ["asset", "library"], [false, true])
    func ordinarySiblingStillExportsAndConsumes(writer: String, dedupe: Bool) async throws {
        let f = try JobRecoveryPathFixture(); defer { f.cleanUp() }
        let creation = try await f.saveOrdinaryCreation()
        let outside = f.recovery.deletingLastPathComponent().appendingPathComponent("JobRecovery-downloads")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let target = outside.appendingPathComponent("export.txt")
        try f.store.export(creation, to: target)
        #expect(try Data(contentsOf: target) == Data("ordinary creation".utf8))
        let result = LibraryExport.copy(LibraryExport.plan([creation]), to: outside, store: f.store)
        #expect(result.written == 1)
        #expect(result.failed.isEmpty)
        let input = outside.appendingPathComponent("download.json")
        let bytes = Data("ordinary disposable download".utf8)
        try bytes.write(to: input)
        if dedupe { _ = try await f.assets.store(bytes, mimeType: "application/json") }
        if writer == "asset" {
            let saved = try await f.assets.store(fileAt: input, mimeType: "application/json")
            #expect(try await f.assets.data(for: saved) == bytes)
        } else {
            let saved = try await f.store.save(fileAt: input, mimeType: "application/json", kind: .transcript,
                modelID: "offline/recovery-boundary", prompt: nil)
            #expect(try await f.store.data(for: saved) == bytes)
        }
        #expect(!FileManager.default.fileExists(atPath: input.path), "Do not fix this by disabling all source consumption")
    }

    @Test("Default AssetStore writers reserve the shared job path without opening it")
    func defaultRecoveryPathWiring() throws {
        let f = try JobRecoveryPathFixture(); defer { f.cleanUp() }
        // Initializers only retain the URL; do not inspect the real directory or
        // initialize JobController.shared just to check default path selection.
        let defaultWriter = AssetStore(baseDirectory: f.assets.baseDirectory, database: f.db)
        #expect(defaultWriter.recoveryDirectory == ManagedStoragePaths.jobRecoveryDirectory.standardizedFileURL)
        #expect(defaultWriter.managedDirectoryURLs.contains(defaultWriter.recoveryDirectory))
        #expect(f.assets.recoveryDirectory == f.recovery.standardizedFileURL)
        #expect(DatabaseManager(path: ":memory:").storageDirectoryURLs.isEmpty)
    }

    @Test("Absent managed roots are reserved through aliases with volume-aware case rules",
          arguments: [false, true])
    func absentRootsAndCaseAliases(caseVariant: Bool) async throws {
        let f = try JobRecoveryPathFixture(); defer { f.cleanUp() }
        let creation = try await f.saveOrdinaryCreation()
        let sensitive = try f.root.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames
        if caseVariant && sensitive != false { return }
        let directories = [f.recovery] + f.db.storageDirectoryURLs
        try #require(directories.count > 1, "Disposable file-backed DB must expose its backup container")
        for directory in directories {
            try #require(!FileManager.default.fileExists(atPath: directory.path))
            let alias = try f.alias(to: directory.deletingLastPathComponent())
            let name = caseVariant ? directory.lastPathComponent.uppercased() : directory.lastPathComponent
            let aliasedRoot = alias.appendingPathComponent(name)
            expectManagedDestination { _ = try f.store.validateExportDestination(aliasedRoot) }
            let destination = aliasedRoot.appendingPathComponent("missing/deeper/export.json")
            expectManagedDestination { try f.store.export(creation, to: destination) }
            expectManagedDestination { try f.store.export(data: Data("not metadata".utf8), to: destination) }
            #expect(!FileManager.default.fileExists(atPath: directory.path))
        }
    }

    @Test("Database recovery containers reject single and bulk exports before staging",
          arguments: ["root", "nested", "alias"])
    func databaseRecoveryTreeRejectsExports(kind: String) async throws {
        let f = try JobRecoveryPathFixture(); defer { f.cleanUp() }
        let creation = try await f.saveOrdinaryCreation()
        try #require(!f.db.storageDirectoryURLs.isEmpty)
        for directory in f.db.storageDirectoryURLs {
            let actual = kind == "nested" ? directory.appendingPathComponent("partial/recovery") : directory
            try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: true)
            let folder = kind == "alias" ? try f.alias(to: actual) : actual
            let target = folder.appendingPathComponent("preserve.sqlite3")
            let bytes = Data("synthetic backup bytes".utf8)
            try bytes.write(to: target)
            expectManagedDestination { try f.store.export(creation, to: target) }
            expectManagedDestination { try f.store.export(data: Data("overwrite".utf8), to: target) }
            var publicationCalls = 0
            let result = LibraryExport.copy(LibraryExport.plan([creation]), to: folder, store: f.store,
                beforePublication: { _ in publicationCalls += 1 })
            #expect(result.written == 0)
            #expect(result.failed.count == 1)
            #expect(publicationCalls == 0)
            #expect(try Data(contentsOf: target) == bytes)
            #expect(try FileManager.default.contentsOfDirectory(atPath: actual.path) == [target.lastPathComponent])
        }
    }

    @Test("All managed source files survive both fresh and deduplicated commits",
          arguments: ["asset", "library"], [false, true])
    func arbitraryManagedSourcesSurvive(writer: String, dedupe: Bool) async throws {
        let f = try JobRecoveryPathFixture(); defer { f.cleanUp() }
        for directory in [f.recovery] + f.db.storageDirectoryURLs {
            for relativePath in [".lock", "nested/unknown-future-format.bin"] {
                let source = directory.appendingPathComponent(relativePath)
                try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
                let bytes = Data("synthetic managed bytes \(UUID().uuidString)".utf8)
                try bytes.write(to: source)
                let inode = try f.inode(source)
                if dedupe { _ = try await f.assets.store(bytes, mimeType: "application/json") }
                // A fresh import copies a regular file through a parent alias.
                // Dedupe also exercises leaf aliases without asking copyItem to
                // import a symlink as the managed asset's stored file type.
                let linkTarget = dedupe ? source : source.deletingLastPathComponent()
                let link = try f.alias(to: linkTarget)
                let alias = dedupe ? link : link.appendingPathComponent(source.lastPathComponent)
                if writer == "asset" {
                    let saved = try await f.assets.store(fileAt: alias, mimeType: "application/json")
                    #expect(try await f.assets.data(for: saved) == bytes)
                } else {
                    let saved = try await f.store.save(fileAt: alias, mimeType: "application/json", kind: .transcript,
                        modelID: "offline/recovery-boundary", prompt: nil)
                    #expect(try await f.store.data(for: saved) == bytes)
                }
                #expect(try Data(contentsOf: source) == bytes)
                #expect(try f.inode(source) == inode)
                #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == linkTarget.path)
            }
        }
    }

    @Test("Case aliases of managed source files are not consumed")
    func caseAliasedSourceSurvivesCommit() async throws {
        let f = try JobRecoveryPathFixture(); defer { f.cleanUp() }
        let sensitive = try f.root.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames
        guard sensitive == false else { return }
        let pending = try f.seedPending()
        let source = f.entry(pending.id)
        let bytes = try Data(contentsOf: source)
        let alias = f.recovery.deletingLastPathComponent().appendingPathComponent("JOBRECOVERY")
            .appendingPathComponent(source.lastPathComponent.lowercased())
        let saved = try await f.assets.store(fileAt: alias, mimeType: "application/json")
        #expect(try await f.assets.data(for: saved) == bytes)
        #expect(try Data(contentsOf: source) == bytes)
        try f.expectPendingEnvelope(pending)
    }

    private func expectManagedDestination(_ work: () throws -> Void) {
        do {
            try work()
            Issue.record("Expected SavedCreationsError.managedExportDestination before filesystem mutation")
        } catch SavedCreationsError.managedExportDestination {
            // Exact intended boundary, not an incidental missing-directory error.
        } catch {
            Issue.record("Expected managedExportDestination, received \(error)")
        }
    }
}

private func jobRecoveryProtectedAssets(baseDirectory: URL, database: DatabaseManager,
                                        recoveryDirectory: URL) -> AssetStore {
    AssetStore(baseDirectory: baseDirectory, database: database, recoveryDirectory: recoveryDirectory)
}

@MainActor
private final class JobRecoveryPathFixture {
    let root: URL
    let recovery: URL
    let databaseURL: URL
    let index: URL
    let db: DatabaseManager
    let assets: AssetStore
    let store: SavedCreationsStore

    init() throws {
        let root = ORBTestScratch.root
            .appendingPathComponent("ORB-job-path-\(UUID().uuidString)")
        self.root = root
        recovery = root.appendingPathComponent("RecoveryOwner/JobRecovery")
        try FileManager.default.createDirectory(at: recovery.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Keep the database and its reserved backup container separate from
        // ordinary external fixtures and from the independently injected journal.
        databaseURL = root.appendingPathComponent("Database/catalog.sqlite3")
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        index = root.appendingPathComponent("creations.json")
        db = DatabaseManager(path: databaseURL.path)
        try #require(db.launchFailure == nil)
        assets = jobRecoveryProtectedAssets(baseDirectory: root.appendingPathComponent("Assets"),
                                           database: db, recoveryDirectory: recovery)
        store = try SavedCreationsStore(assetStore: assets, indexURL: index)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }
    func entry(_ id: UUID) -> URL { recovery.appendingPathComponent("\(id.uuidString).json") }
    func inode(_ url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try #require(attributes[.systemFileNumber] as? NSNumber).uint64Value
    }
    func alias(to directory: URL) throws -> URL {
        let alias = root.appendingPathComponent("alias-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: directory)
        return alias
    }
    func seedPending() throws -> JobRecord {
        try db.execChecked("""
            CREATE TRIGGER reject_path_fixture_job BEFORE INSERT ON jobs
            BEGIN SELECT RAISE(ABORT, 'offline path-protection fixture'); END;
            """)
        let jobs = JobController(database: db, recoveryDirectory: recovery)
        let record = try #require(jobs.recordVideoSubmission(remoteID: "fixture-\(UUID().uuidString)",
            modelID: "offline/recovery-boundary", remoteStatus: "completed", cost: 1,
            prompt: "synthetic pending output"))
        try #require(jobs.unsavedRecordCount == 1)
        try #require(try db.loadJobRecordsChecked().isEmpty)
        try expectPendingEnvelope(record)
        return record
    }
    func expectPendingEnvelope(_ record: JobRecord) throws {
        let entries = try JobRecoveryJournal(directory: recovery).withAccess { try $0.inventory() }
        let envelope = try #require(entries[record.id])
        #expect(entries.count == 1)
        #expect(try JobRecoveryEnvelope.same(envelope.candidate, record))
    }
    func saveOrdinaryCreation() async throws -> SavedCreation {
        try await store.save(Data("ordinary creation".utf8), mimeType: "text/plain", kind: .transcript,
                             modelID: "offline/recovery-boundary", prompt: nil)
    }
}
