import Foundation
import SQLite3
import Darwin

/// Proof is a committed catalog origin AND an exclusively-created directory.
/// A pathname or empty directory alone never authorizes reclamation.
private struct AssetRootClaim: Codable {
    let version: Int
    let catalogID: String
    let root: String
    let device: UInt64
    let inode: UInt64
    let birthSeconds: Int64
    let birthNanoseconds: Int64

    static func readDirectory(_ root: URL, catalogID: String) -> AssetRootClaim? {
        var info = stat()
        guard lstat(root.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { return nil }
        return AssetRootClaim(version: 1, catalogID: catalogID, root: root.path,
                              device: UInt64(UInt32(bitPattern: info.st_dev)), inode: UInt64(info.st_ino),
                              birthSeconds: Int64(info.st_birthtimespec.tv_sec),
                              birthNanoseconds: Int64(info.st_birthtimespec.tv_nsec))
    }

    func matches(_ current: AssetRootClaim) -> Bool {
        version == 1 && catalogID == current.catalogID && root == current.root
            && device == current.device && inode == current.inode
            && birthSeconds == current.birthSeconds && birthNanoseconds == current.birthNanoseconds
    }
}

struct LibraryUndoToken: Codable, Equatable, Sendable {
    let id: UUID
    let manifestID: UUID
}
struct LibraryRemoval: Sendable {
    let token: LibraryUndoToken
    let creations: [SavedCreation]
    let expiresAt: Date
}
struct LibrarySnapshot {
    let manifestID: UUID
    let catalogID: String
    let index: String
    let revision: Int64
    let creations: [SavedCreation]
}
struct LibraryImportToken {
    let id: UUID
    let manifestID: UUID
    let revision: Int64
    let checksum: String
    let path: String
    // A separate random journal identity permits reclaiming an abandoned partial
    // copy even while another creation owns the final content checksum.
    var stagingChecksum: String {
        let hex = id.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        return hex + hex
    }
    var stagingPath: String { String(stagingChecksum.prefix(2)) + "/" + stagingChecksum + ".stage" }
}
enum LibraryOwnershipPhase: String, Sendable {
    case importIntentCommitted, canonicalPublished, creationCommit, removalCommit
    case restoreCommit, finalizationCommit, recoveryCommit, exportWrite, exportAcknowledgement
}

extension DatabaseManager {
    func migrateLibraryOwnership() throws {
        try addColumnIfMissing(table: "assets", column: "library_managed", definition: "INTEGER NOT NULL DEFAULT 0 CHECK(library_managed IN (0,1))")
        // NULL means never classified. A bound pre-protocol root is always legacy.
        try addColumnIfMissing(table: "asset_catalog", column: "reclamation_mode", definition: "TEXT CHECK(reclamation_mode IN ('managed','legacy_blocked'))")
        try addColumnIfMissing(table: "asset_catalog", column: "ownership_protocol", definition: "INTEGER NOT NULL DEFAULT 0")
        try addColumnIfMissing(table: "asset_catalog", column: "root_claim", definition: "TEXT")
        try execChecked("""
        CREATE TABLE IF NOT EXISTS asset_deletion_quarantine (
          catalog_id TEXT NOT NULL, checksum TEXT NOT NULL, relative_path TEXT NOT NULL,
          root TEXT NOT NULL, reason TEXT NOT NULL, quarantined_at REAL NOT NULL,
          PRIMARY KEY(catalog_id, checksum, relative_path));
        CREATE TABLE IF NOT EXISTS library_manifests (
          manifest_id TEXT PRIMARY KEY, catalog_id TEXT NOT NULL,
          canonical_index TEXT NOT NULL UNIQUE, revision INTEGER NOT NULL CHECK(revision >= 0),
          exported_revision INTEGER NOT NULL DEFAULT -1, state TEXT NOT NULL DEFAULT 'registered' CHECK(state IN ('registered','retired')));
        CREATE TABLE IF NOT EXISTS library_creations (
          manifest_id TEXT NOT NULL REFERENCES library_manifests(manifest_id), creation_id TEXT NOT NULL,
          payload TEXT NOT NULL, checksum TEXT NOT NULL, relative_path TEXT NOT NULL,
          PRIMARY KEY(manifest_id, creation_id));
        CREATE TABLE IF NOT EXISTS library_undo (
          token TEXT NOT NULL, manifest_id TEXT NOT NULL REFERENCES library_manifests(manifest_id),
          creation_id TEXT NOT NULL, payload TEXT NOT NULL, checksum TEXT NOT NULL, relative_path TEXT NOT NULL,
          expires_at REAL NOT NULL, PRIMARY KEY(token, creation_id));
        CREATE TABLE IF NOT EXISTS library_imports (
          operation_id TEXT PRIMARY KEY, manifest_id TEXT NOT NULL REFERENCES library_manifests(manifest_id),
          checksum TEXT NOT NULL, relative_path TEXT NOT NULL, lease_until REAL NOT NULL,
          staging_checksum TEXT NOT NULL, staging_path TEXT NOT NULL);
        CREATE INDEX IF NOT EXISTS library_creations_checksum ON library_creations(checksum, relative_path);
        CREATE INDEX IF NOT EXISTS library_undo_checksum ON library_undo(checksum, relative_path);
        CREATE INDEX IF NOT EXISTS library_imports_checksum ON library_imports(checksum, relative_path);
        """)
        // An upgrade cannot mint new-storage provenance. Reconcile old cleanup
        // transactionally now; startup or a later bind can retry after failure.
        // The nonpersistent fallback has no usable asset operations to reconcile.
        if launchFailure == nil {
            try withAssetReservation {
                guard let row = try libraryRows("SELECT identity,reclamation_mode FROM asset_catalog WHERE singleton=1;").first else {
                    throw libraryConflict("Missing catalog during ownership upgrade")
                }
                let origin = try libraryRows("SELECT identity,version,database_path FROM asset_catalog_origin WHERE singleton=1;").first
                if origin != [row[0], "1", catalogStorageIdentity] {
                    try transitionAssetRootToLegacy(reason: "Catalog predates exclusive new-storage provenance")
                } else if row[1] == "managed" {
                    if try !libraryManagedRoot() {
                        try transitionAssetRootToLegacy(reason: "Stored root claim is missing or invalid")
                    }
                } else if row[1] == "legacy_blocked" {
                    try quarantineLegacyAssetDeletions()
                }
            }
        }
    }

