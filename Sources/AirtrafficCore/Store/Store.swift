import Foundation

/// Persistent store for tasks, candidates, preferences, and scan cursors.
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
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Airtraffic", isDirectory: true)
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
        try db.execute(
            """
            CREATE TABLE IF NOT EXISTS candidates (
                id TEXT PRIMARY KEY,
                title TEXT NOT NULL,
                detail TEXT NOT NULL DEFAULT '',
                confidence REAL NOT NULL,
                session_id TEXT NOT NULL,
                agent TEXT NOT NULL,
                excerpt TEXT NOT NULL DEFAULT '',
                status TEXT NOT NULL DEFAULT 'pending',
                created_at REAL NOT NULL,
                reject_reason TEXT,
                dedupe_key TEXT NOT NULL DEFAULT ''
            );
            """)
        try Self.migrateCandidateDedupeKey(db)
        try Self.migrateCandidateClosedAt(db)
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

    /// Brings a pre-dedupe database up to date: adds the key column, backfills
    /// it, collapses rows that were already inserted as duplicates, and locks
    /// the column down with a unique index so no duplicate can be inserted again.
    private static func migrateCandidateDedupeKey(_ db: SQLiteDatabase) throws {
        let columns = try db.query("PRAGMA table_info(candidates)").map { $0.text("name") }
        if !columns.contains("dedupe_key") {
            try db.execute("ALTER TABLE candidates ADD COLUMN dedupe_key TEXT NOT NULL DEFAULT ''")
        }
        // Backfilled in Swift, not SQL, so the key always matches TitleMatcher.
        for row in try db.query("SELECT id, title FROM candidates WHERE dedupe_key = ''") {
            try db.execute(
                "UPDATE candidates SET dedupe_key = ? WHERE id = ?",
                [.text(TitleMatcher.key(row.text("title"))), .text(row.text("id"))])
        }
        // One row survives per key: a row the user already acted on wins over a
        // pending one, and the oldest wins among equals.
        try db.execute(
            """
            DELETE FROM candidates WHERE rowid NOT IN (
                SELECT rowid FROM (
                    SELECT rowid, ROW_NUMBER() OVER (
                        PARTITION BY dedupe_key
                        ORDER BY (status = 'pending') ASC, created_at ASC
                    ) AS position FROM candidates
                ) WHERE position = 1
            )
            """)
        try db.execute(
            "CREATE UNIQUE INDEX IF NOT EXISTS candidates_dedupe_key ON candidates(dedupe_key)")
    }

    /// Adds the close timestamp used by the board's "recently disappeared"
    /// section. Rows closed before the column existed get their creation time
    /// as the best available estimate.
    private static func migrateCandidateClosedAt(_ db: SQLiteDatabase) throws {
        let columns = try db.query("PRAGMA table_info(candidates)").map { $0.text("name") }
        guard !columns.contains("closed_at") else { return }
        try db.execute("ALTER TABLE candidates ADD COLUMN closed_at REAL")
        try db.execute("UPDATE candidates SET closed_at = created_at WHERE status != 'pending'")
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
                source: TaskSource(rawValue: row.text("source")) ?? .manual,
                createdAt: Date(timeIntervalSince1970: row.real("created_at")),
                updatedAt: Date(timeIntervalSince1970: row.real("updated_at")),
                sessionIds: sessionsByTask[row.text("id")] ?? []
            )
        }
    }

    public func upsertTask(_ task: TaskItem) throws {
        try db.execute(
            """
            INSERT INTO tasks (id, title, detail, status, rank, source, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                title = excluded.title, detail = excluded.detail, status = excluded.status,
                rank = excluded.rank, updated_at = excluded.updated_at
            """,
            [
                .text(task.id), .text(task.title), .text(task.detail), .text(task.status.rawValue),
                task.rank.map { .int(Int64($0)) } ?? .null,
                .text(task.source.rawValue),
                .real(task.createdAt.timeIntervalSince1970),
                .real(task.updatedAt.timeIntervalSince1970),
            ])
        for sessionId in task.sessionIds {
            try db.execute(
                """
                INSERT OR IGNORE INTO task_session_links (task_id, session_id) VALUES (?, ?)
                """, [.text(task.id), .text(sessionId)])
        }
    }

    public func setRanks(_ rankedTaskIds: [String]) throws {
        for (index, taskId) in rankedTaskIds.enumerated() {
            try db.execute(
                "UPDATE tasks SET rank = ?, updated_at = ? WHERE id = ?",
                [.int(Int64(index)), .real(Date().timeIntervalSince1970), .text(taskId)])
        }
    }

    // MARK: - Candidates

    public func candidates(status: CandidateStatus? = .pending) throws -> [Candidate] {
        let rows: [[String: SQLiteDatabase.Value]]
        if let status {
            rows = try db.query(
                "SELECT * FROM candidates WHERE status = ? ORDER BY created_at DESC",
                [.text(status.rawValue)])
        } else {
            rows = try db.query("SELECT * FROM candidates ORDER BY created_at DESC")
        }
        return rows.map(Self.candidate(from:))
    }

    /// Candidates that were rejected or expired, newest close first. These feed
    /// the board's "recently disappeared" section, where any of them can be
    /// reopened. Kept (accepted) candidates live on as tasks and are excluded.
    public func closedCandidates(limit: Int = 30) throws -> [Candidate] {
        let rows = try db.query(
            """
            SELECT * FROM candidates WHERE status IN ('rejected', 'expired')
            ORDER BY closed_at DESC LIMIT ?
            """, [.int(Int64(limit))])
        return rows.map(Self.candidate(from:))
    }

    private static func candidate(from row: [String: SQLiteDatabase.Value]) -> Candidate {
        Candidate(
            id: row.text("id"),
            title: row.text("title"),
            detail: row.text("detail"),
            confidence: row.real("confidence"),
            sessionId: row.text("session_id"),
            agent: AgentKind(rawValue: row.text("agent")) ?? .claudeCode,
            excerpt: row.text("excerpt"),
            status: CandidateStatus(rawValue: row.text("status")) ?? .pending,
            createdAt: Date(timeIntervalSince1970: row.real("created_at")),
            rejectReason: row.textOrNil("reject_reason"),
            closedAt: row.realOrNil("closed_at").map(Date.init(timeIntervalSince1970:))
        )
    }

    /// Inserts a candidate unless one with the same normalized title already
    /// exists in any state. Returns false when the insert was dropped as a
    /// duplicate — this is the last line of defense behind the extractor's own
    /// fuzzy filter, and the only one that survives an app restart.
    @discardableResult
    public func insertCandidate(_ candidate: Candidate) throws -> Bool {
        try db.execute(
            """
            INSERT OR IGNORE INTO candidates
                (id, title, detail, confidence, session_id, agent, excerpt, status, created_at,
                 reject_reason, dedupe_key)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                .text(candidate.id), .text(candidate.title), .text(candidate.detail),
                .real(candidate.confidence), .text(candidate.sessionId), .text(candidate.agent.rawValue),
                .text(candidate.excerpt), .text(candidate.status.rawValue),
                .real(candidate.createdAt.timeIntervalSince1970),
                candidate.rejectReason.map { .text($0) } ?? .null,
                .text(TitleMatcher.key(candidate.title)),
            ])
        return db.changes > 0
    }

    public func setCandidateStatus(
        _ id: String, _ status: CandidateStatus, rejectReason: String? = nil, now: Date = Date()
    ) throws {
        try db.execute(
            "UPDATE candidates SET status = ?, reject_reason = ?, closed_at = ? WHERE id = ?",
            [
                .text(status.rawValue), rejectReason.map { .text($0) } ?? .null,
                status == .pending ? .null : .real(now.timeIntervalSince1970), .text(id),
            ])
    }

    /// Puts a rejected or expired candidate back on the board. The creation
    /// time is reset so the reopened candidate does not expire again on the
    /// next sweep.
    public func reopenCandidate(_ id: String, now: Date = Date()) throws {
        try db.execute(
            """
            UPDATE candidates SET status = 'pending', reject_reason = NULL, closed_at = NULL,
                created_at = ? WHERE id = ?
            """, [.real(now.timeIntervalSince1970), .text(id)])
    }

    /// Titles of every candidate ever seen, whatever its state. Accepted,
    /// rejected, and expired candidates all belong here: re-proposing something
    /// the user has already dealt with is exactly what makes the board noisy.
    public func knownCandidateTitles(limit: Int = 300) throws -> [String] {
        let rows = try db.query(
            "SELECT title FROM candidates ORDER BY created_at DESC LIMIT ?", [.int(Int64(limit))])
        return rows.map { $0.text("title") }
    }

    /// Titles the user has rejected before; used as negative examples in extraction prompts.
    public func rejectedTitles(limit: Int = 30) throws -> [String] {
        let rows = try db.query(
            """
            SELECT title FROM candidates WHERE status = 'rejected'
            ORDER BY created_at DESC LIMIT ?
            """, [.int(Int64(limit))])
        return rows.map { $0.text("title") }
    }

    /// Expires pending candidates older than the given age.
    public func expireCandidates(olderThan age: TimeInterval, now: Date = Date()) throws {
        let threshold = now.timeIntervalSince1970 - age
        try db.execute(
            """
            UPDATE candidates SET status = 'expired', closed_at = ?
            WHERE status = 'pending' AND created_at < ?
            """,
            [.real(now.timeIntervalSince1970), .real(threshold)])
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
