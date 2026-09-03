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

    private func authoredTask(
        repo: String = "alex/demo", number: Int = 7, status: TaskStatus = .todo
    ) -> TaskItem {
        reviewTask(repo: repo, number: number, status: status, relation: .authored)
    }

    /// An issue assigned to the user, the only kind of row the label trigger
    /// ever fires on.
    private func issueTask(
        repo: String = "alex/demo", number: Int = 12, state: AutomationState? = nil,
        status: TaskStatus = .todo
    ) -> TaskItem {
        let item = GitHubItem(
            repo: repo, number: number, title: "検索を速くする",
            url: "https://github.com/\(repo)/issues/\(number)", relation: .assigned,
            isPullRequest: false)
        return TaskItem(
            id: item.taskId, title: GitHubTaskSync.title(for: item),
            detail: GitHubTaskSync.detail(for: item), status: status, rank: nil,
            source: .github, createdAt: Date(), updatedAt: Date(), sessionIds: [],
            automationState: state)
    }

    private func labelSettings(
        enabled: Bool = true, labelTrigger: Bool = true, label: String = "ai",
        labelCommand: String = "/usr/bin/true {url}", repos: Set<String> = ["alex/demo"]
    ) -> AutomationSettings {
        AutomationSettings(
            enabled: enabled, relations: [.reviewRequested], commandLine: "/usr/bin/true {url}",
            allowedRepos: repos, labelTrigger: labelTrigger, label: label,
            labelCommandLine: labelCommand)
    }

    private func comment(
        id: Int, author: String = "coderabbitai[bot]", type: String? = "Bot",
        repo: String = "alex/demo", number: Int = 7, ageInSeconds: TimeInterval = 600,
        now: Date = Date()
    ) -> GitHubComment {
        GitHubComment(
            id: id, author: author,
            isBot: CommentTrigger.isBot(login: author, type: type),
            url: "https://github.com/\(repo)/pull/\(number)#discussion_r\(id)",
            createdAt: now.addingTimeInterval(-ageInSeconds))
    }

    private func settings(
        enabled: Bool = true, command: String = "/usr/bin/true {url}",
        repos: Set<String> = ["alex/demo"],
        relations: Set<GitHubRelation> = [.reviewRequested],
        commentTrigger: Bool = true,
        commentCommand: String = "/usr/bin/true {commentUrl}",
        commentDailyLimit: Int = 3
    ) -> AutomationSettings {
        AutomationSettings(
            enabled: enabled, relations: relations, commandLine: command,
            allowedRepos: repos, commentTrigger: commentTrigger,
            commentCommandLine: commentCommand, commentDailyLimit: commentDailyLimit)
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

        await kit.run("a bot is recognised by its type or its login suffix") {
            expect(CommentTrigger.isBot(login: "coderabbitai[bot]", type: nil), "the [bot] suffix")
            expect(CommentTrigger.isBot(login: "copilot-pull-request-reviewer", type: "Bot"), "typed")
            expect(!CommentTrigger.isBot(login: "alex", type: "User"), "a person is not a bot")
        }

        await kit.run("only the user's own pull requests are asked about") {
            let mine = authoredTask()
            let review = reviewTask(number: 8)
            let elsewhere = authoredTask(repo: "alex/other", number: 9)
            let finished = authoredTask(number: 10, status: .done)
            let candidates = CommentTrigger.candidates(
                tasks: [mine, review, elsewhere, finished], settings: settings())
            expectEqual(candidates.map(\.id), [mine.id])
        }

        await kit.run("the comment trigger stays off without its own command") {
            let mine = authoredTask()
            expect(
                CommentTrigger.candidates(
                    tasks: [mine], settings: settings(commentCommand: "  ")
                ).isEmpty,
                "no command, nothing to fire")
            expect(
                CommentTrigger.candidates(
                    tasks: [mine], settings: settings(commentTrigger: false)
                ).isEmpty,
                "the trigger is off")
        }

        await kit.run("the newest bot comment of a batch names the event") {
            let now = Date()
            let comments = [
                comment(id: 11, ageInSeconds: 900, now: now),
                comment(id: 12, ageInSeconds: 800, now: now),
                comment(id: 13, author: "alex", type: "User", ageInSeconds: 300, now: now),
            ]
            let event = try unwrap(
                CommentTrigger.event(task: authoredTask(), comments: comments, now: now))
            expectEqual(event.commentId, 12)
            expectEqual(event.author, "coderabbitai[bot]")
            expectEqual(event.id, "ghc:alex/demo#7@12")
        }

        await kit.run("a review still being written, or long since read, fires nothing") {
            let now = Date()
            let task = authoredTask()
            expect(
                CommentTrigger.event(
                    task: task, comments: [comment(id: 1, ageInSeconds: 60, now: now)], now: now)
                    == nil,
                "the batch has not settled")
            expect(
                CommentTrigger.event(
                    task: task, comments: [comment(id: 2, ageInSeconds: 48 * 3600, now: now)],
                    now: now) == nil,
                "older than a day")
            expect(
                CommentTrigger.event(
                    task: task,
                    comments: [comment(id: 3, author: "alex", type: "User", now: now)], now: now)
                    == nil,
                "a person reviewed it")
        }

        await kit.run("an event already recorded never runs twice") {
            let now = Date()
            let event = try unwrap(
                CommentTrigger.event(
                    task: authoredTask(), comments: [comment(id: 21, now: now)], now: now))
            expect(
                CommentTrigger.select(
                    events: [event], recorded: [event.id], runsToday: [:], settings: settings()
                )
                .run.isEmpty,
                "the same comment is done with")
            expectEqual(
                CommentTrigger.select(
                    events: [event], recorded: ["ghc:alex/demo#7@20"], runsToday: [:],
                    settings: settings()
                ).run.map(\.id),
                [event.id])
        }

        await kit.run("a pull request that hit its daily limit is held back, not dropped") {
            let now = Date()
            let event = try unwrap(
                CommentTrigger.event(
                    task: authoredTask(), comments: [comment(id: 22, now: now)], now: now))
            let selection = CommentTrigger.select(
                events: [event], recorded: [], runsToday: [event.taskId: 3],
                settings: settings())
            expect(selection.run.isEmpty, "nothing runs")
            expectEqual(selection.blocked.map(\.id), [event.id])

            let raised = CommentTrigger.select(
                events: [event], recorded: [], runsToday: [event.taskId: 3],
                settings: settings(commentDailyLimit: 5))
            expectEqual(raised.run.map(\.id), [event.id])
        }

        await kit.run("the command waits for the checks, whatever they conclude") {
            expectEqual(CommentTrigger.checksState([]), ChecksState.none)
            expectEqual(
                CommentTrigger.checksState([
                    GitHubCheck(status: "COMPLETED", state: nil),
                    GitHubCheck(status: nil, state: "SUCCESS"),
                ]), ChecksState.complete)
            expectEqual(
                CommentTrigger.checksState([
                    GitHubCheck(status: "COMPLETED", state: nil),
                    GitHubCheck(status: "IN_PROGRESS", state: nil),
                ]), ChecksState.pending)
            expectEqual(
                CommentTrigger.checksState([GitHubCheck(status: nil, state: "PENDING")]),
                ChecksState.pending)
            expectEqual(
                CommentTrigger.checksState([GitHubCheck(status: nil, state: nil)]),
                ChecksState.pending)

            expect(
                CommentTrigger.isReady(checks: [GitHubCheck(status: "COMPLETED", state: nil)]),
                "finished checks let it through")
            expect(
                CommentTrigger.isReady(checks: [GitHubCheck(status: nil, state: "FAILURE")]),
                "a red build is what the command is for")
            expect(!CommentTrigger.isReady(checks: nil), "GitHub could not be asked")
        }

        await kit.run("a comment event adds its own two placeholders") {
            let now = Date()
            let task = authoredTask()
            let event = try unwrap(
                CommentTrigger.event(task: task, comments: [comment(id: 31, now: now)], now: now))
            let values = try unwrap(
                TaskAutomation.values(for: task, outDir: "/tmp/out", event: event))
            expectEqual(
                TaskAutomation.arguments(
                    commandLine: "agent {commentUrl} {author} {number}", values: values),
                [
                    "agent", "https://github.com/alex/demo/pull/7#discussion_r31",
                    "coderabbitai[bot]", "7",
                ])
            let plain = try unwrap(TaskAutomation.values(for: task, outDir: "/tmp/out"))
            expect(plain[.commentUrl] == nil, "the arrival command sees no comment")
        }

        await kit.run("a failed run keeps the directory it wrote into, even on a rerun") {
            let base = FileManager.default.temporaryDirectory
                .appendingPathComponent("airtraffic-runner-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: base) }
            let runner = AutomationRunner(base: base)
            let task = reviewTask()
            let directory = TaskAutomation.artifactDirectory(base: base, taskId: task.id).path
            // The wrapper writes its reason to the same file name every time
            // and exits non-zero, which is how a real one reports giving up.
            let settings = AutomationSettings(
                enabled: true, commandLine: "/bin/sh -c 'echo failed > \"$0/結果.md\"; exit 1' {outDir}",
                workingDirectory: "/tmp", allowedRepos: ["alex/demo"])

            for attempt in 1...2 {
                // A second write inside the same second would carry the same
                // modification date and look like nothing happened.
                if attempt == 2 { try await Task.sleep(for: .milliseconds(1100)) }
                let outcome = await runner.run(task: task, settings: settings)
                guard case .failed(let reason, let path) = outcome else {
                    return expect(false, "attempt \(attempt) should fail, got \(outcome)")
                }
                expect(reason.contains("終了コード 1"), "attempt \(attempt): \(reason)")
                expect(path == directory, "attempt \(attempt) keeps the output directory")
            }
        }

        await kit.run("a rerun that overwrites the same file still counts as produced") {
            let base = FileManager.default.temporaryDirectory
                .appendingPathComponent("airtraffic-runner-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: base) }
            let runner = AutomationRunner(base: base)
            let task = reviewTask()
            let directory = TaskAutomation.artifactDirectory(base: base, taskId: task.id).path
            // The page lives in a subdirectory, the way a wrapper keeps each
            // skill's output apart: overwriting it leaves the parent's own
            // date untouched, so the top level alone would see nothing.
            let settings = AutomationSettings(
                enabled: true,
                commandLine:
                    "/bin/sh -c 'mkdir -p \"$0/sub\"; echo ok > \"$0/sub/page.html\"' {outDir}",
                workingDirectory: "/tmp", allowedRepos: ["alex/demo"])

            expectEqual(await runner.run(task: task, settings: settings), .produced(directory))
            try await Task.sleep(for: .milliseconds(1100))
            // The overwritten page is new output.
            expectEqual(await runner.run(task: task, settings: settings), .produced(directory))

            let idle = AutomationSettings(
                enabled: true, commandLine: "/bin/sh -c 'exit 0'", workingDirectory: "/tmp",
                allowedRepos: ["alex/demo"])
            guard case .failed(let reason, let path) = await runner.run(task: task, settings: idle)
            else { return expect(false, "writing nothing is not success") }
            expect(reason.contains("何も書かれませんでした"), reason)
            expect(path == nil, "nothing new to point at")
        }

        await kit.run("an assigned issue carrying the label qualifies once") {
            let task = issueTask()
            let planned = LabelTrigger.plan(
                tasks: [task], labels: [task.id: ["bug", "ai"]], settings: labelSettings())
            expectEqual(planned.map(\.id), [task.id])

            // The state written before the command starts is what stops the
            // next pass from starting it again.
            let ran = issueTask(state: .done)
            expect(
                LabelTrigger.plan(
                    tasks: [ran], labels: [ran.id: ["ai"]], settings: labelSettings()
                ).isEmpty,
                "a row that already ran never runs again")
            let failed = issueTask(state: .failed)
            expect(
                LabelTrigger.plan(
                    tasks: [failed], labels: [failed.id: ["ai"]], settings: labelSettings()
                )
                .isEmpty,
                "a failed row waits for a manual reset")
        }

        await kit.run("the label is matched whatever its case and spacing") {
            expect(LabelTrigger.matches(labels: ["AI"], label: " ai "), "case and spaces")
            expect(LabelTrigger.matches(labels: [" ai "], label: "AI"), "either side")
            expect(!LabelTrigger.matches(labels: ["ai-review"], label: "ai"), "not a prefix")
            expect(!LabelTrigger.matches(labels: ["ai"], label: "  "), "an empty label fires nothing")
        }

        await kit.run("a label nothing was read for, or a row of another kind, fires nothing") {
            let task = issueTask()
            expect(
                LabelTrigger.plan(tasks: [task], labels: [:], settings: labelSettings()).isEmpty,
                "labels the pass could not read must not look like a match")
            expect(
                LabelTrigger.plan(
                    tasks: [task], labels: [task.id: ["ai"]],
                    settings: labelSettings(repos: ["alex/other"])
                ).isEmpty,
                "the repository has to be allowed")
            expect(
                LabelTrigger.plan(
                    tasks: [issueTask(status: .done)], labels: [task.id: ["ai"]],
                    settings: labelSettings()
                ).isEmpty,
                "a finished row is not implemented again")
            // Somebody else's pull request, and the user's own: neither is an
            // issue assigned to them.
            let others = [reviewTask(number: 8), authoredTask(number: 9)]
            expect(
                LabelTrigger.plan(
                    tasks: others,
                    labels: Dictionary(uniqueKeysWithValues: others.map { ($0.id, ["ai"]) }),
                    settings: labelSettings()
                ).isEmpty,
                "a pull request row never fires the label trigger")
        }

        await kit.run("the label trigger stays off without its switch, label or command") {
            let task = issueTask()
            let labels = [task.id: ["ai"]]
            for settings in [
                labelSettings(enabled: false),
                labelSettings(labelTrigger: false),
                labelSettings(label: ""),
                labelSettings(labelCommand: "   "),
            ] {
                expect(
                    LabelTrigger.plan(tasks: [task], labels: labels, settings: settings).isEmpty,
                    "nothing runs until all four are set")
            }
        }

        await kit.run("one pass starts at most three label runs") {
            let tasks = (1...5).map { issueTask(number: $0) }
            let labels = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, ["ai"]) })
            expectEqual(
                LabelTrigger.plan(tasks: tasks, labels: labels, settings: labelSettings()).count,
                LabelTrigger.runLimit)
        }

        await kit.run("a label run runs the label command, not the arrival one") {
            let base = FileManager.default.temporaryDirectory
                .appendingPathComponent("airtraffic-runner-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: base) }
            let runner = AutomationRunner(base: base)
            let task = issueTask()
            let directory = TaskAutomation.artifactDirectory(base: base, taskId: task.id).path
            // The arrival command writes nothing, so only the label command
            // can be what produced the file.
            let settings = AutomationSettings(
                enabled: true, commandLine: "/bin/sh -c 'exit 0'", workingDirectory: "/tmp",
                allowedRepos: ["alex/demo"], labelTrigger: true, label: "ai",
                labelCommandLine: "/bin/sh -c 'echo done > \"$0/実装.md\"' {outDir}")

            expectEqual(
                await runner.run(task: task, settings: settings, trigger: .label),
                .produced(directory))
            expect(
                FileManager.default.fileExists(atPath: directory + "/実装.md"),
                "the label command's output is there")
        }

        await kit.run("an artifact directory is one flat name per task") {
            let base = URL(fileURLWithPath: "/tmp/artifacts")
            let directory = TaskAutomation.artifactDirectory(base: base, taskId: "gh:alex/demo#7")
            expectEqual(directory.lastPathComponent, "gh_alex_demo_7")
            expectEqual(directory.deletingLastPathComponent().path, base.path)
        }
    }
}
