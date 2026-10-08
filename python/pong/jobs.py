"""Job control plane — source of truth for handoffs."""

from __future__ import annotations

import time
import uuid
from pathlib import Path
from typing import Any

from . import events, traces
from .jsonutil import read_json, write_json
from .paths import ensure_layout, jobs_dir
from .schema import (
    JOB_STATUSES,
    SchemaError,
    TERMINAL_STATUSES,
    assert_transition,
    job_summary,
    validate_job,
)
from .state import (
    format_permissions_block,
    format_team_context,
    load_session_state,
    resolve_worker,
    session_artifact,
)

# re-export for callers
STATUSES = JOB_STATUSES


def new_job_id() -> str:
    ts = time.strftime("%Y%m%d_%H%M%S")
    return f"job_{ts}_{uuid.uuid4().hex[:6]}"


def job_path(session: str, job_id: str) -> Path:
    return jobs_dir(session) / f"{job_id}.json"


def load_job(session: str, job_id: str) -> dict[str, Any]:
    return read_json(job_path(session, job_id))


def save_job(job: dict[str, Any]) -> Path:
    errs = validate_job(job)
    if errs:
        raise SchemaError("invalid job: " + "; ".join(errs))
    sess = str(job["session"])
    jid = str(job["id"])
    ensure_layout(sess)
    job["updated_at"] = time.time()
    # strip ephemeral keys before disk
    disk = {k: v for k, v in job.items() if not str(k).startswith("_")}
    path = job_path(sess, jid)
    write_json(path, disk)
    write_json(jobs_dir(sess) / "latest.json", {"id": jid, "path": str(path)})
    return path


def list_jobs(session: str, *, status: str | None = None) -> list[dict[str, Any]]:
    d = jobs_dir(session)
    if not d.exists():
        return []
    out: list[dict[str, Any]] = []
    for p in sorted(d.glob("job_*.json"), reverse=True):
        j = read_json(p)
        if not j:
            continue
        if status and j.get("status") != status:
            continue
        out.append(j)
    return out


def open_jobs(session: str) -> list[dict[str, Any]]:
    return [
        j
        for j in list_jobs(session)
        if j.get("status") not in TERMINAL_STATUSES
    ]


# --- Activity age (align Mission STUCK / RUNTIME thresholds) ---
# notified/queued soft-activity: 20 minutes; running: 45 minutes.
# Auto-cancel abandoned notified/queued after 2 hours; running after 24 hours.
ACTIVITY_NOTIFIED_QUEUED_MAX_AGE = 20 * 60
ACTIVITY_RUNNING_MAX_AGE = 45 * 60
STALE_NOTIFIED_CANCEL_AGE = 2 * 3600
STALE_RUNNING_CANCEL_AGE = 24 * 3600


def job_age_seconds(job: dict[str, Any], *, now: float | None = None) -> float:
    """Age from updated_at, then created_at. Missing timestamps → 0 (treat as fresh)."""
    now_t = time.time() if now is None else now
    raw = job.get("updated_at")
    if raw is None:
        raw = job.get("created_at")
    try:
        ts = float(raw or 0)
    except (TypeError, ValueError):
        ts = 0.0
    if ts <= 0:
        return 0.0
    return max(0.0, now_t - ts)


def is_activity_fresh(job: dict[str, Any], *, now: float | None = None) -> bool:
    """Whether a non-terminal job still counts toward map seat activity."""
    st = str(job.get("status") or "").lower()
    age = job_age_seconds(job, now=now)
    if st == "human_takeover" or job.get("human_takeover"):
        return True
    if st in ("notified", "queued"):
        return age <= ACTIVITY_NOTIFIED_QUEUED_MAX_AGE
    if st == "running" or "working" in st:
        return age <= ACTIVITY_RUNNING_MAX_AGE
    # Other non-terminal: include while under notified threshold
    return age <= ACTIVITY_NOTIFIED_QUEUED_MAX_AGE


def activity_open_jobs(session: str, *, now: float | None = None) -> list[dict[str, Any]]:
    """Open jobs fresh enough to drive status_hint / map ACTIVE pulse."""
    now_t = time.time() if now is None else now
    return [j for j in open_jobs(session) if is_activity_fresh(j, now=now_t)]


