#!/usr/bin/env python3
"""Seat busy/available + availability rules."""

from __future__ import annotations

import os
import sys
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "python"))


class SeatStatusTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        os.environ["PONG_HOME"] = self.tmp.name
        os.environ["PONG_SESSION"] = "pong-team"
        self._saved_seat = os.environ.pop("PONG_SEAT", None)
        os.environ.pop("PONG_SEAT_STALE_BUSY_SEC", None)
        from pong.paths import ensure_layout, pairs_path, active_path, jobs_dir
        from pong.jsonutil import write_json

        ensure_layout("pong-team")
        pair = {
            "schema_version": 2,
            "conductor": {
                "id": "c1",
                "type": "grok",
                "label": "Grok",
                "cmd": "grok",
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
                }
            ],
            "transport_default": "job",
        }
        write_json(pairs_path(), {"pong-team": pair})
        write_json(active_path(), {**pair, "session": "pong-team"})
        self.jobs_dir = jobs_dir("pong-team")

    def tearDown(self) -> None:
        self.tmp.cleanup()
        os.environ.pop("PONG_HOME", None)
        os.environ.pop("PONG_SESSION", None)
        if self._saved_seat is not None:
            os.environ["PONG_SEAT"] = self._saved_seat

    def test_cold_start_available(self) -> None:
        from pong.seat_status import is_available, availability

        self.assertTrue(is_available("pong-team", "c1"))
        self.assertTrue(is_available("pong-team", "w1"))
        ok, reason = availability("pong-team", "w1")
        self.assertTrue(ok)
        self.assertIn("default", reason)

    def test_explicit_busy_available(self) -> None:
        from pong.seat_status import is_available, set_available, set_busy

        set_busy("pong-team", "c1", reason="verifying", job_id="job_x")
        self.assertFalse(is_available("pong-team", "c1"))
        set_available("pong-team", "c1", reason="done")
        self.assertTrue(is_available("pong-team", "c1"))

    def test_open_job_makes_busy(self) -> None:
        from pong.jsonutil import write_json
        from pong.seat_status import is_available

        write_json(
            self.jobs_dir / "job_open_1.json",
            {
                "id": "job_open_1",
                "session": "pong-team",
                "worker": "w1",
                "status": "notified",
                "task": "x",
                "schema_version": 2,
                "created_at": time.time(),
                "updated_at": time.time(),
            },
        )
        self.assertFalse(is_available("pong-team", "w1"))
        self.assertTrue(is_available("pong-team", "c1"))

    def test_stale_busy_auto_available(self) -> None:
        from pong.seat_status import (
            is_available,
            load_seat_status,
            save_seat_status,
            set_busy,
        )

        os.environ["PONG_SEAT_STALE_BUSY_SEC"] = "10"
        set_busy("pong-team", "c1", reason="old")
        data = load_seat_status("pong-team")
        data["seats"]["c1"]["updated_at"] = time.time() - 100
        save_seat_status("pong-team", data)
        self.assertTrue(is_available("pong-team", "c1"))

    def _write_job(self, jid: str, status: str, worker: str = "w1") -> None:
        from pong.jsonutil import write_json

        write_json(
            self.jobs_dir / f"{jid}.json",
            {
                "id": jid,
                "session": "pong-team",
                "worker": worker,
                "status": status,
                "task": "x",
                "schema_version": 2,
                "created_at": time.time(),
                "updated_at": time.time(),
            },
        )

    def test_busy_row_does_not_outlive_the_job_it_names(self) -> None:
        """A seat held for job X frees when X closes — without waiting on stale."""
        from pong.seat_status import availability, is_available, set_busy

        for closed in ("done", "failed", "rejected", "cancelled"):
            with self.subTest(status=closed):
                jid = f"job_closed_{closed}"
                self._write_job(jid, "notified")
                set_busy("pong-team", "w1", reason="job", job_id=jid)
                self.assertFalse(is_available("pong-team", "w1"))
                # The close path that does NOT go through record_claim.
                self._write_job(jid, closed)
                ok, reason = availability("pong-team", "w1")
                self.assertTrue(ok)
                self.assertEqual(reason, "job_closed_auto_available")

    def test_human_takeover_keeps_the_seat_held(self) -> None:
        """Terminal for the job, not for the seat — a human holds that pane."""
        from pong.seat_status import is_available, set_busy

        self._write_job("job_takeover", "human_takeover")
        set_busy("pong-team", "w1", reason="job", job_id="job_takeover")
        self.assertFalse(is_available("pong-team", "w1"))

    def test_closed_job_does_not_free_a_seat_with_other_open_work(self) -> None:
        """One job closing never releases a seat that is still running another."""
        from pong.seat_status import availability, set_busy

        self._write_job("job_first", "done")
        self._write_job("job_second", "running")
        set_busy("pong-team", "w1", reason="job", job_id="job_first")
        ok, reason = availability("pong-team", "w1")
        self.assertFalse(ok)
        self.assertIn("job_second", reason)

    def test_unreadable_job_leaves_seat_held(self) -> None:
        """A busy row naming a job we cannot read falls back to the stale path."""
        from pong.seat_status import is_available, set_busy

        set_busy("pong-team", "w1", reason="job", job_id="job_never_written")
        self.assertFalse(is_available("pong-team", "w1"))


if __name__ == "__main__":
    unittest.main()
