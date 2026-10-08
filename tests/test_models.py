#!/usr/bin/env python3
"""Runtime + model routing.

The thing these pin is not "coder gets fable" — that is policy and lives in
``models/catalog.json`` where it can be edited. What they pin is that the router
cannot produce a seat that will not come up: a runtime that is not installed, a
Claude model on a Grok pane, a tool job on a runtime with no tools, or a
decision nobody can read the reason for.
"""

from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "python"))

BOTH = ("claude", "grok")


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


class CatalogTests(unittest.TestCase):
    def setUp(self) -> None:
        from pong import models

        self.M = models

    def test_the_shipped_catalog_is_loadable_and_complete(self) -> None:
        cat = self.M.load_catalog()
        self.assertIn("claude", cat["runtimes"])
        self.assertIn("grok", cat["runtimes"])
        self.assertTrue(cat["rules"], "a catalog with no rules routes nothing")
        for rule in cat["rules"]:
            self.assertTrue(rule.get("id"), "every rule needs an id to be reported")
            self.assertTrue(rule.get("why"), f"rule {rule.get('id')} has no reason")
            self.assertIn(rule["pick"]["runtime"], cat["runtimes"])
        self.assertTrue(cat["fallback"]["why"])

    def test_every_runtime_declares_how_to_set_a_model(self) -> None:
        """`--model` or nothing. Guessing a flag is how a seat fails to launch."""
        for rid, row in self.M.runtimes().items():
            models = row.get("models") or {}
            if models:
                self.assertIn(
                    row.get("default_model"), models,
                    f"{rid} default_model is not one of its models")
            self.assertTrue(
                row.get("model_flag") or not models,
                f"{rid} lists models but no way to select one")

    def test_a_model_id_is_reachable_by_the_names_people_write(self) -> None:
        self.assertEqual(self.M.canonical_model("claude", "opus 5"), "opus")
        self.assertEqual(self.M.canonical_model("claude", "Fable-5"), "fable")
        self.assertEqual(self.M.canonical_model("grok", "grok4.6"), "grok-4.6")
        # Unknown names pass through: a model that shipped this morning must
        # work this morning, not after this table is edited.
        self.assertEqual(self.M.canonical_model("claude", "brand-new"), "brand-new")


class DemandTests(unittest.TestCase):
    def setUp(self) -> None:
        from pong import models

        self.M = models

    def test_markers_match_whole_words_only(self) -> None:
        """"latest" is not "test", and "rapid" is not "api" — reading them that
        way tagged a scouting job as code work and routed it accordingly."""
        self.assertNotIn("code", self.M.demands_for("the latest posts on X"))
        self.assertNotIn("code", self.M.demands_for("rapid capital growth"))
        self.assertIn("code", self.M.demands_for("run the test suite"))

    def test_tool_work_is_recognised(self) -> None:
        self.assertIn("tools", self.M.demands_for("open the file and commit"))
        self.assertIn("deep", self.M.demands_for("find the root cause of the race"))
        self.assertEqual(self.M.demands_for(""), [])


