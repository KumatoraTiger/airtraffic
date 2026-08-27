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
        /// It ran but produced nothing, or could not be started at all.
        case failed(String)
    }

    /// Long enough for an agent to read a pull request and write a page, short
    /// enough that a wedged one frees the queue the same morning.
    private static let timeout: TimeInterval = 900

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
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Airtraffic/artifacts", isDirectory: true)
    }

    /// Runs the command for one task. Never throws: every failure is an
    /// `Outcome.failed` carrying a line the board can show.
    public func run(task: TaskItem, settings: AutomationSettings) -> Outcome {
        let directory = TaskAutomation.artifactDirectory(base: base, taskId: task.id)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return .failed("出力先を作成できませんでした")
        }
        guard let values = TaskAutomation.values(for: task, outDir: directory.path) else {
            return .failed("タスクから GitHub の情報を読めませんでした")
        }
        let arguments = TaskAutomation.arguments(
            commandLine: settings.commandLine, values: values)
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
        if timedOut { return .failed("時間切れで打ち切りました") }
        guard process.terminationStatus == 0 else {
            return .failed("終了コード \(process.terminationStatus) で終わりました")
        }

        guard !files(in: directory).subtracting(before).isEmpty else {
            return .failed("出力先に何も書かれませんでした")
        }
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

    private func files(in directory: URL) -> Set<URL> {
        let found =
            (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil)) ?? []
        return Set(found)
    }

}
