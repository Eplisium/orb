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

/// A model list row. Equatable on its value inputs (the callbacks always
/// route to the same view model), so with `.equatable()` SwiftUI skips rows
/// whose model, facts and flags did not change.
struct ModelRowView: View, Equatable {
    let model: ModelInfo
    /// Precomputed once per catalog and price unit by the view model.
    let facts: ModelRowFacts
    let isFavorite: Bool
    let isComparing: Bool
    let anyComparing: Bool
    let isCopied: Bool
    var isSelected: Bool = false
    let actions: ModelRowActions
    @State private var isHovered = false

    nonisolated static func == (lhs: ModelRowView, rhs: ModelRowView) -> Bool {
        lhs.model.id == rhs.model.id && lhs.facts == rhs.facts
            && lhs.isFavorite == rhs.isFavorite && lhs.isComparing == rhs.isComparing
            && lhs.anyComparing == rhs.anyComparing && lhs.isCopied == rhs.isCopied
            && lhs.isSelected == rhs.isSelected
    }

    private var handoff: Set<ModelHandoff.Destination> { ModelHandoff.available(for: model) }

    private func factsLine(_ facts: ModelRowFacts, price: String, elo: Bool, icons: Bool) -> some View {
        HStack(spacing: 10) {
            if facts.context != "N/A" { Text(facts.context + " ctx").monospacedDigit() }
            Text(price)
                .monospacedDigit()
                .foregroundStyle(model.isFree ? ORBTheme.success : Color.secondary)
            if elo, let value = model.bestDesignElo { Text("Elo \(Int(value))") }
            if icons { capabilityIcons(facts.capabilities) }
        }
        .lineLimit(1)
        .fixedSize()
    }

    private func titleText(_ facts: ModelRowFacts) -> some View {
        Text(facts.title)
            .font(ORBFont.body.weight(.medium))
            .lineLimit(1)
            .truncationMode(.tail)
    }

