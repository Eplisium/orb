import SwiftUI
import AppKit

/// Settings: General (appearance, prices, notifications, security, updates,
/// about), Accounts & Keys, Usage & Credits, MCP and Advanced (network,
/// storage & diagnostics, provider directory). One header style
/// (`SettingsSectionHeader`) and the semantic colour tokens throughout.
struct SettingsView: View {
    @StateObject private var account = AccountService()
    @StateObject private var directory = DirectoryService()
    @StateObject private var keySave = SaveFeedback(what: "API key")
    @StateObject private var managementSave = SaveFeedback(what: "Management key")
    @StateObject private var storage = StorageDiagnosticsModel()
    @ObservedObject private var signIn = OpenRouterSignInModel.shared
    @ObservedObject private var updates = UpdateChecker.shared
    @AppStorage(SettingsPane.storageKey) private var paneRaw = SettingsPane.general.rawValue
    private var pane: Binding<SettingsPane> {
        Binding(get: { (SettingsPane(rawValue: paneRaw) ?? .general).visiblePane }, set: { paneRaw = $0.rawValue })
    }
    /// Inference-key state, cached: the Keychain is read on appear and after
    /// save/remove/sign-in, never on every redraw (each keystroke in the key
    /// field redraws the pane).
    @State private var inference = InferenceKeyPanel()
    @State private var showKey = false
    @State private var showRemoveKeyConfirmation = false
    // Management key section (F03/W04). The draft lives in a small panel
    // struct so the save/remove rules are unit-testable; the configured state
    // itself is always read from `account.hasManagementKey`.
    @State private var management = ManagementKeyPanel()
    @State private var showRemoveManagementKeyConfirmation = false
    @ObservedObject private var appLock = AppLock.shared
    @AppStorage(OPMode.key) private var opMode = false
    @State private var confirmOPMode = false
    @AppStorage(AppLockPolicy.idleMinutesKey) private var idleMinutes = AppLockPolicy.defaultIdleMinutes
    @AppStorage(UpdateChecker.autoCheckKey) private var autoCheckUpdates = true

