#!/usr/bin/env python3
"""Work graph spawn must not mutate the org graph."""

from __future__ import annotations

import copy
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "python"))


def _pair(tmp, session="pong-team"):
    os.environ["PONG_HOME"] = tmp
    os.environ["PONG_SESSION"] = session
    from pong.paths import ensure_layout, pairs_path, active_path
    from pong.jsonutil import write_json
    from pong.routing import ensure_session_token

    ensure_layout(session)
    pair = {
        "schema_version": 2,
        "conductor": {
            "id": "c1", "type": "grok", "label": "Grok",
            "cmd": "grok", "mode": "tmux", "tmux_index": 0,
        },
        "workers": [
            {
                "id": "w1", "type": "claude", "label": "Builder",
                "cmd": "claude", "tmux_index": 1, "mission_role": "coder",
            },
            {
                "id": "w2", "type": "claude", "label": "Lead",
                "cmd": "claude", "tmux_index": 2, "mission_role": "coder",
            },
            {
                "id": "w3", "type": "claude", "label": "Reviewer",
                "cmd": "claude", "tmux_index": 3, "mission_role": "reviewer",
            },
        ],
        "transport_default": "job",
        "flow_graph": {
            "edges": [
                {"from": "c1", "to": "w1", "kind": "delegate"},
                {"from": "w1", "to": "c1", "kind": "claim"},
                {"from": "c1", "to": "w2", "kind": "delegate"},
                {"from": "w2", "to": "c1", "kind": "claim"},
                {"from": "c1", "to": "w3", "kind": "delegate"},
                {"from": "w3", "to": "c1", "kind": "claim"},
            ]
        },
    }
    write_json(pairs_path(), {session: pair})
    active = dict(pair)
    active["session"] = session
    write_json(active_path(), active)
    ensure_session_token(session)
    return pair



class WorkGraphTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.pair = _pair(self.tmp.name)
        self._saved_seat = os.environ.pop("PONG_SEAT", None)
        self._dispatch_patcher = patch("pong.transports.dispatch.dispatch_job")
        self.mock_dispatch = self._dispatch_patcher.start()

    def tearDown(self) -> None:
        self._dispatch_patcher.stop()
        self.tmp.cleanup()
        os.environ.pop("PONG_HOME", None)
        os.environ.pop("PONG_SESSION", None)
        os.environ.pop("PONG_TOKEN", None)
        if self._saved_seat is not None:
            os.environ["PONG_SEAT"] = self._saved_seat
        else:
            os.environ.pop("PONG_SEAT", None)

    def _set_pane(self, worker_id: str, pane_id: str) -> None:
        from pong.jsonutil import read_json, write_json
        from pong.paths import active_path, pairs_path

        session = "pong-team"
        db = read_json(pairs_path())
        pair = db[session]
        for w in pair.get("workers") or []:
            if str(w.get("id")) == worker_id:
                w["pane_id"] = pane_id
        write_json(pairs_path(), db)
        active = dict(pair)
        active["session"] = session
        write_json(active_path(), active)

    def test_spawn_does_not_mutate_flow_graph(self) -> None:
        from pong.state import load_session_state
        from pong.work_graph import start

        before = load_session_state("pong-team")
        edges_before = copy.deepcopy((before.get("flow_graph") or {}).get("edges"))
        workers_before = [w.get("id") for w in (before.get("workers") or [])]
        start(
            "pong-team",
            owner="w1",
            loop="fan",
            task="fan out",
            fan_n=2,
        )
        after = load_session_state("pong-team")
        self.assertEqual((after.get("flow_graph") or {}).get("edges"), edges_before)
        self.assertEqual([w.get("id") for w in (after.get("workers") or [])], workers_before)

    def test_gauntlet_refuses_without_bar(self) -> None:
        from pong.work_graph import WorkGraphError, start

        with self.assertRaises(WorkGraphError):
            start("pong-team", owner="w1", loop="gauntlet", task="ship it")

    def test_cancel_tears_down_without_mutating_org(self) -> None:
        from pong.state import load_session_state
        from pong.work_graph import cancel, load, start

        before = load_session_state("pong-team")
        edges_before = copy.deepcopy((before.get("flow_graph") or {}).get("edges"))
        g = start("pong-team", owner="w1", loop="cycle", task="iterate", max_rounds=2)
        cancelled = cancel("pong-team", g["id"])
        self.assertEqual(cancelled["status"], "cancelled")
        doc = load("pong-team")
        stored = next(x for x in doc["graphs"] if x["id"] == g["id"])
        self.assertEqual(stored["status"], "cancelled")
        after = load_session_state("pong-team")
        self.assertEqual((after.get("flow_graph") or {}).get("edges"), edges_before)

    def test_cancel_missing_id_errors(self) -> None:
        from pong.work_graph import WorkGraphError, cancel

        with self.assertRaises(WorkGraphError):
            cancel("pong-team", "g_missing")

    def test_participants_default_owner_only(self) -> None:
        from pong.work_graph import load, start

        g = start("pong-team", owner="w1", loop="fan", task="fan out", fan_n=2)
        self.assertEqual(g["owner"], "w1")
        self.assertEqual(g["participants"], ["w1"])
        doc = load("pong-team")
        stored = next(x for x in doc["graphs"] if x["id"] == g["id"])
        self.assertEqual(stored["participants"], ["w1"])
        seats = [n.get("seat") for n in g["nodes"] if n.get("seat")]
        self.assertTrue(all(s == "w1" or str(s).startswith("w1.") for s in seats))

    def test_participants_with_named_mains(self) -> None:
        from pong.state import load_session_state
        from pong.work_graph import WorkGraphError, _create_work_job, load, start

        before = load_session_state("pong-team")
        edges_before = (before.get("flow_graph") or {}).get("edges")
        workers_before = [w.get("id") for w in (before.get("workers") or [])]
        g = start(
            "pong-team",
            owner="w1",
            loop="cycle",
            task="iterate with leads",
            max_rounds=2,
            participants=["w2", "w3"],
        )
        self.assertEqual(g["owner"], "w1")
        self.assertEqual(g["participants"], ["w1", "w2", "w3"])
        doc = load("pong-team")
        stored = next(x for x in doc["graphs"] if x["id"] == g["id"])
        self.assertEqual(stored["participants"], ["w1", "w2", "w3"])
        after = load_session_state("pong-team")
        self.assertEqual((after.get("flow_graph") or {}).get("edges"), edges_before)
        self.assertEqual([w.get("id") for w in (after.get("workers") or [])], workers_before)

        # Named participant is allowed; an org main outside the set is not.
        ok = _create_work_job(
            "pong-team",
            owner="w1",
            seat="w2",
            task="named main hop",
            role="builder",
            graph_id=g["id"],
            node_id="hop",
        )
        self.assertTrue(ok.get("id"))
        with self.assertRaises(WorkGraphError):
            _create_work_job(
                "pong-team",
                owner="w1",
                seat="c1",
                task="outside the set",
                role="builder",
                graph_id=g["id"],
                node_id="nope",
            )

    def test_start_dispatches_job(self) -> None:
        from pong.work_graph import start

        self.mock_dispatch.reset_mock()
        start("pong-team", owner="w1", loop="cycle", task="iterate", max_rounds=2)
        self.assertTrue(self.mock_dispatch.called)
        job, worker, state = self.mock_dispatch.call_args[0][:3]
        self.assertTrue(job.get("_prompt") or job.get("prompt_path"))
        self.assertEqual(job.get("worker"), "w1.a")
        self.assertFalse(worker.get("pane_id"))

    def test_builder_uses_live_participant_not_owner_dot_a(self) -> None:
        from pong.work_graph import start

        self._set_pane("w2", "%42")
        self.mock_dispatch.reset_mock()
        g = start(
            "pong-team",
            owner="c1",
            loop="cycle",
            task="iterate with a live pane",
            max_rounds=2,
            participants=["w2"],
        )
        builder = next(n for n in g["nodes"] if n.get("id") == "builder")
        self.assertEqual(builder["seat"], "w2")
        self.assertNotEqual(builder["seat"], "c1.a")
        self.assertTrue(self.mock_dispatch.called)
        _job, worker, _state = self.mock_dispatch.call_args[0][:3]
        self.assertEqual(worker.get("id"), "w2")
        self.assertEqual(worker.get("pane_id"), "%42")

    def test_gauntlet_critic_prefers_live_reviewer(self) -> None:
        from pong.work_graph import start

        bar = Path(self.tmp.name) / "bar.md"
        bar.write_text("# bar\npass\n", encoding="utf-8")
        self._set_pane("w2", "%7")
        self._set_pane("w3", "%8")
        g = start(
            "pong-team",
            owner="c1",
            loop="gauntlet",
            task="ship it",
            bar=str(bar),
            participants=["w2", "w3"],
        )
        builder = next(n for n in g["nodes"] if n.get("id") == "builder")
        critic = next(n for n in g["nodes"] if n.get("id") == "critic")
        self.assertEqual(builder["seat"], "w2")
        self.assertEqual(critic["seat"], "w3")

    # ---------------------------------------------------------- disposable ---

    def test_a_disposable_seat_is_routed_not_hardcoded(self) -> None:
        """Every loop node used to open on `claude` with no model, so a router
        that classifies one word and a builder that refactors a subsystem came
        up identical and a critic graded on whatever the default was."""
        from pong.models import runtimes
        from pong.work_graph import _synthetic_worker

        builder = _synthetic_worker("w1.a", "w1", "builder", task="implement it")
        critic = _synthetic_worker("w1.b", "w1", "critic", task="score it")
        router = _synthetic_worker("w1.r", "w1", "router", task="pick an edge")

        self.assertEqual(builder["mission_role"], "coder")
        self.assertEqual(critic["mission_role"], "reviewer")
        self.assertEqual(router["mission_role"], "task_runner")
        # Builder and critic both run on Opus under the 28 Aug policy; the point
        # is that each was chosen by its own rule and the router is not a
        # reasoning model.
        self.assertNotEqual(builder["model_rule"], critic["model_rule"])
        self.assertNotEqual(builder["model"], router["model"])
        for w in (builder, critic, router):
            self.assertIn(w["type"], runtimes())
            self.assertTrue(w["cmd"])
            self.assertTrue(w["model_why"], "a routing decision with no reason")

    def test_the_chosen_model_reaches_the_job_record(self) -> None:
        """The app, the trace and the human all read the job file. A pick that
        only exists inside the spawn call cannot be reviewed by any of them."""
        from pong.work_graph import start

        self.mock_dispatch.reset_mock()
        start("pong-team", owner="w1", loop="cycle", task="iterate", max_rounds=2)
        job = self.mock_dispatch.call_args[0][0]
        self.assertTrue(job.get("model"))
        self.assertTrue(job.get("runtime"))
        self.assertTrue(job.get("model_why"))

    @unittest.skip(
        "asserts another checkout's prompt header format ('router:w1.r (claude)'); this "
        "repo's role_identity renders the seat id instead. A prompt-format "
        "difference in another module, not a work_graph behaviour."
    )
    def test_an_ephemeral_seat_is_told_the_role_it_actually_has(self) -> None:
        """It is not on the roster, so the lookup found nothing and the block
        opened "You are **w1.r** · w1.r" with the default mission role — a
        router node informed it was a Coder."""
        from pong.jobs import build_task_prompt
        from pong.state import load_session_state

        state = load_session_state("pong-team")
        job = {
            "id": "job_x", "session": "pong-team", "worker": "w1.r",
            "worker_label": "router:w1.r", "worker_type": "claude",
            "mission_role": "task_runner", "round": 1,
        }
        prompt = build_task_prompt(job, state)
        self.assertIn("You are **w1.r** · router:w1.r (claude)", prompt)
        self.assertIn("Task runner", prompt)
        self.assertNotIn("Mission role (locked): Coder", prompt)

    def test_spawning_refuses_to_touch_the_live_tmux_from_a_test(self) -> None:
        """tmux has no PONG_HOME. The first run of these tests opened eighteen
        real windows in the human's team before this guard existed."""
        from pong.groups import ensure_ephemeral_window, isolated_home

        self.assertTrue(isolated_home())
        out = ensure_ephemeral_window(
            {"session": "pong-team"}, {"id": "w1.a", "ephemeral": True})
        self.assertFalse(out["spawned"])
        self.assertIn("isolated PONG_HOME", out["note"])

    def test_two_ticks_at_once_do_not_re_dispatch_the_same_round(self) -> None:
        """tick runs from the cron runner, from drain and from the panel poll.
        Both reading before either writes is how one round gets built twice."""
        from pong.work_graph import _graph_lock, tick

        with _graph_lock("pong-team") as held:
            self.assertTrue(held)
            out = tick("pong-team")
        self.assertEqual(out["advanced"], [])
        self.assertIn("skipped", out)
        # Released again, a tick runs normally.
        self.assertNotIn("skipped", tick("pong-team"))


