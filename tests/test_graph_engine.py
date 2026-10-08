#!/usr/bin/env python3
"""The graph runtime's semantics, each pinned by the failure that motivated it.

- A win takes the win edge only (a done edge beside it no longer fires too).
- A critic that claims without a verdict is refused and counted as fail.
- A graph that starts at a gate can be approved (it could not in 1.6).
- A join waits for every branch (``all``) or the first (``any``).
- Two gates can be open at once; resume names one.
- A pause holds dispatches but still harvests finished work.
- Lost work is retried once, then fails.
- Budgets stop the graph and say why; a dispatch that raises does not wedge it.
- ``count`` makes K copies; the prompt says which words end the step.
"""
from __future__ import annotations

import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "python"))

S = "pong-team"


def node(g, nid):
    return next(n for n in g["nodes"] if n["id"] == nid)


class GraphEngineTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        os.environ["PONG_HOME"] = self.tmp.name
        os.environ["PONG_RUNTIMES"] = "claude,grok,codex,hermes"
        os.environ["PONG_SESSION"] = S
        os.environ.pop("PONG_SEAT", None)
        os.environ.pop("TYPESAFE_API_KEY", None)
        os.environ.pop("PONG_JEV_FAKE", None)
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

    # helpers
    def start(self, topo, task="ship it", **kw):
        from pong.work_graph import start
        return start(S, owner="w2", loop="graph", task=task, topology=topo, **kw)

    def g(self, gid):
        from pong.work_graph import find_graph
        return find_graph(S, gid)

    def claim(self, gid, nid, summary, files=None):
        from pong.jobs import record_claim
        from pong.work_graph import tick
        jid = node(self.g(gid), nid)["job_id"]
        record_claim(S, jid, summary=summary, files=files or [])
        tick(S)
        return self.g(gid)

    # 1
    def test_a_win_takes_the_win_edge_only(self) -> None:
        topo = {"start": "c", "nodes": [{"id": "c", "role": "critic"}, {"id": "design", "role": "writer"},
                                        {"id": "build", "role": "builder"}, {"id": "end", "role": "end"}],
                "edges": [{"from": "c", "to": "design", "on": "fail"}, {"from": "c", "to": "design", "on": "done"},
                          {"from": "c", "to": "build", "on": "win"}, {"from": "design", "to": "end"}, {"from": "build", "to": "end"}]}
        g = self.start(topo)
        f = self.claim(g["id"], "c", "win — clears the bar")
        self.assertEqual(node(f, "build")["status"], "running")
        self.assertEqual(node(f, "design")["status"], "pending", "the done edge must not also fire on a win")

    # 2
    def test_a_critic_without_a_verdict_is_refused_and_fails(self) -> None:
        topo = {"start": "b", "nodes": [{"id": "b", "role": "builder"}, {"id": "c", "role": "critic"}, {"id": "ok", "role": "human"},
                                        {"id": "end", "role": "end"}],
                "edges": [{"from": "b", "to": "c"}, {"from": "c", "to": "b", "on": "fail"}, {"from": "c", "to": "ok", "on": "win"},
                          {"from": "ok", "to": "end", "on": "approved"}]}
        g = self.start(topo)
        self.claim(g["id"], "b", "built it")
        f = self.claim(g["id"], "c", "looked at it, seems fine")
        self.assertEqual(node(f, "b")["visits"], 2, "an empty verdict is a fail: back to the builder")
        self.assertEqual(f["refusals"][-1]["node"], "c")
        self.assertIn("without saying win or fail", f["refusals"][-1]["reason"])
        self.assertEqual(f["status"], "running")

    # 3
    def test_summary_parsing_is_tolerant_but_strict_about_the_word(self) -> None:
        from pong.graph_engine import parse_summary
        cases = {"**WIN** — ok": "win", "`win`": "win", "> Win: all green": "win", "fail: tests red": "fail",
                 "Failed — no tests": "fail", "rejected, see notes": "fail", "route: high priority": "route:high",
                 "Windows build fixed": None, "Failover added": None, "winner picked": None, "": None}
        for text, want in cases.items():
            self.assertEqual(parse_summary(text), want, text)

    # 4
    def test_a_graph_that_starts_at_a_gate_can_be_approved(self) -> None:
        from pong.work_graph import resume
        topo = {"start": "me", "nodes": [{"id": "me", "role": "human"}, {"id": "write", "role": "writer"}, {"id": "done", "role": "join"}],
                "edges": [{"from": "me", "to": "done", "on": "approved"}, {"from": "me", "to": "write", "on": "rejected"},
                          {"from": "write", "to": "me"}]}
        g = self.start(topo)
        self.assertEqual(node(g, "me")["status"], "waiting_human")
        self.assertTrue(g["paused"] and g["paused"]["gate"], "older readers see the gate on paused")
        f = resume(S, g["id"], outcome="approved")
        self.assertEqual(f["status"], "done")
        self.assertEqual(f["stop_reason"], "win")

    def test_the_1_6_record_shape_of_a_start_gate_resumes_too(self) -> None:
        """A 1.6 team's gate graph: human start, paused None, no gate record."""
        from pong.work_graph import load, resume, save
        g = self.start({"start": "me", "nodes": [{"id": "me", "role": "human"}, {"id": "done", "role": "join"}],
                        "edges": [{"from": "me", "to": "done", "on": "approved"}]})
        data = load(S)
        rec = next(x for x in data["graphs"] if x["id"] == g["id"])
        rec["paused"] = None
        node(rec, "me").pop("gate", None)
        save(S, data)
        f = resume(S, g["id"], outcome="approved")
        self.assertEqual((f["status"], f["stop_reason"]), ("done", "win"))

    def test_a_1_6_gate_on_paused_is_migrated(self) -> None:
        from pong.work_graph import load, resume, save
        topo = {"start": "b", "nodes": [{"id": "b", "role": "builder"}, {"id": "ok", "role": "human"}, {"id": "end", "role": "end"}],
                "edges": [{"from": "b", "to": "ok"}, {"from": "ok", "to": "end", "on": "approved"}]}
        g = self.start(topo)
        data = load(S)
        rec = next(x for x in data["graphs"] if x["id"] == g["id"])
        node(rec, "b")["status"] = "done"
        node(rec, "ok")["status"] = "waiting_human"
        rec["paused"] = {"at": 1, "reason": "b finished", "next_node": "ok", "prev": {"summary": "x"}, "gate": True}
        save(S, data)
        f = resume(S, g["id"], outcome="approved")
        self.assertEqual((f["status"], f["stop_reason"]), ("done", "win"))

    # 5
    def fan(self, wait="all"):
        return {"start": "split",
                "nodes": [{"id": "split", "role": "scout"}, {"id": "a", "role": "researcher", "task": "A: {prev_summary}"},
                          {"id": "b", "role": "researcher"}, {"id": "j", "role": "join", "wait": wait},
                          {"id": "final", "role": "writer", "task": "merge: {prev_summary} | {prev_artifacts}"},
                          {"id": "end", "role": "end"}],
                "edges": [{"from": "split", "to": "a"}, {"from": "split", "to": "b"}, {"from": "a", "to": "j"},
                          {"from": "b", "to": "j"}, {"from": "j", "to": "final"}, {"from": "final", "to": "end"}]}

    def test_a_join_waits_for_every_branch_and_merges_them(self) -> None:
        from pong.jobs import load_job
        g = self.start(self.fan())
        f = self.claim(g["id"], "split", "split into two")
        self.assertEqual((node(f, "a")["status"], node(f, "b")["status"]), ("running", "running"), "fan-out: both edges run")
        f = self.claim(g["id"], "a", "found A", files=["a.md"])
        self.assertEqual(node(f, "j")["status"], "waiting")
        self.assertEqual(node(f, "final")["status"], "pending", "b is still running; the barrier holds")
        f = self.claim(g["id"], "b", "found B", files=["b.md"])
        final = node(f, "final")
        self.assertEqual(final["status"], "running")
        task = load_job(S, final["job_id"])["task"]
        self.assertIn("found A", task); self.assertIn("found B", task); self.assertIn("a.md", task); self.assertIn("b.md", task)
        f = self.claim(g["id"], "final", "merged")
        self.assertEqual((f["status"], f["stop_reason"]), ("done", "done"))

    def test_a_join_on_any_takes_the_first_and_cancels_the_rest(self) -> None:
        from pong.jobs import load_job
        g = self.start(self.fan("any"))
        f = self.claim(g["id"], "split", "go")
        b_job = node(f, "b")["job_id"]
        f = self.claim(g["id"], "a", "A first")
        self.assertEqual(node(f, "final")["status"], "running")
        self.assertEqual(node(f, "b")["status"], "cancelled")
        self.assertEqual(load_job(S, b_job)["status"], "cancelled")

    # 6
    def test_a_join_with_a_timeout_goes_ahead_without_the_slow_branch(self) -> None:
        import time as _t
        from pong.work_graph import load, save, tick
        topo = self.fan()
        for n in topo["nodes"]:
            if n["id"] == "j":
                n["timeout_min"] = 1
        g = self.start(topo)
        self.claim(g["id"], "split", "go")
        f = self.claim(g["id"], "a", "A done")
        self.assertEqual(node(f, "final")["status"], "pending")
        data = load(S)
        rec = next(x for x in data["graphs"] if x["id"] == g["id"])
        node(rec, "j")["arrivals"][0]["at"] = _t.time() - 120
        save(S, data)
        tick(S)
        f = self.g(g["id"])
        self.assertEqual(node(f, "final")["status"], "running")
        self.assertEqual(node(f, "b")["status"], "cancelled")

    def test_two_gates_can_be_open_and_resume_names_one(self) -> None:
        from pong.work_graph import WorkGraphError, resume
        topo = {"start": "split", "nodes": [{"id": "split", "role": "scout"}, {"id": "x", "role": "writer"}, {"id": "y", "role": "writer"},
                                            {"id": "gx", "role": "human"}, {"id": "gy", "role": "human"}, {"id": "end", "role": "end"}],
                "edges": [{"from": "split", "to": "x"}, {"from": "split", "to": "y"}, {"from": "x", "to": "gx"}, {"from": "y", "to": "gy"},
                          {"from": "gx", "to": "end", "on": "approved"}, {"from": "gy", "to": "end", "on": "approved"}]}
        g = self.start(topo)
        self.claim(g["id"], "split", "go")
        self.claim(g["id"], "x", "draft x")
        f = self.claim(g["id"], "y", "draft y")
        self.assertEqual({n["id"] for n in f["nodes"] if n["status"] == "waiting_human"}, {"gx", "gy"})
        with self.assertRaises(WorkGraphError):
            resume(S, g["id"], outcome="approved")
        f = resume(S, g["id"], outcome="approved", node="gx")
        self.assertEqual(f["status"], "running", "gy still waits")
        f = resume(S, g["id"], outcome="approved")
        self.assertEqual((f["status"], f["stop_reason"]), ("done", "win"))

    # 7
    def test_a_pause_holds_dispatch_but_harvests(self) -> None:
        from pong.work_graph import pause, resume
        topo = {"start": "a", "nodes": [{"id": "a", "role": "builder"}, {"id": "b", "role": "critic"}, {"id": "end", "role": "end"}],
                "edges": [{"from": "a", "to": "b"}, {"from": "b", "to": "end", "on": "win"}, {"from": "b", "to": "a", "on": "fail"}]}
        g = self.start(topo)
        pause(S, g["id"])
        f = self.claim(g["id"], "a", "built")
        self.assertEqual(node(f, "a")["status"], "done", "finished work is harvested while paused")
        self.assertEqual(node(f, "b")["status"], "held")
        self.assertIsNone(node(f, "b")["job_id"])
        f = resume(S, g["id"])
        self.assertEqual(node(f, "b")["status"], "running")
        f = self.claim(g["id"], "b", "win")
        self.assertEqual(f["stop_reason"], "win")

    # 8
    def test_lost_work_is_retried_once_then_fails(self) -> None:
        from pong.jobs import set_status
        from pong.work_graph import tick
        topo = {"start": "a", "nodes": [{"id": "a", "role": "operator"}, {"id": "fix", "role": "builder"}, {"id": "end", "role": "end"}],
                "edges": [{"from": "a", "to": "end"}, {"from": "a", "to": "fix", "on": "fail"}, {"from": "fix", "to": "end"}]}
        g = self.start(topo)
        first = node(self.g(g["id"]), "a")["job_id"]
        set_status(S, first, "cancelled", skip_snapshot=True, cancel_reason="stale_notified")
        tick(S)
        f = self.g(g["id"])
        a = node(f, "a")
        self.assertEqual(a["status"], "running"); self.assertNotEqual(a["job_id"], first)
        self.assertEqual((a["visits"], a["retry_count"]), (1, 1), "a retry is not a new visit")
        set_status(S, a["job_id"], "cancelled", skip_snapshot=True, cancel_reason="stale_notified")
        tick(S)
        f = self.g(g["id"])
        self.assertEqual(node(f, "fix")["status"], "pending", "a lost seat is not a fail verdict: the fail edge stays shut")
        self.assertEqual(node(f, "a")["status"], "failed")
        self.assertEqual((f["status"], f["stop_reason"]), ("done", "error:a"))

    def test_an_error_edge_takes_lost_work_and_retry_revives_it(self) -> None:
        from pong.jobs import set_status
        from pong.work_graph import retry, tick
        topo = {"start": "a", "nodes": [{"id": "a", "role": "operator", "retries": 0}, {"id": "ask", "role": "human"},
                                        {"id": "end", "role": "end"}],
                "edges": [{"from": "a", "to": "end"}, {"from": "a", "to": "ask", "on": "error"}, {"from": "ask", "to": "end", "on": "approved"}]}
        g = self.start(topo)
        set_status(S, node(self.g(g["id"]), "a")["job_id"], "cancelled", skip_snapshot=True, cancel_reason="stale_running")
        tick(S)
        f = self.g(g["id"])
        self.assertEqual(node(f, "ask")["status"], "waiting_human", "error went to the person")
        f = retry(S, g["id"], "a")
        self.assertEqual(node(f, "a")["status"], "running")

    # 9
    def test_a_job_budget_stops_the_graph_and_cancels_what_runs(self) -> None:
        topo = {"start": "a", "max_rounds": 5, "boundaries": {"max_jobs": 2},
                "nodes": [{"id": "a", "role": "builder"}, {"id": "b", "role": "critic"}],
                "edges": [{"from": "a", "to": "b"}, {"from": "b", "to": "a", "on": "fail"}]}
        g = self.start(topo)
        self.claim(g["id"], "a", "v1")
        f = self.claim(g["id"], "b", "fail")
        self.assertEqual((f["status"], f["stop_reason"]), ("done", "failed_bounded:jobs"))

    def test_a_dispatch_that_raises_is_a_refusal_not_a_wedge(self) -> None:
        from pong import work_graph as W
        topo = {"start": "a", "nodes": [{"id": "a", "role": "builder"}, {"id": "b", "role": "critic"}],
                "edges": [{"from": "a", "to": "b"}]}
        g = self.start(topo)
        real = W._create_work_job

        def boom(*a, **k):
            if k.get("node_id") == "b":
                raise W.WorkGraphError("no pane for you")
            return real(*a, **k)

        with patch.object(W, "_create_work_job", boom):
            f = self.claim(g["id"], "a", "built")
        self.assertEqual(node(f, "b")["status"], "failed")
        self.assertIn("dispatch failed", f["refusals"][-1]["reason"])
        self.assertEqual(f["status"], "done", "nothing is in flight, so the graph ends and says why")

    # 10
    def test_count_makes_copies_with_their_own_pins(self) -> None:
        topo = {"start": "gen", "nodes": [{"id": "gen", "role": "builder", "count": 3, "pins": ["claude", "grok"],
                                           "task": "candidate {copy} for {goal}"},
                                          {"id": "j", "role": "join"}, {"id": "rank", "role": "critic"}, {"id": "end", "role": "end"}],
                "edges": [{"from": "gen", "to": "j"}, {"from": "j", "to": "rank"}, {"from": "rank", "to": "end", "on": "win"},
                          {"from": "rank", "to": "gen", "on": "fail"}]}
        g = self.start(topo)
        gens = [n for n in g["nodes"] if n.get("copy_of") == "gen"]
        self.assertEqual([n["id"] for n in gens], ["gen#1", "gen#2", "gen#3"])
        self.assertTrue(all(n["status"] == "running" for n in gens), "every copy starts")
        self.assertEqual(g["pins"]["gen#2"], "grok")
        self.assertEqual(len({n["seat"] for n in gens}), 3, "each copy on its own seat")
        self.assertIn("candidate 1/3", g["_jobs"][0]["_prompt"])
        f = g
        for n in gens:
            f = self.claim(g["id"], n["id"], f"candidate from {n['id']}")
        self.assertEqual(node(f, "rank")["status"], "running")

    # 11
    def test_the_prompt_says_how_the_step_ends(self) -> None:
        from pong.jobs import load_job
        topo = {"start": "b", "nodes": [{"id": "b", "role": "builder", "task": "{goal} (round {round}) {history}"},
                                        {"id": "c", "role": "critic"}, {"id": "end", "role": "end"}],
                "edges": [{"from": "b", "to": "c"}, {"from": "c", "to": "b", "on": "fail"}, {"from": "c", "to": "end", "on": "win"}]}
        g = self.start(topo, task="make {round} literal")
        first = g["_jobs"][0]["_prompt"]
        self.assertIn("make {round} literal (round 1)", first, "a brace in the goal is left as written")
        self.assertIn("Shared notes for this graph", first)
        self.assertTrue(Path(g["notes_path"]).exists())
        f = self.claim(g["id"], "b", "built")
        prompt = Path(load_job(S, node(f, "c")["job_id"])["prompt_path"]).read_text()
        self.assertIn("must begin with one of: `fail` → b · `win` → end", prompt)
        self.assertIn("When, and only when, the work is finished", prompt)

    # 12
    def test_lint_warns_about_shapes_that_misbehave(self) -> None:
        from pong.work_graph import lint_topology
        t = lint_topology({"start": "b", "nodes": [{"id": "b", "role": "builder"}, {"id": "c", "role": "critic"}],
                           "edges": [{"from": "b", "to": "c"}]})
        text = " ".join(t["warnings"])
        self.assertIn("no fail edge", text); self.assertIn("no human gate", text)

    def test_the_snapshot_carries_what_the_map_draws(self) -> None:
        from pong.work_graph import snapshot_block
        topo = {"start": "b", "boundaries": {"max_wall_min": 90},
                "nodes": [{"id": "b", "role": "builder"}, {"id": "ok", "role": "human"}, {"id": "end", "role": "end"}],
                "edges": [{"from": "b", "to": "ok"}, {"from": "ok", "to": "end", "on": "approved"}]}
        g = self.start(topo)
        self.claim(g["id"], "b", "built", files=["x.py"])
        blk = next(x for x in snapshot_block(S)["graphs"] if x["id"] == g["id"])
        self.assertEqual(blk["gates"][0]["node"], "ok")
        self.assertIn("x.py", blk["gates"][0]["artifacts"])
        self.assertEqual(blk["budget"]["max_wall_min"], 90)
        self.assertEqual(blk["budget"]["jobs"], 1)
        b = next(n for n in blk["nodes"] if n["id"] == "b")
        self.assertEqual((b["visits"], b["last_outcome"], b["runtime"]), (1, "done", "claude"))
        self.assertTrue(any(r["event"] == "gate_open" for r in blk["recent"]))


    def test_a_gate_left_overnight_does_not_spend_the_wall_budget(self) -> None:
        """max_wall_min bounds agent work: a gate answered ten hours later must not
        stop the graph, and the budget still stops agent work that runs long."""
        from pong.work_graph import resume, snapshot_block, tick
        import time as _t
        clock = [_t.time()]
        topo = {"start": "b", "boundaries": {"max_wall_min": 30},
                "nodes": [{"id": "b", "role": "builder"}, {"id": "ok", "role": "human"}, {"id": "end", "role": "end"}],
                "edges": [{"from": "b", "to": "ok"}, {"from": "ok", "to": "b", "on": "rejected"},
                          {"from": "ok", "to": "end", "on": "approved"}]}
        with patch("pong.graph_engine._now", side_effect=lambda: clock[0]):
            g = self.start(topo)
            clock[0] += 10 * 60
            f = self.claim(g["id"], "b", "built")
            self.assertEqual(node(f, "ok")["status"], "waiting_human")
            tick(S)
            clock[0] += 10 * 3600
            tick(S)
            f = self.g(g["id"])
            self.assertEqual(f["status"], "running", "a person's night at the gate is not agent time")
            blk = next(x for x in snapshot_block(S)["graphs"] if x["id"] == g["id"])
            self.assertEqual(blk["budget"]["wall_min"], 10.0)
            self.assertEqual(blk["budget"]["people_wait_min"], 600.0)
            resume(S, g["id"], outcome="rejected")
            tick(S)
            self.assertEqual(node(self.g(g["id"]), "b")["status"], "running")
            clock[0] += 15 * 60
            tick(S)
            self.assertEqual(self.g(g["id"])["status"], "running", "25 minutes of work is inside a 30-minute budget")
            clock[0] += 10 * 60
            tick(S)
            f = self.g(g["id"])
            self.assertEqual((f["status"], f["stop_reason"]), ("done", "failed_bounded:wall"))

    def test_a_manual_pause_with_nothing_running_is_people_time(self) -> None:
        from pong.graph_engine import _people_only
        g = {"nodes": [{"id": "b", "status": "held"}], "paused": {"manual": True}}
        self.assertTrue(_people_only(g))
        g["nodes"].append({"id": "c", "status": "running"})
        self.assertFalse(_people_only(g), "a step still running is agent time, paused or not")
        self.assertFalse(_people_only({"nodes": [{"id": "j", "status": "waiting"}], "paused": None}))


    def test_a_writer_is_told_its_normal_claim_goes_on_and_fail_is_only_for_when_it_could_not(self) -> None:
        from pong.jobs import load_job
        topo = {"start": "w", "nodes": [{"id": "w", "role": "writer"}, {"id": "c", "role": "critic"},
                                        {"id": "me", "role": "human"}, {"id": "end", "role": "end"}],
                "edges": [{"from": "w", "to": "c", "on": "done"}, {"from": "w", "to": "me", "on": "fail"},
                          {"from": "w", "to": "me", "on": "abstain"}, {"from": "c", "to": "w", "on": "fail"},
                          {"from": "c", "to": "me", "on": "win"}, {"from": "me", "to": "end", "on": "approved"}]}
        g = self.start(topo)
        prompt = Path(load_job(S, node(g, "w")["job_id"])["prompt_path"]).read_text()
        self.assertIn("with no verdict word: it goes on to c", prompt)
        self.assertIn("Only if you could not do the step, start the claim summary with one of: `fail` → me", prompt)
        self.assertNotIn("must begin with one of", prompt)
        f = self.claim(g["id"], "w", "PLAN.md — the first full plan")
        self.assertEqual(node(f, "c")["status"], "running", "a path-first claim goes on to the critic")
        self.assertEqual(f["refusals"], [])
        prompt = Path(load_job(S, node(f, "c")["job_id"])["prompt_path"]).read_text()
        self.assertIn("must begin with one of", prompt)  # a critic still owes a verdict

    def test_a_critics_longer_list_reaches_the_writer_with_the_files_it_judged(self) -> None:
        from pong.jobs import load_job, record_claim
        from pong.work_graph import tick
        topo = {"start": "w", "nodes": [{"id": "w", "role": "writer", "task": "Prev: {prev_summary}\nFiles: {prev_artifacts}"},
                                        {"id": "c", "role": "critic"}, {"id": "end", "role": "end"}],
                "edges": [{"from": "w", "to": "c"}, {"from": "c", "to": "w", "on": "fail"}, {"from": "c", "to": "end", "on": "win"}]}
        g = self.start(topo)
        record_claim(S, node(g, "w")["job_id"], summary="done", files=["PLAN.md"])
        tick(S)
        long = "fail — " + " ".join(f"point {i}: section {i} needs a table." for i in range(60))
        f = self.claim(g["id"], "c", long)
        prompt = Path(load_job(S, node(f, "w")["job_id"])["prompt_path"]).read_text()
        self.assertIn("point 45: section 45", prompt, "a critic's list is kept past 600 characters")
        self.assertIn("Files: PLAN.md", prompt, "the revision names the files the critic judged")

    def test_a_graph_can_start_its_seats_without_live_tools(self) -> None:
        from pong.groups import _launch_command
        from pong.work_graph import _synthetic_worker
        w = _synthetic_worker("w2.a", "w2", "researcher", boundaries={"live_tools": False})
        self.assertTrue(w["no_live_tools"])
        self.assertFalse(_synthetic_worker("w2.b", "w2", "researcher", boundaries={})["no_live_tools"])
        c = _launch_command({"session": S}, {**w, "type": "claude", "cmd": "claude"}, initial_prompt="go")
        self.assertIn("export ENABLE_CLAUDEAI_MCP_SERVERS=false", c)
        self.assertIn("--strict-mcp-config", c)
        g = _launch_command({"session": S}, {**w, "type": "grok", "cmd": "grok"}, initial_prompt="go")
        self.assertIn("--deny MCPTool", g)
        plain = _launch_command({"session": S}, {"id": "w2.c", "type": "claude", "cmd": "claude"}, initial_prompt="go")
        self.assertNotIn("strict-mcp-config", plain)
        self.assertIn("Bash(git push:*)", c)            # no shell route to a remote either
        self.assertIn("Bash(git commit:*)", c)          # and no writes to a repository it only reads
        self.assertNotIn("Bash(git log", c)             # reading history stays open
        self.assertIn("Bash(git -C:*)", c)              # a write aimed at another repository with -C is refused too
        self.assertIn("Bash(npx:*)", c)                 # nothing fetched from the internet to run
        self.assertIn("Bash(pip install:*)", c)
        self.assertIn("--deny 'Bash(supabase*)'", g)
        self.assertNotIn("disallowedTools", plain)

    def test_a_family_pick_is_not_called_a_persons_pin(self) -> None:
        from pong.jobs import load_job
        topo = {"start": "w", "nodes": [{"id": "w", "role": "writer"}, {"id": "c", "role": "critic", "family": "different"},
                                        {"id": "end", "role": "end"}],
                "edges": [{"from": "w", "to": "c"}, {"from": "c", "to": "w", "on": "fail"}, {"from": "c", "to": "end", "on": "win"}]}
        g = self.start(topo)
        f = self.claim(g["id"], "w", "written")
        prompt = Path(load_job(S, node(f, "c")["job_id"])["prompt_path"]).read_text()
        self.assertNotIn("Pinned by you", prompt)
        self.assertIn("Another model family", prompt)

    def test_a_graph_step_is_scoped_by_its_task_not_the_teams_old_brief(self) -> None:
        from pong.jobs import load_job
        from pong.jsonutil import read_json, write_json
        from pong.paths import pairs_path
        pairs = read_json(pairs_path()) or {}
        pairs[S]["team_brief"] = "Stage grade: read JEV-SPEC.md against the ten sections."
        write_json(pairs_path(), pairs)
        topo = {"start": "w", "nodes": [{"id": "w", "role": "writer"}, {"id": "end", "role": "end"}],
                "edges": [{"from": "w", "to": "end"}]}
        g = self.start(topo)
        prompt = Path(load_job(S, node(g, "w")["job_id"])["prompt_path"]).read_text()
        self.assertNotIn("JEV-SPEC.md", prompt)
        self.assertIn("your task below is the scope", prompt)
        self.assertNotIn("Another product/repo is a STOP", prompt)
        self.assertIn("Mission role (locked): Writer", prompt)
        self.assertNotIn("role=coder", prompt)            # the architecture recap agrees with the identity

