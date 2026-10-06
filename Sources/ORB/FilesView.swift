import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Files manager
//
// Remote workspace uploads are separate from locally saved creations.

struct FilesView: View {
    @ObservedObject private var service = StudioServices.shared.files
    @StudioState("FilesView.remoteFiles") private var remoteFiles: [WorkspaceFile] = []
    @StudioState("FilesView.nextCursor") private var nextCursor: String? = nil
    @StudioState("FilesView.hasMore") private var hasMore = false
    @StudioState("FilesView.isFetchingPage") private var isFetchingPage = false
    @StudioState("FilesView.pageError") private var pageError: String? = nil
    @StudioState("FilesView.errorMessage") private var errorMessage: String? = nil
    @State private var showingCreations = false
    @StudioState("FilesView.isUploading") private var isUploading = false
    /// The file awaiting delete confirmation. The service layer refuses an
    /// unconfirmed delete, so the confirmation dialog is the only way the
    /// destructive call is ever issued.
    @State private var pendingDelete: WorkspaceFile?

    private let accent = ORBTheme.accent

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            if showingCreations {
                SavedCreationsLibraryView()
            } else if isFetchingPage && remoteFiles.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if remoteFiles.isEmpty {
                emptyState
            } else {
                fileList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .task { await refreshPages() }
        .onChange(of: showingCreations) { _, selected in
            if !selected { Task { await refreshPages() } }
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
            StudioHeader(title: "Files", subtitle: "Remote uploads · creations stay on this Mac",
                         icon: "folder.fill", accent: accent)
            Picker("Library", selection: $showingCreations) {
                Text("Uploaded files").tag(false)
                Text("Saved creations").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            if !showingCreations && isFetchingPage {
                ProgressView().controlSize(.small)
            } else if !showingCreations {
                Button { Task { await refreshPages() } } label: {
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
            } else if let error = pageError ?? service.lastError {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
            if hasMore {
                Button(isFetchingPage ? "Loading…" : "Load more") { Task { await loadMore() } }
                    .buttonStyle(StudioChipButtonStyle())
                    .disabled(isFetchingPage)
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
                if let error = pageError ?? service.lastError {
                    PlaygroundErrorBanner(message: error) { pageError = nil; service.lastError = nil }
                }
                if let errorMessage {
                    PlaygroundErrorBanner(message: errorMessage) { self.errorMessage = nil }
                }
                ForEach(remoteFiles) { file in
                    fileRow(file)
                }
                if hasMore {
                    Button(isFetchingPage ? "Loading…" : "Load more") { Task { await loadMore() } }
                        .disabled(isFetchingPage)
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
        if panel.runModal() == .OK {
            isUploading = true
            errorMessage = nil
            Task {
                defer { isUploading = false }
                var failures: [String] = []
                for url in panel.urls {
                    do {
                        let scoped = url.startAccessingSecurityScopedResource()
                        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                        let data = try Data(contentsOf: url)
                        let mime = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType?.preferredMIMEType)
                            ?? "application/octet-stream"
                        // Empty/oversized uploads are validated (and rejected
                        // with a clear message) by FileService before any
                        // request is sent.
                        _ = try await service.upload(filename: url.lastPathComponent, mimeType: mime, data: data)
                    } catch is CancellationError {
                        break
                    } catch {
                        failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
                    }
                }
                await refreshPages()
                if !failures.isEmpty { errorMessage = failures.joined(separator: "\n") }
            }
        }
    }

    private func delete(_ file: WorkspaceFile) {
        Task {
            do {
                // Reached only through the confirmation dialog; the service
                // refuses an unconfirmed delete outright.
                _ = try await service.delete(id: file.id, confirming: true)
                remoteFiles.removeAll { $0.id == file.id }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func refreshPages() async {
        guard !isFetchingPage else { return }
        isFetchingPage = true
        defer { isFetchingPage = false }
        do {
            let page = try await service.listPage()
            remoteFiles = page.data
            nextCursor = page.cursor
            hasMore = page.hasMore == true && page.cursor != nil
            pageError = page.hasMore == true && page.cursor == nil ? "More files reported without a cursor; cannot continue safely." : nil
        } catch is CancellationError { }
        catch { pageError = error.localizedDescription }
    }

    private func loadMore() async {
        guard hasMore, let cursor = nextCursor, !isFetchingPage else { return }
        isFetchingPage = true
        defer { isFetchingPage = false }
        do {
            let page = try await service.listPage(cursor: cursor)
            let known = Set(remoteFiles.map(\.id))
            remoteFiles += page.data.filter { !known.contains($0.id) }
            nextCursor = page.cursor
            hasMore = page.hasMore == true && page.cursor != nil && page.cursor != cursor
            pageError = page.hasMore == true && !hasMore ? "Pagination returned no new cursor; stopped to avoid a loop." : nil
        } catch is CancellationError { }
        catch { pageError = error.localizedDescription }
    }
}
