import Foundation
import Testing
@testable import CodexBarCore

struct CodexMachineTodayTests {
    @Test
    func `today follows full conflict decisions and ignores yesterday unknown prices`() throws {
        let today: Int64 = 172_800_000
        func row(_ id: String, at: Int64, known: Bool = true) -> CodexRequestRecord {
            .init(
                id: String(repeating: id, count: 64),
                timestampUnixMs: at,
                inputTokens: 100,
                cacheReadTokens: 0,
                outputTokens: 10,
                reasoningTokens: nil,
                model: known ? "gpt-5" : nil,
                pricingMode: known ? "standard" : nil)
        }
        var local = CodexRequestLedger(startUnixMs: 86_400_000, endUnixMs: today + 1000)
        local.records = [row("a", at: today), row("b", at: today - 1, known: false), row("c", at: today)]
        var remote = local
        remote.records = [row("a", at: today), row("c", at: today - 1)]
        let subtotal = try CodexRequestLedger.merge(
            [local, remote],
            catalog: ModelsDevCatalog(providers: [:]),
            customPricing: .empty,
            recordWindow: today...(today + 1000))
        #expect(subtotal.requestCount == 1)
        #expect(subtotal.totalTokens == 110)
        #expect(subtotal.conflictCount == 1)
        #expect(subtotal.partial)
        #expect(subtotal.costUSD != nil)
    }
}

extension CodexMachineTodayTests {
    @Test(arguments: [false, true])
    func `today keeps unknown usage and observed zero`(known: Bool) throws {
        var ledger = CodexRequestLedger(startUnixMs: 172_800_000, endUnixMs: 172_801_000)
        ledger.records = [.init(
            id: String(repeating: "d", count: 64),
            timestampUnixMs: 172_800_000,
            inputTokens: 0,
            cacheReadTokens: 0,
            outputTokens: 0,
            reasoningTokens: nil,
            model: known ? "gpt-5" : nil,
            pricingMode: known ? "standard" : nil)]
        let subtotal = try CodexRequestLedger.merge(
            [ledger],
            catalog: ModelsDevCatalog(providers: [:]),
            customPricing: .empty,
            recordWindow: 172_800_000...172_801_000)
        #expect(subtotal.requestCount == 1)
        #expect(subtotal.totalTokens == 0)
        #expect(subtotal.costUSD == (known ? 0 : nil))
        #expect(subtotal.unpricedRequestCount == (known ? 0 : 1))
    }
}

extension CodexMachineTodayTests {
    @Test
    func `app today projection keeps missing source coverage and stays off the CLI wire`() async throws {
        var fixture = CodexRequestLedger(startUnixMs: 86_400_000, endUnixMs: 172_801_000)
        fixture.records = [.init(
            id: String(repeating: "e", count: 64),
            timestampUnixMs: 172_800_000,
            inputTokens: 100,
            cacheReadTokens: 0,
            outputTokens: 10,
            reasoningTokens: nil,
            model: "gpt-5",
            pricingMode: "standard")]
        let ledger = fixture
        let app = try await CodexIdentifiedCollection.collect(
            remotes: ["copy", "missing"],
            startUnixMs: ledger.startUnixMs,
            endUnixMs: ledger.endUnixMs,
            includeSourceSubtotals: true,
            local: { ledger },
            fetchRemote: { host in
                if host == "missing" { throw RemoteCodexCostError.unavailable }
                return ledger
            })
        #expect(app.todaySubtotal?.requestCount == 1)
        #expect(app.todaySubtotal?.totalTokens == 110)
        #expect(app.partial && !app.allSourcesAvailable)
        #expect(app.reports.filter { $0.ledger != nil }.count == 2)
        let encoded = try #require(CodexIdentifiedCollection.encodeJSON(app, pretty: false))
        #expect(!encoded.contains("todaySubtotal"))
        let cli = try await CodexIdentifiedCollection.collect(
            remotes: [],
            startUnixMs: ledger.startUnixMs,
            endUnixMs: ledger.endUnixMs,
            local: { ledger },
            fetchRemote: { _ in ledger })
        #expect(cli.todaySubtotal == nil)
        #expect(cli.subtotal == nil && cli.reports.first?.subtotal == nil)
    }
}
