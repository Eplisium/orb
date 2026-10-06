import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Embeddings + rerank lab

struct EmbeddingsView: View {
    @ObservedObject private var service = StudioServices.shared.embeddings
    @StudioState("EmbeddingsView.embeddingModels") private var embeddingModels = ModalityModelChoices()
    @StudioState("EmbeddingsView.rerankModels") private var rerankModels = ModalityModelChoices()
    @ObservedObject private var creations = SavedCreationsStore.shared
    @StudioState("EmbeddingsView.modelId") private var modelId = ""
    @StudioState("EmbeddingsView.rerankModelId") private var rerankModelId = ""
    @StudioState("EmbeddingsView.inputText") private var inputText = ""
    @StudioState("EmbeddingsView.vectors") private var vectors: [(input: String, embedding: [Double])] = []
    @StudioState("EmbeddingsView.requestedDimensions") private var requestedDimensions = ""
    @StudioState("EmbeddingsView.inputType") private var inputType = ""
    @StudioState("EmbeddingsView.embedUsage") private var embedUsage: ImageGenUsage? = nil
    @StudioState("EmbeddingsView.pendingEmbedding") private var pendingEmbedding: (payload: Data, model: String, prompt: String)? = nil
    @StudioState("EmbeddingsView.rerankQuery") private var rerankQuery = ""
    @StudioState("EmbeddingsView.rerankDocs") private var rerankDocs = ""
    @StudioState("EmbeddingsView.rerankResults") private var rerankResults: [RerankResponse.Item] = []
    @StudioState("EmbeddingsView.rankedDocuments") private var rankedDocuments: [String] = []
    @StudioState("EmbeddingsView.topN") private var topN = ""
    @StudioState("EmbeddingsView.rerankUsage") private var rerankUsage: RerankResponse.Usage? = nil
    @StudioState("EmbeddingsView.rerankProvider") private var rerankProvider: String? = nil
    @StudioState("EmbeddingsView.isSaving") private var isSaving = false
    @StudioState("EmbeddingsView.errorMessage") private var errorMessage: String? = nil

