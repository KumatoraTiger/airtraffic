import Foundation

/// Where the app keeps what it owns on disk: the store and the artifacts.
public enum AppDirectories {
    /// The environment variable that moves everything the app writes.
    ///
    /// A debug build launched next to the installed app otherwise opens the
    /// SAME store and runs the SAME migrations on it — `HOME` does not move
    /// Application Support — so a UI check needs a way to point a build at a
    /// scratch directory. Unset (the normal case) means Application Support.
    public static let overrideVariable = "AIRTRAFFIC_DATA_DIR"

    /// `~/Library/Application Support/Airtraffic`, or the override.
    public static func support() -> URL {
        if let override = ProcessInfo.processInfo.environment[overrideVariable],
            !override.isEmpty
        {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Airtraffic", isDirectory: true)
    }
}
