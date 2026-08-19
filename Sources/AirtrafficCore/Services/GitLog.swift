import Foundation

/// Commits one repository received today, as far as `git log` can tell.
public struct RepoCommits: Identifiable, Hashable, Sendable {
    /// Repository root path; the identity `git` itself reports.
    public var path: String
    /// Directory name of the root, for display.
    public var name: String
    /// Commit subjects, newest first, capped.
    public var subjects: [String]
    /// How many commits matched, including the ones not listed in `subjects`.
    public var total: Int

    public var id: String { path }

    public init(path: String, name: String, subjects: [String], total: Int) {
        self.path = path
        self.name = name
        self.subjects = subjects
        self.total = total
    }
}

/// Reads today's commits from the repositories the day's sessions ran in.
///
/// Session titles say what the user meant to do; commits say what actually
/// landed. The daily report needs the second kind of fact to describe results
/// instead of intentions.
///
/// Everything here is best-effort: a directory that is not a repository, a
/// missing `git`, or a repository with no identity configured yields no
/// commits rather than an error. A report is worth writing without this.
public struct GitLog: Sendable {
    /// Commit subjects listed per repository; the rest are counted only.
    private static let subjectLimit = 8
    private let executable: String

    public init(executable: String = "/usr/bin/git") {
        self.executable = executable
    }

    /// Today's commits in the repositories containing `paths`.
    ///
    /// Paths are folded to their repository root first, so several worktrees
    /// of one repo (and several session cwds inside one repo) are read once.
    /// Only commits authored by the repository's configured identity count:
    /// agents commit as the user, and a shared branch carries other people's
    /// work that was never done today.
    public func commitsToday(
        paths: [String], now: Date = Date(), calendar: Calendar = .current
    ) -> [RepoCommits] {
        let midnight = calendar.startOfDay(for: now)
        let since = ISO8601DateFormatter().string(from: midnight)
        var seen: Set<String> = []
        var result: [RepoCommits] = []

        for path in paths {
            guard
                let root = run(["-C", path, "rev-parse", "--show-toplevel"])?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !root.isEmpty,
                seen.insert(root).inserted
            else { continue }

            var arguments = [
                "-C", root, "log", "--no-merges", "--since=\(since)", "--pretty=format:%s",
            ]
            if let email = run(["-C", root, "config", "user.email"])?
                .trimmingCharacters(in: .whitespacesAndNewlines), !email.isEmpty
            {
                arguments.append("--author=\(email)")
            }
            guard let output = run(arguments) else { continue }
            let subjects = output.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard !subjects.isEmpty else { continue }
            result.append(
                RepoCommits(
                    path: root, name: (root as NSString).lastPathComponent,
                    subjects: Array(subjects.prefix(Self.subjectLimit)), total: subjects.count))
        }
        return result.sorted { $0.total > $1.total }
    }

    /// Runs `git` and returns its stdout, or nil when it failed for any reason.
    private func run(_ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
