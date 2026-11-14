import AppKit
import SwiftUI

// Split out of TestSuiteView.swift for readability.

// MARK: - Create Custom Test View

/// Editable form state for a custom test. Pure so mode switching,
/// expectation handling and validation are unit-testable (TESTS-10).
struct CustomTestDraft: Equatable {
    var title = ""
    var subtitle = ""
    var userPrompt = ""
    var mode: TestEvaluationMode = .textResponse
    var systemPrompt = CustomTest.defaultSystemPrompt(for: .textResponse)
    var notes = ""
    var category: TestCategory = .webDevelopment
    var icon = "hammer"
    var expectationKind: CustomTestExpectation.Kind = .contains
    var expectationValue = ""

    init() {}

    init(_ test: CustomTest) {
        title = test.title
        subtitle = test.subtitle
        userPrompt = test.userPrompt
        mode = test.mode
        systemPrompt = test.systemPrompt
        notes = test.notes
        category = test.category
        icon = test.icon
        expectationKind = test.expectation?.kind ?? .contains
        expectationValue = test.expectation?.value ?? ""
    }

    /// Switching mode swaps the system prompt only while it is still the
    /// previous mode's default, so a user's own prompt is never overwritten.
    mutating func setMode(_ newMode: TestEvaluationMode) {
        guard newMode != mode else { return }
        if systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines) == CustomTest.defaultSystemPrompt(for: mode)
            || systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            systemPrompt = CustomTest.defaultSystemPrompt(for: newMode)
        }
        mode = newMode
    }

    var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !userPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func makeTest(id: String = UUID().uuidString, createdAt: Date = Date()) -> CustomTest {
        let system = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return CustomTest(
            id: id,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            subtitle: subtitle.trimmingCharacters(in: .whitespacesAndNewlines),
            icon: icon,
            category: category,
            systemPrompt: system.isEmpty ? CustomTest.defaultSystemPrompt(for: mode) : system,
            userPrompt: userPrompt.trimmingCharacters(in: .whitespacesAndNewlines),
            notes: CustomTest.criteria(from: notes).joined(separator: "\n"),
            createdAt: createdAt,
            mode: mode,
            expectation: CustomTestExpectation.make(kind: expectationKind, value: expectationValue)
        )
    }
}

struct CreateTestView: View {
    let accent: Color
    /// Non-nil when editing: the saved test keeps its id and creation date.
    var existing: CustomTest? = nil
    let onSave: (CustomTest) -> Void

    @State private var draft = CustomTestDraft()
    @State private var loadedExisting = false
    @Environment(\.dismiss) private var dismiss

    private let icons = ["hammer", "safari", "gamecontroller", "macwindow", "network", "cylinder", "building.2", "brain", "chart.bar", "cloud", "shield.lefthalf.filled", "wrench.and.screwdriver", "lightbulb", "star"]

    private var modeBinding: Binding<TestEvaluationMode> {
        Binding(get: { draft.mode }, set: { draft.setMode($0) })
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(accent.opacity(0.12))
                    Image(systemName: "plus.app.fill")
                        .orbFont(size: 14, weight: .bold)
                        .foregroundStyle(accent)
                }
                .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text(existing == nil ? "Create Custom Test" : "Edit Custom Test")
                        .orbFont(size: 15, weight: .semibold)
                    Text(draft.mode == .textResponse
                         ? "Each model gets one streamed answer — no tools, no approvals"
                         : "Tool-capable models build a real project in their own folder; text-only models answer in text")
                        .orbFont(size: 11)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(16)

            Divider()

            // Form
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Mode
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Test Type")
                            .orbFont(size: 11, weight: .semibold)
                        Picker("Test Type", selection: modeBinding) {
                            Text("Text response").tag(TestEvaluationMode.textResponse)
                            Text("Project build").tag(TestEvaluationMode.projectBuild)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }

