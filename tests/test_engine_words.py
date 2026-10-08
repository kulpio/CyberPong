#!/usr/bin/env python3
"""What the engine says to a person, and when it says the runner is off (2.0, the last fixes), each rule pinned.

- The graph runner is judged by time the Mac was awake: a beat from before the Mac slept is not a runner
  that stopped, and a runner that really stopped (its process gone, or silent while awake) still is.
- `pong doctor` shows a Developer line only when developer is on, never a home folder or the owner's flag;
  a missing key reads "no key yet"; the AIs a team change leaves alone are in its settings.
- `jev status` with no key says so in plain words; a key typed as an argument is never printed back.
- `ask show` reads as text; `graph list` and `graph show` name questions, steps and files, not engine words.
- The Activity drawer's lines name steps and results in words, never a step id or a seat.
- The chat's prompt calls the person by the name they gave; `pong --version` prints the engine's version.
- `limits status --json` carries only the limit switches in `settings`.
- install-agent says why it left the runner alone.
- Every terminal a team opens starts in its project folder (the app runs from /), and a project folder
  given as "." or a relative name is kept as a full path.
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
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "python"))

S = "pong-team"
KEY = "apikey_" + "Wx4" * 14  # fake: shaped like a key, used nowhere else

TOPO = {"start": "w", "nodes": [{"id": "w", "role": "writer", "task": "draft"},
                                {"id": "review", "role": "critic", "task": "review"},
                                {"id": "me", "role": "human"}, {"id": "end", "role": "end"}],
        "edges": [{"from": "w", "to": "review"}, {"from": "review", "to": "me", "on": "win"},
                  {"from": "review", "to": "w", "on": "fail"},
                  {"from": "me", "to": "end", "on": "approved"}, {"from": "me", "to": "w", "on": "rejected"}]}


def node(g, nid):
    return next(n for n in g["nodes"] if n["id"] == nid)


class _Home(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.home = Path(self.tmp.name)
        self._env = {k: os.environ.get(k) for k in ("PONG_HOME", "PONG_RUNTIMES", "PONG_SESSION", "PONG_SEAT",
                                                    "TYPESAFE_API_KEY", "PONG_JEV_FAKE", "PERPLEXITY_API_KEY",
                                                    "PONG_JEV_DISABLED", "PONG_PLAIN_ASK", "PONG_PLAIN_ASK_CMD",
                                                    "PONG_ASK_DETAIL", "HOME")}
        os.environ["PONG_HOME"] = self.tmp.name
        for k in ("PONG_SEAT", "TYPESAFE_API_KEY", "PONG_JEV_FAKE", "PERPLEXITY_API_KEY", "PONG_JEV_DISABLED",
                  "PONG_RUNTIMES", "PONG_SESSION", "PONG_PLAIN_ASK_CMD"):
            os.environ.pop(k, None)
        os.environ["PONG_PLAIN_ASK"] = "off"
        os.environ["PONG_ASK_DETAIL"] = "off"

    def tearDown(self) -> None:
        for k, v in self._env.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        self.tmp.cleanup()

    def own_home(self) -> Path:
        """This Mac's own CyberPong home (no PONG_HOME), in a throwaway home folder."""
        from pong import paths

        user = self.home / "user"
        os.environ.pop("PONG_HOME", None)
        os.environ["HOME"] = str(user)
        for k, v in (("PRIMARY", user / ".pong"), ("LEGACY", user / ".hermes-pong")):
            self.addCleanup(setattr, paths, k, getattr(paths, k))
            setattr(paths, k, v)
        return user

    def settings(self, **kw) -> None:
        (Path(os.environ.get("PONG_HOME") or self.home) / "settings.json").write_text(json.dumps(kw))

    def cli(self, argv: list[str], stdin: str = "") -> tuple[int, str, str]:
        from pong.cli.main import main

        out, err = io.StringIO(), io.StringIO()
        old_in = sys.stdin
        sys.stdin = io.StringIO(stdin)
        try:
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                try:
                    code = main(argv)
                except SystemExit as e:  # argparse's own exits (--version, a usage error)
                    code = int(e.code or 0)
        finally:
            sys.stdin = old_in
        return code, out.getvalue(), err.getvalue()


