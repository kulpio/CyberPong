#!/usr/bin/env python3
"""What a person sees move while a graph step runs.

A research step once wrote 50 KB over twenty minutes while the Graphs
page showed one line, "baseline started". The seat before it had sat at a shell
prompt with a cut-off launch line and no model, and nothing on the page told that
apart from work. These pin the reading of a seat's screen (what it is doing, whether
it moved, whether a model is running at all) and the list of files a running graph
changed in its working folder.
"""
from __future__ import annotations

import os
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "python"))

CLAUDE_BUSY = """\
⏺ I'll start by reading the job file.
⏺ Now I have the material. Writing research/WEB-TODAY.md.
  Read 1 file
⏺ Now WEB-TARGET.md. Reading the remaining target sources.
  Reading activity pane and action canvas designs
  ⎿  $ awk 'NR>=348 && NR<=400' "$J/suite-marketing-seo-ads.md"
✶ Doing… (12m 8s · ↓ 53.3k tokens)
────────────────────────────────────────────────────────────────────────────────
❯
────────────────────────────────────────────────────────────────────────────────
  ⏵⏵ auto mode on (shift+tab to cycle) · esc to interrupt · ← for agents
"""

CLAUDE_BUSY_LATER = CLAUDE_BUSY.replace("✶ Doing… (12m 8s · ↓ 53.3k tokens)", "✳ Pondering… (13m 2s · ↓ 58.1k tokens)")

CLAUDE_IDLE = """\
⏺ Wrote research/WEB-TARGET.md.
✻ Churned for 21m 4s
────────────────────────────────────────────────────────────────────────────────
❯
────────────────────────────────────────────────────────────────────────────────
  ⏵⏵ auto mode on (shift+tab to cycle)
"""

GROK = """\
       —— CLAIM READY · c1.c · job_20260921_162125_df019d ——
     via sync-bot-hooks.py. Setup order is in docs/operations/HELPER-SEAT.md.
     Say approve or reject. I will not push, merge, or apply from here.
     Worked for 1m41s
  ╭──────────────────────────────────────────────────────────────╮
  │ ❯ approve                                                    │
  ╰──────────────────────────── Grok 4.6 (high) · always-approve ╯
  Tab/→:accept suggestion  │  Shift+Tab:mode  │  Ctrl+x:shortcuts
"""

CUT_LAUNCH = """\
sam@Sams-MacBook-Air jev % export PONG_SESSION=pong-team-90; export PONG_SEAT=c1.a; exec claude 'Your job \
is in the file job.prompt.txt.' --strict-mcp-config --disallowedTools 'Bash(git checkout:*),Bash(git r
"""


