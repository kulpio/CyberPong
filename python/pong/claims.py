"""Claim board — read-only merge of recorded claims and the delivery waitroom.

Why this module exists: the claim *text* lives on the job (``jobs.record_claim``
is the source of truth) but whether anyone has *seen* it lives in the waitroom.
Read either alone and you get half the answer — the job says a claim exists, the
waitroom says it is still queued for its target. ``pong claims`` merges the two
so any seat can read the board without waiting for a paste into c1.

Read-only by construction. Nothing here pastes, marks delivered, sets seat
status, or mutates a job. It is safe from a cron, a headless shell, or with tmux
stopped — the only writes anywhere on this path are the ``mkdir`` calls that
``paths.ensure_layout`` performs for every reader in the control plane.
"""

from __future__ import annotations

import time
from typing import Any

from .jobs import list_jobs
from .waitroom import _one_line, list_items

DEFAULT_LIMIT = 20

# Longest a summary may run in the text table. The waitroom stores its own
# 200-char line; this is only how much of it a terminal row shows.
SUMMARY_WIDTH = 96


def _seat_labels(session: str) -> dict[str, str]:
    """seat id → human label.

    Empty dict when there is no session state on disk (fresh box, tmux down,
    another machine). Labels are decoration: a missing one blanks a column, it
    never hides a claim.
    """
    try:
        from .state import conductor_from_state, load_session_state, workers_from_state

        state = load_session_state(session)
        if not state:
            return {}
        out: dict[str, str] = {}
        cond = conductor_from_state(state)
        if cond.get("id"):
            out[str(cond["id"])] = str(cond.get("label") or "")
        for w in workers_from_state(state):
            if w.get("id"):
                out[str(w["id"])] = str(w.get("label") or "")
        return out
    except Exception:
        return {}


def _claim_target_resolver(session: str):
    """worker id → the seat its claim is addressed to, per the architecture graph.

    Only used for rows the waitroom no longer holds (delivered items are pruned
    from some archives, and harvested claims may never have had an item). Same
    function ``flow.notify_claim`` routes with, so the board shows the target the
    system would actually use, memoised per worker.
    """
    cache: dict[str, str] = {}
    try:
        from .flow import claim_notify_targets
        from .state import load_session_state

        state = load_session_state(session) or {"session": session}
    except Exception:
        return lambda _worker: ""

    def resolve(worker: str) -> str:
        wid = str(worker or "")
        if not wid:
            return ""
        if wid not in cache:
            try:
                targets = claim_notify_targets(state, wid)
            except Exception:
                targets = []
            cache[wid] = str(targets[0]) if targets else ""
        return cache[wid]

    return resolve


def _row_key(job_id: str, item_id: str) -> str:
    """Merge key. Job id when there is one; otherwise the waitroom row stands alone."""
    jid = str(job_id or "").strip()
    return jid if jid else f"wr:{item_id}"


def _claim_ts(job: dict[str, Any], claim: dict[str, Any]) -> float | None:
    for raw in (claim.get("at"), job.get("updated_at"), job.get("created_at")):
        try:
            ts = float(raw or 0)
        except (TypeError, ValueError):
            continue
        if ts > 0:
            return ts
    return None


def _claim_text(claim: dict[str, Any]) -> str:
    for key in ("summary", "raw", "commands"):
        text = str(claim.get(key) or "").strip()
        if text:
            return _one_line(text, 200)
    return "(no summary)"