    private let accent = ORBTheme.accent

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                headerBar
                embedSection
                rerankSection
                if let errorMessage {
                    PlaygroundErrorBanner(message: errorMessage) { self.errorMessage = nil }
                }
            }
            .padding(20)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            await embeddingModels.load("embeddings")
            if modelId.isEmpty { modelId = embeddingModels.preferredID(current: "") }
            await rerankModels.load("rerank")
            if rerankModelId.isEmpty { rerankModelId = rerankModels.preferredID(current: "") }
        }
    }

    private var headerBar: some View {
        StudioHeader(title: "Embeddings & Rerank", subtitle: "Vectors for search · ordering for retrieval",
                     icon: "chart.dots.scatter", accent: accent) {
            StudioPresetMenu(
                studio: .embeddings,
                snapshot: {
                    StudioPreset.embeddingsSettings(model: modelId, dimensions: requestedDimensions, inputType: inputType,
                                                    rerankModel: rerankModelId, topN: topN)
                },
                apply: { preset in
                    let v = EmbeddingsPresetValues(preset)
                    if !v.model.isEmpty { modelId = v.model }
                    requestedDimensions = v.dimensions; inputType = v.inputType
                    if !v.rerankModel.isEmpty { rerankModelId = v.rerankModel }
                    topN = v.topN
                })
        }
    }

    private var embedSection: some View {
        StudioCard(title: "Embeddings") {
            ModalityModelField(title: "MODEL", modelID: $modelId, choices: embeddingModels)
            StudioField("Inputs to embed (one per line)") {
                StudioPromptEditor(text: $inputText, placeholder: "One input per line…",
                                   accessibilityLabel: "Embedding inputs", height: 90)
            }
            StudioGrid {
                StudioField("Dimensions (optional)") {
                    TextField("e.g. 1024", text: $requestedDimensions).textFieldStyle(.roundedBorder)
                }
                StudioField("Input type") {
                    Picker("Input type", selection: $inputType) {
                        Text("Provider default").tag("")
                        Text("Query").tag("query")
                        Text("Document").tag("document")
                    }.labelsHidden()
                }
            }
            Text("Float vectors requested. Dimensions and input type depend on provider support.")
                .font(.caption2).foregroundStyle(.secondary)
            StudioPrimaryButton(title: "Embed", busyTitle: service.isWorking ? "Embedding…" : "Saving…",
                                isBusy: service.isWorking || isSaving,
                                isEnabled: canEmbed, accent: accent, action: embed)
            if let usage = embedUsage {
                Text("Usage: \(usage.promptTokens.map { "\($0) input tokens" } ?? "input tokens unavailable") · \(usage.totalTokens.map { "\($0) total tokens" } ?? "total tokens unavailable") · \(usage.cost.map { String(format: "$%.5f", $0) } ?? "cost unavailable")")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            ForEach(Array(vectors.enumerated()), id: \.offset) { index, vector in
                VStack(alignment: .leading, spacing: 4) {
                    Text("#\(index + 1) · \(vector.input) · \(vector.embedding.count) dimensions").font(.caption.bold())
                    Text(vector.embedding.map { String($0) }.joined(separator: ", "))
                        .font(.caption.monospaced()).textSelection(.enabled)
                        .lineLimit(3)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if let pendingEmbedding {
                HStack {
                    Text("Vectors available but local save failed.").foregroundStyle(.orange)
                    Button("Retry save") { Task { await saveEmbedding(pendingEmbedding) } }.disabled(isSaving)
                }.font(.caption)
            }
        }
    }

    private var rerankSection: some View {
        StudioCard(title: "Rerank") {
            ModalityModelField(title: "MODEL", modelID: $rerankModelId, choices: rerankModels)
            TextField("Query", text: $rerankQuery)
                .textFieldStyle(.roundedBorder)
            StudioField("Documents (one per line)") {
                StudioPromptEditor(text: $rerankDocs, placeholder: "One document per line…",
                                   accessibilityLabel: "Rerank documents", height: 110)
            }
            StudioField("Top N (optional)") {
                TextField("e.g. 3", text: $topN).textFieldStyle(.roundedBorder)
            }
            StudioPrimaryButton(title: "Rerank", busyTitle: service.isWorking ? "Ranking…" : "Saving…",
                                isBusy: service.isWorking || isSaving,
                                isEnabled: canRerank, accent: accent, action: rerank)
            if let rerankUsage {
                Text("Usage: \(rerankUsage.searchUnits.map { "\($0) search units" } ?? "search units unavailable") · \(rerankUsage.totalTokens.map { "\($0) tokens" } ?? "tokens unavailable") · \(rerankUsage.cost.map { String(format: "$%.5f", $0) } ?? "cost unavailable")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let rerankProvider { Text("Provider: \(rerankProvider)").font(.caption).foregroundStyle(.secondary) }
            if !rerankResults.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(rerankResults.sorted { ($0.relevanceScore ?? 0) > ($1.relevanceScore ?? 0) }, id: \.index) { item in
                        HStack(spacing: 8) {
                            Text("#\(item.index + 1)").font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                            if let score = item.relevanceScore {
                                Text(String(format: "%.3f", score))
                                    .font(.caption.monospacedDigit()).foregroundStyle(accent)
                            }
                            if let document = item.document?.text ?? rankedDocument(index: item.index, in: rankedDocuments) {
                                Text(document)
                                    .font(.caption).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            } else if item.document?.image != nil {
                                Text("Image document (URL omitted)").font(.caption).foregroundStyle(.secondary)
                            } else {
                                Text("Document index unavailable").font(.caption).foregroundStyle(.orange)
                            }
                        }
                        .padding(8)
                        .background(.orbSurface(0.04))
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                    }
                }
            }
        }
    }

    private var canEmbed: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !modelId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (requestedDimensions.isEmpty || (Int(requestedDimensions).map { $0 > 0 } ?? false))
            && !service.isWorking && !isSaving && KeychainManager.hasAPIKey
    }

    private var canRerank: Bool {
        !rerankQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !rerankDocs.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !rerankModelId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (topN.isEmpty || (Int(topN).map { $0 > 0 } ?? false))
            && !service.isWorking && !isSaving && KeychainManager.hasAPIKey
    }

    private func embed() {
        guard canEmbed else { return }
        errorMessage = nil
        let model = modelId.trimmingCharacters(in: .whitespacesAndNewlines)
        let inputs = inputText.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        vectors = []
        embedUsage = nil
        pendingEmbedding = nil
        Task {
            do {
                var request = EmbeddingRequest(model: model, input: inputs)
                request.dimensions = Int(requestedDimensions)
                request.inputType = inputType.isEmpty ? nil : inputType
                request.encodingFormat = "float"
                let response = try await service.embed(request)
                let ordered = try orderedEmbeddingVectors(response.data, inputCount: inputs.count)
                vectors = zip(inputs, ordered).map { (input: $0.0, embedding: $0.1) }
                embedUsage = response.usage
                let records = zip(inputs, ordered).map { ["input": $0.0, "embedding": $0.1] as [String: Any] }
                let payload = try JSONSerialization.data(withJSONObject: ["items": records], options: [.prettyPrinted, .sortedKeys])
                let pending = (payload: payload, model: model, prompt: inputs.joined(separator: " · "))
                pendingEmbedding = pending
                await saveEmbedding(pending)
                StudioNotifier.shared.finished(section: SidebarSection.embeddings.rawValue, title: "Embeddings ready", body: "Your embeddings finished.")
            } catch is CancellationError { }
            catch { errorMessage = error.localizedDescription }
        }
    }

    private func saveEmbedding(_ pending: (payload: Data, model: String, prompt: String)) async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            _ = try await creations.save(pending.payload, mimeType: "application/json", kind: .embedding,
                                         modelID: pending.model, prompt: pending.prompt)
            pendingEmbedding = nil
            errorMessage = nil
        } catch { errorMessage = "Vectors returned, but local save failed: \(error.localizedDescription)" }
    }

    private func rerank() {
        guard canRerank else { return }
        errorMessage = nil
        let docs = rerankDocs.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let model = rerankModelId.trimmingCharacters(in: .whitespacesAndNewlines)
        let query = rerankQuery
        rerankResults = []
        rerankUsage = nil
        rerankProvider = nil
        Task {
            do {
                let response = try await service.rerank(RerankRequest(
                    model: model, query: query, documents: docs, topN: Int(topN)
                ))
                rankedDocuments = docs
                rerankResults = response.results
                rerankUsage = response.usage
                rerankProvider = response.provider
            } catch is CancellationError {
                // Leave prior ranking alone on cancellation.
            } catch {
                await MainActor.run { errorMessage = error.localizedDescription }
            }
        }
    }
}

/// API indices refer to the exact submitted array, before any score sort.
func orderedEmbeddingVectors(_ items: [EmbeddingResponse.Item], inputCount: Int) throws -> [[Double]] {
    guard items.count == inputCount else {
        throw MediaServiceError.decoding("Embedding response count does not match the inputs.")
    }
    var mapped: [Int: [Double]] = [:]
    for (position, item) in items.enumerated() {
        let index = item.index ?? position
        guard (0..<inputCount).contains(index), mapped[index] == nil else {
            throw MediaServiceError.decoding("Embedding response index is invalid or duplicated.")
        }
        mapped[index] = item.embedding
    }
    return (0..<inputCount).map { mapped[$0]! }
}

/// API indices refer to the exact submitted array, before any score sort.
func rankedDocument(index: Int, in documents: [String]) -> String? {
    documents.indices.contains(index) ? documents[index] : nil
}
