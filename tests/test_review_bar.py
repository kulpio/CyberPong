#!/usr/bin/env python3
"""Review bars: scope resolution, lane-scoped authority, criteria rendering.

The bar is only worth anything if it reaches the right seats. These pin the two
things that were actually wrong at some point: role matching alone made every
reviewer binding on every coder across lanes, and the reviewer itself — not
being a coder — matched no scope and so never saw the standard it holds.
"""

from __future__ import annotations

import os
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "python"))


def _state() -> dict:
    """Two lanes, each with its own reviewer — the shape that broke before."""
    return {
        "session": "pong-team",
        "project_root": "",
        "conductor": {"id": "c1", "label": "Chief", "type": "hermes"},
        "workers": [
            {"id": "w16", "label": "Engineering", "type": "claude",
             "mission_role": "coder", "parent_id": None},
            {"id": "w17", "label": "Reviewer", "type": "claude",
             "mission_role": "reviewer", "parent_id": "w16"},
            {"id": "w18", "label": "Migrator", "type": "claude",
             "mission_role": "coder", "parent_id": "w16"},
            {"id": "w20", "label": "Ops", "type": "grok",
             "mission_role": "orchestrator", "parent_id": None},
            {"id": "w21", "label": "Watchdog", "type": "grok",
             "mission_role": "reviewer", "parent_id": "w20"},
            {"id": "w24", "label": "Personal", "type": "grok",
             "mission_role": "operator", "parent_id": "w20"},
        ],
    }


