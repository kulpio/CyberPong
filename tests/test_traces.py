#!/usr/bin/env python3
"""Run traces: record shape, PONG_TRACE=0, PONG_HOME redirection, and the
non-negotiable — a failing trace write must not break a job or a claim."""

from __future__ import annotations

import io
import json
import os
import sys
import tempfile
import unittest
from contextlib import redirect_stderr
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "python"))

LANGSMITH_FIELDS = {
    "id",
    "trace_id",
    "parent_run_id",
    "name",
    "run_type",
    "start_time",
    "end_time",
    "inputs",
    "outputs",
    "error",
    "tags",
    "extra",
}


class TraceTestBase(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        os.environ["PONG_HOME"] = self.tmp.name
        os.environ["PONG_SESSION"] = "pong-team"
        os.environ.pop("PONG_TRACE", None)
        # This suite runs *inside* a live team: the seat/tmux env of the
        # real session would otherwise decide the flow edges under test.
        for k in ("TMUX", "PONG_SEAT", "PONG_FROM_SEAT", "PONG_CLAIM_PASTE"):
            os.environ.pop(k, None)
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
                    "label": "Lead",
                    "cmd": "claude",
                    "mode": "tmux",
                    "tmux_index": 1,
                },
                {
                    "id": "w2",
                    "type": "claude",
                    "label": "Coder",
                    "cmd": "claude",
                    "mode": "tmux",
                    "tmux_index": 2,
                    "parent_id": "w1",
                    "mission_role": "coder",
                },
            ],
            "transport_default": "job",
            "project_root": "/tmp/proj",
            "team_brief": "Trace it",
            "autonomy_level": "full",
        }
        write_json(pairs_path(), {"pong-team": pair})
        active = dict(pair)
        active["session"] = "pong-team"
        write_json(active_path(), active)

    def tearDown(self) -> None:
        self.tmp.cleanup()
        for k in ("PONG_HOME", "PONG_SESSION", "PONG_TRACE", "PONG_SEAT"):
            os.environ.pop(k, None)

    def make_job(self, worker: str = "w2") -> dict:
        from pong.jobs import create_job

        # w2's parent is w1, so w1 is the only seat with an edge to it —
        # assigning from anywhere else is a flow refusal, by design.
        return create_job(
            session="pong-team",
            worker_key=worker,
            task="Instrument the choke points.\nsecond line ignored",
            extra={"from_seat": "w1"},
        )

    def rows_for(self, job_id: str) -> list[dict]:
        from pong.traces import read_trace

        return read_trace("pong-team", job_id)


