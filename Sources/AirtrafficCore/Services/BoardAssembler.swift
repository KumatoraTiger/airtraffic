import Foundation

/// One row on the board: a unit of work. A persistent task when the user has
/// one, with any live sessions attached as its executions; or, for work that
/// only exists as agent activity, the sessions alone.
public struct BoardEntry: Identifiable, Sendable {
    public var id: String
    /// Nil for auto-materialized entries (session activity with no task).
    public var task: TaskItem?
    /// Executions attached to this entry, most recent activity first.
    public var sessions: [SessionSnapshot]
    /// What this work *is* ("レビュー: 認証APIの差分"), when the LLM has
    /// labeled it. Nil until then; everything falls back to session titles.
    public var label: WorkLabel?
    /// Subtask rows hanging under this one, in sibling order. Only one level
    /// deep: a child's own `children` is always empty.
    public var children: [BoardEntry]

    public init(
        id: String, task: TaskItem?, sessions: [SessionSnapshot], label: WorkLabel? = nil,
        children: [BoardEntry] = []
    ) {
        self.id = id
        self.task = task
        self.sessions = sessions
        self.label = label
        self.children = children
    }

    /// This row and its subtask rows, for callers that count work rather than
    /// display it (the waiting badge, the menu bar).
    public var selfAndChildren: [BoardEntry] { [self] + children }

    /// How many subtasks are done, out of how many. Nil without subtasks.
    public var subtaskProgress: (done: Int, total: Int)? {
        let open = children.compactMap(\.task).filter { $0.status != .archived }
        guard !open.isEmpty else { return nil }
        return (open.filter { $0.status == .done }.count, open.count)
    }

    public var title: String {
        if let task { return task.title }
        if let label, !label.isPlaceholder { return label.subject }
        let raw = sessions.first?.title ?? ""
        if TitleCleaner.isPlaceholder(raw) { return "無題のセッション" }
        let title = TitleCleaner.taskLabel(raw)
        return title.isEmpty ? "無題のセッション" : title
    }

    /// Aggregate execution state: the most urgent status among attached
    /// sessions, nil when nothing is attached.
    public var liveStatus: SessionStatus? {
        sessions.min { $0.status.sortOrder < $1.status.sortOrder }?.status
    }

    public var lastActivity: Date? {
        sessions.map(\.lastActivity).max()
    }

    /// True while at least one execution is neither finished nor gone quiet.
    public var isLive: Bool {
        guard let liveStatus else { return false }
        return liveStatus != .idle
    }

    /// How long a taskless entry stays among the live activity after its last
    /// update. Beyond this the work is treated as finished and moves to 完了.
    public static let activityWindow: TimeInterval = 24 * 3600

    /// True while the entry saw any activity within the last 24 hours.
    public func isRecent(now: Date = Date()) -> Bool {
        guard let lastActivity else { return false }
        return now.timeIntervalSince(lastActivity) < Self.activityWindow
    }
}

