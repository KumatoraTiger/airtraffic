import AirtrafficCore
import Foundation

/// Canned-response LLM client for testing labeling and prioritization
/// without network access.
struct MockLLMClient: LLMClient {
    let kind: ProviderKind = .gemini
    let response: String

    func complete(_ request: LLMRequest) async throws -> String { response }
}

struct ServiceTests {
    /// Tests place work several hours before "now", so "now" has to sit late
    /// enough in the local day for those hours to still belong to today. A wall
    /// clock makes that depend on the time of day the suite runs: CI pushes at
    /// 02:00 UTC, where four hours ago is yesterday and the day's activity gets
    /// filtered out. Every test therefore anchors to the same hour instead.
    private var midDay: Date {
        Calendar.current.date(bySettingHour: 18, minute: 30, second: 0, of: Date()) ?? Date()
    }

    private func session(
        id: String, title: String, cwd: String = "/Users/alex/src/demo",
        agent: AgentKind = .claudeCode, status: SessionStatus = .running,
        lastActivity: Date = Date(), todos: [TodoItem] = [],
        lastAssistantText: String = ""
    ) -> SessionSnapshot {
        SessionSnapshot(
            id: id, agent: agent, cwd: cwd, title: title, status: status,
            lastActivity: lastActivity, isSubagent: false, filePath: "/tmp/\(id).jsonl",
            todos: todos, lastUserText: "", lastAssistantText: lastAssistantText)
    }

    private func task(
        id: String, title: String, sessionIds: [String] = [], status: TaskStatus = .todo,
        isToday: Bool = false, parentId: String? = nil
    ) -> TaskItem {
        TaskItem(
            id: id, title: title, detail: "", status: status, rank: nil, isToday: isToday,
            source: .manual, createdAt: Date(), updatedAt: Date(), parentId: parentId,
            sessionIds: sessionIds)
    }