class GraphEngineMoreTests(GraphEngineTests):
    """Research-driven semantics: checks, abstain, bounded edges, panels, notes."""

    def test_a_check_node_runs_commands_and_the_exit_code_decides(self) -> None:
        import time as _t
        from pong.work_graph import tick
        root = Path(self.tmp.name) / "proj"
        root.mkdir()
        (root / "ok.txt").write_text("x")
        topo = {"start": "b", "nodes": [{"id": "b", "role": "builder"},
                                        {"id": "t", "role": "check", "cwd": str(root), "run": ["test -f ok.txt", "echo hi"]},
                                        {"id": "end", "role": "end"}],
                "edges": [{"from": "b", "to": "t"}, {"from": "t", "to": "end", "on": "win"}, {"from": "t", "to": "b", "on": "fail"}]}
        g = self.start(topo)
        f = self.claim(g["id"], "b", "built")
        self.assertIn(node(f, "t")["status"], ("running", "done"), "the check started")
        for _ in range(60):
            _t.sleep(0.05)
            tick(S)
            f = self.g(g["id"])
            if f["status"] != "running":
                break
        self.assertEqual((f["status"], f["stop_reason"]), ("done", "win"))
        self.assertTrue(Path(node(f, "t")["check_log"]).read_text().count("exit 0") == 2)

    def test_a_failing_check_twice_the_same_way_is_no_progress(self) -> None:
        import time as _t
        from pong.work_graph import tick
        root = Path(self.tmp.name) / "proj2"
        root.mkdir()
        topo = {"start": "b", "max_rounds": 5,
                "nodes": [{"id": "b", "role": "builder"}, {"id": "t", "role": "check", "cwd": str(root), "run": ["test -f missing.txt"]}],
                "edges": [{"from": "b", "to": "t"}, {"from": "t", "to": "b", "on": "fail"}]}
        g = self.start(topo)

        def settle():
            for _ in range(60):
                _t.sleep(0.05)
                tick(S)
                f = self.g(g["id"])
                if node(f, "t")["status"] != "running":
                    return f
            return self.g(g["id"])
        self.claim(g["id"], "b", "v1")
        f = settle()
        self.assertEqual(node(f, "b")["visits"], 2, "first failure goes back to the builder")
        self.claim(g["id"], "b", "v2")
        f = settle()
        self.assertEqual((f["status"], f["stop_reason"]), ("done", "failed_bounded:no_progress"))

    def test_a_protected_file_changed_by_the_builder_fails_the_check(self) -> None:
        import time as _t
        from pong.work_graph import tick
        root = Path(self.tmp.name) / "proj3"
        root.mkdir()
        (root / "test_x.py").write_text("assert True\n")
        topo = {"start": "b", "protect": ["test_x.py"],
                "nodes": [{"id": "b", "role": "builder"}, {"id": "t", "role": "check", "cwd": str(root), "run": ["true"]},
                          {"id": "end", "role": "end"}],
                "edges": [{"from": "b", "to": "t"}, {"from": "t", "to": "end", "on": "win"}, {"from": "t", "to": "b", "on": "fail"}]}
        with patch("pong.graph_engine._project_root", return_value=str(root)):
            g = self.start(topo)
            (root / "test_x.py").write_text("# the builder weakened the test\n")
            self.claim(g["id"], "b", "all green now")
            for _ in range(60):
                _t.sleep(0.05)
                tick(S)
                if node(self.g(g["id"]), "t")["status"] != "running":
                    break
        f = self.g(g["id"])
        self.assertIn("protected files changed", f["refusals"][-1]["reason"])
        self.assertEqual(node(f, "b")["visits"], 2, "tampering is a fail: back to the builder")

    def test_abstain_takes_its_own_edge(self) -> None:
        topo = {"start": "c", "nodes": [{"id": "c", "role": "critic"}, {"id": "ask", "role": "human"}, {"id": "b", "role": "builder"},
                                        {"id": "end", "role": "end"}],
                "edges": [{"from": "c", "to": "end", "on": "win"}, {"from": "c", "to": "b", "on": "fail"},
                          {"from": "c", "to": "ask", "on": "abstain"}, {"from": "ask", "to": "end", "on": "approved"}]}
        g = self.start(topo)
        f = self.claim(g["id"], "c", "Abstain — the brief was not in the artifacts")
        self.assertEqual(node(f, "ask")["status"], "waiting_human")
        self.assertEqual(node(f, "b")["status"], "pending")

    def test_a_limit_takes_the_bounded_edge_to_a_person(self) -> None:
        topo = {"start": "b", "max_rounds": 2,
                "nodes": [{"id": "b", "role": "builder"}, {"id": "c", "role": "critic"}, {"id": "ask", "role": "human"},
                          {"id": "end", "role": "end"}],
                "edges": [{"from": "b", "to": "c"}, {"from": "c", "to": "b", "on": "fail"}, {"from": "c", "to": "end", "on": "win"},
                          {"from": "c", "to": "ask", "on": "bounded"}, {"from": "ask", "to": "end", "on": "approved"}]}
        g = self.start(topo)
        for _ in range(2):
            self.claim(g["id"], "b", "try")
            f = self.claim(g["id"], "c", "fail")
        self.assertEqual(f["status"], "running", "the limit did not stop the graph")
        self.assertEqual(node(f, "ask")["status"], "waiting_human")

    def test_a_judge_panel_passes_on_majority(self) -> None:
        topo = {"start": "judge", "nodes": [{"id": "judge", "role": "critic", "count": 3}, {"id": "j", "role": "join", "pass": "majority"},
                                            {"id": "ok", "role": "end"}, {"id": "no", "role": "end"}],
                "edges": [{"from": "judge", "to": "j", "on": "win"}, {"from": "judge", "to": "j", "on": "fail"},
                          {"from": "j", "to": "ok", "on": "win"}, {"from": "j", "to": "no", "on": "fail"}]}
        g = self.start(topo)
        self.claim(g["id"], "judge#1", "win")
        self.claim(g["id"], "judge#2", "fail — missing tests")
        f = self.claim(g["id"], "judge#3", "win")
        self.assertEqual(node(f, "ok")["status"], "ready")
        self.assertEqual(node(f, "no")["status"], "pending")

    def test_a_critic_does_not_see_the_builders_account(self) -> None:
        from pong.jobs import load_job
        topo = {"start": "b", "nodes": [{"id": "b", "role": "builder"},
                                        {"id": "c", "role": "critic", "task": "grade {prev_artifacts}; builder says {prev_summary}"},
                                        {"id": "end", "role": "end"}],
                "edges": [{"from": "b", "to": "c"}, {"from": "c", "to": "end", "on": "win"}, {"from": "c", "to": "b", "on": "fail"}]}
        g = self.start(topo)
        f = self.claim(g["id"], "b", "I am confident this is perfect", files=["out.md"])
        task = load_job(S, node(f, "c")["job_id"])["task"]
        self.assertIn("out.md", task)
        self.assertNotIn("confident", task)

    def test_a_person_rejects_with_a_note_that_reaches_the_next_step(self) -> None:
        from pong.jobs import load_job
        from pong.work_graph import WorkGraphError, resume
        topo = {"start": "w", "nodes": [{"id": "w", "role": "writer", "task": "draft. {prev_summary}"}, {"id": "me", "role": "human"},
                                        {"id": "end", "role": "end"}],
                "edges": [{"from": "w", "to": "me"}, {"from": "me", "to": "end", "on": "approved"}, {"from": "me", "to": "w", "on": "rejected"}]}
        g = self.start(topo)
        self.claim(g["id"], "w", "draft 1")
        with self.assertRaises(WorkGraphError):
            resume(S, g["id"], outcome="rejectd")
        f = resume(S, g["id"], outcome="rejected", note="make it half as long")
        task = load_job(S, node(f, "w")["job_id"])["task"]
        self.assertIn("make it half as long", task)

    def test_a_second_arrival_at_a_running_node_is_not_a_second_job(self) -> None:
        topo = {"start": "s", "nodes": [{"id": "s", "role": "scout"}, {"id": "x", "role": "writer"}, {"id": "y", "role": "writer"},
                                        {"id": "end", "role": "end"}],
                "edges": [{"from": "s", "to": "x"}, {"from": "s", "to": "y"}, {"from": "x", "to": "y"}, {"from": "y", "to": "end"}]}
        g = self.start(topo)
        self.claim(g["id"], "s", "go")
        f = self.g(g["id"])
        first = node(f, "y")["job_id"]
        f = self.claim(g["id"], "x", "x done")
        self.assertEqual(node(f, "y")["job_id"], first)
        self.assertEqual(node(f, "y")["visits"], 1)

    def test_a_graph_claim_reaches_the_owner_by_mailbox_not_by_paste(self) -> None:
        from pong.mailbox import peek
        from pong.waitroom import list_items
        g = self.start({"start": "w", "nodes": [{"id": "w", "role": "writer", "task": "x"}, {"id": "end", "role": "end"}],
                        "edges": [{"from": "w", "to": "end"}]})
        self.claim(g["id"], "w", "wrote it")
        self.assertEqual(list_items(S, to="w2"), [], "nothing queued to paste into the owner's terminal")
        self.assertTrue(any(i.get("kind") == "claim" for i in peek(S, "w2", limit=0)), "the owner still hears it by mailbox")

    def test_lint_refuses_what_cannot_run(self) -> None:
        from pong.work_graph import WorkGraphError, lint_topology
        with self.assertRaises(WorkGraphError):
            lint_topology({"start": "e", "nodes": [{"id": "e", "role": "end"}, {"id": "b", "role": "builder"}],
                           "edges": [{"from": "e", "to": "b"}]})
        with self.assertRaises(WorkGraphError):
            lint_topology({"max_rounds": 0, "nodes": [{"id": "b", "role": "builder"}], "edges": []})
        with self.assertRaises(WorkGraphError):
            lint_topology({"nodes": [{"id": "t", "role": "check"}], "edges": []})
        t = lint_topology({"start": "a", "nodes": [{"id": "a", "role": "builder", "task": "x"}, {"id": "b", "role": "critic", "task": "y"}],
                           "edges": [{"from": "a", "to": "b"}, {"from": "b", "to": "a", "on": "fail"}, {"from": "a", "to": "b"}]})
        text = " ".join(t["warnings"])
        self.assertIn("no way out", text)
        self.assertIn("duplicate edge", text)

    def test_a_pin_that_names_nothing_is_refused(self) -> None:
        from pong.work_graph import WorkGraphError
        topo = {"start": "b", "nodes": [{"id": "b", "role": "builder"}], "edges": []}
        with self.assertRaises(WorkGraphError):
            self.start(topo, pins={"buidler": "grok"})
        with self.assertRaises(WorkGraphError):
            self.start(topo, pins={"b": "gpt9"})


