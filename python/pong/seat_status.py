"""Per-seat busy / available state for delivery waitroom.

Durable file: ``~/.pong/sessions/<session>/seat_status.json``

**Availability rule (ordered):**
1. Explicit ``busy`` in status file → busy (unless stale — see below)
2. Else if seat has non-terminal job in ``{notified, running}`` → busy
3. Else if explicit ``available`` → available
4. Else → **available** (cold start / seat prime)

Bias: false busy (hold) > false idle (stomp). Map visual active is never used.

Stale busy: explicit busy older than ``PONG_SEAT_STALE_BUSY_SEC`` (default 2h)
with **no** open notified/running job → auto-available + event.

Closed-job busy: an explicit busy row that names a ``job_id`` already in
``{done, failed, rejected, cancelled}``, with no other open job, is released
immediately — the seat was busy *because of* that job. ``human_takeover`` is
excluded: the job is terminal but a human holds the pane.
"""

from __future__ import annotations

import json
import os
import time
from pathlib import Path
from typing import Any

from .paths import ensure_layout, sessions_dir

DEFAULT_STALE_BUSY_SEC = 2 * 3600  # 2 hours
# Legacy sticky reason from claim digests — auto-free quickly so c1 does not starve
DEFAULT_CLAIM_DIGEST_BUSY_SEC = 60.0
# Human console paste to orch — busy while human is mid-conversation, not forever
DEFAULT_HUMAN_BUSY_SEC = 15 * 60
# A just-spawned pane is not ready for a paste: the agent CLI is still drawing
# its first screen. Holding the seat briefly sends the job through the waitroom
# instead, which lands once the seat is genuinely free.
DEFAULT_STARTING_BUSY_SEC = 45.0
OPEN_BUSY_STATUSES = frozenset({"notified", "running"})
# Terminal statuses that release the seat. ``human_takeover`` is terminal for the
# job but NOT for the seat — a human is at that pane, so it must stay held.
CLOSED_JOB_STATUSES = frozenset({"done", "failed", "rejected", "cancelled"})
# Reasons with short TTL (auto-available without open job)
SHORT_TTL_REASONS = frozenset({"claim_digest", "human"})


def _stale_sec() -> float:
    raw = (os.environ.get("PONG_SEAT_STALE_BUSY_SEC") or "").strip()
    if raw:
        try:
            return max(60.0, float(raw))
        except ValueError:
            pass
    return float(DEFAULT_STALE_BUSY_SEC)


def _claim_digest_busy_sec() -> float:
    raw = (os.environ.get("PONG_CLAIM_DIGEST_BUSY_SEC") or "").strip()
    if raw:
        try:
            return max(0.0, float(raw))
        except ValueError:
            pass
    return DEFAULT_CLAIM_DIGEST_BUSY_SEC


def _human_busy_sec() -> float:
    raw = (os.environ.get("PONG_HUMAN_BUSY_SEC") or "").strip()
    if raw:
        try:
            return max(30.0, float(raw))
        except ValueError:
            pass
    return float(DEFAULT_HUMAN_BUSY_SEC)


def busy_ttl_sec(reason: str) -> float | None:
    """Return auto-free TTL for a busy reason, or None if only long stale applies."""
    r = (reason or "").strip().lower()
    if r == "claim_digest":
        return _claim_digest_busy_sec()
    if r == "human":
        return _human_busy_sec()
    if r == "starting":
        raw = (os.environ.get("PONG_STARTING_BUSY_SEC") or "").strip()
        if raw:
            try:
                return max(5.0, float(raw))
            except ValueError:
                pass
        return float(DEFAULT_STARTING_BUSY_SEC)
    return None


def seat_status_path(session: str) -> Path:
    ensure_layout(session)
    return sessions_dir(session) / "seat_status.json"


def load_seat_status(session: str) -> dict[str, Any]:
    path = seat_status_path(session)
    if not path.is_file():
        return {"seats": {}}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {"seats": {}}
    if not isinstance(data, dict):
        return {"seats": {}}
    seats = data.get("seats")
    if not isinstance(seats, dict):
        seats = {}
    return {"seats": seats}


