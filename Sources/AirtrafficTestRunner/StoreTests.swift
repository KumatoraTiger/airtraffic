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

        await TestKit.shared.run("store: candidate lifecycle and negative examples") {
            let (store, path) = try makeStore()
            defer { try? FileManager.default.removeItem(atPath: path) }
            let candidate = Candidate(
                id: "c-1", title: "update readme", detail: "", confidence: 0.7,
                sessionId: "claude:s-1", agent: .claudeCode, excerpt: "...",
                status: .pending, createdAt: Date(), rejectReason: nil
            )
            try await store.insertCandidate(candidate)
            expectEqual(try await store.candidates().count, 1)

            try await store.setCandidateStatus("c-1", .rejected, rejectReason: "既に完了している")
            expect(try await store.candidates().isEmpty, "rejected candidate should leave inbox")
            expectEqual(try await store.rejectedTitles(), ["update readme"])
        }

        await TestKit.shared.run("store: one-click reject reason presets round-trip") {
            let (store, path) = try makeStore()
            defer { try? FileManager.default.removeItem(atPath: path) }
            expect(!RejectReasonPreset.allCases.isEmpty, "presets should not be empty")
            expectEqual(
                Set(RejectReasonPreset.allCases.map(\.rawValue)).count,
                RejectReasonPreset.allCases.count)

            for (index, preset) in RejectReasonPreset.allCases.enumerated() {
                let candidate = Candidate(
                    id: "c-\(index)", title: "title \(index)", detail: "", confidence: 0.6,
                    sessionId: "claude:s-1", agent: .claudeCode, excerpt: "",
                    status: .pending, createdAt: Date(), rejectReason: nil
                )
                try await store.insertCandidate(candidate)
                try await store.setCandidateStatus(
                    candidate.id, .rejected, rejectReason: preset.rawValue)
            }
            let rejected = try await store.candidates(status: .rejected)
            expectEqual(
                Set(rejected.compactMap(\.rejectReason)),
                Set(RejectReasonPreset.allCases.map(\.rawValue)))
        }

        await TestKit.shared.run("store: duplicate candidates are rejected at insert") {
            let (store, path) = try makeStore()
            defer { try? FileManager.default.removeItem(atPath: path) }
            func candidate(_ id: String, _ title: String) -> Candidate {
                Candidate(
                    id: id, title: title, detail: "", confidence: 0.7, sessionId: "claude:s-\(id)",
                    agent: .claudeCode, excerpt: "", status: .pending, createdAt: Date(),
                    rejectReason: nil)
            }
            expect(try await store.insertCandidate(candidate("c-1", "READMEを更新する")), "first insert")
            expect(
                try await store.insertCandidate(candidate("c-2", "README を更新する")) == false,
                "same title from another session should be dropped")
            expectEqual(try await store.candidates().count, 1)

            // A candidate the user rejected must not reappear either.
            try await store.setCandidateStatus("c-1", .rejected, rejectReason: nil)
            expect(
                try await store.insertCandidate(candidate("c-3", "READMEを更新する")) == false,
                "rejected title should stay out of the inbox")
            expectEqual(try await store.knownCandidateTitles(), ["READMEを更新する"])
        }

        await TestKit.shared.run("store: closed candidates listing and reopen") {
            let (store, path) = try makeStore()
            defer { try? FileManager.default.removeItem(atPath: path) }
            func candidate(_ id: String, _ title: String, createdAt: Date = Date()) -> Candidate {
                Candidate(
                    id: id, title: title, detail: "", confidence: 0.6, sessionId: "claude:s-1",
                    agent: .claudeCode, excerpt: "", status: .pending, createdAt: createdAt,
                    rejectReason: nil)
            }
            try await store.insertCandidate(candidate("c-1", "clean up logging"))
            try await store.insertCandidate(
                candidate("c-2", "bump dependencies", createdAt: Date(timeIntervalSinceNow: -100 * 3600)))
            try await store.insertCandidate(candidate("c-3", "write changelog"))

            try await store.setCandidateStatus("c-1", .rejected, rejectReason: "対応不要と判断した")
            try await store.expireCandidates(olderThan: 72 * 3600)
            try await store.setCandidateStatus("c-3", .accepted)

            // Rejected and expired show up in the closed list; kept ones do not.
            let closed = try await store.closedCandidates()
            expectEqual(Set(closed.map(\.id)), Set(["c-1", "c-2"]))
            expect(closed.allSatisfy { $0.closedAt != nil }, "closed candidates carry closed_at")

            // Reopening puts the candidate back as pending, wipes the reject
            // reason, and survives the next expiry sweep even for an old one.
            try await store.reopenCandidate("c-2")
            try await store.expireCandidates(olderThan: 72 * 3600)
            let pending = try await store.candidates()
            expectEqual(pending.map(\.id), ["c-2"])
            expectEqual(pending.first?.rejectReason, nil)
            expectEqual(pending.first?.closedAt, nil)
            expectEqual(try await store.closedCandidates().map(\.id), ["c-1"])
        }

        await TestKit.shared.run("store: candidate expiry") {
            let (store, path) = try makeStore()
            defer { try? FileManager.default.removeItem(atPath: path) }
            let old = Candidate(
                id: "c-old", title: "stale idea", detail: "", confidence: 0.5,
                sessionId: "x", agent: .codex, excerpt: "",
                status: .pending, createdAt: Date().addingTimeInterval(-100 * 3600), rejectReason: nil
            )
            try await store.insertCandidate(old)
            try await store.expireCandidates(olderThan: 72 * 3600)
            expect(try await store.candidates().isEmpty, "old pending candidate should expire")
            expectEqual(try await store.candidates(status: .expired).count, 1)
        }
    }
}
