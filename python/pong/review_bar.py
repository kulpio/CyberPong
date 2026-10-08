"""Review bars — the published standard a builder aims at and a reviewer scores against.

A bar is fixed dimensions for one *kind* of work, a numeric scale, and a small
set of already-scored reference outputs kept in the repo. The references are what
hold the bar steady over time: without them a 5 means the reviewer was in a good
mood.

Two rules shape everything here:

* **The builder sees the bar before it starts.** The criteria travel out in the
  job's acceptance block, so a first draft aims at the published standard and a
  verdict becomes something the builder can argue with on the evidence.
* **Scope is configured, not chosen.** A reviewer covers a named set of seats.
  A team can carry more than one bar-setter — one for code, one for research —
  and neither decides for itself what it watches.

Lookup order (first hit wins per bar id), so a team can override the shipped
default without editing the package::

    <project_root>/.pong/review/bars/*.json     team-specific
    ~/.pong/review/bars/*.json                  this machine
    <package>/review/bars/*.json                shipped default
"""

from __future__ import annotations

import json
import os
from pathlib import Path
from typing import Any

_PKG_ROOT = Path(__file__).resolve().parent


def _candidate_roots(project_root: str | None) -> list[Path]:
    roots: list[Path] = []
    pr = (project_root or "").strip()
    if pr:
        roots.append(Path(pr).expanduser() / ".pong" / "review")
    roots.append(Path(os.path.expanduser("~/.pong/review")))
    roots.append(_PKG_ROOT / "review")
    return roots


def load_bars(project_root: str | None = None) -> dict[str, dict[str, Any]]:
    """Every bar visible to this team, keyed by id. Nearest definition wins."""
    out: dict[str, dict[str, Any]] = {}
    for root in _candidate_roots(project_root):
        bars_dir = root / "bars"
        if not bars_dir.is_dir():
            continue
        for path in sorted(bars_dir.glob("*.json")):
            try:
                bar = json.loads(path.read_text(encoding="utf-8"))
            except Exception:
                continue
            bid = str(bar.get("id") or path.stem).strip()
            if not bid or bid in out:
                continue  # nearer root already defined it
            bar["_dir"] = str(root)
            out[bid] = bar
    return out


def _seat_role(state: dict[str, Any], seat_id: str) -> str:
    from .role_identity import seat_mission_role

    try:
        return seat_mission_role(state, seat_id)
    except Exception:
        return ""


def _on_roster(state: dict[str, Any], seat_id: str) -> bool:
    from .state import workers_from_state

    return any(str(w.get("id") or "") == seat_id for w in workers_from_state(state))


def _covers_seat(state: dict[str, Any], bar: dict[str, Any], seat_id: str) -> bool:
    scope = bar.get("scope") or {}
    seats = [str(s) for s in (scope.get("seats") or [])]
    if seats:
        return seat_id in seats
    roles = [str(r) for r in (scope.get("mission_roles") or [])]
    if not roles:
        return False
    # Role matching only applies to seats that are actually on the roster.
    # seat_mission_role falls back to "coder" for anything it does not
    # recognise, which is right for its own callers but here meant a seat id
    # that does not exist — a typo, a torn-down seat — silently matched the code
    # bar and got handed a standard with no reviewer behind it.
    if not _on_roster(state, seat_id):
        return False
    return _seat_role(state, seat_id) in roles


def bar_for_seat(
    state: dict[str, Any], seat_id: str, project_root: str | None = None
) -> dict[str, Any] | None:
    """The bar a given builder seat is measured against, if any."""
    sid = str(seat_id or "").strip()
    if not sid:
        return None
    pr = project_root if project_root is not None else str(state.get("project_root") or "")
    bars = list(load_bars(pr).values())
    # A bar that names this seat outright beats one that merely matched its
    # mission role. Design seats are coders too, so without this precedence the
    # code bar would claim them and whichever bar happened to load first would
    # decide the standard a lane is held to.
    named = [b for b in bars if sid in [str(s) for s in ((b.get("scope") or {}).get("seats") or [])]]
    if named:
        return named[0]
    for bar in bars:
        if _covers_seat(state, bar, sid):
            return bar
    return None


def reviewers_for_seat(
    state: dict[str, Any], seat_id: str, project_root: str | None = None
) -> list[str]:
    """Which seats hold quality authority over this seat.

    Explicit ``scope.reviewer_seats`` wins. Otherwise every seat whose mission
    role is named in ``scope.reviewer_roles`` — which is what makes the shipped
    default portable to a team whose reviewer is not w17.
    """
    bar = bar_for_seat(state, seat_id, project_root)
    if not bar:
        return []
    scope = bar.get("scope") or {}
    explicit = [str(s) for s in (scope.get("reviewer_seats") or []) if str(s).strip()]
    if explicit:
        return explicit
    roles = {str(r) for r in (scope.get("reviewer_roles") or [])}
    if not roles:
        return []
    from .state import workers_from_state

    workers = list(workers_from_state(state))
    parent_of = {str(w.get("id") or ""): str(w.get("parent_id") or "") for w in workers}
    seat_parent = parent_of.get(seat_id, "")

    # Role alone is too broad: on a team with several lanes it would make every
    # reviewer binding on every coder, so Ops' watchdog would hold authority over
    # Engineering's code. A bar-setter covers its own lane — the lead it reports
    # to, and that lead's other reports. On a flat team both parents are empty,
    # which still matches, so a single-reviewer team works unchanged.
    out: list[str] = []
    for w in workers:
        wid = str(w.get("id") or "")
        if not wid or wid == seat_id or _seat_role(state, wid) not in roles:
            continue
        rparent = parent_of.get(wid, "")
        if rparent == seat_id or rparent == seat_parent:
            out.append(wid)
    return out


