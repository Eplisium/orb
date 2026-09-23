import SwiftUI

/// Settings view: API key management, account credits, and usage activity.
struct SettingsView: View {
    @StateObject private var account = AccountService()
    @StateObject private var directory = DirectoryService()
    @State private var apiKeyInput = ""
    @State private var showKeySaved = false
    @State private var showKeyDeleted = false
    @State private var showKey = false
    @State private var showRemoveKeyConfirmation = false
    @State private var keyActionError: String?
    @State private var selectedTab: SettingsTab = .apiKey
    // Management key section (F03/W04). The draft lives in a small panel
    // struct so the save/remove rules are unit-testable; the configured state
    // itself is always read from `account.hasManagementKey`.
    @State private var management = ManagementKeyPanel()
    @State private var showRemoveManagementKeyConfirmation = false
    @ObservedObject private var appLock = AppLock.shared

    enum SettingsTab: String, CaseIterable {
        case apiKey = "API Key"
        case credits = "Credits"
        case activity = "Activity"
        case keyInfo = "Key Info"
        case providers = "Providers"
        case mcp = "MCP Servers"
        case advanced = "Advanced"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Tab bar
            Picker("Section", selection: $selectedTab) {
                ForEach(SettingsTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(16)

            Divider()

            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    switch selectedTab {
                    case .apiKey:
                        VStack(alignment: .leading, spacing: 24) {
                            apiKeySection
                            Divider()
                            managementKeySection
                            Divider()
                            securitySection
                        }
                    case .credits: creditsSection
                    case .activity: activitySection
                    case .keyInfo: keyInfoSection
                    case .providers: providersSection
                    case .mcp: MCPSettingsView(accent: .accentColor)
                    case .advanced: NetworkTimeoutsView(accent: .accentColor)
                    }
                }
                .padding(20)
            }
        }
        .frame(minWidth: 500, minHeight: 400)
        .task {
            if KeychainManager.hasAPIKey {
                await refreshAccount()
            }
        }
        .confirmationDialog(
            "Remove the OpenRouter API key?",
            isPresented: $showRemoveKeyConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove Key", role: .destructive) {
                if KeychainManager.deleteAPIKey() {
                    keyActionError = nil
                    showKeyDeleted = true
                    account.credits = nil
                    account.activity = []
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        showKeyDeleted = false
                    }
                } else {
                    keyActionError = "The API key could not be removed from Keychain."
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Chat, Agent, credits, and activity will be unavailable until another key is saved.")
        }
        .confirmationDialog(
            ManagementKeyPanel.removeTitle,
            isPresented: $showRemoveManagementKeyConfirmation,
            titleVisibility: .visible
        ) {
            Button(ManagementKeyPanel.removeButtonLabel, role: .destructive) {
                management.removeKey(into: account)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(ManagementKeyPanel.removeMessage)
        }
    }

    // MARK: - Security

    private var securitySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Security", systemImage: "lock.fill")
                .font(.title3.weight(.semibold))

            Text("When enabled, ORB asks for \(appLock.biometricLabel) or your Mac password at launch — one \"allow all access\" gesture instead of repeated Keychain dialogs.")
                .font(.callout)
                .foregroundStyle(.secondary)

            Toggle("Require unlock at launch", isOn: Binding(
                get: { appLock.isEnabled },
                set: { appLock.setEnabled($0) }
            ))
            .toggleStyle(.switch)

            if pendingLegacyCount > 0 {
                Button("Move \(pendingLegacyCount) stored key\(pendingLegacyCount == 1 ? "" : "s") to prompt-free storage") {
                    KeychainSecrets.migrateAllLegacy()
                }
                .buttonStyle(.bordered)
                .font(.callout)
            }

