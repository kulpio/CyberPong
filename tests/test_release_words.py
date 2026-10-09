#!/usr/bin/env python3
"""What a release shows the public agrees with the engine's version, and no build output rides along (2.1).

- The landing page names the current version in every place that shows it (title, description, og:title,
  the nav link, the release pill, the download button, the "New in" heading, the footer), and that version
  is the engine's. The README's Version row and build-app.sh's VERSION say the same.
- Every Swift harness builds into a .out* folder under tests/swift; git ignores any such folder and none
  of it is tracked (a stale harness binary once rode into a commit after its ignore line was dropped).
"""
from __future__ import annotations

import re
import shutil
import subprocess
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "python"))

from pong import __version__  # noqa: E402

V = r"(\d+\.\d+\.\d+)"
# Each place on the landing page that shows the current version, by what surrounds it.
LANDING_SPOTS = {
    "title": r"<title>CyberPong " + V + r" ",
    "description": r'<meta name="description" content="CyberPong ' + V + r" ",
    "og:title": r'<meta property="og:title" content="CyberPong ' + V + r'"',
    "nav link": r'<a href="#whats-new">' + V + r"</a>",
    "release pill": r"Release " + V + r" · CyberPong",
    "download button": r"CyberPong-macOS\.zip\">Download " + V + r"</a>",
    "new-in heading": r"<h2>New in " + V + r"</h2>",
    "footer": r"<span>CyberPong " + V + r" · Built by",
}


def _git(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run(["git", "-C", str(ROOT), *args], capture_output=True, text=True)


class LandingVersion(unittest.TestCase):
    def setUp(self) -> None:
        page = ROOT / "landing" / "index.html"
        if not page.is_file():
            self.skipTest("no landing page in this tree")
        self.html = page.read_text(encoding="utf-8")

    def test_every_version_spot_shows_the_engine_version(self) -> None:
        for name, pattern in LANDING_SPOTS.items():
            with self.subTest(spot=name):
                found = re.findall(pattern, self.html)
                self.assertEqual(found, [__version__], f"landing {name} shows {found}, engine is {__version__}")

    def test_new_in_section_leads_with_this_release(self) -> None:
        section = re.search(r'<section class="section" id="whats-new">(.*?)</section>', self.html, re.S)
        self.assertIsNotNone(section, "the What's new section is gone")
        body = section.group(1)
        first_heading = re.search(r"<h[23][^>]*>([^<]*)</h[23]>", body)
        self.assertEqual(first_heading.group(1), f"New in {__version__}")
        # the release's own items come before any older release's heading
        self.assertIn("Notch panel", body.split("<h3", 1)[0])


class OtherVersionLabels(unittest.TestCase):
    def test_readme_version_row(self) -> None:
        readme = ROOT / "README.md"
        if not readme.is_file():
            self.skipTest("no README in this tree")
        row = re.findall(r"^\| \*\*Version\*\* \| \*\*" + V + r"\*\* \|$", readme.read_text(encoding="utf-8"), re.M)
        self.assertEqual(row, [__version__])

    def test_build_app_version(self) -> None:
        script = ROOT / "scripts" / "build-app.sh"
        if not script.is_file():
            self.skipTest("no build-app.sh in this tree")
        found = re.findall(r'^VERSION="' + V + r'"$', script.read_text(encoding="utf-8"), re.M)
        self.assertEqual(found, [__version__])


class SwiftHarnessOutput(unittest.TestCase):
    def setUp(self) -> None:
        if shutil.which("git") is None:
            self.skipTest("no git")
        inside = _git("rev-parse", "--is-inside-work-tree")
        if inside.returncode != 0 or inside.stdout.strip() != "true":
            self.skipTest("not a git checkout")

    def test_any_out_folder_is_ignored(self) -> None:
        for folder in (".out", ".out-setup", ".out-island-graphs", ".out-loop-args", ".out-some-new-harness",
                       "island/.out", "questions/.out", "island-settings/.out"):
            with self.subTest(folder=folder):
                r = _git("check-ignore", "-q", "--no-index", f"tests/swift/{folder}/harness")
                self.assertEqual(r.returncode, 0, f"tests/swift/{folder}/ is not ignored")

    def test_no_build_output_is_tracked(self) -> None:
        r = _git("ls-files", "--", "tests/swift")
        self.assertEqual(r.returncode, 0, r.stderr)
        tracked = [p for p in r.stdout.splitlines() if any(part.startswith(".out") for part in p.split("/"))]
        self.assertEqual(tracked, [], "harness build output is tracked")


if __name__ == "__main__":
    unittest.main()
