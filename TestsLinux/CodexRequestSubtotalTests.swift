import Foundation
import Testing
@testable import CodexBarCLI
@testable import CodexBarCore

struct CodexRequestSubtotalTests {
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
            remote: "fixture-host",
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
        let ledger = try Self.loadNative([
            Self.nativeMetadata,
            #"{"type":"event_msg","timestamp":"2026-08-31T12:00:00Z","payload":{"type":"token_count","#
                + #""info":{"model":"kimi-coding/k2p5","total_token_usage":{"input_tokens":100,"output_tokens":10}}}}"#,
        ])
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
        let content = try [Self.nativeMetadata, Self.nativeRequest()].joined(separator: "\n") + "\n"
        try Data(content.utf8).write(to: root.appendingPathComponent("available.jsonl"))
        var options = CostUsageScanner.Options()
        options.codexSessionsRoot = root
        options.codexTraceDatabaseURL = root.appendingPathComponent("absent-trace.sqlite")
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
        var quarantined = original
        quarantined.conflictingIDs = original.records.map(\.id)
        #expect(try CodexRequestLedger.merge([quarantined, original]).requestCount == 0)
    }

    @Test(arguments: [
        "schema", "future-schema", "invalid-mode", "included-pre-cutoff",
        "provider", "window", "digest", "cached", "reasoning", "overflow", "sum",
    ])
    func `invalid source contracts and overflowing subtotals are rejected`(invalid: String) throws {
        var source = Self.ledger()
        switch invalid {
        case "schema": source.schemaVersion = 1
        case "future-schema": source.schemaVersion = 3
        case "invalid-mode": source = Self.source([Self.accountingRow(mode: "flex")])
        case "included-pre-cutoff": source = Self.source([Self.accountingRow(included: true)])
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
        let copy = try JSONDecoder().decode(CodexRequestLedger.self, from: JSONEncoder().encode(source))
        #expect(throws: RemoteCodexCostError.self) {
            try copy.validate(startUnixMs: Self.start, endUnixMs: Self.end)
            _ = try CodexRequestLedger.merge([copy])
        }
    }

    @Test(arguments: ["same", "contradiction", "invalid", "future-invalid", "reasoning", "timestamp"])
    func `native copies resumes exact UTC bounds and unidentified rows use the real parser`(variant: String)
        throws
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var options = CostUsageScanner.Options()
        options.codexSessionsRoot = root
        options.codexTraceDatabaseURL = root.appendingPathComponent("absent-trace.sqlite")
        let metadata = #"{"type":"session_meta","payload":{"id":"fixture-session"}}"#
        let original = try metadata + "\n" + (Self.nativeRequest("copied")) + "\n"
        try Data(original.utf8).write(to: root.appendingPathComponent("original.jsonl"))
        let contradiction = ["contradiction", "invalid", "reasoning", "timestamp"].contains(variant)
        let resumed = try Self.nativeRequest(
            "copied",
            timestamp: variant == "timestamp" ? "2026-08-31T11:00:00Z" : "2026-08-31T12:00:00Z",
            input: variant == "contradiction" ? 101 : (variant == "invalid" ? 19 : 100),
            reasoning: variant == "reasoning" ? 4 : 3)
        let resume = try original + resumed + "\n"
            + (Self.nativeRequest("new", timestamp: "2026-08-31T00:00:00Z")) + "\n"
            + (Self.nativeRequest("exact-end", timestamp: "2026-08-31T12:00:00.003Z")) + "\n"
            + (Self.nativeRequest(
                "copied",
                timestamp: "2026-08-31T12:00:00.004Z",
                input: variant == "future-invalid" ? 19 : 102)) + "\n"
            + (Self.nativeRequest("before", timestamp: "2026-08-30T23:59:59.999Z")) + "\n"
        try Data(resume.utf8).write(to: root.appendingPathComponent("resumed.jsonl"))
        let fork = try #"{"type":"session_meta","payload":{"id":"fixture-child","forked_from_id":"fixture-session","#
            + #""timestamp":"2026-08-31T12:00:00Z"}}"#
            + "\n" + (Self.nativeRequest("copied", input: 103)) + "\n"
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
        #expect(wire.contains("gpt-5"))
        #expect(!wire.contains(root.path))
    }

    @Test(arguments: ["missing", "empty", "truncated", "malformed", "oversized"])
    func `missing native histories are unavailable while damaged histories are partial`(state: String) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var options = CostUsageScanner.Options()
        options.codexSessionsRoot = root
        options.codexTraceDatabaseURL = root.appendingPathComponent("absent-trace.sqlite")
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
            remote: "fixture-host",
            startUnixMs: Self.start,
            endUnixMs: Self.end,
            local: { ledger },
            fetchRemote: { _ in received })
        #expect(combined.allSourcesAvailable)
        #expect(combined.subtotal?.totalTokens == 110)
        let report = try await CodexBarCLI.collectCodexIdentifiedUsage(
            remote: "fixture-host",
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
                remote: "fixture-host",
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

    @Test(arguments: ["timestamp", "tokens"])
    func `accounting conflicts stay quarantined in every source order`(field: String) throws {
        let clean = Self.accountingRow()
        let changed = field == "timestamp"
            ? Self.accountingRow(timestamp: Self.end - 1) : Self.accountingRow(input: 101)
        let survivor = Self.accountingRow(id: "b")
        let a = Self.source([clean, survivor])
        let b = Self.source([changed, survivor])
        for sources in [[a, b, a], [b, a, a], [a, a, b]] {
            let result = try Self.price(sources)
            #expect(result.requestCount == 1)
            #expect(result.totalTokens == 110)
            #expect(result.conflictCount == 1)
            #expect(result.unpricedRequestCount == 0)
            #expect(result.partial)
        }
        let empty = try Self.price([Self.source([clean, changed, clean])])
        #expect(empty.requestCount == 0 && empty.costUSD == 0)
        #expect(empty.conflictCount == 1 && empty.partial)
    }

    @Test(arguments: ["model", "mode", "inclusion", "null-model", "null-mode"])
    func `pricing disagreements are absorbing through source orders and wire copies`(field: String) throws {
        let timestamp: Int64 = 1_791_270_000_000
        let clean = Self.accountingRow(timestamp: timestamp)
        let changed = Self.accountingRow(
            model: field == "model" ? "gpt-5.4" : field == "null-model" ? nil : "gpt-5",
            mode: field == "mode" ? "priority" : field == "null-mode" ? nil : "standard",
            included: field == "inclusion",
            timestamp: timestamp)
        func source(_ rows: [CodexRequestRecord]) -> CodexRequestLedger {
            .init(startUnixMs: timestamp - 7 * 3_600_000, endUnixMs: timestamp, records: rows)
        }
        for rows in [[clean, changed, clean], [changed, clean, clean], [clean, clean, changed]] {
            let wire = try JSONEncoder().encode(source(rows))
            let copy = try JSONDecoder().decode(CodexRequestLedger.self, from: wire)
            let result = try Self.price([copy, source([clean])])
            #expect(result.requestCount == 1 && result.totalTokens == 110)
            #expect(result.conflictCount == 0 && !result.partial)
            #expect(result.costUSD == nil && result.unpricedRequestCount == 1)
        }
    }

    @Test(arguments: ["omitted", "priority", "ultrafast"])
    func `first post start settings bind once before the owned request`(tier: String) throws {
        let settings = tier == "omitted" ? Self.nativeSettings("default")
            .replacingOccurrences(of: "\"service_tier\":\"default\"", with: "\"model\":\"gpt-5\"")
            : Self.nativeSettings(tier)
        let ledger = try Self.loadNative([
            Self.nativeMetadata, Self.nativeStart("turn"), settings,
            Self.nativeSettings("default"), Self.nativeRequest(turn: "turn", model: "gpt-5.4"),
        ])
        let expected: String? = tier == "omitted" ? "standard" : tier == "priority" ? "priority" : nil
        #expect(ledger.records.first?.pricingMode == expected)
        #expect(try Self.price([ledger]).unpricedRequestCount == (expected == nil ? 1 : 0))
    }

    @Test
    func `unmatched explicit turn cannot inherit a cheaper tier`() throws {
        let ledger = try Self.loadNative([
            Self.nativeMetadata, Self.nativeSettings("priority"), Self.nativeStart("known"),
            Self.nativeRequest(turn: "unmatched", model: "gpt-5.4"),
        ])
        #expect(ledger.records.first?.pricingMode == nil)
        #expect(try Self.price([ledger]).unpricedRequestCount == 1)
    }

    @Test
    func `default before the trace window preserves copied usage with unknown dollars`() throws {
        let lines = try [
            Self.nativeMetadata, Self.nativeSettings("default"),
            Self.nativeStart("turn").replacingOccurrences(of: "2026-08-31T11:00:00Z", with: "2026-08-30T23:59:00Z"),
            Self.nativeRequest(turn: "turn", model: "gpt-5.4"),
        ]
        let absent = try Self.loadNative(lines)
        let empty = try Self.loadNative(lines, trace: [])
        #expect(absent.records.first?.pricingMode == "standard")
        #expect(empty.records.first?.pricingMode == nil)
    }

    @Test(arguments: ["model", "mode", "priority", "priority-long"])
    func `unknown prices preserve complete coverage and explicit wire nulls`(unknown: String) throws {
        let row: CodexRequestRecord = switch unknown {
        case "model": Self.accountingRow(model: nil)
        case "mode": Self.accountingRow(mode: nil)
        case "priority": Self.accountingRow(mode: "priority") // GPT-5 has no published Fast rate.
        default: Self.accountingRow(model: "gpt-5.4", mode: "priority", input: 272_001)
        }
        let result = try Self.price([Self.source([row, row])])
        #expect(result.requestCount == 1 && result.unpricedRequestCount == 1)
        #expect(result.costUSD == nil && !result.partial)
        let wire = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as? [String: Any])
        #expect(wire["costUSD"] is NSNull)
        #expect(wire["unpricedRequestCount"] as? Int == 1)
        let rowWire = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(row)) as? [String: Any])
        if unknown == "model" { #expect(rowWire["model"] is NSNull) }
        if unknown == "mode" { #expect(rowWire["pricingMode"] is NSNull) }
    }

    @Test
    func `per request thresholds cache subsets and reasoning retain scalar prices`() throws {
        let a = Self.accountingRow(model: "gpt-5.4", input: 200_000, cached: 100_000, output: 20, reasoning: 10)
        let b = Self.accountingRow(
            id: "b",
            model: "gpt-5.4",
            input: 200_000,
            cached: 100_000,
            output: 20,
            reasoning: 10)
        let result = try Self.price([Self.source([a, b, a])])
        // Each 200k request stays below 272k even though their union exceeds it; reasoning is output's subset.
        #expect(try abs(#require(result.costUSD) - 0.5506) < 1e-12)
        let olderAlias = try Self.price([Self.source([Self.accountingRow(model: "gpt-5.6")])])
        let canonical = try Self.price([Self.source([Self.accountingRow(model: "gpt-5.6-sol")])])
        #expect(olderAlias.requestCount == 1 && olderAlias.totalTokens == 110)
        #expect(olderAlias.costUSD != nil && olderAlias.costUSD == canonical.costUSD)
    }

    @Test
    func `historical prices use each accepted request timestamp`() throws {
        let cutoff: Int64 = 1_785_369_600_000
        let early = Self.accountingRow(
            model: "gpt-5.6-terra",
            timestamp: cutoff - 1,
            input: 1_000_000,
            cached: 0,
            output: 0,
            reasoning: nil)
        let late = Self.accountingRow(
            id: "b",
            model: "gpt-5.6-terra",
            timestamp: cutoff,
            input: 1_000_000,
            cached: 0,
            output: 0,
            reasoning: nil)
        let source = CodexRequestLedger(startUnixMs: cutoff - 86_400_000, endUnixMs: cutoff, records: [early, late])
        let result = try Self.price([source])
        #expect(result.requestCount == 2)
        #expect(try abs(#require(result.costUSD) - 9) < 1e-12)
    }

    @Test
    func `collector catalog and custom overlay price the deduplicated union`() throws {
        let model = "gpt-5-2025-08-07"
        let ledger = try Self.loadNative([
            Self.nativeMetadata, Self.nativeStart("turn"),
            #"{"type":"turn_context","timestamp":"2026-08-31T11:00:00Z","#
                + #""payload":{"turn_id":"turn","model":"gpt-5-2025-08-07"}}"#,
            Self.nativeRequest(turn: "turn", model: nil),
        ])
        let copy = try JSONDecoder().decode(CodexRequestLedger.self, from: JSONEncoder().encode(ledger))
        #expect(copy.records.first?.model == model)
        let catalog = try JSONDecoder().decode(ModelsDevCatalog.self, from: Data(
            (#"{"openai":{"id":"openai","models":{"gpt-5-2025-08-07":{"id":"gpt-5-2025-08-07","#
                + #""cost":{"input":2,"output":3,"cache_read":0.5}}}}}"#).utf8))
        for pricing in ["complete", "catalog", "incomplete"] {
            let custom = pricing == "catalog" ? CostUsageCustomPricing.empty : CostUsageCustomPricing(
                entries: [model: .init(
                    input: 4,
                    output: pricing == "complete" ? 5 : nil,
                    cacheRead: pricing == "complete" ? 1 : nil)], fingerprint: pricing)
            let result = try Self.price([ledger, copy], catalog: catalog, custom: custom)
            #expect(result.requestCount == 1 && result.totalTokens == 110 && !result.partial)
            #expect(result.unpricedRequestCount == (pricing == "incomplete" ? 1 : 0))
            if pricing == "incomplete" {
                #expect(result.costUSD == nil)
            } else {
                let expected = pricing == "complete" ? 0.00039 : 0.0002
                #expect(try abs(#require(result.costUSD) - expected) < 1e-12)
            }
        }
    }

    @Test
    func `qualified plan inclusion is zero unless the collector overrides it`() throws {
        let cutoff: Int64 = 1_791_270_000_000
        func source(_ rows: [CodexRequestRecord]) -> CodexRequestLedger {
            .init(startUnixMs: cutoff - 7 * 3_600_000, endUnixMs: cutoff, records: rows)
        }
        let known = Self.accountingRow(model: "codex-auto-review", included: true, timestamp: cutoff)
        let incomplete = CostUsageCustomPricing(entries: ["codex-auto-review": .init(input: 4)], fingerprint: "partial")
        let unknown = try Self.price([source([known])], custom: incomplete)
        #expect(unknown.costUSD == nil && unknown.unpricedRequestCount == 1 && !unknown.partial)
    }

    @Test
    func `local pricing uncertainty survives export repartition and later clean files`() throws {
        let clean = try [Self.nativeMetadata, Self.nativeRequest()]
        let changed = try [Self.nativeMetadata, Self.nativeRequest(model: "gpt-5.4")]
        for copies in [[changed, clean], [clean, changed]] {
            let local = try Self.loadNative(clean, copies: copies)
            let row = try #require(local.records.first)
            #expect(local.records.count == 1 && local.conflictingIDs.isEmpty)
            #expect(row.model == nil && row.pricingMode == nil && !row.includedInPlan)
            let exported = try JSONEncoder().encode(local)
            let copy = try JSONDecoder().decode(CodexRequestLedger.self, from: exported)
            let later = try Self.loadNative(clean)
            for sources in [[copy, later], [later, copy]] {
                let result = try Self.price(sources)
                #expect(result.totalTokens == 110 && result.requestCount == 1)
                #expect(result.costUSD == nil && result.unpricedRequestCount == 1)
                #expect(result.conflictCount == 0 && !result.partial)
            }
        }
    }

    @Test(arguments: [
        "default",
        "priority",
        "synthetic-unknown",
        "omitted",
        "null",
        "missing",
    ])
    func `native tiers retain standard priority and unknown evidence`(tier: String) throws {
        let settings = switch tier {
        case "omitted": Self.nativeSettings("default")
            .replacingOccurrences(of: "\"service_tier\":\"default\"", with: "\"model\":\"gpt-5\"")
        case "null": Self.nativeSettings("null").replacingOccurrences(of: "\"null\"", with: "null")
        case "missing": Self.nativeSettings("default")
            .replacingOccurrences(of: "\"thread_settings\":", with: "\"other_settings\":")
        default: Self.nativeSettings(tier)
        }
        let ledger = try Self.loadNative([
            Self.nativeMetadata, settings, Self.nativeStart("turn"),
            Self.nativeRequest(turn: "turn", model: "gpt-5.4"),
        ])
        let row = try #require(ledger.records.first)
        let expectedMode: String? = ["default", "omitted"]
            .contains(tier) ? "standard" : tier == "priority" ? "priority" : nil
        #expect(row.pricingMode == expectedMode)
        let price = try Self.price([ledger])
        #expect(price.unpricedRequestCount == (expectedMode == nil ? 1 : 0))
        #expect(!price.partial)
    }

    @Test
    func `inherited settings and delayed earlier turns keep their own model and tier`() throws {
        let ledger = try Self.loadNative([
            Self.nativeMetadata, Self.nativeSettings("priority"), Self.nativeStart("old"),
            #"{"type":"turn_context","timestamp":"2026-08-31T11:00:00Z","#
                + #""payload":{"turn_id":"old","model":"gpt-5.4"}}"#,
            Self.nativeRequest("first", turn: "old", model: nil),
            Self.nativeSettings("default"), Self.nativeStart("new"),
            #"{"type":"turn_context","timestamp":"2026-08-31T11:01:00Z","payload":{"turn_id":"new","model":"gpt-5"}}"#,
            Self.nativeRequest("delayed", turn: "old", model: nil),
            Self.nativeRequest("new", turn: "new", model: nil),
        ])
        #expect(ledger.records.filter { $0.model == "gpt-5.4" && $0.pricingMode == "priority" }.count == 2)
        #expect(ledger.records.filter { $0.model == "gpt-5" && $0.pricingMode == "standard" }.count == 1)
        #expect(try Self.price([ledger]).unpricedRequestCount == 0)
    }

    @Test(arguments: [
        "priority",
        "no-native-boundary",
        "unsupported-model",
        "mismatched-thread",
        "unreadable",
        "unknown-native",
    ])
    func `trace billing evidence is selected before price lookup`(kind: String) throws {
        let model = kind == "unsupported-model" ? "synthetic-unpriced" : "gpt-5.4"
        let thread = kind == "mismatched-thread" ? "other-thread" : "fixture-session"
        var lines = [Self.nativeMetadata]
        if kind == "unknown-native" { lines.append(Self.nativeSettings("synthetic-unknown")) }
        if kind != "no-native-boundary" { lines.append(Self.nativeStart("turn")) }
        try lines.append(Self.nativeRequest(turn: "turn", model: "gpt-5.4"))
        let ledger = try Self.loadNative(
            lines,
            trace: kind == "unreadable" ? nil : [(
                Self.start / 1000 + 12 * 3600,
                Self.priorityTrace(model: model, thread: thread))],
            brokenTrace: kind == "unreadable")
        let row = try #require(ledger.records.first)
        let result = try Self.price([ledger])
        if kind == "priority" || kind == "no-native-boundary" {
            #expect(row.pricingMode == "priority")
            #expect(try abs(#require(result.costUSD) - 0.00071) < 1e-12)
        } else {
            #expect(result.costUSD == nil && result.unpricedRequestCount == 1)
        }
        if kind == "unsupported-model" { #expect(row.model == "synthetic-unpriced") }
        #expect(!result.partial)
    }

    @Test
    func `identified trace bounds and pricing are independent of host zone`() throws {
        if let requestedZone = ProcessInfo.processInfo.environment["TZ"] {
            let date = Date(timeIntervalSince1970: Double(Self.start) / 1000)
            let expectedZone = try #require(TimeZone(identifier: requestedZone))
            #expect(Calendar.current.timeZone.secondsFromGMT(for: date) == expectedZone.secondsFromGMT(for: date))
            let effectiveZone = Calendar.current.timeZone
            print("Effective TZ: \(effectiveZone.identifier), offset \(effectiveZone.secondsFromGMT(for: date))")
        }
        for insideWindow in [false, true] {
            let ledger = try Self.loadNative(
                [
                    Self.nativeMetadata,
                    #"{"type":"turn_context","timestamp":"2026-08-30T23:59:00Z","#
                        + #""payload":{"turn_id":"turn","model":"gpt-5.4"}}"#,
                    Self.nativeRequest(turn: "turn", model: nil, timestamp: "2026-08-31T00:01:00Z"),
                ],
                trace: [(Self.start / 1000 + (insideWindow ? 30 : -60), Self.priorityTrace())])
            let result = try Self.price([ledger, ledger])
            #expect(ledger.records.first?.pricingMode == (insideWindow ? "priority" : nil))
            #expect(result.requestCount == 1 && result.totalTokens == 110 && !result.partial)
            #expect(result.unpricedRequestCount == (insideWindow ? 0 : 1))
        }
    }

    @Test
    func `contradictory observations in one native file remain quarantined`() throws {
        let ledger = try Self.loadNative([
            Self.nativeMetadata, Self.nativeSettings("default"), Self.nativeStart("turn"),
            Self.nativeRequest(turn: "turn"),
            Self.nativeSettings("priority"), Self.nativeStart("turn"),
            Self.nativeRequest(turn: "turn"), Self.nativeRequest("survivor", turn: "turn"),
        ])
        let result = try Self.price([ledger])
        #expect(result.conflictCount == 0 && !result.partial)
        #expect(result.requestCount == 2 && result.totalTokens == 220)
        #expect(result.unpricedRequestCount == 2)
    }

    @Test
    func `auto review qualification uses creator and cutoff without source pricing`() throws {
        let cutoff: Int64 = 1_791_270_000_000
        let metadata = #"{"type":"session_meta","payload":{"id":"fixture-session","#
            + #""creator_account_id":"private-account"}}"#
        let ledger = try Self.loadNative(
            [
                metadata, Self.nativeSettings("synthetic-unknown"), Self.nativeStart("turn"),
                Self.nativeRequest("before", model: "codex-auto-review", timestamp: "2026-10-06T06:59:59.999Z"),
                Self.nativeRequest("after", model: "codex-auto-review", timestamp: "2026-10-06T07:00:00Z"),
            ],
            start: cutoff - 7 * 3_600_000,
            end: cutoff)
        #expect(ledger.records.filter(\.includedInPlan).count == 1)
        let freeRecord = ledger.records.first { $0.includedInPlan }
        let free = try #require(freeRecord)
        #expect(free.pricingMode == nil)
        let wire = try #require(String(data: JSONEncoder().encode(ledger), encoding: .utf8))
        #expect(!wire.contains("private-account"))
        #expect(!CostUsageScanner.codexAutoReviewIsIncludedInPlan(
            model: "codex-auto-review", timestampUnixMs: cutoff, hasCreatorAccount: false))
    }

    @Test
    func `qualified auto review retains trace billing model through wire and collector override`() throws {
        let cutoff: Int64 = 1_791_270_000_000
        let ledger = try Self.loadNative(
            [
                #"{"type":"session_meta","payload":{"id":"fixture-session","creator_account_id":"fixture-creator"}}"#,
                Self.nativeStart("turn").replacingOccurrences(of: "2026-08-31T11:00:00Z", with: "2026-10-06T07:00:00Z"),
                Self.nativeRequest(turn: "turn", model: "codex-auto-review", timestamp: "2026-10-06T07:00:00Z"),
            ],
            trace: [(cutoff / 1000, Self.priorityTrace())],
            start: cutoff - 7 * 3_600_000,
            end: cutoff)
        let copy = try JSONDecoder().decode(CodexRequestLedger.self, from: JSONEncoder().encode(ledger))
        #expect(copy.records.first?.model == "gpt-5.4")
        #expect(copy.records.first?.includedInPlan == true)
        #expect(try Self.price([copy]).costUSD == 0)
        let overlay = CostUsageCustomPricing(
            entries: ["gpt-5.4": .init(input: 4, output: 5, cacheRead: 1)], fingerprint: "fixture")
        let price = try Self.price([copy], custom: overlay)
        #expect(try abs(#require(price.costUSD) - 0.00078) < 1e-12)
    }

    @Test(arguments: [false, true])
    func `optional pricing observation leaves ordinary rows and saved settings unchanged`(
        settingsAfterStart: Bool) throws
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("history.jsonl")
        let settings = Self.nativeSettings("synthetic-unknown")
        let start = Self.nativeStart("turn")
        let lines = try [Self.nativeMetadata]
            + (settingsAfterStart ? [start, settings] : [settings, start])
            + [Self.nativeRequest(turn: "turn")]
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: file)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let range = CostUsageScanner.CostUsageDayRange(
            since: Date(timeIntervalSince1970: Double(Self.start) / 1000),
            until: Date(timeIntervalSince1970: Double(Self.end) / 1000),
            calendar: calendar)
        let ordinary = try CostUsageScanner.parseCodexFileCancellable(fileURL: file, range: range)
        var count = 0
        let observed = try CostUsageScanner.parseCodexFileCancellable(
            fileURL: file, range: range, ownedRequestObserver: { _, _, _ in
                count += 1
            })
        #expect(count == 1)
        #expect(ordinary.rows == observed.rows)
        #expect(ordinary.requestLedgerState == observed.requestLedgerState)
        #expect(ordinary.bufferedSubagentLines == observed.bufferedSubagentLines)
        #expect(ordinary.bufferedUnresolvedForkLines == observed.bufferedUnresolvedForkLines)
    }

    @Test
    func `a context timestamp alone does not establish a bounded turn start`() throws {
        let ledger = try Self.loadNative([
            Self.nativeMetadata,
            #"{"type":"turn_context","timestamp":"2026-08-31T11:00:00Z","#
                + #""payload":{"turn_id":"turn","model":"gpt-5.4"}}"#,
            Self.nativeRequest(turn: "turn", model: nil),
        ], trace: [(Self.start / 1000 - 60, Self.priorityTrace())])
        #expect(ledger.records.first?.pricingMode == nil)
        #expect(try Self.price([ledger]).unpricedRequestCount == 1)
    }
}

