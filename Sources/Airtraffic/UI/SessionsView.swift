import AirtrafficCore
import SwiftUI

struct SessionsView: View {
    @Environment(AppModel.self) private var model

    private var grouped: [(SessionStatus, [SessionSnapshot])] {
        let order: [SessionStatus] = [.waitingApproval, .waitingInput, .running, .idle]
        return order.compactMap { status in
            let items = model.sessions.filter { $0.status == status }
            return items.isEmpty ? nil : (status, items)
        }
    }

    var body: some View {
        List {
            if model.sessions.isEmpty {
                ContentUnavailableView(
                    "セッションが見つかりません",
                    systemImage: "airplane.departure",
                    description: Text("直近48時間に活動した coding agent のセッションがここに表示されます"))
            }
            ForEach(grouped, id: \.0) { status, items in
                Section {
                    ForEach(items) { session in
                        SessionRow(session: session)
                    }
                } header: {
                    Label(
                        sectionTitle(status, count: items.count),
                        systemImage: statusSymbol(status)
                    )
                    .foregroundStyle(statusColor(status))
                }
            }
        }
    }

    private func sectionTitle(_ status: SessionStatus, count: Int) -> String {
        "\(status.displayName) (\(count))"
    }
}

struct SessionRow: View {
    @Environment(AppModel.self) private var model
    let session: SessionSnapshot
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: session.agent.symbol)
                    .foregroundStyle(.secondary)
                Text(session.title)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Text(session.lastActivity, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Text(session.agent.displayName)
                Text(session.projectName)
                    .padding(.horizontal, 6)
                    .background(.quaternary, in: Capsule())
                if !session.todos.isEmpty {
                    let done = session.todos.filter { $0.status == .completed }.count
                    Text("todo \(done)/\(session.todos.count)")
                }
                Spacer()
                statusBadge
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if !session.lastAssistantText.isEmpty {
                Text(session.lastAssistantText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(expanded ? 8 : 1)
            }
            if expanded, !session.todos.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(session.todos, id: \.self) { todo in
                        HStack(spacing: 6) {
                            Image(systemName: todoSymbol(todo.status))
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
                .padding(.top, 4)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { withAnimation { expanded.toggle() } }
    }

    private var statusBadge: some View {
        Text(session.status.displayName)
            .font(.caption2.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(statusColor(session.status).opacity(0.15), in: Capsule())
            .foregroundStyle(statusColor(session.status))
    }

    private func todoSymbol(_ status: TodoItem.Status) -> String {
        switch status {
        case .completed: "checkmark.circle.fill"
        case .inProgress: "arrow.triangle.2.circlepath.circle"
        case .pending: "circle"
        }
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