    var body: some View {
        // Native toolbar tabs (the standard macOS Settings look).
        TabView(selection: pane) {
            ForEach(SettingsPane.allCases) { item in
                ScrollView {
                    paneContent(item)
                        .padding(24)
                        .frame(maxWidth: 760, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .tabItem { Label(item.title, systemImage: item.symbol) }
                .tag(item)
            }
        }
        .frame(minWidth: 500, minHeight: 400)
        .task {
            reloadInferenceKey()
            await refreshAccount()
        }
        .onChange(of: account.hasManagementKey) { _, has in
            if has { Task { await refreshAccount() } }
        }
        .onChange(of: signIn.completedCount) { _, _ in
            reloadInferenceKey()
            Task { await refreshAccount() }
        }
        .confirmationDialog(
            "Remove the OpenRouter API key?",
            isPresented: $showRemoveKeyConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove Key", role: .destructive) {
                let removed = KeychainManager.deleteAPIKey()
                inference.didRemove(success: removed)
                if removed {
                    // Only the inference key's own panel is cleared. Credits
                    // and activity belong to the management key, which is
                    // still configured.
                    directory.keyInfo = nil
                    AppToasts.center.show("API key removed", kind: .success, duration: 2)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(ManagementKeyPanel.removeInferenceMessage)
        }
        .confirmationDialog(
            ManagementKeyPanel.removeTitle,
            isPresented: $showRemoveManagementKeyConfirmation,
            titleVisibility: .visible
        ) {
            Button(ManagementKeyPanel.removeButtonLabel, role: .destructive) {
                management.removeKey(into: account)
                if management.actionError == nil {
                    AppToasts.center.show("Management key removed", kind: .success, duration: 2)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(ManagementKeyPanel.removeMessage)
        }
    }

    @ViewBuilder
    private func paneContent(_ pane: SettingsPane) -> some View {
        switch pane.visiblePane {
        case .general:
            VStack(alignment: .leading, spacing: 24) {
                AppearanceSettingsSection()
                Divider()
                PriceUnitSettingsSection()
                Divider()
                NotificationSettingsSection()
                Divider()
                securitySection
                Divider()
                updatesSection
                Divider()
                AboutPane()
            }
        case .accounts:
            VStack(alignment: .leading, spacing: 24) {
                apiKeySection
                Divider()
                managementKeySection
                Divider()
                keyInfoSection
            }
        case .usage:
            VStack(alignment: .leading, spacing: 24) {
                creditsSection
                Divider()
                activitySection
                Divider()
                UsageSettingsView(accent: ORBTheme.accent)
            }
        case .mcp: MCPSettingsView(accent: .accentColor)
        case .advanced, .network:
            VStack(alignment: .leading, spacing: 24) {
                NetworkTimeoutsView(accent: ORBTheme.accent)
                Divider()
                storageSection
                Divider()
                providersSection
            }
        }
    }

    // MARK: - Security (App Lock + OP Mode)

    private var securitySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsSectionHeader("Security", symbol: "lock.fill",
                                  subtitle: LockCopy.settingsDescription(biometric: appLock.biometricName))

            Toggle("Require unlock at launch", isOn: Binding(
                get: { appLock.isEnabled },
                set: { appLock.setEnabled($0) }
            ))
            .toggleStyle(.switch)

            Picker("Auto-lock when idle", selection: $idleMinutes) {
                ForEach(AppLockPolicy.idleChoices, id: \.self) { m in
                    Text(AppLockPolicy.label(forMinutes: m)).tag(m)
                }
            }
            .frame(maxWidth: 300)
            .disabled(!appLock.isEnabled)

            if pendingLegacyCount > 0 {
                Button("Move \(pendingLegacyCount) older key\(pendingLegacyCount == 1 ? "" : "s") to secure storage") {
                    KeychainSecrets.migrateAllLegacy(force: true)
                }
                .buttonStyle(.bordered)
            }

            Button {
                appLock.lock()
            } label: {
                Label("Lock ORB Now", systemImage: "lock")
            }
            .buttonStyle(.bordered)
            .disabled(!appLock.isEnabled)
            .help(appLock.isEnabled ? "Lock immediately (\(ShortcutCommand.lockNow.combo.display))" : "Turn on \"Require unlock at launch\" to use the lock")

            opModeControls
                .padding(.top, 8)
        }
    }

    private var opModeControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsSubheading("OP Mode")
            Text("Skips the approval prompt for risky agent tools: terminal commands, computer control and MCP tools. The agent can then run them without asking. It does not change what the agent is allowed to use: Web Only and Computer Access still apply.")
                .orbFont(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Run risky tools without asking", isOn: Binding(
                get: { opMode },
                set: { on in if on { confirmOPMode = true } else { opMode = false } }
            ))
            .toggleStyle(.switch)
            if opMode {
                SettingsNotice(kind: .warning, message: "OP Mode is on. Agent commands run immediately.")
            }
        }
        .confirmationDialog("Turn on OP Mode?", isPresented: $confirmOPMode, titleVisibility: .visible) {
            Button("Turn On OP Mode", role: .destructive) { opMode = true }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The agent will run terminal commands and control this Mac without asking. Only use it with models and prompts you trust.")
        }
    }

    private var pendingLegacyCount: Int {
        KeychainSecrets.pendingLegacyAccounts().count
    }

    // MARK: - Updates

