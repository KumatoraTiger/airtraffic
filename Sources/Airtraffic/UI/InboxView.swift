import AirtrafficCore
import SwiftUI

struct InboxView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            if !model.extractionEnabled {
                Label("LLM によるタスク起票は設定でオフになっています", systemImage: "info.circle")
                    .foregroundStyle(.secondary)
            }
            if model.candidates.isEmpty {
                ContentUnavailableView(
                    "Inbox は空です",
                    systemImage: "tray",
                    description: Text("セッションの新着ログから抽出されたタスク候補がここに届きます。承認するとタスクになります"))
            }
            ForEach(model.candidates) { candidate in
                CandidateRow(candidate: candidate)
            }
        }
        .navigationTitle("Inbox（タスク候補）")
    }
}

struct CandidateRow: View {
    @Environment(AppModel.self) private var model
    let candidate: Candidate
    @State private var showRejectReason = false
    @State private var rejectReason = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(candidate.title).font(.headline)
                Spacer()
                confidenceBadge
            }
            if !candidate.detail.isEmpty {
                Text(candidate.detail).font(.callout)
            }
            if !candidate.excerpt.isEmpty {
                Text("「\(candidate.excerpt)」")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            HStack {
                Label(candidate.agent.displayName, systemImage: candidate.agent.symbol)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(candidate.createdAt, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("承認してタスク化") {
                    Task { await model.accept(candidate) }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                Button("却下") { showRejectReason = true }
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 6)
        .popover(isPresented: $showRejectReason) {
            VStack(alignment: .leading, spacing: 8) {
                Text("却下理由（任意・今後の抽出精度に使われます）")
                    .font(.caption)
                TextField("例: 既に完了している / タスクではない", text: $rejectReason)
                    .frame(width: 320)
                HStack {
                    Spacer()
                    Button("却下する") {
                        showRejectReason = false
                        Task {
                            await model.reject(
                                candidate,
                                reason: rejectReason.isEmpty ? nil : rejectReason)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding()
        }
    }

    private var confidenceBadge: some View {
        let percent = Int(candidate.confidence * 100)
        return Text("確信度 \(percent)%")
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                (candidate.confidence >= 0.7 ? Color.green : .orange).opacity(0.15),
                in: Capsule()
            )
            .foregroundStyle(candidate.confidence >= 0.7 ? .green : .orange)
    }
}
