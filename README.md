# Airtraffic ✈️

A macOS control tower for your parallel coding-agent sessions.

When you run many Claude Code / Codex / Grok sessions at once, the hard part is
knowing **which one is waiting on you** and **what should be done next**.
Airtraffic reads the session transcripts each agent already writes to disk and
gives you:

- **管制 (Sessions)** — every recent session across agents, with sessions that
  need your attention (permission prompts, input waits) pinned to the top.
  A menu bar badge shows how many sessions are blocked on you.
- **タスク (Tasks)** — one task list across all sessions, linked back to the
  sessions they came from. In-session todo lists (TodoWrite / update_plan) can
  be promoted into it.
- **壁打ち (Chat)** — a prioritization dialogue. The AI proposes an ordering
  with reasons; you apply it with one click or push back. Manual reorderings
  are recorded as preferences and fed into future proposals.

Everything runs locally. The only network calls are to the LLM provider you
configure (Gemini / OpenAI / Anthropic — pluggable), and API keys are stored in
the macOS Keychain.

## Supported agents

| Agent | Source read |
|---|---|
| Claude Code | `~/.claude/projects/**/*.jsonl` |
| Codex | `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` |
| Grok CLI | `~/.grok/sessions/**` + `active_sessions.json` |

Adapters are pluggable — see [CLAUDE.md](CLAUDE.md) for how to add one.

## Getting started

Requires macOS 14+ and the Xcode Command Line Tools (no Xcode.app needed).

```bash
make bundle
open dist/Airtraffic.app
```

`dist/` is a build directory that `make clean` wipes, so to keep the app around
— and reachable from Launchpad and Spotlight — copy it out once:

```bash
cp -R dist/Airtraffic.app /Applications/
```

Tasks live in `~/Library/Application Support/Airtraffic`, and API
keys in the Keychain — neither is inside the bundle, so replacing the app on a
later `make bundle` keeps your data.

Or during development:

```bash
make run    # launch from a debug build
make test   # run the test suite
```

Then open 設定 (Settings) in the app, pick an LLM provider, paste an API key,
and optionally enable LLM work labels (off by default).

## Development

This repo is set up for agent-driven development: `CLAUDE.md` / `AGENTS.md`
carry the architecture map and rules, `make test` is the verification loop, and
CI runs build + tests + bundling on every push.

## License

MIT
