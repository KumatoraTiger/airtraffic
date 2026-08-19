import AirtrafficCore
import Foundation

struct PomodoroTests {
    func runAll() async {
        let start = Date(timeIntervalSince1970: 1_000_000)

        await TestKit.shared.run("pomodoro: work starts with the full duration") {
            let timer = PomodoroTimer.startWork(taskId: "t-1", now: start)
            expectEqual(timer.phase, .work)
            expectEqual(timer.taskId, "t-1")
            expectEqual(timer.remaining(now: start), PomodoroTimer.workDuration)
            expect(!timer.isPaused, "a fresh timer is running")
            expect(!timer.isExpired(now: start), "a fresh timer is not expired")
        }

        await TestKit.shared.run("pomodoro: remaining counts down against the clock") {
            let timer = PomodoroTimer.startWork(taskId: "t-1", now: start)
            expectEqual(timer.remaining(now: start.addingTimeInterval(60)), 24 * 60)
            expectEqual(timer.remaining(now: start.addingTimeInterval(30 * 60)), 0)
            expect(timer.isExpired(now: start.addingTimeInterval(25 * 60)), "expires at endsAt")
        }

        await TestKit.shared.run("pomodoro: pause holds the remaining time; resume restarts it") {
            let timer = PomodoroTimer.startWork(taskId: "t-1", now: start)
            let paused = timer.paused(now: start.addingTimeInterval(5 * 60))
            expect(paused.isPaused, "paused after pause")
            expectEqual(paused.pausedRemaining, 20 * 60)
            // Hours later, a paused timer still holds and never expires.
            let later = start.addingTimeInterval(3600 * 3)
            expectEqual(paused.remaining(now: later), 20 * 60)
            expect(!paused.isExpired(now: later), "a paused timer never expires")

            let resumed = paused.resumed(now: later)
            expect(!resumed.isPaused, "running after resume")
            expectEqual(resumed.remaining(now: later), 20 * 60)
            expectEqual(resumed.remaining(now: later.addingTimeInterval(60)), 19 * 60)
        }

        await TestKit.shared.run("pomodoro: pause and resume are idempotent") {
            let timer = PomodoroTimer.startWork(taskId: "t-1", now: start)
            expectEqual(timer.resumed(now: start), timer)
            let paused = timer.paused(now: start)
            expectEqual(paused.paused(now: start.addingTimeInterval(60)), paused)
        }

        await TestKit.shared.run("pomodoro: expired work rolls into rest, expired rest ends") {
            let timer = PomodoroTimer.startWork(taskId: "t-1", now: start)
            let expiry = start.addingTimeInterval(PomodoroTimer.workDuration)
            let rest = try unwrap(timer.afterExpiry(now: expiry))
            expectEqual(rest.phase, .rest)
            expectEqual(rest.taskId, "t-1")
            expectEqual(rest.remaining(now: expiry), PomodoroTimer.restDuration)
            expectEqual(rest.afterExpiry(now: expiry.addingTimeInterval(5 * 60)), nil)
        }

        await TestKit.shared.run("pomodoro: state survives a JSON round trip") {
            let timer = PomodoroTimer.startWork(taskId: "t-1", now: start)
                .paused(now: start.addingTimeInterval(60))
            let data = try JSONEncoder().encode(timer)
            let decoded = try JSONDecoder().decode(PomodoroTimer.self, from: data)
            expectEqual(decoded, timer)
        }

        await TestKit.shared.run("pomodoro: remaining renders as m:ss") {
            expectEqual(PomodoroTimer.remainingText(25 * 60), "25:00")
            expectEqual(PomodoroTimer.remainingText(61), "1:01")
            expectEqual(PomodoroTimer.remainingText(9), "0:09")
            expectEqual(PomodoroTimer.remainingText(-5), "0:00")
        }
    }
}