class SeatScreenTests(unittest.TestCase):
    def setUp(self) -> None:
        from pong import graph_engine

        self.ge = graph_engine

    def test_doing_is_the_latest_step_bullet_for_claude(self) -> None:
        self.assertEqual(self.ge.seat_doing(CLAUDE_BUSY), "Now WEB-TARGET.md. Reading the remaining target sources.")

    def test_doing_is_the_latest_output_line_for_grok(self) -> None:
        self.assertTrue(self.ge.seat_doing(GROK).endswith("Say approve or reject. I will not push, merge, or apply from here."))

    def test_grok_thinking_is_one_line_not_a_wrapped_fragment(self) -> None:
        screen = ("     ❯ Your job is in the file job.prompt.txt. Read\n"
                  "       that file first, then do exactly what it says …\n"
                  "  ┃  ◆ Thinking…\n  ┃\n"
                  "  ┃  This is a thorough document. I need to spot-check at least 25   █\n"
                  "  ┃  claims against the snapshot. Also verify every route            █\n\n"
                  "    ⠧ Thinking… 0.3s                                24s ⇣60.9k [stop]\n"
                  "  ╭──────────────────────────────╮\n  │ ❯                            │\n")
        self.assertEqual(self.ge.seat_doing(screen), "This is a thorough document. I need to spot-check at least 25 "
                                                     "claims against the snapshot. Also verify every route")

    def test_a_finished_claude_turn_shows_its_last_words_not_its_timer(self) -> None:
        screen = ("  No database query, no writes outside the jev folder\n  except the two CyberPong files.\n"
                  "✻ Crunched for 19m 29s · done 1:12 AM\n" + "─" * 40 + "\n❯\n")
        self.assertEqual(self.ge.seat_doing(screen), "No database query, no writes outside the jev folder except the two CyberPong files.")

    def test_an_empty_screen_says_nothing(self) -> None:
        self.assertEqual(self.ge.seat_doing(""), "")
        self.assertEqual(self.ge.seat_doing("────────\n❯\n────────\n"), "")

    def _see(self, node, text, command, at):
        with patch("pong.graph_engine._now", return_value=at):
            return self.ge._see_live(node, text, command)

    def test_a_turning_spinner_is_work_but_not_a_change(self) -> None:
        n = {"id": "baseline", "started_at": 1000.0}
        self.assertTrue(self._see(n, CLAUDE_BUSY, "2.1.278", 1030.0))
        self.assertEqual(n["live"]["state"], "working")
        self.assertTrue(n["live"]["busy"])
        first = n["live"]["changed_at"]
        self._see(n, CLAUDE_BUSY_LATER, "2.1.278", 1060.0)
        self.assertEqual(n["live"]["changed_at"], first, "a timer and a spinner glyph are not movement")
        self.assertEqual(n["live"]["state"], "working", "mid-turn is working even with an unchanged screen")

    def test_an_idle_screen_goes_quiet_after_ten_minutes(self) -> None:
        n = {"id": "baseline", "started_at": 1000.0}
        self._see(n, CLAUDE_IDLE, "2.1.278", 1030.0)
        self.assertEqual(n["live"]["state"], "working")
        self.assertFalse(n["live"]["busy"])
        self.assertTrue(self._see(n, CLAUDE_IDLE, "2.1.278", 1030.0 + 11 * 60))
        self.assertEqual(n["live"]["state"], "quiet")
        self.assertEqual(n["live"]["doing"], "Wrote research/WEB-TARGET.md.")

    def test_a_shell_prompt_is_no_model_after_a_grace(self) -> None:
        n = {"id": "baseline", "started_at": 1000.0}
        self._see(n, CUT_LAUNCH, "zsh", 1010.0)
        self.assertNotEqual(n["live"]["state"], "no_model", "a pane is a shell for a moment before exec")
        self._see(n, CUT_LAUNCH, "zsh", 1070.0)
        self.assertEqual(n["live"]["state"], "no_model")
        self._see(n, CLAUDE_BUSY, "2.1.278", 1100.0)
        self.assertEqual(n["live"]["state"], "working", "the model came up: the alarm clears")

    def test_a_first_look_at_a_long_stuck_seat_is_quiet_not_working(self) -> None:
        n = {"id": "baseline", "started_at": 1000.0}
        self._see(n, CLAUDE_IDLE, "2.1.278", 1000.0 + 2 * 3600)
        self.assertEqual(n["live"]["state"], "quiet", "nothing proves it moved since it started two hours ago")
        m = {"id": "baseline", "started_at": 1000.0}
        self._see(m, CLAUDE_BUSY, "2.1.278", 1000.0 + 2 * 3600)
        self.assertEqual(m["live"]["state"], "working", "mid-turn is proof enough")

    def test_a_key_on_screen_is_not_saved_as_the_doing_line(self) -> None:
        screen = CLAUDE_BUSY.replace("⏺ Now WEB-TARGET.md. Reading the remaining target sources.",
                                     "⏺ Bash(export OPENAI_API_KEY=sk-proj-abcdefghijklmnopqrstuvwxyz0123456789ABCD)")
        n = {"id": "baseline", "started_at": 1000.0}
        self._see(n, screen, "2.1.278", 1030.0)
        self.assertNotIn("sk-proj", n["live"]["doing"])
        self.assertIn("hidden", n["live"]["doing"])
        grok = GROK.replace("via sync-bot-hooks.py.", "via sync-bot-hooks.py. Set MY_SERVICE_TOKEN=abcd1234efgh5678ijkl9012 first.")
        m = {"id": "scout", "started_at": 1000.0}
        self._see(m, grok, "grok-1.0.41-mac", 1030.0)
        self.assertNotIn("abcd1234", m["live"]["doing"], "a named key mid-paragraph is hidden too")

    def test_a_new_visit_starts_a_fresh_reading(self) -> None:
        n = {"id": "baseline", "started_at": 1000.0}
        self._see(n, CLAUDE_IDLE, "2.1.278", 1030.0)
        n["started_at"] = 5000.0
        self._see(n, CLAUDE_BUSY, "2.1.278", 5030.0)
        self.assertEqual(n["live"]["since"], 5000.0)
        self.assertEqual(n["live"]["changed_at"], 5030.0)