    func runAll() async {
        await TestKit.shared.run("board: sessions attach to tasks by link and by title") {
            let tasks = [task(id: "t-1", title: "READMEを更新する", sessionIds: ["claude:s-1"])]
            let sessions = [
                // Linked explicitly; the title need not match.
                session(id: "claude:s-1", title: "ドキュメント直し", status: .waitingInput),
                // No link, but the title is the same work.
                session(id: "codex:s-2", title: "README を更新する", agent: .codex),
                // Matches nothing and becomes its own entry.
                session(id: "claude:s-3", title: "認証バグの調査"),
            ]
            let entries = BoardAssembler.assemble(tasks: tasks, sessions: sessions)
            expectEqual(entries.count, 2)

            let taskEntry = try unwrap(entries.first { $0.task?.id == "t-1" })
            expectEqual(Set(taskEntry.sessions.map(\.id)), Set(["claude:s-1", "codex:s-2"]))
            // The most urgent execution decides the aggregate status.
            expectEqual(taskEntry.liveStatus, .waitingInput)

            let auto = try unwrap(entries.first { $0.task == nil })
            expectEqual(auto.title, "認証バグの調査")
            expect(auto.isLive, "a running session makes its entry live")
        }

        await TestKit.shared.run("board: unmatched same-title sessions collapse into one entry") {
            let sessions = [
                session(id: "claude:s-1", title: "タスクの重複対策", status: .waitingInput),
                // The same conversation imported under another agent, last
                // touched earlier — recency puts it second.
                session(
                    id: "codex:s-2", title: "タスクの重複対策", agent: .codex, status: .idle,
                    lastActivity: Date(timeIntervalSinceNow: -60)),
                // Same title in another project stays separate.
                session(id: "claude:s-3", title: "タスクの重複対策", cwd: "/Users/alex/src/other"),
                // Untitled sessions never merge with each other.
                session(id: "claude:s-4", title: ""),
                session(id: "claude:s-5", title: ""),
            ]
            let entries = BoardAssembler.assemble(tasks: [], sessions: sessions)
            expectEqual(entries.count, 4)

            let merged = try unwrap(
                entries.first { $0.sessions.map(\.id).contains("claude:s-1") })
            expectEqual(Set(merged.sessions.map(\.id)), Set(["claude:s-1", "codex:s-2"]))
            expectEqual(merged.liveStatus, .waitingInput)
            expectEqual(merged.sessions.first?.id, "claude:s-1")
        }

        await TestKit.shared.run("board: an idle-only entry is not live") {
            let entries = BoardAssembler.assemble(
                tasks: [],
                sessions: [session(id: "claude:s-1", title: "古い作業", status: .idle)])
            let entry = try unwrap(entries.first)
            expectEqual(entry.liveStatus, .idle)
            expect(!entry.isLive, "idle sessions mean the entry has stopped")
        }

        await TestKit.shared.run("board: taskless entries age off the live board after 24h") {
            let entries = BoardAssembler.assemble(
                tasks: [],
                sessions: [
                    session(id: "claude:s-1", title: "新しい作業", status: .waitingInput),
                    session(
                        id: "claude:s-2", title: "古い作業", status: .waitingInput,
                        lastActivity: Date(timeIntervalSinceNow: -25 * 3600)),
                ])
            let fresh = try unwrap(entries.first { $0.sessions.first?.id == "claude:s-1" })
            let aged = try unwrap(entries.first { $0.sessions.first?.id == "claude:s-2" })
            expect(fresh.isRecent(), "activity within 24h stays on the live board")
            expect(!aged.isRecent(), "older activity counts as finished and moves to 完了")
        }

        await TestKit.shared.run("board: attached sessions order by recency, newest first") {
            let now = midDay
            let tasks = [
                task(id: "t-1", title: "認証を直す", sessionIds: ["claude:s-1", "claude:s-2"])
            ]
            let entries = BoardAssembler.assemble(
                tasks: tasks,
                sessions: [
                    session(
                        id: "claude:s-1", title: "a", status: .waitingApproval,
                        lastActivity: now.addingTimeInterval(-600)),
                    session(id: "claude:s-2", title: "b", status: .idle, lastActivity: now),
                ])
            let entry = try unwrap(entries.first)
            // Urgency no longer reorders the tree; it only feeds the badge.
            expectEqual(entry.sessions.map(\.id), ["claude:s-2", "claude:s-1"])
            expectEqual(entry.liveStatus, .waitingApproval)
        }

        await TestKit.shared.run("board: a done task attaches only its linked sessions") {
            let tasks = [
                task(id: "t-1", title: "READMEを更新する", sessionIds: ["claude:s-1"], status: .done)
            ]
            let entries = BoardAssembler.assemble(
                tasks: tasks,
                sessions: [
                    session(id: "claude:s-1", title: "別の名前の作業"),
                    // Title-similar but unlinked: must stay live, not vanish
                    // into the done task.
                    session(id: "claude:s-2", title: "README を更新する"),
                ])
            let done = try unwrap(entries.first { $0.task?.id == "t-1" })
            expectEqual(done.sessions.map(\.id), ["claude:s-1"])
            let live = try unwrap(entries.first { $0.task == nil })
            expectEqual(live.sessions.map(\.id), ["claude:s-2"])
        }

        await TestKit.shared.run("board: session titles compact into task-like labels") {
            expectEqual(
                TitleCleaner.taskLabel("https://github.com/alex/demo/pull/12 をレビューして"),
                "github.com をレビューして")
            expectEqual(
                TitleCleaner.taskLabel("/Users/alex/src/demo/README.md を直す\n詳細は本文で"),
                "README.md を直す")
            let long = TitleCleaner.taskLabel(String(repeating: "あ", count: 100))
            expectEqual(long.count, 61)
            expect(long.hasSuffix("…"), "long titles are cut with an ellipsis")
            let entry = try unwrap(
                BoardAssembler.assemble(
                    tasks: [],
                    sessions: [session(id: "claude:s-1", title: "# 認証バグを調べる")]
                ).first)
            expectEqual(entry.title, "認証バグを調べる")
        }

        await TestKit.shared.run("labeler: parses a batch and drops what it cannot trust") {
            let mock = MockLLMClient(
                response: """
                    {"labels": [
                        {"id": "claude:s-1", "kind": "review", "subject": "認証APIの差分"},
                        {"id": "claude:s-2", "kind": "party", "subject": "未知の種類"},
                        {"id": "claude:s-3", "kind": "fix", "subject": "  "},
                        {"id": "claude:s-9", "kind": "design", "subject": "頼んでいないID"}
                    ]}
                    """)
            let sessions = [
                session(id: "claude:s-1", title: "このブランチの差分をレビューする。"),
                session(id: "claude:s-2", title: "x"),
                session(id: "claude:s-3", title: "y"),
            ]
            let labels = try await SessionLabeler().label(client: mock, sessions: sessions)
            expectEqual(labels.count, 1)
            let label = try unwrap(labels.first)
            expectEqual(label.sessionId, "claude:s-1")
            expectEqual(label.kind, .review)
            expectEqual(label.subject, "認証APIの差分")
            expectEqual(label.labeledActivity, sessions[0].lastActivity)
        }

        await TestKit.shared.run("labeler: relabels only missing or stale, newest first") {
            let now = midDay
            let fresh = session(
                id: "claude:s-1", title: "a", lastActivity: now.addingTimeInterval(-50))
            let stale = session(
                id: "claude:s-2", title: "b", lastActivity: now.addingTimeInterval(-30))
            let unlabeled = session(id: "claude:s-3", title: "c", lastActivity: now)
            let labels = [
                "claude:s-1": WorkLabel(
                    sessionId: "claude:s-1", kind: .review, subject: "x",
                    updatedAt: now, labeledActivity: fresh.lastActivity),
                "claude:s-2": WorkLabel(
                    sessionId: "claude:s-2", kind: .review, subject: "y",
                    updatedAt: now, labeledActivity: stale.lastActivity.addingTimeInterval(-700)),
            ]
            let labeler = SessionLabeler(refreshInterval: 600)
            let targets = labeler.sessionsNeedingLabels(
                [fresh, stale, unlabeled], labels: labels)
            expectEqual(targets.map(\.id), ["claude:s-3", "claude:s-2"])

            let capped = SessionLabeler(maxPerPass: 1, refreshInterval: 600)
                .sessionsNeedingLabels([fresh, stale, unlabeled], labels: labels)
            expectEqual(capped.map(\.id), ["claude:s-3"])
        }

        await TestKit.shared.run("board: labeled sessions merge across worktrees") {
            let now = midDay
            func reviewLabel(_ id: String) -> WorkLabel {
                WorkLabel(
                    sessionId: id, kind: .review, subject: "認証APIの差分",
                    updatedAt: now, labeledActivity: now)
            }
            let labels = [
                "claude:s-1": reviewLabel("claude:s-1"),
                "claude:s-2": reviewLabel("claude:s-2"),
                // A placeholder: asked, not classifiable. Must not merge with
                // anything or replace the fallback title.
                "claude:s-3": WorkLabel(
                    sessionId: "claude:s-3", kind: .other, subject: "",
                    updatedAt: now, labeledActivity: now),
            ]
            let entries = BoardAssembler.assemble(
                tasks: [],
                sessions: [
                    session(id: "claude:s-1", title: "このブランチの差分をレビューする。"),
                    session(
                        id: "claude:s-2", title: "このブランチの差分をレビューする。",
                        cwd: "/Users/alex/src/demo-wt2"),
                    session(id: "claude:s-3", title: "別の作業"),
                ],
                labels: labels)
            expectEqual(entries.count, 2)

            let merged = try unwrap(entries.first { $0.sessions.count == 2 })
            expectEqual(merged.title, "認証APIの差分")
            expectEqual(merged.label?.kind, .review)

            let fallback = try unwrap(entries.first { $0.sessions.count == 1 })
            expectEqual(fallback.title, "別の作業")
            expect(fallback.label == nil, "a placeholder never surfaces on the entry")
        }

        await TestKit.shared.run("board: a label attaches its session to the matching task") {
            let now = midDay
            let labels = [
                "claude:s-1": WorkLabel(
                    sessionId: "claude:s-1", kind: .review, subject: "PR #123 のレビュー",
                    updatedAt: now, labeledActivity: now)
            ]
            let entries = BoardAssembler.assemble(
                tasks: [task(id: "t-1", title: "PR #123 のレビュー")],
                sessions: [
                    session(id: "claude:s-1", title: "この PR の説明文だけを確認して")
                ],
                labels: labels)
            expectEqual(entries.count, 1)
            let entry = try unwrap(entries.first)
            expectEqual(entry.task?.id, "t-1")
            expectEqual(entry.sessions.map(\.id), ["claude:s-1"])
        }

        await TestKit.shared.run("matcher: normalizes width, case, and punctuation") {
            expectEqual(TitleMatcher.key("ＲＥＡＤＭＥ を更新する！"), "readmeを更新する")
            expect(
                TitleMatcher.isSimilar("CIを直す", "ＣＩ を直す"),
                "width and spacing differences should not split the same work")
            expect(
                !TitleMatcher.isSimilar("認証まわりのリファクタ", "ログ出力を整理する"),
                "unrelated titles should stay distinct")
        }

        await TestKit.shared.run("prioritizer: parses ranking block and display text") {
            let prioritizer = Prioritizer()
            let reply = """
                まず承認待ちの t-2 を先に片付けるべきです。

                ```ranking
                ["t-2", "t-1"]
                ```
                """
            let proposal = prioritizer.parseRanking(from: reply)
            expectEqual(proposal?.orderedTaskIds, ["t-2", "t-1"])
            let display = prioritizer.displayText(from: reply)
            expect(!display.contains("```"), "display text should strip the ranking block")
        }

        await TestKit.shared.run("prioritizer: no ranking block means no proposal") {
            let prioritizer = Prioritizer()
            expect(
                Prioritizer().parseRanking(from: "順位は今のままで良さそうです") == nil,
                "plain reply should not produce a proposal")
            _ = prioritizer
        }

        await TestKit.shared.run("reporter: completedToday keeps only tasks finished today") {
            let reporter = DailyReporter()
            let now = midDay
            let yesterday = now.addingTimeInterval(-24 * 3600)
            var doneToday = task(id: "t-1", title: "READMEを更新する", status: .done)
            doneToday.completedAt = now.addingTimeInterval(-3600)
            var doneEarlier = task(id: "t-2", title: "CIを直す", status: .done)
            doneEarlier.completedAt = now.addingTimeInterval(-600)
            var doneYesterday = task(id: "t-3", title: "古い作業", status: .done)
            doneYesterday.completedAt = yesterday
            // Completed before the timestamp existed: falls back to updatedAt.
            var legacyDone = task(id: "t-4", title: "タイムスタンプなしの完了", status: .done)
            legacyDone.updatedAt = now
            let open = task(id: "t-5", title: "未完了の作業", status: .inProgress)

            let completed = reporter.completedToday(
                [doneEarlier, doneToday, doneYesterday, legacyDone, open], now: now)
            expectEqual(completed.map(\.id), ["t-1", "t-2", "t-4"])
        }

        await TestKit.shared.run("reporter: activityToday merges by label and skips stale") {
            let reporter = DailyReporter()
            let now = midDay
            let sessions = [
                session(id: "claude:s-1", title: "認証APIの差分を見て", lastActivity: now),
                session(
                    id: "codex:s-2", title: "authのレビュー続き", agent: .codex,
                    lastActivity: now.addingTimeInterval(-1800)),
                session(
                    id: "claude:s-3", title: "昨日の作業",
                    lastActivity: now.addingTimeInterval(-24 * 3600)),
                session(id: "claude:s-4", title: "ログ出力を整理する", lastActivity: now),
            ]
            let labels: [String: WorkLabel] = [
                "claude:s-1": WorkLabel(
                    sessionId: "claude:s-1", kind: .review, subject: "認証APIの差分",
                    updatedAt: now, labeledActivity: now),
                "codex:s-2": WorkLabel(
                    sessionId: "codex:s-2", kind: .review, subject: "認証APIの差分",
                    updatedAt: now, labeledActivity: now),
            ]
            let items = reporter.activityToday(sessions: sessions, labels: labels, now: now)
            expectEqual(items.count, 2)
            let review = try unwrap(items.first { $0.title == "レビュー: 認証APIの差分" })
            expectEqual(Set(review.agents), Set([.claudeCode, .codex]))
            expectEqual(review.sessionCount, 2)
            expect(
                items.contains { $0.title == "ログ出力を整理する" },
                "an unlabeled session should fall back to its cleaned title")
        }

        await TestKit.shared.run("reporter: activityToday merges differently worded work on one PR") {
            let reporter = DailyReporter()
            let now = midDay
            let sessions = [
                session(
                    id: "claude:s-1", title: "PR #123 を見る",
                    lastActivity: now.addingTimeInterval(-7200)),
                session(
                    id: "codex:s-2", title: "認証API移行の続き", agent: .codex,
                    status: .waitingInput, lastActivity: now.addingTimeInterval(-3600),
                    todos: [
                        TodoItem(content: "baselineを直す", status: .pending),
                        TodoItem(content: "レビュー返信", status: .completed),
                    ],
                    lastAssistantText: "指摘3件を反映しました。"),
                session(
                    id: "claude:s-3", title: "同じPRのライブレビュー", lastActivity: now),
            ]
            let labels: [String: WorkLabel] = [
                "claude:s-1": WorkLabel(
                    sessionId: "claude:s-1", kind: .review, subject: "PR #123 同期DBの移行",
                    updatedAt: now, labeledActivity: now),
                "codex:s-2": WorkLabel(
                    sessionId: "codex:s-2", kind: .implement, subject: "#123 認証API移行",
                    updatedAt: now, labeledActivity: now),
                "claude:s-3": WorkLabel(
                    sessionId: "claude:s-3", kind: .review, subject: "PR 123 のライブレビュー",
                    updatedAt: now, labeledActivity: now),
            ]
            let items = reporter.activityToday(sessions: sessions, labels: labels, now: now)
            expectEqual(items.count, 1)
            let item = try unwrap(items.first)
            expectEqual(item.sessionCount, 3)
            expectEqual(item.state, .running)
            expectEqual(item.openTodos, ["baselineを直す"])
            expect(
                item.title == "レビュー: PR 123 のライブレビュー",
                "the newest session should name the merged work")
            expect(item.lastActivity > item.firstActivity, "the group should span the day")
            expect(
                item.lastOutput.contains("指摘3件"),
                "the newest non-empty assistant output should be carried")
        }

        await TestKit.shared.run("reporter: waiting sessions are not reported as running") {
            let reporter = DailyReporter()
            let now = midDay
            let sessions = [
                session(
                    id: "claude:s-1", title: "承認待ちの作業", status: .waitingApproval,
                    lastActivity: now.addingTimeInterval(-4 * 3600)),
                session(id: "claude:s-2", title: "動いている作業", lastActivity: now),
                session(
                    id: "claude:s-3", title: "止まった作業", status: .idle,
                    lastActivity: now.addingTimeInterval(-6 * 3600)),
                // Placeholder titles name no work at all.
                session(id: "claude:s-4", title: "(無題)", lastActivity: now),
            ]
            let items = reporter.activityToday(sessions: sessions, labels: [:], now: now)
            expectEqual(items.map(\.state), [.running, .awaitingUser, .quiet])
            expect(
                !items.contains { $0.title.contains("無題") },
                "a placeholder title should be skipped")

            let input = reporter.reportInput(
                completed: [], plan: DailyReporter.PlanComparison(unplanned: items), now: now)
            expect(input.contains("確認待ち"), "the ambiguous state should be named")
            expect(
                input.contains("完了済みか放置かは不明"),
                "the report input should not claim a waiting session is in progress")
            expect(input.contains("4時間前から"), "how long it has been sitting should be stated")
        }

        await TestKit.shared.run("reporter: plan comparison splits planned, untouched, unplanned") {
            let reporter = DailyReporter()
            let now = midDay
            let sessions = [
                session(id: "claude:s-1", title: "READMEを更新する", lastActivity: now),
                session(id: "claude:s-2", title: "PR #123 のレビュー", lastActivity: now),
            ]
            let items = reporter.activityToday(sessions: sessions, labels: [:], now: now)
            var done = task(id: "t-1", title: "READMEを更新する", status: .done, isToday: true)
            done.completedAt = now
            let planned = task(id: "t-2", title: "CIを直す", status: .todo, isToday: true)
            let someday = task(id: "t-3", title: "いつかやる整理", status: .todo)

            let plan = reporter.comparePlan(
                tasks: [done, planned, someday], activity: items, sessions: sessions, now: now)
            expectEqual(plan.worked.map(\.task.id), ["t-1"])
            expectEqual(plan.untouched.map(\.id), ["t-2"])
            expect(
                plan.unplanned.contains { $0.title.contains("123") },
                "work with no task behind it should be reported as unplanned")
            expect(
                !plan.unplanned.contains { $0.title.contains("README") },
                "work matched to a task should not also be unplanned")
        }

        await TestKit.shared.run("reporter: report input carries the day's facts") {
            let reporter = DailyReporter()
            let now = midDay
            var done = task(id: "t-1", title: "READMEを更新する", status: .done, isToday: true)
            done.completedAt = now
            let item = DailyReporter.ActivityItem(
                id: "#1", title: "レビュー: 認証APIの差分", project: "demo",
                agents: [.claudeCode], kinds: [.review], sessionCount: 2,
                state: .running, firstActivity: now.addingTimeInterval(-3600),
                lastActivity: now, openTodos: ["テストを直す"],
                lastOutput: "差分を読み終えました。")
            let plan = DailyReporter.PlanComparison(
                worked: [DailyReporter.PlannedWork(task: done, activity: [item])],
                untouched: [task(id: "t-2", title: "CIを直す", status: .todo, isToday: true)],
                unplanned: [
                    DailyReporter.ActivityItem(
                        id: "#2", title: "調査: ログの欠落", state: .quiet, lastActivity: now)
                ])
            let commits = [
                RepoCommits(
                    path: "/Users/alex/src/demo", name: "demo",
                    subjects: ["Fix the flaky auth test"], total: 3)
            ]
            let input = reporter.reportInput(
                completed: [done], plan: plan, commits: commits, now: now)
            expect(input.contains("READMEを更新する"), "completed task should be listed")
            expect(input.contains("レビュー: 認証APIの差分"), "activity should be listed")
            expect(input.contains("CIを直す"), "an untouched planned task should be listed")
            expect(input.contains("調査: ログの欠落"), "unplanned work should be listed")
            expect(input.contains("Fix the flaky auth test"), "commit subjects should be listed")
            expect(input.contains("（他に2件）"), "commits beyond the listed ones should be counted")
            expect(input.contains("現在時刻"), "the point-in-time context should be present")
            expect(input.contains("セッション2件"), "merged session counts should be listed")
            expect(input.contains("テストを直す"), "open todos should be listed")
            expect(input.contains("差分を読み終えました"), "the last output should be listed")
        }

        await TestKit.shared.run("git log: today's own commits are read per repository") {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("airtraffic-git-\(UUID().uuidString)")
            let repo = root.appendingPathComponent("demo")
            let nested = repo.appendingPathComponent("sub")
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }

            func git(_ arguments: [String], in directory: URL) throws {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                process.arguments = ["-C", directory.path] + arguments
                process.standardOutput = Pipe()
                process.standardError = Pipe()
                try process.run()
                process.waitUntilExit()
            }
            try git(["init", "--quiet"], in: repo)
            try git(["config", "user.email", "alex@example.com"], in: repo)
            try git(["config", "user.name", "alex"], in: repo)
            try "hello".write(
                to: repo.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
            try git(["add", "."], in: repo)
            try git(["commit", "--quiet", "-m", "Add the readme"], in: repo)

            // Both paths live in the same repository: it must be read once.
            let commits = GitLog().commitsToday(paths: [nested.path, repo.path])
            expectEqual(commits.count, 1)
            let entry = try unwrap(commits.first)
            expectEqual(entry.name, "demo")
            expectEqual(entry.subjects, ["Add the readme"])
            expect(
                GitLog().commitsToday(paths: [root.path]).isEmpty,
                "a directory outside any repository should yield nothing")
        }

        await TestKit.shared.run("reporter: a fenced JSON reply parses into a report") {
            let reporter = DailyReporter()
            let reply = """
                ```json
                {"date": "2026-08-19 (水) 18:53 時点", "mid_day": true,
                 "headline": "認証APIの移行が中心の日。",
                 "themes": [{"kind": "実装", "title": "移行をレビュー指摘まで通した",
                             "body": "指摘3件を反映した。",
                             "evidence": ["webapp", "3セッション"]}],
                 "timeline": [{"time": "14:02", "title": "実装に着手", "note": "差分を絞った。"}],
                 "stuck": [], "closing": "レビューの往復に時間が寄った。"}
                ```
                """
            let report = try unwrap(reporter.parseReport(from: reply))
            expect(report.midDay, "mid_day should decode")
            expectEqual(report.headline, "認証APIの移行が中心の日。")
            expectEqual(report.themes.count, 1)
            // The kind arrived as its Japanese display name, not its raw case.
            expectEqual(report.themes.first?.kind, .implement)
            expectEqual(report.themes.first?.evidence, ["webapp", "3セッション"])
            expectEqual(report.timeline.first?.time, "14:02")
            expectEqual(report.closing, "レビューの往復に時間が寄った。")
            // carry_over was absent: a thin report, not a parse failure.
            expect(report.carryOver.isEmpty, "a missing section should decode as empty")
        }

        await TestKit.shared.run("reporter: an answer in the older shape still reads") {
            let reporter = DailyReporter()
            let reply = """
                {"date": "2026-08-19 (水)",
                 "summary": "今日は PR #123 が中心だった。\\n\\n夕方は調査に寄った。",
                 "achievements": [{"title": "PR #123", "detail": "指摘3件を反映した。",
                                   "meta": ["webapp"]}]}
                """
            let report = try unwrap(reporter.parseReport(from: reply))
            expectEqual(report.headline, "今日は PR #123 が中心だった。")
            expectEqual(report.closing, "夕方は調査に寄った。")
            expectEqual(report.themes.count, 1)
            expectEqual(report.themes.first?.title, "PR #123")
            // Nothing said which kind it was, so it stays uncategorized.
            expectEqual(report.themes.first?.kind, .other)
        }

        await TestKit.shared.run("reporter: an unusable reply parses to nil") {
            let reporter = DailyReporter()
            expect(
                reporter.parseReport(from: "## 完了したこと\n- なにか") == nil,
                "prose should not be accepted as a report")
            expect(
                reporter.parseReport(from: "{\"headline\": \"\"}") == nil,
                "an object with nothing usable should be rejected")
        }

        await TestKit.shared.run("renderer: the page is self-contained and escapes text") {
            let report = DailyReport(
                date: "2026-08-19 (水) 18:53", midDay: true,
                headline: "今日は <script> の混入を試した。",
                themes: [
                    ReportTheme(
                        kind: .review, title: "PR #123 を通した", body: "指摘3件を反映した。",
                        evidence: ["webapp", "5コミット"])
                ],
                timeline: [TimelineNote(time: "14:02", title: "着手", note: "差分を絞った。")],
                stuck: [ReportEntry(title: "確認待ちの調査", detail: "3時間止まっている。")],
                closing: "レビューに時間が寄った。")
            let html = DailyReportRenderer.html(report)
            expect(html.hasPrefix("<!doctype html>"), "a standalone page should be produced")
            expect(!html.contains("http://"), "the page must not reference remote assets")
            expect(!html.contains("<script>"), "text must be escaped, not rendered as markup")
            expect(html.contains("&lt;script&gt;"), "the escaped form should be present")
            expect(html.contains("途中経過"), "a mid-day report should say so")
            expect(html.contains("class=\"lead\""), "the headline should be the lead")
            expect(html.contains("レビュー</span>"), "the kind should be spelled out on the card")
            expect(html.contains("根拠: webapp · 5コミット"), "evidence should be listed")
            expect(html.contains("14:02"), "the narrative timeline should carry its times")
            expect(html.contains("詰まっているところ"), "a non-empty entry group should appear")
            expect(html.contains("明日に持ち越し") == false, "an empty group should be omitted")
            expect(html.contains("まとめ"), "the closing should be present")
        }

        await TestKit.shared.run("renderer: a theme's accent follows its kind, not its order") {
            func slot(_ kind: WorkKind) -> String? {
                let html = DailyReportRenderer.html(
                    DailyReport(date: "d", themes: [ReportTheme(kind: kind, title: "t")]))
                for name in ["s1", "s2", "s3", "neutral"]
                where html.contains("<article class=\"card \(name)\">") {
                    return name
                }
                return nil
            }
            expectEqual(slot(.implement), "s1")
            expectEqual(slot(.design), "s1")
            expectEqual(slot(.fix), "s2")
            expectEqual(slot(.review), "s3")
            expectEqual(slot(.other), "neutral")
        }

        await TestKit.shared.run("renderer: the tiles count the day from the facts") {
            let now = midDay
            let metrics = DayMetrics(
                dayStart: now.addingTimeInterval(-3600), now: now,
                plannedWorked: 2, plannedUntouched: 1, unplanned: 3,
                commits: [RepoCommits(path: "/tmp/a", name: "webapp", subjects: [], total: 7)],
                completedTasks: 4, sessions: 9)
            let html = DailyReportRenderer.html(DailyReport(date: "d"), metrics: metrics)
            expect(html.contains("<b>4</b><span>完了したタスク</span>"), "completed tasks")
            expect(html.contains("<b>5</b><span>動いた作業</span>"), "planned plus unplanned work")
            expect(html.contains("<b>9</b><span>セッション</span>"), "session count")
            expect(html.contains("<b>7</b><span>コミット</span>"), "commit total")
            // Two repositories or fewer say nothing a number did not.
            expect(!html.contains("class=\"figure commits\""), "one repo needs no bar chart")
        }

        await TestKit.shared.run("renderer: markdown keeps every section for pasting") {
            let report = DailyReport(
                date: "2026-08-19 (水)", headline: "概要の文。",
                themes: [
                    ReportTheme(
                        kind: .implement, title: "PR #123", body: "反映した。",
                        evidence: ["3件"])
                ],
                timeline: [TimelineNote(time: "14:02", title: "着手")],
                carryOver: [ReportEntry(title: "設定値の切り替え", detail: "手が付かなかった。")],
                closing: "調査に寄った日。")
            let markdown = DailyReportRenderer.markdown(report)
            expect(markdown.contains("# 日報 2026-08-19 (水)"), "the date line should be present")
            expect(markdown.contains("\n概要の文。\n"), "the headline should stand alone")
            expect(markdown.contains("### [実装] PR #123"), "themes should carry their kind")
            expect(markdown.contains("根拠: 3件"), "evidence should be listed")
            expect(markdown.contains("- 14:02 着手"), "the timeline should be present")
            expect(markdown.contains("## 詰まっているところ\n（なし）"), "empty sections should be named")
            expect(markdown.contains("設定値の切り替え"), "carry-over should be present")
            expect(markdown.hasSuffix("調査に寄った日。\n"), "the closing should end the document")
        }

        await TestKit.shared.run("metrics: the timeline keeps the longest work in time order") {
            let now = midDay
            func item(
                _ id: String, _ title: String, start: TimeInterval, end: TimeInterval,
                state: DailyReporter.ActivityState = .quiet, sessions: Int = 1
            ) -> DailyReporter.ActivityItem {
                DailyReporter.ActivityItem(
                    id: id, title: title, sessionCount: sessions, state: state,
                    firstActivity: now.addingTimeInterval(start),
                    lastActivity: now.addingTimeInterval(end))
            }
            // Nine items: one more than the timeline draws.
            var unplanned = [
                item("long", "長い作業", start: -6 * 3600, end: -600, state: .running, sessions: 3),
                item("short", "短い作業", start: -1800, end: -1740),
            ]
            for index in 0..<7 {
                let offset = Double(index) * 60
                unplanned.append(
                    item(
                        "filler-\(index)", "細かい作業\(index)",
                        start: -2400 - offset, end: -2100 - offset))
            }
            let plan = DailyReporter.PlanComparison(unplanned: unplanned)
            let metrics = DayMetrics.build(
                plan: plan,
                commits: [
                    RepoCommits(path: "/tmp/demo", name: "demo", subjects: ["a"], total: 4)
                ],
                now: now)
            expectEqual(metrics.timeline.count, DayMetrics.barLimit)
            expect(
                metrics.timeline.first?.id == "long",
                "the longest stretch should survive the cut and come first in time")
            expect(
                !metrics.timeline.contains { $0.id == "short" },
                "the shortest work should be the one dropped")
            expectEqual(metrics.unplanned, 9)
            expect(metrics.windowStart <= metrics.timeline[0].start, "the window should cover the bars")
        }

        await TestKit.shared.run("renderer: figures are drawn from the metrics, not the prose") {
            let now = midDay
            let metrics = DayMetrics(
                timeline: [
                    DayMetrics.Bar(
                        id: "#123", title: "PR #123 の移行", state: .awaitingUser,
                        start: now.addingTimeInterval(-3 * 3600), end: now.addingTimeInterval(-600),
                        sessionCount: 3)
                ],
                dayStart: Calendar.current.startOfDay(for: now), now: now,
                plannedWorked: 2, plannedUntouched: 1, unplanned: 3,
                commits: [
                    RepoCommits(path: "/tmp/demo", name: "demo", subjects: ["a"], total: 5)
                ])
            let html = DailyReportRenderer.html(
                DailyReport(date: "2026-08-19 (水)", headline: "概要。"), metrics: metrics)
            expect(html.contains("時間の使いみち"), "the timeline should be present")
            expect(html.contains("予定と実際"), "the plan split should be present")
            expect(html.contains("コミット"), "the commit bars should be present")
            // State is carried by a label as well as by color.
            expect(html.contains("確認待ち · "), "each bar should name its state and hours")
            expect(html.contains("3セッション"), "session counts should label the bar")
            expect(html.contains("<strong>3</strong>"), "every plan segment should show its count")
            expect(!html.contains("width:0.00%"), "a bar must never be drawn with no width")
            expect(
                DailyReportRenderer.html(
                    DailyReport(date: "d"), metrics: DayMetrics(dayStart: now, now: now)
                )
                .contains("時間の使いみち") == false,
                "an empty day should draw no figures")
        }

        await TestKit.shared.run("renderer: the hour axis stays bounded") {
            let start = Date()
            let ticks = DailyReportRenderer.hourTicks(
                from: start, to: start.addingTimeInterval(10 * 3600))
            expectEqual(ticks.count, 4)
            let long = DailyReportRenderer.hourTicks(
                from: start, to: start.addingTimeInterval(100 * 3600))
            expect(long.count <= 12, "a very long window must not flood the axis")
        }

        await TestKit.shared.run("board: untitled sessions never merge") { [self] in
            let entries = BoardAssembler.assemble(
                tasks: [],
                sessions: [
                    session(id: "codex:a", title: "(無題)"),
                    session(id: "codex:b", title: "(無題)"),
                ])
            expectEqual(entries.count, 2)
            expect(
                entries.allSatisfy { $0.title == "無題のセッション" },
                "a placeholder title should read as one on the board")
        }

        await TestKit.shared.run("board: subtasks hang under their parent row") {
            let tasks = [
                task(id: "t-1", title: "認証を直す"),
                task(id: "t-2", title: "トークン検証を書く", parentId: "t-1"),
                task(id: "t-3", title: "テストを足す", status: .done, parentId: "t-1"),
                task(id: "t-4", title: "READMEを更新する"),
            ]
            let entries = BoardAssembler.assemble(tasks: tasks, sessions: [])
            // Only the two top-level tasks are rows of the board.
            expectEqual(entries.map(\.id), ["t-1", "t-4"])

            let parent = try unwrap(entries.first { $0.id == "t-1" })
            expectEqual(parent.children.map(\.id), ["t-2", "t-3"])
            expectEqual(parent.selfAndChildren.count, 3)
            let progress = try unwrap(parent.subtaskProgress)
            expectEqual(progress.done, 1)
            expectEqual(progress.total, 2)
            expect(
                entries.first { $0.id == "t-4" }?.subtaskProgress == nil,
                "a task without subtasks shows no progress")
        }

        await TestKit.shared.run("board: a subtask keeps its own sessions") {
            let tasks = [
                task(id: "t-1", title: "認証を直す"),
                task(
                    id: "t-2", title: "トークン検証を書く", sessionIds: ["claude:s-1"],
                    parentId: "t-1"),
            ]
            let sessions = [session(id: "claude:s-1", title: "検証の実装", status: .waitingInput)]
            let entries = BoardAssembler.assemble(tasks: tasks, sessions: sessions)
            expectEqual(entries.count, 1)
            let child = try unwrap(entries.first?.children.first)
            expectEqual(child.sessions.map(\.id), ["claude:s-1"])
            expectEqual(child.liveStatus, .waitingInput)
            expect(entries[0].sessions.isEmpty, "the session belongs to the subtask, not the parent")
        }

        await TestKit.shared.run("status: completing a parent completes its subtasks") {
            let now = midDay
            let done = TaskItem(
                id: "t-3", title: "テストを足す", detail: "", status: .done, rank: nil,
                source: .manual, createdAt: now, updatedAt: now,
                completedAt: now.addingTimeInterval(-3600), parentId: "t-1", sessionIds: [])
            let tasks = [
                task(id: "t-1", title: "認証を直す"),
                task(id: "t-2", title: "トークン検証を書く", parentId: "t-1"),
                done,
                task(id: "t-4", title: "壊れた検証を消す", status: .archived, parentId: "t-1"),
                task(id: "t-5", title: "READMEを更新する"),
            ]
            let written = TaskStatusChange.apply(.done, to: tasks[0], in: tasks, now: now)
            expectEqual(written.map(\.id), ["t-1", "t-2"])
            expectEqual(written[0].completedAt, now)
            expectEqual(written[1].status, .done)
            expectEqual(written[1].completedAt, now)
            // The subtask already finished keeps its own timestamp, and the
            // archived one is not dragged back onto the board.
            expect(!written.contains { $0.id == "t-3" || $0.id == "t-4" }, "no rewrite needed")
        }

        await TestKit.shared.run("status: reopening a parent leaves its subtasks done") {
            let now = midDay
            let tasks = [
                task(id: "t-1", title: "認証を直す", status: .done),
                task(id: "t-2", title: "トークン検証を書く", status: .done, parentId: "t-1"),
            ]
            let written = TaskStatusChange.apply(.todo, to: tasks[0], in: tasks, now: now)
            expectEqual(written.map(\.id), ["t-1"])
            expect(written[0].completedAt == nil, "reopening clears the completion date")
        }

        await TestKit.shared.run("status: completing a subtask touches nothing else") {
            let now = midDay
            let tasks = [
                task(id: "t-1", title: "認証を直す"),
                task(id: "t-2", title: "トークン検証を書く", parentId: "t-1"),
                task(id: "t-3", title: "テストを足す", parentId: "t-1"),
            ]
            let written = TaskStatusChange.apply(.done, to: tasks[1], in: tasks, now: now)
            expectEqual(written.map(\.id), ["t-2"])
        }

        await TestKit.shared.run("board: an orphaned subtask stays visible") {
            // The parent was archived, so tasks() no longer returns it.
            let tasks = [task(id: "t-2", title: "トークン検証を書く", parentId: "t-1")]
            let entries = BoardAssembler.assemble(tasks: tasks, sessions: [])
            expectEqual(entries.map(\.id), ["t-2"])
        }
    }
}
