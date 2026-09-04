import Foundation

/// Renders a `DailyReport` for reading (HTML) and for pasting elsewhere
/// (Markdown).
///
/// The LLM never writes markup and never writes a number into a figure: it
/// returns wording, the layout below is fixed, and every number and figure is
/// drawn from `DayMetrics`, which comes from the scanned facts. A figure that
/// disagreed with the prose would be worse than no figure.
public enum DailyReportRenderer {
    /// A standalone page: no external stylesheet, no script, no network use,
    /// so it renders the same in the app's web view, in a browser, and in a
    /// saved file. Colors follow the reader's light/dark setting.
    public static func html(_ report: DailyReport, metrics: DayMetrics? = nil) -> String {
        """
        <!doctype html>
        <html lang="ja">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>日報 \(escape(report.date))</title>
        <style>\(styles)</style>
        </head>
        <body class="viz-root">
        <main class="wrap">
          \(hero(report))
          \(metrics.map(tiles) ?? "")
          \(themeCards(report.themes))
          \(stream(report.timeline))
          \(metrics.map(figures) ?? "")
          \(entryGroup(title: "詰まっているところ", accent: "amber", entries: report.stuck))
          \(entryGroup(title: "明日に持ち越し", accent: "blue", entries: report.carryOver))
          \(closing(report.closing))
          <p class="footer">完了したタスクと git log から生成。文章は事実の要約です。</p>
        </main>
        </body>
        </html>
        """
    }

    /// The same report as Markdown, for pasting into Slack or a document.
    public static func markdown(_ report: DailyReport) -> String {
        var out = "# 日報 \(report.date)"
        if report.midDay { out += "（途中経過）" }
        out += "\n"
        if !report.headline.isEmpty { out += "\n\(report.headline)\n" }

        if !report.themes.isEmpty {
            out += "\n## 今日の中身\n"
            for theme in report.themes {
                out += "\n### [\(theme.kind.displayName)] \(theme.title)\n"
                if !theme.body.isEmpty { out += "\(theme.body)\n" }
                if !theme.evidence.isEmpty {
                    out += "根拠: \(theme.evidence.joined(separator: " / "))\n"
                }
            }
        }
        if !report.timeline.isEmpty {
            out += "\n## 時系列\n"
            for note in report.timeline {
                out += "- \(note.time) \(note.title)"
                if !note.note.isEmpty { out += " — \(note.note)" }
                out += "\n"
            }
        }
        out += markdownSection("詰まっているところ", report.stuck)
        out += markdownSection("明日に持ち越し", report.carryOver)
        if !report.closing.isEmpty { out += "\n\(report.closing)\n" }
        return out
    }

    private static func markdownSection(_ title: String, _ entries: [ReportEntry]) -> String {
        var out = "\n## \(title)\n"
        guard !entries.isEmpty else { return out + "（なし）\n" }
        for entry in entries {
            out += "- **\(entry.title)**"
            if !entry.detail.isEmpty { out += " \(entry.detail)" }
            if !entry.meta.isEmpty { out += "（\(entry.meta.joined(separator: " / "))）" }
            out += "\n"
        }
        return out
    }

    // MARK: - Head and prose

    /// The opening: the date as an eyebrow, the title, and the headline as a
    /// lead. The headline is read first and often alone, so it gets the widest
    /// measure and the largest body type on the page.
    private static func hero(_ report: DailyReport) -> String {
        let badge = report.midDay ? "<span class=\"badge\">途中経過</span>" : ""
        let lead =
            report.headline.isEmpty
            ? "" : "<p class=\"lead\">\(escape(report.headline))</p>"
        return """
            <section class="hero">
              <p class="eyebrow"><span class="dot"></span>\(escape(report.date))\(badge)</p>
              <h1>日報</h1>
              \(lead)
            </section>
            """
    }

    /// The closing paragraph, set apart so it reads as the conclusion rather
    /// than as one more section.
    private static func closing(_ text: String) -> String {
        guard !text.isEmpty else { return "" }
        return """
            <section class="closing"><p><strong>まとめ</strong>\(escape(text))</p></section>
            """
    }

    // MARK: - Tiles

    /// The day in four numbers. Every one is counted from the task list and
    /// from git, so the tiles and the prose cannot drift apart.
    private static func tiles(_ metrics: DayMetrics) -> String {
        let cells = [
            (metrics.completedTasks, "完了したタスク"),
            (metrics.carryOver, "持ち越し"),
            (metrics.repoCount, "リポジトリ"),
            (metrics.commitTotal, "コミット"),
        ]
        let body = cells.map { count, label in
            """
            <div class="tile"><b>\(count)</b><span>\(escape(label))</span></div>
            """
        }.joined()
        return "<section class=\"tiles\">\(body)</section>"
    }

