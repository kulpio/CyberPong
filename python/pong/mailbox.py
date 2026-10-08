"""Per-seat mailbox — jsonl inbox + cursor.

Child-done is a mailbox item the parent can peek/ack. Tmux paste is only a
nudge; this file is the durable signal.

Layout::

    ~/.pong/sessions/<session>/mailbox/<seat>.jsonl
    ~/.pong/sessions/<session>/mailbox/<seat>.cursor

Cursor stores acked ids. ``peek`` returns unacked items; ``ack`` advances
the cursor. Append-only jsonl so a crash never loses a posted item.
"""

from __future__ import annotations

import json
import time
import uuid
from pathlib import Path
from typing import Any

from .paths import ensure_layout, sessions_dir

CURSOR_VERSION = 1


def mailbox_dir(session: str) -> Path:
    ensure_layout(session)
    d = sessions_dir(session) / "mailbox"
    d.mkdir(parents=True, exist_ok=True)
    try:
        d.chmod(0o700)
    except OSError:
        pass
    return d


def inbox_path(session: str, seat: str) -> Path:
    sid = str(seat or "").strip() or "c1"
    return mailbox_dir(session) / f"{sid}.jsonl"


def cursor_path(session: str, seat: str) -> Path:
    sid = str(seat or "").strip() or "c1"
    return mailbox_dir(session) / f"{sid}.cursor"


def _new_id() -> str:
    return f"mb_{int(time.time())}_{uuid.uuid4().hex[:8]}"


def _read_cursor(session: str, seat: str) -> dict[str, Any]:
    path = cursor_path(session, seat)
    if not path.is_file():
        return {"version": CURSOR_VERSION, "acked": []}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {"version": CURSOR_VERSION, "acked": []}
    if not isinstance(data, dict):
        return {"version": CURSOR_VERSION, "acked": []}
    acked = data.get("acked")
    if not isinstance(acked, list):
        acked = []
    return {
        "version": int(data.get("version") or CURSOR_VERSION),
        "acked": [str(x) for x in acked if x],
    }


def _write_cursor(session: str, seat: str, data: dict[str, Any]) -> None:
    path = cursor_path(session, seat)
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = {
        "version": CURSOR_VERSION,
        "acked": list(data.get("acked") or []),
        "updated_at": time.time(),
    }
    path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    try:
        path.chmod(0o600)
    except OSError:
        pass


def _read_items(session: str, seat: str) -> list[dict[str, Any]]:
    path = inbox_path(session, seat)
    if not path.is_file():
        return []
    out: list[dict[str, Any]] = []
    try:
        text = path.read_text(encoding="utf-8")
    except OSError:
        return []
    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            row = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(row, dict) and row.get("id"):
            out.append(row)
    return out


def post(
    session: str,
    seat: str,
    *,
    kind: str = "claim",
    from_seat: str = "",
    job_id: str = "",
    summary: str = "",
    result: dict[str, Any] | None = None,
    extra: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """Append one mailbox item. Raises on write failure (callers must not swallow)."""
    item: dict[str, Any] = {
        "id": _new_id(),
        "at": time.time(),
        "kind": str(kind or "claim"),
        "from": str(from_seat or ""),
        "to": str(seat or "").strip() or "c1",
        "job_id": str(job_id or ""),
        "summary": str(summary or ""),
        "result": result if isinstance(result, dict) else None,
    }
    if extra:
        for k, v in extra.items():
            if k not in item and not str(k).startswith("_"):
                item[k] = v
    path = inbox_path(session, seat)
    path.parent.mkdir(parents=True, exist_ok=True)
    line = json.dumps(item, ensure_ascii=False) + "\n"
    with path.open("a", encoding="utf-8") as f:
        f.write(line)
        f.flush()
    try:
        path.chmod(0o600)
    except OSError:
        pass
    try:
        from . import events

        events.emit(
            "mailbox.posted",
            session=session,
            seat=str(seat),
            job_id=item["job_id"],
            kind=item["kind"],
            mailbox_id=item["id"],
        )
    except Exception:
        pass
    return item


def peek(
    session: str,
    seat: str,
    *,
    limit: int | None = 50,
    kind: str | None = None,
) -> list[dict[str, Any]]:
    """Unread (unacked) items, oldest first. Does not advance the cursor."""
    acked = set(_read_cursor(session, seat).get("acked") or [])
    unread: list[dict[str, Any]] = []
    for it in _read_items(session, seat):
        if it.get("id") in acked:
            continue
        if kind and str(it.get("kind") or "") != kind:
            continue
        unread.append(it)
    if limit is None or limit <= 0:
        return unread
    return unread[: int(limit)]


def ack(session: str, seat: str, ids: list[str] | None = None) -> list[str]:
    """Mark items read. ``ids=None`` acks every current unread item."""
    unread = peek(session, seat, limit=0)
    if ids is None:
        want = [str(it.get("id")) for it in unread if it.get("id")]
    else:
        want = [str(i) for i in ids if i]
    if not want:
        return []
    cur = _read_cursor(session, seat)
    have = list(cur.get("acked") or [])
    seen = set(have)
    added: list[str] = []
    for i in want:
        if i not in seen:
            have.append(i)
            seen.add(i)
            added.append(i)
    cur["acked"] = have
    _write_cursor(session, seat, cur)
    return added


def list_items(
    session: str,
    seat: str | None = None,
    *,
    unread_only: bool = False,
    kind: str | None = None,
) -> list[dict[str, Any]]:
    """All items for one seat, or every seat when ``seat`` is None."""
    seats: list[str]
    if seat:
        seats = [str(seat)]
    else:
        d = mailbox_dir(session)
        seats = sorted(p.stem for p in d.glob("*.jsonl"))
    out: list[dict[str, Any]] = []
    for sid in seats:
        acked = set(_read_cursor(session, sid).get("acked") or [])
        for it in _read_items(session, sid):
            if kind and str(it.get("kind") or "") != kind:
                continue
            flagged = dict(it)
            flagged["acked"] = flagged.get("id") in acked
            if unread_only and flagged["acked"]:
                continue
            out.append(flagged)
    out.sort(key=lambda r: float(r.get("at") or 0), reverse=True)
    return out


def unread_counts(session: str) -> dict[str, int]:
    """seat → unread count. Used by the snapshot contract."""
    d = mailbox_dir(session)
    counts: dict[str, int] = {}
    for p in sorted(d.glob("*.jsonl")):
        seat = p.stem
        n = len(peek(session, seat, limit=0))
        if n:
            counts[seat] = n
    return counts


def has_unacked(session: str, seat: str, *, job_id: str | None = None, kind: str | None = None) -> bool:
    for it in peek(session, seat, limit=0, kind=kind):
        if job_id and str(it.get("job_id") or "") != str(job_id):
            continue
        return True
    return False


def snapshot_block(session: str) -> dict[str, Any]:
    counts = unread_counts(session)
    return {
        "unread": counts,
        "unread_total": sum(counts.values()),
        "seats": sorted(counts),
    }
