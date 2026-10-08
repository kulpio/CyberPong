"""Composer — a graph designed from a short interview.

``pong graph new`` asks a handful of plain questions (what, how do we know it
is done, who sees it, how careful, when to stop and show you, which platforms,
where it runs) and turns the answers into a proposal: a loop shape from the
catalog, its rounds, its boundaries, who runs each node and why, and whether
it gets a team of its own. A model may then refine that proposal — through the
Claude CLI already installed, no API key — but only inside the fields the
schema allows, and the human sees the result before anything is spawned.

Two rules shape everything here:

* **The baseline is deterministic.** The same answers always give the same
  graph. The model can adjust it; it cannot invent a node kind the runtime
  cannot execute, and it never starts anything.
* **A person presses Start.** ``compose`` and ``propose`` write nothing.
  ``apply`` writes the team and starts the loop, and only when asked to.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import time
from pathlib import Path
from typing import Any, Callable

Ask = Callable[..., str]

#: The interview, as data. ``options`` are shown to a person in plain words;
#: ``map`` is what each answer means to the composer.
QUESTIONS: list[dict[str, Any]] = [
    {
        "id": "goal",
        "ask": "What should this graph achieve?",
        "hint": "One or two sentences, the way you would say it to the team.",
        "type": "text",
        "required": True,
    },
    {
        "id": "kind",
        "ask": "What kind of work is it?",
        "type": "choice",
        "options": [
            {"key": "code", "label": "Building it", "hint": "code, tests, a repo"},
            {"key": "research", "label": "Finding out", "hint": "read, search, compare, report"},
            {"key": "writing", "label": "The words", "hint": "drafts a person will read"},
            {"key": "ops", "label": "Running things", "hint": "tools, deploys, browser, chores"},
        ],
        "default": "code",
    },
    {
        "id": "done",
        "ask": "How will we know it is done?",
        "type": "choice",
        "options": [
            {"key": "command", "label": "A command must pass", "hint": "e.g. python3 -m unittest, npm test", "value": "command"},
            {"key": "example", "label": "It must match an example", "hint": "a link or a file that shows what great looks like", "value": "examples"},
            {"key": "human", "label": "I will judge it myself", "hint": "no critic; it stops and shows you"},
        ],
        "default": "command",
    },
    {
        "id": "audience",
        "ask": "Who sees the result?",
        "type": "choice",
        "options": [
            {"key": "me", "label": "Just me"},
            {"key": "team", "label": "The team"},
            {"key": "client", "label": "A client", "hint": "platforms that must not write client-facing prose are excluded"},
        ],
        "default": "me",
    },
    {
        "id": "efficiency",
        "ask": "How careful should it be?",
        "type": "choice",
        "options": [
            {"key": "thorough", "label": "Thorough", "hint": "strongest models, a critic on every round, more rounds"},
            {"key": "balanced", "label": "Balanced", "hint": "the standing policy: Opus builds, Opus grades, three rounds"},
            {"key": "fast", "label": "Fast and cheap", "hint": "one round, cheaper tiers where a boundary allows"},
        ],
        "default": "balanced",
    },
    {
        "id": "shape",
        "ask": "What shape should the work take?",
        "type": "choice",
        "options": [
            {"key": "auto", "label": "Let it pick", "hint": "gauntlet, cycle or fan from the answers above"},
            {"key": "graph", "label": "A graph loop I describe", "hint": "stages in order, e.g. gather -> write <-> grade -> me -> done"},
        ],
        "default": "auto",
    },
    {
        "id": "pause",
        "ask": "When should it stop and show you?",
        "type": "choice",
        "options": [
            {"key": "round", "label": "After every round", "hint": "you resume each round by hand"},
            {"key": "win", "label": "When it passes, or runs out of rounds", "hint": "the critic decides; you get one message per round"},
            {"key": "done", "label": "Only when it is done or stuck", "hint": "unattended; needs a command or an example to check against"},
        ],
        "default": "win",
    },
    {
        "id": "platforms",
        "ask": "Which AI platforms may it use?",
        "type": "choice",
        "options": [
            {"key": "any", "label": "Any that fits", "hint": "the solver picks by strength and boundary"},
            {"key": "claude", "label": "Claude only"},
            {"key": "claude+grok", "label": "Claude, and Grok for scouting"},
        ],
        "default": "any",
    },
    {
        "id": "team",
        "ask": "Where should it run?",
        "type": "choice",
        "options": [
            {"key": "new", "label": "A new team of its own", "hint": "a lead seat is created for it"},
            {"key": "under", "label": "Under one of my mains", "hint": "pass --under wN, or answer with the seat id"},
        ],
        "default": "new",
    },
]

ROUNDS = {"thorough": 4, "balanced": 3, "fast": 1}
PIECES = {"thorough": 3, "balanced": 2, "fast": 2}

#: Mission role (what the seat's identity block says) and solver role (which
#: strength it draws on) for the builder node, per kind of work.
BUILDER = {
    "code": ("coder", "builder"),
    "research": ("researcher", "scout"),
    "writing": ("writer", "writer"),
    "ops": ("operator", "operator"),
}


class ComposeError(ValueError):
    pass


# ----------------------------------------------------------------- answers ---


def _slug(text: str, n: int = 6) -> str:
    words = re.findall(r"[a-z0-9]+", str(text or "").lower())
    return "-".join(words[:n]) or "graph"


def title_of(goal: str) -> str:
    words = str(goal or "").strip().split()
    t = " ".join(words[:7])
    return (t[:60].rstrip(" ,.;:") or "New graph")


def normalize_answers(raw: dict[str, Any]) -> dict[str, Any]:
    """Fill defaults, canonicalise choices, refuse an empty goal."""
    a = {k: v for k, v in (raw or {}).items()}
    goal = str(a.get("goal") or "").strip()
    if not goal:
        raise ComposeError("say what the graph should achieve")
    out: dict[str, Any] = {"goal": goal}
    for q in QUESTIONS:
        if q["type"] != "choice":
            continue
        keys = [o["key"] for o in q["options"]]
        val = str(a.get(q["id"]) or q.get("default") or keys[0]).strip().lower()
        if val not in keys:
            # accept a label or a 1-based index
            for i, o in enumerate(q["options"], 1):
                if val in (o["label"].lower(), str(i)):
                    val = o["key"]
                    break
        if val not in keys:
            raise ComposeError(f"{q['id']}: pick one of {', '.join(keys)} (got {val!r})")
        out[q["id"]] = val
    out["done_value"] = str(a.get("done_value") or a.get("command") or a.get("example") or "").strip()
    out["under"] = str(a.get("under") or "").strip()
    out["title"] = str(a.get("title") or "").strip() or title_of(goal)
    out["project_root"] = str(a.get("project_root") or "").strip()
    if out["team"] == "under" and not out["under"]:
        raise ComposeError("team=under needs the main's seat id (--under wN)")
    if out["done"] == "command" and not out["done_value"]:
        raise ComposeError("a command must pass — which one? (done_value)")
    if out["done"] == "example" and not out["done_value"]:
        raise ComposeError("it must match an example — which link or file? (done_value)")
    out["stages"] = str(a.get("stages") or "").strip()
    if out["shape"] == "graph" and not out["stages"]:
        raise ComposeError("a graph loop needs its stages, e.g. gather -> write <-> grade -> me -> done (stages)")
    return out


# ------------------------------------------------------------- graph loop ---

#: A stage name → the node role the runtime runs it as. Anything else is a
#: writer/builder by the kind of work. "me", "human", "review" is a person.
STAGE_ROLES = {
    "gather": "operator", "fetch": "operator", "ingest": "operator", "collect": "operator", "run": "operator",
    "scout": "scout", "research": "researcher", "read": "researcher", "find": "scout", "search": "scout",
    "write": "writer", "draft": "writer", "synthesize": "writer", "synthesise": "writer", "summarize": "writer",
    "build": "builder", "code": "builder", "implement": "builder", "fix": "builder",
    "grade": "critic", "check": "critic", "review": "critic", "critique": "critic", "test": "critic", "judge": "critic", "verify": "critic",
    "route": "router", "decide": "router", "triage": "router",
    "jev": "jev", "jev-grade": "jev", "jev-decide": "jev", "jev-route": "jev",
    "me": "human", "human": "human", "person": "human", "approve": "human",
    "done": "join", "end": "join", "ship": "join", "finish": "join",
}

_ARROW = re.compile(r"\s*(<->|⇄|<=>|->|→|=>)\s*")


#: The rubric shipped with the engine that fits each kind of work (python/pong/loops/rubrics/).
KIND_RUBRIC = {"code": "@code-change", "ops": "@code-change", "writing": "@document", "research": "@document"}


def _jev_rubric(kind: str, done_text: str) -> list[Any]:
    rub: list[Any] = [KIND_RUBRIC.get(kind, "@document")]
    if done_text.strip():
        rub.append({"id": "done_means", "type": "noul",
                    "text": "The work meets what the person said done means: " + done_text.strip()[:400]})
    return rub


def parse_stages(text: str, *, kind: str = "writing", goal: str = "",
                 acceptance: list[str] | None = None, done_text: str = "", jev: bool = True) -> dict[str, Any]:
    """`gather -> write <-> grade -> me -> done` → a topology the runtime lints.

    `->` is an edge on done. `a <-> b` is a cycle: a on done → b, and b is a critic
    whose fail returns to a and whose win goes on. A person (`me`) is a gate:
    approved goes on, rejected returns to the last stage that made something. The
    last stage is the end; if it is not named done/end one is added.

    A stage's role comes from its name: the whole name, or its first word — but
    a gate or an end only from the whole name ("finish the draft" is a stage that
    writes, not the end). A critic's fail, and a gate's reject, go back to the
    last stage that produced something, never to another critic. A router gets a
    ``route:<stage>`` edge to every stage after it. *acceptance* commands become
    an engine ``check`` before the first judge — a critic or Jev — (or the first
    gate): tests decide before a model does.

    Jev: every critic gets a second, independent grade beside it (the rubric
    shipped for this kind of work, plus what the person said done means), in
    ``both`` mode — either may send the work back, a win needs the critic. A
    stage named ``jev`` is a Jev grade of its own; ``jev-decide`` lets Jev pick
    the route among the stages after it. Where Jev is unsure, the work goes to
    the next person gate. *jev* false leaves Jev out (a client-facing graph)."""
    parts = _ARROW.split(str(text or "").strip())
    if not parts or not parts[0]:
        raise ComposeError("stages: say at least two, e.g. write -> me")
    names = [parts[i] for i in range(0, len(parts), 2)]
    ops = [parts[i] for i in range(1, len(parts), 2)]
    if len(names) < 2:
        raise ComposeError("stages: say at least two, e.g. write -> me")
    default_role = {"code": "builder", "research": "researcher", "writing": "writer", "ops": "operator"}.get(kind, "writer")
    nodes: list[dict[str, Any]] = []
    ids: list[str] = []
    for raw in names:
        nid = re.sub(r"[^a-z0-9]+", "-", raw.strip().lower()).strip("-") or "stage"
        base = nid
        n = 2
        while nid in ids:
            nid = f"{base}-{n}"; n += 1
        whole = STAGE_ROLES.get(base)
        first = STAGE_ROLES.get(base.split("-")[0])
        role = whole or (first if first not in ("join", "human") else None) or default_role
        ids.append(nid)
        nd: dict[str, Any] = {"id": nid, "role": role, "task": _stage_task(nid, role)}
        if role == "jev":
            nd.pop("task")
            nd["ask"] = "decide" if base in ("jev-decide", "jev-route") else "grade"
            if nd["ask"] == "grade":
                nd["rubric"] = _jev_rubric(kind, done_text)
                if kind in ("code", "ops"):
                    nd["diff"] = True
        elif role == "critic" and jev:
            nd["jev"] = {"rubric": _jev_rubric(kind, done_text), "mode": "both", **({"diff": True} if kind in ("code", "ops") else {})}
        nodes.append(nd)
    if nodes[-1]["role"] != "join":
        nodes.append({"id": "done" if "done" not in ids else "finish", "role": "join"}); ids.append(nodes[-1]["id"]); ops.append("->")
    cmds = [str(c).strip() for c in (acceptance or []) if str(c).strip()]
    if cmds:
        # before the first judge — a critic or Jev: a grade reads work whose tests passed
        k = next((i for i, n in enumerate(nodes) if n["role"] in ("critic", "jev")), None)
        if k is None:
            k = next((i for i, n in enumerate(nodes) if n["role"] == "human"), len(nodes) - 1)
        tid = "tests" if "tests" not in ids else "tests-run"
        nodes.insert(k, {"id": tid, "role": "check", "run": cmds, "timeout_min": 20})
        ids.insert(k, tid)
        ops.insert(max(0, k - 1), "->")
    producers = {"builder", "writer", "researcher", "scout", "operator"}

    def last_producer(before: int) -> str | None:
        for j in range(before, -1, -1):
            if nodes[j]["role"] in producers:
                return nodes[j]["id"]
        return None

    edges: list[dict[str, str]] = []
    for i in range(len(nodes) - 1):
        op = ops[i] if i < len(ops) else "->"
        a, b = nodes[i], nodes[i + 1]
        cyc = op in ("<->", "⇄", "<=>")
        if a["role"] in ("critic", "check"):
            edges.append({"from": a["id"], "to": b["id"], "on": "win"})
            back = last_producer(i - 1)
            if back:
                edges.append({"from": a["id"], "to": back, "on": "fail"})
        elif a["role"] == "human":
            edges.append({"from": a["id"], "to": b["id"], "on": "approved"})
            back = last_producer(i - 1)
            if back:
                edges.append({"from": a["id"], "to": back, "on": "rejected"})
        elif a["role"] == "router":
            edges.append({"from": a["id"], "to": b["id"], "on": "*"})
            for later in nodes[i + 2:]:
                if later["role"] != "join":
                    edges.append({"from": a["id"], "to": later["id"], "on": f"route:{later['id']}"})
        elif a["role"] == "jev":
            person = next((n["id"] for n in nodes[i + 1:] if n["role"] == "human"), None)
            if a.get("ask") == "decide":
                for later in nodes[i + 1:]:
                    if later["role"] not in ("join", "human"):
                        edges.append({"from": a["id"], "to": later["id"], "on": f"route:{later['id']}"})
            else:
                edges.append({"from": a["id"], "to": b["id"], "on": "win"})
                back = last_producer(i - 1)
                if back:
                    edges.append({"from": a["id"], "to": back, "on": "fail"})
            edges.append({"from": a["id"], "to": person or b["id"], "on": "abstain"})
        else:
            edges.append({"from": a["id"], "to": b["id"], "on": "done"})
        if cyc and b["role"] not in ("critic", "check") and a["role"] in producers:
            # a <-> b with no critic: b's fail comes back to a
            edges.append({"from": b["id"], "to": a["id"], "on": "fail"})
    seen: set[tuple[str, str, str]] = set(); out_edges = []
    for e in edges:
        k2 = (e["from"], e["to"], e["on"])
        if k2 not in seen:
            seen.add(k2); out_edges.append(e)
    return {"name": _slug(text, 4), "start": ids[0], "nodes": nodes, "edges": out_edges, "goal": goal}


def _stage_task(nid: str, role: str) -> str:
    name = nid.replace("-", " ")
    if role == "critic":
        return ("{goal}\n\nRound {round}. Stage `" + name + "`: grade what the previous stage produced ({prev_artifacts}). "
                "Previous step said: {prev_summary}\nSay `win` when it clears the goal, otherwise `fail` with exactly what falls short. Do not edit the files.")
    if role == "router":
        return "{goal}\n\nRound {round}. Stage `" + name + "`: decide where this goes next and claim with `route:<stage>`. Previous: {prev_summary}"
    return ("{goal}\n\nRound {round}. Stage `" + name + "`. Previous step said: {prev_summary}\nArtifacts so far: {prev_artifacts}\n"
            "Do this stage's part of the goal and claim with the file paths you produced and a summary of what moved.")


# ----------------------------------------------------------------- compose ---


def compose(answers: dict[str, Any]) -> dict[str, Any]:
    """Deterministic baseline: answers → proposal. Writes nothing."""
    a = normalize_answers(answers)
    notes: list[str] = []
    kind = a["kind"]
    mission, wire_role = BUILDER.get(kind, BUILDER["code"])
    eff = a["efficiency"]
    rounds = ROUNDS[eff]

    # Shape. A critic needs something to grade against; without a command or
    # an example the engine (rightly) refuses a gauntlet, so the person judges.
    done: dict[str, Any] = {}
    if a["done"] == "command":
        done = {"acceptance": [{"cmd": a["done_value"], "expect_exit": 0}]}
    elif a["done"] == "example":
        v = a["done_value"]
        done = {"examples": [v]} if re.match(r"^https?://", v) else {"bar": v}
    else:
        done = {"human": True}

    if a["done"] == "human":
        loop = "cycle"
        notes.append("No critic: you said you would judge it, so each round comes back to you.")
    elif eff == "fast":
        loop = "cycle"
        notes.append("Fast: one round and no critic. The check you named still travels with the job.")
    else:
        loop = "gauntlet"
        notes.append("Gauntlet: a builder and a separate critic that never sees the builder's transcript.")

    if kind == "research" and eff == "thorough" and a["done"] == "human":
        loop = "fan"
        notes.append("Thorough research with no fixed bar fans out into pieces and joins.")

    topology: dict[str, Any] | None = None
    if a.get("shape") == "graph":
        loop = "graph"
        cmds = [a["done_value"]] if a["done"] == "command" and a.get("done_value") else None
        bar_text = a["done_value"] if a["done"] == "example" and not re.match(r"^https?://", str(a.get("done_value") or "")) else ""
        client = a["audience"] == "client"
        topology = parse_stages(a["stages"], kind=kind, goal=a["goal"], acceptance=cmds, done_text=bar_text, jev=not client)
        topology["max_rounds"] = rounds
        if cmds:
            notes.append(f"The command you named runs as an engine check before the first judge (critic or Jev): `{cmds[0]}`.")
        if any(n.get("jev") for n in topology["nodes"]):
            try:
                from . import jev as _jev

                live = _jev.can_ask()
            except Exception:
                live = False
            notes.append("Jev grades beside each critic against the " + KIND_RUBRIC.get(kind, "@document")[1:]
                         + " rubric" + (" and your bar" if bar_text else "")
                         + ": either can send the work back, a win needs the critic, and you see the weakest line first."
                         + ("" if live else " (Jev is not available on this Mac yet, so the critics decide alone.)"))
        elif client:
            notes.append("Client-facing: Jev is left out (nothing from this graph is sent to it).")
        stages = " → ".join(n["id"] for n in topology["nodes"])
        notes = [n for n in notes if not n.startswith(("Gauntlet", "Fast", "No critic", "Thorough"))]
        notes.append(f"Graph loop: {stages}; every cycle in it is bounded by {rounds} rounds.")

    pause_on = a["pause"]
    agency = "unattended" if pause_on == "done" else "gated"
    if pause_on == "done" and a["done"] == "human":
        pause_on = "win"
        agency = "gated"
        notes.append("Unattended needs a command or an example to check against; with you as the judge it stops when rounds run out instead.")

    allowed: list[str] = []
    if a["platforms"] == "claude":
        allowed = ["claude"]
    elif a["platforms"] == "claude+grok":
        allowed = ["claude", "grok"]

    boundaries = {
        "client_facing": a["audience"] == "client",
        "agency": agency,
        "pause_on": pause_on,
        "efficiency": eff,
        "allowed": allowed,
        "effects": ["read", "write:repo"] if kind in ("code", "ops") else ["read"],
    }
    team = {"mode": a["team"], "under": a["under"] or None, "display_name": a["title"],
            "project_root": a["project_root"] or None}

    return {
        "version": 1,
        "title": a["title"],
        "goal": a["goal"],
        "kind": kind,
        "loop": loop,
        "builder_role": mission,
        "wire_role": wire_role,
        "max_rounds": rounds,
        "pieces": PIECES[eff],
        "done": done,
        "boundaries": boundaries,
        "pins": {},
        "topology": topology,
        "team": team,
        "answers": a,
        "notes": notes,
        "designed_by": {"baseline": "composer"},
    }


# ------------------------------------------------------------- the model ---

#: Fields the model may change, and the values it may choose. Anything else it
#: says is dropped, with a note.
EDITABLE = {
    "loop": {"gauntlet", "cycle", "fan", "graph"},
    "max_rounds": range(1, 7),
    "pieces": range(1, 5),
    "pause_on": {"round", "win", "done"},
    "builder_role": {"coder", "researcher", "writer", "operator"},
}

_DESIGN_PROMPT = """You are designing a bounded agent loop for CyberPong. A person answered a short interview and a deterministic composer produced a baseline. Refine it only where the answers justify it.

