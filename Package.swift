// swift-tools-version: 5.10
import PackageDescription

// NOTE: Tests use a self-contained runner executable (airtraffic-tests) instead of
// XCTest, because XCTest ships with Xcode.app and this project must build with
// Command Line Tools alone. Run tests with `make test` (= swift run airtraffic-tests).
let package = Package(
    name: "Airtraffic",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "AirtrafficCore",
            path: "Sources/AirtrafficCore",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .executableTarget(
            name: "Airtraffic",
            dependencies: ["AirtrafficCore"],
            path: "Sources/Airtraffic"
        ),
        .executableTarget(
            name: "airtraffic-tests",
            dependencies: ["AirtrafficCore"],
            path: "Sources/AirtrafficTestRunner"
        ),
    ]
)
