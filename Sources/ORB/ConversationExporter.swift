import AppKit
import Foundation
import UniformTypeIdentifiers

/// One exporter for Chat and Agent conversations (Markdown and JSON).
/// Includes timestamps, reasoning, tool calls, and per-reply usage. Binary
/// payloads (attachments, inline images) are referenced, never embedded.
enum ConversationExporter {
    enum Format {
        case markdown, json

        var fileExtension: String { self == .markdown ? "md" : "json" }
        var contentType: UTType { self == .markdown ? (UTType(filenameExtension: "md") ?? .plainText) : .json }
    }

    static func export(_ conversation: ChatConversation, as format: Format) throws -> Data {
        switch format {
        case .markdown: return Data(markdown(conversation).utf8)
        case .json: return try json(conversation)
        }
    }

    // MARK: Markdown

    static func markdown(_ conv: ChatConversation) -> String {
        var md = "# \(conv.title)\n\n"
        md += "**Model:** \(conv.modelId)  \n"
        md += "**Mode:** \(conv.mode.rawValue)  \n"
        md += "**Date:** \(conv.createdAt.formatted())  \n"
        if conv.totalTokens > 0 { md += "**Tokens:** \(conv.totalTokens)  \n" }
        if conv.totalCost > 0 { md += "**Cost:** $\(String(format: "%.4f", conv.totalCost))  \n" }
        if !conv.systemPrompt.isEmpty { md += "\n**System prompt:**\n\n> " + conv.systemPrompt.replacingOccurrences(of: "\n", with: "\n> ") + "\n" }
        md += "\n---\n\n"
        for msg in conv.messages {
            md += "\(label(for: msg)): _\(msg.createdAt.formatted(date: .abbreviated, time: .standard))_\n\n"
            if let reasoning = msg.reasoning, !reasoning.isEmpty {
                let seconds = msg.reasoningDuration.map { String(format: " (%.1fs)", $0) } ?? ""
                md += "<details><summary>Reasoning\(seconds)</summary>\n\n\(reasoning)\n\n</details>\n\n"
            }
            md += "\(msg.content)\n"
            if let calls = msg.toolCalls, !calls.isEmpty {
                for call in calls {
                    md += "\n**Tool call** `\(call.name)`\(call.isError ? " (error)" : ""):\n\n```json\n\(call.arguments ?? call.argumentsSummary)\n```\n"
                    if let result = call.result {
                        md += "\nResult:\n\n```\n\(result)\n```\n"
                    }
                }
            }
            if let parts = msg.parts, !parts.isEmpty {
                md += "\n*Attachments: \(parts.count) file(s) — see app to view.*\n"
            }
            if let images = msg.images, !images.isEmpty {
                for (index, image) in images.enumerated() {
                    // Remote URLs embed directly; data URLs would bloat the
                    // file, so reference them by position instead.
                    if image.isRemoteURL {
                        md += "\n![generated image \(index + 1)](\(image.dataURL))\n"
                    } else {
                        md += "\n*[generated image \(index + 1): embedded \(image.mimeType), see app to view]*\n"
                    }
                }
            }
            if msg.status == .failed, let error = msg.errorMessage { md += "\n*Failed: \(error)*\n" }
            if let usage = msg.usage, !usage.summary.isEmpty { md += "\n*\(usage.summary)*\n" }
            md += "\n---\n\n"
        }
        return md
    }

    private static func label(for msg: ChatMessage) -> String {
        switch msg.role {
        case "user": return "**You**"
        case "assistant": return "**Assistant**"
        case "tool": return "**Tool** (\(msg.toolName ?? "unknown"))"
        case "system": return "**System**"
        default: return "**\(msg.role)**"
        }
    }

    // MARK: JSON

    struct ExportedConversation: Codable {
        let title: String
        let model: String
        let mode: String
        let systemPrompt: String
        let createdAt: Date
        let totalTokens: Int
        let totalCost: Double
        let messages: [ExportedMessage]
    }

    struct ExportedMessage: Codable {
        let role: String
        let content: String
        let createdAt: Date
        let status: String
        var reasoning: String?
        var reasoningSeconds: TimeInterval?
        var toolCalls: [ExportedToolCall]?
        var toolName: String?
        var attachments: Int?
        var error: String?
        var usage: MessageUsage?
    }

    struct ExportedToolCall: Codable {
        let name: String
        let arguments: String
        let result: String?
        let isError: Bool
    }

    static func json(_ conv: ChatConversation) throws -> Data {
        let payload = ExportedConversation(
            title: conv.title, model: conv.modelId, mode: conv.mode.rawValue, systemPrompt: conv.systemPrompt,
            createdAt: conv.createdAt, totalTokens: conv.totalTokens, totalCost: conv.totalCost,
            messages: conv.messages.map { msg in
                ExportedMessage(
                    role: msg.role, content: msg.content, createdAt: msg.createdAt, status: msg.status.rawValue,
                    reasoning: msg.reasoning?.isEmpty == false ? msg.reasoning : nil,
                    reasoningSeconds: msg.reasoningDuration,
                    toolCalls: msg.toolCalls.flatMap { calls in
                        calls.isEmpty ? nil : calls.map {
                            ExportedToolCall(name: $0.name, arguments: $0.arguments ?? $0.argumentsSummary,
                                             result: $0.result, isError: $0.isError)
                        }
                    },
                    toolName: msg.toolName,
                    attachments: msg.parts.flatMap { $0.isEmpty ? nil : $0.count },
                    error: msg.errorMessage,
                    usage: msg.usage
                )
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(payload)
    }

    // MARK: Save panel

    /// Asks for a destination and writes the export. Returns an error message
    /// for the caller to surface, or nil on success/cancel.
    @MainActor
    static func saveWithPanel(_ conversation: ChatConversation, as format: Format) -> String? {
        let panel = NSSavePanel()
        panel.title = format == .markdown ? "Export Conversation" : "Export Conversation as JSON"
        panel.nameFieldStringValue = "\(conversation.title).\(format.fileExtension)"
        panel.allowedContentTypes = [format.contentType]
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            try export(conversation, as: format).write(to: url, options: .atomic)
            return nil
        } catch {
            return "Could not export conversation: \(error.localizedDescription)"
        }
    }
}
