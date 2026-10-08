#!/usr/bin/env python3
"""events.tail must not full-read huge logs; route.refused is rate-limited."""

from __future__ import annotations

import json
import os
import sys
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "python"))


class EventsTailTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        os.environ["PONG_HOME"] = self.tmp.name
        # Reset rate-limit map between tests
        import pong.events as events

        events._rate_last.clear()

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def test_tail_reads_only_end_of_large_file(self) -> None:
        from pong.events import events_path, tail, _read_tail_bytes, _TAIL_BYTES

        path = events_path()
        path.parent.mkdir(parents=True, exist_ok=True)
        # ~1MB of noise lines + a few real events at the end
        with path.open("w", encoding="utf-8") as f:
            for i in range(20_000):
                f.write(json.dumps({"ts": i, "type": "system", "session": "old", "n": i}) + "\n")
            for i in range(5):
                f.write(
                    json.dumps(
                        {
                            "ts": 1_000_000 + i,
                            "type": "job.status",
                            "session": "pong-team",
                            "job_id": f"job_{i}",
                        }
                    )
                    + "\n"
                )
        size = path.stat().st_size
        self.assertGreater(size, _TAIL_BYTES)

        chunk = _read_tail_bytes(path, _TAIL_BYTES)
        self.assertLessEqual(len(chunk), _TAIL_BYTES + 1)
        self.assertLess(len(chunk), size)

        rows = tail(10, session="pong-team")
        self.assertTrue(rows)
        self.assertTrue(all(r.get("session") == "pong-team" for r in rows))
        self.assertTrue(any(r.get("job_id") == "job_4" for r in rows))

    def test_route_refused_rate_limited(self) -> None:
        from pong.events import emit, events_path

        # First emit lands
        r1 = emit(
            "route.refused",
            session="pong-team",
            reason="token_mismatch",
            message="nope",
            target="hermes-pair-2",
        )
        self.assertNotIn("_dropped", r1)

        # Immediate same key → dropped
        r2 = emit(
            "route.refused",
            session="pong-team",
            reason="token_mismatch",
            message="nope again",
            target="hermes-pair-2",
        )
        self.assertEqual(r2.get("_dropped"), "rate_limited")

        # Different reason still allowed
        r3 = emit(
            "route.refused",
            session="pong-team",
            reason="other_reason",
            message="diff",
        )
        self.assertNotIn("_dropped", r3)

        # File has 2 lines (first + different reason), not 3
        lines = events_path().read_text(encoding="utf-8").strip().splitlines()
        self.assertEqual(len(lines), 2)

    def test_unrelated_events_not_rate_limited(self) -> None:
        from pong.events import emit, events_path

        for i in range(5):
            emit("job.status", session="pong-team", job_id=f"j{i}", status="done")
        lines = events_path().read_text(encoding="utf-8").strip().splitlines()
        self.assertEqual(len(lines), 5)


if __name__ == "__main__":
    unittest.main()
