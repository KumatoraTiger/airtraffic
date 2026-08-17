import AirtrafficCore
import SwiftUI

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
            if model.waitingCount > 0 {
                Label("\(model.waitingCount)", systemImage: "airplane.circle.fill")
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
        let waiting = model.waitingEntries
        if waiting.isEmpty {
            Text("対応待ちのタスクはありません")
        } else {
            Text("対応待ち \(waiting.count) 件")
            Divider()
            ForEach(waiting.prefix(8)) { entry in
                let kind = entry.label.flatMap { $0.isPlaceholder ? nil : $0.kind }
                let text = (kind.map { "\($0.displayName): " } ?? "") + entry.title
                Label(
                    String(text.prefix(40)),
                    systemImage: statusSymbol(entry.liveStatus ?? .idle))
            }
        }
        Divider()
        Button("Airtraffic を開く") {
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        Button("終了") { NSApplication.shared.terminate(nil) }
    }
}