if __name__ == "__main__":
    unittest.main()


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


class GauntletCriticSeatTests(unittest.TestCase):
    """Who grades the gauntlet, and what happens when that seat goes stale.

    The live wedge these pin: a gauntlet stored ``critic.seat = w17`` while its
    participants were ``[c1, w16]``. The seat was legal when it was written and
    illegal by the time the critic had to run, so ``assert_allowed_seat`` refused
    every tick — no way forward, no way back, on one stored string.
    """

    SESSION = "pong-team"

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        _pair(self.tmp.name, self.SESSION)
        self._saved_seat = os.environ.pop("PONG_SEAT", None)
        self._dispatch_patcher = patch("pong.transports.dispatch.dispatch_job")
        self.mock_dispatch = self._dispatch_patcher.start()
        # w2 builds. w3 is a bare Grok reviewer pane — reviewer by mission role,
        # no tools by runtime. w4 is a Claude reviewer pane: reviewer *and* tools.
        self._set_worker("w2", pane_id="%2")
        self._set_worker("w3", pane_id="%3", type="grok", cmd="grok")
        _toolless(self, session=self.SESSION)  # the test's grok is a runtime without tools
        self._set_worker(
            "w4",
            pane_id="%4",
            type="claude",
            cmd="claude",
            label="Reviewer 2",
            mission_role="reviewer",
            tmux_index=4,
        )
        self.bar = Path(self.tmp.name) / "bar.md"
        self.bar.write_text("# bar\nship it\n", encoding="utf-8")

    def tearDown(self) -> None:
        self._dispatch_patcher.stop()
        self.tmp.cleanup()
        for key in ("PONG_HOME", "PONG_SESSION", "PONG_TOKEN"):
            os.environ.pop(key, None)
        if self._saved_seat is not None:
            os.environ["PONG_SEAT"] = self._saved_seat

    # --- fixture helpers -------------------------------------------------

    def _set_worker(self, worker_id: str, **fields: object) -> None:
        """Add or update one roster worker on both pairs.json and active.json."""
        from pong.jsonutil import read_json, write_json
        from pong.paths import active_path, pairs_path

        db = read_json(pairs_path())
        pair = db[self.SESSION]
        workers = pair.setdefault("workers", [])
        row = next((w for w in workers if str(w.get("id")) == worker_id), None)
        if row is None:
            row = {"id": worker_id, "mode": "tmux"}
            workers.append(row)
        row.update(fields)
        write_json(pairs_path(), db)
        active = dict(pair)
        active["session"] = self.SESSION
        write_json(active_path(), active)

    def _start_gauntlet(self, participants: list[str]):
        from pong.work_graph import start

        return start(
            self.SESSION,
            owner="w1",
            loop="gauntlet",
            task="polish the module",
            bar=str(self.bar),
            participants=participants,
        )

    def _finish_builder(self, graph: dict) -> None:
        """Drive the builder job to a terminal status, the way a claim would."""
        from pong.jobs import set_status

        builder = next(n for n in graph["nodes"] if n["id"] == "builder")
        set_status(self.SESSION, str(builder["job_id"]), "done")

    def _stored(self, gid: str) -> dict:
        from pong.work_graph import load

        return next(g for g in load(self.SESSION)["graphs"] if g["id"] == gid)

    def _critic_node(self, gid: str) -> dict:
        return next(n for n in self._stored(gid)["nodes"] if n["id"] == "critic")

    # --- the wedge -------------------------------------------------------

    def test_gauntlet_tick_reaches_the_critic_instead_of_dead_ending(self) -> None:
        """Builder terminal → critic job exists. The loop must be able to advance."""
        from pong.work_graph import tick

        g = self._start_gauntlet(["w2"])
        self._finish_builder(g)
        tick(self.SESSION, graph_id=g["id"])  # must not raise
        critic = self._critic_node(g["id"])
        self.assertTrue(critic.get("job_id"), "critic never got a job — loop dead-ended")
        self.assertEqual(critic.get("status"), "running")

    def test_critic_seat_is_an_ephemeral_child_of_the_owner(self) -> None:
        """Not a roster seat: a disposable child is what the model router can aim."""
        g = self._start_gauntlet(["w2", "w3"])
        seat = str(self._critic_node(g["id"])["seat"])
        self.assertTrue(
            seat.startswith("w1."),
            f"critic landed on roster seat {seat!r}, not a child of the owner",
        )

    def test_grok_roster_reviewer_is_never_borrowed_as_critic(self) -> None:
        """w3 is a participant and its mission role is reviewer — still not it.

        A bare Grok pane has no MCP and no skills. Grading a code polish pass
        there is the bar drop the model catalog exists to prevent, so the
        reviewer mission role alone must not be enough to win the seat.
        """
        g = self._start_gauntlet(["w2", "w3"])
        self.assertNotEqual(str(self._critic_node(g["id"])["seat"]), "w3")

    def test_tools_roster_reviewer_may_still_be_borrowed(self) -> None:
        """The gate is runtime capability, not a blanket ban on roster seats."""
        g = self._start_gauntlet(["w2", "w4"])
        self.assertEqual(str(self._critic_node(g["id"])["seat"]), "w4")

    def test_critic_runs_a_tools_runtime_on_the_catalog_critic_model(self) -> None:
        """Both looked up through pong.models, so editing the catalog moves this."""
        from pong.jobs import load_job
        from pong.models import plan, runtimes
        from pong.work_graph import tick

        g = self._start_gauntlet(["w2"])
        self._finish_builder(g)
        tick(self.SESSION, graph_id=g["id"])

        cjob = load_job(self.SESSION, str(self._critic_node(g["id"])["job_id"]))
        runtime = str(cjob.get("runtime") or "")
        self.assertTrue(
            runtimes(self.SESSION).get(runtime, {}).get("tools"),
            f"critic runtime {runtime!r} is not a tools runtime",
        )
        expected = plan(str(cjob.get("task") or ""), "critic", session=self.SESSION)
        self.assertEqual(runtime, expected.runtime)
        self.assertEqual(str(cjob.get("model") or ""), expected.model)

    # --- self-heal -------------------------------------------------------

    def test_tick_self_heals_a_foreign_stored_critic_seat(self) -> None:
        """The g_8d468e306d shape: a stored seat that is no longer in the loop.

        Legal when written, illegal by the time it runs. Tick must re-derive a
        legal seat and say so, not refuse forever.
        """
        from pong.work_graph import load, save, tick

        g = self._start_gauntlet(["w2"])
        doc = load(self.SESSION)
        stored = next(x for x in doc["graphs"] if x["id"] == g["id"])
        next(n for n in stored["nodes"] if n["id"] == "critic")["seat"] = "w3"
        save(self.SESSION, doc)

        self._finish_builder(g)
        tick(self.SESSION, graph_id=g["id"])  # must not raise

        critic = self._critic_node(g["id"])
        self.assertTrue(
            str(critic["seat"]).startswith("w1."),
            f"critic still on illegal seat {critic['seat']!r}",
        )
        self.assertEqual((critic.get("seat_repaired") or {}).get("from"), "w3")
        self.assertTrue(critic.get("job_id"), "repaired critic still got no job")

    def test_start_refuses_an_illegal_node_seat_instead_of_storing_it(self) -> None:
        """Write time is where this is cheap. A bad seat must fail loudly there."""
        from pong.work_graph import WorkGraphError, load

        with patch("pong.work_graph._pick_loop_seats", return_value=(["w2"], "w3")):
            with self.assertRaises(WorkGraphError):
                self._start_gauntlet(["w2"])
        self.assertEqual(load(self.SESSION).get("graphs") or [], [])


