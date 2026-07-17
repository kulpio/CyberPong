#!/usr/bin/env python3
"""pong-gate.py — exit guidance for Hermes when a Hermes Pong pair is active.

stdout:
  BRIDGE_OFF
  BRIDGE_ON session=... mode=... autonomy=...

exit codes:
  0 — ok (bridge off or on)
  2 — registered but unhealthy (missing session name / bad state)

stderr additionally carries the verdict-ledger summary (LEDGER / PATTERNS
lines) so the discriminator's memory is re-armed every loop. stdout and exit
codes are a stable contract — new info goes to stderr only.
"""
from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
from pathlib import Path

STATE = Path.home() / ".hermes-pong" / "active-pair.json"


def print_ledger_stderr() -> None:
    """LEDGER + PATTERNS lines on stderr. Never fatal, never touches stdout."""
    try:
        path = Path(__file__).resolve().parent / "pong-ledger.py"
        spec = importlib.util.spec_from_file_location("pong_ledger", path)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        line = mod.stats_line()
        if line is None:
            print("LEDGER: empty (first pair — verify everything)", file=sys.stderr)
            return
        print(f"LEDGER: {line}", file=sys.stderr)
        patterns = mod.patterns_line(3)
        if patterns:
            print(f"PATTERNS: {patterns}", file=sys.stderr)
    except Exception as e:
        print(f"LEDGER: unavailable ({e})", file=sys.stderr)


def main() -> int:
    if not STATE.exists():
        print("BRIDGE_OFF")
        return 0
    try:
        d = json.loads(STATE.read_text())
    except Exception:
        print("BRIDGE_OFF")
        return 0

    sess = d.get("session")
    if not sess:
        print("BRIDGE_OFF")
        return 0

    mode = d.get("claude_mode") or "tmux"
    # v1.3: the verdict loop always runs; legacy ask_* values may linger in
    # old state files but the stdout token format is unchanged.
    auto = d.get("autonomy_level") or "full"

    # Optional: is tmux session alive for tmux mode?
    alive = True
    if mode == "tmux":
        try:
            out = subprocess.run(
                ["tmux", "has-session", "-t", str(sess)],
                capture_output=True,
                text=True,
            )
            alive = out.returncode == 0
        except FileNotFoundError:
            # still treat as on; PATH issues shouldn't disable the rule
            alive = True

    if not alive:
        print(f"BRIDGE_UNHEALTHY session={sess} mode={mode} autonomy={auto}")
        print("RULE: do not code yourself; re-link or New pair first", file=sys.stderr)
        print_ledger_stderr()
        return 2

    print(f"BRIDGE_ON session={sess} mode={mode} autonomy={auto}")
    print(
        "RULE: orchestrate only — all code via: "
        "python3 ~/bin/claude-delegate.py --no-wait '... ##CLAUDE_DONE##'",
        file=sys.stderr,
    )
    print_ledger_stderr()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