def seats_covered_by(
    state: dict[str, Any], reviewer_id: str, project_root: str | None = None
) -> list[str]:
    """The seats a reviewer is configured to watch. It does not pick these."""
    from .state import workers_from_state

    rid = str(reviewer_id or "").strip()
    out: list[str] = []
    for w in workers_from_state(state):
        wid = str(w.get("id") or "")
        if not wid or wid == rid:
            continue
        if rid in reviewers_for_seat(state, wid, project_root):
            out.append(wid)
    return out


def bar_for_reviewer(
    state: dict[str, Any], reviewer_id: str, project_root: str | None = None
) -> dict[str, Any] | None:
    """The bar a reviewer *applies*, as opposed to the one it is measured by.

    A reviewer is not itself a coder, so it never matches a code bar's scope —
    without this the bar-setter would be the one seat on the team that never got
    to read the standard it is supposed to hold.
    """
    for seat in seats_covered_by(state, reviewer_id, project_root):
        bar = bar_for_seat(state, seat, project_root)
        if bar:
            return bar
    return None


def listens_to(
    state: dict[str, Any], seat_id: str, project_root: str | None = None
) -> list[str]:
    """Who this seat must treat as binding, beyond the orchestrator.

    An explicit ``listens_to`` on the seat record is honoured as-is; reviewers
    covering the seat are added on top. c1 is deliberately absent — the
    orchestrator is binding for *assignment* everywhere and does not need to be
    listed here.
    """
    from .state import workers_from_state

    sid = str(seat_id or "").strip()
    out: list[str] = []
    for w in workers_from_state(state):
        if str(w.get("id")) == sid:
            for r in w.get("listens_to") or []:
                if str(r).strip():
                    out.append(str(r).strip())
            break
    for r in reviewers_for_seat(state, sid, project_root):
        if r not in out:
            out.append(r)
    return out


def reference_paths(bar: dict[str, Any]) -> list[tuple[str, Any, str]]:
    """(absolute path, score, why) for each scored reference in a bar."""
    root = Path(str(bar.get("_dir") or (_PKG_ROOT / "review")))
    out: list[tuple[str, Any, str]] = []
    for ref in bar.get("references") or []:
        name = str(ref.get("file") or "").strip()
        if not name:
            continue
        out.append((str(root / "references" / name), ref.get("score"), str(ref.get("why") or "")))
    return out


def format_criteria_block(bar: dict[str, Any], *, for_reviewer: bool = False) -> str:
    """The published standard, as it travels in a job.

    Same text for builder and reviewer by design — a bar nobody can read before
    starting is just a surprise at grading time.
    """
    if not bar:
        return ""
    scale = bar.get("scale") or {}
    lo, hi = scale.get("min", 1), scale.get("max", 5)
    passing = bar.get("pass") or {}
    lines: list[str] = []
    title = str(bar.get("title") or bar.get("id") or "work")
    lines.append(f"## REVIEW BAR — {title} (v{bar.get('version', 1)})")
    if bar.get("summary"):
        lines.append(str(bar["summary"]))
    lines.append("")
    lines.append(
        f"Scored {lo}–{hi} on each dimension below. "
        f"Pass needs **every dimension ≥ {passing.get('min_each', 3)}** "
        f"and a **mean ≥ {passing.get('min_mean', 4)}**. "
        f"{passing.get('note', '')}".strip()
    )
    lines.append("")
    for d in bar.get("dimensions") or []:
        lines.append(f"**{d.get('name')}** (`{d.get('id')}`)")
        lines.append(f"- {hi} looks like: {d.get('five')}")
        lines.append(f"- {lo} looks like: {d.get('one')}")
    labels = scale.get("labels") or {}
    if labels:
        lines.append("")
        lines.append("Scale: " + " · ".join(f"{k} = {v}" for k, v in sorted(labels.items())))
    refs = reference_paths(bar)
    if refs:
        lines.append("")
        lines.append("Already-scored reference outputs — read these before arguing a score:")
        for path, score, why in refs:
            lines.append(f"- `{path}` — scored {score}. {why}")
    lines.append("")
    if for_reviewer:
        lines.append(
            "Score every dimension, cite the reference you anchored against, and say "
            "what specific change would clear the bar. You do not make the change."
        )
    else:
        lines.append(
            "You are measured on this. Aim the first draft at it, and if you "
            "disagree with a score, argue it on the evidence."
        )
    return "\n".join(lines)
