import Testing
import SwiftUI
import AppKit
@testable import ORB

/// Renders the new chrome in light and dark, at a large text size, and checks
/// each produces a non-blank image. Run separately from timing suites:
/// `swift test --filter ChatChromeRenderTests`.
@MainActor
@Suite("Phase 5 chrome: render smoke", .serialized)
struct ChatChromeRenderTests {
    private func render<V: View>(_ view: V, scheme: ColorScheme) -> NSBitmapImageRep? {
        let renderer = ImageRenderer(content:
            view.environment(\.colorScheme, scheme)
                .background(scheme == .dark ? Color.black : Color.white)
                .frame(width: 460))
        renderer.scale = 1
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation else { return nil }
        return NSBitmapImageRep(data: tiff)
    }

    private func isNotBlank(_ rep: NSBitmapImageRep) -> Bool {
        guard rep.pixelsWide > 10, rep.pixelsHigh > 10 else { return false }
        var seen = Set<UInt32>()
        for x in stride(from: 0, to: rep.pixelsWide, by: 4) {
            for y in stride(from: 0, to: rep.pixelsHigh, by: 4) {
                if let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) {
                    seen.insert(UInt32(c.redComponent * 255) << 16 | UInt32(c.greenComponent * 255) << 8 | UInt32(c.blueComponent * 255))
                }
            }
        }
        return seen.count > 2
    }

    private let request = ApprovalCoordinator.Request(id: UUID(), toolName: "run_command", server: nil, summary: "rm -rf ./build && make")

    @Test("Approval sheet renders in both appearances")
    func approval() {
        for scheme in [ColorScheme.light, .dark] {
            let rep = render(ApprovalSheet(request: request, waiting: 2) { _ in }, scheme: scheme)
            #expect(rep.map(isNotBlank) == true, "\(scheme)")
        }
    }

    @Test("Context gauge renders at every level in both appearances")
    func gauge() {
        for used in [10, 75, 99] {
            let g = ContextGauge(usedTokens: used, contextLength: 100)
            for scheme in [ColorScheme.light, .dark] {
                #expect(render(ContextGaugeView(gauge: g), scheme: scheme).map(isNotBlank) == true)
            }
        }
    }

    @Test("Undo toast, run strip and slash menu render")
    func others() {
        for scheme in [ColorScheme.light, .dark] {
            #expect(render(UndoToastView(message: "Deleted 2 sessions", undo: {}, dismiss: {}), scheme: scheme).map(isNotBlank) == true)
            #expect(render(SlashCommandMenu(entries: SlashCommand.catalog) { _ in }, scheme: scheme).map(isNotBlank) == true)
            let msgs = [ChatMessage(role: "assistant", content: "x")]
            #expect(render(AgentRunStatusStrip(messages: msgs, startedAt: .now, phaseText: "Agent working", cancel: {}), scheme: scheme).map(isNotBlank) == true)
        }
    }

    @Test("Approval sheet stays renderable at a very large text size")
    func largeText() {
        let view = ApprovalSheet(request: request, waiting: 0) { _ in }.environment(\.dynamicTypeSize, .accessibility3)
        #expect(render(view, scheme: .light).map(isNotBlank) == true)
    }
}
