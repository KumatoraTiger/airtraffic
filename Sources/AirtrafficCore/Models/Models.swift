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
    /// Transcript text appended since the last scan; input for LLM task extraction.
    public var newTranscriptText: String

    public init(
        id: String, agent: AgentKind, cwd: String, title: String, status: SessionStatus,
        lastActivity: Date, isSubagent: Bool, filePath: String, todos: [TodoItem],
        lastUserText: String, lastAssistantText: String, newTranscriptText: String
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
        self.newTranscriptText = newTranscriptText
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
    /// Extracted by an LLM and accepted by the user from the inbox.
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
    public var source: TaskSource
    public var createdAt: Date
    public var updatedAt: Date
    public var sessionIds: [String]

    public init(
        id: String, title: String, detail: String, status: TaskStatus, rank: Int?,
        source: TaskSource, createdAt: Date, updatedAt: Date, sessionIds: [String]
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.status = status
        self.rank = rank
        self.source = source
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.sessionIds = sessionIds
    }
}

// MARK: - Candidate (inbox)

public enum CandidateStatus: String, Codable, Sendable {
    case pending
    case accepted
    case rejected
    case expired
}

/// Frequently used reject reasons, offered as one-click choices in the inbox.
/// The raw value is stored as the candidate's reject reason and later fed back
/// into extraction prompts as a negative example, so keep the wording concise
/// and self-explanatory.
public enum RejectReasonPreset: String, CaseIterable, Identifiable, Sendable {
    case notATask = "タスクではない"
    case alreadyDone = "既に完了している"
    case duplicate = "既存のタスクと重複している"
    case handledByAgent = "エージェント側で完結する"
    case notNeeded = "対応不要と判断した"

    public var id: String { rawValue }

    /// Button label shown in the inbox menu.
    public var label: String { rawValue }

    public var symbol: String {
        switch self {
        case .notATask: return "xmark.circle"
        case .alreadyDone: return "checkmark.circle"
        case .duplicate: return "doc.on.doc"
        case .handledByAgent: return "cpu"
        case .notNeeded: return "hand.raised"
        }
    }
}

/// An LLM-extracted task candidate. Lives in the inbox until the user accepts or rejects it.
public struct Candidate: Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var detail: String
    public var confidence: Double
    public var sessionId: String
    public var agent: AgentKind
    public var excerpt: String
    public var status: CandidateStatus
    public var createdAt: Date
    public var rejectReason: String?

    public init(
        id: String, title: String, detail: String, confidence: Double, sessionId: String,
        agent: AgentKind, excerpt: String, status: CandidateStatus, createdAt: Date,
        rejectReason: String?
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.confidence = confidence
        self.sessionId = sessionId
        self.agent = agent
        self.excerpt = excerpt
        self.status = status
        self.createdAt = createdAt
        self.rejectReason = rejectReason
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
