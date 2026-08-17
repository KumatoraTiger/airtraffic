import AirtrafficCore
import Foundation

/// Canned-response LLM client for testing extraction and prioritization
/// without network access.
struct MockLLMClient: LLMClient {
    let kind: ProviderKind = .gemini
    let response: String

    func complete(_ request: LLMRequest) async throws -> String { response }
}

/// Records the prompt it was given, so tests can assert on what the LLM sees.
final class RecordingLLMClient: LLMClient, @unchecked Sendable {
    let kind: ProviderKind = .gemini
    let response: String
    private let lock = NSLock()
    private var recorded = ""

    init(response: String) { self.response = response }

    var prompt: String {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func complete(_ request: LLMRequest) async throws -> String {
        lock.lock()
        recorded = request.messages.map(\.text).joined(separator: "\n")
        lock.unlock()
        return response
    }
}

struct ServiceTests {
    private func session(
        id: String, title: String, cwd: String = "/Users/alex/src/demo",
        agent: AgentKind = .claudeCode, status: SessionStatus = .running,
        lastActivity: Date = Date()
    ) -> SessionSnapshot {
        SessionSnapshot(
            id: id, agent: agent, cwd: cwd, title: title, status: status,
            lastActivity: lastActivity, isSubagent: false, filePath: "/tmp/\(id).jsonl",
            todos: [], lastUserText: "", lastAssistantText: "", newTranscriptText: "")
    }

