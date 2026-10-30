import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct MachineSpendTests {
    @Test
    func `editing a prefix preserves retained consent until the host list is committed`() {
        let defaults = InMemoryUserDefaults()
        let settings = testSettingsStore(suiteName: #function, userDefaults: defaults)
        settings.agentSessionsManualHosts = "devbox"
        settings.costUsageHosts = ["devbox"]
        var draft = AgentSessionHostsDraft(settings: settings)
        draft.text = "gdevbox"
        #expect(settings.agentSessionsManualHosts == "devbox")
        #expect(settings.costUsageHosts == ["devbox"])
        draft.text = "gpu, devbox"
        draft.commit(to: settings)
        #expect(settings.agentSessionsManualHosts == "gpu, devbox")
        #expect(settings.costUsageHosts == ["devbox"])
    }

    @Test
    func `removing and readding shared host revokes consent across reload`() {
        let defaults = InMemoryUserDefaults()
        let settings = testSettingsStore(suiteName: #function, userDefaults: defaults)
        settings.agentSessionsManualHosts = "A, B"
        settings.costUsageHosts = ["A", "B"]
        settings.agentSessionsManualHosts = "B"
        settings.agentSessionsManualHosts = "A, B"
        #expect(settings.costUsageHosts == ["B"])
        #expect(testSettingsStore(suiteName: #function, userDefaults: defaults).costUsageHosts == ["B"])
        settings.agentSessionsManualHosts = "A, B, bad/path"
        defaults.set(["B", "stale", "bad/path"], forKey: "costUsageHosts")
        let reloaded = testSettingsStore(suiteName: #function, userDefaults: defaults)
        #expect(reloaded.costUsageHosts == ["B"])
    }

    @Test
    func `manual runs capture hosts and UTC period and cancelled completion never publishes`() async {
        let pending = PendingMachineCollection()
        let controller = SpendDashboardController(
            userDefaults: InMemoryUserDefaults(),
            requestBuilder: { _ in preconditionFailure("Dashboard should not run") },
            machineLoader: { hosts, days, _, _ in await pending.load(hosts, days: days) },
            nowProvider: { Date(timeIntervalSince1970: 172_800) })
        controller.selectPeriod(.rolling(days: 2))
        controller.refreshDateWindow()
        #expect(await pending.calls.isEmpty)
        controller.runMachineSpend(hosts: ["selected"], eligible: true, localPartial: true)
        while await pending.calls.isEmpty {
            await Task.yield()
        }
        #expect(await pending.calls.first?.0 == ["selected"])
        #expect(await pending.calls.first?.1 == 2)
        #expect(controller.machineWindow?.lowerBound == Date(timeIntervalSince1970: 86400))
        controller.cancelMachineSpend()
        await pending.finish()
        for _ in 0..<10 {
            await Task.yield()
        }
        #expect(controller.machineResult == nil && !controller.machineRunning)
        controller.runMachineSpend(hosts: ["disabled"], eligible: false, localPartial: false)
        #expect(await pending.calls.count == 1)
        controller.stop()
        #expect(controller.machineWindow == nil)
    }
}

private actor PendingMachineCollection {
    var calls: [([String], Int)] = []
    var continuation: CheckedContinuation<CodexIdentifiedResult, Never>?
    func load(_ hosts: [String], days: Int) async -> CodexIdentifiedResult {
        self.calls.append((hosts, days))
        return await withCheckedContinuation { self.continuation = $0 }
    }

    func finish() {
        self.continuation?.resume(returning: CodexIdentifiedResult(
            reports: [], subtotal: nil, allSourcesAvailable: false, partial: true))
        self.continuation = nil
    }
}
