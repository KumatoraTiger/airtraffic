import Foundation

/// Reads Codex rollout transcripts: `<root>/YYYY/MM/DD/rollout-*.jsonl`.
///
/// Line types observed: `session_meta` (cwd, subagent flag), `event_msg`
/// (user_message / agent_message / task_started / task_complete), and
/// `response_item` (messages, reasoning, function calls).
public final class CodexAdapter: AgentAdapter {
    public let kind: AgentKind = .codex
    private let root: URL
    private let config: ScanConfig
    private var states: [String: State] = [:]

    private final class State {
        var offset: UInt64 = 0
        var sessionId = ""
        var cwd = ""
        var isSubagent = false
        var firstUserText: String?
        var lastUserText = ""
        var lastAssistantText = ""
        var lastRoleIsAssistant = false
        var lastTimestamp: Date?
        var todos: [TodoItem] = []
        var pendingCalls = 0  // function_call without function_call_output
        var tasksInFlight = 0  // task_started without task_complete

        /// Records a user turn, keeping the first human line for the title.
        func noteUserText(_ text: String) {
            if firstUserText == nil {
                let human = PromptText.humanLine(text)
                if !human.isEmpty { firstUserText = human }
            }
            lastUserText = text
            lastRoleIsAssistant = false
        }
    }

    public init(root: URL? = nil, config: ScanConfig = .default) {
        self.root =
            root
            ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions")
        self.config = config
    }

    public func scan(now: Date) throws -> [SessionSnapshot] {
        var snapshots: [SessionSnapshot] = []
        for file in recentRolloutFiles(now: now) {
            guard
                let mtime = try? file.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate
            else { continue }
            if let snapshot = try? scanFile(file, mtime: mtime, now: now) {
                snapshots.append(snapshot)
            }
        }
        return snapshots
    }

    /// Sessions are sharded into YYYY/MM/DD directories; only walk days inside the lookback.
    private func recentRolloutFiles(now: Date) -> [URL] {
        let fileManager = FileManager.default
        var files: [URL] = []
        let calendar = Calendar(identifier: .gregorian)
        var day = now.addingTimeInterval(-config.lookback)
        while day <= now.addingTimeInterval(24 * 3600) {
            let parts = calendar.dateComponents([.year, .month, .day], from: day)
            let dir =
                root
                .appendingPathComponent(String(format: "%04d", parts.year ?? 0))
                .appendingPathComponent(String(format: "%02d", parts.month ?? 0))
                .appendingPathComponent(String(format: "%02d", parts.day ?? 0))
            if let dayFiles = try? fileManager.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey],
                options: .skipsHiddenFiles
            ) {
                files.append(contentsOf: dayFiles.filter { $0.pathExtension == "jsonl" })
            }
            day = day.addingTimeInterval(24 * 3600)
        }
        return files.filter { file in
            guard
                let mtime = try? file.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate
            else { return false }
            return now.timeIntervalSince(mtime) < config.lookback
        }
    }

    private func scanFile(_ file: URL, mtime: Date, now: Date) throws -> SessionSnapshot? {
        let state = states[file.path] ?? State()
        let (lines, newOffset) = try FileTail.readNewLines(url: file, from: state.offset)
        state.offset = newOffset
        for line in lines {
            guard let object = JSONLine.parse(line) else { continue }
            ingest(object, into: state)
        }
        states[file.path] = state

        guard !state.sessionId.isEmpty else { return nil }
        // Subagent rollouts (judges, reviewers spawned by a parent thread) are noise here.
        if state.isSubagent { return nil }

        let status = StatusResolver.resolve(
            lastActivity: state.lastTimestamp ?? mtime,
            lastRoleIsAssistant: state.lastRoleIsAssistant,
            hasPendingToolUse: state.pendingCalls > 0 || state.tasksInFlight > 0,
            now: now,
            config: config
        )
        return SessionSnapshot(
            id: "codex:\(state.sessionId)",
            agent: .codex,
            cwd: state.cwd,
            title: (state.firstUserText ?? "(無題)").asTitle(),
            status: status,
            lastActivity: state.lastTimestamp ?? mtime,
            isSubagent: false,
            filePath: file.path,
            todos: state.todos,
            lastUserText: state.lastUserText,
            lastAssistantText: state.lastAssistantText
        )
    }

    private func ingest(_ object: [String: Any], into state: State) {
        if let timestamp = object["timestamp"] as? String, let date = ISO8601.date(timestamp) {
            state.lastTimestamp = date
        }
        guard let payload = object["payload"] as? [String: Any] else { return }

        switch object["type"] as? String {
        case "session_meta":
            state.sessionId = payload["id"] as? String ?? payload["session_id"] as? String ?? ""
            state.cwd = payload["cwd"] as? String ?? ""
            if payload["thread_source"] as? String == "subagent" { state.isSubagent = true }
            if let source = payload["source"] as? [String: Any], source["subagent"] != nil {
                state.isSubagent = true
            }
        case "event_msg":
            ingestEvent(payload, into: state)
        case "response_item":
            ingestResponseItem(payload, into: state)
        default:
            break
        }
    }

    private func ingestEvent(_ payload: [String: Any], into state: State) {
        let text = payload["message"] as? String ?? ""
        switch payload["type"] as? String {
        case "user_message":
            guard !text.isEmpty else { return }
            state.noteUserText(text)
        case "agent_message":
            guard !text.isEmpty else { return }
            state.lastAssistantText = text
            state.lastRoleIsAssistant = true
        case "task_started":
            state.tasksInFlight += 1
        case "task_complete":
            state.tasksInFlight = max(0, state.tasksInFlight - 1)
        case "exec_approval_request", "apply_patch_approval_request":
            state.pendingCalls += 1
        default:
            break
        }
    }

    private func ingestResponseItem(_ payload: [String: Any], into state: State) {
        switch payload["type"] as? String {
        // Some threads (orchestrated ones especially) record the user turn only
        // here, never as a `user_message` event, so this is the second source
        // of the title rather than a duplicate of the first.
        case "message":
            guard payload["role"] as? String == "user" else { return }
            let text = Self.inputText(payload["content"])
            guard !text.isEmpty else { return }
            state.noteUserText(text)
        case "function_call":
            state.pendingCalls += 1
            // Codex maintains its plan via the update_plan tool; that plan is
            // the session's deterministic todo list.
            if payload["name"] as? String == "update_plan",
                let argumentsJSON = payload["arguments"] as? String,
                let arguments = JSONLine.parse(argumentsJSON),
                let plan = arguments["plan"] as? [[String: Any]]
            {
                state.todos = plan.compactMap { step in
                    guard let content = step["step"] as? String else { return nil }
                    let status = TodoItem.Status(rawValue: step["status"] as? String ?? "") ?? .pending
                    return TodoItem(content: content, status: status)
                }
            }
        case "function_call_output":
            state.pendingCalls = max(0, state.pendingCalls - 1)
        default:
            break
        }
    }

    /// Concatenated `input_text` blocks of a response_item message.
    private static func inputText(_ content: Any?) -> String {
        if let text = content as? String { return text }
        guard let blocks = content as? [[String: Any]] else { return "" }
        return blocks.compactMap { $0["text"] as? String }.filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}
