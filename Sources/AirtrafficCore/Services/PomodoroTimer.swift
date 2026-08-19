import Foundation

/// Pomodoro timer state, task-first: a work interval always focuses one task.
/// Pure value type — every transition takes `now`, so tests drive it with
/// synthetic clocks and the app stores only `endsAt`, never a ticking counter.
public struct PomodoroTimer: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable {
        case work
        case rest

        public var displayName: String {
            switch self {
            case .work: "作業"
            case .rest: "休憩"
            }
        }
    }

    public static let workDuration: TimeInterval = 25 * 60
    public static let restDuration: TimeInterval = 5 * 60

    public var phase: Phase
    /// The task being focused. Kept through the following rest so the UI can
    /// keep naming the task.
    public var taskId: String
    /// Wall-clock end while running; nil while paused.
    public var endsAt: Date?
    /// Time left while paused; nil while running.
    public var pausedRemaining: TimeInterval?

    public var isPaused: Bool { pausedRemaining != nil }

    /// Full length of the current phase, for progress displays.
    public var phaseDuration: TimeInterval {
        switch phase {
        case .work: Self.workDuration
        case .rest: Self.restDuration
        }
    }

    public static func startWork(taskId: String, now: Date) -> PomodoroTimer {
        PomodoroTimer(
            phase: .work, taskId: taskId, endsAt: now.addingTimeInterval(workDuration),
            pausedRemaining: nil)
    }

    public func remaining(now: Date) -> TimeInterval {
        pausedRemaining ?? endsAt.map { max(0, $0.timeIntervalSince(now)) } ?? 0
    }

    /// A paused timer never expires; it holds its remaining time forever.
    public func isExpired(now: Date) -> Bool {
        !isPaused && remaining(now: now) <= 0
    }

    public func paused(now: Date) -> PomodoroTimer {
        guard !isPaused else { return self }
        var next = self
        next.pausedRemaining = remaining(now: now)
        next.endsAt = nil
        return next
    }

    public func resumed(now: Date) -> PomodoroTimer {
        guard let pausedRemaining else { return self }
        var next = self
        next.endsAt = now.addingTimeInterval(pausedRemaining)
        next.pausedRemaining = nil
        return next
    }

    /// The cycle: an expired work interval rolls into a rest interval, and an
    /// expired rest interval ends the timer (nil).
    public func afterExpiry(now: Date) -> PomodoroTimer? {
        switch phase {
        case .work:
            PomodoroTimer(
                phase: .rest, taskId: taskId, endsAt: now.addingTimeInterval(Self.restDuration),
                pausedRemaining: nil)
        case .rest:
            nil
        }
    }

    /// "mm:ss" for static display (paused state); running countdowns render
    /// with SwiftUI's self-updating timer text instead.
    public static func remainingText(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
