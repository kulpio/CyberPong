#!/usr/bin/env python3
"""Drain: wait_on release; bubble stops at the goal owner."""

from __future__ import annotations

import os
import sys
import tempfile
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



class DrainTests(unittest.TestCase):
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

    def test_wait_on_release(self) -> None:
        from pong.drain import run
        from pong.jobs import record_claim
        from pong.work_graph import find_graph, start

        graph = start(
            "pong-team",
            owner="w2",
            loop="fan",
            task="split the work",
            fan_n=2,
        )
        jobs = graph.get("_jobs") or []
        self.assertEqual(len(jobs), 2)
        for j in jobs:
            record_claim("pong-team", j["id"], summary="slice done")
        result = run("pong-team", write_snap=True)
        self.assertIn(graph["id"], result.get("released") or [])
        fresh = find_graph("pong-team", graph["id"])
        join = next(n for n in fresh["nodes"] if n["id"] == "join")
        self.assertEqual(join["status"], "ready")

    def test_bubble_stops_at_owner(self) -> None:
        from pong.jobs import record_claim
        from pong.mailbox import peek
        from pong.work_graph import start

        graph = start(
            "pong-team",
            owner="w2",
            loop="cycle",
            task="iterate",
            max_rounds=3,
        )
        job = (graph.get("_jobs") or [])[0]
        record_claim("pong-team", job["id"], summary="win — shipped")
        owner_box = peek("pong-team", "w2", limit=0)
        orch_box = peek("pong-team", "c1", limit=0)
        self.assertTrue(any(i.get("job_id") == job["id"] for i in owner_box))
        self.assertFalse(
            any(i.get("job_id") == job["id"] for i in orch_box),
            "must not auto-bubble a work-graph claim to c1",
        )


if __name__ == "__main__":
    unittest.main()
