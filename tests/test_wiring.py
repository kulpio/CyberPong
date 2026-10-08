#!/usr/bin/env python3
"""Wiring: who runs each node, why, and why not.

These pin the contract the map depends on, not the policy: every node of a loop
gets a platform with a reason; every platform that was not picked has a reason
too; a boundary removes a platform before the rules run; a pin wins unless a
boundary forbids it, and then the refusal is said out loud.
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

ALL = ("claude", "grok", "codex", "hermes")


def _toolless(test, rid="grok", session=None):
    """Simulate a runtime without tools for one test. Every shipped runtime has tools
    now (Grok Build runs shell and edits files; catalog 2026-09-20), so the routing
    rules for tool work are pinned on a runtime the test makes toolless."""
    from pong import models
    cat = models.load_catalog(session)
    row = cat["runtimes"][rid]
    before = row.get("tools")
    row["tools"] = False
    row.setdefault("boundaries", [])
    if "no_tools" not in row["boundaries"]:
        row["boundaries"] = list(row["boundaries"]) + ["no_tools"]
    def restore():
        row["tools"] = before
        row["boundaries"] = [b for b in row["boundaries"] if b != "no_tools"]
    test.addCleanup(restore)


class WiringTests(unittest.TestCase):
    def setUp(self) -> None:
        from pong import wiring

        self.W = wiring
        self.tmp = tempfile.TemporaryDirectory()
        os.environ["PONG_HOME"] = self.tmp.name

    def tearDown(self) -> None:
        os.environ.pop("PONG_HOME", None)
        self.tmp.cleanup()

    def test_every_node_of_a_gauntlet_is_wired_with_a_reason(self) -> None:
        plan = self.W.plan_loop("gauntlet", "ship the feature and run the tests", available=ALL)
        self.assertEqual(set(plan["nodes"]), {"builder", "critic"})
        for nid, row in plan["nodes"].items():
            self.assertTrue(row["runtime"], f"{nid} has no platform")
            self.assertTrue(row["why"].strip(), f"{nid} has no reason")
            self.assertIn("rejected", row)

    def test_every_platform_not_picked_has_a_why_not(self) -> None:
        _toolless(self)
        row = self.W.plan_node("builder", "run the tests and commit", available=ALL)
        others = set(ALL) - {row["runtime"]}
        self.assertEqual(set(row["rejected"]), others)
        self.assertIn("no tools", row["rejected"]["grok"])

    def test_a_client_facing_goal_never_wires_grok_to_prose(self) -> None:
        row = self.W.plan_node("writer", "find the latest posts and draft the reply",
                               boundaries={"client_facing": True}, available=ALL)
        self.assertNotEqual(row["runtime"], "grok")
        self.assertIn("client-facing", row["rejected"]["grok"])

    def test_an_open_web_scout_stays_on_grok_when_the_pool_is_healthy(self) -> None:
        row = self.W.plan_node("scout", "find the latest posts on reddit", available=ALL)
        self.assertEqual(row["runtime"], "grok")

    def test_a_shared_pool_below_its_floor_moves_repeated_work_off_it(self) -> None:
        self.W.set_pool("xai", 0.10)
        row = self.W.plan_node("scout", "find the latest posts on reddit", in_cycle=True, available=ALL)
        self.assertNotEqual(row["runtime"], "grok")
        self.assertIn("below its", row["rejected"]["grok"])

    def test_a_pin_wins_and_says_what_the_rule_would_have_chosen(self) -> None:
        row = self.W.plan_node("builder", "implement the endpoint", pin="codex", available=ALL)
        self.assertEqual(row["runtime"], "codex")
        self.assertTrue(row["rule"].startswith("pin"))
        self.assertIsNone(row["conflict"])

    def test_a_pin_a_boundary_forbids_is_refused_out_loud(self) -> None:
        _toolless(self)
        row = self.W.plan_node("builder", "run the tests and commit", pin="grok", available=ALL)
        self.assertNotEqual(row["runtime"], "grok")
        self.assertTrue(row["conflict"])
        self.assertIn("refused", row["why"].lower())

    def test_nothing_installed_is_unwired_not_defaulted(self) -> None:
        _toolless(self)
        row = self.W.plan_node("builder", "run the tests", available=["grok"])
        self.assertIsNone(row["runtime"])
        self.assertEqual(row["conflict"], "unwired")

    def test_a_human_gate_is_a_person(self) -> None:
        row = self.W.plan_node("human", "approve", available=ALL)
        self.assertIsNone(row["runtime"])
        self.assertEqual(row["rule"], "gate")

    def test_pools_round_trip(self) -> None:
        self.W.set_pool("xai", 0.62, floor=0.3)
        rem, floor = self.W.pool_remaining("xai")
        self.assertAlmostEqual(rem, 0.62)
        self.assertAlmostEqual(floor, 0.3)
        self.assertEqual(self.W.pool_remaining("anthropic"), (1.0, self.W.DEFAULT_POOL_FLOOR))


class GoalStartWiringTests(unittest.TestCase):
    """The graph document carries the wiring the island and the map read."""

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        os.environ["PONG_HOME"] = self.tmp.name
        os.environ["PONG_SESSION"] = "pong-team"
        os.environ["PONG_RUNTIMES"] = ",".join(ALL)
        os.environ.pop("PONG_SEAT", None)
        from pong.jsonutil import write_json
        from pong.paths import active_path, ensure_layout, pairs_path
        from pong.routing import ensure_session_token

        ensure_layout("pong-team")
        pair = {
            "schema_version": 2,
            "conductor": {"id": "c1", "type": "grok", "label": "Grok", "cmd": "grok", "mode": "tmux", "tmux_index": 0},
            "workers": [
                {"id": "w2", "type": "claude", "label": "Lead", "cmd": "claude", "tmux_index": 2, "mission_role": "coder"},
            ],
            "transport_default": "job",
            "flow_graph": {"edges": [{"from": "c1", "to": "w2", "kind": "delegate"}, {"from": "w2", "to": "c1", "kind": "claim"}]},
        }
        write_json(pairs_path(), {"pong-team": pair})
        active = dict(pair); active["session"] = "pong-team"
        write_json(active_path(), active)
        ensure_session_token("pong-team")

    def tearDown(self) -> None:
        for k in ("PONG_HOME", "PONG_SESSION", "PONG_TOKEN", "PONG_RUNTIMES"):
            os.environ.pop(k, None)
        self.tmp.cleanup()

    def test_gauntlet_graph_records_who_runs_each_node_and_why(self) -> None:
        from pong.work_graph import start

        g = start("pong-team", owner="w2", loop="gauntlet", task="ship it and run the tests",
                  bar="/tmp/bar.md", boundaries={"client_facing": False, "agency": "gated"})
        w = g["wiring"]
        self.assertIn("builder", w)
        self.assertIn("critic", w)
        self.assertEqual(w["critic"]["runtime"], "claude")
        self.assertEqual(w["critic"]["model"], "opus")
        self.assertTrue(w["critic"]["why"])
        self.assertIn("grok", w["critic"]["rejected"])
        self.assertEqual(g["boundaries"]["agency"], "gated")
        job = g["_jobs"][0]
        self.assertTrue(job.get("model_why"))
        self.assertIn("rejected", job)

    def test_a_pin_from_the_goal_reaches_the_node(self) -> None:
        from pong.work_graph import start

        g = start("pong-team", owner="w2", loop="cycle", task="iterate on it", pins={"builder": "codex"})
        self.assertEqual(g["wiring"]["builder"]["runtime"], "codex")
        self.assertTrue(g["wiring"]["builder"]["rule"].startswith("pin"))


if __name__ == "__main__":
    unittest.main()