def collect_rows(session: str, *, now: float | None = None) -> list[dict[str, Any]]:
    """Every known claim for *session*, newest first, unfiltered.

    Union of two sources, keyed on job id:
    - job JSON with a non-empty ``claim`` dict (the text, and who filed it)
    - waitroom items of kind ``claim`` (who it is addressed to, and whether it
      is still queued — that is what ``unread`` means)

    A row from only one source is still a row: a claim recorded before the
    waitroom existed has no item, and a queued item whose job file was archived
    has no job.
    """
    now_t = time.time() if now is None else now
    labels = _seat_labels(session)
    rows: dict[str, dict[str, Any]] = {}

    for n, job in enumerate(list_jobs(session)):
        claim = job.get("claim")
        if not isinstance(claim, dict) or not claim:
            continue
        jid = str(job.get("id") or "")
        worker = str(job.get("worker") or "")
        # An id-less job file cannot merge with a waitroom item or be looked up,
        # but it is still a claim someone filed — give it its own row.
        rows[_row_key(jid, f"job{n}")] = {
            "job_id": jid,
            "worker": worker,
            "worker_label": str(job.get("worker_label") or labels.get(worker, "")),
            "to": "",
            "at": _claim_ts(job, claim),
            "summary": _claim_text(claim),
            "files": [str(f) for f in (claim.get("files") or [])][:12],
            "job_status": str(job.get("status") or ""),
            # No waitroom item means nothing is pending for this claim.
            "unread": False,
            "waitroom_id": None,
            "waitroom_status": None,
            "sources": ["job"],
        }

    # status=None → queued *and* delivered, so a read claim still shows as read.
    for item in list_items(session, status=None, kind="claim"):
        item_id = str(item.get("id") or "")
        jid = str(item.get("job_id") or "")
        key = _row_key(jid, item_id)
        status = str(item.get("status") or "queued")
        sender = str(item.get("from") or "")
        row = rows.get(key)
        if row is None:
            try:
                created = float(item.get("created_at") or 0) or None
            except (TypeError, ValueError):
                created = None
            row = {
                "job_id": jid,
                "worker": sender,
                "worker_label": labels.get(sender, ""),
                "to": "",
                "at": created,
                "summary": _one_line(str(item.get("summary") or "(no summary)"), 200),
                "files": [str(f) for f in (item.get("files") or [])][:12],
                "job_status": "",
                "unread": False,
                "waitroom_id": None,
                "waitroom_status": None,
                "sources": ["waitroom"],
            }
            rows[key] = row
        elif "waitroom" not in row["sources"]:
            row["sources"] = row["sources"] + ["waitroom"]
        row["to"] = str(item.get("to") or "") or row["to"]
        row["waitroom_id"] = item_id
        row["waitroom_status"] = status
        # Unread = still queued for its target. One queued item is enough:
        # a re-queued claim is unread even if an older copy was delivered.
        row["unread"] = row["unread"] or status == "queued"
        if not row["worker"]:
            row["worker"] = sender
            row["worker_label"] = labels.get(sender, "")

    resolve_target = _claim_target_resolver(session)
    out = list(rows.values())
    for row in out:
        if not row["to"]:
            row["to"] = resolve_target(row["worker"])
        row["age_sec"] = None if row["at"] is None else max(0.0, now_t - row["at"])
    out.sort(key=lambda r: (r["at"] is not None, r["at"] or 0.0), reverse=True)
    return out


def claim_board(
    session: str,
    *,
    seat: str | None = None,
    unread_only: bool = False,
    limit: int | None = DEFAULT_LIMIT,
    now: float | None = None,
) -> dict[str, Any]:
    """Filtered, limited claim board for *session*.

    ``seat`` keeps claims filed **by** that seat or addressed **to** it — both,
    because a lead asks "what did my group claim" and "what is waiting on me"
    with the same flag. ``limit`` of 0 or None means no limit.
    """
    rows = collect_rows(session, now=now)
    matched = rows
    if seat:
        want = str(seat).strip()
        matched = [r for r in matched if want in (r.get("worker"), r.get("to"))]
    if unread_only:
        matched = [r for r in matched if r.get("unread")]
    shown = matched if not limit or limit <= 0 else matched[: int(limit)]
    return {
        "session": session,
        "rows": shown,
        "shown": len(shown),
        "matched": len(matched),
        "total": len(rows),
        "unread": sum(1 for r in matched if r.get("unread")),
        "seat": str(seat).strip() if seat else None,
        "unread_only": bool(unread_only),
    }


def format_age(seconds: float | None) -> str:
    if seconds is None:
        return "—"
    s = max(0.0, float(seconds))
    if s < 90:
        return f"{int(s)}s"
    if s < 90 * 60:
        return f"{int(s / 60)}m"
    if s < 48 * 3600:
        return f"{int(s / 3600)}h"
    return f"{int(s / 86400)}d"


def format_board(board: dict[str, Any]) -> list[str]:
    """Text lines for the terminal. Job id is always its own column so
    ``pong claims | grep <job_id>`` works."""
    head = (
        f"claims {board.get('session')} · {board.get('shown')} shown / "
        f"{board.get('matched')} matched / {board.get('total')} total · "
        f"{board.get('unread')} unread"
    )
    filters = []
    if board.get("seat"):
        filters.append(f"seat={board['seat']}")
    if board.get("unread_only"):
        filters.append("unread only")
    if filters:
        head += " · " + ", ".join(filters)
    lines = [head, "(read-only: jobs + waitroom; nothing pasted, nothing marked delivered)"]
    if not board.get("rows"):
        lines.append("(no claims match)")
        return lines
    for r in board["rows"]:
        mark = "UNREAD" if r.get("unread") else "read  "
        who = str(r.get("worker") or "?")
        label = str(r.get("worker_label") or "")
        if label:
            who = f"{who} ({label})"
        to = str(r.get("to") or "?")
        lines.append(
            f"{mark}\t{r.get('job_id') or '(no job id)'}\t{who} → {to}\t"
            f"{format_age(r.get('age_sec'))}\t"
            f"{_one_line(str(r.get('summary') or ''), SUMMARY_WIDTH)}"
        )
    return lines
