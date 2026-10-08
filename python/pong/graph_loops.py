"""A DAG of loops: the cycles of a topology, found and given budgets of their own.

Every directed graph condenses to a DAG of its strongly connected components;
CyberPong's topologies are already DAGs of loops, each with one clear place
where a round starts. This module finds those loops at lint time — no syntax
is needed — and the engine counts rounds per loop instead of visits per node
for the whole life of a graph (docs/research/dag-of-loops-design-2026-09.md).

Two kinds of loop:

* an **agent loop**: a cycle among the agent and engine steps (a builder ⇄
  tests ⇄ critic). Found on the graph with every edge that leaves a person's
  gate removed. Its **header** is the one node work enters it by; its
  **latches** are the edges that go back to the header. A loop with two ways
  in is **loose**: lint warns and its nodes keep today's per-node caps.
* a **person loop**: a gate whose answer (a rejection, say) sends the work
  back into a cycle that returns to the gate. Its id is the gate's id.

Every cycle must be counted: with every latch removed the graph is acyclic.
A node on a cycle that no latch cuts is **uncounted** and keeps its per-node
lifetime cap, as a loose cycle's nodes do.

A round is counted when work crosses a latch; work entering a loop from
outside opens a fresh activation (a person's reject therefore starts a new
inner loop, rather than inheriting its spent budget). At a loop's cap the
engine takes the loop's own way out — the sender's ``bounded`` edge, any
member's ``bounded`` edge out of the loop, the gate around it — and never
stops the whole graph for it.
"""

from __future__ import annotations

from typing import Any

#: Roles whose steps are not jobs on a seat (for the worst-case job count).
JOBLESS = frozenset({"human", "join", "end", "jev"})
#: A gate's answers that carry work forward (as opposed to sending it back).
FORWARD = frozenset({"approved", "done", "*"})
IN_FLIGHT = frozenset({"running", "held"})
MAX_ITERS = 24


def base(nid: str) -> str:
    """A copy (``gen#2``) counts as its node (``gen``)."""
    return str(nid).split("#", 1)[0]


def _scc(ids: list[str], edges: list[dict[str, Any]]) -> list[list[str]]:
    from .graph_engine import _scc as scc

    return scc(ids, edges)


def _nontrivial(comps: list[list[str]], edges: list[dict[str, Any]]) -> list[set[str]]:
    return [set(c) for c in comps
            if len(c) > 1 or any(e["from"] == c[0] == e["to"] for e in edges)]


def _pos(v: Any) -> int:
    try:
        n = int(float(v))
    except (TypeError, ValueError):
        return 0
    return n if n > 0 else 0


def _reaches(a: str, b: str, edges: list[dict[str, Any]], cut: set[tuple[str, str]] | None = None) -> bool:
    cut = cut or set()
    seen: set[str] = set()
    stack = [a]
    while stack:
        x = stack.pop()
        if x == b:
            return True
        if x in seen:
            continue
        seen.add(x)
        stack.extend(e["to"] for e in edges if e["from"] == x and (e["from"], e["to"]) not in cut)
    return False


def check_overrides(overrides: Any) -> list[str]:
    """Problems with a topology's ``loops`` map (lint refuses them)."""
    if overrides is None:
        return []
    if not isinstance(overrides, dict):
        return ["loops must be a map of loop id → {\"max_iters\": n}"]
    out: list[str] = []
    for k, v in overrides.items():
        if not isinstance(v, dict):
            out.append(f"loops.{k} must be an object like {{\"max_iters\": 4}}")
            continue
        unknown = sorted(set(v) - {"max_iters"})
        if unknown:
            out.append(f"loops.{k}: unknown setting(s) {', '.join(unknown)} (stage 1 knows max_iters)")
        if "max_iters" in v and not 1 <= _pos(v.get("max_iters")) <= MAX_ITERS:
            out.append(f"loops.{k}.max_iters must be a whole number 1..{MAX_ITERS}, not {v.get('max_iters')!r}")
    return out


