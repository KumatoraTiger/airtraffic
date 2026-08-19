import AirtrafficCore
import Foundation

struct PomodoroSoundTests {
    func runAll() async {
        await TestKit.shared.run("sound: chime maps to a system sound except なし") {
            expectEqual(PomodoroChime.none.systemSoundName, nil)
            expectEqual(PomodoroChime.none.displayName, "なし")
            expectEqual(PomodoroChime.glass.systemSoundName, "Glass")
            for chime in PomodoroChime.allCases where chime != .none {
                let name = try unwrap(chime.systemSoundName)
                let path = "/System/Library/Sounds/\(name).aiff"
                expect(
                    FileManager.default.fileExists(atPath: path),
                    "\(name) exists as a macOS system sound")
            }
        }

        await TestKit.shared.run("sound: each phase picks its own chime") {
            var settings = PomodoroSoundSettings.default
            settings.workEndChime = .ping
            settings.restEndChime = .pop
            expectEqual(settings.chime(endingPhase: .work), .ping)
            expectEqual(settings.chime(endingPhase: .rest), .pop)
        }

        await TestKit.shared.run("sound: a silenced phase keeps its なし choice") {
            var settings = PomodoroSoundSettings.default
            settings.restEndChime = .none
            expectEqual(settings.chime(endingPhase: .rest).systemSoundName, nil)
            expectEqual(settings.chime(endingPhase: .work), .glass)
        }

        await TestKit.shared.run("sound: settings survive a JSON round trip") {
            var settings = PomodoroSoundSettings.default
            settings.workEndChime = .submarine
            settings.restEndChime = .none
            let data = try JSONEncoder().encode(settings)
            expectEqual(try JSONDecoder().decode(PomodoroSoundSettings.self, from: data), settings)
        }
    }
}
