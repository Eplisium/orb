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
    private var dataLines: [Data] = []
    private var eventBytes = 0
    private let maxEventBytes: Int
    private let diagnosticLimit: Int

    init(maxEventBytes: Int = 1_048_576, diagnosticLimit: Int = 512) {
        self.maxEventBytes = maxEventBytes
        self.diagnosticLimit = diagnosticLimit
    }

    mutating func consume<S: DataProtocol>(_ fragment: S) throws -> [OpenRouterStreamEvent] {
        pending.append(contentsOf: fragment)
        guard pending.count <= maxEventBytes - eventBytes + 1 else {
            throw OpenRouterStreamError.eventTooLarge(limit: maxEventBytes)
        }

        var output: [OpenRouterStreamEvent] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            var line = Data(pending[..<newline])
            pending.removeSubrange(...newline)
            if line.last == 0x0D { line.removeLast() }

            if line.isEmpty {
                if !dataLines.isEmpty {
                    output += try decodeCurrentEvent()
                    dataLines.removeAll(keepingCapacity: true)
                    eventBytes = 0
                }
                continue
            }
            if line.first == 0x3A { continue } // comment / keepalive

            let prefix = Data("data:".utf8)
            guard line.starts(with: prefix) else { continue }
            var value = Data(line.dropFirst(prefix.count))
            if value.first == 0x20 { value.removeFirst() }
            eventBytes += value.count + (dataLines.isEmpty ? 0 : 1)
            guard eventBytes <= maxEventBytes else {
                throw OpenRouterStreamError.eventTooLarge(limit: maxEventBytes)
            }
            dataLines.append(value)
        }
        return output
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
                if let content = choice.delta?.content, !content.isEmpty {
                    events.append(.contentDelta(choiceIndex: choice.index ?? 0, text: content))
                }
                if let reasoning = choice.delta?.reasoningText, !reasoning.isEmpty {
                    events.append(.reasoningDelta(choiceIndex: choice.index ?? 0, text: reasoning))
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
    /// Plain-text chain-of-thought (`reasoning: "…"`, older providers).
    let reasoning: String?
    /// Structured chain-of-thought (`reasoning_details: [{text|summary}]`,
    /// newer providers like Meta responses-style models).
    let reasoningDetails: [StreamReasoningDetail]?
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
    var reasoningText: String? {
        if let reasoning, !reasoning.isEmpty { return reasoning }
        guard let reasoningDetails else { return nil }
        // Walk newest-first so the latest thinking wins.
        for detail in reasoningDetails.reversed() {
            if let text = detail.text, !text.isEmpty { return text }
            if let summary = detail.summary, !summary.isEmpty { return summary }
            if let data = detail.data, !data.isEmpty { return data }
        }
        return nil
    }
}

/// One entry of a `reasoning_details` array. Seen shapes: `{type, text}`,
/// `{type, summary}`, `{type, data}`. Unknown extra keys are ignored.
private struct StreamReasoningDetail: Decodable {
    let text: String?
    let summary: String?
    let data: String?

    enum CodingKeys: String, CodingKey { case text, summary, data }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // `text`/`summary`/`data` may arrive as a string or, on some
        // providers, as a nested object — coerce only plain strings.
        text = (try? container.decodeIfPresent(String.self, forKey: .text)) ?? nil
        summary = (try? container.decodeIfPresent(String.self, forKey: .summary)) ?? nil
        data = (try? container.decodeIfPresent(String.self, forKey: .data)) ?? nil
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
