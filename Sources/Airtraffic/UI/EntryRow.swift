import AirtrafficCore
import AppKit
import SwiftUI

/// One unit of work on the board, task-first. A persistent task leads with
/// its done-toggle like any task list; execution state (agents, status) is
/// trailing decoration that appears only while something is actually running.
/// Its linked sessions hang under it as a tree, newest first, three at most —
/// and stay there until the task itself is done. Auto-materialized entries
/// lead with their status symbol and carry 「タスクにする」 (promote to a task) and
/// 「紐づけ」 (attach to an existing task). Tapping expands the detail and
/// the attached executions, whose todos can be promoted into persistent tasks.
/// Subtasks hang one level under the task, each a task in its own right; the
/// parent row shows their progress as 「2/5」 and never completes on its own.
struct EntryRow: View {
    @Environment(AppModel.self) private var model
    let entry: BoardEntry
    @State private var expanded = false
    @State private var newSubtaskTitle = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let task = entry.task {
                    Button {
                        Task {
                            await model.setTaskStatus(
                                task, task.status == .done ? .todo : .done)
                        }
                    } label: {
                        Image(systemName: task.status == .done ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(task.status == .done ? .green : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help("完了にする")
                } else {
                    Image(systemName: statusSymbol(entry.liveStatus ?? .idle))
                        .font(.caption)
                        .foregroundStyle(statusColor(entry.liveStatus ?? .idle))
                }
                if let label = entry.label, !label.isPlaceholder {
                    Text(label.kind.displayName)
                        .font(.caption2.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(kindColor(label.kind).opacity(0.15), in: Capsule())
                        .foregroundStyle(kindColor(label.kind))
                }
                Text(entry.title)
                    .fontWeight(.medium)
                    .strikethrough(entry.task?.status == .done)
                    .lineLimit(1)
                subtaskProgress
                // Expansion lives on this chevron, not on the whole row: any
                // tap gesture on the row surface (even a simultaneous one)
                // keeps NSTableView from ever starting a row drag, which
                // silently kills both reorder and cross-section drops.
                Button {
                    withAnimation { expanded.toggle() }
                } label: {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help(expanded ? "折りたたむ" : "詳細を表示")
                Spacer()
                if let project = entry.sessions.first?.projectName {
                    Text(project)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .background(.quaternary, in: Capsule())
                        .foregroundStyle(.secondary)
                }
                ForEach(agents, id: \.self) { agent in
                    Image(systemName: agent.symbol)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help(agent.displayName)
                }
                todoProgress
                if entry.isLive, let lastActivity = entry.lastActivity {
                    Text(lastActivity, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                if entry.isLive, let status = entry.liveStatus {
                    statusBadge(status)
                }
                if let task = entry.task {
                    if let timer = model.pomodoro, timer.taskId == task.id {
                        pomodoroBadge(timer)
                    }
                    if task.status != .done {
                        todayToggle(task)
                    }
                    sourceBadge(task)
                } else {
                    Button("タスクにする") {
                        Task { await model.keepEntry(entry) }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("タスクにする（セッションが終わっても消えなくなります）")
                    linkMenu
                }
            }
            if entry.task != nil {
                sessionTree
                subtaskTree
            } else if let nowDoing {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(nowDoing)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(expanded ? 8 : 1)
                }
                .padding(.leading, 2)
            }
            if expanded {
                if let detail = entry.task?.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 14)
                }
                if let task = entry.task, !task.isSubtask, task.status != .done {
                    addSubtaskField(task)
                }
                ForEach(entry.sessions) { session in
                    SessionDetail(session: session)
                        .padding(.leading, 14)
                }
            }
        }
        .padding(.vertical, 3)
        .contextMenu {
            if let task = entry.task {
                if task.status == .done {
                    Button("未完了に戻す") { Task { await model.setTaskStatus(task, .todo) } }
                } else {
                    Button("完了にする") { Task { await model.setTaskStatus(task, .done) } }
                    Button(task.isToday ? "今日やるから外す" : "今日やるに入れる") {
                        Task { await model.setTaskToday(task, !task.isToday) }
                    }
                    if model.pomodoro?.taskId == task.id {
                        Button("ポモドーロを止める") { model.stopPomodoro() }
                    } else {
                        Button("ポモドーロを開始") { model.startPomodoro(task) }
                    }
                    if !task.isSubtask {
                        Button("サブタスクを追加") { withAnimation { expanded = true } }
                    }
                    if !nestTargets(for: task).isEmpty {
                        nestMenu(task)
                    }
                }
                Button("アーカイブ") { Task { await model.setTaskStatus(task, .archived) } }
            }
        }
    }

    /// The linked executions, hanging under the task as a tree: newest
    /// activity first, three at most. They never leave on their own — only
    /// completing the task takes them off the board.
    @ViewBuilder
    private var sessionTree: some View {
        ForEach(entry.sessions.prefix(3)) { session in
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "arrow.turn.down.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Image(systemName: statusSymbol(session.status))
                    .font(.caption)
                    .foregroundStyle(statusColor(session.status))
                Text(sessionLabel(session))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Text(session.status.displayName)
                    .font(.caption2)
                    .foregroundStyle(statusColor(session.status))
                Text(session.lastActivity, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.leading, 2)
        }
        if entry.sessions.count > 3 {
            Text("他 \(entry.sessions.count - 3) 件（タップで表示）")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.leading, 20)
        }
    }

    /// 「2/5」 on the parent row: subtasks done out of subtasks open. No
    /// rollup happens on completion, so this progress is the only signal.
    @ViewBuilder
    private var subtaskProgress: some View {
        if let progress = entry.subtaskProgress {
            Text("\(progress.done)/\(progress.total)")
                .font(.caption2.monospacedDigit())
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(.quaternary, in: Capsule())
                .foregroundStyle(progress.done == progress.total ? .green : .secondary)
                .help("サブタスクの進捗")
        }
    }

    /// The subtasks, indented under their parent. They are rows of their own —
    /// completable, pomodoro-able, session-attachable — just one level in.
    @ViewBuilder
    private var subtaskTree: some View {
        ForEach(entry.children) { child in
            SubtaskRow(entry: child)
                .padding(.leading, 16)
        }
    }

    /// Adds one subtask, staying focused for the next: a checklist is
    /// typically written in one go.
    private func addSubtaskField(_ task: TaskItem) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.turn.down.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            TextField("サブタスクを追加…", text: $newSubtaskTitle)
                .textFieldStyle(.roundedBorder)
                .font(.caption)
                .onSubmit { submitSubtask(task) }
            Button("追加") { submitSubtask(task) }
                .controlSize(.small)
                .disabled(newSubtaskTitle.isEmpty)
        }
        .padding(.leading, 14)
    }

    private func submitSubtask(_ task: TaskItem) {
        let title = newSubtaskTitle
        newSubtaskTitle = ""
        Task { await model.addSubtask(of: task, title: title) }
    }

    /// Hangs this task under another one. Only tasks without subtasks of
    /// their own are offered, so nesting stays one level deep.
    private func nestMenu(_ task: TaskItem) -> some View {
        Menu("別のタスクのサブタスクにする") {
            ForEach(nestTargets(for: task)) { parent in
                Button(parent.title) {
                    Task { await model.nestTask(task, under: parent) }
                }
            }
        }
    }

    /// Open top-level tasks other than this one. A task that already has
    /// subtasks is not offered a parent at all (that would be two levels),
    /// which is why the menu is hidden for it.
    private func nestTargets(for task: TaskItem) -> [TaskItem] {
        guard entry.children.isEmpty else { return [] }
        return model.tasks.filter {
            $0.id != task.id && $0.parentId == nil && $0.status != .done
                && $0.status != .archived
        }
    }

    private func sessionLabel(_ session: SessionSnapshot) -> String {
        let title = TitleCleaner.taskLabel(session.title)
        return title.isEmpty ? session.agent.displayName : title
    }

    /// Attaches this taskless entry to an existing open task.
    private var linkMenu: some View {
        Menu {
            ForEach(openTasks) { task in
                Button(linkLabel(task)) {
                    Task { await model.linkEntry(entry, to: task) }
                }
            }
        } label: {
            Text("紐づけ")
        }
        .menuStyle(.borderlessButton)
        .controlSize(.small)
        .fixedSize()
        .disabled(openTasks.isEmpty)
        .help("既存のタスクに紐づける（タスクの下にぶら下がります）")
    }

    private var openTasks: [TaskItem] {
        model.tasks.filter { $0.status != .done && $0.status != .archived }
    }

    /// Subtasks read as children in the 紐づけ menu too, so linking a session
    /// to the right level is one glance.
    private func linkLabel(_ task: TaskItem) -> String {
        task.isSubtask ? "↳ \(task.title)" : task.title
    }

    private var agents: [AgentKind] {
        var seen: [AgentKind] = []
        for session in entry.sessions where !seen.contains(session.agent) {
            seen.append(session.agent)
        }
        return seen
    }

    @ViewBuilder
    private var todoProgress: some View {
        if let todos = entry.sessions.first?.todos, !todos.isEmpty {
            let done = todos.filter { $0.status == .completed }.count
            Text("\(done)/\(todos.count)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .help("todo の進捗")
        }
    }

    /// In and out of the 「今日やる」 section with one click. Filled sun while
    /// the task is in; the flag never expires on its own.
    private func todayToggle(_ task: TaskItem) -> some View {
        Button {
            Task { await model.setTaskToday(task, !task.isToday) }
        } label: {
            Image(systemName: task.isToday ? "sun.max.fill" : "sun.max")
                .font(.caption)
                .foregroundStyle(task.isToday ? .orange : .secondary)
        }
        .buttonStyle(.plain)
        .help(task.isToday ? "今日やるから外す" : "今日やるに入れる")
    }

    /// A live countdown on the focused task's row. The running state uses
    /// SwiftUI's self-updating timer text, so no view-side ticking is needed.
    private func pomodoroBadge(_ timer: PomodoroTimer) -> some View {
        HStack(spacing: 3) {
            Image(systemName: timer.isPaused ? "pause.circle" : pomodoroSymbol(timer.phase))
            if let endsAt = timer.endsAt {
                Text(timerInterval: Date()...max(Date(), endsAt), countsDown: true)
            } else {
                Text(PomodoroTimer.remainingText(timer.pausedRemaining ?? 0))
            }
        }
        .font(.caption2.monospacedDigit())
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .background(pomodoroColor(timer.phase).opacity(0.15), in: Capsule())
        .foregroundStyle(pomodoroColor(timer.phase))
        .help("ポモドーロ\(timer.phase.displayName)中")
    }

    @ViewBuilder
    private func sourceBadge(_ task: TaskItem) -> some View {
        let (label, color): (String, Color) =
            switch task.source {
            case .deterministic: ("todo", .blue)
            case .llm: ("AI", .purple)
            case .manual: ("手動", .gray)
            case .github: ("GitHub", .green)
            }
        let capsule =
            Text(label)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
        // A GitHub row exists to be opened, so its badge is the link.
        if task.source == .github, let url = githubURL(task) {
            Button {
                NSWorkspace.shared.open(url)
            } label: {
                capsule
            }
            .buttonStyle(.plain)
            .help("GitHub で開く")
        } else {
            capsule
        }
    }

    /// The issue or pull request link the sync wrote into the detail line.
    private func githubURL(_ task: TaskItem) -> URL? {
        task.detail
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix("https://") }
            .flatMap(URL.init(string:))
    }

    /// One line for what the most urgent execution is on right now: its
    /// in-progress todo when there is one, else the assistant's latest
    /// message. Marker-only messages from imported transcripts say nothing
    /// about the work, so they are dropped. Stopped executions say nothing
    /// about *now*, so the line is live-only.
    private var nowDoing: String? {
        guard entry.isLive, let session = entry.sessions.first else { return nil }
        if let doing = session.todos.first(where: { $0.status == .inProgress }) {
            return doing.content
        }
        let text = session.lastAssistantText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !(text.hasPrefix("<") && text.hasSuffix(">")) else { return nil }
        return text
    }

    private func statusBadge(_ status: SessionStatus) -> some View {
        Text(status.displayName)
            .font(.caption2.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(statusColor(status).opacity(0.15), in: Capsule())
            .foregroundStyle(statusColor(status))
    }
}

