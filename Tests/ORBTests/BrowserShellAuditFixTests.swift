import AppKit
import Combine
import Foundation
import SwiftUI
import Testing
@testable import ORB

// Regression tests for the model-browser, settings and app-shell audit batch.

// MARK: - Fixtures

private func auditModel(id: String, name: String = "Old Name") -> ModelInfo {
    ModelInfo(
        id: id, canonicalSlug: nil, huggingFaceId: nil, name: name, created: nil,
        description: nil, contextLength: 128_000,
        architecture: Architecture(
            modality: "text->text", inputModalities: ["text"], outputModalities: ["text"],
            tokenizer: nil, instructType: nil
        ),
        pricing: Pricing(prompt: "0.000001", completion: "0.000002", inputCacheRead: nil),
        topProvider: nil, supportedParameters: [], reasoning: nil, knowledgeCutoff: nil,
        expirationDate: nil, supportedVoices: nil, benchmarks: nil, perRequestLimits: nil,
        defaultParameters: nil
    )
}

private let catalogURL = "https://openrouter.ai/api/v1/models"
private func endpointsURL(_ id: String) -> String { "https://openrouter.ai/api/v1/models/\(id)/endpoints" }
private let noEndpoints = #"{"data":{"id":"fixture","name":"Fixture","endpoints":[]}}"#
private func oneEndpoint(_ provider: String) -> String {
    #"{"data":{"id":"fixture","name":"Fixture","endpoints":[{"provider_name":"\#(provider)","pricing":{"prompt":"0.1","completion":"0.2"}}]}}"#
}

/// Status the test loader turns into a thrown `URLError(.cancelled)`.
private let cancelledStatus = 499

@MainActor
private func auditVM(
    _ loader: GatedLoader, defaults: UserDefaults? = nil, notifications: NotificationCenter = NotificationCenter()
) -> BrowserViewModel {
    let cache = FileManager.default.temporaryDirectory
        .appendingPathComponent("orb-audit-cache-\(UUID().uuidString).json")
    let api = APIService(cacheURL: cache) { url in
        let (data, response) = await loader.handle(url)
        if (response as? HTTPURLResponse)?.statusCode == cancelledStatus { throw URLError(.cancelled) }
        return (data, response)
    }
    // DatabaseManager() is an isolated implicit test database.
    return BrowserViewModel(api: api, db: DatabaseManager(), defaults: defaults, notifications: notifications)
}

