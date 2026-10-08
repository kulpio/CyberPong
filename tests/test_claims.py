#!/usr/bin/env python3
"""Claim board: job JSON + waitroom merge, unread marker, filters, no-tmux read."""

from __future__ import annotations

import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from unittest import mock

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "python"))


class ClaimBoardTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        os.environ["PONG_HOME"] = self.tmp.name
        os.environ["PONG_SESSION"] = "pong-team"
        self._saved_tmux = os.environ.pop("TMUX", None)
        self._saved_seat = os.environ.pop("PONG_SEAT", None)
        os.environ.pop("PONG_CLAIM_PASTE", None)
        os.environ.pop("PONG_WAITROOM_GRACE", None)
        from pong.jsonutil import write_json
        from pong.paths import active_path, ensure_layout, pairs_path

        ensure_layout("pong-team")
        pair = {
            "schema_version": 2,
            "conductor": {
                "id": "c1",
                "type": "grok",
                "label": "Chief",
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
        for key in ("PONG_HOME", "PONG_SESSION", "PONG_WAITROOM_GRACE"):
            os.environ.pop(key, None)
        if self._saved_tmux is not None:
            os.environ["TMUX"] = self._saved_tmux
        if self._saved_seat is not None:
            os.environ["PONG_SEAT"] = self._saved_seat

    def _paste(self, session: str, seat: str, text: str, state: dict) -> bool:
        self.pastes.append((session, seat, text))
        return True

    def _claim_from(self, worker: str, summary: str) -> dict:
        """Create a job for *worker* and record a claim on it (the real path)."""
        from pong.jobs import create_job, record_claim

        j = create_job(
            session="pong-team",
            worker_key=worker,
            task=summary,
            require_claim=True,
            extra={"from_seat": "c1"},
        )
        with mock.patch("pong.waitroom._default_paste", side_effect=self._paste):
            record_claim("pong-team", j["id"], summary=summary, files=["a.py"])
        return j

    def _row(self, board: dict, job_id: str) -> dict:
        for r in board["rows"]:
            if r["job_id"] == job_id:
                return r
        self.fail(f"{job_id} not on the board: {[r['job_id'] for r in board['rows']]}")

    # --- merge -----------------------------------------------------------

    def test_queued_claim_is_unread_and_merges_both_sources(self) -> None:
        from pong.claims import claim_board
        from pong.seat_status import set_busy

        set_busy("pong-team", "c1", reason="verifying")  # nothing delivers
        j = self._claim_from("w1", "built the thing")

        board = claim_board("pong-team")
        row = self._row(board, j["id"])
        self.assertTrue(row["unread"])
        self.assertEqual(row["waitroom_status"], "queued")
        self.assertEqual(sorted(row["sources"]), ["job", "waitroom"])
        self.assertEqual(row["worker"], "w1")
        self.assertEqual(row["worker_label"], "Builder")
        self.assertEqual(row["to"], "c1")
        self.assertIn("built the thing", row["summary"])
        self.assertEqual(row["job_status"], "done")
        self.assertEqual(board["unread"], 1)
        # Reading the board must not deliver anything.
        self.assertEqual(self.pastes, [])

    def test_delivered_claim_reads_as_read(self) -> None:
        from pong.claims import claim_board
        from pong.seat_status import set_available

        set_available("pong-team", "c1")
        j = self._claim_from("w1", "delivered straight away")

        self.assertEqual(len(self.pastes), 1)  # digest landed on an available c1
        row = self._row(claim_board("pong-team"), j["id"])
        self.assertFalse(row["unread"])
        self.assertEqual(row["waitroom_status"], "delivered")
        self.assertEqual(claim_board("pong-team")["unread"], 0)

    def test_waitroom_only_claim_shows_without_a_job_file(self) -> None:
        """Harvested/orphan items are still claims — the merge is a union."""
        from pong.claims import claim_board
        from pong.waitroom import enqueue_claim

        enqueue_claim(
            "pong-team",
            to="c1",
            from_worker="w2",
            job_id="job_no_file",
            summary="claim with no job on disk",
        )
        row = self._row(claim_board("pong-team"), "job_no_file")
        self.assertEqual(row["sources"], ["waitroom"])
        self.assertTrue(row["unread"])
        self.assertEqual(row["worker"], "w2")
        self.assertEqual(row["worker_label"], "Checker")
        self.assertEqual(row["to"], "c1")

    def test_job_only_claim_falls_back_to_the_architecture_target(self) -> None:
        """A claim recorded with no waitroom item reads as read, addressed to c1."""
        from pong.claims import claim_board
        from pong.jobs import create_job, save_job

        j = create_job(
            session="pong-team",
            worker_key="w1",
            task="claimed before the waitroom existed",
            extra={"from_seat": "c1"},
        )
        j["status"] = "done"
        j["claim"] = {"summary": "legacy claim", "files": [], "at": 1.0}
        save_job(j)

        row = self._row(claim_board("pong-team"), j["id"])
        self.assertEqual(row["sources"], ["job"])
        self.assertFalse(row["unread"])
        self.assertIsNone(row["waitroom_id"])
        self.assertEqual(row["to"], "c1")
        self.assertEqual(row["summary"], "legacy claim")

    def test_summary_falls_back_to_raw_when_summary_empty(self) -> None:
        from pong.claims import claim_board
        from pong.jobs import create_job, save_job

        j = create_job(
            session="pong-team",
            worker_key="w1",
            task="raw only",
            extra={"from_seat": "c1"},
        )
        j["status"] = "done"
        j["claim"] = {"summary": "", "raw": "CLAIM:\nfiles: x.py\nran   pytest", "at": 2.0}
        save_job(j)
        row = self._row(claim_board("pong-team"), j["id"])
        self.assertEqual(row["summary"], "CLAIM: files: x.py ran pytest")

    # --- filters ---------------------------------------------------------

    def test_seat_filter_matches_sender_and_target(self) -> None:
        from pong.claims import claim_board
        from pong.seat_status import set_busy
        from pong.waitroom import enqueue_claim

        set_busy("pong-team", "c1", reason="verifying")
        mine = self._claim_from("w1", "from w1 to c1")
        enqueue_claim(
            "pong-team",
            to="w1",
            from_worker="w2",
            job_id="job_child",
            summary="addressed to w1",
        )

        ids = {r["job_id"] for r in claim_board("pong-team", seat="w1")["rows"]}
        self.assertEqual(ids, {mine["id"], "job_child"})

        to_c1 = {r["job_id"] for r in claim_board("pong-team", seat="c1")["rows"]}
        self.assertIn(mine["id"], to_c1)
        self.assertNotIn("job_child", to_c1)

        self.assertEqual(claim_board("pong-team", seat="w9")["rows"], [])

    def test_unread_filter_and_limit(self) -> None:
        from pong.claims import claim_board
        from pong.seat_status import set_available, set_busy

        set_available("pong-team", "c1")
        os.environ["PONG_WAITROOM_GRACE"] = "0"
        read_job = self._claim_from("w1", "already delivered")
        set_busy("pong-team", "c1", reason="verifying")
        unread_job = self._claim_from("w2", "still queued")

        unread = claim_board("pong-team", unread_only=True)
        self.assertEqual([r["job_id"] for r in unread["rows"]], [unread_job["id"]])
        self.assertEqual(unread["matched"], 1)
        self.assertEqual(unread["total"], 2)

        newest_first = claim_board("pong-team", limit=1)
        self.assertEqual(newest_first["shown"], 1)
        self.assertEqual(newest_first["matched"], 2)
        self.assertEqual(newest_first["rows"][0]["job_id"], unread_job["id"])
        self.assertIn(read_job["id"], [r["job_id"] for r in claim_board("pong-team")["rows"]])

        self.assertEqual(claim_board("pong-team", limit=0)["shown"], 2)

    # --- read-only -------------------------------------------------------

    def test_board_never_delivers_or_marks_anything(self) -> None:
        from pong.claims import claim_board
        from pong.seat_status import get_status, set_busy
        from pong.waitroom import list_items

        set_busy("pong-team", "c1", reason="verifying")
        self._claim_from("w1", "must stay queued")
        before = json.dumps(list_items("pong-team", status=None), sort_keys=True)
        before_seat = json.dumps(get_status("pong-team", "c1"), sort_keys=True)

        for _ in range(3):
            claim_board("pong-team")

        self.assertEqual(
            json.dumps(list_items("pong-team", status=None), sort_keys=True), before
        )
        self.assertEqual(
            json.dumps(get_status("pong-team", "c1"), sort_keys=True), before_seat
        )
        self.assertEqual(self.pastes, [])

    # --- CLI -------------------------------------------------------------

    def _run_cli(self, argv: list[str]) -> tuple[int, str]:
        from pong.cli.main import main

        buf = io.StringIO()
        with redirect_stdout(buf):
            code = main(argv)
        return code, buf.getvalue()

    def test_cli_text_output_is_greppable_by_job_id(self) -> None:
        from pong.seat_status import set_busy

        set_busy("pong-team", "c1", reason="verifying")
        j = self._claim_from("w1", "greppable row")
        code, out = self._run_cli(["-s", "pong-team", "claims"])
        self.assertEqual(code, 0)
        hit = [ln for ln in out.splitlines() if j["id"] in ln]
        self.assertEqual(len(hit), 1, out)
        self.assertTrue(hit[0].startswith("UNREAD"), hit[0])
        self.assertIn("greppable row", hit[0])
        self.assertIn("w1 (Builder) → c1", hit[0])

    def test_cli_json_and_flags(self) -> None:
        from pong.seat_status import set_busy

        set_busy("pong-team", "c1", reason="verifying")
        j = self._claim_from("w1", "json row")
        code, out = self._run_cli(
            ["-s", "pong-team", "claims", "--json", "--unread", "--seat", "w1"]
        )
        self.assertEqual(code, 0)
        board = json.loads(out)
        self.assertEqual(board["session"], "pong-team")
        self.assertEqual(board["seat"], "w1")
        self.assertTrue(board["unread_only"])
        self.assertEqual([r["job_id"] for r in board["rows"]], [j["id"]])
        self.assertTrue(board["rows"][0]["unread"])

    def test_cli_limit_flag_is_an_int(self) -> None:
        from pong.seat_status import set_busy

        set_busy("pong-team", "c1", reason="verifying")
        self._claim_from("w1", "one")
        self._claim_from("w2", "two")
        code, out = self._run_cli(["-s", "pong-team", "claims", "--json", "--limit", "1"])
        self.assertEqual(code, 0)
        board = json.loads(out)
        self.assertEqual(board["shown"], 1)
        self.assertEqual(board["matched"], 2)

    # --- no tmux ---------------------------------------------------------

    def test_reads_with_no_tmux_and_no_session_env(self) -> None:
        """Falls back to active-pair and never shells out to tmux."""
        from pong.seat_status import set_busy

        set_busy("pong-team", "c1", reason="verifying")
        j = self._claim_from("w1", "no tmux here")

        os.environ.pop("PONG_SESSION", None)
        os.environ.pop("TMUX", None)

        def no_subprocess(*a, **kw):  # pragma: no cover - only fires on regression
            raise AssertionError(f"claim board shelled out: {a!r}")

        with mock.patch.object(subprocess, "run", side_effect=no_subprocess):
            code, out = self._run_cli(["claims"])
        self.assertEqual(code, 0)
        self.assertIn(j["id"], out)
        os.environ["PONG_SESSION"] = "pong-team"

    def test_no_state_on_disk_still_lists_claims(self) -> None:
        """Labels come from session state; losing it blanks a column, not a row."""
        from pong.claims import claim_board
        from pong.paths import active_path, pairs_path
        from pong.waitroom import enqueue_claim

        enqueue_claim(
            "pong-team",
            to="c1",
            from_worker="w1",
            job_id="job_stateless",
            summary="still readable",
        )
        pairs_path().unlink()
        active_path().unlink()

        row = self._row(claim_board("pong-team"), "job_stateless")
        self.assertEqual(row["worker"], "w1")
        self.assertEqual(row["worker_label"], "")
        self.assertEqual(row["to"], "c1")
        self.assertTrue(row["unread"])

    def test_empty_session_is_not_an_error(self) -> None:
        from pong.claims import claim_board, format_board

        board = claim_board("pong-team")
        self.assertEqual(board["rows"], [])
        self.assertEqual(board["total"], 0)
        self.assertIn("(no claims match)", format_board(board))


if __name__ == "__main__":
    unittest.main()
