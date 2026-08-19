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
            // A real View type, not inline content: observation tracking runs
            // during a `body` evaluation, so model changes only invalidate the
            // status item when the reads happen inside one.
            MenuBarLabel(model: model)
        }
    }
}

/// The status item itself. The countdown takes over while a pomodoro runs;
/// the waiting count is still one click away in the menu. The countdown text
/// is static and follows the model's 1-second tick — a self-updating timer
/// Text here redraws the status item every frame and pins the main thread.
struct MenuBarLabel: View {
    let model: AppModel

    var body: some View {
        // Not Label: MenuBarExtra renders a Label icon-only, dropping the
        // title, so the icon and text are composed by hand.
        if let timer = model.pomodoro {
            HStack(spacing: 3) {
                Image(systemName: timer.isPaused ? "pause.circle" : pomodoroSymbol(timer.phase))
                Text(PomodoroTimer.remainingText(timer.remaining(now: model.pomodoroNow)))
                    .monospacedDigit()
            }
        } else if model.waitingCount > 0 {
            HStack(spacing: 3) {
                Image(systemName: "airplane.circle.fill")
                Text("\(model.waitingCount)")
            }
        } else {
            Image(systemName: "airplane.circle")
        }
    }
}

struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if let timer = model.pomodoro {
            let subject = model.pomodoroTaskTitle ?? "タスク"
            Text("\(timer.phase.displayName)中: \(String(subject.prefix(40)))")
            if timer.isPaused {
                Button("再開") { model.resumePomodoro() }
            } else {
                Button("一時停止") { model.pausePomodoro() }
            }
            Button("タイマーを止める") { model.stopPomodoro() }
            Divider()
        }
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
