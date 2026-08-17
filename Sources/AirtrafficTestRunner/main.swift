import Foundation

// Entry point for `swift run airtraffic-tests`.
let semaphore = DispatchSemaphore(value: 0)
Task {
    let adapterTests = AdapterTests()
    await adapterTests.runAll()
    await StoreTests().runAll()
    semaphore.signal()
}
semaphore.wait()
TestKit.shared.finish()
