"""Cron v2 — a real runner, not a Swift Timer.

Cadence: ``every Nm``, ``every Nh``, ``daily HH:MM``.
First due fires (do not seed lastFired without firing).
Catch-up fires once (not N missed slots).
Verbs: job.create, drain, snapshot, mailbox.post, goal.tick.
No draft-only path. Token from ``sessions/<session>/token``.
End every tick with drain + snapshot.
"""

from __future__ import annotations

import os
import re
import time
from datetime import datetime
from pathlib import Path
from typing import Any

from .jsonutil import read_json, write_json
from .paths import sessions_dir, state_dir

VERBS = frozenset(
    {"job.create", "drain", "snapshot", "mailbox.post", "goal.tick"}
)
EVERY_RE = re.compile(r"^every\s+(\d+)\s*([mh])$", re.I)
DAILY_RE = re.compile(r"^daily\s+(\d{1,2}):(\d{2})$", re.I)
HOURLY_RE = re.compile(r"^hourly$", re.I)


def schedules_path() -> Path:
    return state_dir() / "cron-schedules.json"


def run_state_path() -> Path:
    return state_dir() / "cron-run.json"


def load_schedules(session: str | None = None) -> dict[str, list[dict[str, Any]]]:
    raw = read_json(schedules_path())
    out: dict[str, list[dict[str, Any]]] = {}
    for key, val in (raw or {}).items():
        if key in ("updated", "updated_at"):
            continue
        if session and key != session:
            continue
        if isinstance(val, list):
            out[key] = [j for j in val if isinstance(j, dict)]
    return out


def save_schedules(db: dict[str, list[dict[str, Any]]]) -> None:
    payload: dict[str, Any] = dict(db)
    payload["updated"] = time.time()
    write_json(schedules_path(), payload)


def load_run_state() -> dict[str, Any]:
    data = read_json(run_state_path())
    return data if isinstance(data, dict) else {}


def save_run_state(data: dict[str, Any]) -> None:
    data = dict(data)
    data["updated_at"] = time.time()
    write_json(run_state_path(), data)


#: A runner whose last beat is older than this, in time the Mac was awake, is not running.
RUNNER_STALE_S = 180.0


def beat_age(st: dict[str, Any], now: float | None = None, mono: float | None = None) -> float | None:
    """How long ago the runner's last beat was, in time the Mac was awake; None when it never beat.

    The wall clock runs on while the Mac sleeps and the runner's own sleep does not (``time.monotonic`` is
    mach_absolute_time on macOS, which stops in sleep), so right after a wake the last beat looked hours
    old until the runner slept out its pause and ran a pass, up to half a minute, and Home called the
    runner off. A beat also stores the monotonic clock (``awake_at``); while the process that wrote it is
    still alive (so the clock is from this boot), the smaller of the two ages is the true one.
    *now* and *mono* replace the clocks (tests)."""
    now = time.time() if now is None else float(now)
    try:
        last = float(st.get("last_tick_at") or 0)
    except (TypeError, ValueError):
        return None
    if last <= 0:
        return None
    gap = now - last
    awake_at, pid = st.get("awake_at"), st.get("pid")
    if isinstance(awake_at, (int, float)) and not isinstance(awake_at, bool) and isinstance(pid, int) and pid > 0:
        try:
            os.kill(pid, 0)  # the runner that wrote this beat still runs: same boot, same clock
        except OSError:
            return gap
        awake = (time.monotonic() if mono is None else float(mono)) - float(awake_at)
        if 0 <= awake < gap:
            return awake
    return gap


def runner_beating(st: dict[str, Any], now: float | None = None, mono: float | None = None) -> bool:
    """The runner's last pass went well and its beat is fresh (:func:`beat_age`)."""
    age = beat_age(st, now, mono)
    return bool(st.get("runner_ok")) and age is not None and age < RUNNER_STALE_S


def parse_cadence(cadence: str) -> tuple[float, float | None]:
    """Return (interval_sec, daily_phase_sec_or_None)."""
    text = (cadence or "").strip()
    m = EVERY_RE.match(text)
    if m:
        n = int(m.group(1))
        unit = m.group(2).lower()
        sec = float(n * (60 if unit == "m" else 3600))
        return max(60.0, sec), None
    if HOURLY_RE.match(text) or text.lower() == "every 1h":
        return 3600.0, None
    d = DAILY_RE.match(text)
    if d:
        hh, mm = int(d.group(1)), int(d.group(2))
        return 86400.0, float(hh * 3600 + mm * 60)
    # Fallback: treat bare "15m" / "5m"
    m2 = re.match(r"^(\d+)\s*([mh])$", text, re.I)
    if m2:
        n = int(m2.group(1))
        unit = m2.group(2).lower()
        return float(n * (60 if unit == "m" else 3600)), None
    return 3600.0, None


