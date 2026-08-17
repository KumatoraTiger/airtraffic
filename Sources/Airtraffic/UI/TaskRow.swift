import AirtrafficCore
import SwiftUI

/// One persistent task on the board. The leading circle toggles done state,
/// which is also how a completed task is brought back from the
/// "recently disappeared" section.
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
