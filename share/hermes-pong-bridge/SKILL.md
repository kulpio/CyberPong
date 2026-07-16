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
3. Apply autonomy (below)
4. If more code is needed → **another** `claude-delegate` call (never local coding)

## Autonomy (per pair)

```bash
python3 - <<'PY'
import json
from pathlib import Path
p = Path.home() / ".hermes-pong" / "active-pair.json"
d = json.loads(p.read_text()) if p.exists() else {}
print(d.get("autonomy_level", "ask_on_done"))
PY
```

| Level | Behavior |
|-------|----------|
| `ask_every` | After each Claude reply, stop and ask the user |
| `ask_on_done` | Keep bridging until `##CLAUDE_DONE##`, then report |
| `full` | Keep bridging toward the goal with minimal interrupts |

Set in the Hermes Pong control panel (Every / Done / Full on the active pair).  
Autonomy is **not** auto-injected into Claude — you enforce it by how you loop.

## Pre-flight

If the Claude side is a bare shell (`$` / `%`), stop and re-Link to the real Claude Code terminal.  
See `references/shell-vs-tui-preflight.md` and `references/routing.md`.

## Prompt bank

**Feature:** Implement `<SPEC>` in the open project. Edit real files. Ship. End with `##CLAUDE_DONE##` + file list.

**Bug:** Bug `<WHAT>`; evidence `<ERR>`. Root-cause, fix, verify. End with `##CLAUDE_DONE##`.

**Stepwise:** Goal `<GOAL>`. Do only step N. End with `##CLAUDE_DONE##` + proposed next step.

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