@MainActor
private func waitUntil(timeout: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

private func freshDefaults() -> UserDefaults {
    let name = "orb.tests.audit.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

private final class AuditPublishCounter: @unchecked Sendable {
    var value = 0
}

// MARK: - Model browser

@Suite("Audit: model browser view model")
@MainActor
struct BrowserViewModelAuditTests {
    @Test("refresh drops restored compare ids the catalog no longer has, and saves the result")
    func refreshPrunesCompare() async {
        let defaults = freshDefaults()
        let first = auditVM(GatedLoader(), defaults: defaults)
        _ = first.toggleCompare("a/1")
        _ = first.toggleCompare("gone/9")

        let loader = GatedLoader()
        loader.enqueue(catalogURL, json: #"{"data":[{"id":"a/1","name":"One"},{"id":"a/2","name":"Two"}]}"#)
        let restored = auditVM(loader, defaults: defaults)
        #expect(restored.compareIDs == ["a/1", "gone/9"])

        await restored.refresh()

        #expect(restored.compareIDs == ["a/1"])
        #expect(restored.compareModels.map(\.id) == ["a/1"])
        #expect(BrowserPrefsStore.load(from: defaults)?.compareIDs == ["a/1"])
    }

    @Test("a failed refresh with no catalog keeps the compare selection")
    func emptyCatalogDoesNotPrune() async {
        let loader = GatedLoader()
        loader.enqueue(catalogURL, json: "{}", status: 500)
        let vm = auditVM(loader)
        _ = vm.toggleCompare("a/1")

        await vm.refresh()

        #expect(vm.api.models.isEmpty)
        #expect(vm.compareIDs == ["a/1"])
    }

    @Test("a compare deep link keeps only ids in the loaded catalog, before the cap")
    func setCompareDropsUnknown() {
        let vm = auditVM(GatedLoader())
        let known = (0..<TestBatchSelection.maximumModels).map { "a/\($0)" }
        vm.api.models = known.map { auditModel(id: $0) }

        vm.setCompare(["gone/1", "gone/2"] + known)

        #expect(vm.compareIDs == known)
        #expect(vm.compareLimitNotice == nil)
    }

    @Test("a compare deep link before the catalog loads is kept for the refresh to check")
    func setCompareBeforeCatalog() {
        let vm = auditVM(GatedLoader())
        vm.setCompare(["a/1", "a/2"])
        #expect(vm.compareIDs == ["a/1", "a/2"])
    }

    @Test("refresh replaces the selected model with the refreshed catalog value")
    func refreshReResolvesSelection() async {
        let loader = GatedLoader()
        loader.enqueue(endpointsURL("openai/gpt-a"), json: oneEndpoint("First"))
        let vm = auditVM(loader)
        vm.selectModel(auditModel(id: "openai/gpt-a", name: "Old Name"))
        let reached1 = await waitUntil { vm.endpoints.count == 1 }
        #expect(reached1)

        loader.enqueue(endpointsURL("openai/gpt-a"), json: oneEndpoint("Second"))
        loader.enqueue(catalogURL, json: #"""
        {"data":[{"id":"openai/gpt-a","name":"New Name","context_length":200000,
                  "pricing":{"prompt":"0.000009","completion":"0.00001"}}]}
        """#)
        await vm.refresh()

        #expect(vm.selectedModel?.name == "New Name")
        #expect(vm.selectedModel?.contextLength == 200_000)
        #expect(vm.selectedModel?.pricing?.prompt == "0.000009")
        let reached2 = await waitUntil { vm.endpoints.first?.providerName == "Second" }
        #expect(reached2)
    }

    @Test("refresh keeps a selected model that left the catalog")
    func refreshKeepsVanishedSelection() async {
        let loader = GatedLoader()
        loader.enqueue(endpointsURL("openai/gpt-a"), json: oneEndpoint("First"))
        let vm = auditVM(loader)
        vm.selectModel(auditModel(id: "openai/gpt-a"))
        let reached3 = await waitUntil { vm.endpoints.count == 1 }
        #expect(reached3)

        loader.enqueue(endpointsURL("openai/gpt-a"), json: oneEndpoint("Second"))
        loader.enqueue(catalogURL, json: #"{"data":[{"id":"other/model","name":"Other"}]}"#)
        await vm.refresh()

        #expect(vm.selectedModel?.name == "Old Name")
        let reached4 = await waitUntil { vm.endpoints.first?.providerName == "Second" }
        #expect(reached4)
    }

    @Test("a cancelled endpoints request for A is not shown as an error under B")
    func cancelledFetchDoesNotLeak() async throws {
        let loader = GatedLoader()
        loader.enqueue(endpointsURL("openai/gpt-b"), json: noEndpoints)
        let vm = auditVM(loader)

        vm.selectModel(auditModel(id: "openai/gpt-a"))
        let reached5 = await waitUntil { loader.callCount("openai/gpt-a") == 1 }
        #expect(reached5)
        vm.selectModel(auditModel(id: "openai/gpt-b"))
        let reached6 = await waitUntil { loader.callCount("openai/gpt-b") == 1 && !vm.isLoadingEndpoints }
        #expect(reached6)

        loader.release("openai/gpt-a", json: "", status: cancelledStatus)
        try await Task.sleep(for: .milliseconds(100))

        #expect(vm.selectedModel?.id == "openai/gpt-b")
        #expect(vm.endpoints.isEmpty)
        #expect(vm.api.endpointsError == nil)
    }

    @Test("a late failure for A is not shown as an error under B")
    func lateFailureDoesNotLeak() async throws {
        let loader = GatedLoader()
        loader.enqueue(endpointsURL("openai/gpt-b"), json: noEndpoints)
        let vm = auditVM(loader)

        vm.selectModel(auditModel(id: "openai/gpt-a"))
        let reached7 = await waitUntil { loader.callCount("openai/gpt-a") == 1 }
        #expect(reached7)
        vm.selectModel(auditModel(id: "openai/gpt-b"))
        let reached8 = await waitUntil { loader.callCount("openai/gpt-b") == 1 && !vm.isLoadingEndpoints }
        #expect(reached8)

        loader.release("openai/gpt-a", json: "{}", status: 500)
        try await Task.sleep(for: .milliseconds(100))

        #expect(vm.api.endpointsError == nil)
    }

    @Test("a failure for the selected model is still reported")
    func ownFailureIsReported() async {
        let loader = GatedLoader()
        loader.enqueue(endpointsURL("openai/gpt-a"), json: "{}", status: 503)
        let vm = auditVM(loader)

        vm.selectModel(auditModel(id: "openai/gpt-a"))

        let reached9 = await waitUntil { vm.api.endpointsError == "HTTP 503 loading providers" }
        #expect(reached9)
        #expect(!vm.isLoadingEndpoints)
    }

    @Test("fetchEndpoints from a cancelled task does not write the shared error")
    func cancelledTaskWritesNoError() async {
        let api = APIService(
            cacheURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        ) { _ in throw URLError(.cancelled) }

        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return await api.fetchEndpoints(for: "a/b")
        }

        let fetched = await task.value
        #expect(fetched.isEmpty)
        #expect(api.endpointsError == nil)
    }

    @Test("the catalog loading state reaches view-model observers while the request is running")
    func loadingStateRepublishes() async {
        let loader = GatedLoader()
        let vm = auditVM(loader)
        let publishes = AuditPublishCounter()
        let subscription = vm.objectWillChange.sink { publishes.value += 1 }
        defer { subscription.cancel() }

        let refresh = Task { await vm.refresh() }
        let reached10 = await waitUntil { loader.callCount(catalogURL) == 1 }
        #expect(reached10)

        // The request is still held: nothing else in refresh() has published yet.
        #expect(vm.api.isLoading)
        #expect(publishes.value > 0)

        loader.release(catalogURL, json: #"{"data":[]}"#)
        await refresh.value
        #expect(!vm.api.isLoading)
    }

    @Test("forwarding service changes does not keep the view model alive")
    func forwardingDoesNotRetain() {
        var vm: BrowserViewModel? = auditVM(GatedLoader())
        weak var released = vm
        vm = nil
        #expect(released == nil)
    }

    @Test("notes typed inside the save delay are written when the app is about to quit")
    func notesFlushOnTerminate() {
        let center = NotificationCenter()
        let vm = auditVM(GatedLoader(), notifications: center)

        vm.stageNotes("half-typed thought", for: "a/b")
        #expect(vm.db.getNotes("a/b") == "")

        center.post(name: NSApplication.willTerminateNotification, object: nil)

        #expect(vm.db.getNotes("a/b") == "half-typed thought")
        #expect(vm.pendingNotes == nil)
    }

    @Test("staged notes are cleared by a save or by reverting to the saved text")
    func stagedNotesLifecycle() {
        let vm = auditVM(GatedLoader())

        vm.stageNotes("draft", for: "a/b")
        vm.saveNotes("draft", for: "a/b")
        #expect(vm.pendingNotes == nil)

        vm.stageNotes("draft 2", for: "a/b")
        vm.stageNotes(nil, for: "other/model")
        #expect(vm.pendingNotes?.text == "draft 2")
        vm.stageNotes(nil, for: "a/b")
        #expect(vm.pendingNotes == nil)

        vm.flushPendingNotes()
        #expect(vm.db.getNotes("a/b") == "draft")
    }
}

@Suite("Audit: model browser facts")
struct BrowserFactsAuditTests {
    @Test("The one-liner is the first line that still has text after Markdown is stripped")
    func firstLine() {
        #expect(ModelRowFacts.firstLine(of: "\n\n# \n**Fast** model\nSecond line") == "Fast model")
        #expect(ModelRowFacts.firstLine(of: "Plain first\nSecond") == "Plain first")
        #expect(ModelRowFacts.firstLine(of: " \n\t\n") == nil)
        #expect(ModelRowFacts.firstLine(of: "") == nil)
        #expect(ModelRowFacts.firstLine(of: nil) == nil)
    }

    @Test("Uptime shows one decimal place and reads fractions and percentages alike")
    func uptime() {
        #expect(EndpointUptime.label(99.997) == "Uptime 99.9%")
        #expect(EndpointUptime.label(99.89481609843396) == "Uptime 99.9%")
        #expect(EndpointUptime.label(97.27894707082307) == "Uptime 97.3%")
        #expect(EndpointUptime.label(0.997) == "Uptime 99.7%")
        #expect(EndpointUptime.label(100) == "Uptime 100%")
        #expect(EndpointUptime.label(1) == "Uptime 100%")
        #expect(EndpointUptime.label(0) == "Uptime 0.0%")
        #expect(EndpointUptime.label(-1) == nil)
        #expect(EndpointUptime.label(.nan) == nil)
        #expect(EndpointUptime.percent(0.5) == 50)
        #expect(EndpointUptime.percent(250) == 100)
    }

    @Test("A $0 endpoint sorts first and is the cheapest; variable and unknown prices stay last")
    @MainActor
    func zeroPriceRanksFirst() async throws {
        let json = #"""
        {"data":{"id":"a/b","endpoints":[
          {"provider_name":"Paid","pricing":{"prompt":"0.000001","completion":"0.000002"}},
          {"provider_name":"Variable","pricing":{"prompt":"-1","completion":"-1"}},
          {"provider_name":"Free","pricing":{"prompt":"0","completion":"0"}},
          {"provider_name":"Unknown"}
        ]}}
        """#
        let api = APIService(
            cacheURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        ) { url in
            (Data(json.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }

        let endpoints = try await api.loadEndpoints(for: "a/b").get()

        #expect(endpoints.map(\.displayName) == ["Free", "Paid", "Unknown", "Variable"])
        #expect(endpoints.map(\.rankingInputPrice) == [0, 0.000001, nil, nil])
        #expect(ModelEndpoint.cheapestInputPrice(in: endpoints) == 0)
        #expect(ModelEndpoint.cheapestInputPrice(in: Array(endpoints.suffix(2))) == nil)
    }
}

// MARK: - Settings

@Suite("Audit: request parameters JSON Schema")
struct JSONSchemaDraftTests {
    private let cityText = #"{"type":"object","properties":{"city":{"type":"string"}},"required":["city"]}"#
    private var citySchema: JSONValue {
        .object([
            "type": .string("object"),
            "properties": .object(["city": .object(["type": .string("string")])]),
            "required": .array([.string("city")]),
        ])
    }

    @Test("Typed schema fields are committed into a JSON Schema response format")
    func commits() {
        var format = ResponseFormatSettings.jsonSchema(name: "response", schema: .object([:]), strict: true)
        var draft = JSONSchemaDraft()
        draft.name = "  weather  "
        draft.text = cityText
        draft.strict = false

        draft.commit(into: &format)

        #expect(format == .jsonSchema(name: "weather", schema: citySchema, strict: false))
        #expect(draft.error == nil)
    }

    @Test("Editing the fields never turns a different response format into JSON Schema")
    func leavesOtherFormats() {
        var draft = JSONSchemaDraft()
        draft.text = cityText
        var off = ResponseFormatSettings.off
        var object = ResponseFormatSettings.jsonObject
        draft.commit(into: &off)
        draft.commit(into: &object)
        #expect(off == .off)
        #expect(object == .jsonObject)
    }

    @Test("A half-typed schema keeps the last valid one; name and strict still apply")
    func invalidTextKeepsSchema() {
        var format = ResponseFormatSettings.jsonSchema(name: "weather", schema: citySchema, strict: true)
        var draft = JSONSchemaDraft()
        draft.name = "forecast"
        draft.text = #"{"type":"object","prop"#
        draft.strict = false

        draft.commit(into: &format)

        #expect(format == .jsonSchema(name: "forecast", schema: citySchema, strict: false))
        #expect(draft.error == "Schema must be a valid JSON object.")
    }

    @Test("A blank name falls back to the default and is flagged")
    func blankName() {
        var draft = JSONSchemaDraft()
        draft.name = "   "
        #expect(draft.error == "Give the schema a name.")
        #expect(draft.responseFormat(keeping: nil) == .jsonSchema(
            name: JSONSchemaDraft.defaultName, schema: draft.parsedSchema ?? .null, strict: true
        ))
    }

    @Test("Reopening the sheet shows the stored schema, and seeding changes nothing")
    func seedsFromStored() throws {
        let stored = ResponseFormatSettings.jsonSchema(name: "weather", schema: citySchema, strict: false)

        let draft = try #require(JSONSchemaDraft(stored: stored))

        #expect(draft.name == "weather")
        #expect(draft.strict == false)
        #expect(draft.parsedSchema == citySchema)
        #expect(draft.text != JSONSchemaDraft.exampleText)
        var format = stored
        draft.commit(into: &format)
        #expect(format == stored)
    }

    @Test("Other formats have no stored schema, so the example stays")
    func noSeedForOtherFormats() {
        #expect(JSONSchemaDraft(stored: .off) == nil)
        #expect(JSONSchemaDraft(stored: .jsonObject) == nil)
        #expect(JSONSchemaDraft().text == JSONSchemaDraft.exampleText)
        #expect(JSONSchemaDraft().parsedSchema != nil)
    }
}

@Suite("Audit: MCP arguments field")
struct MCPArgumentsTests {
    @Test("Plain arguments split on whitespace")
    func plain() {
        #expect(MCPArguments.parse("-y  @scope/server --flag") == ["-y", "@scope/server", "--flag"])
        #expect(MCPArguments.parse("") == [])
        #expect(MCPArguments.parse("   ") == [])
        #expect(MCPArguments.render(["-y", "@scope/server"]) == "-y @scope/server")
    }

    @Test("Quoted and backslash-escaped spaces stay inside one argument")
    func quoting() {
        #expect(MCPArguments.parse(#"--root "/data/My Files" -v"#) == ["--root", "/data/My Files", "-v"])
        #expect(MCPArguments.parse("--root '/data/My Files'") == ["--root", "/data/My Files"])
        #expect(MCPArguments.parse(#"--root /data/My\ Files"#) == ["--root", "/data/My Files"])
        #expect(MCPArguments.parse(#"--name="two words""#) == ["--name=two words"])
        #expect(MCPArguments.parse(#"a "" b"#) == ["a", "", "b"])
        #expect(MCPArguments.parse(#""say \"hi\"""#) == [#"say "hi""#])
    }

    @Test("A half-typed quote keeps its text instead of dropping it")
    func unterminated() {
        #expect(MCPArguments.parse(#"--root "/data/My"#) == ["--root", "/data/My"])
        #expect(MCPArguments.parse(#"--root "/data/My Fi"#) == ["--root", "/data/My Fi"])
        #expect(MCPArguments.parse(#"trailing\"#) == [#"trailing\"#])
    }

    @Test("Every argument list survives render then parse")
    func roundTrip() {
        let lists: [[String]] = [
            [],
            ["-y", "server"],
            ["--root", "/data/My Files"],
            ["two  spaces", "", "it's", #"say "hi""#, #"C:\dir\file"#, #"ends with \"#, "tab\there"],
            [" leading", "trailing "],
        ]
        for list in lists {
            #expect(MCPArguments.parse(MCPArguments.render(list)) == list, "\(list)")
        }
        #expect(MCPArguments.render(["--root", "/data/My Files"]) == #"--root "/data/My Files""#)
    }
}

@Suite("Audit: usage range")
struct UsageRangeAuditTests {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0)!
        return c
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 0, minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    @Test("7 and 30 day totals start on the first day the chart plots")
    func windowMatchesChart() {
        let now = date(2026, 10, 7, hour: 15, minute: 30)
        for days in [1, 7, 30] {
            let start = UsageSeries.windowStart(days: days, endingAt: now, calendar: calendar)
            let plotted = UsageSeries.daily([], days: days, endingAt: now, calendar: calendar)
            #expect(plotted.count == days)
            #expect(plotted.first?.date == start, "\(days) days")
        }
        #expect(UsageSeries.windowStart(days: 7, endingAt: now, calendar: calendar) == date(2026, 10, 1))
        #expect(UsageSeries.windowStart(days: 30, endingAt: now, calendar: calendar) == date(2026, 9, 8))
        #expect(UsageSeries.windowStart(days: 1, endingAt: now, calendar: calendar) == date(2026, 10, 7))
    }

    @Test("The range picker uses the calendar-day window")
    func rangeStart() {
        let now = date(2026, 10, 7, hour: 23, minute: 59)
        typealias Range = UsageSettingsView.Range
        #expect(Range.today.start(now: now, calendar: calendar) == date(2026, 10, 7))
        #expect(Range.week.start(now: now, calendar: calendar) == date(2026, 10, 1))
        #expect(Range.month.start(now: now, calendar: calendar) == date(2026, 9, 8))
        #expect(Range.allTime.start(now: now, calendar: calendar) == nil)
        #expect(Range.allCases.map(\.days) == [1, 7, 30, nil])
    }
}

@Suite("Audit: settings copy and panes")
struct SettingsCopyAuditTests {
    @Test("Removing the inference key does not claim credits and activity go away")
    func removeInferenceCopy() {
        let message = ManagementKeyPanel.removeInferenceMessage
        #expect(message.contains("inference key"))
        #expect(message.contains("Credits and activity use the management key and are not affected."))
    }

    @Test("Empty states describe macOS controls")
    func macCopy() {
        for copy in [ManagementKeyPanel.creditsEmptyMessage, ManagementKeyPanel.keyInfoEmptyMessage] {
            #expect(!copy.localizedCaseInsensitiveContains("pull to refresh"))
            #expect(!copy.localizedCaseInsensitiveContains("tap"))
            #expect(copy.contains("refresh button"))
        }
    }

    @Test("The lock screen's settings link targets the pane with the Security section")
    func lockSettingsPane() {
        let defaults = freshDefaults()
        SettingsPane.network.store(in: defaults)
        SettingsPane.lockSettings.store(in: defaults)
        #expect(SettingsPane.restore(from: defaults) == .general)
    }
}

// MARK: - Shell

@Suite("Audit: deep links while locked")
struct LockedDeepLinkInboxTests {
    @Test("A link that arrives while locked is held and handed out once after unlock")
    func heldUntilUnlock() {
        var inbox = LockedDeepLinkInbox()

        let now = inbox.receive(.selectModel("openai/gpt-4o"), isUnlocked: false)
        #expect(now == nil)
        #expect(inbox.held == .selectModel("openai/gpt-4o"))

        let afterUnlock = inbox.takeAfterUnlock()
        #expect(afterUnlock == .selectModel("openai/gpt-4o"))
        let again = inbox.takeAfterUnlock()
        #expect(again == nil)
    }

    @Test("The newest link wins while locked")
    func newestWins() {
        var inbox = LockedDeepLinkInbox()
        _ = inbox.receive(.selectModel("a/b"), isUnlocked: false)
        _ = inbox.receive(.openCompareWith(["a/b", "c/d"]), isUnlocked: false)
        let afterUnlock = inbox.takeAfterUnlock()
        #expect(afterUnlock == .openCompareWith(["a/b", "c/d"]))
    }

    @Test("A link that arrives while unlocked runs at once and leaves nothing behind")
    func immediateWhenUnlocked() {
        var inbox = LockedDeepLinkInbox()
        _ = inbox.receive(.selectModel("old/link"), isUnlocked: false)
        let now = inbox.receive(.chatWithModel("a/b"), isUnlocked: true)
        #expect(now == .chatWithModel("a/b"))
        let afterUnlock = inbox.takeAfterUnlock()
        #expect(afterUnlock == nil)
    }

    @Test("Every deep link kind survives the lock")
    func everyKind() throws {
        for text in ["orb://model/openai/gpt-4o", "orb://chat?model=a/b", "orb://chat", "orb://compare?ids=a/1,b/2"] {
            let link = try #require(URL(string: text).flatMap(DeepLink.parse))
            var inbox = LockedDeepLinkInbox()
            _ = inbox.receive(link.shellAction, isUnlocked: false)
            let afterUnlock = inbox.takeAfterUnlock()
            #expect(afterUnlock == link.shellAction, "\(text)")
        }
    }
}

@Suite("Audit: toast announcements")
@MainActor
struct ToastAnnouncementTests {
    @Test("Each toast is announced once, even when a newer one leaves first")
    func noReannouncement() {
        let center = ToastCenter()
        let older = center.show("Saved", kind: .success, duration: 0)
        #expect(center.takeUnannounced().map(\.id) == [older])

        let newer = center.show("Copied", kind: .info, duration: 0)
        #expect(center.takeUnannounced().map(\.id) == [newer])

        // The newer toast expires first; the older one is last again.
        center.dismiss(newer)
        #expect(center.toasts.last?.id == older)
        #expect(center.takeUnannounced().isEmpty)
    }

    @Test("Toasts shown together are all announced, oldest first")
    func batch() {
        let center = ToastCenter()
        let first = center.show("One", duration: 0)
        let second = center.show("Two", duration: 0)
        #expect(center.takeUnannounced().map(\.id) == [first, second])
        #expect(center.takeUnannounced().isEmpty)
    }
}
