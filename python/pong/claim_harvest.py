"""Recover a claim when the worker finished a turn but never ran `pong job claim`.

Grok seats write a Recap and go idle. Claude seats often print a CLAIM: block
and stop. The job stays `notified`, the seat stays busy, and twenty minutes
later the island paints them stuck.

This module reads an idle pane, parses Recap / CLAIM, and records the claim
so the control plane matches what the human already sees.
"""

from __future__ import annotations

import re
from typing import Any

from . import events
from .pane_activity import _tmux, is_thinking

_JOB_ID = re.compile(r"job_\d{8}_\d{6}_[0-9a-f]+")
_CLAIM = re.compile(
    r"CLAIM:\s*\n\s*files:\s*(?P<files>.+?)\n\s*commands:\s*(?P<commands>.+?)"
    r"\n\s*summary:\s*(?P<summary>.+?)(?:\n\s*\n|\n##|\Z)",
    re.I | re.S,
)
_RECAP = re.compile(
    r"◆\s*Recap\s+(?P<summary>.+?)(?:\n\s*\n|\n\s*╭)",
    re.S,
)
_HOLDING = re.compile(r"\bHolding for\b", re.I)
_OPEN = frozenset({"notified", "running"})


def capture_seat_pane(session: str, worker_id: str, worker: dict[str, Any] | None = None) -> str:
    """Prefer the dedicated per-seat tmux session; fall back to the roster window."""
    worker = worker or {}
    ok, out = _tmux(
        "capture-pane", "-p", "-J", "-t", f"={session}-{worker_id}:", "-S", "-120"
    )
    if ok and (out or "").strip():
        return out
    # A graph seat (c1.c) is not on the roster and has no tmux_index: its pane
    # is only in panes.json. Without this a node that printed its CLAIM block
    # but never ran `pong job claim` sat until the 2-hour stale cancel.
    try:
        from .routing import load_pane_registration

        from .groups import pane_owned

        pane = str((load_pane_registration(session, worker_id) or {}).get("pane_id") or "")
        if pane and pane_owned(pane, session, worker_id):
            ok, out = _tmux("capture-pane", "-p", "-J", "-t", pane, "-S", "-120")
            if ok and (out or "").strip():
                return out
    except Exception:
        pass
    idx = worker.get("tmux_index")
    if isinstance(idx, int):
        ok, out = _tmux(
            "capture-pane", "-p", "-J", "-t", f"{session}:{idx}", "-S", "-120"
        )
        if ok:
            return out
    return ""


def _clean(text: str) -> str:
    cleaned = (text or "").replace("┃", " ").replace("◆", " ")
    return " ".join(cleaned.split())


def _files(raw: str) -> list[str]:
    out: list[str] = []
    for part in (raw or "").split(","):
        p = part.strip().strip("`")
        if not p or p.lower() in {"none", "(none)", "n/a"}:
            continue
        out.append(p)
    return out


def parse_pane_claim(pane: str, job: dict[str, Any]) -> dict[str, Any] | None:
    """Return files/commands/summary/raw/source, or None if this is not a finished claim."""
    text = pane or ""
    if not text.strip():
        return None
    if _HOLDING.search(text) and not _CLAIM.search(text):
        return None
    job_id = str(job.get("id") or "")
    ids = _JOB_ID.findall(text)
    has_recap = bool(_RECAP.search(text))
    has_claim = bool(_CLAIM.search(text))
    # Leftover CLAIM from an earlier job — do not close this one with it.
    if ids and job_id not in ids and has_claim:
        return None
    if ids and job_id not in ids and not (has_recap and "TEAM CONTEXT" in text):
        return None

    m = _CLAIM.search(text)
    if m:
        summary = _clean(m.group("summary"))
        if len(summary) < 12:
            return None
        return {
            "files": _files(m.group("files")),
            "commands": _clean(m.group("commands")),
            "summary": summary,
            "raw": m.group(0).strip(),
            "source": "claim_block",
        }
    r = _RECAP.search(text)
    if r:
        summary = _clean(r.group("summary"))
        if len(summary) < 20:
            return None
        return {
            "files": [],
            "commands": "harvested from pane Recap",
            "summary": summary,
            "raw": r.group(0).strip(),
            "source": "recap",
        }
    return None


def _looks_like_prior_claim(
    session: str, worker_id: str, parsed: dict[str, Any], *, exclude_job: str
) -> bool:
    from .jobs import list_jobs

    needle = (parsed.get("summary") or "")[:80]
    if not needle:
        return False
    # A leftover Grok Recap still on screen after it was harvested onto an earlier job of this seat.
    for j in list_jobs(session):
        if str(j.get("id") or "") == exclude_job:
            continue
        if str(j.get("worker") or "") != worker_id:
            continue
        if str(j.get("status") or "") != "done":
            continue
        prev = ((j.get("claim") or {}) if isinstance(j.get("claim"), dict) else {})
        old = str(prev.get("summary") or "")[:80]
        if old and old == needle:
            return True
    try:
        from .waitroom import load_waitroom

        for it in load_waitroom(session).get("items") or []:
            if str(it.get("from") or "") != worker_id:
                continue
            if str(it.get("summary") or "")[:80] == needle:
                return True
    except Exception:
        pass
    return False


def harvest_job(
    session: str,
    job: dict[str, Any],
    *,
    pane: str | None = None,
    worker: dict[str, Any] | None = None,
) -> dict[str, Any] | None:
    """If this open job has a harvestable idle-pane claim, record it and return the job."""
    from .jobs import record_claim

    if str(job.get("status") or "") not in _OPEN:
        return None
    if job.get("claim"):
        return None
    wid = str(job.get("worker") or "")
    text = pane if pane is not None else capture_seat_pane(session, wid, worker)
    if not text or is_thinking(text):
        return None
    parsed = parse_pane_claim(text, job)
    if not parsed:
        return None
    if _looks_like_prior_claim(session, wid, parsed, exclude_job=str(job.get("id") or "")):
        return None
    claimed = record_claim(
        session,
        str(job["id"]),
        files=parsed["files"],
        commands=parsed["commands"],
        summary=parsed["summary"],
        raw=parsed.get("raw") or parsed["summary"],
    )
    events.emit(
        "job.claim_harvested",
        session=session,
        job_id=str(job.get("id") or ""),
        worker=wid,
        source=parsed.get("source") or "",
    )
    return claimed


def harvest_session(session: str) -> list[dict[str, Any]]:
    """Scan every open notified/running job and record harvestable claims."""
    from .jobs import open_jobs
    from .state import load_session_state, workers_from_state

    state = load_session_state(session) or {"session": session}
    by_id = {str(w.get("id")): w for w in workers_from_state(state)}
    out: list[dict[str, Any]] = []
    for job in list(open_jobs(session)):
        try:
            claimed = harvest_job(
                session, job, worker=by_id.get(str(job.get("worker") or ""))
            )
        except Exception:
            continue
        if claimed:
            out.append(claimed)
    return out
