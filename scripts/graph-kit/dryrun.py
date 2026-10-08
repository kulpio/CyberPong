#!/usr/bin/env python3
"""Walk a graph topology end to end before launching it: no seats, no tmux, no tokens.

    python3 dryrun.py --file build/loop.json [--team pong-team-N] [--pin node=grok ...]
                      [--critic-fails 1] [--expect "BRIEF.md" ...] [--keep]

It starts the graph in a throwaway PONG_HOME (a copy of nothing but the team's project folder name and
its model catalog), then plays every step the engine dispatches: a critic answers "fail" for its first
--critic-fails visits (so the loop back to its writer is exercised) and "win" after; every other step
claims "done"; every gate at a human node is approved. It prints the path the graph took, which seat,
runtime and model each step got, and every problem it saw:
- a step's prompt still carrying a placeholder ({prev_summary}, {prev_artifacts}, {copy}, {round});
- a prompt missing a string you said must be in every step (--expect);
- a refusal, a graph that does not finish, or one that stops for any reason other than a win.
Jev has no key inside the throwaway home, so a Jev grade beside a critic reports "no key" and the
critic's verdict stands; the path is the one the critics' words choose.

Why: on 26 September a real launch found what a dry run would have (a plan step's retry landing on a
dead seat, a join timing out); the rule since the Jev integration is "simulate a new topology end to
end before telling anyone to launch it". Rebuilt from the round-2 script, which lived in a scratch
folder and was wiped.
"""

import argparse, json, os, shutil, sys, tempfile
from pathlib import Path

HOME = Path.home()
PLACEHOLDERS = ("{prev_summary}", "{prev_artifacts}", "{copy}", "{round}")
SESSION = "pong-dryrun"


