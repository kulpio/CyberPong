#!/usr/bin/env python3
"""Cron v2: first-due fires; catch-up once; token from file; real job.create."""

from __future__ import annotations

import os
import sys
import tempfile
import time
import unittest
from pathlib import Path

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
        ],
        "transport_default": "job",
        "flow_graph": {
            "edges": [
                {"from": "c1", "to": "w1", "kind": "delegate"},
                {"from": "w1", "to": "c1", "kind": "claim"},
                {"from": "c1", "to": "w2", "kind": "delegate"},
                {"from": "w2", "to": "c1", "kind": "claim"},
            ]
        },
    }
    write_json(pairs_path(), {session: pair})
    active = dict(pair)
    active["session"] = session
    write_json(active_path(), active)
    ensure_session_token(session)
    return pair



class CronV2Tests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        _pair(self.tmp.name)
        self._saved_seat = os.environ.pop("PONG_SEAT", None)

    def tearDown(self) -> None:
        self.tmp.cleanup()
        os.environ.pop("PONG_HOME", None)
        os.environ.pop("PONG_SESSION", None)
        os.environ.pop("PONG_TOKEN", None)
        if self._saved_seat is not None:
            os.environ["PONG_SEAT"] = self._saved_seat
        else:
            os.environ.pop("PONG_SEAT", None)

    def test_first_due_fires(self) -> None:
        from pong.cron import tick, upsert
        from pong.jobs import list_jobs
        from pong.routing import read_session_token

        tok = read_session_token("pong-team")
        self.assertTrue(tok)
        upsert(
            "pong-team",
            name="heartbeat",
            cadence="every 5m",
            task="cron heartbeat check",
            owner_id="w1",
            verb="job.create",
        )
        os.environ.pop("PONG_TOKEN", None)
        result = tick("pong-team", now=time.time())
        self.assertEqual(len(result["fired"]), 1)
        jobs = list_jobs("pong-team")
        self.assertTrue(jobs, "job.create must write a real job")
        self.assertIn("cron heartbeat", (jobs[0].get("task") or ""))
        self.assertEqual(os.environ.get("PONG_TOKEN"), tok)

    def test_catch_up_once(self) -> None:
        from pong.cron import load_schedules, tick, upsert

        row = upsert(
            "pong-team",
            name="stale",
            cadence="every 5m",
            task="catch-up once",
            owner_id="w1",
            verb="job.create",
        )
        now = time.time()
        # Pretend last fire was an hour ago (12 missed slots)
        db = load_schedules()
        for j in db["pong-team"]:
            if j["id"] == row["id"]:
                j["last_fired"] = now - 3600
        from pong.cron import save_schedules

        save_schedules(db)
        result = tick("pong-team", now=now)
        fired = [f for f in result["fired"] if f["id"] == row["id"]]
        self.assertEqual(len(fired), 1)
        # A second tick immediately must not fire again
        result2 = tick("pong-team", now=now + 1)
        fired2 = [f for f in result2["fired"] if f["id"] == row["id"]]
        self.assertEqual(len(fired2), 0)

    def test_token_from_file(self) -> None:
        from pong.cron import apply_token
        from pong.paths import sessions_dir

        path = sessions_dir("pong-team") / "token"
        path.write_text("file-token-abc\n", encoding="utf-8")
        os.environ.pop("PONG_TOKEN", None)
        tok = apply_token("pong-team")
        self.assertEqual(tok, "file-token-abc")
        self.assertEqual(os.environ["PONG_TOKEN"], "file-token-abc")
        self.assertEqual(os.environ["PONG_SESSION"], "pong-team")


if __name__ == "__main__":
    unittest.main()
