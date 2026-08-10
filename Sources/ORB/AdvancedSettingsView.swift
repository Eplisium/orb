import SwiftUI

/// Full OpenRouter parameter surface: sampling, penalties, reasoning, routing,
/// fallbacks, and plugins.
///
/// Every control binds to an optional. "Provider default" is a real, distinct
/// state from any specific value — toggling a parameter off omits it from the
/// request rather than sending a value ORB chose.
struct AdvancedSettingsView: View {
    let accent: Color
    @Binding var settings: GenerationSettings
    @Environment(\.dismiss) private var dismiss

    @State private var stopEntry = ""
    @State private var orderEntry = ""
    @State private var ignoreEntry = ""
    @State private var fallbackEntry = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    samplingSection
                    Divider()
                    penaltySection
                    Divider()
                    reasoningSection
                    Divider()
                    routingSection
                    Divider()
                    extrasSection
                }
                .padding(20)
            }
            Divider()
            footer
        }
        .frame(width: 560, height: 640)
    }

    private var header: some View {
        HStack {
            Label("Request Parameters", systemImage: "slider.horizontal.3")
                .font(.headline)
            Spacer()
            if !settings.activeSummary.isEmpty {
                Text("\(settings.activeSummary.count) active")
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(accent.opacity(0.18), in: Capsule())
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var footer: some View {
        HStack {
            Button("Reset to Defaults") { settings = .default }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: Sections

    private var samplingSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("Sampling", "dial.medium")
            optionalSlider("Temperature", value: $settings.temperature, range: 0...2, step: 0.05,
                           help: "Higher values increase variety. 0 is deterministic.")
            optionalSlider("Top P", value: $settings.topP, range: 0...1, step: 0.01,
                           help: "Nucleus sampling: consider only the top tokens summing to P.")
            optionalIntStepper("Top K", value: $settings.topK, range: 0...200,
                               help: "Limit choices to the K most likely tokens. 0 disables.")
            optionalSlider("Min P", value: $settings.minP, range: 0...1, step: 0.01,
                           help: "Minimum probability relative to the best token.")
            optionalSlider("Top A", value: $settings.topA, range: 0...1, step: 0.01,
                           help: "Dynamic filter scaled by the top token's probability.")
            optionalIntStepper("Seed", value: $settings.seed, range: 0...999_999,
                               help: "Deterministic sampling when the provider supports it.")
            optionalIntStepper("Max Tokens", value: $settings.maxTokens, range: 1...1_000_000,
                               step: 256, help: "Upper bound on generated tokens.")
        }
    }

    private var penaltySection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("Repetition Control", "repeat")
            optionalSlider("Frequency Penalty", value: $settings.frequencyPenalty, range: -2...2, step: 0.05,
                           help: "Penalizes tokens by how often they already appear.")
            optionalSlider("Presence Penalty", value: $settings.presencePenalty, range: -2...2, step: 0.05,
                           help: "Penalizes tokens that appeared at all.")
            optionalSlider("Repetition Penalty", value: $settings.repetitionPenalty, range: 0.01...2, step: 0.01,
                           help: "Multiplicative penalty on repeated tokens.")
            tokenListEditor(
                title: "Stop Sequences",
                help: "Generation halts when any of these strings appears.",
                entry: $stopEntry,
                items: $settings.stop,
                placeholder: "e.g. \\n\\nUser:"
            )
        }
    }

    private var reasoningSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("Reasoning", "brain")
            Picker("Effort", selection: Binding(
                get: { settings.reasoning.effort },
                set: { newValue in
                    settings.reasoning.effort = newValue
                    // Effort and an explicit budget are mutually exclusive.
                    if newValue != nil { settings.reasoning.maxTokens = nil }
                }
            )) {
                Text("Provider default").tag(ReasoningSettings.Effort?.none)
                ForEach(ReasoningSettings.Effort.allCases) { effort in
                    Text(effort.label).tag(ReasoningSettings.Effort?.some(effort))
                }
            }
            if settings.reasoning.effort == nil {
                optionalIntStepper("Reasoning Budget", value: $settings.reasoning.maxTokens,
                                   range: 1...200_000, step: 512,
                                   help: "Anthropic-style explicit thinking token budget.")
            }
            Toggle("Hide reasoning from response", isOn: $settings.reasoning.exclude)
                .help("The model still thinks, but reasoning tokens are not returned.")
            Toggle("Enable with provider defaults", isOn: $settings.reasoning.enabled)
                .disabled(settings.reasoning.effort != nil || settings.reasoning.maxTokens != nil)
        }
    }

    private var routingSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("Provider Routing", "point.3.connected.trianglepath.dotted")
            Picker("Optimize for", selection: $settings.provider.sort) {
                ForEach(ProviderSettings.Sort.allCases) { sort in
                    Text(sort.label).tag(sort)
                }
            }
            Picker("Data collection", selection: $settings.provider.dataCollection) {
                ForEach(ProviderSettings.DataCollection.allCases) { policy in
                    Text(policy.label).tag(policy)
                }
            }
            Toggle("Allow fallback providers", isOn: $settings.provider.allowFallbacks)
                .help("When off, the request fails rather than routing elsewhere.")
            Toggle("Require full parameter support", isOn: $settings.provider.requireParameters)
                .help("Skip providers that don't support every parameter you set.")
            Toggle("Require zero data retention", isOn: $settings.provider.zeroDataRetention)
            tokenListEditor(
                title: "Preferred Providers (in order)",
                help: "Provider slugs to try first, e.g. anthropic, openai.",
                entry: $orderEntry,
                items: $settings.provider.order,
                placeholder: "anthropic"
            )
            tokenListEditor(
                title: "Ignored Providers",
                help: "Never route to these providers.",
                entry: $ignoreEntry,
                items: $settings.provider.ignore,
                placeholder: "deepinfra"
            )
        }
    }

    private var extrasSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("Extras", "sparkles")
            Toggle("Enable web search", isOn: $settings.webSearch)
                .help("Adds OpenRouter's web plugin so the model can search online.")
            if settings.webSearch {
                optionalIntStepper("Max web results", value: $settings.webSearchMaxResults,
                                   range: 1...10, help: "Number of search results to inject.")
            }
            Toggle("Compress long context (middle-out)", isOn: Binding(
                get: { settings.transforms.contains("middle-out") },
                set: { enabled in
                    if enabled {
                        if !settings.transforms.contains("middle-out") {
                            settings.transforms.append("middle-out")
                        }
                    } else {
                        settings.transforms.removeAll { $0 == "middle-out" }
                    }
                }
            ))
            .help("Drops middle messages when a conversation exceeds the context window.")
            Toggle("Report usage and cost", isOn: $settings.includeUsageAccounting)
            tokenListEditor(
                title: "Fallback Models",
                help: "Tried in order if the primary model is unavailable.",
                entry: $fallbackEntry,
                items: $settings.fallbackModels,
                placeholder: "openai/gpt-4o-mini"
            )
        }
    }

    // MARK: Reusable controls

    private func sectionTitle(_ text: String, _ icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(accent)
    }

    /// A slider that can also be "off", meaning the parameter is omitted and
    /// the provider default applies.
    private func optionalSlider(
        _ title: String,
        value: Binding<Double?>,
        range: ClosedRange<Double>,
        step: Double,
        help: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Toggle(isOn: Binding(
                    get: { value.wrappedValue != nil },
                    set: { value.wrappedValue = $0 ? (value.wrappedValue ?? defaultValue(in: range)) : nil }
                )) {
                    Text(title).font(.callout)
                }
                .toggleStyle(.checkbox)
                Spacer()
                Text(value.wrappedValue.map { String(format: "%.2f", $0) } ?? "provider default")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(value.wrappedValue == nil ? .secondary : .primary)
            }
            if let current = value.wrappedValue {
                Slider(
                    value: Binding(get: { current }, set: { value.wrappedValue = $0 }),
                    in: range,
                    step: step
                )
                .tint(accent)
            }
            Text(help).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func optionalIntStepper(
        _ title: String,
        value: Binding<Int?>,
        range: ClosedRange<Int>,
        step: Int = 1,
        help: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Toggle(isOn: Binding(
                    get: { value.wrappedValue != nil },
                    set: { value.wrappedValue = $0 ? (value.wrappedValue ?? range.lowerBound) : nil }
                )) {
                    Text(title).font(.callout)
                }
                .toggleStyle(.checkbox)
                Spacer()
                if let current = value.wrappedValue {
                    Stepper(
                        value: Binding(get: { current }, set: { value.wrappedValue = $0 }),
                        in: range,
                        step: step
                    ) {
                        Text("\(current)").font(.caption.monospacedDigit())
                    }
                    .fixedSize()
                } else {
                    Text("provider default").font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(help).font(.caption2).foregroundStyle(.secondary)
        }
    }

    /// Chip-style editor for the several string-array parameters.
    private func tokenListEditor(
        title: String,
        help: String,
        entry: Binding<String>,
        items: Binding<[String]>,
        placeholder: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.callout)
            HStack(spacing: 6) {
                TextField(placeholder, text: entry)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { commit(entry: entry, into: items) }
                Button("Add") { commit(entry: entry, into: items) }
                    .disabled(entry.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if !items.wrappedValue.isEmpty {
                FlowChips(items: items.wrappedValue, accent: accent) { item in
                    items.wrappedValue.removeAll { $0 == item }
                }
            }
            Text(help).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func commit(entry: Binding<String>, into items: Binding<[String]>) {
        let trimmed = entry.wrappedValue.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !items.wrappedValue.contains(trimmed) else { return }
        items.wrappedValue.append(trimmed)
        entry.wrappedValue = ""
    }

    private func defaultValue(in range: ClosedRange<Double>) -> Double {
        range.contains(1) ? 1 : range.lowerBound
    }
}

/// Wrapping row of removable chips.
private struct FlowChips: View {
    let items: [String]
    let accent: Color
    let onRemove: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(rows(), id: \.self) { row in
                HStack(spacing: 6) {
                    ForEach(row, id: \.self) { item in
                        HStack(spacing: 4) {
                            Text(item).font(.caption)
                            Button {
                                onRemove(item)
                            } label: {
                                Image(systemName: "xmark.circle.fill").font(.caption2)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(accent.opacity(0.15), in: Capsule())
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    /// Naive fixed-count chunking. Chips here are short slugs, so this reads
    /// well without the cost of a full layout pass.
    private func rows() -> [[String]] {
        stride(from: 0, to: items.count, by: 3).map {
            Array(items[$0..<min($0 + 3, items.count)])
        }
    }
}
