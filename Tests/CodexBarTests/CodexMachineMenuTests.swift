import AppKit
import Foundation
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
        #expect(lines[0] == "Across machines · Codex identified requests")
        #expect(lines[1] == "Today (UTC): $4.20 · 110 tokens")
        #expect(lines[2].contains("00:00 UTC · 1/2 sources"))
        #expect(lines[2].contains("Partial data"))
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
    @Test(CodexCredentialFixtures(), arguments: ["timezone", "auth"])
    func `presentation stays passive and display configuration keeps the UTC result`(change: String) async throws {
        let calls = MachineMenuCollectionRecorder()
        let fixture = Self.result(cost: 4.2)
        let home = CodexCredentialFixtures.root.appendingPathComponent("codex", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        func configuration(_ zone: String) -> SpendDashboardConfiguration {
            let source = SpendDashboardSource.codexSource(
                account: nil,
                homePath: home.path,
                providerName: "Codex",
                index: 0,
                count: 1,
                bucketTimeZoneIdentifier: zone)
            return .init(
                costUsageEnabled: true,
                providerIDs: ["codex"],
                codexAccountIdentities: [source.identity],
                bucketTimeZoneIdentifier: zone)
        }
        let initial = configuration("UTC")
        let controller = SpendDashboardController(
            userDefaults: InMemoryUserDefaults(),
            requestBuilder: { _ in
                .init(
                    configuration: initial,
                    capturedInputs: [],
                    unavailableSourceIDs: [],
                    codexRequests: [],
                    now: Date(timeIntervalSince1970: 1_728_000_100),
                    force: false)
            },
            machineLoader: { _, _, _, _ in await calls.load(fixture) },
            nowProvider: { Date(timeIntervalSince1970: 1_728_000_100) })
        defer { controller.stop() }
        controller.update(configuration: initial)
        for _ in 0..<5 {
            controller.revealMachineSpend()
            _ = controller.machineCostMenuLines()
        }
        #expect(controller.machineExpanded && controller.machineRevealRevision == 5)
        #expect(await calls.loadCount == 0)
        controller.runMachineSpend(hosts: ["offline"], eligible: true, localPartial: false)
        while controller.machineRunning {
            await Task.yield()
        }
        #expect(await calls.loadCount == 1)
        #expect(controller.machineCostMenuLines().last?.contains("00:00 UTC") == true)
        if change == "auth" {
            try Data("synthetic-auth-revision".utf8).write(to: home.appendingPathComponent("auth.json"))
        }
        let changed = configuration(change == "timezone" ? "America/Vancouver" : "UTC")
        #expect(changed.codexAccountIdentities != initial.codexAccountIdentities)
        let lines = controller.machineCostMenuLines()
        controller.update(configuration: changed)
        #expect(controller.machineCostMenuLines() == lines)
        controller.cancelMachineSpend()
        #expect(controller.machineResult == nil)
        controller.runMachineSpend(hosts: [], eligible: false, localPartial: false)
        #expect(await calls.loadCount == 1)
    }
}

private actor MachineMenuCollectionRecorder {
    var loadCount = 0
    func load(_ result: CodexIdentifiedResult) -> CodexIdentifiedResult {
        self.loadCount += 1
        return result
    }
}

extension CodexMachineMenuTests {
    @Test
    func `local Cost lines keep their scope separate from machine usage`() {
        let usage = UsageMenuCardView.Model.TokenUsageSection(
            sessionLine: "This Mac today",
            monthLine: "This Mac history",
            hintLine: nil,
            errorLine: nil,
            errorCopyText: nil)
        #expect(StatusItemController.costMenuVisibleDetailLines(
            provider: .codex, tokenUsage: usage, hasSubmenu: false)
            == ["This Mac today", "This Mac history"])
        #expect(StatusItemController.costMenuTooltipLines(
            provider: .codex, tokenUsage: usage) == ["This Mac today", "This Mac history"])
        #expect(StatusItemController.costMenuVisibleDetailLines(
            provider: .codex, tokenUsage: usage, hasSubmenu: true).isEmpty)
    }
}

extension CodexMachineMenuTests {
    @Test
    func `available machine usage needs no local history and wholly unavailable collection shows no amount`() {
        let now = Date(timeIntervalSince1970: 1_728_000_002)
        #expect(StatusItemController.costMenuVisibleDetailLines(
            provider: .codex, tokenUsage: nil, hasSubmenu: false).isEmpty)
        let unavailable = CodexIdentifiedResult(
            reports: [.init(host: "local", source: "local", collectedAt: nil, ledger: nil, error: "Unavailable")],
            subtotal: nil,
            allSourcesAvailable: false,
            partial: true)
        #expect(SpendDashboardController.machineCostMenuLines(
            result: unavailable, localPartial: false, now: now).isEmpty)
    }
}

