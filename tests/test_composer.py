#!/usr/bin/env python3
"""The interview → proposal → team → loop path, and pause / resume.

What these pin: the same answers always give the same baseline; a person who
judges never gets a critic; unattended needs something to check against; the
model may only move inside the fields the schema allows and never starts
anything; a new graph can be a team of its own; a loop that should stop after
every round does, and resume files exactly the next round.
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

ALL = "claude,grok,codex,hermes"

BASE = {
    "goal": "Ship the seat-busy TTL so a stuck seat frees itself after twenty minutes. Run the tests.",
    "kind": "code", "done": "command", "done_value": "python3 -m unittest tests.test_seat_status",
    "audience": "me", "efficiency": "balanced", "pause": "win", "platforms": "any", "team": "new",
}


class ComposeTests(unittest.TestCase):
    def setUp(self) -> None:
        from pong import composer

        self.C = composer

    def test_the_same_answers_always_give_the_same_graph(self) -> None:
        a = self.C.compose(dict(BASE))
        b = self.C.compose(dict(BASE))
        a.pop("answers"); b.pop("answers")
        self.assertEqual(a, b)
        self.assertEqual(a["loop"], "gauntlet")
        self.assertEqual(a["max_rounds"], 3)
        self.assertEqual(a["builder_role"], "coder")
        self.assertEqual(a["done"]["acceptance"][0]["cmd"], BASE["done_value"])
        self.assertEqual(a["boundaries"]["pause_on"], "win")
        self.assertEqual(a["boundaries"]["agency"], "gated")

    def test_a_person_who_judges_never_gets_a_critic(self) -> None:
        p = self.C.compose({**BASE, "done": "human", "done_value": ""})
        self.assertEqual(p["loop"], "cycle")
        self.assertTrue(p["done"].get("human"))

    def test_unattended_needs_something_to_check_against(self) -> None:
        p = self.C.compose({**BASE, "done": "human", "pause": "done"})
        self.assertEqual(p["boundaries"]["pause_on"], "win")
        self.assertEqual(p["boundaries"]["agency"], "gated")
        ok = self.C.compose({**BASE, "pause": "done"})
        self.assertEqual(ok["boundaries"]["agency"], "unattended")

    def test_fast_is_one_round_and_no_critic(self) -> None:
        p = self.C.compose({**BASE, "efficiency": "fast"})
        self.assertEqual(p["loop"], "cycle")
        self.assertEqual(p["max_rounds"], 1)
        self.assertEqual(p["boundaries"]["efficiency"], "fast")

    def test_kind_sets_who_builds(self) -> None:
        r = self.C.compose({**BASE, "kind": "research", "done": "example", "done_value": "https://stripe.com/docs"})
        self.assertEqual((r["builder_role"], r["wire_role"]), ("researcher", "scout"))
        self.assertEqual(r["done"]["examples"], ["https://stripe.com/docs"])
        w = self.C.compose({**BASE, "kind": "writing", "audience": "client"})
        self.assertEqual(w["wire_role"], "writer")
        self.assertTrue(w["boundaries"]["client_facing"])

    def test_platform_choice_becomes_an_allow_list(self) -> None:
        p = self.C.compose({**BASE, "platforms": "claude+grok"})
        self.assertEqual(p["boundaries"]["allowed"], ["claude", "grok"])

    def test_an_empty_goal_is_refused(self) -> None:
        with self.assertRaises(self.C.ComposeError):
            self.C.compose({**BASE, "goal": "  "})
        with self.assertRaises(self.C.ComposeError):
            self.C.compose({**BASE, "done": "command", "done_value": ""})

    def test_the_interview_accepts_numbers_labels_and_defaults(self) -> None:
        script = iter(["Make the island faster", "", "3", "2", "1", "", "1", "2", "1"])  # shape: default (auto)
        answers = self.C.interview(lambda _q: next(script))
        self.assertEqual(answers["goal"], "Make the island faster")
        self.assertEqual(answers["kind"], "code")
        self.assertEqual(answers["done"], "human")
        self.assertEqual(answers["audience"], "team")
        self.assertEqual(answers["efficiency"], "thorough")
        self.assertEqual(answers["pause"], "round")
        self.assertEqual(answers["platforms"], "claude")
        self.assertEqual(answers["team"], "new")


class ModelRefinementTests(unittest.TestCase):
    def setUp(self) -> None:
        from pong import composer

        self.C = composer
        os.environ.pop("PONG_GRAPH_MODEL", None)

    def test_the_model_may_only_move_inside_the_schema(self) -> None:
        p = self.C.compose(dict(BASE))
        reply = json.dumps({"max_rounds": 5, "loop": "cycle", "pause_on": "round",
                            "title": "Seat TTL", "goal": "Free a stuck seat after twenty minutes of silence; prove it with the seat-status tests.",
                            "seats": 12, "why": ["five rounds: the fix touches a hot path"]})
        out = self.C.propose(p, runner=lambda _prompt: (True, "Sure! " + reply + " done"))
        self.assertEqual(out["max_rounds"], 5)
        self.assertEqual(out["loop"], "cycle")
        self.assertEqual(out["boundaries"]["pause_on"], "round")
        self.assertEqual(out["title"], "Seat TTL")
        self.assertIn("seats", out["designed_by"]["dropped"])
        self.assertEqual(out["designed_by"]["model"], "claude")
        self.assertTrue(any("five rounds" in n for n in out["notes"]))

    def test_the_model_cannot_add_a_critic_the_person_did_not_ask_for(self) -> None:
        p = self.C.compose({**BASE, "done": "human"})
        out = self.C.propose(p, runner=lambda _p: (True, json.dumps({"loop": "gauntlet", "pause_on": "done"})))
        self.assertEqual(out["loop"], "cycle")
        self.assertEqual(out["boundaries"]["pause_on"], "win")
        self.assertEqual(len(out["designed_by"]["dropped"]), 2)

    def test_an_unavailable_model_keeps_the_baseline_and_says_so(self) -> None:
        p = self.C.compose(dict(BASE))
        out = self.C.propose(p, runner=lambda _p: (False, "claude CLI is not installed"))
        self.assertEqual(out["loop"], "gauntlet")
        self.assertEqual(out["designed_by"]["model"], "unavailable")
        self.assertTrue(any("skipped" in n for n in out["notes"]))
        out2 = self.C.propose(self.C.compose(dict(BASE)), runner=lambda _p: (True, "no json here"))
        self.assertEqual(out2["designed_by"]["model"], "no-json")

    def test_the_switch_turns_the_model_off(self) -> None:
        os.environ["PONG_GRAPH_MODEL"] = "0"
        try:
            called = []
            out = self.C.propose(self.C.compose(dict(BASE)), runner=lambda p: called.append(p) or (True, "{}"))
            self.assertEqual(called, [])
            self.assertEqual(out["designed_by"]["model"], "off")
        finally:
            os.environ.pop("PONG_GRAPH_MODEL", None)


class ApplyTests(unittest.TestCase):
    """A new graph is a team of its own, written where the app reads."""

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        os.environ["PONG_HOME"] = self.tmp.name
        os.environ["PONG_RUNTIMES"] = ALL
        for k in ("PONG_SESSION", "PONG_SEAT", "PONG_TOKEN"):
            os.environ.pop(k, None)

    def tearDown(self) -> None:
        for k in ("PONG_HOME", "PONG_RUNTIMES", "PONG_SESSION", "PONG_TOKEN"):
            os.environ.pop(k, None)
        self.tmp.cleanup()

    def test_a_new_graph_gets_a_team_a_token_and_a_running_loop(self) -> None:
        from pong import composer
        from pong.paths import active_path, sessions_dir
        from pong.state import load_pairs_db
        from pong.work_graph import find_graph

        p = composer.compose(dict(BASE))
        g = composer.apply(p)
        sess = g["_session"]
        self.assertEqual(sess, "pong-team-1")
        pair = load_pairs_db()[sess]
        self.assertEqual(pair["conductor"]["id"], "c1")
        self.assertEqual(pair["conductor"]["type"], "claude")
        self.assertEqual(pair["conductor"]["model"], "fable")
        self.assertEqual(pair["display_name"], p["title"])
        self.assertTrue((sessions_dir(sess) / "token").is_file())
        self.assertEqual(json.loads(active_path().read_text())["session"], sess)
        fresh = find_graph(sess, g["id"])
        self.assertEqual(fresh["kind"], "gauntlet")
        self.assertEqual(fresh["owner"], "c1")
        self.assertEqual(fresh["builder_role"], "coder")
        self.assertEqual(fresh["acceptance"][0]["cmd"], BASE["done_value"])
        self.assertTrue(fresh.get("bar"), "a command-checked gauntlet writes its bar from the command")
        self.assertIn("must exit 0", Path(fresh["bar"]).read_text())
        self.assertEqual(fresh["boundaries"]["pause_on"], "win")
        self.assertEqual(fresh["wiring"]["critic"]["model"], "opus")
        job = g["_jobs"][0]
        self.assertIn("python3 -m unittest", job.get("_prompt", ""), "the check travels with the builder's job")
        self.assertIn("isolated PONG_HOME", g.get("_spawn_note") or "")

    def test_two_new_graphs_get_two_teams(self) -> None:
        from pong import composer

        a = composer.apply(composer.compose(dict(BASE)))
        b = composer.apply(composer.compose({**BASE, "goal": "Draft the weekly note", "kind": "writing", "done": "human"}))
        self.assertEqual((a["_session"], b["_session"]), ("pong-team-1", "pong-team-2"))
        self.assertEqual(b["builder_role"], "writer")


class PauseResumeTests(unittest.TestCase):
    """pause_on=round: a loop that stops to show you, and resumes on your say-so."""

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        os.environ["PONG_HOME"] = self.tmp.name
        os.environ["PONG_RUNTIMES"] = ALL
        os.environ["PONG_SESSION"] = "pong-team"
        os.environ.pop("PONG_SEAT", None)
        from pong.jsonutil import write_json
        from pong.paths import active_path, ensure_layout, pairs_path
        from pong.routing import ensure_session_token

        ensure_layout("pong-team")
        pair = {
            "schema_version": 2,
            "conductor": {"id": "c1", "type": "grok", "label": "Grok", "cmd": "grok", "mode": "tmux", "tmux_index": 0},
            "workers": [{"id": "w2", "type": "claude", "label": "Lead", "cmd": "claude", "tmux_index": 2, "mission_role": "coder"}],
            "transport_default": "job",
            "flow_graph": {"edges": [{"from": "c1", "to": "w2", "kind": "delegate"}, {"from": "w2", "to": "c1", "kind": "claim"}]},
        }
        write_json(pairs_path(), {"pong-team": pair})
        active = dict(pair); active["session"] = "pong-team"
        write_json(active_path(), active)
        ensure_session_token("pong-team")

    def tearDown(self) -> None:
        for k in ("PONG_HOME", "PONG_RUNTIMES", "PONG_SESSION", "PONG_TOKEN"):
            os.environ.pop(k, None)
        self.tmp.cleanup()

    def test_a_cycle_that_pauses_after_every_round(self) -> None:
        from pong.jobs import record_claim
        from pong.mailbox import peek
        from pong.work_graph import find_graph, resume, start, tick

        g = start("pong-team", owner="w2", loop="cycle", task="iterate on it", max_rounds=3,
                  boundaries={"pause_on": "round"})
        job = g["_jobs"][0]
        record_claim("pong-team", job["id"], summary="not there yet")
        tick("pong-team")
        fresh = find_graph("pong-team", g["id"])
        self.assertTrue(fresh["paused"], "the loop must stop and show you")
        self.assertEqual(fresh["paused"]["next_round"], 2)
        self.assertEqual(fresh["round"], 1, "no second round was filed")
        self.assertTrue(any(i.get("kind") == "pause" for i in peek("pong-team", "w2", limit=0)))
        # A tick while paused does nothing.
        tick("pong-team")
        self.assertEqual(find_graph("pong-team", g["id"])["round"], 1)
        # Resume files exactly the next round.
        after = resume("pong-team", g["id"])
        self.assertIsNone(after["paused"])
        self.assertEqual(after["round"], 2)
        builder = next(n for n in after["nodes"] if n["id"] == "builder")
        self.assertEqual(builder["status"], "running")
        self.assertNotEqual(builder["job_id"], job["id"])

    def test_resume_past_the_cap_ends_the_loop(self) -> None:
        from pong.jobs import record_claim
        from pong.work_graph import find_graph, resume, start, tick

        g = start("pong-team", owner="w2", loop="cycle", task="iterate", max_rounds=1,
                  boundaries={"pause_on": "round"})
        record_claim("pong-team", g["_jobs"][0]["id"], summary="done-ish")
        tick("pong-team")
        fresh = find_graph("pong-team", g["id"])
        # cap 1: the engine stops at max_rounds before it could pause
        self.assertEqual(fresh["status"], "done")
        with self.assertRaises(Exception):
            resume("pong-team", g["id"])

    def test_a_manual_pause_holds_the_next_round(self) -> None:
        from pong.jobs import record_claim
        from pong.work_graph import find_graph, pause, resume, start, tick

        g = start("pong-team", owner="w2", loop="cycle", task="iterate", max_rounds=3)
        pause("pong-team", g["id"])
        record_claim("pong-team", g["_jobs"][0]["id"], summary="round one")
        tick("pong-team")
        self.assertEqual(find_graph("pong-team", g["id"])["round"], 1)
        resume("pong-team", g["id"])
        self.assertEqual(find_graph("pong-team", g["id"])["round"], 2)


if __name__ == "__main__":
    unittest.main()


class GraphLoopShapeTests(unittest.TestCase):
    """`gather -> synthesize <-> grade -> me -> done` becomes a topology the
    runtime lints and starts; the shape the person described is never swapped
    for an auto shape."""

    def test_stages_parse_into_nodes_edges_and_a_gate(self) -> None:
        from pong.composer import parse_stages
        t = parse_stages("gather -> synthesize <-> grade -> me -> done", kind="writing", goal="g")
        ids = [n["id"] for n in t["nodes"]]
        self.assertEqual(ids, ["gather", "synthesize", "grade", "me", "done"])
        roles = {n["id"]: n["role"] for n in t["nodes"]}
        self.assertEqual(roles, {"gather": "operator", "synthesize": "writer", "grade": "critic", "me": "human", "done": "join"})
        edges = {(e["from"], e["to"], e["on"]) for e in t["edges"]}
        self.assertIn(("gather", "synthesize", "done"), edges)
        self.assertIn(("synthesize", "grade", "done"), edges)
        self.assertIn(("grade", "synthesize", "fail"), edges, "the critic's fail loops back")
        self.assertIn(("grade", "me", "win"), edges)
        self.assertIn(("me", "done", "approved"), edges)
        self.assertIn(("me", "synthesize", "rejected"), edges, "a rejection at the gate returns to the last producing stage")
        self.assertEqual(t["start"], "gather")

    def test_a_bare_pair_gets_an_end_and_unknown_stages_take_the_kind_role(self) -> None:
        from pong.composer import parse_stages
        t = parse_stages("outline -> polish", kind="code")
        self.assertEqual([n["id"] for n in t["nodes"]], ["outline", "polish", "done"])
        self.assertEqual({n["role"] for n in t["nodes"][:2]}, {"builder"})

    def test_compose_with_the_graph_shape_keeps_it_and_the_engine_lints_it(self) -> None:
        from pong.composer import compose
        from pong.work_graph import lint_topology
        p = compose({"goal": "Keep the persona fresh", "kind": "writing", "done": "human", "shape": "graph",
                     "stages": "gather -> synthesize <-> grade -> me -> done", "efficiency": "balanced"})
        self.assertEqual(p["loop"], "graph")
        self.assertEqual(p["topology"]["max_rounds"], 3)
        lint_topology(p["topology"])
        self.assertTrue(any(n.startswith("Graph loop:") for n in p["notes"]))

    def test_a_graph_shape_without_stages_is_refused(self) -> None:
        from pong.composer import ComposeError, compose
        with self.assertRaises(ComposeError):
            compose({"goal": "x", "shape": "graph"})
