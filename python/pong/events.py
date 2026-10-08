"""Append-only event log for audit + UI tail."""

from __future__ import annotations

import json
import time
from pathlib import Path
from typing import Any

from .paths import secure_file, state_dir
from .schema import EVENT_TYPES

# High-frequency refuses must not balloon events.jsonl (was 300MB+ of route.refused).
_RATE_LIMITED_TYPES = frozenset({"route.refused"})
# (type, session, reason) → last emit wall time
_rate_last: dict[tuple[str, str, str], float] = {}
_RATE_INTERVAL_SEC = 30.0
_RATE_MAP_MAX = 512
# Reset rate map when PONG_HOME / state dir changes (tests + multi-home)
_rate_state_dir: str | None = None
# Tail window: never read whole multi-hundred-MB log into memory
_TAIL_BYTES = 256_000


def events_path() -> Path:
    return state_dir() / "events.jsonl"


def _rate_key(event_type: str, session: str | None, payload: dict[str, Any]) -> tuple[str, str, str]:
    sess = str(session or payload.get("session") or "")
    reason = str(payload.get("reason") or payload.get("message") or "")[:120]
    return (event_type, sess, reason)


def _should_emit_rate_limited(event_type: str, session: str | None, payload: dict[str, Any]) -> bool:
    """Return False if this high-frequency event should be dropped (spam).

    First emission for a (type, session, reason) always lands; subsequent ones
    within ``_RATE_INTERVAL_SEC`` are dropped so a stuck token_mismatch loop
    cannot grow events.jsonl without bound.
    """
    global _rate_state_dir
    if event_type not in _RATE_LIMITED_TYPES:
        return True
    # Fresh state tree (e.g. unittest PONG_HOME) → clear counters
    sd = str(state_dir())
    if _rate_state_dir != sd:
        _rate_last.clear()
        _rate_state_dir = sd
    now = time.time()
    key = _rate_key(event_type, session, payload)
    last = _rate_last.get(key)
    if last is not None and (now - last) < _RATE_INTERVAL_SEC:
        return False
    _rate_last[key] = now
    # Bound map size (drop oldest-ish by clearing half when huge)
    if len(_rate_last) > _RATE_MAP_MAX:
        # Keep most recent half
        items = sorted(_rate_last.items(), key=lambda kv: kv[1], reverse=True)
        _rate_last.clear()
        for k, t in items[: _RATE_MAP_MAX // 2]:
            _rate_last[k] = t
    return True


def emit(event_type: str, *, session: str | None = None, **payload: Any) -> dict[str, Any]:
    if event_type not in EVENT_TYPES:
        payload = {"original_type": event_type, **payload}
        event_type = "system"
    if not _should_emit_rate_limited(event_type, session, payload):
        # Quiet drop — first event for key still lands (interval check after write time)
        return {
            "ts": time.time(),
            "type": event_type,
            "session": session,
            "_dropped": "rate_limited",
            **{k: v for k, v in payload.items() if v is not None},
        }
    row: dict[str, Any] = {
        "ts": time.time(),
        "type": event_type,
    }
    if session:
        row["session"] = session
    for k, v in payload.items():
        if v is not None:
            row[k] = v
    path = events_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as f:
        f.write(json.dumps(row, ensure_ascii=False) + "\n")
    secure_file(path, 0o600)
    return row


def _read_tail_bytes(path: Path, max_bytes: int = _TAIL_BYTES) -> bytes:
    """Read only the last *max_bytes* of *path* (never the whole multi-MB file)."""
    try:
        size = path.stat().st_size
    except OSError:
        return b""
    if size <= 0:
        return b""
    try:
        with path.open("rb") as f:
            if size > max_bytes:
                f.seek(size - max_bytes)
                data = f.read(max_bytes)
            else:
                data = f.read()
        return data
    except OSError:
        return b""


def tail(n: int = 50, *, session: str | None = None) -> list[dict[str, Any]]:
    path = events_path()
    if not path.exists():
        return []
    data = _read_tail_bytes(path, _TAIL_BYTES)
    if not data:
        return []
    text = data.decode("utf-8", errors="replace")
    # If we started mid-line, drop the partial first line
    if path.stat().st_size > _TAIL_BYTES and "\n" in text:
        text = text.split("\n", 1)[1]
    rows: list[dict[str, Any]] = []
    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            row = json.loads(line)
        except Exception:
            continue
        if session and row.get("session") != session:
            continue
        rows.append(row)
    return rows[-n:]