extension CodexMachineMenuTests {
    @Test(CodexCredentialFixtures())
    func `disabled Codex hides the machine action and rejects an action built before disabling`() throws {
        let fixture = try MachineMenuFixture()
        defer { fixture.stop() }
        let model = try #require(fixture.controller.menuCardModel(for: .codex))
        let menu = NSMenu()
        fixture.controller.addCostMenuItems(to: menu, model: model, submenu: nil, width: 350)
        let action = try #require(menu.items.first { $0.action != nil })
        enableTestProviders([], settings: fixture.settings)
        #expect(!fixture.controller.showsMachineCostMenu(for: .codex))
        var opened = false
        fixture.controller.settingsOpenHandler = { _ in opened = true }
        _ = fixture.controller.perform(action.action)
        #expect(!opened)
        #expect(!fixture.dashboard.machineExpanded)
        #expect(!fixture.dashboard.machineRunning)
        let disabledMenu = NSMenu()
        fixture.controller.addMachineCostMenuItems(to: disabledMenu, provider: .codex, width: 350)
        #expect(disabledMenu.items.isEmpty)
        enableTestProviders([.codex], settings: fixture.settings)
        #expect(!fixture.dashboard.machineExpanded)
        fixture.settings.costSummaryDisplayStyle = .inlineSummary
        #expect(!fixture.controller.showsMachineCostMenu(for: .codex))
        fixture.settings.costSummaryDisplayStyle = .both
        fixture.settings.costUsageEnabled = false
        #expect(!fixture.controller.showsMachineCostMenu(for: .codex))
        #expect(!fixture.controller.showsMachineCostMenu(for: .claude))
    }

    @Test(CodexCredentialFixtures(), arguments: ["merged", "sectioned", "stacked"])
    func `machine row follows local content once in every layout`(layout: String) async throws {
        let fixture = try MachineMenuFixture(result: Self.result(cost: 4.2))
        defer { fixture.stop() }
        fixture.dashboard.runMachineSpend(hosts: ["offline"], eligible: true, localPartial: false)
        while fixture.dashboard.machineRunning {
            await Task.yield()
        }
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Local content", action: nil, keyEquivalent: ""))
        switch layout {
        case "merged":
            fixture.controller.addMachineCostMenuItems(to: menu, provider: .codex, width: 350)
        case "sectioned":
            try fixture.controller.addCostMenuItems(
                to: menu, model: #require(fixture.controller.menuCardModel(for: .codex)), submenu: nil, width: 350)
        default:
            fixture.controller.addAccountAgnosticCostMenuSection(to: menu, context: .init(
                currentProvider: .codex,
                selectedProvider: .codex,
                menuWidth: 350,
                codexAccountDisplay: nil,
                tokenAccountDisplay: nil,
                openAIContext: .init(
                    hasUsageBreakdown: false,
                    hasCreditsHistory: false,
                    hasCostHistory: false,
                    canShowBuyCredits: false,
                    hasOpenAIWebMenuItems: false)))
        }
        let rows = menu.items.filter { $0.representedObject as? String == "menuCardMachineCost" }
        let row = try #require(rows.first)
        #expect(rows.count == 1)
        #expect(row.title == "Across machines")
        #expect(row.toolTip?.contains("Today (UTC): $4.20 · 110 tokens") == true)
        #expect(menu.items.first?.title == "Local content")
        #expect(menu.items.filter { $0.title == "By machine…" }.count == 1)
        let actionIndex = try #require(menu.items.firstIndex { $0.title == "By machine…" })
        #expect(try #require(menu.items.firstIndex(of: row)) < actionIndex)
        #expect(!fixture.dashboard.machineExpanded)
    }
}

extension CodexMachineMenuTests {
    @Test(CodexCredentialFixtures(), arguments: ["arrival", "rollover"])
    func `cached Codex tab validates the current manual machine projection`(change: String) async throws {
        let clock = LockIsolated(Date(timeIntervalSince1970: 1_728_000_100))
        let fixture = try MachineMenuFixture(result: Self.result(cost: 4.2), now: { clock.value })
        defer { fixture.stop() }
        if change == "rollover" {
            fixture.dashboard.runMachineSpend(hosts: [], eligible: true, localPartial: false)
            while fixture.dashboard.machineRunning {
                await Task.yield()
            }
        }
        let menu = NSMenu()
        let content = NSMenu()
        fixture.controller.addMachineCostMenuItems(to: content, provider: .codex, width: 350)
        #expect(content.items.contains { $0.representedObject as? String == "menuCardMachineCost" }
            == (change == "rollover"))
        fixture.controller.lastMenuLocalizationSignature = fixture.controller.menuLocalizationSignature()
        fixture.controller.cacheMergedSwitcherContent(
            content.items,
            in: menu,
            selection: .provider(.codex),
            context: .init(menuWidth: 350, codexAccountDisplay: nil, tokenAccountDisplay: nil, contentVersion: nil))
        #expect(fixture.controller.reusableMergedSwitcherContent(
            for: .provider(.codex),
            in: menu,
            menuWidth: 350,
            codexAccountDisplay: nil,
            tokenAccountDisplay: nil) != nil)
        if change == "arrival" {
            fixture.dashboard.runMachineSpend(hosts: [], eligible: true, localPartial: false)
            while fixture.dashboard.machineRunning {
                await Task.yield()
            }
        } else {
            clock.setValue(Date(timeIntervalSince1970: 1_728_086_400))
        }
        #expect(fixture.dashboard.machineCostMenuLines().isEmpty == (change == "rollover"))
        #expect(fixture.controller.reusableMergedSwitcherContent(
            for: .provider(.codex),
            in: menu,
            menuWidth: 350,
            codexAccountDisplay: nil,
            tokenAccountDisplay: nil) == nil)
        #expect(!fixture.dashboard.machineRunning)
    }
}

