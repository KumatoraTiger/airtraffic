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
/// sharpening, `implement` for one ready to be written. Each rule runs once
/// per issue, so the two labels are two jobs whether they arrive together or
/// weeks apart; an issue wearing both at once runs the first rule in the list
/// now and the second on the next pass.
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

    /// The first rule an issue's labels satisfy and whose command has not run
    /// for it yet, or nil when there is none.
    ///
    /// First, not "best": one pass starts one command per row, so two fresh
    /// labels on one issue have to be resolved somehow, and the order the
    /// user wrote the rules in is the one thing they can see and change. The
    /// other one is picked up by the next pass. A rule missing its label or
    /// its command is skipped rather than matched — half a rule fires
    /// nothing.
    ///
    /// `ran` is the labels this row already ran, compared the same way the
    /// labels themselves are.
    public static func rule(labels: [String], rules: [LabelRule], ran: [String] = []) -> LabelRule? {
        rules.first { rule in
            rule.isUsable && matches(labels: labels, label: rule.label)
                && !matches(labels: ran, label: rule.label)
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
    /// Each RULE qualifies once per row, and `automationLabels` is what says
    /// which ones are spent — failures included, so running the same label
    /// again needs the board's 「もう一度動けるようにする」 like the other
    /// triggers. Labelling an issue `improve` and, once that has run,
    /// `implement`, therefore runs both: the second label is a second job,
    /// not a repeat of the first. (Until 2026-09-10 the row's
    /// `automationState` held it back, so the second label did nothing.)
    ///
    /// `automationState` still matters in one way: a row whose command is
    /// running is left alone, because one row runs one command at a time.
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
                guard task.source == .github, task.automationState != .running else { return nil }
                guard task.status != .archived, task.status != .done else { return nil }
                // Only issues assigned to the user: the label is read off the
                // assigned search, and that is the only search this app asks
                // labels for.
                guard GitHubTaskSync.relation(fromDetail: task.detail) == .assigned else {
                    return nil
                }
                guard let reference = GitHubItem.reference(taskId: task.id) else { return nil }
                guard settings.allowedRepos.contains(reference.repo) else { return nil }
                guard
                    let rule = rule(
                        labels: labels[task.id] ?? [], rules: rules, ran: task.automationLabels)
                else { return nil }
                return Match(task: task, rule: rule)
            }
            .prefix(limit))
    }
}
