import AirtrafficCore
import AppKit
import Foundation
import SwiftUI

/// A single chat entry in the prioritization panel.
struct ChatEntry: Identifiable, Hashable {
    enum Sender { case user, assistant }
    let id = UUID()
    var sender: Sender
    var text: String
    var proposal: [String]?  // ranking proposal (task ids), if the reply had one
}

@Observable
@MainActor
final class AppModel {
    // MARK: - State

    var sessions: [SessionSnapshot] = [] {
        didSet { rebuildBoard() }
    }
    var tasks: [TaskItem] = [] {
        didSet { rebuildBoard() }
    }
    /// LLM-generated work labels ("レビュー: …") by session id.
    var labels: [String: WorkLabel] = [:] {
        didSet { rebuildBoard() }
    }
    var preferences: [PreferenceNote] = []
    var chatEntries: [ChatEntry] = []
    var chatBusy = false
    /// The last generated daily report. Not persisted: the report is a
    /// snapshot of "now", regenerated on demand.
    var report: DailyReport?
    /// The model's raw reply when it could not be read as a report. Shown as
    /// plain text so a malformed answer never looks like an empty day.
    var reportFallback: String?
    var reportBusy = false

    var hasReport: Bool { report != nil || reportFallback != nil }

    /// Figures for the report, computed from the same facts the LLM was given.
    /// Kept from the generating pass: recomputing later would redraw the day
    /// under a report that describes an earlier moment.
    private(set) var reportMetrics: DayMetrics?

    /// The report as a standalone page, for the web view and for saving.
    var reportHTML: String? {
        report.map { DailyReportRenderer.html($0, metrics: reportMetrics) }
    }

    /// The report as Markdown, for pasting into a document or a chat.
    var reportMarkdown: String? {
        if let report { return DailyReportRenderer.markdown(report) }
        return reportFallback
    }
    /// The running pomodoro, if any. Persisted so an in-flight timer survives
    /// an app restart; a timer that expired while the app was closed is
    /// dropped silently on launch.
    var pomodoro: PomodoroTimer? {
        didSet {
            if let pomodoro, let data = try? JSONEncoder().encode(pomodoro) {
                UserDefaults.standard.set(data, forKey: "pomodoro")
            } else {
                UserDefaults.standard.removeObject(forKey: "pomodoro")
            }
            updatePomodoroTicker()
        }
    }
    /// The menu bar's clock. Advanced once a second by the ticker while a
    /// pomodoro runs, so the label re-renders exactly once a second — a
    /// self-updating timer Text there redraws the status item every frame
    /// and pins the main thread.
    var pomodoroNow = Date()
    var lastError: String?
    /// Task edits that can be taken back, oldest first. Only the task list is
    /// covered: it is the only thing the user edits by hand, and a mistake
    /// there (a task completed too early, a session linked to the wrong task,
    /// a task hung under the wrong parent) is otherwise unrecoverable.
    private(set) var undoStack: [UndoStep] = []
    /// Undone edits, for putting back. An undo is itself an action the user
    /// can regret.
    private(set) var redoStack: [UndoStep] = []
    /// How far back the history goes. Deep enough to cover a wrong move a few
    /// actions ago, short enough to stay understandable.
    private static let historyDepth = 20

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    /// What 「元に戻す」 would take back right now, for the menu and the button.
    var undoLabel: String? { undoStack.last?.label }
    var redoLabel: String? { redoStack.last?.label }
    var labelingEnabled: Bool {
        didSet { UserDefaults.standard.set(labelingEnabled, forKey: "labelingEnabled") }
    }
    var selectedProvider: ProviderKind {
        didSet { UserDefaults.standard.set(selectedProvider.rawValue, forKey: "provider") }
    }
    var models: [ProviderKind: String] {
        didSet {
            for (kind, model) in models {
                UserDefaults.standard.set(model, forKey: "model.\(kind.rawValue)")
            }
        }
    }
    /// GitHub inbox: assigned issues, the user's own pull requests and the
    /// reviews they were asked for, imported as tasks.
    var githubEnabled: Bool {
        didSet { UserDefaults.standard.set(githubEnabled, forKey: Self.githubEnabledKey) }
    }
    /// Repositories the user opted OUT of. Everything else is imported, so a
    /// repository they start working in appears without any setup.
    var githubExcludedRepos: Set<String> {
        didSet {
            UserDefaults.standard.set(
                Array(githubExcludedRepos).sorted(), forKey: Self.githubExcludedKey)
        }
    }
    var githubCloseBehavior: GitHubCloseBehavior {
        didSet {
            UserDefaults.standard.set(githubCloseBehavior.rawValue, forKey: Self.githubCloseKey)
        }
    }
    /// Every repository seen so far, so settings can list one to opt out of
    /// even when it has nothing open right now.
    private(set) var githubRepos: [String] {
        didSet { UserDefaults.standard.set(githubRepos, forKey: Self.githubReposKey) }
    }
    /// What the last pass did, for the settings screen. Nil before the first
    /// pass of the session.
    private(set) var githubStatus: String?

