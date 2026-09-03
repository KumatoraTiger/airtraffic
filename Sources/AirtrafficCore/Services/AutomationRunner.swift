import Foundation

/// Runs one task's command, one at a time, and reports what it left behind.
///
/// An actor because the whole point is serialization: several review requests
/// can land in one GitHub pass, and starting a coding agent per row at once is
/// how a laptop stops answering.
public actor AutomationRunner {
    public enum Outcome: Sendable, Equatable {
        /// The command finished and left something behind in this directory.
        ///
        /// The directory, not a file: how many files a command writes is its
        /// own business, and picking one of them for the user was guesswork
        /// that got the intermediate output as often as the finished page.
        case produced(String)
        /// It failed: a non-zero exit, a timeout, nothing written, or it
        /// could not be started at all. `artifactPath` is the output
        /// directory when the command wrote into it before failing — a
        /// wrapper that reports WHY it gave up does so as a file there, and
        /// that report is the one thing the user wants from a failed run.
        case failed(String, artifactPath: String? = nil)
    }

    /// How long one command may hold the queue.
    ///
    /// This is not a policy on how long an agent may work — it is what stops a
    /// wedged run from blocking every later one, since this actor runs them one
    /// at a time. An hour, because answering a review takes an agent far longer
    /// than writing a page did: reading the comments, changing the code,
    /// pushing and replying.
    private static let timeout: TimeInterval = 3600

    /// Where an executable named without a path is looked up. A bundled app
    /// inherits a minimal PATH, so the usual install sites are named here.
    private static let searchDirectories = [
        "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin",
        ".local/bin", ".claude/local/bin", ".bun/bin", ".npm-global/bin", ".volta/bin",
    ]

    private let base: URL

    public init(base: URL) {
        self.base = base
    }

    public static func defaultBase() -> URL {
        AppDirectories.support().appendingPathComponent("artifacts", isDirectory: true)
    }

    /// Runs the command for one task. Never throws: every failure is an
    /// `Outcome.failed` carrying a line the board can show.
    ///
    /// `trigger` says which of the three command lines runs; `event` carries
    /// the review comment's own values, and is only passed with `.comment`.
    /// All three write into the same per-task directory, so a row keeps one
    /// folder however many times it ran.
    public func run(
        task: TaskItem, settings: AutomationSettings, trigger: AutomationTrigger = .arrival,
        event: CommentEvent? = nil
    ) -> Outcome {
        let directory = TaskAutomation.artifactDirectory(base: base, taskId: task.id)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return .failed("出力先を作成できませんでした")
        }
        guard let values = TaskAutomation.values(for: task, outDir: directory.path, event: event)
        else {
            return .failed("タスクから GitHub の情報を読めませんでした")
        }
        let commandLine =
            switch trigger {
            case .arrival: settings.commandLine
            case .comment: settings.commentCommandLine
            case .label: settings.labelCommandLine
            }
        let arguments = TaskAutomation.arguments(
            commandLine: commandLine, values: values)
        guard let command = arguments.first else { return .failed("コマンドが空です") }
        guard let executable = resolve(command) else {
            return .failed("\(command) が見つかりませんでした")
        }

        let before = files(in: directory)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(arguments.dropFirst())
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let workingDirectory = TaskAutomation.workingDirectory(
            setting: settings.workingDirectory, values: values, home: home)
        var isDirectory: ObjCBool = false
        // A path that names no directory (a repository checked out somewhere
        // else, a typo) would make `Process.run` throw with nothing readable
        // in it, so it is caught here instead.
        guard FileManager.default.fileExists(atPath: workingDirectory, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            return .failed("作業ディレクトリがありません: \(workingDirectory)")
        }
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return .failed("起動できませんでした: \(error.localizedDescription)")
        }
        var timedOut = false
        let watchdog = DispatchWorkItem {
            if process.isRunning {
                timedOut = true
                process.terminate()
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.timeout, execute: watchdog)
        process.waitUntilExit()
        watchdog.cancel()
        // Whether anything was written is checked BEFORE the exit code: a
        // wrapper that fails on purpose still writes its reason to the
        // output directory, and that reason must stay reachable.
        let wrote = !files(in: directory).subtracting(before).isEmpty
        let output = wrote ? directory.path : nil
        if timedOut { return .failed("時間切れで打ち切りました", artifactPath: output) }
        guard process.terminationStatus == 0 else {
            return .failed(
                "終了コード \(process.terminationStatus) で終わりました", artifactPath: output)
        }
        guard wrote else { return .failed("出力先に何も書かれませんでした") }
        return .produced(directory.path)
    }

    /// Removes what a task's command wrote, for a row that is going away.
    public func discard(taskId: String) {
        let directory = TaskAutomation.artifactDirectory(base: base, taskId: taskId)
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Helpers

    /// An absolute path is taken as given; a bare name is looked up in the
    /// usual install directories. Nothing is resolved through a shell, so a
    /// command the user did not name cannot be reached.
    private func resolve(_ command: String) -> String? {
        if command.contains("/") {
            let path = (command as NSString).expandingTildeInPath
            return FileManager.default.isExecutableFile(atPath: path) ? path : nil
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for directory in Self.searchDirectories {
            let root = directory.hasPrefix("/") ? directory : "\(home)/\(directory)"
            let path = "\(root)/\(command)"
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    /// One file as it was at one moment. Comparing these sets before and
    /// after the run is what says "the command wrote something": a new file
    /// shows up as a new path, and a file the command overwrote — a wrapper
    /// writing its `結果.md` for the second review of the same pull request —
    /// shows up as the same path with a new modification date. Comparing
    /// paths alone missed the second case and called a rerun "no output".
    private struct FileStamp: Hashable {
        var path: String
        var modified: Date?
    }

    /// Every file under the directory, subdirectories included. A wrapper
    /// keeps each skill's pages in its own subdirectory, and overwriting a
    /// file there leaves the parent directory's own date untouched, so the
    /// top level alone would miss a rerun that rewrote the same page.
    private func files(in directory: URL) -> Set<FileStamp> {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard
            let found = FileManager.default.enumerator(
                at: directory, includingPropertiesForKeys: keys)
        else { return [] }
        var stamps: Set<FileStamp> = []
        for case let url as URL in found {
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true else { continue }
            stamps.insert(FileStamp(path: url.path, modified: values?.contentModificationDate))
        }
        return stamps
    }

}
