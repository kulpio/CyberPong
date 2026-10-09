"""Fluid work graph under a main agent.

Org graph (flow_graph + workers[]) stays still. Work under a main is a
disposable graph stored in ``sessions/<session>/work_graph.json``.

Spawning a loop must NOT mutate ``flow_graph`` or permanent ``workers[]``.
Jobs for work-graph seats carry ``work_graph_id`` / ``work_owner`` so claims
bubble to the goal owner only.
"""

from __future__ import annotations

import fcntl
import os
import time
import uuid
from contextlib import contextmanager
from pathlib import Path
from typing import Any, Iterator

from .jsonutil import read_json, write_json
from .loops import (
    FAN_CAP,
    GAUNTLET_PIECES_CAP,
    LoopError,
    assert_start_args,
    load_loop,
)
from .examples import with_examples as _task_with_examples
from .paths import ensure_layout, sessions_dir

GRAPH_VERSION = 1


class WorkGraphError(ValueError):
    pass


def work_graph_path(session: str) -> Path:
    ensure_layout(session)
    return sessions_dir(session) / "work_graph.json"


@contextmanager
def _graph_lock(session: str, *, blocking: bool = True) -> Iterator[bool]:
    """Serialise read-modify-write on ``work_graph.json``.

    :func:`tick` is called from the cron runner, from ``pong drain``, from the
    panel's snapshot poll and by hand. Two of those landing together on one
    gauntlet each read the graph before either wrote it, and both conclude the
    builder is done and needs a critic — two critic jobs, two panes, one node
    id, and a round that grades itself twice. The waitroom already takes this
    precaution for exactly this reason.

    ``blocking=False`` yields ``False`` instead of waiting, which is what a
    periodic tick wants: if another tick holds the lock the work is already
    being done, and queueing a second one behind it only means doing it twice.
    """
    path = work_graph_path(session)
    lock_path = path.with_suffix(".json.lock")
    path.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(str(lock_path), os.O_CREAT | os.O_RDWR, 0o600)
    held = False
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX if blocking else fcntl.LOCK_EX | fcntl.LOCK_NB)
            held = True
        except OSError:
            if blocking:
                raise
        yield held
    finally:
        if held:
            try:
                fcntl.flock(fd, fcntl.LOCK_UN)
            except OSError:
                pass
        os.close(fd)


def load(session: str) -> dict[str, Any]:
    path = work_graph_path(session)
    data = read_json(path)
    if not data:
        return {"version": GRAPH_VERSION, "graphs": []}
    graphs = data.get("graphs")
    if not isinstance(graphs, list):
        graphs = []
    return {"version": int(data.get("version") or GRAPH_VERSION), "graphs": graphs}


def save(session: str, data: dict[str, Any]) -> None:
    payload = {
        "version": GRAPH_VERSION,
        "graphs": data.get("graphs") or [],
        "updated_at": time.time(),
    }
    write_json(work_graph_path(session), payload)


def find_graph(session: str, graph_id: str) -> dict[str, Any] | None:
    gid = str(graph_id or "")
    for g in load(session).get("graphs") or []:
        if isinstance(g, dict) and str(g.get("id") or "") == gid:
            return g
    return None


def owner_of_seat(session: str, seat: str) -> str | None:
    """Work-graph owner for a disposable seat, or None if org-graph only."""
    sid = str(seat or "").strip()
    if not sid:
        return None
    for g in load(session).get("graphs") or []:
        if not isinstance(g, dict):
            continue
        # A finished loop no longer owns anyone: a roster seat it borrowed goes
        # back to claiming along the org graph.
        if str(g.get("status") or "") not in ("running", "waiting"):
            continue
        if str(g.get("owner") or "") == sid:
            return sid
        for n in g.get("nodes") or []:
            if isinstance(n, dict) and str(n.get("seat") or "") == sid:
                return str(g.get("owner") or "") or None
    return None


def graph_for_job(session: str, job: dict[str, Any]) -> dict[str, Any] | None:
    gid = str(job.get("work_graph_id") or "")
    if gid:
        return find_graph(session, gid)
    seat = str(job.get("worker") or "")
    for g in load(session).get("graphs") or []:
        if not isinstance(g, dict):
            continue
        for n in g.get("nodes") or []:
            if isinstance(n, dict) and (
                str(n.get("seat") or "") == seat
                or str(n.get("job_id") or "") == str(job.get("id") or "")
            ):
                return g
    return None


def _new_id(prefix: str = "g") -> str:
    return f"{prefix}_{uuid.uuid4().hex[:10]}"


def _letter(i: int) -> str:
    return chr(ord("a") + i) if 0 <= i < 26 else f"n{i}"


#: A loop node's role in graph words, as a mission role the rest of the control
#: plane already understands (identity block, review bars, seat status).
_MISSION_BY_ROLE = {
    "builder": "coder",
    "critic": "reviewer",
    "router": "task_runner",
    "join": "task_runner",
    # A writer, scout, operator or researcher was told its locked role was
    # "Coder" (audit 2026-09-24); each has its own playbook in role_identity.
    "writer": "writer",
    "scout": "researcher",
    "researcher": "researcher",
    "operator": "operator",
}


def _synthetic_worker(
    seat: str,
    owner: str,
    role: str,
    *,
    task: str = "",
    session: str | None = None,
    boundaries: dict[str, Any] | None = None,
    in_cycle: bool = False,
    pin: str | None = None,
    mission: str | None = None,
    wire_role: str | None = None,
    pin_why: str | None = None,
) -> dict[str, Any]:
    """A disposable seat, pointed at the runtime and model the work calls for.

    The pick comes from :mod:`pong.wiring`, which asks :mod:`pong.models` by
    rule and then records why every other platform was not chosen. It travels
    with the seat so the island, the map, the trace and the pane banner can all
    say what was chosen and why. A pin from the goal wins; a pin a boundary
    forbids is refused out loud and the rules choose instead.
    """
    from .wiring import plan_node

    mission = mission or _MISSION_BY_ROLE.get(role, "coder")
    try:
        plan = plan_node(wire_role or role or mission, task, session=session, boundaries=boundaries,
                         pin=pin, in_cycle=in_cycle, pin_why=pin_why)
    except Exception as e:  # a loop that runs on the default beats a loop that raises
        plan = {"runtime": "claude", "model": None, "cmd": "claude", "rule": "default",
                "why": f"catalog unavailable ({type(e).__name__}) — defaulted to claude",
                "rejected": {}, "conflict": None, "launch_cmd": "claude"}
    runtime = str(plan.get("runtime") or "claude")
    # boundaries.live_tools = false (a topology's choice): the seat starts with no MCP
    # servers and no claude.ai connectors, so a research or planning step cannot reach
    # live systems (mail, the database, a company's own services) even by mistake.
    no_live = isinstance(boundaries, dict) and boundaries.get("live_tools") is False
    return {
        "no_live_tools": no_live,
        "id": seat,
        "type": runtime,
        "label": f"{role}:{seat}",
        "cmd": str(plan.get("cmd") or runtime),
        "model": plan.get("model"),
        "mode": "tmux",
        "parent_id": owner,
        "ephemeral": True,
        "mission_role": mission,
        "done_marker": "##WORKER_DONE##",
        "model_rule": plan.get("rule"),
        "model_why": plan.get("why"),
        "rejected": plan.get("rejected") or {},
        "conflict": plan.get("conflict"),
        "launch_cmd": plan.get("launch_cmd"),
    }


