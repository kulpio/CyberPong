"""Loop kinds as data — JSON catalog, not org-edge enums.

Bundled defaults live next to this module in ``python/pong/loops/*.json``.
Session overrides: ``~/.pong/sessions/<session>/loops/*.json``.
Machine overrides: ``~/.pong/loops/*.json``.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from .paths import sessions_dir, state_dir

_PKG = Path(__file__).resolve().parent / "loops"

KINDS = frozenset({"fan", "join", "router", "cycle", "gauntlet", "graph"})
FAN_CAP = 4
GAUNTLET_PIECES_CAP = 6


class LoopError(ValueError):
    pass


def _load_json(path: Path) -> dict[str, Any] | None:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return None
    return data if isinstance(data, dict) else None


def _roots(session: str | None = None) -> list[Path]:
    roots: list[Path] = []
    if session:
        roots.append(sessions_dir(session) / "loops")
    roots.append(state_dir() / "loops")
    roots.append(_PKG)
    return roots


def list_kinds(session: str | None = None) -> list[str]:
    found: set[str] = set()
    for root in _roots(session):
        if not root.is_dir():
            continue
        for p in root.glob("*.json"):
            data = _load_json(p)
            kind = str((data or {}).get("kind") or p.stem).strip().lower()
            if kind in KINDS:
                found.add(kind)
    return sorted(found)


def load_loop(kind: str, session: str | None = None) -> dict[str, Any]:
    key = str(kind or "").strip().lower()
    if key not in KINDS:
        raise LoopError(f"unknown loop kind {kind!r}; want one of {sorted(KINDS)}")
    for root in _roots(session):
        path = root / f"{key}.json"
        if not path.is_file():
            continue
        data = _load_json(path)
        if not data:
            continue
        data = dict(data)
        data.setdefault("kind", key)
        data["_path"] = str(path)
        return data
    # Catalog missing — still a valid kind with defaults
    return {"kind": key, "version": 1, "nodes": [], "edges": []}


def assert_start_args(
    kind: str,
    *,
    bar: str | None,
    fan_n: int | None = None,
    examples: object = None,
) -> None:
    key = str(kind or "").strip().lower()
    if key not in KINDS:
        raise LoopError(f"unknown loop kind {kind!r}; want one of {sorted(KINDS)}")
    spec = load_loop(key)
    has_examples = False
    if isinstance(examples, str):
        has_examples = bool(examples.strip())
    elif isinstance(examples, (list, tuple)):
        has_examples = any(bool(x) for x in examples)
    if key == "gauntlet" or spec.get("requires_bar"):
        if not (bar or "").strip() and not has_examples:
            raise LoopError("gauntlet requires --bar PATH or at least one example")
    if key == "fan" and fan_n is not None and int(fan_n) > FAN_CAP:
        raise LoopError(f"fan cap is {FAN_CAP} (got {fan_n})")
