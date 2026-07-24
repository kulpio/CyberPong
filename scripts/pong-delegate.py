#!/usr/bin/env python3
"""Legacy entrypoint → pong delegate (job + transports)."""
from __future__ import annotations

import sys
from pathlib import Path


def _insert_pong_paths() -> None:
    """Resolve bundled package + ~/.pong/lib + repo checkout.

    When packaged into CyberPong.app/Contents/Resources/, the package lives at
    Resources/python (not Contents/python). Repo layout keeps scripts/ next to python/.
    """
    here = Path(__file__).resolve().parent
    candidates = [
        here / "python",  # app: Contents/Resources/python
        here.parent / "python",  # repo: ROOT/python when script is scripts/
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

# Map old flags: remaining args after script name
args = ["delegate", *sys.argv[1:]]
from pong.cli.main import main

raise SystemExit(main(args))
