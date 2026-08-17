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
    var candidates: [Candidate] = []
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

    var attentionCount: Int { sessions.filter { $0.status.needsAttention }.count }

    // MARK: - Internals

    private let store: Store?
    private let coordinator: IngestionCoordinator
    private let extractor = TaskExtractor()
    private let prioritizer = Prioritizer()
    /// Transcript text accumulated per session since the last extraction pass.
    private var pendingText: [String: (title: String, agent: AgentKind, text: String)] = [:]
    private var scanTask: Task<Void, Never>?
    private var lastExtraction = Date.distantPast

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
        }
    }

    private func refreshFromStore() async {
        guard let store else { return }
        tasks = (try? await store.tasks()) ?? []
        candidates = (try? await store.candidates()) ?? []
        preferences = (try? await store.preferences()) ?? []
        try? await store.expireCandidates(olderThan: 72 * 3600)
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

    // MARK: - Extraction (inbox candidates)

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
                try? await store.insertCandidate(candidate)
                // Sessions later in this pass see it in their prompt too.
                known.pendingCandidates.append(extraction.title)
            }
        }
        candidates = (try? await store.candidates()) ?? []
    }

    // MARK: - Inbox actions

    func accept(_ candidate: Candidate) async {
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

    /// Manual reorder. The move itself is recorded as a preference so future
    /// AI proposals learn from it.
    func moveTask(fromOffsets: IndexSet, toOffset: Int) async {
        guard let store else { return }
        var reordered = tasks
        reordered.move(fromOffsets: fromOffsets, toOffset: toOffset)
        try? await store.setRanks(reordered.map(\.id))
        if let index = fromOffsets.first, index < tasks.count {
            let moved = tasks[index]
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
