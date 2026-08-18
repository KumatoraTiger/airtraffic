import AirtrafficCore
import SwiftUI

/// The unified board: a priority-ordered task list with execution state
/// attached. Session status only paints badges on rows; it never moves a row
/// between sections. Sections, in the order the user should spend attention:
///
/// - タスク: the priority list itself — every open task, in rank order,
///   with its linked sessions hanging under it as a tree
/// - 提案: LLM-extracted candidates; optional, expire untouched
/// - タスク外の動き: agent activity matching no task, active within 24 hours
/// - 完了: done tasks (with their sessions), aged-out activity, expired proposals
/// - キャンセル: rejected proposals
struct BoardView: View {
    @Environment(AppModel.self) private var model
    @State private var newTitle = ""
    @State private var showDone = false
    @State private var showCancelled = false
    @State private var showAllProposals = false

    /// Proposals shown before the fold. Enough to notice fresh ones without
    /// burying the sections below.
    private static let proposalFold = 3

    var body: some View {
        List {
            if model.boardEntries.isEmpty && model.candidates.isEmpty {
                ContentUnavailableView(
                    "まだ何も映っていません",
                    systemImage: "airplane.departure",
                    description: Text("coding agent のセッションが動き出すと、ここに映ります"))
            }
            taskSection
            proposalSection
            entrySection(
                activity, title: "タスク外の動き", symbol: "antenna.radiowaves.left.and.right",
                color: .gray)
            doneSection
            cancelledSection
        }
    }

    // MARK: - Row selection

    /// The priority list: every open task in rank order (as the store returns
    /// them). Waiting or running executions are badges on the row, never a
    /// reason to move it.
    private var taskEntries: [BoardEntry] {
        model.boardEntries.filter { entry in
            guard let task = entry.task else { return false }
            return task.status != .done
        }
    }

