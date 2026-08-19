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
                        model.reportText == nil ? "日報を生成" : "日報を再生成",
                        systemImage: "sparkles")
                }
                .disabled(model.reportBusy)
                if model.reportBusy {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                if model.reportText != nil {
                    Button {
                        copyReport()
                    } label: {
                        Label(copied ? "コピーしました" : "コピー", systemImage: "doc.on.doc")
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
                HStack(alignment: .firstTextBaseline) {
                    Text(item.title)
                    Spacer()
                    Text(item.agents.map(\.displayName).joined(separator: ", "))
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
        if let report = model.reportText {
            Section {
                // Shown verbatim: the report is Markdown meant for pasting
                // elsewhere, so what you copy is exactly what you see.
                Text(verbatim: report)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            } header: {
                Label("日報", systemImage: "doc.text")
                    .foregroundStyle(.purple)
            }
        }
    }

    // MARK: - Helpers

    private func timeText(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    private func copyReport() {
        guard let report = model.reportText else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }
}
