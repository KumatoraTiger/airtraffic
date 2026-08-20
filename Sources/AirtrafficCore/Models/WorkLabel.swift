import Foundation

/// What kind of work a session is doing, from a fixed vocabulary. Fixed so
/// rows line up: scanning the board vertically reads as "three reviews, one
/// design" instead of seven differently-worded blurbs.
public enum WorkKind: String, Codable, CaseIterable, Sendable {
    case review
    case design
    case implement
    case investigate
    case fix
    case ops
    case other

    /// Reads a kind from whatever the LLM wrote: the raw case, the Japanese
    /// display name, or a near miss. Anything unrecognized is `other`, which
    /// is a category rather than an error.
    public init(loose text: String) {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let match = WorkKind(rawValue: cleaned) {
            self = match
            return
        }
        if let match = WorkKind.allCases.first(where: { $0.displayName == cleaned }) {
            self = match
            return
        }
        self = .other
    }

    public var displayName: String {
        switch self {
        case .review: "レビュー"
        case .design: "設計"
        case .implement: "実装"
        case .investigate: "調査"
        case .fix: "修正"
        case .ops: "運用"
        case .other: "その他"
        }
    }
}

/// An LLM-generated label for what a session is working on: a kind plus a
/// short subject ("レビュー: 認証APIの差分"). Labels are cached per
/// session id and refreshed only when the session keeps moving, so the board
/// can show *what the user is doing* instead of the raw first message.
public struct WorkLabel: Sendable {
    public var sessionId: String
    public var kind: WorkKind
    /// Shortest noun phrase that identifies the target, ~15 chars.
    public var subject: String
    public var updatedAt: Date
    /// The session's `lastActivity` at labeling time; how staleness is judged.
    public var labeledActivity: Date

    public init(
        sessionId: String, kind: WorkKind, subject: String,
        updatedAt: Date, labeledActivity: Date
    ) {
        self.sessionId = sessionId
        self.kind = kind
        self.subject = subject
        self.updatedAt = updatedAt
        self.labeledActivity = labeledActivity
    }

    /// Text-only rendering for places without room for a styled kind tag
    /// (the menu bar).
    public var displayTitle: String { "\(kind.displayName): \(subject)" }

    /// A negative-cache marker: the LLM was asked and could not classify this
    /// session. Stored so the same session is not re-asked every pass; never
    /// shown, never used for matching or merging.
    public var isPlaceholder: Bool { subject.isEmpty }
}
