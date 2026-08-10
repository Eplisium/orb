import Foundation
import Testing
@testable import ORB

/// Exercises the real `URLSessionStreamingTransport` against a genuine local
/// HTTP server that emits SSE chunks with deliberate pauses between them.
///
/// The bug this guards against: an implementation that buffers the response
/// body (or iterates it byte-by-byte through a fixed-size block) does not
/// surface a chunk until the buffer fills or the body ends. That makes
/// time-to-first-token track the whole response instead of the first chunk —
/// exactly the "not snappy" symptom. Asserting on *ordering and timing*, not
/// just final content, is what catches it.
@Suite(.serialized)
struct StreamingTransportLatencyTests {

    /// Minimal single-connection HTTP server that writes pre-scripted chunks
    /// with a delay between each, then closes.
    private final class ChunkedServer: @unchecked Sendable {
        private let listener: FileHandle
        private var socket: Int32 = -1
        let port: UInt16

        init(chunks: [String], gap: TimeInterval) throws {
            var fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
            var yes: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = 0 // let the kernel choose a free port
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")

            let bindResult = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bindResult == 0, Darwin.listen(fd, 1) == 0 else {
                close(fd)
                throw NSError(domain: "ChunkedServer", code: 1)
            }

            var bound = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            _ = withUnsafeMutablePointer(to: &bound) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    getsockname(fd, $0, &len)
                }
            }
            port = UInt16(bigEndian: bound.sin_port)
            socket = fd
            listener = FileHandle(fileDescriptor: fd, closeOnDealloc: false)

            let listenFD = fd
            Thread.detachNewThread {
                var clientAddr = sockaddr()
                var clientLen = socklen_t(MemoryLayout<sockaddr>.size)
                let client = Darwin.accept(listenFD, &clientAddr, &clientLen)
                guard client >= 0 else { return }
                defer { close(client) }

                // Drain the request line/headers so the client can proceed.
                var scratch = [UInt8](repeating: 0, count: 4096)
                _ = Darwin.recv(client, &scratch, scratch.count, 0)

                let header = """
                HTTP/1.1 200 OK\r
                Content-Type: text/event-stream\r
                Cache-Control: no-cache\r
                Transfer-Encoding: chunked\r
                \r

                """
                _ = header.withCString { Darwin.send(client, $0, strlen($0), 0) }

                for chunk in chunks {
                    // HTTP chunked framing: size in hex, CRLF, payload, CRLF.
                    let framed = String(format: "%lX\r\n%@\r\n", chunk.utf8.count, chunk)
                    _ = framed.withCString { Darwin.send(client, $0, strlen($0), 0) }
                    Thread.sleep(forTimeInterval: gap)
                }
                _ = "0\r\n\r\n".withCString { Darwin.send(client, $0, strlen($0), 0) }
                Thread.sleep(forTimeInterval: 0.05)
            }
        }

        func shutdown() {
            if socket >= 0 { close(socket) }
        }
    }

    private func makeRequest(port: UInt16) -> URLRequest {
        URLRequest(url: URL(string: "http://127.0.0.1:\(port)/stream")!)
    }

    @Test("each SSE chunk is delivered as it arrives, not buffered to the end")
    func chunksArriveIncrementally() async throws {
        let gap = 0.12
        let chunks = (0..<4).map { "data: {\"n\":\($0)}\n\n" }
        let server = try ChunkedServer(chunks: chunks, gap: gap)
        defer { server.shutdown() }

        let transport = URLSessionStreamingTransport()
        let stream = try await transport.bytes(for: makeRequest(port: server.port)).body

        let start = Date()
        var arrivals: [TimeInterval] = []
        var received = ""
        for try await data in stream {
            guard !data.isEmpty else { continue }
            arrivals.append(Date().timeIntervalSince(start))
            received += String(decoding: data, as: UTF8.self)
        }

        // All payload must survive intact.
        for i in 0..<4 {
            #expect(received.contains("{\"n\":\(i)}"))
        }

        let firstArrival = try #require(arrivals.first)
        let totalSpan = try #require(arrivals.last)

        // The decisive assertion: the first chunk lands long before the last
        // one is sent. A buffering transport would push firstArrival up to
        // roughly totalSpan.
        #expect(firstArrival < gap * 2,
                "first chunk took \(firstArrival)s — transport is buffering")
        #expect(totalSpan > gap * 2,
                "expected the server's pacing to be observable")
        #expect(arrivals.count >= 2,
                "expected multiple discrete deliveries, got \(arrivals.count)")
    }

    @Test("a chunk far smaller than any internal buffer is still delivered promptly")
    func smallChunkIsNotWithheld() async throws {
        // A single tiny chunk followed by a long pause. An implementation that
        // waits for a 4KB block to fill would stall here until the body closed.
        let server = try ChunkedServer(chunks: ["data: hi\n\n"], gap: 0.4)
        defer { server.shutdown() }

        let transport = URLSessionStreamingTransport()
        let stream = try await transport.bytes(for: makeRequest(port: server.port)).body

        let start = Date()
        var firstAt: TimeInterval?
        for try await data in stream where !data.isEmpty {
            if firstAt == nil { firstAt = Date().timeIntervalSince(start) }
        }

        let arrival = try #require(firstAt)
        #expect(arrival < 0.3, "tiny chunk withheld for \(arrival)s")
    }

    @Test("HTTP status and headers are surfaced before the body streams")
    func responseMetadataIsAvailableUpFront() async throws {
        let server = try ChunkedServer(chunks: ["data: x\n\n"], gap: 0.05)
        defer { server.shutdown() }

        let transport = URLSessionStreamingTransport()
        let result = try await transport.bytes(for: makeRequest(port: server.port))
        let stream = result.body

        let http = try #require(result.response as? HTTPURLResponse)
        #expect(http.statusCode == 200)
        // Status must be known before draining, so error responses can be
        // detected without consuming the whole body.
        #expect(
            (http.value(forHTTPHeaderField: "Content-Type") ?? "")
                .contains("text/event-stream")
        )

        for try await _ in stream {}
    }
}
