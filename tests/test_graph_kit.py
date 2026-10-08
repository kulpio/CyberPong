#!/usr/bin/env python3
"""The graph kit on any Mac (2.0): Perplexity research and the hand-run limit guard.

- pplx.py takes its switch, its daily cap and its key from Settings, and names no one in its User-Agent.
- limit-guard.py reads screens the way the runner does, and while it runs the runner leaves its team alone;
  when it stops, a heartbeat-only state goes so the runner takes the team back at once.
No network, no tmux: the scripts are loaded as modules and only their pure parts are called.
"""
from __future__ import annotations

import importlib.util
import io
import json
import os
import sys
import tempfile
import time
import unittest
from contextlib import redirect_stderr, redirect_stdout
from datetime import date
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "python"))
KIT = ROOT / "scripts" / "graph-kit"


def load(name: str, file: str):
    spec = importlib.util.spec_from_file_location(name, KIT / file)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class _Home(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.home = Path(self.tmp.name)
        self._old = {k: os.environ.get(k) for k in ("PONG_HOME", "PERPLEXITY_API_KEY")}
        os.environ["PONG_HOME"] = self.tmp.name
        os.environ.pop("PERPLEXITY_API_KEY", None)

    def tearDown(self) -> None:
        for k, v in self._old.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        self.tmp.cleanup()

    def settings(self, **kw) -> None:
        (self.home / "settings.json").write_text(json.dumps(kw))


class PerplexityTests(_Home):
    def test_switch_cap_and_key_come_from_settings(self) -> None:
        from pong import settings as St

        p = load("pplx_kit", "pplx.py")
        self.assertIsNotNone(p.S, "the engine beside the kit is found")
        self.assertEqual(p.USER_AGENT, "cyberpong-research/2.0")
        self.assertEqual(p.USAGE, str(self.home / "pplx-usage.json"))
        self.assertEqual(p.limits(), (True, 15.0))
        self.assertEqual(p.key(), "")
        St.write_key("perplexity", "pplx-" + "k2" * 20)
        self.assertEqual(p.key(), "pplx-" + "k2" * 20)
        self.settings(limits={"perplexity_daily_usd": 0.5})
        on, cap = p.limits()
        self.assertEqual((on, cap), (True, 0.5))
        Path(p.USAGE).write_text(json.dumps({date.today().isoformat(): {"calls": 3, "high": 0, "cost_usd": 0.6}}))
        self.assertIn("allowance is used", p.budget("medium", max_cost=cap))
        self.settings(limits={"perplexity": False})
        sys_argv = sys.argv
        sys.argv = ["pplx.py", "what changed in the tax rules this year?"]
        try:
            with self.assertRaises(SystemExit) as e, redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
                p.main()
        finally:
            sys.argv = sys_argv
        self.assertIn("switched off", str(e.exception.code))

    def test_no_owners_names_in_the_kit_that_ships(self) -> None:
        import re

        # no one's home folder, checkout, team or address: the kit runs on any Mac, for any team
        own = (r"/Users/[^/\s'\"]+", r"\bpong-team-\d+", r"[\w.+-]+@[\w-]+\.[\w.]+", re.escape(str(ROOT)))
        for f in ("pplx.py", "limit-guard.py", "watch.py", "dryrun.py", "README.md"):
            text = (KIT / f).read_text()
            for pat in own:
                self.assertIsNone(re.search(pat, text), f"{f}: {pat}")


class LimitGuardTests(_Home):
    def test_it_shares_the_runners_reading_and_yields_the_team_while_it_runs(self) -> None:
        from pong import limits as L

        g = load("limit_guard_kit", "limit-guard.py")
        self.assertIs(g.L.LIMIT_LINE, L.LIMIT_LINE, "one reading of a screen")
        self.assertIs(g.LIMIT_LINE, L.LIMIT_LINE)
        self.assertEqual(g.next_time("resets 3pm"), L.next_time("resets 3pm"))
        g.TEAM = "pong-team"
        g.beat()
        f = self.home / "sessions" / "pong-team" / "graph-kit" / "limit-state.json"
        st = json.loads(f.read_text())
        self.assertEqual(st["pid"], os.getpid())
        self.assertLess(time.time() - st["beat_at"], 5)
        self.assertTrue(L.guard_holds("pong-team", time.time(), L.Env()), "the runner leaves the team to the guard")
        g.end()
        self.assertFalse(f.exists(), "a heartbeat alone goes when the guard stops")
        self.assertFalse(L.guard_holds("pong-team", time.time(), L.Env()))
        g.save({"limited_until": time.time() + 3600, "paused": ["g_1"]})
        g.beat()
        g.end()
        st = json.loads(f.read_text())
        self.assertNotIn("beat_at", st, "a weekly hold stays for watch.py, without a heartbeat")
        self.assertIn("limited_until", st)


if __name__ == "__main__":
    unittest.main()