class WatchSeatTests(unittest.TestCase):
    """The watcher turns a model-less seat into a question for a person."""

    def setUp(self) -> None:
        from pong import graph_engine

        self.ge = graph_engine
        self.graph = {"id": "g_1", "owner": "c1", "history": [],
                      "nodes": [{"id": "baseline", "seat": "c1.a", "status": "running", "started_at": 1000.0}]}
        self.node = self.graph["nodes"][0]
        self.posts: list[dict] = []

    def _watch(self, screen: str, command: str, at: float) -> bool:
        self.keys: list[tuple] = getattr(self, "keys", [])

        def tmux(*args):
            if args[0] == "send-keys":
                self.keys.append(args)
                return True, ""
            if args[0] == "capture-pane":
                return True, screen
            if args[0] == "display-message":
                return True, command + "\n"
            return True, ""

        with patch("pong.graph_engine._now", return_value=at), \
             patch("pong.groups._tmux", side_effect=tmux), \
             patch("pong.groups.isolated_home", return_value=False), \
             patch("pong.groups.pane_owned", return_value=True), \
             patch("pong.routing.load_pane_registration", return_value={"pane_id": "%40"}), \
             patch("pong.graph_engine._post", side_effect=lambda *a, **k: self.posts.append(k)):
            return self.ge._watch_seat("pong-team-90", self.graph, self.node)

    def test_a_cut_off_launch_asks_a_person_once(self) -> None:
        self._watch(CUT_LAUNCH, "zsh", 1010.0)
        self.assertIsNone(self.node["attention"])
        self.assertTrue(self._watch(CUT_LAUNCH, "zsh", 1080.0))
        self.assertEqual(self.node["attention"], self.ge.NO_MODEL_ATTENTION)
        self.assertEqual(len(self.posts), 1)
        self.assertIn("model is not running", self.posts[0]["summary"])
        self._watch(CUT_LAUNCH, "zsh", 1110.0)
        self.assertEqual(len(self.posts), 1, "one post per alarm, not one per tick")
        self._watch(CLAUDE_BUSY, "2.1.278", 1140.0)
        self.assertIsNone(self.node["attention"])

    def test_grok_trust_is_answered_only_for_the_teams_own_folder(self) -> None:
        with tempfile.TemporaryDirectory() as root:
            self.graph["project_root"] = root
            screen = (f"  Do you trust the contents of this directory?\n  {root}\n"
                      "  Grok Build may run or modify contents in this directory,\n  posing security risks.\n"
                      "     Yes, proceed        y\n     No, quit            n\n")
            self._watch(screen, "grok-1.0.41-mac", 1010.0)
            self.assertEqual(self.keys, [("send-keys", "-t", "%40", "-l", "y")])
            self.assertEqual(self.node["trust_answered"], 1)
            self.keys.clear()
            self.node.pop("trust_answered")
            self._watch(screen.replace(root, "/Users/someone/elsewhere"), "grok-1.0.41-mac", 1020.0)
            self.assertEqual(self.keys, [], "a folder the engine did not open the seat in is a person's call")
            self.assertIn("outside this project", self.node["attention"])
            self.assertEqual(len(self.posts), 1)
            self.node.pop("attention")
            self._watch(screen.replace(root, root + "-sibling"), "grok-1.0.41-mac", 1030.0)
            self.assertEqual(self.keys, [], "a sibling folder with the same prefix is not the team's")
            self.node.pop("attention")
            self._watch(screen + "  ╭──────────╮\n  │ ❯ do you trust the contents of this directory │\n",
                        "grok-1.0.41-mac", 1040.0)
            self.assertEqual(self.keys, [], "a 'y' never goes into an input box")
        self.graph["project_root"] = os.path.expanduser("~")
        self.node.pop("attention", None)
        home = os.path.expanduser("~")
        self._watch(f"  Do you trust the contents of this directory?\n  {home}\n     Yes, proceed   y\n", "grok-1.0.41-mac", 1050.0)
        self.assertEqual(self.keys, [], "never the whole home folder")

    def test_a_permission_question_still_reads_as_one(self) -> None:
        screen = "⏺ Bash(ls)\n Do you want to proceed?\n ❯ 1. Yes\n   2. No\n"
        self._watch(screen, "2.1.278", 1030.0)
        # the question in its own words, and what it is about when the words alone do not say
        self.assertEqual(self.node["attention"], "is asking: \u201cDo you want to proceed? (Bash(ls))\u201d Open its screen to answer.")
        self.assertIn("asking for permission", self.posts[0]["summary"])

    def test_a_specific_question_is_quoted_as_it_is(self) -> None:
        screen = " Edit file\n app.py\n Do you want to make this edit to app.py?\n ❯ 1. Yes\n   2. No\n"
        self._watch(screen, "2.1.278", 1030.0)
        self.assertEqual(self.node["attention"], "is asking: \u201cDo you want to make this edit to app.py?\u201d Open its screen to answer.")


