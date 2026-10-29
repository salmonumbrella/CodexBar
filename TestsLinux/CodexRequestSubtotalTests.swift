import Commander
import Foundation
import Testing
@testable import CodexBarCLI
@testable import CodexBarCore

struct CodexRequestSubtotalTests {
    private static let start: Int64 = 1_788_134_400_000
    private static let end: Int64 = 1_788_177_600_000

    private static func ledger(input: Int = 100, id: String = "a", output: Int = 10) -> CodexRequestLedger {
        CodexRequestLedger(
            startUnixMs: self.start,
            endUnixMs: self.end,
            records: [.init(
                id: String(repeating: id, count: 64),
                timestampUnixMs: self.end,
                inputTokens: input,
                cacheReadTokens: 20,
                outputTokens: output,
                reasoningTokens: min(3, output))])
    }

    @Test
    func `SSH alias local retains explicit remote provenance`() async throws {
        let ledger = Self.ledger()
        let report = try await CodexBarCLI.collectCodexIdentifiedUsage(
            remotes: ["local"],
            startUnixMs: Self.start,
            endUnixMs: Self.end,
            local: { ledger },
            fetchRemote: { _ in ledger })
        let wire = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any])
        let rows = try #require(wire["reports"] as? [[String: Any]])
        #expect(rows.map { $0["source"] as? String } == ["local", "ssh"])
        #expect(rows.allSatisfy { $0["collectedAt"] != nil })
    }

    @Test(arguments: [
        [0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0],
    ])
    func `all source permutations preserve copied and quarantined identities`(order: [Int]) async throws {
        let original = Self.ledger()
        var conflict = Self.ledger(input: 101)
        conflict.records += Self.ledger(id: "b").records
        let sources = [original, conflict, original]
        let result = try await CodexBarCLI.collectCodexIdentifiedUsage(
            remotes: ["0", "1", "2"],
            startUnixMs: Self.start,
            endUnixMs: Self.end,
            local: { CodexRequestLedger(
                startUnixMs: Self.start,
                endUnixMs: Self.end) },
            fetchRemote: { sources[order[Int($0)!]] })
        #expect(result.allSourcesAvailable)
        #expect(result.partial)
        #expect(result.subtotal?.totalTokens == 110)
        #expect(result.subtotal?.requestCount == 1)
        #expect(result.subtotal?.conflictCount == 1)
        let strict = try CodexRequestLedger.merge(order.map { sources[$0] })
        #expect(strict.totalTokens == result.subtotal?.totalTokens)
        #expect(strict.conflictCount == result.subtotal?.conflictCount)
    }

    @Test(arguments: ["unavailable", "schema", "window", "overflow"])
    func `a rejected middle source rolls back its union and later hosts still contribute`(failure: String)
        async throws
    {
        let local = Self.ledger()
        let other = Self.ledger(id: "c")
        var rejected = Self.ledger(input: Int.max - 100, id: "b", output: 0)
        rejected.conflictingIDs = local.records.map(\.id)
        rejected.excludedCount = 5
        rejected.partial = true
        if failure == "schema" { rejected.schemaVersion = 2 }
        if failure == "window" { rejected.endUnixMs += 1 }
        let invalid = rejected
        let stamp = Date(timeIntervalSince1970: 1234)
        let result = try await CodexBarCLI.collectCodexIdentifiedUsage(
            remotes: ["first", "bad", "last", "last"],
            startUnixMs: Self.start,
            endUnixMs: Self.end,
            now: { stamp },
            local: { local },
            fetchRemote: { host in
                if host == "bad" {
                    if failure == "unavailable" { throw CocoaError(.fileReadNoPermission) }
                    return invalid
                }
                return host == "first" ? other : local
            })
        #expect(result.reports.map(\.host) == ["local", "first", "bad", "last", "last"])
        #expect(result.reports.map(\.source) == ["local", "ssh", "ssh", "ssh", "ssh"])
        #expect(result.reports.map(\.collectedAt) == [stamp, stamp, nil, stamp, stamp])
        #expect(result.reports[2].error != nil)
        #expect(result.reports[2].ledger == nil)
        #expect(result.subtotal?.totalTokens == 220)
        #expect(result.subtotal?.conflictCount == 0)
        #expect(result.subtotal?.excludedCount == 0)
        #expect(result.subtotal?.partial == false)
        #expect(!result.allSourcesAvailable && result.partial)
    }

    @Test(arguments: ["remote", "none", "empty", "partial"])
    func `availability is separate from an empty or partial accepted subtotal`(state: String) async throws {
        var ledger = Self.ledger()
        if state == "empty" { ledger.records = [] }
        ledger.partial = state == "partial"
        let source = ledger
        let result = try await CodexBarCLI.collectCodexIdentifiedUsage(
            remotes: ["host"],
            startUnixMs: Self.start,
            endUnixMs: Self.end,
            local: {
                if state == "remote" || state == "none" { throw RemoteCodexCostError.unavailable }
                return source
            },
            fetchRemote: { _ in
                if state == "none" { throw RemoteCodexCostError.unavailable }
                return source
            })
        #expect(result.allSourcesAvailable == (state == "empty" || state == "partial"))
        #expect(result.partial == (state != "empty"))
        #expect(result.subtotal?.totalTokens == (state == "none" ? nil : (state == "empty" ? 0 : 110)))
        if state == "none" {
            let wire = try #require(
                JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as? [String: Any])
            #expect(wire["subtotal"] == nil)
            #expect(result.reports.allSatisfy { $0.collectedAt == nil && $0.error != nil })
        }
    }

    @Test
    func `strict merge allows a later conflict to remove intermediate overflow`() throws {
        let local = Self.ledger()
        let huge = Self.ledger(input: Int.max - 100, id: "b", output: 0)
        var conflict = huge
        conflict.conflictingIDs = huge.records.map(\.id)
        let subtotal = try CodexRequestLedger.merge([local, huge, conflict])
        #expect(subtotal.totalTokens == 110)
        #expect(subtotal.conflictCount == 1)
    }

    @Test
    func `cancellation after a source returns prevents the next SSH fetch`() async {
        let task = Task {
            try await CodexBarCLI.collectCodexIdentifiedUsage(
                remotes: ["first", "never"],
                startUnixMs: Self.start,
                endUnixMs: Self.end,
                local: { Self.ledger() },
                fetchRemote: { host in
                    #expect(host == "first")
                    withUnsafeCurrentTask { $0?.cancel() }
                    return Self.ledger()
                })
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test
    func `real cost parser preserves every repeated remote in argument order`() throws {
        let parsed = try Program(descriptors: CodexBarCLI.commandDescriptors()).resolve(argv: [
            "cost", "--provider", "codex", "--identified-only", "--format", "json",
            "--remote", "one", "--remote", "local", "--remote", "one",
        ]).parsedValues
        #expect(parsed.options["remote"] == ["one", "local", "one"])
        #expect(parsed.flags.contains("identifiedOnly"))
    }

    @Test(arguments: [1, 2])
    func `overflowing remote usage retains the valid local subtotal`(remoteRequests: Int) async throws {
        let local = Self.ledger()
        var remote = local
        remote.records = ["b", "c"].prefix(remoteRequests).map { character in .init(
            id: String(repeating: character, count: 64),
            timestampUnixMs: Self.end,
            inputTokens: remoteRequests == 1 ? Int.max - 109 : Int.max / 2 + 1,
            cacheReadTokens: 0,
            outputTokens: 0,
            reasoningTokens: nil) }
        let report = try await CodexBarCLI.collectCodexIdentifiedUsage(
            remotes: ["fixture-host"],
            startUnixMs: Self.start,
            endUnixMs: Self.end,
            local: { local },
            fetchRemote: { [remote] _ in remote })
        #expect(report.subtotal?.totalTokens == 110)
        #expect(report.reports[1].ledger == nil)
        #expect(!report.allSourcesAvailable && report.partial)
    }

    @Test
    func `foreign legacy usage does not make Codex coverage partial`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let content = """
        {"type":"session_meta","payload":{"id":"fixture-session"}}
        {"type":"event_msg","timestamp":"2026-08-31T12:00:00Z","payload":{"type":"token_count",\
        "info":{"model":"kimi-coding/k2p5","total_token_usage":{"input_tokens":100,"output_tokens":10}}}}

        """
        try Data(content.utf8).write(to: root.appendingPathComponent("foreign.jsonl"))
        var options = CostUsageScanner.Options()
        options.codexSessionsRoot = root
        let ledger = try CodexRequestLedger.load(
            startUnixMs: Self.start, endUnixMs: Self.end, options: options, checkCancellation: {})
        #expect(ledger.excludedCount == 0)
        #expect(!ledger.partial)
    }

    @Test
    func `a vanished file marks discovered history partial instead of unavailable`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let vanished = root.appendingPathComponent("vanished.jsonl")
        try Data().write(to: vanished)
        let content = """
        {"type":"session_meta","payload":{"id":"fixture-session"}}
        {"type":"token_usage_record","timestamp":"2026-08-31T12:00:00Z","payload":{\
        "thread_id":"fixture-session","response_id":"fixture-response","model":"gpt-5",\
        "usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":10},\
        "thread_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":10}}}

        """
        try Data(content.utf8).write(to: root.appendingPathComponent("available.jsonl"))
        var options = CostUsageScanner.Options()
        options.codexSessionsRoot = root
        var checks = 0
        let ledger = try CodexRequestLedger.load(
            startUnixMs: Self.start, endUnixMs: Self.end, options: options, checkCancellation: {
                checks += 1
                // Remove an inventoried file before scanning the two-file source.
                if checks == 4 { try FileManager.default.removeItem(at: vanished) }
            })
        #expect(ledger.partial)
        #expect(try CodexRequestLedger.merge([ledger]).totalTokens == 110)
    }

    @Test
    func `scan snapshots refresh Foundation metadata after a file changes`() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("a".utf8).write(to: file)
        #expect(try CodexRequestLedger.fileMetadata(file).fileSize == 1)
        _ = try file.resourceValues(forKeys: [.fileSizeKey])
        try Data("abcdefgh".utf8).write(to: file)
        #expect(try CodexRequestLedger.fileMetadata(file).fileSize == 8)
    }

    @Test
    func `copied requests count once and conflicting copies stay excluded in every source order`() throws {
        let original = Self.ledger()
        let copied = try CodexRequestLedger.merge([original, original])
        #expect(copied.totalTokens == 110)
        #expect(copied.requestCount == 1)
        let different = Self.ledger(input: 101)
        for sources in [
            [original, different, original],
            [different, original, original],
            [original, original, different],
        ] {
            let result = try CodexRequestLedger.merge(sources)
            #expect(result.totalTokens == 0)
            #expect(result.conflictCount == 1)
            #expect(result.partial)
        }
        var quarantined = original
        quarantined.conflictingIDs = original.records.map(\.id)
        #expect(try CodexRequestLedger.merge([quarantined, original]).requestCount == 0)
        let wire = try JSONSerialization.jsonObject(with: JSONEncoder().encode(copied)) as? [String: Any]
        #expect(wire?["costUSD"] is NSNull)
    }

    @Test(arguments: ["schema", "provider", "window", "digest", "cached", "reasoning", "overflow", "sum"])
    func `invalid source contracts and overflowing subtotals are rejected`(invalid: String) throws {
        var source = Self.ledger()
        switch invalid {
        case "schema": source.schemaVersion = 2
        case "provider": source.provider = "claude"
        case "window": source.endUnixMs += 1
        case "digest": source.conflictingIDs = ["raw-session-id"]
        case "cached": source = Self.ledger(input: 19)
        case "reasoning": source.records = [.init(
                id: source.records[0].id,
                timestampUnixMs: Self.end,
                inputTokens: 100,
                cacheReadTokens: 20,
                outputTokens: 2,
                reasoningTokens: 3)]
        default:
            source.records = ["a", "b"].map { character in .init(
                id: String(repeating: character, count: 64),
                timestampUnixMs: Self.end,
                inputTokens: Int.max - 1,
                cacheReadTokens: 0,
                outputTokens: invalid == "overflow" ? 2 : 0,
                reasoningTokens: nil) }
        }
        #expect(throws: RemoteCodexCostError.self) {
            try source.validate(startUnixMs: Self.start, endUnixMs: Self.end)
            _ = try CodexRequestLedger.merge([source])
        }
    }

    @Test(arguments: ["same", "contradiction", "invalid", "future-invalid", "reasoning"])
    func `native copies resumes exact UTC bounds and unidentified rows use the real parser`(variant: String)
        throws
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var options = CostUsageScanner.Options()
        options.codexSessionsRoot = root
        let metadata = #"{"type":"session_meta","payload":{"id":"fixture-session"}}"#
        func request(
            _ response: String,
            input: Int = 100,
            reasoning: Int = 3,
            timestamp: String = "2026-08-31T12:00:00Z") -> String
        {
            """
            {"type":"token_usage_record","timestamp":"\(timestamp)","payload":{\
            "thread_id":"fixture-session","response_id":"\(response)","model":"gpt-5",\
            "usage":{"input_tokens":\(input),"cached_input_tokens":20,"output_tokens":10,\
            "reasoning_output_tokens":\(reasoning)},\
            "thread_token_usage":{"input_tokens":1000,"cached_input_tokens":20,"output_tokens":100,\
            "reasoning_output_tokens":10}}}
            """
        }
        let original = metadata + "\n" + request("copied") + "\n"
        try Data(original.utf8).write(to: root.appendingPathComponent("original.jsonl"))
        let contradiction = ["contradiction", "invalid", "reasoning"].contains(variant)
        let resumed = request(
            "copied",
            input: variant == "contradiction" ? 101 : (variant == "invalid" ? 19 : 100),
            reasoning: variant == "reasoning" ? 4 : 3,
            timestamp: "2026-08-31T11:00:00Z")
        let resume = original + resumed + "\n"
            + request("new", timestamp: "2026-08-31T00:00:00Z") + "\n"
            + request("exact-end", timestamp: "2026-08-31T12:00:00.003Z") + "\n"
            + request(
                "copied",
                input: variant == "future-invalid" ? 19 : 102,
                timestamp: "2026-08-31T12:00:00.004Z") + "\n"
            + request("before", timestamp: "2026-08-30T23:59:59.999Z") + "\n"
        try Data(resume.utf8).write(to: root.appendingPathComponent("resumed.jsonl"))
        let fork = #"{"type":"session_meta","payload":{"id":"fixture-child","forked_from_id":"fixture-session","#
            + #""timestamp":"2026-08-31T12:00:00Z"}}"#
            + "\n" + request("copied", input: 103) + "\n"
        try Data(fork.utf8).write(to: root.appendingPathComponent("fork.jsonl"))
        let legacy = metadata + "\n" +
            #"{"type":"event_msg","timestamp":"2026-08-31T12:00:00Z","payload":{"type":"token_count","# +
            #""info":{"model":"gpt-5","total_token_usage":{"input_tokens":100,"output_tokens":10}}}}"# +
            "\n"
        try Data(legacy.utf8).write(to: root.appendingPathComponent("legacy.jsonl"))
        let ledger = try CodexRequestLedger.load(
            startUnixMs: Self.start, endUnixMs: Self.end + 3, options: options, checkCancellation: {})
        let subtotal = try CodexRequestLedger.merge([ledger, ledger])
        #expect(subtotal.totalTokens == (contradiction ? 220 : 330))
        #expect(subtotal.requestCount == (contradiction ? 2 : 3))
        #expect(ledger.excludedCount > 0)
        let wire = try #require(String(bytes: JSONEncoder().encode(ledger), encoding: .utf8))
        #expect(!wire.contains("fixture-session"))
        #expect(!wire.contains("gpt-5"))
        #expect(!wire.contains(root.path))
    }

    @Test(arguments: ["missing", "empty", "truncated", "malformed", "oversized"])
    func `missing native histories are unavailable while damaged histories are partial`(state: String) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var options = CostUsageScanner.Options()
        options.codexSessionsRoot = root
        defer { try? FileManager.default.removeItem(at: root) }
        if state != "missing" {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            if state != "empty" {
                let content = state == "oversized" ? String(repeating: "x", count: 256 * 1024 + 1) + "\n"
                    : (state == "malformed" ? "{broken}\n" : "{\"type\":\"token_usage_record\"")
                try Data(content.utf8).write(to: root.appendingPathComponent("damaged.jsonl"))
            }
        }
        if state == "missing" {
            #expect(throws: RemoteCodexCostError.self) {
                _ = try CodexRequestLedger.load(
                    startUnixMs: Self.start, endUnixMs: Self.end, options: options, checkCancellation: {})
            }
        } else {
            let ledger = try CodexRequestLedger.load(
                startUnixMs: Self.start, endUnixMs: Self.end, options: options, checkCancellation: {})
            #expect(ledger.records.isEmpty)
            #expect(ledger.partial == (state != "empty"))
        }
    }

    @Test
    func `SSH export pins the same window and source failures retain an explicit partial subtotal`() async throws {
        let ledger = Self.ledger()
        let wire = try #require(String(bytes: JSONEncoder().encode(ledger), encoding: .utf8))
        let fetcher = RemoteCodexCostFetcher { arguments, environment in
            #expect(arguments.contains("StrictHostKeyChecking=yes"))
            #expect(arguments.contains("ForwardAgent=no"))
            #expect(arguments.contains("-n"))
            #expect(arguments.last?.contains("--identified-end \(Self.end)") == true)
            #expect(arguments.last?.contains("--identified-only --days 1") == true)
            #expect(environment["UNRELATED_TOKEN"] == nil)
            return wire
        }
        let received = try await fetcher.fetchIdentifiedUsage(
            host: "fixture-host",
            historyDays: 1,
            startUnixMs: Self.start,
            endUnixMs: Self.end,
            environment: ["UNRELATED_TOKEN": "fixture-secret"])
        #expect(received.records == ledger.records)
        let combined = try await CodexBarCLI.collectCodexIdentifiedUsage(
            remotes: ["fixture-host"],
            startUnixMs: Self.start,
            endUnixMs: Self.end,
            local: { ledger },
            fetchRemote: { _ in received })
        #expect(combined.allSourcesAvailable)
        #expect(combined.subtotal?.totalTokens == 110)
        let report = try await CodexBarCLI.collectCodexIdentifiedUsage(
            remotes: ["fixture-host"],
            startUnixMs: Self.start,
            endUnixMs: Self.end,
            local: { ledger },
            fetchRemote: { _ in throw CocoaError(.fileReadNoPermission) })
        #expect(report.subtotal?.totalTokens == 110)
        #expect(!report.allSourcesAvailable)
        #expect(report.partial)
        #expect(report.reports[0].ledger != nil)
        #expect(report.reports[1].ledger == nil)
        let cancelled = Task {
            try await CodexBarCLI.collectCodexIdentifiedUsage(
                remotes: ["fixture-host"],
                startUnixMs: Self.start,
                endUnixMs: Self.end,
                local: { throw CancellationError() },
                fetchRemote: { _ in
                    Issue.record("Cancellation must prevent SSH")
                    return ledger
                })
        }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
    }
}