if __name__ == "__main__":
    unittest.main()


class LaunchLineTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        os.environ["PONG_HOME"] = self.tmp.name
        from pong.paths import ensure_layout
        from pong.routing import ensure_session_token

        ensure_layout("t-team")
        self.token = ensure_session_token("t-team")

    def tearDown(self) -> None:
        os.environ.pop("PONG_HOME", None)
        self.tmp.cleanup()

    def test_a_fresh_seat_starts_on_its_job_and_the_token_is_never_typed(self) -> None:
        from pong.groups import _launch_command
        state = {"session": "t-team"}
        line = _launch_command(state, {"id": "c1.c", "type": "claude", "cmd": "claude"},
                               initial_prompt="Your job is in the file /x/job.prompt.txt. Read it.")
        self.assertIn("'Your job is in the file /x/job.prompt.txt. Read it.'", line)
        self.assertNotIn(self.token, line, "the token value never goes into a typed line")
        self.assertIn("$(cat ", line)
        hermes = _launch_command(state, {"id": "c1.d", "type": "hermes", "cmd": "hermes"}, initial_prompt="x y")
        self.assertNotIn("'x y'", hermes, "a CLI without an initial-prompt argument gets the paste instead")


class TemplateTests(unittest.TestCase):
    def test_every_bundled_template_lints(self) -> None:
        import json
        from pong.loops import _PKG
        from pong.work_graph import lint_topology
        names = sorted(p.stem for p in (_PKG / "graphs").glob("*.json"))
        for want in ("build-verify", "fanout-synthesize", "best-of-n", "scout-panel", "tournament-evolve", "planner-sprints"):
            self.assertIn(want, names)
        for p in (_PKG / "graphs").glob("*.json"):
            t = lint_topology(json.loads(p.read_text()))
            self.assertTrue(t["nodes"], p.name)
            self.assertTrue(any(n["role"] == "human" for n in t["nodes"]), f"{p.name} has a person at the end")


class InterviewTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        os.environ["PONG_HOME"] = self.tmp.name
        os.environ["PONG_RUNTIMES"] = "claude,grok"
        from pong.jsonutil import write_json
        from pong.paths import active_path, ensure_layout
        ensure_layout("pong-team-1")
        write_json(active_path(), {"session": "pong-team-1"})

    def tearDown(self) -> None:
        for k in ("PONG_HOME", "PONG_RUNTIMES", "PONG_SESSION", "PONG_TOKEN"):
            os.environ.pop(k, None)
        self.tmp.cleanup()

    def test_a_failed_start_takes_its_new_team_back(self) -> None:
        from pong import composer
        from pong.jsonutil import read_json
        from pong.paths import active_path
        from pong.state import load_pairs_db
        proposal = composer.compose({"goal": "g", "kind": "writing", "done": "human", "shape": "graph",
                                     "stages": "write -> me", "team": "new"})
        with patch("pong.composer._start_from", side_effect=RuntimeError("boom")):
            with self.assertRaises(RuntimeError):
                composer.apply(proposal)
        self.assertEqual(list(load_pairs_db().keys()), [], "no orphan team left behind")
        self.assertEqual(read_json(active_path()).get("session"), "pong-team-1", "the active team is back")

    def test_a_command_becomes_an_engine_check_before_the_critic(self) -> None:
        from pong import composer
        p = composer.compose({"goal": "g", "kind": "code", "done": "command", "done_value": "make test",
                              "shape": "graph", "stages": "build <-> review -> me"})
        roles = [(n["id"], n["role"]) for n in p["topology"]["nodes"]]
        self.assertEqual(roles[:3], [("build", "builder"), ("tests", "check"), ("review", "critic")])
        self.assertEqual(p["topology"]["nodes"][1]["run"], ["make test"])
