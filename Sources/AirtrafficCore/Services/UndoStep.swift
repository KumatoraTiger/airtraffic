import Foundation

/// One reversible edit of the task list.
///
/// Actions are not asked to describe their own inverse: the list is diffed
/// before and after the action, and the difference is the step. Undoing it is
/// then always the same two writes — put the old rows back, drop the rows the
/// action created — whatever the action was (completing a task, hanging it
/// under another one, linking a session to the wrong task).
public struct UndoStep: Sendable, Equatable {
    /// What the action was, in the words the menu item shows.
    public let label: String
    /// Rows to write back exactly as they were, links included.
    public let restore: [TaskItem]
    /// Ids of rows the action created, to remove again.
    public let removeIds: [String]
    /// Preference notes the action recorded. A reverted move must not keep
    /// teaching the ranking prompt a decision the user took back.
    public let removePreferenceIds: [String]

    public init(
        label: String, restore: [TaskItem], removeIds: [String],
        removePreferenceIds: [String] = []
    ) {
        self.label = label
        self.restore = restore
        self.removeIds = removeIds
        self.removePreferenceIds = removePreferenceIds
    }

    /// True when the action changed nothing, so nothing is worth recording.
    public var isEmpty: Bool {
        restore.isEmpty && removeIds.isEmpty && removePreferenceIds.isEmpty
    }

    /// The step that turns `after` back into `before`.
    ///
    /// A row missing from `after` counts as changed, not as gone: the task
    /// list read from the store hides archived rows, so archiving a task looks
    /// like a disappearance and is undone by writing the row back.
    public static func between(
        before: [TaskItem], after: [TaskItem], label: String,
        addedPreferenceIds: [String] = []
    ) -> UndoStep {
        let afterById = Dictionary(after.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let beforeIds = Set(before.map(\.id))
        return UndoStep(
            label: label,
            restore: before.filter { afterById[$0.id] != $0 },
            removeIds: after.filter { !beforeIds.contains($0.id) }.map(\.id),
            removePreferenceIds: addedPreferenceIds)
    }
}
