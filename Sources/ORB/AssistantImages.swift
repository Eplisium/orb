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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(images) { image in
                AssistantImageCard(image: image, accent: accent)
            }
        }
    }
}

private struct AssistantImageCard: View {
    let image: ChatImageAttachment
    let accent: Color

    @State private var nsImage: NSImage?
    @State private var isLoading = true
    @State private var showSaved = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Group {
                if let nsImage {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 480, maxHeight: 360)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
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

            HStack(spacing: 8) {
                if let prompt = image.prompt, !prompt.isEmpty {
                    Text(prompt)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
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
