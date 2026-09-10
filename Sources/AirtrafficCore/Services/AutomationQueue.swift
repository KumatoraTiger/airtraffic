import Foundation

/// Which planned run may start, and how many may run at once.
///
/// Every trigger plans into one queue and every running command counts
/// against one ceiling, because what decides whether the laptop stays usable
/// is the number of coding agents alive at this moment — not how many of them
/// a particular trigger started. Counting per trigger would let three
/// arrivals, three labels and three reviews add up to nine.
///
/// Two numbers, and they answer different questions. `limit` is the ceiling
/// the machine has to survive. `automaticLanes` is how much of it the app
/// helps itself to without being asked: one, so an unattended morning drains
/// the queue at the pace it always did, and the rest of the ceiling is there
/// for the runs the user starts by hand from the board.
///
/// Pure on purpose: the decision is a function of the run rows and of what
/// this process has in flight, so it can be tested without a process.
public enum AutomationQueue {
    /// How many commands may be running at the same time, whoever started
    /// them.
    public static let limit = 3

    /// How many of those the app starts on its own.
    public static let automaticLanes = 1

    /// The queue, oldest first: the order it drains in, and the order the
    /// board lists it in. `startedAt` is the moment the row was planned until
    /// the command actually starts, so for a queued row it is the waiting
    /// time.
    public static func waiting(_ runs: [AutomationRun]) -> [AutomationRun] {
        runs.filter { $0.state == .queued }.sorted { $0.startedAt < $1.startedAt }
    }

    /// The queued run the app should start by itself now, if any.
    ///
    /// `inFlight` maps the id of every run THIS process started and has not
    /// finished to the task it is working on, and `automatic` is the subset it
    /// started on its own. Only this process runs commands, so those two are
    /// the whole truth about what is alive — a `running` row in the store that
    /// is not in `inFlight` belongs to a previous process and is marked
    /// interrupted at launch.
    public static func nextAutomatic(
        runs: [AutomationRun], inFlight: [String: String], automatic: Set<String>
    ) -> AutomationRun? {
        guard automatic.count < automaticLanes, hasCapacity(inFlight: inFlight.count) else {
            return nil
        }
        return waiting(runs).first { block(run: $0, inFlight: inFlight) == nil }
    }

    /// Whether one more command may start at all.
    public static func hasCapacity(inFlight: Int) -> Bool { inFlight < limit }

    /// Why this queued run cannot start right now, in the words the board
    /// shows, or nil when it can.
    ///
    /// The same rule answers for the automatic lane and for the user's
    /// 「いま実行する」, so the button is never offered on a row the queue
    /// would refuse.
    public static func block(run: AutomationRun, inFlight: [String: String]) -> String? {
        guard run.state == .queued else { return "待機中の実行ではありません" }
        guard inFlight[run.id] == nil else { return "すでに実行中です" }
        guard !inFlight.values.contains(run.taskId) else {
            // One row writes into one output directory, and "did it write
            // anything" is decided by comparing that directory before and
            // after. Two commands in it at once would each see the other's
            // files.
            return "同じタスクのコマンドが実行中です"
        }
        guard hasCapacity(inFlight: inFlight.count) else {
            return "同時に実行できるのは \(limit) 件までです"
        }
        return nil
    }
}