def _local_midnight(now: float) -> float:
    dt = datetime.fromtimestamp(now)
    mid = datetime(dt.year, dt.month, dt.day)
    return mid.timestamp()


def is_due(job: dict[str, Any], now: float) -> bool:
    if not job.get("enabled", True):
        return False
    cadence = str(job.get("cadence") or "hourly")
    interval, phase = parse_cadence(cadence)
    last = float(job.get("last_fired") or job.get("lastFired") or 0)
    if last <= 0:
        # First sight: fire if the cadence says we are at/past due.
        if phase is not None:
            midnight = _local_midnight(now)
            due_at = midnight + phase
            if due_at > now:
                due_at -= 86400
            return now >= due_at
        # Interval jobs: first sight is due (do not seed without firing).
        return True
    if phase is not None:
        # Daily: due if last fire was before today's phase and now >= phase
        midnight = _local_midnight(now)
        due_at = midnight + phase
        if last < due_at <= now:
            return True
        # Catch-up: last fire more than one cadence ago
        return (now - last) >= interval
    return (now - last) >= interval


def apply_token(session: str) -> str | None:
    """Export PONG_TOKEN / PONG_SESSION from the session token file."""
    from .routing import read_session_token

    tok = read_session_token(session)
    os.environ["PONG_SESSION"] = session
    if tok:
        os.environ["PONG_TOKEN"] = tok
    return tok


def _record_fire(job: dict[str, Any], now: float, result: dict[str, Any]) -> None:
    job["last_fired"] = now
    job["lastFired"] = now
    job["last_result"] = result
    job["lastResult"] = result
    if result.get("ok"):
        job["last_error"] = None
        job["lastError"] = None
    else:
        job["last_error"] = result.get("error")
        job["lastError"] = result.get("error")


#: Words that mean a task reaches outside this machine. Deliberately generous:
#: a false positive costs a draft job a person approves; a false negative sends
#: mail or moves money on a timer with nobody's name on it. A row that declares
#: ``allow_effects: true`` (or ``effects`` beyond read/write) bypasses the scan.
OUTWARD_VERBS = (
    "send", "email", "e-mail", "reply", "publish", "post ", "tweet", "dm ",
    "spend", "pay ", "invoice", "charge", "refund", "purchase", "buy ",
    "deploy", "release", "ship to", "merge to main", "grant", "scope",
)


def reaches_outside(task: str) -> bool:
    t = str(task or "").lower()
    for v in OUTWARD_VERBS:
        needle = v.strip()
        if " " in needle:
            if needle in t:
                return True
        elif re.search(rf"(?<!\w){re.escape(needle)}(?!\w)", t):
            return True
    return False


def draft_only_task(job: dict[str, Any], task: str) -> str:
    from .settings import owner_name

    return (
        f"SCHEDULED — {job.get('name') or job.get('id')}\n\n{task}\n\n"
        "HUMAN GATE. This fired on a timer, so nobody has approved it. This wording "
        "looks like it would send, publish or spend. Prepare the work and STOP at the "
        f"point of sending: draft it, put it where {owner_name()} can see it, and say plainly what "
        "you would do next and what it would cost. Do not send, publish, pay, deploy, or "
        "widen a scope. A named human presses the button, not a schedule."
    )


def _effects_allowed(job: dict[str, Any]) -> bool:
    if job.get("allow_effects") is True:
        return True
    effects = job.get("effects")
    if isinstance(effects, list):
        return any(str(e) in ("send", "spend", "publish", "deploy") for e in effects)
    return False


def _fire_job_create(session: str, job: dict[str, Any]) -> dict[str, Any]:
    from .jobs import create_job
    from .transports.dispatch import dispatch_job, parse_transport_plan

    apply_token(session)
    owner = str(job.get("owner_id") or job.get("owner") or "c1")
    task = str(job.get("task") or job.get("prompt") or "").strip()
    if not task:
        return {"ok": False, "error": "empty task"}
    gated = reaches_outside(task) and not _effects_allowed(job)
    if gated:
        task = draft_only_task(job, task)
    created = create_job(
        session=session,
        worker_key=owner,
        task=task,
        extra={"from_seat": "c1", "cron_id": job.get("id"), "gated": gated},
    )
    plan = parse_transport_plan("job")
    dispatch_job(created, created.get("_worker") or {"id": owner}, created.get("_state") or {"session": session}, plan=plan)
    return {"ok": True, "job_id": created["id"], "verb": "job.create", "gated": gated}


def _fire_drain(session: str) -> dict[str, Any]:
    from .drain import run

    r = run(session, write_snap=False)
    return {"ok": True, "verb": "drain", "harvested": r.get("harvested")}


