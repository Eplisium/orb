import Foundation

struct OpenRouterAPIError: Error, Equatable, Sendable {
    let code: Int?
    let message: String
    let errorType: String?
    let providerName: String?
}

enum OpenRouterStreamEvent: Equatable, Sendable {
    case contentDelta(choiceIndex: Int, text: String)
    case reasoningDelta(choiceIndex: Int, text: String)
    /// Structured `reasoning_details` blocks streamed in this chunk, in wire
    /// order. Opaque signature/encrypted payloads ride here so they can
    /// round-trip for tool continuation without ever being rendered as text.
    case reasoningDetails(choiceIndex: Int, details: [ReasoningDetail])
    /// One assistant image (`images` entry) streamed or delivered whole.
    case imageDelta(choiceIndex: Int, imageURL: String)
    case toolCallFragment(
        choiceIndex: Int,
        toolIndex: Int,
        id: String?,
        type: String?,
        name: String?,
        arguments: String?
    )
    case usage(ChatUsage)
    case finishReason(choiceIndex: Int, reason: String)
    case apiError(OpenRouterAPIError)
    case metadata(id: String?, model: String?)
    case done
}

enum OpenRouterStreamError: Error, Equatable, LocalizedError {
    case malformedEvent(String)
    case eventTooLarge(limit: Int)
    case incompleteEventAtEOF(String)

    var errorDescription: String? {
        switch self {
        case .malformedEvent(let raw): return "Malformed OpenRouter stream event: \(raw)"
        case .eventTooLarge(let limit): return "OpenRouter stream event exceeded \(limit) bytes."
        case .incompleteEventAtEOF(let raw): return "OpenRouter stream ended inside an event: \(raw)"
        }
    }
}

/// Incremental SSE decoder. It operates on bytes so network fragments may split
/// UTF-8 scalars without ever producing replacement characters.
struct ServerSentEventDecoder {
    private var pending = Data()
    private var previousWasCR = false
    private var dataLines: [Data] = []
    private var eventBytes = 0
    private let maxEventBytes: Int
    private let diagnosticLimit: Int

    init(maxEventBytes: Int = 1_048_576, diagnosticLimit: Int = 512) {
        self.maxEventBytes = maxEventBytes
        self.diagnosticLimit = diagnosticLimit
    }

    mutating func consume<S: DataProtocol>(_ fragment: S) throws -> [OpenRouterStreamEvent] {
        var output: [OpenRouterStreamEvent] = []
        // Process the chunk as it arrives rather than checking its total size:
        // one URLSession delivery can contain many individually small events.
        // A complete line is only materialized once, not rescanned per byte.
        for byte in fragment {
            if byte == 0x0A && previousWasCR {
                previousWasCR = false // CRLF is one line ending, even across chunks
                continue
            }
            if byte == 0x0D || byte == 0x0A {
                previousWasCR = byte == 0x0D
                output += try finishLine()
            } else {
                previousWasCR = false
                pending.append(byte)
                // Count comments and unknown fields too; a malicious keepalive
                // must not grow indefinitely without emitting a data event.
                guard pending.count <= maxEventBytes - eventBytes else {
                    throw OpenRouterStreamError.eventTooLarge(limit: maxEventBytes)
                }
            }
        }
        return output
    }

    private mutating func finishLine() throws -> [OpenRouterStreamEvent] {
        let line = pending
        pending.removeAll(keepingCapacity: true)
        if line.isEmpty {
            defer {
                dataLines.removeAll(keepingCapacity: true)
                eventBytes = 0
            }
            return dataLines.isEmpty ? [] : try decodeCurrentEvent()
        }
        eventBytes += line.count + 1
        guard eventBytes <= maxEventBytes else {
            throw OpenRouterStreamError.eventTooLarge(limit: maxEventBytes)
        }
        if line.first == 0x3A { return [] } // comment / keepalive
        let prefix = Data("data:".utf8)
        guard line.starts(with: prefix) else { return [] }
        var value = Data(line.dropFirst(prefix.count))
        if value.first == 0x20 { value.removeFirst() }
        dataLines.append(value)
        return []
    }

    mutating func finish() throws -> [OpenRouterStreamEvent] {
        guard pending.isEmpty, dataLines.isEmpty else {
            let raw = diagnostic(Data(dataLines.joined(separator: Data([0x0A]))) + pending)
            throw OpenRouterStreamError.incompleteEventAtEOF(raw)
        }
        return []
    }

