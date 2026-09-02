# Airtraffic — development guide for coding agents

macOS app that watches local coding-agent sessions (Claude Code / Codex / Grok),
surfaces which ones are waiting on the user, and helps prioritize tasks in a chat.

## Commands

```bash
make build      # debug build (all targets)
make test       # run the test suite — ALWAYS run before finishing a change
make run        # launch the app from the debug build
make bundle     # build dist/Airtraffic.app (release)
make fmt        # format sources with the toolchain's swift-format
make fmt-check  # lint formatting (CI runs this)
```

Constraints of this environment:

- **No Xcode.app** — only Command Line Tools. Therefore no XCTest / Swift Testing.
  Tests are a plain executable (`Sources/AirtrafficTestRunner`) with a tiny harness
  in `TestKit.swift`. Add tests by appending `TestKit.shared.run("name") { ... }`
  blocks and using `expect` / `expectEqual` / `unwrap`.
- **No external dependencies** — the package builds with the Apple toolchain alone
  (SQLite via the system `libsqlite3`). Keep it that way unless there is a strong
  reason.
- **A debug build shares the installed app's data.** `HOME` does not move
  Application Support, so `.build/debug/Airtraffic` opens the same store and
  runs the same migrations as the app the user has running. For a UI check,
  set `AIRTRAFFIC_DATA_DIR=/tmp/somewhere` and pass `-github.enabled 0
  -automation.enabled 0` so nothing real is synced or launched.

## Architecture

Three SPM targets:

- `AirtrafficCore` (library, public API) — all logic, no UI
  - `Models/` — `SessionSnapshot`, `TaskItem`, `PreferenceNote`
  - `Ingestion/` — one adapter per agent + shared `StatusResolver` / `FileTail`.
    Adapters are **stateful incremental parsers**: first scan parses the whole
    file to rebuild state, later scans read only appended bytes.
  - `Store/` — SQLite persistence (tasks, preferences, cursors).
    Sessions are NOT persisted; transcripts on disk are the source of truth.
  - `LLM/` — provider-agnostic `LLMClient` + Gemini/OpenAI/Anthropic raw-HTTP
    clients + `KeychainStore`. Adding a provider = new client + a case in
    `ProviderKind` + `LLMClientFactory`.
  - `Services/` — `IngestionCoordinator` (scan loop), `SessionLabeler`
    (LLM → work labels), `Prioritizer` (chat prompts + ranking parsing)
- `Airtraffic` (executable) — SwiftUI app. `AppModel` is the single
  `@Observable` state holder; views are thin.
- `airtraffic-tests` (executable) — the test suite.

## How session status is derived

`StatusResolver.resolve` in `Ingestion/AgentAdapter.swift`:
fresh writes → `running`; pending tool_use gone quiet → `waitingApproval`;
assistant turn end with no follow-up → `waitingInput`; older than 4h → `idle`.
Grok differs: liveness comes from `active_sessions.json` + process check.

## Adding a new agent adapter

1. Create `Ingestion/<Name>Adapter.swift` conforming to `AgentAdapter`,
   modeled on `CodexAdapter` (JSONL) or `GrokAdapter` (metadata files).
2. Add a case to `AgentKind` (display name + SF Symbol).
3. Register it in `IngestionCoordinator.standard()`.
4. Add tests with **synthetic fixtures generated in temp dirs**.

## Rules (this repo is public)

- **Never commit real transcripts, real paths containing usernames, or API
  keys.** Test fixtures use fictional data (user "alex", `/Users/alex/...`).
- API keys live in the macOS Keychain (`KeychainStore`) or env vars — never in
  UserDefaults, files, or code.
- Resolve home-relative paths at runtime via
  `FileManager.default.homeDirectoryForCurrentUser` — never hardcode a home dir.
- UI text is Japanese; code, comments, and commit messages are English.
- Run `make test` and `make build` before declaring any change done.
