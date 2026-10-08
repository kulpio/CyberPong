#!/usr/bin/env python3
from __future__ import annotations

import os
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "python"))

from pong.claim_harvest import parse_pane_claim
from pong.pane_activity import is_thinking


JOB = {"id": "job_20260818_111554_3fefef", "worker": "w10"}

GROK_RECAP = """
     ❯ ## TEAM CONTEXT                                              11:15 AM
       - session: pong-team

  ┃  ◆ Recap
  ┃
  ┃  We wrote the house briefs and named Sam’s three emails missing
  ┃  after Analytics and Deep Research finished the mailbox hunt.

  ╭──────────────────────────────────────────────────────────────────────────╮
  │ ❯                                                                        │
  ╰─────────────────────────────────────── Grok 4.6 (high) · always-approve ─╯
"""

CLAUDE_CLAIM = """
CLAIM:
files: docs/client-briefs/pre-boarding.md, docs/client-briefs/deck.md
commands: wrote briefs; pong job claim forgotten
summary: House pre-boarding.md has the 8-step order. Sam emails MISSING.

##WORKER_DONE##

✻ Crunched for 2m 30s
❯
  ⏵⏵ auto mode on (shift+tab to cycle)
"""

HOLDING = """
  Sequence from here: w27 claims → I verify → claim to c1.
  Holding for Migrator's claim.

✻ Crunched for 2m 30s
❯
"""

OLD_CLAIM_OTHER_JOB = """
  summary: The code bar (live + draft) gains vendor_oauth
  claimed both Gauntlet jobs to Chief. job_20260817_193715_a7c03d

CLAIM:
files: none
commands: edited code.json
summary: vendor_oauth added to the code bar exactly as specified.

##WORKER_DONE##
❯
"""

WORKING = """
✶ Working on the invite link
ctrl+c to interrupt
"""


class ParsePaneClaimTests(unittest.TestCase):
    def test_grok_recap(self) -> None:
        parsed = parse_pane_claim(GROK_RECAP, JOB)
        self.assertIsNotNone(parsed)
        assert parsed is not None
        self.assertEqual(parsed["source"], "recap")
        self.assertIn("emails missing", parsed["summary"])
        self.assertFalse(is_thinking(GROK_RECAP))

    def test_claude_claim_block(self) -> None:
        parsed = parse_pane_claim(CLAUDE_CLAIM, JOB)
        self.assertIsNotNone(parsed)
        assert parsed is not None
        self.assertEqual(parsed["source"], "claim_block")
        self.assertEqual(
            parsed["files"],
            [
                "docs/client-briefs/pre-boarding.md",
                "docs/client-briefs/deck.md",
            ],
        )
        self.assertIn("MISSING", parsed["summary"])

    def test_holding_is_not_a_claim(self) -> None:
        self.assertIsNone(parse_pane_claim(HOLDING, JOB))

    def test_old_claim_for_other_job_is_ignored(self) -> None:
        self.assertIsNone(parse_pane_claim(OLD_CLAIM_OTHER_JOB, JOB))

    def test_empty(self) -> None:
        self.assertIsNone(parse_pane_claim("", JOB))
        self.assertIsNone(parse_pane_claim("   \n", JOB))


class HarvestRecordsTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        os.environ["PONG_HOME"] = self.tmp.name
        from pong.paths import ensure_layout, pairs_path, active_path
        from pong.jsonutil import write_json

        ensure_layout()
        pair = {
            "schema_version": 2,
            "conductor": {
                "id": "c1",
                "type": "hermes",
                "label": "Chief",
                "cmd": "hermes",
                "mode": "tmux",
                "tmux_index": 0,
            },
            "workers": [
                {
                    "id": "w10",
                    "type": "claude",
                    "label": "Research",
                    "cmd": "claude",
                    "mode": "tmux",
                    "tmux_index": 1,
                    "parent_id": "c1",
                }
            ],
            "transport_default": "job",
            "project_root": "/tmp/proj",
            "team_brief": "Ship",
            "autonomy_level": "full",
        }
        write_json(pairs_path(), {"pong-team": pair})
        active = dict(pair)
        active["session"] = "pong-team"
        write_json(active_path(), active)
        os.environ["PONG_SESSION"] = "pong-team"

    def tearDown(self) -> None:
        self.tmp.cleanup()
        os.environ.pop("PONG_HOME", None)
        os.environ.pop("PONG_SESSION", None)

    def test_harvest_records_recap_as_claim(self) -> None:
        from unittest import mock
        from pong.jobs import create_job, load_job, set_status
        from pong.claim_harvest import harvest_job

        job = create_job(session="pong-team", worker_key="w10", task="Write briefs")
        set_status("pong-team", job["id"], "notified")
        job = load_job("pong-team", job["id"])
        with mock.patch("pong.waitroom._default_paste", return_value=True):
            claimed = harvest_job("pong-team", job, pane=GROK_RECAP)
        self.assertIsNotNone(claimed)
        stored = load_job("pong-team", job["id"])
        self.assertEqual(stored["status"], "done")
        self.assertIn("emails missing", (stored.get("claim") or {}).get("summary") or "")

    def test_leftover_recap_is_not_harvested_onto_the_next_job(self) -> None:
        """A recap still on screen after it was harvested is the old job's claim, not the new one's."""
        from unittest import mock
        from pong.jobs import create_job, load_job, set_status
        from pong.claim_harvest import _looks_like_prior_claim, harvest_job

        stale = GROK_RECAP.replace(
            "We wrote the house briefs and named Sam’s three emails missing",
            "We filed Research’s vendor, chat and connector-OAuth findings",
        ).replace(
            "after Analytics and Deep Research finished the mailbox hunt.",
            "under ~/.pong then sent Analytics and Deep Research.",
        )
        first = create_job(session="pong-team", worker_key="w10", task="File findings")
        set_status("pong-team", first["id"], "notified")
        with mock.patch("pong.waitroom._default_paste", return_value=True):
            self.assertIsNotNone(harvest_job("pong-team", load_job("pong-team", first["id"]), pane=stale))
        self.assertEqual(load_job("pong-team", first["id"])["status"], "done")
        nxt = create_job(session="pong-team", worker_key="w10", task="Next thing")
        set_status("pong-team", nxt["id"], "notified")
        parsed = parse_pane_claim(stale, load_job("pong-team", nxt["id"]))
        self.assertIsNotNone(parsed)
        self.assertTrue(_looks_like_prior_claim("pong-team", "w10", parsed, exclude_job=nxt["id"]))
        with mock.patch("pong.waitroom._default_paste", return_value=True):
            self.assertIsNone(harvest_job("pong-team", load_job("pong-team", nxt["id"]), pane=stale))
        self.assertNotEqual(load_job("pong-team", nxt["id"])["status"], "done")
        self.assertFalse(_looks_like_prior_claim("pong-team", "w11", parsed, exclude_job=nxt["id"]),
                         "another seat's identical words are its own claim")

    def test_harvest_skips_thinking_pane(self) -> None:
        from pong.jobs import create_job, load_job, set_status
        from pong.claim_harvest import harvest_job

        job = create_job(session="pong-team", worker_key="w10", task="Write briefs")
        set_status("pong-team", job["id"], "notified")
        job = load_job("pong-team", job["id"])
        self.assertIsNone(harvest_job("pong-team", job, pane=WORKING))


if __name__ == "__main__":
    unittest.main()