    private var updatesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsSectionHeader("Updates", symbol: "arrow.down.circle",
                                  subtitle: "ORB asks GitHub (no account, no keys sent) whether a newer release of ORB exists. Nothing is downloaded or installed automatically.")
            Toggle("Check for updates once a day", isOn: $autoCheckUpdates)
                .toggleStyle(.switch)
            HStack(spacing: 10) {
                Button("Check Now") { Task { await updates.checkNow() } }
                    .disabled(updates.isChecking)
                if updates.isChecking {
                    ProgressView().controlSize(.small)
                } else if let result = updates.lastResult {
                    Text(result.summary).orbFont(.footnote).foregroundStyle(.secondary)
                    if case .available(let release) = result {
                        Link("View Release →", destination: release.pageURL).orbFont(.footnote)
                    }
                }
            }
            Text("This is version \(updates.currentVersion).")
                .orbFont(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - API Key

    private var apiKeySection: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsSectionHeader("Inference Key", symbol: "key.fill",
                                  subtitle: ManagementKeyPanel.inferenceExplanation)

            SettingsStatusRow(
                tone: inference.hasKey ? .ok : .attention,
                title: inference.statusTitle,
                detail: inference.maskedKey
            )

            if !inference.hasKey {
                VStack(alignment: .leading, spacing: 6) {
                    OpenRouterSignInButton(model: signIn)
                    Text("Creates a key for ORB on openrouter.ai and saves it here. Or paste a key below.")
                        .orbFont(.caption).foregroundStyle(.secondary)
                }
            }

            // Key input
            VStack(alignment: .leading, spacing: 8) {
                Text(inference.hasKey ? "Replace Inference Key" : "Paste an Inference Key")
                    .orbFont(.body, weight: .medium)

                HStack {
                    Group {
                        if showKey {
                            TextField("sk-or-v1-...", text: $inference.draft)
                        } else {
                            SecureField("sk-or-v1-...", text: $inference.draft)
                        }
                    }
                    .textFieldStyle(.roundedBorder)
                    .orbFont(size: 13, design: .monospaced)
                    .onSubmit(saveInferenceKey)

                    Button {
                        showKey.toggle()
                    } label: {
                        Image(systemName: showKey ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                    .help(showKey ? "Hide key" : "Show key")
                    .accessibilityLabel(showKey ? "Hide key" : "Show key")
                }

                if let hint = KeyFieldValidation.check(inference.draft).message {
                    Label(hint, systemImage: "info.circle")
                        .orbFont(.footnote).foregroundStyle(.secondary)
                        .accessibilityLabel("Key format note: \(hint)")
                }
                HStack {
                    Button(inference.hasKey ? "Replace Key" : "Save Key", action: saveInferenceKey)
                        .buttonStyle(.borderedProminent)
                        .tint(ORBTheme.accent)
                        .disabled(!inference.canSave)

                    SaveStatusLabel(status: keySave.status)

                    Spacer()

                    if inference.hasKey {
                        Button("Remove Key", role: .destructive) {
                            showRemoveKeyConfirmation = true
                        }
                        .buttonStyle(.bordered)
                    }
                }

                if let error = inference.actionError {
                    SettingsNotice(kind: .error, message: error)
                }
            }

            Link("Get an API key from OpenRouter →", destination: OpenRouterLinks.keys)
                .orbFont(.footnote)
        }
    }

    private func saveInferenceKey() {
        guard inference.canSave else { return }
        let trimmed = inference.trimmedDraft
        var failure: String?
        if keySave.run({ failure = KeychainManager.saveAPIKey(trimmed); return failure }) {
            inference.didSave(masked: KeychainManager.maskedKey)
            Task { await refreshAccount() }
        } else {
            inference.actionError = failure
        }
    }

    private func reloadInferenceKey() {
        let has = KeychainManager.hasAPIKey
        inference.reload(hasKey: has, masked: has ? KeychainManager.maskedKey : nil)
    }

    // MARK: - Management Key (role-aware credentials, F03/W04)

    private var managementKeySection: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsSectionHeader("Management Key", symbol: "lock.shield",
                                  subtitle: ManagementKeyPanel.explanation)

            SettingsStatusRow(
                tone: account.hasManagementKey ? .ok : .neutral,
                title: account.hasManagementKey ? "Management key configured" : "No management key set"
            )

            VStack(alignment: .leading, spacing: 8) {
                Text(account.hasManagementKey ? "Replace Management Key" : "Paste a Management Key")
                    .orbFont(.body, weight: .medium)

                // Write-only by design: a SecureField with no reveal affordance.
                // The value is never displayed back, echoed, or logged.
                SecureField("sk-or-...", text: $management.draftKey)
                    .textFieldStyle(.roundedBorder)
                    .orbFont(size: 13, design: .monospaced)
                    .onSubmit(saveManagementKey)

                if let hint = management.formatHint {
                    Label(hint, systemImage: "info.circle")
                        .orbFont(.footnote).foregroundStyle(.secondary)
                        .accessibilityLabel("Key format note: \(hint)")
                }

                HStack {
                    Button(account.hasManagementKey ? "Replace Key" : "Save Key", action: saveManagementKey)
                        .buttonStyle(.borderedProminent)
                        .tint(ORBTheme.accent)
                        .disabled(!management.canSave)

                    SaveStatusLabel(status: managementSave.status)

                    Spacer()

                    if account.hasManagementKey {
                        Button("Remove Key", role: .destructive) {
                            showRemoveManagementKeyConfirmation = true
                        }
                        .buttonStyle(.bordered)
                    }
                }

                if let error = management.actionError {
                    SettingsNotice(kind: .error, message: error)
                }
            }

            Link("Create a management key on openrouter.ai →", destination: OpenRouterLinks.managementKeys)
                .orbFont(.footnote)
        }
    }

    private func saveManagementKey() {
        guard management.canSave else { return }
        managementSave.begin()
        management.saveDraft(into: account)
        // A newly-authorized role can now load the locked panels.
        if management.showSaved {
            managementSave.succeed()
            Task { await refreshAccount() }
        } else if let reason = management.actionError {
            managementSave.fail(reason)
        } else {
            managementSave.fail("The key was not accepted.")
        }
    }

    // MARK: - Credits (OpenRouter account)

    private var creditsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsSectionHeader("OpenRouter Account · Balance", symbol: "dollarsign.circle.fill",
                                  subtitle: "Account-wide, from OpenRouter. Includes every app and device using your keys.") {
                SettingsRefreshButton(isLoading: account.isLoadingCredits, help: "Refresh credits") {
                    Task { await account.fetchCredits() }
                }
            }

            if !panelAvailable(.credits) {
                SettingsNotice(kind: .info, message: AccountPanel.credits.missingKeyMessage)
            } else if let error = account.creditsError {
                SettingsNotice(kind: .error, message: error)
            } else if let credits = account.credits {
                let usedShare = credits.totalCredits > 0 ? min(credits.totalUsage / credits.totalCredits, 1) : 0
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                    CreditCard(title: "Remaining", value: ORBMoney.format(credits.remaining), icon: "wallet.bifold.fill",
                               color: credits.remaining > 0 ? ORBTheme.success : ORBTheme.danger)
                    CreditCard(title: "Total purchased", value: ORBMoney.format(credits.totalCredits), icon: "banknote.fill", color: ORBTheme.accent)
                    CreditCard(title: "Used (all time)", value: ORBMoney.format(credits.totalUsage), icon: "chart.line.downtrend.xyaxis", color: ORBTheme.warning)
                    CreditCard(title: "Used share", value: credits.totalCredits > 0 ? String(format: "%.1f%%", usedShare * 100) : "—",
                               icon: "percent", color: ORBTheme.info)
                }

                if credits.totalCredits > 0 {
                    VStack(alignment: .leading, spacing: 4) {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 4).fill(.quaternary)
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(credits.remaining > 0 ? ORBTheme.accent : ORBTheme.danger)
                                    .frame(width: geo.size.width * CGFloat(usedShare))
                            }
                        }
                        .frame(height: 8)
                        .accessibilityElement()
                        .accessibilityLabel("Credits used")
                        .accessibilityValue(String(format: "%.0f percent", usedShare * 100))
                        HStack {
                            Text("0%").orbFont(.caption).foregroundStyle(.tertiary)
                            Spacer()
                            Text("Used \(String(format: "%.1f%%", usedShare * 100))").orbFont(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Text("100%").orbFont(.caption).foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.top, 4)
                }
            } else {
                Text(ManagementKeyPanel.creditsEmptyMessage)
                    .orbFont(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Activity (OpenRouter account, last 30 days)

    private var activitySection: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsSectionHeader("OpenRouter Account · Last 30 Days", symbol: "chart.bar.fill",
                                  subtitle: "Account-wide activity reported by OpenRouter for the last 30 UTC days.") {
                SettingsRefreshButton(isLoading: account.isLoadingActivity, help: "Refresh activity") {
                    Task { await account.fetchActivity() }
                }
            }

            if !panelAvailable(.activity) {
                SettingsNotice(kind: .info, message: AccountPanel.activity.missingKeyMessage)
            } else if let error = account.activityError {
                SettingsNotice(kind: .error, message: error)
            } else if account.activity.isEmpty && !account.isLoadingActivity {
                Text("No activity in the last 30 days. Usage appears here after you make API calls.")
                    .orbFont(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    CreditCard(title: "Spend · 30 days", value: ORBMoney.format(account.totalSpend), icon: "dollarsign.circle", color: ORBTheme.warning)
                    CreditCard(title: "Requests · 30 days", value: "\(account.totalRequests)", icon: "arrow.left.arrow.right", color: ORBTheme.info)
                    CreditCard(title: "Models used", value: "\(account.topModels.count)", icon: "cpu", color: ORBTheme.accent)
                }

                if !account.topModels.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        SettingsSubheading("Top models")
                        ForEach(account.topModels.prefix(10), id: \.model) { item in
                            HStack {
                                Text(item.model)
                                    .orbFont(size: 12, design: .monospaced)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                Text("\(item.requests) reqs")
                                    .orbFont(.caption)
                                    .foregroundStyle(.secondary)
                                Text(ORBMoney.format(item.usage))
                                    .orbFont(size: 12, design: .monospaced)
                                    .frame(minWidth: 70, alignment: .trailing)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                    .padding(.top, 8)
                }

                if !account.dailySpend.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        SettingsSubheading("Daily spend")
                        ForEach(account.dailySpend.prefix(14), id: \.date) { item in
                            HStack {
                                Text(item.date)
                                    .orbFont(size: 12, design: .monospaced)
                                Spacer()
                                Text(ORBMoney.format(item.amount))
                                    .orbFont(size: 12, design: .monospaced)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                    .padding(.top, 8)
                }
            }
        }
    }

    // MARK: - Helpers

    private func panelAvailable(_ panel: AccountPanel) -> Bool {
        panel.isAvailable(hasInferenceKey: inference.hasKey, hasManagementKey: account.hasManagementKey)
    }

    private func refreshAccount() async {
        let panels = AccountPanel.panelsToRefresh(
            hasInferenceKey: inference.hasKey, hasManagementKey: account.hasManagementKey
        )
        if panels.contains(.credits) { await account.fetchCredits() }
        if panels.contains(.activity) { await account.fetchActivity() }
        if panels.contains(.keyInfo) { await directory.fetchKeyInfo() }
    }

    // MARK: - Key Info (`GET /key`)

    private var keyInfoSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsSectionHeader("Current Inference Key", symbol: "gauge.with.dots.needle.67percent",
                                  subtitle: "Limits and spend OpenRouter reports for the inference key above.") {
                SettingsRefreshButton(isLoading: false, help: "Refresh key info") {
                    Task { await directory.fetchKeyInfo() }
                }
            }

            if !panelAvailable(.keyInfo) {
                SettingsNotice(kind: .info, message: AccountPanel.keyInfo.missingKeyMessage)
            } else if let error = directory.lastError, directory.keyInfo == nil {
                SettingsNotice(kind: .error, message: error)
            } else if let info = directory.keyInfo {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                    CreditCard(title: "Label", value: info.label ?? ORBMoney.unknown, icon: "tag.fill", color: ORBTheme.info)
                    CreditCard(
                        title: "Spend limit",
                        value: info.limit.map { ORBMoney.format($0) } ?? "No limit",
                        icon: "gauge.with.dots.needle.67percent", color: ORBTheme.accent
                    )
                    CreditCard(
                        title: "Limit remaining",
                        value: ORBMoney.format(info.limitRemaining),
                        icon: "wallet.bifold.fill",
                        color: (info.limitRemaining ?? 1) > 0 ? ORBTheme.success : ORBTheme.danger
                    )
                    CreditCard(title: "Used (all time)", value: ORBMoney.format(info.usage), icon: "chart.line.uptrend.xyaxis", color: ORBTheme.warning)
                }
                VStack(alignment: .leading, spacing: 6) {
                    keyInfoRow("Reset", info.limitReset ?? ORBMoney.unknown)
                    keyInfoRow("Today", ORBMoney.format(info.usageDaily))
                    keyInfoRow("This week", ORBMoney.format(info.usageWeekly))
                    keyInfoRow("This month", ORBMoney.format(info.usageMonthly))
                    if info.isFreeTier == true {
                        keyInfoRow("Tier", "Free")
                    }
                    if info.isProvisioningKey == true {
                        keyInfoRow("Provisioning key", "Yes")
                    }
                    if info.isManagementKey == true {
                        keyInfoRow("Management key", "Yes")
                    }
                    if let expires = info.expiresAt {
                        keyInfoRow("Expires", expires)
                    }
                }
                .padding(.top, 4)
            } else {
                Text(ManagementKeyPanel.keyInfoEmptyMessage)
                    .orbFont(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func keyInfoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).orbFont(.footnote).foregroundStyle(.secondary)
            Spacer()
            Text(value).orbFont(size: 12, design: .monospaced)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Storage & Diagnostics

    private var storageSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsSectionHeader("Storage & Diagnostics", symbol: "internaldrive",
                                  subtitle: "Disk space ORB's own data uses on this Mac.") {
                SettingsRefreshButton(isLoading: storage.isMeasuring, help: "Measure again") {
                    Task { await storage.refresh() }
                }
            }
            .task { await storage.refresh() }

            if let report = storage.report {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 6) {
                    storageRow("Database", StorageFormat.bytes(report.databaseBytes))
                    storageRow("Database journal (WAL)", StorageFormat.bytes(report.walBytes))
                    storageRow("Saved media", "\(StorageFormat.bytes(report.assetsBytes)) · \(report.assetFileCount) file\(report.assetFileCount == 1 ? "" : "s")")
                    storageRow("Recovery backups", "\(StorageFormat.bytes(report.recoveryBackupBytes)) · \(report.recoveryBackupCount)")
                    Divider().gridCellUnsizedAxes(.horizontal)
                    storageRow("Total", StorageFormat.bytes(report.totalBytes), emphasized: true)
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Measuring…").orbFont(.footnote).foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 10) {
                Button("Reveal in Finder") { storage.revealInFinder() }
                Button("Copy Diagnostics") {
                    let text = storage.diagnosticsText(
                        hasInferenceKey: OnboardingGate.isReviewMode() ? nil : inference.hasKey,
                        hasManagementKey: OnboardingGate.isReviewMode() ? nil : account.hasManagementKey
                    )
                    AppToasts.copy(text, what: "Diagnostics")
                }
                .help("Copies versions, counts and sizes for a bug report. No keys, file paths or conversation content.")
            }
        }
    }

    private func storageRow(_ label: String, _ value: String, emphasized: Bool = false) -> some View {
        GridRow {
            Text(label).orbFont(.footnote, weight: emphasized ? .semibold : nil).foregroundStyle(emphasized ? .primary : .secondary)
            Text(value).orbFont(.footnote, weight: emphasized ? .semibold : nil).monospacedDigit()
        }
    }

    // MARK: - Providers (`GET /providers`)

    private var providersSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsSectionHeader("Provider Directory", symbol: "building.2.fill",
                                  subtitle: "Read-only: the inference providers that serve models on OpenRouter.") {
                SettingsRefreshButton(isLoading: false, help: "Refresh providers") {
                    Task { await directory.fetchProviders() }
                }
            }
            .task { await directory.fetchProviders() }

            if let error = directory.lastError, directory.providers.isEmpty {
                SettingsNotice(kind: .error, message: error)
            } else if directory.providers.isEmpty {
                Text("No providers loaded yet.")
                    .orbFont(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Text("\(directory.providers.count) inference providers serve models on OpenRouter.")
                    .orbFont(.footnote).foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ForEach(directory.providers) { provider in
                        HStack(spacing: 6) {
                            Circle().fill(ORBTheme.accent.opacity(0.6)).frame(width: 7, height: 7)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(provider.name).orbFont(size: 12, weight: .medium).lineLimit(1)
                                Text(provider.slug).orbFont(size: 11, design: .monospaced).foregroundStyle(.tertiary).lineLimit(1)
                            }
                            Spacer()
                        }
                        .padding(8)
                        .background(.orbSurface(0.04))
                        .clipShape(RoundedRectangle(cornerRadius: ORBMetrics.radiusSM))
                    }
                }
            }
        }
    }
}