class ChangedFilesTests(unittest.TestCase):
    def setUp(self) -> None:
        from pong import graph_engine

        self.ge = graph_engine
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        (self.root / "research").mkdir()
        (self.root / ".claude").mkdir()
        (self.root / "node_modules").mkdir()
        old = self.root / "HANDOFF.md"
        old.write_text("old")
        os.utime(old, (1000.0, 1000.0))
        self.t0 = time.time() - 600

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def _graph(self, *running, started=None):
        g = {"id": "g_1", "created_at": self.t0, "history": [], "project_root": str(self.root),
             "nodes": [{"id": nid, "status": "running", "role": "researcher", "task": task, "seat": f"c1.{i}",
                        "started_at": started or self.t0 + 60}
                       for i, (nid, task) in enumerate(running)]}
        self._track(g, time.time() - 120)  # the first look lists what is there and tells nothing
        return g

    def _track(self, graph, at=None):
        with patch("pong.graph_engine._now", return_value=at or time.time()):
            return self.ge._track_files("pong-team", graph)

    def _write(self, rel, text="x", at=None):
        p = self.root / rel
        p.write_text(text)
        t = at or time.time()
        os.utime(p, (t, t))
        return p

    def told(self, g):
        return [h for h in g["history"] if h["event"] == "progress"]

    def test_only_files_changed_since_the_graph_started_are_listed(self) -> None:
        g = self._graph(("baseline", "write research/WEB-TODAY.md"))
        self._write("research/WEB-TODAY.md", "x" * 2048)
        self._write(".claude/settings.local.json", "{}")
        self._write("node_modules/dep.js")
        self._write("research/draft.md.swp")
        self.assertTrue(self._track(g))
        self.assertEqual(set(g["files"]), {os.path.join("research", "WEB-TODAY.md")})
        f = g["files"][os.path.join("research", "WEB-TODAY.md")]
        self.assertEqual((f["kb"], f["node"]), (2.0, "baseline"))
        self.assertEqual([(h["node"], h["outcome"]) for h in self.told(g)], [("baseline", "changed")])
        self.assertIn("WEB-TODAY.md · 2 KB", self.told(g)[0]["summary"])

    def test_a_file_belongs_to_the_step_that_ran_when_it_was_written(self) -> None:
        """Installed mid-run, the critic must not appear to have written what it judges."""
        g = {"id": "g_1", "created_at": self.t0, "history": [], "project_root": str(self.root),
             "nodes": [{"id": "baseline", "status": "done", "role": "researcher", "task": "",
                        "started_at": self.t0 + 10, "finished_at": self.t0 + 300},
                       {"id": "baseline-review", "status": "running", "role": "critic", "task": "",
                        "started_at": self.t0 + 301}]}
        self._write("research/WEB-TODAY.md", at=self.t0 + 200)
        self._track(g)
        self.assertEqual(g["files"][os.path.join("research", "WEB-TODAY.md")]["node"], "baseline")
        self.assertEqual(self.told(g), [], "a first look lists files, it does not narrate the past")
        self._write("research/later.md", at=self.t0 + 250)
        self._track(g, time.time() + 70)
        self.assertEqual(g["files"][os.path.join("research", "later.md")]["node"], "baseline")
        self.assertEqual(self.told(g), [], "a finished step's file is listed, not told as news")

    def test_a_file_written_between_steps_has_no_owner(self) -> None:
        g = {"id": "g_1", "created_at": self.t0, "history": [], "project_root": str(self.root),
             "nodes": [{"id": "a", "status": "done", "role": "researcher", "started_at": self.t0 + 10,
                        "finished_at": self.t0 + 100},
                       {"id": "b", "status": "running", "role": "researcher", "started_at": self.t0 + 400}]}
        self._write("HANDOFF.md", at=self.t0 + 200)
        self._track(g)
        self.assertIsNone(g["files"]["HANDOFF.md"]["node"], "a person's edit is not a step's work")

    def test_a_walk_waits_a_minute_and_tells_a_file_once(self) -> None:
        g = self._graph(("baseline", ""))
        now = time.time()
        p = self._write("research/WEB-TODAY.md", "a", at=now - 5)
        self._track(g, now)
        self._write("research/WEB-TODAY.md", "ab", at=now + 5)
        self.assertFalse(self._track(g, now + 30), "no second walk inside a minute")
        self.assertTrue(self._track(g, now + 70))
        self.assertEqual(len(self.told(g)), 1, "a rewrite updates the list, not the timeline")
        self.assertEqual(g["files"][os.path.join("research", "WEB-TODAY.md")]["kb"], 0.0)
        self.assertTrue(p.exists())

    def test_parallel_steps_own_only_the_files_their_task_names(self) -> None:
        g = self._graph(("research-a#1", "write research/web-next-1-decide.md"),
                        ("research-a#2", "write research/web-next-2-proactive.md"))
        self._write("research/web-next-1-decide.md")
        self._write("research/notes-unclaimed.md")
        self._track(g, time.time() + 70)
        self.assertEqual(g["files"][os.path.join("research", "web-next-1-decide.md")]["node"], "research-a#1")
        self.assertIsNone(g["files"][os.path.join("research", "notes-unclaimed.md")]["node"])
        self.assertEqual([h["node"] for h in self.told(g)], ["research-a#1"], "an unowned file is listed, not told")

    def test_a_step_tells_a_few_files_then_the_list_has_the_rest(self) -> None:
        g = self._graph(("baseline", ""))
        for i in range(10):
            self._write(f"research/proto-{i}.py")
        self._track(g, time.time() + 70)
        self.assertEqual(len(g["files"]), 10)
        self.assertEqual(len(self.told(g)), self.ge.FILES_TOLD_PER_VISIT)

    def test_a_trimmed_list_never_tells_a_file_again(self) -> None:
        g = self._graph(("baseline", ""))
        self._write("research/a.md", at=time.time() - 30)
        self._track(g, time.time() + 70)
        g["files"].clear()  # the 300-file trim dropped it
        self._track(g, time.time() + 140)
        self.assertEqual(len(self.told(g)), 1)

    def test_one_more_walk_after_a_step_ends_lists_its_last_files(self) -> None:
        g = self._graph(("baseline", ""))
        now = time.time()
        self._track(g, now)
        self._write("research/last-minute.md", at=now + 20)
        g["nodes"][0].update(status="done", finished_at=now + 25)  # the next node is a gate: no seat runs
        self.assertTrue(self._track(g, now + 70))
        self.assertEqual(g["files"][os.path.join("research", "last-minute.md")]["node"], "baseline")
        self.assertFalse(self._track(g, now + 140), "and then no more walks while nothing runs")

    def test_a_file_dated_in_the_future_does_not_silence_the_rest(self) -> None:
        g = self._graph(("baseline", ""))
        now = time.time()
        self._write("research/future.md", at=now + 10 * 86400)
        self._track(g, now + 70)
        self._write("research/next.md", at=now + 80)
        self._track(g, now + 140)
        self.assertIn(os.path.join("research", "next.md"), [h["summary"].split(" · ")[0] for h in self.told(g)])

    def test_file_lines_are_the_first_history_to_go(self) -> None:
        g = {"id": "g_1", "history": [], "nodes": []}
        self.ge._history(g, "a", "done", "the claim", event="claim")
        for i in range(420):
            self.ge._history(g, "a", "changed", f"f{i}", event="progress")
        self.assertEqual(len(g["history"]), 400)
        self.assertEqual(g["history"][0]["event"], "claim", "a claim outlives file lines")

    def test_no_walk_without_a_running_seat_or_in_a_home_folder(self) -> None:
        g = self._graph(("baseline", ""))
        g["nodes"][0]["status"] = "pending"
        self.assertFalse(self._track(g, time.time() + 70))
        g = {"id": "g_1", "created_at": self.t0, "history": [], "project_root": os.path.expanduser("~"),
             "nodes": [{"id": "b", "status": "running", "role": "researcher", "started_at": self.t0}]}
        with patch("pong.graph_engine._changed_files") as walk:
            self._track(g)
        walk.assert_not_called()
        self.assertNotIn("files", g)

    def test_the_snapshot_carries_the_live_view_and_the_newest_files(self) -> None:
        g = self._graph(("baseline", ""))
        self._write("research/a.md")
        self._track(g, time.time() + 70)
        g["nodes"][0]["live"] = {"since": 1.0, "state": "working", "doing": "Writing a.md", "busy": True,
                                 "changed_at": 2.0, "seen_at": 3.0, "fp": "abc"}
        snap = self.ge.snapshot_node(g, g["nodes"][0])
        # a reading saved before 2.1 has no plain line or line time: the plain line is worked out on the way out
        self.assertEqual(snap["live"], {"state": "working", "doing": "Writing a.md", "busy": True,
                                        "changed_at": 2.0, "seen_at": 3.0, "doing_at": None,
                                        "doing_plain": "Writing a.md"})
        g["nodes"][0]["status"] = "done"
        self.assertIsNone(self.ge.snapshot_node(g, g["nodes"][0])["live"], "a finished step shows no live line")
        fields = self.ge.snapshot_fields(g)
        self.assertEqual([f["path"] for f in fields["files"]], [os.path.join("research", "a.md")])
        self.assertEqual(fields["files_root"], str(self.root))


