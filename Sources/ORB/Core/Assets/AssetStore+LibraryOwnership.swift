import Foundation

/// Every filesystem publication is guarded by the catalog's cross-connection
/// writer reservation. Intent survives a failed metadata COMMIT/crash and names
/// the exact canonical path, including an unindexed file left by that failure.
extension AssetStore {
    func publishLibraryCreation(data: Data?, source: URL?, snapshot: LibrarySnapshot,
                                mimeType: String, kind: SavedCreation.Kind, modelID: String,
                                prompt: String?, videoRemoteID: String?, now: @escaping () -> Date,
                                failpoint: @escaping (LibraryOwnershipPhase) throws -> Void) throws -> SavedCreation {
        let checksum: String
        let size: Int
        if let source {
            checksum = try Self.sha256Hex(fileAt: source)
            size = (try FileManager.default.attributesOfItem(atPath: source.path)[.size] as? NSNumber)?.intValue ?? 0
        } else if let data { checksum = Self.sha256Hex(data); size = data.count }
        else { throw database.libraryConflict("Missing save input") }
        try recoverLibraryOwnership(now: now(), failpoint: failpoint)
        let token = try withCatalogReservation { () -> LibraryImportToken in
            try database.requireLibraryRevision(snapshot.manifestID, snapshot.revision)
            let path = try database.loadAssetRecordsChecked(checksum: checksum)
                .sorted { $0.createdAt < $1.createdAt }.first?.relativePath
                ?? Self.relativePath(forChecksum: checksum, mimeType: mimeType)
            guard Self.validContentPath(path, checksum: checksum) else { throw AssetStoreError.invalidPath(path) }
            try database.requireAssetPathNotQuarantined(checksum: checksum, path: path)
            let token = LibraryImportToken(id: UUID(), manifestID: snapshot.manifestID,
                                           revision: snapshot.revision, checksum: checksum, path: path)
            try database.libraryExecute("INSERT INTO library_imports(operation_id,manifest_id,checksum,relative_path,lease_until,staging_checksum,staging_path) VALUES (?,?,?,?,?,?,?);",
                [token.id.uuidString, token.manifestID.uuidString, checksum, path, String(now().addingTimeInterval(300).timeIntervalSince1970), token.stagingChecksum, token.stagingPath])
            return token
        }
        // An injected crash here deliberately leaves the durable intent for reopen.
        try failpoint(.importIntentCommitted)
        var creation: SavedCreation?
        do {
            let asset = try storePayload(checksum: checksum, size: size, mimeType: mimeType,
                remoteReference: nil, jobID: nil, messageID: nil, libraryImport: token, now: now,
                commit: { asset in
                    guard asset.relativePath == token.path else { throw self.database.libraryConflict("Import path changed; retry") }
                    guard try !self.database.libraryRows("SELECT 1 FROM library_imports WHERE operation_id=? AND lease_until>?;", [token.id.uuidString, String(now().timeIntervalSince1970)]).isEmpty else {
                        throw self.database.libraryConflict("Import expired while copying; retry")
                    }
                    try failpoint(.canonicalPublished)
                    let item = SavedCreation(id: UUID(), kind: kind, modelID: modelID, prompt: prompt,
                        mimeType: mimeType, createdAt: now(), assetPath: asset.relativePath, checksum: checksum,
                        videoRemoteID: videoRemoteID)
                    try self.database.insertLibraryCreation(item, manifestID: token.manifestID)
                    try self.database.libraryExecute("DELETE FROM library_imports WHERE operation_id=?;", [token.id.uuidString])
                    try self.database.bumpLibraryRevision(token.manifestID)
                    try failpoint(.creationCommit)
                    creation = item
                }, stage: { temporary in
                    if let source {
                        try FileManager.default.copyItem(at: source, to: temporary)
                    } else if let data { try data.write(to: temporary, options: .withoutOverwriting) }
                    guard try Self.sha256Hex(fileAt: temporary) == checksum else {
                        throw AssetStoreError.storageFailure("Source changed while copying")
                    }
                })
            guard let creation else { throw database.libraryConflict("Missing committed creation") }
            if let source { consumeSourceFile(source, afterStoring: asset) }
            return creation
        } catch {
            // Abort is itself recoverable: if it fails, the lease will expire.
            try? withCatalogReservation {
                try database.libraryExecute("DELETE FROM library_imports WHERE operation_id=?;", [token.id.uuidString])
                try database.prepareLibraryReclamation([
                    AssetDeletionEntry(checksum: token.checksum, relativePath: token.path),
                    AssetDeletionEntry(checksum: token.stagingChecksum, relativePath: token.stagingPath)
                ])
            }
            _ = try? recoverPendingDeletions()
            throw error
        }
    }

