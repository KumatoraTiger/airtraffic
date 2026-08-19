import Foundation

// MARK: - Agent

public enum AgentKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case claudeCode = "claude_code"
    case codex
    case grok

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        case .grok: "Grok"
        }
    }

    public var symbol: String {
        switch self {
        case .claudeCode: "asterisk.circle.fill"
        case .codex: "chevron.left.forwardslash.chevron.right"
        case .grok: "bolt.circle.fill"
        }
    }
}

// MARK: - Session

public enum SessionStatus: String, Codable, Sendable {
    /// The agent is actively producing output.
    case running
    /// The agent finished its turn and is waiting for the user's next input.
    case waitingInput = "waiting_input"
    /// A tool call is pending without a result; likely blocked on permission approval.
    case waitingApproval = "waiting_approval"
    /// No recent activity.
    case idle

    /// Sessions that resume as soon as the user spends a few seconds on them.
    public var needsAttention: Bool { self == .waitingInput || self == .waitingApproval }

    public var displayName: String {
        switch self {
        case .running: "実行中"
        case .waitingInput: "入力待ち"
        case .waitingApproval: "承認待ち"
        case .idle: "待機"
        }
    }

    public var sortOrder: Int {
        switch self {
        case .waitingApproval: 0
        case .waitingInput: 1
        case .running: 2
        case .idle: 3
        }
    }
}

public struct TodoItem: Codable, Hashable, Sendable {
    public enum Status: String, Codable, Sendable {
        case pending
        case inProgress = "in_progress"
        case completed
    }

    public var content: String
    public var status: Status

    public init(content: String, status: Status) {
        self.content = content
        self.status = status
    }
}

/// A normalized view of one coding-agent session, produced by an adapter.
public struct SessionSnapshot: Identifiable, Hashable, Sendable {
    public var id: String
    public var agent: AgentKind
    public var cwd: String
    public var title: String
    public var status: SessionStatus
    public var lastActivity: Date
    public var isSubagent: Bool
    public var filePath: String
    public var todos: [TodoItem]
    public var lastUserText: String
    public var lastAssistantText: String

    public init(
        id: String, agent: AgentKind, cwd: String, title: String, status: SessionStatus,
        lastActivity: Date, isSubagent: Bool, filePath: String, todos: [TodoItem],
        lastUserText: String, lastAssistantText: String
    ) {
        self.id = id
        self.agent = agent
        self.cwd = cwd
        self.title = title
        self.status = status
        self.lastActivity = lastActivity
        self.isSubagent = isSubagent
        self.filePath = filePath
        self.todos = todos
        self.lastUserText = lastUserText
        self.lastAssistantText = lastAssistantText
    }

    public var projectName: String {
        let name = (cwd as NSString).lastPathComponent
        return name.isEmpty ? cwd : name
    }

    public static func == (lhs: SessionSnapshot, rhs: SessionSnapshot) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - Task

public enum TaskStatus: String, Codable, CaseIterable, Sendable {
    case todo
    case inProgress = "in_progress"
    case done
    case archived
}

public enum TaskSource: String, Codable, Sendable {
    /// Parsed from a structured signal in the transcript (e.g. TodoWrite).
    case deterministic
    /// Created by the removed LLM-proposal feature; kept so stored tasks decode.
    case llm
    /// Created by hand in the app.
    case manual
}

public struct TaskItem: Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var detail: String
    public var status: TaskStatus
    /// Lower rank means higher priority. Nil means unranked.
    public var rank: Int?
    /// Picked for today's focus. Sticks until the user takes it off; the board
    /// shows these in their own section above the main list.
    public var isToday: Bool
    public var source: TaskSource
    public var createdAt: Date
    public var updatedAt: Date
    /// When the task last entered `done`. Cleared if it is reopened, so the
    /// daily report only counts work finished (and still finished) today.
    public var completedAt: Date?
    public var sessionIds: [String]

    public init(
        id: String, title: String, detail: String, status: TaskStatus, rank: Int?,
        isToday: Bool = false, source: TaskSource, createdAt: Date, updatedAt: Date,
        completedAt: Date? = nil, sessionIds: [String]
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.status = status
        self.rank = rank
        self.isToday = isToday
        self.source = source
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.completedAt = completedAt
        self.sessionIds = sessionIds
    }
}

// MARK: - Preference

/// A recorded prioritization preference, fed back into future ranking prompts.
public struct PreferenceNote: Identifiable, Hashable, Sendable {
    public var id: String
    public var text: String
    public var createdAt: Date

    public init(id: String, text: String, createdAt: Date) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
    }
}
