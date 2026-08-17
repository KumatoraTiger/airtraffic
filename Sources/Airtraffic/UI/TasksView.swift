import AirtrafficCore
import SwiftUI

struct TasksView: View {
    @Environment(AppModel.self) private var model
    @State private var newTitle = ""
    @State private var showDone = false

    private var visibleTasks: [TaskItem] {
        showDone ? model.tasks : model.tasks.filter { $0.status != .done }
    }

    var body: some View {
        VStack(spacing: 0) {
            List {
                if visibleTasks.isEmpty {
                    ContentUnavailableView(
                        "タスクはまだありません",
                        systemImage: "checklist",
                        description: Text("Inbox で候補を承認するか、下の欄から手動で追加します"))
                }
                ForEach(visibleTasks) { task in
                    TaskRow(task: task)
                }
                .onMove { indices, offset in
                    Task { await model.moveTask(fromOffsets: indices, toOffset: offset) }
                }
            }
            Divider()
            HStack {
                TextField("タスクを手動で追加…", text: $newTitle)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { submit() }
                Button("追加") { submit() }
                    .disabled(newTitle.isEmpty)
                Toggle("完了も表示", isOn: $showDone)
                    .toggleStyle(.checkbox)
            }
            .padding(10)
        }
        .navigationTitle("タスク")
    }

    private func submit() {
        let title = newTitle
        newTitle = ""
        Task { await model.addManualTask(title: title) }
    }
}

struct TaskRow: View {
    @Environment(AppModel.self) private var model
    let task: TaskItem

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Button {
                Task {
                    await model.setTaskStatus(task, task.status == .done ? .todo : .done)
                }
            } label: {
                Image(systemName: task.status == .done ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(task.status == .done ? .green : .secondary)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .strikethrough(task.status == .done)
                if !task.detail.isEmpty {
                    Text(task.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer()
            if let rank = task.rank {
                Text("#\(rank + 1)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            sourceBadge
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button("アーカイブ") { Task { await model.setTaskStatus(task, .archived) } }
        }
    }

    private var sourceBadge: some View {
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
}
