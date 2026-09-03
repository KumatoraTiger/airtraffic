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

## Running a command when a task arrives

The GitHub inbox can run a command of your own for every row it imports, once
per row. Which kinds of row fire it is up to you: review requests, your own
pull requests, assigned issues, or any combination. Review requests are the
default, since that is the row whose subject you have not read yet.

Airtraffic ships no command and knows nothing about any particular tool: you
write the command line, it substitutes `{url}`, `{repo}`, `{repoName}`, `{number}`, `{title}`,
`{taskId}` and `{outDir}`, and once the command writes anything into
`{outDir}` the task row grows a button that reveals that directory in the
Finder, newest page selected. Write as many files as you like: the app never
picks one for you.

The working directory takes the same placeholders, so `~/src/{repoName}` runs
the command inside the checkout of the repository the row came from.

The setting is off by default and does nothing until you also tick the
repositories it may run for.

Two more triggers share that command runner, that repository list and that
working directory, each with a command line of its own:

- **A label on an assigned issue.** Name a label (`ai`, say) and Airtraffic
  runs your command once for every open issue assigned to you that carries it
  — the way to hand an issue to a coding agent is then to label it on GitHub.
  It runs once per issue; to run it again, right-click the row in the board's
  自動実行 section and choose 「もう一度動けるようにする」.
- **A bot's review on your own pull request.** Runs once per batch of review
  comments, after the pull request's checks have finished, bounded by a daily
  limit per pull request so a bot and an agent cannot push each other back and
  forth forever. It adds `{commentUrl}` and `{author}` to the substitutions.

The 自動実行 section lists the runs still going and those that finished in the
last day. Everything older is housekeeping: a run's history row and the files
it wrote are both kept for 30 days and then deleted together, so the output
directory does not grow for the life of the install. A row whose files have
aged out keeps its outcome and loses its folder button.

Two things to know before turning it on:

- **The command line is never handed to a shell.** Arguments are split with
  shell-like quoting and passed straight to the process, so a pull request
  title containing shell metacharacters is one ordinary argument. The cost is
  that pipes, `&&` and redirection do not work — wrap those in a script of
  your own if you need them.
- **The command may read text somebody else wrote.** A pull request body or
  diff can contain instructions aimed at whatever agent you point at it, and that
  agent runs on your machine with your credentials, unattended. Run it with
  the narrowest permissions your tool offers (read-only tools, no network,
  a sandbox), and opt in only for repositories whose contributors you trust.

## Development

This repo is set up for agent-driven development: `CLAUDE.md` / `AGENTS.md`
carry the architecture map and rules, `make test` is the verification loop, and
CI runs build + tests + bundling on every push.

## License

MIT