Interview answers (JSON):
{answers}

Baseline proposal (JSON):
{baseline}

Rules:
- Reply with ONE JSON object and nothing else.
- Allowed keys: "title" (short name, max 60 chars), "goal" (the goal rewritten as one clear paragraph a builder can act on; keep every fact, add none), "loop" (gauntlet|cycle|fan), "max_rounds" (1-6), "pieces" (1-4, fan only), "builder_role" (coder|researcher|writer|operator), "pause_on" (round|win|done), "why" (one sentence per change, as a list of strings).
- A gauntlet needs something to grade against (a command or an example). Never propose one when the person will judge it themselves.
- "done" means unattended; only keep it when a command or example exists.
- Omit any key you would not change. Do not use tools or read files; answer from the text above only.
"""


def _find_json(text: str) -> dict[str, Any] | None:
    s = str(text or "")
    start = s.find("{")
    while start != -1:
        depth = 0
        for i in range(start, len(s)):
            if s[i] == "{":
                depth += 1
            elif s[i] == "}":
                depth -= 1
                if depth == 0:
                    try:
                        data = json.loads(s[start : i + 1])
                        return data if isinstance(data, dict) else None
                    except json.JSONDecodeError:
                        break
        start = s.find("{", start + 1)
    return None


def _run_model(prompt: str, *, session: str | None = None, timeout: float = 90.0) -> tuple[bool, str]:
    """Ask the installed Claude CLI, headless. No key, no socket of our own."""
    import tempfile

    # One turn, no tools, in an empty directory: this is a judgment call on a
    # JSON document, not an agentic session. Without these the CLI happily
    # spends two minutes reading the repository it was started in.
    argv = ["claude", "-p", prompt, "--output-format", "text", "--max-turns", "1"]
    model = (os.environ.get("PONG_GRAPH_MODEL") or "").strip()
    if model and model.lower() not in ("1", "on", "yes", "true"):
        argv += ["--model", model]
    env = {k: v for k, v in os.environ.items() if not k.startswith(("CLAUDE_CODE", "CLAUDE_AGENT"))}
    try:
        with tempfile.TemporaryDirectory() as cwd:
            r = subprocess.run(argv, capture_output=True, text=True, timeout=timeout,
                               cwd=cwd, env=env, stdin=subprocess.DEVNULL)
    except FileNotFoundError:
        return False, "claude CLI is not installed"
    except subprocess.TimeoutExpired:
        return False, f"model did not answer within {int(timeout)} s"
    except Exception as e:  # noqa: BLE001
        return False, f"{type(e).__name__}: {e}"
    if r.returncode != 0:
        return False, (r.stderr or r.stdout or f"exit {r.returncode}").strip()[:300]
    return True, r.stdout or ""


def propose(
    proposal: dict[str, Any],
    *,
    session: str | None = None,
    runner: Callable[[str], tuple[bool, str]] | None = None,
) -> dict[str, Any]:
    """Let the model refine the baseline, inside EDITABLE. Never starts anything."""
    if (os.environ.get("PONG_GRAPH_MODEL") or "").strip().lower() in ("0", "off", "no", "false"):
        proposal["designed_by"] = {"baseline": "composer", "model": "off"}
        return proposal
    prompt = _DESIGN_PROMPT.format(
        answers=json.dumps(proposal.get("answers") or {}, ensure_ascii=False, indent=2),
        baseline=json.dumps({k: proposal[k] for k in ("title", "goal", "loop", "max_rounds", "pieces", "builder_role", "boundaries", "done")}, ensure_ascii=False, indent=2),
    )
    run = runner or (lambda p: _run_model(p, session=session))
    ok, out = run(prompt)
    if not ok:
        proposal["designed_by"] = {"baseline": "composer", "model": "unavailable", "error": out}
        proposal["notes"].append(f"Model refinement skipped: {out}")
        return proposal
    edits = _find_json(out)
    if not edits:
        proposal["designed_by"] = {"baseline": "composer", "model": "no-json"}
        proposal["notes"].append("Model answered without a JSON object; baseline kept.")
        return proposal
    changed: list[str] = []
    dropped: list[str] = []
    human_judges = bool((proposal.get("done") or {}).get("human"))
    for key, val in edits.items():
        if key == "title" and isinstance(val, str) and val.strip():
            proposal["title"] = val.strip()[:60]
            proposal["team"]["display_name"] = proposal["title"]
            changed.append("title")
        elif key == "goal" and isinstance(val, str) and len(val.strip()) >= 12:
            proposal["goal"] = val.strip()
            changed.append("goal")
        elif key == "loop" and val in EDITABLE["loop"]:
            if proposal.get("topology"):
                dropped.append(f"loop={val} (the person described the graph; its shape stays)")
            elif val == "graph":
                dropped.append("loop=graph (no stages were described)")
            elif val == "gauntlet" and human_judges:
                dropped.append("loop=gauntlet (no bar to grade against)")
            else:
                proposal["loop"] = val
                changed.append("loop")
        elif key == "max_rounds" and isinstance(val, int) and val in EDITABLE["max_rounds"]:
            proposal["max_rounds"] = val
            changed.append("max_rounds")
        elif key == "pieces" and isinstance(val, int) and val in EDITABLE["pieces"]:
            proposal["pieces"] = val
            changed.append("pieces")
        elif key == "builder_role" and val in EDITABLE["builder_role"]:
            proposal["builder_role"] = val
            proposal["wire_role"] = {"coder": "builder", "researcher": "scout", "writer": "writer", "operator": "operator"}[val]
            changed.append("builder_role")
        elif key == "pause_on" and val in EDITABLE["pause_on"]:
            if val == "done" and human_judges:
                dropped.append("pause_on=done (unattended needs a check)")
            else:
                proposal["boundaries"]["pause_on"] = val
                proposal["boundaries"]["agency"] = "unattended" if val == "done" else "gated"
                changed.append("pause_on")
        elif key == "why" and isinstance(val, list):
            proposal["notes"].extend(str(x) for x in val if str(x).strip())
        else:
            dropped.append(str(key))
    proposal["designed_by"] = {"baseline": "composer", "model": "claude", "changed": changed, "dropped": dropped}
    return proposal


# --------------------------------------------------------------- the team ---


def _next_team_name() -> str:
    from .paths import state_dir
    from .state import load_pairs_db

    taken = set(load_pairs_db().keys())
    jobs = state_dir() / "jobs"
    if jobs.is_dir():
        taken |= {p.name for p in jobs.iterdir()}
    n = 1
    while f"pong-team-{n}" in taken or (n == 1 and "pong-team" in taken and False):
        n += 1
    return f"pong-team-{n}"


def new_team(proposal: dict[str, Any], *, session: str | None = None, initial_prompt: str = "") -> dict[str, Any]:
    """Create a team of its own for this graph: a lead seat, a token, a tmux
    session when tmux is there. Returns the pair state. Idempotent on name.

    ``initial_prompt`` starts the lead on it (the CLI's positional): a graph architect's
    lead starts on a pointer to its prompt file rather than on an empty chat."""
    from .jsonutil import write_json
    from .paths import active_path, ensure_layout, resolved_folder
    from .routing import ensure_session_token, register_worker_pane, exact_window_title
    from .state import load_pairs_db, save_pairs_db
    from .wiring import plan_node

    name = session or _next_team_name()
    pins = proposal.get("pins") if isinstance(proposal.get("pins"), dict) else {}
    lead = plan_node("orchestrator", proposal.get("goal") or "", session=None,
                     boundaries=proposal.get("boundaries"),
                     pin=pins.get("lead") or pins.get("orchestrator") or pins.get("*"))
    runtime = str(lead.get("runtime") or "claude")
    title = str(proposal.get("title") or "New graph")
    # A model the person picked belongs to the runtime they picked: when that pin was refused (not
    # installed, switched off) the lead runs elsewhere, and "grok-4.7" on a Claude seat would be a
    # record that disagrees with what launched, or a seat that does not start.
    lead_model = str(proposal.get("lead_model") or "").strip()
    if lead_model:
        try:
            from . import models as M

            if M._belongs_elsewhere(M.runtimes(None), runtime, lead_model):
                lead_model = ""
        except Exception:
            pass
    pair: dict[str, Any] = {
        "session": name,
        "schema_version": 2,
        "conductor": {
            "id": "c1", "type": runtime,
            "label": f"{title} · lead",
            "cmd": str(lead.get("cmd") or runtime),
            # a model the person picked (a graph architect's chat) wins over the lead policy's pick
            "model": lead_model or lead.get("model"),
            "mode": "tmux", "tmux_index": 0, "window_id": None,
            "mission_role": "orchestrator",
            "model_why": lead.get("why"),
        },
        "workers": [],
        "transport_default": "job+paste",
        "display_name": title,
        "team_brief": str(proposal.get("goal") or ""),
        # absolute and resolved: the runner and the app run from other folders, where "." is somewhere else
        "project_root": resolved_folder((proposal.get("team") or {}).get("project_root") or os.getcwd()),
        "flow_graph": {"edges": []},
        "composed": {"at": time.time(), "kind": proposal.get("kind"), "loop": proposal.get("loop"),
                     "designed_by": proposal.get("designed_by")},
    }
    db = load_pairs_db()
    # A team that lives only in the active file (the app mirrors whole teams there, and an older
    # `graph new` wrote them nowhere else) would be lost when the pointer below replaces that file:
    # it goes into the list first. (A team's settings were once lost this way.)
    try:
        from .state import load_active

        prev = load_active() or {}
    except Exception:
        prev = {}
    prev_sess = str(prev.get("session") or "") if isinstance(prev, dict) else ""
    if prev_sess and prev_sess != name and prev_sess not in db and isinstance(prev.get("conductor"), dict):
        db[prev_sess] = {k: v for k, v in prev.items() if k != "updated"}
    db[name] = pair
    save_pairs_db(db)
    ensure_layout(name)
    ensure_session_token(name)
    write_json(active_path(), {"session": name, "updated": time.time()})

    # A real terminal for the lead, when the tmux server is reachable and this
    # is the live state dir. Otherwise the team exists and the seat comes up on
    # the next spawn — never a guessed window.
    spawned = {"tmux": False, "note": ""}
    try:
        from .groups import _launch_command, _tmux, isolated_home, session_exists, start_dir_args, type_launch

        if isolated_home():
            spawned["note"] = "isolated PONG_HOME — no tmux"
        elif session_exists(name):
            spawned["note"] = "tmux session already there"
            spawned["tmux"] = True
        else:
            # in the project folder: tmux would open it where this command runs (the app's is /)
            ok, err = _tmux("new-session", "-d", "-s", name, "-n", "lead", *start_dir_args(pair))
            if ok:
                state = dict(pair)
                cmd = _launch_command(state, pair["conductor"], initial_prompt=initial_prompt)
                type_launch(f"{name}:0", cmd, session=name, seat=str(pair["conductor"].get("id") or "c1"))
                ok2, pane = _tmux("display-message", "-t", f"{name}:0", "-p", "#{pane_id}")
                if ok2 and pane.strip():
                    register_worker_pane(name, "c1", pane_id=pane.strip(),
                                         start_command=pair["conductor"]["cmd"],
                                         title=exact_window_title(name, "c1"))
                spawned = {"tmux": True, "note": f"tmux session {name} created, lead on window 0"}
            else:
                spawned["note"] = (f"tmux unavailable — the chat's terminal could not start ({err})" if err
                                   else "tmux unavailable — the chat's terminal could not start")
    except Exception as e:  # noqa: BLE001
        spawned["note"] = f"tmux step skipped — the chat's terminal could not start ({type(e).__name__}: {e})"
    pair["_spawn"] = spawned
    return pair


def start_team(session: str) -> dict[str, Any]:
    """Start a stopped team again under its own name (1.9, the Team page's Start).

    Its terminal session comes back with the lead on window 0 and each helper on its own window,
    as the team was set up; the schedules, the name, the folder and the brief stay as they were.
    A lead that was a chat's seat (a team made from a chat, whose lead is the architect) starts on
    its chat's prompt again, so it takes up its role and says what the team did and what is open.
    A running team is refused: nothing live is touched."""
    from .groups import (_launch_command, _tmux, ensure_seat_window, isolated_home, session_exists, start_dir_args,
                         type_launch)
    from .paths import ensure_layout
    from .routing import ensure_session_token, exact_window_title, register_worker_pane
    from .state import load_pairs_db

    pair = load_pairs_db().get(session)
    if not isinstance(pair, dict) or not isinstance(pair.get("conductor"), dict):
        raise ComposeError(f"no team {session!r}")
    if isolated_home():
        raise ComposeError("this state folder is not the live one: no terminal sessions start from it")
    if session_exists(session):
        raise ComposeError(f"{session} is already running")
    ensure_layout(session)
    ensure_session_token(session)
    state = dict(pair)
    state["session"] = session
    lead = dict(pair["conductor"])
    lead_id = str(lead.get("id") or "c1")

    def register(seat: str, idx: int, cmd: str) -> None:
        ok, pane = _tmux("display-message", "-t", f"{session}:{idx}", "-p", "#{pane_id}")
        if ok and pane.strip():
            register_worker_pane(session, seat, pane_id=pane.strip(), start_command=cmd, title=exact_window_title(session, seat))

    ok, err = _tmux("new-session", "-d", "-s", session, "-n", "lead", *start_dir_args(state))
    if not ok:
        raise ComposeError(f"tmux could not open the session: {err}".strip())
    prompt = ""
    try:
        from .architect import _pointer, list_for

        for a in reversed(list_for(session)):
            path = str(a.get("prompt_path") or "")
            if a.get("seat") == lead_id and path and os.path.exists(path):
                prompt = _pointer(str(a.get("title") or pair.get("display_name") or session), Path(path))
                break
    except Exception:
        prompt = ""  # a lead that comes up without its chat's prompt still comes up
    type_launch(f"{session}:0", _launch_command(state, lead, initial_prompt=prompt), session=session, seat=lead_id)
    register(lead_id, 0, str(lead.get("cmd") or ""))
    started = [f"{lead_id}: the lead, on window 0" + (" (its chat's prompt again)" if prompt else "")]
    for w in pair.get("workers") or []:
        if not isinstance(w, dict) or not w.get("id"):
            continue
        started.append(ensure_seat_window(state, w))
        if isinstance(w.get("tmux_index"), int):
            register(str(w["id"]), int(w["tmux_index"]), str(w.get("cmd") or ""))
    return {"session": session, "started": started, "lead_prompt": bool(prompt)}


# ------------------------------------------------------------------ apply ---


def bar_from_acceptance(session: str, title: str, goal: str, acceptance: list[dict[str, Any]]) -> Path:
    """A critic needs a published standard. When the person said "a command
    must pass", that command *is* the standard: write it down as a bar file so
    the gauntlet has one and the critic can re-run exactly what was promised."""
    from .paths import sessions_dir

    d = sessions_dir(session) / "bars"
    d.mkdir(parents=True, exist_ok=True)
    path = d / f"{_slug(title, 5)}-{int(time.time())}.md"
    cmds = "\n".join(f"- `{a.get('cmd')}` must exit {int(a.get('expect_exit', 0) or 0)}" for a in acceptance if isinstance(a, dict))
    path.write_text(
        f"# Bar · {title}\n\n"
        f"## Goal\n{goal}\n\n"
        f"## Must pass (re-run these yourself on the builder's artifacts)\n{cmds}\n\n"
        "## Verdict\n"
        "`win` only when every command above passes on the artifacts the builder named and the goal is met as written. "
        "Anything else is `fail`, with what specifically falls short and what change would clear it. "
        "A claim you cannot reproduce fails.\n",
        encoding="utf-8",
    )
    return path



def apply(proposal: dict[str, Any], *, session: str | None = None) -> dict[str, Any]:
    """Create the team if asked, then start the loop. This is the one write."""
    from .work_graph import start

    team = proposal.get("team") or {}
    mode = str(team.get("mode") or "new")
    if str(proposal.get("loop") or "") == "graph" and proposal.get("topology"):
        # Refuse a graph that cannot run before a team, a token or a tmux
        # session exists for it (a failed Start used to leave all three).
        from .work_graph import lint_topology

        lint_topology(dict(proposal["topology"]))
    from .jsonutil import read_json
    from .paths import active_path

    prev_active = read_json(active_path()) or None
    if mode == "new":
        pair = new_team(proposal, session=None)
        sess = str(pair["session"])
        owner = "c1"
        spawn_note = (pair.get("_spawn") or {}).get("note", "")
    else:
        sess = str(session or "").strip()
        if not sess:
            raise ComposeError("running under a main needs -s SESSION")
        owner = str(team.get("under") or "").strip()
        if not owner:
            raise ComposeError("running under a main needs --under wN")
        spawn_note = ""
    # This process is creating (or joining) the team on purpose, so it writes
    # with that team's own token — the same thing the cron runner does per
    # session. A stale PONG_SESSION from an earlier start in the same process
    # would otherwise make the second team look like a cross-team write.
    from .cron import apply_token

    apply_token(sess)
    done = proposal.get("done") or {}
    bar = done.get("bar")
    if not bar and not done.get("examples") and done.get("acceptance") and str(proposal.get("loop")) == "gauntlet":
        bar = str(bar_from_acceptance(sess, str(proposal.get("title") or "graph"), str(proposal.get("goal") or ""), list(done["acceptance"])))
    try:
        graph = _start_from(proposal, sess, owner, bar, done)
    except Exception:
        if mode == "new":
            _undo_team(sess, prev_active)
        raise
    graph["_session"] = sess
    graph["_owner"] = owner
    graph["_spawn_note"] = spawn_note
    return graph


def _undo_team(sess: str, prev_active: dict[str, Any] | None) -> None:
    """Take back a team created for a Start (or a chat) that then failed: its tmux
    session, its pairs entry, its state folder, its jobs folder while it is still
    empty (an empty one would hold the team's name), and the active-pair switch."""
    import shutil

    from .jsonutil import write_json
    from .paths import active_path, jobs_dir, sessions_dir
    from .state import load_pairs_db, save_pairs_db

    try:
        from .groups import _tmux, isolated_home, session_exists

        if not isolated_home() and session_exists(sess):
            _tmux("kill-session", "-t", f"={sess}")
    except Exception:
        pass
    try:
        db = load_pairs_db()
        if sess in db:
            db.pop(sess)
            save_pairs_db(db)
    except Exception:
        pass
    try:
        shutil.rmtree(sessions_dir(sess), ignore_errors=True)
    except Exception:
        pass
    try:
        jobs_dir(sess).rmdir()  # only when empty: a job written there is never thrown away
    except OSError:
        pass
    if prev_active:
        try:
            write_json(active_path(), prev_active)
        except Exception:
            pass
    else:
        # no team was active before (a new Mac): a pointer left at the team taken back
        # would name a team that does not exist
        try:
            from .jsonutil import read_json

            if str((read_json(active_path()) or {}).get("session") or "") == sess:
                active_path().unlink()
        except Exception:
            pass


def _start_from(proposal: dict[str, Any], sess: str, owner: str, bar: Any, done: dict[str, Any]) -> dict[str, Any]:
    from .work_graph import start

    return start(
        sess,
        owner=owner,
        loop=str(proposal.get("loop") or "cycle"),
        task=str(proposal.get("goal") or ""),
        bar=bar,
        fan_n=int(proposal.get("pieces") or 2),
        max_rounds=int(proposal.get("max_rounds") or 3),
        examples=list(done.get("examples") or []) or None,
        boundaries=proposal.get("boundaries"),
        pins=proposal.get("pins") or None,
        builder_role=proposal.get("builder_role"),
        wire_role=proposal.get("wire_role"),
        acceptance=list(done.get("acceptance") or []) or None,
        topology=proposal.get("topology") or None,
    )


# --------------------------------------------------------------- interview ---


def interview(ask: Ask, *, under_default: str = "") -> dict[str, Any]:
    """Ask the questions in order; return raw answers. ``ask`` is injected so a
    test can drive it and a non-interactive shell fails loudly upstream."""
    answers: dict[str, Any] = {}
    for q in QUESTIONS:
        if q["type"] == "text":
            while True:
                v = ask(f"{q['ask']}\n  {q.get('hint', '')}\n> ").strip()
                if v or not q.get("required"):
                    break
                print("  (say something — an empty goal is not a graph)")
            answers[q["id"]] = v
            continue
        opts = q["options"]
        lines = [f"{q['ask']}"]
        for i, o in enumerate(opts, 1):
            hint = f"  — {o['hint']}" if o.get("hint") else ""
            mark = "*" if o["key"] == q.get("default") else " "
            lines.append(f"  {i}{mark} {o['label']}{hint}")
        v = ask("\n".join(lines) + "\n> ").strip()
        key = q.get("default") or opts[0]["key"]
        if v:
            for i, o in enumerate(opts, 1):
                if v == str(i) or v.lower() in (o["key"], o["label"].lower()):
                    key = o["key"]
                    break
        answers[q["id"]] = key
        if q["id"] == "done" and key in ("command", "example"):
            prompt = "Which command must pass?\n> " if key == "command" else "Which link or file shows what great looks like?\n> "
            answers["done_value"] = ask(prompt).strip()
        if q["id"] == "shape" and key == "graph":
            answers["stages"] = ask("The stages, in order. `->` goes on when done, `<->` loops back on fail, `me` is you, `done` ends it.\n  e.g. gather -> synthesize <-> grade -> me -> done\n> ").strip()
        if q["id"] == "team" and key == "under":
            answers["under"] = ask(f"Which main? (seat id, e.g. w7){' [' + under_default + ']' if under_default else ''}\n> ").strip() or under_default
    return answers


def format_proposal(p: dict[str, Any], wiring: dict[str, Any] | None = None) -> list[str]:
    b = p.get("boundaries") or {}
    done = p.get("done") or {}
    if done.get("acceptance"):
        done_s = "passes `" + str(done["acceptance"][0].get("cmd")) + "`"
    elif done.get("examples"):
        done_s = "matches " + ", ".join(done["examples"])
    elif done.get("bar"):
        done_s = "clears the bar " + str(done["bar"])
    else:
        done_s = "you judge it"
    team = p.get("team") or {}
    where = "a new team of its own" if team.get("mode") == "new" else f"under {team.get('under')}"
    lines = [
        f"{p.get('title')}",
        f"  goal      {p.get('goal')}",
        f"  shape     {p.get('loop')} · {p.get('max_rounds')} round(s)" + (f" · {p.get('pieces')} pieces" if p.get("loop") == "fan" else "")
        + ((" · " + " → ".join(n["id"] for n in (p.get("topology") or {}).get("nodes") or [])) if p.get("topology") else ""),
        f"  builder   {p.get('builder_role')} ({p.get('wire_role')})",
        f"  done when {done_s}",
        f"  stops     {'after every round' if b.get('pause_on') == 'round' else ('only when done or stuck' if b.get('pause_on') == 'done' else 'when it passes or runs out of rounds')} · agency {b.get('agency')}",
        f"  careful   {b.get('efficiency')}" + (" · client-facing" if b.get("client_facing") else "") + (f" · platforms {', '.join(b.get('allowed'))}" if b.get("allowed") else " · any platform that fits"),
        f"  runs      {where}",
    ]
    if wiring:
        for nid, row in wiring.items():
            who = f"{row.get('runtime') or '—'} {row.get('model') or ''}".strip()
            lines.append(f"  {nid:9} {who:16} {row.get('why') or ''}")
    db = p.get("designed_by") or {}
    if db.get("model") == "claude":
        lines.append(f"  designed  baseline + Claude (changed: {', '.join(db.get('changed') or []) or 'nothing'})")
    elif db.get("model"):
        lines.append(f"  designed  baseline only ({db.get('model')}{': ' + db['error'] if db.get('error') else ''})")
    for n in p.get("notes") or []:
        lines.append(f"  · {n}")
    return lines