class RecordShapeTests(TraceTestBase):
    def test_trace_file_lands_under_pong_home(self) -> None:
        from pong.traces import trace_path

        job = self.make_job()
        path = trace_path("pong-team", job["id"])
        self.assertTrue(path.exists(), f"no trace file at {path}")
        # PONG_HOME redirection: nothing written to the real ~/.pong
        self.assertTrue(
            str(path).startswith(self.tmp.name),
            f"trace escaped PONG_HOME: {path}",
        )
        self.assertEqual(
            path.parent, Path(self.tmp.name) / "traces" / "pong-team"
        )

    def test_row_uses_langsmith_export_field_names(self) -> None:
        job = self.make_job()
        rows = self.rows_for(job["id"])
        self.assertTrue(rows)
        row = rows[0]
        self.assertEqual(set(row.keys()), LANGSMITH_FIELDS)
        self.assertEqual(row["name"], "job.create")
        self.assertIn(row["run_type"], ("chain", "tool", "llm"))
        # Root run: it *is* the trace, so no parent and id == trace_id
        self.assertIsNone(row["parent_run_id"])
        self.assertEqual(row["id"], row["trace_id"])
        # ISO 8601 with timezone, parseable by a replay script
        from datetime import datetime

        self.assertTrue(datetime.fromisoformat(row["start_time"]).tzinfo)
        # Pong specifics live under extra, never at the top level
        extra = row["extra"]
        self.assertEqual(extra["session"], "pong-team")
        self.assertEqual(extra["seat"], "w2")
        self.assertEqual(extra["parent_seat"], "w1")
        self.assertEqual(extra["mission_role"], "coder")
        self.assertEqual(extra["job_id"], job["id"])
        self.assertEqual(extra["job_status"], "queued")
        # Task is a one-liner, not the whole prompt
        self.assertEqual(
            row["inputs"]["task"], "Instrument the choke points."
        )

    def test_status_and_claim_share_one_trace_id(self) -> None:
        from pong.jobs import record_claim, set_status

        job = self.make_job()
        set_status("pong-team", job["id"], "running")
        record_claim(
            "pong-team",
            job["id"],
            files=["python/pong/traces.py"],
            commands="python3 -m unittest tests.test_traces",
            summary="wired the choke points",
        )
        rows = self.rows_for(job["id"])
        names = [r["name"] for r in rows]
        self.assertEqual(names[0], "job.create")
        self.assertIn("job.status.running", names)
        self.assertIn("job.claim", names)
        trace_ids = {r["trace_id"] for r in rows}
        self.assertEqual(len(trace_ids), 1, f"trace split across ids: {trace_ids}")
        for r in rows[1:]:
            self.assertEqual(r["parent_run_id"], rows[0]["id"])
        claim = next(r for r in rows if r["name"] == "job.claim")
        self.assertEqual(claim["outputs"]["files"], ["python/pong/traces.py"])
        self.assertIn("unittest", claim["outputs"]["commands"])

    def test_dispatch_records_one_run_per_transport(self) -> None:
        from pong.transports.dispatch import dispatch_job

        job = self.make_job()
        state = job["_state"]
        dispatch_job(job, job["_worker"], state, plan=["job_file"])
        rows = self.rows_for(job["id"])
        tool_rows = [r for r in rows if r["run_type"] == "tool"]
        self.assertTrue(tool_rows, f"no transport runs in {[r['name'] for r in rows]}")
        self.assertEqual(tool_rows[0]["name"], "transport.job_file")
        self.assertTrue(tool_rows[0]["outputs"]["ok"])
        self.assertIsNone(tool_rows[0]["error"])

    def test_failed_transport_carries_the_error(self) -> None:
        from pong.traces import transport_result

        job = self.make_job()
        transport_result(
            job, name="tmux_paste", ok=False, detail="no tmux server"
        )
        row = self.rows_for(job["id"])[-1]
        self.assertEqual(row["name"], "transport.tmux_paste")
        self.assertEqual(row["error"], "no tmux server")
        self.assertIn("error", row["tags"])

    def test_verdict_files_against_the_job_id(self) -> None:
        from pong import ledger

        job = self.make_job()
        ledger.record(
            task_id=job["id"],
            round_n=1,
            verdict="accept",
            evidence="tests green",
            session="pong-team",
            worker="w2",
        )
        row = self.rows_for(job["id"])[-1]
        self.assertEqual(row["name"], "ledger.verdict.accept")
        self.assertEqual(row["outputs"]["verdict"], "accept")
        self.assertEqual(row["outputs"]["evidence"], "tests green")
        self.assertEqual(row["trace_id"], self.rows_for(job["id"])[0]["trace_id"])

    def test_long_values_are_clipped_not_dropped(self) -> None:
        from pong.traces import record

        record(
            session="pong-team",
            job_id="job_clip",
            name="t",
            inputs={"blob": "x" * 9000},
        )
        row = self.rows_for("job_clip")[0]
        blob = row["inputs"]["blob"]
        self.assertLess(len(blob), 9000)
        self.assertTrue(blob.startswith("xxxx"))
        self.assertIn("[+5000]", blob)


class DisableTests(TraceTestBase):
    def test_pong_trace_0_writes_nothing(self) -> None:
        from pong.traces import trace_path

        os.environ["PONG_TRACE"] = "0"
        job = self.make_job()
        self.assertFalse(trace_path("pong-team", job["id"]).exists())
        self.assertFalse((Path(self.tmp.name) / "traces").exists())
        # …and the job itself is unaffected
        self.assertEqual(job["status"], "queued")

    def test_pong_trace_off_and_false_also_disable(self) -> None:
        from pong.traces import enabled

        for val, want in (
            ("0", False),
            ("false", False),
            ("off", False),
            ("no", False),
            ("1", True),
            ("", True),
        ):
            os.environ["PONG_TRACE"] = val
            self.assertEqual(enabled(), want, f"PONG_TRACE={val!r}")


