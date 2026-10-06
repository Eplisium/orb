import Foundation
import Testing
@testable import ORB

@Suite("Local file size preflight")
struct LocalFilePreflightTests {
    private func sparseFile(bytes: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("orb-preflight-\(UUID())")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        // Sparse: sets the size without writing (or reading) the bytes.
        try handle.truncate(atOffset: UInt64(bytes))
        try handle.close()
        return url
    }

    @Test("oversized files are rejected from metadata alone")
    func oversized() throws {
        let url = try sparseFile(bytes: LocalFilePreflight.maxTranscriptionBytes + 1)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try LocalFilePreflight.size(of: url) == LocalFilePreflight.maxTranscriptionBytes + 1)
        #expect(throws: MediaServiceError.self) {
            try LocalFilePreflight.check(url, limit: LocalFilePreflight.maxTranscriptionBytes, purpose: "transcription")
        }
        let upload = try sparseFile(bytes: FileService.maxUploadBytes + 1)
        defer { try? FileManager.default.removeItem(at: upload) }
        #expect(throws: MediaServiceError.self) {
            try LocalFilePreflight.check(upload, limit: FileService.maxUploadBytes, purpose: "upload")
        }
    }

    @Test("limit-sized files pass; empty files and directories fail")
    func boundaries() throws {
        let ok = try sparseFile(bytes: 1024)
        defer { try? FileManager.default.removeItem(at: ok) }
        #expect(try LocalFilePreflight.check(ok, limit: 1024, purpose: "upload") == 1024)
        let empty = try sparseFile(bytes: 0)
        defer { try? FileManager.default.removeItem(at: empty) }
        #expect(throws: MediaServiceError.self) { try LocalFilePreflight.check(empty, limit: 10, purpose: "upload") }
        #expect(throws: (any Error).self) {
            try LocalFilePreflight.check(FileManager.default.temporaryDirectory, limit: .max, purpose: "upload")
        }
    }
}
