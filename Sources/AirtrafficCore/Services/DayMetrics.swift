import Foundation

/// The numbers behind the day's figures.
///
/// Everything here is computed from the scanned facts, never from the LLM: a
/// figure that disagrees with the text would be worse than no figure at all.
public struct DayMetrics: Sendable {
    /// One piece of work on the day's timeline.
    public struct Bar: Sendable, Identifiable {
        public var id: String
        public var title: String
        public var state: DailyReporter.ActivityState
        public var start: Date
        public var end: Date
        public var sessionCount: Int

        public init(
            id: String, title: String, state: DailyReporter.ActivityState,
            start: Date, end: Date, sessionCount: Int
        ) {
            self.id = id
            self.title = title
            self.state = state
            self.start = start
            self.end = end
            self.sessionCount = sessionCount
        }
    }

    /// Work bars, in reading order: earliest first.
    public var timeline: [Bar]
    /// The window the timeline is drawn in.
    public var dayStart: Date
    public var now: Date
    /// How the day's work split against the plan.
    public var plannedWorked: Int
    public var plannedUntouched: Int
    public var unplanned: Int
    /// Commits per repository, largest first.
    public var commits: [RepoCommits]
    /// Tasks the user finished today.
    public var completedTasks: Int
    /// Sessions behind the day's work, after merging by target: the number of
    /// separate agent conversations the day took.
    public var sessions: Int

    /// How many bars a timeline shows before the rest are dropped. Beyond a
    /// handful the rows stop being readable, and the entry lists carry the
    /// detail anyway.
    public static let barLimit = 8

    public init(
        timeline: [Bar] = [], dayStart: Date, now: Date,
        plannedWorked: Int = 0, plannedUntouched: Int = 0, unplanned: Int = 0,
        commits: [RepoCommits] = [], completedTasks: Int = 0, sessions: Int = 0
    ) {
        self.timeline = timeline
        self.dayStart = dayStart
        self.now = now
        self.plannedWorked = plannedWorked
        self.plannedUntouched = plannedUntouched
        self.unplanned = unplanned
        self.commits = commits
        self.completedTasks = completedTasks
        self.sessions = sessions
    }

    /// Total commits across every repository touched today.
    public var commitTotal: Int { commits.reduce(0) { $0 + $1.total } }

    /// Pieces of work the day touched, planned or not.
    public var workItems: Int { plannedWorked + unplanned }

    /// True when there is nothing worth drawing.
    public var isEmpty: Bool { timeline.isEmpty && commits.isEmpty }

    /// The earliest hour the timeline needs to show, floored to the hour, so a
    /// day that started at 14:00 does not draw fourteen empty hours.
    public var windowStart: Date {
        guard let earliest = timeline.map(\.start).min() else { return dayStart }
        return max(
            dayStart,
            Calendar.current.date(
                bySettingHour: Calendar.current.component(.hour, from: earliest),
                minute: 0, second: 0, of: earliest) ?? earliest)
    }

    /// Builds the figures from the day's comparison and commits.
    ///
    /// Bars are chosen by how long the work ran, then put back into time order:
    /// the timeline is for seeing where the day went, so the longest stretches
    /// are the ones that must survive the cut.
    public static func build(
        plan: DailyReporter.PlanComparison, commits: [RepoCommits], completedTasks: Int = 0,
        now: Date = Date(), calendar: Calendar = .current
    ) -> DayMetrics {
        let planned = plan.worked.flatMap(\.activity)
        let items = planned + plan.unplanned
        let bars =
            items
            .sorted {
                $0.lastActivity.timeIntervalSince($0.firstActivity)
                    > $1.lastActivity.timeIntervalSince($1.firstActivity)
            }
            .prefix(barLimit)
            .map {
                Bar(
                    id: $0.id, title: $0.title, state: $0.state,
                    start: $0.firstActivity, end: $0.lastActivity,
                    sessionCount: $0.sessionCount)
            }
            .sorted { $0.start < $1.start }

        return DayMetrics(
            timeline: bars, dayStart: calendar.startOfDay(for: now), now: now,
            plannedWorked: plan.worked.count, plannedUntouched: plan.untouched.count,
            unplanned: plan.unplanned.count, commits: commits,
            completedTasks: completedTasks,
            sessions: items.reduce(0) { $0 + $1.sessionCount })
    }
}