    // These checked primitives serialize the connection; compound callers additionally
    // hold withAssetReservation. Never turn a failed SELECT into an empty inventory.
    func libraryRows(_ sql: String, _ values: [String] = []) throws -> [[String]] {
        dbLock.lock(); defer { dbLock.unlock() }
        guard let stmt = prepare(sql) else { throw DatabaseManagerError.operationFailed(currentError()) }
        defer { sqlite3_finalize(stmt) }
        for (offset, value) in values.enumerated() {
            guard Self.bindText(stmt, Int32(offset + 1), value) == SQLITE_OK else {
                throw DatabaseManagerError.operationFailed(currentError())
            }
        }
        var rows: [[String]] = []
        while true {
            switch sqlite3_step(stmt) {
            case SQLITE_ROW:
                rows.append((0..<sqlite3_column_count(stmt)).map { columnTextOrNil(stmt, $0) ?? "" })
            case SQLITE_DONE: return rows
            default: throw DatabaseManagerError.operationFailed(currentError())
            }
        }
    }
    func libraryExecute(_ sql: String, _ values: [String] = []) throws {
        _ = try libraryRows(sql, values)
    }
    /// Called inside BEGIN IMMEDIATE, before binding/publishing the catalog marker.
    /// mkdir is the root CAS: EEXIST (even an empty directory) loses the new-root
    /// claim. A crash before the DB commit leaves a directory/marker but no claim,
    /// so reopen is conservatively legacy rather than trying to finish/adopt it.
    func classifyAssetRoot(_ root: URL, markerExists: Bool) throws {
        try requireAssetReservation()
        let rows = try libraryRows("SELECT root,reclamation_mode,identity,ownership_protocol,root_claim FROM asset_catalog WHERE singleton=1;")
        guard let catalog = rows.first, UUID(uuidString: catalog[2]) != nil else {
            throw libraryConflict("Missing or invalid catalog")
        }
        let origin = try libraryRows("SELECT identity,version,database_path FROM asset_catalog_origin WHERE singleton=1;").first
        let provenCatalog = origin == [catalog[2], "1", catalogStorageIdentity]
        if catalog[1] == "managed" {
            let claim = try? JSONDecoder().decode(AssetRootClaim.self, from: Data(catalog[4].utf8))
            if provenCatalog, markerExists, catalog[0] == root.path, catalog[3] == "1",
               let claim, let current = AssetRootClaim.readDirectory(root, catalogID: catalog[2]), claim.matches(current) {
                return
            }
            // Missing/corrupt proof or a replaced directory revokes reclamation.
            // Keep the original claim for diagnostics; never regenerate it.
            try transitionAssetRootToLegacy(reason: "Managed root provenance is missing or no longer matches", root: root.path)
            return
        }
        if catalog[1] == "legacy_blocked" { return }
        let hasRows = try !libraryRows("""
            SELECT 1 FROM assets UNION ALL SELECT 1 FROM asset_library_pins
            UNION ALL SELECT 1 FROM asset_deletions UNION ALL SELECT 1 FROM asset_deletion_quarantine
            UNION ALL SELECT 1 FROM library_manifests LIMIT 1;
            """).isEmpty
        if provenCatalog && catalog[0].isEmpty && catalog[1].isEmpty && catalog[4].isEmpty && !markerExists && !hasRows {
            try FileManager.default.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
            if mkdir(root.path, S_IRWXU) == 0 {
                guard let claim = AssetRootClaim.readDirectory(root, catalogID: catalog[2]) else {
                    throw libraryConflict("Could not verify the exclusively-created asset directory")
                }
                let encoded = String(decoding: try JSONEncoder().encode(claim), as: UTF8.self)
                try libraryExecute("UPDATE asset_catalog SET reclamation_mode='managed',ownership_protocol=1,root_claim=? WHERE singleton=1;", [encoded])
                return
            }
            guard errno == EEXIST else {
                throw libraryConflict("Could not exclusively create the asset directory")
            }
        }
        try transitionAssetRootToLegacy(reason: "No exclusive new catalog and root claim", root: root.path)
    }

