import Foundation

/// Builds the 「今日のふりかえり」 view's data and the daily-report prompt.
///
/// The report is point-in-time by design: opened mid-day it covers everything
/// up to now, opened at the end of the day it is the full 日報. The facts are
/// the user's own record of the day — the tasks finished, the tasks planned
/// and left over, and the commits that landed. Agent sessions are deliberately
/// not part of it: what an agent was doing is not what the day achieved.
public struct DailyReporter: Sendable {
    public init() {}

    /// Tasks finished today and still marked done, earliest completion first.
    /// Tasks completed before `completed_at` existed have no timestamp and
    /// fall back to `updatedAt`.
    public func completedToday(
        _ tasks: [TaskItem], now: Date = Date(), calendar: Calendar = .current
    ) -> [TaskItem] {
        tasks.filter { task in
            guard task.status == .done else { return false }
            return calendar.isDate(task.completedAt ?? task.updatedAt, inSameDayAs: now)
        }
        .sorted { ($0.completedAt ?? $0.updatedAt) < ($1.completedAt ?? $1.updatedAt) }
    }

    public func systemPrompt() -> String {
        """
        あなたはユーザーの1日の作業記録から日報を書くアシスタントです。
        読み手はユーザー本人と、その日の動きを知らないチームメイトです。
        求められているのは記録の転記ではなく、その日が何の日だったかがわかる文章です。

        出力は次の形の JSON オブジェクトだけにする。前後に説明を書かない。

        {
          "date": "2026-08-19 (水) 18:53 時点",
          "mid_day": true,
          "headline": "認証APIの移行を、レビュー指摘の反映まで進めた日。",
          "themes": [
            {"kind": "implement",
             "title": "認証APIの移行をレビュー指摘まで通した",
             "body": "同期経路の移行を実装し、レビューで挙がった3件を反映した。残るのは設定値の切り替えだけで、次の検証環境デプロイに乗せられる状態になった。",
             "evidence": ["webapp", "完了タスク2件", "コミット2件"]}
          ],
          "carry_over": [{"title": "…", "detail": "…", "meta": ["…"]}],
          "closing": "実装そのものより、レビューの往復に時間を使った1日だった。"
        }

        各フィールドの中身:
        - date: 与えられた現在時刻を読みやすい1行にする。1日の途中なら mid_day を true にする。
        - headline: 1〜2文。その日の重心（いちばん手数を使った作業）を名指しする。
          単独で読まれる場所なので、これだけで日の輪郭がわかるようにする。
        - themes: その日を2〜4個のまとまりに分ける。1件の作業を1テーマにしない。
          同じ対象、または同じ狙いに向かう作業をまとめて、1つの話として書く。
          - kind: review / design / implement / investigate / fix / ops / other から1つ。
          - title: 話題ではなく結果を書く。「CIの調査」ではなく「CIの停止を解消した」。
          - body: 2〜3文。何をして、どこまで進み、次に何が残っているかを書く。箇条書きにしない。
          - evidence: この文章の根拠にした事実を、与えられた事実の中の短い語で2〜4個。
            リポジトリ名、完了タスク数、コミット数などを入れる。事実にない語を evidence に入れない。
        - carry_over: 今日やる予定で完了しなかったタスク。手が付かなかったものは detail にそう書く。
        - closing: 1〜2文。その日が何の日だったかを言い切る。headline の言い換えにしない。
          headline が「何をしたか」なら、closing は「どこに時間が寄ったか」「何が変わったか」を書く。

        書き方:
        - 与えられた見出し文の丸写しはしない。事実を読んで、作業の意味がわかる文にする。
        - themes は最大4件、carry_over は最大8件。あふれるものは最後の項目にまとめて件数を書く。
        - 前置き、感想、励ましは書かない。「重要なのは」「〜に取り組んだ」のような中身のない語を使わない。

        事実の扱い:
        - 与えられた事実だけから書く。推測で作業内容を膨らませない。
        - 完了タスクとコミットが事実のすべてで、作業の途中経過は与えられない。
          どこまで進んだかは、完了タスクとコミットから読み取れる範囲だけ書く。
        - 存在しない時刻や件数を作らない。
        - 評価や助言は書かない。「同じリポジトリにコミットが8件ある」は事実なので書いてよい。
          「レビューの進め方に問題がある」は推測なので書かない。
        """
    }

    /// Reads the model's answer as a report.
    ///
    /// Models wrap JSON in fences or add a line before it, so the object is
    /// located by its braces rather than by parsing the whole reply. Returns
    /// nil when nothing decodes, and the caller shows the raw text instead:
    /// a badly-shaped answer must not look like an empty day.
    public func parseReport(from reply: String) -> DailyReport? {
        guard let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"),
            start < end
        else { return nil }
        let json = String(reply[start...end])
        guard let data = json.data(using: .utf8),
            let report = try? JSONDecoder().decode(DailyReport.self, from: data),
            !report.isEmpty
        else { return nil }
        return report
    }

    /// The fact sheet the LLM writes the report from: what was finished, what
    /// was planned and did not get done, and what landed in git.
    public func reportInput(
        completed: [TaskItem], carryOver: [TaskItem] = [], commits: [RepoCommits] = [],
        now: Date = Date()
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "yyyy-MM-dd (E) HH:mm"
        var input = "現在時刻: \(formatter.string(from: now))\n"

        input += "\n# 今日完了したタスク\n"
        if completed.isEmpty { input += "（なし）\n" }
        for task in completed {
            let time = timeFormatter.string(from: task.completedAt ?? task.updatedAt)
            input += "- [\(time) 完了] \(task.title)\n"
            if !task.detail.isEmpty { input += "    \(task.detail.prefix(200))\n" }
        }

        input += "\n# 今日やる予定で完了しなかったタスク\n"
        if carryOver.isEmpty { input += "（なし）\n" }
        for task in carryOver {
            input += "- \(task.title) [\(task.status.rawValue)]\n"
            if !task.detail.isEmpty { input += "    \(task.detail.prefix(200))\n" }
        }

        input += "\n# 今日のコミット（作業の実体）\n"
        if commits.isEmpty { input += "（なし、または取得できず）\n" }
        for repo in commits {
            input += "- \(repo.name): \(repo.total)件\n"
            for subject in repo.subjects {
                input += "    \(subject)\n"
            }
            let hidden = repo.total - repo.subjects.count
            if hidden > 0 { input += "    （他に\(hidden)件）\n" }
        }
        return input
    }

    private var timeFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }

}