class RoutingTests(unittest.TestCase):
    def setUp(self) -> None:
        from pong import models

        self.M = models

    def plan(self, task="", role="", **kw):
        kw.setdefault("available", BOTH)
        return self.M.plan(task, role, **kw)

    def test_a_critic_is_never_cheaper_than_the_builder(self) -> None:
        builder = self.plan("ship the feature", "builder")
        critic = self.plan("score the artifacts", "critic")
        self.assertEqual(critic.runtime, "claude")
        tiers = self.M.runtimes()["claude"]["models"]
        self.assertIn(tiers[critic.model]["tier"], ("judge", "deep"))
        self.assertNotEqual(critic.rule, "fallback")
        self.assertTrue(builder.why and critic.why)

    TOOL_WORK = "run the tests and commit the migration in the repo"

    def test_tool_work_never_lands_on_a_runtime_without_tools(self) -> None:
        """A bare Grok seat has no MCP and no skills. Cheap is not the point."""
        p = self.plan("open the file and run the tests", "task_runner")
        self.assertTrue(self.M.runtimes()[p.runtime].get("tools"))

    def test_a_pinned_toolless_runtime_does_not_get_tool_work_either(self) -> None:
        """The pinned path is the one every roster grok seat actually takes.

        plan_for_worker pins ``type`` from the roster row, so this — not the
        unpinned call above — is how tool work reaches a Grok pane in practice.
        The rule loop skips every rule whose pick is a different runtime and
        falls through to runtime-default, which used to hand back grok with an
        empty ``skipped`` and a ``why`` that read like an ordinary decision.
        """
        _toolless(self)
        p = self.plan(self.TOOL_WORK, "scout", prefer_runtime="grok")
        self.assertIn("tools", p.demands)
        self.assertTrue(
            self.M.runtimes()[p.runtime].get("tools"),
            f"tool work landed on {p.runtime}, which has no tools",
        )
        self.assertTrue(
            any("pin refused" in s.lower() for s in p.skipped),
            f"the refused pin must be reported, got {p.skipped}",
        )
        self.assertIn("respawn", p.why.lower())

    def test_a_roster_model_does_not_smuggle_tool_work_onto_a_toolless_seat(self) -> None:
        """The `explicit` early return fires before the rule loop is reached.

        plan_for_worker passes the roster row's model as well as its type, so a
        grok seat annotated model="grok-4.6" takes this path. A guard on the
        fallthrough alone would leave it wide open.
        """
        _toolless(self)
        p = self.plan(
            self.TOOL_WORK, "scout", prefer_runtime="grok", prefer_model="grok-4.6"
        )
        self.assertNotEqual(p.rule, "explicit")
        self.assertTrue(
            self.M.runtimes()[p.runtime].get("tools"),
            f"tool work landed on {p.runtime}, which has no tools",
        )
        self.assertTrue(any("pin refused" in s.lower() for s in p.skipped))

    def test_a_refused_pin_still_returns_a_launchable_pair(self) -> None:
        """`grok --model fable` does not launch. Never emit that shape."""
        _toolless(self)
        for kw in ({}, {"prefer_model": "grok-4.6"}):
            p = self.plan(self.TOOL_WORK, "scout", prefer_runtime="grok", **kw)
            row = self.M.runtimes()[p.runtime]
            self.assertEqual(p.cmd, row["cmd"])
            self.assertIn(p.model, set(row.get("models") or {}) | {row.get("default_model")})
            self.assertEqual(p.launch_cmd, f"{p.cmd} --model {p.model}")

    def test_with_no_tools_runtime_available_the_refusal_is_still_loud(self) -> None:
        """Nowhere good to send it is not a reason to quietly send it anyway."""
        _toolless(self)
        p = self.plan(self.TOOL_WORK, "scout", prefer_runtime="grok", available=["grok"])
        self.assertTrue(p.skipped, "a refused pin came back with an empty skipped list")
        self.assertTrue(any("pin refused" in s.lower() for s in p.skipped))
        self.assertIn("no tools", p.why.lower())

    def test_a_pinned_toolless_runtime_keeps_work_that_needs_no_tools(self) -> None:
        """The guard is scoped to the tools demand, not to grok."""
        p = self.plan("find the latest posts on reddit", "scout", prefer_runtime="grok")
        self.assertNotIn("tools", p.demands)
        self.assertEqual(p.runtime, "grok")
        self.assertFalse([s for s in p.skipped if "pin refused" in s.lower()])

    def test_a_rule_naming_an_uninstalled_runtime_is_skipped_and_said_so(self) -> None:
        p = self.plan("find the latest posts on reddit", "scout", available=["claude"])
        self.assertEqual(p.runtime, "claude")
        self.assertTrue(
            any("not installed" in s for s in p.skipped),
            f"the skip must be reported, got {p.skipped}")

    def test_every_decision_carries_a_readable_reason(self) -> None:
        for task, role in [("", ""), ("x", "coder"), ("cron tick", "task_runner")]:
            p = self.plan(task, role)
            self.assertTrue(p.why.strip(), f"{role!r} routed with no reason")
            self.assertTrue(p.rule.strip())
            self.assertIn(p.runtime, self.M.runtimes())

    def test_a_live_pane_pins_the_runtime_but_not_the_model(self) -> None:
        """A seat's CLI is a running process; its model is a launch flag. So a
        Claude seat with no annotation still gets fable for code and opus for
        review rather than one blanket default."""
        coder = self.plan("implement it", "coder", prefer_runtime="claude")
        review = self.plan("score it", "reviewer", prefer_runtime="claude")
        lead = self.plan("plan the sprint", "orchestrator", prefer_runtime="claude")
        self.assertEqual(coder.runtime, "claude")
        self.assertEqual(review.runtime, "claude")
        # The rule, not a blanket default, chose each model — and the lead
        # (Fable, 28 Aug policy) differs from the coder (Opus).
        self.assertNotEqual(coder.rule, "runtime-default")
        self.assertNotEqual(review.rule, "runtime-default")
        self.assertNotEqual(lead.model, coder.model)

    def test_a_pinned_runtime_is_never_swapped_out_from_under_the_pane(self) -> None:
        p = self.plan("find the latest posts on reddit", "scout", prefer_runtime="claude")
        self.assertEqual(p.runtime, "claude")

    def test_a_model_from_another_runtime_is_treated_as_a_typo(self) -> None:
        """`grok --model fable` does not launch, so the seat never comes up."""
        p = self.plan("", "coder", prefer_runtime="grok", prefer_model="fable")
        self.assertEqual(p.model, "grok-4.7")
        self.assertTrue(any("belongs to another runtime" in s for s in p.skipped))

    def test_an_unknown_model_name_is_still_honoured(self) -> None:
        p = self.plan("", "coder", prefer_runtime="claude", prefer_model="opus-9")
        self.assertEqual(p.model, "opus-9")
        self.assertEqual(p.flags, ["--model", "opus-9"])

    def test_the_launch_line_is_what_actually_gets_run(self) -> None:
        p = self.plan("implement it", "coder")
        self.assertEqual(p.launch_cmd, f"{p.cmd} --model {p.model}")
        self.assertIsNone(self.M.model_command("grok", p.model))
        self.assertEqual(self.M.model_command("claude", "fable"), "/model fable")

    def test_a_runtime_with_no_model_flag_gets_a_bare_launch_line(self) -> None:
        p = self.plan("", "orchestrator", prefer_runtime="hermes")
        self.assertEqual(p.flags, [])
        self.assertEqual(p.launch_cmd, "hermes chat")


