"""Select and run transports for a job."""

from __future__ import annotations

import os
from typing import Any

from .. import traces
from ..jobs import save_job
from . import headless, job_file, tmux_paste, window_paste
from .base import TransportResult


def parse_transport_plan(
    default: str,
    *,
    no_paste: bool = False,
    headless_only: bool = False,
    paste_only: bool = False,
) -> list[str]:
    if headless_only:
        return ["job_file", "headless"]
    if paste_only:
        return ["job_file", "tmux_paste", "window_paste"]
    if no_paste:
        return ["job_file"]
    d = (default or "job+paste").lower().strip()
    if d in ("job", "job_file", "file"):
        return ["job_file"]
    if d in ("headless", "cli"):
        return ["job_file", "headless"]
    if d in ("paste", "tmux"):
        return ["job_file", "tmux_paste"]
    if d in ("window",):
        return ["job_file", "window_paste"]
    # job+paste (default): file always; try paste for human-visible TUI
    return ["job_file", "tmux_paste", "window_paste"]


def _force_paste_env() -> bool:
    v = (os.environ.get("PONG_FORCE_JOB_PASTE") or "").strip().lower()
    return v in ("1", "true", "yes", "on")


def dispatch_job(
    job: dict[str, Any],
    worker: dict[str, Any],
    state: dict[str, Any],
    plan: list[str] | None = None,
    *,
    force_paste: bool = False,
) -> list[TransportResult]:
    """Write job file always; paste only if target seat is **available**.

    When the worker is busy, job stays ``queued`` and a waitroom ``kind=job``
    item is enqueued. ``force_paste`` / ``PONG_FORCE_JOB_PASTE=1`` bypasses.
    """
    plan = plan or parse_transport_plan(str(state.get("transport_default") or "job+paste"))
    results: list[TransportResult] = []
    used: list[str] = list(job.get("transports_used") or [])
    mode = str(worker.get("mode") or state.get("claude_mode") or "tmux")
    session = str(job.get("session") or state.get("session") or "")
    seat_id = str(worker.get("id") or job.get("worker") or "")

    wants_paste = any(n in plan for n in ("tmux_paste", "window_paste"))
    defer_paste = False
    if wants_paste and not force_paste and not _force_paste_env() and session and seat_id:
        try:
            from ..seat_status import is_available

            if not is_available(session, seat_id):
                defer_paste = True
        except Exception:
            defer_paste = False

    effective_plan = list(plan)
    if defer_paste:
        # Job file only; paste later via waitroom try_deliver
        effective_plan = [n for n in plan if n not in ("tmux_paste", "window_paste")]
        if "job_file" not in effective_plan:
            effective_plan.insert(0, "job_file")

    for name in effective_plan:
        if name == "job_file":
            r = job_file.send(job, worker, state)
        elif name == "tmux_paste":
            if mode == "window" and "window_paste" in plan:
                continue  # prefer window when worker is window-linked
            r = tmux_paste.send(job, worker, state)
        elif name == "window_paste":
            if mode != "window" and "tmux_paste" in plan:
                # try window only if tmux not in plan or after tmux fails — handled below
                if any(x.name == "tmux_paste" and x.ok for x in results):
                    continue
            if window_paste._isolated_home():
                # a temporary home never reaches a real Terminal window (tmux_paste guards its panes the same way)
                r = TransportResult("window_paste", False, window_paste.ISOLATED_DETAIL)
            else:
                r = window_paste.send(job, worker, state)
        elif name == "headless":
            r = headless.send(job, worker, state)
        else:
            r = TransportResult(name, False, "unknown transport")
        results.append(r)
        if r.ok and name not in used:
            used.append(name)

    if defer_paste:
        results.append(
            TransportResult(
                "waitroom",
                True,
                f"paste deferred — seat {seat_id} busy; queued for delivery",
                meta={"deferred": True, "seat": seat_id},
            )
        )
        try:
            from ..waitroom import enqueue_job

            enqueue_job(
                session,
                to=seat_id,
                job_id=str(job.get("id") or ""),
                summary=str(job.get("task") or "")[:120],
            )
        except Exception:
            pass

    job["transports_used"] = used
    for r in results:
        traces.transport_result(
            job, name=r.name, ok=r.ok, detail=r.detail, meta=r.meta
        )
    prev = str(job.get("status") or "queued")
    # job_file success ⇒ at least queued; any non-file notify ⇒ notified
    notify_ok = any(
        r.ok and r.name not in ("job_file", "waitroom") for r in results
    )
    file_ok = any(r.ok and r.name == "job_file" for r in results)
    if file_ok and notify_ok:
        job["status"] = "notified"
        job["error"] = None
        for r in results:
            if r.name == "headless" and r.ok and (r.meta or {}).get("stdout_tail"):
                job["headless_tail"] = r.meta["stdout_tail"]
        # Successful paste → seat busy on work
        try:
            from ..seat_status import set_busy

            set_busy(
                session,
                seat_id,
                reason="job",
                job_id=str(job.get("id") or ""),
            )
        except Exception:
            pass
    elif file_ok:
        job["status"] = "queued"
        if defer_paste:
            job["error"] = None
            job["delivery"] = "waitroom"
        else:
            job["error"] = "; ".join(
                f"{r.name}:{r.detail}"
                for r in results
                if not r.ok and r.name not in ("job_file", "waitroom")
            ) or None
    else:
        job["status"] = "failed"
        job["error"] = "job_file transport failed"
    save_job(job)
    try:
        from .. import events

        events.emit(
            "job.dispatch",
            session=str(job.get("session")),
            job_id=str(job.get("id")),
            status=job.get("status"),
            transports=[r.name for r in results if r.ok],
            deferred=defer_paste,
            **{"from": prev},
        )
        if prev != job.get("status"):
            events.emit(
                "job.status",
                session=str(job.get("session")),
                job_id=str(job.get("id")),
                status=job.get("status"),
                **{"from": prev},
            )
    except Exception:
        pass
    # After any dispatch, try deliver other seats (not a timer — event-driven)
    if session:
        try:
            from ..waitroom import try_deliver

            try_deliver(session, force=False, state=state)
        except Exception:
            pass
    return results
