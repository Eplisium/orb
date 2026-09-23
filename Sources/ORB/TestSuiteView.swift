import AppKit
import SwiftUI

/// A professional test suite for evaluating AI models across real-world
/// development tasks. Each test runs through the agent function-calling loop,
/// so the AI actually creates files, runs commands, and builds a working
/// project in its own directory — not just a wall of text. Runs accept
/// optional user input layered on top of the scenario prompt.
struct TestSuiteView: View {
    @ObservedObject var viewModel: BrowserViewModel
    @StateObject private var testRunner = TestRunner()

    @State private var selectedCategory: TestCategory?
    @State private var selectedScenario: TestScenario?
    @State private var selectedModelId = ""
    @State private var showModelPicker = false
    @State private var modelSearchText = ""
    @State private var showCreateTest = false
    @State private var customTests: [CustomTest] = []
    @State private var showSavedResults = false
    @State private var userInstructions = ""

    private let accent = PlaygroundTheme.testAccent

    // MARK: - Design tokens (shared vocabulary: cards 10, controls 8)

    private let cardRadius: CGFloat = 10
    private let controlRadius: CGFloat = 8

    var body: some View {
        HStack(spacing: 0) {
            categorySidebar
            Rectangle()
                .fill(Color.primary.opacity(0.07))
                .frame(width: 1)
            mainArea
        }
        .background(testBackground)
        .task {
            if selectedModelId.isEmpty { selectedModelId = preferredModelId }
            viewModel.loadFavorites()
            customTests = DatabaseManager.shared.loadCustomTests()
            testRunner.loadSavedResults()
        }
        .onChange(of: selectedScenario?.id) { _, _ in
            // Input is scoped to the run the user is looking at.
            userInstructions = ""
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
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 1) {
                Text("Test Suite")
                    .font(.system(size: 14, weight: .semibold))
                Text("Builds real projects")
                    .font(.system(size: 11, weight: .medium))
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
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.tertiary)
        }
        .font(.system(size: 11, weight: .semibold))
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.primary.opacity(0.05))
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
                toolCapableOnly: $testRunner.toolCapableOnly,
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
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(accent)
                        Text("CATEGORIES")
                            .font(.system(size: 10, weight: .bold))
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
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(accent)
                Text("CUSTOM TESTS")
                    .font(.system(size: 10, weight: .bold))
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
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isSelected ? accent : .secondary)
            Text(test.title)
                .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
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
            Button("Delete", role: .destructive) {
                DatabaseManager.shared.deleteCustomTest(test.id)
                customTests = DatabaseManager.shared.loadCustomTests()
                if selectedScenario?.id == "custom-\(test.id)" {
                    selectedScenario = nil
                }
            }
        }
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
            ? TestCatalog.allScenarios.count
            : TestCatalog.scenarios(in: category!).count

        return Button {
            selectedCategory = category
            selectedScenario = nil
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isSelected ? accent : .secondary)
                Text(title)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text("\(count)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
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
                .fill(Color.primary.opacity(0.07))
                .frame(height: 1)

            HStack(spacing: 7) {
                Circle()
                    .fill(runnerStatusColor)
                    .frame(width: 7, height: 7)
                    .shadow(color: runnerStatusColor.opacity(0.6), radius: 3)
                Text(runnerStatusText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
            }

            if !testRunner.results.isEmpty {
                HStack {
                    Label("\(testRunner.results.count)", systemImage: "checkmark.circle")
                    Spacer()
                    Text(testRunner.formattedTotalCost)
                }
                .font(.system(size: 10, weight: .medium, design: .monospaced))
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
        if !testRunner.results.isEmpty { return "\(testRunner.results.count) tests completed" }
        return KeychainManager.hasAPIKey ? "Ready to test" : "API key needed"
    }

    // MARK: - Main Area

    private var mainArea: some View {
        VStack(spacing: 0) {
            testHeader
            Rectangle()
                .fill(Color.primary.opacity(0.07))
                .frame(height: 1)

            if let scenario = selectedScenario {
                scenarioDetail(scenario)
            } else {
                scenarioGrid
            }
        }
    }

    private var testHeader: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(selectedCategory?.rawValue ?? "All Tests")
                    .font(.system(size: 16, weight: .semibold))
                if let cat = selectedCategory {
                    Text(cat.description)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text("\(TestCatalog.allScenarios.count) professional tests — each builds a real project in its own directory")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 16)

            if !customTests.isEmpty || selectedCategory != nil {
                Button {
                    showCreateTest = true
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "plus")
                        Text("New Test")
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(accent.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: controlRadius))
                }
                .buttonStyle(.plain)
                .help("Create a custom test with your own prompt")
            }

            if let cat = selectedCategory {
                Button {
                    runAllInCategory(cat)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "play.fill")
                        Text("Run All")
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(testRunner.isRunning ? Color.gray : accent)
                    .clipShape(RoundedRectangle(cornerRadius: controlRadius))
                }
                .buttonStyle(.plain)
                .disabled(testRunner.isRunning || !KeychainManager.hasAPIKey)
                .help("Run every test in this category")
            }
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
                }

                // Scenario cards
                VStack(alignment: .leading, spacing: 12) {
                    Text("AVAILABLE TESTS")
                        .font(.system(size: 10, weight: .bold))
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
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    DatabaseManager.shared.clearTestResults()
                    testRunner.clearResults()
                } label: {
                    Text("Clear All")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
            }

            ForEach(testRunner.results.prefix(8)) { result in
                savedResultRow(result)
            }
        }
        .frame(maxWidth: 880, alignment: .leading)
    }

    private func savedResultRow(_ result: TestRunResult) -> some View {
        Button {
            if let scenario = TestCatalog.scenario(id: result.scenarioId) {
                selectedScenario = scenario
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: result.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(result.success ? .green : .red)

                VStack(alignment: .leading, spacing: 2) {
                    Text(result.scenarioTitle)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(shortModelName(result.modelId))
                        Text("•")
                        Text("\(result.totalTokens) tokens")
                        Text("•")
                        Text("\(result.latencyMs)ms")
                        if result.outputPath != nil {
                            Text("•")
                            Label("Project", systemImage: "folder.fill")
                        }
                    }
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tertiary)
                }
                Spacer()
                Text(testRunner.formattedCost(result.cost))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Color.primary.opacity(0.025))
            .clipShape(RoundedRectangle(cornerRadius: controlRadius))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let path = result.outputPath {
                Button("Open Project Folder") {
                    NSWorkspace.shared.openFolder(atPath: path)
                }
                Button("Open in Finder") {
                    NSWorkspace.shared.selectFile(nil, inDirectory: path)
                }
            }
            Button("Delete Result", role: .destructive) {
                DatabaseManager.shared.deleteTestResult(result.id)
                testRunner.loadSavedResults()
            }
        }
    }

    private var filteredScenarios: [TestScenario] {
        if let category = selectedCategory {
            return TestCatalog.scenarios(in: category).sorted { $0.difficulty.sortOrder < $1.difficulty.sortOrder }
        }
        return TestCatalog.allScenarios.sorted { $0.difficulty.sortOrder < $1.difficulty.sortOrder }
    }

    private func scenarioCard(_ scenario: TestScenario) -> some View {
        let result = testRunner.results.first { $0.scenarioId == scenario.id }

        return Button {
            selectedScenario = scenario
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(accent.opacity(0.10))
                        Image(systemName: scenario.icon)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(accent)
                    }
                    .frame(width: 34, height: 34)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(scenario.title)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        Text(scenario.category.rawValue)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()

                    if let result {
                        resultBadge(result)
                    }
                }

                Text(scenario.subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 8) {
                    difficultyTag(scenario.difficulty)
                    Label("\(scenario.estimatedSeconds)s", systemImage: "clock")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                    if result?.outputPath != nil {
                        Label("Built", systemImage: "folder.badge.checkmark")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.green)
                    }
                    Spacer()
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.032))
            .overlay {
                RoundedRectangle(cornerRadius: cardRadius)
                    .stroke(Color.primary.opacity(0.06), lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: cardRadius))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(testRunner.isRunning)
    }

    private func resultBadge(_ result: TestRunResult) -> some View {
        HStack(spacing: 3) {
            Image(systemName: result.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 10))
            Text(result.success ? "Pass" : "Fail")
                .font(.system(size: 10, weight: .bold))
        }
        .foregroundStyle(result.success ? Color.green : Color.red)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background((result.success ? Color.green : Color.red).opacity(0.10))
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
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.10))
            .clipShape(Capsule())
    }

    // MARK: - Scenario Detail

    private func scenarioDetail(_ scenario: TestScenario) -> some View {
        let result = testRunner.results.first { $0.scenarioId == scenario.id }
        let isThisRunning = testRunner.isRunning && testRunner.runningScenarioId == scenario.id

        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                HStack(spacing: 12) {
                    Button {
                        selectedScenario = nil
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .help("Back to all tests")

                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(accent.opacity(0.10))
                        Image(systemName: scenario.icon)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(accent)
                    }
                    .frame(width: 42, height: 42)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(scenario.title)
                            .font(.system(size: 18, weight: .semibold))
                        Text(scenario.subtitle)
                            .font(.system(size: 12))
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
                    Label("\(scenario.evaluationCriteria.count) criteria", systemImage: "checklist")
                    Spacer()
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(maxWidth: 820)

                // Evaluation Criteria
                VStack(alignment: .leading, spacing: 8) {
                    Text("EVALUATION CRITERIA")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                    ForEach(scenario.evaluationCriteria, id: \.self) { criterion in
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle")
                                .font(.system(size: 11))
                                .foregroundStyle(accent)
                            Text(criterion)
                                .font(.system(size: 12))
                        }
                    }
                }
                .frame(maxWidth: 820, alignment: .leading)

                userInputSection(isRunning: isThisRunning)

                Divider().frame(maxWidth: 820)

                // Run button
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
                        }
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        .background(isThisRunning ? Color.gray : accent)
                        .clipShape(RoundedRectangle(cornerRadius: controlRadius))
                    }
                    .buttonStyle(.plain)
                    .disabled(testRunner.isRunning || !KeychainManager.hasAPIKey)

                    if !KeychainManager.hasAPIKey {
                        Text("Add your OpenRouter API key in Account to run tests.")
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                    }

                    Spacer()
                }
                .frame(maxWidth: 820)

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
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.03))
                        .clipShape(RoundedRectangle(cornerRadius: controlRadius))
                }
                .font(.system(size: 11, weight: .medium))
                .frame(maxWidth: 820, alignment: .leading)

                DisclosureGroup("User Prompt") {
                    Text(scenario.userPrompt)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.03))
                        .clipShape(RoundedRectangle(cornerRadius: controlRadius))
                }
                .font(.system(size: 11, weight: .medium))
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
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                Text("OPTIONAL")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.05))
                    .clipShape(Capsule())
                Spacer()
                if !userInstructions.isEmpty {
                    Button {
                        userInstructions = ""
                    } label: {
                        Text("Clear")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(isRunning)
                }
            }

            Text("Add a note, constraint, or extra instruction for this run. It is appended to the task prompt below.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            ZStack(alignment: .topLeading) {
                if userInstructions.isEmpty {
                    Text("e.g. Use a dark theme, keep the project under 200 lines…")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 14)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $userInstructions)
                    .font(.system(size: 12))
                    .frame(minHeight: 72)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .disabled(isRunning)
            }
            .background(Color.primary.opacity(0.04))
            .overlay {
                RoundedRectangle(cornerRadius: controlRadius)
                    .stroke(Color.primary.opacity(0.06), lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: controlRadius))
        }
        .frame(maxWidth: 820, alignment: .leading)
    }

    // MARK: - Activity Log

    private var activityLogView: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("AGENT ACTIVITY")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(accent)
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(testRunner.activityLog.enumerated()), id: \.offset) { _, entry in
                        HStack(spacing: 6) {
                            Image(systemName: entry.icon)
                                .font(.system(size: 10))
                                .foregroundStyle(accent.opacity(0.7))
                            Text(entry.text)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 200)
            .padding(10)
            .background(Color.primary.opacity(0.03))
            .clipShape(RoundedRectangle(cornerRadius: controlRadius))
        }
    }

    // MARK: - Test Result View

    private func testResultView(_ scenario: TestScenario, _ result: TestRunResult) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: result.success ? "checkmark.seal.fill" : "xmark.seal.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(result.success ? .green : .red)
                Text(result.success ? "Test Passed" : "Test Failed")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
            }

            // Metrics row
            HStack(spacing: 14) {
                Label("\(result.promptTokens + result.completionTokens) tokens", systemImage: "text.word.spacing")
                Label("\(result.latencyMs)ms", systemImage: "clock")
                Label(testRunner.formattedCost(result.cost), systemImage: "dollarsign.circle")
            }
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(.secondary)

            if let error = result.errorMessage {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: controlRadius))
            }

            // Project directory actions
            if let projectPath = result.outputPath {
                projectActionsView(projectPath, result: result)
            }

            // Agent summary
            if !result.response.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("AGENT SUMMARY")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                    Text(result.response)
                        .font(.system(size: 13))
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.03))
                        .overlay {
                            RoundedRectangle(cornerRadius: cardRadius)
                                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
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
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                // Project path display
                HStack(spacing: 6) {
                    Image(systemName: "folder.fill")
                        .foregroundStyle(accent)
                    Text(projectPath.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(1)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color.primary.opacity(0.04))
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
                    .font(.system(size: 11, weight: .semibold))
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
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Color.primary.opacity(0.06))
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
        let htmlFiles = findHTMLFiles(in: projectPath)

        return Group {
            if !htmlFiles.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("OPEN IN BROWSER")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)

                    ForEach(htmlFiles, id: \.self) { file in
                        Button {
                            NSWorkspace.shared.open(URL(fileURLWithPath: file))
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "safari.fill")
                                Text(URL(fileURLWithPath: file).lastPathComponent)
                                    .lineLimit(1)
                            }
                            .font(.system(size: 11, weight: .medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(accent.opacity(0.10))
                            .clipShape(RoundedRectangle(cornerRadius: controlRadius))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func findHTMLFiles(in dir: String) -> [String] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: dir) else { return [] }
        var htmls: [String] = []
        for case let file as String in enumerator {
            if file.hasSuffix(".html") || file.hasSuffix(".htm") {
                htmls.append((dir as NSString).appendingPathComponent(file))
            }
        }
        return htmls.sorted()
    }

    // MARK: - Actions

    private var preferredModelId: String {
        if let favorite = viewModel.api.models.first(where: { viewModel.favoriteIds.contains($0.id) && $0.supportsTools })?.id {
            return favorite
        }
        if let selected = viewModel.selectedModel?.id { return selected }
        if let toolModel = viewModel.api.models.first(where: \.supportsTools)?.id { return toolModel }
        return "openai/gpt-4o"
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

    private func runAllInCategory(_ category: TestCategory) {
        let scenarios = TestCatalog.scenarios(in: category)
        Task {
            for scenario in scenarios {
                await testRunner.run(
                    scenario: scenario,
                    modelId: currentModelId,
                    models: viewModel.api.models
                )
            }
        }
    }
}
