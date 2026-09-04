import Foundation

/// The numbers behind the day's figures.
///
/// Everything here is computed from the scanned facts, never from the LLM: a
/// figure that disagrees with the text would be worse than no figure at all.
public struct DayMetrics: Sendable {
    /// Commits per repository, largest first.
    public var commits: [RepoCommits]
    /// Tasks the user finished today.
    public var completedTasks: Int
    /// Tasks planned for today that are not done yet.
    public var carryOver: Int

    public init(commits: [RepoCommits] = [], completedTasks: Int = 0, carryOver: Int = 0) {
        self.commits = commits
        self.completedTasks = completedTasks
        self.carryOver = carryOver
    }

    /// Total commits across every repository touched today.
    public var commitTotal: Int { commits.reduce(0) { $0 + $1.total } }

    /// Repositories that received a commit today.
    public var repoCount: Int { commits.count }

    /// True when there is nothing worth drawing.
    public var isEmpty: Bool { commits.isEmpty && completedTasks == 0 && carryOver == 0 }

    /// Builds the figures from the day's tasks and commits.
    public static func build(
        commits: [RepoCommits], completedTasks: Int = 0, carryOver: Int = 0
    ) -> DayMetrics {
        DayMetrics(commits: commits, completedTasks: completedTasks, carryOver: carryOver)
    }
}
