#!/usr/bin/env python3
"""A DAG of loops (stage 1): loops found from the topology, each with its own rounds.

- Lint finds agent loops (a header, latches back to it) and person loops (a gate
  whose answer sends the work round again); copies count as one node; a cycle
  with two ways in is loose and keeps per-node caps.
- A round is counted when work crosses a latch; work entering a loop from
  outside opens a fresh activation at round 1 — so a person's reject starts a
  new inner loop instead of inheriting its spent budget.
- At a loop's cap the engine takes the loop's way out, in order: the sender's
  bounded edge, a member's bounded edge out of the loop, the person's gate
  around it; else only that branch ends. It never stops the whole graph.
- A person's answer past the budget is refused (the gate stays open);
  ``extend`` raises it. Only a person raises a budget.
"""
from __future__ import annotations

import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "python"))

S = "pong-team"


def node(g, nid):
    return next(n for n in g["nodes"] if n["id"] == nid)


class LoopDerivationTests(unittest.TestCase):
    def derive(self, topo):
        from pong.graph_engine import lint
        out = lint(topo)
        return {L["id"]: L for L in out["loops"]}, out

    def template(self, name):
        return json.loads((ROOT / "python" / "pong" / "loops" / "graphs" / f"{name}.json").read_text())

    def test_build_verify_is_an_agent_loop_inside_a_person_loop(self) -> None:
        loops, out = self.derive(self.template("build-verify"))
        self.assertEqual(set(loops), {"build", "ship"})
        self.assertEqual(loops["build"]["kind"], "agent")
        self.assertEqual(loops["build"]["parent"], "ship")
        self.assertEqual(loops["ship"]["kind"], "person")
        self.assertIn(["judge", "build"], loops["build"]["latches"])
        self.assertGreater(out["worst_jobs"], 0)

    def test_copies_count_as_one_node_and_a_forward_choice_gate_is_not_a_loop(self) -> None:
        loops, _ = self.derive(self.template("tournament-evolve"))
        self.assertEqual(loops["gen"]["header"], ["gen"])
        self.assertEqual(len([x for x in loops["gen"]["latches"] if x[0] == "meta"]), 4)
        loops, _ = self.derive(self.template("jev-triage"))
        self.assertIn("me", loops)
        self.assertNotIn("choose", loops)  # a gate that only picks the path forward sends nothing round

    def test_a_cycle_with_two_ways_in_is_loose(self) -> None:
        topo = {"start": "a", "nodes": [{"id": "a", "role": "builder"}, {"id": "b", "role": "builder"},
                                        {"id": "c", "role": "critic"}, {"id": "end", "role": "end"}],
                "edges": [{"from": "a", "to": "b"}, {"from": "a", "to": "c"}, {"from": "b", "to": "c"},
                          {"from": "c", "to": "b", "on": "fail"}, {"from": "c", "to": "a", "on": "blocked"},
                          {"from": "c", "to": "end", "on": "win"}]}
        loops, out = self.derive(topo)
        self.assertTrue(any("loose" in w or "single way in" in w for w in out["warnings"]) or "b" not in loops)

    def test_a_topology_can_set_a_loops_rounds(self) -> None:
        topo = self.template("build-verify")
        topo["loops"] = {"build": {"max_iters": 6}, "ship": {"max_iters": 2}}
        loops, _ = self.derive(topo)
        self.assertEqual((loops["build"]["max_iters"], loops["ship"]["max_iters"]), (6, 2))


class LoopRuntimeTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        os.environ["PONG_HOME"] = self.tmp.name
        os.environ["PONG_RUNTIMES"] = "claude,grok,codex,hermes"
        os.environ["PONG_SESSION"] = S
        for k in ("PONG_SEAT", "TYPESAFE_API_KEY", "PONG_JEV_FAKE"):
            os.environ.pop(k, None)
        from pong.jsonutil import write_json
        from pong.paths import active_path, ensure_layout, pairs_path
        from pong.routing import ensure_session_token

        ensure_layout(S)
        pair = {"schema_version": 2,
                "conductor": {"id": "c1", "type": "grok", "label": "Grok", "cmd": "grok", "mode": "tmux", "tmux_index": 0},
                "workers": [{"id": "w2", "type": "claude", "label": "Lead", "cmd": "claude", "tmux_index": 2, "mission_role": "coder"}],
                "transport_default": "job",
                "flow_graph": {"edges": [{"from": "c1", "to": "w2", "kind": "delegate"}, {"from": "w2", "to": "c1", "kind": "claim"}]}}
        write_json(pairs_path(), {S: pair}); active = dict(pair); active["session"] = S; write_json(active_path(), active)
        ensure_session_token(S)

    def tearDown(self) -> None:
        for k in ("PONG_HOME", "PONG_RUNTIMES", "PONG_SESSION", "PONG_TOKEN"):
            os.environ.pop(k, None)
        self.tmp.cleanup()

    def start(self, topo, **kw):
        from pong.work_graph import start
        out = start(S, owner="w2", loop="graph", task="ship it", topology=topo, **kw)
        return out["id"]

    def g(self, gid):
        from pong.work_graph import find_graph
        return find_graph(S, gid)

    def claim(self, gid, nid, summary):
        from pong.jobs import record_claim
        from pong.work_graph import tick
        record_claim(S, node(self.g(gid), nid)["job_id"], summary=summary, files=[])
        tick(S)
        return self.g(gid)

    LOOP = {"start": "build", "max_rounds": 2,
            "nodes": [{"id": "build", "role": "builder", "task": "round {iteration}, {iterations_left} left: {goal}"},
                      {"id": "check", "role": "critic"}, {"id": "ship", "role": "human"}, {"id": "end", "role": "end"}],
            "edges": [{"from": "build", "to": "check"}, {"from": "check", "to": "build", "on": "fail"},
                      {"from": "check", "to": "ship", "on": "win"}, {"from": "ship", "to": "end", "on": "approved"},
                      {"from": "ship", "to": "build", "on": "rejected"}]}

    def spend_inner_loop(self, gid):
        for _ in range(2):
            self.claim(gid, "build", "done")
            g = self.claim(gid, "check", "fail — not yet")
        return g

    def test_the_iteration_reaches_the_prompt(self) -> None:
        from pong.jobs import load_job
        gid = self.start(self.LOOP)
        job = load_job(S, node(self.g(gid), "build")["job_id"])
        self.assertIn("round 1, 1 left", job["task"])

    def test_a_spent_inner_loop_goes_to_the_gate_and_a_reject_starts_a_fresh_one(self) -> None:
        from pong.work_graph import resume
        gid = self.start(self.LOOP)
        g = self.spend_inner_loop(gid)
        self.assertEqual(g["status"], "running")
        self.assertEqual(node(g, "ship")["status"], "waiting_human")
        resume(S, gid, outcome="rejected", note="another approach")
        g = self.g(gid)
        self.assertEqual(node(g, "build")["status"], "running")
        self.assertEqual((g["loops"]["build"]["round"], g["loops"]["build"]["activation"]), (1, 2))
        self.assertEqual(g["loops"]["ship"]["round"], 2)

    def test_a_reject_past_the_gates_budget_is_refused_and_extend_allows_it(self) -> None:
        from pong.work_graph import WorkGraphError, resume
        gid = self.start(self.LOOP)
        self.spend_inner_loop(gid)
        resume(S, gid, outcome="rejected")                    # person round 2 of 2
        self.spend_inner_loop(gid)
        with self.assertRaisesRegex(WorkGraphError, "extend"):
            resume(S, gid, outcome="rejected")                # round 3 would pass the gate's 2
        g = self.g(gid)
        self.assertEqual(g["status"], "running")
        self.assertEqual(node(g, "ship")["status"], "waiting_human")  # the gate stays open
        resume(S, gid, outcome="rejected", extend=1)
        g = self.g(gid)
        self.assertEqual(g["loops"]["ship"]["max_iters"], 3)
        self.assertEqual(node(g, "build")["status"], "running")

    def test_extend_pays_for_the_worst_round_it_allows(self) -> None:
        """One more person round can cost every inner round (2 here × build + check = 4
        jobs), not the fewest; the wall budget rises by those jobs at the step timeout."""
        from pong.work_graph import resume
        topo = json.loads(json.dumps(self.LOOP))
        topo["boundaries"] = {"max_jobs": 40, "max_wall_min": 100, "node_timeout_min": 30}
        gid = self.start(topo)
        self.spend_inner_loop(gid)
        resume(S, gid, outcome="rejected")
        self.spend_inner_loop(gid)
        resume(S, gid, outcome="rejected", extend=1)
        b = self.g(gid)["boundaries"]
        self.assertEqual((b["max_jobs"], b["max_wall_min"]), (44, 220))

    def test_a_reject_needs_room_for_every_round_it_allows(self) -> None:
        """A reject opens up to max_rounds inner rounds (2 here × build + check = 4 jobs); with
        room for only one round it is refused with the --extend command, never accepted and
        then stopped half-way on max_jobs."""
        from pong.work_graph import WorkGraphError, resume
        topo = json.loads(json.dumps(self.LOOP))
        topo["loops"] = {"ship": {"max_iters": 5}}
        gid = self.start(topo)
        self.spend_inner_loop(gid)                         # 4 jobs used, gate open
        from pong.work_graph import load, save
        doc = load(S)
        for g in doc["graphs"]:
            if g.get("id") == gid:
                g["boundaries"] = {**(g.get("boundaries") or {}), "max_jobs": 7}   # room for 3: one round (2), not a whole pass (4)
        save(S, doc)
        with self.assertRaisesRegex(WorkGraphError, "extend"):
            resume(S, gid, outcome="rejected")
        self.assertEqual(node(self.g(gid), "ship")["status"], "waiting_human")

    def test_a_gate_answered_before_any_tick_saw_it_is_still_a_persons_time(self) -> None:
        import time as _t
        from unittest.mock import patch
        from pong.work_graph import resume, snapshot_block, tick
        from pong.jobs import record_claim
        clock = [_t.time()]
        topo = json.loads(json.dumps(self.LOOP))
        topo["boundaries"] = {"max_wall_min": 60}
        with patch("pong.graph_engine._now", side_effect=lambda: clock[0]):
            gid = self.start(topo)
            clock[0] += 5 * 60
            self.claim(gid, "build", "built")
            clock[0] += 5 * 60
            record_claim(S, node(self.g(gid), "check")["job_id"], summary="win — ok", files=[])
            tick(S)                                   # this tick opens the gate; no tick after it
            self.assertEqual(node(self.g(gid), "ship")["status"], "waiting_human")
            clock[0] += 8 * 3600                      # the runner was down all night
            resume(S, gid, outcome="rejected", note="tighten section 3")
            tick(S)
            g = self.g(gid)
            self.assertEqual(g["status"], "running", "the night at the gate is not agent time")
            blk = next(x for x in snapshot_block(S)["graphs"] if x["id"] == gid)
            self.assertEqual(blk["budget"]["wall_min"], 10.0)
            self.assertEqual(blk["budget"]["people_wait_min"], 480.0)
            clock[0] += 60                            # the step the answer started is working
            tick(S)
            blk = next(x for x in snapshot_block(S)["graphs"] if x["id"] == gid)
            self.assertEqual(blk["budget"]["wall_min"], 11.0, "the wait closed when the answer started a step")

    def test_the_note_stands_apart_from_the_step_before_it(self) -> None:
        from pong.jobs import load_job
        from pong.work_graph import resume
        topo = json.loads(json.dumps(self.LOOP))
        topo["nodes"][0]["task"] = "Previous: {prev_summary}"
        gid = self.start(topo)
        self.claim(gid, "build", "built")
        self.claim(gid, "check", "win — clears the bar")
        resume(S, gid, outcome="rejected", note="tighten section 3")
        prompt = Path(load_job(S, node(self.g(gid), "build")["job_id"])["prompt_path"]).read_text()
        self.assertIn("Their note: tighten section 3\n\nBefore that, check said: win — clears the bar", prompt)

    def test_a_gate_after_a_critic_shows_the_work_it_judged(self) -> None:
        from pong.jobs import record_claim
        from pong.work_graph import snapshot_block, tick
        gid = self.start(self.LOOP)
        record_claim(S, node(self.g(gid), "build")["job_id"], summary="built", files=["PLAN.md"])
        tick(S)
        self.claim(gid, "check", "win — ok")
        blk = next(x for x in snapshot_block(S)["graphs"] if x["id"] == gid)
        self.assertEqual(blk["gates"][0]["artifacts"], ["PLAN.md"])

    def test_at_the_cap_the_senders_bounded_edge_comes_first(self) -> None:
        topo = json.loads(json.dumps(self.LOOP))
        topo["nodes"].append({"id": "triage", "role": "human"})
        topo["edges"] += [{"from": "check", "to": "triage", "on": "bounded"}, {"from": "triage", "to": "end", "on": "approved"}]
        gid = self.start(topo)
        g = self.spend_inner_loop(gid)
        self.assertEqual(node(g, "triage")["status"], "waiting_human")
        self.assertNotEqual(node(g, "ship")["status"], "waiting_human")

    def test_with_no_way_out_only_the_branch_ends_and_an_idle_graph_says_why(self) -> None:
        topo = {"start": "build", "max_rounds": 2,
                "nodes": [{"id": "build", "role": "builder"}, {"id": "check", "role": "critic"}, {"id": "end", "role": "end"}],
                "edges": [{"from": "build", "to": "check"}, {"from": "check", "to": "build", "on": "fail"},
                          {"from": "check", "to": "end", "on": "win"}]}
        gid = self.start(topo)
        g = self.spend_inner_loop(gid)
        self.assertEqual(g["status"], "done")
        self.assertEqual(g["stop_reason"], "failed_bounded:rounds")
        self.assertTrue(any(e.get("loop") == "build" for e in g["ends"]))

    def test_an_explicit_max_visits_stays_a_lifetime_cap(self) -> None:
        topo = json.loads(json.dumps(self.LOOP))
        topo["nodes"][0]["max_visits"] = 2
        topo["max_rounds"] = 3
        gid = self.start(topo)
        self.assertEqual(self.g(gid)["loops"]["build"]["max_iters"], 2)

    def test_a_graph_stored_without_loops_runs_as_before(self) -> None:
        from pong.work_graph import _graph_lock, load, save
        gid = self.start(self.LOOP)
        with _graph_lock(S):
            data = load(S)
            for gr in data["graphs"]:
                if gr.get("id") == gid:
                    gr.pop("loops", None)
            save(S, data)
        g = self.spend_inner_loop(gid)
        self.assertEqual(g["status"], "done")  # the old lifetime cap and stop
        self.assertEqual(g["stop_reason"], "failed_bounded:rounds")

    def test_the_snapshot_shows_each_loop_and_each_nodes_round(self) -> None:
        from pong.work_graph import snapshot_block
        gid = self.start(self.LOOP)
        self.claim(gid, "build", "done")
        self.claim(gid, "check", "fail — again")
        blk = snapshot_block(S, full=True)
        gr = next(x for x in blk["graphs"] if x["id"] == gid)
        loops = {L["id"]: L for L in gr["loops"]}
        self.assertEqual(loops["build"]["round"], 2)
        self.assertEqual(next(n for n in gr["nodes"] if n["id"] == "build")["loop"]["round"], 2)


