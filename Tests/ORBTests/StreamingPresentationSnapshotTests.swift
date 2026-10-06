import AppKit
import Foundation
import SwiftUI
import Testing
@testable import ORB

/// Offline visual fixture: set ORB_STREAM_SNAPSHOT_DIR to write PNGs. It never
/// reads Keychain, opens the production database, or calls OpenRouter.
/// ImageRenderer may omit selectable text inside nested ScrollViews (reasoning
/// and code bodies); inspect those in the real app after unlock.
@Suite("Streaming presentation snapshots")
@MainActor
struct StreamingPresentationSnapshotTests {
    @Test(
        "Chat and Agent streaming states render without a live account",
        .enabled(
            if: ProcessInfo.processInfo.environment["ORB_STREAM_SNAPSHOT_DIR"] != nil,
            "Rendering snapshot; set ORB_STREAM_SNAPSHOT_DIR=<dir> and run this suite alone"
        )
    )
    func renderFixtures() throws {
        let directory = try #require(ProcessInfo.processInfo.environment["ORB_STREAM_SNAPSHOT_DIR"])
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)

        let thinking = ChatMessage(
            role: "assistant", content: "", status: .streaming,
            reasoning: "Let me compare the constraints and work through the options before answering.\nA shorter path is likely more reliable.",
            reasoningStartedAt: Date().addingTimeInterval(-8)
        )
        let answer = ChatMessage(
            role: "assistant",
            content: "## A clear answer\n\nThe result arrives **as it is generated**, with readable prose and calm spacing.\n\n- First useful detail\n- Second useful detail\n\n```swift\nlet stream = updates.map(\\.content)\nprint(stream)\n```\n\nThe next sentence is still arriv",
            status: .streaming, reasoning: "I checked the constraints before answering.",
            reasoningStartedAt: Date().addingTimeInterval(-7), reasoningDuration: 7
        )
        var tool = ChatMessage(
            role: "assistant", content: "I will check the project first.\n\nHere is what I found so far.",
            toolCalls: [ToolCallDisplay(id: "fixture-call", name: "read_file", argumentsSummary: "{\"path\":\"Sources/ORB/ChatView.swift\"}", arguments: "{\"path\":\"Sources/ORB/ChatView.swift\"}", result: "Read Sources/ORB/ChatView.swift", isError: false, isExecuting: false)],
            status: .streaming
        )

        tool.reasoning = "I should inspect the message renderer, then verify the result."
        tool.recordTranscript(.reasoning, text: tool.reasoning ?? "")
        tool.recordTranscript(.text, text: "I will check the project first.")
        tool.recordTranscriptTool("fixture-call")
        tool.recordTranscript(.text, text: "Here is what I found so far.")

        try save(
            VStack(alignment: .leading, spacing: 24) {
                Text("CHAT · THINKING").font(.caption).foregroundStyle(.secondary)
                PlaygroundMessageView(message: thinking, isStreaming: true, assistantName: "Assistant", accent: PlaygroundTheme.chatAccent, isReasoning: true)
                Text("CHAT · ANSWERING").font(.caption).foregroundStyle(.secondary)
                PlaygroundMessageView(message: answer, isStreaming: true, assistantName: "Assistant", accent: PlaygroundTheme.chatAccent)
                HStack { ActivityPulseOrb(accent: PlaygroundTheme.chatAccent, isActive: true).scaleEffect(0.5).frame(width: 16, height: 16); Text("Streaming…").foregroundStyle(.secondary) }
                Spacer(minLength: 0)
            },
            name: "chat-streaming.png", directory: directory
        )
        try save(
            VStack(alignment: .leading, spacing: 22) {
                Text("AGENT · WORKING").font(.caption).foregroundStyle(.secondary)
                PlaygroundMessageView(message: ChatMessage(role: "user", content: "Make reasoning, tool activity, and answers read as one conversation."), isStreaming: false, assistantName: "You", accent: PlaygroundTheme.agentAccent)
                PlaygroundMessageView(message: tool, isStreaming: true, assistantName: "OpenRouter Agent", accent: PlaygroundTheme.agentAccent, showToolCalls: true)
                HStack { ActivityPulseOrb(accent: PlaygroundTheme.agentAccent, isActive: true).scaleEffect(0.5).frame(width: 16, height: 16); Text("Writing response… · 8s · 1 tool call").foregroundStyle(.secondary) }
                Spacer(minLength: 0)
            },
            name: "agent-streaming.png", directory: directory
        )
    }

    private func save<Content: View>(_ content: Content, name: String, directory: String) throws {
        for scheme in [ColorScheme.light, .dark] {
        let canvas = ZStack(alignment: .topLeading) {
            Color(nsColor: .windowBackgroundColor)
            content.padding(28)
        }
        .frame(width: 850, height: 650)
        .environment(\.colorScheme, scheme)
        let renderer = ImageRenderer(content: canvas)
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        let tiff = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiff))
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        let variant = (scheme == .dark ? "dark-" : "light-") + name
        try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent(variant))
        }
    }
}