extension CodexRequestSubtotalTests {
    private static func ledger(input: Int = 100) -> CodexRequestLedger {
        self.source([self.accountingRow(input: input)])
    }

    private static func accountingRow(
        id: String = "a",
        model: String? = "gpt-5",
        mode: String? = "standard",
        included: Bool = false,
        timestamp: Int64? = nil,
        input: Int = 100,
        cached: Int = 20,
        output: Int = 10,
        reasoning: Int? = 3) -> CodexRequestRecord
    {
        .init(
            id: String(repeating: id, count: 64),
            timestampUnixMs: timestamp ?? self.end,
            inputTokens: input,
            cacheReadTokens: cached,
            outputTokens: output,
            reasoningTokens: reasoning,
            model: model,
            pricingMode: mode,
            includedInPlan: included)
    }

    private static func source(_ rows: [CodexRequestRecord]) -> CodexRequestLedger {
        .init(startUnixMs: self.start, endUnixMs: self.end, records: rows)
    }

    private static func price(
        _ sources: [CodexRequestLedger],
        catalog: ModelsDevCatalog = .init(providers: [:]),
        custom: CostUsageCustomPricing = .empty) throws -> CodexRequestSubtotal
    {
        try CodexRequestLedger.merge(sources, catalog: catalog, customPricing: custom)
    }

