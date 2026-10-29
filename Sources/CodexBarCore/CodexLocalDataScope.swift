import Foundation

/// Resolves all local Codex sources as one scope. A managed Codex home must
/// never silently borrow an ambient state database or cache identity.
struct CodexLocalDataScope: Sendable, Equatable {
    let identifier: String
    let codexHome: URL
    let sqliteHome: URL
    let sessionsRoot: URL
    let archivedSessionsRoot: URL
    let stateDatabaseURL: URL

    static func resolve(
        options: CostUsageScanner.Options,
        environment: [String: String] = ProcessInfo.processInfo.environment) -> CodexLocalDataScope
    {
        let codexHome: URL = if let sessionsRoot = options.codexSessionsRoot?.standardizedFileURL,
                                sessionsRoot.lastPathComponent == "sessions"
        {
            sessionsRoot.deletingLastPathComponent()
        } else if let codexHomePath = Self.nonEmpty(environment["CODEX_HOME"]) {
            URL(fileURLWithPath: codexHomePath, isDirectory: true).standardizedFileURL
        } else {
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        }

        // CODEX_SQLITE_HOME relocates SQLite files only; native rollout sessions stay under CODEX_HOME.
        let sqliteHome = Self.nonEmpty(environment["CODEX_SQLITE_HOME"])
            .map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }
            ?? codexHome.standardizedFileURL
        return self.make(codexHome: codexHome, sqliteHome: sqliteHome)
    }

    func applying(to options: CostUsageScanner.Options) -> CostUsageScanner.Options {
        var copy = options
        copy.codexSessionsRoot = self.sessionsRoot
        copy.codexTraceDatabaseURL = copy.codexTraceDatabaseURL ?? self.stateDatabaseURL
        return copy
    }

    private static func make(codexHome: URL, sqliteHome: URL) -> CodexLocalDataScope {
        let standardizedHome = codexHome.standardizedFileURL
        let standardizedSQLiteHome = sqliteHome.standardizedFileURL
        return CodexLocalDataScope(
            identifier: "codex-workspaces:" + Self.scopeFingerprint(
                standardizedHome.path + "\u{0}" + standardizedSQLiteHome.path),
            codexHome: standardizedHome,
            sqliteHome: standardizedSQLiteHome,
            sessionsRoot: standardizedHome.appendingPathComponent("sessions", isDirectory: true),
            archivedSessionsRoot: standardizedHome.appendingPathComponent("archived_sessions", isDirectory: true),
            stateDatabaseURL: standardizedSQLiteHome.appendingPathComponent("state_5.sqlite", isDirectory: false))
    }

    /// Stable local identifier for cache partitioning. It is not a security
    /// primitive; it only prevents raw home paths from entering cache metadata.
    private static func scopeFingerprint(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}
