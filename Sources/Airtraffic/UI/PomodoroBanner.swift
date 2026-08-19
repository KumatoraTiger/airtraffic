import AirtrafficCore
import SwiftUI

/// The in-window face of a running pomodoro: a full-width colored banner
/// above the lanes with the focused task, a large countdown, a progress bar,
/// and the pause/stop controls. Red while focusing, green while resting;
/// gone when no timer runs.
struct PomodoroBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let timer = model.pomodoro {
            VStack(spacing: 8) {
                HStack(spacing: 12) {
                    Image(systemName: pomodoroSymbol(timer.phase))
                        .font(.system(size: 26))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(phaseLine(timer))
                            .font(.caption.bold())
                            .opacity(0.85)
                        Text(model.pomodoroTaskTitle ?? "タスク")
                            .font(.headline)
                            .lineLimit(1)
                    }
                    Spacer()
                    countdown(timer)
                    controls(timer)
                }
                ProgressView(value: progress(timer))
                    .progressViewStyle(.linear)
                    .tint(.white)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .foregroundStyle(.white)
            .background(gradient(timer.phase))
        }
    }

    private func phaseLine(_ timer: PomodoroTimer) -> String {
        timer.isPaused ? "\(timer.phase.displayName)・一時停止中" : "\(timer.phase.displayName)中"
    }

    @ViewBuilder
    private func countdown(_ timer: PomodoroTimer) -> some View {
        Group {
            if let endsAt = timer.endsAt {
                Text(timerInterval: Date()...max(Date(), endsAt), countsDown: true)
            } else {
                Text(PomodoroTimer.remainingText(timer.pausedRemaining ?? 0))
            }
        }
        .font(.system(size: 32, weight: .bold, design: .rounded).monospacedDigit())
        .opacity(timer.isPaused ? 0.7 : 1)
    }

    private func controls(_ timer: PomodoroTimer) -> some View {
        HStack(spacing: 8) {
            if timer.isPaused {
                controlButton("play.fill", help: "再開") { model.resumePomodoro() }
            } else {
                controlButton("pause.fill", help: "一時停止") { model.pausePomodoro() }
            }
            controlButton("stop.fill", help: "タイマーを止める") { model.stopPomodoro() }
        }
    }

    private func controlButton(
        _ symbol: String, help: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .bold))
                .frame(width: 30, height: 30)
                .background(.white.opacity(0.2), in: Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// Elapsed fraction of the phase. Follows the model's 1-second tick, so
    /// the bar advances in step with the menu bar.
    private func progress(_ timer: PomodoroTimer) -> Double {
        let duration = timer.phaseDuration
        guard duration > 0 else { return 0 }
        return min(1, max(0, 1 - timer.remaining(now: model.pomodoroNow) / duration))
    }

    private func gradient(_ phase: PomodoroTimer.Phase) -> LinearGradient {
        let colors: [Color] =
            switch phase {
            case .work: [Color(red: 0.85, green: 0.25, blue: 0.2), .orange]
            case .rest: [.teal, .green]
            }
        return LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing)
    }
}