def _roster_by_id(session: str) -> dict[str, dict[str, Any]]:
    from .state import load_session_state, workers_from_state

    state = load_session_state(session)
    out: dict[str, dict[str, Any]] = {}
    for w in workers_from_state(state):
        if not isinstance(w, dict):
            continue
        wid = str(w.get("id") or "").strip()
        if wid:
            out[wid] = w
    return out


def _roster_worker(session: str, seat: str) -> dict[str, Any] | None:
    """Roster worker dict when that seat exists and has pane_id."""
    w = _roster_by_id(session).get(str(seat or "").strip())
    if w and str(w.get("pane_id") or "").strip():
        return dict(w)
    return None


def _live_seats(session: str, owner: str, participants: Any = None) -> list[str]:
    """Owner + participants that have pane_id on session workers[]."""
    roster = _roster_by_id(session)
    live: list[str] = []
    for seat in normalize_participants(owner, participants):
        w = roster.get(seat)
        if w and str(w.get("pane_id") or "").strip():
            live.append(seat)
    return live


def _next_free_child(owner: str, used: Any, *, start: int = 0) -> str:
    """First ``owner.<letter>`` not already spoken for by another node."""
    taken = {str(s or "") for s in (used or ())}
    # past z the names go on (c1.n26, c1.n27, ...): wrapping back to the start
    # handed a second graph a seat another graph was still holding
    for i in range(max(0, int(start)), 26 + 500):
        seat = f"{owner}.{_letter(i)}"
        if seat not in taken:
            return seat
    return f"{owner}.{_letter(start)}"


def _runtime_has_tools(session: str, worker: dict[str, Any]) -> bool:
    """Whether this seat's CLI is a tools runtime, per the model catalog.

    Asked of the catalog rather than a hardcoded list so that adding a runtime
    is a catalog edit, not a code edit. A catalog we cannot read answers False:
    the caller then falls back to a disposable seat the router can aim, which is
    the safe direction — never silently promote a pane with no tools.
    """
    try:
        from .models import runtimes

        row = runtimes(session).get(str(worker.get("type") or "")) or {}
    except Exception:
        # This repo has no model catalog at all, so the import itself is the
        # thing that fails. The docstring above already says an unreadable
        # catalog answers False, so the import moved inside the guard rather
        # than a catalog being invented to satisfy it — same answer, and the
        # safe direction: never silently promote a pane with no tools.
        return False
    return bool(row.get("tools"))


def _pick_loop_seats(
    session: str,
    owner: str,
    participants: Any = None,
    *,
    n_builders: int = 1,
    need_critic: bool = False,
) -> tuple[list[str], str | None]:
    """Prefer live participant panes for builders; critic defaults disposable.

    The builder wants a live pane — a human's seat already has the checkout and
    the context. The critic does not: grading is the one job where the model
    matters more than the window, and a disposable child of the owner is what
    lets :mod:`pong.models` aim the strongest reviewing model at it.

    A roster pane is therefore only borrowed as critic when all three hold: it
    is a named participant, its mission role is reviewer, and its runtime is a
    tools runtime in the catalog. A bare Grok pane passes the middle test and
    fails the last one — grading a code polish pass from a seat with no MCP and
    no skills is exactly the bar drop the catalog exists to prevent.
    """
    live = _live_seats(session, owner, participants)
    builders: list[str] = []
    for i in range(max(1, int(n_builders))):
        if i < len(live):
            builders.append(live[i])
        else:
            builders.append(f"{owner}.{_letter(i)}")
    critic: str | None = None
    if need_critic:
        used = set(builders)
        critic = _next_free_child(owner, used, start=1)
        roster = _roster_by_id(session)
        for seat in live:
            if seat in used:
                continue
            worker = roster.get(seat) or {}
            if str(worker.get("mission_role") or "") != "reviewer":
                continue
            if not _runtime_has_tools(session, worker):
                continue
            critic = seat
            break
    return builders, critic


def _ensure_terminal(
    session: str, worker: dict[str, Any], *, task: str = "", initial_prompt: str = ""
) -> dict[str, Any]:
    """Give a disposable seat a pane before anything is dispatched to it.

    Roster seats are left alone — a human owns those windows. For an ephemeral
    seat this is the difference between a loop that runs and a loop that looks
    like it is running: without a registered pane the paste transport refuses
    (correctly — it never guesses a window index), the job file lands with
    nobody to read it, and the node sits at ``running`` until someone goes
    looking.

    A freshly spawned seat is marked busy for a short TTL so the first paste
    goes through the waitroom rather than into a TUI that is still drawing.
    """
    out: dict[str, Any] = {"spawned": False, "note": "roster seat — left alone"}
    if not worker.get("ephemeral"):
        return out
    try:
        from .groups import ensure_ephemeral_window
        from .state import load_session_state

        state = load_session_state(session) or {}
        state.setdefault("session", session)
        out = ensure_ephemeral_window(state, worker, task=task, initial_prompt=initial_prompt)
    except Exception as e:  # a loop that dispatches beats a loop that raises
        return {"spawned": False, "note": f"spawn failed — {e}"}
    if out.get("pane_id"):
        worker["pane_id"] = out["pane_id"]
    if out.get("tmux_index") is not None:
        worker["tmux_index"] = out["tmux_index"]
    if out.get("spawned") and not out.get("with_prompt"):
        try:
            from .seat_status import set_busy

            set_busy(session, str(worker.get("id") or ""), reason="starting")
        except Exception:
            pass
    return out


