import Foundation

/// What the app does with a task whose issue or pull request was closed or
/// merged upstream.
public enum GitHubCloseBehavior: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Move it to 完了, so the daily report counts it with the rest of the day.
    case complete
    /// Leave it where it is with a note in its detail line.
    case mark
    /// Leave it entirely alone.
    case keep

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .complete: "完了にする"
        case .mark: "印を付けて残す"
        case .keep: "何もしない"
        }
    }
}

/// How the GitHub inbox is configured. Repositories are opted OUT, never in:
/// a repository the user starts working in shows up on its own, and the ones
/// they never want to see are listed here.
public struct GitHubSettings: Sendable, Equatable {
    public var enabled: Bool
    public var excludedRepos: Set<String>
    public var closeBehavior: GitHubCloseBehavior

    public init(
        enabled: Bool = false, excludedRepos: Set<String> = [],
        closeBehavior: GitHubCloseBehavior = .complete
    ) {
        self.enabled = enabled
        self.excludedRepos = excludedRepos
        self.closeBehavior = closeBehavior
    }
}

/// Turns GitHub items into task rows, and closed items into task updates.
///
/// Pure by design: every rule here is decided without touching the network or
/// the store, which is what makes it testable in this repository's harness.
public enum GitHubTaskSync {
    /// Appended to the detail line under the 「印を付けて残す」 behavior. Also read
    /// back, so a task reopened upstream loses the note again.
    public static let closedMarker = "GitHub 上は完了"

    /// Prefixed on the title of a pull request waiting for the user's review,
    /// so the board says what the row asks of them before its subject.
    public static let reviewPrefix = "レビュー: "

    /// The `PR #123 ` / `issue #123 ` marker put in front of every GitHub
    /// title, so the board says what kind of item the row stands for and
    /// which one it is.
    public static func kindPrefix(for item: GitHubItem) -> String {
        "\(item.isPullRequest ? "PR" : "issue") #\(item.number) "
    }

    /// The title of a GitHub task: what the item is and its number, then the
    /// item's own title, with 「レビュー: 」 in front when the item is a review
    /// request.
    ///
    /// The markers are stripped off the incoming title before being put back,
    /// so a re-scan never stacks them, a row written by an older build is
    /// rewritten into the current convention, and an upstream title that
    /// already reads 「レビュー: …」 is not doubled.
    public static func title(for item: GitHubItem) -> String {
        let titled = kindPrefix(for: item) + strippedTitle(item.title, number: item.number)
        return item.relation == .reviewRequested ? reviewPrefix + titled : titled
    }

    /// The subject alone: every marker this type ever wrote in front of a
    /// title, removed in any order and any number of times.
    private static func strippedTitle(_ title: String, number: Int) -> String {
        let markers = [reviewPrefix, "PR #\(number) ", "issue #\(number) ", "#\(number) "]
        var body = Substring(title)
        var stripping = true
        while stripping {
            stripping = false
            for marker in markers where body.hasPrefix(marker) {
                body = body.dropFirst(marker.count)
                stripping = true
            }
        }
        return String(body)
    }

    /// The detail line of a GitHub task: what the item is, then its link.
    public static func detail(for item: GitHubItem) -> String {
        let kind = item.isDraft ? "\(item.relation.displayName)（下書き）" : item.relation.displayName
        return "\(kind) · \(item.repo)#\(item.number)\n\(item.url)"
    }

    /// The relation a stored task was built from, read back out of its
    /// detail line.
    ///
    /// The detail line is machine-owned (`detail(for:)` writes it and nothing
    /// else edits it), which is what makes reading it back safe. A row from an
    /// older build, or one whose line was hand-edited, answers nil.
    public static func relation(fromDetail detail: String) -> GitHubRelation? {
        guard let head = detail.split(separator: "\n").first,
            let kind = head.split(separator: "·").first
        else { return nil }
        let name = kind.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "（下書き）", with: "")
        return GitHubRelation.allCases.first { $0.displayName == name }
    }

    /// The link a stored task was built from, read back out of its detail
    /// line. Nil when no line of it parses as a URL.
    public static func url(fromDetail detail: String) -> String? {
        detail.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { URL(string: $0)?.scheme != nil }
    }

    /// One item per task id, keeping the most pressing reason it matched.
    public static func deduplicate(_ items: [GitHubItem]) -> [GitHubItem] {
        var best: [String: GitHubItem] = [:]
        for item in items {
            guard let held = best[item.taskId] else {
                best[item.taskId] = item
                continue
            }
            if item.relation.precedence < held.relation.precedence { best[item.taskId] = item }
        }
        return best.values.sorted { $0.taskId < $1.taskId }
    }

    /// Rows to write for the items that are open right now.
    ///
    /// An archived task is never rebuilt: archiving a GitHub row is how the
    /// user says "not this one", and a sync that undid that would make the
    /// board unusable. A row the user already completed keeps its status too;
    /// only its title and link are refreshed.
    public static func upserts(
        open items: [GitHubItem], existing: [TaskItem], settings: GitHubSettings, now: Date = Date()
    ) -> [TaskItem] {
        let byId = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [TaskItem] = []
        for item in deduplicate(items) {
            guard !settings.excludedRepos.contains(item.repo) else { continue }
            let detail = detail(for: item)
            let title = title(for: item)
            guard let held = byId[item.taskId] else {
                result.append(
                    TaskItem(
                        id: item.taskId, title: title, detail: detail, status: .todo,
                        rank: nil, source: .github, createdAt: now, updatedAt: now,
                        sessionIds: []))
                continue
            }
            guard held.status != .archived else { continue }
            guard held.title != title || held.detail != detail else { continue }
            var updated = held
            updated.title = title
            updated.detail = detail
            updated.updatedAt = now
            result.append(updated)
        }
        return result
    }

    /// GitHub tasks that are still open on the board but gone from the search
    /// results, so their fate has to be asked for one by one.
    public static func staleTasks(existing: [TaskItem], openIds: Set<String>) -> [TaskItem] {
        existing.filter { task in
            task.source == .github && !openIds.contains(task.id)
                && task.status != .archived && task.status != .done
        }
    }

    /// Rows to write for the items that left the open set, given what GitHub
    /// answered about each of them.
    public static func closedUpdates(
        stale: [TaskItem], closures: [String: GitHubClosure], settings: GitHubSettings,
        now: Date = Date()
    ) -> [TaskItem] {
        guard settings.closeBehavior != .keep else { return [] }
        var result: [TaskItem] = []
        for task in stale {
            switch closures[task.id] {
            case .merged, .closed: break
            case .open, .unknown, nil: continue
            }
            var updated = task
            switch settings.closeBehavior {
            case .complete:
                updated.status = .done
                updated.completedAt = now
            case .mark:
                guard !task.detail.contains(closedMarker) else { continue }
                updated.detail = task.detail.isEmpty ? closedMarker : "\(task.detail)\n\(closedMarker)"
            case .keep:
                continue
            }
            updated.updatedAt = now
            result.append(updated)
        }
        return result
    }
}
