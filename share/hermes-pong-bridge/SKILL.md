---
name: hermes-pong-bridge
description: Load when Hermes Pong is paired or when coding/building. While a pair is active, route ALL implementation through claude-delegate to Claude Code — never code yourself mid-session.
---

# Hermes Pong bridge

## When to load

- Hermes Pong, pair, Claude Code bridge, or tmux pair is mentioned
- You are about to implement, fix, or refactor product code
- `~/.hermes-pong/active-pair.json` may have a live `session`

## Hard rule

**While a pair is ACTIVE, you are the orchestrator only. Claude Code is the only coder.**

Forbidden while ACTIVE (including “quick” fixes after the first bridge send):

- Writing or patching product code yourself
- Dropping the bridge after 1–2 successful sends
- Raw `tmux send-keys` into a hidden pane

Allowed while ACTIVE:

- Read/search for context
- `claude-delegate.py` handoffs
- Run verification commands (tests, builds, diffs) — verifying is not coding
- Pair status / Front / Kill guidance
- Explaining Claude’s results to the user

## Gate (before every implementation step)

```bash
python3 ~/bin/pong-gate.py
```

| Result | Meaning |
|--------|---------|
| `BRIDGE_OFF` | You may implement yourself |
| `BRIDGE_ON …` | **Only** Claude via `claude-delegate.py` |
| exit `2` / unhealthy | Fix Link/New pair before coding |

Re-run this gate every loop. Do not skip it after the first send.

## How to send work

```bash
python3 ~/bin/claude-delegate.py --no-wait "$(cat <<'EOF'
<task>

When completely done, print exactly ##CLAUDE_DONE## on its own line, then a short summary of files changed / what you did.
EOF
)"
```

Then:

1. Wait / poll `~/.hermes-pong/last-claude.txt` (or watch the Claude window)
2. Read Claude’s result
3. Run the verdict loop (below)
4. If more code is needed → **another** `claude-delegate` call (never local coding)

For tasks with checkable criteria, write a task file from `~/.hermes-pong/templates/task.md` and send with:

```bash
python3 ~/bin/claude-delegate.py --no-wait --criteria path/to/task.md '<task>'
```

Criteria must be *checkable* — a command with an expected exit/output, not vibes.

## Verdict loop

**Never accept `##CLAUDE_DONE##` on the claim alone** — same rule as never inventing it from a timeout. While ACTIVE you may (and must) run verification commands: the acceptance checks from the task file, plus diffs/greps. Then:

1. All criteria pass → record `accept` (`python3 ~/bin/pong-ledger.py record --task-id <id> --round <N> --verdict accept --evidence '<what you checked>'`), announce `##HERMES_ACCEPT##`, move on.
2. Any criterion fails → record `reject` with evidence, send back through `claude-delegate.py` using this shape: `REJECTED round <N>: <criterion that failed>. Evidence: <exact output>. Fix only this. End with ##CLAUDE_DONE## + CLAIM block.` Rejections without specific evidence are **forbidden** — a bare “no” teaches nothing.
3. Three rejects on one task → record `escalate`, stop, surface the full verdict trail to the user.

**Check-gaming watchlist** — verify specifically that Claude did **not**: delete or skip failing tests, weaken assertions, or edit outside `## Out of scope`. If the check was gamed, that is a reject with the gaming named as evidence.

The loop always runs — there are no ask-modes. Work silently until **accept** (announce `##HERMES_ACCEPT##`, move on) or **escalate** (stop and surface the full verdict trail to the user). Legacy `ask_every` / `ask_on_done` values in old state files mean the same thing: run the loop.

The ledger lives in `~/.hermes-pong/ledger/` (`verdicts.jsonl` + `patterns.md`). `pong-gate.py` re-arms your memory of it (LEDGER / PATTERNS on stderr) every loop; run `python3 ~/bin/pong-ledger.py distill` after notable rejects. Recording is pairing-scoped: `record` refuses (exit 2) unless a pair is ACTIVE — record verdicts in the loop, before the pair is killed.

## Pre-flight

If the Claude side is a bare shell (`$` / `%`), stop and re-Link to the real Claude Code terminal.  
See `references/shell-vs-tui-preflight.md` and `references/routing.md`.

## Prompt bank

**Feature:** Implement `<SPEC>` in the open project. Edit real files. Ship. End with `##CLAUDE_DONE##` + CLAIM block.

**Bug:** Bug `<WHAT>`; evidence `<ERR>`. Root-cause, fix, verify. End with `##CLAUDE_DONE##` + CLAIM block.

**Stepwise:** Goal `<GOAL>`. Do only step N. End with `##CLAUDE_DONE##` + CLAIM block (proposed next step in `notes:`).

**Reject:** REJECTED round `<N>`: `<criterion that failed>`. Evidence: `<exact output>`. Fix only this. End with `##CLAUDE_DONE##` + CLAIM block.

## Recovery

```bash
cat ~/.hermes-pong/active-pair.json
tmux list-sessions | grep hermes || true
python3 ~/bin/pong-gate.py
python3 ~/bin/claude-delegate.py --no-wait 'Reply with pong only. Print ##CLAUDE_DONE##'
```

If bridge is off: open Hermes Pong → **New pair** or **Link existing terminals**.

## Anti-pattern

1. Pair connects  
2. Hermes sends 1–2 tasks to Claude  
3. Hermes starts coding with local tools  

**Never do step 3 while `pong-gate.py` says `BRIDGE_ON`.**
