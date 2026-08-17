// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Airtraffic",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Airtraffic",
            path: "Sources/Airtraffic",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .testTarget(
            name: "AirtrafficTests",
            dependencies: ["Airtraffic"],
            path: "Tests/AirtrafficTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
