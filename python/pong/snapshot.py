"""UI snapshot — single document the panel polls."""

from __future__ import annotations

import json
import os
import re
import time
from pathlib import Path
from typing import Any

from . import events
from . import ledger as ledger_mod
from .jobs import (
    activity_open_jobs,
    cancel_stale_abandoned_jobs,
    open_jobs,
    summarize_jobs,
)
from .jsonutil import write_json
from .paths import binds_dir, sessions_dir, state_dir
from .schema import CONTRACT_VERSION, SCHEMA_VERSION
from .state import (
    conductor_from_state,
    detect_bound_session,
    gate_text,
    load_pairs_db,
    load_session_state,
    normalize_pair_state,
    workers_from_state,
)


def _worker_status_hint(session: str, worker_id: str) -> tuple[str, int]:
    """Map status for UI: running/notified → in-flight; queued → busy; none → idle.

    Only age-fresh open jobs count (stale notified/queued/running do not pulse seats).
    """
    act = activity_open_jobs(session)
    open_j = [
        j
        for j in act
        if j.get("worker") == worker_id and not j.get("human_takeover")
    ]
    takeover = [
        j
        for j in act
        if j.get("worker") == worker_id and j.get("status") == "human_takeover"
    ]
    if takeover:
        return "human_takeover", len(open_j) + len(takeover)
    if not open_j:
        return "idle", 0
    # Prefer real in-flight over soft "busy" so map seats calm when only queued
    for j in open_j:
        st = str(j.get("status") or "").lower()
        if st in ("running", "notified") or "working" in st:
            return "running", len(open_j)
    return "busy", len(open_j)


