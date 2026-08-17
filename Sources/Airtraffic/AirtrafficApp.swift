import SwiftUI
import AirtrafficCore

@main
struct AirtrafficApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .onAppear {
                    // SPM executables launch as background processes; promote to a
                    // regular app so the window can take focus.
                    NSApplication.shared.setActivationPolicy(.regular)
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    model.start()
                }
        }

        MenuBarExtra {
            MenuBarContent()
                .environment(model)
        } label: {
            if model.attentionCount > 0 {
                Label("\(model.attentionCount)", systemImage: "airplane.circle.fill")
            } else {
                Image(systemName: "airplane.circle")
            }
        }
    }
}

struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let waiting = model.sessions.filter { $0.status.needsAttention }
        if waiting.isEmpty {
            Text("対応待ちのセッションはありません")
        } else {
            Text("対応待ち \(waiting.count) 件")
            Divider()
            ForEach(waiting.prefix(8)) { session in
                Label(
                    "[\(session.agent.displayName)] \(session.title.prefix(40))",
                    systemImage: statusSymbol(session.status))
            }
        }
        Divider()
        Button("Airtraffic を開く") {
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        Button("終了") { NSApplication.shared.terminate(nil) }
    }
}
