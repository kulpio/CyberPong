#!/usr/bin/env python3
"""Legacy hermes_pong.py CLI — status / session / write-bind."""
from __future__ import annotations

import argparse
import sys
from pathlib import Path


def _insert_pong_paths() -> None:
    here = Path(__file__).resolve().parent
    candidates = [
        here / "python",  # app: Contents/Resources/python
        here.parent / "python",  # repo: ROOT/python
        Path.home() / ".pong" / "lib",
    ]
    for c in candidates:
        if (c / "pong").is_dir() or (c / "pong" / "__init__.py").is_file():
            s = str(c)
            if s not in sys.path:
                sys.path.insert(0, s)
            return
    for c in candidates:
        s = str(c)
        if s not in sys.path:
            sys.path.insert(0, s)


_insert_pong_paths()

from pong.state import (  # noqa: E402
    detect_bound_session,
    format_team_roster,
    gate_text,
    load_session_state,
    write_bind_card,
)
from pong.paths import state_dir  # noqa: E402


def main() -> int:
    ap = argparse.ArgumentParser(prog="hermes_pong.py")
    ap.add_argument("cmd", choices=("status", "session", "write-bind"))
    ap.add_argument("--session", "-s", default=None)
    args = ap.parse_args()
    sess = detect_bound_session(args.session)
    if args.cmd == "session":
        print(sess or "")
        return 0 if sess else 1
    if args.cmd == "write-bind":
        if not sess:
            print("no session", file=sys.stderr)
            return 2
        print(write_bind_card(sess))
        return 0
    # status
    state = load_session_state(sess)
    g, _ = gate_text(sess)
    print(f"state_dir={state_dir()}")
    print(f"bound_session={sess or ''}")
    print(f"gate={g}")
    if state:
        print(f"roster={format_team_roster(state)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