    private static func nativeRequest(
        _ response: String = "request",
        turn: String? = nil,
        model: String? = "gpt-5",
        timestamp: String = "2026-08-31T12:00:00Z",
        input: Int = 100,
        reasoning: Int = 3) throws -> String
    {
        let usage = [
            "input_tokens": input,
            "cached_input_tokens": 20,
            "output_tokens": 10,
            "reasoning_output_tokens": reasoning,
        ]
        var payload: [String: Any] = [
            "thread_id": "fixture-session",
            "response_id": response,
            "usage": usage,
            "thread_token_usage": usage,
        ]
        payload["turn_id"] = turn
        payload["model"] = model
        let data = try JSONSerialization.data(withJSONObject: [
            "type": "token_usage_record", "timestamp": timestamp, "payload": payload,
        ], options: .sortedKeys)
        return try #require(String(data: data, encoding: .utf8))
    }

    private static func nativeSettings(_ tier: String) -> String {
        #"{"type":"event_msg","timestamp":"2026-08-31T10:00:00Z","payload":{"type":"thread_settings_applied","#
            + #""thread_settings":{"service_tier":""#
            + tier + #""}}}"#
    }

    private static func nativeStart(_ turn: String) -> String {
        #"{"type":"event_msg","timestamp":"2026-08-31T11:00:00Z","payload":{"type":"task_started","turn_id":""#
            + turn + #""}}"#
    }