class ReviewBarTests(unittest.TestCase):
    def setUp(self) -> None:
        from pong import review_bar

        self.rb = review_bar
        self.st = _state()
        # Point HOME at an empty directory for the duration.
        #
        # `load_bars` looks in ~/.pong/review between the project and the
        # package, so these tests were reading whatever bars happen to be
        # installed on the machine running them — they passed only while that
        # directory was empty. The moment a team published an ops bar, two of
        # them failed on a machine state that has nothing to do with the logic
        # under test. Isolating it is the fix; the assertions below are about
        # the package bars and the roster, and should not care what this Mac
        # has installed.
        self._home = tempfile.TemporaryDirectory()
        self._old_home = os.environ.get("HOME")
        os.environ["HOME"] = self._home.name

    def tearDown(self) -> None:
        if self._old_home is None:
            os.environ.pop("HOME", None)
        else:
            os.environ["HOME"] = self._old_home
        self._home.cleanup()

    def test_code_bar_ships_with_the_package(self) -> None:
        bars = self.rb.load_bars(None)
        self.assertIn("code", bars, "packaged code bar must be discoverable")
        bar = bars["code"]
        self.assertTrue(bar.get("dimensions"), "a bar with no dimensions is not a bar")
        self.assertEqual(bar["scale"]["min"], 1)
        self.assertEqual(bar["scale"]["max"], 5)

    def test_every_reference_file_exists(self) -> None:
        """A scored reference that is not on disk cannot anchor anything."""
        bar = self.rb.load_bars(None)["code"]
        refs = self.rb.reference_paths(bar)
        self.assertGreaterEqual(len(refs), 2, "need real anchors, not one example")
        for path, score, _why in refs:
            self.assertTrue(Path(path).is_file(), f"missing reference: {path}")
            self.assertIsNotNone(score, f"reference is unscored: {path}")

    def test_coders_are_covered_and_others_are_not(self) -> None:
        # w16 has reports, so it is a group lead: it fires jobs, it does not
        # implement, and the code bar does not follow it. Its reports are covered.
        self.assertIsNone(self.rb.bar_for_seat(self.st, "w16"))
        self.assertIsNotNone(self.rb.bar_for_seat(self.st, "w18"))
        # An operator writes no code, so the code bar must not follow it around.
        self.assertIsNone(self.rb.bar_for_seat(self.st, "w24"))

    def test_reviewer_authority_stays_in_its_own_lane(self) -> None:
        """Role alone would make Ops' Watchdog binding on Engineering's code."""
        # The lead writes no code (see test_coders_are_covered_and_others_are_not).
        self.assertEqual(self.rb.reviewers_for_seat(self.st, "w16"), [])
        self.assertEqual(self.rb.reviewers_for_seat(self.st, "w18"), ["w17"])
        self.assertEqual(sorted(self.rb.seats_covered_by(self.st, "w17")), ["w18"])
        # Watchdog's lane has no coders, so it holds this bar over nobody.
        self.assertEqual(self.rb.seats_covered_by(self.st, "w21"), [])

    def test_explicit_scope_overrides_role_inference(self) -> None:
        """Scope is configured; a reviewer never picks it for itself."""
        bar = dict(self.rb.load_bars(None)["code"])
        bar["scope"] = {"seats": ["w18"], "reviewer_seats": ["w21"],
                        "mission_roles": [], "reviewer_roles": []}
        self.assertTrue(self.rb._covers_seat(self.st, bar, "w18"))
        self.assertFalse(self.rb._covers_seat(self.st, bar, "w16"))

    def test_listen_list_binds_the_covered_seat(self) -> None:
        self.assertIn("w17", self.rb.listens_to(self.st, "w18"))
        self.assertEqual(self.rb.listens_to(self.st, "w24"), [])

    def test_reviewer_reads_the_bar_it_holds(self) -> None:
        """It matches no scope itself, so without this it never sees the bar."""
        self.assertIsNone(self.rb.bar_for_seat(self.st, "w17"))
        applied = self.rb.bar_for_reviewer(self.st, "w17")
        self.assertIsNotNone(applied)
        self.assertEqual(applied["id"], "code")
        self.assertIsNone(self.rb.bar_for_reviewer(self.st, "w21"))

    def test_criteria_block_carries_scale_dimensions_and_anchors(self) -> None:
        bar = self.rb.load_bars(None)["code"]
        builder = self.rb.format_criteria_block(bar, for_reviewer=False)
        reviewer = self.rb.format_criteria_block(bar, for_reviewer=True)
        for d in bar["dimensions"]:
            self.assertIn(str(d["name"]), builder)
        self.assertIn("REVIEW BAR", builder)
        self.assertIn("references/code-5", builder)
        # The two sides differ only in the instruction at the end.
        self.assertIn("You are measured on this", builder)
        self.assertIn("Score every dimension", reviewer)
        self.assertNotIn("Score every dimension", builder)

    def test_a_named_seat_beats_a_role_match(self) -> None:
        """Design seats are coders too, so the code bar would otherwise claim
        them and load order would decide which standard a lane is held to."""
        bars = self.rb.load_bars(None)
        self.assertIn("design", bars, "packaged design bar must be discoverable")
        design = bars["design"]
        named = [str(s) for s in (design.get("scope") or {}).get("seats") or []]
        self.assertTrue(named, "design bar must name its seats outright")
        st = _state()
        st["workers"].append(
            {"id": named[0], "label": "Engineering — Design", "type": "claude",
             "mission_role": "coder", "parent_id": None}
        )
        picked = self.rb.bar_for_seat(st, named[0])
        self.assertEqual(picked["id"], "design")

    def test_design_bar_scores_contrast_and_sourcing(self) -> None:
        design = self.rb.load_bars(None)["design"]
        ids = {str(d["id"]) for d in design["dimensions"]}
        self.assertTrue({"accessibility", "sourcing", "hierarchy"} <= ids)
        for path, score, _why in self.rb.reference_paths(design):
            self.assertTrue(Path(path).is_file(), f"missing reference: {path}")
            self.assertIsNotNone(score)

    def test_missing_bar_is_absence_not_an_exception(self) -> None:
        empty = {"session": "x", "workers": [], "conductor": {"id": "c1"}}
        self.assertIsNone(self.rb.bar_for_seat(empty, "w16"))
        self.assertEqual(self.rb.reviewers_for_seat(empty, "w16"), [])
        self.assertEqual(self.rb.format_criteria_block({}), "")


if __name__ == "__main__":
    unittest.main()
