#!/usr/bin/env python3
"""Claude's usage limits, handled by the runner (2.0), each rule pinned by what it has to do.

Real graphs in a temporary home, real pauses and resumes; only the Mac is faked (seat screens, the
/usage pane, typing, the network), so no tmux and no Claude is touched.

- At the 5-hour limit every running graph with a Claude step is paused; after the reset only its own
  pauses are lifted (never a person's), and each step still showing the limit is told once to continue.
- Near the weekly limit graphs pause until the reset, or until the person presses Resume; Resume holds
  until the reset, and a switched-off weekly stop never pauses anything. A full week with Claude's usage
  credits on pauses nothing when the weekly stop is off.
- A graph that runs only on other AIs is never paused for Claude's limits; with Claude switched off,
  nothing Claude-related happens at all (no reading, no pause) and a hold it made is lifted.
- Only Claude Code's own limit banner is a limit: a reply, test output or a diff quoting it is not.
- Nothing is ever typed into a step showing a question, a menu or a permission prompt, nor into a draft.
- The /usage screen is read in two ticks (type, then read), so no runner pass waits on it.
- A team a hand-run limit guard holds is left to it; a stale hold is cleared.
- A step stopped on a network error is told to go on: three times at most, fifteen minutes apart.
- A pause is lifted as the graph's own team, whichever team the process was bound to; a lift that failed
  is kept and tried again.
- `pong graph list --json` carries the state and whether the graph runner is on; `pong limits
  status/resume` show and lift it.
"""
from __future__ import annotations

import contextlib
import io
import json
import os
import sys
import tempfile
import time
import unittest
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "python"))

S = "pong-team"
T0 = datetime(2026, 10, 7, 13, 0).timestamp()  # 1:00 pm, local time
LIMIT = "⏺ Writing the plan\n\n  ⎿  You've hit your session limit · resets 3pm\n\n❯ \n"
WEEK = "  ⎿  You've hit your weekly limit · resets Oct 9 at 11am\n❯ \n"
NETERR = "⏺ Reading files\n  ⎿  API Error: Connection error.\n❯ \n"
WORKING = "✽ Thinking… (12s · esc to interrupt)\n"
USAGE = """
 Settings:  Status   Config   Usage

 Current session
 ███████▌                                     12% used
 Resets 6pm (Europe/Paris)

 Current week (all models)
 ████████████████████████████████████████████ 98% used
 Resets Oct 9 at 11am (Europe/Paris)

 Current week (Fable)
 ████████████████                             40% used
 Resets Oct 9 at 11am (Europe/Paris)

 Usage credits are off · /usage-credits to turn them on
"""
CFG = {"ride_out_5h": True, "week_stop_pct": 97, "helper_ai": True, "jev": True, "perplexity": True,
       "perplexity_daily_usd": 15.0}
# Screens that quote the limit or wait for a person: none is a limit to pause for, nothing is typed into any.
DIALOG_NET = ("⏺ Bash(pytest -k retry)\n   Run the API error handling tests\n Do you want to proceed?\n"
              " ❯ 1. Yes\n   2. No, and tell Claude what to do differently (esc)\n")
LIMIT_DIALOG = ("  ⎿  You've hit your session limit · resets 3pm\n Do you want to make this edit to app.py?\n"
                " ❯ 1. Yes\n   2. No\n")
DIFF_DIALOG = ("╭──────────────────────────────────────────────────────╮\n│ Edit file                                            │\n"
               "│   70  \n│   71 +# a seat that hit your weekly limit stays paused · resets Oct 9 at 11am\n"
               "│ Do you want to make this edit to test_limits.py?     │\n│ ❯ 1. Yes                                             │\n"
               "│   2. No, and tell Claude what to do differently      │\n╰──────────────────────────────────────────────────────╯\n")
QUOTED = "⏺ I quoted \"You've hit your weekly limit · resets Oct 9 at 11am\" and checked the tick.\n\n❯ \n"
TEST_OUT = "  ⎿  AssertionError: '' != \"You've hit your weekly limit · resets Oct 9 at 11am\"\n\n❯ \n"
RATE = "⏺ The API said: Rate limit reached for requests · resets in 20s\n  ⎿  retry limit reached · resets later\n❯ \n"
DRAFT = "  ⎿  You've hit your session limit · resets 3pm\n\n❯ fix the\n"


def at(h: int, m: int = 0, day: int = 7) -> float:
    return datetime(2026, 10, day, h, m).timestamp()