    /// Caller holds the catalog reservation. Mode and uncertain journal transfer
    /// commit together; a failed INSERT/DELETE/COMMIT preserves the old inventory.
    func transitionAssetRootToLegacy(reason: String, root: String = "") throws {
        try requireAssetReservation()
        try libraryExecute("UPDATE asset_catalog SET reclamation_mode='legacy_blocked',ownership_protocol=1 WHERE singleton=1;")
        try quarantineLegacyAssetDeletions(reason: reason, root: root)
    }

    /// Also called after a reservation's body, so older callers which update the
    /// mode directly (v1 registration) cannot commit an unquarantined downgrade.
    /// No filesystem access: even malformed or conflicting paths remain inventory.
    func quarantineLegacyAssetDeletions(reason: String = "Legacy ownership is incomplete", root: String = "") throws {
        try requireAssetReservation()
        guard try !libraryManagedRoot() else { return }
        try libraryExecute("""
            INSERT OR IGNORE INTO asset_deletion_quarantine(catalog_id,checksum,relative_path,root,reason,quarantined_at)
            SELECT c.identity,d.checksum,d.relative_path,COALESCE(c.root,?),?,?
            FROM asset_deletions d CROSS JOIN asset_catalog c WHERE c.singleton=1;
            """, [root, reason, String(Date().timeIntervalSince1970)])
        // Do not discard anything unless its exact diagnostic row was preserved.
        try libraryExecute("""
            DELETE FROM asset_deletions WHERE EXISTS (
              SELECT 1 FROM asset_deletion_quarantine q JOIN asset_catalog c ON c.identity=q.catalog_id
              WHERE c.singleton=1 AND q.checksum=asset_deletions.checksum AND q.relative_path=asset_deletions.relative_path);
            """)
    }

    func hasQuarantinedAsset(checksum: String, path: String? = nil) throws -> Bool {
        dbLock.lock(); defer { dbLock.unlock() }
        let root = try libraryRows("SELECT root FROM asset_catalog WHERE singleton=1;").first?.first ?? ""
        func normalized(_ path: String, root: String) -> String {
            let absolute = path.hasPrefix("/") || root.isEmpty ? path : root + "/" + path
            // Conservative on case-sensitive volumes too: a malformed inventory
            // must not lose its reservation merely because spelling differs.
            return (absolute as NSString).standardizingPath.lowercased()
        }
        let target = path.map { normalized($0, root: root) }
        return try libraryRows("SELECT checksum,relative_path,root FROM asset_deletion_quarantine;").contains { row in
            if row[0].lowercased() == checksum.lowercased() { return true }
            guard let path, let target else { return false }
            return (row[1] as NSString).standardizingPath.lowercased() == (path as NSString).standardizingPath.lowercased()
                || normalized(row[1], root: row[2].isEmpty ? root : row[2]) == target
        }
    }

