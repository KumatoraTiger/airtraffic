import AirtrafficCore
import Foundation
import SwiftUI

/// A single chat entry in the prioritization panel.
struct ChatEntry: Identifiable, Hashable {
    enum Sender { case user, assistant }
    let id = UUID()
    var sender: Sender
    var text: String
    var proposal: [String]?  // ranking proposal (task ids), if the reply had one
}

@Observable
@MainActor
final class AppModel {
    // MARK: - State

    var sessions: [SessionSnapshot] = []
    var tasks: [TaskItem] = []
    /// LLM-generated work labels ("レビュー: …") by session id.
    var labels: [String: WorkLabel] = [:]
    var candidates: [Candidate] = []
    /// Recently rejected or expired proposals, revertable from the board.
    var closedCandidates: [Candidate] = []
    var preferences: [PreferenceNote] = []
    var chatEntries: [ChatEntry] = []
    var chatBusy = false
    var lastError: String?
    var extractionEnabled: Bool {
        didSet { UserDefaults.standard.set(extractionEnabled, forKey: "extractionEnabled") }
    }
    var selectedProvider: ProviderKind {
        didSet { UserDefaults.standard.set(selectedProvider.rawValue, forKey: "provider") }
    }
    var models: [ProviderKind: String] {
        didSet {
            for (kind, model) in models {
                UserDefaults.standard.set(model, forKey: "model.\(kind.rawValue)")
            }
        }
    }

    /// Entries with an execution waiting on the user, among what the live
    /// sections show. Status never moves a row anymore; this only feeds the
    /// lane badges and the menu bar.
    var waitingEntries: [BoardEntry] {
        boardEntries.filter { entry in
            guard entry.liveStatus?.needsAttention == true else { return false }
            if let task = entry.task { return task.status != .done }
            return entry.isRecent()
        }
    }
    var waitingCount: Int { waitingEntries.count }

    /// Unified board rows: tasks with their executions attached, plus session
    /// activity that matches no task, materialized as its own rows. Done tasks
    /// are included (with their linked sessions); the view puts them in 完了.
    var boardEntries: [BoardEntry] {
        BoardAssembler.assemble(tasks: tasks, sessions: sessions, labels: labels)
    }

    /// Proposals that expired untouched; shown inside 完了.
    var expiredCandidates: [Candidate] { closedCandidates.filter { $0.status == .expired } }
    /// Proposals the user rejected; shown inside キャンセル.
    var rejectedCandidates: [Candidate] { closedCandidates.filter { $0.status == .rejected } }

    // MARK: - Internals

    private let store: Store?
    private let coordinator: IngestionCoordinator
    private let extractor = TaskExtractor()
    private let labeler = SessionLabeler()
    private let prioritizer = Prioritizer()
    /// Transcript text accumulated per session since the last extraction pass.
    private var pendingText: [String: (title: String, agent: AgentKind, text: String)] = [:]
    private var scanTask: Task<Void, Never>?
    private var lastExtraction = Date.distantPast
    private var lastExpiry = Date.distantPast

    init() {
        extractionEnabled = UserDefaults.standard.object(forKey: "extractionEnabled") as? Bool ?? false
        selectedProvider =
            ProviderKind(
                rawValue: UserDefaults.standard.string(forKey: "provider") ?? "") ?? .gemini
        var models: [ProviderKind: String] = [:]
        for kind in ProviderKind.allCases {
            models[kind] =
                UserDefaults.standard.string(forKey: "model.\(kind.rawValue)")
                ?? kind.defaultModel
        }
        self.models = models
        store = try? Store(path: Store.defaultPath())
        coordinator = .standard()
    }

