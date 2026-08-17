import Foundation

/// The prioritization chat: proposes a ranking with reasons, in dialogue with
/// the user. The AI proposes; the human decides. Applied rankings come back as
/// a machine-readable block the app can parse.
public struct Prioritizer: Sendable {
    public init() {}

    /// A ranking proposal parsed out of an assistant reply, if one is present.
    public struct RankingProposal: Sendable {
        public var orderedTaskIds: [String]
    }

    public func systemPrompt(
        tasks: [TaskItem],
        sessions: [SessionSnapshot],
        preferences: [PreferenceNote]
    ) -> String {
        var prompt = """
        あなたは並列で動くコーディングエージェントのタスクの優先順位付けを、ユーザーとの壁打ちで支援するアシスタントです。

        原則:
        - 順位はあなたが決めるのではなく提案する。必ず理由を添える。
        - 入力待ち・承認待ちのセッションに紐づくタスクは、数秒の対応で進むため原則優先度が高い。
        - ユーザーが順位を変えたら、その判断を尊重し preference として学ぶ。
        - 簡潔に。順位と理由が中心で、前置きは不要。

        順位の提案・変更に合意が取れたときだけ、返答の最後に次の形式のブロックを1つ出力する:
        ```ranking
        ["task-id-1", "task-id-2", ...]
        ```
        雑談や質問への回答だけのときは ranking ブロックを出さない。

        """
        prompt += "\n# 現在のタスク一覧\n"
        if tasks.isEmpty {
            prompt += "（なし）\n"
        }
        for task in tasks {
            let rank = task.rank.map { "rank=\($0)" } ?? "未ランク"
            prompt += "- id=\(task.id) [\(task.status.rawValue)] \(rank): \(task.title)\n"
            if !task.detail.isEmpty { prompt += "    \(task.detail.prefix(200))\n" }
        }
        prompt += "\n# セッション状況\n"
        for session in sessions.prefix(20) {
            prompt += "- [\(session.agent.displayName)] \(session.status.displayName): \(session.title)（\(session.projectName)）\n"
        }
        if !preferences.isEmpty {
            prompt += "\n# ユーザーの優先順位づけの傾向（過去の学習）\n"
            for preference in preferences.suffix(20) {
                prompt += "- \(preference.text)\n"
            }
        }
        return prompt
    }

    /// Parses the trailing ```ranking``` block, if any.
    public func parseRanking(from reply: String) -> RankingProposal? {
        guard let blockRange = reply.range(of: "```ranking") else { return nil }
        let tail = reply[blockRange.upperBound...]
        guard let end = tail.range(of: "```") else { return nil }
        let jsonText = String(tail[..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = jsonText.data(using: .utf8),
              let ids = (try? JSONSerialization.jsonObject(with: data)) as? [String],
              !ids.isEmpty
        else { return nil }
        return RankingProposal(orderedTaskIds: ids)
    }

    /// Strips the machine-readable block for display.
    public func displayText(from reply: String) -> String {
        guard let blockRange = reply.range(of: "```ranking") else { return reply }
        return String(reply[..<blockRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
