import Foundation
import Testing
@testable import ORB

@MainActor
struct UsageLedgerTests {
    private func makeLedger() -> (UsageLedger, DatabaseManager) {
        let db = DatabaseManager()   // isolated temp DB under test
        return (UsageLedger(database: { db }), db)
    }

    @Test func groupsByFeatureAndModelAndKeepsUnknownCostUnpriced() {
        let (ledger, _) = makeLedger()
        ledger.record(.chat, model: "a/x", cost: 0.10, totalTokens: 100)
        ledger.record(.chat, model: "a/x", cost: 0.05, totalTokens: 50)
        ledger.record(.images, model: "b/y", cost: 0.20)
        ledger.record(.speech, model: "c/z", cost: nil)

        let features = ledger.buckets(.feature)
        #expect(features.first?.key == "Images")
        let chat = features.first { $0.key == "Chat" }
        #expect(chat?.requests == 2)
        #expect(abs((chat?.cost ?? 0) - 0.15) < 1e-9)
        #expect(chat?.tokens == 150)
        let speech = features.first { $0.key == "Speech" }
        #expect(speech?.unpricedRequests == 1)
        #expect(speech?.cost == 0)
        #expect(ledger.buckets(.model).count == 3)
    }

    @Test func duplicateEventIDsNeverDoubleCount() {
        let (ledger, _) = makeLedger()
        ledger.record(.video, model: "v/m", cost: 1.0, eventID: "job-1")
        ledger.record(.video, model: "v/m", cost: 1.0, eventID: "job-1")
        #expect(ledger.buckets(.feature).first?.requests == 1)
        #expect(ledger.buckets(.feature).first?.cost == 1.0)
    }

    @Test func rangeFilterExcludesOlderEvents() {
        let (ledger, db) = makeLedger()
        db.insertUsageEvent(UsageEvent(timestamp: Date().addingTimeInterval(-86_400 * 40),
                                       feature: "Chat", modelID: "m", cost: 5))
        ledger.record(.chat, model: "m", cost: 1)
        let recent = ledger.buckets(.feature, since: Date().addingTimeInterval(-86_400 * 30))
        #expect(recent.first?.cost == 1)
        #expect(ledger.buckets(.feature).first?.cost == 6)
    }

    @Test func ledgerPersistsAcrossReopen() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("ledger-\(UUID().uuidString).sqlite3").path
        defer { for ext in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + ext) } }
        do {
            let db = DatabaseManager(path: path)
            UsageLedger(database: { db }).record(.agent, model: "m", cost: 2.5)
        }
        let reopened = DatabaseManager(path: path)
        #expect(UsageLedger(database: { reopened }).buckets(.feature).first?.cost == 2.5)
    }
}
