import Foundation
import Testing
@testable import ORB

@Suite("Test evaluation boundaries")
struct TestEvaluationBoundaryTests {
    private let fm = FileManager.default

    private func fixture() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ORB-eval-boundary-\(UUID())", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func scenario(category: TestCategory = .apiDesign, paths: [String] = []) -> TestScenario {
        TestScenario(id: "boundary", category: category, title: "Boundary", subtitle: "", icon: "doc",
                     difficulty: .foundational, estimatedSeconds: 1, systemPrompt: "", userPrompt: "",
                     evaluationCriteria: ["Requires human review"], expectedArtifacts: paths)
    }

    private func record(_ scenario: TestScenario, dir: URL?, response: String = "Finished.",
                        mode: TestEvaluationMode = .projectBuild) -> ExperimentRunRecord {
        ExperimentEvaluation.record(scenario: scenario, modelID: "offline", policy: .projectBuild,
                                    projectDirectory: dir, response: response, usage: nil,
                                    completionStatus: .completed, startedAt: Date(timeIntervalSince1970: 1),
                                    finishedAt: Date(timeIntervalSince1970: 2), errorMessage: nil,
                                    evaluationMode: mode)
    }

    @Test("project mode rejects nil or nonexistent directories; text mode is unverified")
    func modes() throws {
        let s = scenario()
        let nilProject = record(s, dir: nil)
        #expect(nilProject.verdict == .failed)
        #expect(nilProject.artifactChecks.first?.name == "projectDirectoryPresent")
        #expect(nilProject.artifactChecks.first?.passed == false)
        let absent = fm.temporaryDirectory.appendingPathComponent("ORB-absent-\(UUID())")
        #expect(record(s, dir: absent).verdict == .failed)
        let text = record(s, dir: nil, mode: .textResponse)
        #expect(text.verdict == .unverified)
        #expect(text.artifactChecks.first?.name == "textResponseMode")
        #expect(record(s, dir: nil, response: " \n\t ", mode: .textResponse).verdict == .failed)
        #expect(record(s, dir: nil, response: "I cannot complete this.", mode: .textResponse).verdict == .failed)
        #expect(ExperimentEvaluation.overallVerdict(completionStatus: .completed, artifactChecks: [], assertions: []) == .failed)
    }

    @Test("empty and whitespace-only files do not count as generated artifacts")
    func blanks() throws {
        let dir = try fixture()
        defer { try? fm.removeItem(at: dir) }
        let s = scenario(paths: ["output.txt"])
        try Data().write(to: dir.appendingPathComponent("output.txt"))
        #expect(record(s, dir: dir).verdict == .failed)
        try Data(" \n\t  ".utf8).write(to: dir.appendingPathComponent("output.txt"))
        let blank = record(s, dir: dir)
        #expect(blank.artifactChecks.first(where: { $0.name == "atLeastOneFileCreated" })?.passed == false)
        #expect(blank.artifactChecks.first(where: { $0.name == "expectedArtifact:output.txt" })?.passed == false)
        try Data("actual output".utf8).write(to: dir.appendingPathComponent("output.txt"))
        #expect(record(s, dir: dir).verdict == .passed)
    }

    @Test("external symlinks and traversal cannot satisfy declared artifacts")
    func escapes() throws {
        let dir = try fixture()
        let outside = try fixture()
        defer { try? fm.removeItem(at: dir); try? fm.removeItem(at: outside) }
        try Data("external evidence".utf8).write(to: outside.appendingPathComponent("proof.txt"))
        try fm.createSymbolicLink(at: dir.appendingPathComponent("linked.txt"), withDestinationURL: outside.appendingPathComponent("proof.txt"))
        try fm.createSymbolicLink(at: dir.appendingPathComponent("external"), withDestinationURL: outside)
        for path in ["linked.txt", "external/proof.txt", "../\(outside.lastPathComponent)/proof.txt", outside.appendingPathComponent("proof.txt").path] {
            let result = record(scenario(paths: [path]), dir: dir)
            #expect(result.verdict == .failed, "Path must be rejected: \(path)")
            #expect(result.artifactChecks.first(where: { $0.name == "expectedArtifact:\(path)" })?.passed == false)
        }
        #expect(record(scenario(), dir: dir).verdict == .failed) // symlinks alone do not count
    }

    @Test("large padded HTML placeholders fail, real page passes structural smoke check")
    func webPlaceholders() throws {
        let dir = try fixture()
        defer { try? fm.removeItem(at: dir) }
        let index = dir.appendingPathComponent("index.html")
        let padded = "<!doctype html><html><body>Coming soon</body></html>" + String(repeating: "<!-- filler -->", count: 30)
        try Data(padded.utf8).write(to: index)
        let s = scenario(category: .webDevelopment, paths: ["index.html"])
        #expect(record(s, dir: dir).artifactChecks.first(where: { $0.name == "webIndexHTMLPresent" })?.passed == false)
        #expect(record(s, dir: dir).verdict == .failed)
        let page = "<!doctype html><html><head><title>Demo</title></head><body><nav>Home</nav><main><h1>Example application</h1><p>Useful instructions for the visitor. Explore the dashboard, review your projects, and select a task to get started.</p><button>Start</button></main></body></html>"
        try Data(page.utf8).write(to: index)
        #expect(record(s, dir: dir).verdict == .passed)
    }

    @Test("exact-output probes reject malformed, wrong-typed, or altered answers")
    func exactResponses() throws {
        let json = try #require(TestCatalog.scenario(id: "llm-structured-output"))
        let unicode = try #require(TestCatalog.scenario(id: "llm-unicode-fidelity"))
        let validJSON = record(json, dir: nil, response: "{\"name\":\"A\\\"B\",\"count\":2}", mode: .textResponse)
        #expect(validJSON.verdict == .unverified)
        #expect(validJSON.assertions.first(where: { $0.name == "exactStructuredJSON" })?.passed == true)
        for response in ["```json\n{\"name\":\"A\\\"B\",\"count\":2}\n```",
                         "{\"name\":\"A\\\"B\",\"count\":\"2\"}",
                         "{\"name\":\"A\\\"B\",\"count\":true}",
                         "{\"name\":\"A\\\"B\",\"count\":2,\"extra\":0}"] {
            let result = record(json, dir: nil, response: response, mode: .textResponse)
            #expect(result.verdict == .failed)
            #expect(result.assertions.first(where: { $0.name == "exactStructuredJSON" })?.passed == false)
        }
        let exact = "[\"café\",\"東京\",\"👩🏽‍💻\"]"
        #expect(record(unicode, dir: nil, response: exact, mode: .textResponse).verdict == .unverified)
        #expect(record(unicode, dir: nil, response: "[\"cafe\",\"東京\",\"👩🏽‍💻\"]", mode: .textResponse).verdict == .failed)
        #expect(record(unicode, dir: nil, response: "[\"東京\",\"café\",\"👩🏽‍💻\"]", mode: .textResponse).verdict == .failed)
    }

    @Test("calibrated refusal is permitted but never automatically graded correct")
    func permittedRefusal() throws {
        let s = try #require(TestCatalog.scenario(id: "llm-calibrated-refusal"))
        #expect(s.evaluationMode == .textResponse)
        #expect(record(s, dir: nil, response: "I cannot know that password from this prompt.", mode: .textResponse).verdict == .unverified)
    }
}