# ------------------------------------------------------------------ the runner, after a sleep ---

class RunnerAwakeTests(_Home):
    def beat(self, *, wall_ago: float, awake_ago: float, pid: int | None = None) -> float:
        from pong.cron import save_run_state

        now = time.time()
        save_run_state({"runner_ok": True, "last_tick_at": now - wall_ago, "awake_at": time.monotonic() - awake_ago,
                        "pid": os.getpid() if pid is None else pid})
        return now

    def test_a_beat_from_before_the_mac_slept_is_not_a_runner_that_stopped(self) -> None:
        from pong import doctor
        from pong.cron import status

        now = self.beat(wall_ago=3620, awake_ago=20)  # an hour asleep, 20 s awake since the last beat
        r = doctor._runner(now)
        self.assertTrue(r["running"])
        self.assertEqual(r["last_beat_s"], 20, "the beat's age in awake time")
        self.assertTrue(status()["runner_ok"])

    def test_a_runner_that_really_stopped_still_reads_off(self) -> None:
        from pong import doctor
        from pong.cron import status

        now = self.beat(wall_ago=3620, awake_ago=600)  # silent for 10 min while the Mac was awake
        self.assertFalse(doctor._runner(now)["running"])
        dead = 2 ** 22 + 12345  # beyond any pid macOS hands out: the process that wrote the beat is gone
        now = self.beat(wall_ago=3620, awake_ago=20, pid=dead)
        self.assertFalse(doctor._runner(now)["running"])
        self.assertEqual(doctor._runner(now)["last_beat_s"], 3620)
        self.assertFalse(status()["runner_ok"])

    def test_the_clock_can_be_given_and_the_shape_is_kept(self) -> None:
        from pong import doctor

        now = self.beat(wall_ago=5000, awake_ago=10)
        r = doctor._runner(now, mono=time.monotonic() + 400)  # 410 s awake since the beat
        self.assertEqual(set(r), {"ok", "installed", "running", "last_beat_s"})
        self.assertFalse(r["running"])
        from pong.runtime import heartbeat
        from pong.cron import load_run_state

        heartbeat(True)
        st = load_run_state()
        self.assertIsInstance(st["awake_at"], float)
        self.assertTrue(doctor._runner(time.time())["running"])


# ------------------------------------------------------------------ doctor and keys ---

