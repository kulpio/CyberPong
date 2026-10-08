#!/usr/bin/env python3
"""The graph loop: a topology you describe, routed on outcomes, bounded, gated.

What these pin: a bad topology is refused before anything is spawned; a claim's
outcome takes the matching edge; a cycle stops at max_rounds with a named
reason; a human node pauses the graph and resume takes the edge the person
chose; a node whose outcome has no edge stops the graph with a refusal, never
silently.
"""
from __future__ import annotations

import os
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "python"))

TOPO = {
    "start": "build", "max_rounds": 2,
    "nodes": [
        {"id": "build", "role": "builder", "task": "{goal} round {round}. prev: {prev_summary}"},
        {"id": "check", "role": "critic", "task": "grade {prev_artifacts}"},
        {"id": "ok", "role": "human"},
        {"id": "end", "role": "join"},
    ],
    "edges": [
        {"from": "build", "to": "check", "on": "done"},
        {"from": "check", "to": "build", "on": "fail"},
        {"from": "check", "to": "ok", "on": "win"},
        {"from": "ok", "to": "end", "on": "approved"},
        {"from": "ok", "to": "build", "on": "rejected"},
    ],
}


class GraphKindTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        os.environ["PONG_HOME"] = self.tmp.name
        os.environ["PONG_RUNTIMES"] = "claude,grok,codex,hermes"
        os.environ["PONG_SESSION"] = "pong-team"
        os.environ.pop("PONG_SEAT", None)
        from pong.jsonutil import write_json
        from pong.paths import active_path, ensure_layout, pairs_path
        from pong.routing import ensure_session_token

        ensure_layout("pong-team")
        pair = {"schema_version": 2,
                "conductor": {"id": "c1", "type": "grok", "label": "Grok", "cmd": "grok", "mode": "tmux", "tmux_index": 0},
                "workers": [{"id": "w2", "type": "claude", "label": "Lead", "cmd": "claude", "tmux_index": 2, "mission_role": "coder"}],
                "transport_default": "job",
                "flow_graph": {"edges": [{"from": "c1", "to": "w2", "kind": "delegate"}, {"from": "w2", "to": "c1", "kind": "claim"}]}}
        write_json(pairs_path(), {"pong-team": pair}); active = dict(pair); active["session"] = "pong-team"; write_json(active_path(), active)
        ensure_session_token("pong-team")

    def tearDown(self) -> None:
        for k in ("PONG_HOME", "PONG_RUNTIMES", "PONG_SESSION", "PONG_TOKEN"):
            os.environ.pop(k, None)
        self.tmp.cleanup()

    def _start(self, topo=TOPO, **kw):
        from pong.work_graph import start
        return start("pong-team", owner="w2", loop="graph", task="ship it", topology=topo, **kw)

    def test_a_bad_topology_is_refused_before_anything_runs(self) -> None:
        from pong.jobs import list_jobs
        from pong.work_graph import WorkGraphError
        for bad, why in (
            ({**TOPO, "nodes": TOPO["nodes"] + [{"id": "orphan", "role": "builder"}]}, "unreachable"),
            ({**TOPO, "edges": TOPO["edges"] + [{"from": "build", "to": "nowhere", "on": "done"}]}, "unknown node"),
            ({**TOPO, "edges": [{"from": "build", "to": "check", "on": "maybe"}]}, "on="),
            ({**TOPO, "max_rounds": 99}, "max_rounds"),
            ({**TOPO, "nodes": [{"id": "x", "role": "wizard"}], "edges": [], "start": "x"}, "role"),
        ):
            with self.assertRaises(WorkGraphError, msg=why) as cm:
                self._start(bad)
            self.assertIn(why, str(cm.exception))
        self.assertEqual(list_jobs("pong-team"), [], "a refused graph spawns nothing")

    def test_outcomes_take_edges_and_the_cycle_is_bounded(self) -> None:
        from pong.jobs import record_claim
        from pong.work_graph import find_graph, tick
        g = self._start()
        self.assertEqual([n["status"] for n in g["nodes"]], ["running", "pending", "pending", "pending"])
        self.assertEqual(g["wiring"]["check"]["runtime"], "claude")
        build_job = g["_jobs"][0]["id"]
        self.assertIn("round 1", g["_jobs"][0]["_prompt"])
        record_claim("pong-team", build_job, summary="built it", files=["a.py"])
        tick("pong-team")
        f = find_graph("pong-team", g["id"])
        check = next(n for n in f["nodes"] if n["id"] == "check")
        self.assertEqual(check["status"], "running", "done took build→check")
        claims = [h for h in f["history"] if h.get("event", "claim") == "claim"]
        self.assertEqual(claims[-1]["node"], "build")
        record_claim("pong-team", check["job_id"], summary="fail — tests missing")
        tick("pong-team")
        f = find_graph("pong-team", g["id"])
        build = next(n for n in f["nodes"] if n["id"] == "build")
        self.assertEqual(build["status"], "running"); self.assertEqual(build["visits"], 2, "fail took check→build, round 2")
        from pong.jobs import load_job
        self.assertIn("prev: fail — tests missing", load_job("pong-team", build["job_id"])["task"])
        record_claim("pong-team", build["job_id"], summary="built again")
        tick("pong-team")
        f = find_graph("pong-team", g["id"])
        check = next(n for n in f["nodes"] if n["id"] == "check")
        record_claim("pong-team", check["job_id"], summary="fail again")
        tick("pong-team")
        f = find_graph("pong-team", g["id"])
        # A third build would exceed the build⇄check loop's 2 rounds. The loop sits inside the ok gate's
        # loop, so its way out is that gate: a person decides, the graph is not killed (DAG of loops, stage 1).
        self.assertEqual(f["status"], "running")
        ok = next(n for n in f["nodes"] if n["id"] == "ok")
        self.assertEqual(ok["status"], "waiting_human")
        self.assertIn("without passing", ok["gate"]["prev"]["summary"])
        self.assertEqual(next(L for L in f["loops"].values() if L["id"] == "build")["status"], "bounded")
        # and a person's reject opens a fresh inner loop at round 1, not a spent budget
        from pong.work_graph import resume
        resume("pong-team", g["id"], outcome="rejected", note="try a different approach")
        f = find_graph("pong-team", g["id"])
        build = next(n for n in f["nodes"] if n["id"] == "build")
        self.assertEqual(build["status"], "running")
        loop = f["loops"]["build"]
        self.assertEqual((loop["round"], loop["activation"]), (1, 2))

    def test_a_human_gate_pauses_and_resume_takes_the_chosen_edge(self) -> None:
        from pong.jobs import record_claim
        from pong.mailbox import peek
        from pong.work_graph import find_graph, resume, tick
        g = self._start()
        record_claim("pong-team", g["_jobs"][0]["id"], summary="done")
        tick("pong-team")
        check = next(n for n in find_graph("pong-team", g["id"])["nodes"] if n["id"] == "check")
        record_claim("pong-team", check["job_id"], summary="win — clears the bar")
        tick("pong-team")
        f = find_graph("pong-team", g["id"])
        self.assertTrue(f["paused"] and f["paused"]["gate"], "win took check→ok and the graph waits for a person")
        self.assertEqual(f["paused"]["next_node"], "ok")
        self.assertTrue(any(i.get("kind") == "gate" for i in peek("pong-team", "w2", limit=0)))
        tick("pong-team")  # nothing moves while a person is deciding
        self.assertEqual(find_graph("pong-team", g["id"])["status"], "running")
        f = resume("pong-team", g["id"], outcome="approved")
        self.assertEqual(f["status"], "done"); self.assertEqual(f["stop_reason"], "win")

    def test_a_rejection_at_the_gate_loops_back(self) -> None:
        from pong.jobs import record_claim
        from pong.work_graph import find_graph, resume, tick
        g = self._start()
        record_claim("pong-team", g["_jobs"][0]["id"], summary="done")
        tick("pong-team")
        check = next(n for n in find_graph("pong-team", g["id"])["nodes"] if n["id"] == "check")
        record_claim("pong-team", check["job_id"], summary="win")
        tick("pong-team")
        f = resume("pong-team", g["id"], outcome="rejected")
        build = next(n for n in f["nodes"] if n["id"] == "build")
        self.assertEqual(build["status"], "running"); self.assertEqual(build["visits"], 2)
        self.assertIsNone(f["paused"])

    def test_an_outcome_with_no_edge_stops_with_a_refusal(self) -> None:
        from pong.jobs import record_claim
        from pong.work_graph import find_graph, tick
        g = self._start()
        record_claim("pong-team", g["_jobs"][0]["id"], summary="route:elsewhere nothing matches")
        tick("pong-team")
        f = find_graph("pong-team", g["id"])
        self.assertEqual(f["status"], "done")
        self.assertTrue(f["stop_reason"].startswith("no_edge:"))
        self.assertEqual(f["refusals"][0]["node"], "build")

    def test_the_bundled_example_lints(self) -> None:
        import json
        from pong.loops import _PKG
        from pong.work_graph import lint_topology
        t = lint_topology(json.loads((_PKG / "graphs" / "brain-loop.json").read_text()))
        self.assertEqual(t["start"], "gather"); self.assertEqual(len(t["nodes"]), 5)


if __name__ == "__main__":
    unittest.main()
