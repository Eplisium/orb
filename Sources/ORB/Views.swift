import SwiftUI

// MARK: - Model Row

/// Compact price text: at least two decimals, trailing zeros trimmed
/// beyond that ("$2.00", "$2.50", "$0.15", "$0.0375") so columns read evenly.
enum PriceFormat {
    static func perMillion(_ value: Double) -> String {
        var text = String(format: "%.4f", value)
        while text.hasSuffix("0"), let dot = text.firstIndex(of: "."),
              text.distance(from: dot, to: text.endIndex) > 3 {
            text.removeLast()
        }
        return "$" + text
    }
}

/// Callbacks a row needs; rows take plain values plus these so a change to
/// one model's state does not invalidate every row via the whole view model.
struct ModelRowActions {
    var toggleFavorite: (ModelInfo) -> Void
    var toggleCompare: (ModelInfo) -> Void
    var copyID: (ModelInfo) -> Void
    var chat: (ModelInfo) -> Void
    var agent: (ModelInfo) -> Void
}

struct ModelRowView: View {
    let model: ModelInfo
    let isFavorite: Bool
    let isComparing: Bool
    let anyComparing: Bool
    let isCopied: Bool
    let actions: ModelRowActions
    @AppStorage(PriceUnit.defaultsKey) private var priceUnit: PriceUnit = .perMillion
    @State private var isHovered = false

    private var facts: ModelRowFacts { ModelRowFacts.make(model, unit: priceUnit) }

