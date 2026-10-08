#!/usr/bin/env python3
"""Short names for chats and graphs (1.9, `pong names`), pinned by what they must do.

- `graph list --json` shows a known name in place of the title and keeps the old one as raw_title;
  a graph's chat shows its chat's name too.
- A chat or graph with no name is wanted; so is a chat named before it had a graph, once.
  A name a person set is never wanted again, and a failed attempt waits before it is tried again.
- A model's answer becomes a name only when it is one: short, not a sentence, not a key.
- The fill writes names from the model's answers (a fake command here), keeps a person's name, and
  marks a failure; a temporary home never starts a fill and never spends a token, and a fill run by
  hand calls no model while the helper AI or Claude is switched off.
- The chat's request is read from its launch line.
"""
from __future__ import annotations

import json
import os
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "python"))

S = "pong-team-78"


class NamesTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        os.environ["PONG_HOME"] = self.tmp.name
        for k in ("PONG_NAMES", "PONG_NAMES_CMD"):
            os.environ.pop(k, None)
        from pong import names as N
        from pong.paths import ensure_layout

        self.N = N
        ensure_layout(S)

    def tearDown(self) -> None:
        for k in ("PONG_HOME", "PONG_NAMES", "PONG_NAMES_CMD"):
            os.environ.pop(k, None)
        self.tmp.cleanup()

    def payload(self, *, graphs=None, chat_graphs=None):
        return {"graphs": graphs if graphs is not None else
                [{"session": S, "id": "g_1", "title": "bakery-plan-v1", "goal_text": "Write two plans for the client",
                  "architect": {"id": "a_1", "title": "I want you to look into"}}],
                "architects": [{"session": S, "id": "a_1", "seat": "c1", "title": "I want you to look into",
                                "graphs": chat_graphs if chat_graphs is not None else ["g_1"]}],
                "asks": []}

    def test_apply_shows_names_and_keeps_the_old_title(self) -> None:
        N = self.N
        N.set_name("graph", S, "g_1", "Riverside Bakery plans for Sam")
        N.set_name("chat", S, "a_1", "Riverside Bakery plans with Sam")
        p = self.payload()
        N.apply(p)
        g, a = p["graphs"][0], p["architects"][0]
        self.assertEqual(g["title"], "Riverside Bakery plans for Sam")
        self.assertEqual(g["raw_title"], "bakery-plan-v1")
        self.assertEqual(a["title"], "Riverside Bakery plans with Sam")
        self.assertEqual(a["raw_title"], "I want you to look into")
        self.assertEqual(g["architect"]["title"], "Riverside Bakery plans with Sam")

    def test_nothing_known_changes_nothing(self) -> None:
        p = self.payload()
        self.N.apply(p)
        self.assertEqual(p["graphs"][0]["title"], "bakery-plan-v1")
        self.assertNotIn("raw_title", p["graphs"][0])

    def test_wanted(self) -> None:
        N = self.N
        keys = lambda p: sorted(w["key"] for w in N.wanted(p))
        self.assertEqual(keys(self.payload()), [N.key("chat", S, "a_1"), N.key("graph", S, "g_1")])
        # a chat named before its first graph is named again once it has one
        with N._locked() as d:
            d["names"][N.key("chat", S, "a_1")] = {"name": "Look into something", "by": "model", "with_graph": False}
            d["names"][N.key("graph", S, "g_1")] = {"name": "Riverside Bakery plans", "by": "model"}
        self.assertEqual(keys(self.payload(chat_graphs=[])), [])
        self.assertEqual(keys(self.payload()), [N.key("chat", S, "a_1")])
        # a person's name is never wanted; a failure waits
        N.set_name("chat", S, "a_1", "My own name")
        self.assertEqual(keys(self.payload()), [])
        N.forget("chat", S, "a_1")
        with N._locked() as d:
            d["names"][N.key("chat", S, "a_1")] = {"failed_at": time.time()}
        self.assertEqual(keys(self.payload()), [])

    def test_clean(self) -> None:
        c = self.N.clean
        self.assertEqual(c('  "Riverside Bakery plans for Sam."  '), "Riverside Bakery plans for Sam")
        self.assertEqual(c(""), "")
        self.assertEqual(c("one two three four five six seven eight"), "")
        self.assertEqual(c("x" * 60), "")
        self.assertEqual(c("Token " + "a" * 40), "")
        with self.assertRaises(ValueError):
            self.N.set_name("graph", S, "g_1", "")

    def test_fill_with_a_fake_model(self) -> None:
        N = self.N
        fake = Path(self.tmp.name) / "fake_model.py"
        fake.write_text("import json, sys\nsys.stdin.read()\n"
                        "print(json.dumps({'result': json.dumps({'name': 'Riverside Bakery plans for Sam'})}))\n")
        os.environ["PONG_NAMES_CMD"] = f"{sys.executable} {fake}"
        N.set_name("chat", S, "a_1", "Kept as it is")
        p = self.payload()
        with mock.patch("pong.graph_engine.list_all", return_value=p["graphs"]), \
                mock.patch("pong.architect.list_all", return_value=p["architects"]):
            r = N.fill()
        self.assertEqual(r, {"named": 1, "wanted": 1})
        self.assertEqual(N.name_for("graph", S, "g_1"), "Riverside Bakery plans for Sam")
        self.assertEqual(N.name_for("chat", S, "a_1"), "Kept as it is")
        # a model that answers nothing usable marks a failure instead of a name
        fake.write_text("import sys\nsys.stdin.read()\nprint('no json here')\n")
        N.forget("graph", S, "g_1")
        with mock.patch("pong.graph_engine.list_all", return_value=p["graphs"]), \
                mock.patch("pong.architect.list_all", return_value=p["architects"]):
            r = N.fill()
        self.assertEqual(r["named"], 0)
        self.assertTrue(N.known()[N.key("graph", S, "g_1")].get("failed_at"))

    def test_a_fill_run_by_hand_follows_the_helper_and_claude_switches(self) -> None:
        N = self.N
        ran = Path(self.tmp.name) / "model_ran"
        fake = Path(self.tmp.name) / "fake_model.py"
        fake.write_text("import json, sys\nsys.stdin.read()\n"
                        f"open({str(ran)!r}, 'w').close()\n"
                        "print(json.dumps({'result': json.dumps({'name': 'Plans for the bakery'})}))\n")
        os.environ["PONG_NAMES_CMD"] = f"{sys.executable} {fake}"
        p = self.payload()
        settings = Path(self.tmp.name) / "settings.json"
        for off in ({"ai_enabled": {"claude": False}}, {"limits": {"helper_ai": False}}):
            settings.write_text(json.dumps(off))
            with mock.patch("pong.graph_engine.list_all", return_value=p["graphs"]), \
                    mock.patch("pong.architect.list_all", return_value=p["architects"]):
                self.assertEqual(N.fill(), {"named": 0, "wanted": 0}, off)
            self.assertFalse(ran.exists(), f"no model call with {off}")
            self.assertEqual(N.name_for("graph", S, "g_1"), "")
        settings.write_text(json.dumps({"ai_enabled": {"grok": False}}))  # another AI switched off: no matter
        with mock.patch("pong.graph_engine.list_all", return_value=p["graphs"]), \
                mock.patch("pong.architect.list_all", return_value=p["architects"]):
            self.assertEqual(N.fill()["named"], 2)
        self.assertTrue(ran.exists())
        self.assertEqual(N.name_for("graph", S, "g_1"), "Plans for the bakery")

    def test_names_in_one_team_stay_distinct(self) -> None:
        N = self.N
        self.assertEqual(N.distinct("Bakery plan", ["Bakery plan", "Other"]), "Bakery plan (2)")
        self.assertEqual(N.distinct("Bakery plan", ["bakery plan", "Bakery plan (2)"]), "Bakery plan (3)")
        self.assertEqual(N.distinct("New", ["Old"]), "New")
        # an earlier fill gave two graphs the same name: the later one is named again
        with N._locked() as d:
            d["names"][N.key("graph", S, "g_1")] = {"name": "Bakery plan", "by": "model"}
            d["names"][N.key("graph", S, "g_2")] = {"name": "Bakery plan", "by": "model"}
        graphs = [{"session": S, "id": "g_1", "created_at": 1, "title": "bakery-plan-v1"},
                  {"session": S, "id": "g_2", "created_at": 2, "title": "bakery-plan-v1b"}]
        N._rename_repeats({"graphs": graphs, "architects": []})
        self.assertEqual(N.name_for("graph", S, "g_1"), "Bakery plan")
        self.assertEqual(N.name_for("graph", S, "g_2"), "")
        self.assertIn("Bakery plan", N.facts({"kind": "graph", "rec": graphs[1]}, {}, N.taken("graph", S, but="x")))

    def test_a_temporary_home_never_starts_a_fill(self) -> None:
        N = self.N
        self.assertFalse(N.enabled())
        with mock.patch("subprocess.Popen") as popen:
            self.assertFalse(N.kick(self.payload()))
            popen.assert_not_called()
        os.environ["PONG_NAMES_CMD"] = "true"
        os.environ["PONG_NAMES"] = "off"
        self.assertFalse(N.enabled())

    def test_the_model_names_with_thinking_off(self) -> None:
        cmd = self.N._command()  # the real command line (never run here)
        self.assertEqual(json.loads(cmd[cmd.index("--settings") + 1]), {"alwaysThinkingEnabled": False})
        self.assertIn("--no-session-persistence", cmd)
        os.environ["PONG_NAMES_CMD"] = "fake-model --x"
        self.assertEqual(self.N._command(), ["fake-model", "--x"])  # a test's own command is left as it is

    def test_kick_starts_one_fill_at_a_time(self) -> None:
        N = self.N
        os.environ["PONG_NAMES_CMD"] = "true"
        with mock.patch("subprocess.Popen") as popen:
            popen.return_value.pid = os.getpid()
            self.assertTrue(N.kick(self.payload()))
            self.assertFalse(N.kick(self.payload()))  # within the minute, and the fill is alive
            self.assertEqual(popen.call_count, 1)

    def test_request_from_the_launch_line(self) -> None:
        from pong.paths import sessions_dir

        d = sessions_dir(S) / "launch"
        d.mkdir(parents=True, exist_ok=True)
        (d / "c1.sh").write_text("exec claude 'You are the architect. The person'\\''s request, in their own words: "
                                 "«Look into the Riverside Bakery plans for Sam and Alex»'\n")
        self.assertEqual(self.N._request(S, "c1"), "Look into the Riverside Bakery plans for Sam and Alex")
        self.assertEqual(self.N._request(S, "c9"), "")
        text = self.N.facts({"kind": "chat", "rec": self.payload()["architects"][0]}, {})
        self.assertIn("Look into the Riverside Bakery plans", text)


if __name__ == "__main__":
    unittest.main()
