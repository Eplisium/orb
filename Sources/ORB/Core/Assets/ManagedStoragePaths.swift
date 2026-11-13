import Foundation
import Darwin

/// Shared production locations and the boundary used by exports and source
/// cleanup. Constructing a location never creates or reads its contents.
enum ManagedStoragePaths {
    static var jobRecoveryDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("ORB/JobRecovery", isDirectory: true)
    }

    /// Foundation does not resolve ancestor links reliably for an absent leaf.
    /// Resolve the deepest existing ancestor, then append the missing suffix.
    static func canonicalURL(_ url: URL) -> URL {
        var ancestor = url.standardizedFileURL
        var suffix: [String] = []
        while !FileManager.default.fileExists(atPath: ancestor.path), ancestor.path != "/" {
            suffix.append(ancestor.lastPathComponent)
            ancestor.deleteLastPathComponent()
        }
        return suffix.reversed().reduce(ancestor.resolvingSymlinksInPath().standardizedFileURL) {
            $0.appendingPathComponent($1)
        }
    }

    /// Includes reserved directories themselves and every descendant, even
    /// before creation. File/volume identity covers filesystem aliases; path
    /// components and volume case rules cover names which do not exist yet.
    /// Failure to inspect a path is an error, never permission to overwrite it.
    static func contains(_ target: URL, directories: [URL], files: [URL]) throws -> Bool {
        guard target.isFileURL else { return true }
        for directory in directories {
            let canonicalDirectory = canonicalURL(directory)
            let options = try comparisonOptions(at: canonicalDirectory)
            // Walk lexical ancestors too: a link inside a managed directory
            // must not make that managed directory entry disposable.
            var ancestor = target.standardizedFileURL
            while true {
                let components = canonicalURL(ancestor).pathComponents
                let root = canonicalDirectory.pathComponents
                if components.count >= root.count,
                   equal(Array(components.prefix(root.count)), root, options: options) { return true }
                if try sameIdentity(ancestor, directory) { return true }
                if ancestor.path == "/" { break }
                ancestor.deleteLastPathComponent()
            }
        }
        let canonicalTarget = canonicalURL(target)
        for file in files {
            let canonicalFile = canonicalURL(file)
            let options = try comparisonOptions(at: canonicalFile)
            if equal(canonicalTarget.pathComponents, canonicalFile.pathComponents, options: options) { return true }
            if try sameIdentity(target, file) { return true }
        }
        return false
    }

    private static func equal(_ lhs: [String], _ rhs: [String], options: String.CompareOptions) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy {
            $0.0.compare($0.1, options: options) == .orderedSame
        }
    }

    private static func comparisonOptions(at url: URL) throws -> String.CompareOptions {
        var ancestor = url
        while !FileManager.default.fileExists(atPath: ancestor.path), ancestor.path != "/" {
            ancestor.deleteLastPathComponent()
        }
        let sensitive = try ancestor.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
            .volumeSupportsCaseSensitiveNames ?? false
        return sensitive ? [] : [.caseInsensitive]
    }

    private static func sameIdentity(_ lhs: URL, _ rhs: URL) throws -> Bool {
        let keys: Set<URLResourceKey> = [.fileResourceIdentifierKey, .volumeIdentifierKey]
        do {
            let left = try lhs.resourceValues(forKeys: keys)
            let right = try rhs.resourceValues(forKeys: keys)
            guard let leftFile = left.fileResourceIdentifier as? NSObject,
                  let rightFile = right.fileResourceIdentifier as? NSObject,
                  let leftVolume = left.volumeIdentifier as? NSObject,
                  let rightVolume = right.volumeIdentifier as? NSObject else {
                throw SavedCreationsError.unavailable("could not verify managed storage identity")
            }
            return leftFile.isEqual(rightFile) && leftVolume.isEqual(rightVolume)
        } catch let error as NSError where
            (error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError) ||
            (error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT)) { return false }
    }
}