    func removeLibraryCreations(snapshot: LibrarySnapshot, ids: Set<UUID>, now: Date,
                                undoDuration: TimeInterval,
                                failpoint: (LibraryOwnershipPhase) throws -> Void) throws -> LibraryRemoval {
        try withCatalogReservation {
            try database.requireLibraryRevision(snapshot.manifestID, snapshot.revision)
            let current = try database.librarySnapshot(snapshot.manifestID)
            guard now.timeIntervalSince1970.isFinite, undoDuration.isFinite,
                  undoDuration > 0, undoDuration <= 86400 else { throw database.libraryConflict("Invalid Undo deadline") }
            let removed = current.creations.filter { ids.contains($0.id) }
            let token = LibraryUndoToken(id: UUID(), manifestID: current.manifestID)
            let expiry = now.addingTimeInterval(undoDuration)
            for item in removed {
                try database.libraryExecute("""
                    INSERT INTO library_undo(token,manifest_id,creation_id,payload,checksum,relative_path,expires_at)
                    SELECT ?,manifest_id,creation_id,payload,checksum,relative_path,? FROM library_creations
                    WHERE manifest_id=? AND creation_id=?;
                    """, [token.id.uuidString, String(expiry.timeIntervalSince1970), current.manifestID.uuidString, item.id.uuidString])
                try database.libraryExecute("DELETE FROM library_creations WHERE manifest_id=? AND creation_id=?;", [current.manifestID.uuidString,item.id.uuidString])
            }
            if !removed.isEmpty { try database.bumpLibraryRevision(current.manifestID) }
            try failpoint(.removalCommit)
            return LibraryRemoval(token: token, creations: removed, expiresAt: expiry)
        }
    }

    func restoreLibraryRemoval(_ token: LibraryUndoToken, now: Date,
                               failpoint: (LibraryOwnershipPhase) throws -> Void) throws {
        try withCatalogReservation {
            _ = try database.librarySnapshot(token.manifestID)
            let rows = try database.libraryRows("SELECT creation_id,payload,checksum,relative_path,expires_at FROM library_undo WHERE token=? AND manifest_id=?;", [token.id.uuidString,token.manifestID.uuidString])
            guard !rows.isEmpty else { throw database.libraryConflict("Undo is no longer available") }
            for row in rows {
                guard let expiry = Double(row[4]), expiry.isFinite, expiry > now.timeIntervalSince1970 else {
                    throw database.libraryConflict("Undo has expired")
                }
                let item = try database.decodeLibraryCreation(row)
                let record = AssetRecord(id: item.id, relativePath: item.assetPath, remoteReference: nil,
                    mimeType: item.mimeType, sizeBytes: 0, checksum: item.checksum, jobID: nil,
                    messageID: nil, retention: .keep, createdAt: item.createdAt)
                try validateAttachment(record)
                try database.insertLibraryCreation(item, manifestID: token.manifestID)
            }
            try database.libraryExecute("DELETE FROM library_undo WHERE token=? AND manifest_id=?;", [token.id.uuidString,token.manifestID.uuidString])
            try database.bumpLibraryRevision(token.manifestID)
            try failpoint(.restoreCommit)
        }
    }

    func finalizeLibraryRemoval(_ token: LibraryUndoToken,
                                failpoint: (LibraryOwnershipPhase) throws -> Void) throws {
        try withCatalogReservation {
            _ = try database.librarySnapshot(token.manifestID)
            let candidates = try database.libraryRows("SELECT checksum,relative_path FROM library_undo WHERE token=? AND manifest_id=?;", [token.id.uuidString,token.manifestID.uuidString]).map { AssetDeletionEntry(checksum: $0[0], relativePath: $0[1]) }
            try database.libraryExecute("DELETE FROM library_undo WHERE token=? AND manifest_id=?;", [token.id.uuidString,token.manifestID.uuidString])
            try database.prepareLibraryReclamation(candidates)
            try failpoint(.finalizationCommit)
        }
        // Caller reports unlink failure separately from the already committed hold release.
    }

    func recoverLibraryOwnership(now: Date,
                                 failpoint: (LibraryOwnershipPhase) throws -> Void = { _ in }) throws {
        try withCatalogReservation {
            try database.expireLibraryOwnership(now: now)
            try failpoint(.recoveryCommit)
        }
        try recoverPendingDeletions()
    }
}
