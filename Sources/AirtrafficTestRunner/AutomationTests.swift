import AirtrafficCore
import Foundation

/// Tests for the per-task command's rules. Nothing here spawns a process:
/// what is worth testing is which rows qualify and what ends up in argv.
struct AutomationTests {
    private func reviewTask(
        repo: String = "alex/demo", number: Int = 7,
        state: AutomationState? = nil, status: TaskStatus = .todo,
        relation: GitHubRelation = .reviewRequested
    ) -> TaskItem {
        let item = GitHubItem(
            repo: repo, number: number, title: "ログイン画面を直す",
            url: "https://github.com/\(repo)/pull/\(number)", relation: relation,
            isPullRequest: true)
        return TaskItem(
            id: item.taskId, title: GitHubTaskSync.title(for: item),
            detail: GitHubTaskSync.detail(for: item), status: status, rank: nil,
            source: .github, createdAt: Date(), updatedAt: Date(), sessionIds: [],
            automationState: state)
    }

    private func settings(
        enabled: Bool = true, command: String = "/usr/bin/true {url}",
        repos: Set<String> = ["alex/demo"],
        relations: Set<GitHubRelation> = [.reviewRequested]
    ) -> AutomationSettings {
        AutomationSettings(
            enabled: enabled, relations: relations, commandLine: command,
            allowedRepos: repos)
    }

    func runAll() async {
        let kit = TestKit.shared

        await kit.run("a detail line says which relation built it") {
            let review = GitHubItem(
                repo: "alex/demo", number: 3, title: "直す",
                url: "https://github.com/alex/demo/pull/3", relation: .reviewRequested,
                isPullRequest: true, isDraft: true)
            let detail = GitHubTaskSync.detail(for: review)
            expectEqual(GitHubTaskSync.relation(fromDetail: detail), .reviewRequested)
            expectEqual(GitHubTaskSync.url(fromDetail: detail), "https://github.com/alex/demo/pull/3")
            expect(GitHubTaskSync.relation(fromDetail: "手で書いたメモ") == nil, "not a GitHub line")
        }

        await kit.run("only a fresh review row in an allowed repository qualifies") {
            let allowed = reviewTask()
            let elsewhere = reviewTask(repo: "alex/other", number: 8)
            let alreadyRun = reviewTask(number: 9, state: .failed)
            let finished = reviewTask(number: 10, status: .done)
            let planned = TaskAutomation.plan(
                tasks: [allowed, elsewhere, alreadyRun, finished], settings: settings())
            expectEqual(planned.map(\.id), [allowed.id])
        }

        await kit.run("the kinds of row that fire are the ones the user picked") {
            let review = reviewTask(number: 11)
            let authored = reviewTask(number: 12, relation: .authored)
            let assigned = reviewTask(number: 13, relation: .assigned)
            let tasks = [review, authored, assigned]
            expectEqual(
                TaskAutomation.plan(tasks: tasks, settings: settings(relations: [.authored]))
                    .map(\.id),
                [authored.id])
            expectEqual(
                TaskAutomation.plan(
                    tasks: tasks, settings: settings(relations: [.reviewRequested, .assigned])
                ).map(\.id),
                [review.id, assigned.id])
            expect(
                TaskAutomation.plan(tasks: tasks, settings: settings(relations: [])).isEmpty,
                "no kind picked")
        }

        await kit.run("nothing runs while the feature is off or the command is empty") {
            let task = reviewTask()
            expect(
                TaskAutomation.plan(tasks: [task], settings: settings(enabled: false)).isEmpty,
                "disabled")
            expect(
                TaskAutomation.plan(tasks: [task], settings: settings(command: "   ")).isEmpty,
                "no command")
            expect(
                TaskAutomation.plan(tasks: [task], settings: settings(repos: [])).isEmpty,
                "no repository opted in")
        }

        await kit.run("a command line splits into arguments, quotes included") {
            expectEqual(
                TaskAutomation.tokenize("claude -p \"{url} を読んで\""),
                ["claude", "-p", "{url} を読んで"])
            expectEqual(TaskAutomation.tokenize("  "), [])
            expectEqual(TaskAutomation.tokenize("a 'b c' d"), ["a", "b c", "d"])
        }

        await kit.run("a hostile title stays one argument") {
            let item = GitHubItem(
                repo: "alex/demo", number: 4, title: "\"; touch /tmp/pwned; echo \"",
                url: "https://github.com/alex/demo/pull/4", relation: .reviewRequested,
                isPullRequest: true)
            let task = TaskItem(
                id: item.taskId, title: item.title, detail: GitHubTaskSync.detail(for: item),
                status: .todo, rank: nil, source: .github, createdAt: Date(), updatedAt: Date(),
                sessionIds: [])
            let values = try unwrap(TaskAutomation.values(for: task, outDir: "/tmp/out"))
            let arguments = TaskAutomation.arguments(
                commandLine: "claude -p {title}", values: values)
            expectEqual(arguments.count, 3)
            expectEqual(arguments.last, item.title)
        }

        await kit.run("placeholders are filled from the task itself") {
            let task = reviewTask()
            let values = try unwrap(TaskAutomation.values(for: task, outDir: "/tmp/out"))
            let arguments = TaskAutomation.arguments(
                commandLine: "agent {url} {repo} {number} {taskId} {outDir}", values: values)
            expectEqual(
                arguments,
                [
                    "agent", "https://github.com/alex/demo/pull/7", "alex/demo", "7",
                    "gh:alex/demo#7", "/tmp/out",
                ])
        }

        await kit.run("a detail line pointing somewhere else is refused") {
            var task = reviewTask()
            task.detail = "レビュー依頼 · alex/demo#7\nhttps://evil.example.com/alex/demo/pull/7"
            expect(TaskAutomation.values(for: task, outDir: "/tmp/out") == nil, "not github.com")
        }

        await kit.run("the working directory takes the same placeholders") {
            let task = reviewTask()
            let values = try unwrap(TaskAutomation.values(for: task, outDir: "/tmp/out"))
            expectEqual(
                TaskAutomation.workingDirectory(
                    setting: "~/src/{repoName}", values: values, home: "/Users/alex"),
                "/Users/alex/src/demo")
            expectEqual(
                TaskAutomation.workingDirectory(
                    setting: "  ", values: values, home: "/Users/alex"),
                "/Users/alex")
            expectEqual(
                TaskAutomation.workingDirectory(
                    setting: "/work/{repo}", values: values, home: "/Users/alex"),
                "/work/alex/demo")
        }

        await kit.run("a repository name can never climb out of a path") {
            expect(!TaskAutomation.isRepo("alex/.."), "no parent directory")
            expect(!TaskAutomation.isRepo("../demo"), "no parent directory")
            expect(!TaskAutomation.isRepo("alex/demo/extra"), "two segments only")
            expect(TaskAutomation.isRepo("alex/demo.io"), "a dot inside a name is fine")
        }

        await kit.run("an artifact directory is one flat name per task") {
            let base = URL(fileURLWithPath: "/tmp/artifacts")
            let directory = TaskAutomation.artifactDirectory(base: base, taskId: "gh:alex/demo#7")
            expectEqual(directory.lastPathComponent, "gh_alex_demo_7")
            expectEqual(directory.deletingLastPathComponent().path, base.path)
        }
    }
}
