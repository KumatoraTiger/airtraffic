import SwiftUI
import AirtrafficCore

struct ChatView: View {
    @Environment(AppModel.self) private var model
    @State private var input = ""

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if model.chatEntries.isEmpty {
                            ContentUnavailableView(
                                "優先順位の壁打ち",
                                systemImage: "bubble.left.and.bubble.right",
                                description: Text("「今なにを先にやるべき？」と聞くと、タスクとセッション状況をもとに順位と理由を提案します"))
                                .padding(.top, 60)
                        }
                        ForEach(model.chatEntries) { entry in
                            ChatBubble(entry: entry)
                                .id(entry.id)
                        }
                        if model.chatBusy {
                            ProgressView().padding(.leading, 12)
                        }
                    }
                    .padding()
                }
                .onChange(of: model.chatEntries.count) {
                    if let last = model.chatEntries.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
            Divider()
            HStack {
                TextField("今なにを先にやるべき？", text: $input)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { submit() }
                Button("送信") { submit() }
                    .disabled(input.isEmpty || model.chatBusy)
            }
            .padding(10)
        }
        .navigationTitle("壁打ち")
    }

    private func submit() {
        let text = input
        input = ""
        Task { await model.sendChat(text) }
    }
}

struct ChatBubble: View {
    @Environment(AppModel.self) private var model
    let entry: ChatEntry
    @State private var applied = false

    var body: some View {
        HStack {
            if entry.sender == .user { Spacer(minLength: 60) }
            VStack(alignment: .leading, spacing: 8) {
                Text(entry.text)
                    .textSelection(.enabled)
                if let proposal = entry.proposal {
                    Button(applied ? "適用しました" : "この順位を適用") {
                        applied = true
                        Task { await model.applyRanking(proposal) }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(applied)
                }
            }
            .padding(10)
            .background(
                entry.sender == .user
                    ? AnyShapeStyle(Color.accentColor.opacity(0.15))
                    : AnyShapeStyle(.quaternary),
                in: RoundedRectangle(cornerRadius: 10))
            if entry.sender == .assistant { Spacer(minLength: 60) }
        }
    }
}