@MainActor
private struct MachineMenuFixture {
    let settings: SettingsStore
    let store: UsageStore
    let dashboard: SpendDashboardController
    let controller: StatusItemController

    init(
        result: CodexIdentifiedResult? = nil,
        now: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: 1_728_000_100) }) throws
    {
        let root = CodexCredentialFixtures.root
        let environment = [
            "HOME": root.path,
            "CODEX_HOME": root.appendingPathComponent("codex").path,
            "CLAUDE_CONFIG_DIR": root.appendingPathComponent("claude").path,
        ]
        let settings = testSettingsStore(
            suiteName: #function, userDefaults: InMemoryUserDefaults(), config: testConfigWithAllProvidersDisabled())
        settings._test_codexAccountSnapshotLoader = { source in
            .init(
                storedAccounts: [],
                activeStoredAccount: nil,
                liveSystemAccount: nil,
                matchingStoredAccountForLiveSystemAccount: nil,
                activeSource: source,
                hasUnreadableAddedAccountStore: false)
        }
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.costUsageEnabled = true
        settings.costSummaryDisplayStyle = .both
        enableTestProviders([.codex], settings: settings)
        let store = UsageStore(
            fetcher: UsageFetcher(environment: environment),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: environment)
        let dashboard = SpendDashboardController(
            userDefaults: InMemoryUserDefaults(),
            requestBuilder: { _ in .init(
                configuration: .init(costUsageEnabled: false, providerIDs: [], codexAccountIdentities: []),
                capturedInputs: [],
                unavailableSourceIDs: [],
                codexRequests: [],
                now: Date(timeIntervalSince1970: 1_728_000_100),
                force: false) },
            machineLoader: { _, _, _, _ in
                guard let result else { throw CancellationError() }
                return result
            },
            nowProvider: now)
        store.sharedSpendDashboardControllerStorage = dashboard
        self.settings = settings
        self.store = store
        self.dashboard = dashboard
        self.controller = StatusItemController(
            store: store,
            settings: settings,
            account: AccountInfo(email: nil, plan: nil),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: MachineMenuStatusBar(),
            menuCardRenderingEnabled: false,
            menuRefreshEnabled: false,
            observeProviderConfigNotifications: false)
    }

    func stop() {
        self.controller.releaseStatusItemsForTesting()
        self.dashboard.stop()
        self.settings.configFileWatcher?.stop()
    }
}

private final class MachineMenuStatusBar: NSStatusBar {
    override func statusItem(withLength _: CGFloat) -> NSStatusItem { MachineMenuStatusItem() }
    override func removeStatusItem(_: NSStatusItem) {}
}

private final class MachineMenuStatusItem: NSStatusItem {
    private var storedMenu: NSMenu?
    override var menu: NSMenu? {
        get { self.storedMenu }
        set { self.storedMenu = newValue }
    }

    override var autosaveName: String! {
        get { "synthetic-machine-menu" }
        set {}
    }

    override var isVisible: Bool {
        get { false }
        set {}
    }

    override var length: CGFloat {
        get { 0 }
        set {}
    }

    override var button: NSStatusBarButton? {
        nil
    }
}