    /// Per-task command: runs once for a newly imported GitHub row, in the
    /// repositories the user named. Off until they write a command.
    var automationEnabled: Bool {
        didSet { UserDefaults.standard.set(automationEnabled, forKey: Self.automationEnabledKey) }
    }
    /// Which kinds of GitHub row fire the command. Review requests by
    /// default: that is the row whose subject the user has not read yet.
    var automationRelations: Set<GitHubRelation> {
        didSet {
            UserDefaults.standard.set(
                automationRelations.map(\.rawValue).sorted(), forKey: Self.automationRelationsKey)
        }
    }
    var automationCommand: String {
        didSet { UserDefaults.standard.set(automationCommand, forKey: Self.automationCommandKey) }
    }
    var automationWorkingDirectory: String {
        didSet {
            UserDefaults.standard.set(automationWorkingDirectory, forKey: Self.automationCwdKey)
        }
    }
    /// Repositories the user opted IN to. Empty means the command never runs:
    /// it acts on a pull request somebody else wrote, so it waits to be told
    /// where that is acceptable.
    var automationRepos: Set<String> {
        didSet {
            UserDefaults.standard.set(Array(automationRepos).sorted(), forKey: Self.automationReposKey)
        }
    }
    /// Review-comment trigger: runs a command when a bot reviews one of the
    /// user's own pull requests.
    var automationCommentTrigger: Bool {
        didSet {
            UserDefaults.standard.set(automationCommentTrigger, forKey: Self.automationCommentKey)
        }
    }
    var automationCommentCommand: String {
        didSet {
            UserDefaults.standard.set(
                automationCommentCommand, forKey: Self.automationCommentCommandKey)
        }
    }
    /// How many times one pull request may fire the command in 24 hours.
    var automationCommentDailyLimit: Int {
        didSet {
            UserDefaults.standard.set(
                automationCommentDailyLimit, forKey: Self.automationCommentLimitKey)
        }
    }
    /// Label trigger: runs a command when an issue assigned to the user
    /// carries the label named below.
    var automationLabelTrigger: Bool {
        didSet {
            UserDefaults.standard.set(automationLabelTrigger, forKey: Self.automationLabelKey)
        }
    }
    var automationLabel: String {
        didSet { UserDefaults.standard.set(automationLabel, forKey: Self.automationLabelNameKey) }
    }
    var automationLabelCommand: String {
        didSet {
            UserDefaults.standard.set(
                automationLabelCommand, forKey: Self.automationLabelCommandKey)
        }
    }
    /// What the last command did, for the settings screen.
    private(set) var automationStatus: String?
    /// Every run of the per-task command the store remembers, newest first.
    /// The board's 自動実行 section reads it; refreshed whenever a run starts
    /// or ends and once at launch.
    private(set) var automationRuns: [AutomationRun] = []

    var automationSettings: AutomationSettings {
        AutomationSettings(
            enabled: automationEnabled, relations: automationRelations,
            commandLine: automationCommand, workingDirectory: automationWorkingDirectory,
            allowedRepos: automationRepos, commentTrigger: automationCommentTrigger,
            commentCommandLine: automationCommentCommand,
            commentDailyLimit: automationCommentDailyLimit,
            labelTrigger: automationLabelTrigger, label: automationLabel,
            labelCommandLine: automationLabelCommand)
    }

    /// Chime preferences for the pomodoro, persisted across launches.
    var soundSettings: PomodoroSoundSettings {
        didSet {
            if let data = try? JSONEncoder().encode(soundSettings) {
                UserDefaults.standard.set(data, forKey: "pomodoroSound")
            }
        }
    }

    /// Open tasks with an execution waiting on the user. Status never moves a
    /// row; this only feeds the lane badges and the menu bar. Sessions that
    /// match no task are not on the board, so they are not counted either.
    var waitingEntries: [BoardEntry] {
        boardEntries.flatMap(\.selfAndChildren).filter { entry in
            guard entry.liveStatus?.needsAttention == true else { return false }
            guard let task = entry.task else { return false }
            return task.status != .done
        }
    }
    /// Kept as state rather than recomputed: the badge and the menu bar read
    /// it on every redraw, and it walks every row.
    private(set) var waitingCount: Int = 0

    /// Unified board rows: tasks with their executions attached, plus session
    /// activity that matches no task, materialized as its own rows. Done tasks
    /// are included (with their linked sessions); the view puts them in 完了.
    ///
    /// Assembled once per change to `tasks` / `sessions` / `labels`, never in a
    /// view body: matching is quadratic in tasks × sessions, and the board
    /// reads these rows a dozen times per redraw.
    private(set) var boardEntries: [BoardEntry] = []

    /// Rebuilds the board rows. Called from the `didSet` of everything they
    /// are built from, so no caller has to remember to.
    private func rebuildBoard() {
        boardEntries = BoardAssembler.assemble(tasks: tasks, sessions: sessions, labels: labels)
        let count = waitingEntries.count
        if count != waitingCount { waitingCount = count }
    }

    // MARK: - Internals

