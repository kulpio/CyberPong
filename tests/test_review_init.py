#!/usr/bin/env python3
"""The bar interview: what it asks, what it writes, and what it refuses.

The interview is driven by an injected `ask`, so these run it end to end with
scripted answers — the same path a person takes, without a terminal.
"""

from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "python"))


def _state(project_root: str) -> dict:
    return {
        "session": "pong-team",
        "project_root": project_root,
        "conductor": {"id": "c1", "label": "Chief", "type": "hermes"},
        "workers": [
            {"id": "w16", "label": "Engineering — CyberPong", "type": "claude",
             "mission_role": "coder", "parent_id": None},
            {"id": "w17", "label": "Reviewer — CyberPong", "type": "grok",
             "mission_role": "reviewer", "parent_id": "w16"},
            {"id": "w18", "label": "Migrator — CyberPong", "type": "claude",
             "mission_role": "coder", "parent_id": "w16"},
            {"id": "w29", "label": "Engineering — Design (UX/UI)", "type": "claude",
             "mission_role": "coder", "parent_id": None},
            {"id": "w30", "label": "Reviewer — Design", "type": "claude",
             "mission_role": "reviewer", "parent_id": "w29"},
        ],
    }


class Script:
    """Answers a scripted interview, and records what it was asked."""

    def __init__(self, answers: list[str]) -> None:
        self.answers = list(answers)
        self.prompts: list[str] = []

    def __call__(self, prompt: str, default: str = "") -> str:
        self.prompts.append(prompt)
        if not self.answers:
            return default
        got = self.answers.pop(0)
        return got if got != "" else default