def _create_work_job(
    session: str,
    *,
    owner: str,
    seat: str,
    task: str,
    role: str,
    graph_id: str,
    node_id: str,
    extra: dict[str, Any] | None = None,
    graph: dict[str, Any] | None = None,
) -> dict[str, Any]:
    from .jobs import create_job
    from .transports.dispatch import dispatch_job, parse_transport_plan

    probe = graph if isinstance(graph, dict) else find_graph(session, graph_id)
    if probe is None:
        probe = {"owner": owner, "participants": normalize_participants(owner, None), "nodes": []}
    assert_allowed_seat(probe, seat)

    in_cycle = role in ("builder", "critic") and str(probe.get("kind") or "") in ("cycle", "gauntlet")
    pins = probe.get("pins") if isinstance(probe.get("pins"), dict) else {}
    mission = str(probe.get("builder_role") or "") or None if role == "builder" else None
    wire_role = str(probe.get("wire_role") or "") or None if role == "builder" else None
    worker = _roster_worker(session, seat) or _synthetic_worker(
        seat, owner, role, task=task, session=session,
        boundaries=probe.get("boundaries"), in_cycle=in_cycle, pin=pins.get(node_id) or pins.get(str(role or "")) or pins.get("*"),
        pin_why=("Another model family than the step before it (the engine's choice). "
                 if node_id in (probe.get("family_picks") or {}) else None),
        mission=mission, wire_role=wire_role,
    )
    # A disposable seat whose pane is not up yet starts ON its job: the prompt
    # file is written first and the CLI is launched with a one-line pointer to
    # it. Nothing is pasted into a TUI that is still drawing (Claude seats left
    # long pastes unsubmitted; a trust prompt swallowed them). A seat that is
    # already live gets the paste as before.
    launch_first = bool(worker.get("ephemeral")) and str(worker.get("type") or "") in ("claude", "grok", "codex")
    spawn = {} if launch_first else _ensure_terminal(session, worker, task=task)
    payload = {
        "work_node": True,
        "work_graph_id": graph_id,
        "work_node_id": node_id,
        "work_owner": owner,
        "work_role": role,
        "from_seat": owner,
        "_worker": worker,
        "no_recap": role == "critic",
        "no_identity": role == "critic",
        "mission_role": worker.get("mission_role"),
        "runtime": worker.get("type"),
        "model": worker.get("model"),
        "model_why": worker.get("model_why"),
        "model_rule": worker.get("model_rule"),
        "rejected": worker.get("rejected"),
        "spawn": {
            k: spawn.get(k)
            for k in ("spawned", "pane_id", "tmux_index", "note")
            if spawn.get(k) is not None
        },
    }
    if extra:
        payload.update(extra)
    try:
        acceptance = probe.get("acceptance") if role == "builder" else None
        job = create_job(
            session=session,
            worker_key=seat,
            task=task,
            require_claim=True,
            acceptance=list(acceptance) if isinstance(acceptance, list) and acceptance else None,
            extra=payload,
        )
        prompt_path = job.get("prompt_path")
        if prompt_path:
            job["_prompt"] = Path(str(prompt_path)).read_text(encoding="utf-8")
        from .graph_log import append as _log_append

        _log_append(probe, "dispatch", node=node_id, role=role, seat=seat, job_id=job.get("id"),
                    runtime=worker.get("type"), model=worker.get("model"), model_rule=worker.get("model_rule"),
                    prompt_path=prompt_path, launch_first=launch_first or None)
        state = job.get("_state") or {}
        dispatch_worker = job.get("_worker") or worker
        if launch_first:
            pointer = (f"Your job is in the file {prompt_path}. Read that file first, then do exactly what it says, "
                       f"and finish with the pong job claim command it gives you.")
            spawn = _ensure_terminal(session, worker, task=task, initial_prompt=pointer)
            job["spawn"] = {k: spawn.get(k) for k in ("spawned", "pane_id", "tmux_index", "note", "with_prompt")
                            if spawn.get(k) is not None}
            if spawn.get("pane_id"):
                dispatch_worker = dict(dispatch_worker)
                dispatch_worker["pane_id"] = spawn["pane_id"]
                if spawn.get("tmux_index") is not None:
                    dispatch_worker["tmux_index"] = spawn["tmux_index"]
            if spawn.get("spawned") and spawn.get("with_prompt"):
                from .jobs import set_status
                from .seat_status import set_busy

                set_status(session, str(job["id"]), "notified", skip_snapshot=True,
                           transports_used=["launch_prompt"], spawn=job["spawn"])
                job["status"] = "notified"
                try:
                    set_busy(session, seat, reason="job", job_id=str(job["id"]))
                except Exception:
                    pass
                return job
        plan = parse_transport_plan(str(state.get("transport_default") or "job+paste"))
        dispatch_job(job, dispatch_worker, state, plan=plan)
        return job
    except WorkGraphError:
        raise
    except Exception as e:
        raise WorkGraphError(f"could not create job for {seat}: {e}") from e


def normalize_participants(owner: str, with_seats: Any = None) -> list[str]:
    """Owner first, then unique named mains from --with / participants."""
    owner = str(owner or "").strip()
    raw: list[str] = []
    if isinstance(with_seats, str):
        raw = [p.strip() for p in with_seats.split(",") if p.strip()]
    elif isinstance(with_seats, (list, tuple)):
        raw = [str(p).strip() for p in with_seats if str(p).strip()]
    out: list[str] = []
    seen: set[str] = set()
    for p in ([owner] if owner else []) + raw:
        if p and p not in seen:
            out.append(p)
            seen.add(p)
    return out


def allowed_seats(graph: dict[str, Any]) -> set[str]:
    """Owner + participants + ephemeral children of the owner (owner.a, …)."""
    owner = str(graph.get("owner") or "").strip()
    seats = set(normalize_participants(owner, graph.get("participants")))
    if owner:
        seats.add(owner)
    for n in graph.get("nodes") or []:
        if not isinstance(n, dict):
            continue
        seat = str(n.get("seat") or "").strip()
        if not seat:
            continue
        if seat == owner or (owner and seat.startswith(owner + ".")) or seat in seats:
            seats.add(seat)
    return seats


def assert_allowed_seat(graph: dict[str, Any], seat: str) -> None:
    seat = str(seat or "").strip()
    owner = str(graph.get("owner") or "").strip()
    if not seat:
        raise WorkGraphError("seat is required")
    if seat in allowed_seats(graph):
        return
    if owner and (seat == owner or seat.startswith(owner + ".")):
        return
    raise WorkGraphError(
        f"seat {seat} is not in this loop "
        "(owner + participants + ephemeral children of owner)"
    )


def _repair_node_seat(
    session: str, graph: dict[str, Any], node: dict[str, Any], *, role: str = "builder"
) -> tuple[str, bool]:
    """Return a legal seat for *node*, re-deriving one if the stored seat is gone.

    A seat can be legal when it is written and illegal by the time it runs: the
    graph predates a rule, someone hand-edited the file, or the roster seat left
    the participants list. assert_allowed_seat is right to refuse it, but
    refusing at tick is a dead end — the node cannot run, nothing rewrites it,
    and the whole loop is wedged on one stored string. So re-derive a disposable
    child of the owner, record the swap on the node, and carry on.

    Returns ``(seat, repaired)``. Never silent: the swap is on the node and in
    the event log.
    """
    seat = str(node.get("seat") or "").strip()
    try:
        assert_allowed_seat(graph, seat)
        return seat, False
    except WorkGraphError:
        pass

    owner = str(graph.get("owner") or "").strip()
    used = {
        str(n.get("seat") or "")
        for n in (graph.get("nodes") or [])
        if isinstance(n, dict) and n is not node
    }
    repaired = _next_free_child(owner, used, start=1 if role == "critic" else 0)
    node["seat"] = repaired
    node["seat_repaired"] = {
        "from": seat,
        "to": repaired,
        "role": role,
        "at": time.time(),
    }
    try:
        from . import events

        # No work_graph.* type is registered, so this lands as `system` with
        # original_type kept — visible in events.jsonl without a schema edit.
        events.emit(
            "work_graph.seat_repaired",
            session=session,
            graph_id=str(graph.get("id") or ""),
            node_id=str(node.get("id") or ""),
            role=role,
            old_seat=seat,
            new_seat=repaired,
        )
    except Exception:
        pass
    return repaired, True


