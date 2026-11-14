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
    @StudioState("EmbeddingsView.tool") private var tool: Tool = .embed
    /// Rows + cosine matrix computed once per result, off main (STUDIO-9).
    @StudioState("EmbeddingsView.summary") private var summary = EmbeddingResultSummary.empty
    @StudioState("EmbeddingsView.promptHistoryRevision") private var promptHistoryRevision = 0
    @EnvironmentObject private var shell: ShellController
    private let promptHistory = StudioPromptHistory(studio: .embeddings)

    enum Tool: String, CaseIterable { case embed = "Embed", rerank = "Rerank" }

    private let accent = ORBTheme.accent

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            // Shared scaffold (V-3): controls + pinned action left, results right.
            StudioScaffold {
                if tool == .embed { embedControls } else { rerankControls }
            } footer: {
                footer
            } results: {
                if tool == .embed { embedResults } else { rerankResultsPane }
            }
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
        HStack(spacing: 12) {
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
            Picker("Tool", selection: $tool) {
                ForEach(Tool.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
        .background(.ultraThinMaterial.opacity(0.45))
    }

    // MARK: Footer — errors first, then the tool's own action (STUDIO-2/3)

    @ViewBuilder private var footer: some View {
        if let errorMessage {
            PlaygroundErrorBanner(message: errorMessage) { self.errorMessage = nil }
        }
        if tool == .embed {
            StudioPrimaryButton(title: "Embed", busyTitle: service.isEmbedding ? "Embedding…" : "Saving…",
                                isBusy: service.isEmbedding || isSaving,
                                isEnabled: canEmbed, accent: accent, action: embed)
                .keyboardShortcut(.return, modifiers: .command)
            Text(embedCostLine).font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            StudioPrimaryButton(title: "Rerank", busyTitle: "Ranking…",
                                isBusy: service.isReranking,
                                isEnabled: canRerank, accent: accent, action: rerank)
                .keyboardShortcut(.return, modifiers: .command)
            Text("Billed per request; usage is shown with the ranking.").font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var embedInputs: [String] {
        inputText.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    /// Per-token estimate from catalog pricing (STUDIO-12).
    private var embedCostLine: String {
        let model = embeddingModels.models.first { $0.id == modelId }
        let characters = embedInputs.reduce(0) { $0 + $1.count }
        if let estimate = StudioCostEstimate.embeddings(promptPrice: model?.pricing?.prompt, characters: characters) {
            return "\(estimate.label). Vectors are saved to the Library."
        }
        return "Price unknown for this model. Vectors are saved to the Library."
    }

    // MARK: Embed

    @ViewBuilder private var embedControls: some View {
        ModalityModelField(title: "MODEL", modelID: $modelId, choices: embeddingModels)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                StudioLabel("Inputs to embed (one per line)")
                Spacer(minLength: 0)
                StudioPromptHistoryMenu(history: promptHistory, onPick: { inputText = $0 },
                                        revision: promptHistoryRevision)
            }
            StudioPromptEditor(text: $inputText, placeholder: "One input per line…",
                               accessibilityLabel: "Embedding inputs", height: 120)
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
        if let pendingEmbedding {
            HStack {
                Text("Vectors available but local save failed.").foregroundStyle(.orange)
                Button("Retry save") { Task { await saveEmbedding(pendingEmbedding) } }.disabled(isSaving)
            }.font(.caption)
        }
    }

    private var recentEmbeddings: [SavedCreation] {
        Array(creations.creations.filter { $0.kind == .embedding }.prefix(12))
    }

    private var embedResults: some View {
        let recent = recentEmbeddings
        return Group {
            if summary.rows.isEmpty && recent.isEmpty {
                StudioEmptyState(icon: "chart.dots.scatter", title: "No vectors yet",
                                 message: "Enter two or more lines to compare them by cosine similarity.",
                                 accent: accent)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if let usage = embedUsage {
                            Text("Usage: \(usage.promptTokens.map { "\($0) input tokens" } ?? "input tokens unavailable") · \(usage.totalTokens.map { "\($0) total tokens" } ?? "total tokens unavailable") · \(usage.cost.map { String(format: "$%.5f", $0) } ?? "cost unavailable")")
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        if summary.matrix.count >= 2 {
                            StudioSectionTitle("Cosine similarity")
                            EmbeddingSimilarityHeatMap(matrix: summary.matrix,
                                                       labels: summary.rows.prefix(summary.matrix.count).map(\.input),
                                                       accent: accent)
                            if let best = summary.bestPair {
                                Text(best).font(.caption).foregroundStyle(.secondary)
                            }
                            if summary.matrixTruncated {
                                Text("Matrix shows the first \(EmbeddingResultSummary.matrixLimit) inputs.")
                                    .font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                        if !summary.rows.isEmpty {
                            StudioSectionTitle("Vectors")
                            ForEach(summary.rows) { row in
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text("#\(row.id + 1) · \(row.input)").font(.caption.bold()).lineLimit(2)
                                        Spacer()
                                        Button("Copy Vector") { AppToasts.copy(row.json, what: "Vector") }
                                            .font(.caption).buttonStyle(.link)
                                    }
                                    Text("\(row.dimensions) dimensions · ‖v‖ \(String(format: "%.4f", row.norm))")
                                        .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                                    Text(row.preview)
                                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.orbSurface(0.035), in: RoundedRectangle(cornerRadius: 10))
                            }
                        }
                        if !recent.isEmpty {
                            HStack {
                                StudioSectionTitle("Recent embeddings")
                                Button("Show all in Library") { StudioNavigation.showInLibrary(nil, shell: shell) }
                                    .font(.caption).buttonStyle(.link)
                            }
                            ForEach(recent) { creation in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(creation.prompt ?? "Embedding").font(.caption).lineLimit(1)
                                        Text(creation.modelID).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                                    }
                                    Spacer()
                                    Button("Reuse Inputs") {
                                        if let prompt = creation.prompt {
                                            inputText = prompt.components(separatedBy: " · ").joined(separator: "\n")
                                            modelId = creation.modelID
                                        }
                                    }.font(.caption)
                                    CreationActionsMenu(creation: creation, store: creations, onError: { errorMessage = $0 })
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }
                    .padding(20)
                }
            }
        }
    }

    // MARK: Rerank

    @ViewBuilder private var rerankControls: some View {
        ModalityModelField(title: "MODEL", modelID: $rerankModelId, choices: rerankModels)
        StudioField("Query") {
            TextField("Query", text: $rerankQuery).textFieldStyle(.roundedBorder)
        }
        StudioField("Documents (one per line)") {
            StudioPromptEditor(text: $rerankDocs, placeholder: "One document per line…",
                               accessibilityLabel: "Rerank documents", height: 140)
        }
        StudioField("Top N (optional)") {
            TextField("e.g. 3", text: $topN).textFieldStyle(.roundedBorder)
        }
    }

    private var rerankResultsPane: some View {
        Group {
            if rerankResults.isEmpty {
                StudioEmptyState(icon: "list.number", title: "No ranking yet",
                                 message: "Enter a query and documents, then Rerank.", accent: accent)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if let rerankUsage {
                            Text("Usage: \(rerankUsage.searchUnits.map { "\($0) search units" } ?? "search units unavailable") · \(rerankUsage.totalTokens.map { "\($0) tokens" } ?? "tokens unavailable") · \(rerankUsage.cost.map { String(format: "$%.5f", $0) } ?? "cost unavailable")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if let rerankProvider { Text("Provider: \(rerankProvider)").font(.caption).foregroundStyle(.secondary) }
                        StudioSectionTitle("Ranking")
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
                    .padding(20)
                }
            }
        }
    }

    private var canEmbed: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !modelId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (requestedDimensions.isEmpty || (Int(requestedDimensions).map { $0 > 0 } ?? false))
            && !service.isEmbedding && !isSaving && KeychainManager.hasAPIKey
    }

    /// Independent of embedding (STUDIO-3): rerank has no local save step.
    private var canRerank: Bool {
        !rerankQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !rerankDocs.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !rerankModelId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (topN.isEmpty || (Int(topN).map { $0 > 0 } ?? false))
            && !service.isReranking && KeychainManager.hasAPIKey
    }

    private func embed() {
        guard canEmbed else { return }
        errorMessage = nil
        let model = modelId.trimmingCharacters(in: .whitespacesAndNewlines)
        let inputs = inputText.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        vectors = []
        summary = .empty
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
                summary = await EmbeddingResultSummary.compute(vectors)
                embedUsage = response.usage
                promptHistory.record(inputs.joined(separator: "\n"))
                promptHistoryRevision += 1
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

/// N×N cosine heat-map (STUDIO-9). Cells are precomputed; this only draws.
struct EmbeddingSimilarityHeatMap: View {
    let matrix: [[Double?]]
    let labels: [String]
    let accent: Color

    static func cellOpacity(_ value: Double?) -> Double {
        guard let value else { return 0 }
        return 0.12 + 0.88 * max(0, min(1, (value + 1) / 2))
    }

    var body: some View {
        let n = matrix.count
        let side: CGFloat = n > 10 ? 26 : 40
        ScrollView(.horizontal) {
            Grid(horizontalSpacing: 2, verticalSpacing: 2) {
                GridRow {
                    Color.clear.frame(width: 28, height: 18)
                    ForEach(0..<n, id: \.self) { j in
                        Text("#\(j + 1)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                            .frame(width: side)
                    }
                }
                ForEach(0..<n, id: \.self) { i in
                    GridRow {
                        Text("#\(i + 1)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                            .frame(width: 28, alignment: .trailing)
                            .help(labels.indices.contains(i) ? labels[i] : "")
                        ForEach(0..<n, id: \.self) { j in
                            let value = matrix[i][j]
                            ZStack {
                                RoundedRectangle(cornerRadius: 4).fill(accent.opacity(Self.cellOpacity(value)))
                                if n <= 10 {
                                    Text(value.map { String(format: "%.2f", $0) } ?? "—")
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(Self.cellOpacity(value) > 0.6 ? .white : .primary)
                                }
                            }
                            .frame(width: side, height: side)
                            .help(value.map { "#\(i + 1) vs #\(j + 1): \(String(format: "%.4f", $0))" } ?? "Not comparable")
                            .accessibilityLabel(value.map { "Input \(i + 1) versus \(j + 1), cosine \(String(format: "%.2f", $0))" }
                                                ?? "Input \(i + 1) versus \(j + 1), not comparable")
                        }
                    }
                }
            }
            .padding(.bottom, 4)
        }
    }
}
