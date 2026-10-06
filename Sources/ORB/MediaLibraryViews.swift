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
    init(catalog: GenerateModelCatalog? = nil) { self.catalog = catalog ?? GenerateModelCatalog() }

    func load(_ modality: String) async {
        guard !isLoading else { return }
        isLoading = true
        error = nil
        defer { isLoading = false }
        do { models = try await catalog.fetch(outputModalities: [modality]) }
        catch is CancellationError { }
        catch { self.error = error.localizedDescription }
    }

    var status: String? {
        if isLoading { return "Discovering models…" }
        if let error { return "Model discovery unavailable: \(error). Enter a model ID manually." }
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
                Text(status).font(.caption2).foregroundStyle(choices.error == nil ? Color.secondary : Color.orange)
            }
        }
    }
}