class GateFilesTests(unittest.TestCase):
    """A gate shows the work to judge, not CyberPong's own notes and lessons files."""

    def test_a_critic_that_wrote_in_the_notes_still_shows_the_plan(self) -> None:
        from pong import graph_engine as ge
        from pong.paths import sessions_dir

        with tempfile.TemporaryDirectory() as home, tempfile.TemporaryDirectory() as root:
            old = os.environ.get("PONG_HOME")
            os.environ["PONG_HOME"] = home
            try:
                notes = str(sessions_dir("t") / "graphs" / "g_1" / "notes.md")
                lessons = str(sessions_dir("t") / "lessons.md")
                g = {"id": "g_1", "files_root": root, "notes_path": notes, "nodes": [
                    {"id": "plan", "role": "writer", "status": "done"},
                    {"id": "critique", "role": "critic", "status": "done",
                     "last_prev": {"node": "plan", "artifacts": ["WEB-NEXT-PLAN.md", "research/D.md", "run.log"]}}]}
                prev = {"node": "critique", "artifacts": [notes, lessons]}
                self.assertEqual(ge._gate_files(g, prev),
                                 [os.path.join(root, "WEB-NEXT-PLAN.md"), os.path.join(root, "research/D.md")])
                # the judge and the next step see the same work, not the notes
                self.assertEqual(ge._upstream_work(g, prev)["artifacts"], ["WEB-NEXT-PLAN.md", "research/D.md"])
                self.assertEqual(ge._upstream_work(g, prev)["node"], "plan")
                own = {"node": "plan", "artifacts": ["/abs/work.md", notes]}
                self.assertEqual(ge._gate_files(g, own), ["/abs/work.md"], "a step's own work is shown, full path")
            finally:
                if old is None:
                    os.environ.pop("PONG_HOME", None)
                else:
                    os.environ["PONG_HOME"] = old


