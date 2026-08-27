import Foundation

/// What the automation did with a task, so a command runs at most once per row.
public enum AutomationState: String, Codable, Sendable {
    /// The command is running right now.
    case running
    /// It finished and left something behind.
    case done
    /// It failed, timed out, or produced nothing. Not retried: a command that
    /// fails once usually fails the same way on the next pass.
    case failed
}

/// How the per-task command is configured.
///
/// Repositories are opted IN here, unlike the inbox's opt-out list. The inbox
/// only shows rows; this runs a command against a pull request written by
/// somebody else, so the set of repositories it trusts is named explicitly.
public struct AutomationSettings: Sendable, Equatable {
    public var enabled: Bool
    /// Which kinds of GitHub row fire the command.
    public var relations: Set<GitHubRelation>
    /// Executable and arguments, split like a shell would but never run
    /// through one. See `TaskAutomation.tokenize`.
    public var commandLine: String
    /// Working directory for the command. Empty means the user's home.
    public var workingDirectory: String
    /// Repositories allowed to fire the command, as `owner/name`.
    public var allowedRepos: Set<String>

    public init(
        enabled: Bool = false,
        relations: Set<GitHubRelation> = [.reviewRequested],
        commandLine: String = "",
        workingDirectory: String = "",
        allowedRepos: Set<String> = []
    ) {
        self.enabled = enabled
        self.relations = relations
        self.commandLine = commandLine
        self.workingDirectory = workingDirectory
        self.allowedRepos = allowedRepos
    }
}

/// Everything the automation decides without touching the disk, the network,
/// or a process. Kept pure so this repository's harness can test the rules.
public enum TaskAutomation {
    /// Placeholders replaced inside a single argument, never across arguments.
    public enum Placeholder: String, CaseIterable, Sendable {
        case url = "{url}"
        case repo = "{repo}"
        /// Just the `name` half of `owner/name`, which is what a checkout on
        /// disk is usually called.
        case repoName = "{repoName}"
        case number = "{number}"
        case title = "{title}"
        case taskId = "{taskId}"
        case outDir = "{outDir}"
    }

    // MARK: - Planning

    /// The tasks whose command should run now.
    ///
    /// A row qualifies once: `automationState` is what stops the next pass
    /// from running the same command again, failures included.
    public static func plan(tasks: [TaskItem], settings: AutomationSettings) -> [TaskItem] {
        guard settings.enabled, !tokenize(settings.commandLine).isEmpty else { return [] }
        return tasks.filter { task in
            guard task.source == .github, task.automationState == nil else { return false }
            guard task.status != .archived, task.status != .done else { return false }
            guard let relation = GitHubTaskSync.relation(fromDetail: task.detail),
                settings.relations.contains(relation)
            else { return false }
            guard let reference = GitHubItem.reference(taskId: task.id) else { return false }
            return settings.allowedRepos.contains(reference.repo)
        }
    }

    // MARK: - Command building

    /// Splits a command line into arguments the way a shell would quote them,
    /// WITHOUT handing anything to a shell.
    ///
    /// The command is later spawned with these as `Process.arguments`, so a
    /// destructive command smuggled into a pull request title stays one
    /// ordinary string instead of becoming a second command. That is the whole
    /// reason this exists instead of `/bin/sh -c`: it costs pipes and `&&`,
    /// and buys immunity to the injection upstream titles would carry.
    public static func tokenize(_ commandLine: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var hasCurrent = false
        var quote: Character?
        var escaped = false
        for character in commandLine {
            if escaped {
                current.append(character)
                escaped = false
                continue
            }
            if character == "\\", quote != "'" {
                escaped = true
                hasCurrent = true
                continue
            }
            if let open = quote {
                if character == open {
                    quote = nil
                } else {
                    current.append(character)
                }
                continue
            }
            if character == "'" || character == "\"" {
                quote = character
                hasCurrent = true
                continue
            }
            if character.isWhitespace {
                if hasCurrent {
                    tokens.append(current)
                    current = ""
                    hasCurrent = false
                }
                continue
            }
            current.append(character)
            hasCurrent = true
        }
        if hasCurrent { tokens.append(current) }
        return tokens
    }

    /// The values substituted into the command for one task, or nil when the
    /// task carries something that does not look like what it claims to be.
    ///
    /// Everything but the title is checked against its shape. The title is
    /// free text written by whoever opened the pull request, so it is passed
    /// through as one argument and nothing more is assumed about it.
    public static func values(for task: TaskItem, outDir: String) -> [Placeholder: String]? {
        guard let reference = GitHubItem.reference(taskId: task.id) else { return nil }
        guard isRepo(reference.repo) else { return nil }
        guard let url = GitHubTaskSync.url(fromDetail: task.detail), isGitHubURL(url) else {
            return nil
        }
        let name = reference.repo.split(separator: "/").last.map(String.init) ?? reference.repo
        return [
            .url: url,
            .repo: reference.repo,
            .repoName: name,
            .number: "\(reference.number)",
            .title: task.title,
            .taskId: task.id,
            .outDir: outDir,
        ]
    }

    /// The command's arguments with the placeholders filled in. Substitution
    /// happens inside one argument, so a value can never introduce a new one.
    public static func arguments(commandLine: String, values: [Placeholder: String]) -> [String] {
        tokenize(commandLine).map { token in
            var filled = token
            for placeholder in Placeholder.allCases {
                guard let value = values[placeholder] else { continue }
                filled = filled.replacingOccurrences(of: placeholder.rawValue, with: value)
            }
            return filled
        }
    }

    /// `owner/name`, the only shape GitHub itself accepts.
    ///
    /// `.` and `..` are refused even though the character set allows their
    /// characters: the repository name is pasted into a directory path, and a
    /// component that climbs out of it must not survive that far.
    public static func isRepo(_ text: String) -> Bool {
        let parts = text.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        guard !parts.contains("."), !parts.contains("..") else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz")
            .union(CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"))
        return parts.allSatisfy { part in
            !part.isEmpty && CharacterSet(charactersIn: String(part)).isSubset(of: allowed)
        }
    }

    /// An `https://github.com/...` link and nothing else, so the command is
    /// never pointed at a host the detail line was talked into naming.
    public static func isGitHubURL(_ text: String) -> Bool {
        guard let url = URL(string: text), url.scheme == "https" else { return false }
        return url.host == "github.com"
    }

    /// The directory the command runs in: the user's setting with the same
    /// placeholders filled in, so `~/src/{repoName}` points at the checkout
    /// this particular pull request lives in. Empty falls back to the home
    /// directory.
    public static func workingDirectory(
        setting: String, values: [Placeholder: String], home: String
    ) -> String {
        var filled = setting.trimmingCharacters(in: .whitespaces)
        guard !filled.isEmpty else { return home }
        for placeholder in Placeholder.allCases {
            guard let value = values[placeholder] else { continue }
            filled = filled.replacingOccurrences(of: placeholder.rawValue, with: value)
        }
        if filled == "~" { return home }
        if filled.hasPrefix("~/") { filled = home + filled.dropFirst(1) }
        return filled
    }

    /// Where one task's generated files live. Named after the task so removing
    /// the row can remove the directory with it.
    public static func artifactDirectory(base: URL, taskId: String) -> URL {
        let safe = taskId.map { character -> Character in
            character.isLetter || character.isNumber || character == "-" || character == "."
                ? character : "_"
        }
        return base.appendingPathComponent(String(safe), isDirectory: true)
    }
}