def derive(nodes: list[dict[str, Any]], edges: list[dict[str, Any]], starts: list[str], max_rounds: int,
           overrides: dict[str, Any] | None = None) -> tuple[list[dict[str, Any]], list[str], list[str]]:
    """(loops, warnings, uncounted node ids) for a linted topology (copies already expanded)."""
    overrides = overrides if isinstance(overrides, dict) else {}
    by_id = {n["id"]: n for n in nodes}
    ids = list(by_id)
    human = {i for i, n in by_id.items() if n.get("role") == "human"}
    start = set(starts or [])
    full = _nontrivial(_scc(ids, edges), edges)
    warnings: list[str] = []
    agent_edges = [e for e in edges if e["from"] not in human]

    # --- person loops: a gate's answer that sends the work round again ---------
    persons: list[dict[str, Any]] = []
    latched: set[tuple[str, str]] = set()
    passes = [agent_edges,  # 1: back to the gate through agent steps only
              [e for e in edges if e["from"] not in human or str(e.get("on") or "done") in FORWARD
               or str(e.get("on") or "").startswith("route:")]]  # 2: also through another gate's forward answer
    for edges_ok in passes:
        for F in full:
            for g in sorted(F & human):
                not_g = [x for x in edges_ok if x["from"] != g]
                back = sorted({(e["from"], e["to"]) for e in edges
                               if e["from"] == g and e["to"] in F and (g, e["to"]) not in latched
                               and _reaches(e["to"], g, not_g, latched)})
                if not back:
                    continue
                latched.update(back)
                P = next((p for p in persons if p["id"] == g), None)
                if P is None:
                    P = {"id": g, "kind": "person", "header": [], "members": [], "latches": [], "parent": None,
                         "depth": 0, "reentry": [],
                         "max_iters": _pos((overrides.get(g) or {}).get("max_iters")) or int(max_rounds)}
                    persons.append(P)
                P["latches"] = [list(x) for x in sorted({tuple(x) for x in P["latches"]} | set(back))]
                P["header"] = sorted({t for _g, t in P["latches"]})
                # the nodes on this gate's cycles: reachable from a way back, and back to the gate
                body = {g}
                for t in P["header"]:
                    for x in F:
                        if _reaches(t, x, edges_ok) and _reaches(x, g, not_g):
                            body.add(x)
                P["members"] = sorted(set(P["members"]) | body)

    # --- agent loops: cycles among agent steps, nested by header --------------
    agents: list[dict[str, Any]] = []
    loose: set[str] = set()

    def reenters(src: str, A: set[str]) -> bool:
        """An edge into A from a gate whose own loop goes round A is a person's re-entry, not a way in."""
        return any(P["id"] == src and A <= set(P["members"]) for P in persons)

    def agent(scope_edges: list[dict[str, Any]], scope: set[str], depth: int) -> None:
        scope_edges = [e for e in scope_edges if e["from"] in scope and e["to"] in scope]
        for A in _nontrivial(_scc(sorted(scope), scope_edges), scope_edges):
            outside = [e for e in edges if e["to"] in A and e["from"] not in A]
            entries = {e["to"] for e in outside if not reenters(e["from"], A)} | (A & start)
            if not entries:  # entered only by a gate of its own cycle group: that answer is its way in
                entries = {e["to"] for e in outside}
            heads = {base(x) for x in entries}
            if len(heads) != 1:
                loose.update(A)
                warnings.append(f"cycle {' ⇄ '.join(sorted({base(x) for x in A}))} has "
                                + ("no single way in" if heads else "no way in")
                                + f" ({', '.join(sorted(heads)) or 'none'}): a loose cycle keeps per-node caps")
                continue
            h = heads.pop()
            lat = sorted({(e["from"], e["to"]) for e in scope_edges if e["from"] in A and base(e["to"]) == h})
            reentry = sorted({e["to"] for e in outside if reenters(e["from"], A) and base(e["to"]) != h})
            mv = next((by_id[i].get("max_visits") for i in sorted(A) if base(i) == h and by_id[i].get("max_visits")), None)
            agents.append({"id": h, "kind": "agent", "header": [h], "members": sorted(A),
                           "latches": [list(x) for x in lat], "parent": None, "depth": depth, "reentry": reentry,
                           "max_iters": _pos((overrides.get(h) or {}).get("max_iters")) or _pos(mv) or int(max_rounds)})
            agent([e for e in scope_edges if (e["from"], e["to"]) not in set(lat)], A, depth + 1)

    agent(agent_edges, set(ids), 1)
    loops: list[dict[str, Any]] = []
    for L in persons + agents:
        if any(M["id"] == L["id"] for M in loops):
            warnings.append(f"two loops are named {L['id']}; the second is ignored")
            continue
        loops.append(L)

    # --- nesting: each loop's parent is the smallest loop around it ------------
    for L in loops:
        mine = set(L["members"])
        around = [M for M in loops if M is not L and mine <= set(M["members"])
                  and (len(M["members"]) > len(mine) or (M["kind"] == "person" and L["kind"] == "agent"))]
        L["parent"] = min(around, key=lambda M: len(M["members"]))["id"] if around else None
    by_lid = {L["id"]: L for L in loops}
    for L in loops:
        d, cur = 0, L.get("parent")
        while cur and d < 20:
            d += 1
            cur = (by_lid.get(cur) or {}).get("parent")
        L["depth"] = d

    # --- every cycle counted: with the latches cut, nothing may cycle ----------
    cut = {tuple(x) for L in loops for x in L["latches"]}
    rest = [e for e in edges if (e["from"], e["to"]) not in cut]
    uncounted = set(loose)
    for C in _nontrivial(_scc(ids, rest), rest):
        if not C <= loose:
            warnings.append(f"cycle {' ⇄ '.join(sorted({base(x) for x in C}))} is not counted by any loop: "
                            "its steps keep per-node caps")
        uncounted |= C
    for k in overrides:
        if k not in by_lid:
            warnings.append(f"loops.{k}: no loop has that id (loops are named by their header, or by the gate for a person loop)")
    return loops, warnings, sorted(uncounted)


