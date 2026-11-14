import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

/// Catalog absence is not the same as a model explicitly lacking a capability.
enum CatalogCapability: Equatable {
    case unknown, supported, unsupported

    static func voice(for model: GenerateCatalogModel?) -> Self {
        guard let voices = model?.supportedVoices else { return .unknown }
        return voices.isEmpty ? .unsupported : .supported
    }
}

@MainActor
@Observable final class ModalityModelChoices {
    private(set) var models: [GenerateCatalogModel] = []
    private(set) var isLoading = false
    private(set) var error: String?
    private let catalog: GenerateModelCatalog
    /// Discovery belongs to this model, not to a transient SwiftUI task.
    private var loadTask: Task<Void, Never>?
    private var loadingModality: String?
    /// Modality of the last load, so a network failure can offer Retry.
    private(set) var lastModality: String?
    init(catalog: GenerateModelCatalog? = nil) { self.catalog = catalog ?? GenerateModelCatalog() }

    func load(_ modality: String) async {
        // Each view uses a dedicated instance per modality. If another caller
        // requests a different modality, serialize it rather than sharing the
        // wrong catalog or allowing an older response to overwrite it.
        while let task = loadTask {
            let sameModality = loadingModality == modality
            await task.value
            if sameModality { return }
        }
        isLoading = true
        loadingModality = modality
        lastModality = modality
        error = nil
        let task = Task { @MainActor in
            defer {
                isLoading = false
                loadingModality = nil
                loadTask = nil
            }
            do { models = try await catalog.fetch(outputModalities: [modality]) }
            catch is CancellationError { }
            catch { self.error = error.localizedDescription }
        }
        loadTask = task
        await task.value
    }

    /// Re-runs discovery after a genuine failure (V-2: discovery is public,
    /// so this is a network retry, not a key prompt).
    func retry() async {
        guard let lastModality, !isLoading else { return }
        await load(lastModality)
    }

    var status: String? {
        if isLoading { return "Discovering models…" }
        if let error {
            return "Model discovery unavailable: \(ErrorCopy.fragment(error)). Enter a model ID manually."
        }
        if models.isEmpty { return "No models listed for this modality. Enter a model ID manually." }
        return nil
    }

    func preferredID(current: String) -> String {
        if models.contains(where: { $0.id == current }) { return current }
        return models.first?.id ?? current
    }
}

struct ModalityModelField: View {
    let title: String
    @Binding var modelID: String
    let choices: ModalityModelChoices
    @State private var showsManual = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            StudioLabel(title)
            if !choices.models.isEmpty {
                Picker("Discovered models", selection: $modelID) {
                    if !choices.models.contains(where: { $0.id == modelID }) {
                        Text("Custom: \(modelID.isEmpty ? "enter below" : modelID)").tag(modelID)
                    }
                    ForEach(choices.models) { model in
                        Text(model.name).tag(model.id)
                    }
                }
                .labelsHidden()
            }
            if showsManual || choices.models.isEmpty {
                TextField("Model ID (manual fallback)", text: $modelID)
                    .textFieldStyle(.roundedBorder)
                    .orbFont(size: 12, design: .monospaced)
            } else {
                HStack(spacing: 6) {
                    Text(modelID).orbFont(size: 11, design: .monospaced)
                        .foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    Button("Enter ID manually") { showsManual = true }
                        .buttonStyle(.plain).orbFont(size: 11).foregroundStyle(.secondary)
                }
            }
            if let status = choices.status {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(status).font(.caption2).foregroundStyle(choices.error == nil ? Color.secondary : Color.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    if choices.error != nil {
                        Button("Retry") { Task { await choices.retry() } }
                            .buttonStyle(.link).font(.caption2)
                    }
                }
            }
        }
    }
}

/// Wording helpers for error text embedded in a longer sentence.
enum ErrorCopy {
    /// Error text ready to be followed by ". Next sentence": surrounding
    /// whitespace and its own trailing full stops are removed, so the result
    /// never reads "…first.. Enter a model ID manually."
    static func fragment(_ message: String) -> String {
        var text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix(".") {
            text = String(text.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }
}
