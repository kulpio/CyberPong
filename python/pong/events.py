"""Append-only event log for audit + UI tail."""

from __future__ import annotations

import json
import time
from pathlib import Path
from typing import Any

from .paths import secure_file, state_dir
from .schema import EVENT_TYPES


def events_path() -> Path:
    return state_dir() / "events.jsonl"


def emit(event_type: str, *, session: str | None = None, **payload: Any) -> dict[str, Any]:
    if event_type not in EVENT_TYPES:
        payload = {"original_type": event_type, **payload}
        event_type = "system"
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


def tail(n: int = 50, *, session: str | None = None) -> list[dict[str, Any]]:
    path = events_path()
    if not path.exists():
        return []
    # efficient-ish: read last ~256KB
    try:
        data = path.read_bytes()
        if len(data) > 256_000:
            data = data[-256_000:]
        text = data.decode("utf-8", errors="replace")
    except Exception:
        return []
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
