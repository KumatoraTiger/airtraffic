import Foundation

/// The rules behind "an issue got one of the labels I chose, run the command
/// that label stands for".
///
/// The third trigger, next to the arrival one ([[TaskAutomation.plan]]) and
/// the review-comment one ([[CommentTrigger]]). It exists for the case the
/// other two cannot express: the user reads an issue, decides an agent should
/// do something with it, and says which job by putting a label on it.
/// Labelling is the deliberate act, so the app needs no other signal.
///
/// The user names as many labels as they have jobs, each carrying its own
/// command line ([[LabelRule]]) — `improve` for an issue that needs
/// sharpening, `implement` for one ready to be written. An issue wearing two
/// of them runs the first rule in the list, because a row runs once.
///
/// Pure like the other two: which rows qualify is decided without touching
/// the network, the store, or a process.
public enum LabelTrigger {
    /// How many commands one pass may start. The same bound as the comment
    /// trigger's, and for the same reason: labelling five issues at once must
    /// not start five coding agents at once.
    public static let runLimit = 3

    /// A task and the rule that picked it up. The rule travels with the task
    /// because it names the command to run, which now differs per label.
    public struct Match: Sendable, Equatable {
        public var task: TaskItem
        public var rule: LabelRule

        public init(task: TaskItem, rule: LabelRule) {
            self.task = task
            self.rule = rule
        }
    }

    /// Whether an item's labels include the one named.
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

    /// The first rule an issue's labels satisfy, or nil when they satisfy
    /// none.
    ///
    /// First, not "best": a row runs once, so two labels on one issue have to
    /// be resolved somehow, and the order the user wrote the rules in is the
    /// one thing they can see and change. A rule missing its label or its
    /// command is skipped rather than matched — half a rule fires nothing.
    public static func rule(labels: [String], rules: [LabelRule]) -> LabelRule? {
        rules.first { rule in
            rule.isUsable && matches(labels: labels, label: rule.label)
        }
    }

    /// The tasks whose label command should run now, each with the rule that
    /// says which command that is.
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
    /// That also means adding a second label to an issue one rule already ran
    /// for changes nothing until the row is reset.
    public static func plan(
        tasks: [TaskItem], labels: [String: [String]], settings: AutomationSettings,
        limit: Int = runLimit
    ) -> [Match] {
        guard settings.enabled, settings.labelTrigger else { return [] }
        let rules = settings.labelRules
        // `rule(labels:rules:)` skips the unusable ones; this only avoids
        // walking every task when none of them can run.
        guard rules.contains(where: \.isUsable) else { return [] }
        return Array(
            tasks.compactMap { task -> Match? in
                guard task.source == .github, task.automationState == nil else { return nil }
                guard task.status != .archived, task.status != .done else { return nil }
                // Only issues assigned to the user: the label is read off the
                // assigned search, and that is the only search this app asks
                // labels for.
                guard GitHubTaskSync.relation(fromDetail: task.detail) == .assigned else {
                    return nil
                }
                guard let reference = GitHubItem.reference(taskId: task.id) else { return nil }
                guard settings.allowedRepos.contains(reference.repo) else { return nil }
                guard let rule = rule(labels: labels[task.id] ?? [], rules: rules) else {
                    return nil
                }
                return Match(task: task, rule: rule)
            }
            .prefix(limit))
    }
}