class GateRoutesTests(unittest.TestCase):
    def test_a_gate_says_where_each_answer_goes(self) -> None:
        from pong import graph_engine as ge

        g = {"edges": [{"from": "me", "to": "end", "on": "approved"}, {"from": "me", "to": "plan", "on": "rejected"}]}
        self.assertEqual(ge.gate_routes(g, "me"), {"approved": ["end"], "rejected": ["plan"]})
        named = {"nodes": [{"id": "done", "role": "end"}], "edges": [{"from": "me", "to": "done", "on": "approved"}]}
        self.assertEqual(ge.gate_routes(named, "me")["approved"], ["end"], "an end step named 'done' still ends the run")
        tail = {"edges": [{"from": "merge", "to": "end", "on": "approved"}]}
        self.assertEqual(ge.gate_routes(tail, "merge"), {"approved": ["end"], "rejected": []},
                         "a reject with nowhere to go ends that branch: the island must not call it 'send back'")


class SeatNamesTests(unittest.TestCase):
    def test_seat_names_go_past_z_instead_of_wrapping(self) -> None:
        from pong.work_graph import _next_free_child

        used = {f"c1.{chr(97 + i)}" for i in range(26)}
        self.assertEqual(_next_free_child("c1", used), "c1.n26")
        self.assertEqual(_next_free_child("c1", used | {"c1.n26"}), "c1.n27")
        self.assertEqual(_next_free_child("c1", {"c1.a"}), "c1.b")


if __name__ == "__main__":
    unittest.main()
