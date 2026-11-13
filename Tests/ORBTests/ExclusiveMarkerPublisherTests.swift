import Foundation
import Testing
@testable import ORB

@Suite("Exclusive binding marker publication")
struct ExclusiveMarkerPublisherTests {
    private enum Fault: Error { case interrupted }

    private func fixture() throws -> URL {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory())
            .appendingPathComponent("orb-marker-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("Interrupted staging never exposes a partial final marker and retry succeeds")
    func interruptedWrite() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent(".orb-catalog")
        let expected = Data("complete-catalog-identity".utf8)
        var writtenURL: URL?
        #expect(throws: Fault.self) {
            try ExclusiveMarkerPublisher.publish(expected, to: marker, write: { data, url in
                writtenURL = url
                try Data(data.prefix(3)).write(to: url)
                throw Fault.interrupted
            })
        }
        let staged = try #require(writtenURL)
        #expect(staged != marker)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        #expect(!FileManager.default.fileExists(atPath: staged.path))
        try ExclusiveMarkerPublisher.publish(expected, to: marker)
        #expect(try Data(contentsOf: marker) == expected)
    }

    @Test("Exclusive-install failure cleans staging and remains retryable")
    func interruptedInstall() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent(".orb-assets")
        let expected = Data("complete-assets-identity".utf8)
        var stagedURL: URL?
        #expect(throws: Fault.self) {
            try ExclusiveMarkerPublisher.publish(expected, to: marker, install: { staged, final in
                stagedURL = staged
                #expect(final == marker)
                #expect(try Data(contentsOf: staged) == expected)
                throw Fault.interrupted
            })
        }
        let staged = try #require(stagedURL)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        #expect(!FileManager.default.fileExists(atPath: staged.path))
        try ExclusiveMarkerPublisher.publish(expected, to: marker)
        #expect(try Data(contentsOf: marker) == expected)
    }

    @Test("A competing final marker is never overwritten")
    func competingOwner() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent(".orb-catalog")
        let other = Data("other-owner".utf8)
        #expect(throws: Error.self) {
            try ExclusiveMarkerPublisher.publish(Data("our-owner".utf8), to: marker, install: { staged, final in
                try other.write(to: final, options: .withoutOverwriting)
                try FileManager.default.linkItem(at: staged, to: final)
            })
        }
        #expect(try Data(contentsOf: marker) == other)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == [marker.lastPathComponent])
    }

    @Test("Identical existing markers succeed but malformed or foreign markers stay untouched")
    func existingMarker() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent(".orb-assets")
        let expected = Data("same-owner".utf8)
        try expected.write(to: marker)
        try ExclusiveMarkerPublisher.publish(expected, to: marker)
        try Data().write(to: marker)
        #expect(throws: Error.self) { try ExclusiveMarkerPublisher.publish(expected, to: marker) }
        #expect(try Data(contentsOf: marker).isEmpty)
    }
}
