import AirtrafficCore
import SwiftUI

enum Lane: String, CaseIterable, Identifiable {
    /// The unified board: the task list with executions attached, AI
    /// proposals inline, and revertable 完了 / キャンセル trails.
    case board
    case chat
    /// 今日のふりかえり: what got done so far today, openable at any point in
    /// the day, with LLM-written 日報 generation on demand.
    case report

    var id: String { rawValue }

    var label: String {
        switch self {
        case .board: "管制"
        case .chat: "壁打ち"
        case .report: "ふりかえり"
        }
    }

    var symbol: String {
        switch self {
        case .board: "airplane"
        case .chat: "bubble.left.and.bubble.right"
        case .report: "doc.text"
        }
    }

    var minWidth: CGFloat {
        switch self {
        case .board: 340
        case .chat: 300
        case .report: 300
        }
    }

    /// Identity color, used to tint the lane header so stacked lanes stay
    /// visually separable.
    var tint: Color {
        switch self {
        case .board: .orange
        case .chat: .teal
        case .report: .purple
        }
    }
}

/// Two-dimensional lane layout: columns side by side, each column a
/// vertical stack of lanes. Encoded as "a,b|c" (columns separated by "|",
/// lanes within a column by ",").
struct LaneLayout: Equatable {
    var columns: [[Lane]]

    static let initial = LaneLayout(columns: [[.board], [.chat]])

    var openLanes: [Lane] { columns.flatMap { $0 } }

    func contains(_ lane: Lane) -> Bool { openLanes.contains(lane) }

    /// Position of a lane as (column index, row index).
    func position(of lane: Lane) -> (column: Int, row: Int)? {
        for (c, column) in columns.enumerated() {
            if let r = column.firstIndex(of: lane) { return (c, r) }
        }
        return nil
    }

    mutating func open(_ lane: Lane) {
        guard !contains(lane) else { return }
        columns.append([lane])
    }

    mutating func close(_ lane: Lane) {
        guard let (c, r) = position(of: lane) else { return }
        columns[c].remove(at: r)
        if columns[c].isEmpty { columns.remove(at: c) }
    }

    // Movement within a column.

    func canMoveUp(_ lane: Lane) -> Bool {
        position(of: lane).map { $0.row > 0 } ?? false
    }

    func canMoveDown(_ lane: Lane) -> Bool {
        position(of: lane).map { $0.row < columns[$0.column].count - 1 } ?? false
    }

    mutating func moveUp(_ lane: Lane) {
        guard canMoveUp(lane), let (c, r) = position(of: lane) else { return }
        columns[c].swapAt(r, r - 1)
    }

    mutating func moveDown(_ lane: Lane) {
        guard canMoveDown(lane), let (c, r) = position(of: lane) else { return }
        columns[c].swapAt(r, r + 1)
    }

    // Movement across columns. A lane sharing a column splits off into its
    // own new column; a lane alone in its column merges into the neighbor.

    func canMoveLeft(_ lane: Lane) -> Bool {
        guard let (c, _) = position(of: lane) else { return false }
        return columns[c].count > 1 || c > 0
    }

    func canMoveRight(_ lane: Lane) -> Bool {
        guard let (c, _) = position(of: lane) else { return false }
        return columns[c].count > 1 || c < columns.count - 1
    }

    mutating func moveLeft(_ lane: Lane) {
        guard let (c, r) = position(of: lane) else { return }
        if columns[c].count > 1 {
            columns[c].remove(at: r)
            columns.insert([lane], at: c)
        } else if c > 0 {
            columns.remove(at: c)
            columns[c - 1].append(lane)
        }
    }

    mutating func moveRight(_ lane: Lane) {
        guard let (c, r) = position(of: lane) else { return }
        if columns[c].count > 1 {
            columns[c].remove(at: r)
            columns.insert([lane], at: c + 1)
        } else if c < columns.count - 1 {
            columns.remove(at: c)
            columns[c].append(lane)
        }
    }