// MARK: - Inference key panel

/// Cached state for the Settings inference-key section. The view fills it
/// from the Keychain on appear and after save/remove/sign-in, so a redraw
/// (every keystroke in the field) never reads the secret.
struct InferenceKeyPanel: Equatable {
    enum Status: Equatable {
        case unknown
        case missing
        case configured(masked: String?)
        /// Just removed: shown as "Key removed" until the next save.
        case removed
    }

    var status: Status = .unknown
    var draft = ""
    var actionError: String?

    var trimmedDraft: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// Format-valid keys only, same rule as onboarding.
    var canSave: Bool { KeyFieldValidation.check(draft) == .valid }

    var hasKey: Bool {
        if case .configured = status { return true }
        return false
    }

    var maskedKey: String? {
        if case .configured(let masked) = status { return masked }
        return nil
    }

    var statusTitle: String {
        switch status {
        case .configured: return "Inference key configured"
        case .removed: return "Key removed"
        case .missing, .unknown: return "No inference key set"
        }
    }

    mutating func reload(hasKey: Bool, masked: String?) {
        if hasKey {
            status = .configured(masked: masked)
        } else if status != .removed {
            status = .missing
        }
    }

    mutating func didSave(masked: String?) {
        draft = ""
        actionError = nil
        status = .configured(masked: masked)
    }

