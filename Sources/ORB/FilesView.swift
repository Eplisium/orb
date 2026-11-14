import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Files manager
//
// Remote workspace uploads are separate from locally saved creations.

struct FilesView: View {
    @ObservedObject private var service = StudioServices.shared.files
    @ObservedObject private var listing = StudioServices.shared.remoteFileList
    @StudioState("FilesView.errorMessage") private var errorMessage: String? = nil
    // Shared so "Show all in Library" from a studio can open the Library tab.
    // The local Library is the default (STUDIO-11): it needs no network and
    // no key, and holds everything the user generated.
    @StudioState(FilesViewDefaults.showingCreationsKey) private var showingCreations = FilesViewDefaults.showsLibraryFirst
    @StudioState("FilesView.isUploading") private var isUploading = false
    /// The file awaiting delete confirmation. The service layer refuses an
    /// unconfirmed delete, so the confirmation dialog is the only way the
    /// destructive call is ever issued.
    @State private var pendingDelete: WorkspaceFile?
    @State private var dropTargeted = false

    private let accent = ORBTheme.accent

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            if showingCreations {
                SavedCreationsLibraryView()
            } else if listing.isFetchingPage && listing.files.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if listing.files.isEmpty {
                emptyState.studioFileDrop(kind: .anyFile, isTargeted: $dropTargeted) { upload($0) }
            } else {
                fileList.studioFileDrop(kind: .anyFile, isTargeted: $dropTargeted) { upload($0) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        // Remote uploads are fetched only when that tab is shown (STUDIO-11).
        .task { if FilesViewDefaults.shouldFetchRemote(showingCreations: showingCreations) { await listing.refresh() } }
        .onChange(of: showingCreations) { _, selected in
            if !selected { Task { await listing.refresh() } }
        }
        .confirmationDialog(
            "Delete “\(pendingDelete?.filename ?? pendingDelete?.id ?? "")”? This cannot be undone.",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete File", role: .destructive) {
                if let file = pendingDelete { delete(file) }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("The remote file is removed and chat references to it stop working. Local creations are unaffected.")
        }
    }

    private var headerBar: some View {
        HStack(spacing: 12) {
            StudioHeader(title: showingCreations ? "Library" : "Files",
                         subtitle: showingCreations ? "Everything you created · stored on this Mac"
                                                    : "Remote uploads for chat · drop files here to upload",
                         icon: showingCreations ? "square.stack.fill" : "folder.fill", accent: accent)
            Picker("Library", selection: $showingCreations) {
                Text("Library").tag(true)
                Text("Uploaded files").tag(false)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            if !showingCreations && listing.isFetchingPage {
                ProgressView().controlSize(.small)
            } else if !showingCreations {
                Button { Task { await listing.refresh() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("Refresh files")
            }
            if !showingCreations {
                Button(action: upload) {
                    Label(isUploading ? "Uploading…" : "Upload", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(StudioChipButtonStyle())
                .disabled(isUploading || !KeychainManager.hasAPIKey)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
        .background(.ultraThinMaterial.opacity(0.45))
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            StudioEmptyState(icon: "tray", title: "No remote uploads yet",
                             message: "Upload files (max 100 MiB) to reference them in chat. Uploaded files cannot be downloaded through the OpenRouter Files API; keep your original. Generated media is in Saved creations.",
                             accent: accent)
            if let errorMessage {
                PlaygroundErrorBanner(message: errorMessage) { self.errorMessage = nil }
                    .frame(maxWidth: 520)
            } else if let error = listing.pageError ?? service.lastError {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
            if listing.hasMore {
                Button(listing.isFetchingPage ? "Loading…" : "Load more") { Task { await listing.loadMore() } }
                    .buttonStyle(StudioChipButtonStyle())
                    .disabled(listing.isFetchingPage)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var fileList: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                Text("Showing loaded remote files. Uploads are chat references, not backups: uploaded content cannot be downloaded through the Files API. Keep your originals.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let error = listing.pageError ?? service.lastError {
                    PlaygroundErrorBanner(message: error) { listing.pageError = nil; service.lastError = nil }
                }
                if let errorMessage {
                    PlaygroundErrorBanner(message: errorMessage) { self.errorMessage = nil }
                }
                ForEach(listing.files) { file in
                    fileRow(file)
                }
                if listing.hasMore {
                    Button(listing.isFetchingPage ? "Loading…" : "Load more") { Task { await listing.loadMore() } }
                        .disabled(listing.isFetchingPage)
                }
            }
            .padding(16)
        }
    }

    private func fileRow(_ file: WorkspaceFile) -> some View {
        HStack(spacing: 12) {
            Image(systemName: iconName(for: file))
                .orbFont(size: 14)
                .foregroundStyle(accent)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.filename ?? file.id)
                    .orbFont(size: 12, weight: .medium)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Text(file.id).orbFont(size: 11, design: .monospaced).foregroundStyle(.tertiary)
                    if let bytes = file.sizeBytes {
                        Text(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            Button {
                AppToasts.copy(file.id, what: "File ID")
            } label: {
                Image(systemName: "doc.on.doc").font(.caption)
            }
            .buttonStyle(.plain)
            .help("Copy file ID")
            Button(role: .destructive) { pendingDelete = file } label: {
                Image(systemName: "trash").font(.caption)
            }
            .buttonStyle(.plain)
            .help("Delete file")
        }
        .padding(12)
        .background(.orbSurface(0.035), in: RoundedRectangle(cornerRadius: 11))
        .overlay { RoundedRectangle(cornerRadius: 11).stroke(.orbSurface(0.07), lineWidth: 0.5) }
    }

    private func iconName(for file: WorkspaceFile) -> String {
        let mime = file.mimeType ?? ""
        if mime.hasPrefix("image/") { return "photo" }
        if mime.hasPrefix("audio/") { return "waveform" }
        if mime == "application/pdf" { return "doc.richtext" }
        if mime.hasPrefix("text/") || mime.contains("json") || mime.contains("csv") { return "doc.text" }
        return "doc"
    }

    private func upload() {
        let panel = NSOpenPanel()
        panel.title = "Upload File"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { upload(panel.urls) }
    }

    /// Uploads picked or dropped files (STUDIO-14) one at a time.
    private func upload(_ urls: [URL]) {
        guard !isUploading, KeychainManager.hasAPIKey, !urls.isEmpty else { return }
        isUploading = true
        errorMessage = nil
        Task {
            defer { isUploading = false }
            var failures: [String] = []
            for url in urls {
                do {
                    // Size from metadata first: never read an oversized file.
                    try LocalFilePreflight.check(url, limit: FileService.maxUploadBytes, purpose: "upload")
                    // Read off the main actor (STUDIO-10).
                    let data = try await LocalFileRead.data(at: url)
                    let mime = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType?.preferredMIMEType)
                        ?? "application/octet-stream"
                    // Empty/oversized uploads are validated (and rejected
                    // with a clear message) by FileService before any
                    // request is sent.
                    _ = try await listing.upload(filename: url.lastPathComponent, mimeType: mime, data: data)
                } catch is CancellationError {
                    break
                } catch {
                    failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
            if !failures.isEmpty { errorMessage = failures.joined(separator: "\n") }
        }
    }

    private func delete(_ file: WorkspaceFile) {
        Task {
            do {
                // Reached only through the confirmation dialog; the service
                // refuses an unconfirmed delete outright.
                try await listing.delete(id: file.id, confirming: true)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// Files/Library tab defaults (STUDIO-11), separated for tests.
enum FilesViewDefaults {
    static let showingCreationsKey = "FilesView.showingCreations"
    static let showsLibraryFirst = true
    static func shouldFetchRemote(showingCreations: Bool) -> Bool { !showingCreations }
}
