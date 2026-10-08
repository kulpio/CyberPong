"""Wiring — who runs each node of a loop, and why (and why not).

:mod:`pong.models` answers one question for one seat: which runtime and model,
by rule. This module asks it for every node of a loop and adds the two things
a person looking at the map needs on top:

* **Boundaries.** A goal can say it is client-facing, what agency it runs at,
  and what policy its nodes carry. A platform that a boundary forbids is
  removed *before* the rules run, and the removal is recorded.
* **Why not.** For every platform that was not picked, one sentence: not
  installed, no tools, forbidden by a boundary, pool below floor, or simply
  weaker at this kind of work than the one chosen. ``rejected`` is what the
  island and the map show on hover.

The strengths matrix and the per-runtime boundaries live in
``models/catalog.json`` (``runtimes.<id>.strengths`` / ``.boundaries``). The
shared-pool allowance lives in ``~/.pong/pools.json``, one number per pool,
because nothing on this machine can read it from the vendor yet.
"""

from __future__ import annotations

import json
import time
from pathlib import Path
from typing import Any

from . import models as M
from .paths import sessions_dir, state_dir

DEFAULT_POOL_FLOOR = 0.25

#: Which strength a role draws on. Roles are normalised through models first,
#: so "reviewer" and "critic" both land on ``judge``.
STRENGTH_KEY = {
    "builder": "build", "coder": "build", "migrator": "build",
    "critic": "judge", "reviewer": "judge", "orchestrator": "judge",
    "scout": "scout", "researcher": "scout",
    "writer": "write",
    "router": "classify", "join": "classify", "task_runner": "classify", "operator": "classify",
}

#: Roles whose output a person outside the team reads.
CLIENT_FACING_ROLES = frozenset({"writer", "critic", "reviewer", "orchestrator"})


# ------------------------------------------------------------------ pools ---


def pools_path(session: str | None = None) -> Path:
    if session:
        return sessions_dir(session) / "pools.json"
    return state_dir() / "pools.json"


def _read(path: Path) -> dict[str, Any]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}
    return data if isinstance(data, dict) else {}


def read_pools(session: str | None = None) -> dict[str, dict[str, Any]]:
    """Per-pool ``{"weekly_remaining": 0..1, "floor": 0..1}``; session overrides machine."""
    out: dict[str, dict[str, Any]] = {}
    for path in (pools_path(None), pools_path(session) if session else None):
        if path is None:
            continue
        for pid, row in _read(path).items():
            if pid in ("updated", "updated_at") or not isinstance(row, dict):
                continue
            cur = dict(out.get(pid) or {})
            cur.update(row)
            out[pid] = cur
    return out


def set_pool(pool: str, remaining: float, *, floor: float | None = None, session: str | None = None) -> dict[str, Any]:
    path = pools_path(session)
    data = _read(path)
    row = dict(data.get(pool) or {})
    row["weekly_remaining"] = max(0.0, min(1.0, float(remaining)))
    if floor is not None:
        row["floor"] = max(0.0, min(1.0, float(floor)))
    row.setdefault("floor", DEFAULT_POOL_FLOOR)
    row["updated_at"] = time.time()
    data[pool] = row
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
    return row


def pool_remaining(pool: str, session: str | None = None) -> tuple[float, float]:
    row = read_pools(session).get(pool) or {}
    try:
        rem = float(row.get("weekly_remaining", 1.0))
    except (TypeError, ValueError):
        rem = 1.0
    try:
        floor = float(row.get("floor", DEFAULT_POOL_FLOOR))
    except (TypeError, ValueError):
        floor = DEFAULT_POOL_FLOOR
    return rem, floor


# ------------------------------------------------------------- boundaries ---


def normalize_boundaries(raw: Any) -> dict[str, Any]:
    b = dict(raw) if isinstance(raw, dict) else {}
    out = {
        "client_facing": bool(b.get("client_facing")),
        "agency": str(b.get("agency") or "gated"),
        "effects": [str(e) for e in (b.get("effects") or ["read", "write:repo"])],
        "policy": dict(b.get("policy") or {}),
        "pause_on": str(b.get("pause_on") or "win"),
        "efficiency": str(b.get("efficiency") or "balanced"),
        "allowed": [str(x).lower() for x in (b.get("allowed") or []) if str(x).strip()],
    }
    if out["agency"] not in ("report_only", "gated", "unattended"):
        out["agency"] = "gated"
    if out["pause_on"] not in ("round", "win", "done"):
        out["pause_on"] = "win"
    if out["efficiency"] not in ("thorough", "balanced", "fast"):
        out["efficiency"] = "balanced"
    # a graph's limits (pong graph attach --max-wall/--max-jobs/--node-timeout) survive normalising
    for k in ("max_wall_min", "max_jobs", "node_timeout_min"):
        try:
            v = float(b.get(k)) if b.get(k) is not None else 0.0
        except (TypeError, ValueError):
            v = 0.0
        if v > 0:
            out[k] = int(v) if k == "max_jobs" else v
    return out


