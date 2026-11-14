import Foundation
import AppKit

// MARK: - Storage & Diagnostics (Settings → Advanced)
//
// Shows how much disk ORB's own data uses and builds a support summary the
// user can paste into a bug report. Rules:
//   • Sizes are measured off the main actor (a large asset folder can take a
//     moment to walk).
//   • The diagnostics text holds versions, counts and sizes only: no keys,
//     no file paths under the home folder, no conversation content, no model
//     prompts — nothing that identifies the user.

struct StorageLocations: Equatable, Sendable {
    let supportDirectory: URL
    let database: URL
    let assets: URL
    let recoveryBackups: URL

    var wal: URL { URL(fileURLWithPath: database.path + "-wal") }
    var shm: URL { URL(fileURLWithPath: database.path + "-shm") }

    /// Application Support/ORB, matching `DatabaseManager`, `AssetStore` and
    /// `DatabaseRecoveryBackup`.
    static func standard(fileManager: FileManager = .default) -> StorageLocations {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("ORB", isDirectory: true)
        return inside(support)
    }

    static func inside(_ support: URL) -> StorageLocations {
        let database = support.appendingPathComponent("favorites.sqlite3")
        return StorageLocations(
            supportDirectory: support,
            database: database,
            assets: support.appendingPathComponent("Assets", isDirectory: true),
            recoveryBackups: support.appendingPathComponent(".orb-database-backups", isDirectory: true)
        )
    }
}

struct StorageReport: Equatable, Sendable {
    var databaseBytes: Int64 = 0
    var walBytes: Int64 = 0
    var assetsBytes: Int64 = 0
    var assetFileCount = 0
    var recoveryBackupBytes: Int64 = 0
    var recoveryBackupCount = 0

    var totalBytes: Int64 { databaseBytes + walBytes + assetsBytes + recoveryBackupBytes }

    /// Walks the locations. Missing files and folders count as zero.
    static func measure(_ locations: StorageLocations, fileManager: FileManager = .default) -> StorageReport {
        var report = StorageReport()
        report.databaseBytes = fileSize(locations.database, fileManager)
        report.walBytes = fileSize(locations.wal, fileManager) + fileSize(locations.shm, fileManager)
        let assets = directoryUsage(locations.assets, fileManager)
        report.assetsBytes = assets.bytes
        report.assetFileCount = assets.files
        report.recoveryBackupBytes = directoryUsage(locations.recoveryBackups, fileManager).bytes
        report.recoveryBackupCount = ((try? fileManager.contentsOfDirectory(
            at: locations.recoveryBackups, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        )) ?? []).filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }.count
        return report
    }

    private static func fileSize(_ url: URL, _ fileManager: FileManager) -> Int64 {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              (attributes[.type] as? FileAttributeType) == .typeRegular else { return 0 }
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }

    private static func directoryUsage(_ url: URL, _ fileManager: FileManager) -> (bytes: Int64, files: Int) {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let walker = fileManager.enumerator(at: url, includingPropertiesForKeys: keys, options: []) else {
            return (0, 0)
        }
        var bytes: Int64 = 0
        var files = 0
        for case let item as URL in walker {
            guard let values = try? item.resourceValues(forKeys: Set(keys)),
                  values.isSymbolicLink != true, values.isRegularFile == true else { continue }
            bytes += Int64(values.fileSize ?? 0)
            files += 1
        }
        return (bytes, files)
    }
}

enum StorageFormat {
    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}

/// The text "Copy Diagnostics" puts on the pasteboard.
enum DiagnosticsSummary {
    struct Environment: Equatable, Sendable {
        var appVersion: String
        var build: String
        var macOS: String
        var architecture: String
        var appLockEnabled: Bool
        var automaticUpdateChecks: Bool
        var hasInferenceKey: Bool?
        var hasManagementKey: Bool?

        @MainActor
        static func current(hasInferenceKey: Bool?, hasManagementKey: Bool?) -> Environment {
            let info = Bundle.main.infoDictionary ?? [:]
            let os = ProcessInfo.processInfo.operatingSystemVersion
            #if arch(arm64)
            let arch = "arm64"
            #else
            let arch = "x86_64"
            #endif
            return Environment(
                appVersion: info["CFBundleShortVersionString"] as? String ?? "unknown",
                build: info["CFBundleVersion"] as? String ?? "unknown",
                macOS: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
                architecture: arch,
                appLockEnabled: AppLock.isEnabled(in: .standard),
                automaticUpdateChecks: UserDefaults.standard.object(forKey: UpdateChecker.autoCheckKey) as? Bool ?? true,
                hasInferenceKey: hasInferenceKey,
                hasManagementKey: hasManagementKey
            )
        }
    }

    /// Plain text, one fact per line. Key presence is yes/no only.
    static func make(_ env: Environment, storage: StorageReport) -> String {
        func presence(_ value: Bool?) -> String { value.map { $0 ? "yes" : "no" } ?? "unknown" }
        return [
            "ORB \(env.appVersion) (\(env.build))",
            "macOS \(env.macOS) · \(env.architecture)",
            "App Lock: \(env.appLockEnabled ? "on" : "off")",
            "Automatic update checks: \(env.automaticUpdateChecks ? "on" : "off")",
            "Inference key configured: \(presence(env.hasInferenceKey))",
            "Management key configured: \(presence(env.hasManagementKey))",
            "Database: \(StorageFormat.bytes(storage.databaseBytes)) (+ \(StorageFormat.bytes(storage.walBytes)) journal)",
            "Saved media: \(storage.assetFileCount) files, \(StorageFormat.bytes(storage.assetsBytes))",
            "Recovery backups: \(storage.recoveryBackupCount), \(StorageFormat.bytes(storage.recoveryBackupBytes))",
            "Total: \(StorageFormat.bytes(storage.totalBytes))",
        ].joined(separator: "\n")
    }
}

@MainActor
final class StorageDiagnosticsModel: ObservableObject {
    @Published private(set) var report: StorageReport?
    @Published private(set) var isMeasuring = false

    let locations: StorageLocations
    private let measure: @Sendable (StorageLocations) async -> StorageReport

    init(
        locations: StorageLocations = .standard(),
        measure: @escaping @Sendable (StorageLocations) async -> StorageReport = { locations in
            await Task.detached(priority: .utility) { StorageReport.measure(locations) }.value
        }
    ) {
        self.locations = locations
        self.measure = measure
    }

    func refresh() async {
        guard !isMeasuring else { return }
        isMeasuring = true
        report = await measure(locations)
        isMeasuring = false
    }

    func revealInFinder() {
        let target = FileManager.default.fileExists(atPath: locations.database.path)
            ? locations.database : locations.supportDirectory
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }

    func diagnosticsText(hasInferenceKey: Bool?, hasManagementKey: Bool?) -> String {
        DiagnosticsSummary.make(
            .current(hasInferenceKey: hasInferenceKey, hasManagementKey: hasManagementKey),
            storage: report ?? StorageReport()
        )
    }
}
