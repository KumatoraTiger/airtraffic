import Foundation

/// Reads Claude Code transcripts: `<root>/<encoded-project>/<session-uuid>.jsonl`,
/// one JSON event per line.
public final class ClaudeCodeAdapter: AgentAdapter {
    public let kind: AgentKind = .claudeCode
    private let root: URL
    private let config: ScanConfig
    private var states: [String: State] = [:]  // keyed by file path

    /// Accumulated parse state for one transcript file.
    private final class State {
        var offset: UInt64 = 0
        var sessionId = ""
        var cwd = ""
        var summary: String?
        var firstUserText: String?
        var lastUserText = ""
        var lastAssistantText = ""
        var lastRoleIsAssistant = false
        var lastTimestamp: Date?
        var isSidechain = false
        var todos: [TodoItem] = []
        var pendingToolUseIds: Set<String> = []
        var newText = ""
        var primed = false  // true once the initial full parse is done
    }

    public init(root: URL? = nil, config: ScanConfig = .default) {
        self.root = root ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
        self.config = config
    }

    public func scan(now: Date) throws -> [SessionSnapshot] {
        let fileManager = FileManager.default
        guard let projectDirs = try? fileManager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
        ) else { return [] }

        var snapshots: [SessionSnapshot] = []
        for projectDir in projectDirs {
            let files = (try? fileManager.contentsOfDirectory(
                at: projectDir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: .skipsHiddenFiles
            )) ?? []
            for file in files where file.pathExtension == "jsonl" {
                guard let mtime = try? file.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate,
                    now.timeIntervalSince(mtime) < config.lookback
                else { continue }
                if let snapshot = try? scanFile(file, mtime: mtime, now: now) {
                    snapshots.append(snapshot)
                }
            }
        }
        return snapshots
    }

    private func scanFile(_ file: URL, mtime: Date, now: Date) throws -> SessionSnapshot? {
        let state = states[file.path] ?? State()
        let isFirstParse = !state.primed
        let (lines, newOffset) = try FileTail.readNewLines(url: file, from: state.offset)
        state.offset = newOffset
        for line in lines {
            guard let object = JSONLine.parse(line) else { continue }
            ingest(object, into: state, collectText: !isFirstParse)
        }
        state.primed = true
        states[file.path] = state

        guard !state.sessionId.isEmpty else { return nil }
        // Sidechains are subagent transcripts inside the same file tree; they are
        // not sessions the user drives directly.
        if state.isSidechain { return nil }

        let newText = state.newText
        state.newText = ""

        let status = StatusResolver.resolve(
            lastActivity: state.lastTimestamp ?? mtime,
            lastRoleIsAssistant: state.lastRoleIsAssistant,
            hasPendingToolUse: !state.pendingToolUseIds.isEmpty,
            now: now,
            config: config
        )
        return SessionSnapshot(
            id: "claude:\(state.sessionId)",
            agent: .claudeCode,
            cwd: state.cwd,
            title: (state.summary ?? state.firstUserText ?? "(無題)").asTitle(),
            status: status,
            lastActivity: state.lastTimestamp ?? mtime,
            isSubagent: false,
            filePath: file.path,
            todos: state.todos,
            lastUserText: state.lastUserText,
            lastAssistantText: state.lastAssistantText,
            newTranscriptText: newText
        )
    }

    private func ingest(_ object: [String: Any], into state: State, collectText: Bool) {
        if let sessionId = object["sessionId"] as? String, state.sessionId.isEmpty {
            state.sessionId = sessionId
        }
        if let cwd = object["cwd"] as? String { state.cwd = cwd }
        if object["isSidechain"] as? Bool == true { state.isSidechain = true }
        if let timestamp = object["timestamp"] as? String, let date = ISO8601.date(timestamp) {
            state.lastTimestamp = date
        }

        switch object["type"] as? String {
        case "summary":
            state.summary = object["summary"] as? String
        case "user":
            guard let message = object["message"] as? [String: Any] else { return }
            let (text, toolResultIds) = Self.userContent(message["content"])
            for id in toolResultIds { state.pendingToolUseIds.remove(id) }
            if !text.isEmpty {
                if state.firstUserText == nil { state.firstUserText = text }
                state.lastUserText = text
                state.lastRoleIsAssistant = false
                if collectText { state.newText += "[user] \(text)\n" }
            }
        case "assistant":
            guard let message = object["message"] as? [String: Any],
                  let blocks = message["content"] as? [[String: Any]] else { return }
            var texts: [String] = []
            for block in blocks {
                switch block["type"] as? String {
                case "text":
                    if let text = block["text"] as? String, !text.isEmpty { texts.append(text) }
                case "tool_use":
                    if let id = block["id"] as? String { state.pendingToolUseIds.insert(id) }
                    if block["name"] as? String == "TodoWrite",
                       let input = block["input"] as? [String: Any],
                       let todos = Self.todos(from: input) {
                        state.todos = todos
                    }
                default:
                    break
                }
            }
            if !texts.isEmpty {
                let joined = texts.joined(separator: "\n")
                state.lastAssistantText = joined
                if collectText { state.newText += "[assistant] \(joined)\n" }
            }
            state.lastRoleIsAssistant = true
        default:
            break
        }
    }

    /// Extracts plain text and acknowledged tool_use ids from a user message content value.
    private static func userContent(_ content: Any?) -> (text: String, toolResultIds: [String]) {
        if let text = content as? String { return (text, []) }
        guard let blocks = content as? [[String: Any]] else { return ("", []) }
        var texts: [String] = []
        var ids: [String] = []
        for block in blocks {
            switch block["type"] as? String {
            case "text":
                if let text = block["text"] as? String { texts.append(text) }
            case "tool_result":
                if let id = block["tool_use_id"] as? String { ids.append(id) }
            default:
                break
            }
        }
        return (texts.joined(separator: "\n"), ids)
    }

    private static func todos(from input: [String: Any]) -> [TodoItem]? {
        guard let raw = input["todos"] as? [[String: Any]] else { return nil }
        return raw.compactMap { item in
            guard let content = item["content"] as? String else { return nil }
            let status = TodoItem.Status(rawValue: item["status"] as? String ?? "") ?? .pending
            return TodoItem(content: content, status: status)
        }
    }
}