    private mutating func decodeCurrentEvent() throws -> [OpenRouterStreamEvent] {
        let payload = Data(dataLines.joined(separator: Data([0x0A])))
        if payload == Data("[DONE]".utf8) { return [.done] }
        do {
            let envelope = try JSONDecoder().decode(StreamEnvelope.self, from: payload)
            if let error = envelope.error {
                return [.apiError(.init(
                    code: error.code,
                    message: error.message,
                    errorType: error.metadata?.errorType,
                    providerName: error.metadata?.providerName
                ))]
            }

            var events: [OpenRouterStreamEvent] = []
            for choice in envelope.choices ?? [] {
                // One provider chunk may contain the last reasoning token and
                // the first answer token together. Emit reasoning first so the
                // active thinking span freezes on the answer, not afterward.
                if let reasoning = choice.delta?.reasoningText, !reasoning.isEmpty {
                    events.append(.reasoningDelta(choiceIndex: choice.index ?? 0, text: reasoning))
                }
                // F07: carry the full structured array through the stream in
                // wire order, alongside the flattened display text above.
                if let details = choice.delta?.reasoningDetails, !details.isEmpty {
                    events.append(.reasoningDetails(choiceIndex: choice.index ?? 0, details: details))
                }
                if let content = choice.delta?.content, !content.isEmpty {
                    events.append(.contentDelta(choiceIndex: choice.index ?? 0, text: content))
                }
                for image in choice.delta?.images ?? [] where !image.url.isEmpty {
                    events.append(.imageDelta(choiceIndex: choice.index ?? 0, imageURL: image.url))
                }
                for tool in choice.delta?.toolCalls ?? [] {
                    events.append(.toolCallFragment(
                        choiceIndex: choice.index ?? 0,
                        toolIndex: tool.index,
                        id: tool.id,
                        type: tool.type,
                        name: tool.function?.name,
                        arguments: tool.function?.arguments
                    ))
                }
                if let finish = choice.finishReason {
                    events.append(.finishReason(choiceIndex: choice.index ?? 0, reason: finish))
                }
            }
            if let usage = envelope.usage { events.append(.usage(usage)) }
            if events.isEmpty { events.append(.metadata(id: envelope.id, model: envelope.model)) }
            return events
        } catch {
            throw OpenRouterStreamError.malformedEvent(diagnostic(payload))
        }
    }

    private func diagnostic(_ bytes: Data) -> String {
        String(decoding: bytes.prefix(diagnosticLimit), as: UTF8.self)
    }
}

private struct StreamEnvelope: Decodable {
    let id: String?
    let model: String?
    let choices: [StreamChoice]?
    let usage: ChatUsage?
    let error: StreamAPIError?
}

private struct StreamChoice: Decodable {
    let index: Int?
    let delta: StreamDelta?
    let finishReason: String?

    enum CodingKeys: String, CodingKey {
        case index, delta
        case finishReason = "finish_reason"
    }
}

private struct StreamDelta: Decodable {
    let content: String?
    /// Plain-text chain-of-thought (`reasoning: "…"` string, older providers).
    let reasoning: String?
    /// Structured chain-of-thought blocks (`reasoning_details: [...]`,
    /// newer providers like Meta responses-style models). Decoded as typed
    /// values so opaque signature/encrypted payloads survive intact (F07).
    let reasoningDetails: [ReasoningDetail]?
    let toolCalls: [StreamToolFragment]?
    /// Assistant images streamed alongside text (`images: [...]`).
    let images: [AssistantImagePart]?

    enum CodingKeys: String, CodingKey {
        case content, reasoning, images
        case reasoningDetails = "reasoning_details"
        case toolCalls = "tool_calls"
    }

    /// Providers disagree on where the thinking text lives. Prefer the plain
    /// `reasoning` field, then fall back to the detail blocks (newest last).
    ///
    /// Only human-readable text/summary blocks are surfaced — signature and
    /// encrypted payloads are opaque wire state and must never leak into the
    /// visible reasoning summary (F07).
    var reasoningText: String? {
        if let reasoning, !reasoning.isEmpty { return reasoning }
        guard let reasoningDetails else { return nil }
        // Walk newest-first so the latest thinking wins.
        for detail in reasoningDetails.reversed() {
            if let text = detail.displayText { return text }
        }
        return nil
    }
}

private struct StreamToolFragment: Decodable {
    let index: Int
    let id: String?
    let type: String?
    let function: StreamFunctionFragment?
}

private struct StreamFunctionFragment: Decodable {
    let name: String?
    let arguments: String?
}

private struct StreamAPIError: Decodable {
    let code: Int?
    let message: String
    let metadata: StreamErrorMetadata?
}

private struct StreamErrorMetadata: Decodable {
    let errorType: String?
    let providerName: String?

    enum CodingKeys: String, CodingKey {
        case errorType = "error_type"
        case providerName = "provider_name"
    }
}