class SharedPoolTests(unittest.TestCase):
    """Ten grok seats and the chief spend one weekly allowance, so heavy work
    sent there is taken out of every other seat's week."""

    def setUp(self) -> None:
        from pong import models

        self.M = models
        self.tmp = tempfile.TemporaryDirectory()
        # A machine override that deliberately routes heavy work at the shared
        # pool — the shipped rules do not, and the guard has to hold anyway.
        d = Path(self.tmp.name) / "models"
        d.mkdir(parents=True)
        (d / "catalog.json").write_text(json.dumps({
            "rules": [{
                "id": "everything-to-grok",
                "when": {},
                "pick": {"runtime": "grok", "model": "grok-4.6"},
                "why": "test override",
            }],
        }), encoding="utf-8")
        self._home = str(self.tmp.name)

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def _plan(self, task, role):
        import os

        os.environ["PONG_HOME"] = self._home
        try:
            return self.M.plan(task, role, available=BOTH)
        finally:
            os.environ.pop("PONG_HOME", None)

    def test_light_work_stays_on_the_shared_pool(self) -> None:
        p = self._plan("send a quick ping", "task_runner")
        self.assertEqual(p.runtime, "grok")

    def test_heavy_work_moves_off_the_shared_pool(self) -> None:
        p = self._plan("audit the architecture for a race", "task_runner")
        self.assertEqual(p.runtime, "claude")
        self.assertIn("pool-guard", p.rule)
        self.assertIn("shared", p.why)


if __name__ == "__main__":
    unittest.main()