    private let store: Store?
    private let coordinator: IngestionCoordinator
    private let labeler = SessionLabeler()
    private let prioritizer = Prioritizer()
    private let reporter = DailyReporter()
    private let gitLog = GitLog()
    private let githubInbox = GitHubInbox()
    private let automationRunner = AutomationRunner(base: AutomationRunner.defaultBase())
    private var scanTask: Task<Void, Never>?
    private var pomodoroTickTask: Task<Void, Never>?
    private var lastLabelPass = Date.distantPast
    private var lastGitHubPass = Date.distantPast
    private var githubPassRunning = false
    private var automationRunning = false
    /// The labels of the open issues the last GitHub pass read, by task id.
    /// Kept in memory only: it is what that one pass saw, and the next pass
    /// replaces it. Nothing runs from a stale answer, so nothing is stored.
    private var githubIssueLabels: [String: [String]] = [:]

    static let githubEnabledKey = "github.enabled"
    static let githubExcludedKey = "github.excludedRepos"
    static let githubCloseKey = "github.closeBehavior"
    static let githubReposKey = "github.repos"
    static let automationEnabledKey = "automation.enabled"
    static let automationRelationsKey = "automation.relations"
    static let automationCommandKey = "automation.command"
    static let automationCwdKey = "automation.workingDirectory"
    static let automationReposKey = "automation.repos"
    static let automationCommentKey = "automation.commentTrigger"
    static let automationCommentCommandKey = "automation.commentCommand"
    static let automationCommentLimitKey = "automation.commentDailyLimit"
    static let automationLabelKey = "automation.labelTrigger"
    static let automationLabelNameKey = "automation.label"
    static let automationLabelCommandKey = "automation.labelCommand"
    /// GitHub is polled far less often than the transcripts: it is a network
    /// call, and an issue list does not change every three seconds.
    private static let githubInterval: TimeInterval = 300

    init() {
        // The key was "extractionEnabled" while the toggle also covered the
        // removed LLM-proposal feature; carry the old value over once.
        labelingEnabled =
            UserDefaults.standard.object(forKey: "labelingEnabled") as? Bool
            ?? UserDefaults.standard.object(forKey: "extractionEnabled") as? Bool ?? false
        selectedProvider =
            ProviderKind(
                rawValue: UserDefaults.standard.string(forKey: "provider") ?? "") ?? .gemini
        var models: [ProviderKind: String] = [:]
        for kind in ProviderKind.allCases {
            models[kind] =
                UserDefaults.standard.string(forKey: "model.\(kind.rawValue)")
                ?? kind.defaultModel
        }
        self.models = models
        githubEnabled = UserDefaults.standard.object(forKey: Self.githubEnabledKey) as? Bool ?? false
        githubExcludedRepos = Set(
            UserDefaults.standard.stringArray(forKey: Self.githubExcludedKey) ?? [])
        githubCloseBehavior =
            GitHubCloseBehavior(
                rawValue: UserDefaults.standard.string(forKey: Self.githubCloseKey) ?? "")
            ?? .complete
        githubRepos = UserDefaults.standard.stringArray(forKey: Self.githubReposKey) ?? []
        automationEnabled =
            UserDefaults.standard.object(forKey: Self.automationEnabledKey) as? Bool ?? false
        automationRelations = Set(
            (UserDefaults.standard.stringArray(forKey: Self.automationRelationsKey)
                ?? [GitHubRelation.reviewRequested.rawValue])
                .compactMap(GitHubRelation.init(rawValue:)))
        automationCommand = UserDefaults.standard.string(forKey: Self.automationCommandKey) ?? ""
        automationWorkingDirectory =
            UserDefaults.standard.string(forKey: Self.automationCwdKey) ?? ""
        automationRepos = Set(
            UserDefaults.standard.stringArray(forKey: Self.automationReposKey) ?? [])
        automationCommentTrigger =
            UserDefaults.standard.object(forKey: Self.automationCommentKey) as? Bool ?? false
        automationCommentCommand =
            UserDefaults.standard.string(forKey: Self.automationCommentCommandKey) ?? ""
        automationCommentDailyLimit =
            UserDefaults.standard.object(forKey: Self.automationCommentLimitKey) as? Int ?? 3
        automationLabelTrigger =
            UserDefaults.standard.object(forKey: Self.automationLabelKey) as? Bool ?? false
        automationLabel = UserDefaults.standard.string(forKey: Self.automationLabelNameKey) ?? ""
        automationLabelCommand =
            UserDefaults.standard.string(forKey: Self.automationLabelCommandKey) ?? ""
        soundSettings =
            UserDefaults.standard.data(forKey: "pomodoroSound")
            .flatMap { try? JSONDecoder().decode(PomodoroSoundSettings.self, from: $0) }
            ?? .default
        if let data = UserDefaults.standard.data(forKey: "pomodoro"),
            let saved = try? JSONDecoder().decode(PomodoroTimer.self, from: data),
            !saved.isExpired(now: Date())
        {
            pomodoro = saved
        }
        store = try? Store(path: Store.defaultPath())
        coordinator = .standard()
    }

