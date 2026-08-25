import Foundation

// MARK: - Model

/// Why a GitHub item concerns the user. One item can match several searches;
/// `precedence` decides which reason the task row shows.
public enum GitHubRelation: String, Codable, Sendable, CaseIterable {
    /// An issue assigned to the user.
    case assigned
    /// A pull request the user opened.
    case authored
    /// A pull request waiting for the user's review.
    case reviewRequested = "review_requested"

    public var displayName: String {
        switch self {
        case .assigned: "担当 issue"
        case .authored: "自分の PR"
        case .reviewRequested: "レビュー依頼"
        }
    }

    /// Lower wins when one item arrives through several searches. A review
    /// request blocks somebody else, so it outranks the user's own work.
    var precedence: Int {
        switch self {
        case .reviewRequested: 0
        case .assigned: 1
        case .authored: 2
        }
    }
}

/// One open issue or pull request the user is on the hook for.
public struct GitHubItem: Hashable, Sendable {
    /// `owner/name`, the identity GitHub itself uses.
    public var repo: String
    public var number: Int
    public var title: String
    public var url: String
    public var relation: GitHubRelation
    public var isPullRequest: Bool
    public var isDraft: Bool
    public var updatedAt: Date

    public init(
        repo: String, number: Int, title: String, url: String, relation: GitHubRelation,
        isPullRequest: Bool, isDraft: Bool = false, updatedAt: Date = Date()
    ) {
        self.repo = repo
        self.number = number
        self.title = title
        self.url = url
        self.relation = relation
        self.isPullRequest = isPullRequest
        self.isDraft = isDraft
        self.updatedAt = updatedAt
    }

    /// The task id this item always maps to, so a re-scan updates the row it
    /// created last time instead of adding a second one.
    public var taskId: String { Self.taskId(repo: repo, number: number) }

    public static func taskId(repo: String, number: Int) -> String { "gh:\(repo)#\(number)" }

    /// The repository and number encoded in a task id, for looking the item up
    /// again once it left the open results.
    public static func reference(taskId: String) -> (repo: String, number: Int)? {
        guard taskId.hasPrefix("gh:") else { return nil }
        let body = taskId.dropFirst(3)
        guard let hash = body.lastIndex(of: "#") else { return nil }
        let repo = String(body[body.startIndex..<hash])
        guard let number = Int(body[body.index(after: hash)...]), !repo.isEmpty else { return nil }
        return (repo, number)
    }
}

/// What became of an item that is no longer in the open results.
public enum GitHubClosure: Sendable {
    case merged
    case closed
    /// Still open upstream; it only left the search (unassigned, review
    /// dismissed). Nothing was finished, so the task is left alone.
    case open
    /// GitHub could not be asked. Also leaves the task alone.
    case unknown
}

// MARK: - Source

/// Reads the user's GitHub work through the `gh` CLI.
///
/// The CLI is the whole authentication story: `gh auth login` already holds a
/// token in the keychain, so the app stores no credential of its own and asks
/// for no OAuth flow. Without `gh`, or without a login, every call returns nil
/// and the feature stays silently off.
public struct GitHubSource: Sendable {
    private static let searchPaths = [
        "/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh",
    ]
    /// Long enough for a slow network, short enough that a wedged CLI does not
    /// hold the sync forever.
    private static let timeout: TimeInterval = 20

    private let executable: String?

    public init(executable: String? = nil) {
        self.executable =
            executable ?? Self.searchPaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public var isAvailable: Bool { executable != nil }

    /// Every open item across the three searches, or nil when any of them
    /// failed.
    ///
    /// All-or-nothing on purpose: a partial answer looks exactly like "these
    /// items are gone", and the caller closes tasks from what is missing.
    public func fetchOpen(limit: Int = 50) -> [GitHubItem]? {
        guard isAvailable else { return nil }
        let queries: [(GitHubRelation, [String])] = [
            (
                .assigned,
                ["search", "issues", "--assignee=@me", "--state=open", "--limit", "\(limit)"]
            ),
            (
                .authored,
                ["search", "prs", "--author=@me", "--state=open", "--limit", "\(limit)"]
            ),
            (
                .reviewRequested,
                ["search", "prs", "--review-requested=@me", "--state=open", "--limit", "\(limit)"]
            ),
        ]
        var items: [GitHubItem] = []
        for (relation, arguments) in queries {
            // `gh search issues` has no isDraft field; asking for it fails the
            // whole query.
            let fields =
                relation == .assigned
                ? "repository,number,title,url,updatedAt,isPullRequest"
                : "repository,number,title,url,updatedAt,isPullRequest,isDraft"
            guard let output = run(arguments + ["--json", fields]) else { return nil }
            guard let rows = decodeSearch(output) else { return nil }
            items.append(contentsOf: rows.map { $0.item(relation: relation) })
        }
        return items
    }

    /// What happened to one item, asked directly since it is no longer in the
    /// search results. Issues and pull requests share this endpoint.
    public func closure(repo: String, number: Int) -> GitHubClosure {
        guard isAvailable,
            let output = run(["api", "repos/\(repo)/issues/\(number)"]),
            let data = output.data(using: .utf8),
            let row = try? JSONDecoder().decode(IssueRow.self, from: data)
        else { return .unknown }
        guard row.state == "closed" else { return .open }
        return row.pullRequest?.mergedAt == nil ? .closed : .merged
    }

    // MARK: - Decoding

    private struct SearchRow: Decodable {
        struct Repository: Decodable { let nameWithOwner: String }
        let repository: Repository
        let number: Int
        let title: String
        let url: String
        let updatedAt: String?
        let isPullRequest: Bool?
        let isDraft: Bool?

        func item(relation: GitHubRelation) -> GitHubItem {
            GitHubItem(
                repo: repository.nameWithOwner,
                number: number,
                title: title,
                url: url,
                relation: relation,
                isPullRequest: isPullRequest ?? (relation != .assigned),
                isDraft: isDraft ?? false,
                updatedAt: updatedAt.flatMap(GitHubSource.parseDate) ?? Date())
        }
    }

    private struct IssueRow: Decodable {
        struct PullRequest: Decodable {
            let mergedAt: String?
            enum CodingKeys: String, CodingKey { case mergedAt = "merged_at" }
        }
        let state: String
        let pullRequest: PullRequest?
        enum CodingKeys: String, CodingKey {
            case state
            case pullRequest = "pull_request"
        }
    }

    private func decodeSearch(_ output: String) -> [SearchRow]? {
        guard let data = output.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([SearchRow].self, from: data)
    }

    private static func parseDate(_ text: String) -> Date? {
        ISO8601DateFormatter().date(from: text)
    }

    // MARK: - Process

    /// Runs `gh` and returns its stdout, or nil when it failed for any reason.
    private func run(_ arguments: [String]) -> String? {
        guard let executable else { return nil }
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
        let watchdog = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.timeout, execute: watchdog)
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