    // Persistence.

    func encoded() -> String {
        columns.map { $0.map(\.rawValue).joined(separator: ",") }
            .joined(separator: "|")
    }

    init(columns: [[Lane]]) {
        self.columns = columns
    }

    init?(encoded: String) {
        let columns = encoded.split(separator: "|").map { part in
            part.split(separator: ",").compactMap { Lane(rawValue: String($0)) }
        }.filter { !$0.isEmpty }
        // Drop layouts with duplicate or unknown lanes rather than render them.
        let lanes = columns.flatMap { $0 }
        guard Set(lanes).count == lanes.count else { return nil }
        self.columns = columns
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var layout: LaneLayout = RootView.restoreLayout()
    @State private var showSettings = false
    /// Always-on-top toggle. Persisted so the choice survives relaunches.
    @AppStorage("windowPinned") private var windowPinned = false

    // v2: the sessions/tasks/inbox lanes merged into the board lane. A new key
    // (rather than migrating the old string) so downgrades keep their layout.
    private static let layoutKey = "laneLayout.v2"

    var body: some View {
        VStack(spacing: 0) {
            PomodoroBanner()
            lanes
        }
        .animation(.easeInOut(duration: 0.2), value: model.pomodoro != nil)
        // Keep the window above other apps while the pin is on, without
        // taking key focus away from wherever the user is working.
        .background(WindowLevelPin(pinned: windowPinned))
        .frame(
            minWidth: max(480, layout.columns.map { $0.map(\.minWidth).max() ?? 240 }.reduce(0, +)),
            minHeight: 480
        )
        .toolbar {
            ToolbarItemGroup {
                ForEach(Lane.allCases) { lane in
                    laneToggle(lane)
                }
                Button {
                    Task { await model.undoLastEdit() }
                } label: {
                    Label("元に戻す", systemImage: "arrow.uturn.backward")
                }
                .disabled(!model.canUndo)
                .help(
                    model.undoLabel.map { "「\($0)」を元に戻す (⌘Z)" }
                        ?? "元に戻せる操作はありません")
                Button {
                    windowPinned.toggle()
                } label: {
                    Label("前面固定", systemImage: windowPinned ? "pin.fill" : "pin")
                }
                .foregroundStyle(windowPinned ? Color.orange : Color.secondary)
                .help(windowPinned ? "前面固定を解除" : "ウィンドウを常に前面に固定")
                Button {
                    showSettings = true
                } label: {
                    Label("設定", systemImage: "gearshape")
                }
                .help("設定")
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsSheet()
        }
    }

    private var lanes: some View {
        Group {
            if layout.columns.isEmpty {
                ContentUnavailableView(
                    "レーンがすべて閉じています",
                    systemImage: "rectangle.split.3x1",
                    description: Text("ツールバーのボタンからレーンを開きます"))
            } else {
                HSplitView {
                    ForEach(layout.columns.indices, id: \.self) { c in
                        VSplitView {
                            ForEach(layout.columns[c]) { lane in
                                LaneColumn(
                                    lane: lane,
                                    layout: layout,
                                    mutate: { mutation in mutateLayout(mutation) }
                                )
                                .frame(minHeight: 140, maxHeight: .infinity)
                                .layoutPriority(1)
                            }
                        }
                        .frame(
                            minWidth: layout.columns[c].map(\.minWidth).max() ?? 240,
                            maxWidth: .infinity, maxHeight: .infinity
                        )
                        .layoutPriority(1)
                    }
                }
            }
        }
    }

    private func laneToggle(_ lane: Lane) -> some View {
        Button {
            mutateLayout { layout in
                if layout.contains(lane) {
                    layout.close(lane)
                } else {
                    layout.open(lane)
                }
            }
        } label: {
            Label(lane.label, systemImage: lane.symbol)
                .overlay(alignment: .topTrailing) {
                    if let count = badgeCount(for: lane), count > 0 {
                        Text("\(count)")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 3)
                            .background(badgeColor(for: lane), in: Capsule())
                            .foregroundStyle(.white)
                            .offset(x: 8, y: -6)
                    }
                }
        }
        .foregroundStyle(layout.contains(lane) ? lane.tint : Color.secondary)
        .keyboardShortcut(shortcutKey(for: lane), modifiers: .command)
        .help("\(lane.label)レーンを開閉 (⌘\(shortcutNumber(for: lane)))")
    }

    private func badgeCount(for lane: Lane) -> Int? {
        switch lane {
        case .board: model.waitingCount
        default: nil
        }
    }

    private func badgeColor(for lane: Lane) -> Color {
        .orange
    }

    private func shortcutNumber(for lane: Lane) -> Int {
        (Lane.allCases.firstIndex(of: lane) ?? 0) + 1
    }

    private func shortcutKey(for lane: Lane) -> KeyEquivalent {
        KeyEquivalent(Character("\(shortcutNumber(for: lane))"))
    }

    private func mutateLayout(_ mutation: (inout LaneLayout) -> Void) {
        withAnimation(.easeInOut(duration: 0.15)) {
            mutation(&layout)
        }
        UserDefaults.standard.set(layout.encoded(), forKey: Self.layoutKey)
    }

    private static func restoreLayout() -> LaneLayout {
        guard let stored = UserDefaults.standard.string(forKey: layoutKey),
            let layout = LaneLayout(encoded: stored)
        else { return .initial }
        return layout
    }
}

/// One open lane: a slim header (title, badge, move menu, close button)
/// above the content.
private struct LaneColumn: View {
    @Environment(AppModel.self) private var model
    let lane: Lane
    let layout: LaneLayout
    let mutate: ((inout LaneLayout) -> Void) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Label(lane.label, systemImage: lane.symbol)
                    .font(.headline)
                    .foregroundStyle(lane.tint)
                headerBadge
                Spacer()
                moveMenu
                Button {
                    mutate { $0.close(lane) }
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2.bold())
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("\(lane.label)レーンを閉じる")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(lane.tint.opacity(0.12))
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(lane.tint.opacity(0.55))
                    .frame(height: 2)
            }
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var moveMenu: some View {
        Menu {
            Button("左へ移動", systemImage: "arrow.left") {
                mutate { $0.moveLeft(lane) }
            }
            .disabled(!layout.canMoveLeft(lane))
            Button("右へ移動", systemImage: "arrow.right") {
                mutate { $0.moveRight(lane) }
            }
            .disabled(!layout.canMoveRight(lane))
            Button("上へ移動", systemImage: "arrow.up") {
                mutate { $0.moveUp(lane) }
            }
            .disabled(!layout.canMoveUp(lane))
            Button("下へ移動", systemImage: "arrow.down") {
                mutate { $0.moveDown(lane) }
            }
            .disabled(!layout.canMoveDown(lane))
        } label: {
            Image(systemName: "rectangle.split.2x2")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("レーンの配置を移動（同じ列にレーンがある場合、左右で列を分離します）")
    }

    @ViewBuilder
    private var headerBadge: some View {
        if lane == .board, model.waitingCount > 0 {
            countBadge(model.waitingCount, color: .orange)
        }
    }

    private func countBadge(_ count: Int, color: Color) -> some View {
        Text("\(count)")
            .font(.caption2.bold())
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(color.opacity(0.2), in: Capsule())
            .foregroundStyle(color)
    }

    @ViewBuilder
    private var content: some View {
        switch lane {
        case .board: BoardView()
        case .chat: ChatView()
        case .report: ReportView()
        }
    }
}

private struct SettingsSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("設定", systemImage: "gearshape")
                    .font(.headline)
                Spacer()
                Button("閉じる") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()
            SettingsView()
        }
        .frame(width: 560, height: 620)
    }
}
