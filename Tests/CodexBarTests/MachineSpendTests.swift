import AppKit
import Foundation
import SwiftUI
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct MachineSpendTests {
    @Test
    func `shared host input commits with monitoring off and explains invalid aliases`() throws {
        let settings = testSettingsStore(suiteName: #function, userDefaults: InMemoryUserDefaults())
        settings.agentSessionsEnabled = false
        settings.agentSessionsRemoteEnabled = false
        let (window, hosting) = Self.hostEditor(settings: settings)
        defer { window.contentView = nil; window.close() }
        let field = try #require(Self.textFields(in: hosting).first { $0.isEditable })
        try #require(field.isEnabled, "Manual cost-host setup must not require automatic monitoring.")
        let guidance = try #require(RemoteCodexCostError.invalidHost.errorDescription)
        Self.submit("devbox", through: field)
        #expect(settings.agentSessionsManualHosts == "devbox")
        hosting.layoutSubtreeIfNeeded()
        #expect(!MenuLayoutScreenshotRenderTests.accessibilityText(hosting).contains(guidance))
        Self.submit("bad/path", through: field)
        try #require(settings.agentSessionsManualHosts == "bad/path", "The test must drive the real commit path.")
        hosting.layoutSubtreeIfNeeded()
        let deadline = Date().addingTimeInterval(1)
        var visible = MenuLayoutScreenshotRenderTests.accessibilityText(hosting)
        while !visible.contains(guidance), Date() < deadline {
            RunLoop.current.run(mode: .default, before: deadline)
            hosting.layoutSubtreeIfNeeded()
            visible = MenuLayoutScreenshotRenderTests.accessibilityText(hosting)
        }
        try #require(
            visible.contains(L("agent_sessions_hosts_title")),
            "The text traversal must find the real label: \(visible)")
        #expect(visible.contains(guidance), "Rejected input must show its existing actionable host-format guidance.")
    }

    private static func hostEditor(settings: SettingsStore) -> (NSWindow, NSView) {
        _ = NSApplication.shared
        let hosting = NSHostingView(rootView: AgentSessionHostsEditor(settings: settings)
            .environment(\.locale, Locale(identifier: "en_US"))
            .environment(\.accessibilityEnabled, true)
            .padding().frame(width: 640, height: 180))
        let window = NSWindow(
            contentRect: NSRect(x: -10000, y: -10000, width: 640, height: 180),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        return (window, hosting)
    }

    private static func textFields(in view: NSView) -> [NSTextField] {
        (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap { self.textFields(in: $0) }
    }

    private static func submit(_ text: String, through field: NSTextField) {
        field.stringValue = text
        field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
        field.sendAction(field.action, to: field.target)
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
        settings.costUsageHosts = ["B", "bad/path"]
        #expect(settings.selectableCostUsageHosts == ["A", "B"])
        #expect(settings.costUsageHosts == ["B"])
    }

    @Test
    func `manual runs receive hosts and UTC period and cancel or stop rejects late completion`() async {
        let pending = PendingMachineCollection()
        let controller = SpendDashboardController(
            userDefaults: InMemoryUserDefaults(),
            requestBuilder: { _ in
                SpendDashboardLoadRequest(
                    configuration: .init(costUsageEnabled: false, providerIDs: [], codexAccountIdentities: []),
                    capturedInputs: [],
                    unavailableSourceIDs: [],
                    codexRequests: [],
                    now: Date(timeIntervalSince1970: 172_800),
                    force: false)
            },
            machineLoader: { hosts, days, _, _ in await pending.load(hosts, days: days) },
            nowProvider: { Date(timeIntervalSince1970: 172_800) })
        controller.selectPeriod(.rolling(days: 2))
        let cancelledCompletion = AsyncStream<Void>.makeStream()
        MachineTaskCompletion.$token.withValue(MachineTaskCompletion.Token(cancelledCompletion.continuation)) {
            controller.runMachineSpend(hosts: ["selected"], eligible: true, localPartial: true)
        }
        while await pending.calls.isEmpty {
            await Task.yield()
        }
        #expect(await pending.calls.first?.0 == ["selected"])
        #expect(await pending.calls.first?.1 == 2)
        #expect(controller.machineWindow?.lowerBound == Date(timeIntervalSince1970: 86400))
        controller.cancelMachineSpend()
        await pending.finish()
        for await _ in cancelledCompletion.stream {}
        #expect(controller.machineResult == nil && !controller.machineRunning)
        controller.runMachineSpend(hosts: ["disabled"], eligible: false, localPartial: false)
        #expect(!controller.machineRunning && controller.machineWindow == nil)

        #expect(await pending.calls.count == 1)
        let stoppedCompletion = AsyncStream<Void>.makeStream()
        MachineTaskCompletion.$token.withValue(MachineTaskCompletion.Token(stoppedCompletion.continuation)) {
            controller.runMachineSpend(hosts: ["selected"], eligible: true, localPartial: true)
        }
        while await pending.calls.count < 2 {
            await Task.yield()
        }
        #expect(controller.machineRunning && controller.machineWindow != nil)
        controller.stop()
        #expect(!controller.machineRunning && controller.machineWindow == nil)
        await pending.finish()
        for await _ in stoppedCompletion.stream {}
        #expect(controller.machineResult == nil)
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
            reports: [.init(
                host: "local",
                source: "local",
                collectedAt: nil,
                ledger: nil,
                error: "Local native Codex identified usage is unavailable.")],
            subtotal: nil,
            allSourcesAvailable: false,
            partial: true))
        self.continuation = nil
    }
}

private enum MachineTaskCompletion {
    @TaskLocal static var token: Token?

    final class Token: Sendable {
        let continuation: AsyncStream<Void>.Continuation

        init(_ continuation: AsyncStream<Void>.Continuation) {
            self.continuation = continuation
        }

        deinit {
            self.continuation.finish()
        }
    }
}
