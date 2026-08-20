import Foundation

/// Builds the 「今日のふりかえり」 view's data and the daily-report prompt.
///
/// The report is point-in-time by design: opened mid-day it covers everything
/// up to now, opened at the end of the day it is the full 日報. Selection and
/// merging are deterministic; the LLM only turns the selected facts into
/// prose. Merging matters: without it every session of the same PR becomes
/// its own line and the report degenerates into a transcript of session
/// titles.
public struct DailyReporter: Sendable {
    public init() {}

    /// How much of the user's attention a piece of work still holds.
    ///
    /// `awaitingUser` is deliberately not called 進行中: a session that ended
    /// its turn waiting for input looks the same whether the work is finished
    /// and the tab was simply left open, or the work is genuinely blocked on
    /// the user. Only the elapsed time hints at which, so the report says
    /// "確認待ち" and leaves the judgement to the reader.
    public enum ActivityState: String, Sendable, Comparable {
        /// The agent is producing output right now.
        case running
        /// Ended its turn waiting for the user; may be blocked, may be abandoned.
        case awaitingUser
        /// No recent activity at all.
        case quiet

        /// Ordering for the report: the most alive state first.
        public var rank: Int {
            switch self {
            case .running: 0
            case .awaitingUser: 1
            case .quiet: 2
            }
        }

        public var displayName: String {
            switch self {
            case .running: "実行中"
            case .awaitingUser: "確認待ち"
            case .quiet: "停止"
            }
        }

        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }

