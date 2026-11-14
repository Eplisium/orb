import AppKit
import SwiftUI

/// Text-only models receive a response check; tool models build projects.
struct TestSuiteView: View {
    @ObservedObject var viewModel: BrowserViewModel
    @ObservedObject private var testRunner = StudioServices.shared.testRunner

    @StudioState("TestSuiteView.selectedCategory") private var selectedCategory: TestCategory? = nil
    @StudioState("TestSuiteView.selectedScenario") private var selectedScenario: TestScenario? = nil
    @StudioState("TestSuiteView.selectedModelId") private var selectedModelId = ""
    @State private var showModelPicker = false
    @State private var approvalHostID = UUID()
    @StudioState("TestSuiteView.modelSearchText") private var modelSearchText = ""
    @State private var showCreateTest = false
    @StudioState("TestSuiteView.customTests") private var customTests: [CustomTest] = []
    @State private var showSavedResults = false
    @StudioState("TestSuiteView.userInstructions") private var userInstructions = ""
    @StudioState("TestSuiteView.toolCapableOnly") private var toolCapableOnly = false
    @State private var showBatchPicker = false
    @State private var showBatchConfirmation = false
    @StudioState("TestSuiteView.batchSelectedIDs") private var batchSelectedIDs: Set<String> = []
    @StudioState("TestSuiteView.batchSearch") private var batchSearch = ""
    @StudioState("TestSuiteView.batchCeiling") private var batchCeiling = "1.00"
    @State private var showClearConfirmation = false
    /// Pending rerun awaiting cost confirmation (single row or failed/unverified batch).
    @State private var pendingRerun: [TestRerunBatch] = []
    @State private var showRerunConfirmation = false
    @State private var leaderboardRecords: [ExperimentRunRecord] = []
    @State private var leaderboardMode: ModelLeaderboard.ModeFilter = .all
    @State private var resultsNotice: String?
    /// Test the Compare picker will run; preselected when a hand-off arrives with no test open.
    @State private var batchScenarioID: String?
    @State private var batchOpenedFromHandoff = false
    @State private var editingTest: CustomTest?
    @State private var pendingDeleteTest: CustomTest?

    private var leaderboard: [ModelLeaderboardRow] {
        ModelLeaderboard.rows(ModelLeaderboard.summaries(leaderboardRecords, mode: leaderboardMode))
    }

    private var batchScenario: TestScenario? {
        batchScenarioID.flatMap { scenario(id: $0) }
    }

    private var batchPlan: TestBatchLaunchPlan {
        TestBatchLaunchPlan.resolve(scenario: batchScenario, modelIDs: batchSelectedIDs, ceilingText: batchCeiling)
    }

    private var ceilingCopy: String {
        let amount = TestSpendCeilingParser.parse(batchCeiling).map { TestResultsTable.costText($0, zeroAsDash: false) } ?? "$\(batchCeiling)"
        return "Inference may cost money. Known spend is checked after each model turn against the \(amount) ceiling; the turn in flight may exceed it. Unknown cost stops the run."
    }

    private let accent = PlaygroundTheme.testAccent

    // MARK: - Design tokens (shared vocabulary: cards 10, controls 8)

    private let cardRadius: CGFloat = 10
    private let controlRadius: CGFloat = 8

