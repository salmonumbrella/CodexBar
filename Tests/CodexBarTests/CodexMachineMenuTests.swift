import Foundation
import Observation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct CodexMachineMenuTests {
    @Test
    func `menu has no amount without a session result or after UTC midnight`() {
        let captured = Date(timeIntervalSince1970: 1_728_000_001)
        #expect(SpendDashboardController.machineCostMenuLines(result: nil, localPartial: false, now: captured).isEmpty)
        let result = Self.result(cost: 4.2)
        #expect(SpendDashboardController.machineCostMenuLines(
            result: result, localPartial: false, now: Date(timeIntervalSince1970: 1_728_086_400)).isEmpty)
        let lines = SpendDashboardController.machineCostMenuLines(result: result, localPartial: false, now: captured)
        #expect(lines[0] == "Across machines · Codex identified only")
        #expect(lines[1] == "Today (UTC): $4.20 · 110 tokens")
        #expect(lines[2].contains("00:00 UTC · 1/2 sources"))
        #expect(lines[2].contains("Partial coverage"))
    }

    @Test(arguments: [nil, 0.0])
    func `menu distinguishes unknown prices from observed zero`(cost: Double?) {
        let lines = SpendDashboardController.machineCostMenuLines(
            result: Self.result(cost: cost), localPartial: false, now: Date(timeIntervalSince1970: 1_728_000_002))
        #expect(lines[1] == (cost == nil
                ? "Today (UTC): 110 tokens · Price unknown" : "Today (UTC): $0.00 · 110 tokens"))
    }

    private static func result(cost: Double?) -> CodexIdentifiedResult {
        var ledger = CodexRequestLedger(startUnixMs: 1_727_913_600_000, endUnixMs: 1_728_000_001_000)
        ledger.records = [.init(
            id: String(repeating: "a", count: 64),
            timestampUnixMs: 1_728_000_000_000,
            inputTokens: 100,
            cacheReadTokens: 0,
            outputTokens: 10,
            reasoningTokens: nil,
            model: "gpt-5",
            pricingMode: "standard")]
        let subtotal = CodexRequestSubtotal(
            totalTokens: 110,
            requestCount: 1,
            conflictCount: 0,
            excludedCount: 0,
            partial: false,
            costUSD: cost,
            unpricedRequestCount: cost == nil ? 1 : 0)
        return CodexIdentifiedResult(
            reports: [
                .init(host: "local", source: "local", collectedAt: nil, ledger: ledger, error: nil),
                .init(host: "offline", source: "ssh", collectedAt: nil, ledger: nil, error: "Unavailable"),
            ],
            subtotal: subtotal,
            allSourcesAvailable: false,
            partial: true,
            todaySubtotal: subtotal)
    }
}