    var body: some View {
        let available = handoff
        HStack(spacing: 10) {
            avatar(facts.avatarLetter)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    if isFavorite {
                        Image(systemName: "star.fill")
                            .orbFont(size: 11)
                            .foregroundStyle(.yellow)
                            .accessibilityLabel("Favorite")
                    }
                    // Human name first; the slug follows when there is room
                    // (never as a truncated stub) and is always in the tooltip.
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 6) {
                            titleText(facts)
                            Text(facts.slug)
                                .orbFont(size: 11, design: .monospaced)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                        titleText(facts)
                    }
                    .help(model.id)
                    if model.isAlias {
                        Text("ALIAS").orbFont(size: 11, weight: .bold).foregroundStyle(ORBTheme.accentLink)
                            .fixedSize()
                    }
                    if model.isBatchOnly {
                        Text("BATCH API").orbFont(size: 11, weight: .bold).foregroundStyle(.secondary)
                            .fixedSize()
                            .help(ModelHandoff.unavailableReason(.chat, for: model) ?? "Batch API")
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
                // Drop the least important facts first instead of truncating every one ("1.0M c…", "$0.10…").
                ViewThatFits(in: .horizontal) {
                    factsLine(facts, price: facts.price, elo: true, icons: true)
                    factsLine(facts, price: facts.compactPrice, elo: true, icons: true)
                    factsLine(facts, price: facts.compactPrice, elo: false, icons: true)
                    factsLine(facts, price: facts.compactPrice, elo: false, icons: false)
                }
                .font(ORBFont.caption)
                .foregroundStyle(.secondary)
                .help("\(facts.context) context · \(facts.price)")
            }

            Spacer(minLength: 8)

            quickActions(available)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        // One labelled, selectable element per row (model + provider +
        // state). The hover-only quick buttons are reachable as named
        // actions below.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ModelRowAccessibility.label(model, isFavorite: isFavorite, isComparing: isComparing))
        .accessibilityValue(ModelRowAccessibility.value(facts))
        .accessibilityHint("Shows the model's details")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityActions {
            Button(isFavorite ? "Remove from favorites" : "Add to favorites") { actions.toggleFavorite(model) }
            Button(isComparing ? "Remove from compare" : "Add to compare") { actions.toggleCompare(model) }
            Button("Copy model ID") { actions.copyID(model) }
            if available.contains(.chat) {
                Button("Chat with this model") { actions.chat(model) }
            }
            if available.contains(.agent) {
                Button("Use in the Agent") { actions.agent(model) }
            }
        }
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
            if available.contains(.chat) {
                Button { actions.chat(model) } label: {
                    Label("Chat with this Model", systemImage: "bubble.left")
                }
            } else {
                Button {} label: { Label(model.isBatchOnly ? "Batch API only: can't chat" : "Can't chat with this model", systemImage: "bubble.left") }
                    .disabled(true)
            }
            if available.contains(.agent) {
                Button { actions.agent(model) } label: {
                    Label("Run in Agent", systemImage: "wand.and.stars")
                }
            } else if available.contains(.chat) {
                Button {} label: { Label("Agent needs tool calling", systemImage: "wand.and.stars") }
                    .disabled(true)
            }
            if let url = model.openRouterURL {
                Divider()
                Button { NSWorkspace.shared.open(url) } label: {
                    Label("Open on OpenRouter", systemImage: "safari")
                }
            }
        }
    }

    private func avatar(_ letter: String) -> some View {
        let color = Self.providerColor(for: model.provider)
        return Text(letter)
            .orbFont(size: 13, weight: .bold, design: .rounded)
            .foregroundStyle(color)
            .frame(width: 30, height: 30)
            .background(color.opacity(0.16), in: Circle())
            .help(facts.author.isEmpty ? model.provider : facts.author)
            .accessibilityHidden(true)
    }

    private func quickActions(_ available: Set<ModelHandoff.Destination>) -> some View {
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
            .hiddenUnless(isHovered && available.contains(.chat))
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
    private func capabilityIcons(_ caps: [ModelRowFacts.Badge]) -> some View {
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

    /// System palette colors cycled for providers without a hand-picked one.
    private static let fallbackPalette: [Color] = [.blue, .green, .orange, .purple, .pink, .teal, .indigo, .mint, .cyan, .brown, .red]

    /// Brand-ish colors for well-known authors; any other author gets a
    /// stable palette slot instead of the same grey for everyone.
    static func providerColor(for provider: String) -> Color {
        let p = provider.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "~"))
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
        if p.contains("01-ai") { return .pink }
        if p.contains("phind") { return .indigo }
        if p.contains("sao10k") { return .purple }
        if p.contains("liquid") { return .cyan }
        return fallbackPalette[ProviderPalette.slot(for: p, count: fallbackPalette.count)]
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
    case overview = "Overview", providers = "Providers", api = "API", notes = "Notes"
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
                    case .api:
                        ModelSnippetPanel(model: model)
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
        let chatBlocked = ModelHandoff.unavailableReason(.chat, for: model)
        let agentBlocked = ModelHandoff.unavailableReason(.agent, for: model)
        let row = HStack(spacing: 8) {
            Button { shell.send(.chatWithModel(model.id)) } label: { Label("Chat", systemImage: "bubble.left") }
                .buttonStyle(.borderedProminent).tint(ORBTheme.accent)
                .disabled(chatBlocked != nil)
                .help(chatBlocked ?? "Start a chat with this model")
                .accessibilityLabel("Chat with \(model.displayTitle)")
                .accessibilityHint(chatBlocked ?? "")
            Button { shell.send(.agentWithModel(model.id)) } label: { Label("Agent", systemImage: "wand.and.stars") }
                .disabled(agentBlocked != nil)
                .help(agentBlocked ?? "Run this model in the Agent")
                .accessibilityLabel("Use \(model.displayTitle) in the Agent")
                .accessibilityHint(agentBlocked ?? "")
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
                if model.isBatchOnly {
                    Text("BATCH API").font(ORBFont.caption.weight(.bold)).foregroundStyle(.secondary)
                        .help("Runs only through the Batch API (/api/v1/batches); Chat and Agent can't use it")
                }
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
            Text(model.displayTitle).orbFont(size: 22, weight: .semibold).lineLimit(2)
                .textSelection(.enabled)
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
            let cheapest = ModelEndpoint.cheapestInputPrice(in: eps)
            let unit = priceUnit
            let fastest = eps.compactMap { $0.latencyLast30m?.typical }.min()
            let hasStats = EndpointPerformance.hasStats(eps)
            VStack(alignment: .leading, spacing: 6) {
                Text("Price and latency by provider").font(.headline)
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                    GridRow {
                        Text("Provider"); Text("Input / \(unit.suffix)"); Text("Output / \(unit.suffix)")
                        Text("Latency").help(hasStats ? "Median time to first token over the last 30 minutes" : EndpointPerformance.unavailableHelp)
                        Text("Throughput").help(hasStats ? "Median output tokens per second over the last 30 minutes" : EndpointPerformance.unavailableHelp)
                    }
                    .font(ORBFont.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(eps) { ep in
                        GridRow {
                            Text(ep.displayName).lineLimit(1)
                            HStack(spacing: 3) {
                                Text(PriceDisplay.perToken(ep.pricing?.prompt).map { PriceDisplay.amount(perToken: $0, unit: unit) } ?? "—")
                                if let c = ep.rankingInputPrice, c == cheapest {
                                    Image(systemName: "checkmark.seal.fill").foregroundStyle(ORBTheme.success)
                                        .help("Cheapest input").accessibilityLabel("Cheapest input")
                                }
                            }
                            Text(PriceDisplay.perToken(ep.pricing?.completion).map { PriceDisplay.amount(perToken: $0, unit: unit) } ?? "—")
                            HStack(spacing: 3) {
                                Text(EndpointPerformance.latencyText(ep.latencyLast30m) ?? "—")
                                if let l = ep.latencyLast30m?.typical, l == fastest, eps.count > 1 {
                                    Image(systemName: "bolt.fill").foregroundStyle(ORBTheme.success)
                                        .help("Lowest latency").accessibilityLabel("Lowest latency")
                                }
                            }
                            .help(EndpointPerformance.help(ep.latencyLast30m, unit: "ms", what: "Time to first token"))
                            Text(EndpointPerformance.throughputText(ep.throughputLast30m) ?? "—")
                                .help(EndpointPerformance.help(ep.throughputLast30m, unit: "tokens/s", what: "Output throughput"))
                        }
                        .font(ORBFont.footnote)
                    }
                }
                if !hasStats {
                    Text("Latency and throughput need a signed-in request; ORB loads provider data anonymously.")
                        .font(ORBFont.caption)
                        .foregroundStyle(.tertiary)
                        .help(EndpointPerformance.unavailableHelp)
                }
            }
        }
    }

    // MARK: Notes tab

    private var notesTab: some View { notesSection }

    private func flushNotes(_ modelID: String) {
        guard notes != savedNotes else {
            viewModel.stageNotes(nil, for: modelID)
            return
        }
        viewModel.saveNotes(notes, for: modelID)
        savedNotes = notes
    }

    // MARK: Description

    @ViewBuilder
    private var descriptionSection: some View {
        if let desc = model.description, !desc.isEmpty {
            // Catalog descriptions are Markdown: links open, bold renders.
            Text(CatalogDescriptionText.attributed(desc))
                .font(.body)
                .foregroundStyle(.secondary)
                .tint(ORBTheme.accentLink)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Stats Grid

    @ViewBuilder
    private var statsGrid: some View {
        // Adaptive columns: 3 across in a wide detail pane, 2 when narrow, so values like
        // "text+image->text" and "Oct 7, 2026" are not cut to "text+im…" / "Oct 7, 2…".
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 128), spacing: 12)], spacing: 12) {
            StatCard(title: "Context", value: model.contextLengthFormatted, icon: "arrow.left.arrow.right", color: .blue)
            StatCard(title: "Modality", value: model.modalityLabel, icon: "arrow.triangle.branch", color: .purple)

            if let maxTokens = model.topProvider?.maxCompletionTokens {
                StatCard(title: "Max Output", value: BrowserFormat.context(maxTokens), icon: "text.alignleft", color: .green)
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
                    // Staged on the view model, which writes it if the app
                    // quits before the pause below ends.
                    viewModel.stageNotes(newValue == savedNotes ? nil : newValue, for: modelID)
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
            // Status dot, with the state in words for the tooltip and VoiceOver.
            let status = EndpointStatusPresentation(status: endpoint.status)
            Circle()
                .fill(statusColor(status))
                .frame(width: 8, height: 8)
                .help(status.label)
                .accessibilityLabel(status.label)

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
                    if let uptime = endpoint.uptimeLast1d.flatMap(EndpointUptime.label) {
                        Text(uptime)
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

    private func statusColor(_ status: EndpointStatusPresentation) -> Color {
        switch status {
        case .available: return ORBTheme.success
        case .degraded: return ORBTheme.danger
        case .unknown: return Color.secondary.opacity(0.5)
        }
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
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            Text(value)
                .orbFont(size: 17, weight: .semibold)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .help("\(title): \(value)")
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

// MARK: - API snippet

/// The detail pane's API tab: a ready-to-paste request for this model in
/// curl, Python or TypeScript. The key is always the `$OPENROUTER_API_KEY`
/// placeholder, never the user's credential.
struct ModelSnippetPanel: View {
    let model: ModelInfo
    @AppStorage("orb.browser.snippetLanguage") private var languageRaw = ModelSnippet.Language.curl.rawValue
    @State private var copied = false

    private var language: ModelSnippet.Language {
        ModelSnippet.Language(rawValue: languageRaw) ?? .curl
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Call this model").font(.headline)
            if let snippet = ModelSnippet.render(model: model, language: language) {
                HStack(spacing: 8) {
                    Picker("Language", selection: $languageRaw) {
                        ForEach(ModelSnippet.Language.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 360)
                    Spacer(minLength: 4)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(snippet, forType: .string)
                        copied = true
                        Task {
                            try? await Task.sleep(for: .seconds(2))
                            copied = false
                        }
                    } label: {
                        Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    .help("Copy this \(language.title) example")
                }
                ScrollView(.horizontal) {
                    Text(snippet)
                        .orbFont(size: 12, design: .monospaced)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: true)
                        .padding(12)
                }
                .background(.orbSurface(0.05), in: RoundedRectangle(cornerRadius: ORBMetrics.cardRadius))
                .accessibilityLabel("\(language.title) example")
                Text("Set OPENROUTER_API_KEY in your shell first. The example never includes your key.")
                    .font(ORBFont.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text(model.isBatchOnly
                     ? "This variant runs only through the Batch API (/api/v1/batches), which takes uploaded JSONL files rather than a single request."
                     : "ORB doesn't have a request example for this kind of model yet. See its page on OpenRouter.")
                    .font(ORBFont.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
