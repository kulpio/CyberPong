#!/usr/bin/env python3
from __future__ import annotations

import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "python"))

from pong.pane_activity import is_thinking, parse_usage


GROK_WORKING = """
    ⠋ Capture live panes and find island refre… 0.3s     1m37s ⇣183k [↓][stop]
  ╭──────────────────────────────────────────────────────────────────────────╮
  │ ❯                                                                        │
  ╰─────────────────────────────────────── Grok 4.6 (high) · always-approve ─╯
  Shift+Tab:mode  │  Esc:cancel  │  Ctrl+b:send to bg  │  Ctrl+x:shortcuts
"""

GROK_IDLE = """
  ╭──────────────────────────────────────────────────────────────────────────╮
  │ ❯ Build anything                                                         │
  ╰─────────────────────────────────────── Grok 4.6 (high) · always-approve ─╯
  Ctrl+e:expand thinking  │  Space:prompt  │  Esc:cancel  │  Ctrl+b:send to bg
"""

CLAUDE_IDLE = """
✻ Crunched for 1m 59s
─────────────────────────────────────────────────────────────────────────────
❯ add the read paths to settings.json permanently
  ⏵⏵ auto mode on (shift+tab to cycle)
"""

CLAUDE_CHURNED = """
✻ Churned for 37s
❯ fix the client-briefs folder structure
"""

CLAUDE_WORKING = """
✶ Working on the invite link
ctrl+c to interrupt
"""


class PaneActivityTests(unittest.TestCase):
    def test_grok_working(self) -> None:
        self.assertTrue(is_thinking(GROK_WORKING))

    def test_grok_idle_chrome_is_not_work(self) -> None:
        self.assertFalse(is_thinking(GROK_IDLE))

    def test_claude_past_tense_is_idle(self) -> None:
        self.assertFalse(is_thinking(CLAUDE_IDLE))

    def test_claude_churned_is_idle(self) -> None:
        self.assertFalse(is_thinking(CLAUDE_CHURNED))

    def test_claude_interrupt_is_work(self) -> None:
        self.assertTrue(is_thinking(CLAUDE_WORKING))

    def test_empty(self) -> None:
        self.assertFalse(is_thinking(""))
        self.assertFalse(is_thinking("   \n"))


CLAUDE_WEEKLY = """
You've used 93% of your weekly limit · resets 11am (America/New_York)
❯
"""

CLAUDE_CLEAR = """
  ⏵⏵ auto mode on (shift+tab to cycle) · ← for agents
                                                                                     new task? /clear to save 300.3k tokens
"""

CLAUDE_FRAC = "context 185K / 500K remaining in the window\n❯"

KEY_PANE = "FACTORY_8090_API_KEY=sk-live-not-a-usage-number-at-all\n❯"


class ParseUsageTests(unittest.TestCase):
    def test_empty_is_none(self) -> None:
        self.assertIsNone(parse_usage(""))
        self.assertIsNone(parse_usage("   \n"))

    def test_grok_idle_has_no_usage(self) -> None:
        self.assertIsNone(parse_usage(GROK_IDLE))

    def test_claude_weekly(self) -> None:
        u = parse_usage(CLAUDE_WEEKLY)
        self.assertIsNotNone(u)
        self.assertEqual(u["weekly_pct"], 93.0)
        self.assertEqual(u["chip"], "93%")
        self.assertIn("11am", u["reset"])

    def test_claude_clear_tokens(self) -> None:
        u = parse_usage(CLAUDE_CLEAR)
        self.assertIsNotNone(u)
        self.assertEqual(u["chip"], "300.3k")
        self.assertEqual(u["tokens"], "300.3k")
        self.assertNotIn("weekly_pct", u)

    def test_grok_meter(self) -> None:
        u = parse_usage(GROK_WORKING)
        self.assertIsNotNone(u)
        self.assertEqual(u["chip"], "183k")

    def test_context_fraction(self) -> None:
        u = parse_usage(CLAUDE_FRAC)
        self.assertIsNotNone(u)
        self.assertEqual(u["chip"], "185k")
        self.assertEqual(u["limit"], "500k")

    def test_key_pane_is_not_usage(self) -> None:
        self.assertIsNone(parse_usage(KEY_PANE))

    def test_does_not_invent_remaining_from_percent(self) -> None:
        u = parse_usage(CLAUDE_WEEKLY)
        self.assertNotIn("remaining", u)


class ExactSessionTests(unittest.TestCase):
    """A stopped pong-team-9 read pong-team-91's screens as its own: tmux takes a bare name as the start
    of the one session that has it, so the snapshot said the team was up (``teams[].alive``) and gave its
    lead the other team's doing line (2.1 review)."""

    def test_the_targets_are_exact(self) -> None:
        from unittest.mock import patch

        from pong import pane_activity as pa

        seen: list[tuple] = []

        def fake(*args):
            seen.append(args)
            return True, ""

        with patch.object(pa, "_tmux", side_effect=fake):
            pa.capture_all_alive("pong-team-9", [0])
        self.assertEqual([a[a.index("-t") + 1] for a in seen], ["=pong-team-9:", "=pong-team-9:0"])

    def test_a_team_never_reads_a_team_whose_name_starts_with_its_own(self) -> None:
        import os
        import shutil
        import subprocess
        import time
        from unittest.mock import patch

        from pong import pane_activity as pa

        if not shutil.which("tmux"):
            self.skipTest("no tmux")
        sock = f"pongtest-pa-{os.getpid()}"  # its own tmux server, never the person's

        def tmux(*args):
            r = subprocess.run(["tmux", "-L", sock, "-f", "/dev/null", *args], text=True, capture_output=True,
                               timeout=10)
            return r.returncode == 0, ((r.stdout or "") + (r.stderr or "")).strip()

        sock_path = ""
        try:
            ok, err = tmux("new-session", "-d", "-s", "pong-team-91", "-n", "lead",
                           "printf '* Update(src/other-team/Secret.swift)\\n'; exec cat")
            self.assertTrue(ok, err)
            sock_path = tmux("display-message", "-p", "#{socket_path}")[1]
            with patch.object(pa, "_tmux", side_effect=tmux):
                for _ in range(40):
                    if "Secret.swift" in pa.capture_all_alive("pong-team-91", [0])[1].get(0, ""):
                        break
                    time.sleep(0.05)
                alive, panes = pa.capture_all_alive("pong-team-91", [0])
                self.assertTrue(alive)
                self.assertIn("Secret.swift", panes[0])
                self.assertFalse(pa.session_alive("pong-team-9"))
                self.assertEqual(pa.capture_all_alive("pong-team-9", [0]), (False, {}))
                self.assertFalse(pa.capture_pane("pong-team-9", 0)[0])
                ok, err = tmux("new-session", "-d", "-s", "pong-team-9", "-n", "lead", "exec cat")
                self.assertTrue(ok, err)
                alive, panes = pa.capture_all_alive("pong-team-9", [0])
                self.assertTrue(alive, "a running team still reads as up")
                self.assertNotIn("Secret.swift", panes[0], "and reads its own screen")
        finally:
            subprocess.run(["tmux", "-L", sock, "kill-server"], capture_output=True)
            if sock_path.endswith("/" + sock):
                try:
                    os.unlink(sock_path)
                except OSError:
                    pass


if __name__ == "__main__":
    unittest.main()