    var body: some View {
        HStack(spacing: 10) {
            avatar

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    if isFavorite {
                        Image(systemName: "star.fill")
                            .orbFont(size: 11)
                            .foregroundStyle(.yellow)
                            .accessibilityLabel("Favorite")
                    }
                    Text(model.modelSlug)
                        .font(ORBFont.body.weight(.medium))
                        .lineLimit(1)
                    if model.isAlias {
                        Text("ALIAS").orbFont(size: 11, weight: .bold).foregroundStyle(ORBTheme.accentLink)
                    }
                    if model.hasExpired {
                        Text("EXPIRED").orbFont(size: 11, weight: .bold).foregroundStyle(.red)
                    }
                }
                if let line = facts.oneLiner {
                    Text(line)
                        .font(ORBFont.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                HStack(spacing: 10) {
                    Text(facts.context + " ctx").monospacedDigit()
                    Text(facts.price)
                        .monospacedDigit()
                        .foregroundStyle(model.isFree ? ORBTheme.success : Color.secondary)
                    if let elo = model.bestDesignElo { Text("Elo \(Int(elo))") }
                    capabilityIcons
                }
                .font(ORBFont.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: 8)

            quickActions
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        // One labelled element per row (model + provider + state). The
        // hover-only quick buttons are reachable as named actions below.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ModelRowAccessibility.label(model, isFavorite: isFavorite, isComparing: isComparing))
        .accessibilityValue(ModelRowAccessibility.value(facts))
        .accessibilityAction(named: isFavorite ? "Remove from favorites" : "Add to favorites") { actions.toggleFavorite(model) }
        .accessibilityAction(named: isComparing ? "Remove from compare" : "Add to compare") { actions.toggleCompare(model) }
        .accessibilityAction(named: "Copy model ID") { actions.copyID(model) }
        .accessibilityAction(named: "Chat with this model") { actions.chat(model) }
        .accessibilityAction(named: "Use in the Agent") { actions.agent(model) }
        .contextMenu {
            Button {
                actions.copyID(model)
            } label: {
                Label("Copy Model ID", systemImage: "doc.on.doc")
            }
            Button {
                actions.toggleFavorite(model)
            } label: {
                Label(isFavorite ? "Remove Favorite" : "Add Favorite",
                      systemImage: isFavorite ? "star.slash" : "star")
            }
            Button {
                actions.toggleCompare(model)
            } label: {
                Label(isComparing ? "Remove from Compare" : "Add to Compare", systemImage: "rectangle.split.3x1")
            }
            Divider()
            Button { actions.chat(model) } label: {
                Label("Chat with this Model", systemImage: "bubble.left")
            }
            Button { actions.agent(model) } label: {
                Label("Run in Agent", systemImage: "wand.and.stars")
            }
            if let url = model.openRouterURL {
                Divider()
                Button { NSWorkspace.shared.open(url) } label: {
                    Label("Open on OpenRouter", systemImage: "safari")
                }
            }
        }
    }

    private var avatar: some View {
        Text(facts.avatarLetter)
            .orbFont(size: 13, weight: .bold, design: .rounded)
            .foregroundStyle(providerColor)
            .frame(width: 30, height: 30)
            .background(providerColor.opacity(0.16), in: Circle())
            .help(model.provider)
            .accessibilityLabel("Provider \(model.provider)")
    }

    private var quickActions: some View {
        HStack(spacing: 8) {
            let compareVisible = isHovered || isComparing || anyComparing
            Button { actions.toggleCompare(model) } label: {
                Image(systemName: isComparing ? "checkmark.square.fill" : "square")
                    .foregroundStyle(isComparing ? ORBTheme.accent : Color.secondary)
            }
            .buttonStyle(.plain)
            .hiddenUnless(compareVisible)
            .help(isComparing ? "Remove from compare" : "Add to compare")
            .accessibilityLabel(isComparing ? "Remove from compare" : "Add to compare")

            Button { actions.chat(model) } label: {
                Image(systemName: "bubble.left").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .hiddenUnless(isHovered)
            .help("Chat with this model")
            .accessibilityLabel("Chat with this model")

            Button { actions.copyID(model) } label: {
                Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                    .foregroundStyle(isCopied ? ORBTheme.success : Color.secondary)
            }
            .buttonStyle(.plain)
            .hiddenUnless(isHovered || isCopied)
            .help("Copy model ID")
            .accessibilityLabel("Copy model ID")

            Button { actions.toggleFavorite(model) } label: {
                Image(systemName: isFavorite ? "star.fill" : "star")
                    .foregroundStyle(isFavorite ? Color.yellow : Color.secondary.opacity(0.7))
            }
            .buttonStyle(.plain)
            .help(isFavorite ? "Remove from favorites" : "Add to favorites")
            .accessibilityLabel(isFavorite ? "Remove from favorites" : "Add to favorites")
        }
        .orbFont(size: 13)
    }

    /// Neutral glyphs, capped, with the full list in the tooltip.
    @ViewBuilder
    private var capabilityIcons: some View {
        let caps = facts.capabilities
        if !caps.isEmpty {
            HStack(spacing: 5) {
                ForEach(Array(caps.prefix(Self.maxCapabilityIcons).enumerated()), id: \.offset) { _, cap in
                    Image(systemName: cap.icon).orbFont(size: 11).help(cap.name)
                }
                if caps.count > Self.maxCapabilityIcons {
                    Text("+\(caps.count - Self.maxCapabilityIcons)").lineLimit(1)
                }
            }
            .fixedSize()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Capabilities: " + caps.map(\.name).joined(separator: ", "))
        }
    }

    private static let maxCapabilityIcons = 4

    var providerColor: Color {
        let p = model.provider.lowercased()
        if p.contains("openai") { return .green }
        if p.contains("anthropic") { return .orange }
        if p.contains("google") { return .blue }
        if p.contains("meta") || p.contains("llama") { return .indigo }
        if p.contains("mistral") { return .teal }
        if p.contains("cohere") { return .purple }
        if p.contains("deepseek") { return .cyan }
        if p.contains("nvidia") { return .green }
        if p.contains("qwen") || p.contains("alibaba") { return .red }
        if p.contains("microsoft") { return .blue }
        if p.contains("amazon") { return .orange }
        if p.contains("x-ai") || p.contains("xai") || p.contains("grok") { return .gray }
        if p.contains("perplexity") { return .teal }
        if p.contains("nous") { return .brown }
        if p.contains("01-ai") || p.contains("yi") { return .pink }
        if p.contains("phind") { return .indigo }
        if p.contains("sao10k") { return .purple }
        if p.contains("liquid") { return .cyan }
        return .gray
    }
}

private extension View {
    /// Invisible controls must not be clickable or read by VoiceOver; the
    /// row exposes the same actions as accessibility actions instead.
    func hiddenUnless(_ visible: Bool) -> some View {
        opacity(visible ? 1 : 0)
            .allowsHitTesting(visible)
            .accessibilityHidden(!visible)
    }
}

// MARK: - Model Detail

enum ModelDetailTab: String, CaseIterable, Identifiable {
    case overview = "Overview", providers = "Providers", notes = "Notes"
    var id: String { rawValue }
}

struct ModelDetailView: View {
    let model: ModelInfo
    @ObservedObject var viewModel: BrowserViewModel
    @EnvironmentObject private var shell: ShellController
    @AppStorage(PriceUnit.defaultsKey) private var priceUnit: PriceUnit = .perMillion
    @State private var notes: String = ""
    /// Last value written, so navigation doesn't rewrite unchanged notes
    /// (and never creates empty rows for models nobody annotated).
    @State private var savedNotes: String = ""
    @State private var notesDebounceTask: Task<Void, Never>?
    @State private var tab: ModelDetailTab = .overview

    var body: some View {
        VStack(spacing: 0) {
            stickyHeader
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    switch tab {
                    case .overview:
                        descriptionSection
                        statsGrid
                        capabilitySection
                        benchmarksSection
                        parametersSection
                    case .providers:
                        endpointComparison
                        providersSection
                    case .notes:
                        notesTab
                    }
                    Spacer()
                }
                .padding(24)
            }
        }
        .onAppear {
            notes = viewModel.db.getNotes(model.id)
            savedNotes = notes
        }
        .onChange(of: model.id) { oldID, _ in
            notesDebounceTask?.cancel()
            flushNotes(oldID)
            notes = viewModel.db.getNotes(model.id)
            savedNotes = notes
        }
        .onDisappear {
            notesDebounceTask?.cancel()
            flushNotes(model.id)
        }
    }

    @ViewBuilder
    private func detailActions(isFav: Bool, iconOnly: Bool) -> some View {
        let row = HStack(spacing: 8) {
            Button { shell.send(.chatWithModel(model.id)) } label: { Label("Chat", systemImage: "bubble.left") }
                .buttonStyle(.borderedProminent).tint(ORBTheme.accent)
                .help("Start a chat with this model")
                .accessibilityLabel("Chat with \(model.name)")
            Button { shell.send(.agentWithModel(model.id)) } label: { Label("Agent", systemImage: "wand.and.stars") }
                .help("Run this model in the Agent")
                .accessibilityLabel("Use \(model.name) in the Agent")
            Button { viewModel.toggleFavorite(model) } label: {
                Label(isFav ? "Favorited" : "Favorite", systemImage: isFav ? "star.fill" : "star")
            }
            .help(isFav ? "Remove from favorites" : "Add to favorites")
            .accessibilityLabel(isFav ? "Remove \(model.name) from favorites" : "Add \(model.name) to favorites")
            .accessibilityValue(isFav ? "Favorite" : "Not a favorite")
            Button { viewModel.copyModelId(model) } label: {
                Label(viewModel.copiedModelId == model.id ? "Copied" : "Copy ID",
                      systemImage: viewModel.copiedModelId == model.id ? "checkmark" : "doc.on.doc")
            }
            .help("Copy the model ID")
            .accessibilityLabel("Copy model ID \(model.id)")

            if let url = model.openRouterURL {
                Button { NSWorkspace.shared.open(url) } label: { Label("Open on OpenRouter", systemImage: "safari") }
                    .help("Open on OpenRouter")
                    .accessibilityLabel("Open \(model.name) on OpenRouter")
            }
        }
        .fixedSize()
        if iconOnly { row.labelStyle(.iconOnly) } else { row }
    }

    // MARK: Sticky header

    private var stickyHeader: some View {
        let isFav = viewModel.favoriteIds.contains(model.id)
        return VStack(alignment: .leading, spacing: 10) {
            if viewModel.selectedModel?.id == model.id, viewModel.selectionIsOutsideList {
                HStack(spacing: 8) {
                    Image(systemName: "eye.slash").accessibilityHidden(true)
                    Text("Not in the current list. Kept from your last selection.")
                        .lineLimit(2)
                    Spacer(minLength: 4)
                    Button("Close") { viewModel.selectModel(nil) }
                        .controlSize(.small)
                        .help("Clear the detail pane")
                }
                .font(ORBFont.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.orbSurface(0.05), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityElement(children: .combine)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(model.provider.uppercased())
                    .font(ORBFont.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if model.isUnofficial { Text("UNOFFICIAL").font(ORBFont.caption.weight(.bold)).foregroundStyle(.orange) }
                if model.isAlias { Text("ALIAS").font(ORBFont.caption.weight(.bold)).foregroundStyle(ORBTheme.accentLink) }
                if model.hasExpired {
                    Text("EXPIRED").font(ORBFont.caption.weight(.bold)).foregroundStyle(.red)
                } else if let warning = model.expirationWarning() {
                    Label(warning, systemImage: "clock.badge.exclamationmark")
                        .font(ORBFont.caption.weight(.semibold)).foregroundStyle(.orange)
                        .help("Expires \(model.expirationDate ?? "")")
                }
            }
            if let target = model.aliasTarget {
                Button { shell.send(.selectModel(target.slug)) } label: {
                    Text("Alias of \(target.name ?? target.slug) →")
                        .font(ORBFont.footnote)
                }
                .buttonStyle(.link)
                .help("Currently routes to \(target.slug). Open that model.")
            }
            Text(model.modelSlug).orbFont(size: 22, weight: .semibold).lineLimit(2)
            Text(model.id)
                .orbFont(size: 12, design: .monospaced)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            // Full labels when they fit; icons (with tooltips and spoken
            // labels) in a narrow detail column instead of clipped words.
            ViewThatFits(in: .horizontal) {
                detailActions(isFav: isFav, iconOnly: false)
                detailActions(isFav: isFav, iconOnly: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .controlSize(.regular)
            Picker("Section", selection: $tab) {
                ForEach(ModelDetailTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 360)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }

    // MARK: Endpoint price/latency comparison

    @ViewBuilder
    private var endpointComparison: some View {
        let eps = viewModel.endpoints
        if eps.count > 1 {
            let cheapest = eps.compactMap(\.promptCostPer1M).min()
            let unit = priceUnit
            let fastest = eps.compactMap(\.latencyLast30m).min()
            VStack(alignment: .leading, spacing: 6) {
                Text("Price and latency by provider").font(.headline)
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                    GridRow {
                        Text("Provider"); Text("Input / \(unit.suffix)"); Text("Output / \(unit.suffix)"); Text("Latency"); Text("Throughput")
                    }
                    .font(ORBFont.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(eps) { ep in
                        GridRow {
                            Text(ep.displayName).lineLimit(1)
                            HStack(spacing: 3) {
                                Text(PriceDisplay.perToken(ep.pricing?.prompt).map { PriceDisplay.amount(perToken: $0, unit: unit) } ?? "—")
                                if let c = ep.promptCostPer1M, c == cheapest {
                                    Image(systemName: "checkmark.seal.fill").foregroundStyle(ORBTheme.success)
                                        .help("Cheapest input").accessibilityLabel("Cheapest input")
                                }
                            }
                            Text(PriceDisplay.perToken(ep.pricing?.completion).map { PriceDisplay.amount(perToken: $0, unit: unit) } ?? "—")
                            HStack(spacing: 3) {
                                Text(ep.latencyLast30m.map { "\($0) ms" } ?? "—")
                                if let l = ep.latencyLast30m, l == fastest {
                                    Image(systemName: "bolt.fill").foregroundStyle(ORBTheme.success)
                                        .help("Lowest latency").accessibilityLabel("Lowest latency")
                                }
                            }
                            Text(ep.throughputLast30m.map { "\($0) tok/s" } ?? "—")
                        }
                        .font(ORBFont.footnote)
                    }
                }
            }
        }
    }

    // MARK: Notes tab

    private var notesTab: some View { notesSection }

    private func flushNotes(_ modelID: String) {
        guard notes != savedNotes else { return }
        viewModel.saveNotes(notes, for: modelID)
        savedNotes = notes
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

    @ViewBuilder
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
                if let p = PriceDisplay.perToken(model.pricing?.prompt), p > 0 {
                    StatCard(title: "Input $/\(priceUnit.suffix)", value: PriceDisplay.amount(perToken: p, unit: priceUnit), icon: "arrow.down.circle", color: .orange)
                }
                if let c = PriceDisplay.perToken(model.pricing?.completion), c > 0 {
                    StatCard(title: "Output $/\(priceUnit.suffix)", value: PriceDisplay.amount(perToken: c, unit: priceUnit), icon: "arrow.up.circle", color: .red)
                }
                if PriceDisplay.perToken(model.pricing?.prompt) == nil, model.pricing?.prompt != nil {
                    StatCard(title: "Price", value: "Variable", icon: "arrow.triangle.swap", color: .orange)
                }
            }
            ForEach(model.pricing?.extraLines(unit: priceUnit) ?? []) { line in
                StatCard(title: line.title, value: line.value, icon: "dollarsign.circle", color: .yellow)
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
        pricingTiersSection
    }

    /// Override tiers (long-context or time-window prices).
    @ViewBuilder
    private var pricingTiersSection: some View {
        let tiers = model.pricing?.tierLines(unit: priceUnit) ?? []
        if !tiers.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Pricing tiers").font(.headline)
                ForEach(tiers) { tier in
                    HStack(alignment: .firstTextBaseline) {
                        Text(tier.title).font(ORBFont.footnote).foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        Text(tier.value).font(ORBFont.footnote).monospacedDigit().textSelection(.enabled)
                    }
                }
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
                CapabilityTag(label: "Video In", active: model.supportsVideoInput, color: .indigo)
                CapabilityTag(label: "Audio In", active: model.supportsAudioInput, color: .mint)
                CapabilityTag(label: "Files", active: model.supportsFileInput, color: .cyan)
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
                                .orbFont(size: 11, weight: .semibold)
                            Text("\(Int(entry.elo ?? 0))")
                                .orbFont(size: 11, design: .monospaced)
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
                if let error = viewModel.api.endpointsError {
                    HStack(spacing: 6) {
                        Image(systemName: "wifi.exclamationmark")
                            .foregroundStyle(.orange)
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Retry") {
                            viewModel.refetchEndpoints()
                        }
                        .font(.caption)
                    }
                } else {
                    Text("No per-provider data available")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                VStack(spacing: 6) {
                    ForEach(viewModel.endpoints) { ep in
                        ProviderRow(endpoint: ep, unit: priceUnit)
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
                            .orbFont(size: 11, design: .monospaced)
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

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Notes")
                .font(.headline)
            Text("Private to this Mac. Saved automatically.")
                .font(ORBFont.caption).foregroundStyle(.secondary)
            TextEditor(text: $notes)
                .font(.body)
                .frame(minHeight: 120)
                .padding(6)
                .background(.quaternary.opacity(0.3))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel("Notes for \(model.name)")
                .onChange(of: notes) { _, newValue in
                    notesDebounceTask?.cancel()
                    let modelID = model.id
                    notesDebounceTask = Task {
                        try? await Task.sleep(nanoseconds: 800_000_000)
                        guard !Task.isCancelled, modelID == model.id, newValue != savedNotes else { return }
                        viewModel.saveNotes(newValue, for: modelID)
                        savedNotes = newValue
                    }
                }
        }
    }
}

// MARK: - Provider Row

struct ProviderRow: View {
    let endpoint: ModelEndpoint
    var unit: PriceUnit = .perMillion

    var body: some View {
        HStack(spacing: 12) {
            // Status dot
            Circle()
                .fill(endpoint.isAvailable ? Color.green : Color.red)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(endpoint.displayName)
                    .orbFont(size: 13, weight: .semibold)
                    .lineLimit(1)
                HStack(spacing: 10) {
                    if let ctx = endpoint.contextLength {
                        Text(ctxFormatted(ctx))
                            .foregroundStyle(.secondary)
                    }
                    if let q = endpoint.quantization, !q.isEmpty, q != "unknown" {
                        Text(q.uppercased())
                            .orbFont(size: 11, weight: .bold, design: .monospaced)
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
                .orbFont(size: 11)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                if let p = PriceDisplay.perToken(endpoint.pricing?.prompt),
                   let c = PriceDisplay.perToken(endpoint.pricing?.completion) {
                    Text("\(PriceDisplay.amount(perToken: p, unit: unit)) in")
                    Text("\(PriceDisplay.amount(perToken: c, unit: unit)) out")
                    ForEach(endpoint.pricing?.extraLines(unit: unit).prefix(2) ?? []) { line in
                        Text("\(line.title): \(line.value)").foregroundStyle(.secondary)
                    }
                } else {
                    Text("—")
                }
            }
            .orbFont(size: 11, design: .monospaced)
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
                    .orbFont(size: 11)
                    .foregroundStyle(color)
                Text(title)
                    .orbFont(size: 11)
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .orbFont(size: 17, weight: .semibold)
                .monospacedDigit()
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.orbSurface(0.04), in: RoundedRectangle(cornerRadius: ORBMetrics.cardRadius))
        .overlay { RoundedRectangle(cornerRadius: ORBMetrics.cardRadius).stroke(.orbSurface(0.07), lineWidth: 0.5) }
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
                .orbFont(size: 14, weight: .bold, design: .monospaced)
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
                .orbFont(size: 11)
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
                .orbFont(size: 11)
            Text(label)
                .orbFont(size: 12, weight: .medium)
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
