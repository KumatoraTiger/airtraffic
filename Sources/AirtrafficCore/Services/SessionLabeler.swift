import Foundation

/// Generates work labels ("レビュー: 認証APIの差分") for sessions via an
/// LLM. Classification, not extraction: many sessions batch into one call
/// without hurting accuracy, and everything the prompt needs is already in
/// the scanned snapshot — no transcript re-read.
///
/// A wrong or missing label degrades gracefully: the board falls back to the
/// cleaned session title, exactly what it showed before labels existed.
public struct SessionLabeler: Sendable {
    /// Cap on sessions per LLM call.
    public var maxPerPass: Int
    /// How much a session's `lastActivity` must advance before its label is
    /// considered stale. Long enough that a busy session is not relabeled on
    /// every pass, short enough to follow the work as it shifts (review turns
    /// into fixing).
    public var refreshInterval: TimeInterval

    public init(maxPerPass: Int = 10, refreshInterval: TimeInterval = 600) {
        self.maxPerPass = maxPerPass
        self.refreshInterval = refreshInterval
    }

    /// Sessions whose label is missing or stale, newest activity first.
    public func sessionsNeedingLabels(
        _ sessions: [SessionSnapshot], labels: [String: WorkLabel]
    ) -> [SessionSnapshot] {
        let needy = sessions.filter { session in
            guard let label = labels[session.id] else { return true }
            return session.lastActivity.timeIntervalSince(label.labeledActivity)
                > refreshInterval
        }
        return Array(needy.sorted { $0.lastActivity > $1.lastActivity }.prefix(maxPerPass))
    }

    public func label(
        client: any LLMClient, sessions: [SessionSnapshot], now: Date = Date()
    ) async throws -> [WorkLabel] {
        guard !sessions.isEmpty else { return [] }
        let kinds = WorkKind.allCases.map(\.rawValue).joined(separator: " | ")

        let system = """
            あなたはコーディングエージェントのセッションを「いま何の作業か」で分類するアシスタントです。
            各セッションに kind と subject を付けます。

            - kind は次から必ず選ぶ: \(kinds)
              （review=レビュー, design=設計・方針決め, implement=新規実装, investigate=調査・原因究明,
               fix=バグ修正・手直し, ops=デプロイ・環境・運用, other=どれでもない）
            - subject は対象が特定できる最短の日本語名詞句（15字程度）。
              発言や todo から作業対象の機能・変更の名前を読み取り、必ず含める。
              作業の種類（レビュー・調査・修正など）は kind で表すので、
              subject を種類の言葉だけで済ませない。
              PR 番号・リポジトリ名が読み取れるなら含めるが、識別子だけの subject も禁止。
              例:「PR #123 のレビュー」「PR #123 の CI 失敗調査」は不可、
              「PR #123 認証リトライ修正」「PR #123 認証リトライの CI 失敗」は可。
              対象の名前が読み取れないセッションは出力に含めない。依頼文の写しにしない。
            - 判断がつかないセッションは出力に含めない。

            出力は次の JSON のみ: {"labels": [{"id": "セッションID", "kind": "...", "subject": "..."}]}
            """

        var prompt = ""
        for session in sessions {
            prompt += """
                ## id: \(session.id)
                - project: \(session.projectName)
                - 依頼: \(clip(session.title, 200))
                - 直近のユーザー発言: \(clip(session.lastUserText, 200))
                - 直近のアシスタント発言: \(clip(session.lastAssistantText, 300))

                """
            let doing = session.todos.filter { $0.status != .completed }.prefix(3)
            if !doing.isEmpty {
                prompt += "- todo: \(doing.map(\.content).joined(separator: " / "))\n"
            }
            prompt += "\n"
        }

        let response = try await client.complete(
            LLMRequest(
                system: system,
                messages: [ChatMessage(role: .user, text: prompt)],
                jsonMode: true,
                maxTokens: 1024
            ))

        guard let data = LLMJSON.extractJSON(from: response),
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let raw = json["labels"] as? [[String: Any]]
        else { return [] }

        let byId = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        return raw.compactMap { item in
            // Only ids we actually asked about, only kinds from the
            // vocabulary, and never an empty subject — a label that names
            // nothing is worse than the fallback title.
            guard let id = item["id"] as? String,
                let session = byId[id],
                let kind = (item["kind"] as? String).flatMap(WorkKind.init(rawValue:)),
                let subject = (item["subject"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                !subject.isEmpty
            else { return nil }
            return WorkLabel(
                sessionId: id,
                kind: kind,
                subject: String(subject.prefix(40)),
                updatedAt: now,
                labeledActivity: session.lastActivity
            )
        }
    }

    private func clip(_ text: String, _ limit: Int) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return flat.count > limit ? String(flat.prefix(limit)) + "…" : flat
    }
}