    mutating func didRemove(success: Bool) {
        if success {
            actionError = nil
            status = .removed
        } else {
            actionError = "The API key could not be removed from Keychain."
        }
    }
}

// MARK: - Supporting views

/// Draft + presentation rules for the Settings management-key section.
/// Extracted from the view so the save/remove semantics and the
/// confirmation/explanation copy are unit-testable without hosting SwiftUI;
/// the view only renders this state (configured-state display always reads
/// `AccountService.hasManagementKey` directly).
struct ManagementKeyPanel {
    var draftKey = ""
    var actionError: String?
    var showSaved = false

    // MARK: Copy (section 7.7 — confirmations name the exact target and effect)

    /// Inference-key copy: what it powers, and explicitly what it doesn't.
    static let inferenceExplanation = "Your OpenRouter inference (API) key is stored in the macOS Keychain. ORB uses it for Chat, Agent, and Generate (images, video, speech, embeddings). Account-wide credits and activity need the optional management key below."

    static let explanation = "Optional. A management key unlocks account-wide credits, usage activity, and administration on OpenRouter. Chat and media generation keep working with your inference key — they never use this one."

    static let removeTitle = "Remove the management key?"

    static let removeMessage = "Credits, activity, and administration will be unavailable until another management key is saved. Chat keeps working with your inference key."