    func requireAssetPathNotQuarantined(checksum: String, path: String) throws {
        guard try !hasQuarantinedAsset(checksum: checksum, path: path) else {
            throw libraryConflict("This asset path has uncertain legacy ownership; retained for explicit reconciliation")
        }
    }
    func libraryConflict(_ detail: String) -> Error {
        SavedCreationsError.unavailable(detail)
    }
    func librarySnapshot(_ id: UUID) throws -> LibrarySnapshot {
        let rows = try libraryRows("SELECT catalog_id, canonical_index, revision FROM library_manifests WHERE manifest_id=? AND state='registered';", [id.uuidString])
        guard let row = rows.first, let revision = Int64(row[2]), revision >= 0,
              UUID(uuidString: row[0]) != nil, row[1].hasPrefix("/"),
              try libraryRows("SELECT identity FROM asset_catalog WHERE singleton=1;").first?.first == row[0] else {
            throw libraryConflict("Unknown or foreign Library identity")
        }
        let creations = try libraryRows("SELECT creation_id,payload,checksum,relative_path FROM library_creations WHERE manifest_id=?;", [id.uuidString]).map { try decodeLibraryCreation($0) }
        return LibrarySnapshot(manifestID: id, catalogID: row[0], index: row[1], revision: revision,
                               creations: creations.sorted { $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt > $1.createdAt })
    }
    func decodeLibraryCreation(_ row: [String]) throws -> SavedCreation {
        guard row.count >= 4, let data = row[1].data(using: .utf8) else { throw libraryConflict("Invalid Library payload") }
        let item = try JSONDecoder().decode(SavedCreation.self, from: data)
        guard item.id.uuidString == row[0], item.checksum == row[2], item.assetPath == row[3],
              AssetStore.validContentPath(item.assetPath, checksum: item.checksum) else { throw libraryConflict("Invalid Library ownership row") }
        return item
    }
    func insertLibraryCreation(_ item: SavedCreation, manifestID: UUID) throws {
        guard AssetStore.validContentPath(item.assetPath, checksum: item.checksum) else { throw libraryConflict("Invalid creation path") }
        let payload = String(decoding: try JSONEncoder().encode(item), as: UTF8.self)
        try libraryExecute("INSERT INTO library_creations(manifest_id,creation_id,payload,checksum,relative_path) VALUES (?,?,?,?,?);",
                           [manifestID.uuidString, item.id.uuidString, payload, item.checksum, item.assetPath])
    }
    func requireLibraryRevision(_ id: UUID, _ revision: Int64) throws {
        guard try librarySnapshot(id).revision == revision else { throw libraryConflict("Library changed in another window; Refresh before editing") }
    }
    func bumpLibraryRevision(_ id: UUID) throws {
        let current = try librarySnapshot(id).revision
        guard current < Int64.max else { throw libraryConflict("Library revision is exhausted") }
        try libraryExecute("UPDATE library_manifests SET revision=revision+1 WHERE manifest_id=?;", [id.uuidString])
    }
    func libraryHasOwner(checksum: String, path: String? = nil) throws -> Bool {
        if try hasQuarantinedAsset(checksum: checksum, path: path) { return true }
        let paths = try libraryRows("SELECT relative_path FROM assets WHERE checksum=? UNION SELECT relative_path FROM asset_deletions WHERE checksum=?;", [checksum, checksum]).map { $0[0] } + (path.map { [$0] } ?? [])
        for table in ["library_creations", "library_undo", "library_imports"] {
            if try !libraryRows("SELECT 1 FROM \(table) WHERE checksum=? LIMIT 1;", [checksum]).isEmpty { return true }
            for p in paths where try !libraryRows("SELECT 1 FROM \(table) WHERE relative_path=? LIMIT 1;", [p]).isEmpty { return true }
            if table == "library_imports" {
                if try !libraryRows("SELECT 1 FROM library_imports WHERE staging_checksum=? LIMIT 1;", [checksum]).isEmpty { return true }
                for p in paths where try !libraryRows("SELECT 1 FROM library_imports WHERE staging_path=? LIMIT 1;", [p]).isEmpty { return true }
            }
        }
        return false
    }
    func libraryManagedRoot() throws -> Bool {
        dbLock.lock(); defer { dbLock.unlock() }
        guard let row = try libraryRows("SELECT identity,root,root_claim FROM asset_catalog WHERE singleton=1 AND ownership_protocol=1 AND reclamation_mode='managed';").first,
              UUID(uuidString: row[0]) != nil, row[1].hasPrefix("/"),
              try libraryRows("SELECT identity,version,database_path FROM asset_catalog_origin WHERE singleton=1;").first == [row[0], "1", catalogStorageIdentity],
              let claim = try? JSONDecoder().decode(AssetRootClaim.self, from: Data(row[2].utf8)),
              let current = AssetRootClaim.readDirectory(URL(fileURLWithPath: row[1]), catalogID: row[0]) else { return false }
        let root = URL(fileURLWithPath: row[1])
        let marker = root.deletingLastPathComponent().appendingPathComponent(".\(root.lastPathComponent).orb-catalog")
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: marker.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let bytes = try? Data(contentsOf: marker),
              bytes == Data((row[0] + "\n" + catalogStorageIdentity).utf8) else { return false }
        return claim.matches(current)
    }