class LoopReviewFixTests(LoopRuntimeTests):
    """Each test pins a finding of the second adversarial review (2026-09-24)."""

    def test_sibling_loops_are_not_found_twice(self) -> None:
        from pong.graph_engine import lint
        topo = {"start": "a", "nodes": [{"id": x, "role": r} for x, r in
                                        (("a", "builder"), ("b", "critic"), ("c", "builder"), ("d", "critic"), ("end", "end"))],
                "edges": [{"from": "a", "to": "b"}, {"from": "b", "to": "a", "on": "fail"}, {"from": "b", "to": "c", "on": "win"},
                          {"from": "c", "to": "d"}, {"from": "d", "to": "c", "on": "fail"}, {"from": "d", "to": "end", "on": "win"}]}
        out = lint(topo)
        ids = [L["id"] for L in out["loops"]]
        self.assertEqual(sorted(ids), ["a", "c"])
        self.assertIsNone(next(L for L in out["loops"] if L["id"] == "c")["parent"])

    def test_a_loop_entered_only_by_a_gates_forward_answer_is_a_loop(self) -> None:
        from pong.graph_engine import lint
        topo = {"start": "plan", "nodes": [{"id": x, "role": r} for x, r in
                (("plan", "writer"), ("g1", "human"), ("build", "builder"), ("crit", "critic"), ("g2", "human"), ("end", "end"))],
                "edges": [{"from": "plan", "to": "g1"}, {"from": "g1", "to": "plan", "on": "rejected"},
                          {"from": "g1", "to": "build", "on": "approved"}, {"from": "build", "to": "crit"},
                          {"from": "crit", "to": "build", "on": "fail"}, {"from": "crit", "to": "g2", "on": "win"},
                          {"from": "g2", "to": "plan", "on": "rejected"}, {"from": "g2", "to": "end", "on": "approved"}]}
        out = lint(topo)
        loops = {L["id"]: L for L in out["loops"]}
        self.assertIn("build", loops)             # not "loose": g1's approval is its way in
        self.assertIn("g2", loops)                # a second gate's reject is a loop of its own
        self.assertEqual(out["uncounted"], [])    # every cycle is counted

    def test_an_uncounted_cycle_keeps_its_per_node_cap(self) -> None:
        topo = {"start": "plan", "max_rounds": 2,
                "nodes": [{"id": "plan", "role": "writer"}, {"id": "build", "role": "builder"},
                          {"id": "crit", "role": "critic"}, {"id": "end", "role": "end"}],
                "edges": [{"from": "plan", "to": "build"}, {"from": "plan", "to": "crit", "on": "blocked"},
                          {"from": "build", "to": "crit"}, {"from": "crit", "to": "build", "on": "fail"},
                          {"from": "crit", "to": "plan", "on": "route:replan"}, {"from": "crit", "to": "end", "on": "win"}]}
        from pong.graph_engine import lint
        self.assertTrue(set(lint(topo)["uncounted"]) >= {"build", "crit"})
        gid = self.start(topo)
        self.claim(gid, "plan", "done")
        for _ in range(4):
            g = self.g(gid)
            if node(g, "build")["status"] != "running":
                break
            self.claim(gid, "build", "done")
            if node(self.g(gid), "crit")["status"] == "running":
                self.claim(gid, "crit", "fail — again")
        self.assertLessEqual(node(self.g(gid), "build")["visits"], 2)  # the lifetime cap still holds

    def test_a_bounded_edge_into_an_outer_header_respects_the_outer_cap(self) -> None:
        topo = {"start": "plan", "max_rounds": 2,
                "nodes": [{"id": "plan", "role": "writer"}, {"id": "build", "role": "builder"}, {"id": "crit", "role": "critic"},
                          {"id": "me", "role": "human"}, {"id": "end", "role": "end"}],
                "edges": [{"from": "plan", "to": "build"}, {"from": "build", "to": "crit"}, {"from": "crit", "to": "build", "on": "fail"},
                          {"from": "crit", "to": "plan", "on": "bounded"}, {"from": "crit", "to": "me", "on": "win"},
                          {"from": "me", "to": "end", "on": "approved"}]}
        gid = self.start(topo)
        plans = 0
        for _ in range(12):
            g = self.g(gid)
            if g["status"] != "running":
                break
            if node(g, "plan")["status"] == "running":
                plans += 1
                self.claim(gid, "plan", "done")
            elif node(g, "build")["status"] == "running":
                self.claim(gid, "build", "done")
            elif node(g, "crit")["status"] == "running":
                self.claim(gid, "crit", "fail — no")
            else:
                break
        self.assertLessEqual(plans, 2)            # the outer loop's 2 rounds, not a plan per spent inner loop
        self.assertEqual(self.g(gid)["status"], "done")

    def test_a_reject_into_a_step_past_its_max_visits_is_refused_and_extend_allows_it(self) -> None:
        from pong.work_graph import WorkGraphError, resume
        topo = json.loads(json.dumps(self.LOOP))
        topo["nodes"][0]["max_visits"] = 2
        topo["max_rounds"] = 3
        gid = self.start(topo)
        self.claim(gid, "build", "done")
        self.claim(gid, "check", "win — ok")
        resume(S, gid, outcome="rejected")
        self.claim(gid, "build", "done")
        self.claim(gid, "check", "win — ok")
        with self.assertRaisesRegex(WorkGraphError, "max_visits"):
            resume(S, gid, outcome="rejected")
        self.assertEqual(self.g(gid)["status"], "running")
        resume(S, gid, outcome="rejected", extend=1)
        self.assertEqual(node(self.g(gid), "build")["status"], "running")

    def test_a_fan_in_to_a_running_header_is_a_merge_not_a_round(self) -> None:
        topo = {"start": "build", "max_rounds": 3,
                "nodes": [{"id": "build", "role": "builder"}, {"id": "judge", "role": "critic", "count": 2},
                          {"id": "ship", "role": "human"}, {"id": "end", "role": "end"}],
                "edges": [{"from": "build", "to": "judge"}, {"from": "judge", "to": "build", "on": "fail"},
                          {"from": "judge", "to": "ship", "on": "win"}, {"from": "ship", "to": "end", "on": "approved"}]}
        gid = self.start(topo)
        self.claim(gid, "build", "done")
        self.claim(gid, "judge#1", "fail — a")
        self.claim(gid, "judge#2", "fail — b")   # build is already running again: merged
        self.assertEqual(self.g(gid)["loops"]["build"]["round"], 2)

    def test_bad_loop_settings_are_refused(self) -> None:
        from pong.graph_engine import lint
        from pong.work_graph import WorkGraphError
        topo = json.loads(json.dumps(self.LOOP))
        topo["loops"] = {"build": {"max_iters": 0}}
        with self.assertRaisesRegex(WorkGraphError, "max_iters"):
            lint(topo)
        topo["loops"] = {"bulid": {"max_iters": 3}}
        with self.assertRaisesRegex(WorkGraphError, "no loop has that id"):
            lint(topo)


if __name__ == "__main__":
    unittest.main()