/// Builds the board's unified rows from persistent tasks and scanned sessions.
///
/// Matching is deliberately conservative: explicit links first, then work
/// label / title similarity. A session that matches nothing becomes its own
/// entry, so a failed match costs one extra row, never lost information.
/// Unmatched sessions doing the same work collapse into one entry, which
/// also absorbs re-imports of the same conversation under another agent.
public enum BoardAssembler {
    public static func assemble(
        tasks: [TaskItem], sessions: [SessionSnapshot], labels: [String: WorkLabel] = [:]
    ) -> [BoardEntry] {
        var remaining = sessions
        var entries: [BoardEntry] = []
        // A subtask whose parent is gone (archived, deleted) would otherwise
        // vanish from the board, so it is treated as a top-level task.
        let known = Set(tasks.map(\.id))

        for task in tasks {
            var attached: [SessionSnapshot] = []
            remaining.removeAll { session in
                guard attaches(session, to: task, labels: labels)
                else { return false }
                attached.append(session)
                return true
            }
            let sorted = sort(attached)
            entries.append(
                BoardEntry(
                    id: task.id, task: task, sessions: sorted,
                    label: sorted.compactMap { labels[$0.id] }.first { !$0.isPlaceholder }))
        }

        entries = nest(entries, known: known)

        var groups: [String: [SessionSnapshot]] = [:]
        for session in remaining {
            groups[groupKey(session, labels: labels), default: []].append(session)
        }
        let autoEntries = groups.map { key, group -> BoardEntry in
            let sorted = sort(group)
            return BoardEntry(
                id: "session-\(key)", task: nil, sessions: sorted,
                label: sorted.compactMap { labels[$0.id] }.first { !$0.isPlaceholder })
        }
        // Dictionary order is arbitrary; give auto entries a stable order here
        // so the view layer only sorts sections, not rows.
        entries.append(
            contentsOf: autoEntries.sorted {
                ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast)
            })
        return entries
    }

    /// Hangs subtask rows under their parent row, keeping both the parent
    /// order and the sibling order the caller passed in.
    private static func nest(_ entries: [BoardEntry], known: Set<String>) -> [BoardEntry] {
        var childrenByParent: [String: [BoardEntry]] = [:]
        for entry in entries {
            guard let parentId = entry.task?.parentId, known.contains(parentId) else { continue }
            childrenByParent[parentId, default: []].append(entry)
        }
        guard !childrenByParent.isEmpty else { return entries }
        return entries.compactMap { entry in
            guard let task = entry.task else { return entry }
            if let parentId = task.parentId, known.contains(parentId) { return nil }
            var parent = entry
            parent.children = childrenByParent[task.id] ?? []
            return parent
        }
    }

    /// A session belongs to a task by explicit link, by raw-title similarity,
    /// or by its work label naming the same thing the task does — which is
    /// what lets "PR #123 のレビュー" pull in the session doing that review.
    ///
    /// `matchDoneByTitle` opens the title paths for finished tasks too. The
    /// board keeps them closed, so new activity sharing a done task's title
    /// stays live instead of disappearing into it; the daily report needs the
    /// opposite, because it is looking for the sessions that did today's
    /// finished work.
    public static func attaches(
        _ session: SessionSnapshot, to task: TaskItem, labels: [String: WorkLabel] = [:],
        matchDoneByTitle: Bool = false
    ) -> Bool {
        if task.sessionIds.contains(session.id) { return true }
        if task.status == .done && !matchDoneByTitle { return false }
        if TitleMatcher.isSimilar(session.title, task.title) { return true }
        guard let label = labels[session.id], !label.isPlaceholder else { return false }
        return TitleMatcher.isSimilar(label.subject, task.title)
            || TitleMatcher.isSimilar(label.displayTitle, task.title)
    }

    /// Sessions doing the same labeled work are one unit wherever they run —
    /// the label key deliberately omits cwd so the same review spread across
    /// worktrees is one row. Unlabeled sessions fall back to sharing a
    /// normalized title in the same directory; an empty title identifies
    /// nothing, so it never merges.
    private static func groupKey(_ session: SessionSnapshot, labels: [String: WorkLabel])
        -> String
    {
        if let label = labels[session.id], !label.isPlaceholder {
            return "label|\(label.kind.rawValue)|\(TitleMatcher.key(label.subject))"
        }
        // "(無題)" is not a name two sessions share, it is the absence of one.
        guard !TitleCleaner.isPlaceholder(session.title) else { return session.id }
        let titleKey = TitleMatcher.key(session.title)
        return titleKey.isEmpty ? session.id : "\(titleKey)|\(session.cwd)"
    }

    private static func sort(_ sessions: [SessionSnapshot]) -> [SessionSnapshot] {
        sessions.sorted { $0.lastActivity > $1.lastActivity }
    }
}