    func start() {
        // Restoring a persisted timer in init assigns the property without
        // its didSet, so the ticker needs this explicit kick.
        updatePomodoroTicker()
        guard scanTask == nil else { return }
        scanTask = Task { [weak self] in
            await self?.refreshFromStore()
            while !Task.isCancelled {
                await self?.scanOnce()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    // MARK: - Scan loop

    private func scanOnce() async {
        // Assigning an identical array still tells SwiftUI the board changed,
        // and the loop runs every three seconds, so compare before writing.
        let scanned = await coordinator.scan()
        if scanned != sessions { sessions = scanned }
        if labelingEnabled, Date().timeIntervalSince(lastLabelPass) > 60 {
            lastLabelPass = Date()
            await runLabelPass()
        }
        if githubEnabled, Date().timeIntervalSince(lastGitHubPass) > Self.githubInterval {
            await runGitHubPass()
        }
    }

    // MARK: - GitHub

    /// Reads GitHub once and writes what changed.
    ///
    /// Deliberately outside the undo history: these rows mirror GitHub, and
    /// taking back an import would only mean the next pass writes it again.
    /// The way to dismiss one is to archive it, which the sync respects.
    func runGitHubPass() async {
        guard let store, !githubPassRunning else { return }
        githubPassRunning = true
        defer { githubPassRunning = false }
        lastGitHubPass = Date()

        // Archived rows are what tells the sync "the user dismissed this one",
        // so the pass has to see them.
        let existing = (try? await store.tasks(includeArchived: true)) ?? []
        let settings = GitHubSettings(
            enabled: githubEnabled, excludedRepos: githubExcludedRepos,
            closeBehavior: githubCloseBehavior)
        let result = await githubInbox.sync(existing: existing, settings: settings)

        guard result.available else {
            githubStatus = "GitHub CLI (gh) を実行できませんでした。`gh auth login` を確認してください。"
            return
        }
        for task in result.upserts {
            try? await store.upsertTask(task)
        }
        if !result.repos.isEmpty {
            githubRepos = Array(Set(githubRepos).union(result.repos)).sorted()
        }
        let stamp = Date().formatted(date: .omitted, time: .shortened)
        githubStatus =
            result.upserts.isEmpty
            ? "\(stamp) 同期しました（更新なし）" : "\(stamp) \(result.upserts.count) 件を更新しました"
        githubIssueLabels = result.labels
        await refreshLists()
        await runAutomationPass()
        await runIssueLabelPass()
        await runCommentPass()
    }

    // MARK: - Per-task command

    /// Runs the user's command once for each newly imported row it applies to.
    func runAutomationPass() async {
        guard let store, automationSettings.enabled, !automationRunning else { return }
        let existing = (try? await store.tasks(includeArchived: true)) ?? []
        await startRuns(
            TaskAutomation.plan(tasks: existing, settings: automationSettings),
            trigger: .arrival)
    }

    // MARK: - Label command

    /// Runs the user's command once for each assigned issue carrying the label
    /// they chose. The labels come from the GitHub pass that just ran; a pass
    /// that could not read them starts nothing.
    func runIssueLabelPass() async {
        let settings = automationSettings
        guard let store, settings.enabled, settings.labelTrigger, !automationRunning else {
            return
        }
        let existing = (try? await store.tasks(includeArchived: true)) ?? []
        await startRuns(
            LabelTrigger.plan(tasks: existing, labels: githubIssueLabels, settings: settings),
            trigger: .label)
    }

    /// Starts the planned rows one at a time.
    ///
    /// Sequential on purpose, and the state is written before the command
    /// starts: a crash mid-run leaves the row marked `running` rather than
    /// eligible again, so nothing is started twice.
    ///
    /// Shared by the two triggers whose event is the row itself. The comment
    /// trigger keeps its own loop: its runs are identified by the event, and
    /// it has an author and a daily limit to report.
    private func startRuns(_ planned: [TaskItem], trigger: AutomationTrigger) async {
        guard let store, !planned.isEmpty else { return }
        let settings = automationSettings
        automationRunning = true
        defer { automationRunning = false }
        for task in planned {
            let now = Date()
            let run = AutomationRun(
                id: AutomationRun.startId(trigger: trigger, taskId: task.id, now: now),
                taskId: task.id, title: task.title,
                url: GitHubTaskSync.url(fromDetail: task.detail), trigger: trigger,
                startedAt: now)
            try? await store.recordAutomationRun(run)
            try? await store.setAutomation(taskId: task.id, state: .running)
            await refreshLists()
            let outcome = await automationRunner.run(
                task: task, settings: settings, trigger: trigger)
            let success =
                trigger == .label
                ? "\(task.title) を \(settings.label) で実行しました"
                : "\(task.title) の生成物ができました"
            await finishRun(run, task: task, outcome: outcome, success: success)
        }
    }

    /// Writes how a run ended, to the run row and to the task, then tells the
    /// settings screen in one line.
    private func finishRun(
        _ run: AutomationRun, task: TaskItem, outcome: AutomationRunner.Outcome, success: String
    ) async {
        guard let store else { return }
        let stamp = Date().formatted(date: .omitted, time: .shortened)
        switch outcome {
        case .produced(let path):
            try? await store.finishAutomationRun(id: run.id, state: .done, artifactPath: path)
            try? await store.setAutomation(taskId: task.id, state: .done, artifactPath: path)
            automationStatus = "\(stamp) \(success)"
        case .failed(let reason, let path):
            try? await store.finishAutomationRun(
                id: run.id, state: .failed, reason: reason, artifactPath: path)
            // A failure that wrote nothing keeps the folder an earlier run
            // left on the task; there is nothing newer to point at.
            try? await store.setAutomation(
                taskId: task.id, state: .failed, artifactPath: path ?? task.artifactPath)
            automationStatus = "\(stamp) \(task.title): \(reason)"
        }
        await refreshLists()
    }

    // MARK: - Review-comment command

    /// Runs the user's command once for each pull request of theirs a bot has
    /// just reviewed.
    ///
    /// The event is recorded before the command starts, exactly like the
    /// arrival pass writes the row's state first: an interrupted run has to
    /// look like "already handled", because the alternative is an agent
    /// started twice on the same review.
    func runCommentPass() async {
        guard let store, !automationRunning else { return }
        let settings = automationSettings
        let existing = (try? await store.tasks(includeArchived: true)) ?? []
        let candidates = CommentTrigger.candidates(tasks: existing, settings: settings)
        guard !candidates.isEmpty else { return }
        let recorded = (try? await store.automationEventIds()) ?? []
        let events = await githubInbox.commentEvents(candidates: candidates, recorded: recorded)
        guard !events.isEmpty else { return }
        let runsToday =
            (try? await store.automationEventCounts(
                since: Date().addingTimeInterval(-CommentTrigger.dailyWindow))) ?? [:]
        let selection = CommentTrigger.select(
            events: events, recorded: recorded, runsToday: runsToday, settings: settings)
        if let held = selection.blocked.first {
            automationStatus =
                "\(held.repo)#\(held.number) は24時間の実行上限"
                + "（\(settings.commentDailyLimit) 回）に達したので実行しませんでした"
        }
        guard !selection.run.isEmpty else { return }

        automationRunning = true
        defer { automationRunning = false }
        let byId = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for event in selection.run {
            guard let task = byId[event.taskId] else { continue }
            let run = AutomationRun(
                id: event.id, taskId: task.id, title: task.title,
                url: GitHubTaskSync.url(fromDetail: task.detail), trigger: .comment,
                author: event.author, startedAt: Date())
            try? await store.recordAutomationRun(run)
            try? await store.setAutomation(taskId: task.id, state: .running)
            await refreshLists()
            let outcome = await automationRunner.run(
                task: task, settings: settings, trigger: .comment, event: event)
            await finishRun(
                run, task: task, outcome: outcome,
                success: "\(event.author) のレビューに対して実行しました")
        }
    }

    /// Clears one row's result so the command can run again, for the case
    /// where it failed for a reason the user has since fixed.
    func resetAutomation(taskId: String) async {
        guard let store else { return }
        await automationRunner.discard(taskId: taskId)
        try? await store.setAutomation(taskId: taskId, state: nil)
        await refreshLists()
    }

    private func refreshFromStore() async {
        guard let store else { return }
        try? await store.pruneLabels(olderThan: 30 * 24 * 3600)
        try? await store.pruneAutomationRuns(olderThan: 30 * 24 * 3600)
        // Only this process starts commands, so a run still marked running at
        // launch is one the previous process never finished writing.
        try? await store.interruptRunningAutomation()
        labels = (try? await store.labels()) ?? [:]
        await refreshLists()
    }

    // MARK: - LLM plumbing

    func makeClient() throws -> any LLMClient {
        guard let key = KeychainStore.resolveAPIKey(for: selectedProvider) else {
            throw LLMError.missingAPIKey(selectedProvider)
        }
        return LLMClientFactory.make(
            kind: selectedProvider, apiKey: key,
            model: models[selectedProvider] ?? selectedProvider.defaultModel)
    }

    func testConnection(_ kind: ProviderKind) async -> String {
        guard let key = KeychainStore.resolveAPIKey(for: kind) else {
            return "キー未設定"
        }
        let client = LLMClientFactory.make(
            kind: kind, apiKey: key, model: models[kind] ?? kind.defaultModel)
        do {
            _ = try await client.complete(
                LLMRequest(
                    messages: [ChatMessage(role: .user, text: "OK とだけ返答してください")],
                    maxTokens: 16))
            return "接続 OK"
        } catch {
            return "失敗: \(error)"
        }
    }

    /// Labels sessions whose work label is missing or stale, a bounded batch
    /// per pass. Failures cost nothing: unlabeled rows keep their fallback
    /// titles and the next pass tries again.
    private func runLabelPass() async {
        guard let store, let client = try? makeClient() else { return }
        let targets = labeler.sessionsNeedingLabels(sessions, labels: labels)
        guard !targets.isEmpty,
            let fresh = try? await labeler.label(client: client, sessions: targets)
        else { return }
        for label in fresh {
            try? await store.upsertLabel(label)
        }
        // Sessions the LLM saw but could not classify get a placeholder, so
        // the next pass spends its budget on new sessions instead of them.
        let labeled = Set(fresh.map(\.sessionId))
        for session in targets where !labeled.contains(session.id) {
            try? await store.upsertLabel(
                WorkLabel(
                    sessionId: session.id, kind: .other, subject: "",
                    updatedAt: Date(), labeledActivity: session.lastActivity))
        }
        labels = (try? await store.labels()) ?? labels
    }

    // MARK: - Task actions

    func addManualTask(title: String) async {
        await edit("タスクの追加") {
            guard let store, !title.isEmpty else { return }
            let task = TaskItem(
                id: UUID().uuidString, title: title, detail: "", status: .todo, rank: nil,
                source: .manual, createdAt: Date(), updatedAt: Date(), sessionIds: [])
            try? await store.upsertTask(task)
            await refreshLists()
        }
    }

    /// Adds a subtask under `parent`, at the end of its sibling list.
    /// Only one level deep: a subtask's own subtask lands under the same
    /// parent instead of nesting further.
    func addSubtask(of parent: TaskItem, title: String) async {
        await edit("サブタスクの追加") {
            guard let store, !title.isEmpty else { return }
            let parentId = parent.parentId ?? parent.id
            let task = TaskItem(
                id: UUID().uuidString, title: title, detail: "", status: .todo,
                rank: nextSiblingRank(parentId: parentId),
                source: .manual, createdAt: Date(), updatedAt: Date(),
                parentId: parentId, sessionIds: [])
            try? await store.upsertTask(task)
            await refreshLists()
        }
    }

    /// Swaps a subtask with its neighbour. Sibling order is the rank column,
    /// same as the top-level list, so a move is a rewrite of both ranks.
    func moveSubtask(_ task: TaskItem, up: Bool) async {
        await edit("サブタスクの並べ替え") { await performMoveSubtask(task, up: up) }
    }

    private func performMoveSubtask(_ task: TaskItem, up: Bool) async {
        guard let store, let parentId = task.parentId else { return }
        let siblings = subtasks(of: parentId)
        guard let index = siblings.firstIndex(where: { $0.id == task.id }) else { return }
        let target = up ? index - 1 : index + 1
        guard siblings.indices.contains(target) else { return }
        var reordered = siblings
        reordered.swapAt(index, target)
        for (rank, sibling) in reordered.enumerated() where sibling.rank != rank {
            var updated = sibling
            updated.rank = rank
            updated.updatedAt = Date()
            try? await store.upsertTask(updated)
        }
        await refreshLists()
    }

    /// Detaches a subtask, putting it back on the top-level list.
    func promoteSubtask(_ task: TaskItem) async {
        await edit("サブタスクの解除") {
            guard let store, task.parentId != nil else { return }
            var updated = task
            updated.parentId = nil
            updated.rank = nil
            updated.updatedAt = Date()
            try? await store.upsertTask(updated)
            await refreshLists()
        }
    }

    /// Hangs an existing top-level task under another one, at the end of its
    /// subtasks. A task with subtasks of its own is not offered as a child,
    /// so nesting stays one level deep.
    func nestTask(_ task: TaskItem, under parent: TaskItem) async {
        await edit("サブタスク化") {
            guard let store, task.id != parent.id, parent.parentId == nil else { return }
            var updated = task
            updated.parentId = parent.id
            updated.isToday = false
            updated.rank = nextSiblingRank(parentId: parent.id)
            updated.updatedAt = Date()
            try? await store.upsertTask(updated)
            await refreshLists()
        }
    }

    /// Subtasks of a parent, in display order.
    func subtasks(of parentId: String) -> [TaskItem] {
        tasks.filter { $0.parentId == parentId }
    }

    private func nextSiblingRank(parentId: String) -> Int {
        (subtasks(of: parentId).compactMap(\.rank).max() ?? -1) + 1
    }

    /// Puts a task into (or takes it out of) the 「今日やる」 section. The flag
    /// sticks across days until the user flips it back.
    func setTaskToday(_ task: TaskItem, _ isToday: Bool) async {
        await edit(isToday ? "今日やるに追加" : "今日やるから外す") {
            await performSetTaskToday(task, isToday)
        }
    }

    private func performSetTaskToday(_ task: TaskItem, _ isToday: Bool) async {
        guard let store else { return }
        var updated = task
        updated.isToday = isToday
        updated.updatedAt = Date()
        try? await store.upsertTask(updated)
        await refreshLists()
    }

    /// A board drag ended: `todayIds` are the rows that landed above the
    /// タスク divider, `laterIds` the rows below, both in display order.
    /// Today flags follow the divider, and the combined order is the ranking.
    /// The move is recorded as a preference so future AI proposals learn
    /// from it: crossing the divider beats a plain reorder as the signal.
    func applyBoardOrder(
        todayIds: [String], laterIds: [String], movedId: String? = nil, movedUp: Bool? = nil
    ) async {
        await edit("並べ替え") {
            await performBoardOrder(
                todayIds: todayIds, laterIds: laterIds, movedId: movedId, movedUp: movedUp)
        }
    }

    private func performBoardOrder(
        todayIds: [String], laterIds: [String], movedId: String?, movedUp: Bool?
    ) async {
        guard let store else { return }
        if let movedId, let moved = tasks.first(where: { $0.id == movedId }) {
            let becameToday = todayIds.contains(movedId)
            if moved.isToday != becameToday {
                try? await store.insertPreference(
                    "ユーザーは「\(moved.title)」を今日やる\(becameToday ? "に入れた" : "から外した")")
            } else if let movedUp {
                try? await store.insertPreference(
                    "ユーザーは「\(moved.title)」の優先度を手動で\(movedUp ? "上げた" : "下げた")")
            }
        }
        for (ids, isToday) in [(todayIds, true), (laterIds, false)] {
            for task in tasks where ids.contains(task.id) && task.isToday != isToday {
                var updated = task
                updated.isToday = isToday
                updated.updatedAt = Date()
                try? await store.upsertTask(updated)
            }
        }
        try? await store.setRanks(todayIds + laterIds)
        await refreshLists()
    }

    /// Completing a parent completes its open subtasks; see `TaskStatusChange`.
    func setTaskStatus(_ task: TaskItem, _ status: TaskStatus) async {
        await edit(statusEditLabel(status)) {
            guard let store else { return }
            for updated in TaskStatusChange.apply(status, to: task, in: tasks) {
                try? await store.upsertTask(updated)
            }
            await refreshLists()
        }
    }

    private func statusEditLabel(_ status: TaskStatus) -> String {
        switch status {
        case .done: "完了"
        case .archived: "アーカイブ"
        case .inProgress: "着手"
        case .todo: "未着手に戻す"
        }
    }

    /// Promote a session's in-transcript todo into a global task. When the
    /// session already hangs under a task, the todo becomes a subtask of it —
    /// which is where a promoted todo belongs.
    func promoteTodo(_ todo: TodoItem, from session: SessionSnapshot) async {
        await edit("todo の昇格") { await performPromoteTodo(todo, from: session) }
    }

    private func performPromoteTodo(_ todo: TodoItem, from session: SessionSnapshot) async {
        guard let store else { return }
        let done = todo.status == .completed
        let parent = owningTask(of: session)
        let task = TaskItem(
            id: UUID().uuidString, title: todo.content,
            detail: "セッション「\(session.title)」の todo から昇格",
            status: done ? .done : .todo,
            rank: parent.map { nextSiblingRank(parentId: $0.id) },
            source: .deterministic, createdAt: Date(), updatedAt: Date(),
            completedAt: done ? Date() : nil,
            parentId: parent?.id,
            sessionIds: [session.id])
        try? await store.upsertTask(task)
        await refreshLists()
    }

    /// The top-level task a session is attached to, if any.
    private func owningTask(of session: SessionSnapshot) -> TaskItem? {
        boardEntries
            .first { entry in entry.sessions.contains { $0.id == session.id } }?
            .task
    }

    // MARK: - Pomodoro

    func startPomodoro(_ task: TaskItem) {
        pomodoro = .startWork(taskId: task.id, now: Date())
    }

    func pausePomodoro() { pomodoro = pomodoro?.paused(now: Date()) }
    func resumePomodoro() { pomodoro = pomodoro?.resumed(now: Date()) }
    func stopPomodoro() { pomodoro = nil }

    /// The focused task's title, for the menu bar and the timer section.
    var pomodoroTaskTitle: String? {
        guard let pomodoro else { return nil }
        return tasks.first { $0.id == pomodoro.taskId }?.title
    }

    /// Plays a chime once, for the settings screen's preview buttons.
    func previewChime(_ chime: PomodoroChime) {
        playChime(chime)
    }

    private func playChime(_ chime: PomodoroChime) {
        guard let name = chime.systemSoundName else { return }
        NSSound(named: name)?.play()
    }

    /// Runs a 1-second tick while a pomodoro exists: advances `pomodoroNow`
    /// for the menu bar display and rolls an expired timer to its next phase
    /// (work → rest → gone) with a sound.
    private func updatePomodoroTicker() {
        pomodoroNow = Date()
        if pomodoro == nil {
            pomodoroTickTask?.cancel()
            pomodoroTickTask = nil
            return
        }
        guard pomodoroTickTask == nil else { return }
        pomodoroTickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, self.pomodoro != nil else { return }
                self.pomodoroNow = Date()
                if let timer = self.pomodoro, timer.isExpired(now: self.pomodoroNow) {
                    self.pomodoro = timer.afterExpiry(now: self.pomodoroNow)
                    self.playChime(self.soundSettings.chime(endingPhase: timer.phase))
                }
            }
        }
    }

    // MARK: - Undo

    /// Runs a task edit and records how to take it back.
    ///
    /// The action is not asked to describe its own inverse: the task list and
    /// the preference notes are compared before and after, and the difference
    /// is what undo writes back. An action that changed nothing records
    /// nothing, so 「元に戻す」 never spends a step on a no-op.
    private func edit(_ label: String, _ body: () async -> Void) async {
        let tasksBefore = tasks
        let preferenceIdsBefore = Set(preferences.map(\.id))
        await body()
        let step = UndoStep.between(
            before: tasksBefore, after: tasks, label: label,
            addedPreferenceIds: preferences.map(\.id).filter {
                !preferenceIdsBefore.contains($0)
            })
        guard !step.isEmpty else { return }
        undoStack.append(step)
        if undoStack.count > Self.historyDepth { undoStack.removeFirst() }
        // A new edit branches the history: what was undone before it can no
        // longer be put back on top of a different list.
        redoStack.removeAll()
    }

    /// Takes back the last task edit. The edit that would put it back lands on
    /// the redo stack.
    func undoLastEdit() async {
        guard let step = undoStack.popLast() else { return }
        let before = tasks
        await apply(step)
        redoStack.append(UndoStep.between(before: before, after: tasks, label: step.label))
    }

    /// Puts back the last undone edit.
    func redoLastEdit() async {
        guard let step = redoStack.popLast() else { return }
        let before = tasks
        await apply(step)
        undoStack.append(UndoStep.between(before: before, after: tasks, label: step.label))
    }

    /// Writes one step: rows the action created go first, so a restored parent
    /// never lands next to a child the action invented.
    private func apply(_ step: UndoStep) async {
        guard let store else { return }
        for id in step.removeIds {
            try? await store.deleteTask(id)
        }
        for task in step.restore {
            try? await store.restoreTask(task)
        }
        for id in step.removePreferenceIds {
            try? await store.deletePreference(id)
        }
        // A pomodoro pointed at a task the undo removed has nothing left to
        // count down for.
        if let pomodoro, step.removeIds.contains(pomodoro.taskId) {
            self.pomodoro = nil
        }
        await refreshLists()
    }

    private func refreshLists() async {
        guard let store else { return }
        // Runs first: their section sits above the task list, and inserting
        // it after the tasks are in makes the List keep its offset relative
        // to the rows below, which reads as a board that opened scrolled.
        automationRuns = (try? await store.automationRuns()) ?? []
        tasks = (try? await store.tasks()) ?? []
        preferences = (try? await store.preferences()) ?? []
    }

    // MARK: - Daily report

    /// Tasks finished today, earliest first — the ふりかえり lane's main list.
    var completedToday: [TaskItem] {
        reporter.completedToday(tasks)
    }

    /// Today's session activity, one row per distinct piece of work.
    var activityToday: [DailyReporter.ActivityItem] {
        reporter.activityToday(sessions: sessions, labels: labels)
    }

    /// 今日やる picks not finished yet — what the report calls 残っていること.
    var remainingToday: [TaskItem] {
        tasks.filter { $0.isToday && $0.status != .done && $0.status != .archived }
    }

    /// Generates the daily report for everything up to now. Mid-day runs are
    /// fine: the prompt carries the current time so the report says so.
    func generateDailyReport() async {
        guard !reportBusy else { return }
        reportBusy = true
        defer { reportBusy = false }
        do {
            let client = try makeClient()
            let activity = activityToday
            let plan = reporter.comparePlan(
                tasks: tasks, activity: activity, sessions: sessions, labels: labels)
            // Reading commits shells out to git once per repository, so it
            // runs off the main actor while the report is being prepared.
            let repoPaths = Set(
                sessions.filter { !$0.isSubagent && !$0.cwd.isEmpty }.map(\.cwd))
            let log = gitLog
            let commits = await Task.detached {
                log.commitsToday(paths: Array(repoPaths))
            }.value
            let completed = completedToday
            let input = reporter.reportInput(
                completed: completed, plan: plan, commits: commits)
            let reply = try await client.complete(
                LLMRequest(
                    system: reporter.systemPrompt(),
                    messages: [ChatMessage(role: .user, text: input)],
                    maxTokens: 4096))
            if let parsed = reporter.parseReport(from: reply) {
                report = parsed
                reportMetrics = DayMetrics.build(
                    plan: plan, commits: commits, completedTasks: completed.count)
                reportFallback = nil
            } else {
                report = nil
                reportMetrics = nil
                reportFallback = reply
            }
        } catch {
            lastError = "\(error)"
        }
    }

    // MARK: - Prioritization chat

    func sendChat(_ text: String) async {
        guard !text.isEmpty, !chatBusy else { return }
        chatEntries.append(ChatEntry(sender: .user, text: text, proposal: nil))
        chatBusy = true
        defer { chatBusy = false }
        do {
            let client = try makeClient()
            let system = prioritizer.systemPrompt(
                tasks: tasks, sessions: sessions, preferences: preferences)
            let history = chatEntries.map { entry in
                ChatMessage(role: entry.sender == .user ? .user : .assistant, text: entry.text)
            }
            let reply = try await client.complete(
                LLMRequest(
                    system: system, messages: history, maxTokens: 4096))
            let proposal = prioritizer.parseRanking(from: reply)
            chatEntries.append(
                ChatEntry(
                    sender: .assistant,
                    text: prioritizer.displayText(from: reply),
                    proposal: proposal?.orderedTaskIds))
        } catch {
            lastError = "\(error)"
            chatEntries.append(
                ChatEntry(
                    sender: .assistant, text: "エラー: \(error)", proposal: nil))
        }
    }

    func applyRanking(_ orderedTaskIds: [String]) async {
        await edit("AI 提案の並び順を適用") {
            guard let store else { return }
            let known = Set(tasks.map(\.id))
            let valid = orderedTaskIds.filter { known.contains($0) }
            guard !valid.isEmpty else { return }
            try? await store.setRanks(valid)
            await refreshLists()
        }
    }
}
