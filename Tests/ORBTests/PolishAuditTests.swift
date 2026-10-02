import Testing
import Foundation
@testable import ORB

/// Source-level guards for Phase 8 rules, so they stay true as the app changes.
@Suite("Phase 8: source audits")
struct PolishAuditTests {
    private var sourcesRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ORB")
    }

    private func swiftFiles() -> [URL] {
        let e = FileManager.default.enumerator(at: sourcesRoot, includingPropertiesForKeys: nil)
        return (e?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "swift" }
    }

    @Test("No fixed font below 11 pt anywhere in the app")
    func fontFloor() throws {
        let pattern = try NSRegularExpression(pattern: #"\.system\(size:\s*(\d+(?:\.\d+)?)"#)
        var offenders: [String] = []
        for file in swiftFiles() {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let s = String(line)
                for m in pattern.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
                    if let r = Range(m.range(at: 1), in: s), let size = Double(s[r]), size < 11 {
                        offenders.append("\(file.lastPathComponent):\(i + 1) size \(size)")
                    }
                }
            }
        }
        #expect(offenders.isEmpty, "\(offenders.prefix(8))")
    }

    @Test("Every icon-only Button label has an accessibility label nearby")
    func iconButtons() throws {
        // A Button whose label is a bare Image(systemName:) must carry .accessibilityLabel or .help.
        var offenders: [String] = []
        for file in swiftFiles() {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            for (i, line) in lines.enumerated() where line.contains("label: {") {
                let window = lines[i...min(i + 14, lines.count - 1)].joined(separator: "\n")
                let hasImage = window.contains("Image(systemName:")
                let hasText = window.contains("Text(") || window.contains("Label(")
                if hasImage && !hasText && !window.contains("accessibilityLabel") && !window.contains(".help(") {
                    offenders.append("\(file.lastPathComponent):\(i + 1)")
                }
            }
        }
        #expect(offenders.isEmpty, "\(offenders.prefix(60))")
    }

    @Test("Endless animations always go through the Reduce Motion guard")
    func loopingGuard() throws {
        var offenders: [String] = []
        for file in swiftFiles() where file.lastPathComponent != "ORBMotion.swift" {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            for (i, line) in lines.enumerated() where line.contains("repeatForever") {
                let hasGuard = line.contains("ORBMotion.looping") || line.contains("reduceMotion")
                if !hasGuard { offenders.append("\(file.lastPathComponent):\(i + 1)") }
            }
        }
        #expect(offenders.isEmpty, "\(offenders)")
    }
}

@Suite("Phase 8: motion helpers")
struct MotionHelperTests {
    private func defaults(_ override: AppearancePrefs.MotionOverride) -> UserDefaults {
        let name = "orb.tests.motion.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        var p = AppearancePrefs(); p.reduceMotion = override; p.save(to: d)
        return d
    }

    @Test("System Reduce Motion removes looping and one-shot animations")
    func system() {
        let d = defaults(.system)
        #expect(ORBMotion.looping(.linear(duration: 1), system: true, defaults: d) == nil)
        #expect(ORBMotion.oneShot(.easeInOut, system: true, defaults: d) == nil)
        #expect(ORBMotion.looping(.linear(duration: 1), system: false, defaults: d) != nil)
    }

    @Test("The in-app Reduce setting removes animation even when the system allows it")
    func override() {
        let d = defaults(.on)
        #expect(ORBMotion.shouldReduce(system: false, defaults: d))
        #expect(ORBMotion.oneShot(.easeInOut, system: false, defaults: d) == nil)
    }

    @Test("Allow never turns off the system's request to reduce")
    func allow() {
        let d = defaults(.off)
        #expect(ORBMotion.shouldReduce(system: true, defaults: d))
        #expect(!ORBMotion.shouldReduce(system: false, defaults: d))
    }
}
