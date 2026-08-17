import Foundation

/// Minimal test harness. XCTest is unavailable without Xcode.app, so tests are a
/// plain executable: `swift run airtraffic-tests` (or `make test`).
/// Exit code 0 means all tests passed.
final class TestKit {
    static let shared = TestKit()
    private(set) var failureCount = 0
    private(set) var testCount = 0
    private var currentTestFailed = false

    func run(_ name: String, _ body: () async throws -> Void) async {
        testCount += 1
        currentTestFailed = false
        do {
            try await body()
        } catch {
            fail("threw \(error)")
        }
        print(currentTestFailed ? "✗ \(name)" : "✓ \(name)")
    }

    func fail(_ message: String, file: StaticString = #filePath, line: UInt = #line) {
        failureCount += 1
        currentTestFailed = true
        print("  FAIL: \(message) (\(file):\(line))")
    }

    func finish() -> Never {
        print("\n\(testCount) tests, \(failureCount) failures")
        exit(failureCount == 0 ? 0 : 1)
    }
}

func expect(
    _ condition: Bool, _ message: String = "expected true",
    file: StaticString = #filePath, line: UInt = #line
) {
    if !condition { TestKit.shared.fail(message, file: file, line: line) }
}

func expectEqual<T: Equatable>(
    _ actual: T, _ expected: T,
    file: StaticString = #filePath, line: UInt = #line
) {
    if actual != expected {
        TestKit.shared.fail("expected \(expected), got \(actual)", file: file, line: line)
    }
}

struct UnwrapError: Error {}

func unwrap<T>(
    _ value: T?, file: StaticString = #filePath, line: UInt = #line
) throws -> T {
    guard let value else {
        TestKit.shared.fail("unexpected nil", file: file, line: line)
        throw UnwrapError()
    }
    return value
}