def cancel_stale_abandoned_jobs(
    session: str, *, now: float | None = None
) -> list[str]:
    """
    Durable hygiene: auto-cancel abandoned jobs.
    - notified / queued age > 2h → cancelled (cancel_reason=stale_notified)
    - running age > 24h → cancelled (cancel_reason=stale_running)
    Returns cancelled job ids.
    """
    now_t = time.time() if now is None else now
    cancelled: list[str] = []
    for j in list(open_jobs(session)):
        jid = str(j.get("id") or "")
        if not jid:
            continue
        st = str(j.get("status") or "").lower()
        age = job_age_seconds(j, now=now_t)
        reason: str | None = None
        if st in ("notified", "queued") and age > STALE_NOTIFIED_CANCEL_AGE:
            reason = "stale_notified"
        elif st == "running" and age > STALE_RUNNING_CANCEL_AGE:
            reason = "stale_running"
        if not reason:
            continue
        try:
            set_status(
                session,
                jid,
                "cancelled",
                skip_snapshot=True,
                cancel_reason=reason,
                error=f"auto-cancelled: {reason}",
            )
            cancelled.append(jid)
        except Exception:
            # Best-effort hygiene; never break snapshot
            pass
    return cancelled


def build_task_prompt(job: dict[str, Any], state: dict[str, Any]) -> str:
    """Full text a worker would see (TUI paste or headless)."""
    parts: list[str] = []
    worker_id = str(job.get("worker") or "")

    ctx = format_team_context(state, graph_step=bool(job.get("work_node") and job.get("graph_node")))
    if ctx:
        parts.append(ctx.rstrip())
    perms = format_permissions_block(state)
    if perms:
        parts.append(perms.rstrip())

    # Durable role + who-is-who (so humans need not re-brief each boot)
    if not job.get("no_identity"):
        try:
            from .role_identity import format_seat_identity
            from .state import workers_from_state as _wfs

            _on_roster = any(str(w.get("id")) == worker_id for w in _wfs(state))
            ident = format_seat_identity(state, worker_id,
                                         role=None if _on_roster else (job.get("mission_role") or None))
            if ident.strip():
                parts.append(ident.rstrip())
        except Exception:
            pass

    # Architecture road + hop recap (hard guardrails, not suggestions)
    if not job.get("no_recap"):
        try:
            from .role_identity import format_architecture_guardrails

            from .state import workers_from_state as _wfs2

            _rostered = any(str(w.get("id")) == worker_id for w in _wfs2(state))
            road = format_architecture_guardrails(state, worker_id,
                                                  role=None if _rostered else (job.get("mission_role") or None))
            if road.strip():
                parts.append(road.rstrip())
        except Exception:
            try:
                from .handoff_recap import architecture_recap_for_seat

                recap = architecture_recap_for_seat(state, worker_id)
                if recap.strip():
                    parts.append(recap.rstrip())
            except Exception:
                pass

    parts.append(f"## JOB `{job['id']}`")
    parts.append(f"- worker: {job.get('worker')}")
    try:
        from .role_identity import normalize_role, role_meta, seat_mission_role
        from .state import workers_from_state

        on_roster = any(str(w.get("id")) == worker_id for w in workers_from_state(state))
        if not on_roster and job.get("mission_role"):
            mr = normalize_role(str(job["mission_role"]))
        else:
            mr = seat_mission_role(state, worker_id)
        parts.append(f"- mission_role: {role_meta(mr)['title']} ({mr})")
    except Exception:
        pass
    parts.append(f"- round: {job.get('round', 1)}")
    if job.get("work_node") and job.get("runtime"):
        who = f"- runs on: {job.get('runtime')}"
        if job.get("model"):
            who += f" · {job.get('model')}"
        if job.get("model_why"):
            who += f" — {job.get('model_why')}"
        parts.append(who)
    if job.get("project_root"):
        parts.append(f"- project_root: {job['project_root']}")
    parts.append("")
    parts.append(
        "### Seat availability\n"
        "You are **busy** while on this job (system marks busy on paste). "
        "Claim/done → you become **available** for the next delivery. "
        "Do not expect mid-task peer pastes. Optional: `##SEAT_BUSY##` / `##SEAT_AVAILABLE##`."
    )
    parts.append("")
    parts.append(str(job.get("task") or "").rstrip())
    parts.append("")
    acc = job.get("acceptance") or []
    if acc:
        parts.append("## Acceptance")
        for i, a in enumerate(acc, 1):
            if isinstance(a, dict):
                parts.append(
                    f"{i}. `{a.get('cmd')}` (expect exit {a.get('expect_exit', 0)})"
                )
            else:
                parts.append(f"{i}. {a}")
        parts.append("")
    # The bar the reviewer will apply, published to the builder before it starts.
    # A standard that only shows up at grading time produces surprise, not quality.
    try:
        from .review_bar import (
            bar_for_reviewer,
            bar_for_seat,
            format_criteria_block,
            reviewers_for_seat,
            seats_covered_by,
        )

        _bar = bar_for_seat(state, worker_id)
        if _bar:
            parts.append(format_criteria_block(_bar, for_reviewer=False))
            _rev = reviewers_for_seat(state, worker_id)
            if _rev:
                parts.append(
                    f"Quality authority on this work: {', '.join(_rev)}. "
                    "Within this bar their instruction is binding — treat it like a "
                    "job, not a suggestion. c1 still decides what gets built."
                )
            parts.append("")
        else:
            # The bar-setter reads the same standard, from the other side.
            _applies = bar_for_reviewer(state, worker_id)
            if _applies:
                parts.append(format_criteria_block(_applies, for_reviewer=True))
                _covered = seats_covered_by(state, worker_id)
                if _covered:
                    parts.append(
                        f"You hold this bar for: {', '.join(_covered)}. "
                        "Judgment and instruction only — you never edit their files, "
                        "and you do not review seats outside that list."
                    )
                parts.append("")
    except Exception as exc:
        # A silent failure here deletes the published standard from every job
        # and nothing anywhere says so: builders stop seeing the bar, reviewers
        # keep scoring against it, and the mismatch looks like the agents
        # drifting. Say it out loud on both channels a human might read.
        import sys as _sys
        import traceback as _tb

        _sys.stderr.write(
            f"pong: review bar NOT attached to {job.get('id')} "
            f"({worker_id}): {type(exc).__name__}: {exc}\n"
        )
        _tb.print_exc(file=_sys.stderr)
        parts.append(
            "> **Review bar unavailable for this job.** The published standard "
            "could not be loaded, so this job is going out without it — tell c1 "
            "rather than guessing at the criteria."
        )
        parts.append("")
        try:
            from .events import emit

            emit(
                "review_bar_error",
                session=str(job.get("session") or ""),
                job_id=str(job.get("id") or ""),
                worker=worker_id,
                error=f"{type(exc).__name__}: {exc}",
            )
        except Exception:
            # Events are best-effort; stderr above already carried the failure.
            pass
    marker = job.get("done_marker") or "##WORKER_DONE##"
    jid = str(job.get("id") or "")
    if job.get("work_node") and (job.get("claim_outcomes") or job.get("claim_default") or job.get("graph_notes")
                                 or job.get("graph_notes_append_only")):
        # A graph step: the first word of the claim picks the next edge, so say
        # which words exist and where each leads. A critic that did not know
        # this claimed empty and ended a graph (2026-09-23).
        lines = ["## How this step ends"]
        words = [str(w) for w in (job.get("claim_outcomes") or []) if str(w).strip()]
        routes = job.get("claim_routes") if isinstance(job.get("claim_routes"), dict) else {}
        default = [str(t) for t in (job.get("claim_default") or []) if str(t).strip()]
        verdict = bool(job.get("claim_verdict", True))
        lead = " · ".join(
            f"`{w}`" + (f" → {', '.join(str(t) for t in routes.get(w) or [])}" if routes.get(w) else "")
            for w in words
        )
        if words and verdict:
            lines.append(
                f"Your claim summary must begin with one of: {lead}. The first word picks the next step; "
                "a claim without one of them is refused and counted as fail."
            )
        elif not verdict:
            # A step that owes no verdict (a writer, a builder): its normal claim carries no
            # verdict word. Telling it "must begin with fail" sent finished work to a person.
            if default:
                lines.append(
                    "When the step is done, write your claim summary as your task says, with no verdict word: "
                    f"it goes on to {', '.join(default)}."
                )
            if words:
                lines.append(
                    f"Only if you could not do the step, start the claim summary with one of: {lead}. "
                    "The first word picks the next step."
                )
        if job.get("graph_visit"):
            v = str(job.get("graph_visit"))
            lines.append(f"This is {v}." if v.startswith(("round ", "visit ")) else f"This is visit {v} for this step.")
        if job.get("graph_notes"):
            lines.append(
                f"Shared notes for this graph: `{job.get('graph_notes')}`. Read them first. Before you claim, "
                "append a few dated lines: what you tried, what failed and why, what the next step must keep."
            )
        elif job.get("graph_notes_append_only"):
            lines.append(
                f"Judge only what you were given. Before you claim, append your reasons to `{job.get('graph_notes_append_only')}` "
                "(a few dated lines) so the next round knows exactly what to fix. Do not read earlier entries first."
            )
        if job.get("graph_lessons"):
            lines.append(
                f"Team lessons across graphs: `{job.get('graph_lessons')}`. Read them; append one dated line only if you "
                "learned something the next graph on this team must not relearn."
            )
        if job.get("graph_history"):
            lines.append("Recent steps in this graph:\n" + str(job.get("graph_history")))
        lines.append("Claim only when the work is finished: the claim closes this step and hands it on.")
        parts.append("\n\n".join(lines))
        parts.append("")
    if job.get("require_claim", True):
        from .settings import owner_name

        parts.append(
            "When completely done, print exactly "
            f"{marker} on its own line, then a CLAIM block:\n"
            "```\nCLAIM:\nfiles: <comma-separated paths>\n"
            "commands: <what you ran>\n"
            "summary: <one short paragraph>\n```"
        )
        parts.append(
            "**Last required action — the job is not done until this runs:**\n"
            f"`pong job claim {jid} --files '…' --commands '…' --summary '…'`\n"
            "That command marks the job **done** and puts the claim in the "
            "**waitroom**. Your claim target receives it when they are free. "
            "A Recap, chat reply, iMessage, or a CLAIM: block in the TUI is "
            "not a claim. Do not paste CLAIM text into another seat. Do not "
            f"message {owner_name()} instead of claiming. Harvest is a fallback only."
        )
        try:
            from .flow import claim_notify_targets

            targets = claim_notify_targets(state, worker_id)
            if targets:
                joined = ", ".join(targets)
                parts.append(
                    f"Architecture claim path: ** Send claim to {joined} ** "
                    f"(the `pong job claim` line above is what records it)."
                )
        except Exception:
            pass
    else:
        parts.append(
            f"When completely done, print exactly {marker} on its own line, "
            "then a short summary."
        )
    parts.append("")
    parts.append(
        f"Job file: {job_path(str(job['session']), str(job['id']))}\n"
        f"When, and only when, the work is finished, record the claim with `pong job claim {jid}` "
        "— that is the source of truth."
    )
    return "\n".join(parts) + "\n"


