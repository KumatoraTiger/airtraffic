import AirtrafficCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section("LLM プロバイダ") {
                Picker("使用するプロバイダ", selection: $model.selectedProvider) {
                    ForEach(ProviderKind.allCases) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
            }
            ForEach(ProviderKind.allCases) { kind in
                ProviderSettingsSection(kind: kind)
            }
            Section("LLM 連携") {
                Toggle("LLM で作業ラベルの生成を行う", isOn: $model.labelingEnabled)
                Text(
                    "作業ラベルは各セッションが何の作業か（レビュー・設計など）を行に表示するもので、動きのあるセッションだけ約60秒ごとに更新されます。"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            GitHubSection()
            PomodoroSoundSection()
            Section("学習した優先順位の傾向") {
                if model.preferences.isEmpty {
                    Text("まだありません。タスクを手動で並べ替えると記録されます。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(model.preferences) { preference in
                    Text(preference.text).font(.caption)
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct ProviderSettingsSection: View {
    @Environment(AppModel.self) private var model
    let kind: ProviderKind
    @State private var apiKey = ""
    @State private var keyStored = false
    @State private var testResult: String?

    var body: some View {
        @Bindable var model = model
        Section(kind.displayName) {
            TextField(
                "モデル",
                text: Binding(
                    get: { model.models[kind] ?? kind.defaultModel },
                    set: { model.models[kind] = $0 }
                ))
            HStack {
                SecureField(
                    keyStored ? "キーは Keychain に保存済み（変更する場合のみ入力）" : "API キー",
                    text: $apiKey)
                Button("保存") {
                    KeychainStore.setAPIKey(apiKey, for: kind)
                    apiKey = ""
                    keyStored = KeychainStore.apiKey(for: kind) != nil
                }
                .disabled(apiKey.isEmpty)
            }
            HStack {
                Button("接続テスト") {
                    testResult = "テスト中…"
                    Task { testResult = await model.testConnection(kind) }
                }
                if let testResult {
                    Text(testResult).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if keyStored {
                    Button("キーを削除", role: .destructive) {
                        KeychainStore.deleteAPIKey(for: kind)
                        keyStored = false
                    }
                }
            }
            Text("キーは macOS Keychain にのみ保存されます。環境変数 \(kind.apiKeyEnvName) も利用できます。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onAppear { keyStored = KeychainStore.apiKey(for: kind) != nil }
    }
}

/// Pomodoro chimes: the sound that marks the end of each phase. The options
/// are the macOS system sounds, so nothing is bundled with the app.
struct PomodoroSoundSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Section("ポモドーロの音") {
            chimeRow("作業終了の音", selection: $model.soundSettings.workEndChime)
            chimeRow("休憩終了の音", selection: $model.soundSettings.restEndChime)
            Text("スピーカーボタンで音を試せます。「なし」を選ぶと無音のまま切り替わります。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func chimeRow(
        _ title: String, selection: Binding<PomodoroChime>
    ) -> some View {
        HStack {
            Picker(title, selection: selection) {
                ForEach(PomodoroChime.allCases) { chime in
                    Text(chime.displayName).tag(chime)
                }
            }
            Button {
                model.previewChime(selection.wrappedValue)
            } label: {
                Image(systemName: "speaker.wave.2.fill")
            }
            .buttonStyle(.borderless)
            .disabled(selection.wrappedValue == .none)
            .help("音を試す")
        }
    }
}

/// GitHub inbox settings. Repositories are opted out, not in: the list below
/// fills itself from what the sync sees, and unchecking one stops its import.
struct GitHubSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Section("GitHub 連携") {
            Toggle("担当 issue・自分の PR・レビュー依頼をタスクにする", isOn: $model.githubEnabled)
            Text("GitHub CLI (gh) のログインを使います。アプリはトークンを保存しません。5分ごとに同期します。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("GitHub 側で close / merge されたら", selection: $model.githubCloseBehavior) {
                ForEach(GitHubCloseBehavior.allCases) { behavior in
                    Text(behavior.displayName).tag(behavior)
                }
            }
            HStack {
                Button("今すぐ同期") { Task { await model.runGitHubPass() } }
                    .disabled(!model.githubEnabled)
                if let status = model.githubStatus {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
            }
            if model.githubRepos.isEmpty {
                Text("同期するとリポジトリがここに並びます。外したいものだけオフにしてください。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(model.githubRepos, id: \.self) { repo in
                Toggle(
                    repo,
                    isOn: Binding(
                        get: { !model.githubExcludedRepos.contains(repo) },
                        set: { included in
                            if included {
                                model.githubExcludedRepos.remove(repo)
                            } else {
                                model.githubExcludedRepos.insert(repo)
                            }
                        }))
            }
        }
    }
}
