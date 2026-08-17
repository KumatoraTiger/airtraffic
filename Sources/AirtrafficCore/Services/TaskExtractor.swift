import Foundation

/// Extracts task candidates from new transcript text via an LLM.
///
/// False-positive strategy: results are inserted as inbox *candidates*, never
/// as tasks. The prompt carries what is already known — tasks, pending
/// candidates, and previously rejected titles, each in its own section — and a
/// confidence threshold drops the weakest extractions. Whatever the LLM still
/// returns as a duplicate is then filtered by `TitleMatcher`.
public struct TaskExtractor: Sendable {
    public var confidenceThreshold: Double
    /// Cap on transcript characters per extraction call.
    public var maxChunkLength: Int

    public init(confidenceThreshold: Double = 0.4, maxChunkLength: Int = 12000) {
        self.confidenceThreshold = confidenceThreshold
        self.maxChunkLength = maxChunkLength
    }

    public struct Extraction: Sendable {
        public var title: String
        public var detail: String
        public var confidence: Double
        public var excerpt: String
    }

    /// Everything the extractor already knows about, split by how it is used.
    ///
    /// The first three groups get their own section in the prompt with its own
    /// budget, so a long task list can no longer crowd the inbox out of the
    /// prompt entirely. Every group, including `otherSeen`, feeds the
    /// deterministic filter that runs on the response.
    public struct KnownTitles: Sendable {
        /// Existing tasks, most relevant first.
        public var tasks: [String]
        /// Candidates still waiting in the inbox.
        public var pendingCandidates: [String]
        /// Candidates the user rejected before; shown as negative examples.
        public var rejected: [String]
        /// Titles already handled some other way (accepted, expired, older
        /// candidates). Too many to show the LLM, but still duplicates.
        public var otherSeen: [String]

        public init(
            tasks: [String] = [], pendingCandidates: [String] = [],
            rejected: [String] = [], otherSeen: [String] = []
        ) {
            self.tasks = tasks
            self.pendingCandidates = pendingCandidates
            self.rejected = rejected
            self.otherSeen = otherSeen
        }

        var all: [String] { tasks + pendingCandidates + rejected + otherSeen }
    }

    public func extract(
        client: any LLMClient,
        newText: String,
        sessionTitle: String,
        known: KnownTitles
    ) async throws -> [Extraction] {
        let chunk = String(newText.suffix(maxChunkLength))
        guard !chunk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }

        let system = """
            あなたはコーディングエージェントのセッションログから「人間が後で対応すべきタスク」を抽出するアシスタントです。

            抽出するもの:
            - ユーザーやエージェントが言及した、まだ完了していない作業（「あとで直す」「別タスクにする」「TODO」など）
            - セッションのスコープ外として先送りされた作業
            - エージェントが提案し、ユーザーが暗黙的・明示的に合意した追加作業

            抽出しないもの:
            - このセッション内で既に完了した作業
            - エージェント自身が今まさに実行中の作業
            - 一般論や仮定の話
            - 既存タスクや未処理の候補にあるものと実質同じもの（言い回しが違っていても同じ作業なら抽出しない）

            出力は次の JSON のみ: {"candidates": [{"title": "簡潔な日本語タイトル", "detail": "背景を1-2文", "confidence": 0.0-1.0, "excerpt": "根拠となるログの短い引用"}]}
            該当がなければ {"candidates": []} を返す。確信が持てないものは confidence を低くする。
            """

        var prompt = "# セッション: \(sessionTitle)\n\n"
        prompt += section("既存タスク（重複させない）", known.tasks, limit: 20)
        prompt += section("未処理の候補（重複させない）", known.pendingCandidates, limit: 30)
        prompt += section("過去に却下された候補（同種のものは抽出しない）", known.rejected, limit: 20)
        prompt += "# 新着ログ:\n\(chunk)"

        let response = try await client.complete(
            LLMRequest(
                system: system,
                messages: [ChatMessage(role: .user, text: prompt)],
                jsonMode: true,
                maxTokens: 2048
            ))

        guard let data = LLMJSON.extractJSON(from: response),
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let raw = json["candidates"] as? [[String: Any]]
        else { return [] }

        let parsed = raw.compactMap { item -> Extraction? in
            guard let title = item["title"] as? String, !title.isEmpty else { return nil }
            let confidence =
                (item["confidence"] as? Double)
                ?? (item["confidence"] as? Int).map(Double.init) ?? 0
            guard confidence >= confidenceThreshold else { return nil }
            return Extraction(
                title: title,
                detail: item["detail"] as? String ?? "",
                confidence: min(max(confidence, 0), 1),
                excerpt: item["excerpt"] as? String ?? ""
            )
        }

        // Deterministic dedupe on top of the prompt-level instruction. Titles
        // already accepted grow the comparison set, so one response cannot
        // return the same task twice under two phrasings either.
        var seen = known.all
        var accepted: [Extraction] = []
        for extraction in parsed {
            guard !seen.contains(where: { TitleMatcher.isSimilar($0, extraction.title) }) else {
                continue
            }
            seen.append(extraction.title)
            accepted.append(extraction)
        }
        return accepted
    }

    /// One titled bullet list, or nothing when the group is empty.
    private func section(_ heading: String, _ titles: [String], limit: Int) -> String {
        guard !titles.isEmpty else { return "" }
        return "# \(heading):\n"
            + titles.prefix(limit).map { "- \($0)" }.joined(separator: "\n") + "\n\n"
    }
}
