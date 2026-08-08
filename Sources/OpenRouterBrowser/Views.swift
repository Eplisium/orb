import SwiftUI

// MARK: - Model Row

struct ModelRowView: View {
    let model: ModelInfo
    @ObservedObject var viewModel: BrowserViewModel

    var body: some View {
        HStack(spacing: 10) {
            // Provider badge
            Text(model.provider.uppercased())
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 3)
                .background(providerColor)
                .clipShape(RoundedRectangle(cornerRadius: 4))

            VStack(alignment: .leading, spacing: 2) {
                Text(model.modelSlug)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)

                HStack(spacing: 8) {
                    Label(model.contextLengthFormatted, systemImage: "arrow.left.arrow.right")
                    if let cost = model.promptCostPer1M, !model.isFree {
                        Text("$\(cost, specifier: "%.3f")/1M")
                            .foregroundStyle(.orange)
                    }
                    if model.isFree {
                        Text("FREE")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.green)
                    }
                    if model.supportsImages {
                        Image(systemName: "photo")
                            .foregroundStyle(.blue)
                    }
                    if model.supportsImageOutput {
                        Image(systemName: "paintbrush")
                            .foregroundStyle(.pink)
                    }
                    if model.supportsTools {
                        Image(systemName: "wrench.and.screwdriver")
                            .foregroundStyle(.orange)
                    }
                    if model.supportsReasoning {
                        Image(systemName: "brain")
                            .foregroundStyle(.purple)
                    }
                    if let elo = model.bestDesignElo {
                        Text("Elo \(Int(elo))")
                            .foregroundStyle(.teal)
                    }
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            }

            Spacer()

            // Copy button
            Button {
                viewModel.copyModelId(model)
            } label: {
                Image(systemName: viewModel.copiedModelId == model.id ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 12))
                    .foregroundStyle(viewModel.copiedModelId == model.id ? .green : .secondary)
            }
            .buttonStyle(.plain)
            .help("Copy model ID")

            // Favorite button
            Button {
                viewModel.toggleFavorite(model)
            } label: {
                let isFav = viewModel.favoriteIds.contains(model.id)
                Image(systemName: isFav ? "star.fill" : "star")
                    .font(.system(size: 13))
                    .foregroundStyle(isFav ? .yellow : Color.gray.opacity(0.4))
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 3)
    }

    var providerColor: Color {
        let p = model.provider.lowercased()
        if p.contains("openai") { return .green }
        if p.contains("anthropic") { return .orange }
        if p.contains("google") { return .blue }
        if p.contains("meta") { return .indigo }
        if p.contains("mistral") { return .teal }
        if p.contains("cohere") { return .purple }
        if p.contains("deepseek") { return .cyan }
        return .gray
    }
}

// MARK: - Model Detail

