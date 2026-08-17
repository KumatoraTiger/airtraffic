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
    func runAll() async {
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

        await TestKit.shared.run("extractor: a long task list never crowds out the inbox") {
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