def worst_jobs(nodes: list[dict[str, Any]], loops: list[dict[str, Any]], uncounted: list[str] | None = None,
               max_rounds: int = 3) -> int:
    """The most jobs the graph can dispatch under its caps (before max_jobs cuts it)."""
    by_id = {n["id"]: n for n in nodes}
    unc = set(uncounted or [])

    def job(i: str) -> bool:
        return (by_id.get(i) or {}).get("role") not in JOBLESS

    def lifetime(i: str) -> int:
        return _pos((by_id.get(i) or {}).get("max_visits")) or int(max_rounds)

    kids: dict[Any, list[dict[str, Any]]] = {}
    for L in loops:
        kids.setdefault(L.get("parent"), []).append(L)

    def cost(L: dict[str, Any]) -> int:
        inner = kids.get(L["id"], [])
        inner_ids: set[str] = set().union(*[set(a["members"]) for a in inner]) if inner else set()
        own = [i for i in set(L["members"]) - inner_ids if job(i)]
        per = sum(cost(a) for a in inner) + sum(1 for i in own if i not in unc)
        return int(L["max_iters"]) * per + sum(lifetime(i) for i in own if i in unc)

    top = kids.get(None, [])
    covered: set[str] = set().union(*[set(L["members"]) for L in top]) if top else set()
    rest = [i for i in by_id if i not in covered and job(i)]
    return sum(cost(L) for L in top) + sum(lifetime(i) if i in unc else 1 for i in rest)