struct ModelDetailView: View {
    let model: ModelInfo
    @ObservedObject var viewModel: BrowserViewModel
    @State private var notes: String = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerSection
                descriptionSection
                Divider()
                statsGrid
                capabilitySection
                benchmarksSection
                providersSection
                parametersSection
                notesSection
                Spacer()
            }
            .padding(24)
        }
        .onAppear {
            notes = viewModel.db.getNotes(model.id)
            viewModel.selectModel(model)
        }
        .onChange(of: model.id) { _, _ in
            notes = viewModel.db.getNotes(model.id)
            viewModel.selectModel(model)
        }
    }

    // MARK: Header

    private var headerSection: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(model.provider)
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(.secondary)
                    if model.hasExpired {
                        Text("EXPIRED")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.red)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(.red.opacity(0.15))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                }
                Text(model.modelSlug)
                    .font(.system(size: 26, weight: .bold))
                Text(model.id)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Spacer()

            VStack(spacing: 8) {
                Button { viewModel.copyModelId(model) } label: {
                    HStack {
                        Image(systemName: viewModel.copiedModelId == model.id ? "checkmark" : "doc.on.doc")
                        Text(viewModel.copiedModelId == model.id ? "Copied!" : "Copy ID")
                    }
                    .font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(.blue.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .keyboardShortcut("c", modifiers: .command)

                let isFav = viewModel.favoriteIds.contains(model.id)
                Button { viewModel.toggleFavorite(model) } label: {
                    HStack {
                        Image(systemName: isFav ? "star.fill" : "star")
                        Text(isFav ? "Favorited" : "Favorite")
                    }
                    .font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(isFav ? Color.yellow.opacity(0.15) : Color.gray.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)

                Button {
                    let url = URL(string: "https://openrouter.ai/\(model.id)")!
                    NSWorkspace.shared.open(url)
                } label: {
                    HStack {
                        Image(systemName: "safari")
                        Text("Open on OpenRouter")
                    }
                    .font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(.gray.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Description

    @ViewBuilder
    private var descriptionSection: some View {
        if let desc = model.description, !desc.isEmpty {
            Text(desc)
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Stats Grid

    private var statsGrid: some View {
        LazyVGrid(columns: [
            GridItem(.flexible()),
            GridItem(.flexible()),
            GridItem(.flexible())
        ], spacing: 16) {
            StatCard(title: "Context", value: model.contextLengthFormatted, icon: "arrow.left.arrow.right", color: .blue)
            StatCard(title: "Modality", value: model.modalityLabel, icon: "arrow.triangle.branch", color: .purple)

            if let maxTokens = model.topProvider?.maxCompletionTokens {
                let formatted = maxTokens >= 1000 ? "\(maxTokens/1000)K" : "\(maxTokens)"
                StatCard(title: "Max Output", value: formatted, icon: "text.alignleft", color: .green)
            }

            if model.isFree {
                StatCard(title: "Price", value: "Free", icon: "gift", color: .green)
            } else {
                if let p = model.promptCostPer1M {
                    StatCard(title: "Input $/1M", value: String(format: "$%.3f", p), icon: "arrow.down.circle", color: .orange)
                }
                if let c = model.completionCostPer1M {
                    StatCard(title: "Output $/1M", value: String(format: "$%.3f", c), icon: "arrow.up.circle", color: .red)
                }
            }
            if let cr = model.cacheReadCostPer1M {
                StatCard(title: "Cached In $/1M", value: String(format: "$%.3f", cr), icon: "bolt", color: .yellow)
            }

            StatCard(title: "Added", value: model.createdFormatted, icon: "calendar", color: .teal)
            StatCard(title: "Knowledge", value: model.knowledgeCutoffFormatted, icon: "book.closed", color: .indigo)

            if let voices = model.supportedVoices, !voices.isEmpty {
                StatCard(title: "Voices", value: "\(voices.count) voices", icon: "speaker.wave.2", color: .pink)
            }

            if model.topProvider?.isModerated == true {
                StatCard(title: "Moderated", value: "Yes", icon: "shield", color: .yellow)
            }
        }
    }

    // MARK: Capabilities

    private var capabilitySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Capabilities")
                .font(.headline)
            FlowLayout(spacing: 6) {
                CapabilityTag(label: "Image In", active: model.supportsImages, color: .blue)
                CapabilityTag(label: "Image Out", active: model.supportsImageOutput, color: .pink)
                CapabilityTag(label: "Audio Out", active: model.supportsAudioOutput, color: .mint)
                CapabilityTag(label: "Tools", active: model.supportsTools, color: .orange)
                CapabilityTag(label: "Reasoning", active: model.supportsReasoning, color: .purple)
                CapabilityTag(label: "Free", active: model.isFree, color: .green)
                if let voices = model.supportedVoices, !voices.isEmpty {
                    CapabilityTag(label: "Voice (\(voices.count))", active: true, color: .pink)
                }
            }
        }
    }

    // MARK: Benchmarks

    @ViewBuilder
    private var benchmarksSection: some View {
        if let aa = model.benchmarks?.artificialAnalysis {
            VStack(alignment: .leading, spacing: 8) {
                Text("Artificial Analysis Index")
                    .font(.headline)
                HStack(spacing: 16) {
                    if let i = aa.intelligenceIndex {
                        IndexVBar(label: "Intelligence", value: i, color: .blue)
                    }
                    if let c = aa.codingIndex {
                        IndexVBar(label: "Coding", value: c, color: .green)
                    }
                    if let a = aa.agenticIndex {
                        IndexVBar(label: "Agentic", value: a, color: .purple)
                    }
                    Spacer()
                }
            }
        }

        if let arena = model.benchmarks?.designArena, !arena.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Design Arena (best Elo \(arena.map { Int($0.elo ?? 0) }.max() ?? 0))")
                    .font(.headline)
                FlowLayout(spacing: 6) {
                    ForEach(arena.sorted { ($0.elo ?? 0) > ($1.elo ?? 0) }) { entry in
                        HStack(spacing: 4) {
                            Text(entry.category ?? "?")
                                .font(.system(size: 11, weight: .semibold))
                            Text("\(Int(entry.elo ?? 0))")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.teal)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.teal.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                    }
                }
            }
        }
    }

    // MARK: Providers

    @ViewBuilder
    private var providersSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Providers (\(viewModel.endpoints.count))")
                    .font(.headline)
                if viewModel.isLoadingEndpoints {
                    ProgressView().scaleEffect(0.7)
                }
            }
            if viewModel.endpoints.isEmpty && !viewModel.isLoadingEndpoints {
                Text("No per-provider data available")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 6) {
                    ForEach(viewModel.endpoints) { ep in
                        ProviderRow(endpoint: ep)
                    }
                }
            }
        }
    }

    // MARK: Parameters

    @ViewBuilder
    private var parametersSection: some View {
        if let params = model.supportedParameters, !params.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Supported Parameters")
                    .font(.headline)
                FlowLayout(spacing: 6) {
                    ForEach(params.sorted(), id: \.self) { param in
                        Text(param)
                            .font(.system(size: 11, design: .monospaced))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.quaternary)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                }
            }
        }
    }

    // MARK: Notes

    @ViewBuilder
    private var notesSection: some View {
        if viewModel.favoriteIds.contains(model.id) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Notes")
                    .font(.headline)
                TextEditor(text: $notes)
                    .font(.body)
                    .frame(minHeight: 80)
                    .padding(6)
                    .background(.quaternary.opacity(0.3))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .onChange(of: notes) { _, newValue in
                        viewModel.db.setNotes(model.id, notes: newValue)
                    }
            }
        }
    }
}

