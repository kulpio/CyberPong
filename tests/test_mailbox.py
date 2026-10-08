#!/usr/bin/env python3
"""Mailbox: claim writes inbox even if paste raises."""

from __future__ import annotations

import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

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



class MailboxTests(unittest.TestCase):
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

    def test_claim_writes_mailbox_even_if_paste_raises(self) -> None:
        from pong.jobs import create_job, record_claim
        from pong.mailbox import peek
        from pong.transports.dispatch import dispatch_job, parse_transport_plan

        job = create_job(
            session="pong-team",
            worker_key="w1",
            task="Do the thing",
            extra={"from_seat": "c1"},
        )
        dispatch_job(job, job["_worker"], job["_state"], plan=parse_transport_plan("job"))
        with mock.patch(
            "pong.waitroom._default_paste",
            side_effect=RuntimeError("paste down"),
        ):
            claimed = record_claim(
                "pong-team",
                job["id"],
                files=["a.swift"],
                summary="built foo",
            )
        self.assertEqual(claimed["status"], "done")
        self.assertTrue(claimed.get("result"))
        self.assertEqual(claimed["result"]["artifacts"], ["a.swift"])
        unread = peek("pong-team", "c1", limit=0)
        self.assertTrue(unread, "mailbox must have the claim")
        self.assertEqual(unread[0]["job_id"], job["id"])
        self.assertEqual(unread[0]["kind"], "claim")
        self.assertEqual(unread[0]["from"], "w1")

    def test_peek_ack_list(self) -> None:
        from pong.mailbox import ack, list_items, peek, post

        a = post("pong-team", "w1", kind="note", summary="one")
        post("pong-team", "w1", kind="note", summary="two")
        unread = peek("pong-team", "w1", limit=0)
        self.assertEqual(len(unread), 2)
        ack("pong-team", "w1", [a["id"]])
        unread = peek("pong-team", "w1", limit=0)
        self.assertEqual(len(unread), 1)
        self.assertEqual(unread[0]["summary"], "two")
        all_items = list_items("pong-team", "w1")
        self.assertEqual(len(all_items), 2)


if __name__ == "__main__":
    unittest.main()
