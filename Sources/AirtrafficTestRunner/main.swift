import Foundation

// Entry point for `swift run airtraffic-tests`.
let semaphore = DispatchSemaphore(value: 0)
Task {
    let adapterTests = AdapterTests()
    await adapterTests.runAll()
    await StoreTests().runAll()
    await ServiceTests().runAll()
    await PomodoroTests().runAll()
    await PomodoroSoundTests().runAll()
    await GitHubTests().runAll()
    semaphore.signal()
}
semaphore.wait()
TestKit.shared.finish()