// MARK: - Provider Row

struct ProviderRow: View {
    let endpoint: ModelEndpoint

    var body: some View {
        HStack(spacing: 12) {
            // Status dot
            Circle()
                .fill(endpoint.isAvailable ? Color.green : Color.red)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(endpoint.providerName ?? "Unknown")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 10) {
                    if let ctx = endpoint.contextLength {
                        Text(ctxFormatted(ctx))
                            .foregroundStyle(.secondary)
                    }
                    if let q = endpoint.quantization, !q.isEmpty, q != "unknown" {
                        Text(q.uppercased())
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(.teal)
                    }
                    if let up = endpoint.uptimeLast1d {
                        Text("Uptime \(Int(up))%")
                            .foregroundStyle(.secondary)
                    }
                    if endpoint.supportsImplicitCaching == true {
                        Label("cache", systemImage: "bolt")
                            .foregroundStyle(.yellow)
                    }
                }
                .font(.system(size: 11))
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                if let p = endpoint.promptCostPer1M, let c = endpoint.completionCostPer1M {
                    Text("$\(p, specifier: "%.4f") in")
                    Text("$\(c, specifier: "%.4f") out")
                } else {
                    Text("—")
                }
            }
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.orange)
        }
        .padding(10)
        .background(.quaternary.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func ctxFormatted(_ ctx: Int) -> String {
        if ctx >= 1_000_000 { return String(format: "%.1fM ctx", Double(ctx) / 1_000_000) }
        if ctx >= 1000 { return "\(ctx / 1000)K ctx" }
        return "\(ctx) ctx"
    }
}

// MARK: - Stat Card

struct StatCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundStyle(color)
                Text(title)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(size: 16, weight: .semibold))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(color.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Index VBar

struct IndexVBar: View {
    let label: String
    let value: Double
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(Int(value))")
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundStyle(color)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(.quaternary)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(color)
                        .frame(width: geo.size.width * CGFloat(min(value, 100) / 100))
                }
            }
            .frame(height: 8)
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .frame(width: 90)
    }
}

// MARK: - Capability Tag

struct CapabilityTag: View {
    let label: String
    let active: Bool
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: active ? "checkmark.circle.fill" : "xmark.circle")
                .font(.system(size: 11))
            Text(label)
                .font(.system(size: 12, weight: .medium))
        }
        .foregroundStyle(active ? color : .secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(active ? color.opacity(0.12) : Color.gray.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - Flow Layout

struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrange(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(proposal: proposal, subviews: subviews)
        for (index, offset) in result.offsets.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + offset.x, y: bounds.minY + offset.y), proposal: .unspecified)
        }
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (offsets: [CGPoint], size: CGSize) {
        let maxWidth = proposal.width ?? .infinity
        var offsets: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxX: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            offsets.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            maxX = max(maxX, x)
        }

        return (offsets, CGSize(width: maxX, height: y + rowHeight))
    }
}