    var body: some View {
        HStack(spacing: 0) {
            categorySidebar
            Rectangle()
                .fill(.orbSurface(0.07))
                .frame(width: 1)
            mainArea
        }
        .background(testBackground)
        .modifier(ApprovalSheetModifier(presenter: testRunner.approvalPresenter,
                                        isPresentationHost: testRunner.approvalHostID == approvalHostID))
        .onAppear { testRunner.registerApprovalHost(approvalHostID) }
        .onDisappear { testRunner.unregisterApprovalHost(approvalHostID) }
        .task {
            if selectedModelId.isEmpty { selectedModelId = preferredModelId }
            viewModel.loadFavorites()
            customTests = DatabaseManager.shared.loadCustomTests()
            testRunner.loadSavedResults()
            reloadLeaderboard()
            consumeCompareHandoff()
        }
        // Also consume a hand-off staged while Test Suite is already visible.
        .onReceive(NotificationCenter.default.publisher(for: .testSuiteCompareHandoffStaged)) { _ in
            consumeCompareHandoff()
        }
        .onChange(of: testRunner.totalResultCount) { _, _ in reloadLeaderboard() }
        .onChange(of: selectedScenario?.id) { _, _ in
            // Input is scoped to the run the user is looking at.
            userInstructions = ""
        }
        .sheet(isPresented: $showBatchPicker) { batchPicker }
        .sheet(item: $editingTest) { test in
            CreateTestView(accent: accent, existing: test) { updated in
                DatabaseManager.shared.saveCustomTest(updated)
                customTests = DatabaseManager.shared.loadCustomTests()
                if selectedScenario?.id == "custom-\(updated.id)" { selectedScenario = updated.toScenario() }
            }
        }
        .confirmationDialog("Delete \u{201C}\(pendingDeleteTest?.title ?? "")\u{201D}?",
                            isPresented: Binding(get: { pendingDeleteTest != nil }, set: { if !$0 { pendingDeleteTest = nil } }),
                            titleVisibility: .visible) {
            Button("Delete Test", role: .destructive) {
                if let test = pendingDeleteTest { deleteCustomTest(test) }
                pendingDeleteTest = nil
            }
            Button("Cancel", role: .cancel) { pendingDeleteTest = nil }
        } message: {
            Text("Its saved results stay in the Results table but can no longer be opened or rerun.")
        }
        .confirmationDialog("Delete all \(testRunner.totalResultCount) saved test results?",
                            isPresented: $showClearConfirmation, titleVisibility: .visible) {
            Button("Delete \(testRunner.totalResultCount) Results", role: .destructive) {
                DatabaseManager.shared.clearTestResults()
                testRunner.clearResults()
            }
        } message: {
            Text("This can't be undone. Experiment records used by the leaderboard are kept.")
        }
        .confirmationDialog(rerunTitle, isPresented: $showRerunConfirmation, titleVisibility: .visible) {
            Button("Run \(TestRerunPlanner.modelCount(pendingRerun)) model run\(TestRerunPlanner.modelCount(pendingRerun) == 1 ? "" : "s")") {
                startPendingRerun()
            }
            Button("Cancel", role: .cancel) { pendingRerun = [] }
        } message: {
            Text(ceilingCopy + " The ceiling is set in Compare Models.")
        }
        .confirmationDialog("Run \(batchScenario?.title ?? "test") on \(batchSelectedIDs.count) model\(batchSelectedIDs.count == 1 ? "" : "s")?",
                            isPresented: $showBatchConfirmation, titleVisibility: .visible) {
            Button("Run \(batchSelectedIDs.count) model\(batchSelectedIDs.count == 1 ? "" : "s")") { startBatch() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(ceilingCopy + " Text responses do not verify a project.")
        }
    }

    private var testBackground: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            RadialGradient(
                colors: [accent.opacity(0.06), .clear],
                center: .top,
                startRadius: 20,
                endRadius: 600
            )
        }
        .ignoresSafeArea()
    }

    private var batchPickerModels: [ModelInfo] {
        let favorites = viewModel.favoriteIds
        return viewModel.api.models.filter {
            TestModelRoute.resolve($0) != nil &&
            (batchSearch.isEmpty || $0.id.localizedCaseInsensitiveContains(batchSearch) ||
             $0.name.localizedCaseInsensitiveContains(batchSearch))
        }
        .enumerated()
        .sorted { lhs, rhs in
            let lf = favorites.contains(lhs.element.id), rf = favorites.contains(rhs.element.id)
            return lf != rf ? lf : lhs.offset < rhs.offset
        }
        .map(\.element)
    }

    private var batchPicker: some View {
        let cap = TestBatchSelection.maximumModels
        let atCap = batchSelectedIDs.count >= cap
        return VStack(alignment: .leading, spacing: 12) {
            Text(batchOpenedFromHandoff && batchScenarioID == TestCatalog.defaultCompareScenario.id && selectedScenario == nil
                 ? "Pick a test to run on these \(batchSelectedIDs.count) model\(batchSelectedIDs.count == 1 ? "" : "s")"
                 : "Compare models on a test").font(.headline)
            HStack(spacing: 8) {
                Text("Test").font(ORBFont.footnote.weight(.semibold))
                Picker("Test", selection: $batchScenarioID) {
                    Text("Choose a test…").tag(String?.none)
                    if !customTests.isEmpty {
                        Section("Custom tests") {
                            ForEach(customTests) { Text($0.title).tag(String?.some("custom-\($0.id)")) }
                        }
                    }
                    Section("Text probes") {
                        ForEach(TestCatalog.edgeCaseScenarios) { Text($0.title).tag(String?.some($0.id)) }
                    }
                    Section("Project builds") {
                        ForEach(TestCatalog.allScenarios) { Text($0.title).tag(String?.some($0.id)) }
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 320)
            }
            Text(batchScenario.map { $0.evaluationMode == .textResponse
                    ? "Text probe: one streamed answer per model, no tools."
                    : "Project build: tool models run the agent (commands ask for approval); text-only models answer in text." }
                 ?? "Pick the test these models will run. Nothing starts until you confirm.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("Search models", text: $batchSearch)
                Text("\(batchSelectedIDs.count) of \(cap) selected")
                    .font(ORBFont.caption.monospacedDigit())
                    .foregroundStyle(atCap ? ORBTheme.warning : .secondary)
                    .fixedSize()
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(batchPickerModels, id: \.id) { model in
                        let selected = batchSelectedIDs.contains(model.id)
                        Button {
                            if selected {
                                batchSelectedIDs.remove(model.id)
                            } else if !atCap {
                                batchSelectedIDs.insert(model.id)
                            }
                        } label: {
                            HStack {
                                Image(systemName: selected ? "checkmark.square.fill" : "square")
                                if viewModel.favoriteIds.contains(model.id) {
                                    Image(systemName: "star.fill").foregroundStyle(.yellow).font(ORBFont.caption)
                                        .accessibilityLabel("Favorite")
                                }
                                Text(model.name).lineLimit(1)
                                Spacer()
                                Text(ModelRowFacts.make(model).compactPrice)
                                    .font(ORBFont.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .help("Prompt / completion price per million tokens")
                                Text(batchScenario?.evaluationMode == .textResponse ? "Text probe" :
                                     TestModelRoute.resolve(model) == .project ? "Project" : "Text only")
                                    .font(ORBFont.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 66, alignment: .trailing)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 4)
                        .disabled(!selected && atCap)
                        .help(!selected && atCap ? "Up to \(cap) models per comparison. Deselect one to add another." : "")
                    }
                }
            }
            HStack {
                Text("Spend ceiling (USD)")
                TextField("1.00", text: $batchCeiling).frame(width: 90)
                if let reason = batchPlan.blockedReason {
                    Text(reason).font(ORBFont.caption).foregroundStyle(ORBTheme.warning).lineLimit(2)
                }
                Spacer()
                Button("Cancel") { showBatchPicker = false }
                Button("Review \(batchSelectedIDs.count) model\(batchSelectedIDs.count == 1 ? "" : "s")") {
                    showBatchPicker = false
                    showBatchConfirmation = true
                }
                .keyboardShortcut(.defaultAction)
                .disabled(batchPlan.blockedReason != nil)
            }
        }
        .padding(20)
        .frame(width: 600, height: 520)
    }

    /// Opens the picker for models staged by Browse → Compare. With no
    /// test open, a cheap exactly-checked text probe is preselected and
    /// the title asks the user to confirm or pick another test.
    private func consumeCompareHandoff() {
        guard let ids = CompareHandoff.shared.take() else { return }
        batchSelectedIDs = Set(ids)
        batchSearch = ""
        batchScenarioID = selectedScenario?.id ?? TestCatalog.defaultCompareScenario.id
        batchOpenedFromHandoff = true
        showBatchPicker = true
    }

    private func openBatchPicker(preselecting ids: Set<String>, scenario: TestScenario) {
        batchSelectedIDs = ids
        batchSearch = ""
        batchScenarioID = scenario.id
        batchOpenedFromHandoff = false
        showBatchPicker = true
    }

    private func startBatch() {
        switch batchPlan {
        case .run(let scenarioID, let ids, let ceiling):
            guard let scenario = scenario(id: scenarioID) else {
                testRunner.batchNotice = "This test no longer exists."
                return
            }
            if selectedScenario?.id != scenario.id {
                selectedScenario = scenario
                selectedCategory = nil
            }
            testRunner.start(scenario: scenario, modelIDs: ids, models: viewModel.api.models,
                             userInput: userInstructions, ceilingUSD: ceiling)
        case let blocked:
            testRunner.batchNotice = blocked.blockedReason
        }
    }

    private func reloadLeaderboard() {
        leaderboardRecords = DatabaseManager.shared.loadExperimentRunRecords()
    }

    private func deleteCustomTest(_ test: CustomTest) {
        DatabaseManager.shared.deleteCustomTest(test.id)
        customTests = DatabaseManager.shared.loadCustomTests()
        if selectedScenario?.id == "custom-\(test.id)" { selectedScenario = nil }
        resultsNotice = "Deleted \u{201C}\(test.title)\u{201D}."
    }

    // MARK: - Category Sidebar

    private var categorySidebar: some View {
        VStack(spacing: 0) {
            sidebarHeader
            modelSelector
            categoryList
            Spacer(minLength: 0)
            sidebarFooter
        }
        .frame(width: 232)
        .background(.ultraThinMaterial.opacity(0.72))
    }

    private var sidebarHeader: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(
                        LinearGradient(
                            colors: [accent, Color(red: 0.98, green: 0.55, blue: 0.42)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: "checkmark.seal.fill")
                    .orbFont(size: 13, weight: .bold)
                    .foregroundStyle(.white)
            }
            .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 1) {
                Text("Test Suite")
                    .orbFont(size: 14, weight: .semibold)
                Text("Text & project tests")
                    .orbFont(size: 11, weight: .medium)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    private var modelSelector: some View {
        HStack(spacing: 6) {
            Image(systemName: "cpu")
                .foregroundStyle(accent)
            Text(shortModelName(currentModelId))
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .orbFont(size: 11, weight: .bold)
                .foregroundStyle(.tertiary)
        }
        .orbFont(size: 11, weight: .semibold)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.orbSurface(0.05))
        .clipShape(RoundedRectangle(cornerRadius: controlRadius))
        .contentShape(Rectangle())
        .onTapGesture {
            modelSearchText = ""
            showModelPicker = true
        }
        .popover(isPresented: $showModelPicker, arrowEdge: .bottom) {
            PlaygroundModelPicker(
                models: viewModel.api.models,
                favoriteIds: viewModel.favoriteIds,
                selectedModelId: $selectedModelId,
                searchText: $modelSearchText,
                toolCapableOnly: $toolCapableOnly,
                accent: accent,
                toggleFavorite: viewModel.toggleFavorite,
                dismiss: { showModelPicker = false }
            )
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }

    private var categoryList: some View {
        ScrollView {
            LazyVStack(spacing: 6, pinnedViews: [.sectionHeaders]) {
                Section {
                    categoryButton(nil)
                    ForEach(TestCategory.allCases) { category in
                        categoryButton(category)
                    }
                    if !customTests.isEmpty {
                        customTestsSection
                    }
                } header: {
                    HStack(spacing: 6) {
                        Image(systemName: "square.grid.2x2")
                            .orbFont(size: 11, weight: .semibold)
                            .foregroundStyle(accent)
                        Text("CATEGORIES")
                            .orbFont(size: 11, weight: .bold)
                        Spacer()
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial.opacity(0.92))
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 12)
        }
    }

    private var customTestsSection: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "plus.app")
                    .orbFont(size: 11, weight: .semibold)
                    .foregroundStyle(accent)
                Text("CUSTOM TESTS")
                    .orbFont(size: 11, weight: .bold)
                Spacer()
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .padding(.top, 6)

            ForEach(customTests) { test in
                customTestButton(test)
            }
        }
    }

    private func customTestButton(_ test: CustomTest) -> some View {
        let isSelected = selectedScenario?.id == "custom-\(test.id)"

        return HStack(spacing: 6) {
            Image(systemName: test.icon)
                .orbFont(size: 11, weight: .semibold)
                .foregroundStyle(isSelected ? accent : .secondary)
            Text(test.title)
                .orbFont(size: 12, weight: isSelected ? .semibold : .medium)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(isSelected ? accent.opacity(0.14) : Color.primary.opacity(0.025))
        .overlay {
            RoundedRectangle(cornerRadius: controlRadius)
                .stroke(isSelected ? accent.opacity(0.34) : Color.primary.opacity(0.04), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: controlRadius))
        .contextMenu {
            Button("Edit…") { editingTest = test }
            Button("Delete…", role: .destructive) { pendingDeleteTest = test }
        }
        .help(test.mode == .textResponse ? "Custom text test — right-click to edit or delete"
              : "Custom project test — right-click to edit or delete")
        .onTapGesture {
            selectedScenario = test.toScenario()
            selectedCategory = nil
        }
    }

    private func categoryButton(_ category: TestCategory?) -> some View {
        let isSelected = selectedCategory == category && selectedScenario == nil
        let title = category?.rawValue ?? "All Tests"
        let icon = category?.icon ?? "checkmark.seal"
        let count = category == nil
            ? TestCatalog.availableScenarios.count
            : TestCatalog.scenarios(in: category!).count

        return Button {
            selectedCategory = category
            selectedScenario = nil
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .orbFont(size: 11, weight: .semibold)
                    .foregroundStyle(isSelected ? accent : .secondary)
                Text(title)
                    .orbFont(size: 12, weight: isSelected ? .semibold : .medium)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text("\(count)")
                    .orbFont(size: 11, weight: .medium, design: .monospaced)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(isSelected ? accent.opacity(0.14) : Color.primary.opacity(0.025))
            .overlay {
                RoundedRectangle(cornerRadius: controlRadius)
                    .stroke(isSelected ? accent.opacity(0.34) : Color.primary.opacity(0.04), lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: controlRadius))
        }
        .buttonStyle(.plain)
    }

    private var sidebarFooter: some View {
        VStack(spacing: 9) {
            Rectangle()
                .fill(.orbSurface(0.07))
                .frame(height: 1)

            HStack(spacing: 7) {
                Circle()
                    .fill(runnerStatusColor)
                    .frame(width: 7, height: 7)
                    .shadow(color: runnerStatusColor.opacity(0.6), radius: 3)
                Text(runnerStatusText)
                    .orbFont(size: 11, weight: .medium)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            if !testRunner.results.isEmpty {
                HStack {
                    Label("\(testRunner.results.count)", systemImage: "checkmark.circle")
                    Spacer()
                    Text(testRunner.formattedTotalCost)
                }
                .orbFont(size: 11, weight: .medium, design: .monospaced)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 13)
    }

    private var runnerStatusColor: Color {
        if testRunner.isRunning { return .orange }
        if !testRunner.results.isEmpty { return .green }
        return KeychainManager.hasAPIKey ? .blue : .orange
    }

    private var runnerStatusText: String {
        if testRunner.isRunning {
            return testRunner.activityLabel.isEmpty ? "Running test…" : testRunner.activityLabel
        }
        if !testRunner.results.isEmpty { return "\(testRunner.results.count) results saved" }
        return KeychainManager.hasAPIKey ? "Ready to test" : "API key needed"
    }

    // MARK: - Main Area

    private var mainArea: some View {
        VStack(spacing: 0) {
            testHeader
            Rectangle()
                .fill(.orbSurface(0.07))
                .frame(height: 1)

            // A running batch keeps spending after the user navigates away
            // from its scenario detail; outside the detail (which carries its
            // own Cancel row) this banner is the only way to stop it.
            if testRunner.isRunning, selectedScenario == nil {
                runBanner
            }

            if let scenario = selectedScenario {
                scenarioDetail(scenario)
            } else {
                scenarioGrid
            }
        }
    }

    /// Persistent status and Cancel for a run the user has navigated away from.
    private var runBanner: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text(testRunner.activityLabel.isEmpty ? "Running test…" : testRunner.activityLabel)
                    .orbFont(size: 11, weight: .semibold)
                    .lineLimit(1)
                if testRunner.batchTotal > 0 {
                    Text("\(testRunner.batchCompleted)/\(testRunner.batchTotal) finished · \(testRunner.runningModelId ?? "")")
                        .orbFont(size: 11, design: .monospaced)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            CostCeilingBar(progress: CostCeilingProgress(
                spent: testRunner.batchSpent, ceiling: testRunner.batchCeilingUSD,
                unreportedRuns: testRunner.batchUnreportedRuns))
                .frame(maxWidth: 220)
            Spacer(minLength: 8)
            Button("Cancel", role: .destructive) { testRunner.cancel() }
                .controlSize(.small)
                .help("Cancel the running test (it keeps spending until stopped)")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .background(ORBTheme.accentSubtle)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Test run in progress. \(testRunner.activityLabel)")
    }

    private var testHeader: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(selectedCategory?.rawValue ?? "All Tests")
                    .orbFont(size: 16, weight: .semibold)
                if let cat = selectedCategory {
                    Text(cat.description)
                        .orbFont(size: 11, weight: .medium)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text("\(TestCatalog.availableScenarios.count) prompts — project tasks use tools when available; text probes do not")
                        .orbFont(size: 11, weight: .medium)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 16)

            // Always available: hiding it until a custom test existed made
            // the first custom test impossible to create from "All Tests".
            Button {
                showCreateTest = true
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "plus")
                    Text("New Test")
                }
                .orbFont(size: 11, weight: .semibold)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(accent.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: controlRadius))
            }
            .buttonStyle(.plain)
            .help("Create a custom test with your own prompt")

            // No implicit category-wide paid inference.
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
        .background(.ultraThinMaterial.opacity(0.45))
        .sheet(isPresented: $showCreateTest) {
            CreateTestView(accent: accent) { newTest in
                DatabaseManager.shared.saveCustomTest(newTest)
                customTests = DatabaseManager.shared.loadCustomTests()
                selectedScenario = newTest.toScenario()
                selectedCategory = nil
            }
        }
    }

    // MARK: - Scenario Grid

    private var scenarioGrid: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Saved results
                if !testRunner.results.isEmpty {
                    savedResultsSection
                } else if !leaderboardRecords.isEmpty {
                    // Clear All deletes results but keeps experiment records;
                    // the leaderboard built from them stays reachable.
                    VStack(alignment: .leading, spacing: 8) {
                        Text("MODEL LEADERBOARD").orbFont(size: 11, weight: .bold).foregroundStyle(.secondary)
                        leaderboardSection
                    }
                    .frame(maxWidth: 880, alignment: .leading)
                }

                // Scenario cards
                VStack(alignment: .leading, spacing: 12) {
                    Text("AVAILABLE TESTS")
                        .orbFont(size: 11, weight: .bold)
                        .foregroundStyle(.secondary)

                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                        ForEach(filteredScenarios) { scenario in
                            scenarioCard(scenario)
                        }
                    }
                }
                .frame(maxWidth: 880)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity)
        }
    }

    private var savedResultsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("RECENT RESULTS")
                    .orbFont(size: 11, weight: .bold)
                    .foregroundStyle(.secondary)
                Spacer()
                let rerunBatches = TestRerunPlanner.batches(from: testRunner.results)
                if !rerunBatches.isEmpty {
                    Button("Rerun failed/unverified (\(TestRerunPlanner.modelCount(rerunBatches)))") {
                        confirmRerun(rerunBatches)
                    }
                    .disabled(testRunner.isRunning)
                    .help("Reruns the latest failed or unverified result for each scenario and model.")
                }
                Menu("Export") {
                    Button("Results as CSV…") { exportResultsCSV() }
                    Button("Results with Responses as CSV…") { exportResultsCSV(includeResponses: true) }
                    Button("Experiment Records as JSON…") { exportExperimentJSON() }
                }
                .menuStyle(.borderlessButton).fixedSize()
                Button {
                    showClearConfirmation = true
                } label: {
                    Text("Clear All")
                        .orbFont(size: 11, weight: .medium)
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
            }

            if let notice = TestResultsPaging.notice(shown: testRunner.results.count, total: testRunner.totalResultCount) {
                HStack {
                    Text(notice).orbFont(size: 11).foregroundStyle(.secondary)
                    Button("Load all") { testRunner.loadAllResults() }.buttonStyle(.link).orbFont(size: 11)
                }
            }
            if let resultsNotice {
                PlaygroundErrorBanner(message: resultsNotice) { self.resultsNotice = nil }
            }

            Text("Older saved passes may predate artifact checks; rerun to verify them. — cost means zero or unreported; totals are lower bounds.")
                .orbFont(size: 11).foregroundStyle(.secondary)

            DisclosureGroup("Compare models side by side") {
                CompareMatrixView(results: testRunner.results).padding(.top, 6)
            }
            .font(ORBFont.footnote)

            DisclosureGroup("Model leaderboard (all recorded runs)") {
                leaderboardSection.padding(.top, 6)
            }
            .font(ORBFont.footnote)

            TestResultsTableView(
                results: testRunner.results,
                onOpen: { result in
                    if let scenario = scenario(id: result.scenarioId) {
                        selectedScenario = scenario
                        selectedModelId = result.modelId
                    } else {
                        resultsNotice = "This test no longer exists."
                    }
                },
                onDelete: { result in
                    DatabaseManager.shared.deleteTestResult(result.id)
                    testRunner.loadSavedResults()
                },
                onRerun: { result in
                    confirmRerun([TestRerunBatch(scenarioID: result.scenarioId, modelIDs: [result.modelId])])
                }
            )
        }
        .frame(maxWidth: 880, alignment: .leading)
    }

    private var leaderboardSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Runs", selection: $leaderboardMode) {
                ForEach(ModelLeaderboard.ModeFilter.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 320)
            ModelLeaderboardView(rows: leaderboard)
        }
    }

    private var filteredScenarios: [TestScenario] {
        if let category = selectedCategory {
            return TestCatalog.scenarios(in: category).sorted { $0.difficulty.sortOrder < $1.difficulty.sortOrder }
        }
        return TestCatalog.availableScenarios.sorted { $0.difficulty.sortOrder < $1.difficulty.sortOrder }
    }

    private func scenarioCard(_ scenario: TestScenario) -> some View {
        let result = testRunner.results.first { $0.scenarioId == scenario.id && $0.modelId == currentModelId }

        return Button {
            selectedScenario = scenario
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(accent.opacity(0.10))
                        Image(systemName: scenario.icon)
                            .orbFont(size: 14, weight: .semibold)
                            .foregroundStyle(accent)
                    }
                    .frame(width: 34, height: 34)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(scenario.title)
                            .orbFont(size: 13, weight: .semibold)
                            .lineLimit(1)
                            // Long titles truncate at the default width; the
                            // full name stays one hover away.
                            .help(scenario.title)
                        Text(scenario.category.rawValue)
                            .orbFont(size: 11, weight: .medium)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()

                    if let result {
                        resultBadge(result)
                    }
                }

                Text(scenario.subtitle)
                    .orbFont(size: 11)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 8) {
                    difficultyTag(scenario.difficulty)
                    Label("\(scenario.estimatedSeconds)s", systemImage: "clock")
                        .orbFont(size: 11, weight: .medium)
                        .foregroundStyle(.tertiary)
                    if ScenarioCardBadge.showsBuilt(result) {
                        Label("Built", systemImage: "folder.badge.checkmark")
                            .orbFont(size: 11, weight: .medium)
                            .foregroundStyle(.green)
                    }
                    Spacer()
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.orbSurface(0.032))
            .overlay {
                RoundedRectangle(cornerRadius: cardRadius)
                    .stroke(.orbSurface(0.06), lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: cardRadius))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Browsing other tests stays possible during a run; only Run is disabled.
    }

    private func resultBadge(_ result: TestRunResult) -> some View {
        let unverified = result.errorMessage == TestRunner.unverifiedMessage
        return HStack(spacing: 3) {
            Image(systemName: unverified ? "questionmark.circle.fill" : result.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                .orbFont(size: 11)
            Text(unverified ? "Review" : result.success ? "Pass" : "Fail")
                .orbFont(size: 11, weight: .bold)
        }
        .foregroundStyle(unverified ? Color.orange : result.success ? Color.green : Color.red)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background((unverified ? Color.orange : result.success ? Color.green : Color.red).opacity(0.10))
        .clipShape(Capsule())
    }

    private func difficultyTag(_ difficulty: TestDifficulty) -> some View {
        let color: Color = {
            switch difficulty {
            case .foundational: return .green
            case .intermediate: return .blue
            case .advanced: return .orange
            case .expert: return .red
            }
        }()

        return Text(difficulty.rawValue.uppercased())
            .orbFont(size: 11, weight: .bold)
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.10))
            .clipShape(Capsule())
    }

    // MARK: - Scenario Detail

    private func scenarioDetail(_ scenario: TestScenario) -> some View {
        let result = testRunner.results.first { $0.scenarioId == scenario.id && $0.modelId == currentModelId }
        let isThisRunning = testRunner.isRunning && testRunner.runningScenarioId == scenario.id
        let isEligible = viewModel.api.models.contains { $0.id == currentModelId && TestModelRoute.resolve($0) != nil }

        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                HStack(spacing: 12) {
                    Button {
                        selectedScenario = nil
                    } label: {
                        Image(systemName: "chevron.left")
                            .orbFont(size: 12, weight: .semibold)
                    }
                    .buttonStyle(.plain)
                    .help("Back to all tests")

                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(accent.opacity(0.10))
                        Image(systemName: scenario.icon)
                            .orbFont(size: 18, weight: .semibold)
                            .foregroundStyle(accent)
                    }
                    .frame(width: 42, height: 42)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(scenario.title)
                            .orbFont(size: 18, weight: .semibold)
                        Text(scenario.subtitle)
                            .orbFont(size: 12)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()
                    difficultyTag(scenario.difficulty)
                }
                .frame(maxWidth: 820)

                // Meta
                HStack(spacing: 14) {
                    Label(scenario.category.rawValue, systemImage: scenario.category.icon)
                    Label("\(scenario.estimatedSeconds)s est.", systemImage: "clock")
                    Label("\(scenario.evaluationCriteria.count) review criteria", systemImage: "checklist")
                    Spacer()
                }
                .orbFont(size: 11, weight: .medium)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 820)

                // Evaluation Criteria
                VStack(alignment: .leading, spacing: 8) {
                    Text("REVIEW CRITERIA — NOT AUTOMATICALLY SCORED")
                        .orbFont(size: 11, weight: .bold)
                        .foregroundStyle(.secondary)
                    ForEach(scenario.evaluationCriteria, id: \.self) { criterion in
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle")
                                .orbFont(size: 11)
                                .foregroundStyle(accent)
                            Text(criterion)
                                .orbFont(size: 12)
                        }
                    }
                }
                .frame(maxWidth: 820, alignment: .leading)

                userInputSection(isRunning: isThisRunning)

                Divider().frame(maxWidth: 820)

                // Run controls: buttons on one row; progress and the ceiling
                // bar on their own row so nothing wraps at 960 pt.
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        Button {
                            runScenario(scenario)
                        } label: {
                            HStack(spacing: 6) {
                                if isThisRunning {
                                    ProgressView()
                                        .controlSize(.small)
                                        .tint(.white)
                                } else {
                                    Image(systemName: "play.fill")
                                }
                                Text(isThisRunning ? (testRunner.activityLabel.isEmpty ? "Running…" : testRunner.activityLabel) : "Run Test")
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                            .orbFont(size: 13, weight: .semibold)
                            .foregroundStyle(.white)
                            .frame(maxWidth: 220)
                            .fixedSize(horizontal: !isThisRunning, vertical: false)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 9)
                            .background(isThisRunning ? Color.gray : accent)
                            .clipShape(RoundedRectangle(cornerRadius: controlRadius))
                        }
                        .buttonStyle(.plain)
                        .disabled(testRunner.isRunning || !KeychainManager.hasAPIKey || !isEligible)
                        .help(isThisRunning ? testRunner.activityLabel : "Run this test on \(shortModelName(currentModelId))")

                        Button("Compare Models…") {
                            openBatchPicker(preselecting: isEligible ? [currentModelId] : [], scenario: scenario)
                        }
                        .disabled(testRunner.isRunning || !KeychainManager.hasAPIKey)

                        if testRunner.isRunning {
                            Button("Cancel", role: .destructive) { testRunner.cancel() }
                        }
                        Spacer(minLength: 0)
                    }

                    if testRunner.isRunning {
                        HStack(spacing: 12) {
                            Text("\(testRunner.batchCompleted)/\(testRunner.batchTotal) finished · \(testRunner.runningModelId ?? "")")
                                .orbFont(size: 11).lineLimit(1).truncationMode(.middle)
                            CostCeilingBar(progress: CostCeilingProgress(
                                spent: testRunner.batchSpent, ceiling: testRunner.batchCeilingUSD,
                                unreportedRuns: testRunner.batchUnreportedRuns))
                                .frame(maxWidth: 300)
                            Spacer(minLength: 0)
                        }
                    }

                    if !KeychainManager.hasAPIKey {
                        Text("Add your OpenRouter API key in Settings → Accounts & Keys to run tests.")
                            .orbFont(size: 11)
                            .foregroundStyle(.orange)
                    } else if !isEligible {
                        Text("Choose an available text-output model to run this test.")
                            .orbFont(size: 11)
                            .foregroundStyle(.orange)
                    }
                }
                .frame(maxWidth: 820, alignment: .leading)

                if isEligible && !testRunner.isRunning {
                    Text("Single runs use credits without a ceiling. Compare Models stops at a spend ceiling, checked after each model turn.")
                        .orbFont(size: 11)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 820, alignment: .leading)
                }

                if let notice = testRunner.batchNotice {
                    Text(notice).orbFont(size: 11).foregroundStyle(.orange)
                }

                let latestPerModel = ScenarioComparison.latestPerModel(testRunner.results, scenarioID: scenario.id, limit: 10)
                if !latestPerModel.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("LATEST RESULT BY MODEL").orbFont(size: 11, weight: .bold)
                        ForEach(latestPerModel) { entry in
                            Button {
                                selectedModelId = entry.modelId
                            } label: {
                                HStack {
                                    Text(entry.modelId).lineLimit(1)
                                    Spacer()
                                    TestVerdictPill(kind: .of(entry))
                                    Text(testRunner.formattedCost(entry.cost)).monospacedDigit()
                                }
                                .orbFont(size: 11)
                                .padding(5)
                                .background(entry.modelId == currentModelId ? accent.opacity(0.10) : Color.clear)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help(TestVerdictKind.headline(entry))
                        }
                    }
                    .frame(maxWidth: 820)

                    if latestPerModel.count >= 2 {
                        DisclosureGroup("Compare answers side by side") {
                            ScenarioComparisonView(
                                results: Array(latestPerModel.prefix(TestBatchSelection.maximumModels)),
                                accent: accent)
                                .padding(.top, 6)
                        }
                        .orbFont(size: 11, weight: .medium)
                        .frame(maxWidth: 820, alignment: .leading)
                    }
                }

                // Activity log during run
                if isThisRunning, !testRunner.activityLog.isEmpty {
                    activityLogView
                        .frame(maxWidth: 820, alignment: .leading)
                }

                // Result
                if let result {
                    testResultView(scenario, result)
                }

                // System prompt preview
                DisclosureGroup("System Prompt") {
                    Text(scenario.systemPrompt)
                        .orbFont(size: 11, design: .monospaced)
                        .textSelection(.enabled)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.orbSurface(0.03))
                        .clipShape(RoundedRectangle(cornerRadius: controlRadius))
                }
                .orbFont(size: 11, weight: .medium)
                .frame(maxWidth: 820, alignment: .leading)

                DisclosureGroup("User Prompt") {
                    Text(scenario.userPrompt)
                        .orbFont(size: 11, design: .monospaced)
                        .textSelection(.enabled)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.orbSurface(0.03))
                        .clipShape(RoundedRectangle(cornerRadius: controlRadius))
                }
                .orbFont(size: 11, weight: .medium)
                .frame(maxWidth: 820, alignment: .leading)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - User Input

    /// Optional run-specific input: a small note, constraint, or extra
    /// instruction the user wants layered on top of the scenario prompt.
    private func userInputSection(isRunning: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("YOUR INPUT")
                    .orbFont(size: 11, weight: .bold)
                    .foregroundStyle(.secondary)
                Text("OPTIONAL")
                    .orbFont(size: 11, weight: .bold)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.orbSurface(0.05))
                    .clipShape(Capsule())
                Spacer()
                if !userInstructions.isEmpty {
                    Button {
                        userInstructions = ""
                    } label: {
                        Text("Clear")
                            .orbFont(size: 11, weight: .medium)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(isRunning)
                }
            }

            Text("Add a note, constraint, or extra instruction for this run. It is appended to the task prompt below.")
                .orbFont(size: 11)
                .foregroundStyle(.secondary)

            ZStack(alignment: .topLeading) {
                if userInstructions.isEmpty {
                    Text("e.g. Use a dark theme, keep the project under 200 lines…")
                        .orbFont(size: 12)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 14)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $userInstructions)
                    .orbFont(size: 12)
                    .frame(minHeight: 72)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .disabled(isRunning)
            }
            .background(.orbSurface(0.04))
            .overlay {
                RoundedRectangle(cornerRadius: controlRadius)
                    .stroke(.orbSurface(0.06), lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: controlRadius))
        }
        .frame(maxWidth: 820, alignment: .leading)
    }

    // MARK: - Activity Log

    private var activityLogView: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("AGENT ACTIVITY")
                .orbFont(size: 11, weight: .bold)
                .foregroundStyle(accent)
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(testRunner.activityLog.enumerated()), id: \.offset) { _, entry in
                        HStack(spacing: 6) {
                            Image(systemName: entry.icon)
                                .orbFont(size: 11)
                                .foregroundStyle(accent.opacity(0.7))
                            Text(entry.text)
                                .orbFont(size: 11, design: .monospaced)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 200)
            .padding(10)
            .background(.orbSurface(0.03))
            .clipShape(RoundedRectangle(cornerRadius: controlRadius))
        }
    }

    // MARK: - Test Result View

    private func testResultView(_ scenario: TestScenario, _ result: TestRunResult) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: result.errorMessage == TestRunner.unverifiedMessage ? "questionmark.circle.fill" :
                      result.success ? "checkmark.seal.fill" : "xmark.seal.fill")
                    .orbFont(size: 14)
                    .foregroundStyle(result.errorMessage == TestRunner.unverifiedMessage ? .orange :
                                     result.success ? .green : .red)
                Text(TestVerdictKind.headline(result))
                    .orbFont(size: 13, weight: .semibold)
                Spacer()
            }

            // Metrics row
            HStack(spacing: 14) {
                Label("\(result.promptTokens + result.completionTokens) tokens", systemImage: "text.word.spacing")
                Label(TestResultsTable.latencyText(result.latencyMs), systemImage: "clock")
                    .help(TestResultsTable.latencyHelp(result))
                if let ttft = result.ttftMs {
                    Label("TTFT " + TestResultsTable.ttftText(ttft), systemImage: "bolt")
                }
                if result.tokensPerSec != nil {
                    Label(TestResultsTable.throughputText(result.tokensPerSec), systemImage: "speedometer")
                }
                Label(testRunner.formattedCost(result.cost), systemImage: "dollarsign.circle")
            }
            .orbFont(size: 11, weight: .medium, design: .monospaced)
            .foregroundStyle(.secondary)

            if let error = result.errorMessage {
                let needsReview = error == TestRunner.unverifiedMessage
                Text(error)
                    .orbFont(size: 11)
                    .foregroundStyle(needsReview ? .orange : .red)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background((needsReview ? Color.orange : Color.red).opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: controlRadius))
            }

            // Project directory actions
            if let projectPath = result.outputPath {
                projectActionsView(projectPath, result: result)
            }

            // Agent summary
            if !result.response.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(result.outputPath == nil ? "TEXT RESPONSE" : "AGENT SUMMARY")
                        .orbFont(size: 11, weight: .bold)
                        .foregroundStyle(.secondary)
                    MarkdownText(content: result.response, accent: accent)
                        .textSelection(.enabled)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.orbSurface(0.03))
                        .overlay {
                            RoundedRectangle(cornerRadius: cardRadius)
                                .stroke(.orbSurface(0.06), lineWidth: 1)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: cardRadius))
                }
            }
        }
        .frame(maxWidth: 820, alignment: .leading)
    }

    private func projectActionsView(_ projectPath: String, result: TestRunResult) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("PROJECT OUTPUT")
                .orbFont(size: 11, weight: .bold)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                // Project path display
                HStack(spacing: 6) {
                    Image(systemName: "folder.fill")
                        .foregroundStyle(accent)
                    Text(projectPath.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                        .orbFont(size: 11, design: .monospaced)
                        .lineLimit(1)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(.orbSurface(0.04))
                .clipShape(RoundedRectangle(cornerRadius: controlRadius))

                Spacer()

                // Open folder
                Button {
                    NSWorkspace.shared.openFolder(atPath: projectPath)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "folder.open.fill")
                        Text("Open Folder")
                    }
                    .orbFont(size: 11, weight: .semibold)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(accent.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: controlRadius))
                }
                .buttonStyle(.plain)

                // Open in Finder
                Button {
                    NSWorkspace.shared.selectFile(nil, inDirectory: projectPath)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "macfinder")
                        Text("Reveal")
                    }
                    .orbFont(size: 11, weight: .semibold)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(.orbSurface(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: controlRadius))
                }
                .buttonStyle(.plain)
            }

            // Detect and show HTML files with "Open in Browser"
            htmlFileButtons(projectPath)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(accent.opacity(0.04))
        .overlay {
            RoundedRectangle(cornerRadius: cardRadius)
                .stroke(accent.opacity(0.15), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: cardRadius))
    }

    private func htmlFileButtons(_ projectPath: String) -> some View {
        ProjectHTMLButtons(projectPath: projectPath, accent: accent, controlRadius: controlRadius)
    }

    // MARK: - Results actions

    private var rerunTitle: String {
        let n = TestRerunPlanner.modelCount(pendingRerun)
        let scenarios = Set(pendingRerun.map(\.scenarioID)).count
        return "Rerun \(n) model run\(n == 1 ? "" : "s") across \(scenarios) scenario\(scenarios == 1 ? "" : "s")?"
    }

    /// Resolves scenarios (built-in or custom); missing ones are reported.
    private func scenario(id: String) -> TestScenario? {
        TestScenarioResolver.resolve(id: id, custom: customTests)
    }

    private func confirmRerun(_ batches: [TestRerunBatch]) {
        guard !testRunner.isRunning else { return }
        guard TestSpendCeilingParser.parse(batchCeiling) != nil else {
            resultsNotice = "Set a positive spend ceiling in Compare models before rerunning."
            return
        }
        pendingRerun = batches
        showRerunConfirmation = true
    }

    private func startPendingRerun() {
        let batches = pendingRerun
        pendingRerun = []
        var plan: [(scenario: TestScenario, modelIDs: [String])] = []
        var missing = 0
        for batch in batches {
            if let s = scenario(id: batch.scenarioID) { plan.append((s, batch.modelIDs)) } else { missing += 1 }
        }
        if missing > 0 { resultsNotice = "\(missing) scenario\(missing == 1 ? " no longer exists" : "s no longer exist") and will be skipped." }
        guard !plan.isEmpty, let ceiling = TestSpendCeilingParser.parse(batchCeiling) else { return }
        testRunner.start(plan: plan, models: viewModel.api.models, ceilingUSD: ceiling)
    }

    private func exportResultsCSV(includeResponses: Bool = false) {
        let rows = testRunner.showsAllResults ? testRunner.results : DatabaseManager.shared.loadAllTestResults()
        save(text: TestResultsCSV.encode(rows, includeResponses: includeResponses),
             name: includeResponses ? "orb-test-results-with-responses.csv" : "orb-test-results.csv")
    }

    private func exportExperimentJSON() {
        do {
            let json = try ExperimentExport.encodeJSON(records: DatabaseManager.shared.loadExperimentRunRecords())
            save(text: json, name: "orb-experiment-runs.json")
        } catch {
            resultsNotice = "Export failed: \(error.localizedDescription)"
        }
    }

    private func save(text: String, name: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try Data(text.utf8).write(to: url, options: .atomic) }
        catch { resultsNotice = "Export failed: \(error.localizedDescription)" }
    }

    // MARK: - Actions

    /// A tool-capable favourite, then the browser selection when Test Suite
    /// can run it (text models run as direct text probes), then the catalog's
    /// preferred tool-capable model. Never a stale hard-coded id.
    private var preferredModelId: String {
        let models = viewModel.api.models
        let toolFavorite = models.first { viewModel.favoriteIds.contains($0.id) && CatalogModelPreference.Candidate($0).satisfies(.toolCalling) }
        if let toolFavorite { return toolFavorite.id }
        if let selected = viewModel.selectedModel, CatalogModelPreference.Candidate(selected).satisfies(.textChat),
           models.contains(where: { $0.id == selected.id }) {
            return selected.id
        }
        let tool = PlaygroundModelDefaults.agentFallback(
            models: models, favoriteIds: viewModel.favoriteIds, selectedModelId: nil,
            recentIds: ModelRecentsStore().recentIds()
        )
        if !tool.isEmpty { return tool }
        return PlaygroundModelDefaults.chatFallback(models: models, favoriteIds: viewModel.favoriteIds, selectedModelId: nil)
    }

    private var currentModelId: String {
        selectedModelId.isEmpty ? preferredModelId : selectedModelId
    }

    private func runScenario(_ scenario: TestScenario) {
        Task {
            await testRunner.run(
                scenario: scenario,
                modelId: currentModelId,
                models: viewModel.api.models,
                userInput: userInstructions
            )
        }
    }

}