def table(loops: list[dict[str, Any]]) -> list[str]:
    """The loop table `pong graph lint` prints, outermost first."""
    out: list[str] = []
    by_parent: dict[Any, list[dict[str, Any]]] = {}
    for L in loops:
        by_parent.setdefault(L["parent"], []).append(L)

    def walk(parent: Any, depth: int) -> None:
        for L in sorted(by_parent.get(parent, []), key=lambda x: x["id"]):
            lat = ", ".join(f"{a}→{b}" for a, b in L["latches"][:4])
            who = "you answer" if L["kind"] == "person" else "agents"
            out.append(f"{'  ' * depth}{L['id']:<10} {L['kind']:<6} header {', '.join(L['header'])} · "
                       f"{L['max_iters']} round(s) · {who} · back: {lat}")
            walk(L["id"], depth + 1)

    walk(None, 0)
    return out


# ---------------------------------------------------------------- runtime ---

def records(loops: list[dict[str, Any]], starts: list[str]) -> dict[str, dict[str, Any]]:
    """The loop records a graph carries, with the loops that hold a start node already open."""
    out: dict[str, dict[str, Any]] = {}
    for L in loops:
        opened = bool(set(starts or []) & set(L["members"]))
        out[L["id"]] = {**L, "round": 1 if opened else 0, "activation": 1 if opened else 0,
                        "status": "active" if opened else "idle", "trail": []}
    return out


def _children(graph: dict[str, Any], lid: str) -> list[str]:
    loops = graph.get("loops") or {}
    out: list[str] = []
    stack = [lid]
    while stack:
        cur = stack.pop()
        for k, L in loops.items():
            if L.get("parent") == cur and k not in out:
                out.append(k)
                stack.append(k)
    return out


def innermost(graph: dict[str, Any], nid: str) -> dict[str, Any] | None:
    """The deepest loop *nid* belongs to."""
    best = None
    for L in (graph.get("loops") or {}).values():
        if nid in (L.get("members") or []):
            key = (int(L.get("depth") or 0), 1 if L.get("kind") == "agent" else 0)
            if best is None or key > best[0]:
                best = (key, L)
    return best[1] if best else None


def in_loop(graph: dict[str, Any], nid: str) -> bool:
    return any(nid in (L.get("members") or []) for L in (graph.get("loops") or {}).values())


def counted(graph: dict[str, Any], nid: str) -> bool:
    """In a loop whose rounds bound it (not on a loose or uncounted cycle)."""
    return in_loop(graph, nid) and nid not in set(graph.get("uncounted") or [])


def _status(graph: dict[str, Any], nid: str) -> str:
    for n in graph.get("nodes") or []:
        if isinstance(n, dict) and n.get("id") == nid:
            return str(n.get("status") or "")
    return ""


def cross(graph: dict[str, Any], source: str, targets: list[str], *, now: float = 0.0,
          summary: str = "") -> dict[str, Any]:
    """Work routed from *source* to *targets*: open, count and close loop activations.

    Returns ``{"blocked": {target: loop_id}}`` for targets a loop at its cap
    refuses (the caller takes that loop's way out instead of dispatching them).
    One routing counts at most one round, and opens at most one activation, per
    loop, however many copies it feeds; work arriving at a header that is
    already running is a merge, not a round.
    """
    loops = graph.get("loops") or {}
    blocked: dict[str, str] = {}
    touched: set[str] = set()
    ordered = sorted(loops.items(), key=lambda kv: int(kv[1].get("depth") or 0))
    for lid, L in ordered:
        members = set(L.get("members") or [])
        latches = {tuple(x) for x in L.get("latches") or []}
        for t in targets:
            if t in blocked or lid in touched:
                continue
            if (source, t) in latches:
                live = [u for u in targets if (source, u) in latches and _status(graph, u) not in IN_FLIGHT]
                if not live:
                    continue  # every way back is already running: a merge, not a round
                touched.add(lid)
                if int(L.get("round") or 0) >= int(L.get("max_iters") or 1):
                    for u in live:
                        blocked[u] = lid
                    continue
                L["trail"] = (L.get("trail") or [])[-19:] + [{"round": int(L.get("round") or 0), "ended_by": source,
                                                              "at": now, "summary": str(summary)[:160]}]
                L["round"] = int(L.get("round") or 0) + 1
                L["status"] = "active"
                for c in _children(graph, lid):  # the loops inside start fresh on their next entry
                    loops[c].update(status="idle", round=0)
            elif t in members and source not in members:
                touched.add(lid)
                L["activation"] = int(L.get("activation") or 0) + 1
                at_header = base(t) in {base(h) for h in L.get("header") or []}
                L["round"] = 1 if (at_header or L.get("kind") == "person") else 0
                L["status"] = "active"
                L["trail"] = []
                for c in _children(graph, lid):
                    loops[c].update(status="idle", round=0)
            elif source in members and t not in members and L.get("status") == "active":
                L["status"] = "done"
    return {"blocked": blocked}


