import Foundation

/// Renders a `DailyReport` for reading (HTML) and for pasting elsewhere
/// (Markdown).
///
/// The LLM never writes markup and never writes a number into a figure: it
/// returns wording, the layout below is fixed, and every figure is drawn from
/// `DayMetrics`, which comes from the scanned facts. A figure that disagreed
/// with the prose would be worse than no figure.
public enum DailyReportRenderer {
    /// A standalone page: no external stylesheet, no script, no network use,
    /// so it renders the same in the app's web view, in a browser, and in a
    /// saved file. Colors follow the reader's light/dark setting.
    public static func html(_ report: DailyReport, metrics: DayMetrics? = nil) -> String {
        let sections = [
            section(title: "成果", accent: "green", entries: report.achievements),
            section(title: "詰まっているところ", accent: "amber", entries: report.stuck),
            section(title: "明日に持ち越し", accent: "blue", entries: report.carryOver),
        ].joined()

        return """
            <!doctype html>
            <html lang="ja">
            <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <title>日報 \(escape(report.date))</title>
            <style>\(styles)</style>
            </head>
            <body class="viz-root">
            <main>
              <header>
                <h1>日報</h1>
                <p class="date">\(escape(report.date))\
            \(report.midDay ? "<span class=\"badge\">途中経過</span>" : "")</p>
              </header>
              \(summaryBlock(report.summary))
              \(metrics.map(figures) ?? "")
              \(sections)
              \(observationsBlock(report.observations))
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
        for paragraph in report.summary { out += "\n\(paragraph)\n" }
        out += markdownSection("成果", report.achievements)
        out += markdownSection("詰まっているところ", report.stuck)
        out += markdownSection("明日に持ち越し", report.carryOver)
        if !report.observations.isEmpty {
            out += "\n## 気付いたこと\n"
            for line in report.observations { out += "- \(line)\n" }
        }
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

    // MARK: - Text blocks

    private static func summaryBlock(_ paragraphs: [String]) -> String {
        guard !paragraphs.isEmpty else { return "" }
        let body = paragraphs.map { "<p>\(escape($0))</p>" }.joined()
        return "<section class=\"summary\">\(body)</section>"
    }

    private static func section(title: String, accent: String, entries: [ReportEntry]) -> String {
        var out = """
            <section class="group \(accent)">
              <h2>\(escape(title))<span class="count">\(entries.count)</span></h2>
            """
        if entries.isEmpty {
            out += "<p class=\"empty\">（なし）</p>"
        } else {
            out += "<ul>"
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
            out += "</ul>"
        }
        return out + "</section>"
    }

    private static func observationsBlock(_ observations: [String]) -> String {
        guard !observations.isEmpty else { return "" }
        let items = observations.map { "<li>\(escape($0))</li>" }.joined()
        return "<section class=\"notes\"><h2>気付いたこと</h2><ul>\(items)</ul></section>"
    }

    // MARK: - Figures

    private static func figures(_ metrics: DayMetrics) -> String {
        guard !metrics.isEmpty else { return "" }
        return timeline(metrics) + planSplit(metrics) + commitBars(metrics)
    }

    /// Where the day went: one row per piece of work, positioned on a shared
    /// hour scale. State is carried by color *and* by the label on the row, so
    /// the rows stay readable without color.
    private static func timeline(_ metrics: DayMetrics) -> String {
        guard !metrics.timeline.isEmpty else { return "" }
        let start = metrics.windowStart
        let span = max(metrics.now.timeIntervalSince(start), 3600)

        func offset(_ date: Date) -> Double {
            min(max(date.timeIntervalSince(start) / span, 0), 1) * 100
        }

        var rows = ""
        for bar in metrics.timeline {
            let left = offset(bar.start)
            // A bar thinner than this reads as a dot and loses its position.
            let width = max(offset(bar.end) - left, 1.5)
            let state = stateClass(bar.state)
            let label =
                "\(bar.state.displayName) · \(time(bar.start))–\(time(bar.end))"
                + (bar.sessionCount > 1 ? " · \(bar.sessionCount)セッション" : "")
            rows += """
                <div class="row">
                  <p class="row-label">\(escape(bar.title))<span>\(escape(label))</span></p>
                  <div class="track">
                    <div class="bar \(state)" style="left:\(pct(left));width:\(pct(width));" \
                title="\(escape(bar.title)) \(escape(label))"></div>
                  </div>
                </div>
                """
        }

        var ticks = ""
        for date in hourTicks(from: start, to: metrics.now) {
            ticks += "<span style=\"left:\(pct(offset(date)));\">\(time(date))</span>"
        }

        return """
            <section class="figure">
              <h2>時間の使いみち<span class="count">\(metrics.timeline.count)</span></h2>
              <div class="chart">\(rows)<div class="axis">\(ticks)</div></div>
              <p class="legend">
                <span class="key running"></span>実行中
                <span class="key awaiting"></span>確認待ち
                <span class="key quiet"></span>停止
              </p>
              <p class="note">セッションの記録された時刻から引いた幅です。実際の着手時刻より狭く出ることがあります。</p>
            </section>
            """
    }

    /// The plan against the day: one stacked bar, every segment labeled.
    private static func planSplit(_ metrics: DayMetrics) -> String {
        let parts = [
            ("予定して進んだ", metrics.plannedWorked, "s1"),
            ("予定外に動いた", metrics.unplanned, "s2"),
            ("手が付かなかった", metrics.plannedUntouched, "s3"),
        ].filter { $0.1 > 0 }
        let total = parts.reduce(0) { $0 + $1.1 }
        guard total > 0 else { return "" }

        var segments = ""
        var legend = ""
        for (label, count, slot) in parts {
            let share = Double(count) / Double(total) * 100
            segments += """
                <div class="seg \(slot)" style="width:\(pct(share));" \
                title="\(escape(label)) \(count)件"></div>
                """
            legend += """
                <span class="item"><span class="key \(slot)"></span>\(escape(label))\
                    <strong>\(count)</strong></span>
                """
        }
        return """
            <section class="figure">
              <h2>予定と実際<span class="count">\(total)</span></h2>
              <div class="stack">\(segments)</div>
              <p class="legend">\(legend)</p>
            </section>
            """
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
        let total = metrics.commits.reduce(0) { $0 + $1.total }
        return """
            <section class="figure commits">
              <h2>コミット<span class="count">\(total)</span></h2>
              <div class="chart">\(rows)</div>
            </section>
            """
    }

    /// Hour marks every three hours, so a long day keeps a readable axis.
    public static func hourTicks(from start: Date, to end: Date, calendar: Calendar = .current)
        -> [Date]
    {
        var ticks: [Date] = []
        var cursor = start
        while cursor <= end, ticks.count < 12 {
            ticks.append(cursor)
            guard let next = calendar.date(byAdding: .hour, value: 3, to: cursor) else { break }
            cursor = next
        }
        return ticks
    }

    private static func pct(_ value: Double) -> String {
        String(format: "%.2f%%", value)
    }

    private static func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    private static func stateClass(_ state: DailyReporter.ActivityState) -> String {
        switch state {
        case .running: "running"
        case .awaitingUser: "awaiting"
        case .quiet: "quiet"
        }
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
          --bg: #f6f6f7; --card: #ffffff; --ink: #1c1c1e; --muted: #6b6b70;
          --line: #e3e3e6; --tag: #f0f0f2; --grid: #ebebee;
          --green: #2f8f4e; --amber: #b7791f; --blue: #2b6cb0;
          /* Categorical slots 1–3 and the status steps, light mode. */
          --s1: #2a78d6; --s2: #eb6834; --s3: #1baf7a;
          --state-running: #0ca30c; --state-awaiting: #fab219; --state-quiet: #9a9aa0;
        }
        @media (prefers-color-scheme: dark) {
          .viz-root {
            color-scheme: dark;
            --bg: #1b1b1d; --card: #26262a; --ink: #f2f2f4; --muted: #a0a0a8;
            --line: #34343a; --tag: #33333a; --grid: #2f2f35;
            --green: #6cc48a; --amber: #e0b055; --blue: #7aa9e0;
            --s1: #3987e5; --s2: #d95926; --s3: #199e70;
            --state-running: #0ca30c; --state-awaiting: #fab219; --state-quiet: #75757c;
          }
        }
        * { box-sizing: border-box; }
        body {
          margin: 0; padding: 24px; background: var(--bg); color: var(--ink);
          font: 14px/1.85 -apple-system, "Hiragino Sans", "Noto Sans JP", sans-serif;
          -webkit-font-smoothing: antialiased;
        }
        main { max-width: 760px; margin: 0 auto; }
        header { margin-bottom: 20px; }
        h1 { margin: 0; font-size: 20px; letter-spacing: .02em; }
        .date { margin: 4px 0 0; color: var(--muted); font-size: 13px; }
        .badge {
          margin-left: 8px; padding: 2px 8px; border-radius: 999px;
          background: var(--tag); color: var(--muted); font-size: 11px;
        }
        .summary {
          background: var(--card); border: 1px solid var(--line); border-radius: 12px;
          padding: 18px 20px; margin-bottom: 24px;
        }
        .summary p { margin: 0; font-size: 15px; line-height: 2.0; max-width: 34em; }
        .summary p + p { margin-top: 14px; }
        section { margin-bottom: 24px; }
        h2 {
          display: flex; align-items: center; gap: 8px; margin: 0 0 12px;
          font-size: 13px; letter-spacing: .04em; color: var(--muted);
        }
        .group h2::before {
          content: ""; width: 8px; height: 8px; border-radius: 2px; background: var(--muted);
        }
        .green h2::before { background: var(--green); }
        .amber h2::before { background: var(--amber); }
        .blue h2::before { background: var(--blue); }
        .count {
          padding: 1px 7px; border-radius: 999px; background: var(--tag);
          font-size: 11px; color: var(--muted);
        }
        .group ul { list-style: none; margin: 0; padding: 0; display: grid; gap: 10px; }
        .group li {
          background: var(--card); border: 1px solid var(--line); border-radius: 10px;
          padding: 14px 16px;
        }
        .title { margin: 0; font-weight: 600; }
        .detail { margin: 6px 0 0; max-width: 40em; }
        .meta { margin: 10px 0 0; display: flex; flex-wrap: wrap; gap: 6px; }
        .meta span {
          padding: 2px 8px; border-radius: 999px; background: var(--tag);
          font-size: 11px; color: var(--muted); white-space: nowrap;
        }
        .empty { margin: 0; color: var(--muted); font-size: 13px; }
        /* Figures */
        .figure {
          background: var(--card); border: 1px solid var(--line); border-radius: 12px;
          padding: 16px 18px;
        }
        .chart { display: grid; gap: 10px; }
        .row { display: grid; grid-template-columns: 1fr; gap: 4px; }
        .commits .row {
          grid-template-columns: 8em 1fr 2.5em; align-items: center; gap: 10px;
        }
        .row-label { margin: 0; font-size: 12px; line-height: 1.6; }
        .row-label span { display: block; color: var(--muted); font-size: 11px; }
        .value { margin: 0; font-size: 12px; color: var(--muted); text-align: right; }
        .track {
          position: relative; height: 10px; border-radius: 5px; background: var(--grid);
        }
        .bar { position: absolute; top: 0; height: 10px; border-radius: 5px; }
        .bar.running { background: var(--state-running); }
        .bar.awaiting { background: var(--state-awaiting); }
        .bar.quiet { background: var(--state-quiet); }
        .bar.s1 { background: var(--s1); }
        .axis {
          position: relative; height: 16px; margin-top: 2px;
          border-top: 1px solid var(--line);
        }
        .axis span {
          position: absolute; top: 2px; transform: translateX(-50%);
          font-size: 10px; color: var(--muted); font-variant-numeric: tabular-nums;
        }
        .stack { display: flex; gap: 2px; height: 14px; }
        .stack .seg { border-radius: 3px; min-width: 3px; }
        .seg.s1 { background: var(--s1); }
        .seg.s2 { background: var(--s2); }
        .seg.s3 { background: var(--s3); }
        .legend {
          margin: 10px 0 0; display: flex; flex-wrap: wrap; gap: 14px;
          font-size: 11px; color: var(--muted); align-items: center;
        }
        .legend .item { display: inline-flex; align-items: center; gap: 6px; }
        .legend strong { color: var(--ink); font-variant-numeric: tabular-nums; }
        .key {
          width: 10px; height: 10px; border-radius: 3px; display: inline-block;
          margin-right: 6px; vertical-align: -1px;
        }
        .key.running { background: var(--state-running); }
        .key.awaiting { background: var(--state-awaiting); }
        .key.quiet { background: var(--state-quiet); }
        .key.s1 { background: var(--s1); margin-right: 0; }
        .key.s2 { background: var(--s2); margin-right: 0; }
        .key.s3 { background: var(--s3); margin-right: 0; }
        .note { margin: 8px 0 0; font-size: 11px; color: var(--muted); }
        .notes { border-top: 1px solid var(--line); padding-top: 16px; margin-top: 24px; }
        .notes h2 { margin: 0 0 8px; }
        .notes ul { margin: 0; padding-left: 20px; }
        """
}