def start(
    session: str,
    *,
    owner: str,
    loop: str,
    task: str,
    bar: str | None = None,
    fan_n: int = 2,
    max_rounds: int | None = None,
    pieces: int | None = None,
    participants: Any = None,
    examples: Any = None,
    boundaries: dict[str, Any] | None = None,
    pins: dict[str, str] | None = None,
    builder_role: str | None = None,
    wire_role: str | None = None,
    acceptance: list[Any] | None = None,
    topology: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """Attach a disposable loop under *owner*. Does not touch flow_graph/workers."""
    from .examples import normalize_selected, with_examples as _task_with_examples, write_bar

    owner = str(owner or "").strip()
    if not owner:
        raise WorkGraphError("--owner is required")
    participants = normalize_participants(owner, participants)
    kind = str(loop or "").strip().lower()
    selected = normalize_selected(examples)
    try:
        assert_start_args(kind, bar=bar, fan_n=fan_n, examples=selected)
    except LoopError as e:
        raise WorkGraphError(str(e)) from e
    spec = load_loop(kind, session)
    rounds = int(max_rounds or spec.get("max_rounds") or 3)
    n_fan = max(1, min(int(fan_n or 2), FAN_CAP))
    n_pieces = max(2, min(int(pieces or 2), GAUNTLET_PIECES_CAP))
    if kind == "gauntlet" and n_pieces > GAUNTLET_PIECES_CAP:
        raise WorkGraphError(f"gauntlet pieces cap is {GAUNTLET_PIECES_CAP}")

    gid = _new_id("g")
    # GUI / `pong -s SESSION goal start` has no PONG_SESSION export.
    # Bind it here so create_job's write gate sees caller == target.
    if session and not (os.environ.get("PONG_SESSION") or "").strip():
        os.environ["PONG_SESSION"] = session
    bar_written: Path | None = None
    if selected and not str(bar or "").strip():
        bar_written = write_bar(session, gid, task, selected)
        bar = str(bar_written)
    try:
        return _start_graph(
            session,
            owner=owner,
            kind=kind,
            task=task,
            bar=bar,
            selected=selected,
            participants=participants,
            spec=spec,
            rounds=rounds,
            n_fan=n_fan,
            gid=gid,
            boundaries=boundaries,
            pins=pins,
            builder_role=builder_role,
            wire_role=wire_role,
            acceptance=acceptance,
            topology=topology,
        )
    except Exception:
        if bar_written is not None:
            try:
                bar_written.unlink()
            except Exception:
                pass
        raise


def _start_graph(
    session: str,
    *,
    owner: str,
    kind: str,
    task: str,
    bar: str | None,
    selected: list[dict[str, Any]],
    participants: list[str],
    spec: dict[str, Any],
    rounds: int,
    n_fan: int,
    gid: str,
    boundaries: dict[str, Any] | None = None,
    pins: dict[str, str] | None = None,
    builder_role: str | None = None,
    wire_role: str | None = None,
    acceptance: list[Any] | None = None,
    topology: dict[str, Any] | None = None,
) -> dict[str, Any]:
    from .wiring import normalize_boundaries

    nodes: list[dict[str, Any]] = []
    edges: list[dict[str, Any]] = []
    jobs_out: list[dict[str, Any]] = []
    if kind == "graph" and ((topology or {}).get("boundaries") or {}).get("client_facing"):
        # a topology may only tighten this: its client-facing work reaches the wiring plan
        # (no client-facing prose from the wrong seat) and never goes to Jev
        boundaries = {**(boundaries or {}), "client_facing": True}
    bnd = normalize_boundaries(boundaries)
    pins = {str(k): str(v) for k, v in (pins or {}).items()}
    probe = {"owner": owner, "participants": participants, "nodes": [], "kind": kind,
             "boundaries": bnd, "pins": pins, "builder_role": builder_role,
             "wire_role": wire_role, "acceptance": list(acceptance or [])}

    builders, _ = _pick_loop_seats(session, owner, participants, n_builders=n_fan)

    if kind == "fan":
        wait_ids: list[str] = []
        for i in range(n_fan):
            nid = f"fan_{_letter(i)}"
            seat = builders[i] if i < len(builders) else f"{owner}.{_letter(i)}"
            piece_task = _task_with_examples(
                f"{task.rstrip()}\n\n"
                f"You are fan piece {i + 1}/{n_fan} under {owner}. "
                f"Claim when your slice is done.",
                selected,
            )
            job = _create_work_job(
                session,
                owner=owner,
                seat=seat,
                task=piece_task,
                role="builder",
                graph_id=gid,
                node_id=nid,
                graph=probe,
            )
            nodes.append(
                {
                    "id": nid,
                    "kind": "seat",
                    "role": "builder",
                    "seat": seat,
                    "job_id": job["id"],
                    "status": "running",
                }
            )
            wait_ids.append(job["id"])
            jobs_out.append(job)
        nodes.append(
            {
                "id": "join",
                "kind": "join",
                "role": "join",
                "seat": owner,
                "wait_on": wait_ids,
                "status": "waiting",
            }
        )
        for n in nodes:
            if n["id"] != "join":
                edges.append({"from": n["id"], "to": "join", "on": "done"})
    elif kind == "join":
        nodes.append(
            {
                "id": "join",
                "kind": "join",
                "role": "join",
                "seat": owner,
                "wait_on": [],
                "status": "waiting",
            }
        )
    elif kind == "router":
        seat = f"{owner}.r"
        job = _create_work_job(
            session,
            owner=owner,
            seat=seat,
            task=_task_with_examples(task, selected),
            role="router",
            graph_id=gid,
            node_id="router",
            graph=probe,
            )
        nodes.append(
            {
                "id": "router",
                "kind": "router",
                "role": "router",
                "seat": seat,
                "job_id": job["id"],
                "status": "running",
            }
        )
        jobs_out.append(job)
    elif kind == "cycle":
        seat = builders[0] if builders else f"{owner}.a"
        job = _create_work_job(
            session,
            owner=owner,
            seat=seat,
            task=_task_with_examples(task, selected),
            role="builder",
            graph_id=gid,
            node_id="builder",
            extra={"round": 1},
            graph=probe,
            )
        nodes.append(
            {
                "id": "builder",
                "kind": "cycle",
                "role": "builder",
                "seat": seat,
                "job_id": job["id"],
                "status": "running",
                "round": 1,
                "max_rounds": rounds,
            }
        )
        edges.append({"from": "builder", "to": "builder", "on": "cycle"})
        jobs_out.append(job)
    elif kind == "gauntlet":
        bar_path = str(bar or "").strip()
        picked, critic_picked = _pick_loop_seats(
            session, owner, participants, n_builders=1, need_critic=True
        )
        builder_seat = picked[0] if picked else f"{owner}.a"
        critic_seat = critic_picked or f"{owner}.b"
        # The critic carries a seat but gets no job until the first tick, so the
        # assert inside _create_work_job never sees it. Check it here, before the
        # builder is spawned and dispatched — the catch-all loop below would
        # refuse this graph anyway, but only after leaving an orphan job behind.
        assert_allowed_seat(probe, critic_seat)
        builder_task = _task_with_examples(
            f"{task.rstrip()}\n\n"
            f"## Gauntlet bar\n"
            f"The critic will score you against: `{bar_path}`.\n"
            f"Publish artifacts (file paths) in your CLAIM. "
            f"Do not grade yourself.",
            selected,
        )
        job = _create_work_job(
            session,
            owner=owner,
            seat=builder_seat,
            task=builder_task,
            role="builder",
            graph_id=gid,
            node_id="builder",
            extra={"round": 1, "bar": bar_path},
            graph=probe,
            )
        nodes.append(
            {
                "id": "builder",
                "kind": "seat",
                "role": "builder",
                "seat": builder_seat,
                "job_id": job["id"],
                "status": "running",
                "round": 1,
                "bar": bar_path,
            }
        )
        nodes.append(
            {
                "id": "critic",
                "kind": "seat",
                "role": "critic",
                "seat": critic_seat,
                "job_id": None,
                "status": "pending",
                "bar": bar_path,
            }
        )
        nodes.append(
            {
                "id": "join",
                "kind": "join",
                "role": "join",
                "seat": owner,
                "wait_on": [],
                "status": "waiting",
            }
        )
        edges.extend(
            [
                {"from": "builder", "to": "critic", "on": "done"},
                {"from": "critic", "to": "builder", "on": "fail"},
                {"from": "critic", "to": "join", "on": "win"},
            ]
        )
        jobs_out.append(job)
    elif kind == "graph":
        from . import graph_engine

        topo = lint_topology(topology or {})
        rounds = int(topo.get("max_rounds") or rounds)
        nodes, edges, jobs_out, custom = graph_engine.start_nodes(session, owner, task, topo, probe, gid, participants)
    else:
        raise WorkGraphError(f"unhandled loop kind {kind!r}")

    graph = {
        "id": gid,
        "owner": owner,
        "participants": participants,
        "goal": task,
        "kind": kind,
        "status": "running",
        "bar": (bar or None),
        "examples": selected,
        "max_rounds": rounds,
        "round": 1,
        "created_at": time.time(),
        "nodes": nodes,
        "edges": edges,
        "catalog": spec.get("kind"),
        "boundaries": bnd,
        "pins": pins,
        "builder_role": builder_role,
        "wire_role": wire_role,
        "acceptance": list(acceptance or []),
        "paused": None,
        "topology": ({"start": (topology or {}).get("start"), "name": (topology or {}).get("name")} if kind == "graph" else None),
        "history": [],
        "wiring": _wiring_of(jobs_out, nodes, owner=owner, task=task, session=session,
                             boundaries=bnd, kind=kind, pins=pins,
                             builder_role=builder_role, wire_role=wire_role),
        "refusals": [],
    }
    if kind == "graph":
        # The graph runtime owns these fields; its start already wrote them.
        planned = dict(graph.get("wiring") or {})
        planned.update(custom.get("wiring") or {})
        graph.update({k: v for k, v in custom.items() if v is not None and k != "wiring"})
        graph["wiring"] = planned
        graph["topology"]["notes"] = topo.get("notes") or ""
        graph["topology"]["starts"] = topo.get("starts") or [topo.get("start")]
    # Enforce the seat invariant here, where it is cheap and loud. A node that
    # carries a seat but no job yet — the gauntlet critic is the only one — used
    # to reach disk unchecked, because the only assert_allowed_seat on the path
    # lives in _create_work_job and the critic's job is not created until the
    # first tick. Start and tick then disagreed about the same stored value and
    # the loop had no way forward and no way back. Fail at start instead.
    for n in nodes:
        node_seat = str(n.get("seat") or "").strip()
        if node_seat:
            assert_allowed_seat(graph, node_seat)
    # Only the append is locked. The dispatch above spawns panes and can take
    # seconds; holding the lock across it would stall every tick on the machine.
    with _graph_lock(session):
        data = load(session)
        graphs = list(data.get("graphs") or [])
        graphs.append(graph)
        data["graphs"] = graphs
        save(session, data)
    graph["_jobs"] = jobs_out
    return graph


def _wiring_of(
    jobs: list[dict[str, Any]],
    nodes: list[dict[str, Any]],
    *,
    owner: str,
    task: str,
    session: str | None,
    boundaries: dict[str, Any] | None,
    kind: str,
    pins: dict[str, str] | None = None,
    builder_role: str | None = None,
    wire_role: str | None = None,
) -> dict[str, Any]:
    """node id → who runs it and why. Nodes without a job yet (the gauntlet
    critic) are planned the same way so the map can show them before round one
    ends; the plan is re-made when the job is actually created."""
    out: dict[str, Any] = {}
    by_job = {str(j.get("id") or ""): j for j in jobs}
    for n in nodes:
        nid = str(n.get("id") or "")
        role = str(n.get("role") or "")
        seat = str(n.get("seat") or "")
        job = by_job.get(str(n.get("job_id") or ""))
        if job is not None:
            w = job.get("_worker") or {}
            out[nid] = {
                "seat": seat, "role": role, "runtime": job.get("runtime") or w.get("type"),
                "model": job.get("model") or w.get("model"), "rule": job.get("model_rule") or w.get("model_rule"),
                "why": job.get("model_why") or w.get("model_why"), "rejected": job.get("rejected") or w.get("rejected") or {},
                "persist": not bool(w.get("ephemeral", True)), "status": "running",
            }
        elif role in ("critic", "builder", "router", "scout", "writer", "operator", "researcher") and seat and not (session and _roster_worker(session, seat)):
            w = _synthetic_worker(seat, owner, role, task=task, session=session, boundaries=boundaries,
                                  in_cycle=kind in ("cycle", "gauntlet", "graph"), pin=(pins or {}).get(nid) or (pins or {}).get(role) or (pins or {}).get("*"),
                                  wire_role=(wire_role if role == "builder" else None),
                                  mission=(builder_role if role == "builder" else None))
            out[nid] = {"seat": seat, "role": role, "runtime": w.get("type"), "model": w.get("model"),
                        "rule": w.get("model_rule"), "why": w.get("model_why"), "rejected": w.get("rejected") or {},
                        "persist": False, "status": "planned"}
        else:
            out[nid] = {"seat": seat, "role": role, "runtime": None, "model": None, "rule": "seat",
                        "why": "runs on the owner's own seat" if seat == owner else "roster seat",
                        "rejected": {}, "persist": True, "status": str(n.get("status") or "")}
    return out


def _post_owner(session: str, graph: dict[str, Any], *, kind: str, summary: str, job_id: str = "", **extra: Any) -> None:
    """Best-effort mailbox item to the goal owner. The tick never fails on it."""
    try:
        from .mailbox import post

        post(session, str(graph.get("owner") or ""), kind=kind, from_seat="loop",
             job_id=job_id, summary=summary,
             extra={"graph_id": graph.get("id"), "loop": graph.get("kind"), **extra})
    except Exception:
        pass
    try:  # the same news for the graph's architect, if it has one
        from .architect import queue_event

        queue_event(session, graph, kind=kind, summary_text=summary)
    except Exception:
        pass


def _node(graph: dict[str, Any], nid: str) -> dict[str, Any] | None:
    for n in graph.get("nodes") or []:
        if isinstance(n, dict) and str(n.get("id") or "") == nid:
            return n
    return None


def _job_done(session: str, job_id: str) -> dict[str, Any] | None:
    if not job_id:
        return None
    from .jobs import load_job
    from .schema import TERMINAL_STATUSES

    job = load_job(session, job_id)
    if not job:
        return None
    if str(job.get("status") or "") in TERMINAL_STATUSES:
        return job
    return None


def _critic_task(bar: str, artifacts: list[str], goal: str, round_n: int, examples: object = None) -> str:
    arts = "\n".join(f"- {a}" for a in artifacts) or "- (no artifacts listed)"
    _ = goal  # owner goal stays on the graph; critic must not see builder text
    from .examples import with_examples
    body = (
        f"## Gauntlet critic · round {round_n}\n"
        f"Score the artifacts against the published bar. "
        f"You do **not** receive the builder's transcript, prompt, or task text — "
        f"only the bar and the artifact refs.\n\n"
        f"Bar: `{bar}`\n"
        f"Artifacts:\n{arts}\n\n"
        f"CLAIM summary must start with `win` or `fail` "
        f"(or set next=win / next=fail). "
        f"Do not edit the builder's files."
    )
    return with_examples(body, examples)


def _critic_explicit(job: dict[str, Any]) -> bool:
    """Did the critic actually say win or fail?

    A claim with neither is not a verdict, and the old fall-through ("done"
    means win) let a critic that claimed without grading pass the work. The
    end state of a node is a verified output or a logged refusal; an ambiguous
    grade is the second one.
    """
    result = job.get("result") if isinstance(job.get("result"), dict) else {}
    nxt = str(result.get("next") or "").strip().lower()
    if nxt in ("win", "fail", "done", "cycle"):
        return True
    claim = job.get("claim") if isinstance(job.get("claim"), dict) else {}
    summary = str(claim.get("summary") or result.get("summary") or "").strip().lower()
    if summary.startswith(("win", "fail", "reject")):
        return True
    st = str(result.get("status") or "").lower()
    return st in ("fail", "failed", "rejected")


def _critic_verdict(job: dict[str, Any]) -> str:
    result = job.get("result") if isinstance(job.get("result"), dict) else {}
    nxt = str(result.get("next") or "").strip().lower()
    if nxt in ("win", "fail", "done", "cycle"):
        return "win" if nxt == "done" else nxt
    claim = job.get("claim") if isinstance(job.get("claim"), dict) else {}
    summary = str(claim.get("summary") or result.get("summary") or "").strip().lower()
    if summary.startswith("win"):
        return "win"
    if summary.startswith("fail") or summary.startswith("reject"):
        return "fail"
    st = str(result.get("status") or job.get("status") or "").lower()
    if st in ("fail", "failed", "rejected"):
        return "fail"
    # Ambiguous. Never a win by default — see _critic_explicit.
    return "fail"


def _artifacts_of(job: dict[str, Any]) -> list[str]:
    result = job.get("result") if isinstance(job.get("result"), dict) else {}
    arts = result.get("artifacts") or []
    if isinstance(arts, list) and arts:
        return [str(a) for a in arts]
    claim = job.get("claim") if isinstance(job.get("claim"), dict) else {}
    files = claim.get("files") or []
    if isinstance(files, list):
        return [str(f) for f in files]
    return []


def tick(session: str, *, graph_id: str | None = None) -> dict[str, Any]:
    """Advance joins / cycles / gauntlets from completed child jobs.

    Serialised against other ticks. A tick that finds the lock held reports
    ``skipped`` rather than waiting: whoever holds it is already doing this
    round, and a second pass would re-dispatch it.
    """
    try:
        from .graph_engine import _reap

        _reap()  # finished Jev and check processes are collected even when no graph is running
    except Exception:
        pass
    with _graph_lock(session, blocking=False) as held:
        if not held:
            return {"advanced": [], "released": [], "skipped": "another tick is running"}
        return _tick_locked(session, graph_id=graph_id)


def _tick_locked(session: str, *, graph_id: str | None = None) -> dict[str, Any]:
    data = load(session)
    graphs = [g for g in (data.get("graphs") or []) if isinstance(g, dict)]
    if graph_id:
        graphs = [g for g in graphs if str(g.get("id")) == str(graph_id)]
    advanced: list[str] = []
    released: list[str] = []
    for graph in graphs:
        kind = str(graph.get("kind") or "")
        gid = str(graph.get("id") or "")
        if str(graph.get("status") or "") not in ("running", "waiting"):
            if kind == "graph":
                from . import graph_engine

                try:
                    if graph_engine.cleanup_seats(session, graph):
                        advanced.append(gid)
                except Exception:
                    pass
            continue
        if kind == "graph":
            # The graph runtime harvests while paused and holds only dispatches,
            # and one graph that raises must not stop the others from moving.
            from . import graph_engine

            try:
                if graph_engine.tick(session, graph, released):
                    advanced.append(gid)
                graph.pop("last_error", None)
            except Exception as e:
                graph["last_error"] = {"at": time.time(), "error": f"{type(e).__name__}: {e}"[:400]}
                advanced.append(gid)
            continue
        if graph.get("paused"):
            continue  # a person resumes it; see resume()
        owner = str(graph.get("owner") or "")
        changed = False

        # Join barrier
        for node in graph.get("nodes") or []:
            if not isinstance(node, dict) or str(node.get("kind") or "") != "join":
                continue
            if str(node.get("status") or "") != "waiting":
                continue
            wait_on = [str(x) for x in (node.get("wait_on") or []) if x]
            if not wait_on:
                continue
            done_jobs = [_job_done(session, jid) for jid in wait_on]
            if not all(done_jobs):
                continue
            node["status"] = "ready"
            node["released_at"] = time.time()
            released.append(gid)
            changed = True
            try:
                from .mailbox import post

                post(
                    session,
                    owner,
                    kind="join",
                    from_seat=str(node.get("id") or "join"),
                    job_id=wait_on[0],
                    summary=f"join ready for goal {graph.get('goal') or gid}",
                    extra={"graph_id": gid, "wait_on": wait_on},
                )
            except Exception:
                pass
            if kind in ("fan", "join", "gauntlet"):
                graph["status"] = "done"
                graph["finished_at"] = time.time()

        # Cycle: re-dispatch builder until max_rounds or done-as-success
        if kind == "cycle":
            builder = _node(graph, "builder")
            if builder and str(builder.get("status") or "") == "running":
                job = _job_done(session, str(builder.get("job_id") or ""))
                if job:
                    rnd = int(builder.get("round") or graph.get("round") or 1)
                    cap = int(builder.get("max_rounds") or graph.get("max_rounds") or 3)
                    verdict = _critic_verdict(job)
                    if verdict == "win" or rnd >= cap:
                        builder["status"] = "done"
                        graph["status"] = "done"
                        graph["finished_at"] = time.time()
                        graph["stop_reason"] = (
                            "max_rounds" if rnd >= cap and verdict != "win" else "done"
                        )
                        changed = True
                        _post_owner(session, graph, kind="goal", job_id=str(job.get("id") or ""),
                                    summary=f"cycle {graph.get('stop_reason')} after round {rnd}: {str(graph.get('goal') or '')[:80]}",
                                    stop_reason=graph.get("stop_reason"), round=rnd)
                    else:
                        nxt = rnd + 1
                        if _should_pause(graph):
                            _pause_graph(session, graph, reason=f"round {rnd} came back; waiting for you before round {nxt}/{cap}", next_round=nxt)
                            builder["status"] = "paused"
                        else:
                            _dispatch_builder_round(session, graph, builder, None, nxt, cap, rnd)
                        changed = True

        # Gauntlet: builder done → critic (bar+artifacts only); critic win/fail
        if kind == "gauntlet":
            builder = _node(graph, "builder")
            critic = _node(graph, "critic")
            if builder and critic:
                bjob = (
                    _job_done(session, str(builder.get("job_id") or ""))
                    if str(builder.get("status") or "") == "running"
                    else None
                )
                if bjob and str(critic.get("status") or "") == "pending":
                    arts = _artifacts_of(bjob)
                    bar = str(critic.get("bar") or graph.get("bar") or "")
                    # Critic must never receive the builder transcript/prompt.
                    ctask = _critic_task(
                        bar,
                        arts,
                        str(graph.get("goal") or ""),
                        int(builder.get("round") or 1),
                        examples=graph.get("examples"),
                    )
                    cseat, fixed = _repair_node_seat(
                        session, graph, critic, role="critic"
                    )
                    changed = changed or fixed
                    cjob = _create_work_job(
                        session,
                        owner=owner,
                        seat=cseat,
                        task=ctask,
                        role="critic",
                        graph_id=gid,
                        node_id="critic",
                        extra={
                            "bar": bar,
                            "artifacts": arts,
                            "round": builder.get("round") or 1,
                            "no_recap": True,
                            "no_identity": True,
                        },
                    )
                    critic["job_id"] = cjob["id"]
                    critic["status"] = "running"
                    critic["artifacts"] = arts
                    builder["status"] = "awaiting_critic"
                    changed = True
                if str(critic.get("status") or "") == "running":
                    cdone = _job_done(session, str(critic.get("job_id") or ""))
                    if cdone:
                        verdict = _critic_verdict(cdone)
                        rnd = int(builder.get("round") or graph.get("round") or 1)
                        cap = int(graph.get("max_rounds") or 3)
                        if not _critic_explicit(cdone):
                            graph.setdefault("refusals", []).append({
                                "node": "critic", "round": rnd, "job_id": cdone.get("id"),
                                "reason": "ambiguous_verdict",
                                "claim": str(((cdone.get("claim") or {}).get("summary") or ""))[:200],
                                "at": time.time(),
                            })
                            _post_owner(session, graph, kind="refusal", job_id=str(cdone.get("id") or ""),
                                        summary=f"critic round {rnd} gave no win/fail — counted as fail")
                        if verdict == "win" or rnd >= cap:
                            critic["status"] = "done"
                            graph["status"] = "done"
                            graph["finished_at"] = time.time()
                            graph["stop_reason"] = (
                                "max_rounds" if verdict != "win" else "win"
                            )
                            join = _node(graph, "join")
                            if join:
                                join["status"] = "ready"
                                join["released_at"] = time.time()
                                released.append(gid)
                            changed = True
                            _post_owner(session, graph, kind="goal", job_id=str(cdone.get("id") or ""),
                                        summary=f"gauntlet {graph.get('stop_reason')} after round {rnd}: {str(graph.get('goal') or '')[:80]}",
                                        stop_reason=graph.get("stop_reason"), round=rnd)
                        else:
                            nxt = rnd + 1
                            critic["status"] = "pending"
                            critic["job_id"] = None
                            if _should_pause(graph):
                                _pause_graph(session, graph, reason=f"critic failed round {rnd}; waiting for you before round {nxt}/{cap}", next_round=nxt)
                                builder["status"] = "paused"
                            else:
                                _dispatch_builder_round(session, graph, builder, critic, nxt, cap, rnd)
                            changed = True

        if changed:
            advanced.append(gid)

    if advanced or released:
        # write back the (possibly filtered) graphs into the full document
        full = load(session)
        by_id = {str(g.get("id")): g for g in graphs}
        merged = []
        for g in full.get("graphs") or []:
            gid = str(g.get("id") or "")
            merged.append(by_id.get(gid, g))
        full["graphs"] = merged
        save(session, full)
    # The graphs' news reaches their architects: queued by _post_owner, delivered when the architect is
    # idle and nobody is typing. After the save, so a delivery can never hold the graph document back.
    try:
        from .architect import pump

        pump(session, [g for g in graphs if str(g.get("kind") or "") == "graph"])
    except Exception:
        pass
    return {"advanced": advanced, "released": released}


def _should_pause(graph: dict[str, Any]) -> bool:
    """``pause_on == "round"``: every round comes back to a person."""
    return str((graph.get("boundaries") or {}).get("pause_on") or "win") == "round"


def _pause_graph(session: str, graph: dict[str, Any], *, reason: str, next_round: int) -> None:
    graph["paused"] = {"at": time.time(), "reason": reason, "next_round": int(next_round)}
    _post_owner(session, graph, kind="pause", summary=reason, next_round=int(next_round))


def _dispatch_builder_round(
    session: str,
    graph: dict[str, Any],
    builder: dict[str, Any],
    critic: dict[str, Any] | None,
    nxt: int,
    cap: int,
    prev_round: int,
) -> dict[str, Any]:
    """One more builder round — used by tick and by resume, so the two cannot
    drift. Repairs the seat if it went illegal, files the job, posts to the owner."""
    owner = str(graph.get("owner") or "")
    gid = str(graph.get("id") or "")
    bseat, _fixed = _repair_node_seat(session, graph, builder, role="builder")
    extra: dict[str, Any] = {"round": nxt}
    if critic is not None:
        extra["bar"] = graph.get("bar")
    new_job = _create_work_job(
        session,
        owner=owner,
        seat=bseat,
        task=_task_with_examples(str(graph.get("goal") or ""), graph.get("examples")),
        role="builder",
        graph_id=gid,
        node_id="builder",
        extra=extra,
    )
    builder["job_id"] = new_job["id"]
    builder["round"] = nxt
    builder["status"] = "running"
    if critic is not None:
        critic["status"] = "pending"
        critic["job_id"] = None
    graph["round"] = nxt
    _post_owner(session, graph, kind="round", job_id=new_job["id"],
                summary=f"round {prev_round} did not pass; builder starts round {nxt}/{cap}", round=nxt)
    return new_job


def resume(session: str, graph_id: str, *, outcome: str = "approved", node: str | None = None,
           note: str = "", extend: int = 0) -> dict[str, Any]:
    """Continue a paused loop: file the next round the pause was holding.

    For a custom graph, *outcome* answers an open gate — ``approved`` (default),
    ``rejected``, or any label the topology names — and *node* names the gate
    when more than one is open. With no gate open it lifts a pause."""
    gid = str(graph_id or "").strip()
    if not gid:
        raise WorkGraphError("--id is required")
    with _graph_lock(session):
        data = load(session)
        graph = next((g for g in (data.get("graphs") or []) if isinstance(g, dict) and str(g.get("id") or "") == gid), None)
        if not graph:
            raise WorkGraphError(f"no graph {gid}")
        if str(graph.get("kind") or "") == "graph":
            from . import graph_engine

            did = graph_engine.resume(session, graph, outcome=outcome, node_id=node, note=note, extend=int(extend or 0))
            save(session, data)
            graph["_did"] = did
            return graph
        paused = graph.get("paused")
        if not paused:
            raise WorkGraphError(f"{gid} is not paused")
        if str(graph.get("status") or "") not in ("running", "waiting"):
            raise WorkGraphError(f"{gid} is {graph.get('status')} — nothing to resume")
        graph["paused"] = None
        nxt = int((paused or {}).get("next_round") or int(graph.get("round") or 1) + 1)
        cap = int(graph.get("max_rounds") or 3)
        builder = _node(graph, "builder")
        critic = _node(graph, "critic") if str(graph.get("kind") or "") == "gauntlet" else None
        if builder is None:
            raise WorkGraphError(f"{gid} has no builder node to resume")
        if nxt > cap:
            graph["status"] = "done"
            graph["finished_at"] = time.time()
            graph["stop_reason"] = "max_rounds"
        else:
            _dispatch_builder_round(session, graph, builder, critic, nxt, cap, nxt - 1)
        graph["resumed_at"] = time.time()
        save(session, data)
        return graph


def retry(session: str, graph_id: str, node: str) -> dict[str, Any]:
    """Run one failed step of a custom graph again (a person's call)."""
    gid = str(graph_id or "").strip()
    with _graph_lock(session):
        data = load(session)
        graph = next((g for g in (data.get("graphs") or []) if isinstance(g, dict) and str(g.get("id") or "") == gid), None)
        if not graph:
            raise WorkGraphError(f"no graph {gid}")
        if str(graph.get("kind") or "") != "graph":
            raise WorkGraphError(f"{gid} is a {graph.get('kind')} loop; retry is for graphs")
        from . import graph_engine

        did = graph_engine.retry(session, graph, str(node or ""))
        save(session, data)
        graph["_did"] = did
        return graph


def pause(session: str, graph_id: str, *, reason: str = "paused by you") -> dict[str, Any]:
    """Hold a loop: nothing further is dispatched until resume. Jobs already
    filed keep running; the next round waits."""
    gid = str(graph_id or "").strip()
    if not gid:
        raise WorkGraphError("--id is required")
    with _graph_lock(session):
        data = load(session)
        graph = next((g for g in (data.get("graphs") or []) if isinstance(g, dict) and str(g.get("id") or "") == gid), None)
        if not graph:
            raise WorkGraphError(f"no graph {gid}")
        if str(graph.get("kind") or "") == "graph":
            from . import graph_engine

            if str(graph.get("status") or "") != "running":
                raise WorkGraphError(f"{gid} is {graph.get('status')} — nothing to pause")
            graph_engine.pause(graph, reason=reason)
            save(session, data)
            return graph
        if graph.get("paused"):
            return graph
        graph["paused"] = {"at": time.time(), "reason": reason, "next_round": int(graph.get("round") or 1) + 1}
        save(session, data)
        return graph


def cancel(session: str, graph_id: str) -> dict[str, Any]:
    """Tear down a work-graph loop. Does not touch flow_graph / workers[]."""
    gid = str(graph_id or "").strip()
    if not gid:
        raise WorkGraphError("--id is required")
    with _graph_lock(session):
        return _cancel_locked(session, gid)


def _cancel_locked(session: str, gid: str) -> dict[str, Any]:
    # Stop and Delete from the island run with no session bound, and set_status
    # refuses a write it cannot attribute: the graph read cancelled while every
    # job stayed open. Bind the team the way start() does.
    if session and not (os.environ.get("PONG_SESSION") or "").strip():
        os.environ["PONG_SESSION"] = session
    data = load(session)
    found: dict[str, Any] | None = None
    for g in data.get("graphs") or []:
        if isinstance(g, dict) and str(g.get("id") or "") == gid:
            found = g
            break
    if not found:
        raise WorkGraphError(f"no graph {gid}")
    found["status"] = "cancelled"
    found["finished_at"] = time.time()
    found["stop_reason"] = "cancelled"
    from .schema import TERMINAL_STATUSES

    for n in found.get("nodes") or []:
        if not isinstance(n, dict):
            continue
        if str(n.get("status") or "") not in ("done", "cancelled"):
            n["status"] = "cancelled"
        jid = str(n.get("job_id") or "")
        if not jid:
            continue
        try:
            from .jobs import load_job, set_status

            job = load_job(session, jid)
            if job and str(job.get("status") or "") not in TERMINAL_STATUSES:
                set_status(session, jid, "cancelled", skip_snapshot=True)
        except Exception:
            pass
    save(session, data)
    return found


def delete(session: str, graph_id: str) -> dict[str, Any]:
    """Forget a loop: remove it from ``work_graph.json`` entirely.

    ``cancel`` is the stop path — it marks the graph cancelled, cancels the
    open jobs, and leaves the row behind as history. This is the forget path,
    for a list someone wants shorter. The two are separate on purpose: history
    you can still read is the more conservative default, so deleting has to be
    asked for by name.

    Cancelling first is deliberate rather than tidy. A graph with live jobs
    whose row simply vanished would leave those jobs queued against seats
    nobody can now trace back to a goal — the record that explains them would
    be the thing that was deleted. So a still-running graph is torn down the
    normal way and only then dropped. Deleting an already-cancelled graph skips
    that and is a plain removal, which is what makes this safe to call twice.

    Only the named graph is touched; every other row is written back as it was.
    """
    gid = str(graph_id or "").strip()
    if not gid:
        raise WorkGraphError("--id is required")
    with _graph_lock(session):
        data = load(session)
        graphs = [g for g in (data.get("graphs") or []) if isinstance(g, dict)]
        found = next((g for g in graphs if str(g.get("id") or "") == gid), None)
        if not found:
            raise WorkGraphError(f"no graph {gid}")
        if str(found.get("status") or "") == "running":
            # Reuse the stop path rather than a second teardown: it is the one
            # that knows how to cancel the jobs, and it saves as it goes.
            found = _cancel_locked(session, gid)
            data = load(session)
            graphs = [g for g in (data.get("graphs") or []) if isinstance(g, dict)]
        removed = dict(found)
        data["graphs"] = [g for g in graphs if str(g.get("id") or "") != gid]
        save(session, data)
        removed["deleted"] = True
        return removed



# ---------------------------------------------------------------- graph ---
#
# A custom graph: nodes with roles, edges with conditions, cycles bounded by
# max_rounds, a human node as a gate. The five fixed kinds above are shapes
# this could express; they stay because their behaviour is tested and known.

from .graph_engine import EDGE_ON, NODE_ROLES  # noqa: E402  (the runtime lives there)


def lint_topology(topo: dict[str, Any]) -> dict[str, Any]:
    """Refuse a graph the runtime cannot run. Returns a normalised copy with
    ``warnings`` for shapes that will run but misbehave. See :mod:`pong.graph_engine`."""
    from .graph_engine import lint

    return lint(topo)


def _paused_view(p: Any) -> Any:
    """The pause record without the step's whole report (``prev``, kept for the engine: the gate's own
    summary already carries it)."""
    return {k: v for k, v in p.items() if k != "prev"} if isinstance(p, dict) else p


def _limit_until() -> float | None:
    """When the runner's pause for Claude's limits lifts (one small file read), or None."""
    try:
        from .limits import load_state

        st = load_state()
        return float(st["until"]) if st.get("state") in ("paused_5h", "paused_week") and st.get("until") else None
    except Exception:
        return None


def snapshot_block(session: str, *, full: bool = False, brief_finished: bool = False) -> dict[str, Any]:
    """Graphs for one team. ``full`` adds the long history and goal text the
    graph page reads (``pong graph list``); the team snapshot the map polls
    stays lean so it never grows past what a pipe carries in one read.
    ``brief_finished`` (the team snapshot) sends a finished graph as its id,
    title, status, stop reason and finish time only: the graph page reads
    finished graphs from ``pong graph list``."""
    from . import graph_engine as _engine

    data = load(session)
    graphs = []
    unread = object()
    limit_until: Any = unread  # read once, and only when a graph is held for Claude's limits
    for g in data.get("graphs") or []:
        if not isinstance(g, dict):
            continue
        if brief_finished and str(g.get("status") or "") not in ("running", "waiting"):
            graphs.append({"id": g.get("id"), "title": _engine.graph_title(g), "status": g.get("status"),
                           "stop_reason": g.get("stop_reason"), "finished_at": g.get("finished_at")})
            continue
        is_graph = g.get("kind") == "graph"
        places, total = _engine.step_places(g) if is_graph else ({}, None)
        paused = g.get("paused") if isinstance(g.get("paused"), dict) else {}
        lu = None
        if is_graph and paused.get("manual") and _engine._limit_pause(str(paused.get("reason") or "")):
            if limit_until is unread:
                limit_until = _limit_until()
            lu = limit_until
        graphs.append(
            {
                "id": g.get("id"),
                "session": session,
                "owner": g.get("owner"),
                "participants": list(g.get("participants") or []),
                "kind": g.get("kind"),
                "status": g.get("status"),
                "goal": (str(g.get("goal") or "")[:80]),
                "round": g.get("round"),
                "max_rounds": g.get("max_rounds"),
                "stop_reason": g.get("stop_reason"),
                "created_at": g.get("created_at"),
                "finished_at": g.get("finished_at"),
                "boundaries": g.get("boundaries") or {},
                "paused": _paused_view(g.get("paused")),
                "builder_role": g.get("builder_role"),
                "edges": [e for e in (g.get("edges") or []) if isinstance(e, dict)],
                "history": len(g.get("history") or []),
                "topology": g.get("topology"),
                "refusals": len(g.get("refusals") or []),
                "wiring": {
                    str(k): {
                        "seat": v.get("seat"), "role": v.get("role"), "runtime": v.get("runtime"),
                        "model": v.get("model"), "why": v.get("why"), "rule": v.get("rule"),
                        "rejected": v.get("rejected") or {}, "persist": v.get("persist"),
                    }
                    for k, v in (g.get("wiring") or {}).items() if isinstance(v, dict)
                },
                "nodes": [
                    {
                        "id": n.get("id"),
                        "kind": n.get("kind"),
                        "role": n.get("role"),
                        "seat": n.get("seat"),
                        "status": n.get("status"),
                        "job_id": n.get("job_id"),
                        "round": n.get("round"),
                        **(_engine.snapshot_node(g, n, places) if is_graph else {}),
                    }
                    for n in (g.get("nodes") or [])
                    if isinstance(n, dict)
                ],
                **(_engine.snapshot_fields(g, full=full, places=places, total=total, limit_until=lu) if is_graph else {}),
                "last_error": g.get("last_error"),
            }
        )
    return {"version": GRAPH_VERSION, "graphs": graphs}
