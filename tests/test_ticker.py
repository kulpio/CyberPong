#!/usr/bin/env python3
"""The island ear: which tone wins, and whether the words fit.

The ear is a sliver, so "it fits" is a correctness property, not polish — a
line that overflows either gets chopped mid-thought or reaches over the camera
cutout. These pin both the priority order and the length.
"""

from __future__ import annotations

import sys
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "python"))


def _state() -> dict:
    return {
        "workers": [
            {"id": "w16", "label": "Engineering — CyberPong"},
            {"id": "w2", "label": "Deck Writer"},
        ]
    }


class TickerTests(unittest.TestCase):
    def setUp(self) -> None:
        from pong import ticker

        self.t = ticker
        self.state = _state()
        self.now = time.time()

    def _build(self, jobs):
        # A session name that has no chat.jsonl, so only `jobs` decides.
        return self.t.build_ticker("no-such-session", self.state, jobs, now=self.now)

    def test_quiet_is_a_real_answer(self) -> None:
        self.assertEqual(self._build({"open": [], "recent": []}), [])

    def test_orange_leads(self) -> None:
        """Priority orders the list; it does not throw the rest away."""
        r = self._build({
            "open": [{"worker": "w2", "status": "ask"}],
            "recent": [{"worker": "w16", "status": "done", "updated_at": self.now}],
        })
        self.assertEqual(r[0]["tone"], "orange")
        self.assertIn("green", [line["tone"] for line in r],
                      "the win was dropped instead of being queued behind the ask")

    def test_human_takeover_counts_as_needing_you(self) -> None:
        r = self._build({"open": [{"worker": "w2", "human_takeover": True,
                                   "status": "running"}], "recent": []})
        self.assertEqual(r[0]["tone"], "orange")

    def test_green_for_a_job_that_just_closed(self) -> None:
        r = self._build({"open": [],
                         "recent": [{"worker": "w16", "status": "done",
                                     "updated_at": self.now}]})
        self.assertEqual(r[0]["tone"], "green")
        self.assertIn("done", r[0]["text"])

    def test_an_old_win_is_not_news(self) -> None:
        r = self._build({"open": [],
                         "recent": [{"worker": "w16", "status": "done",
                                     "updated_at": self.now - 3600}]})
        self.assertEqual(r, [])

    def test_two_seats_asking_are_two_lines(self) -> None:
        """The whole point of a list: one ear, both names, in turn."""
        r = self._build({"open": [{"worker": "w2", "status": "ask"},
                                  {"worker": "w16", "status": "ask"}],
                         "recent": []})
        self.assertEqual(len(r), 2, r)
        self.assertNotEqual(r[0]["text"], r[1]["text"])

    def test_the_ear_is_never_flooded(self) -> None:
        jobs = {"open": [{"worker": f"w{i}", "status": "ask"} for i in range(12)],
                "recent": []}
        self.assertLessEqual(len(self._build(jobs)), self.t.MAX_LINES)

    def test_every_line_fits_the_ear(self) -> None:
        cases = [
            {"open": [{"worker": "w2", "status": "ask"}], "recent": []},
            {"open": [], "recent": [{"worker": "w16", "status": "done",
                                     "updated_at": self.now}]},
            {"open": [{"worker": "w2", "status": "ask"}],
             "recent": [{"worker": "w16", "status": "done",
                         "updated_at": self.now}]},
        ]
        for jobs in cases:
            for line in self._build(jobs):
                self.assertLessEqual(len(line["text"]), self.t.MAX_CHARS,
                                     f"{line['text']!r} will not fit the ear")
                self.assertIn(line["tone"], ("orange", "green", "purple"))

    def test_a_line_starts_on_a_word(self) -> None:
        """Chief cards are captured from a pane, so they arrive wearing its
        furniture — one read "❙ ◆ Run Show…", which says nothing at a glance."""
        self.assertEqual(self.t._clean_lead("❙ ◆ Run Show now"), "Run Show now")
        self.assertEqual(self.t._clean_lead("  ╭─ hello"), "hello")
        self.assertEqual(self.t._clean_lead("Engineering done"), "Engineering done")
        self.assertEqual(self.t._clean_lead("❙ ◆"), "")

    def test_the_name_is_shortened_not_the_message(self) -> None:
        """Truncating "Deck Writer needs you" drops the words that matter."""
        got = self.t._who_and("Deck Writer", "needs you")
        self.assertTrue(got.endswith("needs you"), got)
        self.assertLessEqual(len(got), self.t.MAX_CHARS)

    def test_shortening_never_cuts_mid_word(self) -> None:
        got = self.t._short("alpha beta gamma delta epsilon")
        self.assertTrue(got.endswith("…"))
        for word in got.rstrip("…").split():
            self.assertIn(word, "alpha beta gamma delta epsilon".split())

    def test_a_leading_seat_label_is_dropped(self) -> None:
        """Labels carry em-dashes, so the news is what follows the whole label."""
        got = self.t._strip_label("Engineering — CyberPong — the island is up",
                                  ["Engineering — CyberPong"])
        self.assertEqual(got, "the island is up")
        self.assertEqual(self.t._strip_label("nothing to strip", ["Other"]),
                         "nothing to strip")

    def test_a_long_label_never_produces_a_bare_first_name(self) -> None:
        r = self._build({"open": [], "recent": [{"worker": "w16", "status": "done",
                                                 "updated_at": self.now}]})
        self.assertNotEqual(r[0]["text"].strip(), "Engineering")
        self.assertIn("done", r[0]["text"])


if __name__ == "__main__":
    unittest.main()