    private static func loadNative(
        _ lines: [String],
        copies: [[String]] = [],
        trace: [(Int64, String)]? = nil,
        brokenTrace: Bool = false,
        start: Int64 = Self.start,
        end: Int64 = Self.end) throws -> CodexRequestLedger
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for (index, history) in ([lines] + copies).enumerated() {
            try Data((history.joined(separator: "\n") + "\n").utf8)
                .write(to: root.appendingPathComponent("history-\(index).jsonl"))
        }
        var options = CostUsageScanner.Options()
        options.codexSessionsRoot = root
        options.codexTraceDatabaseURL = root.appendingPathComponent("trace.sqlite")
        if let trace {
            let database = try #require(options.codexTraceDatabaseURL)
            try CodexPrioritySQLiteTests.Fixture.createDatabase(at: database)
            try CodexPrioritySQLiteTests.Fixture.insert(trace, at: database)
        }
        if brokenTrace { try Data("not a database".utf8).write(to: #require(options.codexTraceDatabaseURL)) }
        return try CodexRequestLedger.load(
            startUnixMs: start,
            endUnixMs: end,
            options: options,
            checkCancellation: {})
    }

    private static func priorityTrace(model: String = "gpt-5.4", thread: String = "fixture-session") -> String {
        "thread_id=\(thread) turn.id=turn websocket request: "
            + #"{"type":"response.create","service_tier":"priority","model":""# + model + #""}"#
    }

    private static let start: Int64 = 1_788_134_400_000
    private static let end: Int64 = 1_788_177_600_000
    private static let nativeMetadata = #"{"type":"session_meta","payload":{"id":"fixture-session"}}"#
}