    private func task(
        id: String, title: String, sessionIds: [String] = [], status: TaskStatus = .todo
    ) -> TaskItem {
        TaskItem(
            id: id, title: title, detail: "", status: status, rank: nil, source: .manual,
            createdAt: Date(), updatedAt: Date(), sessionIds: sessionIds)
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
            let now = Date()
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
            let now = Date()
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
            let now = Date()
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
            let now = Date()
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

        await TestKit.shared.run("extractor: parses candidates and applies threshold") {
            let mock = MockLLMClient(
                response: """
                    {"candidates": [
                        {"title": "READMEを更新する", "detail": "セットアップ手順が古い", "confidence": 0.8, "excerpt": "READMEも直さないと"},
                        {"title": "あいまいな思いつき", "detail": "", "confidence": 0.2, "excerpt": ""}
                    ]}
                    """)
            let extractor = TaskExtractor(confidenceThreshold: 0.4)
            let results = try await extractor.extract(
                client: mock, newText: "[user] READMEも直さないと\n",
                sessionTitle: "demo", known: .init())
            expectEqual(results.count, 1)
            expectEqual(results.first?.title, "READMEを更新する")
        }

        await TestKit.shared.run("extractor: caps a pass at its strongest three") {
            let mock = MockLLMClient(
                response: """
                    {"candidates": [
                        {"title": "候補A", "detail": "", "confidence": 0.7, "excerpt": ""},
                        {"title": "候補B", "detail": "", "confidence": 0.95, "excerpt": ""},
                        {"title": "候補C", "detail": "", "confidence": 0.8, "excerpt": ""},
                        {"title": "候補D", "detail": "", "confidence": 0.9, "excerpt": ""},
                        {"title": "候補E", "detail": "", "confidence": 0.65, "excerpt": ""}
                    ]}
                    """)
            let results = try await TaskExtractor().extract(
                client: mock, newText: "[user] x\n", sessionTitle: "demo", known: .init())
            expectEqual(results.map(\.title), ["候補B", "候補D", "候補C"])
        }

        await TestKit.shared.run("extractor: drops duplicates of existing tasks") {
            let mock = MockLLMClient(
                response: """
                    {"candidates": [{"title": "READMEを更新する", "detail": "", "confidence": 0.9, "excerpt": ""}]}
                    """)
            let extractor = TaskExtractor()
            let results = try await extractor.extract(
                client: mock, newText: "[user] x\n", sessionTitle: "demo",
                known: .init(tasks: ["README を更新する"]))
            expect(results.isEmpty, "similar title should be deduped")
        }

        await TestKit.shared.run("extractor: drops paraphrases of existing tasks") {
            let mock = MockLLMClient(
                response: """
                    {"candidates": [{"title": "READMEの記述を更新する", "detail": "", "confidence": 0.9, "excerpt": ""}]}
                    """)
            let results = try await TaskExtractor().extract(
                client: mock, newText: "[user] x\n", sessionTitle: "demo",
                known: .init(tasks: ["READMEを更新する"]))
            expect(results.isEmpty, "paraphrased title should be deduped")
        }

        await TestKit.shared.run("extractor: keeps titles that only look alike") {
            let mock = MockLLMClient(
                response: """
                    {"candidates": [{"title": "テストを追加", "detail": "", "confidence": 0.9, "excerpt": ""}]}
                    """)
            let results = try await TaskExtractor().extract(
                client: mock, newText: "[user] x\n", sessionTitle: "demo",
                known: .init(tasks: ["テストを修正"]))
            expectEqual(results.count, 1)
        }

        await TestKit.shared.run("extractor: drops repeats of rejected candidates") {
            let mock = MockLLMClient(
                response: """
                    {"candidates": [{"title": "READMEを更新する", "detail": "", "confidence": 0.9, "excerpt": ""}]}
                    """)
            let results = try await TaskExtractor().extract(
                client: mock, newText: "[user] x\n", sessionTitle: "demo",
                known: .init(rejected: ["README を更新する"]))
            expect(results.isEmpty, "rejected title should not come back")
        }

        await TestKit.shared.run("extractor: dedupes within a single response") {
            let mock = MockLLMClient(
                response: """
                    {"candidates": [
                        {"title": "READMEを更新する", "detail": "", "confidence": 0.9, "excerpt": ""},
                        {"title": "README を更新する", "detail": "", "confidence": 0.8, "excerpt": ""}
                    ]}
                    """)
            let results = try await TaskExtractor().extract(
                client: mock, newText: "[user] x\n", sessionTitle: "demo",
                known: .init())
            expectEqual(results.count, 1)
            expectEqual(results.first?.title, "READMEを更新する")
        }

        await TestKit.shared.run("extractor: a long task list never crowds out open proposals") {
            let mock = RecordingLLMClient(response: #"{"candidates": []}"#)
            _ = try await TaskExtractor().extract(
                client: mock, newText: "[user] x\n", sessionTitle: "demo",
                known: .init(
                    tasks: (1...50).map { "タスク\($0)" },
                    pendingCandidates: ["認証まわりをリファクタする"],
                    rejected: ["却下されたもの"]))
            expect(
                mock.prompt.contains("認証まわりをリファクタする"),
                "pending candidates get their own budget, so tasks cannot push them out")
            expect(mock.prompt.contains("却下されたもの"), "rejected titles survive too")
            expect(!mock.prompt.contains("タスク50"), "the task list is still capped")
        }

        await TestKit.shared.run("matcher: normalizes width, case, and punctuation") {
            expectEqual(TitleMatcher.key("ＲＥＡＤＭＥ を更新する！"), "readmeを更新する")
            expect(
                TitleMatcher.isSimilar("CIを直す", "ＣＩ を直す"),
                "width and spacing differences should not create a new candidate")
            expect(
                !TitleMatcher.isSimilar("認証まわりのリファクタ", "ログ出力を整理する"),
                "unrelated titles should stay distinct")
        }

        await TestKit.shared.run("extractor: tolerates markdown-fenced JSON") {
            let mock = MockLLMClient(
                response: """
                    前置きの文章。
                    ```json
                    {"candidates": [{"title": "テストを足す", "detail": "", "confidence": 0.7, "excerpt": ""}]}
                    ```
                    """)
            let extractor = TaskExtractor()
            let results = try await extractor.extract(
                client: mock, newText: "[user] x\n", sessionTitle: "demo",
                known: .init())
            expectEqual(results.count, 1)
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
    }
}
