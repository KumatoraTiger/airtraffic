import AirtrafficCore
import Foundation

struct StoreTests {
    private func makeStore() throws -> (Store, String) {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("airtraffic-test-\(UUID().uuidString).sqlite").path
        return (try Store(path: path), path)
    }

    func runAll() async {
        await TestKit.shared.run("store: cursor roundtrip") {
            let (store, path) = try makeStore()
            defer { try? FileManager.default.removeItem(atPath: path) }
            expectEqual(try await store.cursor(for: "/tmp/some.jsonl"), 0)
            try await store.setCursor(1234, for: "/tmp/some.jsonl")
            expectEqual(try await store.cursor(for: "/tmp/some.jsonl"), 1234)
        }

        await TestKit.shared.run("store: task upsert and ranking") {
            let (store, path) = try makeStore()
            defer { try? FileManager.default.removeItem(atPath: path) }
            let task = TaskItem(
                id: "t-1", title: "write docs", detail: "", status: .todo, rank: nil,
                source: .manual, createdAt: Date(), updatedAt: Date(), sessionIds: ["claude:s-1"]
            )
            try await store.upsertTask(task)
            var fetched = try await store.tasks()
            expectEqual(fetched.count, 1)
            expectEqual(fetched.first?.sessionIds, ["claude:s-1"])

            let task2 = TaskItem(
                id: "t-2", title: "fix bug", detail: "", status: .todo, rank: nil,
                source: .llm, createdAt: Date(), updatedAt: Date(), sessionIds: []
            )
            try await store.upsertTask(task2)
            try await store.setRanks(["t-2", "t-1"])
            fetched = try await store.tasks()
            expectEqual(fetched.map(\.id), ["t-2", "t-1"])
        }

        await TestKit.shared.run("store: today flag roundtrip") {
            let (store, path) = try makeStore()
            defer { try? FileManager.default.removeItem(atPath: path) }
            var task = TaskItem(
                id: "t-1", title: "write docs", detail: "", status: .todo, rank: nil,
                source: .manual, createdAt: Date(), updatedAt: Date(), sessionIds: []
            )
            try await store.upsertTask(task)
            expectEqual(try await store.tasks().first?.isToday, false)

            task.isToday = true
            try await store.upsertTask(task)
            expectEqual(try await store.tasks().first?.isToday, true)

            task.isToday = false
            try await store.upsertTask(task)
            expectEqual(try await store.tasks().first?.isToday, false)
        }

        await TestKit.shared.run("store: completed_at roundtrip") {
            let (store, path) = try makeStore()
            defer { try? FileManager.default.removeItem(atPath: path) }
            var task = TaskItem(
                id: "t-1", title: "write docs", detail: "", status: .todo, rank: nil,
                source: .manual, createdAt: Date(), updatedAt: Date(), sessionIds: []
            )
            try await store.upsertTask(task)
            expect(try await store.tasks().first?.completedAt == nil, "starts unset")

            let finishedAt = Date(timeIntervalSince1970: 1_755_000_000)
            task.status = .done
            task.completedAt = finishedAt
            try await store.upsertTask(task)
            expectEqual(try await store.tasks().first?.completedAt, finishedAt)

            // Reopening clears the timestamp.
            task.status = .todo
            task.completedAt = nil
            try await store.upsertTask(task)
            expect(try await store.tasks().first?.completedAt == nil, "cleared on reopen")
        }

        await TestKit.shared.run("store: work labels roundtrip and prune") {
            let (store, path) = try makeStore()
            defer { try? FileManager.default.removeItem(atPath: path) }
            let now = Date()
            try await store.upsertLabel(
                WorkLabel(
                    sessionId: "claude:s-1", kind: .review, subject: "認証APIの差分",
                    updatedAt: now, labeledActivity: now))
            try await store.upsertLabel(
                WorkLabel(
                    sessionId: "claude:s-2", kind: .design, subject: "古い設計メモ",
                    updatedAt: now, labeledActivity: now.addingTimeInterval(-40 * 24 * 3600)))
            var labels = try await store.labels()
            expectEqual(labels.count, 2)
            expectEqual(labels["claude:s-1"]?.kind, .review)
            expectEqual(labels["claude:s-1"]?.subject, "認証APIの差分")

            // Relabeling overwrites in place.
            try await store.upsertLabel(
                WorkLabel(
                    sessionId: "claude:s-1", kind: .fix, subject: "レビュー指摘の反映",
                    updatedAt: now, labeledActivity: now))
            labels = try await store.labels()
            expectEqual(labels.count, 2)
            expectEqual(labels["claude:s-1"]?.kind, .fix)

            // Labels whose session went quiet for a month get swept.
            try await store.pruneLabels(olderThan: 30 * 24 * 3600, now: now)
            labels = try await store.labels()
            expectEqual(labels.count, 1)
            expect(labels["claude:s-2"] == nil, "the stale label should be gone")
        }

        await TestKit.shared.run("store: subtask parent link roundtrip") {
            let (store, path) = try makeStore()
            defer { try? FileManager.default.removeItem(atPath: path) }
            let parent = TaskItem(
                id: "t-1", title: "認証を直す", detail: "", status: .todo, rank: 0,
                source: .manual, createdAt: Date(), updatedAt: Date(), sessionIds: []
            )
            var child = TaskItem(
                id: "t-2", title: "リフレッシュトークンを検証する", detail: "", status: .todo,
                rank: 0, source: .manual, createdAt: Date(), updatedAt: Date(),
                parentId: "t-1", sessionIds: []
            )
            try await store.upsertTask(parent)
            try await store.upsertTask(child)
            var fetched = try await store.tasks()
            expectEqual(fetched.first { $0.id == "t-1" }?.parentId, nil)
            expectEqual(fetched.first { $0.id == "t-2" }?.parentId, "t-1")
            expectEqual(fetched.first { $0.id == "t-2" }?.isSubtask, true)

            // Detaching writes the null back, instead of keeping the old parent.
            child.parentId = nil
            try await store.upsertTask(child)
            fetched = try await store.tasks()
            expect(fetched.first { $0.id == "t-2" }?.parentId == nil, "the link should be gone")
        }
        await TestKit.shared.run("store: restoreTask drops the links the row lost") {
            let (store, path) = try makeStore()
            defer { try? FileManager.default.removeItem(atPath: path) }
            var task = TaskItem(
                id: "t-1", title: "認証を直す", detail: "", status: .todo, rank: nil,
                source: .manual, createdAt: Date(), updatedAt: Date(),
                sessionIds: ["claude:s-1", "claude:s-2"]
            )
            try await store.upsertTask(task)
            expectEqual(try await store.tasks().first?.sessionIds.count, 2)

            // upsertTask only ever adds links, so taking a wrong 紐づけ back
            // needs restoreTask.
            task.sessionIds = ["claude:s-1"]
            try await store.upsertTask(task)
            expectEqual(try await store.tasks().first?.sessionIds.count, 2)
            try await store.restoreTask(task)
            expectEqual(try await store.tasks().first?.sessionIds, ["claude:s-1"])
        }

        await TestKit.shared.run("store: a comment run is recorded once and counted for the daily limit") {
            let (store, path) = try makeStore()
            defer { try? FileManager.default.removeItem(atPath: path) }
            func run(_ id: String, task: String, trigger: AutomationTrigger = .comment) -> AutomationRun {
                AutomationRun(
                    id: id, taskId: task, title: "PR #7 ログイン画面を直す",
                    url: "https://github.com/alex/demo/pull/7", trigger: trigger,
                    author: trigger == .comment ? "coderabbitai[bot]" : nil, startedAt: Date())
            }
            try await store.recordAutomationRun(run("ghc:alex/demo#7@12", task: "gh:alex/demo#7"))
            try await store.recordAutomationRun(run("ghc:alex/demo#7@12", task: "gh:alex/demo#7"))
            expectEqual(try await store.automationEventIds(), ["ghc:alex/demo#7@12"])

            try await store.recordAutomationRun(run("ghc:alex/demo#7@13", task: "gh:alex/demo#7"))
            try await store.recordAutomationRun(run("ghc:alex/demo#9@14", task: "gh:alex/demo#9"))
            // An arrival run is a run too, but not one the comment limit counts.
            try await store.recordAutomationRun(
                run("gha:gh:alex/demo#9@1", task: "gh:alex/demo#9", trigger: .arrival))
            let counts = try await store.automationEventCounts(
                since: Date().addingTimeInterval(-3600))
            expectEqual(counts["gh:alex/demo#7"], 2)
            expectEqual(counts["gh:alex/demo#9"], 1)
            expect(
                try await store.automationEventCounts(since: Date().addingTimeInterval(3600))
                    .isEmpty,
                "nothing inside an empty window")
            expectEqual(try await store.automationEventIds().count, 3)
            expectEqual(try await store.automationRuns().count, 4)

            try await store.pruneAutomationRuns(olderThan: 30 * 24 * 3600)
            expectEqual(try await store.automationRuns().count, 4)
            try await store.pruneAutomationRuns(olderThan: -1)
            expect(try await store.automationRuns().isEmpty, "the old runs are gone")
        }

        await TestKit.shared.run("store: a run keeps its outcome and is read back newest first") {
            let (store, path) = try makeStore()
            defer { try? FileManager.default.removeItem(atPath: path) }
            let first = AutomationRun(
                id: "gha:gh:alex/demo#7@1", taskId: "gh:alex/demo#7", title: "PR #7 直す",
                url: "https://github.com/alex/demo/pull/7", trigger: .arrival,
                startedAt: Date(timeIntervalSince1970: 1_000))
            let second = AutomationRun(
                id: "ghc:alex/demo#8@20", taskId: "gh:alex/demo#8", title: "PR #8 足す",
                trigger: .comment, author: "coderabbitai[bot]",
                startedAt: Date(timeIntervalSince1970: 2_000))
            try await store.recordAutomationRun(first)
            try await store.recordAutomationRun(second)
            try await store.finishAutomationRun(
                id: first.id, state: .done, artifactPath: "/tmp/out",
                now: Date(timeIntervalSince1970: 1_500))
            try await store.finishAutomationRun(
                id: second.id, state: .failed, reason: "終了コード 1 で終わりました",
                now: Date(timeIntervalSince1970: 2_500))

            let runs = try await store.automationRuns()
            expectEqual(runs.map(\.id), [second.id, first.id])
            let done = try unwrap(runs.last)
            expectEqual(done.state, .done)
            expectEqual(done.artifactPath, "/tmp/out")
            expectEqual(done.finishedAt, Date(timeIntervalSince1970: 1_500))
            expectEqual(done.url, "https://github.com/alex/demo/pull/7")
            let failed = try unwrap(runs.first)
            expectEqual(failed.state, .failed)
            expectEqual(failed.reason, "終了コード 1 で終わりました")
            expectEqual(failed.author, "coderabbitai[bot]")
            expectEqual(failed.trigger, .comment)
        }

        await TestKit.shared.run("store: a run remembers the kind of row it fired on") {
            let (store, path) = try makeStore()
            defer { try? FileManager.default.removeItem(atPath: path) }
            try await store.recordAutomationRun(
                AutomationRun(
                    id: "gha:gh:alex/demo#7@1", taskId: "gh:alex/demo#7", title: "レビュー: PR #7 直す",
                    trigger: .arrival, startedAt: Date(timeIntervalSince1970: 2_000),
                    relation: .reviewRequested))
            // A row from a build that had no relation column reads back nil,
            // which is what makes the badge fall back to the trigger's name.
            try await store.recordAutomationRun(
                AutomationRun(
                    id: "gha:gh:alex/demo#8@1", taskId: "gh:alex/demo#8", title: "PR #8 足す",
                    trigger: .arrival, startedAt: Date(timeIntervalSince1970: 1_000)))

            let runs = try await store.automationRuns()
            expectEqual(runs.first?.relation, .reviewRequested)
            expectEqual(runs.first?.triggerLabel, "レビュー依頼")
            expectEqual(runs.last?.relation, nil)
            expectEqual(runs.last?.triggerLabel, "新着")
        }

        await TestKit.shared.run("store: a pruned output directory is cleared off the rows") {
            let (store, path) = try makeStore()
            defer { try? FileManager.default.removeItem(atPath: path) }
            let task = TaskItem(
                id: "gh:alex/demo#7", title: "PR #7 直す", detail: "", status: .todo, rank: nil,
                source: .github, createdAt: Date(), updatedAt: Date(), sessionIds: [])
            try await store.upsertTask(task)
            try await store.setAutomation(
                taskId: task.id, state: .done, artifactPath: "/tmp/out/7")
            try await store.recordAutomationRun(
                AutomationRun(
                    id: "gha:gh:alex/demo#7@1", taskId: task.id, title: task.title,
                    trigger: .arrival, startedAt: Date(), artifactPath: "/tmp/out/7"))

            try await store.clearArtifactPaths(["/tmp/out/7"])
            let stored = try unwrap(try await store.tasks().first)
            expectEqual(stored.artifactPath, nil)
            // The outcome survives: a run that succeeded a month ago still
            // succeeded, it just has nothing left to open.
            expectEqual(stored.automationState, .done)
            expectEqual(try await store.automationRuns().first?.artifactPath, nil)
        }

        await TestKit.shared.run("store: runs still running at launch are marked interrupted") {
            let (store, path) = try makeStore()
            defer { try? FileManager.default.removeItem(atPath: path) }
            let task = TaskItem(
                id: "gh:alex/demo#7", title: "PR #7 直す", detail: "", status: .todo, rank: nil,
                source: .github, createdAt: Date(), updatedAt: Date(), sessionIds: [])
            try await store.upsertTask(task)
            try await store.setAutomation(taskId: task.id, state: .running)
            try await store.recordAutomationRun(
                AutomationRun(
                    id: "gha:gh:alex/demo#7@1", taskId: task.id, title: task.title,
                    trigger: .arrival, startedAt: Date()))
            try await store.recordAutomationRun(
                AutomationRun(
                    id: "gha:gh:alex/demo#6@1", taskId: "gh:alex/demo#6", title: "PR #6",
                    trigger: .arrival, startedAt: Date(), finishedAt: Date(), state: .done))

            try await store.interruptRunningAutomation(now: Date(timeIntervalSince1970: 9_000))

            let runs = try await store.automationRuns()
            let interrupted = try unwrap(runs.first { $0.taskId == task.id })
            expectEqual(interrupted.state, .failed)
            expectEqual(interrupted.reason, Store.interruptedReason)
            expectEqual(interrupted.finishedAt, Date(timeIntervalSince1970: 9_000))
            let untouched = try unwrap(runs.first { $0.taskId == "gh:alex/demo#6" })
            expectEqual(untouched.state, .done)
            expectEqual(try await store.tasks().first?.automationState, .failed)
        }

        await TestKit.shared.run("store: deleteTask removes the row and its links") {
            let (store, path) = try makeStore()
            defer { try? FileManager.default.removeItem(atPath: path) }
            let task = TaskItem(
                id: "t-1", title: "認証を直す", detail: "", status: .todo, rank: nil,
                source: .manual, createdAt: Date(), updatedAt: Date(),
                sessionIds: ["claude:s-1"]
            )
            try await store.upsertTask(task)
            try await store.deleteTask("t-1")
            expect(try await store.tasks(includeArchived: true).isEmpty, "the row is gone")

            // A new task reusing the session must not inherit the old links.
            let reused = TaskItem(
                id: "t-2", title: "認証を直す", detail: "", status: .todo, rank: nil,
                source: .manual, createdAt: Date(), updatedAt: Date(), sessionIds: []
            )
            try await store.upsertTask(reused)
            expectEqual(try await store.tasks().first?.sessionIds, [])
        }
    }
}
