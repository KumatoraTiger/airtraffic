import AirtrafficCore
import AppKit
import SwiftUI

/// 今日のふりかえり: a live view of everything finished (and moved) so far
/// today, plus on-demand 日報 generation. Opened mid-day it shows the day up
/// to now; the lists recompute from current state on every render.
struct ReportView: View {
    @Environment(AppModel.self) private var model
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            List {
                completedSection
                activitySection
                remainingSection
                reportSection
            }
            Divider()
            HStack {
                Button {
                    Task { await model.generateDailyReport() }
                } label: {
                    Label(
                        model.hasReport ? "日報を再生成" : "日報を生成",
                        systemImage: "sparkles")
                }
                .disabled(model.reportBusy)
                if model.reportBusy {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                if model.hasReport {
                    Button {
                        openInBrowser()
                    } label: {
                        Label("ブラウザで開く", systemImage: "safari")
                    }
                    .disabled(model.reportHTML == nil)
                    Button {
                        saveHTML()
                    } label: {
                        Label("HTMLを保存", systemImage: "square.and.arrow.down")
                    }
                    .disabled(model.reportHTML == nil)
                    Button {
                        copyReport()
                    } label: {
                        Label(copied ? "コピーしました" : "Markdownをコピー", systemImage: "doc.on.doc")
                    }
                    .disabled(copied)
                }
            }
            .padding(10)
        }
    }

    // MARK: - Sections

    private var completedSection: some View {
        Section {
            if model.completedToday.isEmpty {
                Text("今日完了したタスクはまだありません")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            ForEach(model.completedToday) { task in
                HStack(alignment: .firstTextBaseline) {
                    Text(task.title)
                    Spacer()
                    Text(timeText(task.completedAt ?? task.updatedAt))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Label(
                "今日完了 (\(model.completedToday.count))",
                systemImage: "checkmark.circle.fill"
            )
            .foregroundStyle(.green)
        }
    }

    private var activitySection: some View {
        Section {
            if model.activityToday.isEmpty {
                Text("今日動いたセッションはまだありません")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            ForEach(model.activityToday) { item in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(item.title)
                        Spacer()
                        Text(stateText(item.state))
                            .font(.caption)
                            .foregroundStyle(stateColor(item.state))
                    }
                    Text(subtitle(for: item))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Label(
                "今日の動き (\(model.activityToday.count))",
                systemImage: "antenna.radiowaves.left.and.right"
            )
            .foregroundStyle(.gray)
        }
    }

    private var remainingSection: some View {
        Section {
            if model.remainingToday.isEmpty {
                Text("今日やるタスクはすべて完了しています")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            ForEach(model.remainingToday) { task in
                Text(task.title)
            }
        } header: {
            Label(
                "今日やるの残り (\(model.remainingToday.count))",
                systemImage: "sun.max"
            )
            .foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private var reportSection: some View {
        if let html = model.reportHTML {
            Section {
                // The page owns its own layout, so the height is fixed here
                // rather than measured: the list must not fight the web view
                // over how much room the report gets.
                ReportWebView(html: html)
                    .frame(minHeight: 460)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            } header: {
                Label("日報", systemImage: "doc.text")
                    .foregroundStyle(.purple)
            }
        } else if let fallback = model.reportFallback {
            Section {
                // The model answered with something that is not a report.
                // Showing it verbatim beats showing an empty page.
                Text(verbatim: fallback)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            } header: {
                Label("日報（整形できませんでした）", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
        }
    }

    // MARK: - Helpers

    private func stateText(_ state: DailyReporter.ActivityState) -> String {
        state.displayName
    }

    /// 確認待ち reads as "still mine to do", but a session can also sit there
    /// because the work finished and the tab was left open. The row shows the
    /// state and the elapsed time and leaves that call to the user.
    private func stateColor(_ state: DailyReporter.ActivityState) -> Color {
        switch state {
        case .running: .green
        case .awaitingUser: .orange
        case .quiet: .secondary
        }
    }

    private func subtitle(for item: DailyReporter.ActivityItem) -> String {
        var parts: [String] = []
        if !item.project.isEmpty { parts.append(item.project) }
        parts.append("\(timeText(item.firstActivity))–\(timeText(item.lastActivity))")
        if item.sessionCount > 1 { parts.append("セッション\(item.sessionCount)件") }
        parts.append(item.agents.map(\.displayName).joined(separator: ", "))
        if !item.openTodos.isEmpty { parts.append("未完了\(item.openTodos.count)件") }
        return parts.joined(separator: " · ")
    }

    private func timeText(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    private func copyReport() {
        guard let markdown = model.reportMarkdown else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(markdown, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }

    /// Opens the report in the default browser, from a temporary file: the
    /// page is self-contained, so a file URL is enough.
    private func openInBrowser() {
        guard let html = model.reportHTML else { return }
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("airtraffic-report-\(UUID().uuidString).html")
        do {
            try html.write(to: file, atomically: true, encoding: .utf8)
            NSWorkspace.shared.open(file)
        } catch {
            model.lastError = "\(error)"
        }
    }

    private func saveHTML() {
        guard let html = model.reportHTML else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(defaultFileName()).html"
        panel.allowedContentTypes = [.html]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try html.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            model.lastError = "\(error)"
        }
    }

    private func defaultFileName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return "日報-\(formatter.string(from: Date()))"
    }
}