def team_snapshot(session: str, entry: dict[str, Any] | None = None) -> dict[str, Any]:
    from .subagents import collect_ephemeral_subs

    # Hygiene first: auto-cancel abandoned notified/queued (>2h) / running (>24h)
    try:
        cancel_stale_abandoned_jobs(session)
    except Exception:
        pass

    state = load_session_state(session)
    if not state and entry:
        state = normalize_pair_state({**entry, "session": session})
    if not state:
        state = {"session": session, "workers": [], "conductor": {}}
    c = conductor_from_state(state)
    cond_id = str(c.get("id") or "c1")
    permanent_ids: set[str] = {cond_id}
    # Seat availability + waitroom depth (delivery truth).
    # Pane thinking is a separate honest signal: a TUI mid-turn with no job.
    seat_avail: dict[str, Any] = {}
    waitroom_depth = 0
    try:
        from .seat_status import all_statuses
        from .waitroom import list_items

        seat_avail = all_statuses(session)
        waitroom_depth = len(list_items(session, status="queued"))
    except Exception:
        seat_avail = {}
    workers = workers_from_state(state)
    pane_on: dict[int, bool] = {}
    pane_text: dict[int, str] = {}
    alive = False
    try:
        from .pane_activity import capture_all_alive, is_thinking, parse_usage

        idxs = [c.get("tmux_index"), *[w.get("tmux_index") for w in workers]]
        alive, pane_text = capture_all_alive(session, idxs)
        pane_on = {i: is_thinking(t) for i, t in pane_text.items()}
    except Exception:
        alive = False
        pane_on = {}
        pane_text = {}
        parse_usage = None  # type: ignore[assignment]
    open_by_worker: dict[str, int] = {}
    for w in workers:
        wid = str(w.get("id"))
        _, nopen = _worker_status_hint(session, wid)
        open_by_worker[wid] = nopen
    waiting_parents: set[str] = set()
    for w in workers:
        pid = str(w.get("parent_id") or w.get("parent") or "")
        if pid and open_by_worker.get(str(w.get("id")), 0) > 0:
            waiting_parents.add(pid)
    workers_out = []
    for w in workers:
        wid = str(w.get("id"))
        permanent_ids.add(wid)
        hint, nopen = _worker_status_hint(session, wid)
        # Permanent roster workers tagged ephemeral only appear while busy
        is_eph_worker = bool(w.get("ephemeral"))
        sa = seat_avail.get(wid) or {}
        idx = w.get("tmux_index")
        thinking = bool(isinstance(idx, int) and pane_on.get(idx))
        usage = None
        if parse_usage and isinstance(idx, int):
            try:
                usage = parse_usage(pane_text.get(idx, ""))
            except Exception:
                usage = None
        rec = {
            "id": wid,
            "type": w.get("type"),
            "label": w.get("label"),
            "cmd": w.get("cmd"),
            "mode": w.get("mode"),
            "window_id": w.get("window_id"),
            "tmux_index": w.get("tmux_index"),
            "done_marker": w.get("done_marker"),
            "status_hint": hint,
            "open_jobs": nopen,
            "parent_id": w.get("parent_id") or w.get("parent"),
            "ephemeral": is_eph_worker,
            "mission_role": w.get("mission_role") or w.get("role") or "coder",
            # Hidden from map when ephemeral + idle (vanish when done)
            "map_visible": (not is_eph_worker) or nopen > 0 or hint not in ("idle", ""),
            "seat_state": sa.get("state") or "available",
            "seat_reason": sa.get("reason") or "",
            "pane_active": thinking,
            "waiting_on_child": wid in waiting_parents,
            "usage": usage,
        }
        workers_out.append(rec)
    jobs = summarize_jobs(session)
    # Ephemeral seats track activity-fresh jobs so stale notified does not pin them
    open_list = activity_open_jobs(session)
    eph_subs = collect_ephemeral_subs(
        session,
        permanent_ids=permanent_ids,
        open_job_list=open_list,
        conductor_id=cond_id,
    )
    sess_dir = sessions_dir(session)
    c_sa = seat_avail.get(cond_id) or {}
    c_idx = c.get("tmux_index")
    c_thinking = bool(isinstance(c_idx, int) and pane_on.get(c_idx))
    c_usage = None
    if parse_usage and isinstance(c_idx, int):
        try:
            c_usage = parse_usage(pane_text.get(c_idx, ""))
        except Exception:
            c_usage = None
    conductor_out = {
        "id": c.get("id"),
        "type": c.get("type"),
        "label": c.get("label"),
        "cmd": c.get("cmd"),
        "window_id": c.get("window_id"),
        "mode": c.get("mode"),
        "tmux_index": c.get("tmux_index"),
        "seat_state": c_sa.get("state") or "available",
        "seat_reason": c_sa.get("reason") or "",
        "pane_active": c_thinking,
        "status_hint": "idle",
        "usage": c_usage,
    }
    mailbox_block: dict = {"unread": {}, "unread_total": 0, "seats": []}
    work_graph_block: dict = {"version": 1, "graphs": []}
    try:
        from .mailbox import snapshot_block as _mb

        mailbox_block = _mb(session)
    except Exception:
        pass
    try:  # finished graphs go as a line each: the graph page reads them from `pong graph list` (2.1)
        from .work_graph import snapshot_block as _wg

        work_graph_block = _wg(session, brief_finished=True)
    except Exception:
        pass
    try:  # the short names the app shows (1.9)
        from .names import apply_graphs

        apply_graphs(session, work_graph_block.get("graphs") or [])
    except Exception:
        pass
    # What each member is doing, in its own words and in plain ones, and which graph step it is on (2.1)
    try:
        doing = _member_doing(session, pane_text, [(cond_id, c_idx), *[(str(w.get("id")), w.get("tmux_index"))
                                                                       for w in workers]])
    except Exception:
        doing = {}
    try:
        on_graph = _seat_graphs(work_graph_block.get("graphs") or [], {str(w.get("id")) for w in workers}, cond_id)
    except Exception:
        on_graph = {}
    conductor_out.update(doing.get(cond_id) or _NO_DOING)
    conductor_out["graph"] = on_graph.get(cond_id)
    for rec in workers_out:
        rec.update(doing.get(rec["id"]) or _NO_DOING)
        rec["graph"] = on_graph.get(rec["id"])
    try:
        last_message = _last_message(session, cond_id)
    except Exception:  # a view: a chat log it can't read never stops the snapshot, and shows nothing
        last_message = _no_last_message()
    try:
        from .graph_engine import owner_label, owner_labels

        labels = owner_labels(state, workers)
        for g in work_graph_block.get("graphs") or []:
            if isinstance(g, dict) and "nodes" in g:
                g["owner_label"] = owner_label(labels, g.get("owner"))
    except Exception:
        pass
    return {
        "session": session,
        "display_name": state.get("display_name") or "",
        # its tmux session is there (the check the screen capture already makes)
        "alive": bool(alive),
        # the lead's latest message to the person, so the notch panel needn't read the chat log (2.1)
        "last_message": last_message,
        "stowed": bool(state.get("stowed")),
        "schema_version": state.get("schema_version") or SCHEMA_VERSION,
        "conductor": conductor_out,
        "workers": workers_out,
        "ephemeral_subs": eph_subs,
        "project_root": state.get("project_root") or "",
        "team_brief": state.get("team_brief") or "",
        "transport_default": state.get("transport_default") or "job+paste",
        "jobs": jobs,
        # The lines the island's right ear rotates through, most urgent first,
        # composed here so the display never has to read prose. Empty when there
        # is nothing worth saying — a quiet ear is a real answer.
        "ticker": _ticker(session, state, jobs),
        "waitroom_queued": waitroom_depth,
        "seat_status": seat_avail,
        "weekly_usage": _weekly_usage(conductor_out, workers_out),
        "mailbox": mailbox_block,
        "work_graph": work_graph_block,
        # questions this team's AIs asked the person with `pong ask` (the island shows them as cards)
        "asks": _open_asks(session),
        "artifacts": {
            "last_sent": str(sess_dir / "last-sent.txt"),
            "last_reply": str(sess_dir / "last-reply.txt"),
            "bind_card": str(binds_dir() / f"{session}.md"),
        },
    }


