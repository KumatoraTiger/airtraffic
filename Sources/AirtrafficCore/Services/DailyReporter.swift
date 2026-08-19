import Foundation

/// Builds the 「今日のふりかえり」 view's data and the daily-report prompt.
///
/// The report is point-in-time by design: opened mid-day it covers everything
/// up to now, opened at the end of the day it is the full 日報. All selection
/// is deterministic; the LLM only turns the selected facts into prose.
public struct DailyReporter: Sendable {
    public init() {}

    /// One line of today's session activity: what work ran, on which agent.
    public struct ActivityItem: Identifiable, Hashable, Sendable {
        public var id: String { title }
        public var title: String
        public var agents: [AgentKind]
        public var lastActivity: Date

        public init(title: String, agents: [AgentKind], lastActivity: Date) {
            self.title = title
            self.agents = agents
            self.lastActivity = lastActivity
        }
    }

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

    /// Today's session activity, one item per distinct piece of work. Work
    /// labels name and merge sessions; unlabeled sessions fall back to their
    /// cleaned titles. Subagents are internal machinery, not the user's work.
    public func activityToday(
        sessions: [SessionSnapshot], labels: [String: WorkLabel],
        now: Date = Date(), calendar: Calendar = .current
    ) -> [ActivityItem] {
        var items: [String: ActivityItem] = [:]
        for session in sessions {
            guard !session.isSubagent,
                calendar.isDate(session.lastActivity, inSameDayAs: now)
            else { continue }
            let title: String
            if let label = labels[session.id], !label.isPlaceholder {
                title = label.displayTitle
            } else {
                let cleaned = TitleCleaner.taskLabel(session.title)
                guard !cleaned.isEmpty else { continue }
                title = cleaned
            }
            var item =
                items[title]
                ?? ActivityItem(title: title, agents: [], lastActivity: session.lastActivity)
            if !item.agents.contains(session.agent) { item.agents.append(session.agent) }
            item.lastActivity = max(item.lastActivity, session.lastActivity)
            items[title] = item
        }
        return items.values.sorted { $0.lastActivity > $1.lastActivity }
    }

    public func systemPrompt() -> String {
        """
        あなたはユーザーの1日の作業記録から日報を書くアシスタントです。

        原則:
        - 与えられた事実だけから書く。推測で作業内容を膨らませない。
        - Markdown で、次の見出し構成にする: 「## 完了したこと」「## 進行中」「## 残っていること」。
        - 各項目は1行で簡潔に。件数が0の見出しは「（なし）」と書く。
        - 冒頭に日付と、生成時点が1日の途中ならその旨を1行で書く。
        - 前置きや感想は不要。日報本文だけを出力する。
        """
    }

    /// The fact sheet the LLM writes the report from.
    public func reportInput(
        completed: [TaskItem], activity: [ActivityItem], remainingToday: [TaskItem],
        now: Date = Date()
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "yyyy-MM-dd (E) HH:mm"
        var input = "現在時刻: \(formatter.string(from: now))\n"

        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm"
        input += "\n# 今日完了したタスク\n"
        if completed.isEmpty { input += "（なし）\n" }
        for task in completed {
            let time = timeFormatter.string(from: task.completedAt ?? task.updatedAt)
            input += "- [\(time) 完了] \(task.title)\n"
            if !task.detail.isEmpty { input += "    \(task.detail.prefix(200))\n" }
        }

        input += "\n# 今日動いたセッション（進行中の作業を含む）\n"
        if activity.isEmpty { input += "（なし）\n" }
        for item in activity {
            let agents = item.agents.map(\.displayName).joined(separator: ", ")
            input += "- \(item.title)（\(agents)）\n"
        }

        input += "\n# 今日やる予定でまだ完了していないタスク\n"
        if remainingToday.isEmpty { input += "（なし）\n" }
        for task in remainingToday {
            input += "- [\(task.status.rawValue)] \(task.title)\n"
        }
        return input
    }
}