def synthesize_result(
    job: dict[str, Any],
    claim: dict[str, Any] | None = None,
    *,
    status: str | None = None,
) -> dict[str, Any]:
    """claim_v1 from an existing CLAIM block (or a bare done status).

    Named failure is a value, not an exception. ``next`` is what the work graph
    routes on; a summary that starts with win/fail sets it, nothing else does.
    """
    claim = claim if isinstance(claim, dict) else {}
    files = claim.get("files") or []
    if isinstance(files, str):
        files = [f.strip() for f in files.split(",") if f.strip()]
    artifacts = [str(f) for f in files] if isinstance(files, list) else []
    raw_status = str(status or job.get("status") or "done").lower()
    mapped = {
        "done": "done", "failed": "fail", "fail": "fail", "rejected": "fail",
        "cancelled": "fail", "blocked": "blocked", "not_found": "not_found",
    }.get(raw_status, "done")
    nxt = claim.get("next")
    summary = str(claim.get("summary") or claim.get("raw") or "").strip()
    # The graph runtime's parser: tolerant of markdown and "Verdict: win",
    # strict about the word ("Windows build fixed" is not a win).
    try:
        from .graph_engine import parse_summary

        said = parse_summary(summary)
    except Exception:
        said = None
    if said:
        nxt = nxt or said
        if said == "fail" and mapped == "done":
            mapped = "fail"
    return {
        "job_id": str(job.get("id") or ""),
        "status": mapped,
        "summary": summary,
        "artifacts": artifacts,
        "next": nxt,
    }