class _Base(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        os.environ["PONG_HOME"] = self.tmp.name
        os.environ["PONG_RUNTIMES"] = "claude,grok,codex,hermes"
        os.environ["PONG_SESSION"] = S
        for k in ("PONG_SEAT", "TYPESAFE_API_KEY", "PONG_JEV_FAKE"):
            os.environ.pop(k, None)
        from pong.jsonutil import write_json
        from pong.paths import active_path, ensure_layout, pairs_path
        from pong.routing import ensure_session_token

        ensure_layout(S)
        pair = {"schema_version": 2, "project_root": self.tmp.name,
                "conductor": {"id": "c1", "type": "claude", "label": "lead", "cmd": "claude", "mode": "tmux", "tmux_index": 0},
                "workers": [], "transport_default": "job", "flow_graph": {"edges": []}}
        write_json(pairs_path(), {S: pair})
        write_json(active_path(), {**pair, "session": S})
        ensure_session_token(S)
        from pong import limits as L

        self.L = L
        test = self

        class FakeEnv(L.Env):
            screens: dict = {}
            typed: list = []
            ready = True
            probe_up = False
            probe_text = ""
            net = True
            pids: set = set()
            started = sent = read = screen_reads = fail_resume = 0

            def seat_screen(self, session, seat):
                test.env.screen_reads += 1
                return test.env.screens.get(seat)

            def resume_ours(self, session, gid, rec):
                if test.env.fail_resume:
                    test.env.fail_resume -= 1
                    raise OSError("the graph's file could not be written")
                return super().resume_ours(session, gid, rec)

            def type_into(self, session, seat, text):
                test.env.typed.append((seat, text))
                return True

            def seat_runtime(self, session, seat):
                return "claude"

            def claude_ready(self):
                return test.env.ready

            def probe_exists(self):
                return test.env.probe_up

            def probe_start(self):
                test.env.started += 1
                test.env.probe_up = True
                return True

            def probe_send(self):
                test.env.sent += 1
                return test.env.send_results.pop(0) if test.env.send_results else "sent"

            def probe_read(self):
                test.env.read += 1
                return test.env.probe_text

            def probe_reset(self):
                test.env.probe_up = False

            def network_ok(self):
                return test.env.net

            def pid_alive(self, pid):
                return int(pid) in test.env.pids

        self.env = FakeEnv()
        self.env.screens, self.env.typed, self.env.pids, self.env.send_results = {}, [], set(), []

    def tearDown(self) -> None:
        for k in ("PONG_HOME", "PONG_RUNTIMES", "PONG_SESSION", "PONG_TOKEN"):
            os.environ.pop(k, None)
        self.tmp.cleanup()

    def graph(self, name: str = "g", runtimes: str | None = None) -> dict:
        """A running graph; *runtimes* narrows the AIs its steps are wired to (``"grok"``: no Claude step).
        It has a step the person answers too, which the engine runs itself on the lead's seat."""
        from pong.work_graph import start

        old = os.environ["PONG_RUNTIMES"]
        os.environ["PONG_RUNTIMES"] = runtimes or old
        try:
            return start(S, owner="c1", loop="graph", task=f"plan {name}",
                         topology={"name": name, "start": "w",
                                   "nodes": [{"id": "w", "role": "writer"}, {"id": "end", "role": "end"}]
                                   + ([{"id": "me", "role": "human"}] if runtimes else []),
                                   "edges": [{"from": "w", "to": "me" if runtimes else "end"}]
                                   + ([{"from": "me", "to": "end"}] if runtimes else [])})
        finally:
            os.environ["PONG_RUNTIMES"] = old

    def g(self, gid: str) -> dict:
        from pong.work_graph import find_graph

        return find_graph(S, gid)

    def seat(self, gid: str) -> str:
        return next(n["seat"] for n in self.g(gid)["nodes"] if n["id"] == "w")

    def tick(self, now: float, **cfg) -> dict:
        return self.L.tick(env=self.env, now=now, cfg={**CFG, **cfg})

    def state_file(self) -> Path:
        return Path(self.tmp.name) / "limits-state.json"


class ReadingTests(_Base):
    def test_the_usage_screen_and_the_reset_times(self) -> None:
        L = self.L
        u = L.parse_usage(USAGE, datetime.fromtimestamp(T0))
        self.assertEqual(u["session"][0], 12)
        self.assertEqual(u["session"][1], datetime(2026, 10, 7, 18, 0))
        self.assertEqual(u["week"], (98, datetime(2026, 10, 9, 11, 0)))
        self.assertEqual(u["fable"][0], 40)
        self.assertEqual(u["credits"], "off")
        self.assertEqual(L.parse_usage("Usage credits are on", None)["credits"], "on")
        self.assertEqual(L.parse_usage("a trust question", None), {"credits": None})
        self.assertEqual(L.next_time("resets 2:20am", datetime(2026, 10, 7, 13, 0)), datetime(2026, 10, 8, 2, 20))
        self.assertIn("session limit", L.limit_hit(LIMIT))
        self.assertEqual(L.limit_hit(LIMIT + WORKING), "", "a working step is not stopped")
        self.assertTrue(L.network_stopped(NETERR))
        self.assertFalse(L.network_stopped(LIMIT))


class FiveHourTests(_Base):
    def test_pause_at_the_limit_then_lift_only_its_own_pauses(self) -> None:
        from pong.work_graph import pause

        g1, g2, g3 = self.graph("one"), self.graph("two"), self.graph("three")
        pause(S, g2["id"], reason="paused by you")
        self.env.screens[self.seat(g1["id"])] = LIMIT
        r = self.tick(T0)
        self.assertEqual(r["state"], "paused_5h")
        self.assertEqual(r["until"], at(15))
        self.assertEqual({p["graph"] for p in r["paused"]}, {g1["id"], g3["id"]}, "the person's own pause is not ours")
        self.assertEqual(self.g(g1["id"])["paused"]["reason"], self.L.REASON_5H)
        self.assertEqual(r["note"], "Graphs paused for Claude's 5-hour limit · back at 3:00 pm")
        self.assertEqual(self.L.view(T0)["state"], "paused_5h")
        # the person resumes g3 by hand during the hold, and pauses it again for their own reasons
        from pong.work_graph import resume

        resume(S, g3["id"])
        pause(S, g3["id"], reason="paused by you")
        self.assertEqual(self.tick(T0 + 120)["state"], "paused_5h")
        r = self.tick(at(15) + 61)
        self.assertEqual(r["state"], "ok")
        self.assertIsNone(self.g(g1["id"])["paused"], "its own pause is lifted after the reset")
        self.assertTrue(self.g(g2["id"])["paused"]["manual"], "a person's pause is never lifted")
        self.assertTrue(self.g(g3["id"])["paused"]["manual"], "nor a pause the person made again")
        self.assertEqual(self.env.typed, [(self.seat(g1["id"]), self.L.NUDGE)], "the stuck step is told once")
        self.tick(at(15) + 200)
        self.assertEqual(len(self.env.typed), 1, "once per step visit")

    def test_nothing_running_means_nothing_read_or_written(self) -> None:
        r = self.tick(T0)
        self.assertEqual(r["state"], "ok")
        self.assertFalse(self.state_file().exists())
        self.assertEqual(self.env.started + self.env.sent, 0, "no probe when no graph runs")
        self.assertIsNone(self.L.view(T0))

    def test_switched_off_means_no_pause_and_a_hold_is_lifted(self) -> None:
        g1 = self.graph()
        self.env.screens[self.seat(g1["id"])] = LIMIT
        self.assertEqual(self.tick(T0, ride_out_5h=False, week_stop_pct=0)["state"], "ok")
        self.assertIsNone(self.g(g1["id"]).get("paused"))
        self.assertEqual(self.tick(T0 + 61)["state"], "paused_5h")
        r = self.tick(T0 + 200, ride_out_5h=False)
        self.assertEqual(r["state"], "ok")
        self.assertIsNone(self.g(g1["id"])["paused"])

    def test_a_graph_started_during_the_hold_is_held_too(self) -> None:
        g1 = self.graph("one")
        self.env.screens[self.seat(g1["id"])] = LIMIT
        self.tick(T0)
        g2 = self.graph("two")
        r = self.tick(T0 + 61)
        self.assertEqual({p["graph"] for p in r["paused"]}, {g1["id"], g2["id"]})
        from pong.work_graph import resume

        resume(S, g2["id"])  # the person lets it run anyway
        r = self.tick(T0 + 200)
        self.assertNotIn("manual", json.dumps(self.g(g2["id"]).get("paused")), "a graph resumed by hand stays resumed")

    def test_a_stale_hold_is_cleared(self) -> None:
        self.state_file().write_text(json.dumps({"state": "paused_5h", "until": T0 - 3600, "paused": [],
                                                 "usage": None, "credits": None, "note": "old"}))
        self.assertEqual(self.tick(T0)["state"], "ok")
        self.state_file().write_text(json.dumps({"state": "paused_week", "until": None, "paused": [{"session": S, "graph": "g_gone"}]}))
        r = self.tick(T0)
        self.assertEqual((r["state"], r["paused"]), ("ok", []), "a hold whose graphs are gone goes")


class ProbeAndWeekTests(_Base):
    def probe_to_reading(self, t: float, **cfg) -> dict:
        self.env.probe_text = USAGE
        r1 = self.tick(t, **cfg)                     # signed in; the probe pane starts
        r2 = self.tick(t + 20, **cfg)                # typed /usage
        r3 = self.tick(t + 30, **cfg)                # read it
        self.assertEqual((self.env.started, self.env.sent, self.env.read), (1, 1, 1))
        self.assertEqual(r1["state"], "ok")
        self.assertEqual(r2["state"], "ok")
        return r3

    def test_the_weekly_stop_and_the_persons_resume(self) -> None:
        g1 = self.graph()
        r = self.probe_to_reading(T0)
        self.assertEqual(r["state"], "paused_week")
        self.assertEqual(r["until"], at(11, day=9))
        self.assertEqual(r["usage"]["week_pct"], 98)
        self.assertEqual(r["credits"], "off")
        self.assertIn("This week's Claude use is at 98%", r["note"])
        self.assertTrue(self.g(g1["id"])["paused"]["manual"])
        res = self.L.resume_now(env=self.env, now=T0 + 40)
        self.assertEqual((res["state"], res["resumed"]), ("ok", [f"{S}/{g1['id']}"]))
        self.assertIsNone(self.g(g1["id"])["paused"])
        self.assertEqual(self.tick(T0 + 100)["state"], "ok", "Resume holds until the weekly reset")
        self.assertIsNone(self.g(g1["id"])["paused"])

    def test_a_reading_from_before_the_reset_never_pauses_again(self) -> None:
        g1 = self.graph()
        self.env.probe_text = USAGE.replace("12% used", "100% used").replace("Resets 6pm", "Resets 3pm").replace("98% used", "60% used")
        self.tick(T0)
        self.tick(T0 + 20)
        r = self.tick(T0 + 30)
        self.assertEqual((r["state"], r["until"]), ("paused_5h", at(15)))
        r = self.tick(at(15) + 61)
        self.assertEqual(r["state"], "ok", "the 100% read before the reset is history")
        self.assertIsNone(self.g(g1["id"])["paused"])
        self.env.probe_text = USAGE.replace("98% used", "60% used")  # what /usage says after the reset
        r = self.tick(at(15) + 120)
        self.assertEqual(r["state"], "ok")
        self.assertEqual(r["usage"]["session_pct"], 12)
        self.assertIsNone(self.g(g1["id"])["paused"])

    def test_a_weekly_stop_switched_off_never_pauses(self) -> None:
        g1 = self.graph()
        r = self.probe_to_reading(T0, week_stop_pct=0)
        self.assertEqual(r["state"], "ok")
        self.assertIsNone(self.g(g1["id"]).get("paused"))
        self.assertEqual(r["usage"]["week_pct"], 98, "the reading is still kept for the app")
        self.assertEqual(self.L.view(T0 + 40)["usage"]["week_pct"], 98)

    def test_the_weekly_hold_ends_at_the_reset(self) -> None:
        g1 = self.graph()
        self.probe_to_reading(T0)
        r = self.tick(at(11, day=9) + 61)
        self.assertEqual(r["state"], "ok")
        self.assertIsNone(self.g(g1["id"])["paused"])

    def test_a_real_weekly_limit_on_a_seat_holds_for_the_week(self) -> None:
        g1 = self.graph()
        self.env.ready = False  # no usage reading: the seat's own screen decides
        self.env.screens[self.seat(g1["id"])] = WEEK
        r = self.tick(T0)
        self.assertEqual(r["state"], "paused_week")
        self.assertEqual(r["until"], at(11, day=9))
        self.assertIn("weekly limit is reached", r["note"])

    def test_no_probe_without_a_signed_in_claude(self) -> None:
        self.graph()
        self.env.ready = False
        for i in range(4):
            self.tick(T0 + i * 30)
        self.assertEqual(self.env.started + self.env.sent, 0)

    def test_the_probes_own_folder_is_trusted_and_any_other_question_waits(self) -> None:
        g1 = self.graph()
        self.env.probe_text = USAGE
        self.env.send_results = ["trusted", "sent"]
        self.tick(T0)                       # the probe pane starts
        self.tick(T0 + 20)                  # Claude asks to trust the probe's empty folder: answered
        self.tick(T0 + 30)                  # let it draw again
        self.tick(T0 + 40)                  # /usage typed
        r = self.tick(T0 + 50)              # read
        self.assertEqual(r["state"], "paused_week")
        self.assertTrue(self.g(g1["id"])["paused"]["manual"])

    def test_a_question_in_the_probe_pane_is_left_for_the_person(self) -> None:
        self.graph()
        self.env.send_results = ["blocked"]
        self.tick(T0)
        self.tick(T0 + 20)
        self.assertEqual(self.env.read, 0)
        self.assertIn("waiting for an answer", self.L.status()["usage_note"])
        self.assertNotIn("tmux", self.L.status()["usage_note"], "plain words: what the person can do")
        self.assertFalse(self.env.probe_up, "closed, so a fresh pane tries again once the person has answered")
        self.env.send_results = ["sent"]
        self.env.probe_text = USAGE
        self.tick(T0 + 20 + 901)            # fifteen minutes on: a fresh pane
        self.tick(T0 + 20 + 901 + 20)       # /usage typed
        self.tick(T0 + 20 + 901 + 30)       # read
        self.assertEqual(self.env.started, 2)
        self.assertEqual(self.L.status()["usage_note"], "")
        self.assertEqual(self.L.status()["usage"]["week_pct"], 98)

    def test_an_unreadable_screen_restarts_the_probe_later(self) -> None:
        self.graph()
        self.env.probe_text = "Do you trust the files in this folder?"
        self.tick(T0)
        self.tick(T0 + 20)
        self.tick(T0 + 30)
        self.assertFalse(self.env.probe_up, "the pane is closed so it starts clean next time")
        self.tick(T0 + 200)
        self.assertEqual(self.env.started, 1, "and it waits before trying again")


class CoexistenceTests(_Base):
    def test_a_team_held_by_a_hand_run_guard_is_left_to_it(self) -> None:
        g1 = self.graph()
        self.env.screens[self.seat(g1["id"])] = LIMIT
        kit = Path(self.tmp.name) / "sessions" / S / "graph-kit"
        kit.mkdir(parents=True)
        (kit / "limit-state.json").write_text(json.dumps({"beat_at": T0 - 60, "pid": 4242}))
        self.assertEqual(self.tick(T0)["state"], "ok")
        self.assertIsNone(self.g(g1["id"]).get("paused"))
        (kit / "limit-state.json").write_text(json.dumps({"limited_until": T0 + 3600, "pid": 4242}))
        self.env.pids = {4242}
        self.assertEqual(self.tick(T0 + 61)["state"], "ok", "a guard holding a limit, still alive")
        self.env.pids = set()
        self.assertEqual(self.tick(T0 + 122)["state"], "paused_5h", "a guard that died holds nothing")


class NetworkTests(_Base):
    def test_three_nudges_fifteen_minutes_apart_and_only_when_the_network_answers(self) -> None:
        g1 = self.graph()
        seat = self.seat(g1["id"])
        self.env.screens[seat] = NETERR
        t = time.time()  # the step started just now (its timeout counts from its start)
        self.env.net = False
        self.tick(t)
        self.assertEqual(self.env.typed, [])
        self.env.net = True
        self.tick(t + 61)
        self.tick(t + 122)
        self.assertEqual(self.env.typed, [(seat, self.L.NET_NUDGE)])
        for i in range(1, 5):
            self.tick(t + 61 + i * 901)
        self.assertEqual(len(self.env.typed), 3)
        self.assertEqual(self.tick(t + 61 + 6 * 901)["state"], "ok", "a network error is not a limit")


class SafetyTests(_Base):
    def gated(self) -> dict:
        from pong.work_graph import start

        return start(S, owner="c1", loop="graph", task="plan with a question",
                     topology={"name": "gated", "start": "w",
                               "nodes": [{"id": "w", "role": "writer"}, {"id": "me", "role": "human"},
                                         {"id": "end", "role": "end"}],
                               "edges": [{"from": "w", "to": "me"}, {"from": "me", "to": "end", "on": "approved"},
                                         {"from": "me", "to": "w", "on": "rejected"}]})

    def test_lifting_its_pause_never_answers_a_question_left_open(self) -> None:
        from pong.work_graph import _graph_lock, load, resume, save

        g = self.gated()
        self.env.screens[self.seat(g["id"])] = LIMIT
        self.assertEqual(self.tick(T0)["state"], "paused_5h")
        rec = json.loads(self.state_file().read_text())["paused"][0]
        # the person lets it run on by hand, and the step then opens its question
        resume(S, g["id"])
        with _graph_lock(S):
            data = load(S)
            graph = next(x for x in data["graphs"] if x["id"] == g["id"])
            next(n for n in graph["nodes"] if n["id"] == "me")["status"] = "waiting_human"
            save(S, data)
        self.assertFalse(self.env.resume_ours(S, g["id"], rec), "checked under the graph's lock: no longer ours")
        r = self.tick(at(15) + 61)
        self.assertEqual(r["state"], "ok")
        me = next(n for n in self.g(g["id"])["nodes"] if n["id"] == "me")
        self.assertEqual(me["status"], "waiting_human", "the person's question is still theirs to answer")

    def test_its_own_pause_is_lifted_under_the_lock(self) -> None:
        g = self.graph()
        self.env.screens[self.seat(g["id"])] = LIMIT
        self.tick(T0)
        rec = json.loads(self.state_file().read_text())["paused"][0]
        self.assertTrue(self.env.resume_ours(S, g["id"], rec))
        self.assertIsNone(self.g(g["id"])["paused"])
        self.assertFalse(self.env.resume_ours(S, g["id"], rec), "and only once")

    def test_a_pass_that_finds_the_state_busy_changes_nothing(self) -> None:
        g = self.graph()
        self.env.screens[self.seat(g["id"])] = LIMIT
        with self.L._state_lock():
            r = self.tick(T0)
        self.assertEqual(r["state"], "ok")
        self.assertIn("busy", r["did"][0])
        self.assertIsNone(self.g(g["id"]).get("paused"))
        self.assertEqual(self.tick(T0 + 1)["state"], "paused_5h", "the next pass does the work")

    def test_a_limit_line_left_on_a_screen_after_its_reset_is_not_a_new_limit(self) -> None:
        g = self.graph()
        seat = self.seat(g["id"])
        self.env.ready = False  # no usage reading: only the screen speaks
        self.env.screens[seat] = LIMIT  # "resets 3pm", still on the screen at 3:10 pm
        r = self.tick(at(15, 10), ride_out_5h=False)
        self.assertEqual(r["state"], "ok", "today's 3 pm has passed: not a weekly hold until tomorrow 3 pm")
        self.assertIsNone(self.g(g["id"]).get("paused"))
        self.env.screens[seat] = WEEK  # "resets Oct 9 at 11am", read on Oct 11
        r = self.tick(at(12, day=11))
        self.assertEqual(r["state"], "ok", "a date that has passed is not next year's reset")
        self.assertIsNone(self.g(g["id"]).get("paused"))
        self.env.screens[seat] = LIMIT  # a fresh hit the next day: 3 pm is two hours ahead
        self.assertEqual(self.tick(at(13, day=12))["state"], "paused_5h")

    def test_resume_is_the_persons_button(self) -> None:
        from pong.cli.main import main

        g = self.graph()
        self.env.screens[self.seat(g["id"])] = LIMIT
        self.L.tick(env=self.env, now=T0, cfg=CFG)  # 1 pm: "resets 3pm" is ahead (a real clock made this pass by day only)
        os.environ["PONG_SEAT"] = "c1.arch"
        try:
            with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                code = main(["limits", "resume", "--json"])
        finally:
            os.environ.pop("PONG_SEAT", None)
        self.assertEqual(code, 2)
        self.assertEqual(self.L.status()["state"], "paused_5h")
        self.assertTrue(self.g(g["id"])["paused"]["manual"])

    def test_no_live_check_from_a_temporary_home(self) -> None:
        env = self.L.Env()
        self.assertFalse(env.claude_ready(), "no `claude auth status` from a test or a dry run")
        self.assertFalse(env.network_ok(), "and no request")
        self.assertIsNone(self.L.PROBE_QUESTION.search("Update available! Run: brew upgrade claude-code"),
                          "an update notice on the idle screen is not a question")


class CliTests(_Base):
    def cli(self, argv: list[str]) -> tuple[int, str]:
        from pong.cli.main import main

        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
            code = main(argv)
        return code, out.getvalue()

    def test_graph_list_status_and_resume(self) -> None:
        g1 = self.graph()
        code, out = self.cli(["graph", "list", "--json"])
        self.assertEqual(code, 0)
        self.assertIn("limits", json.loads(out))
        self.assertIsNone(json.loads(out)["limits"])
        self.env.screens[self.seat(g1["id"])] = LIMIT
        self.L.tick(env=self.env, now=T0, cfg=CFG)
        lim = json.loads(self.cli(["graph", "list", "--json"])[1])["limits"]
        self.assertEqual(lim["state"], "paused_5h")
        self.assertEqual(lim["paused"], [{"session": S, "graph": g1["id"]}])
        st = json.loads(self.cli(["limits", "status", "--json"])[1])
        self.assertEqual(st["state"], "paused_5h")
        self.assertEqual(st["settings"]["week_stop_pct"], 97)
        r = json.loads(self.cli(["limits", "resume", "--json"])[1])
        self.assertEqual((r["ok"], r["state"], r["was"]), (True, "ok", "paused_5h"))
        self.assertIsNone(self.g(g1["id"])["paused"])
        self.assertEqual(json.loads(self.cli(["limits", "resume", "--json"])[1])["resumed"], [])

    def test_graph_list_says_whether_the_runner_is_on(self) -> None:
        from pong import runtime as R

        old = os.environ.get("HOME")
        os.environ["HOME"] = str(Path(self.tmp.name) / "user")  # no launchd agent in this home
        try:
            self.graph()
            payload = json.loads(self.cli(["graph", "list", "--json"])[1])
            self.assertEqual(payload["runner"], {"ok": False, "installed": False, "running": False, "last_beat_s": None},
                             "a graph stops after its first step without the runner: Home has to be able to say so")
            p = R.plist_path()
            p.parent.mkdir(parents=True)
            p.write_text("<plist/>")
            R.heartbeat(True)
            r = json.loads(self.cli(["graph", "list", "--json"])[1])["runner"]
            self.assertEqual((r["ok"], r["installed"], r["running"]), (True, True, True))
            self.assertLess(r["last_beat_s"], 60)
        finally:
            if old is None:
                os.environ.pop("HOME", None)
            else:
                os.environ["HOME"] = old


class ScreenTests(_Base):
    def test_only_claudes_own_banner_is_a_limit(self) -> None:
        L = self.L
        for banner in ("  ⎿  You've hit your session limit · resets 3pm",
                       "You've hit your weekly limit · resets Oct 9 at 11am",
                       "You’ve hit your Opus limit · resets 9pm",
                       "5-hour limit reached ∙ resets 3pm",
                       "Opus weekly limit reached ∙ resets Oct 9 at 11am",
                       "  ⎿  Claude usage limit reached. Your limit will reset at 3pm (Europe/Paris).",
                       "  ⎿  You're out of extra usage · resets 3pm"):
            self.assertTrue(L.limit_hit(banner + "\n❯ \n"), banner)
        for screen in (QUOTED, TEST_OUT, RATE, DIFF_DIALOG,
                       "⏺ Note: a seat that hit your weekly limit stays paused.\n❯ \n",
                       "  ⎿  You've hit your session limit\n❯ \n",  # no reset named: not Claude Code's banner
                       "  ⎿  Claude Opus limit reached, now using Sonnet\n❯ \n",  # it goes on, on another model
                       "-  You've hit your session limit · resets 3pm\n+  something else\n❯ \n"):
            self.assertEqual(L.limit_hit(screen), "", screen)
        self.assertTrue(L.network_stopped(DIALOG_NET), "the words alone look like a network error")

    def test_only_an_empty_input_line_takes_a_line(self) -> None:
        L = self.L
        for screen in (LIMIT, WEEK, NETERR, QUOTED, "  ⎿  done\n│ ❯ │\n", '❯ Try "fix the tests"\n'):
            self.assertTrue(L.ready_for_input(screen), screen)
        for screen in (DIALOG_NET, LIMIT_DIALOG, DIFF_DIALOG, DRAFT, LIMIT + WORKING, "", "⏺ Thinking about it\n"):
            self.assertFalse(L.ready_for_input(screen), screen)

    def test_typing_reads_the_screen_again_first(self) -> None:
        """The screen a tick decided on can be seconds old: a prompt that came up since gets nothing."""
        sent: list = []
        screen = {"now": DIALOG_NET}

        class Mac(self.L.Env):
            def _live(self):
                return True

            def _seat_pane(self, session, seat):
                return "%9"

            def _tmux(self, *args):
                if args[0] == "capture-pane":
                    self.captured = args
                    return True, screen["now"]
                sent.append(args)
                return True, ""

        mac = Mac()
        self.assertFalse(mac.type_into(S, "c1.a", self.L.NUDGE))
        self.assertEqual(sent, [])
        self.assertIn("-J", mac.captured, "a wrapped line is read whole")
        screen["now"] = LIMIT
        self.assertTrue(mac.type_into(S, "c1.a", self.L.NUDGE))
        self.assertEqual([a[-1] for a in sent], [self.L.NUDGE, "Enter"])


class HandRunGuardTests(_Base):
    def guard(self, *, without_engine: bool):
        """scripts/graph-kit/limit-guard.py, loaded as a kit beside the engine, or alone (its own copies)."""
        import importlib.util

        import pong

        saved = (sys.modules.get("pong.limits"), pong.__dict__.get("limits"))
        if without_engine:
            sys.modules["pong.limits"] = None  # an import of it fails, as on a Mac with only the kit
            pong.__dict__.pop("limits", None)
        try:
            spec = importlib.util.spec_from_file_location("limit_guard_f1", ROOT / "scripts" / "graph-kit" / "limit-guard.py")
            g = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(g)
        finally:
            sys.modules["pong.limits"], pong.limits = saved
        return g

    def test_its_own_copies_read_a_screen_as_the_runner_does(self) -> None:
        alone = self.guard(without_engine=True)
        self.assertIsNone(alone.L)
        self.assertEqual((alone.LIMIT_LINE.pattern, alone.LIMIT_LINE.flags), (self.L.LIMIT_LINE.pattern, self.L.LIMIT_LINE.flags))
        self.assertEqual(alone.ASKING.pattern, self.L.ASKING.pattern)
        for screen in (LIMIT, WEEK, NETERR, DIALOG_NET, LIMIT_DIALOG, DIFF_DIALOG, DRAFT, QUOTED, TEST_OUT, RATE):
            self.assertEqual(alone.ready_for_input(screen), self.L.ready_for_input(screen), screen)
        self.assertIs(self.guard(without_engine=False).ASKING, self.L.ASKING)

    def test_it_never_types_into_a_question(self) -> None:
        import subprocess

        g = self.guard(without_engine=True)
        sent: list = []
        screen = {"now": DIALOG_NET}

        def sh(args, timeout=60):
            if "capture-pane" in args:
                return subprocess.CompletedProcess(args, 0, screen["now"], "")
            sent.append(args)
            return subprocess.CompletedProcess(args, 0, "", "")

        g.sh = sh
        g.time = type("T", (), {"sleep": staticmethod(lambda s: None), "time": staticmethod(time.time)})
        self.assertFalse(g.type_line("%9", g.NUDGE))
        self.assertEqual(sent, [])
        screen["now"] = LIMIT
        self.assertTrue(g.type_line("%9", g.NUDGE))
        self.assertEqual([a[-1] for a in sent], [g.NUDGE, "Enter"])


class QuestionOnScreenTests(_Base):
    """A permission prompt takes Enter as its highlighted "1. Yes": nothing is ever typed into one."""

    def test_a_permission_prompt_that_mentions_a_network_error_is_left_alone(self) -> None:
        g = self.graph()
        self.env.screens[self.seat(g["id"])] = DIALOG_NET
        t = time.time()
        did = []
        for i in range(4):
            did += self.tick(t + i * 901)["did"]
        self.assertEqual(self.env.typed, [])
        self.assertFalse(any("told to continue" in d for d in did))

    def test_a_limit_above_a_question_pauses_but_nothing_is_typed(self) -> None:
        g = self.graph()
        self.env.screens[self.seat(g["id"])] = LIMIT_DIALOG
        self.assertEqual(self.tick(T0)["state"], "paused_5h")
        r = self.tick(at(15) + 61)
        self.assertEqual(r["state"], "ok")
        self.assertIsNone(self.g(g["id"])["paused"])
        self.assertEqual(self.env.typed, [], "Enter would have answered the question")

    def test_a_half_typed_line_is_not_sent(self) -> None:
        g = self.graph()
        self.env.screens[self.seat(g["id"])] = DRAFT
        self.assertEqual(self.tick(T0)["state"], "paused_5h")
        self.tick(at(15) + 61)
        self.assertEqual(self.env.typed, [])

    def test_a_step_asking_for_permission_is_not_told_to_continue(self) -> None:
        from pong.work_graph import _graph_lock, load, save

        g = self.graph()
        self.env.screens[self.seat(g["id"])] = NETERR
        with _graph_lock(S):
            data = load(S)
            n = next(x for x in next(y for y in data["graphs"] if y["id"] == g["id"])["nodes"] if x["id"] == "w")
            n["attention"] = "is asking your permission. Open its screen to answer."
            save(S, data)
        self.tick(time.time())
        self.assertEqual(self.env.typed, [])

    def test_text_that_quotes_the_limit_never_pauses(self) -> None:
        g = self.graph()
        seat = self.seat(g["id"])
        self.env.ready = False  # no usage reading: only the screen speaks
        for i, screen in enumerate((DIFF_DIALOG, QUOTED, TEST_OUT, RATE)):
            self.env.screens[seat] = screen
            r = self.tick(T0 + i * 61)
            self.assertEqual(r["state"], "ok", screen)
            self.assertIsNone(self.g(g["id"]).get("paused"), screen)
        self.assertEqual(self.env.typed, [])


class OtherAIsTests(_Base):
    """Claude's limits are Claude's: a graph on other AIs goes on."""

    def test_at_the_5_hour_limit_only_graphs_with_a_claude_step_pause(self) -> None:
        mixed, grok = self.graph("claude"), self.graph("grok only", runtimes="grok")
        self.assertEqual(grok["wiring"]["w"]["runtime"], "grok")
        self.env.screens[self.seat(mixed["id"])] = LIMIT
        r = self.tick(T0)
        self.assertEqual(r["state"], "paused_5h")
        self.assertEqual([p["graph"] for p in r["paused"]], [mixed["id"]])
        self.assertIsNone(self.g(grok["id"]).get("paused"), "the person's own step (on the lead's seat) is not a Claude step")
        later = self.graph("grok later", runtimes="grok")
        claude_later = self.graph("claude later")
        r = self.tick(T0 + 61)
        self.assertEqual({p["graph"] for p in r["paused"]}, {mixed["id"], claude_later["id"]},
                         "a Claude graph started during the hold is held too; a Grok one is not")
        self.assertIsNone(self.g(later["id"]).get("paused"))

    def test_a_graph_whose_claude_step_goes_out_during_the_hold_is_held_then(self) -> None:
        """Its first step runs on Grok and its next on Claude: left running while the Grok step works, held
        once the Claude step is out (it only runs into the same limit), and that step is told to go on."""
        from pong import jobs
        from pong.drain import run as drain_run
        from pong.work_graph import start

        claude = self.graph("claude")
        self.env.screens[self.seat(claude["id"])] = LIMIT
        os.environ["PONG_RUNTIMES"] = "grok"
        mixed = start(S, owner="c1", loop="graph", task="plan mixed",
                      topology={"name": "mixed", "start": "w1",
                                "nodes": [{"id": "w1", "role": "writer"}, {"id": "w2", "role": "writer"},
                                          {"id": "end", "role": "end"}],
                                "edges": [{"from": "w1", "to": "w2"}, {"from": "w2", "to": "end"}]})
        r = self.tick(T0)
        self.assertEqual(r["state"], "paused_5h")
        self.assertEqual([p["graph"] for p in r["paused"]], [claude["id"]])
        self.tick(T0 + 61)
        self.assertIsNone(self.g(mixed["id"]).get("paused"), "its Grok step goes on")
        os.environ["PONG_RUNTIMES"] = "claude"  # the next step goes out on Claude
        w1 = next(n for n in self.g(mixed["id"])["nodes"] if n["id"] == "w1")
        jobs.set_status(S, w1["job_id"], "done", result={"summary": "w1 finished"}, summary="w1 finished")
        drain_run(S, write_snap=False)
        g = self.g(mixed["id"])
        w2 = next(n for n in g["nodes"] if n["id"] == "w2")
        self.assertEqual((w2["status"], g["wiring"]["w2"]["runtime"]), ("running", "claude"))
        self.env.screens[w2["seat"]] = LIMIT
        r = self.tick(T0 + 122)
        self.assertEqual({p["graph"] for p in r["paused"]}, {claude["id"], mixed["id"]},
                         "a Claude step that went out during the hold runs into the same limit")
        r = self.tick(at(15) + 61)
        self.assertEqual(r["state"], "ok")
        self.assertIsNone(self.g(mixed["id"])["paused"])
        self.assertIn((w2["seat"], self.L.NUDGE), self.env.typed)

    def test_a_week_or_a_session_reading_never_pauses_a_graph_on_other_ais(self) -> None:
        g = self.graph("grok only", runtimes="grok")
        for text in (USAGE, USAGE.replace("12% used", "100% used").replace("98% used", "60% used")):
            self.env.probe_text = text
            for i in range(4):
                r = self.tick(T0 + i * 200)
                self.assertEqual(r["state"], "ok")
            self.assertIsNone(self.g(g["id"]).get("paused"))
        self.assertEqual(self.env.started, 0, "no Claude graph runs: Claude's use is not even read")

    def test_the_weekly_stop_spares_a_graph_on_other_ais_beside_a_claude_one(self) -> None:
        claude, grok = self.graph("claude"), self.graph("grok only", runtimes="grok")
        self.env.probe_text = USAGE
        self.tick(T0)
        self.tick(T0 + 20)
        r = self.tick(T0 + 30)
        self.assertEqual(r["state"], "paused_week")
        self.assertEqual([p["graph"] for p in r["paused"]], [claude["id"]])
        self.assertIsNone(self.g(grok["id"]).get("paused"))

    def test_a_full_week_pauses_nothing_with_both_switches_off(self) -> None:
        g = self.graph()
        self.env.probe_text = USAGE.replace("98% used", "100% used")
        for t in (T0, T0 + 20, T0 + 30, T0 + 40):
            r = self.tick(t, week_stop_pct=0, ride_out_5h=False)
        self.assertEqual(r["state"], "ok")
        self.assertIsNone(self.g(g["id"]).get("paused"))
        self.assertEqual(self.env.started, 0, "nothing to watch for: Claude Code is not started for a reading")

    def test_a_full_week_with_usage_credits_on_and_the_weekly_stop_off_pauses_nothing(self) -> None:
        g = self.graph()
        full = USAGE.replace("98% used", "100% used")
        self.env.probe_text = full.replace("Usage credits are off · /usage-credits to turn them on", "Usage credits are on")
        for t in (T0, T0 + 20, T0 + 30, T0 + 40):
            r = self.tick(t, week_stop_pct=0)
        self.assertEqual((r["state"], r["credits"]), ("ok", "on"), "Claude goes on working on the person's credits")
        self.assertIsNone(self.g(g["id"]).get("paused"))
        # credits off: the full week has stopped Claude, so the 5-hour switch rides it out
        self.env.probe_text = full
        for t in (T0 + 220, T0 + 230):
            r = self.tick(t, week_stop_pct=0)
        self.assertEqual(r["state"], "paused_week")
        # and turned on during that hold, the hold the reading alone made ends
        self.env.probe_text = self.env.probe_text.replace("Usage credits are off · /usage-credits to turn them on", "Usage credits are on")
        for t in (T0 + 420, T0 + 430, T0 + 440):
            r = self.tick(t, week_stop_pct=0)
        self.assertEqual(r["state"], "ok")
        self.assertIsNone(self.g(g["id"])["paused"])


class ClaudeOffTests(_Base):
    """Claude switched off in Settings: nothing Claude-related runs, and a hold it made ends."""

    def test_nothing_is_read_or_paused_with_claude_switched_off(self) -> None:
        (Path(self.tmp.name) / "settings.json").write_text(json.dumps({"ai_enabled": {"claude": False}}))
        self.assertFalse(self.L._settings()["claude"])
        g = self.graph()
        self.env.screens[self.seat(g["id"])] = LIMIT
        self.env.probe_text = USAGE.replace("12% used", "99% used")
        for i in range(6):
            r = self.tick(T0 + i * 200, claude=False)
            self.assertEqual(r["state"], "ok")
        self.assertIsNone(self.g(g["id"]).get("paused"))
        self.assertEqual((self.env.started, self.env.sent, self.env.read, self.env.screen_reads), (0, 0, 0, 0),
                         "Claude Code is never started, not even for a reading, and no screen is read")
        self.assertEqual(self.env.typed, [])

    def test_switching_claude_off_lifts_the_hold_and_closes_the_reading_pane(self) -> None:
        g = self.graph()
        self.env.probe_text = USAGE
        self.tick(T0)
        self.tick(T0 + 20)
        self.assertEqual(self.tick(T0 + 30)["state"], "paused_week")
        self.assertTrue(self.env.probe_up)
        r = self.tick(T0 + 40, claude=False)
        self.assertEqual(r["state"], "ok")
        self.assertIsNone(self.g(g["id"])["paused"])
        self.assertFalse(self.env.probe_up)
        self.assertTrue(any("Claude was switched off" in d for d in r["did"]))


class LiftTests(_Base):
    def test_a_lift_that_failed_is_kept_and_tried_again(self) -> None:
        g = self.graph()
        self.env.screens[self.seat(g["id"])] = LIMIT
        self.assertEqual(self.tick(T0)["state"], "paused_5h")
        self.env.fail_resume = 1
        r = self.tick(at(15) + 61)
        self.assertEqual(r["state"], "ok")
        self.assertTrue(self.g(g["id"])["paused"]["manual"], "not lifted yet")
        kept = self.L.load_state()["paused"]
        self.assertEqual([(p["graph"], p["tries"]) for p in kept], [(g["id"], 1)], "its record is kept, not dropped")
        self.tick(at(15) + 120)
        self.assertIsNone(self.g(g["id"])["paused"], "the next pass lifts it")
        self.assertEqual(self.L.load_state()["paused"], [])

    def test_resume_says_what_it_could_not_resume(self) -> None:
        g = self.graph()
        self.env.screens[self.seat(g["id"])] = LIMIT
        self.tick(T0)
        self.env.fail_resume = 1
        r = self.L.resume_now(env=self.env, now=T0 + 60)
        self.assertEqual((r["resumed"], r["not_resumed"]), ([], [f"{S}/{g['id']}"]))
        self.assertIn("could not be resumed yet", r["note"])
        r = self.L.resume_now(env=self.env, now=T0 + 90)
        self.assertEqual(r["resumed"], [f"{S}/{g['id']}"], "pressed again, it tries again")
        self.assertIsNone(self.g(g["id"])["paused"])


class TwoTeamTests(unittest.TestCase):
    """A held step goes out under its own team's name, whichever team the process was bound to before."""

    TEAMS = ("team-a", "team-b")

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self._env = {k: os.environ.get(k) for k in ("PONG_HOME", "PONG_RUNTIMES", "PONG_SESSION", "PONG_TOKEN", "PONG_SEAT")}
        os.environ["PONG_HOME"] = self.tmp.name
        os.environ["PONG_RUNTIMES"] = "claude,grok,codex,hermes"
        for k in ("PONG_SESSION", "PONG_TOKEN", "PONG_SEAT"):
            os.environ.pop(k, None)
        from pong.jsonutil import write_json
        from pong.paths import active_path, ensure_layout, pairs_path

        pairs = {}
        for t in self.TEAMS:
            ensure_layout(t)
            pairs[t] = {"schema_version": 2, "project_root": self.tmp.name,
                        "conductor": {"id": "c1", "type": "claude", "label": "lead", "cmd": "claude", "mode": "tmux",
                                      "tmux_index": 0},
                        "workers": [], "transport_default": "job", "flow_graph": {"edges": []}}
        write_json(pairs_path(), pairs)
        write_json(active_path(), {**pairs[self.TEAMS[0]], "session": self.TEAMS[0]})

    def tearDown(self) -> None:
        for k, v in self._env.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        self.tmp.cleanup()

    def held(self, reason: str) -> list[dict]:
        """In each team, a graph paused by the limits whose first step finished during the pause: its second
        step is held by the engine, to go out when the pause is lifted."""
        from pong import jobs
        from pong import limits as L
        from pong.cron import apply_token
        from pong.drain import run as drain_run
        from pong.routing import ensure_session_token
        from pong.work_graph import find_graph, start

        recs = []
        for t in self.TEAMS:
            os.environ.pop("PONG_TOKEN", None)
            os.environ["PONG_SESSION"] = t
            ensure_session_token(t)
            apply_token(t)
            g = start(t, owner="c1", loop="graph", task="plan",
                      topology={"name": "two", "start": "w1",
                                "nodes": [{"id": "w1", "role": "writer"}, {"id": "w2", "role": "writer"}, {"id": "end", "role": "end"}],
                                "edges": [{"from": "w1", "to": "w2"}, {"from": "w2", "to": "end"}]})
            at_ = L.Env().pause(t, g["id"], reason)
            w1 = next(n for n in find_graph(t, g["id"])["nodes"] if n["id"] == "w1")
            jobs.set_status(t, w1["job_id"], "done", result={"summary": "w1 finished"}, summary="w1 finished")
            drain_run(t, write_snap=False)
            nodes = {n["id"]: n["status"] for n in find_graph(t, g["id"])["nodes"]}
            self.assertEqual((nodes["w1"], nodes["w2"]), ("done", "held"))
            recs.append({"session": t, "graph": g["id"], "at": at_})
        for k in ("PONG_SESSION", "PONG_TOKEN"):
            os.environ.pop(k, None)
        return recs

    def assert_sent_out(self, recs: list[dict]) -> None:
        from pong import jobs
        from pong.work_graph import find_graph

        for rec in recs:
            g = find_graph(rec["session"], rec["graph"])
            self.assertEqual(g["status"], "running", rec)
            self.assertIsNone(g.get("paused"))
            w2 = next(n for n in g["nodes"] if n["id"] == "w2")
            self.assertEqual(w2["status"], "running", rec)
            self.assertFalse([h for h in g.get("history") or [] if h.get("event") == "dispatch_failed"], rec)
            self.assertIn(w2["job_id"], [j.get("id") for j in jobs.list_jobs(rec["session"])], "filed in its own team")

    def test_the_runner_lifts_each_pause_as_the_graphs_own_team(self) -> None:
        from pong import limits as L
        from pong import runtime

        recs = self.held(L.REASON_5H)
        L.save_state({"state": "paused_5h", "until": time.time() - 120, "paused": recs, "usage": None,
                      "credits": None, "note": "", "_": {}})
        with contextlib.redirect_stderr(io.StringIO()):
            runtime.run(loops=1, cron=False, interval=1)  # drains both teams (bound to the last), then the limits
        self.assert_sent_out(recs)
        self.assertEqual(L.load_state()["paused"], [])

    def test_resume_lifts_every_team_and_leaves_the_binding_as_it_was(self) -> None:
        from pong import limits as L

        recs = self.held(L.REASON_WEEK)
        L.save_state({"state": "paused_week", "until": None, "paused": recs, "usage": None, "credits": None,
                      "note": "", "_": {}})
        r = L.resume_now()
        self.assertEqual(sorted(r["resumed"]), sorted(f"{x['session']}/{x['graph']}" for x in recs))
        self.assert_sent_out(recs)
        self.assertIsNone(os.environ.get("PONG_SESSION"))
        self.assertIsNone(os.environ.get("PONG_TOKEN"))


if __name__ == "__main__":
    unittest.main()
