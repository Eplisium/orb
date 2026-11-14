import Foundation

/// Root for disposable on-disk test fixtures: the system temporary directory,
/// fully resolved (`/var/…` → `/private/var/…`) so path-identity and symlink
/// checks see one canonical spelling. Never a home-directory tool cache.
enum ORBTestScratch {
    static let root: URL = {
        let temporary = NSTemporaryDirectory()
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let resolved = realpath(temporary, &buffer).map { String(cString: $0) } ?? temporary
        return URL(fileURLWithPath: resolved, isDirectory: true)
    }()
}