_NO_DOING: dict[str, Any] = {"doing": None, "doing_plain": None, "doing_at": None}
#: Each seat's last doing line and when it changed, so a line's age survives from one pass to the next.
DOING_FILE = "seat-doing.json"


def _member_doing(session: str, pane_text: dict[int, str], seats: list[tuple[str, Any]],
                  now: float | None = None) -> dict[str, dict[str, Any]]:
    """seat → {doing, doing_plain, doing_at} from the screens already captured for this pass (16 lines
    each): the seat's latest step line, keys hidden the way a graph step's live view hides them, the
    same line in plain words, and when it last changed. A seat whose screen wasn't read has none."""
    from .graph_engine import hide_keys, plain_doing, seat_doing
    from .jsonutil import read_json, write_json

    now = time.time() if now is None else now
    path = sessions_dir(session) / DOING_FILE
    old = read_json(path) if path.exists() else {}
    out: dict[str, dict[str, Any]] = {}
    for sid, idx in seats:
        text = pane_text.get(idx) if isinstance(idx, int) else None
        if not sid or text is None:
            continue
        raw = hide_keys(seat_doing(text), text)
        if not raw:
            continue
        prev = old.get(sid) if isinstance(old.get(sid), dict) else {}
        at = prev.get("at") if prev.get("doing") == raw and prev.get("at") else round(now, 1)
        out[sid] = {"doing": raw, "doing_plain": plain_doing(raw), "doing_at": at}
    keep = {sid: {"doing": v["doing"], "at": v["doing_at"]} for sid, v in out.items()}
    if keep != old:
        try:
            write_json(path, keep)
        except Exception:
            pass
    return out


