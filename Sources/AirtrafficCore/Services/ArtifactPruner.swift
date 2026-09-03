import Foundation

/// Removes what per-task commands wrote once it is old enough to be of no
/// use, so the artifacts directory stops growing for the life of the install.
///
/// Age is the only rule. Keeping a directory for as long as something still
/// points at it was considered and dropped: a task row holds its
/// `artifact_path` for as long as the issue stays open, so a folder would be
/// protected indefinitely — which is the unbounded growth this exists to
/// stop. Deleting by age instead means the board must stop offering a folder
/// that is gone, which is why `prune` returns the paths it removed and the
/// caller clears them off the rows.
public actor ArtifactPruner {
    /// How long a run's output is kept. The same window `pruneAutomationRuns`
    /// uses, so a run's history and its files disappear together.
    public static let retention: TimeInterval = 30 * 24 * 3600

    /// One entry directly under the artifacts base, dated by the newest thing
    /// inside it.
    public struct Entry: Sendable, Equatable {
        public var path: String
        public var lastWrite: Date

        public init(path: String, lastWrite: Date) {
            self.path = path
            self.lastWrite = lastWrite
        }
    }

    private let base: URL

    public init(base: URL) {
        self.base = base
    }

    /// Which entries have aged out. Pure, so the rule is testable without a
    /// disk: an entry is expired when nothing in it has been written for
    /// `age`.
    public static func expired(
        _ entries: [Entry], age: TimeInterval = ArtifactPruner.retention, now: Date = Date()
    ) -> [String] {
        entries.filter { now.timeIntervalSince($0.lastWrite) >= age }.map(\.path)
    }

    /// Deletes every aged-out entry under the base and returns their paths.
    ///
    /// Never throws: housekeeping that fails must not stop a launch. A path it
    /// could not remove is left out of the answer, so the rows keep pointing
    /// at a directory that is still there.
    public func prune(
        age: TimeInterval = ArtifactPruner.retention, now: Date = Date()
    ) -> [String] {
        var removed: [String] = []
        for path in Self.expired(entries(), age: age, now: now) {
            do {
                try FileManager.default.removeItem(atPath: path)
                removed.append(path)
            } catch {
                continue
            }
        }
        return removed
    }

    /// The immediate children of the base, dated.
    ///
    /// Files as well as directories: a row written before the output became a
    /// directory names a single file, and that one ages out the same way. A
    /// directory is dated by the newest FILE anywhere inside it, never by its
    /// own timestamp, for the reason the runner already knows — a
    /// subdirectory's date does not move when a file within it is rewritten.
    /// An empty directory falls back to its own date so it can still expire.
    private func entries() -> [Entry] {
        let children =
            (try? FileManager.default.contentsOfDirectory(
                at: base, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles])) ?? []
        return children.map { url in
            let isDirectory =
                (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let newest = isDirectory ? newestWrite(in: url) : nil
            // Spelled from the base, not taken from the listing: enumerating a
            // directory resolves symlinks along the way (/var becomes
            // /private/var), and the path reported here has to match the one
            // the runner stored on the row character for character, or
            // `clearArtifactPaths` clears nothing.
            return Entry(
                path: base.appendingPathComponent(url.lastPathComponent).path,
                lastWrite: newest ?? Self.date(of: url))
        }
    }

    /// The newest modification date of any regular file under `directory`, or
    /// nil when it holds none.
    private func newestWrite(in directory: URL) -> Date? {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard
            let found = FileManager.default.enumerator(
                at: directory, includingPropertiesForKeys: keys)
        else { return nil }
        var newest: Date?
        for case let url as URL in found {
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true else { continue }
            guard let date = values?.contentModificationDate else { continue }
            if date > newest ?? .distantPast { newest = date }
        }
        return newest
    }

    /// A URL with no readable date is treated as brand new, never as ancient:
    /// housekeeping that cannot tell how old something is must not delete it.
    private static func date(of url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? Date()
    }
}