    func start() {
        guard scanTask == nil else { return }
        scanTask = Task { [weak self] in
            await self?.refreshFromStore()
            while !Task.isCancelled {
                await self?.scanOnce()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    // MARK: - Scan loop

    private func scanOnce() async {
        let snapshots = await coordinator.scan()
        sessions = snapshots
        for snapshot in snapshots where !snapshot.newTranscriptText.isEmpty {
            var entry =
                pendingText[snapshot.id]
                ?? (title: snapshot.title, agent: snapshot.agent, text: "")
            entry.text += snapshot.newTranscriptText
            entry.title = snapshot.title
            pendingText[snapshot.id] = entry
        }
        if extractionEnabled, Date().timeIntervalSince(lastExtraction) > 60 {
            lastExtraction = Date()
            await runExtractionPass()
            await runLabelPass()
        }
        // Untouched proposals leave the board on their own; sweep periodically
        // so this happens while the app stays open, not only at launch.
        if Date().timeIntervalSince(lastExpiry) > 900 {
            lastExpiry = Date()
            if let store {
                try? await store.expireCandidates(olderThan: 72 * 3600)
                candidates = (try? await store.candidates()) ?? []
                closedCandidates = (try? await store.closedCandidates()) ?? []
            }
        }
    }

    private func refreshFromStore() async {
        guard let store else { return }
        try? await store.expireCandidates(olderThan: 72 * 3600)
        try? await store.pruneLabels(olderThan: 30 * 24 * 3600)
        labels = (try? await store.labels()) ?? [:]
        tasks = (try? await store.tasks()) ?? []
        candidates = (try? await store.candidates()) ?? []
        closedCandidates = (try? await store.closedCandidates()) ?? []
        preferences = (try? await store.preferences()) ?? []
    }

    // MARK: - LLM plumbing

    func makeClient() throws -> any LLMClient {
        guard let key = KeychainStore.resolveAPIKey(for: selectedProvider) else {
            throw LLMError.missingAPIKey(selectedProvider)
        }
        return LLMClientFactory.make(
            kind: selectedProvider, apiKey: key,
            model: models[selectedProvider] ?? selectedProvider.defaultModel)
    }

    func testConnection(_ kind: ProviderKind) async -> String {
        guard let key = KeychainStore.resolveAPIKey(for: kind) else {
            return "キー未設定"
        }
        let client = LLMClientFactory.make(
            kind: kind, apiKey: key, model: models[kind] ?? kind.defaultModel)
        do {
            _ = try await client.complete(
                LLMRequest(
                    messages: [ChatMessage(role: .user, text: "OK とだけ返答してください")],
                    maxTokens: 16))
            return "接続 OK"
        } catch {
            return "失敗: \(error)"
        }
    }

    // MARK: - Extraction (board proposals)

    private func runExtractionPass() async {
        guard let store, let client = try? makeClient() else { return }
        let pending = pendingText
        pendingText = [:]
        // Archived tasks and already-handled candidates count as known: the
        // point is to never surface something the user has seen before.
        var known = TaskExtractor.KnownTitles(
            tasks: ((try? await store.tasks(includeArchived: true)) ?? []).map(\.title),
            pendingCandidates: candidates.map(\.title),
            rejected: (try? await store.rejectedTitles()) ?? [],
            otherSeen: (try? await store.knownCandidateTitles()) ?? []
        )

        for (sessionId, entry) in pending {
            guard
                let extractions = try? await extractor.extract(
                    client: client, newText: entry.text, sessionTitle: entry.title, known: known
                )
            else { continue }
            for extraction in extractions {
                let candidate = Candidate(
                    id: UUID().uuidString,
                    title: extraction.title,
                    detail: extraction.detail,
                    confidence: extraction.confidence,
                    sessionId: sessionId,
                    agent: entry.agent,
                    excerpt: extraction.excerpt,
                    status: .pending,
                    createdAt: Date(),
                    rejectReason: nil
                )
                _ = try? await store.insertCandidate(candidate)
                // Sessions later in this pass see it in their prompt too.
                known.pendingCandidates.append(extraction.title)
            }
        }
        candidates = (try? await store.candidates()) ?? []
    }

    /// Labels sessions whose work label is missing or stale, a bounded batch
    /// per pass. Failures cost nothing: unlabeled rows keep their fallback
    /// titles and the next pass tries again.
    private func runLabelPass() async {
        guard let store, let client = try? makeClient() else { return }
        let targets = labeler.sessionsNeedingLabels(sessions, labels: labels)
        guard !targets.isEmpty,
            let fresh = try? await labeler.label(client: client, sessions: targets)
        else { return }
        for label in fresh {
            try? await store.upsertLabel(label)
        }
        // Sessions the LLM saw but could not classify get a placeholder, so
        // the next pass spends its budget on new sessions instead of them.
        let labeled = Set(fresh.map(\.sessionId))
        for session in targets where !labeled.contains(session.id) {
            try? await store.upsertLabel(
                WorkLabel(
                    sessionId: session.id, kind: .other, subject: "",
                    updatedAt: Date(), labeledActivity: session.lastActivity))
        }
        labels = (try? await store.labels()) ?? labels
    }

    // MARK: - Proposal actions

    /// Keeps a proposal as a persistent task. Nothing requires this: proposals
    /// left alone simply expire off the board.
    func keep(_ candidate: Candidate) async {
        guard let store else { return }
        let task = TaskItem(
            id: UUID().uuidString, title: candidate.title, detail: candidate.detail,
            status: .todo, rank: nil, source: .llm,
            createdAt: Date(), updatedAt: Date(), sessionIds: [candidate.sessionId])
        try? await store.upsertTask(task)
        try? await store.setCandidateStatus(candidate.id, .accepted)
        await refreshLists()
    }

    func reject(_ candidate: Candidate, reason: String?) async {
        guard let store else { return }
        try? await store.setCandidateStatus(candidate.id, .rejected, rejectReason: reason)
        await refreshLists()
    }

    /// Brings a rejected or expired proposal back onto the board.
    func reopen(_ candidate: Candidate) async {
        guard let store else { return }
        try? await store.reopenCandidate(candidate.id)
        await refreshLists()
    }

    // MARK: - Task actions

    func addManualTask(title: String) async {
        guard let store, !title.isEmpty else { return }
        let task = TaskItem(
            id: UUID().uuidString, title: title, detail: "", status: .todo, rank: nil,
            source: .manual, createdAt: Date(), updatedAt: Date(), sessionIds: [])
        try? await store.upsertTask(task)
        await refreshLists()
    }

    func setTaskStatus(_ task: TaskItem, _ status: TaskStatus) async {
        guard let store else { return }
        var updated = task
        updated.status = status
        updated.updatedAt = Date()
        try? await store.upsertTask(updated)
        await refreshLists()
    }

    /// Persists an auto-materialized entry as a task, so it survives its
    /// sessions going quiet. Also the way an aged-out entry is brought back
    /// from the 完了 section.
    func keepEntry(_ entry: BoardEntry) async {
        guard let store, entry.task == nil, !entry.sessions.isEmpty else { return }
        let task = TaskItem(
            id: UUID().uuidString, title: entry.title, detail: "",
            status: entry.isLive ? .inProgress : .todo, rank: nil,
            source: .deterministic, createdAt: Date(), updatedAt: Date(),
            sessionIds: entry.sessions.map(\.id))
        try? await store.upsertTask(task)
        await refreshLists()
    }

    /// Ties a taskless entry's sessions to an existing task. The entry's row
    /// disappears into the task, which shows them as its executions from then
    /// on — and keeps them until the task itself is done.
    func linkEntry(_ entry: BoardEntry, to task: TaskItem) async {
        guard let store, entry.task == nil, !entry.sessions.isEmpty else { return }
        var updated = task
        updated.sessionIds.append(contentsOf: entry.sessions.map(\.id))
        updated.updatedAt = Date()
        try? await store.upsertTask(updated)
        await refreshLists()
    }

    /// Promote a session's in-transcript todo into a global task.
    func promoteTodo(_ todo: TodoItem, from session: SessionSnapshot) async {
        guard let store else { return }
        let task = TaskItem(
            id: UUID().uuidString, title: todo.content,
            detail: "セッション「\(session.title)」の todo から昇格",
            status: todo.status == .completed ? .done : .todo, rank: nil,
            source: .deterministic, createdAt: Date(), updatedAt: Date(),
            sessionIds: [session.id])
        try? await store.upsertTask(task)
        await refreshLists()
    }

    /// Manual reorder of the tasks visible in one list. Offsets are relative
    /// to `visibleIds` (the list the user actually dragged in), not to the
    /// full task array. The move itself is recorded as a preference so future
    /// AI proposals learn from it.
    func moveTask(in visibleIds: [String], fromOffsets: IndexSet, toOffset: Int) async {
        guard let store else { return }
        var reordered = visibleIds
        reordered.move(fromOffsets: fromOffsets, toOffset: toOffset)
        try? await store.setRanks(reordered)
        if let index = fromOffsets.first, index < visibleIds.count,
            let moved = tasks.first(where: { $0.id == visibleIds[index] })
        {
            let direction = toOffset <= index ? "上げた" : "下げた"
            try? await store.insertPreference(
                "ユーザーは「\(moved.title)」の優先度を手動で\(direction)")
        }
        await refreshLists()
    }

    private func refreshLists() async {
        guard let store else { return }
        tasks = (try? await store.tasks()) ?? []
        candidates = (try? await store.candidates()) ?? []
        closedCandidates = (try? await store.closedCandidates()) ?? []
        preferences = (try? await store.preferences()) ?? []
    }

    // MARK: - Prioritization chat

    func sendChat(_ text: String) async {
        guard !text.isEmpty, !chatBusy else { return }
        chatEntries.append(ChatEntry(sender: .user, text: text, proposal: nil))
        chatBusy = true
        defer { chatBusy = false }
        do {
            let client = try makeClient()
            let system = prioritizer.systemPrompt(
                tasks: tasks, sessions: sessions, preferences: preferences)
            let history = chatEntries.map { entry in
                ChatMessage(role: entry.sender == .user ? .user : .assistant, text: entry.text)
            }
            let reply = try await client.complete(
                LLMRequest(
                    system: system, messages: history, maxTokens: 4096))
            let proposal = prioritizer.parseRanking(from: reply)
            chatEntries.append(
                ChatEntry(
                    sender: .assistant,
                    text: prioritizer.displayText(from: reply),
                    proposal: proposal?.orderedTaskIds))
        } catch {
            lastError = "\(error)"
            chatEntries.append(
                ChatEntry(
                    sender: .assistant, text: "エラー: \(error)", proposal: nil))
        }
    }

    func applyRanking(_ orderedTaskIds: [String]) async {
        guard let store else { return }
        let known = Set(tasks.map(\.id))
        let valid = orderedTaskIds.filter { known.contains($0) }
        guard !valid.isEmpty else { return }
        try? await store.setRanks(valid)
        await refreshLists()
    }
}
