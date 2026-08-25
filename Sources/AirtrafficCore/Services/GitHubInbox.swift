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

        public init(upserts: [TaskItem] = [], repos: [String] = [], available: Bool = true) {
            self.upserts = upserts
            self.repos = repos
            self.available = available
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
        return Result(upserts: upserts, repos: repos, available: true)
    }
}