    /// Agent activity matching no task, active within the last 24 hours,
    /// newest first. Rows here can be promoted to a task or linked to one.
    private var activity: [BoardEntry] {
        model.boardEntries
            .filter { $0.task == nil && $0.isRecent() }
            .sorted { ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast) }
    }

    /// Taskless activity that aged past the 24-hour window: treated as
    /// finished, still revertable via 「タスクにする」.
    private var agedOut: [BoardEntry] {
        model.boardEntries.filter { $0.task == nil && !$0.isRecent() }
    }

    /// Done tasks, newest completion first. Their linked sessions stay
    /// attached, so completing a task takes its whole tree along.
    private var doneEntries: [BoardEntry] {
        Array(
            model.boardEntries
                .filter { $0.task?.status == .done }
                .sorted { ($0.task?.updatedAt ?? .distantPast) > ($1.task?.updatedAt ?? .distantPast) }
                .prefix(10))
    }

    // MARK: - Sections

    @ViewBuilder
    private func entrySection(
        _ entries: [BoardEntry], title: String, symbol: String, color: Color
    ) -> some View {
        if !entries.isEmpty {
            Section {
                ForEach(entries) { entry in
                    EntryRow(entry: entry)
                }
            } header: {
                Label("\(title) (\(entries.count))", systemImage: symbol)
                    .foregroundStyle(color)
            }
        }
    }

    @ViewBuilder
    private var proposalSection: some View {
        if !model.candidates.isEmpty {
            let visible =
                showAllProposals
                ? model.candidates : Array(model.candidates.prefix(Self.proposalFold))
            Section {
                ForEach(visible) { candidate in
                    ProposalRow(candidate: candidate)
                }
            } header: {
                HStack {
                    Label("提案 (\(model.candidates.count))", systemImage: "sparkles")
                        .foregroundStyle(.purple)
                    Spacer()
                    if model.candidates.count > Self.proposalFold {
                        Button(showAllProposals ? "折りたたむ" : "すべて表示") {
                            withAnimation { showAllProposals.toggle() }
                        }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(.purple)
                    }
                }
            }
        }
    }

    private var taskSection: some View {
        Section {
            ForEach(taskEntries) { entry in
                EntryRow(entry: entry)
            }
            .onMove { indices, offset in
                let ids = taskEntries.compactMap { $0.task?.id }
                Task { await model.moveTask(in: ids, fromOffsets: indices, toOffset: offset) }
            }
            HStack {
                TextField("タスクを追加…", text: $newTitle)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { submit() }
                Button("追加") { submit() }
                    .disabled(newTitle.isEmpty)
            }
            .padding(.vertical, 2)
        } header: {
            HStack {
                Label("タスク (\(taskEntries.count))", systemImage: "checklist")
                    .foregroundStyle(.blue)
                Spacer()
                Text("上が高優先・ドラッグで並べ替え")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Finished work, brought back with one click: done tasks (their sessions
    /// still attached) via the checkmark, aged-out activity via 「タスクにする」,
    /// expired proposals via 「戻す」.
    @ViewBuilder
    private var doneSection: some View {
        let count = doneEntries.count + agedOut.count + model.expiredCandidates.count
        if count > 0 {
            Section {
                if showDone {
                    ForEach(doneEntries) { entry in
                        EntryRow(entry: entry)
                    }
                    ForEach(agedOut) { entry in
                        EntryRow(entry: entry)
                    }
                    ForEach(model.expiredCandidates) { candidate in
                        ClosedProposalRow(candidate: candidate)
                    }
                }
            } header: {
                collapsibleHeader(
                    "完了 (\(count))", symbol: "checkmark.circle", expanded: $showDone)
            }
        }
    }

    /// Rejected proposals live apart from 完了: the user turned these down,
    /// nothing here finished.
    @ViewBuilder
    private var cancelledSection: some View {
        if !model.rejectedCandidates.isEmpty {
            Section {
                if showCancelled {
                    ForEach(model.rejectedCandidates) { candidate in
                        ClosedProposalRow(candidate: candidate)
                    }
                }
            } header: {
                collapsibleHeader(
                    "キャンセル (\(model.rejectedCandidates.count))",
                    symbol: "xmark.circle", expanded: $showCancelled)
            }
        }
    }

    private func collapsibleHeader(
        _ title: String, symbol: String, expanded: Binding<Bool>
    ) -> some View {
        Button {
            withAnimation { expanded.wrappedValue.toggle() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: expanded.wrappedValue ? "chevron.down" : "chevron.right")
                    .font(.caption2)
                Label(title, systemImage: symbol)
            }
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
    }

    private func submit() {
        let title = newTitle
        newTitle = ""
        Task { await model.addManualTask(title: title) }
    }
}

// MARK: - Proposal rows

/// An AI proposal. Deliberately quieter than a work row: acting on it is
/// optional, and untouched proposals expire on their own.
struct ProposalRow: View {
    @Environment(AppModel.self) private var model
    let candidate: Candidate
    @State private var expanded = false
    @State private var showRejectReason = false
    @State private var rejectReason = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.caption)
                    .foregroundStyle(.purple)
                Text(candidate.title)
                    .font(.callout)
                    .lineLimit(expanded ? nil : 1)
                Spacer()
                confidenceBadge
                Button("タスクにする") {
                    Task { await model.keep(candidate) }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("タスクにする（しなければ数日で自動的に消えます）")
                rejectMenu
            }
            if expanded {
                if !candidate.detail.isEmpty {
                    Text(candidate.detail).font(.caption)
                }
                if !candidate.excerpt.isEmpty {
                    Text("「\(candidate.excerpt)」")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                HStack {
                    Label(candidate.agent.displayName, systemImage: candidate.agent.symbol)
                    if let origin = originTitle {
                        Text("出所: \(origin)")
                    }
                    Text(candidate.createdAt, style: .relative)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .opacity(0.9)
        .contentShape(Rectangle())
        .onTapGesture { withAnimation { expanded.toggle() } }
        .popover(isPresented: $showRejectReason) {
            VStack(alignment: .leading, spacing: 8) {
                Text("却下理由（任意・今後の抽出精度に使われます）")
                    .font(.caption)
                TextField("例: 既に完了している / タスクではない", text: $rejectReason)
                    .frame(width: 320)
                HStack {
                    Spacer()
                    Button("却下する") {
                        showRejectReason = false
                        Task {
                            await model.reject(
                                candidate,
                                reason: rejectReason.isEmpty ? nil : rejectReason)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding()
        }
    }

    /// Title of the session this proposal was extracted from, when it is
    /// still around.
    private var originTitle: String? {
        model.sessions.first { $0.id == candidate.sessionId }?.title
    }

    /// Reject reasons are one click each; free text stays available under 「その他…」.
    private var rejectMenu: some View {
        Menu {
            ForEach(RejectReasonPreset.allCases) { preset in
                Button {
                    Task { await model.reject(candidate, reason: preset.rawValue) }
                } label: {
                    Label(preset.label, systemImage: preset.symbol)
                }
            }
            Divider()
            Button("理由なしで却下") {
                Task { await model.reject(candidate, reason: nil) }
            }
            Button("その他…") {
                rejectReason = ""
                showRejectReason = true
            }
        } label: {
            Text("却下")
        }
        .menuStyle(.borderlessButton)
        .controlSize(.small)
        .fixedSize()
    }

    private var confidenceBadge: some View {
        let percent = Int(candidate.confidence * 100)
        return Text("提案 \(percent)%")
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.purple.opacity(0.12), in: Capsule())
            .foregroundStyle(.purple)
    }
}

/// A proposal that already left the board, with the way back.
struct ClosedProposalRow: View {
    @Environment(AppModel.self) private var model
    let candidate: Candidate

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: candidate.status == .rejected ? "xmark.circle" : "hourglass")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(candidate.title)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Text(closedLabel)
                    if let closedAt = candidate.closedAt {
                        Text(closedAt, style: .relative)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
            Spacer()
            Button("戻す") {
                Task { await model.reopen(candidate) }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.vertical, 2)
    }

    private var closedLabel: String {
        switch candidate.status {
        case .rejected:
            if let reason = candidate.rejectReason, !reason.isEmpty {
                return "却下: \(reason)"
            }
            return "却下"
        case .expired:
            return "期限切れで自動的に消えました"
        default:
            return candidate.status.rawValue
        }
    }
}