class DoctorWordsTests(_Home):
    def test_no_developer_line_unless_it_is_on(self) -> None:
        from pong import doctor

        text = "\n".join(doctor.format_text(doctor.check()))
        self.assertNotIn("Developer", text)
        self.assertNotIn("--developer", text)
        self.assertNotIn(str(Path.home()), text)
        self.settings(developer=True)
        self.assertIn("Developer: on", "\n".join(doctor.format_text(doctor.check())))

    def test_a_missing_key_reads_no_key_yet(self) -> None:
        from pong import doctor

        text = "\n".join(doctor.format_text(doctor.check()))
        self.assertIn("Jev: no key yet", text)
        self.assertIn("Perplexity: no key yet", text)
        self.assertNotIn("not set · on", text)
        self.settings(limits={"jev": False})
        self.assertIn("Jev: no key yet · switched off in Settings", "\n".join(doctor.format_text(doctor.check())))
        code, out, _ = self.cli(["keys", "status"])
        self.assertEqual(code, 0)
        self.assertIn("Jev: no key yet · switched off in Settings", out)
        self.assertEqual(doctor.key_words("Jev", {"set": True, "source": "settings", "enabled": True}),
                         "Jev: set (from Settings)")

    def test_the_seats_left_alone_are_shown(self) -> None:
        from pong import doctor

        self.assertEqual(doctor.check()["settings"]["protected_labels"], [])
        self.settings(protected_labels=["Personal", "mail"])
        d = doctor.check()
        self.assertEqual(d["settings"]["protected_labels"], ["personal", "mail"])
        self.assertIn("Never moved or stopped in a team change: AIs whose name includes personal, mail",
                      "\n".join(doctor.format_text(d)))

    def test_jev_status_with_no_key_in_plain_words(self) -> None:
        code, out, _ = self.cli(["jev", "status"])
        self.assertEqual(code, 1)
        self.assertNotIn("PONG_HOME", out)
        self.assertIn("Jev: no Jev key in this CyberPong folder. Add one in Settings › Limits & keys", out)
        self.own_home()
        code, out, _ = self.cli(["jev", "status"])
        self.assertIn("Jev: no Jev key on this Mac. Add one in Settings › Limits & keys, or: pong jev key set < file", out)
        code, out, _ = self.cli(["jev", "status", "--json"])
        self.assertEqual(json.loads(out)["key_note"], "no Jev key on this Mac")

    def test_a_key_typed_as_an_argument_is_never_printed_back(self) -> None:
        for argv in (["jev", "key", "set", KEY], ["jev", "key", KEY], ["keys", "set", "--name", "perplexity", KEY],
                     ["-s", S, "jev", "key", "set", "--json", KEY], ["keys", "set", KEY, "--name", "jev"]):
            code, out, err = self.cli(argv)
            self.assertEqual(code, 2, argv)
            self.assertNotIn(KEY, out + err)
            self.assertIn("Paste the key on standard input, not as an argument: pong ", err)
        self.assertIn("pong jev key set < file", self.cli(["jev", "key", "set", KEY])[2])
        self.assertIn("pong keys set --name jev < file", self.cli(["keys", "set", "--name", "jev", KEY])[2])
        code, out, _ = self.cli(["jev", "key", "set"], stdin=KEY + "\n")  # stdin is still the way in
        self.assertEqual(code, 0)
        self.assertNotIn(KEY, out)
        self.assertEqual(self.cli(["keys", "status", "--json"])[0], 0)

    def test_version(self) -> None:
        from pong import __version__

        code, out, _ = self.cli(["--version"])
        self.assertEqual(code, 0)
        self.assertEqual(out.strip(), f"CyberPong engine {__version__}")

    def test_limits_status_settings_are_the_limit_switches_only(self) -> None:
        code, out, _ = self.cli(["limits", "status", "--json"])
        st = json.loads(out)
        self.assertNotIn("claude", st["settings"])
        self.assertIs(st["claude_on"], True)
        self.assertEqual(set(st["settings"]), {"ride_out_5h", "week_stop_pct", "helper_ai", "jev", "perplexity",
                                               "perplexity_daily_usd"})
        self.settings(ai_enabled={"claude": False})
        self.assertIs(json.loads(self.cli(["limits", "status", "--json"])[1])["claude_on"], False)
        self.assertIn("Claude is switched off in Settings", self.cli(["limits", "status"])[1])

    def test_install_agent_says_why_it_left_the_runner_alone(self) -> None:
        from pong import runtime as R

        os.environ["HOME"] = str(self.home / "user")
        r = R.install_agent()
        self.assertEqual(r["reason"], "not_this_home")
        self.assertIn("a copy of CyberPong in another folder", r["error"])
        self.assertNotIn("(~/.pong)", r["error"])
        self.own_home()  # ~/.pong, but in a home folder that is not the account's own
        r = R.install_agent()
        self.assertIn("a home folder other than your account's own", r["error"])


# ------------------------------------------------------------------ a team, a graph, a question ---

