import Foundation

/// What started a per-task command.
public enum AutomationTrigger: String, Codable, Sendable {
    /// A GitHub row the inbox just imported.
    case arrival
    /// A bot's review comment on a pull request the user opened.
    case comment
    /// A label the user put on an issue assigned to them.
    case label

    public var displayName: String {
        switch self {
        case .arrival: "新着"
        case .comment: "Bot レビュー"
        case .label: "ラベル"
        }
    }

    /// How a run of this trigger is named in the store, so the three kinds
    /// never collide on one task.
    var idPrefix: String {
        switch self {
        case .arrival: "gha"
        case .comment: "ghc"
        case .label: "ghl"
        }
    }
}

/// One run of the per-task command, as the board shows it: what started it,
/// for which row, when, and how it ended.
///
/// The title and link are copied from the task at start time so the row keeps
/// reading correctly after the task is archived or renamed by a later sync.
public struct AutomationRun: Identifiable, Sendable, Equatable {
    public var id: String
    public var taskId: String
    public var title: String
    /// The GitHub link of the row, when the detail line carried one.
    public var url: String?
    public var trigger: AutomationTrigger
    /// Login of the bot whose review fired a `.comment` run.
    public var author: String?
    public var startedAt: Date
    /// Nil while the command is still running.
    public var finishedAt: Date?
    public var state: AutomationState
    /// Why it failed, in the words the runner used. Nil unless `state` is `.failed`.
    public var reason: String?
    /// The directory it wrote into, once it produced something.
    public var artifactPath: String?

    public init(
        id: String, taskId: String, title: String, url: String? = nil,
        trigger: AutomationTrigger, author: String? = nil, startedAt: Date,
        finishedAt: Date? = nil, state: AutomationState = .running, reason: String? = nil,
        artifactPath: String? = nil
    ) {
        self.id = id
        self.taskId = taskId
        self.title = title
        self.url = url
        self.trigger = trigger
        self.author = author
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.state = state
        self.reason = reason
        self.artifactPath = artifactPath
    }

    /// The id of a run whose trigger is the row itself — an arrival or a
    /// label. The task runs at most once until it is reset, and the timestamp
    /// keeps a reset-and-rerun from colliding with the first run's row. A
    /// comment run carries its event's id instead, which is what makes one
    /// review fire once.
    public static func startId(trigger: AutomationTrigger, taskId: String, now: Date) -> String {
        "\(trigger.idPrefix):\(taskId)@\(Int(now.timeIntervalSince1970 * 1000))"
    }

    /// How long a finished run stays on the board.
    public static let displayWindow: TimeInterval = 24 * 3600

    /// True while the run should still be on the board: running, or finished
    /// within the last day.
    public func isDisplayed(now: Date = Date()) -> Bool {
        guard let finishedAt else { return true }
        return now.timeIntervalSince(finishedAt) < Self.displayWindow
    }
}
