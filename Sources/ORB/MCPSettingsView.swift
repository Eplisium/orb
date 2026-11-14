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
    /// Status text per config id (ids survive renames; names do not).
    @State private var status: [UUID: String] = [:]
    /// Enabled rows edited since their process was launched.
    @State private var needsApply: Set<UUID> = []
    @State private var probeTasks: [UUID: Task<Void, Never>] = [:]
    @State private var importText = ""
    @State private var showImport = false
    @State private var importError: String?
    @State private var importNotes: [String] = []
    @State private var pendingRemoval: MCPServerConfig?
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

            if !importNotes.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(importNotes, id: \.self) { note in
                        Label(note, systemImage: "info.circle")
                            .orbFont(size: 11)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 10)
            }

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
        // Live state on open, not only after Test or Reconnect All.
        .task { await refreshStatus() }
        .onReceive(NotificationCenter.default.publisher(for: MCPRegistry.configsDidChange)) { _ in
            let saved = MCPRegistry.loadConfigs()
            if saved != configs { configs = saved }
        }
        .onDisappear {
            for task in probeTasks.values { task.cancel() }
        }
        .confirmationDialog(
            "Remove \(pendingRemoval?.name ?? "this server")?",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            presenting: pendingRemoval
        ) { config in
            Button("Remove Server", role: .destructive) { remove(config) }
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
        } message: { config in
            Text(MCPServerRemoval.confirmationMessage(for: config))
        }
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: "puzzlepiece.extension.fill")
                .foregroundStyle(accent)
            VStack(alignment: .leading, spacing: 1) {
                Text("MCP Servers")
                    .font(.headline)
                Text(MCPAgentAvailability.header)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
        let id = config.wrappedValue.id
        let nameError = MCPRegistry.nameError(for: config.wrappedValue.name, id: id, in: configs)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Toggle("", isOn: config.isEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .accessibilityLabel("Enable \(config.wrappedValue.name)")
                TextField("Name", text: config.name)
                    .textFieldStyle(.plain)
                    .orbFont(size: 12, weight: .semibold)
                Spacer()
                if probeTasks[id] != nil {
                    ProgressView().controlSize(.mini)
                    Button("Cancel") { cancelProbe(id) }
                        .controlSize(.small)
                } else {
                    Button("Test") { probe(config.wrappedValue) }
                        .controlSize(.small)
                        .disabled(nameError != nil)
                }
                Button {
                    pendingRemoval = config.wrappedValue
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove server")
                .help("Remove this server, stop it, and delete its Keychain values")
            }

            if let nameError {
                Label(nameError, systemImage: "exclamationmark.triangle.fill")
                    .orbFont(size: 11)
                    .foregroundStyle(ORBTheme.warning)
            }

            Label(MCPAgentAvailability.status(isEnabled: config.wrappedValue.isEnabled),
                  systemImage: config.wrappedValue.isEnabled ? "checkmark.shield" : "minus.circle")
                .orbFont(size: 11)
                .foregroundStyle(.secondary)
                .help(MCPAgentAvailability.header)

            TextField("Command (e.g. npx)", text: config.command)
                .textFieldStyle(.roundedBorder)
                .orbFont(size: 11, design: .monospaced)

            MCPArgumentsField(args: config.args)

            TextField("Working folder (optional)", text: Binding(
                get: { config.wrappedValue.workingDirectory ?? "" },
                set: { config.wrappedValue.workingDirectory = $0.isEmpty ? nil : $0 }
            ))
            .textFieldStyle(.roundedBorder)
            .orbFont(size: 11, design: .monospaced)

            MCPEnvironmentEditor(config: config)

            secretConsentSection(config.wrappedValue)

            if needsApply.contains(id), config.wrappedValue.isEnabled {
                HStack(spacing: 8) {
                    Label("Changes not applied — the agent can't use this server until you apply them.",
                          systemImage: "arrow.triangle.2.circlepath")
                        .orbFont(size: 11)
                        .foregroundStyle(ORBTheme.warning)
                    Spacer()
                    Button("Apply") { apply(config.wrappedValue) }
                        .controlSize(.small)
                        .disabled(nameError != nil)
                }
            } else if let message = status[id] {
                Text(message)
                    .orbFont(size: 11)
                    .foregroundStyle(message.hasPrefix("✓") ? .green : (message.hasPrefix("Off") ? .secondary : .red))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(.orbSurface(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onChange(of: config.wrappedValue) { oldValue, newValue in
            persist()
            switch MCPRowEdit.classify(old: oldValue, new: newValue) {
            case .toggled:
                // A toggle flip connects or disconnects the server right away.
                needsApply.remove(newValue.id)
                status[newValue.id] = nil
                applyEnablement(of: newValue, previousName: oldValue.name)
            case .launchInputsChanged:
                // The old status described the old command; never keep it.
                status[newValue.id] = nil
                if newValue.isEnabled { needsApply.insert(newValue.id) }
            case .unchanged:
                break
            }
        }
    }

    private var footer: some View {
        HStack {
            Button {
                configs.append(MCPServerConfig(name: MCPRegistry.uniqueName("New Server", in: configs), command: ""))
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
                    needsApply.removeAll()
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
            Text("The same format Claude Desktop and other MCP hosts use. Remote (URL) servers are skipped; ORB runs local command-line servers.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
                        let report = try MCPRegistry.parseStandardConfigReport(importText)
                        let imported = report.configs
                        // Replace same-named entries so re-importing is idempotent.
                        let replaced = configs.filter { old in imported.contains { $0.name == old.name } }
                        let names = Set(imported.map(\.name))
                        configs.removeAll { names.contains($0.name) }
                        configs += imported
                        persist()
                        // A replaced row's Keychain values belong to its old id.
                        for old in replaced { MCPRegistry.deleteSecrets(of: old, store: KeychainCredentialStore()) }
                        // Imported servers connect immediately, like a toggle.
                        for server in imported where server.isEnabled {
                            applyEnablement(of: server, previousName: nil)
                        }
                        importNotes = report.warnings
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
        // Stored secrets are listed by `MCPEnvironmentEditor`.
        let candidates = config.env.keys.sorted()

        if !candidates.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Selected plain values move into the macOS Keychain; the settings file keeps only a reference. Values are never shown.")
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

    /// Keeps live connections in step with the row state: a just-enabled (or
    /// just-imported) server connects now, and a just-disabled one is shut
    /// down — "Enabled" must be true when the switch flips, not only after
    /// Reconnect All or a relaunch.
    private func applyEnablement(of config: MCPServerConfig, previousName: String?) {
        Task {
            if config.isEnabled {
                await MCPRegistry.shared.startServer(named: config.name)
            } else {
                await MCPRegistry.shared.stopServer(id: config.id)
                await MCPRegistry.shared.stopServer(named: previousName ?? config.name)
            }
            await refreshStatus()
        }
    }

    /// Restarts an edited, enabled server from its saved row.
    private func apply(_ config: MCPServerConfig) {
        needsApply.remove(config.id)
        status[config.id] = "Connecting…"
        Task {
            await MCPRegistry.shared.stopServer(id: config.id)
            await MCPRegistry.shared.startServer(named: config.name)
            await refreshStatus()
        }
    }

    private func remove(_ config: MCPServerConfig) {
        pendingRemoval = nil
        cancelProbe(config.id)
        configs.removeAll { $0.id == config.id }
        persist()
        status[config.id] = nil
        needsApply.remove(config.id)
        Task {
            await MCPServerRemoval.finish(config, registry: MCPRegistry.shared, store: KeychainCredentialStore())
        }
    }

    private func probe(_ config: MCPServerConfig) {
        status[config.id] = nil
        probeTasks[config.id] = Task {
            let outcome = await MCPRegistry.shared.probe(config)
            await MainActor.run {
                probeTasks[config.id] = nil
                guard !Task.isCancelled else { return }
                switch outcome {
                case .success(let report):
                    let detail = report.detail.isEmpty ? "" : "\n" + report.detail
                    status[config.id] = "✓ Connected — \(report.summary)" + detail
                case .failure(let error):
                    status[config.id] = error is CancellationError ? "Test cancelled." : error.localizedDescription
                }
            }
        }
    }

    private func cancelProbe(_ id: UUID) {
        guard let task = probeTasks.removeValue(forKey: id) else { return }
        task.cancel()
        status[id] = "Test cancelled."
    }

    private func refreshStatus() async {
        let rows = await MCPRegistry.shared.rowStatuses()
        await MainActor.run {
            for (id, row) in rows where probeTasks[id] == nil {
                if row.needsApply { needsApply.insert(id) }
                status[id] = MCPRowStatusText.text(for: row, isEnabled: configs.first { $0.id == id }?.isEnabled ?? false)
            }
        }
    }
}

/// How one edit to a server row affects its running process.
enum MCPRowEdit: Equatable {
    case unchanged
    /// The Enabled switch flipped.
    case toggled
    /// Name, command, arguments, folder or environment changed.
    case launchInputsChanged

    static func classify(old: MCPServerConfig, new: MCPServerConfig) -> MCPRowEdit {
        if old.isEnabled != new.isEnabled { return .toggled }
        return old == new ? .unchanged : .launchInputsChanged
    }
}

/// Status line for a row, from the registry's live state.
enum MCPRowStatusText {
    static func text(for row: MCPRegistry.RowStatus, isEnabled: Bool) -> String {
        if let error = row.error { return error }
        if row.connected { return "✓ Connected — \(row.toolCount) tool\(row.toolCount == 1 ? "" : "s")" }
        return isEnabled ? "Not connected yet." : "Off — not connected"
    }
}

/// Deleting a server: the row goes, its process stops, and its Keychain
/// values are deleted, so nothing keeps running or lingers in the Keychain.
enum MCPServerRemoval {
    static func confirmationMessage(for config: MCPServerConfig) -> String {
        let secrets = (config.secretEnv ?? [:]).count
        let secretNote = secrets == 0 ? "" : " Its \(secrets) Keychain value\(secrets == 1 ? "" : "s") will be deleted."
        return "ORB stops the server if it is running.\(secretNote) This can't be undone."
    }

    /// Stops the process launched from `config` and deletes its secrets.
    /// Returns variables whose secret could not be verified as deleted.
    @discardableResult
    static func finish(_ config: MCPServerConfig, registry: MCPRegistry, store: CredentialSecretStore) async -> [String] {
        await registry.stopServer(id: config.id)
        await registry.stopServer(named: config.name)
        return MCPRegistry.deleteSecrets(of: config, store: store)
    }
}

/// Env variables for one server: plain values, and secrets that go straight
/// into the Keychain (the settings file keeps only a reference).
private struct MCPEnvironmentEditor: View {
    @Binding var config: MCPServerConfig
    @State private var newKey = ""
    @State private var newValue = ""
    @State private var storeInKeychain = true
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("ENVIRONMENT")
                .orbFont(size: 11, weight: .bold)
                .foregroundStyle(.secondary)
            ForEach(config.env.keys.sorted(), id: \.self) { key in
                HStack(spacing: 6) {
                    Text(key).orbFont(size: 11, design: .monospaced)
                    TextField("Value", text: Binding(
                        get: { config.env[key] ?? "" },
                        set: { config.env[key] = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .orbFont(size: 11, design: .monospaced)
                    Button { config.env[key] = nil } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove \(key)")
                }
            }
            ForEach((config.secretEnv ?? [:]).keys.sorted(), id: \.self) { key in
                HStack(spacing: 6) {
                    Image(systemName: "lock.fill").orbFont(size: 11).foregroundStyle(.green)
                    Text(key).orbFont(size: 11, design: .monospaced)
                    Text("stored in the Keychain").orbFont(size: 11).foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        config = MCPRegistry.removingSecretEnv(key, from: config, store: KeychainCredentialStore())
                    } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove \(key)")
                }
            }
            HStack(spacing: 6) {
                TextField("NAME", text: $newKey)
                    .textFieldStyle(.roundedBorder)
                    .orbFont(size: 11, design: .monospaced)
                    .frame(maxWidth: 170)
                Group {
                    if storeInKeychain {
                        SecureField("Value", text: $newValue)
                    } else {
                        TextField("Value", text: $newValue)
                    }
                }
                .textFieldStyle(.roundedBorder)
                .orbFont(size: 11, design: .monospaced)
                Toggle("Keychain", isOn: $storeInKeychain)
                    .toggleStyle(.checkbox)
                    .orbFont(size: 11)
                    .help("Store the value in the macOS Keychain; the settings file keeps only a reference")
                Button("Add") { add() }
                    .controlSize(.small)
                    .disabled(newKey.trimmingCharacters(in: .whitespaces).isEmpty || newValue.isEmpty)
            }
            if let error {
                Text(error).orbFont(size: 11).foregroundStyle(.red)
            }
        }
    }

    private func add() {
        let key = newKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if storeInKeychain {
            let result = MCPRegistry.settingSecretEnv(key, value: newValue, in: config, store: KeychainCredentialStore())
            if let failure = result.error { error = failure; return }
            config = result.config
        } else {
            guard !key.isEmpty else { return }
            config.env[key] = newValue
        }
        error = nil
        newKey = ""
        newValue = ""
    }
}

/// The Arguments field of a server row. It edits its own text and writes the
/// parsed list back only when the list really changes. Joining the list with
/// spaces and splitting on every space, as the row once did, broke a path
/// containing a space into two arguments and saved it that way.
private struct MCPArgumentsField: View {
    @Binding var args: [String]
    @State private var text: String

    init(args: Binding<[String]>) {
        _args = args
        _text = State(initialValue: MCPArguments.render(args.wrappedValue))
    }

    var body: some View {
        TextField("Arguments (space separated; quote values that contain spaces)", text: $text)
            .textFieldStyle(.roundedBorder)
            .orbFont(size: 11, design: .monospaced)
            .onChange(of: text) { _, newText in
                let parsed = MCPArguments.parse(newText)
                if parsed != args { args = parsed }
            }
            .onChange(of: args) { _, newArgs in
                // Changed elsewhere (import, secret migration): show the new
                // list, unless the text being typed already means the same.
                if MCPArguments.parse(text) != newArgs { text = MCPArguments.render(newArgs) }
            }
    }
}

/// Shell-style quoting for the Arguments field, so a value with spaces
/// survives a round trip: `parse(render(args)) == args` for every list.
enum MCPArguments {
    /// Splits on unquoted whitespace. Single quotes are literal; inside
    /// double quotes a backslash escapes `"` and `\`; elsewhere a backslash
    /// escapes the next character. An unclosed quote runs to the end, so a
    /// half-typed value is never dropped.
    static func parse(_ text: String) -> [String] {
        var args: [String] = []
        var current = ""
        var hasCurrent = false
        var quote: Character?
        var index = text.startIndex

        func next() -> Character? {
            let after = text.index(after: index)
            return after < text.endIndex ? text[after] : nil
        }

        while index < text.endIndex {
            let character = text[index]
            if let open = quote {
                if character == open {
                    quote = nil
                } else if open == "\"", character == "\\", let escaped = next(), escaped == "\"" || escaped == "\\" {
                    current.append(escaped)
                    index = text.index(after: index)
                } else {
                    current.append(character)
                }
            } else if character == "'" || character == "\"" {
                quote = character
                hasCurrent = true
            } else if character == "\\", let escaped = next() {
                current.append(escaped)
                hasCurrent = true
                index = text.index(after: index)
            } else if character.isWhitespace {
                if hasCurrent { args.append(current) }
                current = ""
                hasCurrent = false
            } else {
                current.append(character)
                hasCurrent = true
            }
            index = text.index(after: index)
        }
        if hasCurrent { args.append(current) }
        return args
    }

    /// Joins with spaces, double-quoting any argument that is empty or
    /// contains whitespace, a quote or a backslash.
    static func render(_ args: [String]) -> String {
        args.map(quoted).joined(separator: " ")
    }

    private static func quoted(_ argument: String) -> String {
        let needsQuoting = argument.isEmpty || argument.contains { character in
            character.isWhitespace || character == "\"" || character == "'" || character == "\\"
        }
        guard needsQuoting else { return argument }
        let escaped = argument
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"" + escaped + "\""
    }
}

/// Truthful copy for what an MCP server actually grants. Mirrors
/// `ToolPolicy.agentSession`: an enabled server is the per-server approval,
/// tools are offered only with the Agent's Computer Access capability, and
/// every call still goes through the approval prompt (unless OP Mode).
enum MCPAgentAvailability {
    static let header = "Enabled servers' tools are offered to the Agent only when Computer Access is on. Each tool call asks for your approval first (OP Mode skips the prompt). Web Only never uses MCP."

    static func status(isEnabled: Bool) -> String {
        isEnabled
            ? "Enabled: connected and offered to the Agent with Computer Access; each call needs approval. Edits apply when you press Apply."
            : "Off: never offered to the Agent"
    }
}