/// One subtask under its parent. A task in its own right — completable,
/// pomodoro-able, and able to carry the sessions doing it — rendered flatter
/// than a top-level row so the hierarchy reads at a glance. Reordering is in
/// the context menu: the board's drag gesture belongs to the top-level list.
private struct SubtaskRow: View {
    @Environment(AppModel.self) private var model
    let entry: BoardEntry
    @State private var expanded = false

    var body: some View {
        let task = entry.task
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "arrow.turn.down.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                if let task {
                    Button {
                        Task {
                            await model.setTaskStatus(
                                task, task.status == .done ? .todo : .done)
                        }
                    } label: {
                        Image(
                            systemName: task.status == .done
                                ? "checkmark.circle.fill" : "circle"
                        )
                        .font(.caption)
                        .foregroundStyle(task.status == .done ? .green : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help("完了にする")
                }
                Text(entry.title)
                    .font(.callout)
                    .strikethrough(task?.status == .done)
                    .foregroundStyle(task?.status == .done ? .secondary : .primary)
                    .lineLimit(1)
                if !entry.sessions.isEmpty {
                    Button {
                        withAnimation { expanded.toggle() }
                    } label: {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help(expanded ? "折りたたむ" : "セッションを表示")
                }
                Spacer()
                ForEach(agents, id: \.self) { agent in
                    Image(systemName: agent.symbol)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .help(agent.displayName)
                }
                if let timer = model.pomodoro, let task, timer.taskId == task.id {
                    Image(systemName: pomodoroSymbol(timer.phase))
                        .font(.caption2)
                        .foregroundStyle(pomodoroColor(timer.phase))
                        .help("ポモドーロ\(timer.phase.displayName)中")
                }
                if entry.isLive, let status = entry.liveStatus {
                    Text(status.displayName)
                        .font(.caption2.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(statusColor(status).opacity(0.15), in: Capsule())
                        .foregroundStyle(statusColor(status))
                }
            }
            if expanded {
                ForEach(entry.sessions) { session in
                    SessionDetail(session: session)
                        .padding(.leading, 18)
                }
            }
        }
        .contextMenu {
            if let task {
                if task.status == .done {
                    Button("未完了に戻す") { Task { await model.setTaskStatus(task, .todo) } }
                } else {
                    Button("完了にする") { Task { await model.setTaskStatus(task, .done) } }
                    if model.pomodoro?.taskId == task.id {
                        Button("ポモドーロを止める") { model.stopPomodoro() }
                    } else {
                        Button("ポモドーロを開始") { model.startPomodoro(task) }
                    }
                }
                Button("上へ") { Task { await model.moveSubtask(task, up: true) } }
                Button("下へ") { Task { await model.moveSubtask(task, up: false) } }
                Button("サブタスクをやめる（単独のタスクに戻す）") {
                    Task { await model.promoteSubtask(task) }
                }
                Button("アーカイブ") { Task { await model.setTaskStatus(task, .archived) } }
            }
        }
    }

    private var agents: [AgentKind] {
        var seen: [AgentKind] = []
        for session in entry.sessions where !seen.contains(session.agent) {
            seen.append(session.agent)
        }
        return seen
    }
}

/// One execution inside an expanded entry: which agent, its state, its last
/// message, and its todos.
private struct SessionDetail: View {
    @Environment(AppModel.self) private var model
    let session: SessionSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: session.agent.symbol)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(session.agent.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(session.status.displayName)
                    .font(.caption2)
                    .foregroundStyle(statusColor(session.status))
                Spacer()
                Text(session.lastActivity, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if !session.lastAssistantText.isEmpty {
                Text(session.lastAssistantText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
            }
            ForEach(session.todos, id: \.self) { todo in
                HStack(spacing: 6) {
                    Image(systemName: todoSymbol(todo.status))
                        .font(.caption)
                        .foregroundStyle(todo.status == .completed ? .green : .secondary)
                    Text(todo.content).font(.caption)
                    Spacer()
                    Button("タスクにする") {
                        Task { await model.promoteTodo(todo, from: session) }
                    }
                    .buttonStyle(.link)
                    .font(.caption2)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func todoSymbol(_ status: TodoItem.Status) -> String {
        switch status {
        case .completed: "checkmark.circle.fill"
        case .inProgress: "arrow.triangle.2.circlepath.circle"
        case .pending: "circle"
        }
    }
}

/// One fixed color per work kind, so scanning the board vertically reads
/// as a distribution of work ("いまレビューが3本、設計が1本").
func kindColor(_ kind: WorkKind) -> Color {
    switch kind {
    case .review: .orange
    case .design: .purple
    case .implement: .blue
    case .investigate: .teal
    case .fix: .red
    case .ops: .brown
    case .other: .gray
    }
}

func pomodoroSymbol(_ phase: PomodoroTimer.Phase) -> String {
    switch phase {
    case .work: "timer"
    case .rest: "cup.and.saucer.fill"
    }
}

func pomodoroColor(_ phase: PomodoroTimer.Phase) -> Color {
    switch phase {
    case .work: .red
    case .rest: .green
    }
}

func statusColor(_ status: SessionStatus) -> Color {
    switch status {
    case .waitingApproval: .orange
    case .waitingInput: .yellow
    case .running: .green
    case .idle: .gray
    }
}

func statusSymbol(_ status: SessionStatus) -> String {
    switch status {
    case .waitingApproval: "exclamationmark.triangle.fill"
    case .waitingInput: "person.fill.questionmark"
    case .running: "play.circle.fill"
    case .idle: "pause.circle"
    }
}