        init(_ status: SessionStatus) {
            switch status {
            case .running: self = .running
            case .waitingInput, .waitingApproval: self = .awaitingUser
            case .idle: self = .quiet
            }
        }
    }

    /// One piece of work from today, with every session that touched it merged
    /// into it. The key is the target (a PR or issue number, otherwise the
    /// work's subject), so three review sessions on the same PR are one item.
    public struct ActivityItem: Identifiable, Hashable, Sendable {
        public var id: String
        public var title: String
        public var project: String
        public var agents: [AgentKind]
        public var kinds: [WorkKind]
        public var sessionCount: Int
        public var state: ActivityState
        /// Earliest and latest session activity in the group; the day's span
        /// of this work as far as the transcripts show it.
        public var firstActivity: Date
        public var lastActivity: Date
        /// Unfinished todos left in the sessions, deduplicated.
        public var openTodos: [String]
        /// Short excerpt of the newest assistant output: what the work last said.
        public var lastOutput: String
        /// Ids of the merged sessions, newest first; how the work is matched
        /// against the day's planned tasks.
        public var sessionIds: [String]

        public init(
            id: String, title: String, project: String = "", agents: [AgentKind] = [],
            kinds: [WorkKind] = [], sessionCount: Int = 1, state: ActivityState = .quiet,
            firstActivity: Date = Date(), lastActivity: Date = Date(),
            openTodos: [String] = [], lastOutput: String = "", sessionIds: [String] = []
        ) {
            self.id = id
            self.title = title
            self.project = project
            self.agents = agents
            self.kinds = kinds
            self.sessionCount = sessionCount
            self.state = state
            self.firstActivity = firstActivity
            self.lastActivity = lastActivity
            self.openTodos = openTodos
            self.lastOutput = lastOutput
            self.sessionIds = sessionIds
        }
    }

    /// A task the day planned for, with the work that actually ran on it.
    public struct PlannedWork: Sendable {
        public var task: TaskItem
        public var activity: [ActivityItem]

        public init(task: TaskItem, activity: [ActivityItem]) {
            self.task = task
            self.activity = activity
        }
    }

    /// The day's plan next to what happened, which is where a report stops
    /// listing work and starts saying something: the third bucket names the
    /// work that took the day without being planned for.
    public struct PlanComparison: Sendable {
        /// Planned tasks that saw work today.
        public var worked: [PlannedWork]
        /// Planned tasks with no session activity today at all.
        public var untouched: [TaskItem]
        /// Work that ran without a planned task behind it.
        public var unplanned: [ActivityItem]

        public init(
            worked: [PlannedWork] = [], untouched: [TaskItem] = [],
            unplanned: [ActivityItem] = []
        ) {
            self.worked = worked
            self.untouched = untouched
            self.unplanned = unplanned
        }
    }

    /// Activity items beyond this many are dropped from the prompt, with the
    /// dropped count stated in the fact sheet so the LLM never presents a
    /// truncated day as the whole day.
    private static let promptItemLimit = 20
    private static let outputExcerptLength = 160

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

    /// Today's work, one item per target rather than one per session.
    /// Subagents are internal machinery, not the user's work.
    public func activityToday(
        sessions: [SessionSnapshot], labels: [String: WorkLabel],
        now: Date = Date(), calendar: Calendar = .current
    ) -> [ActivityItem] {
        var groups: [String: ActivityItem] = [:]
        // Newest first so the group's title and last output come from the most
        // recent session that touched the work.
        let today =
            sessions
            .filter {
                !$0.isSubagent && calendar.isDate($0.lastActivity, inSameDayAs: now)
            }
            .sorted { $0.lastActivity > $1.lastActivity }

        for session in today {
            let label = labels[session.id].flatMap { $0.isPlaceholder ? nil : $0 }
            let title = label?.displayTitle ?? TitleCleaner.taskLabel(session.title)
            guard isMeaningful(title) else { continue }
            let subject = label?.subject ?? title
            let key = mergeKey(subject: subject)
            let state = ActivityState(session.status)
            let todos = session.todos.filter { $0.status != .completed }.map(\.content)

            guard var item = groups[key] else {
                groups[key] = ActivityItem(
                    id: key, title: title, project: session.projectName,
                    agents: [session.agent], kinds: label.map { [$0.kind] } ?? [],
                    sessionCount: 1, state: state,
                    firstActivity: session.lastActivity, lastActivity: session.lastActivity,
                    openTodos: todos, lastOutput: excerpt(session.lastAssistantText),
                    sessionIds: [session.id])
                continue
            }
            item.sessionCount += 1
            if !item.agents.contains(session.agent) { item.agents.append(session.agent) }
            if let kind = label?.kind, !item.kinds.contains(kind) { item.kinds.append(kind) }
            item.state = min(item.state, state)
            item.firstActivity = min(item.firstActivity, session.lastActivity)
            item.lastActivity = max(item.lastActivity, session.lastActivity)
            for todo in todos where !item.openTodos.contains(todo) { item.openTodos.append(todo) }
            // Sessions are walked newest first, so the first non-empty output
            // wins: the newest session may have written nothing yet.
            if item.lastOutput.isEmpty { item.lastOutput = excerpt(session.lastAssistantText) }
            item.sessionIds.append(session.id)
            groups[key] = item
        }

        return groups.values.sorted {
            $0.state == $1.state
                ? $0.lastActivity > $1.lastActivity : $0.state < $1.state
        }
    }

    /// Lines up today's tasks with today's work.
    ///
    /// Tasks count as planned when the user picked them for today or finished
    /// them today; matching reuses the board's session-to-task rules, so a
    /// task and the sessions doing it stay together here exactly as they do on
    /// the board.
    public func comparePlan(
        tasks: [TaskItem], activity: [ActivityItem], sessions: [SessionSnapshot],
        labels: [String: WorkLabel] = [:], now: Date = Date(), calendar: Calendar = .current
    ) -> PlanComparison {
        let byId = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let planned = tasks.filter { task in
            if task.status == .archived { return false }
            if task.isToday && task.status != .done { return true }
            return task.status == .done
                && calendar.isDate(task.completedAt ?? task.updatedAt, inSameDayAs: now)
        }

        var claimed: Set<String> = []
        var worked: [PlannedWork] = []
        var untouched: [TaskItem] = []
        for task in planned {
            let matched = activity.filter { item in
                item.sessionIds.contains { id in
                    guard let session = byId[id] else { return false }
                    return BoardAssembler.attaches(
                        session, to: task, labels: labels, matchDoneByTitle: true)
                }
            }
            if matched.isEmpty {
                untouched.append(task)
            } else {
                claimed.formUnion(matched.map(\.id))
                worked.append(PlannedWork(task: task, activity: matched))
            }
        }
        return PlanComparison(
            worked: worked, untouched: untouched,
            unplanned: activity.filter { !claimed.contains($0.id) })
    }

    /// Titles that name no work: placeholders the agents write when a session
    /// has no first user message yet.
    private func isMeaningful(_ title: String) -> Bool {
        let stripped = title.trimmingCharacters(in: CharacterSet(charactersIn: "()（） 　"))
        return !stripped.isEmpty && stripped != "無題" && stripped != "Untitled"
    }

    /// The merge key for a piece of work. A PR or issue number identifies the
    /// target far more reliably than the wording around it, so "PR #123 の
    /// レビュー" and "#123 の 認証APIの移行" land in the same group; without a
    /// number, the normalized subject has to do.
    ///
    /// The project is deliberately not part of the key: one PR is often worked
    /// on from several worktrees of the same repo, and those have different
    /// directory names.
    func mergeKey(subject: String) -> String {
        if let number = referenceNumber(in: subject) { return "#\(number)" }
        return normalize(subject)
    }

    /// First `#1234` / `PR 1234` / `issue 1234` style reference in the text.
    private func referenceNumber(in text: String) -> String? {
        let patterns = [
            #"#\s*(\d{2,6})"#,
            #"(?i)(?:PR|pull\s*request|issue|チケット)\s*(\d{2,6})"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                let match = regex.firstMatch(
                    in: text, range: NSRange(text.startIndex..., in: text)),
                let range = Range(match.range(at: 1), in: text)
            else { continue }
            return String(text[range])
        }
        return nil
    }

    /// Folds away the differences that make the same subject look like two:
    /// case, spacing, and the punctuation agents sprinkle into titles.
    private func normalize(_ text: String) -> String {
        let dropped = CharacterSet.whitespacesAndNewlines
            .union(.punctuationCharacters)
            .union(CharacterSet(charactersIn: "・「」（）()【】:：、。/-—"))
        return text.lowercased().components(separatedBy: dropped).joined()
    }

    private func excerpt(_ text: String) -> String {
        let flat = text.replacingOccurrences(
            of: #"\s+"#, with: " ", options: .regularExpression
        ).trimmingCharacters(in: .whitespaces)
        guard flat.count > Self.outputExcerptLength else { return flat }
        return String(flat.prefix(Self.outputExcerptLength)) + "…"
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
             "evidence": ["webapp", "3セッション 14:02–18:40", "コミット2件"]}
          ],
          "timeline": [
            {"time": "14:02", "title": "移行の実装に着手", "note": "既存経路と衝突しない差分に絞った。"}
          ],
          "stuck": [{"title": "…", "detail": "…", "meta": ["…"]}],
          "carry_over": [{"title": "…", "detail": "…", "meta": ["…"]}],
          "closing": "実装そのものより、レビューの往復に時間を使った1日だった。"
        }

        各フィールドの中身:
        - date: 与えられた現在時刻を読みやすい1行にする。1日の途中なら mid_day を true にする。
        - headline: 1〜2文。その日の重心（いちばん時間と往復を使った作業）を名指しする。
          単独で読まれる場所なので、これだけで日の輪郭がわかるようにする。
        - themes: その日を2〜4個のまとまりに分ける。1件の作業を1テーマにしない。
          同じ対象、または同じ狙いに向かう作業をまとめて、1つの話として書く。
          - kind: review / design / implement / investigate / fix / ops / other から1つ。
          - title: 話題ではなく結果を書く。「CIの調査」ではなく「CIの停止を解消した」。
          - body: 2〜3文。何をして、どこまで進み、次に何が残っているかを書く。箇条書きにしない。
          - evidence: この文章の根拠にした事実を、与えられた事実の中の短い語で2〜4個。
            リポジトリ名、セッション数と時間帯、コミット数、停止時間などを入れる。
            事実にない語を evidence に入れない。
        - timeline: その日の転換点を3〜6件、時刻の早い順に並べる。同じ内容を刻まない。
          time は与えられた時刻から書く。存在しない時刻を作らない。
        - stuck: 確認待ちのまま止まっているもの、未完了TODOが残っているもの。
        - carry_over: 今日やる予定で完了しなかったタスク。手が付かなかったものは detail にそう書く。
        - closing: 1〜2文。その日が何の日だったかを言い切る。headline の言い換えにしない。
          headline が「何をしたか」なら、closing は「どこに時間が寄ったか」「何が変わったか」を書く。

        書き方:
        - 与えられた見出し文の丸写しはしない。事実を読んで、作業の意味がわかる文にする。
        - themes は最大4件、timeline は最大6件、stuck と carry_over は各最大8件。
          あふれるものは最後の項目にまとめて件数を書く。
        - 前置き、感想、励ましは書かない。「重要なのは」「〜に取り組んだ」のような中身のない語を使わない。

        事実の扱い:
        - 与えられた事実だけから書く。推測で作業内容を膨らませない。
        - 状態が「実行中」のものだけを進行中の作業として扱う。
        - 状態が「確認待ち」のものは、作業が終わってタブを閉じ忘れた場合と、返答を待って止まっている場合の
          区別がつかない。どちらかに決めつけず、経過時間が長いものは放置されている可能性に触れる。
        - 評価や助言は書かない。「同じPRに3セッション使った」は事実なので書いてよい。
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

    /// The fact sheet the LLM writes the report from.
    public func reportInput(
        completed: [TaskItem], plan: PlanComparison, commits: [RepoCommits] = [],
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

        input += "\n# 予定していた作業とその進み（同じ対象のセッションは統合済み）\n"
        if plan.worked.isEmpty { input += "（なし）\n" }
        for entry in plan.worked {
            input += "- タスク「\(entry.task.title)」[\(entry.task.status.rawValue)]\n"
            for item in entry.activity.prefix(3) {
                input += "  " + activityLine(item, now: now)
            }
        }

        input += "\n# 予定していたが今日は手が付かなかったタスク\n"
        if plan.untouched.isEmpty { input += "（なし）\n" }
        for task in plan.untouched {
            input += "- \(task.title) [\(task.status.rawValue)]\n"
        }

        input += "\n# 予定外に動いた作業\n"
        if plan.unplanned.isEmpty { input += "（なし）\n" }
        for item in plan.unplanned.prefix(Self.promptItemLimit) {
            input += activityLine(item, now: now)
        }
        let dropped = plan.unplanned.count - Self.promptItemLimit
        if dropped > 0 {
            input += "（他に\(dropped)件、更新の古いものを省略）\n"
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

    /// One activity item as a fact line, with its follow-up lines.
    private func activityLine(_ item: ActivityItem, now: Date) -> String {
        var facts: [String] = []
        if !item.project.isEmpty { facts.append("対象: \(item.project)") }
        facts.append("状態: \(stateText(for: item, now: now))")
        let span =
            "\(timeFormatter.string(from: item.firstActivity))–"
            + timeFormatter.string(from: item.lastActivity)
        facts.append("セッション\(item.sessionCount)件 (\(span))")
        facts.append(item.agents.map(\.displayName).joined(separator: ", "))
        var line = "- \(item.title)【\(facts.joined(separator: " / "))】\n"
        if !item.openTodos.isEmpty {
            line += "    未完了TODO: \(item.openTodos.prefix(5).joined(separator: " / "))\n"
        }
        if !item.lastOutput.isEmpty {
            line += "    直近の出力: \(item.lastOutput)\n"
        }
        return line
    }

    private var timeFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }

    /// State plus, for the ambiguous one, how long it has been sitting there.
    private func stateText(for item: ActivityItem, now: Date) -> String {
        guard item.state == .awaitingUser else { return item.state.displayName }
        let elapsed = max(0, now.timeIntervalSince(item.lastActivity))
        return "\(item.state.displayName)（\(elapsedText(elapsed))前から止まっており、完了済みか放置かは不明）"
    }

    private func elapsedText(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes)分" }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "\(hours)時間" : "\(hours)時間\(rest)分"
    }
}
