#!/usr/bin/env python3
"""Loop catalog: fan+join; gauntlet critic isolation; cycle max_rounds."""

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



class LoopsTests(unittest.TestCase):
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

    def test_fan_then_join(self) -> None:
        from pong.jobs import record_claim
        from pong.work_graph import find_graph, start, tick

        graph = start(
            "pong-team",
            owner="w1",
            loop="fan",
            task="cover the surface",
            fan_n=2,
        )
        for j in graph.get("_jobs") or []:
            record_claim("pong-team", j["id"], summary="piece done")
        tick("pong-team")
        fresh = find_graph("pong-team", graph["id"])
        join = next(n for n in fresh["nodes"] if n["kind"] == "join")
        self.assertEqual(join["status"], "ready")
        self.assertEqual(fresh["status"], "done")

    def test_gauntlet_critic_has_no_builder_transcript(self) -> None:
        from pong.jobs import load_job, record_claim
        from pong.work_graph import find_graph, start, tick

        secret = "BUILDER_TRANSCRIPT_SECRET_XYZ"
        bar = Path(self.tmp.name) / "bar.md"
        bar.write_text("# quality bar\nno silent fails\n", encoding="utf-8")
        graph = start(
            "pong-team",
            owner="w1",
            loop="gauntlet",
            task="Build the feature. " + secret,
            bar=str(bar),
        )
        builder_job = (graph.get("_jobs") or [])[0]
        record_claim(
            "pong-team",
            builder_job["id"],
            files=["out/result.txt"],
            summary="built the artifact",
        )
        tick("pong-team")
        fresh = find_graph("pong-team", graph["id"])
        critic = next(n for n in fresh["nodes"] if n["id"] == "critic")
        self.assertTrue(critic.get("job_id"))
        cjob = load_job("pong-team", critic["job_id"])
        prompt = Path(cjob["prompt_path"]).read_text(encoding="utf-8")
        self.assertNotIn(secret, prompt)
        self.assertNotIn(secret, cjob.get("task") or "")
        self.assertIn(str(bar), cjob.get("task") or "")
        self.assertIn("out/result.txt", cjob.get("task") or "")

    def test_cycle_stops_at_max_rounds(self) -> None:
        from pong.jobs import record_claim
        from pong.work_graph import find_graph, start, tick

        graph = start(
            "pong-team",
            owner="w1",
            loop="cycle",
            task="keep trying",
            max_rounds=2,
        )
        j1 = (graph.get("_jobs") or [])[0]
        record_claim("pong-team", j1["id"], summary="fail — not yet")
        tick("pong-team")
        mid = find_graph("pong-team", graph["id"])
        self.assertEqual(mid["status"], "running")
        self.assertEqual(mid["round"], 2)
        builder = next(n for n in mid["nodes"] if n["id"] == "builder")
        record_claim("pong-team", builder["job_id"], summary="fail — still no")
        tick("pong-team")
        done = find_graph("pong-team", graph["id"])
        self.assertEqual(done["status"], "done")
        self.assertEqual(done.get("stop_reason"), "max_rounds")


if __name__ == "__main__":
    unittest.main()
