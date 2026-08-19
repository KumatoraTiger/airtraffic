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

    }
}
