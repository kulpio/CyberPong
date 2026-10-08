#!/usr/bin/env python3
"""The app runs this checkout; every seat's `pong` runs ~/.pong/lib.

They had drifted by seven modules — every one CyberPong 2 added — and nothing
said so, because the only window anyone watches loads the checkout. These pin
that the drift is reported rather than discovered in a pane.
"""

from __future__ import annotations

import os
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "python"))


class InstallStatusTests(unittest.TestCase):
    def setUp(self) -> None:
        from pong import install

        self.I = install
        self.tmp = tempfile.TemporaryDirectory()
        os.environ["PONG_HOME"] = self.tmp.name

    def tearDown(self) -> None:
        os.environ.pop("PONG_HOME", None)
        self.tmp.cleanup()

    def _lib(self) -> Path:
        d = Path(self.tmp.name) / "lib" / "pong"
        d.mkdir(parents=True, exist_ok=True)
        return d

    def test_no_install_at_all_is_a_failure_not_a_warning(self) -> None:
        st = self.I.status()
        self.assertFalse(st["installed_exists"])
        self.assertFalse(st["ok"])
        self.assertTrue(st["hint"])
        self.assertTrue(any("FAIL" in ln for ln in self.I.format_status(st)))

    def test_the_exact_drift_that_shipped_is_reported_by_name(self) -> None:
        """An install with the pre-v2 module set: every documented v2 command
        answers `invalid choice` in a pane, and claims write no mailbox item."""
        lib = self._lib()
        for mod in ("jobs", "flow", "state", "claims", "snapshot", "traces",
                    "waitroom", "seat_status", "claim_harvest", "groups"):
            (lib / f"{mod}.py").write_text("", encoding="utf-8")
        (lib / "cli").mkdir()
        (lib / "cli" / "main.py").write_text("", encoding="utf-8")

        st = self.I.status()
        self.assertFalse(st["ok"])
        for gone in ("mailbox.py", "work_graph.py", "loops.py", "models.py",
                     "cron.py", "drain.py", "runtime.py", "examples.py"):
            self.assertIn(gone, st["missing"], f"{gone} must be named, not implied")
        lines = "\n".join(self.I.format_status(st))
        self.assertIn("invalid choice", lines, "say what a seat will actually see")
        self.assertIn("install-control-plane.sh", lines)

    def test_required_data_directories_count_as_missing(self) -> None:
        """A catalog that did not copy fails at read time, not import time."""
        lib = self._lib()
        for mod in self.I.REQUIRED_MODULES:
            p = lib / f"{mod}.py"
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text("", encoding="utf-8")
        st = self.I.status()
        self.assertIn("loops/", st["missing"])
        self.assertIn("models/", st["missing"])

    def test_the_stamp_is_read_when_present(self) -> None:
        lib = self._lib()
        (lib / "INSTALL_STAMP").write_text(
            "version=9.9.9\nsource=/somewhere\n", encoding="utf-8")
        self.assertEqual(self.I.installed_version(), "9.9.9")
        header = self.I.format_status(self.I.status())[0]
        self.assertIn("version=9.9.9", header)

    def test_an_unstamped_install_says_so_rather_than_claiming_a_version(self) -> None:
        self._lib()
        self.assertEqual(self.I.installed_version(), "")
        self.assertIn("unstamped", self.I.format_status(self.I.status())[0])


if __name__ == "__main__":
    unittest.main()
