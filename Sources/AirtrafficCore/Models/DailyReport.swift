import Foundation

/// One line of a daily report: what the work was, plus the facts that give it
/// weight (repository, session count, commits, how long it has been stuck).
public struct ReportEntry: Codable, Hashable, Sendable, Identifiable {
    public var title: String
    /// One sentence: what was done and how far it got.
    public var detail: String
    /// Short badges shown next to the entry, e.g. "webapp", "3セッション".
    public var meta: [String]

    public var id: String { title + detail }

    public init(title: String, detail: String = "", meta: [String] = []) {
        self.title = title
        self.detail = detail
        self.meta = meta
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = (try? container.decode(String.self, forKey: .title)) ?? ""
        detail = (try? container.decode(String.self, forKey: .detail)) ?? ""
        meta = (try? container.decode([String].self, forKey: .meta)) ?? []
    }
}

/// A theme of the day: several related pieces of work read as one story, with
/// the facts it was written from attached.
///
/// Themes are what keep the report from being a list. Three sessions on a PR,
/// a follow-up fix and the commits that landed are one theme ("認証APIの移行を
/// レビュー指摘まで通した"), not five lines. The `evidence` list is the
/// mitigation for the LLM's freedom: it may choose the wording, but it has to
/// name the facts behind it, so a reader can tell an observation from an
/// invention.
public struct ReportTheme: Codable, Hashable, Sendable, Identifiable {
    /// What kind of work the theme mostly is; drives the card's accent color.
    public var kind: WorkKind
    /// The theme as an outcome, not a topic: "CI の停止を解消した".
    public var title: String
    /// Two or three sentences of prose.
    public var body: String
    /// The facts this was written from: repository, session count, commit
    /// subjects, times.
    public var evidence: [String]

    public var id: String { title }

    public init(
        kind: WorkKind = .other, title: String, body: String = "", evidence: [String] = []
    ) {
        self.kind = kind
        self.title = title
        self.body = body
        self.evidence = evidence
    }

    enum CodingKeys: String, CodingKey {
        case kind, title, body, evidence
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let raw = (try? container.decode(String.self, forKey: .kind)) ?? ""
        kind = WorkKind(loose: raw)
        title = (try? container.decode(String.self, forKey: .title)) ?? ""
        body = (try? container.decode(String.self, forKey: .body)) ?? ""
        evidence = (try? container.decode([String].self, forKey: .evidence)) ?? []
    }
}

/// One moment of the day, for the narrative timeline: when, what turned, and
/// one sentence of why it mattered.
public struct TimelineNote: Codable, Hashable, Sendable, Identifiable {
    /// "14:20" or "14:20–16:05", written by the LLM from the given times.
    public var time: String
    public var title: String
    public var note: String

    public var id: String { time + title }

    public init(time: String, title: String, note: String = "") {
        self.time = time
        self.title = title
        self.note = note
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        time = (try? container.decode(String.self, forKey: .time)) ?? ""
        title = (try? container.decode(String.self, forKey: .title)) ?? ""
        note = (try? container.decode(String.self, forKey: .note)) ?? ""
    }
}

/// A daily report as structure rather than prose, so the app owns the layout.
///
/// The LLM writes the wording — the headline, the theme bodies, the timeline
/// notes, the closing — and nothing else: the headings, ordering, badges,
/// figures and styling are the app's, and therefore identical from day to day.
public struct DailyReport: Codable, Hashable, Sendable {
    /// Human-readable date line, written by the LLM ("2026-08-19 (水) 18:53").
    public var date: String
    /// True when the report covers a day still in progress.
    public var midDay: Bool
    /// The opening: one or two sentences naming what kind of day this was.
    /// Read first and often alone, so it has to stand by itself.
    public var headline: String
    /// The day grouped into two to four stories.
    public var themes: [ReportTheme]
    /// The day in order, as turning points rather than as a log.
    public var timeline: [TimelineNote]
    public var stuck: [ReportEntry]
    public var carryOver: [ReportEntry]
    /// The closing paragraph: what the day adds up to.
    public var closing: String

    enum CodingKeys: String, CodingKey {
        case date
        case midDay = "mid_day"
        case headline
        case themes
        case timeline
        case stuck
        case carryOver = "carry_over"
        case closing
        // Read on decode only, to absorb an answer shaped like the older
        // report: models that ignore `themes` tend to answer with these.
        case summary
        case achievements
        case observations
    }

    public init(
        date: String, midDay: Bool = false, headline: String = "",
        themes: [ReportTheme] = [], timeline: [TimelineNote] = [],
        stuck: [ReportEntry] = [], carryOver: [ReportEntry] = [], closing: String = ""
    ) {
        self.date = date
        self.midDay = midDay
        self.headline = headline
        self.themes = themes
        self.timeline = timeline
        self.stuck = stuck
        self.carryOver = carryOver
        self.closing = closing
    }

    /// Tolerant decoding: a report missing a section is a thin report, not a
    /// failure. Only a response that is not an object at all fails to parse,
    /// and that case falls back to showing the raw text.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        date = (try? container.decode(String.self, forKey: .date)) ?? ""
        midDay = (try? container.decode(Bool.self, forKey: .midDay)) ?? false
        themes = (try? container.decode([ReportTheme].self, forKey: .themes)) ?? []
        timeline = (try? container.decode([TimelineNote].self, forKey: .timeline)) ?? []
        stuck = (try? container.decode([ReportEntry].self, forKey: .stuck)) ?? []
        carryOver = (try? container.decode([ReportEntry].self, forKey: .carryOver)) ?? []
        closing = (try? container.decode(String.self, forKey: .closing)) ?? ""

        // `summary` used to be the opening, as one blob or a list of
        // paragraphs. Either shape still fills the headline and the closing.
        var paragraphs: [String] = []
        if let list = try? container.decode([String].self, forKey: .summary) {
            paragraphs = list
        } else if let text = try? container.decode(String.self, forKey: .summary) {
            paragraphs = text.components(separatedBy: "\n\n")
        }
        paragraphs =
            paragraphs
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        headline = (try? container.decode(String.self, forKey: .headline)) ?? ""
        if headline.isEmpty { headline = paragraphs.first ?? "" }
        if closing.isEmpty, paragraphs.count > 1 { closing = paragraphs.dropFirst().joined(separator: " ") }
        if closing.isEmpty {
            closing = ((try? container.decode([String].self, forKey: .observations)) ?? [])
                .joined(separator: " ")
        }
        // An answer that listed achievements instead of themes is still a
        // report; each line becomes a theme so nothing is dropped.
        if themes.isEmpty {
            themes = ((try? container.decode([ReportEntry].self, forKey: .achievements)) ?? [])
                .map { ReportTheme(title: $0.title, body: $0.detail, evidence: $0.meta) }
        }
    }

    /// Written back in the current shape only: the legacy keys above exist to
    /// read an older-shaped answer, never to produce one.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(date, forKey: .date)
        try container.encode(midDay, forKey: .midDay)
        try container.encode(headline, forKey: .headline)
        try container.encode(themes, forKey: .themes)
        try container.encode(timeline, forKey: .timeline)
        try container.encode(stuck, forKey: .stuck)
        try container.encode(carryOver, forKey: .carryOver)
        try container.encode(closing, forKey: .closing)
    }

    /// True when the LLM answered with an object that carried nothing usable.
    public var isEmpty: Bool {
        headline.isEmpty && themes.isEmpty && timeline.isEmpty && stuck.isEmpty
            && carryOver.isEmpty
    }
}