class _Team(_Home):
    def setUp(self) -> None:
        super().setUp()
        os.environ["PONG_RUNTIMES"] = "claude,grok,codex,hermes"
        os.environ["PONG_SESSION"] = S
        from pong.jsonutil import write_json
        from pong.paths import active_path, ensure_layout, pairs_path
        from pong.routing import ensure_session_token

        ensure_layout(S)
        self.project = self.home / "project"
        self.project.mkdir()
        (self.project / "PLAN.md").write_text("# The round 2 plan\nThree engines.\n")
        (self.project / "NOTES.md").write_text("# Notes\n")
        pair = {"schema_version": 2, "project_root": str(self.project),
                "conductor": {"id": "c1", "type": "claude", "label": "lead", "cmd": "claude", "mode": "tmux", "tmux_index": 0},
                "workers": [], "transport_default": "job", "flow_graph": {"edges": []}}
        write_json(pairs_path(), {S: pair})
        write_json(active_path(), {**pair, "session": S})
        ensure_session_token(S)

    def g(self, gid):
        from pong.work_graph import find_graph
        return find_graph(S, gid)

    def claim(self, gid, nid, summary, files=()):
        from pong.jobs import record_claim
        from pong.work_graph import tick
        record_claim(S, node(self.g(gid), nid)["job_id"], summary=summary, files=list(files))
        tick(S)
        return self.g(gid)

    def to_gate(self):
        from pong.work_graph import start
        g = start(S, owner="c1", loop="graph", task="write the round 2 plan", topology=TOPO)
        self.claim(g["id"], "w", "done — wrote PLAN.md", files=[str(self.project / "PLAN.md"), str(self.project / "NOTES.md")])
        return self.claim(g["id"], "review", "win — the plan meets the brief")