class NeverBreakTheControlPlaneTests(TraceTestBase):
    """Tracing is observability. It gets zero votes on whether work happens."""

    def test_unwritable_traces_dir_does_not_break_create_or_claim(self) -> None:
        """The real failure: traces/ exists as a *file*, so mkdir raises."""
        from pong.jobs import load_job, record_claim
        from pong.traces import trace_path

        (Path(self.tmp.name) / "traces").write_text("not a directory")
        err = io.StringIO()
        with redirect_stderr(err):
            job = self.make_job()
            claimed = record_claim(
                "pong-team", job["id"], summary="still landed"
            )
        self.assertEqual(claimed["status"], "done")
        self.assertEqual(claimed["claim"]["summary"], "still landed")
        # Job JSON on disk is intact and readable
        self.assertEqual(load_job("pong-team", job["id"])["status"], "done")
        self.assertFalse(trace_path("pong-team", job["id"]).exists())
        # Degrades *visibly*: one stderr line, not a silent swallow
        self.assertIn("trace write disabled", err.getvalue())

    def test_disk_full_on_write_does_not_break_create_job(self) -> None:
        """ENOSPC on the trace file only — job JSON and prompt still land."""
        from pong.jobs import create_job, load_job

        real_open = Path.open

        def enospc(self_path, *a, **kw):
            if "traces" in self_path.parts:
                raise OSError(28, "No space left on device")
            return real_open(self_path, *a, **kw)

        err = io.StringIO()
        with mock.patch.object(Path, "open", enospc), redirect_stderr(err):
            job = create_job(
                session="pong-team",
                worker_key="w2",
                task="disk is full",
                extra={"from_seat": "w1"},
            )
        self.assertEqual(job["status"], "queued")
        self.assertEqual(load_job("pong-team", job["id"])["id"], job["id"])
        self.assertTrue(Path(job["prompt_path"]).exists())
        self.assertEqual(self.rows_for(job["id"]), [])
        self.assertIn("No space left on device", err.getvalue())

    def test_exploding_record_does_not_break_create_or_status(self) -> None:
        from pong import traces
        from pong.jobs import set_status

        with mock.patch.object(
            traces, "record", side_effect=RuntimeError("trace backend on fire")
        ), redirect_stderr(io.StringIO()):
            job = self.make_job()
            after = set_status("pong-team", job["id"], "running")
        self.assertEqual(after["status"], "running")

    def test_record_returns_none_instead_of_raising(self) -> None:
        from pong import traces

        with mock.patch.object(
            traces, "trace_path", side_effect=OSError("nope")
        ), redirect_stderr(io.StringIO()):
            self.assertIsNone(
                traces.record(session="pong-team", job_id="job_x", name="t")
            )

    def test_warns_once_per_reason_not_once_per_job(self) -> None:
        from pong import traces

        traces._warned.clear()
        err = io.StringIO()
        with mock.patch.object(
            traces, "trace_path", side_effect=OSError("nope")
        ), redirect_stderr(err):
            for _ in range(5):
                traces.record(session="pong-team", job_id="job_x", name="t")
        self.assertEqual(err.getvalue().count("trace write disabled"), 1)
        traces._warned.clear()


class ReadSideTests(TraceTestBase):
    def test_list_and_find_are_read_only(self) -> None:
        from pong.traces import find_trace, list_traces

        job = self.make_job()
        before = sorted(p.name for p in (Path(self.tmp.name) / "traces" / "pong-team").iterdir())
        rows = list_traces(limit=5)
        self.assertTrue(rows)
        self.assertEqual(rows[0]["job_id"], job["id"])
        self.assertEqual(rows[0]["session"], "pong-team")
        self.assertEqual(rows[0]["seat"], "w2")
        hit = find_trace(job["id"])
        self.assertIsNotNone(hit)
        self.assertEqual(hit[0], "pong-team")
        after = sorted(p.name for p in (Path(self.tmp.name) / "traces" / "pong-team").iterdir())
        self.assertEqual(before, after)

    def test_show_missing_job_returns_none_not_a_crash(self) -> None:
        from pong.traces import find_trace, read_trace

        self.assertIsNone(find_trace("job_does_not_exist"))
        self.assertEqual(read_trace("pong-team", "job_does_not_exist"), [])

    def test_corrupt_line_is_skipped_not_fatal(self) -> None:
        from pong.traces import read_trace, trace_path

        job = self.make_job()
        with trace_path("pong-team", job["id"]).open("a") as f:
            f.write("{not json\n")
        rows = read_trace("pong-team", job["id"])
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["name"], "job.create")

    def test_cli_traces_list_and_show(self) -> None:
        from contextlib import redirect_stdout

        from pong.cli.main import main

        job = self.make_job()
        out = io.StringIO()
        with redirect_stdout(out):
            self.assertEqual(main(["traces", "list", "--limit", "5"]), 0)
        self.assertIn(job["id"], out.getvalue())
        out = io.StringIO()
        with redirect_stdout(out):
            self.assertEqual(main(["traces", "show", job["id"], "--json"]), 0)
        rows = json.loads(out.getvalue())
        self.assertEqual(rows[0]["name"], "job.create")
        self.assertEqual(set(rows[0]), LANGSMITH_FIELDS)


if __name__ == "__main__":
    unittest.main()
