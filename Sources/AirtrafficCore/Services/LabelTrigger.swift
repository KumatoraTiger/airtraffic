import Foundation

/// The rules behind "an issue got the label I chose, run my command".
///
/// The third trigger, next to the arrival one ([[TaskAutomation.plan]]) and
/// the review-comment one ([[CommentTrigger]]). It exists for the case the
/// other two cannot express: the user reads an issue, decides an agent should
/// implement it, and says so by putting a label on it. Labelling is the
/// deliberate act, so the app needs no other signal.
///
/// Pure like the other two: which rows qualify is decided without touching
/// the network, the store, or a process.
public enum LabelTrigger {
    /// How many commands one pass may start. The same bound as the comment
    /// trigger's, and for the same reason: labelling five issues at once must
    /// not start five coding agents at once.
    public static let runLimit = 3

    /// Whether an item's labels include the one the user named.
    ///
    /// Compared case-insensitively and without surrounding spaces, because
    /// the setting is typed by hand while the label comes from GitHub.
    public static func matches(labels: [String], label: String) -> Bool {
        let wanted = label.trimmingCharacters(in: .whitespaces)
        guard !wanted.isEmpty else { return false }
        return labels.contains { name in
            name.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(wanted)
                == .orderedSame
        }
    }

    /// The tasks whose label command should run now.
    ///
    /// `labels` maps a task id to the label names of the issue behind it, as
    /// the last GitHub pass read them. A task missing from the map is a task
    /// nothing is known about this pass, and nothing is started for it: a
    /// label that could not be read must never look like a label that is
    /// there.
    ///
    /// A row qualifies once. `automationState` is what stops the next pass
    /// from running the same command again, failures included, so a second
    /// run needs the board's 「もう一度動けるようにする」 like the other triggers.
    public static func plan(
        tasks: [TaskItem], labels: [String: [String]], settings: AutomationSettings,
        limit: Int = runLimit
    ) -> [TaskItem] {
        guard settings.enabled, settings.labelTrigger else { return [] }
        guard !settings.label.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        guard !TaskAutomation.tokenize(settings.labelCommandLine).isEmpty else { return [] }
        return Array(
            tasks.filter { task in
                guard task.source == .github, task.automationState == nil else { return false }
                guard task.status != .archived, task.status != .done else { return false }
                // Only issues assigned to the user: the label is read off the
                // assigned search, and that is the only search this app asks
                // labels for.
                guard GitHubTaskSync.relation(fromDetail: task.detail) == .assigned else {
                    return false
                }
                guard let reference = GitHubItem.reference(taskId: task.id) else { return false }
                guard settings.allowedRepos.contains(reference.repo) else { return false }
                return matches(labels: labels[task.id] ?? [], label: settings.label)
            }
            .prefix(limit))
    }
}