def _seat_graphs(graphs: list[dict[str, Any]], roster: set[str], lead: str) -> dict[str, dict[str, Any]]:
    """seat → {graph_id, title, step_name} for the team's members at work on a graph: a member that is a
    running step's own seat, else (helpers only) one that runs a graph of its own (its newest)."""
    from .graph_engine import SEATLESS

    running = sorted((g for g in graphs if isinstance(g, dict) and g.get("status") == "running" and "nodes" in g),
                     key=lambda g: -float(g.get("created_at") or 0))
    out: dict[str, dict[str, Any]] = {}
    for g in running:
        for n in g.get("nodes") or []:
            seat = str(n.get("seat") or "")
            if str(n.get("status") or "") != "running" or str(n.get("role") or "") in SEATLESS:
                continue
            if (seat in roster or seat == lead) and seat not in out:
                out[seat] = {"graph_id": g.get("id"), "title": g.get("title"), "step_name": n.get("step_name")}
    for g in running:
        owner = str(g.get("owner") or "")
        if owner in roster and owner not in out:
            out[owner] = {"graph_id": g.get("id"), "title": g.get("title"),
                          "step_name": (g.get("now") or {}).get("step_name")}
    return out


#: Lines a screen reader picked up from the lead's terminal chrome (the Teams page leaves the same out).
_CHAT_CHROME = re.compile(r"enter to select|to navigate|esc to|\? for shortcuts|bypass permissions|^⎿", re.I)
LAST_MESSAGE_MAX = 200
#: How much of the chat log's end is read for the lead's latest message.
LAST_MESSAGE_TAIL = 65536


def _no_last_message() -> dict[str, Any]:
    """Nothing the lead wrote may be shown: no log yet, none written, or each line held back (a key in it,
    a job's recap). Never null: the app reads null as an older engine and falls back to reading the chat
    log itself, without these tests, and keeps what it read; a log that appeared between the engine's read
    and the app's (a new team's first job recaps) would put a held-back line on the notch panel."""
    return {"text": "", "at": None}