def main() -> int:
    ap = argparse.ArgumentParser(description="Dry-run a graph topology in a throwaway CyberPong home.")
    ap.add_argument("--file", required=True, help="the topology JSON")
    ap.add_argument("--team", default=os.environ.get("PONG_SESSION"),
                    help="copy this team's project folder and model catalog (so model picks match the real run)")
    ap.add_argument("--project-root", default=None, help="the folder the steps work in (default: the team's, else the file's parent)")
    ap.add_argument("--pin", action="append", default=[], help="node=runtime, as `graph attach --pin` takes it")
    ap.add_argument("--critic-fails", type=int, default=1, help="how many visits each critic answers fail before win")
    ap.add_argument("--expect", action="append", default=[], help="a string every step's prompt must contain")
    ap.add_argument("--max-steps", type=int, default=600)
    ap.add_argument("--keep", action="store_true", help="keep the throwaway home and print its path")
    a = ap.parse_args()

    topo_path = Path(a.file).expanduser().resolve()
    topo = json.loads(topo_path.read_text(encoding="utf-8"))
    pairs = {}
    try:
        pairs = json.loads((HOME / ".pong" / "pairs.json").read_text(encoding="utf-8"))
    except Exception:
        pass
    root = a.project_root or str((pairs.get(a.team) or {}).get("project_root") or "") or str(topo_path.parent.parent)

    tmp = tempfile.mkdtemp(prefix="pong-dryrun-")
    os.environ.update({"PONG_HOME": tmp, "PONG_RUNTIMES": "claude,grok,codex,hermes", "PONG_SESSION": SESSION})
    for k in ("PONG_SEAT", "TYPESAFE_API_KEY", "PONG_JEV_FAKE", "PONG_TOKEN"):
        os.environ.pop(k, None)
    lib = os.environ.get("PONG_LIB") or str(HOME / ".pong" / "lib")
    sys.path.insert(0, lib)
    try:
        from pong.jsonutil import write_json
        from pong.paths import active_path, ensure_layout, pairs_path
        from pong.routing import ensure_session_token
        from pong.work_graph import find_graph, resume, start, tick
        from pong.jobs import load_job, record_claim
    except ImportError as e:
        print(f"cannot import CyberPong from {lib}: {e} (set PONG_LIB to the folder that holds `pong`)", file=sys.stderr)
        return 2

    ensure_layout(SESSION)
    pair = {"schema_version": 2, "project_root": root,
            "conductor": {"id": "c1", "type": "claude", "label": "lead", "cmd": "claude", "mode": "tmux", "tmux_index": 0,
                          "mission_role": "orchestrator"},
            "workers": [], "transport_default": "job", "flow_graph": {"edges": []}}
    write_json(pairs_path(), {SESSION: pair})
    act = dict(pair)
    act["session"] = SESSION
    write_json(active_path(), act)
    ensure_session_token(SESSION)
    if a.team:
        cat = HOME / ".pong" / "sessions" / a.team / "models" / "catalog.json"
        if cat.is_file():
            dst = Path(tmp) / "sessions" / SESSION / "models"
            dst.mkdir(parents=True, exist_ok=True)
            shutil.copy(cat, dst / "catalog.json")

    pins = dict(p.split("=", 1) for p in a.pin if "=" in p)
    problems: list[str] = []
    seen: dict[str, tuple] = {}
    path: list[str] = []
    try:
        g = start(SESSION, owner="c1", loop="graph", task=topo.get("goal") or topo.get("name") or "dry run",
                  topology=topo, pins=pins)
    except Exception as e:
        print(f"the engine refused to start it: {e}")
        return 1
    gid = g["id"]

    def graph():
        return find_graph(SESSION, gid) or {}

    for _ in range(a.max_steps):
        g = graph()
        if str(g.get("status") or "") != "running":
            break
        acted = False
        for n in g.get("nodes") or []:
            if str(n.get("role") or "") == "human" and str(n.get("status") or "") == "waiting_human":
                resume(SESSION, gid, outcome="approved", node=n["id"])
                path.append(f"{n['id']}: approved")
                acted = True
                break
            if str(n.get("status") or "") not in ("running", "dispatched", "claimed") or not n.get("job_id"):
                continue
            job = load_job(SESSION, n["job_id"]) or {}
            prompt = ""
            if job.get("prompt_path") and Path(str(job["prompt_path"])).is_file():
                prompt = Path(str(job["prompt_path"])).read_text(encoding="utf-8")
            else:
                prompt = str(job.get("task") or "")
            for ph in PLACEHOLDERS:
                if ph in prompt:
                    problems.append(f"{n['id']}: its prompt still has {ph}")
            for must in a.expect:
                if must not in prompt:
                    problems.append(f"{n['id']}: its prompt lacks {must!r}")
            seen[n["id"]] = (n.get("seat"), job.get("runtime") or (job.get("_worker") or {}).get("type"), job.get("model"))
            visits = int(n.get("visits") or 1)
            if str(n.get("role") or "") == "critic":
                word = "fail" if visits <= a.critic_fails else "win"
                summary = f"{word}: dry run, visit {visits}."
            else:
                summary = f"dryrun/{n['id']}.md: dry run, visit {visits}."
            record_claim(SESSION, n["job_id"], summary=summary, files=[])
            path.append(f"{n['id']}: {summary.split(':')[0] if n.get('role') == 'critic' else 'done'}")
            acted = True
        for _ in range(3):
            tick(SESSION)
        if not acted and str(graph().get("status") or "") == "running":
            tick(SESSION)
            if not any(str(n.get("status") or "") in ("running", "dispatched", "claimed", "waiting_human")
                       for n in graph().get("nodes") or []):
                problems.append("the graph is running with nothing dispatched and no gate open: it is stuck")
                break
    g = graph()
    status, reason = g.get("status"), g.get("stop_reason")
    if status == "running":
        problems.append(f"it did not finish within {a.max_steps} steps")
    elif reason != "win":
        problems.append(f"it stopped {status} / {reason}, not with a win")
    for r in g.get("refusals") or []:
        problems.append(f"refusal: {json.dumps(r)[:200]}")

    print(f"{topo_path.name}: {status} / {reason} · {g.get('dispatches') or len(seen)} jobs · project folder {root}")
    print("path: " + " → ".join(path))
    print("steps (seat · runtime · model):")
    for k, (seat, rt, model) in sorted(seen.items()):
        print(f"  {k:22} {str(seat):9} {str(rt):7} {model}")
    print("problems: " + ("none" if not problems else ""))
    for p in problems:
        print(f"  - {p}")
    if a.keep:
        print(f"throwaway home kept at {tmp}")
    else:
        shutil.rmtree(tmp, ignore_errors=True)
    return 0 if not problems else 1


if __name__ == "__main__":
    sys.exit(main())
