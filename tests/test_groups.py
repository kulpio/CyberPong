#!/usr/bin/env python3
"""Coding groups: membership, refusals, and the guards that keep a reset surgical.

These pin the two ways a group operation can do real damage — reaching seats it
does not own, and typing into an agent that is still asking its own startup
question. The second one is not hypothetical: it deleted a seat.

Pure logic only; nothing here talks to tmux.
"""

from __future__ import annotations

import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "python"))


def _state() -> dict:
    return {
        "session": "pong-team",
        "conductor": {"id": "c1", "label": "Chief", "type": "hermes"},
        "workers": [
            {"id": "w16", "label": "Engineering — CyberPong", "type": "claude",
             "cmd": "claude", "mission_role": "coder", "parent_id": None, "tmux_index": 16},
            {"id": "w17", "label": "Reviewer", "type": "claude", "cmd": "claude",
             "mission_role": "reviewer", "parent_id": "w16", "tmux_index": 17},
            {"id": "w20", "label": "Ops", "type": "grok", "cmd": "grok",
             "mission_role": "orchestrator", "parent_id": None, "tmux_index": 20},
            {"id": "w24", "label": "Personal", "type": "grok", "cmd": "grok",
             "mission_role": "operator", "parent_id": "w20", "tmux_index": 24},
            {"id": "w25", "label": "Engineering — Website", "type": "claude",
             "cmd": "claude", "mission_role": "coder", "parent_id": None, "tmux_index": 25},
            {"id": "w28", "label": "Fixer — Website", "type": "grok", "cmd": "grok",
             "mission_role": "task_runner", "parent_id": "w25", "tmux_index": 28},
        ],
    }


