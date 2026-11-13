import Foundation
import Testing
@testable import ORB

@Suite("Batch duplicate result identities")
struct BatchDuplicateResultTests {
    @Test("conflicting custom_id outcomes remain raw but cannot resolve as one result")
    func conflictingDuplicateOutcomesFailClosed() throws {
        // Synthetic adapter-only input, not an assertion about live provider output.
        // Success comes first: first-wins indexing would silently hide the failure.
        let fixture = """
        {
          "id": "batch_duplicate_fixture",
          "status": "completed",
          "results": [
            {
              "custom_id": "duplicate",
              "response": {"status_code": 200, "body": {"answer": "retained success"}},
              "error": null
            },
            {
              "custom_id": "duplicate",
              "response": null,
              "error": {"code": "invalid_request", "message": "retained failure"}
            },
            {
              "custom_id": "unique",
              "response": {"status_code": 200, "body": ["opaque", 1]},
              "error": null
            }
          ]
        }
        """
        let record = try JSONDecoder().decode(BatchRecord.self, from: Data(fixture.utf8))
        let raw = try #require(record.results)
        try #require(raw.count == 3)
        #expect(raw.map(\.customID) == ["duplicate", "duplicate", "unique"])
        #expect(raw[0].succeeded)
        #expect(raw[0].response?.body == .object(["answer": .string("retained success")]))
        #expect(!raw[1].succeeded)
        #expect(raw[1].error == .object([
            "code": .string("invalid_request"),
            "message": .string("retained failure")
        ]))

        // Existing nonthrowing accessors must not choose either conflicting row.
        // Both expectations expose the current first-wins defect without a new API.
        #expect(record.resultsByCustomID["duplicate"] == nil)
        #expect(record.result(for: "duplicate") == nil)
        #expect(record.resultsByCustomID["unique"] == raw[2])
        #expect(record.result(for: "unique") == raw[2])
        #expect(record.results == raw)
    }

    @Test("reversed, identical, and triple duplicates never select or restore a result", arguments: [
        [0, 1], [1, 0], [0, 0], [1, 1], [0, 1, 0], [1, 0, 1], [0, 0, 0]
    ])
    func repeatedIdentitiesStayExcluded(outcomes: [Int]) throws {
        let variants = [
            #"{"custom_id":"duplicate","response":{"status_code":200,"body":{"answer":"retained"}}}"#,
            #"{"custom_id":"duplicate","error":{"code":"fixture_failure"}}"#
        ]
        var rows = outcomes.map { variants[$0] }
        // Nonadjacent repetitions must also be excluded.
        rows.insert(#"{"custom_id":"unique","response":{"status_code":200,"body":["opaque",1]}}"#, at: 1)
        let rawJSON = "[\(rows.joined(separator: ","))]"
        let raw = try JSONDecoder().decode([BatchResultItem].self, from: Data(rawJSON.utf8))
        let record = try JSONDecoder().decode(
            BatchRecord.self, from: Data("{\"results\":\(rawJSON)}".utf8)
        )

        #expect(record.resultsByCustomID == ["unique": raw[1]])
        #expect(record.result(for: "duplicate") == nil)
        #expect(record.result(for: "unique") == raw[1])
        #expect(record.result(for: "missing") == nil)
        for item in raw {
            #expect(record.result(for: item.customID) == record.resultsByCustomID[item.customID])
        }
        // Repeated accessor reads do not change either the index or the raw rows.
        #expect(record.resultsByCustomID == ["unique": raw[1]])
        #expect(record.results == raw)
    }

    @Test("only empty IDs are omitted; nonempty opaque IDs retain their exact spelling")
    func emptyAndOpaqueIdentities() throws {
        let ids = ["", " ", "\t\n", " req!?/:#% ", "req!?/:#%", "req_1", "req-1"]
        let rows = ids.map { id -> [String: Any] in
            ["custom_id": id, "error": ["message": id]]
        }
        let data = try JSONSerialization.data(withJSONObject: ["results": rows])
        let record = try JSONDecoder().decode(BatchRecord.self, from: data)
        let raw = try #require(record.results)
        #expect(raw.map(\.customID) == ids)
        #expect(record.resultsByCustomID.count == ids.count - 1)
        #expect(record.resultsByCustomID[""] == nil)
        #expect(record.result(for: "") == nil)
        for item in raw where !item.customID.isEmpty {
            #expect(record.resultsByCustomID[item.customID] == item)
            #expect(record.result(for: item.customID) == item)
            #expect(record.result(for: item.customID)?.customID.utf8.elementsEqual(item.customID.utf8) == true)
        }
        #expect(record.result(for: "req") == nil)
        #expect(record.results == raw)
    }

    @Test("absent, null, and empty results have empty lookups", arguments: [
        "{}", #"{"results":null}"#, #"{"results":[]}"#
    ])
    func absentResults(fixture: String) throws {
        let record = try JSONDecoder().decode(BatchRecord.self, from: Data(fixture.utf8))
        #expect(record.resultsByCustomID.isEmpty)
        #expect(record.result(for: "missing") == nil)
        #expect(record.result(for: "") == nil)
        if fixture == #"{"results":[]}"# {
            #expect(record.results == [])
        } else {
            #expect(record.results == nil)
        }
    }

    @Test("missing, null, and non-string custom_id values remain decoding errors", arguments: [
        "{}", #"{"custom_id":null}"#, #"{"custom_id":42}"#,
        #"{"custom_id":true}"#, #"{"custom_id":[]}"#, #"{"custom_id":{}}"#
    ])
    func malformedTypedIdentities(row: String) {
        // Do not coerce malformed IDs or silently discard malformed rows at decode time.
        let fixture = "{\"results\":[{\"custom_id\":\"unique\"},\(row)]}"
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(BatchRecord.self, from: Data(fixture.utf8))
        }
    }
}
