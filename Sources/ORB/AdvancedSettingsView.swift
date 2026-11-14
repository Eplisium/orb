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
    @State private var schemaDraft = JSONSchemaDraft()

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
                    outputSection
                    Divider()
                    identitySection
                    Divider()
                    extrasSection
                }
                .padding(20)
            }
            Divider()
            footer
        }
        .frame(width: 560, height: 640)
        .onAppear {
            // Show the schema that is actually stored, not the example.
            if let stored = JSONSchemaDraft(stored: settings.responseFormat) { schemaDraft = stored }
        }
        .onChange(of: schemaDraft) { _, draft in
            // Typing in the schema fields must reach the request; before,
            // only moving the picker committed them.
            var format = settings.responseFormat
            draft.commit(into: &format)
            if format != settings.responseFormat { settings.responseFormat = format }
        }
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

    private var outputSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("Output Shape", "text.badge.checkmark")
            VStack(alignment: .leading, spacing: 6) {
                Text("Response format").font(.callout)
                Picker("Response format", selection: responseFormatSelection) {
                    Text("Model default").tag(0)
                    Text("JSON object").tag(1)
                    Text("JSON Schema").tag(2)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text("JSON object requires the prompt to ask for JSON. JSON Schema needs a supporting model.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if responseFormatSelection.wrappedValue == 2 {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Schema name").font(.callout)
                    TextField("e.g. answer", text: $schemaDraft.name)
                        .textFieldStyle(.roundedBorder)
                    Text("JSON Schema (object)").font(.callout)
                    TextEditor(text: $schemaDraft.text)
                        .orbFont(size: 11, design: .monospaced)
                        .frame(minHeight: 90)
                        .overlay {
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.primary.opacity(0.10), lineWidth: 1)
                        }
                    Toggle("Strict mode", isOn: $schemaDraft.strict)
                    if let schemaError = schemaDraft.error {
                        Label(schemaError, systemImage: "exclamationmark.triangle")
                            .orbFont(.caption).foregroundStyle(ORBTheme.warning)
                    }
                }
            }
            optionalIntStepper("Max completion tokens", value: $settings.maxCompletionTokens,
                               range: 1...1_000_000, step: 256,
                               help: "New-style completion cap. Leave off unless the model needs it.")
            VStack(alignment: .leading, spacing: 6) {
                Text("Service tier").font(.callout)
                Picker("Service tier", selection: $settings.serviceTier) {
                    Text("Provider default").tag(ServiceTier?.none)
                    ForEach(ServiceTier.allCases) { tier in
                        Text(tier.label).tag(ServiceTier?.some(tier))
                    }
                }
                Text("Priority costs more; flex trades speed for price.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Output modalities").font(.callout)
                Toggle("Request image output", isOn: modalityBinding(.image))
                    .help("Ask image-capable models to return pictures alongside text.")
                Toggle("Request audio output", isOn: modalityBinding(.audio))
                    .help("Ask audio-capable models to return speech alongside text.")
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Image config").font(.callout)
                TextField("Aspect ratio (e.g. 16:9, optional)", text: imageAspectBinding)
                    .textFieldStyle(.roundedBorder)
                TextField("Quality (e.g. high, optional)", text: imageQualityBinding)
                    .textFieldStyle(.roundedBorder)
                Text("Only sent for image-output models when filled in.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var identitySection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("Identity & Routing Extras", "person.badge.key")
            VStack(alignment: .leading, spacing: 6) {
                Text("End-user ID (optional)").font(.callout)
                TextField("Stable ID for abuse isolation", text: endUserBinding)
                    .textFieldStyle(.roundedBorder)
                Text("Hashed upstream; never sent to providers verbatim.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Session ID (optional)").font(.callout)
                TextField("Groups related requests; sticky routing key", text: sessionBinding)
                    .textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Max price caps (USD, optional)").font(.callout)
                optionalPriceStepper("Prompt $/1M tokens", value: $settings.provider.maxPromptPrice)
                optionalPriceStepper("Completion $/1M tokens", value: $settings.provider.maxCompletionPrice)
                optionalPriceStepper("Per image", value: $settings.provider.maxImagePrice)
                optionalPriceStepper("Per audio unit", value: $settings.provider.maxAudioPrice)
                optionalPriceStepper("Per request", value: $settings.provider.maxRequestPrice)
                Text("Requests fail rather than route above these caps.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Extra plugins").font(.callout)
                ForEach(ExtraPlugin.Kind.allCases) { kind in
                    Toggle(kind.label, isOn: extraPluginBinding(kind))
                }
                Text("File parser helps PDF-heavy chats; moderation and healing run server-side.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Output-shape bindings
    //
    // ResponseFormatSettings is an enum, so the schema fields are edited in
    // a `JSONSchemaDraft` that is seeded from settings when the sheet opens
    // and committed back whenever a field or the picker changes.

    private var responseFormatSelection: Binding<Int> {
        Binding(
            get: {
                switch settings.responseFormat {
                case .off: return 0
                case .jsonObject: return 1
                case .jsonSchema: return 2
                }
            },
            set: { commitResponseFormat(selection: $0) }
        )
    }

    private func commitResponseFormat(selection: Int) {
        switch selection {
        case 1:
            settings.responseFormat = .jsonObject
        case 2:
            settings.responseFormat = schemaDraft.responseFormat(keeping: nil)
        default:
            settings.responseFormat = .off
        }
    }

    private func modalityBinding(_ modality: OutputModality) -> Binding<Bool> {
        Binding(
            get: { settings.modalities.contains(modality) },
            set: { enabled in
                if enabled, !settings.modalities.contains(modality) {
                    settings.modalities.append(modality)
                } else if !enabled {
                    settings.modalities.removeAll { $0 == modality }
                }
            }
        )
    }

    private var imageAspectBinding: Binding<String> {
        Binding(
            get: { settings.imageConfig.aspectRatio ?? "" },
            set: { settings.imageConfig.aspectRatio = $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        )
    }

    private var imageQualityBinding: Binding<String> {
        Binding(
            get: { settings.imageConfig.quality ?? "" },
            set: { settings.imageConfig.quality = $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        )
    }

    private var endUserBinding: Binding<String> {
        Binding(
            get: { settings.endUserId ?? "" },
            set: { settings.endUserId = $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        )
    }

    private var sessionBinding: Binding<String> {
        Binding(
            get: { settings.sessionId ?? "" },
            set: { settings.sessionId = $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        )
    }

    private func extraPluginBinding(_ kind: ExtraPlugin.Kind) -> Binding<Bool> {
        Binding(
            get: { settings.extraPlugins.contains { $0.kind == kind } },
            set: { enabled in
                if enabled, !settings.extraPlugins.contains(where: { $0.kind == kind }) {
                    settings.extraPlugins.append(ExtraPlugin(kind: kind))
                } else if !enabled {
                    settings.extraPlugins.removeAll { $0.kind == kind }
                }
            }
        )
    }

    private func optionalPriceStepper(_ title: String, value: Binding<Double?>) -> some View {
        HStack {
            Toggle(isOn: Binding(
                get: { value.wrappedValue != nil },
                set: { value.wrappedValue = $0 ? (value.wrappedValue ?? 5.0) : nil }
            )) {
                Text(title).font(.callout)
            }
            .toggleStyle(.checkbox)
            Spacer()
            if let current = value.wrappedValue {
                TextField("USD", value: Binding(
                    get: { current },
                    set: { value.wrappedValue = $0 }
                ), format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 90)
            } else {
                Text("no cap").font(.caption).foregroundStyle(.secondary)
            }
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

/// The editable JSON Schema fields of Request Parameters. Kept apart from the
/// view so seeding from the stored format and committing edits can be tested.
struct JSONSchemaDraft: Equatable {
    static let defaultName = "response"
    static let exampleText = """
        {"type":"object","properties":{"answer":{"type":"string"}},"required":["answer"]}
        """

    var name = JSONSchemaDraft.defaultName
    var text = JSONSchemaDraft.exampleText
    var strict = true

    init() {}

    /// The draft for a stored JSON Schema format; nil for any other format,
    /// so the caller keeps what it has (the example, on first use).
    init?(stored format: ResponseFormatSettings) {
        guard case .jsonSchema(let name, let schema, let strict) = format else { return nil }
        self.name = name
        self.text = Self.render(schema)
        self.strict = strict
    }

    /// The schema text as a JSON object; nil while it does not parse.
    var parsedSchema: JSONValue? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else { return nil }
        return JSONValue(any: dict)
    }

    var error: String? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Give the schema a name." }
        if parsedSchema == nil { return "Schema must be a valid JSON object." }
        return nil
    }

    /// The format these fields describe. While the text does not parse, the
    /// schema falls back to `previous` (the last valid one) and then to an
    /// empty object, so a half-typed edit never replaces a working schema.
    func responseFormat(keeping previous: JSONValue?) -> ResponseFormatSettings {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return .jsonSchema(
            name: trimmed.isEmpty ? Self.defaultName : trimmed,
            schema: parsedSchema ?? previous ?? .object([:]),
            strict: strict
        )
    }

    /// Writes the fields into `format` when it is a JSON Schema format.
    /// Other formats are left alone: editing the hidden fields must not
    /// switch the response format on.
    func commit(into format: inout ResponseFormatSettings) {
        guard case .jsonSchema(_, let stored, _) = format else { return }
        format = responseFormat(keeping: stored)
    }

    private static func render(_ schema: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(schema), let text = String(data: data, encoding: .utf8) else {
            return exampleText
        }
        return text
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
                            .accessibilityLabel("Remove \(item)")
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
