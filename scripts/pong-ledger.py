#!/usr/bin/env python3
"""Legacy ledger CLI → pong ledger."""
from __future__ import annotations

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
from pong.cli.main import main

# argv: record|summary|distill …
raise SystemExit(main(["ledger", *sys.argv[1:]]))
