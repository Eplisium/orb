import Foundation

/// Installs a catalog binding without replacing a competing owner's marker.
/// I/O closures allow deterministic interruption tests without touching real data.
enum ExclusiveMarkerPublisher {
    static func publish(
        _ payload: Data,
        to marker: URL,
        fileManager: FileManager = .default,
        write: (Data, URL) throws -> Void = { try $0.write(to: $1, options: .withoutOverwriting) },
        install: (URL, URL) throws -> Void = { try FileManager.default.linkItem(at: $0, to: $1) }
    ) throws {
        if fileManager.fileExists(atPath: marker.path) {
            try verify(payload, at: marker, fileManager: fileManager)
            return
        }
        // A failed/interrupted write may leave only an unreferenced sibling,
        // never a partially written authoritative binding. linkItem publishes
        // a complete inode exclusively; unlike rename it cannot replace a winner.
        let staged = marker.deletingLastPathComponent()
            .appendingPathComponent(".orb-binding-\(UUID().uuidString).tmp")
        defer { try? fileManager.removeItem(at: staged) }
        try write(payload, staged)
        do {
            try install(staged, marker)
        } catch {
            // Another publisher with the same identity may have won. Only an
            // exact regular-file match is success; foreign/partial claims stay.
            guard (try? verify(payload, at: marker, fileManager: fileManager)) != nil else {
                throw error
            }
        }
        try verify(payload, at: marker, fileManager: fileManager)
    }

    private static func verify(_ payload: Data, at marker: URL, fileManager: FileManager) throws {
        let attributes = try fileManager.attributesOfItem(atPath: marker.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              try Data(contentsOf: marker) == payload else {
            throw AssetStoreError.storageFailure("Binding marker belongs to another catalog or is invalid")
        }
    }
}