def exits(graph: dict[str, Any], lid: str) -> list[dict[str, Any]]:
    """A loop's ``bounded`` edges from its members to outside it."""
    L = (graph.get("loops") or {}).get(lid) or {}
    members = set(L.get("members") or [])
    return [e for e in graph.get("edges") or [] if isinstance(e, dict) and e.get("on") == "bounded"
            and e.get("from") in members and e.get("to") not in members]


def enclosing_gate(graph: dict[str, Any], lid: str) -> str | None:
    """The person loop's gate around loop *lid*, if any."""
    loops = graph.get("loops") or {}
    cur = (loops.get(lid) or {}).get("parent")
    while cur:
        L = loops.get(cur) or {}
        if L.get("kind") == "person":
            return cur
        cur = L.get("parent")
    return None


def person_latch(graph: dict[str, Any], gate: str, targets: list[str]) -> dict[str, Any] | None:
    """The person loop a gate's answer would go round, if the answer sends work back."""
    L = (graph.get("loops") or {}).get(gate)
    if not L or L.get("kind") != "person":
        return None
    latches = {tuple(x) for x in L.get("latches") or []}
    return L if any((gate, t) in latches for t in targets) else None


def iteration(graph: dict[str, Any], nid: str) -> tuple[int, int] | None:
    """(round, rounds left) of the innermost loop *nid* is in."""
    L = innermost(graph, nid)
    if not L:
        return None
    r = int(L.get("round") or 0)
    return r, max(0, int(L.get("max_iters") or 0) - r)


def pass_jobs_worst(graph: dict[str, Any], lid: str) -> int:
    """The jobs one pass of loop *lid* can dispatch at the most: its own job steps
    plus every round of each loop nested in it (what one more round a person
    allows can cost; `round_jobs` is the least)."""
    loops = graph.get("loops") or {}
    L = loops.get(lid) or {}
    roles = {str(n.get("id")): str(n.get("role") or "") for n in graph.get("nodes") or [] if isinstance(n, dict)}
    kids = [k for k, M in loops.items() if M.get("parent") == lid]
    inner: set[str] = set().union(*[set(loops[k].get("members") or []) for k in kids]) if kids else set()
    own = sum(1 for m in L.get("members") or [] if m not in inner and roles.get(m, "") not in JOBLESS)
    return max(1, own + sum(max(1, int(loops[k].get("max_iters") or 1)) * pass_jobs_worst(graph, k) for k in kids))


def round_jobs(graph: dict[str, Any], lid: str) -> int:
    """The jobs one pass of loop *lid* dispatches at the least: its job steps outside
    the loops nested in it, plus one pass of each of those."""
    loops = graph.get("loops") or {}
    L = loops.get(lid) or {}
    roles = {str(n.get("id")): str(n.get("role") or "") for n in graph.get("nodes") or [] if isinstance(n, dict)}
    kids = [k for k, M in loops.items() if M.get("parent") == lid]
    inner: set[str] = set().union(*[set(loops[k].get("members") or []) for k in kids]) if kids else set()
    own = sum(1 for m in L.get("members") or [] if m not in inner and roles.get(m, "") not in JOBLESS)
    return max(1, own + sum(round_jobs(graph, k) for k in kids))
