import Foundation
import Testing
@testable import CodexBarCore

struct CodexIdentifiedCollectionTests {
    @Test
    func `shared observations retain subtotals while union counts once and wire keys stay unchanged`() async throws {
        var ledger = CodexRequestLedger(startUnixMs: 0, endUnixMs: 1000)
        ledger.records = [.init(
            id: String(repeating: "a", count: 64),
            timestampUnixMs: 1,
            inputTokens: 10,
            cacheReadTokens: 0,
            outputTokens: 2,
            reasoningTokens: nil,
            model: "fictitious-unknown",
            pricingMode: nil,
            includedInPlan: false)]
        let fixture = ledger
        let result = try await CodexIdentifiedCollection.collect(
            remotes: ["remote"],
            startUnixMs: 0,
            endUnixMs: 1000,
            includeSourceSubtotals: true,
            local: { fixture },
            fetchRemote: { _ in fixture })
        #expect(result.reports.map { $0.subtotal?.requestCount } == [1, 1])
        #expect(result.subtotal?.requestCount == 1)
        #expect(result.subtotal?.costUSD == nil)
        #expect(result.subtotal?.unpricedRequestCount == 1)
        let json = try #require(CodexIdentifiedCollection.encodeJSON(result, pretty: false))
        let object = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let reports = try #require(object["reports"] as? [[String: Any]])
        #expect(reports.allSatisfy { $0["subtotal"] == nil })
        let local = try await CodexIdentifiedCollection.collect(
            remotes: [],
            startUnixMs: 0,
            endUnixMs: 1000,
            includeSourceSubtotals: true,
            local: { fixture },
            fetchRemote: { _ in throw CancellationError() })
        #expect(CodexIdentifiedCollection.window(days: 2, endUnixMs: 172_800_001) == 86_400_000)
        #expect(CodexIdentifiedCollection.window(days: 365, endUnixMs: 0) == nil)
        #expect(local.subtotal == nil)
        #expect(local.reports.first?.subtotal?.requestCount == 1)
        let exported = try #require(local.localLedgerJSON)
        let expected = try #require(CodexIdentifiedCollection.encodeJSON(fixture, pretty: false))
        let exportedObject = try #require(JSONSerialization.jsonObject(with: Data(exported.utf8)) as? NSDictionary)
        let expectedObject = try #require(JSONSerialization.jsonObject(with: Data(expected.utf8)) as? NSDictionary)
        #expect(exportedObject == expectedObject)
    }
}