class GraphWordsTests(_Team):
    def test_the_activity_lines_name_steps_not_ids(self) -> None:
        g = self.to_gate()
        rows = [h for h in g["history"] if h.get("event") in ("dispatch", "gate_open")]
        self.assertEqual([h["summary"] for h in rows if h["event"] == "dispatch"], ["round 1", "round 1"])
        self.assertEqual([h["summary"] for h in rows if h["event"] == "gate_open"],
                         ["after a reviewer finished: it passes"])
        for h in rows:
            self.assertNotRegex(h["summary"], r"\b(visit|c1|review|win|seat|gate|node)\b")
        # the person's answer: the Activity's event column says what they pressed; the line says whether they wrote
        from pong.work_graph import resume
        resume(S, g["id"], outcome="rejected", note="fix the dates")
        ans = [h for h in self.g(g["id"])["history"] if h.get("event") == "gate_answer"]
        self.assertEqual(ans[-1]["summary"], "with a note: fix the dates")

    def test_a_limit_names_the_step_not_its_id(self) -> None:
        from pong.work_graph import start
        topo = {"start": "a", "boundaries": {"max_jobs": 2},
                "nodes": [{"id": "a", "role": "builder", "title": "Build the page"}, {"id": "b", "role": "critic"}],
                "edges": [{"from": "a", "to": "b"}, {"from": "b", "to": "a", "on": "fail"}]}
        g = start(S, owner="c1", loop="graph", task="build it", topology=topo)
        self.claim(g["id"], "a", "v1")
        f = self.claim(g["id"], "b", "fail — the header is missing")
        self.assertEqual(f["stop_reason"], "failed_bounded:jobs")
        stop = [h for h in f["history"] if h.get("event") == "stop"][-1]["summary"]
        self.assertEqual(stop, "Build the page would be job 3, past the graph's limit of 2 jobs")
        routes = [h["summary"] for h in f["history"] if h.get("event") == "route"]
        self.assertIn("→ a reviewer", routes)  # where the work went, by what the step does

    def test_graph_list_and_show_in_plain_words(self) -> None:
        g = self.to_gate()
        code, out, _ = self.cli(["graph", "list"])
        self.assertEqual(code, 0)
        self.assertIn("1 question waiting", out)
        self.assertNotIn("gate(s)", out)
        code, out, _ = self.cli(["-s", S, "graph", "show", "--id", g["id"]])
        self.assertEqual(code, 0)
        self.assertIn("QUESTION FOR YOU: Is the work (2 files) good enough to call it done?", out)
        self.assertIn("  Your answer: A reviewer finished: it passes. You decide what happens next.", out)
        self.assertIn(f"    files: {self.project / 'PLAN.md'}", out)
        self.assertNotIn("artifact:", out)
        self.assertNotIn("GATE ", out)
        self.assertNotIn("(me)", out)
        # the card lists both files, so no point repeats them
        self.assertNotIn("The work is in 2 files", out)

    def test_the_designers_question_says_details_are_coming(self) -> None:
        from pong.cli import main as M

        gate = {"node": "me", "reason": "r", "ask_pending": True,
                "ask": {"question": "Send the plan?", "own": True, "by": "the graph's designer"}}
        g = {"id": "g_1", "title": "t", "status": "running", "kind": "graph", "budget": {}, "nodes": [], "gates": [gate]}
        import pong.work_graph as W
        orig = W.snapshot_block
        W.snapshot_block = lambda sess, **kw: {"graphs": [g]}
        try:
            code, out, _ = self.cli(["-s", S, "graph", "show", "--id", "g_1"])
            self.assertIn("Send the plan?  (details coming)", out)
            gate["ask"] = {"question": "Is it done?", "own": False, "by": "CyberPong"}
            code, out, _ = self.cli(["-s", S, "graph", "show", "--id", "g_1"])
            self.assertIn("Is it done?  (plain words coming)", out)
        finally:
            W.snapshot_block = orig
        self.assertEqual((M._step_name("me"), M._step_name("baseline-review")), ("Your answer", "Baseline review"))

    def test_ask_show_reads_as_text(self) -> None:
        from pong import asks as Q

        r = Q.new(S, "Put the $600 into the newspaper ad or more social ads?", context=["Open question 2 of the plan."],
                  options=[Q.parse_option("Newspaper::the half page on 18 March"), Q.parse_option("Social::two more weeks")],
                  files=[str(self.project / "PLAN.md")], detail=[{"text": "The ad costs $600.", "file": str(self.project / "PLAN.md"),
                                                                    "where": "Budget"}])
        code, out, _ = self.cli(["-s", S, "ask", "show", "--id", r["id"]])
        self.assertEqual(code, 0)
        self.assertFalse(out.lstrip().startswith("{"), "text, not the record")
        for line in ("Put the $600 into the newspaper ad or more social ads?", "  · Open question 2 of the plan.",
                     "What you're deciding (by the chat):", f"  - The ad costs $600.  [{self.project / 'PLAN.md'} · Budget]",
                     "  1. Newspaper: the half page on 18 March", f"Files: {self.project / 'PLAN.md'}",
                     f"To answer: pong -s {S} ask answer --id {r['id']} --choice <number>"):
            self.assertIn(line, out)
        code, out, _ = self.cli(["-s", S, "ask", "show", "--id", r["id"], "--json"])
        self.assertEqual(json.loads(out)["id"], r["id"])

    def test_a_chats_long_context_line_is_cut_where_a_sentence_ends(self) -> None:
        from pong import asks as Q

        long = "The first fact is here. " + "The second runs on and on without an end in sight " * 6
        r = Q.new(S, "Go?", context=[long])
        self.assertEqual(r["context"], ["The first fact is here."])