    /// Prepares ONLY known Library candidates; no filesystem sweep, no inference
    /// from nil job/message IDs. Must be called inside the owner's transaction.
    func prepareLibraryReclamation(_ candidates: [AssetDeletionEntry]) throws {
        guard try libraryManagedRoot() else { return }
        for checksum in Set(candidates.map(\.checksum)) {
            let records = try loadAssetRecordsChecked(checksum: checksum)
            let entries = Set(records.map(\.relativePath) + candidates.filter { $0.checksum == checksum }.map(\.relativePath))
            guard try !hasAttachedAssetRecord(checksum: checksum),
                  try libraryRows("SELECT 1 FROM assets WHERE checksum=? AND library_managed=0 LIMIT 1;", [checksum]).isEmpty else { continue }
            var blocked = false
            for path in entries {
                guard AssetStore.validContentPath(path, checksum: checksum) else { throw libraryConflict("Invalid cleanup candidate") }
                if try libraryHasOwner(checksum: checksum, path: path) { blocked = true }
                if try !libraryRows("SELECT 1 FROM assets WHERE relative_path=? AND (checksum<>? OR library_managed=0 OR job_id IS NOT NULL OR message_id IS NOT NULL OR remote_reference IS NOT NULL) LIMIT 1;", [path, checksum]).isEmpty { blocked = true }
            }
            if blocked { continue }
            for path in entries {
                try libraryExecute("INSERT OR IGNORE INTO asset_deletions(checksum,relative_path) VALUES (?,?);", [checksum,path])
            }
            try libraryExecute("DELETE FROM assets WHERE checksum=? AND library_managed=1;", [checksum])
        }
    }
    func expireLibraryOwnership(now: Date) throws {
        guard now.timeIntervalSince1970.isFinite else { throw libraryConflict("Invalid maintenance clock") }
        let time = String(now.timeIntervalSince1970)
        // Validate full payloads before dropping any expired holds. A failed or
        // malformed read must not become an empty ownership inventory.
        for row in try libraryRows("SELECT creation_id,payload,checksum,relative_path,expires_at FROM library_undo WHERE expires_at<=?;", [time]) {
            _ = try decodeLibraryCreation(row)
            guard let expiry = Double(row[4]), expiry.isFinite else { throw libraryConflict("Invalid Undo expiry") }
        }
        for row in try libraryRows("SELECT operation_id,manifest_id,checksum,relative_path,lease_until,staging_checksum,staging_path FROM library_imports WHERE lease_until<=?;", [time]) {
            guard let operationID = UUID(uuidString: row[0]), let manifestID = UUID(uuidString: row[1]),
                  AssetStore.validContentPath(row[3], checksum: row[2]),
                  let expiry = Double(row[4]), expiry.isFinite else { throw libraryConflict("Invalid import lease") }
            let token = LibraryImportToken(id: operationID, manifestID: manifestID, revision: 0, checksum: row[2], path: row[3])
            guard row[5] == token.stagingChecksum, row[6] == token.stagingPath else { throw libraryConflict("Invalid staging identity") }
            _ = try librarySnapshot(manifestID)
        }
        var candidates = try libraryRows("SELECT checksum,relative_path FROM library_undo WHERE expires_at<=? UNION SELECT checksum,relative_path FROM library_imports WHERE lease_until<=?;", [time,time]).map { AssetDeletionEntry(checksum: $0[0], relativePath: $0[1]) }
        // Library staging names are deterministic from the leased operation so a
        // crash during copying cannot leave untracked random .tmp files forever.
        candidates += try libraryRows("SELECT staging_checksum,staging_path FROM library_imports WHERE lease_until<=?;", [time]).map {
            AssetDeletionEntry(checksum: $0[0], relativePath: $0[1])
        }
        try libraryExecute("DELETE FROM library_undo WHERE expires_at<=?;", [time])
        try libraryExecute("DELETE FROM library_imports WHERE lease_until<=?;", [time])
        try prepareLibraryReclamation(candidates)
    }
}
