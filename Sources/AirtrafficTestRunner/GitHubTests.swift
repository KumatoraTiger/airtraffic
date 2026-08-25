import AirtrafficCore
import Foundation

/// Tests for the GitHub inbox's decisions. Everything here is the pure part:
/// the `gh` calls themselves are not exercised, since the suite must run
/// offline and must never touch a real account.
struct GitHubTests {
    private func item(
        repo: String = "alex/demo", number: Int = 1, title: String = "バグを直す",
        relation: GitHubRelation = .assigned, isPullRequest: Bool = false
    ) -> GitHubItem {
        GitHubItem(
            repo: repo, number: number, title: title,
            url: "https://github.com/\(repo)/issues/\(number)", relation: relation,
            isPullRequest: isPullRequest)
    }

    private func task(
        id: String, title: String = "バグを直す", detail: String = "",
        status: TaskStatus = .todo, source: TaskSource = .github
    ) -> TaskItem {
        TaskItem(
            id: id, title: title, detail: detail, status: status, rank: nil, source: source,
            createdAt: Date(), updatedAt: Date(), sessionIds: [])
    }

    func runAll() async {
        let kit = TestKit.shared

        await kit.run("task ids round-trip through a repository and a number") {
            let id = GitHubItem.taskId(repo: "alex/demo", number: 42)
            expectEqual(id, "gh:alex/demo#42")
            let reference = GitHubItem.reference(taskId: id)
            expectEqual(reference?.repo, "alex/demo")
            expectEqual(reference?.number, 42)
            expect(GitHubItem.reference(taskId: "manual-task") == nil, "not a GitHub id")
        }

        await kit.run("an open item becomes one task row") {
            let rows = GitHubTaskSync.upserts(
                open: [item()], existing: [], settings: GitHubSettings(enabled: true))
            expectEqual(rows.count, 1)
            expectEqual(rows[0].id, "gh:alex/demo#1")
            expectEqual(rows[0].source, .github)
            expectEqual(rows[0].status, .todo)
            expect(rows[0].detail.contains("https://"), "detail carries the link")
        }

        await kit.run("a second pass writes nothing when nothing changed") {
            let first = GitHubTaskSync.upserts(
                open: [item()], existing: [], settings: GitHubSettings(enabled: true))
            let second = GitHubTaskSync.upserts(
                open: [item()], existing: first, settings: GitHubSettings(enabled: true))
            expectEqual(second.count, 0)
        }

        await kit.run("a renamed item updates the row it already made") {
            let first = GitHubTaskSync.upserts(
                open: [item()], existing: [], settings: GitHubSettings(enabled: true))
            let second = GitHubTaskSync.upserts(
                open: [item(title: "バグを直す（改題）")], existing: first,
                settings: GitHubSettings(enabled: true))
            expectEqual(second.count, 1)
            expectEqual(second[0].title, "バグを直す（改題）")
        }

        await kit.run("an archived row is never rebuilt") {
            let dismissed = task(id: "gh:alex/demo#1", status: .archived)
            let rows = GitHubTaskSync.upserts(
                open: [item()], existing: [dismissed], settings: GitHubSettings(enabled: true))
            expectEqual(rows.count, 0)
        }

        await kit.run("an excluded repository is skipped") {
            let settings = GitHubSettings(enabled: true, excludedRepos: ["alex/demo"])
            let rows = GitHubTaskSync.upserts(
                open: [item(), item(repo: "alex/other", number: 3)], existing: [],
                settings: settings)
            expectEqual(rows.count, 1)
            expectEqual(rows[0].id, "gh:alex/other#3")
        }

        await kit.run("a review request outranks the user's own pull request") {
            let mine = item(number: 7, relation: .authored, isPullRequest: true)
            let review = item(number: 7, relation: .reviewRequested, isPullRequest: true)
            let deduplicated = GitHubTaskSync.deduplicate([mine, review])
            expectEqual(deduplicated.count, 1)
            expectEqual(deduplicated[0].relation, .reviewRequested)
        }

        await kit.run("only open, unfinished GitHub rows count as stale") {
            let existing = [
                task(id: "gh:alex/demo#1"),
                task(id: "gh:alex/demo#2", status: .done),
                task(id: "gh:alex/demo#3", status: .archived),
                task(id: "manual-1", source: .manual),
            ]
            let stale = GitHubTaskSync.staleTasks(existing: existing, openIds: [])
            expectEqual(stale.map(\.id), ["gh:alex/demo#1"])
        }

        await kit.run("a merged item completes its task under 完了にする") {
            let stale = [task(id: "gh:alex/demo#1")]
            let rows = GitHubTaskSync.closedUpdates(
                stale: stale, closures: ["gh:alex/demo#1": .merged],
                settings: GitHubSettings(enabled: true, closeBehavior: .complete))
            expectEqual(rows.count, 1)
            expectEqual(rows[0].status, .done)
            expect(rows[0].completedAt != nil, "completion is dated")
        }

        await kit.run("印を付けて残す leaves the status alone and notes it once") {
            let settings = GitHubSettings(enabled: true, closeBehavior: .mark)
            let stale = [task(id: "gh:alex/demo#1", detail: "レビュー依頼 · alex/demo#1")]
            let first = GitHubTaskSync.closedUpdates(
                stale: stale, closures: ["gh:alex/demo#1": .closed], settings: settings)
            expectEqual(first.count, 1)
            expectEqual(first[0].status, .todo)
            expect(first[0].detail.contains(GitHubTaskSync.closedMarker), "detail is marked")
            let second = GitHubTaskSync.closedUpdates(
                stale: first, closures: ["gh:alex/demo#1": .closed], settings: settings)
            expectEqual(second.count, 0)
        }

        await kit.run("何もしない writes nothing at all") {
            let rows = GitHubTaskSync.closedUpdates(
                stale: [task(id: "gh:alex/demo#1")], closures: ["gh:alex/demo#1": .merged],
                settings: GitHubSettings(enabled: true, closeBehavior: .keep))
            expectEqual(rows.count, 0)
        }

        await kit.run("an item still open upstream is left alone") {
            let rows = GitHubTaskSync.closedUpdates(
                stale: [task(id: "gh:alex/demo#1")],
                closures: ["gh:alex/demo#1": .open],
                settings: GitHubSettings(enabled: true, closeBehavior: .complete))
            expectEqual(rows.count, 0)
        }

        await kit.run("an unanswered lookup never completes a task") {
            let rows = GitHubTaskSync.closedUpdates(
                stale: [task(id: "gh:alex/demo#1")], closures: [:],
                settings: GitHubSettings(enabled: true, closeBehavior: .complete))
            expectEqual(rows.count, 0)
        }
    }
}
