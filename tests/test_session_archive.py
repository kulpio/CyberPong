#!/usr/bin/env python3
"""Session vault smart-compress + archive store."""

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


class SessionArchiveTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        os.environ["PONG_HOME"] = self.tmp.name
        os.environ["PONG_SESSION"] = "pong-team"
        from pong.paths import ensure_layout, pairs_path, jobs_dir, ledger_dir
        from pong.jsonutil import write_json

        ensure_layout("pong-team")
        write_json(
            pairs_path(),
            {
                "pong-team": {
                    "schema_version": 2,
                    "display_name": "CyberPong",
                    "project_root": "/tmp/proj",
                    "team_brief": "Ship session vault with smart compress",
                    "conductor": {
                        "id": "c1",
                        "type": "grok",
                        "label": "Grok Build",
                    },
                    "workers": [
                        {
                            "id": "w1",
                            "type": "claude",
                            "label": "Builder",
                            "mission_role": "coder",
                        },
                        {
                            "id": "w2",
                            "type": "claude",
                            "label": "Checker",
                            "mission_role": "reviewer",
                        },
                    ],
                }
            },
        )
        jd = jobs_dir("pong-team")
        write_json(
            jd / "job_20260802_100000_aaaaaa.json",
            {
                "id": "job_20260802_100000_aaaaaa",
                "session": "pong-team",
                "worker": "w1",
                "status": "done",
                "task": "## BUILD — Vault foundation\n\nImplement archive store.",
                "claim": {
                    "summary": "Added session-archive layout and recap sections",
                    "files": "python/pong/session_archive.py",
                },
            },
        )
        write_json(
            jd / "job_20260802_110000_bbbbbb.json",
            {
                "id": "job_20260802_110000_bbbbbb",
                "session": "pong-team",
                "worker": "w1",
                "status": "notified",
                "task": "## BUILD — Wire UI next to Kill",
            },
        )
        led = ledger_dir()
        led.mkdir(parents=True, exist_ok=True)
        (led / "verdicts.jsonl").write_text(
            json.dumps(
                {
                    "ts": time.time(),
                    "session": "pong-team",
                    "task_id": "job_20260802_100000_aaaaaa",
                    "round": 1,
                    "verdict": "accept",
                    "evidence": "Recap has date goals decisions done next",
                }
            )
            + "\n",
            encoding="utf-8",
        )

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def test_recap_has_required_sections(self) -> None:
        from pong.session_archive import build_recap_markdown

        md = build_recap_markdown("pong-team", title="Test pack")
        self.assertIn("CONTINUITY RECAP", md)
        self.assertIn("Date / session identity", md)
        self.assertIn("Goals / destination", md)
        self.assertIn("Decisions & rationale", md)
        self.assertIn("Done (accepted", md)
        self.assertIn("Open / next", md)
        self.assertIn("Risks / human notes", md)
        self.assertIn("Ship session vault", md)
        self.assertIn("job_20260802_100000_aaaaaa", md)
        self.assertIn("accept", md)
        self.assertIn("notified", md)
        self.assertIn("/tmp/proj", md)
        self.assertIn("pong-team", md)

    def test_save_list_delete_rename(self) -> None:
        from pong.session_archive import (
            delete_archive,
            get_archive,
            list_archives,
            rename_archive,
            save_archive,
        )

        out = save_archive("pong-team", title="My compress")
        self.assertTrue(out["id"].startswith("sess_"))
        self.assertTrue(Path(out["recap_path"]).is_file())
        recap = Path(out["recap_path"]).read_text(encoding="utf-8")
        self.assertIn("CONTINUITY RECAP", recap)

        listed = list_archives()
        self.assertEqual(len(listed), 1)
        self.assertEqual(listed[0]["title"], "My compress")

        got = get_archive(out["id"])
        assert got is not None
        recap = got.get("recap") or ""
        self.assertIn("job_20260802_100000_aaaaaa", recap)
        self.assertIn("Recap has date goals decisions done next", recap)

        renamed = rename_archive(out["id"], "Renamed vault")
        assert renamed is not None
        self.assertEqual(renamed["title"], "Renamed vault")

        self.assertTrue(delete_archive(out["id"]))
        self.assertEqual(list_archives(), [])
        self.assertIsNone(get_archive(out["id"]))

    def test_save_does_not_require_bridge(self) -> None:
        """Archive works from files alone — no BRIDGE_ON gate."""
        from pong.session_archive import save_archive

        out = save_archive("pong-team")
        self.assertIn("id", out)
        self.assertTrue(Path(out["path"]).is_dir())

    def test_safe_archive_id_rejects_traversal(self) -> None:
        from pong.session_archive import safe_archive_id, archive_dir, delete_archive

        for bad in (
            "",
            ".",
            "..",
            "../",
            "..\\",
            "foo/bar",
            "foo\\bar",
            "/tmp/evil",
            "sess_/../etc",
            "sess_../../.pong",
            "sess_x/../../",
            "notasess_abc",
            "sess_",  # empty suffix still matches regex? sess_ alone — check
            "SESS_ABC",  # case: prefix must be sess_
            "sess_a/b",
            "sess_a\x00b",
            "~/.pong",
            "C:\\Windows",
        ):
            self.assertIsNone(safe_archive_id(bad), msg=f"should reject {bad!r}")
            self.assertIsNone(archive_dir(bad), msg=f"archive_dir should reject {bad!r}")
            self.assertFalse(delete_archive(bad), msg=f"delete should refuse {bad!r}")

        # Valid shape
        self.assertEqual(safe_archive_id("sess_20260802_120000_abcdef"), "sess_20260802_120000_abcdef")
        self.assertIsNone(safe_archive_id(None))

    def test_delete_refuses_parent_escape(self) -> None:
        """Malicious ids must never rmtree outside session-archive."""
        from pong.session_archive import archive_root, delete_archive, save_archive
        from pong.paths import state_dir

        # Sentinel file outside archive root — must survive delete attempts
        state = Path(state_dir())
        sentinel = state / "DO_NOT_DELETE_TRAVERSAL_TEST"
        sentinel.write_text("safe\n", encoding="utf-8")
        archive_root()  # ensure exists

        for bad in ("..", "../", "../../", "sess_/../../../", "/tmp"):
            self.assertFalse(delete_archive(bad))
            self.assertTrue(sentinel.is_file(), msg=f"sentinel vanished after delete({bad!r})")
            self.assertTrue(state.is_dir())

        # Happy path still deletes only the archive entry
        out = save_archive("pong-team", title="to-delete")
        aid = out["id"]
        entry = Path(out["path"])
        self.assertTrue(entry.is_dir())
        self.assertTrue(delete_archive(aid))
        self.assertFalse(entry.exists())
        self.assertTrue(sentinel.is_file())
        self.assertTrue(archive_root().is_dir())
        sentinel.unlink(missing_ok=True)

    def test_get_rename_load_reject_traversal(self) -> None:
        from pong.session_archive import (
            get_archive,
            load_recap_text,
            rename_archive,
            save_archive,
        )

        for bad in ("..", "foo/bar", "/etc/passwd", "sess_../x"):
            self.assertIsNone(get_archive(bad))
            self.assertEqual(load_recap_text(bad), "")
            self.assertIsNone(rename_archive(bad, "nope"))

        out = save_archive("pong-team", title="ok")
        self.assertIsNotNone(get_archive(out["id"]))
        self.assertIn("CONTINUITY", load_recap_text(out["id"]))
        ren = rename_archive(out["id"], "renamed-ok")
        assert ren is not None
        self.assertEqual(ren["title"], "renamed-ok")

    def test_default_title_includes_display_name(self) -> None:
        from pong.session_archive import default_archive_title, save_archive

        t = default_archive_title("Sam's team")
        self.assertTrue(t.startswith("Sam's team · "))
        self.assertIn(" · ", t)

        out = save_archive("pong-team")  # no title
        self.assertTrue(out["title"].startswith("CyberPong · "))
        self.assertEqual(out["meta"]["display_name"], "CyberPong")
        self.assertEqual(out["meta"]["source_session"], "pong-team")

        # Empty / whitespace title must also default
        out2 = save_archive("pong-team", title="   ")
        self.assertTrue(out2["title"].startswith("CyberPong · "))

    def test_list_filter_by_team_and_session(self) -> None:
        from pong.jsonutil import write_json
        from pong.paths import pairs_path
        from pong.session_archive import (
            archive_matches_team,
            archive_row_label,
            list_archives,
            save_archive,
        )

        # Second live pair under a different team name
        pairs = {
            "pong-team": {
                "schema_version": 2,
                "display_name": "CyberPong",
                "project_root": "/tmp/proj",
                "team_brief": "A",
                "conductor": {"id": "c1", "type": "grok", "label": "Grok"},
                "workers": [{"id": "w1", "type": "claude", "label": "B", "mission_role": "coder"}],
            },
            "pong-team-sam": {
                "schema_version": 2,
                "display_name": "Sam's team",
                "project_root": "/tmp/d",
                "team_brief": "B",
                "conductor": {"id": "c1", "type": "grok", "label": "Grok"},
                "workers": [{"id": "w1", "type": "claude", "label": "B", "mission_role": "coder"}],
            },
        }
        write_json(pairs_path(), pairs)

        a = save_archive("pong-team", title="Cyber CLI smoke")
        b = save_archive("pong-team-sam", title="Sam's team · custom")
        c = save_archive("pong-team-sam", title="custom without team word")

        all_rows = list_archives()
        self.assertGreaterEqual(len(all_rows), 3)

        by_name = list_archives(display_name="Sam's team")
        ids = {r["id"] for r in by_name}
        self.assertIn(b["id"], ids)
        self.assertIn(c["id"], ids)
        self.assertNotIn(a["id"], ids)

        # Case-insensitive display_name
        by_ci = list_archives(display_name="sam's TEAM")
        self.assertEqual({r["id"] for r in by_ci}, ids)

        by_sess = list_archives(source_session="pong-team")
        self.assertEqual({r["id"] for r in by_sess}, {a["id"]})

        # OR: source_session miss + display_name hit still matches
        mixed = list_archives(
            source_session="nonexistent-pair",
            display_name="CyberPong",
        )
        self.assertIn(a["id"], {r["id"] for r in mixed})

        # Rename edge: display_name filter alone misses after rename in meta...
        # but source_session still finds the archive.
        meta = a["meta"]
        self.assertTrue(
            archive_matches_team(meta, source_session="pong-team", display_name="Renamed")
        )
        self.assertFalse(
            archive_matches_team(meta, display_name="Renamed")
        )

        # Row label adds team when title lacks it
        self.assertEqual(
            archive_row_label({"title": "CLI smoke", "display_name": "CyberPong"}),
            "CLI smoke · CyberPong",
        )
        self.assertEqual(
            archive_row_label(
                {"title": "Sam's team · Aug 5", "display_name": "Sam's team"}
            ),
            "Sam's team · Aug 5",
        )


if __name__ == "__main__":
    unittest.main()