def _fire_snapshot(session: str) -> dict[str, Any]:
    from .snapshot import write_snapshot

    p = write_snapshot(session=session)
    return {"ok": True, "verb": "snapshot", "path": str(p)}


def _fire_mailbox_post(session: str, job: dict[str, Any]) -> dict[str, Any]:
    from .mailbox import post

    owner = str(job.get("owner_id") or job.get("owner") or "c1")
    item = post(
        session,
        owner,
        kind="cron",
        from_seat="cron",
        summary=str(job.get("task") or job.get("name") or "cron"),
        extra={"cron_id": job.get("id")},
    )
    return {"ok": True, "verb": "mailbox.post", "mailbox_id": item["id"]}


def _fire_goal_tick(session: str) -> dict[str, Any]:
    from .work_graph import tick

    r = tick(session)
    return {"ok": True, "verb": "goal.tick", **r}


def fire_verb(session: str, job: dict[str, Any]) -> dict[str, Any]:
    verb = str(job.get("verb") or "job.create").strip()
    if verb not in VERBS:
        return {"ok": False, "error": f"unknown verb {verb!r}"}
    try:
        if verb == "job.create":
            return _fire_job_create(session, job)
        if verb == "drain":
            return _fire_drain(session)
        if verb == "snapshot":
            return _fire_snapshot(session)
        if verb == "mailbox.post":
            return _fire_mailbox_post(session, job)
        if verb == "goal.tick":
            return _fire_goal_tick(session)
    except Exception as e:
        return {"ok": False, "error": f"{type(e).__name__}: {e}", "verb": verb}
    return {"ok": False, "error": f"unhandled verb {verb}"}


def tick(
    session: str | None = None,
    *,
    now: float | None = None,
    drain_after: bool = True,
) -> dict[str, Any]:
    """One pass over schedules. Ends with drain+snapshot."""
    now_t = time.time() if now is None else now
    db = load_schedules(session)
    fired: list[dict[str, Any]] = []
    skipped: list[dict[str, Any]] = []
    changed = False
    for sess, jobs in db.items():
        apply_token(sess)
        for job in jobs:
            if not job.get("enabled", True):
                skipped.append({"id": job.get("id"), "reason": "disabled"})
                continue
            if not is_due(job, now_t):
                skipped.append({"id": job.get("id"), "reason": "not_due"})
                continue
            result = fire_verb(sess, job)
            _record_fire(job, now_t, result)
            changed = True
            fired.append(
                {
                    "session": sess,
                    "id": job.get("id"),
                    "name": job.get("name"),
                    "verb": job.get("verb") or "job.create",
                    "result": result,
                }
            )
    if changed:
        # write back into full db (preserve other sessions)
        full = load_schedules()
        if session:
            full[session] = db.get(session) or full.get(session) or []
        else:
            full.update(db)
        save_schedules(full)

    if drain_after:
        from .drain import run_all

        run_all(session, write_snap=True)

    run_st = load_run_state()
    run_st["last_tick_at"] = now_t
    run_st["awake_at"] = time.monotonic()  # the same beat in awake time (beat_age)
    run_st["runner_ok"] = True
    run_st["last_fired"] = [
        {"id": f.get("id"), "session": f.get("session"), "ok": bool((f.get("result") or {}).get("ok"))}
        for f in fired
    ]
    save_run_state(run_st)
    return {"fired": fired, "skipped": skipped, "now": now_t}


def status() -> dict[str, Any]:
    st = load_run_state()
    last = float(st.get("last_tick_at") or 0)
    ok = runner_beating(st)
    return {
        "runner_ok": ok,
        "last_tick_at": last or None,
        "last_fired": st.get("last_fired") or [],
        "path": str(run_state_path()),
    }


def upsert(
    session: str,
    *,
    name: str,
    cadence: str,
    task: str = "",
    owner_id: str = "c1",
    verb: str = "job.create",
    enabled: bool = True,
    job_id: str | None = None,
) -> dict[str, Any]:
    import uuid

    db = load_schedules()
    jobs = list(db.get(session) or [])
    row = {
        "id": job_id or uuid.uuid4().hex[:8],
        "name": name,
        "task": task,
        "cadence": cadence,
        "owner_id": owner_id,
        "verb": verb if verb in VERBS else "job.create",
        "enabled": enabled,
        "last_fired": 0,
    }
    for i, existing in enumerate(jobs):
        if existing.get("id") == row["id"] or str(existing.get("name") or "").lower() == name.lower():
            row["id"] = existing.get("id") or row["id"]
            jobs[i] = {**existing, **row}
            db[session] = jobs
            save_schedules(db)
            return jobs[i]
    jobs.append(row)
    db[session] = jobs
    save_schedules(db)
    return row