def create_job(
    *,
    session: str | None,
    worker_key: str | None,
    task: str,
    acceptance: list[Any] | None = None,
    require_claim: bool = True,
    round_n: int = 1,
    extra: dict[str, Any] | None = None,
) -> dict[str, Any]:
    from .flow import assert_assign_allowed
    from .routing import resolve_write_session, write_session_last

    # V1/V2: never fall back to active-pair; require session token for cross-team
    sess = resolve_write_session(session)
    state = load_session_state(sess)
    if not state.get("session"):
        state = dict(state)
        state["session"] = sess
    if not (task or "").strip():
        raise ValueError("empty task")
    # A work-graph node is a disposable seat under a goal owner — `w16.a`, not
    # a member of permanent workers[] and not a stop on the org flow graph. So
    # neither gate below can answer for it: resolve_worker would fail to find
    # it, and assert_assign_allowed would refuse a hop that the org road, by
    # design, does not contain. The loop's own gate is
    # work_graph.assert_allowed_seat, which checks the seat against the graph
    # that owns it before the job is ever built.
    #
    # This is narrow on purpose: it needs BOTH the work_node flag and a fully
    # formed _worker dict from the caller. Ordinary jobs are unaffected and
    # still go through resolve_worker and the flow gate.
    extra = extra or None
    work_node = bool(extra and extra.get("work_node"))
    if work_node and extra and isinstance(extra.get("_worker"), dict):
        worker = dict(extra["_worker"])
        worker.setdefault("id", worker_key)
    else:
        worker = resolve_worker(state, worker_key)
        # Architecture edges are enforced when flow_graph is non-empty (UI topology).
        from_seat = None
        if extra and extra.get("from_seat"):
            from_seat = str(extra.get("from_seat"))
        if not work_node:
            assert_assign_allowed(state, str(worker.get("id") or ""), from_seat=from_seat)
    jid = new_job_id()
    now = time.time()
    job: dict[str, Any] = {
        "id": jid,
        "session": sess,
        "worker": worker.get("id"),
        "worker_type": worker.get("type"),
        "worker_label": worker.get("label"),
        "status": "queued",
        "task": task.strip(),
        "project_root": state.get("project_root") or "",
        "team_brief": state.get("team_brief") or "",
        "acceptance": acceptance or [],
        "done_marker": worker.get("done_marker") or "##WORKER_DONE##",
        "require_claim": require_claim,
        "human_takeover": False,
        "round": round_n,
        "created_at": now,
        "updated_at": now,
        "claim": None,
        "error": None,
        "transports_used": [],
        "prompt_path": None,
        "schema_version": 2,
    }
    if extra:
        for k, v in extra.items():
            if not str(k).startswith("_"):
                job[k] = v
    prompt = build_task_prompt(job, state)
    ensure_layout(str(sess))
    prompt_path = session_artifact(state, f"{jid}.prompt.txt")
    prompt_path.write_text(prompt, encoding="utf-8")
    job["prompt_path"] = str(prompt_path)
    # V6: per-session last-sent only — no global root mirror
    write_session_last(str(sess), "last-sent", prompt)
    save_job(job)
    events.emit(
        "job.created",
        session=str(sess),
        job_id=jid,
        worker=worker.get("id"),
        worker_type=worker.get("type"),
    )
    traces.job_created(job, state=state)
    job["_prompt"] = prompt
    job["_state"] = state
    job["_worker"] = worker
    return job


