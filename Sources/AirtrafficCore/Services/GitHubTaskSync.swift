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

    /// The detail line of a GitHub task: what the item is, then its link.
    public static func detail(for item: GitHubItem) -> String {
        let kind = item.isDraft ? "\(item.relation.displayName)（下書き）" : item.relation.displayName
        return "\(kind) · \(item.repo)#\(item.number)\n\(item.url)"
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
            guard let held = byId[item.taskId] else {
                result.append(
                    TaskItem(
                        id: item.taskId, title: item.title, detail: detail, status: .todo,
                        rank: nil, source: .github, createdAt: now, updatedAt: now,
                        sessionIds: []))
                continue
            }
            guard held.status != .archived else { continue }
            guard held.title != item.title || held.detail != detail else { continue }
            var updated = held
            updated.title = item.title
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