extension CodexMachineMenuTests {
    @Test(arguments: [false, true])
    func `presentation and summary reads are passive and explicit detail collection owns result lifetime`(
        scopeChange: Bool) async
    {
        let calls = MachineMenuCollectionRecorder()
        let fixture = Self.result(cost: 4.2)
        let configuration = SpendDashboardConfiguration(
            costUsageEnabled: true, providerIDs: ["codex"], codexAccountIdentities: ["ambient|one"])
        let controller = SpendDashboardController(
            userDefaults: InMemoryUserDefaults(),
            requestBuilder: { _ in
                .init(
                    configuration: configuration,
                    capturedInputs: [],
                    unavailableSourceIDs: [],
                    codexRequests: [],
                    now: Date(timeIntervalSince1970: 1_728_000_100),
                    force: false)
            },
            machineLoader: { _, _, _, _ in try await calls.load(fixture) },
            nowProvider: { Date(timeIntervalSince1970: 1_728_000_100) })
        defer { controller.stop() }
        let settings = testSettingsStore(suiteName: #function, userDefaults: InMemoryUserDefaults())
        let store = UsageStore(
            fetcher: UsageFetcher(), browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        store.sharedSpendDashboardControllerStorage = controller
        let completed = LockIsolated(false)
        withObservationTracking {
            _ = store.menuObservationToken
        } onChange: { completed.setValue(true) }
        controller.update(configuration: configuration)
        for _ in 0..<5 {
            controller.revealMachineSpend()
            _ = controller.machineCostMenuLines()
        }
        #expect(controller.machineExpanded && controller.machineRevealRevision == 5)
        #expect(await calls.loadCount == 0)
        #expect(!completed.value)
        controller.runMachineSpend(hosts: ["offline"], eligible: true, localPartial: false)
        while controller.machineRunning {
            await Task.yield()
        }
        #expect(await calls.loadCount == 1)
        #expect(completed.value)
        let retained = controller.machineCostMenuLines()
        #expect(retained.last?.contains("00:00 UTC") == true)
        controller.runMachineSpend(hosts: ["offline"], eligible: true, localPartial: false)
        while controller.machineRunning {
            await Task.yield()
        }
        #expect(await calls.loadCount == 2)
        #expect(controller.machineCostMenuLines() == retained)
        let cleared = LockIsolated(false)
        withObservationTracking {
            _ = store.menuObservationToken
        } onChange: { cleared.setValue(true) }
        controller.update(configuration: .init(
            costUsageEnabled: scopeChange,
            providerIDs: scopeChange ? ["codex"] : [],
            codexAccountIdentities: scopeChange ? ["ambient|changed"] : []))
        #expect(controller.machineCostMenuLines().isEmpty)
        #expect(cleared.value)
        controller.cancelMachineSpend()
        #expect(controller.machineResult == nil)
        controller.runMachineSpend(hosts: [], eligible: false, localPartial: false)
        #expect(await calls.loadCount == 2)
    }
}

private actor MachineMenuCollectionRecorder {
    var loadCount = 0
    func load(_ result: CodexIdentifiedResult) throws -> CodexIdentifiedResult {
        self.loadCount += 1
        if self.loadCount > 1 { throw CancellationError() }
        return result
    }
}

extension CodexMachineMenuTests {
    @Test(arguments: [UsageProvider.codex, .claude, .pi], [false, true])
    func `machine action follows only the enabled Codex Cost surface`(provider: UsageProvider, enabled: Bool) {
        #expect(StatusItemController.showsMachineCostMenu(provider: provider, costSubmenuEnabled: enabled)
            == (provider == .codex && enabled))
    }

    @Test
    func `ordinary Cost lines place machine summary after local Today and before local history`() {
        let usage = UsageMenuCardView.Model.TokenUsageSection(
            sessionLine: "This Mac today",
            monthLine: "This Mac history",
            hintLine: nil,
            errorLine: nil,
            errorCopyText: nil)
        let machine = ["Across machines · Codex identified only", "Today (UTC): $4.20", "As of 00:00 UTC"]
        #expect(StatusItemController.costMenuVisibleDetailLines(
            provider: .codex, tokenUsage: usage, hasSubmenu: true, machineLines: machine)
            == ["This Mac today"] + machine + ["This Mac history"])
    }
}

extension CodexMachineMenuTests {
    @Test
    func `available machine usage needs no local history and wholly unavailable collection shows no amount`() {
        let now = Date(timeIntervalSince1970: 1_728_000_002)
        let lines = SpendDashboardController.machineCostMenuLines(
            result: Self.result(cost: 4.2), localPartial: false, now: now)
        #expect(StatusItemController.costMenuVisibleDetailLines(
            provider: .codex, tokenUsage: nil, hasSubmenu: false, machineLines: lines) == lines)
        let unavailable = CodexIdentifiedResult(
            reports: [.init(host: "local", source: "local", collectedAt: nil, ledger: nil, error: "Unavailable")],
            subtotal: nil,
            allSourcesAvailable: false,
            partial: true)
        #expect(SpendDashboardController.machineCostMenuLines(
            result: unavailable, localPartial: false, now: now).isEmpty)
    }
}