def _clear_ephemeral_for_job(session: str, job_id: str) -> None:
    """Drop registry marks tied to a finished job so the 3D seat vanishes."""
    try:
        from . import subagents

        subagents.unregister(session, job_id)
        subagents.unregister(session, f"eph_{job_id}")
    except Exception:
        pass


def set_status(
    session: str,
    job_id: str,
    status: str,
    *,
    skip_snapshot: bool = False,
    **fields: Any,
) -> dict[str, Any]:
    from .routing import resolve_write_session

    sess = resolve_write_session(session)
    job = load_job(sess, job_id)
    if not job:
        raise FileNotFoundError(job_id)
    if str(job.get("session") or sess) != sess:
        from .routing import refuse

        refuse(
            f"set_status refused — job session {job.get('session')!r} ≠ write session {sess!r}",
            reason="job_session_mismatch",
            target=str(job.get("session")),
            caller=sess,
        )
    prev = str(job.get("status") or "queued")
    assert_transition(prev, status)
    job["status"] = status
    if status == "human_takeover":
        job["human_takeover"] = True
    if status == "running" and job.get("human_takeover") and status != "human_takeover":
        # resuming from takeover
        pass
    skip_mailbox = bool(fields.pop("skip_mailbox", False)) if "skip_mailbox" in fields else False
    for k, v in fields.items():
        if not str(k).startswith("_"):
            job[k] = v
    if status == "done" and not job.get("result"):
        claim = job.get("claim") if isinstance(job.get("claim"), dict) else {}
        job["result"] = synthesize_result(job, claim, status="done")
    save_job(job)
    if status == "done" and not skip_mailbox:
        # Mailbox only — the paste nudge stays on record_claim/notify_claim so a
        # status flip does not fire a claim digest into the waitroom.
        try:
            from .flow import claim_notify_targets
            from .mailbox import post
            from .state import load_session_state as _lss

            st = _lss(sess) or {"session": sess}
            st.setdefault("session", sess)
            worker = str(job.get("worker") or "")
            owner = str(job.get("work_owner") or "").strip()
            targets = [owner] if owner else (claim_notify_targets(st, worker) if worker else [])
            claim = job.get("claim") if isinstance(job.get("claim"), dict) else {}
            summary = str(claim.get("summary") or claim.get("raw") or "") or f"status=done {job_id}"
            for tid in targets:
                post(sess, tid, kind="claim", from_seat=worker, job_id=job_id, summary=summary,
                     result=job.get("result") if isinstance(job.get("result"), dict) else None,
                     extra={"graph_id": job.get("work_graph_id"), "via": "set_status"})
        except Exception:
            pass
    if status in TERMINAL_STATUSES:
        _clear_ephemeral_for_job(sess, job_id)
        # Push UI snapshot so map seats calm without waiting for the next panel poll.
        # skip_snapshot=True when hygiene runs inside team_snapshot (avoids re-entry).
        if not skip_snapshot:
            try:
                from .snapshot import write_snapshot

                write_snapshot(session=sess)
            except Exception:
                pass
    events.emit(
        "job.status",
        session=sess,
        job_id=job_id,
        status=status,
        **{"from": prev},
    )
    traces.job_status(job, previous=prev, status=status)
    return job


