"""Delivery waitroom — queue pastes until the target seat can receive them.

Claims and deferred job pastes land in ``~/.pong/sessions/<session>/waitroom.json``.

**Jobs:** paste only when the seat is available and the TUI is not mid-turn.  
**Claims:** paste when the pane is idle, even if the seat looks busy because
it still has an open parent job (leads waiting on children). Still hold on
pane mid-turn and explicit human busy.  
**Secondary:** anti-double-paste grace (~2.5s), not a 12s push timer.

Bias: false busy (hold) > false idle (stomp) for *job* pastes. Claims must
not starve a lead who is idle at the prompt with an open parent job.

Escape: ``force=True``, ``PONG_CLAIM_PASTE=1``, ``--notify-paste``. These lift
the *seat-state* gates (open-job hold, human busy, grace) and, for the claim
paste, the digest — never the pane check. A pane that is mid-turn, or that
tmux cannot read, is refused by every path, and the item stays queued for the
next drain.
"""

from __future__ import annotations

import json
from contextlib import contextmanager
import fcntl
import os
import time
import uuid
from pathlib import Path
from typing import Any, Callable

from .paths import ensure_layout, sessions_dir

# Short anti-double-paste only (not an interrupt cadence)
DEFAULT_GRACE_SEC = 2.5

PasteFn = Callable[[str, str, str, dict[str, Any]], bool]
# paste_fn(session, seat_id, text, state) -> ok


def _grace_sec() -> float:
    raw = (os.environ.get("PONG_WAITROOM_GRACE") or "").strip()
    if not raw:
        # Back-compat: old COOLDOWN env still accepted but clamped to small grace
        raw = (os.environ.get("PONG_WAITROOM_COOLDOWN") or "").strip()
    if raw:
        try:
            return max(0.0, min(float(raw), 30.0))
        except ValueError:
            pass
    return DEFAULT_GRACE_SEC


def want_immediate_claim_paste(*, flag: bool = False) -> bool:
    """True when full claim paste is requested (escape hatch)."""
    if flag:
        return True
    v = (os.environ.get("PONG_CLAIM_PASTE") or "").strip().lower()
    return v in ("1", "true", "yes", "on")


def waitroom_path(session: str) -> Path:
    ensure_layout(session)
    return sessions_dir(session) / "waitroom.json"


def load_waitroom(session: str) -> dict[str, Any]:
    path = waitroom_path(session)
    if not path.is_file():
        return {"items": [], "last_deliver_at": {}}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {"items": [], "last_deliver_at": {}}
    if not isinstance(data, dict):
        return {"items": [], "last_deliver_at": {}}
    items = data.get("items")
    if not isinstance(items, list):
        items = []
    lda = data.get("last_deliver_at")
    if not isinstance(lda, dict):
        lda = {}
    return {"items": items, "last_deliver_at": {str(k): float(v) for k, v in lda.items()}}


_HELD: dict[str, int] = {}


