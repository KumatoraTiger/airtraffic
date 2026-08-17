import AirtrafficCore
import Foundation

/// Canned-response LLM client for testing extraction and prioritization
/// without network access.
struct MockLLMClient: LLMClient {
    let kind: ProviderKind = .gemini
    let response: String

    func complete(_ request: LLMRequest) async throws -> String { response }
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
                sessionTitle: "demo", existingTitles: [], rejectedTitles: [])
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
                existingTitles: ["README を更新する"], rejectedTitles: [])
            expect(results.isEmpty, "similar title should be deduped")
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
                existingTitles: [], rejectedTitles: [])
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