def record_claim(
    session: str,
    job_id: str,
    *,
    files: list[str] | None = None,
    commands: str | None = None,
    summary: str | None = None,
    raw: str | None = None,
    claim_token: str | None = None,
    notify_paste: bool = False,
) -> dict[str, Any]:
    """Record claim on job (source of truth). Notify path uses waitroom by default.

    ``notify_paste=True`` (or env ``PONG_CLAIM_PASTE=1``) restores immediate
    full CLAIM paste into the orchestrator — escape hatch only.
    """
    import secrets

    from .routing import (
        assert_claim_session,
        presented_token,
        read_session_token,
        resolve_write_session,
        write_session_last,
    )

    # V2/V7: write gate + session-bound claim token
    write_sess = resolve_write_session(session)
    job = load_job(write_sess, job_id)
    if not job:
        raise FileNotFoundError(job_id)
    job_sess = str(job.get("session") or write_sess)
    if job_sess != write_sess:
        from .routing import refuse

        refuse(
            f"claim refused — write session {write_sess!r} ≠ job session {job_sess!r}",
            reason="claim_session_mismatch",
            target=job_sess,
            caller=write_sess,
        )
    assert_claim_session(job_sess, claim_token=claim_token)
    prev = str(job.get("status") or "queued")
    if prev in ("cancelled", "failed", "rejected"):
        # A claim that lands after the job was stopped is kept for the record
        # but does not bring the job back: a cancelled job silently becoming
        # done re-opened graphs that had been stopped on purpose.
        job["late_claim"] = {"files": files or [], "commands": commands or "", "summary": summary or "",
                             "raw": raw or "", "at": time.time()}
        save_job(job)
        return job
    # claim implies done — allow from non-terminal via transition rules
    if prev not in TERMINAL_STATUSES or prev == "human_takeover":
        try:
            assert_transition(prev, "done")
        except SchemaError:
            # force path: if already done, just update claim
            if prev != "done":
                raise
    tok = claim_token or presented_token()
    expected = read_session_token(job_sess)
    claim = {
        "files": files or [],
        "commands": commands or "",
        "summary": summary or "",
        "raw": raw or "",
        "at": time.time(),
        "session": job_sess,
        "token_ok": bool(
            tok and expected and secrets.compare_digest(tok, expected)
        ),
    }
    already = prev == "done" and isinstance(job.get("claim"), dict)
    job["claim"] = claim
    job["status"] = "done"
    job["human_takeover"] = False
    job["result"] = synthesize_result(job, claim, status="done")
    save_job(job)
    if already:
        # The harvest recorded this claim from the pane first; the seat's own
        # `pong job claim` refines it, but the owner is not told twice.
        events.emit("job.claim", session=job_sess, job_id=job_id, worker=job.get("worker"), repeat=True)
        return job
    _clear_ephemeral_for_job(job_sess, job_id)
    events.emit("job.claim", session=job_sess, job_id=job_id, worker=job.get("worker"))
    traces.job_claim(job, claim, previous=prev)
    if prev != "done":
        events.emit(
            "job.status",
            session=job_sess,
            job_id=job_id,
            status="done",
            **{"from": prev},
        )
    text = raw or summary or json_fallback(claim)
    # V6: per-session last-* only — no global root mirrors
    write_session_last(job_sess, "last-reply", text)
    write_session_last(job_sess, "last-claude", text)
    # Worker finished → available; then enqueue claim for c1 (delivery if orch free)
    worker_id = str(job.get("worker") or "")
    if worker_id:
        try:
            from .seat_status import set_available

            set_available(job_sess, worker_id, reason="claim_done")
        except Exception:
            pass
    # Mailbox FIRST — the durable signal, and it must succeed. The paste nudge
    # inside notify_claim is best-effort and never raises.
    from .flow import notify_claim
    from .state import load_session_state as _lss

    st = _lss(job_sess) or {"session": job_sess}
    st.setdefault("session", job_sess)
    notify_claim(st, job, claim, immediate=bool(notify_paste))
    # Also try deliver deferred jobs for this worker (now available)
    try:
        from .waitroom import try_deliver

        try_deliver(job_sess, force=False)
    except Exception:
        pass
    try:
        from .snapshot import write_snapshot

        write_snapshot(session=job_sess)
    except Exception:
        pass
    return job


