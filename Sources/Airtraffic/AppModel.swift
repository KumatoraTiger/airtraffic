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
    var preferences: [PreferenceNote] = []
    var chatEntries: [ChatEntry] = []
    var chatBusy = false
    var lastError: String?
    var labelingEnabled: Bool {
        didSet { UserDefaults.standard.set(labelingEnabled, forKey: "labelingEnabled") }
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

    // MARK: - Internals

    private let store: Store?
    private let coordinator: IngestionCoordinator
    private let labeler = SessionLabeler()
    private let prioritizer = Prioritizer()
    private var scanTask: Task<Void, Never>?
    private var lastLabelPass = Date.distantPast

    init() {
        // The key was "extractionEnabled" while the toggle also covered the
        // removed LLM-proposal feature; carry the old value over once.
        labelingEnabled =
            UserDefaults.standard.object(forKey: "labelingEnabled") as? Bool
            ?? UserDefaults.standard.object(forKey: "extractionEnabled") as? Bool ?? false
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
        sessions = await coordinator.scan()
        if labelingEnabled, Date().timeIntervalSince(lastLabelPass) > 60 {
            lastLabelPass = Date()
            await runLabelPass()
        }
    }

    private func refreshFromStore() async {
        guard let store else { return }
        try? await store.pruneLabels(olderThan: 30 * 24 * 3600)
        labels = (try? await store.labels()) ?? [:]
        tasks = (try? await store.tasks()) ?? []
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

    // MARK: - Task actions

    func addManualTask(title: String) async {
        guard let store, !title.isEmpty else { return }
        let task = TaskItem(
            id: UUID().uuidString, title: title, detail: "", status: .todo, rank: nil,
            source: .manual, createdAt: Date(), updatedAt: Date(), sessionIds: [])
        try? await store.upsertTask(task)
        await refreshLists()
    }

    /// Puts a task into (or takes it out of) the 「今日やる」 section. The flag
    /// sticks across days until the user flips it back.
    func setTaskToday(_ task: TaskItem, _ isToday: Bool) async {
        guard let store else { return }
        var updated = task
        updated.isToday = isToday
        updated.updatedAt = Date()
        try? await store.upsertTask(updated)
        await refreshLists()
    }

    /// A board drag ended: `todayIds` are the rows that landed above the
    /// タスク divider, `laterIds` the rows below, both in display order.
    /// Today flags follow the divider, and the combined order is the ranking.
    /// The move is recorded as a preference so future AI proposals learn
    /// from it: crossing the divider beats a plain reorder as the signal.
    func applyBoardOrder(
        todayIds: [String], laterIds: [String], movedId: String? = nil, movedUp: Bool? = nil
    ) async {
        guard let store else { return }
        if let movedId, let moved = tasks.first(where: { $0.id == movedId }) {
            let becameToday = todayIds.contains(movedId)
            if moved.isToday != becameToday {
                try? await store.insertPreference(
                    "ユーザーは「\(moved.title)」を今日やる\(becameToday ? "に入れた" : "から外した")")
            } else if let movedUp {
                try? await store.insertPreference(
                    "ユーザーは「\(moved.title)」の優先度を手動で\(movedUp ? "上げた" : "下げた")")
            }
        }
        for (ids, isToday) in [(todayIds, true), (laterIds, false)] {
            for task in tasks where ids.contains(task.id) && task.isToday != isToday {
                var updated = task
                updated.isToday = isToday
                updated.updatedAt = Date()
                try? await store.upsertTask(updated)
            }
        }
        try? await store.setRanks(todayIds + laterIds)
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

    private func refreshLists() async {
        guard let store else { return }
        tasks = (try? await store.tasks()) ?? []
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