            Button("Lock ORB Now") {
                appLock.lock()
            }
            .disabled(!appLock.isEnabled)
        }
    }

    private var pendingLegacyCount: Int {
        KeychainSecrets.pendingLegacyAccounts().count
    }

    // MARK: - API Key

    private var apiKeySection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("API Key", systemImage: "key.fill")
                .font(.title2.weight(.semibold))

            Text("Your OpenRouter API key is stored securely in the macOS Keychain. It's used for authenticated features like checking credits and sending chat messages.")
                .font(.callout)
                .foregroundStyle(.secondary)

            Divider()

            // Current key status
            HStack {
                Circle()
                    .fill(KeychainManager.hasAPIKey ? Color.green : Color.red)
                    .frame(width: 10, height: 10)
                Text(KeychainManager.hasAPIKey ? "API key configured" : "No API key set")
                    .font(.subheadline.weight(.medium))

                Spacer()

                if let masked = KeychainManager.maskedKey {
                    Text(masked)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .background(.quaternary.opacity(0.3))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            // Key input
            VStack(alignment: .leading, spacing: 8) {
                Text("Enter API Key")
                    .font(.subheadline.weight(.medium))

                HStack {
                    Group {
                        if showKey {
                            TextField("sk-or-v1-...", text: $apiKeyInput)
                        } else {
                            SecureField("sk-or-v1-...", text: $apiKeyInput)
                        }
                    }
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13, design: .monospaced))

                    Button {
                        showKey.toggle()
                    } label: {
                        Image(systemName: showKey ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.plain)
                    .help(showKey ? "Hide key" : "Show key")
                }

                HStack {
                    Button("Save Key") {
                        let trimmed = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        if let error = KeychainManager.saveAPIKey(trimmed) {
                            keyActionError = error
                        } else {
                            keyActionError = nil
                            showKeySaved = true
                            apiKeyInput = ""
                            Task { await refreshAccount() }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                showKeySaved = false
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if showKeySaved {
                        Label("Saved!", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.subheadline)
                            .transition(.opacity)
                    }

                    Spacer()

                    if KeychainManager.hasAPIKey {
                        Button("Remove Key") {
                            showRemoveKeyConfirmation = true
                        }
                        .foregroundStyle(.red)

                        if showKeyDeleted {
                            Label("Removed", systemImage: "trash.fill")
                                .foregroundStyle(.red)
                                .font(.subheadline)
                        }
                    }
                }

                if let keyActionError {
                    Label(keyActionError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Divider()

            // Quick link
            HStack {
                Link("Get an API key from OpenRouter →", destination: URL(string: "https://openrouter.ai/settings/keys")!)
                    .font(.callout)
                Spacer()
            }
        }
    }

    // MARK: - Management Key (role-aware credentials, F03/W04)

    private var managementKeySection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Management Key", systemImage: "lock.shield")
                .font(.title2.weight(.semibold))

            Text(ManagementKeyPanel.explanation)
                .font(.callout)
                .foregroundStyle(.secondary)

            // Current configured state, read from the service.
            HStack {
                Circle()
                    .fill(account.hasManagementKey ? Color.green : Color.orange)
                    .frame(width: 10, height: 10)
                Text(account.hasManagementKey
                    ? "Management key configured"
                    : "No management key set")
                    .font(.subheadline.weight(.medium))
                Spacer()
            }
            .padding(12)
            .background(.quaternary.opacity(0.3))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 8) {
                Text(account.hasManagementKey ? "Replace Management Key" : "Enter Management Key")
                    .font(.subheadline.weight(.medium))

                // Write-only by design: a SecureField with no reveal affordance.
                // The value is never displayed back, echoed, or logged.
                SecureField("sk-or-...", text: $management.draftKey)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13, design: .monospaced))

                HStack {
                    Button(account.hasManagementKey ? "Replace Key" : "Save Key") {
                        management.saveDraft(into: account)
                        // A newly-authorized role can now load the locked panels.
                        if management.showSaved {
                            Task { await refreshAccount() }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!management.canSave)

                    if management.showSaved {
                        Label("Saved!", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.subheadline)
                            .transition(.opacity)
                    }

                    Spacer()

                    if account.hasManagementKey {
                        Button("Remove Key") {
                            showRemoveManagementKeyConfirmation = true
                        }
                        .foregroundStyle(.red)
                    }
                }

                if let error = management.actionError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Link(
                "Create a management key on openrouter.ai →",
                destination: URL(string: "https://openrouter.ai/settings/keys")!
            )
            .font(.callout)
        }
    }

    // MARK: - Credits

    private var creditsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Account Credits", systemImage: "dollarsign.circle.fill")
                    .font(.title2.weight(.semibold))
                Spacer()
                if account.isLoadingCredits {
                    ProgressView().scaleEffect(0.7)
                } else {
                    Button {
                        Task { await account.fetchCredits() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .help("Refresh credits")
                }
            }

            if !KeychainManager.hasAPIKey {
                noKeyBanner
            } else if let error = account.creditsError {
                ErrorBanner(message: error)
            } else if let credits = account.credits {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                    CreditCard(title: "Total Credits", value: formatCurrency(credits.totalCredits), icon: "banknote.fill", color: .green)
                    CreditCard(title: "Total Used", value: formatCurrency(credits.totalUsage), icon: "chart.line.downtrend.xyaxis", color: .orange)
                    CreditCard(title: "Remaining", value: formatCurrency(credits.remaining), icon: "wallet.bifold.fill", color: credits.remaining > 0 ? .blue : .red)
                    CreditCard(title: "Usage %", value: credits.totalCredits > 0 ? String(format: "%.1f%%", credits.totalUsage / credits.totalCredits * 100) : "0%", icon: "percent", color: .purple)
                }

                // Usage bar
                if credits.totalCredits > 0 {
                    VStack(alignment: .leading, spacing: 4) {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(.quaternary)
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(credits.remaining > 0 ? Color.blue : Color.red)
                                    .frame(width: geo.size.width * CGFloat(min(credits.totalUsage / credits.totalCredits, 1.0)))
                            }
                        }
                        .frame(height: 8)
                        HStack {
                            Text("0%")
                                .font(.caption2).foregroundStyle(.tertiary)
                            Spacer()
                            Text("Used \(String(format: "%.1f%%", credits.totalUsage / credits.totalCredits * 100))")
                                .font(.caption2).foregroundStyle(.secondary)
                            Spacer()
                            Text("100%")
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.top, 4)
                }
            } else {
                Text("Pull to refresh or tap the arrow to check your credits.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Activity

    private var activitySection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Usage Activity", systemImage: "chart.bar.fill")
                    .font(.title2.weight(.semibold))
                Spacer()
                if account.isLoadingActivity {
                    ProgressView().scaleEffect(0.7)
                } else {
                    Button {
                        Task { await account.fetchActivity() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .help("Refresh activity")
                }
            }

            if !KeychainManager.hasAPIKey {
                noKeyBanner
            } else if let error = account.activityError {
                ErrorBanner(message: error)
            } else if account.activity.isEmpty && !account.isLoadingActivity {
                Text("No activity found. Usage data appears after you make API calls.")
                    .foregroundStyle(.secondary)
            } else {
                // Summary stats
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    CreditCard(title: "Total Spend", value: formatCurrency(account.totalSpend), icon: "dollarsign.circle", color: .orange)
                    CreditCard(title: "Requests", value: "\(account.totalRequests)", icon: "arrow.left.arrow.right", color: .blue)
                    CreditCard(title: "Models Used", value: "\(account.topModels.count)", icon: "cpu", color: .purple)
                }

                // Top models
                if !account.topModels.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Top Models")
                            .font(.headline)

                        ForEach(account.topModels.prefix(10), id: \.model) { item in
                            HStack {
                                Text(item.model)
                                    .font(.system(size: 12, design: .monospaced))
                                    .lineLimit(1)
                                Spacer()
                                Text("\(item.requests) reqs")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(formatCurrency(item.usage))
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(.orange)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                    .padding(.top, 8)
                }

                // Daily spend
                if !account.dailySpend.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Daily Spend")
                            .font(.headline)

                        ForEach(account.dailySpend.prefix(14), id: \.date) { item in
                            HStack {
                                Text(item.date)
                                    .font(.system(size: 12, design: .monospaced))
                                Spacer()
                                Text(formatCurrency(item.amount))
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(.orange)
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

    private var noKeyBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "key.fill")
                .foregroundStyle(.orange)
            Text("Configure your API key in the API Key tab to see account data.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.orange.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func formatCurrency(_ value: Double) -> String {
        if value < 0.01 {
            return String(format: "$%.4f", value)
        }
        return String(format: "$%.2f", value)
    }

    private func refreshAccount() async {
        await account.fetchCredits()
        await account.fetchActivity()
        await directory.fetchKeyInfo()
    }

    // MARK: - Key Info (`GET /key`)

    private var keyInfoSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Current Key", systemImage: "key.fill")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button {
                    Task { await directory.fetchKeyInfo() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("Refresh key info")
            }

            if !KeychainManager.hasAPIKey {
                noKeyBanner
            } else if let error = directory.lastError, directory.keyInfo == nil {
                ErrorBanner(message: error)
            } else if let info = directory.keyInfo {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                    CreditCard(title: "Label", value: info.label ?? "—", icon: "tag.fill", color: .blue)
                    CreditCard(
                        title: "Spend Limit",
                        value: info.limit.map { formatCurrency($0) } ?? "No limit",
                        icon: "gauge.with.dots.needle.67percent", color: .purple
                    )
                    CreditCard(
                        title: "Remaining",
                        value: info.limitRemaining.map { formatCurrency($0) } ?? "—",
                        icon: "wallet.bifold.fill",
                        color: (info.limitRemaining ?? 1) > 0 ? .green : .red
                    )
                    CreditCard(title: "Used (total)", value: formatCurrency(info.usage ?? 0), icon: "chart.line.uptrend.xyaxis", color: .orange)
                }
                VStack(alignment: .leading, spacing: 6) {
                    keyInfoRow("Reset", info.limitReset ?? "—")
                    keyInfoRow("Today", formatCurrency(info.usageDaily ?? 0))
                    keyInfoRow("This week", formatCurrency(info.usageWeekly ?? 0))
                    keyInfoRow("This month", formatCurrency(info.usageMonthly ?? 0))
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
                Text("Tap the arrow to load key limits and usage.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func keyInfoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.callout).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.system(size: 12, design: .monospaced))
        }
        .padding(.vertical, 2)
    }

    // MARK: - Providers (`GET /providers`)

    private var providersSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Providers", systemImage: "building.2.fill")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button {
                    Task { await directory.fetchProviders() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("Refresh providers")
            }
            .task { await directory.fetchProviders() }

            if let error = directory.lastError, directory.providers.isEmpty {
                ErrorBanner(message: error)
            } else if directory.providers.isEmpty {
                Text("No providers loaded yet.")
                    .foregroundStyle(.secondary)
            } else {
                Text("\(directory.providers.count) providers serve models on OpenRouter.")
                    .font(.callout).foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ForEach(directory.providers) { provider in
                        HStack(spacing: 6) {
                            Circle().fill(Color.accentColor.opacity(0.6)).frame(width: 7, height: 7)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(provider.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                Text(provider.slug).font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary).lineLimit(1)
                            }
                            Spacer()
                        }
                        .padding(8)
                        .background(Color.primary.opacity(0.04))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
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

    static let explanation = "A management key unlocks account-wide credits, usage activity, and administration on OpenRouter. Chat and media generation keep working with your inference key — they never use this one."

    static let removeTitle = "Remove the management key?"

    static let removeMessage = "Credits, activity, and administration will be unavailable until another management key is saved. Chat keeps working with your inference key."

    static let removeButtonLabel = "Remove Management Key"

    var canSave: Bool { !normalizedDraft.isEmpty }
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
        service.removeManagementKey()
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
                    .font(.system(size: 11))
                    .foregroundStyle(color)
                Text(title)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(size: 18, weight: .semibold, design: .monospaced))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(color.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

struct ErrorBanner: View {
    let message: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.red.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
