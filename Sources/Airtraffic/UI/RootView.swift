import SwiftUI
import AirtrafficCore

enum Pane: String, CaseIterable, Identifiable {
    case sessions
    case tasks
    case inbox
    case chat
    case settings

    var id: String { rawValue }

    var label: String {
        switch self {
        case .sessions: "管制"
        case .tasks: "タスク"
        case .inbox: "Inbox"
        case .chat: "壁打ち"
        case .settings: "設定"
        }
    }

    var symbol: String {
        switch self {
        case .sessions: "airplane"
        case .tasks: "checklist"
        case .inbox: "tray"
        case .chat: "bubble.left.and.bubble.right"
        case .settings: "gearshape"
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var pane: Pane = .sessions

    var body: some View {
        NavigationSplitView {
            List(Pane.allCases, selection: $pane) { pane in
                Label {
                    HStack {
                        Text(pane.label)
                        Spacer()
                        badge(for: pane)
                    }
                } icon: {
                    Image(systemName: pane.symbol)
                }
                .tag(pane)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180)
        } detail: {
            switch pane {
            case .sessions: SessionsView()
            case .tasks: TasksView()
            case .inbox: InboxView()
            case .chat: ChatView()
            case .settings: SettingsView()
            }
        }
        .frame(minWidth: 760, minHeight: 480)
    }

    @ViewBuilder
    private func badge(for pane: Pane) -> some View {
        switch pane {
        case .sessions where model.attentionCount > 0:
            countBadge(model.attentionCount, color: .orange)
        case .inbox where !model.candidates.isEmpty:
            countBadge(model.candidates.count, color: .purple)
        default:
            EmptyView()
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
}
