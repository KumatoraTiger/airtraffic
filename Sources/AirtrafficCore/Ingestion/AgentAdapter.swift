import Foundation

/// One coding-agent integration. Adapters are stateful incremental parsers:
/// the first scan of a file parses it fully to rebuild session state, and
/// later scans read only appended bytes.
public protocol AgentAdapter: AnyObject {
    var kind: AgentKind { get }
    /// Scans on-disk session data and returns a snapshot per recent session.
    func scan(now: Date) throws -> [SessionSnapshot]
}

/// Tunable thresholds shared by all adapters.
public struct ScanConfig: Sendable {
    /// Sessions untouched for longer than this are not scanned at all.
    public var lookback: TimeInterval = 48 * 3600
    /// Activity within this window means the agent is actively running.
    public var activeWindow: TimeInterval = 45
    /// A session waiting longer than this is shown as idle, not waiting.
    public var idleAfter: TimeInterval = 4 * 3600

    public static let `default` = ScanConfig()

    public init(
        lookback: TimeInterval = 48 * 3600,
        activeWindow: TimeInterval = 45,
        idleAfter: TimeInterval = 4 * 3600
    ) {
        self.lookback = lookback
        self.activeWindow = activeWindow
        self.idleAfter = idleAfter
    }
}

public enum StatusResolver {
    /// Derives a session status from the last observed activity.
    ///
    /// The rules, in order:
    /// 1. Fresh writes mean the agent is running.
    /// 2. A tool call without a result, gone quiet, is most likely a permission prompt.
    /// 3. An assistant turn end with no follow-up means the agent waits for user input.
    /// 4. Anything older than `idleAfter` is idle.
    public static func resolve(
        lastActivity: Date,
        lastRoleIsAssistant: Bool,
        hasPendingToolUse: Bool,
        now: Date,
        config: ScanConfig
    ) -> SessionStatus {
        let age = now.timeIntervalSince(lastActivity)
        if age < config.activeWindow { return .running }
        if age >= config.idleAfter { return .idle }
        if hasPendingToolUse { return .waitingApproval }
        if lastRoleIsAssistant { return .waitingInput }
        return .idle
    }
}

/// Reads newly appended data from a growing file.
enum FileTail {
    /// Returns lines appended after `offset` and the new offset.
    /// A trailing partial line (no newline yet) is left for the next read.
    static func readNewLines(url: URL, from offset: UInt64) throws -> (lines: [String], newOffset: UInt64) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        // The file shrank (rotated or truncated): start over.
        let start = offset <= size ? offset : 0
        guard start < size else { return ([], size) }
        try handle.seek(toOffset: start)
        let data = try handle.readToEnd() ?? Data()
        var consumed = data
        if data.last != UInt8(ascii: "\n"), let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) {
            consumed = data.prefix(through: lastNewline)
        } else if data.last != UInt8(ascii: "\n") {
            return ([], start)
        }
        let text = String(decoding: consumed, as: UTF8.self)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        return (lines, start + UInt64(consumed.count))
    }
}

enum JSONLine {
    static func parse(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

extension String {
    /// First line, trimmed and capped, for use as a session title.
    func asTitle(maxLength: Int = 80) -> String {
        let firstLine = split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? self
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        return trimmed.count <= maxLength ? trimmed : String(trimmed.prefix(maxLength)) + "…"
    }
}

enum ISO8601 {
    private static let withFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let plain = ISO8601DateFormatter()

    static func date(_ string: String) -> Date? {
        withFractional.date(from: string) ?? plain.date(from: string)
    }
}
