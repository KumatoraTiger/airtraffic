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

/// A daily report as structure rather than prose, so the app owns the layout.
///
/// The LLM writes the wording (the 概要 paragraph, one sentence per entry) and
/// nothing else: the headings, ordering, badges and styling are the app's, and
/// therefore identical from day to day.
public struct DailyReport: Codable, Hashable, Sendable {
    /// Human-readable date line, written by the LLM ("2026-08-19 (水) 18:53").
    public var date: String
    /// True when the report covers a day still in progress.
    public var midDay: Bool
    /// The opening, as paragraphs: what kind of day this was. Kept as several
    /// short blocks rather than one, because a wall of text is the thing
    /// readers skip.
    public var summary: [String]
    public var achievements: [ReportEntry]
    public var stuck: [ReportEntry]
    public var carryOver: [ReportEntry]
    /// At most two observations, each backed by a number in the facts.
    public var observations: [String]

    enum CodingKeys: String, CodingKey {
        case date
        case midDay = "mid_day"
        case summary
        case achievements
        case stuck
        case carryOver = "carry_over"
        case observations
    }

    public init(
        date: String, midDay: Bool = false, summary: [String] = [],
        achievements: [ReportEntry] = [], stuck: [ReportEntry] = [],
        carryOver: [ReportEntry] = [], observations: [String] = []
    ) {
        self.date = date
        self.midDay = midDay
        self.summary = summary
        self.achievements = achievements
        self.stuck = stuck
        self.carryOver = carryOver
        self.observations = observations
    }

    /// Tolerant decoding: a report missing a section is a thin report, not a
    /// failure. Only a response that is not an object at all fails to parse,
    /// and that case falls back to showing the raw text.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        date = (try? container.decode(String.self, forKey: .date)) ?? ""
        midDay = (try? container.decode(Bool.self, forKey: .midDay)) ?? false
        // Models answer with either a list of paragraphs or one blob; a blob is
        // split on blank lines so it still reads as paragraphs.
        if let paragraphs = try? container.decode([String].self, forKey: .summary) {
            summary = paragraphs.filter { !$0.isEmpty }
        } else if let text = try? container.decode(String.self, forKey: .summary) {
            summary = text.components(separatedBy: "\n\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        } else {
            summary = []
        }
        achievements = (try? container.decode([ReportEntry].self, forKey: .achievements)) ?? []
        stuck = (try? container.decode([ReportEntry].self, forKey: .stuck)) ?? []
        carryOver = (try? container.decode([ReportEntry].self, forKey: .carryOver)) ?? []
        observations = (try? container.decode([String].self, forKey: .observations)) ?? []
    }

    /// True when the LLM answered with an object that carried nothing usable.
    public var isEmpty: Bool {
        summary.isEmpty && achievements.isEmpty && stuck.isEmpty && carryOver.isEmpty
    }
}
