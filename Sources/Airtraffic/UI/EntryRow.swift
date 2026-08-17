import AirtrafficCore
import SwiftUI

/// One unit of work on the board, task-first. A persistent task leads with
/// its done-toggle like any task list; execution state (agents, status) is
/// trailing decoration that appears only while something is actually running.
/// Auto-materialized entries lead with their status symbol and carry a
/// 「残す」 button; everything else about them is hands-off. Tapping expands
/// the detail and the attached executions, whose todos can be promoted into
/// persistent tasks.
struct EntryRow: View {
    @Environment(AppModel.self) private var model
    let entry: BoardEntry
    @State private var expanded = false

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
                    .lineLimit(1)
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
                    sourceBadge(task)
                } else {
                    Button("残す") {
                        Task { await model.keepEntry(entry) }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("タスクとして残す（セッションが終わっても消えなくなります）")
                }
            }
            if let nowDoing {
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
                ForEach(entry.sessions) { session in
                    SessionDetail(session: session)
                        .padding(.leading, 14)
                }
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture { withAnimation { expanded.toggle() } }
        .contextMenu {
            if let task = entry.task {
                Button("完了にする") { Task { await model.setTaskStatus(task, .done) } }
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

    private func sourceBadge(_ task: TaskItem) -> some View {
        let (label, color): (String, Color) =
            switch task.source {
            case .deterministic: ("todo", .blue)
            case .llm: ("AI", .purple)
            case .manual: ("手動", .gray)
            }
        return Text(label)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
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
                    Button("タスクに昇格") {
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
