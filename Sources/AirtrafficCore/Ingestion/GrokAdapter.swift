import Foundation

/// Reads Grok CLI sessions: `<home>/sessions/<urlencoded-cwd>/<session-id>/`
/// containing `summary.json` (metadata) and `chat_history.jsonl` (messages).
/// Subagent sessions live in the same tree and carry `session_kind: "subagent"`.
/// `<home>/active_sessions.json` lists sessions with a live CLI process.
public final class GrokAdapter: AgentAdapter {
    public let kind: AgentKind = .grok
    private let home: URL
    private let config: ScanConfig
    /// Overridable for tests; defaults to a real process-liveness check.
    private let isProcessAlive: (Int32) -> Bool
    private var states: [String: State] = [:]

    private final class State {
        var offset: UInt64 = 0
        var firstUserText = ""
        var lastUserText = ""
        var lastAssistantText = ""
    }

    public init(
        home: URL? = nil, config: ScanConfig = .default,
        isProcessAlive: @escaping (Int32) -> Bool = { kill($0, 0) == 0 }
    ) {
        self.home =
            home
            ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".grok")
        self.config = config
        self.isProcessAlive = isProcessAlive
    }

    public func scan(now: Date) throws -> [SessionSnapshot] {
        let fileManager = FileManager.default
        let sessionsRoot = home.appendingPathComponent("sessions")
        guard
            let cwdDirs = try? fileManager.contentsOfDirectory(
                at: sessionsRoot, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
            )
        else { return [] }

        let liveSessionIds = liveSessions()
        var snapshots: [SessionSnapshot] = []
        for cwdDir in cwdDirs where cwdDir.hasDirectoryPath || isDirectory(cwdDir) {
            let sessionDirs =
                (try? fileManager.contentsOfDirectory(
                    at: cwdDir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
                )) ?? []
            for sessionDir in sessionDirs {
                if let snapshot = try? scanSession(sessionDir, liveSessionIds: liveSessionIds, now: now) {
                    snapshots.append(snapshot)
                }
            }
        }
        return snapshots
    }

    /// Session ids from active_sessions.json whose process is still alive.
    private func liveSessions() -> Set<String> {
        let url = home.appendingPathComponent("active_sessions.json")
        guard let data = try? Data(contentsOf: url),
            let entries = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
        else { return [] }
        var ids: Set<String> = []
        for entry in entries {
            guard let id = entry["session_id"] as? String else { continue }
            if let pid = entry["pid"] as? Int, !isProcessAlive(Int32(pid)) { continue }
            ids.insert(id)
        }
        return ids
    }

    private func scanSession(_ dir: URL, liveSessionIds: Set<String>, now: Date) throws -> SessionSnapshot? {
        let summaryURL = dir.appendingPathComponent("summary.json")
        guard let data = try? Data(contentsOf: summaryURL),
            let summary = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }

        // Grok writes subagent transcripts next to real sessions; they are
        // internal machinery, not work the user drives.
        if summary["session_kind"] as? String == "subagent" { return nil }

        let sessionId =
            (summary["info"] as? [String: Any])?["id"] as? String
            ?? dir.lastPathComponent
        let updatedAt =
            (summary["updated_at"] as? String).flatMap(ISO8601.date)
            ?? (summary["last_active_at"] as? String).flatMap(ISO8601.date)
        guard let lastActivity = updatedAt,
            now.timeIntervalSince(lastActivity) < config.lookback
        else { return nil }

        let state = states[dir.path] ?? State()
        let historyURL = dir.appendingPathComponent("chat_history.jsonl")
        if let (lines, newOffset) = try? FileTail.readNewLines(url: historyURL, from: state.offset) {
            state.offset = newOffset
            for line in lines {
                guard let object = JSONLine.parse(line) else { continue }
                ingest(object, into: state)
            }
        }
        states[dir.path] = state

        let isLive = liveSessionIds.contains(sessionId)
        let status: SessionStatus
        if isLive {
            status =
                now.timeIntervalSince(lastActivity) < config.activeWindow
                ? .running : .waitingInput
        } else {
            status = .idle
        }

        // Grok writes `session_summary` as an empty string until it has one,
        // and `??` only falls back on a missing key, so the empty value has to
        // be rejected explicitly or the two later sources are never reached.
        let title = firstHumanTitle(
            summary["session_summary"] as? String,
            summary["generated_title"] as? String,
            state.firstUserText)
        let lastTurnSummary = summary["last_turn_summary"] as? String ?? ""
        let cwd = (summary["info"] as? [String: Any])?["cwd"] as? String ?? ""

        return SessionSnapshot(
            id: "grok:\(sessionId)",
            agent: .grok,
            cwd: cwd,
            title: title.isEmpty ? "(無題)" : title.asTitle(),
            status: status,
            lastActivity: lastActivity,
            isSubagent: false,
            filePath: dir.path,
            todos: [],
            lastUserText: state.lastUserText,
            lastAssistantText: lastTurnSummary.isEmpty ? state.lastAssistantText : lastTurnSummary
        )
    }

    private func ingest(_ object: [String: Any], into state: State) {
        let text: String
        if let string = object["content"] as? String {
            text = string
        } else if let blocks = object["content"] as? [[String: Any]] {
            text = blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
        } else {
            return
        }
        guard !text.isEmpty else { return }
        switch object["type"] as? String {
        case "user":
            if state.firstUserText.isEmpty {
                state.firstUserText = PromptText.humanLine(text)
            }
            state.lastUserText = text
        case "assistant":
            state.lastAssistantText = text
        default:
            break
        }
    }

    /// First candidate that names something a person asked for, or "".
    /// Grok derives `session_summary` from the first message, so a session
    /// driven by a JSON payload carries that payload as its summary.
    private func firstHumanTitle(_ candidates: String?...) -> String {
        for candidate in candidates {
            let line = PromptText.humanLine(candidate ?? "")
            if !line.isEmpty { return line }
        }
        return ""
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        return isDir.boolValue
    }
}
