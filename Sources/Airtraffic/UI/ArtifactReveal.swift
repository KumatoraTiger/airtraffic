import AppKit
import Foundation

/// Opens the Finder on what a per-task command wrote, with the newest page
/// selected. A command is free to write several files (a short version and a
/// long one, say), and choosing among them for the user was guesswork, so the
/// directory is what opens and the newest `.html` is what sits under the
/// cursor. A path left by an earlier build names one file, which the same call
/// reveals just as well.
func revealArtifact(_ path: String) {
    let url = URL(fileURLWithPath: path)
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return }
    guard isDirectory.boolValue else {
        NSWorkspace.shared.activateFileViewerSelecting([url])
        return
    }
    let contents =
        (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
    let pages = contents.filter { $0.pathExtension.lowercased() == "html" }
    let newest = (pages.isEmpty ? contents : pages).max { left, right in
        modificationDate(left) < modificationDate(right)
    }
    if let newest {
        NSWorkspace.shared.activateFileViewerSelecting([newest])
    } else {
        NSWorkspace.shared.open(url)
    }
}

private func modificationDate(_ url: URL) -> Date {
    (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        ?? .distantPast
}
