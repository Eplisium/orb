import Foundation
import Combine

/// Shared pagination state for the remote Files page; the local Library is separate.
@MainActor
final class RemoteFileList: ObservableObject {
    @Published private(set) var files: [WorkspaceFile] = []
    @Published private(set) var nextCursor: String?
    @Published private(set) var hasMore = false
    @Published private(set) var isFetchingPage = false
    @Published var pageError: String?

    private let service: FileService
    private var pageTask: Task<Void, Never>?
    private var pageCursor: String?
    private var generation = UUID()
    private var consumedCursors: Set<String> = []

    init(service: FileService) { self.service = service }

    /// View tasks join shared work; leaving a view does not cancel its owner.
    func refresh() async {
        if let pageTask, pageCursor == nil { await pageTask.value; return }
        // A Refresh asks for an authoritative first page, not the completion
        // of an older pagination request. Existing refresh callers still join.
        pageTask?.cancel()
        nextCursor = nil
        hasMore = false
        await startPage(cursor: nil).value
    }

    func loadMore() async {
        if let pageTask { await pageTask.value; return }
        guard hasMore, let cursor = nextCursor else { return }
        await startPage(cursor: cursor).value
    }

    private func startPage(cursor: String?) -> Task<Void, Never> {
        let identity = UUID()
        generation = identity
        pageCursor = cursor
        pageError = nil
        if cursor == nil { consumedCursors = [] }
        isFetchingPage = true
        let task = Task { @MainActor in
            defer {
                if generation == identity {
                    pageTask = nil
                    pageCursor = nil
                    isFetchingPage = false
                }
            }
            do {
                let page = try await service.listPage(cursor: cursor)
                try Task.checkCancellation()
                guard generation == identity else { return }
                if cursor != nil {
                    // Malformed/unstable pages must not duplicate rows: dedupe
                    // against a growing set, not a snapshot taken before the page.
                    var known = Set(files.map(\.id))
                    files += page.data.filter { known.insert($0.id).inserted }
                    let repeatedCursor = page.cursor.map(consumedCursors.contains) ?? false
                    hasMore = page.hasMore == true && page.cursor != nil && !repeatedCursor
                    pageError = page.hasMore == true && !hasMore
                        ? (repeatedCursor ? "Pagination repeated a cursor; stopped to avoid a loop."
                                          : "Pagination returned no new cursor; stopped to avoid a loop.")
                        : nil
                } else {
                    // The first page is authoritative, but duplicate identities
                    // still cannot appear twice in a ForEach keyed by ID.
                    var known = Set<String>()
                    files = page.data.filter { known.insert($0.id).inserted }
                    hasMore = page.hasMore == true && page.cursor != nil
                    pageError = page.hasMore == true && page.cursor == nil ? "More files reported without a cursor; cannot continue safely." : nil
                }
                if let cursor { consumedCursors.insert(cursor) }
                if let next = page.cursor { consumedCursors.insert(next) }
                nextCursor = page.cursor
            } catch is CancellationError { }
            catch {
                guard generation == identity else { return }
                pageError = error.localizedDescription
            }
        }
        pageTask = task
        return task
    }

    /// A successful mutation must never join a GET begun before that mutation.
    /// Cancellation is an optimization; identity guards also reject late results,
    /// errors and cleanup from transports that cannot cancel immediately.
    private func refreshAfterMutation() async {
        generation = UUID()
        pageTask?.cancel()
        pageTask = nil
        nextCursor = nil
        hasMore = false
        await refresh()
    }

    func delete(id: String, confirming: Bool) async throws {
        _ = try await service.delete(id: id, confirming: confirming)
        files.removeAll { $0.id == id }
        await refreshAfterMutation()
    }

    func upload(filename: String, mimeType: String, data: Data) async throws -> WorkspaceFile {
        let file = try await service.upload(filename: filename, mimeType: mimeType, data: data)
        await refreshAfterMutation()
        return file
    }
}