def save_seat_status(session: str, data: dict[str, Any]) -> None:
    path = seat_status_path(session)
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = {"seats": data.get("seats") or {}}
    path.write_text(json.dumps(payload, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    try:
        path.chmod(0o600)
    except OSError:
        pass


def get_status(session: str, seat: str) -> dict[str, Any]:
    """Return raw seat row or empty dict if never set."""
    data = load_seat_status(session)
    row = data["seats"].get(str(seat))
    return dict(row) if isinstance(row, dict) else {}


def _open_jobs_for_seat(session: str, seat: str) -> list[dict[str, Any]]:
    try:
        from .jobs import list_jobs

        return [
            j
            for j in list_jobs(session)
            if str(j.get("worker") or "") == str(seat)
            and str(j.get("status") or "") in OPEN_BUSY_STATUSES
        ]
    except Exception:
        return []


def _busy_job_closed(session: str, row: dict[str, Any]) -> bool:
    """True when a busy row names a job that has already closed.

    A job file we cannot read is **not** treated as closed: an unreadable store
    should leave the seat held for the long stale path rather than free it.
    """
    jid = str(row.get("job_id") or "").strip()
    if not jid:
        return False
    try:
        from .jobs import load_job

        job = load_job(session, jid)
    except Exception:
        return False
    if not job:
        return False
    return str(job.get("status") or "") in CLOSED_JOB_STATUSES


def is_available(session: str, seat: str, *, now: float | None = None) -> bool:
    """True if waitroom may paste to *seat* (conservative)."""
    ok, _ = availability(session, seat, now=now)
    return ok


def availability(
    session: str,
    seat: str,
    *,
    now: float | None = None,
) -> tuple[bool, str]:
    """Return (available, reason). Does not use map dots."""
    t = time.time() if now is None else now
    sid = str(seat)
    row = get_status(session, sid)
    explicit = str(row.get("state") or "").strip().lower()
    updated = float(row.get("updated_at") or 0)
    open_jobs = _open_jobs_for_seat(session, sid)

    if explicit == "busy":
        age = t - updated if updated else 0.0
        reason = str(row.get("reason") or "busy")
        # Short-TTL reasons (legacy claim_digest sticky, human console)
        ttl = busy_ttl_sec(reason)
        if ttl is not None and not open_jobs:
            if age >= ttl:
                set_available(session, sid, reason=f"{reason}_ttl_auto")
                return True, f"{reason}_ttl_auto_available"
            remain = max(0.0, ttl - age)
            return False, f"{reason} (auto-free in {remain:.0f}s)"
        # Long stale busy with no open work → free the seat
        if age >= _stale_sec() and not open_jobs:
            set_available(session, sid, reason="stale_busy_auto")
            return True, "stale_busy_auto_available"
        # "Busy because of job X" must not outlive X. record_claim frees the
        # seat itself, but every other close path goes through jobs.set_status
        # (hygiene_cancel_stale, `pong job status <id> cancelled|failed`), which
        # does not — leaving the row busy against a job that is already closed,
        # so the seat's next queued job waits out the 2h stale timer. The jobs
        # store is already authoritative in the other direction (an open job
        # overrides an "available" row below), so reconcile here, at the single
        # reader, instead of at each writer.
        if not open_jobs and _busy_job_closed(session, row):
            set_available(session, sid, reason="job_closed_auto")
            return True, "job_closed_auto_available"
        if open_jobs:
            return False, f"busy+open_job={open_jobs[0].get('id')}"
        return False, reason

    if open_jobs:
        return False, f"open_job={open_jobs[0].get('id')} status={open_jobs[0].get('status')}"

    if explicit == "available":
        return True, "explicit_available"

    # Cold start / never seen
    return True, "default_available"


def set_busy(
    session: str,
    seat: str,
    *,
    reason: str = "work",
    job_id: str | None = None,
) -> dict[str, Any]:
    data = load_seat_status(session)
    row = {
        "state": "busy",
        "reason": (reason or "work")[:120],
        "job_id": job_id or "",
        "updated_at": time.time(),
    }
    data["seats"][str(seat)] = row
    save_seat_status(session, data)
    try:
        from . import events

        events.emit(
            "seat.busy",
            session=session,
            seat=str(seat),
            reason=row["reason"],
            job_id=row["job_id"] or None,
        )
    except Exception:
        pass
    return row


def set_available(
    session: str,
    seat: str,
    *,
    reason: str = "ready",
) -> dict[str, Any]:
    data = load_seat_status(session)
    row = {
        "state": "available",
        "reason": (reason or "ready")[:120],
        "job_id": "",
        "updated_at": time.time(),
    }
    data["seats"][str(seat)] = row
    save_seat_status(session, data)
    try:
        from . import events

        events.emit(
            "seat.available",
            session=session,
            seat=str(seat),
            reason=row["reason"],
        )
    except Exception:
        pass
    return row


def all_statuses(session: str) -> dict[str, Any]:
    """Resolved status for known seats + any rows in the file."""
    from .state import conductor_from_state, load_session_state, workers_from_state

    st = load_session_state(session) or {}
    ids: list[str] = []
    c = conductor_from_state(st)
    if c:
        ids.append(str(c.get("id") or "c1"))
    else:
        ids.append("c1")
    for w in workers_from_state(st):
        wid = str(w.get("id") or "")
        if wid and wid not in ids:
            ids.append(wid)
    raw = load_seat_status(session)["seats"]
    for k in raw:
        if k not in ids:
            ids.append(str(k))
    # Queue depth per target seat (soft inbox)
    queue_by: dict[str, int] = {}
    try:
        from .waitroom import list_items

        for it in list_items(session, status="queued"):
            to = str(it.get("to") or "c1")
            queue_by[to] = queue_by.get(to, 0) + 1
    except Exception:
        pass
    out: dict[str, Any] = {}
    now = time.time()
    for sid in ids:
        avail, reason = availability(session, sid, now=now)
        row = get_status(session, sid)
        exp_reason = str(row.get("reason") or "")
        free_in: float | None = None
        if not avail and str(row.get("state") or "") == "busy":
            ttl = busy_ttl_sec(exp_reason)
            if ttl is not None:
                age = now - float(row.get("updated_at") or 0)
                free_in = max(0.0, ttl - age)
        out[sid] = {
            "state": "available" if avail else "busy",
            "reason": reason,
            "explicit": row.get("state") or "",
            "explicit_reason": exp_reason,
            "job_id": row.get("job_id") or "",
            "updated_at": row.get("updated_at") or 0,
            "queue_depth": queue_by.get(sid, 0),
            "free_in_sec": free_in,
        }
    return out