                    // Title
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Title")
                            .orbFont(size: 11, weight: .semibold)
                        TextField("e.g. Build a REST API with Express", text: $draft.title)
                            .textFieldStyle(.roundedBorder)
                    }

                    // Subtitle
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Subtitle")
                            .orbFont(size: 11, weight: .semibold)
                        TextField("Short description shown on the card", text: $draft.subtitle)
                            .textFieldStyle(.roundedBorder)
                    }

                    // Category
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Category")
                            .orbFont(size: 11, weight: .semibold)
                        Picker("Category", selection: $draft.category) {
                            ForEach(TestCategory.allCases) { cat in
                                Label(cat.rawValue, systemImage: cat.icon).tag(cat)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                    }

                    // Icon
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Icon")
                            .orbFont(size: 11, weight: .semibold)
                        LazyVGrid(columns: Array(repeating: GridItem(.fixed(36)), count: 7), spacing: 8) {
                            ForEach(icons, id: \.self) { iconName in
                                Button {
                                    draft.icon = iconName
                                } label: {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 8)
                                            .fill(draft.icon == iconName ? accent.opacity(0.18) : Color.primary.opacity(0.04))
                                        Image(systemName: iconName)
                                            .orbFont(size: 13)
                                            .foregroundStyle(draft.icon == iconName ? accent : .secondary)
                                    }
                                    .frame(width: 36, height: 36)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Icon: \(iconName)")
                                .accessibilityAddTraits(draft.icon == iconName ? .isSelected : [])
                            }
                        }
                    }

                    // Prompt
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Task Prompt")
                            .orbFont(size: 11, weight: .semibold)
                        Text(draft.mode == .textResponse
                             ? "Ask for exactly the answer you want to compare across models."
                             : "Describe what the AI should build. It writes files in its own project folder; commands need your approval.")
                            .orbFont(size: 11)
                            .foregroundStyle(.secondary)
                        TextEditor(text: $draft.userPrompt)
                            .orbFont(size: 12)
                            .frame(minHeight: 80)
                            .padding(4)
                            .background(.orbSurface(0.04))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }

                    // System prompt
                    DisclosureGroup("Custom System Prompt") {
                        TextEditor(text: $draft.systemPrompt)
                            .orbFont(size: 11)
                            .frame(minHeight: 60)
                            .padding(4)
                            .background(.orbSurface(0.04))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .orbFont(size: 11, weight: .medium)

                    // Expected output
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Expected Output")
                            .orbFont(size: 11, weight: .semibold)
                        Text("Optional — checked automatically against the response. Leave blank to review answers yourself.")
                            .orbFont(size: 11)
                            .foregroundStyle(.secondary)
                        HStack {
                            Picker("Check", selection: $draft.expectationKind) {
                                ForEach(CustomTestExpectation.Kind.allCases) { Text($0.title).tag($0) }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                            .fixedSize()
                            TextField(draft.expectationKind == .exactJSON ? #"{"answer": 42}"# : "Expected text or pattern",
                                      text: $draft.expectationValue)
                                .textFieldStyle(.roundedBorder)
                        }
                    }

                    // Notes / evaluation criteria
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Evaluation Criteria (one per line)")
                            .orbFont(size: 11, weight: .semibold)
                        Text("Optional — shown as review items in the test detail; blank lines are ignored.")
                            .orbFont(size: 11)
                            .foregroundStyle(.secondary)
                        TextEditor(text: $draft.notes)
                            .orbFont(size: 11)
                            .frame(minHeight: 50)
                            .padding(4)
                            .background(.orbSurface(0.04))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
                .padding(16)
            }

            Divider()

            // Buttons
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.plain)
                Button(existing == nil ? "Create Test" : "Save Changes") {
                    let test = existing.map { draft.makeTest(id: $0.id, createdAt: $0.createdAt) } ?? draft.makeTest()
                    onSave(test)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(accent)
                .disabled(!draft.canSave)
            }
            .padding(12)
        }
        .frame(width: 540, height: 620)
        .onAppear {
            guard !loadedExisting else { return }
            loadedExisting = true
            if let existing { draft = CustomTestDraft(existing) }
        }
    }
}