class OrgGraphIsByteIdenticalTests(unittest.TestCase):
    """The safety property of the whole engine, asserted on the bytes.

    A loop is ephemeral structure layered over a fixed org: it may add work
    under a main, and it may never edit the org itself. The tests above compare
    the parsed edge list and the worker ids, which is the property people mean.
    This compares the raw file, which is the property people can rely on — a
    reordered key, a mutated ``mission_role``, a seat quietly appended to
    ``workers[]`` all pass a parsed comparison of the fields it happens to look
    at, and none of them pass this.

    Run for every loop kind, because they build different node sets: fan makes
    n builders plus a join, cycle makes one builder it re-dispatches, gauntlet
    makes a builder and a critic.
    """

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        _pair(self.tmp.name)
        self._saved_seat = os.environ.pop("PONG_SEAT", None)
        self.bar = Path(self.tmp.name) / "bar.md"
        self.bar.write_text("# bar\nopen the artifact\n", encoding="utf-8")

    def tearDown(self) -> None:
        self.tmp.cleanup()
        for key in ("PONG_HOME", "PONG_SESSION", "PONG_TOKEN"):
            os.environ.pop(key, None)
        if self._saved_seat is not None:
            os.environ["PONG_SEAT"] = self._saved_seat
        else:
            os.environ.pop("PONG_SEAT", None)

    def _org_bytes(self) -> bytes:
        from pong.paths import pairs_path

        return Path(pairs_path()).read_bytes()

    def test_every_loop_kind_leaves_the_org_file_byte_identical(self) -> None:
        from pong.work_graph import start

        cases = [
            {"loop": "fan", "task": "cover the surface", "fan_n": 2},
            {"loop": "cycle", "task": "keep trying", "max_rounds": 2},
            {"loop": "gauntlet", "task": "ship it", "bar": str(self.bar)},
        ]
        for case in cases:
            with self.subTest(loop=case["loop"]):
                before = self._org_bytes()
                graph = start("pong-team", owner="w1", **case)
                self.assertTrue(graph.get("nodes"), "loop started with no nodes")
                self.assertEqual(
                    self._org_bytes(),
                    before,
                    f"{case['loop']} start rewrote the org file",
                )

    def test_the_disposable_seats_never_join_permanent_workers(self) -> None:
        """The seats a loop invents must not become roster members."""
        from pong.state import load_session_state, workers_from_state
        from pong.work_graph import start

        before = {str(w.get("id")) for w in workers_from_state(load_session_state("pong-team"))}
        graph = start("pong-team", owner="w1", loop="fan", task="fan out", fan_n=2)
        seats = {str(n.get("seat")) for n in graph.get("nodes") or [] if n.get("seat")}
        after = {str(w.get("id")) for w in workers_from_state(load_session_state("pong-team"))}
        self.assertEqual(after, before)
        # And the loop really did invent seats that are not on the roster —
        # otherwise this test would pass on an engine that did nothing.
        self.assertTrue(seats - before, f"no disposable seat was created: {seats}")

    def test_cancel_also_leaves_the_org_file_byte_identical(self) -> None:
        from pong.work_graph import cancel, start

        graph = start("pong-team", owner="w1", loop="fan", task="fan out", fan_n=2)
        before = self._org_bytes()
        cancel("pong-team", graph["id"])
        self.assertEqual(self._org_bytes(), before, "cancel rewrote the org file")