@contextmanager
def _wr_lock(session: str):
    """Serialise read-modify-write on waitroom.json across processes.

    Reentrant inside one process (a delivery pass marks items while holding it).
    Without it 320 concurrent enqueues left 9 items and two drains pasted the
    same digest twice (audit, 2026-09-24).
    """
    if _HELD.get(session):
        _HELD[session] += 1
        try:
            yield
        finally:
            _HELD[session] -= 1
        return
    path = waitroom_path(session).with_suffix(".json.lock")
    fd = os.open(str(path), os.O_CREAT | os.O_RDWR, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        _HELD[session] = 1
        try:
            yield
        finally:
            _HELD[session] = 0
            fcntl.flock(fd, fcntl.LOCK_UN)
    finally:
        os.close(fd)


def save_waitroom(session: str, data: dict[str, Any]) -> None:
    path = waitroom_path(session)
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = {
        "items": data.get("items") or [],
        "last_deliver_at": data.get("last_deliver_at") or {},
    }
    # Atomic: a reader never sees half a file (a torn read wiped the queue).
    tmp = path.with_suffix(f".json.tmp{os.getpid()}")
    tmp.write_text(json.dumps(payload, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    try:
        tmp.chmod(0o600)
    except OSError:
        pass
    os.replace(tmp, path)


def prune_delivered(session: str, *, now: float | None = None, keep_sec: float = 24 * 3600) -> int:
    """Forget delivered and dropped items older than a day (the queue grew to 1090)."""
    now_t = time.time() if now is None else now
    with _wr_lock(session):
        data = load_waitroom(session)
        before = len(data["items"])
        keep = []
        for it in data["items"]:
            if not isinstance(it, dict):
                continue
            st = str(it.get("status") or "queued")
            at = float(it.get("delivered_at") or it.get("dropped_at") or it.get("created_at") or now_t)
            if st in ("delivered", "dropped") and now_t - at > keep_sec:
                continue
            keep.append(it)
        if len(keep) != before:
            data["items"] = keep
            save_waitroom(session, data)
        return before - len(keep)


def _drop_dead_jobs(session: str) -> int:
    """A queued job item whose job is gone or already finished is dropped, not
    retried forever: one such item held a seat's queue for four weeks."""
    from .jobs import load_job
    from .schema import TERMINAL_STATUSES

    dropped = 0
    with _wr_lock(session):
        data = load_waitroom(session)
        for it in data["items"]:
            if not isinstance(it, dict) or str(it.get("status") or "queued") != "queued":
                continue
            if str(it.get("kind") or "") != "job" or not it.get("job_id"):
                continue
            job = load_job(session, str(it.get("job_id")))
            age = time.time() - float(it.get("created_at") or it.get("at") or time.time())
            if (not job and age > 600) or (job and str(job.get("status") or "") in TERMINAL_STATUSES):
                it["status"] = "dropped"
                it["dropped_at"] = time.time()
                it["drop_reason"] = "job missing" if not job else f"job {job.get('status')}"
                dropped += 1
        if dropped:
            save_waitroom(session, data)
    return dropped


def _one_line(s: str, limit: int = 120) -> str:
    t = " ".join((s or "").split())
    if len(t) <= limit:
        return t
    return t[: limit - 1].rstrip() + "…"


def _append_item(session: str, item: dict[str, Any]) -> dict[str, Any]:
    with _wr_lock(session):
        data = load_waitroom(session)
        data["items"].append(item)
        save_waitroom(session, data)
    return item


def _summary_key(text: str) -> str:
    cleaned = (text or "").replace("┃", " ").replace("◆", " ")
    return " ".join(cleaned.split())[:160]


def enqueue_claim(
    session: str,
    *,
    to: str,
    from_worker: str,
    job_id: str,
    summary: str,
    files: list[str] | None = None,
) -> dict[str, Any]:
    """Append a queued claim delivery item. Always persists; no paste."""
    summary_line = _one_line(summary or f"(claim for {job_id})", 200)
    key = _summary_key(summary_line)
    if key:
        for old in load_waitroom(session).get("items") or []:
            if not isinstance(old, dict):
                continue
            if str(old.get("kind") or "claim") != "claim":
                continue
            if str(old.get("from") or "") != str(from_worker or ""):
                continue
            if _summary_key(str(old.get("summary") or "")) == key:
                return old
    item: dict[str, Any] = {
        "id": f"wr_{int(time.time())}_{uuid.uuid4().hex[:8]}",
        "kind": "claim",
        "to": str(to or "c1"),
        "from": str(from_worker or ""),
        "job_id": str(job_id or ""),
        "summary": summary_line,
        "files": list(files or [])[:12],
        "created_at": time.time(),
        "status": "queued",
    }
    _append_item(session, item)
    try:
        from . import events

        events.emit(
            "claim.queued",
            session=session,
            job_id=item["job_id"],
            worker=item["from"],
            to=item["to"],
            waitroom_id=item["id"],
        )
    except Exception:
        pass
    return item


def enqueue_job(
    session: str,
    *,
    to: str,
    job_id: str,
    summary: str | None = None,
) -> dict[str, Any]:
    """Queue a deferred job paste for a busy worker seat."""
    item: dict[str, Any] = {
        "id": f"wr_{int(time.time())}_{uuid.uuid4().hex[:8]}",
        "kind": "job",
        "to": str(to or ""),
        "from": "dispatch",
        "job_id": str(job_id or ""),
        "summary": _one_line(summary or f"job {job_id}", 200),
        "files": [],
        "created_at": time.time(),
        "status": "queued",
    }
    _append_item(session, item)
    try:
        from . import events

        events.emit(
            "job.queued_delivery",
            session=session,
            job_id=item["job_id"],
            to=item["to"],
            waitroom_id=item["id"],
        )
    except Exception:
        pass
    return item


def list_items(
    session: str,
    *,
    status: str | None = "queued",
    to: str | None = None,
    kind: str | None = None,
) -> list[dict[str, Any]]:
    data = load_waitroom(session)
    out: list[dict[str, Any]] = []
    for it in data["items"]:
        if not isinstance(it, dict):
            continue
        if status and str(it.get("status") or "") != status:
            continue
        if to and str(it.get("to") or "") != to:
            continue
        if kind and str(it.get("kind") or "") != kind:
            continue
        out.append(it)
    out.sort(key=lambda x: float(x.get("created_at") or 0))
    return out


def seconds_since_last_deliver(session: str, seat: str) -> float | None:
    data = load_waitroom(session)
    raw = data.get("last_deliver_at") or {}
    if seat not in raw:
        return None
    try:
        return max(0.0, time.time() - float(raw[seat]))
    except (TypeError, ValueError):
        return None


def _seat_pane_index(session: str, seat: str) -> int | None:
    """tmux window index for *seat*, or ``None`` when it has no resolvable pane."""
    try:
        from .flow import conductor_id
        from .state import conductor_from_state, load_session_state, workers_from_state

        state = load_session_state(session)
        if not state:
            return None
        if str(seat) == str(conductor_id(state)) or str(seat) in ("c1", "hermes"):
            idx = conductor_from_state(state).get("tmux_index")
            return idx if isinstance(idx, int) else 0
        for w in workers_from_state(state):
            if str(w.get("id")) == str(seat):
                idx = w.get("tmux_index")
                return idx if isinstance(idx, int) else None
    except Exception:
        return None
    return None


def _target_pane_thinking(session: str, seat: str) -> bool:
    """True when that seat's TUI is mid-turn — **or unreadable**.

    Fails CLOSED on a capture error. If tmux will not hand us the pane text we
    cannot show the seat is sitting at a prompt, and the two outcomes are not
    symmetric: holding costs a few seconds until the next drain, stomping costs
    that seat the turn it was composing.

    A session that is *gone* is a different thing from a pane we could not
    read. There is no live turn to protect in a dead session, so that stays
    "not thinking" — which also keeps the queue from wedging on a box where
    tmux is simply not running.
    """
    # Isolated homes (tests) share the live tmux name; never capture those.
    if _isolated_home():
        return False
    try:
        from .pane_activity import capture_pane, is_thinking, session_alive
    except Exception:
        return False
    idx = _seat_pane_index(session, seat)
    if idx is None:
        return False
    if not session_alive(session):
        return False
    ok, text = capture_pane(session, idx)
    if not ok:
        return True
    return is_thinking(text)


def pane_blocks_paste(session: str, seat: str) -> bool:
    """True when nothing may be pasted into *seat* right now.

    Public because the escape hatch in ``flow.notify_claim`` has to consult the
    same gate ``can_deliver`` does. That path may skip the digest and the
    seat-state gates — that is its purpose — but never a live turn.
    """
    return _target_pane_thinking(session, seat)


def _open_job_hold(why: str) -> bool:
    """True when availability is blocked only by a notified/running job."""
    w = str(why or "")
    return w.startswith("open_job=") or w.startswith("busy+open_job=")


def _explicit_human_busy(session: str, seat: str) -> bool:
    from .seat_status import get_status

    row = get_status(session, seat)
    return (
        str(row.get("state") or "").strip().lower() == "busy"
        and str(row.get("reason") or "").strip().lower() == "human"
    )


def can_deliver(
    session: str,
    seat: str,
    *,
    force: bool = False,
    now: float | None = None,
    cooldown: float | None = None,
    kind: str | None = None,
) -> tuple[bool, str]:
    """Gate one waitroom item kind for *seat*.

    Jobs still require the seat available. Claims may land on an idle pane
    even when the seat is busy solely because of an open parent job.
    ``cooldown`` param kept for API compat (= grace seconds).

    ``force`` bypasses the SEAT-STATE gates — open-job hold, explicit human
    busy, and the anti-double-paste grace. It does **not** bypass the pane
    check below.
    """
    # A pane that is mid-turn is never a paste target, for anyone. Text sent
    # into a live turn is appended to the prompt the seat is already composing,
    # so a `drain --force` at the wrong moment corrupts that seat's job rather
    # than delivering to it. Nothing is lost by refusing: the item stays
    # QUEUED and the next drain retries once the pane is idle. This check sits
    # above `force` on purpose — an override that can defeat it is the bug.
    if _target_pane_thinking(session, seat):
        return False, "pane_thinking"

    if force:
        return True, "force"

    from .seat_status import availability

    avail, why = availability(session, seat, now=now)
    kind_norm = str(kind or "").strip().lower()
    if not avail:
        claim_ok = (
            kind_norm == "claim"
            and _open_job_hold(why)
            and not _explicit_human_busy(session, seat)
        )
        if not claim_ok:
            return False, f"seat_busy:{why}"
        why = f"claim_while_open_job:{why}"

    grace = _grace_sec() if cooldown is None else max(0.0, cooldown)
    if grace <= 0:
        return True, f"available:{why}"

    data = load_waitroom(session)
    last = (data.get("last_deliver_at") or {}).get(seat)
    if last is None:
        return True, f"available:{why}"
    t = time.time() if now is None else now
    elapsed = t - float(last)
    if elapsed >= grace:
        return True, f"available:{why}"
    remain = grace - elapsed
    return False, f"grace {remain:.1f}s (anti-double-paste)"


def format_digest(items: list[dict[str, Any]], *, seat: str = "c1") -> str:
    """One paste body for a batch of pending **claim** items."""
    claims = [it for it in items if str(it.get("kind") or "claim") == "claim"]
    if not claims:
        return ""
    if len(claims) == 1:
        it = claims[0]
        files = it.get("files") or []
        files_s = ", ".join(str(f) for f in files[:6]) if files else "—"
        return (
            f"\n—— CLAIM READY · {it.get('from') or '?'} · {it.get('job_id')} ——\n"
            f"{it.get('summary') or '(no summary)'}\n"
            f"files: {files_s}\n"
            f"(full text in job file; `pong job show {it.get('job_id')}` · accept only after checks)\n"
            f"(Queued claims auto-deliver when you are free — human need not ask “any updates?”. "
            f"Optional: ##SEAT_AVAILABLE## / `pong seat available --seat {seat}`.)\n"
        )
    lines = [f"\n—— CLAIMS READY · {len(claims)} · → {seat} ——"]
    for it in claims:
        lines.append(
            f"- {it.get('from') or '?'} {it.get('job_id') or '?'}: "
            f"{it.get('summary') or '(no summary)'}"
        )
    lines.append(
        "(full text in job files; `pong job show <id>` / run acceptance before ledger verdict)\n"
        "(More claims auto-flush when free; short grace prevents double-paste. "
        f"Optional: ##SEAT_AVAILABLE## / `pong seat available --seat {seat}`.)\n"
    )
    return "\n".join(lines)


def mark_delivered(session: str, item_ids: list[str], *, seat: str) -> None:
    with _wr_lock(session):
        data = load_waitroom(session)
        ids = set(item_ids)
        now = time.time()
        for it in data["items"]:
            if isinstance(it, dict) and it.get("id") in ids:
                it["status"] = "delivered"
                it["delivered_at"] = now
        lda = data.setdefault("last_deliver_at", {})
        lda[seat] = now
        save_waitroom(session, data)


def _isolated_home() -> bool:
    """True when PONG_HOME is not the live ~/.pong (tests, scratch)."""
    home = (os.environ.get("PONG_HOME") or "").strip()
    if not home:
        return False
    try:
        return Path(home).expanduser().resolve() != (Path.home() / ".pong").resolve()
    except OSError:
        return True


def _default_paste(session: str, seat_id: str, text: str, state: dict[str, Any]) -> bool:
    """Best-effort tmux paste into seat."""
    # Isolated homes share the live tmux name — never paste into the owner's seats.
    if _isolated_home():
        return True
    from .flow import _all_seats, _paste_by_index, conductor_id
    from .state import conductor_from_state

    workers = {str(w.get("id")): w for w in _all_seats(state)}
    seat = workers.get(seat_id) or {"id": seat_id}
    if seat_id == conductor_id(state):
        seat = dict(conductor_from_state(state) or {})
        seat.setdefault("id", seat_id)
    try:
        from .transports import tmux_paste

        job_proxy = {
            "session": session,
            "worker": seat_id,
            "_prompt": text,
        }
        r = tmux_paste.send(job_proxy, seat, state)
        if r.ok:
            return True
        _paste_by_index(session, seat, text)
        return True
    except Exception:
        try:
            _paste_by_index(session, seat, text)
            return True
        except Exception:
            return False


def _deliver_job_item(
    session: str,
    item: dict[str, Any],
    state: dict[str, Any],
    paste: PasteFn,
) -> bool:
    """Paste one deferred job prompt; mark job notified; set seat busy."""
    from .jobs import load_job, save_job
    from .seat_status import set_busy

    jid = str(item.get("job_id") or "")
    seat_id = str(item.get("to") or "")
    job = load_job(session, jid)
    if not job:
        return False
    # Skip if already past queued
    st = str(job.get("status") or "")
    if st not in ("queued", "notified"):
        return False
    prompt = ""
    pp = job.get("prompt_path")
    if pp and Path(str(pp)).is_file():
        try:
            prompt = Path(str(pp)).read_text(encoding="utf-8", errors="replace")
        except OSError:
            prompt = ""
    if not prompt:
        prompt = str(job.get("task") or "")
    if not prompt.strip():
        return False
    text = prompt if prompt.endswith("\n") else prompt + "\n"
    ok = paste(session, seat_id, text, state)
    if not ok:
        return False
    # The paste can take seconds; a cancel written meanwhile must win.
    fresh = load_job(session, jid) or job
    if str(fresh.get("status") or "") not in ("queued", "notified"):
        return False
    job = fresh
    job["status"] = "notified"
    job["updated_at"] = time.time()
    used = list(job.get("transports_used") or [])
    if "tmux_paste" not in used:
        used.append("tmux_paste")
    job["transports_used"] = used
    job["error"] = None
    save_job(job)
    set_busy(session, seat_id, reason="job", job_id=jid)
    try:
        from . import events

        events.emit(
            "delivery.delivered",
            session=session,
            kind="job",
            to=seat_id,
            job_id=jid,
        )
        events.emit(
            "job.status",
            session=session,
            job_id=jid,
            status="notified",
            **{"from": "queued"},
        )
    except Exception:
        pass
    return True


def try_deliver(
    session: str,
    *,
    to: str | None = None,
    force: bool = False,
    state: dict[str, Any] | None = None,
    paste_fn: PasteFn | None = None,
    set_available_first: bool = False,
) -> dict[str, Any]:
    """Process waitroom for seats: one delivery unit per seat per cycle.

    Per seat (when the matching gate allows, or force):
    - Prefer pending **job** items (one job paste) first — jobs still
      require the seat available
    - If the job is held (open parent job, human busy, thinking), still
      try pending **claim** items — claims may land on an idle pane
    - Else batch all pending **claim** items into one digest
    """
    with _wr_lock(session):
        _drop_dead_jobs(session)
        return _try_deliver_locked(session, to=to, force=force, state=state, paste_fn=paste_fn,
                                   set_available_first=set_available_first)


def _try_deliver_locked(
    session: str,
    *,
    to: str | None = None,
    force: bool = False,
    state: dict[str, Any] | None = None,
    paste_fn: PasteFn | None = None,
    set_available_first: bool = False,
) -> dict[str, Any]:
    from .seat_status import set_available
    from .state import load_session_state

    st = state or load_session_state(session) or {"session": session}
    st.setdefault("session", session)
    paste = paste_fn or _default_paste

    if set_available_first and to:
        set_available(session, to, reason="drain_implies_ready")
    elif set_available_first and not to:
        # Mark all seats that have queue as available when drain --force readiness
        for it in list_items(session, status="queued"):
            set_available(session, str(it.get("to") or "c1"), reason="drain_implies_ready")

    pending_all = list_items(session, status="queued")
    seats: list[str] = []
    if to:
        seats = [to]
    else:
        for it in pending_all:
            sid = str(it.get("to") or "c1")
            if sid not in seats:
                seats.append(sid)

    result: dict[str, Any] = {
        "session": session,
        "delivered": [],
        "held": [],
        "empty": True,
    }

    for seat in seats:
        items = [it for it in pending_all if str(it.get("to") or "c1") == seat]
        if not items:
            continue
        result["empty"] = False
        jobs = [it for it in items if str(it.get("kind") or "") == "job"]
        claims = [it for it in items if str(it.get("kind") or "claim") == "claim"]

        if jobs:
            ok_job, reason_job = can_deliver(session, seat, force=force, kind="job")
            if ok_job:
                item = jobs[0]
                if _deliver_job_item(session, item, st, paste):
                    mark_delivered(session, [str(item.get("id"))], seat=seat)
                    result["delivered"].append(
                        {
                            "to": seat,
                            "kind": "job",
                            "count": 1,
                            "item_ids": [item.get("id")],
                            "job_id": item.get("job_id"),
                        }
                    )
                else:
                    result["held"].append(
                        {"to": seat, "count": 1, "reason": "job_paste_failed"}
                    )
                continue
            result["held"].append(
                {
                    "to": seat,
                    "count": 1,
                    "reason": reason_job,
                    "kind": "job",
                }
            )
            try:
                from . import events

                events.emit(
                    "delivery.held",
                    session=session,
                    to=seat,
                    count=1,
                    reason=reason_job,
                    kind="job",
                )
            except Exception:
                pass
            if not claims:
                continue
            # Job stays queued; claims may still land on an idle pane.

        if claims:
            ok_claim, reason_claim = can_deliver(
                session, seat, force=force, kind="claim"
            )
            if not ok_claim:
                result["held"].append(
                    {
                        "to": seat,
                        "count": len(claims),
                        "reason": reason_claim,
                        "kind": "claim",
                    }
                )
                try:
                    from . import events

                    events.emit(
                        "delivery.held",
                        session=session,
                        to=seat,
                        count=len(claims),
                        reason=reason_claim,
                        kind="claim",
                    )
                except Exception:
                    pass
                continue
            text = format_digest(claims, seat=seat)
            pasted = paste(session, seat, text, st)
            ids = [str(it.get("id")) for it in claims if it.get("id")]
            if pasted:
                mark_delivered(session, ids, seat=seat)
                # Do NOT set_busy(claim_digest) — that starved c1 forever.
                # Anti-double-paste is the short grace window only.
                # Workers stay protected via job-paste → busy until claim.
                try:
                    from . import events

                    events.emit(
                        "claim.notified",
                        session=session,
                        to=seat,
                        count=len(claims),
                        job_ids=[it.get("job_id") for it in claims],
                        digest=True,
                    )
                    events.emit(
                        "delivery.delivered",
                        session=session,
                        kind="claim_digest",
                        to=seat,
                        count=len(claims),
                    )
                except Exception:
                    pass
                result["delivered"].append(
                    {
                        "to": seat,
                        "kind": "claim_digest",
                        "count": len(claims),
                        "item_ids": ids,
                        "text": text,
                    }
                )
            else:
                result["held"].append(
                    {"to": seat, "count": len(claims), "reason": "paste_failed"}
                )
    return result


# Back-compat alias
def drain(
    session: str,
    *,
    to: str | None = None,
    force: bool = False,
    state: dict[str, Any] | None = None,
    paste_fn: PasteFn | None = None,
    cooldown: float | None = None,
    imply_available: bool = False,
) -> dict[str, Any]:
    """Deliver waitroom items (claims + jobs). Alias of try_deliver.

    ``force`` bypasses availability. ``imply_available`` sets available then drains
    (for ``pong waitroom drain`` when human is free to receive).
    """
    # cooldown unused — availability is primary; grace still applied inside can_deliver
    _ = cooldown
    return try_deliver(
        session,
        to=to,
        force=force,
        state=state,
        paste_fn=paste_fn,
        set_available_first=imply_available or force,
    )


def enqueue_and_maybe_drain(
    session: str,
    *,
    to: str,
    from_worker: str,
    job_id: str,
    summary: str,
    files: list[str] | None = None,
    state: dict[str, Any] | None = None,
    paste_fn: PasteFn | None = None,
) -> dict[str, Any]:
    """Enqueue claim then try_deliver only if target available (no timer interrupt)."""
    item = enqueue_claim(
        session,
        to=to,
        from_worker=from_worker,
        job_id=job_id,
        summary=summary,
        files=files,
    )
    drain_result = try_deliver(
        session, to=to, force=False, state=state, paste_fn=paste_fn
    )
    return {"item": item, "drain": drain_result}
