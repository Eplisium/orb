import AppKit
import SwiftUI

// MARK: - Assistant image rendering
//
// Image-output models return pictures, not just words. This renders them
// inline in the message bubble with save-to-disk support.

/// Loads an `NSImage` from a `ChatImageAttachment` (data URL or remote).
/// Remote images download on demand and cache in memory for the session.
enum AssistantImageLoader {
    private static let cache = NSCache<NSString, NSImage>()

    static func load(_ attachment: ChatImageAttachment) async -> NSImage? {
        if let cached = cache.object(forKey: attachment.dataURL as NSString) {
            return cached
        }
        if let data = attachment.inlineData, let image = NSImage(data: data) {
            cache.setObject(image, forKey: attachment.dataURL as NSString)
            return image
        }
        guard attachment.isRemoteURL, let url = URL(string: attachment.dataURL) else { return nil }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let image = NSImage(data: data) else { return nil }
        cache.setObject(image, forKey: attachment.dataURL as NSString)
        return image
    }
}

struct AssistantImageRow: View {
    let images: [ChatImageAttachment]
    let accent: Color
    var onReusePrompt: ((String) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(images) { image in
                AssistantImageCard(image: image, accent: accent, onReusePrompt: onReusePrompt)
            }
        }
    }
}

private struct AssistantImageCard: View {
    let image: ChatImageAttachment
    let accent: Color
    var onReusePrompt: ((String) -> Void)? = nil

    @State private var nsImage: NSImage?
    @State private var isLoading = true
    @State private var showSaved = false
    @State private var promptExpanded = false
    @State private var promptCopied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Group {
                if let nsImage {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 480, maxHeight: 360)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .contentShape(RoundedRectangle(cornerRadius: 10))
                        .onTapGesture { FullScreenImageViewer.shared.show(nsImage) }
                        .onHover { inside in
                            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                        }
                        .help("Click to view full screen")
                } else if isLoading {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.primary.opacity(0.05))
                        .frame(width: 320, height: 200)
                        .overlay { ProgressView().controlSize(.small) }
                } else {
                    Label("Could not load image", systemImage: "photo.badge.exclamationmark")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(12)
                }
            }
            .task(id: image.id) {
                nsImage = await AssistantImageLoader.load(image)
                isLoading = false
            }

            if let prompt = image.prompt, !prompt.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(prompt)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(promptExpanded ? nil : 2)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture { withAnimation(.easeInOut(duration: 0.15)) { promptExpanded.toggle() } }
                        .help(promptExpanded ? "Click to collapse" : "Click to show the full prompt")
                    HStack(spacing: 10) {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(prompt, forType: .string)
                            promptCopied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { promptCopied = false }
                        } label: {
                            Label(promptCopied ? "Copied" : "Copy prompt",
                                  systemImage: promptCopied ? "checkmark" : "doc.on.doc")
                                .font(.caption2)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(promptCopied ? .green : accent)
                        if let onReusePrompt {
                            Button { onReusePrompt(prompt) } label: {
                                Label("Use prompt", systemImage: "arrow.uturn.left").font(.caption2)
                            }
                            .buttonStyle(.plain).foregroundStyle(accent)
                        }
                    }
                }
            }
            HStack(spacing: 8) {
                Spacer()
                Button {
                    saveImage()
                } label: {
                    Label(showSaved ? "Saved" : "Save", systemImage: showSaved ? "checkmark" : "square.and.arrow.down")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(showSaved ? .green : accent)
                .disabled(nsImage == nil)
            }
        }
    }

    private func saveImage() {
        guard let nsImage else { return }
        let panel = NSSavePanel()
        panel.title = "Save Image"
        panel.nameFieldStringValue = "orb-image.\(image.fileExtension)"
        if panel.runModal() == .OK, let url = panel.url {
            guard let tiff = nsImage.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff) else { return }
            let fileType: NSBitmapImageRep.FileType = image.fileExtension == "jpg" ? .jpeg : .png
            guard let data = rep.representation(using: fileType, properties: [:]) else { return }
            try? data.write(to: url)
            showSaved = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { showSaved = false }
        }
    }
}

// MARK: - Full-screen viewer

/// Opens an image in a native full-screen window. Click or press Esc to close.
@MainActor
final class FullScreenImageViewer: NSObject, NSWindowDelegate {
    static let shared = FullScreenImageViewer()
    private var window: NSWindow?

    func show(_ image: NSImage) {
        if let window { window.close() }
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                           styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                           backing: .buffered, defer: false)
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.backgroundColor = .black
        win.isReleasedWhenClosed = false
        win.collectionBehavior = [.fullScreenPrimary]
        win.delegate = self
        win.contentView = NSHostingView(rootView: FullScreenImageContent(image: image) { [weak self] in
            self?.dismiss()
        })
        win.center()
        window = win
        win.makeKeyAndOrderFront(nil)
        win.toggleFullScreen(nil)
    }

    private func dismiss() {
        guard let window else { return }
        if window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) } else { window.close() }
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        window?.delegate = nil
        window = nil
    }
}

private struct FullScreenImageContent: View {
    let image: NSImage
    let onClose: () -> Void

    var body: some View {
        ZStack {
            Color.black
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .padding(24)
        }
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture { onClose() }
        .onExitCommand { onClose() }
    }
}

// MARK: - Attachment chips (user-picked files, not yet sent)

struct AttachmentDraftChip: View {
    let draft: ChatAttachmentDraft
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: draft.iconName)
                .font(.system(size: 10))
            Text(draft.filename)
                .lineLimit(1)
            Text(draft.typeLabel)
                .font(.system(size: 8, weight: .bold))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Color.primary.opacity(0.08))
                .clipShape(Capsule())
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
        }
        .font(.system(size: 10, weight: .medium))
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(Color.accentColor.opacity(0.10))
        .clipShape(Capsule())
    }
}

/// Attachment count line under sent user messages, so a multimodal turn
/// still reads sensibly when the parts themselves aren't rendered.
struct SentAttachmentsLabel: View {
    let count: Int

    var body: some View {
        Label(
            "\(count) attachment\(count == 1 ? "" : "s")",
            systemImage: "paperclip"
        )
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
    }
}