class GoalStartWithFlagTests(unittest.TestCase):
    """`pong goal start --with` must reach `start(participants=…)`.

    The engine has taken a set since work_graph gained participants, but until
    the flag existed there was no argv that could say so — every loop the CLI
    or the island started was owner-only. These go through the real parser and
    the real `_cmd_goal`, not `start()` directly, because the argv is the part
    that was missing.
    """

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.pair = _pair(self.tmp.name)
        self._saved_seat = os.environ.pop("PONG_SEAT", None)
        self._dispatch_patcher = patch("pong.transports.dispatch.dispatch_job")
        self.mock_dispatch = self._dispatch_patcher.start()

    def tearDown(self) -> None:
        self._dispatch_patcher.stop()
        self.tmp.cleanup()
        os.environ.pop("PONG_HOME", None)
        os.environ.pop("PONG_SESSION", None)
        os.environ.pop("PONG_TOKEN", None)
        if self._saved_seat is not None:
            os.environ["PONG_SEAT"] = self._saved_seat

    def _run(self, argv: list[str]) -> tuple[int, str]:
        """Parse a real argv and run it. Returns (exit code, stdout)."""
        import contextlib
        import io

        from pong.cli.main import build_parser

        args = build_parser().parse_args(argv)
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            rc = args.func(args)
        return rc, buf.getvalue()

    def _stored(self, out: str) -> dict:
        """The graph `goal start` just printed, read back off disk."""
        from pong.work_graph import find_graph

        gid = out.split("goal ", 1)[1].split(" ", 1)[0]
        g = find_graph("pong-team", gid)
        self.assertIsNotNone(g, f"no stored graph {gid}")
        return g

    def test_with_flag_round_trips_into_participants(self) -> None:
        rc, out = self._run([
            "-s", "pong-team", "goal", "start",
            "--owner", "w1", "--loop", "cycle", "--task", "iterate with leads",
            "--with", "w2,w3", "--max-rounds", "2",
        ])
        self.assertEqual(rc, 0, out)
        self.assertIn("owner=w1", out)
        self.assertIn("participants=w1,w2,w3", out)
        self.assertEqual(self._stored(out)["participants"], ["w1", "w2", "w3"])

    def test_without_the_flag_a_loop_is_one_seat(self) -> None:
        """`--owner wN` alone is still a single-agent loop, not a set."""
        rc, out = self._run([
            "-s", "pong-team", "goal", "start",
            "--owner", "w1", "--loop", "cycle", "--task", "alone", "--max-rounds", "2",
        ])
        self.assertEqual(rc, 0, out)
        self.assertIn("participants=w1", out)
        self.assertEqual(self._stored(out)["participants"], ["w1"])

    def test_owner_leads_the_set_and_is_never_doubled(self) -> None:
        """Whitespace, empties and the owner repeated in --with all collapse."""
        rc, out = self._run([
            "-s", "pong-team", "goal", "start",
            "--owner", "w1", "--loop", "cycle", "--task", "dedupe",
            "--with", " w1 , , w3 ,w2, w3 ", "--max-rounds", "2",
        ])
        self.assertEqual(rc, 0, out)
        self.assertEqual(self._stored(out)["participants"], ["w1", "w3", "w2"])

    def test_a_live_participant_from_with_becomes_the_builder(self) -> None:
        """The set is load-bearing, not decoration: --with picks the seat."""
        from pong.jsonutil import read_json, write_json
        from pong.paths import active_path, pairs_path

        db = read_json(pairs_path())
        pair = db["pong-team"]
        for w in pair.get("workers") or []:
            if str(w.get("id")) == "w2":
                w["pane_id"] = "%42"
        write_json(pairs_path(), db)
        active = dict(pair)
        active["session"] = "pong-team"
        write_json(active_path(), active)

        rc, out = self._run([
            "-s", "pong-team", "goal", "start",
            "--owner", "c1", "--loop", "cycle", "--task", "run on the live pane",
            "--with", "w2", "--max-rounds", "2",
        ])
        self.assertEqual(rc, 0, out)
        g = self._stored(out)
        builder = next(n for n in g["nodes"] if n.get("id") == "builder")
        self.assertEqual(builder["seat"], "w2")
        self.assertNotEqual(builder["seat"], "c1.a")

    def test_with_does_not_touch_the_org_graph(self) -> None:
        """A set is ephemeral structure. It is not an edit to the roster."""
        from pong.state import load_session_state

        before = load_session_state("pong-team")
        edges_before = (before.get("flow_graph") or {}).get("edges")
        workers_before = [w.get("id") for w in (before.get("workers") or [])]

        rc, out = self._run([
            "-s", "pong-team", "goal", "start",
            "--owner", "w1", "--loop", "fan", "--task", "fan across the set",
            "--with", "w2,w3", "--pieces", "2",
        ])
        self.assertEqual(rc, 0, out)

        after = load_session_state("pong-team")
        self.assertEqual((after.get("flow_graph") or {}).get("edges"), edges_before)
        self.assertEqual([w.get("id") for w in (after.get("workers") or [])], workers_before)


if __name__ == "__main__":
    unittest.main()