class GroupTests(unittest.TestCase):
    def setUp(self) -> None:
        from pong import groups

        self.g = groups
        self.st = _state()
        self._old_home = os.environ.get("PONG_HOME")
        self._tmp = tempfile.TemporaryDirectory()
        os.environ["PONG_HOME"] = self._tmp.name

    def tearDown(self) -> None:
        if self._old_home is None:
            os.environ.pop("PONG_HOME", None)
        else:
            os.environ["PONG_HOME"] = self._old_home
        self._tmp.cleanup()

    def _protect(self, labels) -> None:
        (Path(self._tmp.name) / "settings.json").write_text(json.dumps({"protected_labels": labels}))

    def test_membership_is_lead_first_then_children(self) -> None:
        ids = [str(w["id"]) for w in self.g.group_members(self.st, "w25")]
        self.assertEqual(ids, ["w25", "w28"])
        self.assertEqual(self.g.group_members(self.st, "nope"), [])

    def test_a_child_is_not_a_group(self) -> None:
        """Addressing a group by one of its children would reset the wrong set."""
        with self.assertRaises(ValueError) as e:
            self.g.assert_is_lead(self.st, "w17")
        self.assertIn("reports to w16", str(e.exception))

    def test_a_protected_seat_is_never_swept_into_a_group_operation(self) -> None:
        self._protect(["personal"])
        with self.assertRaises(ValueError) as e:
            self.g.assert_is_lead(self.st, "w20")
        self.assertIn("protected", str(e.exception))
        self.assertTrue(self.g.is_protected({"label": "Personal"}))
        self.assertFalse(self.g.is_protected({"label": "Fixer — Website"}))

    def test_no_seat_is_protected_unless_settings_names_it(self) -> None:
        self.assertEqual(self.g.protected_labels(), ())
        self.assertFalse(self.g.is_protected({"label": "Personal"}))
        self.assertEqual([str(m["id"]) for m in self.g.assert_is_lead(self.st, "w20")], ["w20", "w24"])
        self._protect(["  Personal  ", "", 7, "personal", "Ops"])
        self.assertEqual(self.g.protected_labels(), ("personal", "ops"), "trimmed, case-blind, no repeats")
        self._protect("personal")
        self.assertEqual(self.g.protected_labels(), (), "a garbled value protects nothing")

    def test_unknown_seat_refuses_rather_than_matching_nothing(self) -> None:
        with self.assertRaises(ValueError):
            self.g.assert_is_lead(self.st, "w99")

    def test_view_sessions_are_named_by_seat_id(self) -> None:
        """Must agree with TerminalTheme.viewToken, or the island opens nothing."""
        self.assertEqual(self.g.view_name("pong-team", "w25"), "pong-team-w25")

    def test_launch_command_carries_seat_identity(self) -> None:
        cmd = self.g._launch_command(self.st, self.st["workers"][4])
        self.assertIn("export PONG_SEAT=w25", cmd)
        self.assertIn("export PONG_SESSION=pong-team", cmd)
        # The model rides on the launch line now (catalog decides which).
        self.assertIn("exec claude", cmd)
        self.assertIn("--model", cmd.split("exec claude", 1)[1])

    def test_a_long_launch_line_is_sourced_from_a_file_not_typed(self) -> None:
        """A pane keeps 1024 bytes of a typed line on macOS: the live-tools launch
        line (~2.9 KB) arrived cut off at "Bash(git r" and the seat never started."""
        import os
        import subprocess
        import tempfile

        with tempfile.TemporaryDirectory() as tmp:
            old = os.environ.get("PONG_HOME")
            os.environ["PONG_HOME"] = tmp
            try:
                w = dict(self.st["workers"][4], no_live_tools=True)
                cmd = self.g._launch_command(self.st, w, initial_prompt="Your job is in a file.")
                self.assertGreater(len(cmd.encode()), 1024)
                line = self.g.launch_line(cmd, session="pong-team", seat="w25")
                self.assertTrue(line.startswith("source "))
                self.assertLess(len(line.encode()), self.g.TYPED_LINE_MAX)
                path = Path(tmp) / "sessions" / "pong-team" / "launch" / "w25.sh"
                self.assertEqual(path.read_text(), cmd + "\n")
                self.assertEqual(path.stat().st_mode & 0o777, 0o600)
                # sourcing runs it in the pane's own shell: exports stay, exec replaces it
                runnable = "export PONG_T=ok; " + "true; " * 200 + 'exec printf %s "$PONG_T"'
                typed = self.g.launch_line(runnable, session="pong-team", seat="w25")
                for sh in ("/bin/zsh", "/bin/bash"):
                    if os.path.exists(sh):
                        out = subprocess.run([sh, "-c", typed], capture_output=True, text=True)
                        self.assertEqual(out.stdout, "ok", sh)
                # a short line is typed as it is
                short = self.g._launch_command(self.st, self.st["workers"][4])
                self.assertEqual(self.g.launch_line(short, session="pong-team", seat="w25"), short)
            finally:
                if old is None:
                    os.environ.pop("PONG_HOME", None)
                else:
                    os.environ["PONG_HOME"] = old

    def test_a_seat_opened_in_a_view_is_still_its_teams(self) -> None:
        """Opening a seat links its window into a view session; tmux then names the
        view for the pane, and the seat read as gone: its step was cancelled and run
        again (2026-09-25). A seat view's name has a dot in it, which tmux reads as
        window.pane unless the target is exact ("=name:")."""
        import os
        import shutil
        import subprocess
        from unittest.mock import patch

        if not shutil.which("tmux"):
            self.skipTest("no tmux")
        sock = f"pongtest-{os.getpid()}"

        def tmux(*args):
            r = subprocess.run(["tmux", "-L", sock, "-f", "/dev/null", *args], text=True, capture_output=True, timeout=10)
            return r.returncode == 0, ((r.stdout or "") + (r.stderr or "")).strip()

        try:
            ok, _ = tmux("new-session", "-d", "-s", "team-9", "-n", "lead")
            self.assertTrue(ok)
            tmux("new-window", "-d", "-t", "team-9:52", "-n", "critic:c1.b")
            _, pane = tmux("display-message", "-t", "team-9:52", "-p", "#{pane_id}")
            with patch.object(self.g, "_tmux", side_effect=tmux):
                self.assertTrue(self.g.pane_owned(pane, "team-9", "c1.b"))
                self.assertFalse(self.g.session_exists("team-9-c1.b"))
                note = self.g.ensure_view_session({"session": "team-9"}, {"id": "c1.b", "tmux_index": 52})
                self.assertIn("created", note)
                self.assertTrue(self.g.session_exists("team-9-c1.b"))
                note = self.g.ensure_view_session({"session": "team-9"}, {"id": "c1.b", "tmux_index": 52})
                self.assertIn("relinked", note, "a second open finds the view it made")
                self.assertTrue(self.g.pane_owned(pane, "team-9", "c1.b"), "an opened seat is still the team's")
                self.assertFalse(self.g.pane_owned(pane, "team-9", "c1.c"))
                self.assertFalse(self.g.pane_owned(pane, "team-", "c1.b"), "no prefix match on the team")
                # the seat opened again and again from the app: the view keeps the seat, never the lead
                from pong import graph_engine

                with patch("pong.routing.load_pane_registration", return_value={"pane_id": pane}):
                    for _ in range(3):
                        r = graph_engine.seat_view("team-9", "c1.b")
                        self.assertTrue(r["ok"], r)
                        self.assertEqual(r["window"], 52)
                        _, shown = tmux("display-message", "-t", "=team-9-c1.b:0", "-p", "#{pane_id} #{window_name}")
                        self.assertEqual(shown, f"{pane} critic:c1.b")
        finally:
            subprocess.run(["tmux", "-L", sock, "kill-server"], capture_output=True)

    def test_startup_prompts_are_recognised(self) -> None:
        """The exact text that cost a seat: grok's trust prompt."""
        pane = (
            "Grok Build may run or modify contents in this directory,\n"
            "posing security risks.\n   Yes, proceed   y\n   No, quit   n"
        )
        low = pane.lower()
        self.assertTrue(any(p in low for p in self.g._STARTUP_PROMPTS))
        settled = "❯ ready\nShift+Tab:mode  Ctrl+x:shortcuts"
        self.assertFalse(any(p in settled.lower() for p in self.g._STARTUP_PROMPTS))

    def test_list_groups_flags_the_protected_one(self) -> None:
        self._protect(["personal"])
        rows = {r["lead"]: r for r in self.g.list_groups(self.st)}
        self.assertEqual(set(rows), {"w16", "w20", "w25"})
        self.assertTrue(rows["w20"]["protected"])
        self.assertFalse(rows["w25"]["protected"])

    def test_model_comes_from_the_roster_first(self) -> None:
        """Archivist owns the field; the policy below is only a fallback."""
        self.assertEqual(
            self.g.model_for({"type": "claude", "mission_role": "coder", "model": "opus 5"}),
            "opus",
        )

    def test_roster_labels_are_translated_to_cli_aliases(self) -> None:
        """The roster says "opus 5"; the CLI answers "Model 'opus 5' not found".
        Only fable happens to be both, which is why this hid at first."""
        from pong.models import canonical_model

        self.assertEqual(canonical_model("claude", "opus 5"), "opus")
        self.assertEqual(canonical_model("claude", "Opus-5"), "opus")
        self.assertEqual(canonical_model("claude", "fable"), "fable")
        # An unknown name passes through, so a model released tomorrow works
        # without the catalog being edited first.
        self.assertEqual(canonical_model("claude", "some-new-model"), "some-new-model")

    def test_model_policy_when_the_roster_is_silent(self) -> None:
        coder = {"type": "claude", "mission_role": "coder"}
        writer = {"type": "claude", "mission_role": "operator"}
        deep = {"type": "claude", "mission_role": "researcher"}
        # 28 Aug policy, now in models/catalog.json: coders and Deep Research
        # on Opus, leads on Fable, anything else Claude on Opus.
        self.assertEqual(self.g.model_for(coder), "opus")
        self.assertEqual(self.g.model_for(deep), "opus")
        self.assertEqual(self.g.model_for(writer), "opus")
        lead = {"type": "claude", "mission_role": "orchestrator"}
        self.assertEqual(self.g.model_for(lead), "fable")

    def test_reviewer_default_matches_the_roster_and_the_brief(self) -> None:
        """This mapped reviewer to fable, contradicting both."""
        self.assertEqual(
            self.g.model_for({"type": "claude", "mission_role": "reviewer"}), "opus"
        )

    def test_grok_seats_are_never_sent_a_model_command(self) -> None:
        """They have no such command; typing one posts it as a prompt."""
        from pong.models import model_command

        for role in ("task_runner", "coder", "researcher"):
            w = {"type": "grok", "mission_role": role, "model": "fable"}
            # "fable" belongs to Claude — never handed to a grok launch line.
            self.assertNotEqual(self.g.model_for(w), "fable")
            self.assertIsNone(model_command("grok", self.g.model_for(w)))

    def test_other_seats_is_everything_outside_the_group(self) -> None:
        others = self.g._other_seats(self.st, ["w25", "w28"])
        self.assertIn("w24", others)
        self.assertIn("w16", others)
        self.assertNotIn("w25", others)


if __name__ == "__main__":
    unittest.main()
