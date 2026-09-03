import AppKit
import SwiftUI

// Split out of TestSuiteView.swift for readability.

// MARK: - Create Custom Test View

struct CreateTestView: View {
    let accent: Color
    let onSave: (CustomTest) -> Void

    @State private var title = ""
    @State private var subtitle = ""
    @State private var userPrompt = ""
    @State private var systemPrompt = "You are an expert developer. Create a complete, working project with all necessary files. Write each file using the write_file function. After creating all files, verify the project works by listing the directory."
    @State private var notes = ""
    @State private var category: TestCategory = .webDevelopment
    @State private var icon = "hammer"
    @Environment(\.dismiss) private var dismiss

    private let icons = ["hammer", "safari", "gamecontroller", "macwindow", "network", "cylinder", "building.2", "brain", "chart.bar", "cloud", "shield.lefthalf.filled", "wrench.and.screwdriver", "lightbulb", "star"]

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(accent.opacity(0.12))
                    Image(systemName: "plus.app.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(accent)
                }
                .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Create Custom Test")
                        .font(.system(size: 15, weight: .semibold))
                    Text("The AI agent will build a real project in its own directory")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(16)

            Divider()

            // Form
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Title
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Title")
                            .font(.system(size: 11, weight: .semibold))
                        TextField("e.g. Build a REST API with Express", text: $title)
                            .textFieldStyle(.roundedBorder)
                    }

                    // Subtitle
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Subtitle")
                            .font(.system(size: 11, weight: .semibold))
                        TextField("Short description shown on the card", text: $subtitle)
                            .textFieldStyle(.roundedBorder)
                    }

                    // Category
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Category")
                            .font(.system(size: 11, weight: .semibold))
                        Picker("Category", selection: $category) {
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
                            .font(.system(size: 11, weight: .semibold))
                        LazyVGrid(columns: Array(repeating: GridItem(.fixed(36)), count: 7), spacing: 8) {
                            ForEach(icons, id: \.self) { iconName in
                                Button {
                                    icon = iconName
                                } label: {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 8)
                                            .fill(icon == iconName ? accent.opacity(0.18) : Color.primary.opacity(0.04))
                                        Image(systemName: iconName)
                                            .font(.system(size: 13))
                                            .foregroundStyle(icon == iconName ? accent : .secondary)
                                    }
                                    .frame(width: 36, height: 36)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    // Prompt
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Task Prompt")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Describe what the AI should build. It will create files and run commands in its own project directory.")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                        TextEditor(text: $userPrompt)
                            .font(.system(size: 12))
                            .frame(minHeight: 80)
                            .padding(4)
                            .background(Color.primary.opacity(0.04))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }

                    // System prompt
                    DisclosureGroup("Custom System Prompt") {
                        TextEditor(text: $systemPrompt)
                            .font(.system(size: 11))
                            .frame(minHeight: 60)
                            .padding(4)
                            .background(Color.primary.opacity(0.04))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .font(.system(size: 11, weight: .medium))

                    // Notes / evaluation criteria
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Evaluation Criteria (one per line)")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Optional — shown as checklist items in the test detail.")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                        TextEditor(text: $notes)
                            .font(.system(size: 11))
                            .frame(minHeight: 50)
                            .padding(4)
                            .background(Color.primary.opacity(0.04))
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
                Button("Create Test") {
                    let test = CustomTest(
                        title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                        subtitle: subtitle.trimmingCharacters(in: .whitespacesAndNewlines),
                        icon: icon,
                        category: category,
                        systemPrompt: systemPrompt,
                        userPrompt: userPrompt.trimmingCharacters(in: .whitespacesAndNewlines),
                        notes: notes
                    )
                    onSave(test)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(accent)
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || userPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(12)
        }
        .frame(width: 540, height: 620)
    }
}

