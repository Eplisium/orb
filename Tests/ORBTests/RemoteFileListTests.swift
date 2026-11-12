import Foundation
import Testing
@testable import ORB

@Suite("Remote Files request ownership")
@MainActor
struct RemoteFileListTests {
    @Test("F01: pre-delete refresh and next-page responses cannot restore deleted rows", arguments: [false, true])
    func stalePageAfterDelete(loadMore: Bool) async throws {
        let transport = RemoteFilesHeldTransport()
        let listing = RemoteFileList(service: FileService(transport: transport))
        await transport.gate.release(0, body: #"{"data":[{"id":"deleted"},{"id":"keep"}],"has_more":true,"cursor":"A"}"#)
        await listing.refresh()
        let oldPage = Task {
            if loadMore { await listing.loadMore() } else { await listing.refresh() }
        }
        await waitForRequests(2, transport)
        let deletion = Task { try await listing.delete(id: "deleted", confirming: true) }
        await waitForRequests(3, transport)
        await transport.gate.release(2, body: #"{"data":[{"id":"keep"}]}"#)
        try await deletion.value
        #expect(listing.files.map(\.id) == ["keep"])
        await transport.gate.release(1, body: #"{"data":[{"id":"deleted"},{"id":"obsolete"}],"has_more":true,"cursor":"stale"}"#)
        await oldPage.value
        #expect(listing.files.map(\.id) == ["keep"])
        #expect(listing.nextCursor == nil)
        #expect(!listing.hasMore)
        #expect(!listing.isFetchingPage)
    }

    @Test("F01: malformed pages cannot duplicate rows or loop pagination")
    func malformedPaginationIsBounded() async throws {
        let transport = RemoteFilesHeldTransport()
        let listing = RemoteFileList(service: FileService(transport: transport))
        await transport.gate.release(0, body: #"{"data":[{"id":"a"},{"id":"a"}],"has_more":true,"cursor":"A"}"#)
        await listing.refresh()
        #expect(listing.files.map(\.id) == ["a"])
        #expect(listing.nextCursor == "A")

        // A page can repeat an already-seen ID and a brand-new ID twice.
        await transport.gate.release(1, body: #"{"data":[{"id":"a"},{"id":"b"},{"id":"b"}],"has_more":true,"cursor":"B"}"#)
        await listing.loadMore()
        #expect(listing.files.map(\.id) == ["a", "b"])
        #expect(listing.nextCursor == "B")

        // A -> B -> A is a cursor cycle and must stop, not loop forever.
        await transport.gate.release(2, body: #"{"data":[{"id":"c"}],"has_more":true,"cursor":"A"}"#)
        await listing.loadMore()
        #expect(listing.files.map(\.id) == ["a", "b", "c"])
        #expect(!listing.hasMore)
        #expect(listing.pageError != nil)
    }

    @Test("F01: a completed upload refresh is not lost behind an older GET")
    func uploadInvalidatesHeldPage() async throws {
        let transport = RemoteFilesHeldTransport()
        let listing = RemoteFileList(service: FileService(transport: transport))
        let oldPage = Task { await listing.refresh() }
        await waitForRequests(1, transport)
        let upload = Task { try await listing.upload(filename: "new.txt", mimeType: "text/plain", data: Data("new".utf8)) }
        await waitForRequests(2, transport)
        await transport.gate.release(1, body: #"{"data":[{"id":"uploaded"}]}"#)
        let result = try await upload.value
        #expect(result.id == "uploaded")
        #expect(listing.files.map(\.id) == ["uploaded"])
        await transport.gate.release(0, body: #"{"data":[]}"#)
        await oldPage.value
        #expect(listing.files.map(\.id) == ["uploaded"])
        #expect(!listing.isFetchingPage)
    }

    private func waitForRequests(_ count: Int, _ transport: RemoteFilesHeldTransport) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        var current = await transport.gate.count
        while current < count, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
            current = await transport.gate.count
        }
        #expect(current == count)
    }
}

/// The held transport deliberately ignores cancellation, exercising stale
/// publication guards even when cancellation cannot prevent a late response.
private actor RemoteFilesPageGate {
    private var requests: [String?] = []
    private var replies: [Int: Result<String, Error>] = [:]
    private var waiting: [Int: CheckedContinuation<String, Error>] = [:]
    var count: Int { requests.count }

    func page(cursor: String?) async throws -> String {
        let index = requests.count
        requests.append(cursor)
        if let reply = replies.removeValue(forKey: index) { return try reply.get() }
        return try await withCheckedThrowingContinuation { waiting[index] = $0 }
    }

    func release(_ index: Int, body: String) {
        complete(index, result: .success(body))
    }

    func fail(_ index: Int) {
        complete(index, result: .failure(MediaServiceError.decoding("obsolete failure")))
    }

    private func complete(_ index: Int, result: Result<String, Error>) {
        if let continuation = waiting.removeValue(forKey: index) {
            continuation.resume(with: result)
        } else {
            replies[index] = result
        }
    }
}

private final class RemoteFilesHeldTransport: MediaTransport, @unchecked Sendable {
    let gate = RemoteFilesPageGate()

    init() {
        super.init(session: URLSession(configuration: .ephemeral), apiKeyProvider: { "offline-fixture" })
    }

    override func send<T: Decodable>(_ request: URLRequest, as type: T.Type) async throws -> T {
        let body: String
        switch request.httpMethod {
        case "DELETE": body = #"{"id":"deleted","deleted":true}"#
        case "POST": body = #"{"id":"uploaded"}"#
        default:
            let cursor = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "cursor" }?.value
            body = try await gate.page(cursor: cursor)
        }
        return try JSONDecoder().decode(type, from: Data(body.utf8))
    }
}
