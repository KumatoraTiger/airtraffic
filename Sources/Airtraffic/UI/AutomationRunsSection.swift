import AirtrafficCore
import AppKit
import SwiftUI

/// The board's 自動実行 section: what the per-task command is doing in the
/// background right now, and what it did over the last day.
///
/// One row per run. The leading symbol answers the only question that
/// matters at a glance — running, done, or failed — and the rest of the row
/// says what fired it (a new row, or a bot's review), on which pull request,
/// how long ago, and why it failed when it did. Kept above the task list on
/// purpose: an agent working unattended on the user's behalf is the thing
/// they most want to know about when they glance at the window.
struct AutomationRunsSection: View {
    @Environment(AppModel.self) private var model

    /// How many finished runs stay listed. Running ones always show.
    private static let finishedLimit = 8

    var body: some View {
        if !runs.isEmpty {
            Section {
                ForEach(runs) { run in
                    AutomationRunRow(run: run)
                }
            } header: {
                HStack {
                    Label(headerTitle, systemImage: "gearshape.2")
                        .foregroundStyle(runningCount > 0 ? .purple : .secondary)
                    Spacer()
                    Text("GitHub のイベントで動いたエージェント")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Running runs first, then the newest finished ones from the last day.
    private var runs: [AutomationRun] {
        let displayed = model.automationRuns.filter { $0.isDisplayed() }
        let running = displayed.filter { $0.state == .running }
        let finished = displayed.filter { $0.state != .running }.prefix(Self.finishedLimit)
        return running + finished
    }

    private var runningCount: Int { runs.filter { $0.state == .running }.count }

    private var headerTitle: String {
        runningCount > 0 ? "自動実行 (\(runningCount) 件 実行中)" : "自動実行 (\(runs.count))"
    }
}

/// One run of the per-task command.
struct AutomationRunRow: View {
    @Environment(AppModel.self) private var model
    let run: AutomationRun

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                stateSymbol
                triggerBadge
                Text(run.title)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .layoutPriority(1)
                if let url = run.url.flatMap(URL.init(string:)) {
                    Image(systemName: "arrow.up.right.square")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .instantClick("GitHub で開く") { NSWorkspace.shared.open(url) }
                        .help("GitHub で開く")
                }
                Spacer()
                timing
                if let path = run.artifactPath {
                    Image(systemName: "folder")
                        .font(.caption2)
                        .foregroundStyle(.green)
                        .instantClick("生成物のフォルダを開く") { revealArtifact(path) }
                        .help("生成物のフォルダを開く")
                }
            }
            // The reason gets its own line: sharing the first one with the
            // title meant one of the two was always cut short.
            if run.state == .failed, let reason = run.reason {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                        .help(reason)
                }
                .padding(.leading, 2)
            }
        }
        .padding(.vertical, 3)
        .contextMenu {
            if run.state != .running, taskOnBoard {
                Button("もう一度動けるようにする") {
                    Task { await model.resetAutomation(taskId: run.taskId) }
                }
            }
        }
    }

    /// Running, done, or failed — the one thing to read at a glance.
    @ViewBuilder
    private var stateSymbol: some View {
        switch run.state {
        case .running:
            ProgressView()
                .controlSize(.mini)
                .help("実行中")
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .help("生成物を残して終わりました")
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .help(run.reason ?? "失敗しました")
        }
    }

    /// What fired the command: a new row, or the named bot's review. The
    /// `[bot]` suffix goes, since every login here has it, and a long login
    /// is shortened so it cannot push the title off the row.
    private var triggerBadge: some View {
        let text =
            switch run.trigger {
            case .arrival: run.trigger.displayName
            case .comment: run.author.map { "\(Self.botName($0)) のレビュー" } ?? run.trigger.displayName
            }
        let color: Color = run.trigger == .comment ? .orange : .blue
        return Text(text)
            .font(.caption2.bold())
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
            .help(run.author.map { "\($0) のレビューコメントで起動" } ?? "新しく届いた行で起動")
    }

    /// `coderabbitai[bot]` → `coderabbitai`; a login longer than 18
    /// characters keeps its head and tail around an ellipsis.
    static func botName(_ login: String) -> String {
        let name = login.hasSuffix("[bot]") ? String(login.dropLast(5)) : login
        guard name.count > 18 else { return name }
        return "\(name.prefix(9))…\(name.suffix(8))"
    }

    /// Elapsed time while running, the finish time otherwise.
    @ViewBuilder
    private var timing: some View {
        switch run.state {
        case .running:
            HStack(spacing: 3) {
                Text("開始")
                Text(run.startedAt, style: .relative)
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        case .failed, .done:
            finishedAt
        }
    }

    @ViewBuilder
    private var finishedAt: some View {
        if let finishedAt = run.finishedAt {
            Text(finishedAt, format: .dateTime.hour().minute())
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
                .help("終了 \(finishedAt.formatted(date: .abbreviated, time: .shortened))")
        }
    }

    /// Whether the run's task still exists to be reset: a row the sync
    /// removed has nothing to run again.
    private var taskOnBoard: Bool {
        model.tasks.contains { $0.id == run.taskId }
    }
}
