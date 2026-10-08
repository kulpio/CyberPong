"""Session drain — harvest, waitroom wrap, wait_on release, prune, snapshot.

This is the flush that must run even when the panel is quit. Snapshot may
still call into here; it is no longer the only flush.

Wraps the existing waitroom (no second queue).
"""

from __future__ import annotations

import time
from typing import Any

WATCH_INTERVAL_SEC = 2.0
ATTENTION_SEC = 30.0
PRUNE_DELIVERED_SEC = 24 * 3600


def _session_list(session: str | None) -> list[str]:
    if session:
        return [session]
    try:
        from .snapshot import list_team_sessions

        return list_team_sessions()
    except Exception:
        return []


def _harvest(session: str) -> list[str]:
    try:
        from .claim_harvest import harvest_session
    except Exception:
        return []
    try:
        claimed = harvest_session(session)
    except Exception:
        return []
    return [str(j.get("id") or "") for j in claimed if j]


def _waitroom(session: str, *, force: bool = False) -> dict[str, Any]:
    from .waitroom import try_deliver

    return try_deliver(session, force=force)


def _prune(session: str, *, now: float | None = None) -> int:
    try:
        from .waitroom import prune_delivered
    except Exception:
        return 0
    try:
        return prune_delivered(session, now=now)
    except Exception:
        return 0


def _attention(session: str, *, now: float | None = None) -> list[str]:
    """Waitroom delivered-but-unacked >30s → mailbox attention."""
    from .mailbox import has_unacked, list_items as mb_list, post
    from .waitroom import list_items

    now_t = time.time() if now is None else now
    posted: list[str] = []
    try:
        items = list_items(session, status="delivered", kind="claim")
    except Exception:
        return []
    for it in items:
        try:
            delivered_at = float(it.get("delivered_at") or 0)
        except (TypeError, ValueError):
            delivered_at = 0.0
        if delivered_at <= 0 or (now_t - delivered_at) < ATTENTION_SEC:
            continue
        seat = str(it.get("to") or "c1")
        jid = str(it.get("job_id") or "")
        # Already have an unread attention for this job? skip
        existing = [
            m
            for m in mb_list(session, seat, unread_only=True, kind="attention")
            if str(m.get("job_id") or "") == jid
        ]
        if existing:
            continue
        if not has_unacked(session, seat, job_id=jid):
            # Mailbox never landed — still raise attention
            pass
        try:
            item = post(
                session,
                seat,
                kind="attention",
                from_seat=str(it.get("from") or ""),
                job_id=jid,
                summary=(
                    f"waitroom delivered {int(now_t - delivered_at)}s ago "
                    f"but mailbox unacked · {it.get('summary') or jid}"
                ),
                extra={"waitroom_id": it.get("id")},
            )
            posted.append(item["id"])
        except Exception:
            continue
    return posted


def _release_waits(session: str) -> dict[str, Any]:
    try:
        from .work_graph import tick
    except Exception:
        return {"advanced": [], "released": []}
    try:
        return tick(session)
    except Exception as e:
        import sys
        import traceback

        sys.stderr.write(f"pong drain: goal tick for {session} failed: {type(e).__name__}: {e}\n")
        traceback.print_exc(file=sys.stderr)
        return {"advanced": [], "released": [], "error": str(e)}


def _snapshot(session: str) -> None:
    try:
        from .snapshot import write_snapshot

        write_snapshot(session=session)
    except Exception:
        pass


def run(
    session: str,
    *,
    force: bool = False,
    now: float | None = None,
    write_snap: bool = True,
) -> dict[str, Any]:
    """One drain pass for *session*."""
    try:
        from .cron import apply_token

        apply_token(session)
    except Exception:
        pass
    harvested = _harvest(session)
    wr = _waitroom(session, force=force)
    pruned = _prune(session, now=now)
    attention = _attention(session, now=now)
    waits = _release_waits(session)
    if write_snap:
        _snapshot(session)
    return {
        "session": session,
        "harvested": harvested,
        "waitroom": {
            "delivered": wr.get("delivered") or [],
            "held": wr.get("held") or [],
        },
        "pruned": pruned,
        "attention": attention,
        "released": waits.get("released") or [],
        "advanced": waits.get("advanced") or [],
    }


def run_all(
    session: str | None = None,
    *,
    force: bool = False,
    now: float | None = None,
    write_snap: bool = True,
) -> dict[str, Any]:
    sessions = _session_list(session)
    # One snapshot for the pass, covering what was drained. Writing it per team
    # left snapshot.json holding whichever team drained last, so the app and the
    # island lost every other team between polls.
    results = []
    for s in sessions:
        # One team's bad row must not stop every team after it, and the error
        # must land somewhere a person can read (runtime.log was empty for weeks).
        try:
            results.append(run(s, force=force, now=now, write_snap=False))
        except Exception as e:
            import sys
            import traceback

            sys.stderr.write(f"pong drain: {s}: {type(e).__name__}: {e}\n")
            traceback.print_exc(file=sys.stderr)
            results.append({"session": s, "error": f"{type(e).__name__}: {e}"})
    if write_snap and sessions:
        _snapshot(session) if session else _snapshot_all()
    return {"sessions": sessions, "results": results}


def _snapshot_all() -> None:
    try:
        from .snapshot import write_snapshot

        write_snapshot(session=None)
    except Exception:
        pass


def watch(
    session: str | None = None,
    *,
    interval: float = WATCH_INTERVAL_SEC,
    force: bool = False,
    loops: int | None = None,
) -> None:
    """~2s loop. ``loops`` is for tests; None runs forever."""
    n = 0
    while True:
        run_all(session, force=force)
        n += 1
        if loops is not None and n >= loops:
            return
        time.sleep(max(0.2, float(interval)))
