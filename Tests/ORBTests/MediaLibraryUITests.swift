import Foundation
import Testing
@testable import ORB

@Suite("Media library presentation")
struct MediaLibraryUITests {
    @Test("Rerank indices resolve against submitted documents, including filtered lines")
    func rankedDocuments() {
        let submitted = ["First", "Third", "Second"]
        #expect(rankedDocument(index: 2, in: submitted) == "Second")
        #expect(rankedDocument(index: 0, in: submitted) == "First")
        #expect(rankedDocument(index: -1, in: submitted) == nil)
        #expect(rankedDocument(index: 3, in: submitted) == nil)
    }

    @Test("Local export extension reflects stored MIME type")
    func exportNames() {
        func creation(_ mime: String) -> SavedCreation {
            SavedCreation(id: UUID(), kind: .audio, modelID: "test", prompt: nil,
                          mimeType: mime, createdAt: Date(), assetPath: "", checksum: "")
        }
        #expect(creationExtension(creation("audio/mpeg; charset=binary")) == "mp3")
        #expect(creationExtension(creation("audio/wav")) == "wav")
        #expect(creationExtension(creation("video/mp4")) == "mp4")
        #expect(creationExtension(creation("application/json")) == "json")
        #expect(creationExtension(creation("text/plain")) == "txt")
    }
}