class ReviewInitTests(unittest.TestCase):
    def setUp(self) -> None:
        from pong import review_init

        self.ri = review_init
        self.tmp = tempfile.TemporaryDirectory()
        self.root = self.tmp.name
        self.state = _state(self.root)

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def _run(self, answers: list[str]):
        s = Script(answers)
        return self.ri.run_init(s, self.state), s

    def _code_answers(self, **over) -> list[str]:
        a = ["code", "CyberPong code", "cyberpong-code", "the bar for CyberPong",
             "CyberPong", "w17",
             "the island crash fix", "a claim with no command output",
             "",                                   # take the proposed dimensions
             "3", "4.0", "contrast is never waived", "project"]
        return over.get("answers", a)

    def test_it_asks_the_questions_a_critic_needs(self) -> None:
        _, s = self._run(self._code_answers())
        joined = " ".join(s.prompts).lower()
        for needle in ["what kind of work", "who builds", "who holds the bar",
                       "great look like", "fail look like", "dimensions matter",
                       "minimum", "where does this bar live"]:
            self.assertIn(needle, joined, f"interview never asked about {needle!r}")

    def test_it_writes_a_bar_the_lookup_path_finds(self) -> None:
        res, _ = self._run(self._code_answers())
        from pong.review_bar import bar_for_seat, load_bars

        self.assertTrue(Path(res["bar_path"]).is_file())
        bars = load_bars(self.root)
        self.assertIn("cyberpong-code", bars)
        # And the job-attach path resolves it for the seats it names.
        picked = bar_for_seat(self.state, "w16", project_root=self.root)
        self.assertIsNotNone(picked)
        self.assertEqual(picked["id"], "cyberpong-code")

    def test_project_scope_wins_over_the_packaged_bar(self) -> None:
        """Lookup order is project, then machine, then shipped."""
        res, _ = self._run(["code", "Code work", "code", "override",
                            "CyberPong", "w17", "an anchor", "",
                            "", "3", "4.0", "", "project"])
        self.assertIn(self.root, res["bar_path"])
        from pong.review_bar import load_bars

        bars = load_bars(self.root)
        self.assertEqual(bars["code"]["summary"], "override",
                         "a project bar must shadow the one shipped in the package")

    def test_group_shorthand_expands_to_the_coders(self) -> None:
        self.assertEqual(self.ri.resolve_seats(self.state, "CyberPong"), ["w16", "w18"])
        self.assertEqual(self.ri.resolve_seats(self.state, "w16, w18"), ["w16", "w18"])
        # A reviewer is not a builder, so group shorthand must not pull it in.
        self.assertNotIn("w17", self.ri.resolve_seats(self.state, "CyberPong"))

    def test_suggested_reviewer_is_grok_for_code_and_design_for_ux(self) -> None:
        self.assertEqual(self.ri.suggest_reviewers(self.state, "code", ["w16", "w18"]), ["w17"])
        self.assertEqual(self.ri.suggest_reviewers(self.state, "design", ["w29"]), ["w30"])

    def test_taking_the_proposed_set_asks_no_extra_questions(self) -> None:
        """Wording comes from the shipped bar of the same kind, not from memory."""
        _, s = self._run(self._code_answers())
        self.assertEqual(len([p for p in s.prompts if "looks like" in p]), 0)
        dims = self.ri.proposed_dimensions("code")
        self.assertTrue(all(d.get("five") and d.get("one") for d in dims))

    def test_invented_dimensions_are_asked_about(self) -> None:
        _, s = self._run(["code", "T", "t", "s", "CyberPong", "w17", "anchor", "",
                          "Taste, Nerve",           # two of his own
                          "great taste", "no taste", "held nerve", "flinched",
                          "3", "4.0", "", "project"])
        asked = [p for p in s.prompts if "looks like" in p]
        self.assertEqual(len(asked), 4, "each invented dimension needs its 5 and its 1")

    def test_a_seat_may_not_grade_itself(self) -> None:
        with self.assertRaises(ValueError) as e:
            self.ri.build_bar(
                bar_id="x", title="X", kind="code", summary="",
                builders=["w16"], reviewers=["w16"],
                dimensions=[{"id": "a", "name": "A"}],
                references=[{"file": "x-5.md", "score": 5, "why": "y"}],
            )
        self.assertIn("nobody grades their own work", str(e.exception))

    def test_a_bar_without_an_anchor_is_refused(self) -> None:
        with self.assertRaises(ValueError) as e:
            self.ri.build_bar(
                bar_id="x", title="X", kind="code", summary="",
                builders=["w16"], reviewers=["w17"],
                dimensions=[{"id": "a", "name": "A"}], references=[],
            )
        self.assertIn("at least one reference", str(e.exception))

    def test_no_anchor_yet_records_it_as_an_open_task(self) -> None:
        """Saying 'help' must not silently produce a bar that looks anchored."""
        res, _ = self._run(["code", "Code work", "helpme", "s", "CyberPong", "w17",
                            "help", "", "", "3", "4.0", "", "project"])
        refs = res["bar"]["references"]
        self.assertEqual(len(refs), 1)
        self.assertIn("TODO", refs[0]["file"])
        self.assertIn("OPEN", refs[0]["why"])

    def test_reference_stubs_are_created_so_the_reviewer_can_open_them(self) -> None:
        res, _ = self._run(self._code_answers())
        self.assertTrue(res["stubs"], "named references must land as files")
        for p in res["stubs"]:
            self.assertTrue(Path(p).is_file())
            self.assertIn("Why it scores what it scores", Path(p).read_text())

    def test_written_bar_matches_the_schema_the_loader_expects(self) -> None:
        res, _ = self._run(self._code_answers())
        bar = json.loads(Path(res["bar_path"]).read_text())
        for key in ("id", "title", "version", "summary", "scale", "pass",
                    "scope", "dimensions", "references"):
            self.assertIn(key, bar)
        for key in ("reviewer_seats", "reviewer_roles", "seats", "mission_roles"):
            self.assertIn(key, bar["scope"])
        self.assertEqual(bar["pass"]["min_each"], 3)
        self.assertEqual(bar["pass"]["min_mean"], 4.0)
        self.assertIn("never waived", bar["pass"]["note"])
        from pong.review_bar import format_criteria_block

        block = format_criteria_block(bar, for_reviewer=True)
        self.assertIn("REVIEW BAR", block)
        self.assertIn("Score every dimension", block)

    # ---- editing a live bar, rather than only creating new ones

    def _shipped_code_bar(self) -> dict:
        pkg = Path(__file__).resolve().parents[1] / "python" / "pong" / "review" / "bars" / "code.json"
        return json.loads(pkg.read_text(encoding="utf-8"))

    def test_editing_keeps_the_anchors_that_make_a_dimension_mean_anything(self) -> None:
        """A dimension with no five/one is a word, not a standard."""
        bar = self._shipped_code_bar()
        res = self.ri.run_answers({
            "kind": "code", "bar_id": "code", "title": bar["title"],
            "summary": bar["summary"], "groups": ["w16"], "reviewers": "w17",
            "dimensions": bar["dimensions"], "references": bar["references"],
            "scope": "project",
        }, _state(self.tmp.name))
        got = res["bar"]["dimensions"]
        self.assertEqual(len(got), len(bar["dimensions"]))
        self.assertEqual([d["name"] for d in got], [d["name"] for d in bar["dimensions"]])
        for d in got:
            self.assertTrue(d["five"], f"{d['id']} lost its 5-looks-like")
            self.assertTrue(d["one"], f"{d['id']} lost its 1-looks-like")

    def test_a_dimension_name_containing_a_comma_survives(self) -> None:
        """"Root cause, not symptom" used to come back as two dimensions."""
        bar = self._shipped_code_bar()
        res = self.ri.run_answers({
            "kind": "code", "bar_id": "code", "title": "t", "summary": "s",
            "groups": ["w16"], "reviewers": "w17",
            "dimensions": bar["dimensions"], "references": bar["references"],
            "scope": "project",
        }, _state(self.tmp.name))
        self.assertIn("Root cause, not symptom",
                      [d["name"] for d in res["bar"]["dimensions"]])

    def test_a_named_dimension_list_still_works_for_a_fresh_bar(self) -> None:
        res = self.ri.run_answers({
            "kind": "code", "title": "t", "summary": "s", "groups": ["w16"],
            "reviewers": "w17", "dimensions": "Speed, Clarity", "great": "https://a.com",
            "scope": "project",
        }, _state(self.tmp.name))
        self.assertEqual([d["name"] for d in res["bar"]["dimensions"]], ["Speed", "Clarity"])

    def test_an_override_carries_the_real_reference_files_across(self) -> None:
        """Not stubs. The anchors are the bar; a blank template is not."""
        pkg_root = Path(__file__).resolve().parents[1] / "python" / "pong" / "review"
        bar = self._shipped_code_bar()
        res = self.ri.run_answers({
            "kind": "code", "bar_id": "code", "title": "t", "summary": "s",
            "groups": ["w16"], "reviewers": "w17",
            "dimensions": bar["dimensions"], "references": bar["references"],
            "inherit_refs_from": str(pkg_root), "scope": "project",
        }, _state(self.tmp.name))
        self.assertEqual(res["stubs"], [], "a real anchor was replaced by a stub")
        self.assertEqual(len(res["carried"]), len(bar["references"]))
        for path in res["carried"]:
            name = Path(path).name
            self.assertEqual(Path(path).read_text(encoding="utf-8"),
                             (pkg_root / "references" / name).read_text(encoding="utf-8"))

    def test_editing_never_writes_into_the_shipped_package(self) -> None:
        pkg = Path(self.ri.__file__).resolve().parent / "review" / "bars" / "code.json"
        before = pkg.read_bytes()
        bar = self._shipped_code_bar()
        res = self.ri.run_answers({
            "kind": "code", "bar_id": "code", "title": "Mine now", "summary": "s",
            "groups": ["w16"], "reviewers": "w17",
            "dimensions": bar["dimensions"], "references": bar["references"],
            "scope": "project",
        }, _state(self.tmp.name))
        self.assertTrue(res["bar_path"].startswith(self.tmp.name), res["bar_path"])
        self.assertEqual(pkg.read_bytes(), before, "the shipped bar was modified")

    def test_a_list_of_unreadable_dimensions_is_refused_not_silently_defaulted(self) -> None:
        with self.assertRaises(ValueError):
            self.ri.run_answers({
                "kind": "code", "title": "t", "summary": "s", "groups": ["w16"],
                "reviewers": "w17", "dimensions": ["not", "dicts"],
                "great": "https://a.com", "scope": "project",
            }, _state(self.tmp.name))


if __name__ == "__main__":
    unittest.main()