def _last_message(session: str, lead: str) -> dict[str, Any]:
    """The lead's latest message to the person, {text (≤200), at}: the newest line in the end of the chat
    log (``human/<team>/chat.jsonl``, its last 64 KB) that the lead wrote itself. An automatic recap of a
    finished job (it carries a job id) is not the lead speaking, and a line with a key or token in it is
    never shown. ``{"text": "", "at": None}`` when no line qualifies or there is no log yet: never None."""
    path = state_dir() / "human" / session / "chat.jsonl"
    try:
        with open(path, "rb") as f:
            f.seek(0, os.SEEK_END)
            start = max(0, f.tell() - LAST_MESSAGE_TAIL)
            f.seek(max(0, start - 1))
            data = f.read()
    except OSError:
        return _no_last_message()
    if start > 0:  # read from mid-file: keep whole rows only (the byte before shows whether one starts here)
        nl = data.find(b"\n")
        data = data[nl + 1:] if nl >= 0 else b""
    from .graph_engine import HIDDEN_DOING, hide_keys

    # every whole line in the tail, so a run of job recaps can't push the lead's own words out of reach
    for line in reversed(data.decode("utf-8", "replace").splitlines()):
        try:
            row = json.loads(line)
        except ValueError:
            continue
        if not isinstance(row, dict) or str(row.get("kind") or "") != "from_orch" or str(row.get("job_id") or "").strip():
            continue
        if str(row.get("seat_id") or lead) not in (lead, "c1"):
            continue
        text = re.sub(r"^Orchestrator needs you\s*·\s*", "", " ".join(str(row.get("text") or "").split()))
        # a key or token in the message keeps it off the panel (the same test as a doing line)
        if not text or _CHAT_CHROME.search(text) or hide_keys(text, "") == HIDDEN_DOING or \
                (" tokens" in text and "·" in text and re.search(r"thinking|…|\.\.\.", text, re.I)):
            continue
        if len(text) > LAST_MESSAGE_MAX:
            cut = text[:LAST_MESSAGE_MAX - 1]
            text = (cut[:cut.rfind(" ")] if cut.rfind(" ") > LAST_MESSAGE_MAX // 2 else cut).rstrip(" ,;:-—") + "…"
        try:
            at = float(row.get("ts")) if row.get("ts") is not None else None
        except (TypeError, ValueError):
            at = None
        return {"text": text, "at": at}
    return _no_last_message()


def _open_asks(session: str) -> list[dict[str, Any]]:
    try:
        from .asks import list_open

        return list_open(session)
    except Exception:
        return []


def _pool_name(seat_type: str) -> str:
    """Grok seats and Hermes share one Grok weekly pool; Claude is its own."""
    t = (seat_type or "").strip().lower()
    if t in {"claude", "claude-code", "anthropic"}:
        return "Claude"
    if t in {"grok", "hermes", "xai"}:
        return "Grok"
    return ""


def _weekly_usage(conductor: dict[str, Any], workers: list[dict[str, Any]]) -> dict[str, Any]:
    """Team strip: the live model's weekly figure, or an honest empty.

    Live model = the conductor's pool (Hermes currently runs Grok). A Claude
    weekly percent never fills a Grok strip. No percent this poll →
    available False; we do not keep last poll's number.
    """
    live = _pool_name(str(conductor.get("type") or "")) or "Grok"
    out: dict[str, Any] = {"model": live, "available": False}
    for rec in [conductor, *workers]:
        if _pool_name(str(rec.get("type") or "")) != live:
            continue
        u = rec.get("usage") or {}
        if not isinstance(u, dict):
            continue
        if u.get("weekly_pct") is None:
            continue
        chip = u.get("weekly_chip") or u.get("chip")
        out = {
            "model": live,
            "available": True,
            "weekly_pct": u.get("weekly_pct"),
            "chip": chip,
        }
        if u.get("reset"):
            out["reset"] = u["reset"]
        if u.get("remaining"):
            out["remaining"] = u["remaining"]
        if u.get("used"):
            out["used"] = u["used"]
        return out
    return out


def _ticker(session: str, state: dict, jobs: dict) -> list:
    """Never let a ticker failure cost the whole snapshot — the island needs the
    rest of this payload far more than it needs a line of status."""
    try:
        from .ticker import build_ticker

        return build_ticker(session, state, jobs)
    except Exception:
        return []


def list_team_sessions() -> list[str]:
    """Names the poll loop is allowed to harvest and flush.

    pairs.json is first-class: a bound pair stays listed even when its tmux is
    momentarily gone. A leftover jobs directory is not a team: unioning every
    dead session's jobs dir in unconditionally is what produced a
    route.refused storm on every poll (35k refusals against sessions no
    longer in pairs.json). A name that comes only from the directory scan has
    to prove it is live; tmux missing reads as not live, the safe direction.
    """
    from .pane_activity import session_alive
    from .state import is_pair_name

    names = set()
    # A team saved in pairs.json is a team whatever it is called: the legacy
    # name pattern (pong-team, hermes-pair*) is for guessing at a tmux name,
    # not for deciding whether a saved lineup exists. "shop-bots" is a team.
    for k, v in load_pairs_db().items():
        if isinstance(v, dict) and (v.get("conductor") or v.get("workers")):
            names.add(str(k))
        elif is_pair_name(str(k)):
            names.add(str(k))
    jobs_root = state_dir() / "jobs"
    if jobs_root.exists():
        for p in sorted(jobs_root.iterdir()):
            if not p.is_dir() or p.name in names or not is_pair_name(p.name):
                continue
            if session_alive(p.name):
                names.add(p.name)
    return sorted(names)


def _auto_harvest_claims(sessions: list[str]) -> None:
    """Idle pane + Recap/CLAIM + open job → record the claim.

    Snapshot is the island's poll. Without this, a forgotten `pong job claim`
    keeps the seat busy until the 20-minute stuck timer fires.
    """
    try:
        from .claim_harvest import harvest_session
    except Exception:
        return
    for s in sessions:
        try:
            harvest_session(s)
        except Exception:
            continue


def _auto_flush_waitrooms(sessions: list[str]) -> None:
    """Cheap: when queue non-empty and seat free, deliver without human poking orch.

    Called from snapshot build (panel poll). No-op when queues empty.
    Jobs stay queued while a seat is busy. Claims may land on an idle pane
    even when the seat still has an open parent job.
    """
    try:
        from .waitroom import list_items, try_deliver
    except Exception:
        return
    for s in sessions:
        try:
            if not list_items(s, status="queued"):
                continue
            try_deliver(s, force=False)
        except Exception:
            continue


def build_snapshot(*, session: str | None = None, events_n: int = 40) -> dict[str, Any]:
    bound = detect_bound_session(session)
    bridge_line, bridge_code = gate_text(bound)
    bridge_on = bridge_line.startswith("BRIDGE_ON")
    db = load_pairs_db()
    if session:
        teams_list = [session]
    else:
        teams_list = list_team_sessions()
        # if bound not in list but has state, include
        if bound and bound not in teams_list:
            teams_list = [bound] + teams_list

    # Recover Recap/CLAIM text that never became `pong job claim`, then
    # flush waitroom so the harvested claims can actually deliver.
    _auto_harvest_claims(teams_list)
    # Auto-flush pending digests/jobs when seats free (no human “any updates?”)
    _auto_flush_waitrooms(teams_list)

    teams = []
    for s in teams_list:
        entry = db.get(s) if isinstance(db.get(s), dict) else None
        teams.append(team_snapshot(s, entry))

    try:
        led = ledger_mod.summary()
        led_public = {
            "rounds": led.get("rounds"),
            "accepts": led.get("accepts"),
            "rejects": led.get("rejects"),
            "escalations": led.get("escalations"),
            "accept_rate": led.get("accept_rate"),
            "reject_streak": led.get("reject_streak"),
            "last": led.get("last"),
        }
    except Exception:
        led_public = {
            "rounds": 0,
            "accepts": 0,
            "rejects": 0,
            "escalations": 0,
            "accept_rate": 0.0,
            "reject_streak": 0,
            "last": None,
        }

    cron_block: dict = {"runner_ok": False}
    try:
        from .cron import status as cron_status

        cron_block = cron_status()
    except Exception:
        pass
    # the same two as `pong graph list --json` (2.1): what the runner holds for Claude's usage limits
    # (null when all is well) and whether the runner that moves graphs past their first step is on
    try:
        from .limits import view as _limits_view

        limits_block = _limits_view()
    except Exception:
        limits_block = None
    try:
        from .doctor import _runner as _runner_check

        runner_block = _runner_check(time.time())
    except Exception:
        runner_block = None
    snap = {
        "schema_version": SCHEMA_VERSION,
        "contract_version": CONTRACT_VERSION,
        "generated_at": time.time(),
        "state_dir": str(state_dir()),
        "bound_session": bound,
        "bridge": bridge_line,
        "bridge_on": bridge_on,
        "bridge_code": bridge_code,
        "teams": teams,
        "ledger": led_public,
        "events_tail": events.tail(events_n, session=session),
        "mailbox": {
            "unread_total": sum(
                int((t.get("mailbox") or {}).get("unread_total") or 0) for t in teams
            )
        },
        # Each team's graphs are under teams[].work_graph. The all-teams copy that sat here was read by
        # nothing and was nearly half the snapshot (2.1).
        "cron": cron_block,
        "limits": limits_block,
        "runner": runner_block,
    }
    return snap


def write_snapshot(snap: dict[str, Any] | None = None, *, session: str | None = None) -> Path:
    """Write a snapshot where readers expect it.

    ``~/.pong/snapshot.json`` is the all-teams view the app and the island read.
    A snapshot of one team goes beside that team (``sessions/<s>/snapshot.json``):
    writing it over the shared file made every other team vanish from the map
    until the next full pass (each claim and each per-team drain did that).
    """
    snap = snap or build_snapshot(session=session)
    if session:
        from .paths import sessions_dir

        path = sessions_dir(session) / "snapshot.json"
    else:
        path = state_dir() / "snapshot.json"
    write_json(path, snap)
    return path
