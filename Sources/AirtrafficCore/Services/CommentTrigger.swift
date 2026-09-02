import Foundation

/// One run's worth of "a bot reviewed the user's pull request".
///
/// The event is per pull request, not per comment: a review bot posts a dozen
/// inline comments in one go, and starting a dozen agents for one review is
/// the failure mode this type exists to avoid. The newest comment of the batch
/// names the event, so the next batch is a different event and runs again.
public struct CommentEvent: Sendable, Equatable {
    public var taskId: String
    public var repo: String
    public var number: Int
    /// GitHub's id of the newest bot comment in the batch.
    public var commentId: Int
    /// Link to that comment.
    public var url: String
    /// Login of the bot that wrote it.
    public var author: String

    public init(
        taskId: String, repo: String, number: Int, commentId: Int, url: String, author: String
    ) {
        self.taskId = taskId
        self.repo = repo
        self.number = number
        self.commentId = commentId
        self.url = url
        self.author = author
    }

    /// The key that makes the run happen once. Stored before the command
    /// starts, so a crash mid-run never turns into a second run.
    public var id: String { "ghc:\(repo)#\(number)@\(commentId)" }
}

/// Where a pull request's checks stand, as far as the trigger cares.
public enum ChecksState: Sendable, Equatable {
    /// Nothing is running any more, whether it passed or failed.
    case complete
    /// Something is still queued or running.
    case pending
    /// The pull request has no checks at all.
    case none
}

/// What one pass decided to do with the events it found.
public struct CommentSelection: Sendable, Equatable {
    /// Events whose command runs now.
    public var run: [CommentEvent]
    /// Events held back because the pull request hit its daily limit. Shown to
    /// the user rather than dropped silently: this is the case where a bot and
    /// an agent are pushing each other back and forth.
    public var blocked: [CommentEvent]

    public init(run: [CommentEvent] = [], blocked: [CommentEvent] = []) {
        self.run = run
        self.blocked = blocked
    }
}

/// The rules behind "a bot reviewed my pull request, run my command".
///
/// Pure like `TaskAutomation` and `GitHubTaskSync`: which rows are worth
/// asking about, and which answer counts as an event, are decided without
/// touching the network, so this repository's harness can test them.
public enum CommentTrigger {
    /// How long after the newest bot comment the event becomes eligible.
    ///
    /// A review bot writes its comments over a minute or two. Firing on the
    /// first one would run the command against half a review and then run it
    /// again on the rest, so the batch is given time to finish.
    ///
    /// Generous, because on a pull request that has checks this is only the
    /// backstop: `ChecksState` is the real signal, and waiting a few extra
    /// minutes costs nothing on a pull request that has none.
    public static let settle: TimeInterval = 300

    /// A comment older than this never fires.
    ///
    /// Without it, turning the feature on would start one agent per open pull
    /// request that was ever reviewed by a bot.
    public static let maxAge: TimeInterval = 24 * 3600

    /// How many pull requests are asked about in one pass, and how many events
    /// are allowed to run from it.
    public static let pollLimit = 20
    public static let runLimit = 3

    /// The window the per-pull-request limit counts over.
    public static let dailyWindow: TimeInterval = 24 * 3600

    /// Whether an account that wrote a comment is a bot.
    ///
    /// GitHub types App accounts as `Bot` and suffixes their login with
    /// `[bot]`. Either is enough: the type is authoritative, and the suffix
    /// covers the places the type is absent from the payload.
    public static func isBot(login: String, type: String?) -> Bool {
        if let type, type.caseInsensitiveCompare("Bot") == .orderedSame { return true }
        return login.hasSuffix("[bot]")
    }

    /// The task rows worth asking GitHub about.
    ///
    /// Only pull requests the user opened: a review request is somebody else's
    /// pull request, and the bot's comments on it are not the user's to answer.
    public static func candidates(
        tasks: [TaskItem], settings: AutomationSettings, limit: Int = pollLimit
    ) -> [TaskItem] {
        guard settings.enabled, settings.commentTrigger else { return [] }
        guard !TaskAutomation.tokenize(settings.commentCommandLine).isEmpty else { return [] }
        return Array(
            tasks.filter { task in
                guard task.source == .github else { return false }
                guard task.status != .archived, task.status != .done else { return false }
                guard GitHubTaskSync.relation(fromDetail: task.detail) == .authored else {
                    return false
                }
                guard let reference = GitHubItem.reference(taskId: task.id) else { return false }
                return settings.allowedRepos.contains(reference.repo)
            }
            .prefix(limit))
    }

    /// The event one pull request's comments amount to, or nil when there is
    /// nothing to run for: no bot comment, one too fresh to be the whole
    /// review, or one old enough to belong to a review the user already read.
    public static func event(
        task: TaskItem, comments: [GitHubComment], now: Date = Date()
    ) -> CommentEvent? {
        guard let reference = GitHubItem.reference(taskId: task.id) else { return nil }
        guard let newest = comments.filter(\.isBot).max(by: { $0.createdAt < $1.createdAt })
        else { return nil }
        let age = now.timeIntervalSince(newest.createdAt)
        guard age >= settle, age <= maxAge else { return nil }
        guard TaskAutomation.isGitHubURL(newest.url) else { return nil }
        return CommentEvent(
            taskId: task.id, repo: reference.repo, number: reference.number,
            commentId: newest.id, url: newest.url, author: newest.author)
    }

    /// What a pull request's check rollup amounts to.
    ///
    /// A check whose shape says nothing recognisable counts as still running:
    /// the cost of waiting one more pass is a delay, the cost of guessing
    /// "finished" is an agent started on a pull request mid-build.
    public static func checksState(_ checks: [GitHubCheck]) -> ChecksState {
        guard !checks.isEmpty else { return .none }
        let running = checks.contains { check in
            if let status = check.status { return status.uppercased() != "COMPLETED" }
            if let state = check.state {
                return ["PENDING", "EXPECTED"].contains(state.uppercased())
            }
            return true
        }
        return running ? .pending : .complete
    }

    /// Whether a pull request's checks allow the command to start.
    ///
    /// A failing check does not hold it back: a red build is part of what the
    /// command is being started to deal with. Nil means GitHub could not be
    /// asked, and silence must never read as "nothing is running".
    public static func isReady(checks: [GitHubCheck]?) -> Bool {
        guard let checks else { return false }
        switch checksState(checks) {
        case .complete, .none: return true
        case .pending: return false
        }
    }

    /// The events to run now, and the ones held back by the per-pull-request
    /// limit.
    ///
    /// The limit is what stops the loop this trigger can create: the command
    /// pushes a fix, the bot reviews the push, and that is a new event. It
    /// usually converges, but nothing in the mechanism says it has to.
    public static func select(
        events: [CommentEvent], recorded: Set<String>, runsToday: [String: Int],
        settings: AutomationSettings, limit: Int = runLimit
    ) -> CommentSelection {
        var selection = CommentSelection()
        for event in events where !recorded.contains(event.id) {
            guard runsToday[event.taskId, default: 0] < settings.commentDailyLimit else {
                selection.blocked.append(event)
                continue
            }
            guard selection.run.count < limit else { continue }
            selection.run.append(event)
        }
        return selection
    }
}