def json_fallback(claim: dict[str, Any]) -> str:
    import json

    return json.dumps(claim, indent=2)


def pending_for_worker(session: str, worker_id: str) -> list[dict[str, Any]]:
    return [
        j
        for j in list_jobs(session)
        if j.get("worker") == worker_id
        and j.get("status") in ("queued", "notified")
        and not j.get("human_takeover")
    ]


def summarize_jobs(session: str, *, recent_n: int = 10, now: float | None = None) -> dict[str, Any]:
    all_j = list_jobs(session)
    open_j = [j for j in all_j if j.get("status") not in TERMINAL_STATUSES]
    now_t = time.time() if now is None else now
    activity_j = [j for j in open_j if is_activity_fresh(j, now=now_t)]
    recent = [j for j in all_j if j.get("status") in TERMINAL_STATUSES][:recent_n]
    # Per-status tallies for Mission “Jobs by status” (design handoff)
    by_status: dict[str, int] = {}
    for j in all_j:
        st = str(j.get("status") or "unknown")
        by_status[st] = by_status.get(st, 0) + 1
    return {
        # Full open list (Mission STUCK/RUNTIME watchlist)
        "open": [job_summary(j) for j in open_j],
        # Age-filtered open jobs for map seat pulse / ACTIVE chrome
        "activity_open": [job_summary(j) for j in activity_j],
        "recent": [job_summary(j) for j in recent],
        "counts": {
            "open": len(open_j),
            "activity_open": len(activity_j),
            "total": len(all_j),
            "done": sum(1 for j in all_j if j.get("status") == "done"),
            "failed": sum(1 for j in all_j if j.get("status") == "failed"),
            "by_status": by_status,
        },
    }