def _strengths(cat: dict[str, Any], rid: str) -> dict[str, int]:
    row = (cat.get("runtimes") or {}).get(rid) or {}
    st = row.get("strengths") or {}
    return {k: int(v) for k, v in st.items() if isinstance(v, (int, float))}


def hard_reject(
    rid: str,
    row: dict[str, Any],
    *,
    role: str,
    demands: list[str],
    boundaries: dict[str, Any],
    have: set[str],
    in_cycle: bool,
    cat: dict[str, Any],
    session: str | None,
    switched_off: set[str] | None = None,
) -> str | None:
    """One sentence, or None when this runtime may take the node."""
    if switched_off and rid in switched_off:
        return "switched off in Settings"
    if have and rid not in have:
        return "not installed on this Mac"
    allowed = boundaries.get("allowed") or []
    if allowed and rid not in allowed:
        return "not among the platforms you allowed"
    bd = {str(x) for x in (row.get("boundaries") or [])}
    tools = bool(row.get("tools"))
    if "tools" in demands and not tools:
        return "needs tools; this runtime has no tools"
    if role in ("critic", "reviewer") and "tools" in demands and not tools:
        return "critic must re-run the evidence; no tools"
    if boundaries.get("client_facing") and role in CLIENT_FACING_ROLES and "no_client_facing_prose" in bd:
        return "client-facing output; the boundary forbids it"
    pool = str(row.get("pool") or "")
    pool_row = (cat.get("pools") or {}).get(pool) or {}
    if pool_row.get("shared"):
        rem, floor = pool_remaining(pool, session)
        heavy = bool({"deep", "long"} & set(demands)) or in_cycle
        if rem < floor and heavy:
            return f"shared {pool} pool at {int(rem * 100)}% of the week, below its {int(floor * 100)}% floor; heavy or repeated work moves off it"
    if boundaries.get("agency") == "unattended" and role in ("builder", "coder", "critic", "reviewer") and not tools:
        return "unattended runs need executed verification; no tools"
    return None


# ---------------------------------------------------------------- nodes ---


def plan_node(
    role: str,
    task: str,
    *,
    session: str | None = None,
    boundaries: Any = None,
    pin: str | None = None,
    prefer_runtime: str | None = None,
    prefer_model: str | None = None,
    in_cycle: bool = False,
    available: Any = None,
    pin_why: str | None = None,
) -> dict[str, Any]:
    """Routing for one node: the pick, its reason, and why every other platform was not picked.
    *pin_why* says where a pin came from when it was not a person's (a family pick)."""
    role_n = M.normalize_role(role)
    bnd = normalize_boundaries(boundaries)
    cat = M.load_catalog(session)
    rts = {k: v for k, v in (cat.get("runtimes") or {}).items() if isinstance(v, dict)}
    have = {str(a).lower() for a in available} if available is not None else M.available_runtimes(session)
    demands = M.demands_for(task, session)
    key = STRENGTH_KEY.get(role_n, "build")

    if role_n == "human":
        return {"runtime": None, "model": None, "role": role_n, "demands": demands, "rule": "gate",
                "why": "A person presses the button, not a schedule.", "rejected": {}, "conflict": None,
                "strength_key": key, "seat": "you"}

    rejected: dict[str, str] = {}
    allowed: set[str] = set()
    try:  # an AI the person switched off is never picked, even when nothing else is installed
        from .settings import disabled_runtimes

        off = disabled_runtimes()
    except Exception:
        off = set()
    for rid, row in rts.items():
        r = hard_reject(rid, row, role=role_n, demands=demands, boundaries=bnd, have=have,
                        in_cycle=in_cycle, cat=cat, session=session, switched_off=off)
        if r:
            rejected[rid] = r
        else:
            allowed.add(rid)

    if not allowed:
        return {"runtime": None, "model": None, "role": role_n, "demands": demands, "rule": "none",
                "why": "No installed platform satisfies this node's boundaries.", "rejected": rejected,
                "conflict": "unwired", "strength_key": key}

    conflict: str | None = None
    rule_prefix = ""
    why_prefix = ""
    want = str(pin or "").lower() or None
    if want and want in rejected:
        conflict = rejected[want]
        why_prefix = f"Pin {want} refused: {conflict}. "
        rule_prefix = "pin-refused"
        want = None
    elif want:
        rule_prefix = "pin"
        why_prefix = pin_why or "Pinned by you. "

    plan = M.plan(
        task, role_n, session=session, available=sorted(allowed),
        prefer_runtime=want or (prefer_runtime if prefer_runtime in allowed else None),
        prefer_model=prefer_model,
    )
    picked = plan.runtime
    if picked not in allowed:
        # The rules named something a boundary removed and fell through; take
        # the strongest allowed platform for this kind of work instead.
        best = sorted(allowed, key=lambda r: -_strengths(cat, r).get(key, 0))[0]
        plan = M.plan(task, role_n, session=session, available=[best], prefer_runtime=best, prefer_model=prefer_model)
        picked = plan.runtime
        why_prefix += f"{plan.label} takes it as the strongest allowed {key} platform. "
    s0 = _strengths(cat, picked).get(key, 0)
    for rid in sorted(allowed):
        if rid == picked:
            continue
        s = _strengths(cat, rid).get(key, 0)
        label = str((rts.get(rid) or {}).get("label") or rid)
        if s < s0:
            rejected[rid] = f"{key} {s}/5 vs {s0}/5"
        else:
            rejected[rid] = f"{key} {s}/5, but rule '{plan.rule}' applies first"
        _ = label
    out = plan.as_dict()
    # Fast mode: a cheaper tier for the work, never for the judge. The critic
    # grading on a weaker model than the build is how a bar quietly drops.
    if bnd.get("efficiency") == "fast" and role_n not in ("critic", "reviewer", "orchestrator") \
            and picked == "claude" and out.get("model") in ("opus", "fable"):
        out["model"] = "sonnet"
        out["flags"] = M.model_args("claude", "sonnet", session)
        out["launch_cmd"] = " ".join([out.get("cmd") or "claude"] + out["flags"])
        why_prefix += "Fast mode: Sonnet does the work; the critic still grades on Opus. "
        rule_prefix = (rule_prefix + "+" if rule_prefix else "") + "fast"
    out.update({
        "role": role_n,
        "rule": (rule_prefix + ("+" if rule_prefix else "") + plan.rule) if rule_prefix else plan.rule,
        "why": (why_prefix + plan.why).strip(),
        "rejected": rejected,
        "conflict": conflict,
        "strength_key": key,
        "in_cycle": bool(in_cycle),
    })
    return out


