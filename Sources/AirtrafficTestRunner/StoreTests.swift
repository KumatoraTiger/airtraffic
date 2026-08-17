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