class StartFolderTests(_Team):
    def test_every_window_and_session_a_team_opens_starts_in_its_project(self) -> None:
        # tmux opens a new window where the command runs (the app's folder is /): each one names its folder
        from pong import groups

        calls: list[tuple] = []
        names = ("_tmux", "type_launch", "isolated_home", "window_exists", "session_exists")
        orig = {k: getattr(groups, k) for k in names}
        groups._tmux = lambda *a: calls.append(a) or (True, "")
        groups.type_launch = lambda *a, **kw: None
        groups.isolated_home = lambda: False
        groups.window_exists = lambda session, idx: False
        groups.session_exists = lambda name: False
        try:
            state = {"session": S, "project_root": str(self.project)}
            groups.ensure_seat_window(state, {"id": "w1", "type": "claude", "cmd": "claude", "tmux_index": 1})
            groups.ensure_view_session(state, {"id": "w1", "tmux_index": 1})
            groups.ensure_seat_window({"session": S}, {"id": "w2", "type": "claude", "cmd": "claude", "tmux_index": 2})
        finally:
            for k, v in orig.items():
                setattr(groups, k, v)
        opened = [c for c in calls if c[:1] in (("new-window",), ("new-session",))]
        self.assertEqual(len(opened), 3)
        self.assertEqual([c[-2:] for c in opened],
                         [("-c", str(self.project)), ("-c", str(self.project)), ("-c", str(Path.home()))])

    def test_a_relative_project_folder_is_kept_as_a_full_path(self) -> None:
        # the runner and the app run from other folders, where "project" or "." would be somewhere else
        from pong import architect as A
        from pong import groups
        from pong.composer import new_team

        old_cwd, old_win = os.getcwd(), groups.ensure_ephemeral_window
        groups.ensure_ephemeral_window = lambda state, worker, **kw: {"note": "stub"}
        try:
            os.chdir(str(self.home))
            pair = new_team({"title": "t", "goal": "plan the work", "team": {"project_root": "project"}},
                            session="pong-team-9")
            os.chdir(str(self.project))
            r = A.start(S, "the next round", cwd=".")
        finally:
            os.chdir(old_cwd)
            groups.ensure_ephemeral_window = old_win
        real = str(self.project.resolve())
        self.assertEqual(pair["project_root"], real)
        self.assertEqual(A.get(S, r["id"])["cwd"], real)


class ChatPromptTests(_Team):
    def test_the_chat_knows_the_persons_name(self) -> None:
        from pong import architect as A

        p = A._write_prompt(S, "a_1", title="Intake", seat="c1", cwd=str(self.project)).read_text()
        self.assertNotIn("The person you work with is called", p)
        self.settings(owner_name="Sam")
        p = A._write_prompt(S, "a_2", title="Intake", seat="c1", cwd=str(self.project)).read_text()
        self.assertIn("- The person you work with is called Sam.\n", p)


class ArchitectWordsTests(_Team):
    def test_no_tmux_says_homebrew_first(self) -> None:
        from pong import architect as A
        from pong import groups, models

        old = (groups.isolated_home, A._tmux_path, models.find_binary)
        groups.isolated_home = lambda: False
        A._tmux_path = lambda: None
        said = []
        try:
            for brew in (None, "/opt/homebrew/bin/brew"):
                models.find_binary = lambda name, brew=brew: brew if name == "brew" else None
                with self.assertRaises(A.ArchitectError) as e:
                    A.new("Intake app", str(self.project))
                said.append(str(e.exception))
        finally:
            groups.isolated_home, A._tmux_path, models.find_binary = old
        self.assertIn("Install Homebrew (https://brew.sh), then run: brew install tmux", said[0])
        self.assertIn("Run this in Terminal: brew install tmux. Then try again.", said[1])  # Homebrew is there
        self.assertNotIn("Install Homebrew", said[1])


class JevReasonTests(_Team):
    def test_jevs_reasons_for_not_being_asked_are_plain(self) -> None:
        from pong.graph_engine import _jev_blocked

        self.assertEqual(_jev_blocked({}), "No Jev key on this Mac, or Jev is switched off in Settings › Limits & keys.")
        why = _jev_blocked({"boundaries": {"client_facing": True}})
        self.assertNotRegex(why, r"topology|client_ok|client-facing")


if __name__ == "__main__":
    unittest.main()
