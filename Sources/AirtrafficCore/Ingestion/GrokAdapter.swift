import Foundation

/// Reads Grok CLI sessions: `<home>/sessions/<urlencoded-cwd>/<session-id>/`
/// containing `summary.json` (metadata) and `chat_history.jsonl` (messages).
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
        var lastUserText = ""
        var lastAssistantText = ""
        var newText = ""
        var primed = false
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
        let isFirstParse = !state.primed
        let historyURL = dir.appendingPathComponent("chat_history.jsonl")
        if let (lines, newOffset) = try? FileTail.readNewLines(url: historyURL, from: state.offset) {
            state.offset = newOffset
            for line in lines {
                guard let object = JSONLine.parse(line) else { continue }
                ingest(object, into: state, collectText: !isFirstParse)
            }
        }
        state.primed = true
        states[dir.path] = state

        let newText = state.newText
        state.newText = ""

        let isLive = liveSessionIds.contains(sessionId)
        let status: SessionStatus
        if isLive {
            status =
                now.timeIntervalSince(lastActivity) < config.activeWindow
                ? .running : .waitingInput
        } else {
            status = .idle
        }

        let title =
            summary["session_summary"] as? String
            ?? summary["generated_title"] as? String
            ?? state.lastUserText
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
            lastAssistantText: lastTurnSummary.isEmpty ? state.lastAssistantText : lastTurnSummary,
            newTranscriptText: newText
        )
    }

    private func ingest(_ object: [String: Any], into state: State, collectText: Bool) {
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
            state.lastUserText = text
            if collectText { state.newText += "[user] \(text)\n" }
        case "assistant":
            state.lastAssistantText = text
            if collectText { state.newText += "[assistant] \(text)\n" }
        default:
            break
        }
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        return isDir.boolValue
    }
}
