import Foundation

/// Runs one GitHub pass off the main thread: read the open work, decide the
/// rows, then ask about the items that disappeared.
public actor GitHubInbox {
    /// How many vanished items are looked up in one pass. A pass that would
    /// need more leaves the rest for the next one, so a long-neglected board
    /// never fires a hundred requests at once.
    private static let closureLookupLimit = 20

    public struct Result: Sendable {
        /// Rows to write, creations and updates together.
        public var upserts: [TaskItem]
        /// Repositories seen in this pass, for the opt-out list in settings.
        public var repos: [String]
        /// False when `gh` is missing, logged out, or failing. Nothing was
        /// written and nothing should be concluded from the empty result.
        public var available: Bool
        /// The labels of each open ISSUE this pass read, by task id. Pull
        /// requests are left out: the label trigger only ever fires on an
        /// issue, and a map that also answered for pull requests would let it
        /// start on one. A task absent from the map is a task whose labels
        /// this pass knows nothing about ([[LabelTrigger.plan]]).
        public var labels: [String: [String]]

        public init(
            upserts: [TaskItem] = [], repos: [String] = [], available: Bool = true,
            labels: [String: [String]] = [:]
        ) {
            self.upserts = upserts
            self.repos = repos
            self.available = available
            self.labels = labels
        }
    }

    private let source: GitHubSource

    public init(source: GitHubSource = GitHubSource()) {
        self.source = source
    }

    /// One pass. `existing` must include archived tasks, otherwise a row the
    /// user dismissed comes straight back.
    public func sync(
        existing: [TaskItem], settings: GitHubSettings, now: Date = Date()
    ) -> Result {
        guard let items = source.fetchOpen() else { return Result(available: false) }
        let visible = items.filter { !settings.excludedRepos.contains($0.repo) }
        var upserts = GitHubTaskSync.upserts(
            open: items, existing: existing, settings: settings, now: now)

        let openIds = Set(visible.map(\.taskId))
        // A task from an excluded repository is not stale, it is out of scope:
        // its item never appears in `visible`, so it must not be looked up.
        let stale = Array(
            GitHubTaskSync.staleTasks(existing: existing, openIds: openIds)
                .filter { task in
                    guard let reference = GitHubItem.reference(taskId: task.id) else { return true }
                    return !settings.excludedRepos.contains(reference.repo)
                }
                .prefix(Self.closureLookupLimit))
        if settings.closeBehavior != .keep, !stale.isEmpty {
            var closures: [String: GitHubClosure] = [:]
            for task in stale {
                guard let reference = GitHubItem.reference(taskId: task.id) else { continue }
                closures[task.id] = source.closure(repo: reference.repo, number: reference.number)
            }
            upserts += GitHubTaskSync.closedUpdates(
                stale: stale, closures: closures, settings: settings, now: now)
        }

        let repos = Array(Set(items.map(\.repo))).sorted()
        var labels: [String: [String]] = [:]
        for item in items where !item.isPullRequest {
            labels[item.taskId] = item.labels
        }
        return Result(upserts: upserts, repos: repos, available: true, labels: labels)
    }

    /// Asks GitHub what a bot has said on each candidate pull request, and
    /// returns the events worth running a command for.
    ///
    /// One request per pull request, off the main thread like the rest of this
    /// actor. A pull request GitHub could not answer for is skipped rather
    /// than treated as "no comments": silence here must never look like an
    /// answer, the same rule `fetchOpen` follows.
    ///
    /// The checks are asked about second, and only for a pull request that
    /// actually has an unhandled event. Most passes find none, so the extra
    /// request is rare rather than one per pull request per pass.
    public func commentEvents(
        candidates: [TaskItem], recorded: Set<String>, now: Date = Date()
    ) -> [CommentEvent] {
        var events: [CommentEvent] = []
        for task in candidates {
            guard let reference = GitHubItem.reference(taskId: task.id) else { continue }
            guard
                let comments = source.reviewComments(
                    repo: reference.repo, number: reference.number)
            else { continue }
            guard let event = CommentTrigger.event(task: task, comments: comments, now: now) else {
                continue
            }
            // `CommentTrigger.select` filters these again and is the authority
            // on what runs. Here it only saves the request below.
            guard !recorded.contains(event.id) else { continue }
            let checks = source.checks(repo: reference.repo, number: reference.number)
            guard CommentTrigger.isReady(checks: checks) else { continue }
            events.append(event)
        }
        return events
    }
}