    // MARK: - Theme cards

    /// The day's stories, one card each. The card's accent follows the kind of
    /// work, never its position in the list, and the kind is always spelled
    /// out in the tag beside it: color groups the cards at a glance, the label
    /// is what actually says which kind it is.
    private static func themeCards(_ themes: [ReportTheme]) -> String {
        guard !themes.isEmpty else { return "" }
        var cards = ""
        for theme in themes {
            let slot = accent(for: theme.kind)
            var card = """
                <article class="card \(slot)">
                  <span class="tag \(slot)">\(escape(theme.kind.displayName))</span>
                  <h3>\(escape(theme.title))</h3>
                """
            if !theme.body.isEmpty { card += "<p>\(escape(theme.body))</p>" }
            if !theme.evidence.isEmpty {
                let facts = theme.evidence.map(escape).joined(separator: " · ")
                card += "<p class=\"evidence\">根拠: \(facts)</p>"
            }
            cards += card + "</article>"
        }
        return """
            <h2 class="section-title">今日の中身<span class="count">\(themes.count)</span></h2>
            <section class="cards">\(cards)</section>
            """
    }

    /// Three accents for seven kinds, grouped by what the work does: making,
    /// diagnosing, and checking. Three is the cap because the cards sit apart
    /// on the page, where any two may be compared — the validated palette
    /// clears its all-pairs floors at three slots, not more.
    private static func accent(for kind: WorkKind) -> String {
        switch kind {
        case .implement, .design: "s1"
        case .investigate, .fix: "s2"
        case .review, .ops: "s3"
        case .other: "neutral"
        }
    }

    // MARK: - Narrative timeline

    /// The day in order: when something turned, and what turned. Times come
    /// from the fact sheet, so the column is a real clock, not a numbering.
    private static func stream(_ notes: [TimelineNote]) -> String {
        guard !notes.isEmpty else { return "" }
        var rows = ""
        for note in notes {
            rows += """
                <div class="moment">
                  <p class="when">\(escape(note.time))</p>
                  <div>
                    <h4>\(escape(note.title))</h4>
                    \(note.note.isEmpty ? "" : "<p>\(escape(note.note))</p>")
                  </div>
                </div>
                """
        }
        return """
            <h2 class="section-title">時系列</h2>
            <section class="stream">\(rows)</section>
            """
    }

    // MARK: - Entry lists

    private static func entryGroup(title: String, accent: String, entries: [ReportEntry])
        -> String
    {
        guard !entries.isEmpty else { return "" }
        var out = """
            <h2 class="section-title \(accent)">\(escape(title))\
            <span class="count">\(entries.count)</span></h2>
            <section class="group"><ul>
            """
        for entry in entries {
            out += "<li><p class=\"title\">\(escape(entry.title))</p>"
            if !entry.detail.isEmpty {
                out += "<p class=\"detail\">\(escape(entry.detail))</p>"
            }
            if !entry.meta.isEmpty {
                let tags = entry.meta.map { "<span>\(escape($0))</span>" }.joined()
                out += "<p class=\"meta\">\(tags)</p>"
            }
            out += "</li>"
        }
        return out + "</ul></section>"
    }

    // MARK: - Figures

    private static func figures(_ metrics: DayMetrics) -> String {
        guard !metrics.isEmpty else { return "" }
        // Prose first, charts second: the figure backs up what the cards
        // already said, so it reads better after them. A bar chart of one or
        // two repositories says nothing the tile did not; it earns its space
        // from three.
        return metrics.commits.count >= 3 ? commitBars(metrics) : ""
    }

    /// What actually landed: commits per repository, each bar labeled.
    private static func commitBars(_ metrics: DayMetrics) -> String {
        guard !metrics.commits.isEmpty else { return "" }
        let peak = max(metrics.commits.map(\.total).max() ?? 1, 1)
        var rows = ""
        for repo in metrics.commits {
            let share = Double(repo.total) / Double(peak) * 100
            rows += """
                <div class="row">
                  <p class="row-label">\(escape(repo.name))</p>
                  <div class="track">
                    <div class="bar s1" style="left:0;width:\(pct(share));"></div>
                  </div>
                  <p class="value">\(repo.total)</p>
                </div>
                """
        }
        return """
            <section class="figure commits">
              <h2>コミット<span class="count">\(metrics.commitTotal)</span></h2>
              <div class="chart">\(rows)</div>
            </section>
            """
    }

