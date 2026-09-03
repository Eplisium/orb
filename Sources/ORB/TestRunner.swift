import AppKit
import Foundation
import SwiftUI

// Split out of TestSuiteView.swift for readability.

// MARK: - Test Runner

@MainActor
final class TestRunner: ObservableObject {
    @Published var results: [TestRunResult] = []
    @Published var isRunning = false
    @Published var runningScenarioId: String?
    @Published var activityLabel = ""
    @Published var activityLog: [ActivityEntry] = []
    @Published var toolCapableOnly = true

    struct ActivityEntry: Identifiable {
        let id = UUID()
        let text: String
        let icon: String
    }

    /// Directory where all test projects are stored.
    private var testOutputRoot: URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser
        let dir = base.appendingPathComponent("ORB/TestProjects", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    func loadSavedResults() {
        results = DatabaseManager.shared.loadTestResults()
    }

    func clearResults() {
        results.removeAll()
    }

    func run(scenario: TestScenario, modelId: String, models: [ModelInfo]) async {
        guard let apiKey = KeychainManager.getAPIKey(), !apiKey.isEmpty else {
            let result = TestRunResult(
                scenarioId: scenario.id,
                scenarioTitle: scenario.title,
                category: scenario.category,
                modelId: modelId,
                response: "",
                promptTokens: 0,
                completionTokens: 0,
                totalTokens: 0,
                cost: 0,
                latencyMs: 0,
                success: false,
                errorMessage: "No API key configured. Add one in Account."
            )
            results.insert(result, at: 0)
            DatabaseManager.shared.saveTestResult(result)
            return
        }

        // Create a dedicated directory for this test run
        let safeName = scenario.id.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let projectDir = testOutputRoot.appendingPathComponent("\(safeName)-\(Int(Date().timeIntervalSince1970))")
        try? FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        isRunning = true
        runningScenarioId = scenario.id
        activityLabel = "Starting agent…"
        activityLog.removeAll()

        let startTime = Date()

        // Build an agent-style system prompt that tells the AI to create files
        // in the project directory.
        let agentSystemPrompt = """
        \(scenario.systemPrompt)

        You are running inside the ORB Test Suite. Your task is to create a complete, working project in the directory provided below. You MUST:

        1. Use the write_file function to create every file the project needs.
        2. Use list_directory to verify your files were created.
        3. Use run_command to build, test, or verify the project if applicable.
        4. For web projects, create an index.html that can be opened directly in a browser.
        5. Keep all files within the project directory.

        Project directory: \(projectDir.path)
        Workspace: \(projectDir.path)

        After completing the project, write a brief summary of what you built, the file structure, and how to run or open it.
        """

        do {
            let result = try await NativeAgentRunner.run(
                prompt: scenario.userPrompt,
                modelId: modelId,
                apiKey: apiKey,
                workspace: projectDir.path,
                fullComputerAccess: true,
                history: [],
                systemPromptOverride: agentSystemPrompt,
                onActivity: { [weak self] label in
                    guard let self else { return }
                    self.activityLabel = label
                    self.activityLog.append(ActivityEntry(text: label, icon: "gearshape"))
                }
            )

            let elapsed = Int(Date().timeIntervalSince(startTime) * 1000)

            let testResult = TestRunResult(
                scenarioId: scenario.id,
                scenarioTitle: scenario.title,
                category: scenario.category,
                modelId: modelId,
                response: result.response,
                promptTokens: result.usage?.promptTokens ?? 0,
                completionTokens: result.usage?.completionTokens ?? 0,
                totalTokens: result.usage?.totalTokens ?? 0,
                cost: result.usage?.cost ?? 0,
                latencyMs: elapsed,
                success: !result.response.isEmpty,
                errorMessage: result.response.isEmpty ? "Agent returned empty response" : nil,
                outputPath: projectDir.path
            )
            results.insert(testResult, at: 0)
            DatabaseManager.shared.saveTestResult(testResult)

            // Log tool usage
            for toolName in result.toolNames {
                activityLog.append(ActivityEntry(text: "Used tool: \(toolName)", icon: toolIcon(toolName)))
            }

        } catch is CancellationError {
            let elapsed = Int(Date().timeIntervalSince(startTime) * 1000)
            let testResult = TestRunResult(
                scenarioId: scenario.id,
                scenarioTitle: scenario.title,
                category: scenario.category,
                modelId: modelId,
                response: "Test was cancelled.",
                promptTokens: 0,
                completionTokens: 0,
                totalTokens: 0,
                cost: 0,
                latencyMs: elapsed,
                success: false,
                errorMessage: "Cancelled by user",
                outputPath: projectDir.path
            )
            results.insert(testResult, at: 0)
            DatabaseManager.shared.saveTestResult(testResult)
        } catch {
            let elapsed = Int(Date().timeIntervalSince(startTime) * 1000)
            let testResult = TestRunResult(
                scenarioId: scenario.id,
                scenarioTitle: scenario.title,
                category: scenario.category,
                modelId: modelId,
                response: "",
                promptTokens: 0,
                completionTokens: 0,
                totalTokens: 0,
                cost: 0,
                latencyMs: elapsed,
                success: false,
                errorMessage: error.localizedDescription,
                outputPath: projectDir.path
            )
            results.insert(testResult, at: 0)
            DatabaseManager.shared.saveTestResult(testResult)
        }

        isRunning = false
        runningScenarioId = nil
        activityLabel = ""
    }

    private func toolIcon(_ name: String) -> String {
        switch name {
        case "write_file": return "doc.text"
        case "read_file": return "book"
        case "list_directory": return "folder"
        case "search_files": return "magnifyingglass"
        case "run_command": return "terminal"
        case "fetch_url": return "globe"
        case "run_applescript": return "app"
        case "open_application": return "macwindow"
        case "open_url": return "safari"
        case "capture_screen": return "camera"
        case "computer_action": return "macbook"
        default: return "gearshape"
        }
    }

    var formattedTotalCost: String {
        let total = results.reduce(0.0) { $0 + $1.cost }
        return total < 0.01 ? String(format: "$%.4f", total) : String(format: "$%.2f", total)
    }

    func formattedCost(_ cost: Double) -> String {
        cost < 0.01 ? String(format: "$%.4f", cost) : String(format: "$%.2f", cost)
    }
}

// MARK: - NSWorkspace Helpers

extension NSWorkspace {
    func openFolder(atPath path: String) {
        open(URL(fileURLWithPath: path, isDirectory: true))
    }

    func selectFile(_ fullPath: String?, inDirectory dir: String) {
        activateFileViewerSelecting([URL(fileURLWithPath: fullPath ?? dir, isDirectory: fullPath == nil)])
    }
}
