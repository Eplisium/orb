import Foundation

/// Presentation-only chronology. Wire history continues using content and
/// reasoning_details; never send this local display representation upstream.
struct MessageTranscriptSegment: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable { case reasoning, text, tool }
    var id = UUID()
    var kind: Kind
    var text: String = ""
    var toolCallID: String? = nil
}

extension ChatMessage {
    mutating func recordTranscript(_ kind: MessageTranscriptSegment.Kind, text: String) {
        guard !text.isEmpty else { return }
        if transcript == nil { transcript = [] }
        if let last = transcript?.indices.last, transcript?[last].kind == kind {
            transcript?[last].text += text
        } else {
            transcript?.append(.init(kind: kind, text: text))
        }
    }

    mutating func recordTranscriptTool(_ id: String) {
        if transcript == nil { transcript = [] }
        guard transcript?.contains(where: { $0.toolCallID == id }) != true else { return }
        transcript?.append(.init(kind: .tool, toolCallID: id))
    }

    /// Old sessions have no event chronology: keep all their data accessible,
    /// without pretending we can reconstruct interleaving that was not stored.
    var displayTranscript: [MessageTranscriptSegment] {
        if let transcript, !transcript.isEmpty { return transcript }
        var result: [MessageTranscriptSegment] = []
        if let reasoning, !reasoning.isEmpty { result.append(.init(kind: .reasoning, text: reasoning)) }
        for call in toolCalls ?? [] { result.append(.init(kind: .tool, toolCallID: call.id)) }
        if !content.isEmpty { result.append(.init(kind: .text, text: content)) }
        // Deterministic legacy identities; new messages persist their UUIDs.
        for index in result.indices {
            var bytes = id.uuid
            withUnsafeMutableBytes(of: &bytes) { raw in
                raw[14] ^= UInt8(truncatingIfNeeded: index >> 8)
                raw[15] ^= UInt8(truncatingIfNeeded: index)
            }
            result[index].id = UUID(uuid: bytes)
        }
        return result
    }
}
