import Foundation

/// Persistent store for tasks, preferences, and scan cursors.
///
/// Sessions themselves are not the source of truth here — transcripts on disk are.
/// The store keeps only what must survive across scans and app restarts.
public actor Store {
    private let db: SQLiteDatabase

    public init(path: String) throws {
        db = try SQLiteDatabase(path: path)
        try Self.migrate(db)
    }

    public static func defaultPath() -> String {
        let base = AppDirectories.support()
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("airtraffic.sqlite").path
    }

    private static func migrate(_ db: SQLiteDatabase) throws {
        try db.execute(
            """
            CREATE TABLE IF NOT EXISTS tasks (
                id TEXT PRIMARY KEY,
                title TEXT NOT NULL,
                detail TEXT NOT NULL DEFAULT '',
                status TEXT NOT NULL DEFAULT 'todo',
                rank INTEGER,
                source TEXT NOT NULL DEFAULT 'manual',
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            );
            """)
        try db.execute(
            """
            CREATE TABLE IF NOT EXISTS task_session_links (
                task_id TEXT NOT NULL,
                session_id TEXT NOT NULL,
                PRIMARY KEY (task_id, session_id)
            );
            """)
        // The LLM-proposal feature is gone; its leftover table goes with it.
        // Proposals were ephemeral (72h expiry) and kept ones live on as tasks.
        try db.execute("DROP TABLE IF EXISTS candidates")
        try Self.migrateTaskIsToday(db)
        try Self.migrateTaskCompletedAt(db)
        try Self.migrateTaskParentId(db)
        try Self.migrateTaskAutomation(db)
        try Self.migrateAutomationRuns(db)
        try db.execute(
            """
            CREATE TABLE IF NOT EXISTS preferences (
                id TEXT PRIMARY KEY,
                text TEXT NOT NULL,
                created_at REAL NOT NULL
            );
            """)
        try db.execute(
            """
            CREATE TABLE IF NOT EXISTS cursors (
                file_path TEXT PRIMARY KEY,
                byte_offset INTEGER NOT NULL DEFAULT 0,
                extracted_offset INTEGER NOT NULL DEFAULT 0
            );
            """)
        try db.execute(
            """
            CREATE TABLE IF NOT EXISTS session_labels (
                session_id TEXT PRIMARY KEY,
                kind TEXT NOT NULL,
                subject TEXT NOT NULL,
                updated_at REAL NOT NULL,
                labeled_activity REAL NOT NULL
            );
            """)
    }

    /// Adds the today flag behind the board's 「今日やる」 section.
    private static func migrateTaskIsToday(_ db: SQLiteDatabase) throws {
        let columns = try db.query("PRAGMA table_info(tasks)").map { $0.text("name") }
        guard !columns.contains("is_today") else { return }
        try db.execute("ALTER TABLE tasks ADD COLUMN is_today INTEGER NOT NULL DEFAULT 0")
    }

    /// Records when a task entered `done`, so the daily report can tell
    /// today's completions apart from tasks merely edited today.
    private static func migrateTaskCompletedAt(_ db: SQLiteDatabase) throws {
        let columns = try db.query("PRAGMA table_info(tasks)").map { $0.text("name") }
        guard !columns.contains("completed_at") else { return }
        try db.execute("ALTER TABLE tasks ADD COLUMN completed_at REAL")
    }

    /// Adds the parent link behind subtasks. Existing tasks stay top-level.
    private static func migrateTaskParentId(_ db: SQLiteDatabase) throws {
        let columns = try db.query("PRAGMA table_info(tasks)").map { $0.text("name") }
        guard !columns.contains("parent_id") else { return }
        try db.execute("ALTER TABLE tasks ADD COLUMN parent_id TEXT")
    }

    /// Creates the run history behind the board's 自動実行 section, absorbing
    /// the older `automation_events` table whose rows only said "this comment
    /// already fired". Those rows become comment runs whose outcome is read
    /// off the task, since nothing else recorded it at the time.
    ///
    /// The old table is left in place, not dropped: an installed build still
    /// running the old schema shares this file, and losing the table would
    /// make it forget which reviews it already answered.
    private static func migrateAutomationRuns(_ db: SQLiteDatabase) throws {
        try db.execute(
            """
            CREATE TABLE IF NOT EXISTS automation_runs (
                id TEXT PRIMARY KEY,
                task_id TEXT NOT NULL,
                title TEXT NOT NULL DEFAULT '',
                url TEXT,
                trigger TEXT NOT NULL,
                author TEXT,
                started_at REAL NOT NULL,
                finished_at REAL,
                state TEXT NOT NULL,
                reason TEXT,
                artifact_path TEXT,
                relation TEXT
            );
            """)
        // The kind of GitHub row a run fired on, so the board's badge can name
        // it. Rows written before this column answer nil, which reads as "an
        // older build did not record it" and falls back to the trigger's name.
        let columns = try db.query("PRAGMA table_info(automation_runs)").map { $0.text("name") }
        if !columns.contains("relation") {
            try db.execute("ALTER TABLE automation_runs ADD COLUMN relation TEXT")
        }
        let tables = try db.query("SELECT name FROM sqlite_master WHERE type = 'table'")
            .map { $0.text("name") }
        guard tables.contains("automation_events") else { return }
        try db.execute(
            """
            INSERT OR IGNORE INTO automation_runs
                (id, task_id, title, url, trigger, author, started_at, finished_at, state, reason, artifact_path)
            SELECT e.id, e.task_id, COALESCE(t.title, ''), NULL, 'comment', NULL, e.created_at,
                e.created_at, COALESCE(t.automation_state, 'done'), NULL, t.artifact_path
            FROM automation_events e LEFT JOIN tasks t ON t.id = e.task_id
            """)
    }

    /// Adds the automation columns behind the per-task command. Existing
    /// tasks have no state, which is exactly "never ran".
    private static func migrateTaskAutomation(_ db: SQLiteDatabase) throws {
        let columns = try db.query("PRAGMA table_info(tasks)").map { $0.text("name") }
        if !columns.contains("automation_state") {
            try db.execute("ALTER TABLE tasks ADD COLUMN automation_state TEXT")
        }
        if !columns.contains("artifact_path") {
            try db.execute("ALTER TABLE tasks ADD COLUMN artifact_path TEXT")
        }
    }

    // MARK: - Cursors

    /// Byte offset up to which a transcript file has been parsed.
    public func cursor(for filePath: String) throws -> Int64 {
        let rows = try db.query("SELECT byte_offset FROM cursors WHERE file_path = ?", [.text(filePath)])
        return rows.first?.int("byte_offset") ?? 0
    }

    public func setCursor(_ offset: Int64, for filePath: String) throws {
        try db.execute(
            """
            INSERT INTO cursors (file_path, byte_offset) VALUES (?, ?)
            ON CONFLICT(file_path) DO UPDATE SET byte_offset = excluded.byte_offset
            """, [.text(filePath), .int(offset)])
    }

    // MARK: - Tasks

    public func tasks(includeArchived: Bool = false) throws -> [TaskItem] {
        let filter = includeArchived ? "" : "WHERE status != 'archived'"
        let rows = try db.query(
            """
            SELECT * FROM tasks \(filter)
            ORDER BY rank IS NULL, rank ASC, created_at DESC
            """)
        let links = try db.query("SELECT task_id, session_id FROM task_session_links")
        var sessionsByTask: [String: [String]] = [:]
        for link in links {
            sessionsByTask[link.text("task_id"), default: []].append(link.text("session_id"))
        }
        return rows.map { row in
            TaskItem(
                id: row.text("id"),
                title: row.text("title"),
                detail: row.text("detail"),
                status: TaskStatus(rawValue: row.text("status")) ?? .todo,
                rank: row.intOrNil("rank").map(Int.init),
                isToday: row.int("is_today") != 0,
                source: TaskSource(rawValue: row.text("source")) ?? .manual,
                createdAt: Date(timeIntervalSince1970: row.real("created_at")),
                updatedAt: Date(timeIntervalSince1970: row.real("updated_at")),
                completedAt: row.realOrNil("completed_at").map(Date.init(timeIntervalSince1970:)),
                parentId: row.textOrNil("parent_id"),
                sessionIds: sessionsByTask[row.text("id")] ?? [],
                automationState: row.textOrNil("automation_state")
                    .flatMap(AutomationState.init(rawValue:)),
                artifactPath: row.textOrNil("artifact_path")
            )
        }
    }

    public func upsertTask(_ task: TaskItem) throws {
        try db.execute(
            """
            INSERT INTO tasks (id, title, detail, status, rank, is_today, source, created_at, updated_at, completed_at, parent_id)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                title = excluded.title, detail = excluded.detail, status = excluded.status,
                rank = excluded.rank, is_today = excluded.is_today, updated_at = excluded.updated_at,
                completed_at = excluded.completed_at, parent_id = excluded.parent_id
            """,
            [
                .text(task.id), .text(task.title), .text(task.detail), .text(task.status.rawValue),
                task.rank.map { .int(Int64($0)) } ?? .null,
                .int(task.isToday ? 1 : 0),
                .text(task.source.rawValue),
                .real(task.createdAt.timeIntervalSince1970),
                .real(task.updatedAt.timeIntervalSince1970),
                task.completedAt.map { .real($0.timeIntervalSince1970) } ?? .null,
                task.parentId.map { .text($0) } ?? .null,
            ])
        for sessionId in task.sessionIds {
            try db.execute(
                """
                INSERT OR IGNORE INTO task_session_links (task_id, session_id) VALUES (?, ?)
                """, [.text(task.id), .text(sessionId)])
        }
    }

    /// Records what the per-task command did. Deliberately separate from
    /// `upsertTask`: the GitHub pass rewrites a row's title and link on every
    /// scan, and it must not carry a stale automation state back with it.
    public func setAutomation(
        taskId: String, state: AutomationState?, artifactPath: String? = nil
    ) throws {
        try db.execute(
            "UPDATE tasks SET automation_state = ?, artifact_path = ? WHERE id = ?",
            [
                state.map { .text($0.rawValue) } ?? .null,
                artifactPath.map { .text($0) } ?? .null,
                .text(taskId),
            ])
    }

    // MARK: - Automation runs

    /// Every comment event whose command was already started.
    ///
    /// The key of an event is the comment that caused it, so this set is what
    /// makes one bot review run the command once and not once per pass.
    public func automationEventIds() throws -> Set<String> {
        Set(
            try db.query("SELECT id FROM automation_runs WHERE trigger = 'comment'")
                .map { $0.text("id") })
    }

    /// Records a run as started. Written BEFORE the command runs: a crash
    /// mid-run has to look like "already handled", never like "never ran".
    public func recordAutomationRun(_ run: AutomationRun) throws {
        try db.execute(
            """
            INSERT OR IGNORE INTO automation_runs
                (id, task_id, title, url, trigger, author, started_at, finished_at, state, reason, artifact_path, relation)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                .text(run.id), .text(run.taskId), .text(run.title),
                run.url.map { .text($0) } ?? .null,
                .text(run.trigger.rawValue),
                run.author.map { .text($0) } ?? .null,
                .real(run.startedAt.timeIntervalSince1970),
                run.finishedAt.map { .real($0.timeIntervalSince1970) } ?? .null,
                .text(run.state.rawValue),
                run.reason.map { .text($0) } ?? .null,
                run.artifactPath.map { .text($0) } ?? .null,
                run.relation.map { .text($0.rawValue) } ?? .null,
            ])
    }

    /// Records how a run ended.
    public func finishAutomationRun(
        id: String, state: AutomationState, reason: String? = nil, artifactPath: String? = nil,
        now: Date = Date()
    ) throws {
        try db.execute(
            """
            UPDATE automation_runs SET finished_at = ?, state = ?, reason = ?, artifact_path = ?
            WHERE id = ?
            """,
            [
                .real(now.timeIntervalSince1970), .text(state.rawValue),
                reason.map { .text($0) } ?? .null,
                artifactPath.map { .text($0) } ?? .null,
                .text(id),
            ])
    }

    /// Marks every run still `running` as failed, along with the task rows
    /// that say the same. Only the app starts these commands and nothing
    /// survives its exit, so at launch a `running` row can only be a run the
    /// previous process never got to finish writing.
    public func interruptRunningAutomation(now: Date = Date()) throws {
        try db.execute(
            """
            UPDATE automation_runs SET finished_at = ?, state = 'failed', reason = ?
            WHERE state = 'running'
            """, [.real(now.timeIntervalSince1970), .text(Self.interruptedReason)])
        try db.execute(
            "UPDATE tasks SET automation_state = 'failed' WHERE automation_state = 'running'")
    }

    public static let interruptedReason = "アプリの終了で中断されました"

    /// The most recent runs, newest first.
    public func automationRuns(limit: Int = 50) throws -> [AutomationRun] {
        let rows = try db.query(
            "SELECT * FROM automation_runs ORDER BY started_at DESC LIMIT ?", [.int(Int64(limit))])
        return rows.map { row in
            AutomationRun(
                id: row.text("id"), taskId: row.text("task_id"), title: row.text("title"),
                url: row.textOrNil("url"),
                trigger: AutomationTrigger(rawValue: row.text("trigger")) ?? .comment,
                author: row.textOrNil("author"),
                startedAt: Date(timeIntervalSince1970: row.real("started_at")),
                finishedAt: row.realOrNil("finished_at").map(Date.init(timeIntervalSince1970:)),
                state: AutomationState(rawValue: row.text("state")) ?? .failed,
                reason: row.textOrNil("reason"),
                artifactPath: row.textOrNil("artifact_path"),
                relation: row.textOrNil("relation").flatMap(GitHubRelation.init(rawValue:)))
        }
    }

    /// How many comment runs each task fired inside the window, for the
    /// per-pull-request daily limit. Counted from the same rows the dedupe
    /// uses, so a run that was started and then crashed still counts.
    public func automationEventCounts(since: Date) throws -> [String: Int] {
        let rows = try db.query(
            """
            SELECT task_id, COUNT(*) AS runs FROM automation_runs
            WHERE trigger = 'comment' AND started_at >= ? GROUP BY task_id
            """, [.real(since.timeIntervalSince1970)])
        var counts: [String: Int] = [:]
        for row in rows { counts[row.text("task_id")] = Int(row.int("runs")) }
        return counts
    }

    /// Housekeeping only: a run this old names a comment no pass will see
    /// again, and has long left the board.
    public func pruneAutomationRuns(olderThan age: TimeInterval, now: Date = Date()) throws {
        try db.execute(
            "DELETE FROM automation_runs WHERE started_at < ?",
            [.real(now.timeIntervalSince1970 - age)])
    }

    /// Forgets output directories `ArtifactPruner` has deleted, so no row goes
    /// on offering a folder button that opens nothing.
    ///
    /// The one place besides `setAutomation` that writes a task's automation
    /// columns, and deliberately narrow: it clears the path and leaves the
    /// state alone, because a run that succeeded a month ago still succeeded.
    public func clearArtifactPaths(_ paths: [String]) throws {
        for path in paths {
            try db.execute(
                "UPDATE tasks SET artifact_path = NULL WHERE artifact_path = ?", [.text(path)])
            try db.execute(
                "UPDATE automation_runs SET artifact_path = NULL WHERE artifact_path = ?",
                [.text(path)])
        }
    }

    /// Writes a task back exactly as it was, links included. Unlike
    /// `upsertTask`, which only ever adds links, this also drops the links the
    /// row no longer carries — the way a session linked to the wrong task is
    /// unlinked again.
    public func restoreTask(_ task: TaskItem) throws {
        try db.execute("DELETE FROM task_session_links WHERE task_id = ?", [.text(task.id)])
        try upsertTask(task)
        try setAutomation(
            taskId: task.id, state: task.automationState, artifactPath: task.artifactPath)
    }

    /// Removes a task row and its session links, for undoing a task an action
    /// created. Distinct from archiving, which keeps the row on purpose.
    public func deleteTask(_ id: String) throws {
        try db.execute("DELETE FROM task_session_links WHERE task_id = ?", [.text(id)])
        try db.execute("DELETE FROM tasks WHERE id = ?", [.text(id)])
    }

    public func setRanks(_ rankedTaskIds: [String]) throws {
        for (index, taskId) in rankedTaskIds.enumerated() {
            try db.execute(
                "UPDATE tasks SET rank = ?, updated_at = ? WHERE id = ?",
                [.int(Int64(index)), .real(Date().timeIntervalSince1970), .text(taskId)])
        }
    }

    // MARK: - Work labels

    public func labels() throws -> [String: WorkLabel] {
        let rows = try db.query("SELECT * FROM session_labels")
        var labels: [String: WorkLabel] = [:]
        for row in rows {
            guard let kind = WorkKind(rawValue: row.text("kind")) else { continue }
            let sessionId = row.text("session_id")
            labels[sessionId] = WorkLabel(
                sessionId: sessionId,
                kind: kind,
                subject: row.text("subject"),
                updatedAt: Date(timeIntervalSince1970: row.real("updated_at")),
                labeledActivity: Date(timeIntervalSince1970: row.real("labeled_activity"))
            )
        }
        return labels
    }

    public func upsertLabel(_ label: WorkLabel) throws {
        try db.execute(
            """
            INSERT INTO session_labels (session_id, kind, subject, updated_at, labeled_activity)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(session_id) DO UPDATE SET
                kind = excluded.kind, subject = excluded.subject,
                updated_at = excluded.updated_at, labeled_activity = excluded.labeled_activity
            """,
            [
                .text(label.sessionId), .text(label.kind.rawValue), .text(label.subject),
                .real(label.updatedAt.timeIntervalSince1970),
                .real(label.labeledActivity.timeIntervalSince1970),
            ])
    }

    /// Housekeeping only: a label whose session has not moved for this long
    /// belongs to a transcript the board will never show again.
    public func pruneLabels(olderThan age: TimeInterval, now: Date = Date()) throws {
        try db.execute(
            "DELETE FROM session_labels WHERE labeled_activity < ?",
            [.real(now.timeIntervalSince1970 - age)])
    }

    // MARK: - Preferences

    public func preferences() throws -> [PreferenceNote] {
        try db.query("SELECT * FROM preferences ORDER BY created_at ASC").map { row in
            PreferenceNote(
                id: row.text("id"),
                text: row.text("text"),
                createdAt: Date(timeIntervalSince1970: row.real("created_at"))
            )
        }
    }

    public func insertPreference(_ text: String) throws {
        try db.execute(
            "INSERT INTO preferences (id, text, created_at) VALUES (?, ?, ?)",
            [.text(UUID().uuidString), .text(text), .real(Date().timeIntervalSince1970)])
    }

    public func deletePreference(_ id: String) throws {
        try db.execute("DELETE FROM preferences WHERE id = ?", [.text(id)])
    }
}
