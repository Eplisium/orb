import SwiftUI

/// Manages MCP server configurations: add, enable/disable, test, and import
/// from a standard `mcpServers` JSON blob.
struct MCPSettingsView: View {
    let accent: Color
    /// When embedded in the Settings window there is no sheet to dismiss, so
    /// the fixed frame and the Done button are both dropped.
    var isEmbedded = true
    @Environment(\.dismiss) private var dismiss

    @State private var configs: [MCPServerConfig] = MCPRegistry.loadConfigs()
    @State private var status: [String: String] = [:]
    @State private var probing: Set<UUID> = []
    @State private var importText = ""
    @State private var showImport = false
    @State private var importError: String?
    // Consent-driven secret migration (F01 step 5): per-server checkbox
    // selection (keyed by config id), in-flight markers, and the reported
    // outcome. Only variable NAMES are ever held or displayed — values are
    // resolved through the injected store, never shown or logged.
    @State private var secretSelection: [UUID: Set<String>] = [:]
    @State private var migrating: Set<UUID> = []
    @State private var migrationOutcomes: [UUID: MCPSecretMigrationOutcome] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            if configs.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach($configs) { $config in
                            serverRow($config)
                        }
                    }
                    .padding(14)
                }
            }

            Divider()
            footer
        }
        .frame(
            width: isEmbedded ? nil : 560,
            height: isEmbedded ? nil : 460
        )
        .frame(maxWidth: isEmbedded ? .infinity : nil, alignment: .leading)
        .sheet(isPresented: $showImport) { importSheet }
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: "puzzlepiece.extension.fill")
                .foregroundStyle(accent)
            VStack(alignment: .leading, spacing: 1) {
                Text("MCP Servers")
                    .font(.headline)
                Text("Model Context Protocol tools become available to the agent automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !isEmbedded {
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "puzzlepiece.extension")
                .orbFont(size: 30)
                .foregroundStyle(.tertiary)
            Text("No MCP servers configured")
                .orbFont(size: 12, weight: .semibold)
            Text("Add a server or paste an existing mcpServers configuration.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func serverRow(_ config: Binding<MCPServerConfig>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Toggle("", isOn: config.isEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                TextField("Name", text: config.name)
                    .textFieldStyle(.plain)
                    .orbFont(size: 12, weight: .semibold)
                Spacer()
                if probing.contains(config.wrappedValue.id) {
                    ProgressView().controlSize(.mini)
                } else {
                    Button("Test") { probe(config.wrappedValue) }
                        .controlSize(.small)
                }
                Button {
                    configs.removeAll { $0.id == config.wrappedValue.id }
                    persist()
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove server")
            }

            TextField("Command (e.g. npx)", text: config.command)
                .textFieldStyle(.roundedBorder)
                .orbFont(size: 11, design: .monospaced)

            TextField(
                "Arguments (space separated)",
                text: Binding(
                    get: { config.wrappedValue.args.joined(separator: " ") },
                    set: { config.wrappedValue.args = $0.split(separator: " ").map(String.init) }
                )
            )
            .textFieldStyle(.roundedBorder)
            .orbFont(size: 11, design: .monospaced)

            secretConsentSection(config.wrappedValue)

            if let message = status[config.wrappedValue.name] {
                Text(message)
                    .orbFont(size: 11)
                    .foregroundStyle(message.hasPrefix("✓") ? .green : .red)
            }
        }
        .padding(10)
        .background(.orbSurface(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onChange(of: config.wrappedValue) { _, _ in persist() }
    }

    private var footer: some View {
        HStack {
            Button {
                configs.append(MCPServerConfig(name: "New Server", command: ""))
                persist()
            } label: {
                Label("Add Server", systemImage: "plus")
            }
            Button {
                importText = ""
                importError = nil
                showImport = true
            } label: {
                Label("Import JSON", systemImage: "square.and.arrow.down")
            }
            Spacer()
            Button("Reconnect All") {
                Task {
                    await MCPRegistry.shared.shutdownAll()
                    await MCPRegistry.shared.startEnabledServers()
                    await refreshStatus()
                }
            }
        }
        .controlSize(.small)
        .padding(12)
    }

    private var importSheet: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Paste an mcpServers configuration")
                .font(.headline)
            Text("The same format Claude Desktop and other MCP hosts use.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $importText)
                .orbFont(size: 11, design: .monospaced)
                .frame(height: 200)
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.primary.opacity(0.12))
                }
            if let importError {
                Text(importError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { showImport = false }
                Button("Import") {
                    do {
                        let imported = try MCPRegistry.parseStandardConfig(importText)
                        // Replace same-named entries so re-importing is idempotent.
                        let names = Set(imported.map(\.name))
                        configs.removeAll { names.contains($0.name) }
                        configs += imported
                        persist()
                        showImport = false
                    } catch {
                        importError = error.localizedDescription
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 460)
    }

    // MARK: - Secret migration consent (F01 step 5)

    /// Lists this server's env variable NAMES and lets the user consent to
    /// moving selected values into the macOS Keychain. Nothing migrates
    /// automatically: the button is the only trigger, the migrated values are
    /// never displayed, and the reported outcome comes straight from the
    /// migration call.
    @ViewBuilder
    private func secretConsentSection(_ config: MCPServerConfig) -> some View {
        let stored = (config.secretEnv ?? [:]).keys.sorted()
        let candidates = config.env.keys.sorted()

        if !stored.isEmpty {
            HStack(spacing: 5) {
                Image(systemName: "lock.fill")
                    .orbFont(size: 11)
                    .foregroundStyle(.green)
                Text("In the Keychain: \(stored.joined(separator: ", "))")
                    .orbFont(size: 11)
                    .foregroundStyle(.secondary)
            }
        }

        if !candidates.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("ENV VALUES")
                    .orbFont(size: 11, weight: .bold)
                    .foregroundStyle(.secondary)
                Text("Selected values move into the macOS Keychain; the settings file keeps only a reference. Values are never shown.")
                    .orbFont(size: 11)
                    .foregroundStyle(.secondary)
                ForEach(candidates, id: \.self) { variable in
                    Toggle(isOn: secretSelectionBinding(config, variable)) {
                        Text(variable)
                            .orbFont(size: 11, design: .monospaced)
                    }
                    .toggleStyle(.checkbox)
                }
                HStack(spacing: 6) {
                    Button {
                        migrateSecrets(config)
                    } label: {
                        Text(migrateButtonLabel(config))
                    }
                    .controlSize(.small)
                    .disabled(effectiveSelection(config).isEmpty || migrating.contains(config.id))

                    if migrating.contains(config.id) {
                        ProgressView().controlSize(.mini)
                    }
                }
                if let outcome = migrationOutcomes[config.id] {
                    Text(migrationMessage(outcome))
                        .orbFont(size: 11)
                        .foregroundStyle(outcome.didSucceed ? .green : .red)
                }
            }
        }
    }

    private func migrateButtonLabel(_ config: MCPServerConfig) -> String {
        let count = effectiveSelection(config).count
        return count == 1 ? "Move 1 value to Keychain" : "Move \(count) values to Keychain"
    }

    /// The variables the migration would move right now: the user's explicit
    /// selection, defaulting to the name-heuristic guesses.
    private func effectiveSelection(_ config: MCPServerConfig) -> Set<String> {
        if let chosen = secretSelection[config.id] { return chosen }
        return Set(config.env.keys.filter { MCPServerConfig.looksLikeSecret($0) })
    }

    private func secretSelectionBinding(
        _ config: MCPServerConfig, _ variable: String
    ) -> Binding<Bool> {
        Binding<Bool>(
            get: { effectiveSelection(config).contains(variable) },
            set: { on in
                var current = secretSelection[config.id]
                    ?? Set(config.env.keys.filter { MCPServerConfig.looksLikeSecret($0) })
                if on { current.insert(variable) } else { current.remove(variable) }
                secretSelection[config.id] = current
            }
        )
    }

    private func migrateSecrets(_ config: MCPServerConfig) {
        let variables = effectiveSelection(config).sorted()
        guard !variables.isEmpty, !migrating.contains(config.id) else { return }
        migrating.insert(config.id)
        Task {
            // Production path: the Keychain-backed store resolves and holds
            // the values; the rewritten configs carry references only.
            let (updated, outcome) = MCPRegistry.migrateSecretsToKeychain(
                configs: configs,
                serverNamed: config.name,
                variables: variables,
                store: KeychainCredentialStore()
            )
            await MainActor.run {
                migrating.remove(config.id)
                migrationOutcomes[config.id] = outcome
                if outcome.didSucceed {
                    configs = updated
                    persist()
                    secretSelection[config.id] = nil
                }
            }
        }
    }

    private func migrationMessage(_ outcome: MCPSecretMigrationOutcome) -> String {
        if let error = outcome.error { return error }
        var parts: [String] = []
        if !outcome.migratedVariables.isEmpty {
            parts.append("Moved \(outcome.migratedVariables.joined(separator: ", ")) into the Keychain.")
        }
        if !outcome.alreadyMigratedVariables.isEmpty {
            parts.append("Already stored: \(outcome.alreadyMigratedVariables.joined(separator: ", ")).")
        }
        if parts.isEmpty { return "Nothing to migrate." }
        return "✓ " + parts.joined(separator: " ") + " Reconnect the server to pick the values up."
    }

    private func persist() {
        MCPRegistry.saveConfigs(configs)
    }

    private func probe(_ config: MCPServerConfig) {
        probing.insert(config.id)
        Task {
            let outcome = await MCPRegistry.shared.probe(config)
            await MainActor.run {
                probing.remove(config.id)
                switch outcome {
                case .success(let report):
                    let detail = report.detail.isEmpty ? "" : "\n" + report.detail
                    status[config.name] = "✓ Connected — \(report.summary)" + detail
                case .failure(let error):
                    status[config.name] = error.localizedDescription
                }
            }
        }
    }

    private func refreshStatus() async {
        let rows = await MCPRegistry.shared.status()
        await MainActor.run {
            for row in rows {
                status[row.name] = row.error ?? "✓ Connected — \(row.toolCount) tool(s)"
            }
        }
    }
}
