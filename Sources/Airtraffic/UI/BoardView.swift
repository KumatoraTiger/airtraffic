import AirtrafficCore
import SwiftUI

/// The unified board: a priority-ordered task list with execution state
/// attached. Session status only paints badges on rows; it never moves a row
/// between sections. Sections, in the order the user should spend attention:
///
/// - 今日やる: the tasks the user picked for today's focus; they stay here
///   until taken off by hand
/// - タスク: the priority list itself — every other open task, in rank order,
///   with its subtasks and linked sessions hanging under it as a tree
/// - タスク外の動き: agent activity matching no task, active within 24 hours
/// - 完了: done tasks (with their sessions) and aged-out activity
struct BoardView: View {
    @Environment(AppModel.self) private var model
    @State private var newTitle = ""
    @State private var showDone = false

    var body: some View {
        List {
            if model.boardEntries.isEmpty {
                ContentUnavailableView(
                    "まだ何も映っていません",
                    systemImage: "airplane.departure",
                    description: Text("coding agent のセッションが動き出すと、ここに映ります"))
            }
            todayAndTaskSection
            entrySection(
                activity, title: "タスク外の動き", symbol: "antenna.radiowaves.left.and.right",
                color: .gray)
            doneSection
        }
    }

    // MARK: - Row selection

    /// Today's picks, in rank order. Same rows as the main list, just lifted
    /// above it while their flag is on.
    private var todayEntries: [BoardEntry] {
        model.boardEntries.filter { entry in
            guard let task = entry.task else { return false }
            return task.status != .done && task.isToday
        }
    }

    /// The priority list: every open task not picked for today, in rank order
    /// (as the store returns them). Waiting or running executions are badges
    /// on the row, never a reason to move it.
    private var taskEntries: [BoardEntry] {
        model.boardEntries.filter { entry in
            guard let task = entry.task else { return false }
            return task.status != .done && !task.isToday
        }
    }

    /// Agent activity matching no task, active within the last 24 hours,
    /// newest first. Rows here can be promoted to a task or linked to one.
    private var activity: [BoardEntry] {
        model.boardEntries
            .filter { $0.task == nil && $0.isRecent() }
            .sorted { ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast) }
    }

    /// Taskless activity that aged past the 24-hour window: treated as
    /// finished, still revertable via 「タスクにする」.
    private var agedOut: [BoardEntry] {
        model.boardEntries.filter { $0.task == nil && !$0.isRecent() }
    }

    /// Done tasks, newest completion first. Their linked sessions stay
    /// attached, so completing a task takes its whole tree along.
    private var doneEntries: [BoardEntry] {
        Array(
            model.boardEntries
                .filter { $0.task?.status == .done }
                .sorted { ($0.task?.updatedAt ?? .distantPast) > ($1.task?.updatedAt ?? .distantPast) }
                .prefix(10))
    }

    // MARK: - Sections

    @ViewBuilder
    private func entrySection(
        _ entries: [BoardEntry], title: String, symbol: String, color: Color
    ) -> some View {
        if !entries.isEmpty {
            Section {
                ForEach(entries) { entry in
                    EntryRow(entry: entry)
                }
            } header: {
                Label("\(title) (\(entries.count))", systemImage: symbol)
                    .foregroundStyle(color)
            }
        }
    }

    /// 今日やる and タスク as one continuous, reorderable list. macOS's List
    /// starts row drags only through onMove, and an onMove drag cannot leave
    /// its own ForEach — so the two "sections" live in a single ForEach with a
    /// fixed divider row between them, and crossing the divider is what moves
    /// a task in or out of today.
    private var todayAndTaskSection: some View {
        Section {
            if todayEntries.isEmpty {
                Text("タスクを「タスク」見出しの上へドラッグ（行の太陽ボタンでも入ります）")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            ForEach(boardRows) { row in
                switch row {
                case .entry(let entry):
                    EntryRow(entry: entry)
                case .divider:
                    taskDivider.moveDisabled(true)
                }
            }
            .onMove(perform: moveBoardRow)
            HStack {
                TextField("タスクを追加…", text: $newTitle)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { submit() }
                InstantButton(title: "追加", enabled: !newTitle.isEmpty) { submit() }
            }
            .padding(.vertical, 2)
        } header: {
            HStack {
                Label("今日やる (\(todayEntries.count))", systemImage: "sun.max.fill")
                    .foregroundStyle(.orange)
                Spacer()
                Text("ドラッグで並べ替え・「タスク」見出しをまたいで移動")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The fixed boundary row between today's picks and the rest.
    private var taskDivider: some View {
        HStack {
            Label("タスク (\(taskEntries.count))", systemImage: "checklist")
                .font(.callout.bold())
                .foregroundStyle(.blue)
            Spacer()
            Text("上が高優先")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 6)
    }

    /// Finished work, brought back with one click: done tasks (their sessions
    /// still attached) via the checkmark, aged-out activity via 「タスクにする」.
    @ViewBuilder
    private var doneSection: some View {
        let count = doneEntries.count + agedOut.count
        if count > 0 {
            Section {
                if showDone {
                    ForEach(doneEntries) { entry in
                        EntryRow(entry: entry)
                    }
                    ForEach(agedOut) { entry in
                        EntryRow(entry: entry)
                    }
                }
            } header: {
                collapsibleHeader(
                    "完了 (\(count))", symbol: "checkmark.circle", expanded: $showDone)
            }
        }
    }

    private func collapsibleHeader(
        _ title: String, symbol: String, expanded: Binding<Bool>
    ) -> some View {
        HStack(spacing: 6) {
            Image(systemName: expanded.wrappedValue ? "chevron.down" : "chevron.right")
                .font(.caption2)
            Label(title, systemImage: symbol)
        }
        .foregroundStyle(.secondary)
        .instantClick(expanded.wrappedValue ? "折りたたむ" : "開く") {
            withAnimation(.easeOut(duration: 0.16)) { expanded.wrappedValue.toggle() }
        }
    }

    // MARK: - Drag & drop between 今日やる and タスク

    /// One row per open task plus the divider, in display order.
    private enum BoardRow: Identifiable {
        case entry(BoardEntry)
        case divider

        var id: String {
            switch self {
            case .entry(let entry): return entry.id
            case .divider: return "today-task-divider"
            }
        }
    }

    private var boardRows: [BoardRow] {
        todayEntries.map(BoardRow.entry) + [.divider] + taskEntries.map(BoardRow.entry)
    }

    /// A drag ended: replay the move on the combined row list and read the
    /// divider's position back off it. Rows above the divider are today's
    /// picks, rows below are the backlog, and the whole order becomes the
    /// new ranking.
    private func moveBoardRow(fromOffsets: IndexSet, toOffset: Int) {
        var rows = boardRows
        var movedId: String?
        var movedUp: Bool?
        if let from = fromOffsets.first, case .entry(let entry) = rows[from] {
            movedId = entry.task?.id
            movedUp = toOffset <= from
        }
        rows.move(fromOffsets: fromOffsets, toOffset: toOffset)
        var todayIds: [String] = []
        var laterIds: [String] = []
        var seenDivider = false
        for row in rows {
            switch row {
            case .divider:
                seenDivider = true
            case .entry(let entry):
                guard let id = entry.task?.id else { continue }
                if seenDivider { laterIds.append(id) } else { todayIds.append(id) }
            }
        }
        Task {
            await model.applyBoardOrder(
                todayIds: todayIds, laterIds: laterIds, movedId: movedId, movedUp: movedUp)
        }
    }

    private func submit() {
        let title = newTitle
        newTitle = ""
        Task { await model.addManualTask(title: title) }
    }
}
