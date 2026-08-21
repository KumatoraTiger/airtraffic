import Foundation

/// Turns a status change asked on one task into every row that has to be
/// written. A parent carries its subtasks with it: checking off 「認証を直す」
/// means the steps under it are over too, so they are completed with it
/// instead of being left behind as open work nobody will ever tick.
public enum TaskStatusChange {
    /// The tasks to persist, the changed task first. Reopening a parent does
    /// not reopen anything: a subtask may well have been finished on its own,
    /// and resurrecting it would undo work the user recorded.
    public static func apply(
        _ status: TaskStatus, to task: TaskItem, in tasks: [TaskItem], now: Date = Date()
    ) -> [TaskItem] {
        var updated = task
        updated.status = status
        updated.updatedAt = now
        // The completion timestamp follows the done state: reopening clears
        // it, so the daily report never counts a reopened task as finished.
        if status == .done {
            updated.completedAt = task.status == .done ? task.completedAt : now
        } else {
            updated.completedAt = nil
        }
        guard status == .done, !task.isSubtask else { return [updated] }
        let open = tasks.filter {
            $0.parentId == task.id && $0.status != .done && $0.status != .archived
        }
        return [updated]
            + open.map { child in
                var done = child
                done.status = .done
                done.updatedAt = now
                done.completedAt = now
                return done
            }
    }
}