    static let removeButtonLabel = "Remove Management Key"

    /// Removing the inference key leaves the management key, and with it
    /// credits and activity, untouched; the confirmation says so.
    static let removeInferenceMessage = "Chat, Agent, and Generate will be unavailable until another inference key is saved. Credits and activity use the management key and are not affected."

    static let creditsEmptyMessage = "Click the refresh button to load your credits."

    static let keyInfoEmptyMessage = "Click the refresh button to load key limits and usage."

    /// Format-valid keys only (same rule as the inference key and onboarding).
    var canSave: Bool { KeyFieldValidation.check(draftKey) == .valid }
    /// Why Save is disabled, shown under the field.
    var formatHint: String? { KeyFieldValidation.check(draftKey).message }
    private var normalizedDraft: String {
        draftKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Saves the draft through the service. On failure the service keeps the
    /// previous key intact and the error is surfaced; on success the draft is
    /// cleared and never retained (write-only, never displayed or logged).
    @MainActor
    mutating func saveDraft(into service: AccountService) {
        guard canSave else { return }
        if let error = service.setManagementKey(normalizedDraft) {
            actionError = error
            showSaved = false
        } else {
            actionError = nil
            draftKey = ""
            showSaved = true
        }
    }

    /// Removes the key through the service, which also clears published
    /// credits/activity so nothing from the removed credential stays on screen.
    @MainActor
    mutating func removeKey(into service: AccountService) {
        if let error = service.removeManagementKey() {
            actionError = error
            return // key still stored: keep the draft and don't show a removal
        }
        actionError = nil
        showSaved = false
        draftKey = ""
    }
}

struct CreditCard: View {
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
                .orbFont(size: 18, weight: .semibold, design: .monospaced)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(color.opacity(ORBPalette.subtleFillAlpha))
        .clipShape(RoundedRectangle(cornerRadius: ORBMetrics.radiusMD))
        .accessibilityElement(children: .combine)
    }
}

struct ErrorBanner: View {
    let message: String

    var body: some View {
        SettingsNotice(kind: .error, message: message)
    }
}