    private static func pct(_ value: Double) -> String {
        String(format: "%.2f%%", value)
    }

    /// Everything the LLM wrote is text, never markup: escape before it lands
    /// in the page.
    static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private static let styles = """
        .viz-root {
          color-scheme: light;
          --bg: #ffffff; --bg-far: #f7f7f8; --card: #ffffff; --soft: #f6f6f7;
          --ink: #1c1c1e; --body: #46464b; --muted: #6b6b70;
          --line: #e3e3e6; --tag: #f0f0f2; --grid: #ebebee;
          --amber: #b7791f; --blue: #2b6cb0;
          /* Categorical slots 1–3, validated all-pairs against this surface. */
          --s1: #2a78d6; --s2: #eb6834; --s3: #1baf7a; --neutral: #8e8e94;
          --s1-soft: #e8f1fc; --s2-soft: #fceee7; --s3-soft: #e6f6ef;
          --neutral-soft: #f0f0f2;
          --shadow: 0 1px 2px rgba(0,0,0,.04), 0 8px 24px rgba(0,0,0,.05);
        }
        @media (prefers-color-scheme: dark) {
          .viz-root {
            color-scheme: dark;
            --bg: #1b1b1d; --bg-far: #141416; --card: #26262a; --soft: #202024;
            --ink: #f2f2f4; --body: #d3d3d8; --muted: #a0a0a8;
            --line: #34343a; --tag: #33333a; --grid: #2f2f35;
            --amber: #e0b055; --blue: #7aa9e0;
            --s1: #3987e5; --s2: #d95926; --s3: #199e70; --neutral: #85858d;
            --s1-soft: #1d2c3f; --s2-soft: #3a2318; --s3-soft: #14302633;
            --neutral-soft: #2f2f35;
            --shadow: 0 1px 2px rgba(0,0,0,.3);
          }
        }
        * { box-sizing: border-box; }
        body {
          margin: 0; background: linear-gradient(180deg, var(--bg) 0%, var(--bg-far) 100%);
          color: var(--ink);
          font: 14px/1.85 -apple-system, "Hiragino Sans", "Noto Sans JP", sans-serif;
          -webkit-font-smoothing: antialiased;
        }
        .wrap { max-width: 900px; margin: 0 auto; padding: 32px 28px 40px; }
        /* Hero */
        .hero { margin-bottom: 24px; }
        .eyebrow {
          display: inline-flex; align-items: center; gap: 8px; margin: 0;
          padding: 5px 12px; border-radius: 999px;
          background: var(--s1-soft); color: var(--s1);
          font-size: 12px; font-weight: 700; font-variant-numeric: tabular-nums;
        }
        .dot { width: 7px; height: 7px; border-radius: 50%; background: var(--s1); }
        .badge {
          margin-left: 8px; padding: 0 8px; border-radius: 999px;
          background: var(--card); color: var(--muted); font-size: 11px; font-weight: 600;
        }
        h1 {
          margin: 16px 0 12px; font-size: 30px; line-height: 1.3;
          letter-spacing: -.02em;
        }
        .lead {
          margin: 0; max-width: 32em; font-size: 16px; line-height: 1.95;
          color: var(--body);
        }
        /* Tiles */
        .tiles {
          display: grid; grid-template-columns: repeat(4, 1fr); gap: 12px;
          margin-bottom: 28px;
        }
        .tile {
          padding: 16px 18px; background: var(--card); border: 1px solid var(--line);
          border-radius: 14px; box-shadow: var(--shadow);
        }
        .tile b {
          display: block; font-size: 26px; line-height: 1.1; color: var(--s1);
          font-variant-numeric: tabular-nums;
        }
        .tile span { display: block; margin-top: 6px; font-size: 12px; color: var(--muted); }
        /* Section headings */
        .section-title {
          display: flex; align-items: center; gap: 8px; margin: 32px 0 14px;
          font-size: 13px; letter-spacing: .04em; color: var(--muted);
        }
        .section-title::before {
          content: ""; width: 8px; height: 8px; border-radius: 2px; background: var(--muted);
        }
        .section-title.amber::before { background: var(--amber); }
        .section-title.blue::before { background: var(--blue); }
        .count {
          padding: 1px 7px; border-radius: 999px; background: var(--tag);
          font-size: 11px; color: var(--muted); font-variant-numeric: tabular-nums;
        }
        /* Theme cards */
        .cards { display: grid; grid-template-columns: repeat(2, 1fr); gap: 14px; }
        .card {
          position: relative; overflow: hidden; padding: 20px;
          background: var(--card); border: 1px solid var(--line); border-radius: 16px;
          box-shadow: var(--shadow);
        }
        .card::before {
          content: ""; position: absolute; inset: 0 0 auto 0; height: 4px;
          background: var(--neutral);
        }
        .card.s1::before { background: var(--s1); }
        .card.s2::before { background: var(--s2); }
        .card.s3::before { background: var(--s3); }
        .tag {
          display: inline-block; margin-bottom: 10px; padding: 3px 9px;
          border-radius: 8px; font-size: 11px; font-weight: 700;
          background: var(--neutral-soft); color: var(--muted);
        }
        .tag.s1 { background: var(--s1-soft); color: var(--s1); }
        .tag.s2 { background: var(--s2-soft); color: var(--s2); }
        .tag.s3 { background: var(--s3-soft); color: var(--s3); }
        .card h3 { margin: 0 0 8px; font-size: 16px; line-height: 1.6; }
        .card p { margin: 0; color: var(--body); }
        .evidence {
          margin-top: 14px; padding-top: 12px; border-top: 1px solid var(--line);
          font-size: 11px; color: var(--muted);
        }
        .card .evidence { color: var(--muted); }
        /* Narrative timeline */
        .stream {
          background: var(--card); border: 1px solid var(--line); border-radius: 16px;
          padding: 4px 20px; box-shadow: var(--shadow);
        }
        .moment {
          display: grid; grid-template-columns: 5.5em 1fr; gap: 16px;
          padding: 16px 0; border-bottom: 1px solid var(--line);
        }
        .moment:last-child { border-bottom: 0; }
        .when {
          margin: 0; font-weight: 700; color: var(--s1);
          font-variant-numeric: tabular-nums;
        }
        .moment h4 { margin: 0 0 4px; font-size: 14px; line-height: 1.7; }
        .moment p { margin: 0; color: var(--body); }
        /* Entry lists */
        .group ul { list-style: none; margin: 0; padding: 0; display: grid; gap: 10px; }
        .group li {
          background: var(--card); border: 1px solid var(--line); border-radius: 12px;
          padding: 14px 16px;
        }
        .title { margin: 0; font-weight: 600; }
        .detail { margin: 6px 0 0; max-width: 40em; color: var(--body); }
        .meta { margin: 10px 0 0; display: flex; flex-wrap: wrap; gap: 6px; }
        .meta span {
          padding: 2px 8px; border-radius: 999px; background: var(--tag);
          font-size: 11px; color: var(--muted); white-space: nowrap;
        }
        /* Closing */
        .closing {
          margin-top: 32px; padding: 18px 20px; background: var(--soft);
          border: 1px solid var(--line); border-radius: 14px;
        }
        .closing p { margin: 0; color: var(--body); }
        .closing strong { color: var(--ink); margin-right: 8px; }
        .footer { margin: 20px 0 0; font-size: 11px; color: var(--muted); }
        /* Figures */
        .figure {
          background: var(--card); border: 1px solid var(--line); border-radius: 16px;
          padding: 18px 20px; margin-bottom: 14px; box-shadow: var(--shadow);
        }
        .figure h2 {
          display: flex; align-items: center; gap: 8px; margin: 0 0 14px;
          font-size: 13px; letter-spacing: .04em; color: var(--muted);
        }
        .chart { display: grid; gap: 10px; }
        .row { display: grid; grid-template-columns: 1fr; gap: 4px; }
        .commits .row {
          grid-template-columns: 8em 1fr 2.5em; align-items: center; gap: 10px;
        }
        .row-label { margin: 0; font-size: 12px; line-height: 1.6; }
        .row-label span { display: block; color: var(--muted); font-size: 11px; }
        .value {
          margin: 0; font-size: 12px; color: var(--muted); text-align: right;
          font-variant-numeric: tabular-nums;
        }
        .track {
          position: relative; height: 10px; border-radius: 5px; background: var(--grid);
        }
        .bar { position: absolute; top: 0; height: 10px; border-radius: 5px; }
        .bar.s1 { background: var(--s1); }
        @media (max-width: 720px) {
          .wrap { padding: 24px 18px 32px; }
          h1 { font-size: 24px; }
          .lead { font-size: 15px; }
          .tiles { grid-template-columns: repeat(2, 1fr); }
          .cards { grid-template-columns: 1fr; }
          .moment { grid-template-columns: 1fr; gap: 4px; }
        }
        """
}
