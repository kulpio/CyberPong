#!/usr/bin/env python3
"""Waitroom delivery: availability gate, claim digest, job defer, force paths."""

from __future__ import annotations

import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "python"))


class WaitroomTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        os.environ["PONG_HOME"] = self.tmp.name
        os.environ["PONG_SESSION"] = "pong-team"
        self._saved_seat = os.environ.pop("PONG_SEAT", None)
        os.environ.pop("PONG_CLAIM_PASTE", None)
        os.environ.pop("PONG_WAITROOM_COOLDOWN", None)
        os.environ.pop("PONG_WAITROOM_GRACE", None)
        os.environ.pop("PONG_FORCE_JOB_PASTE", None)
        os.environ.pop("PONG_CLAIM_DIGEST_BUSY_SEC", None)
        os.environ.pop("PONG_HUMAN_BUSY_SEC", None)
        from pong.paths import ensure_layout, pairs_path, active_path
        from pong.jsonutil import write_json

        ensure_layout("pong-team")
        pair = {
            "schema_version": 2,
            "conductor": {
                "id": "c1",
                "type": "grok",
                "label": "Grok",
                "cmd": "grok",
                "mode": "tmux",
                "tmux_index": 0,
            },
            "workers": [
                {
                    "id": "w1",
                    "type": "claude",
                    "label": "Builder",
                    "cmd": "claude",
                    "tmux_index": 1,
                    "mission_role": "coder",
                },
                {
                    "id": "w2",
                    "type": "claude",
                    "label": "Checker",
                    "cmd": "claude",
                    "tmux_index": 2,
                    "mission_role": "reviewer",
                },
            ],
            "transport_default": "job+paste",
        }
        write_json(pairs_path(), {"pong-team": pair})
        active = dict(pair)
        active["session"] = "pong-team"
        write_json(active_path(), active)
        self.pastes: list[tuple[str, str, str]] = []

    def tearDown(self) -> None:
        self.tmp.cleanup()
        os.environ.pop("PONG_HOME", None)
        os.environ.pop("PONG_SESSION", None)
        os.environ.pop("PONG_CLAIM_PASTE", None)
        os.environ.pop("PONG_WAITROOM_GRACE", None)
        os.environ.pop("PONG_FORCE_JOB_PASTE", None)
        os.environ.pop("PONG_CLAIM_DIGEST_BUSY_SEC", None)
        os.environ.pop("PONG_HUMAN_BUSY_SEC", None)
        if self._saved_seat is not None:
            os.environ["PONG_SEAT"] = self._saved_seat
        else:
            os.environ.pop("PONG_SEAT", None)

    def _paste(self, session: str, seat: str, text: str, state: dict) -> bool:
        self.pastes.append((session, seat, text))
        return True

    def test_claim_held_when_c1_busy(self) -> None:
        from pong.jobs import create_job, record_claim
        from pong.seat_status import set_busy, is_available
        from pong.waitroom import list_items

        set_busy("pong-team", "c1", reason="verifying")
        self.assertFalse(is_available("pong-team", "c1"))
        with mock.patch("pong.waitroom._default_paste", side_effect=self._paste):
            j = create_job(
                session="pong-team",
                worker_key="w1",
                task="Do thing",
                require_claim=True,
                extra={"from_seat": "c1"},
            )
            # force job file only path for create — no paste needed
            from pong.transports.dispatch import dispatch_job, parse_transport_plan

            dispatch_job(
                j,
                j["_worker"],
                j["_state"],
                plan=parse_transport_plan("job"),
            )
            record_claim(
                "pong-team",
                j["id"],
                summary="built foo",
                files=["a.swift"],
            )
        # Claim recorded but no paste to busy c1
        self.assertEqual(self.pastes, [])
        queued = list_items("pong-team", status="queued")
        self.assertEqual(len(queued), 1)
        self.assertEqual(queued[0]["kind"], "claim")
        self.assertEqual(queued[0]["to"], "c1")

    def test_claim_digest_when_c1_available(self) -> None:
        from pong.jobs import create_job, record_claim, load_job
        from pong.seat_status import set_available, is_available
        from pong.waitroom import list_items
        from pong.transports.dispatch import dispatch_job, parse_transport_plan

        set_available("pong-team", "c1")
        self.assertTrue(is_available("pong-team", "c1"))
        with mock.patch("pong.waitroom._default_paste", side_effect=self._paste):
            j = create_job(
                session="pong-team",
                worker_key="w1",
                task="Do thing",
                require_claim=True,
                extra={"from_seat": "c1"},
            )
            dispatch_job(
                j, j["_worker"], j["_state"], plan=parse_transport_plan("job")
            )
            record_claim(
                "pong-team",
                j["id"],
                summary="built foo",
                files=["a.swift"],
            )
        self.assertEqual(len(self.pastes), 1)
        self.assertEqual(self.pastes[0][1], "c1")
        self.assertIn("CLAIM READY", self.pastes[0][2])
        self.assertEqual(list_items("pong-team", status="queued"), [])
        # Claim digest must NOT stick c1 busy forever (starvation fix)
        self.assertTrue(is_available("pong-team", "c1"))
        loaded = load_job("pong-team", j["id"])
        self.assertEqual(loaded["status"], "done")

    def test_second_claim_batch_without_manual_available(self) -> None:
        """After first digest, more claims auto-deliver (grace only, no sticky busy)."""
        from pong.jobs import create_job, record_claim
        from pong.seat_status import set_available, is_available
        from pong.transports.dispatch import dispatch_job, parse_transport_plan

        set_available("pong-team", "c1")
        os.environ["PONG_WAITROOM_GRACE"] = "0"  # isolate availability from grace

        def claim_one(worker: str, summary: str) -> None:
            j = create_job(
                session="pong-team",
                worker_key=worker,
                task=summary,
                require_claim=True,
                extra={"from_seat": "c1"},
            )
            dispatch_job(
                j, j["_worker"], j["_state"], plan=parse_transport_plan("job")
            )
            record_claim("pong-team", j["id"], summary=summary)

        with mock.patch("pong.waitroom._default_paste", side_effect=self._paste):
            claim_one("w1", "first batch")
            self.assertEqual(len(self.pastes), 1)
            self.assertTrue(is_available("pong-team", "c1"))
            claim_one("w2", "second batch")
            # Second digest delivered without pong seat available
            self.assertEqual(len(self.pastes), 2)
            self.assertIn("second batch", self.pastes[1][2])

    def test_legacy_claim_digest_busy_ttl(self) -> None:
        """Old claim_digest busy rows auto-free after short TTL."""
        from pong.seat_status import (
            is_available,
            load_seat_status,
            save_seat_status,
            set_busy,
        )

        os.environ["PONG_CLAIM_DIGEST_BUSY_SEC"] = "5"
        set_busy("pong-team", "c1", reason="claim_digest")
        data = load_seat_status("pong-team")
        data["seats"]["c1"]["updated_at"] = __import__("time").time() - 30
        save_seat_status("pong-team", data)
        self.assertTrue(is_available("pong-team", "c1"))

    def test_enqueue_claim_dedupes_same_summary(self) -> None:
        from pong.waitroom import enqueue_claim, list_items

        a = enqueue_claim(
            "pong-team",
            to="c1",
            from_worker="w10",
            job_id="job_a",
            summary="We filed Research’s Gauntlet, chat and connector-OAuth findings",
        )
        b = enqueue_claim(
            "pong-team",
            to="c1",
            from_worker="w10",
            job_id="job_b",
            summary="┃ ┃ We filed Research’s Gauntlet, chat and connector-OAuth findings",
        )
        self.assertEqual(a["id"], b["id"])
        self.assertEqual(len(list_items("pong-team")), 1)

    def test_human_busy_blocks_then_ttl(self) -> None:
        from pong.seat_status import (
            is_available,
            load_seat_status,
            save_seat_status,
            set_busy,
        )
        from pong.waitroom import enqueue_claim, list_items, try_deliver

        set_busy("pong-team", "c1", reason="human")
        enqueue_claim(
            "pong-team",
            to="c1",
            from_worker="w1",
            job_id="job_h",
            summary="held while human",
        )
        r = try_deliver("pong-team", force=False, paste_fn=self._paste)
        self.assertEqual(r["delivered"], [])
        self.assertEqual(len(list_items("pong-team", status="queued")), 1)
        os.environ["PONG_HUMAN_BUSY_SEC"] = "10"
        data = load_seat_status("pong-team")
        data["seats"]["c1"]["updated_at"] = __import__("time").time() - 60
        save_seat_status("pong-team", data)
        self.assertTrue(is_available("pong-team", "c1"))
        r2 = try_deliver("pong-team", force=False, paste_fn=self._paste)
        self.assertEqual(len(r2["delivered"]), 1)

    def test_job_deferred_when_worker_busy(self) -> None:
        from pong.jobs import create_job, load_job
        from pong.seat_status import set_busy, is_available
        from pong.waitroom import list_items
        from pong.transports.dispatch import dispatch_job, parse_transport_plan

        set_busy("pong-team", "w1", reason="working")
        j = create_job(
            session="pong-team",
            worker_key="w1",
            task="Second task",
            require_claim=True,
            extra={"from_seat": "c1"},
        )
        with mock.patch("pong.waitroom._default_paste", side_effect=self._paste):
            results = dispatch_job(
                j,
                j["_worker"],
                j["_state"],
                plan=parse_transport_plan("job+paste"),
            )
        self.assertTrue(any(r.name == "waitroom" and r.ok for r in results))
        loaded = load_job("pong-team", j["id"])
        self.assertEqual(loaded["status"], "queued")
        jobs_q = list_items("pong-team", status="queued", kind="job")
        self.assertEqual(len(jobs_q), 1)
        self.assertEqual(jobs_q[0]["to"], "w1")
        # No job prompt paste while busy
        self.assertEqual(self.pastes, [])

        # Free worker → try_deliver pastes job
        from pong.seat_status import set_available
        from pong.waitroom import try_deliver

        set_available("pong-team", "w1")
        # Write a prompt file for delivery
        Path(j["prompt_path"]).write_text("## JOB test\nSecond task\n", encoding="utf-8")
        with mock.patch("pong.waitroom._default_paste", side_effect=self._paste):
            r = try_deliver("pong-team", to="w1", force=False, paste_fn=self._paste)
        self.assertEqual(len(r["delivered"]), 1)
        self.assertEqual(r["delivered"][0]["kind"], "job")
        self.assertEqual(len(self.pastes), 1)
        loaded2 = load_job("pong-team", j["id"])
        self.assertEqual(loaded2["status"], "notified")
        self.assertFalse(is_available("pong-team", "w1"))

    def test_force_paste_bypasses_busy(self) -> None:
        from pong.jobs import create_job, load_job
        from pong.seat_status import set_busy
        from pong.transports.dispatch import dispatch_job, parse_transport_plan

        set_busy("pong-team", "w1", reason="working")
        j = create_job(
            session="pong-team",
            worker_key="w1",
            task="Forced",
            extra={"from_seat": "c1"},
        )
        # Mock paste success without real tmux
        with mock.patch(
            "pong.transports.tmux_paste.send",
            return_value=__import__(
                "pong.transports.base", fromlist=["TransportResult"]
            ).TransportResult("tmux_paste", True, "ok"),
        ):
            results = dispatch_job(
                j,
                j["_worker"],
                j["_state"],
                plan=parse_transport_plan("job+paste"),
                force_paste=True,
            )
        self.assertTrue(any(r.name == "tmux_paste" and r.ok for r in results))
        self.assertFalse(any(r.name == "waitroom" for r in results))
        self.assertEqual(load_job("pong-team", j["id"])["status"], "notified")

    def test_notify_paste_escape_hatch(self) -> None:
        from pong.flow import notify_claim
        from pong.state import load_session_state
        from pong.waitroom import list_items

        pastes: list[str] = []

        def capture(session, seat, text, state):
            pastes.append(text)
            return True

        st = load_session_state("pong-team") or {"session": "pong-team"}
        notify_claim(
            st,
            {"id": "job_x", "session": "pong-team", "worker": "w1"},
            {"summary": "immediate!", "files": ["x.py"]},
            immediate=True,
            paste_fn=capture,
        )
        self.assertEqual(len(pastes), 1)
        self.assertIn("—— CLAIM · w1", pastes[0])
        self.assertEqual(list_items("pong-team", status="queued"), [])

    def test_digest_batches_multiple(self) -> None:
        from pong.waitroom import enqueue_claim, format_digest, list_items, try_deliver
        from pong.seat_status import set_available

        enqueue_claim(
            "pong-team", to="c1", from_worker="w4", job_id="job_a", summary="done A"
        )
        enqueue_claim(
            "pong-team", to="c1", from_worker="w5", job_id="job_b", summary="done B"
        )
        text = format_digest(list_items("pong-team", status="queued"), seat="c1")
        self.assertIn("CLAIMS READY · 2", text)
        set_available("pong-team", "c1")
        r = try_deliver("pong-team", force=False, paste_fn=self._paste)
        self.assertEqual(r["delivered"][0]["count"], 2)
        self.assertEqual(len(self.pastes), 1)

    def test_grace_not_12s_primary(self) -> None:
        """Grace is short anti-double-paste; availability is the real gate."""
        from pong.waitroom import _grace_sec, can_deliver
        from pong.seat_status import set_busy, set_available

        self.assertLessEqual(_grace_sec(), 30.0)
        set_busy("pong-team", "c1")
        ok, reason = can_deliver("pong-team", "c1", force=False)
        self.assertFalse(ok)
        self.assertIn("seat_busy", reason)
        set_available("pong-team", "c1")
        ok2, reason2 = can_deliver("pong-team", "c1", force=False)
        self.assertTrue(ok2)

    def test_single_claim_digest_shape(self) -> None:
        from pong.waitroom import format_digest

        text = format_digest(
            [
                {
                    "kind": "claim",
                    "from": "w1",
                    "job_id": "job_1",
                    "summary": "one liner",
                    "files": ["a.py"],
                }
            ]
        )
        self.assertIn("CLAIM READY", text)
        self.assertIn("one liner", text)

    def _open_parent_on(self, worker: str, task: str = "parent work"):
        from pong.jobs import create_job, save_job
        from pong.seat_status import set_busy

        j = create_job(
            session="pong-team",
            worker_key=worker,
            task=task,
            require_claim=True,
            extra={"from_seat": "c1"},
        )
        j["status"] = "notified"
        save_job(j)
        set_busy("pong-team", worker, reason="job", job_id=j["id"])
        return j

    def test_claim_lands_on_idle_seat_with_open_parent_job(self) -> None:
        """Leads waiting on children must receive claims without --force."""
        from pong.seat_status import is_available
        from pong.waitroom import can_deliver, enqueue_claim, list_items, try_deliver

        self._open_parent_on("w1")
        self.assertFalse(is_available("pong-team", "w1"))
        ok_job, _ = can_deliver("pong-team", "w1", kind="job")
        self.assertFalse(ok_job)
        ok_claim, reason = can_deliver("pong-team", "w1", kind="claim")
        self.assertTrue(ok_claim, reason)
        enqueue_claim(
            "pong-team",
            to="w1",
            from_worker="w2",
            job_id="job_child",
            summary="child filled briefs",
        )
        r = try_deliver("pong-team", to="w1", force=False, paste_fn=self._paste)
        self.assertEqual(len(r["delivered"]), 1)
        self.assertEqual(r["delivered"][0]["kind"], "claim_digest")
        self.assertEqual(list_items("pong-team", status="queued", to="w1"), [])
        self.assertIn("child filled briefs", self.pastes[0][2])

    def test_job_still_held_when_seat_has_open_parent(self) -> None:
        from pong.waitroom import enqueue_job, list_items, try_deliver

        self._open_parent_on("w1")
        enqueue_job("pong-team", to="w1", job_id="job_second", summary="next job")
        r = try_deliver("pong-team", to="w1", force=False, paste_fn=self._paste)
        self.assertEqual(r["delivered"], [])
        self.assertTrue(r["held"])
        self.assertEqual(len(list_items("pong-team", status="queued", kind="job")), 1)
        self.assertEqual(self.pastes, [])

    def test_human_busy_holds_claim_even_with_open_job(self) -> None:
        from pong.seat_status import set_busy
        from pong.waitroom import enqueue_claim, list_items, try_deliver

        self._open_parent_on("w1")
        set_busy("pong-team", "w1", reason="human")
        enqueue_claim(
            "pong-team",
            to="w1",
            from_worker="w2",
            job_id="job_child",
            summary="should stay queued",
        )
        r = try_deliver("pong-team", to="w1", force=False, paste_fn=self._paste)
        self.assertEqual(r["delivered"], [])
        self.assertEqual(len(list_items("pong-team", status="queued")), 1)

    def test_pane_thinking_holds_claim_even_with_open_job(self) -> None:
        from pong.waitroom import enqueue_claim, list_items, try_deliver

        self._open_parent_on("w1")
        enqueue_claim(
            "pong-team",
            to="w1",
            from_worker="w2",
            job_id="job_child",
            summary="thinking hold",
        )
        with mock.patch("pong.waitroom._target_pane_thinking", return_value=True):
            r = try_deliver("pong-team", to="w1", force=False, paste_fn=self._paste)
        self.assertEqual(r["delivered"], [])
        self.assertEqual(r["held"][0]["reason"], "pane_thinking")
        self.assertEqual(len(list_items("pong-team", status="queued")), 1)

    def test_claim_lands_when_job_item_is_also_queued(self) -> None:
        """Open parent holds the next job paste; child claim still flushes."""
        from pong.waitroom import enqueue_claim, enqueue_job, list_items, try_deliver

        self._open_parent_on("w1")
        enqueue_job("pong-team", to="w1", job_id="job_next", summary="follow-on")
        enqueue_claim(
            "pong-team",
            to="w1",
            from_worker="w2",
            job_id="job_child",
            summary="child done",
        )
        r = try_deliver("pong-team", to="w1", force=False, paste_fn=self._paste)
        kinds = {d.get("kind") for d in r["delivered"]}
        self.assertEqual(kinds, {"claim_digest"})
        self.assertTrue(any(h.get("kind") == "job" for h in r["held"]))
        self.assertEqual(len(list_items("pong-team", status="queued", kind="job")), 1)
        self.assertEqual(list_items("pong-team", status="queued", kind="claim"), [])


    # --- force must not stomp a pane that is mid-turn ---------------------

    def _queue_second_job_for(self, worker: str, task: str = "follow-on"):
        """Queue a *new* job paste at a seat that already holds an open one."""
        from pong.jobs import create_job
        from pong.waitroom import enqueue_job

        j = create_job(
            session="pong-team",
            worker_key=worker,
            task=task,
            require_claim=True,
            extra={"from_seat": "c1"},
        )
        enqueue_job("pong-team", to=worker, job_id=j["id"], summary=task)
        return j

    def test_can_deliver_force_refuses_thinking_pane_but_lifts_seat_state(self) -> None:
        """force is for seat state (human busy, open job, grace) — never for a live turn."""
        from pong.seat_status import set_busy
        from pong.waitroom import can_deliver

        set_busy("pong-team", "c1", reason="human")
        with mock.patch("pong.waitroom._target_pane_thinking", return_value=True):
            ok, reason = can_deliver("pong-team", "c1", force=True)
        self.assertFalse(ok)
        self.assertEqual(reason, "pane_thinking")
        # Same seat, same human-busy row, pane idle → force still lands.
        with mock.patch("pong.waitroom._target_pane_thinking", return_value=False):
            ok2, reason2 = can_deliver("pong-team", "c1", force=True)
        self.assertTrue(ok2)
        self.assertEqual(reason2, "force")

    def test_forced_job_into_thinking_pane_stays_queued(self) -> None:
        from pong.jobs import load_job
        from pong.waitroom import list_items, try_deliver

        self._open_parent_on("w1")
        nxt = self._queue_second_job_for("w1")
        with mock.patch("pong.waitroom._target_pane_thinking", return_value=True):
            r = try_deliver("pong-team", to="w1", force=True, paste_fn=self._paste)
        self.assertEqual(r["delivered"], [])
        self.assertEqual(r["held"][0]["reason"], "pane_thinking")
        self.assertEqual(self.pastes, [])
        # Queued, not dropped: the next drain retries it.
        still = list_items("pong-team", status="queued", kind="job")
        self.assertEqual([it["job_id"] for it in still], [nxt["id"]])
        self.assertEqual(load_job("pong-team", nxt["id"])["status"], "queued")

    def test_forced_job_lands_on_idle_seat_with_open_job(self) -> None:
        """The path leads rely on: seat busy only because a job is open, pane idle."""
        from pong.jobs import load_job
        from pong.waitroom import list_items, try_deliver

        self._open_parent_on("w1")
        nxt = self._queue_second_job_for("w1")
        # Without force the open-job hold blocks it.
        held = try_deliver("pong-team", to="w1", force=False, paste_fn=self._paste)
        self.assertEqual(held["delivered"], [])
        with mock.patch("pong.waitroom._target_pane_thinking", return_value=False):
            r = try_deliver("pong-team", to="w1", force=True, paste_fn=self._paste)
        self.assertEqual(len(r["delivered"]), 1)
        self.assertEqual(r["delivered"][0]["kind"], "job")
        self.assertEqual(r["delivered"][0]["job_id"], nxt["id"])
        self.assertEqual(len(self.pastes), 1)
        self.assertEqual(load_job("pong-team", nxt["id"])["status"], "notified")
        self.assertEqual(list_items("pong-team", status="queued", kind="job"), [])

    def test_forced_claim_into_thinking_pane_stays_queued(self) -> None:
        from pong.seat_status import set_busy
        from pong.waitroom import enqueue_claim, list_items, try_deliver

        set_busy("pong-team", "c1", reason="human")
        enqueue_claim(
            "pong-team",
            to="c1",
            from_worker="w1",
            job_id="job_mid_turn",
            summary="do not stomp the chief",
        )
        with mock.patch("pong.waitroom._target_pane_thinking", return_value=True):
            r = try_deliver("pong-team", to="c1", force=True, paste_fn=self._paste)
        self.assertEqual(r["delivered"], [])
        self.assertEqual(r["held"][0]["reason"], "pane_thinking")
        self.assertEqual(self.pastes, [])
        self.assertEqual(len(list_items("pong-team", status="queued")), 1)
        # Pane goes idle → the same forced drain delivers it.
        with mock.patch("pong.waitroom._target_pane_thinking", return_value=False):
            r2 = try_deliver("pong-team", to="c1", force=True, paste_fn=self._paste)
        self.assertEqual(len(r2["delivered"]), 1)
        self.assertEqual(list_items("pong-team", status="queued"), [])

    def test_drain_force_cannot_be_defeated_by_env(self) -> None:
        """No env override exists that pastes into a live turn."""
        from pong.waitroom import drain, list_items

        self._open_parent_on("w1")
        self._queue_second_job_for("w1")
        for var in ("PONG_FORCE_JOB_PASTE", "PONG_CLAIM_PASTE", "PONG_WAITROOM_GRACE"):
            os.environ[var] = "1"
        try:
            with mock.patch("pong.waitroom._target_pane_thinking", return_value=True):
                r = drain("pong-team", to="w1", force=True, paste_fn=self._paste)
        finally:
            for var in ("PONG_FORCE_JOB_PASTE", "PONG_CLAIM_PASTE", "PONG_WAITROOM_GRACE"):
                os.environ.pop(var, None)
        self.assertEqual(r["delivered"], [])
        self.assertEqual(len(list_items("pong-team", status="queued", kind="job")), 1)
        self.assertEqual(self.pastes, [])

    # --- one job paste per seat per drain pass ---------------------------

    def test_one_job_paste_per_seat_per_drain_pass(self) -> None:
        """try_deliver takes jobs[0] and continues — claims batch, jobs do not."""
        from pong.jobs import load_job, set_status
        from pong.seat_status import is_available, set_available
        from pong.waitroom import list_items, try_deliver

        os.environ["PONG_WAITROOM_GRACE"] = "0"
        first = self._queue_second_job_for("w1", "first job")
        second = self._queue_second_job_for("w1", "second job")
        set_available("pong-team", "w1")

        r = try_deliver("pong-team", to="w1", force=False, paste_fn=self._paste)
        self.assertEqual(len(r["delivered"]), 1)
        self.assertEqual(r["delivered"][0]["count"], 1)
        self.assertEqual(r["delivered"][0]["job_id"], first["id"])
        self.assertEqual(len(self.pastes), 1)
        left = list_items("pong-team", status="queued", kind="job")
        self.assertEqual([it["job_id"] for it in left], [second["id"]])

        # A second pass right away changes nothing: the job just pasted is open,
        # so the seat holds the next one. Serialised by seat state, not by luck.
        r_hold = try_deliver("pong-team", to="w1", force=False, paste_fn=self._paste)
        self.assertEqual(r_hold["delivered"], [])
        self.assertIn("open_job", r_hold["held"][0]["reason"])
        self.assertEqual(len(self.pastes), 1)

        # Close the first job → the seat frees → the second job lands, alone.
        # Closing a job writes a snapshot, and that snapshot drains the waitroom
        # (snapshot._autodrain), so the paste happens inside set_status. The
        # promise is "exactly one more paste, and it is the second job" — not
        # "the next explicit try_deliver is the call that pastes". Patch the
        # default paste so the autodrain lands in the same recorder.
        with mock.patch("pong.waitroom._default_paste", side_effect=self._paste):
            set_status("pong-team", first["id"], "done")
        self.assertEqual(len(self.pastes), 2)
        self.assertEqual(self.pastes[1][1], "w1")
        self.assertIn("second job", self.pastes[1][2])
        self.assertEqual(list_items("pong-team", status="queued", kind="job"), [])
        self.assertEqual(load_job("pong-team", second["id"])["status"], "notified")
        # The seat is now held by the second job — freed once, not left open.
        self.assertFalse(is_available("pong-team", "w1"))
        # Nothing is left for a further pass to double-paste.
        r2 = try_deliver("pong-team", to="w1", force=False, paste_fn=self._paste)
        self.assertEqual(r2["delivered"], [])
        self.assertEqual(len(self.pastes), 2)

    def test_forced_drain_also_pastes_one_job_per_seat(self) -> None:
        from pong.waitroom import list_items, try_deliver

        self._queue_second_job_for("w1", "forced first")
        self._queue_second_job_for("w1", "forced second")
        with mock.patch("pong.waitroom._target_pane_thinking", return_value=False):
            r = try_deliver("pong-team", to="w1", force=True, paste_fn=self._paste)
        self.assertEqual(len(r["delivered"]), 1)
        self.assertEqual(len(self.pastes), 1)
        self.assertEqual(len(list_items("pong-team", status="queued", kind="job")), 1)

    # --- escape hatch obeys the pane gate --------------------------------

    def _notify_immediate(self, worker: str = "w1", summary: str = "immediate!"):
        """Run the PONG_CLAIM_PASTE path; return the texts it pasted."""
        from pong.flow import notify_claim
        from pong.state import load_session_state

        pastes: list[str] = []

        def capture(session, seat, text, state):
            pastes.append(text)
            return True

        st = load_session_state("pong-team") or {"session": "pong-team"}
        notify_claim(
            st,
            {"id": "job_x", "session": "pong-team", "worker": worker},
            {"summary": summary, "files": ["x.py"]},
            paste_fn=capture,
        )
        return pastes

    def test_claim_paste_env_into_thinking_pane_stays_queued(self) -> None:
        """PONG_CLAIM_PASTE skips the digest, never a live turn."""
        from pong.waitroom import list_items

        os.environ["PONG_CLAIM_PASTE"] = "1"
        with mock.patch("pong.waitroom._target_pane_thinking", return_value=True):
            pastes = self._notify_immediate()
        self.assertEqual(pastes, [])
        queued = list_items("pong-team", status="queued", kind="claim")
        self.assertEqual(len(queued), 1)
        self.assertEqual(queued[0]["to"], "c1")
        self.assertEqual(queued[0]["job_id"], "job_x")
        # And it is not lost: the next drain onto an idle pane delivers it.
        with mock.patch("pong.waitroom._target_pane_thinking", return_value=False):
            from pong.waitroom import try_deliver

            r = try_deliver("pong-team", to="c1", force=False, paste_fn=self._paste)
        self.assertEqual(len(r["delivered"]), 1)
        self.assertEqual(list_items("pong-team", status="queued", kind="claim"), [])

    def test_claim_paste_env_into_idle_pane_still_pastes(self) -> None:
        """The escape hatch keeps its point: idle target, immediate full paste."""
        from pong.waitroom import list_items

        os.environ["PONG_CLAIM_PASTE"] = "1"
        with mock.patch("pong.waitroom._target_pane_thinking", return_value=False):
            pastes = self._notify_immediate()
        self.assertEqual(len(pastes), 1)
        self.assertIn("—— CLAIM · w1", pastes[0])
        self.assertEqual(list_items("pong-team", status="queued"), [])

    # --- capture error is thinking; a dead session is not ----------------

    def _thinking_with_tmux(self, fake_tmux, seat: str = "w1") -> bool:
        from pong.waitroom import _target_pane_thinking

        with mock.patch("pong.waitroom._isolated_home", return_value=False), \
                mock.patch("pong.pane_activity._tmux", side_effect=fake_tmux):
            return _target_pane_thinking("pong-team", seat)

    def test_capture_error_is_treated_as_thinking(self) -> None:
        """An unreadable pane is held, not pasted into."""
        from pong.waitroom import can_deliver

        def fake_tmux(*args):
            if args[0] == "has-session":
                return True, ""
            return False, "no server running on /tmp/tmux-501/default"

        self.assertTrue(self._thinking_with_tmux(fake_tmux))
        # Fail-closed reaches the gate, and force cannot lift it.
        with mock.patch("pong.waitroom._isolated_home", return_value=False), \
                mock.patch("pong.pane_activity._tmux", side_effect=fake_tmux):
            ok, reason = can_deliver("pong-team", "w1", force=True)
        self.assertFalse(ok)
        self.assertEqual(reason, "pane_thinking")

    def test_missing_session_is_not_thinking(self) -> None:
        """Gone is not busy — a dead session must not wedge the queue."""

        def fake_tmux(*args):
            if args[0] == "has-session":
                return False, "can't find session: pong-team"
            raise AssertionError("must not capture a session that is gone")

        self.assertFalse(self._thinking_with_tmux(fake_tmux))

    def test_live_capture_still_decides_normally(self) -> None:
        """Control: a readable pane is still judged on its text."""

        def tmux_with(pane: str):
            def fake_tmux(*args):
                if args[0] == "has-session":
                    return True, ""
                return True, pane

            return fake_tmux

        self.assertTrue(
            self._thinking_with_tmux(tmux_with("⠹ Cogitating… (12s · esc to interrupt)"))
        )
        self.assertFalse(self._thinking_with_tmux(tmux_with("✻ Churned for 37s\n> ")))


if __name__ == "__main__":
    unittest.main()