def _cycle_ids(kind: str, spec: dict[str, Any]) -> set[str]:
    ids: set[str] = set()
    for e in spec.get("edges") or []:
        if not isinstance(e, dict):
            continue
        on = str(e.get("on") or "")
        if on in ("cycle", "fail"):
            ids.add(str(e.get("from") or ""))
            ids.add(str(e.get("to") or ""))
    ids.discard("")
    ids.discard("join")
    return ids


def plan_loop(
    kind: str,
    task: str,
    *,
    session: str | None = None,
    owner: str | None = None,
    boundaries: Any = None,
    pins: dict[str, str] | None = None,
    available: Any = None,
    roles: dict[str, str] | None = None,
) -> dict[str, Any]:
    """Every node of a loop kind, routed from the same catalog the spawner reads.

    ``roles`` overrides a node's solver role by id (a graph whose builder is a
    writer or a scout), so the preview and the start route the same way."""
    from .loops import load_loop

    spec = load_loop(kind, session)
    cycle = _cycle_ids(kind, spec)
    bnd = normalize_boundaries(boundaries)
    nodes: dict[str, Any] = {}
    for node in spec.get("nodes") or []:
        if not isinstance(node, dict):
            continue
        nid = str(node.get("id") or "")
        role = str((roles or {}).get(nid) or node.get("role") or node.get("kind") or "")
        nodes[nid] = plan_node(
            role, task, session=session, boundaries=bnd, pin=(pins or {}).get(nid),
            in_cycle=nid in cycle, available=available,
        )
    pools: dict[str, int] = {}
    for row in nodes.values():
        p = str(row.get("pool") or "")
        if p:
            pools[p] = pools.get(p) + 1 if p in pools else 1
    warnings = [f"{nid}: {row['conflict']}" for nid, row in nodes.items() if row.get("conflict")]
    pool_state = {pid: {"weekly_remaining": pool_remaining(pid, session)[0], "floor": pool_remaining(pid, session)[1], "nodes": n}
                  for pid, n in pools.items()}
    return {
        "kind": str(kind),
        "owner": owner,
        "task": str(task or "")[:200],
        "boundaries": bnd,
        "pins": dict(pins or {}),
        "computed_at": time.time(),
        "nodes": nodes,
        "pools": pool_state,
        "warnings": warnings,
    }


def format_plan(plan: dict[str, Any]) -> list[str]:
    lines: list[str] = []
    for nid, row in (plan.get("nodes") or {}).items():
        who = f"{row.get('runtime') or '—'} {row.get('model') or ''}".strip()
        lines.append(f"{nid:9} {str(row.get('role') or ''):9} {who:18} {row.get('why') or ''}")
        for rid, r in (row.get("rejected") or {}).items():
            lines.append(f"{'':9} {'':9} {'not ' + rid:18} {r}")
    for w in plan.get("warnings") or []:
        lines.append(f"warning: {w}")
    return lines
