#!/usr/bin/env python3
"""Starting a stopped team again under its own name (1.9, `pong team start`), pinned by what it must do.

- The lead comes back on window 0 of a session with the team's own name, with its own launch line.
- A lead that was a chat's seat starts on its chat's prompt again; any other lead starts plain.
- Every helper gets its own window back; the roster, name and folder are left as they were.
- A running team, an unknown team and a state folder that is not the live one are refused, and
  nothing is typed into tmux.

tmux is never touched: the calls are recorded instead.
"""
from __future__ import annotations

import json
import os
import sys
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "python"))

S = "pong-team-77"


class TeamStartTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        os.environ["PONG_HOME"] = self.tmp.name
        os.environ.pop("PONG_SEAT", None)
        from pong import composer as C
        from pong import groups as G
        from pong import routing as R
        from pong.paths import ensure_layout
        from pong.state import load_pairs_db, save_pairs_db

        self.C, self.G, self.R = C, G, R
        ensure_layout(S)
        db = load_pairs_db()
        db[S] = {
            "session": S,
            "display_name": "Persona loop",
            "project_root": self.tmp.name,
            "conductor": {"id": "c1", "type": "claude", "cmd": "claude", "tmux_index": 0, "label": "lead"},
            "workers": [
                {"id": "w1", "type": "grok", "cmd": "grok", "label": "Dist", "tmux_index": 1},
                {"id": "w2", "type": "grok", "cmd": "grok", "label": "SEO", "tmux_index": 2, "parent_id": "w1"},
            ],
        }
        save_pairs_db(db)
        self.load_pairs_db = load_pairs_db

        # record, never run: tmux, the typed launch lines, the seat windows, the pane registry
        self.calls: list[tuple] = []
        self.live = False
        self.saved = {k: getattr(G, k) for k in ("_tmux", "type_launch", "session_exists", "isolated_home", "ensure_seat_window")}
        self.saved_reg = R.register_worker_pane

        def tmux(*args):
            self.calls.append(("tmux",) + args)
            if args[:1] == ("display-message",):
                return True, "%9" + args[2][-1]
            return True, ""

        G._tmux = tmux
        G.type_launch = lambda target, cmd, *, session, seat: self.calls.append(("type", target, seat, cmd))
        G.session_exists = lambda name: self.live
        G.isolated_home = lambda: False
        G.ensure_seat_window = lambda state, w: (self.calls.append(("seat", w["id"], w["tmux_index"])) or f"{w['id']}: spawned")
        R.register_worker_pane = lambda session, seat, **kw: self.calls.append(("register", seat, kw.get("pane_id")))

    def tearDown(self) -> None:
        for k, v in self.saved.items():
            setattr(self.G, k, v)
        self.R.register_worker_pane = self.saved_reg
        self.tmp.cleanup()
        os.environ.pop("PONG_HOME", None)

    def test_the_lead_and_every_helper_come_back_under_the_same_name(self) -> None:
        out = self.C.start_team(S)
        self.assertEqual(out["session"], S)
        # the team's own folder, never the folder the command ran from (the app runs from /)
        self.assertIn(("tmux", "new-session", "-d", "-s", S, "-n", "lead", "-c", self.tmp.name), self.calls)
        typed = [c for c in self.calls if c[0] == "type"]
        self.assertEqual(len(typed), 1)
        self.assertEqual(typed[0][1], f"{S}:0")
        self.assertEqual(typed[0][2], "c1")
        self.assertIn("export PONG_SESSION=" + S, typed[0][3])
        self.assertIn("export PONG_SEAT=c1", typed[0][3])
        self.assertEqual([c[1:] for c in self.calls if c[0] == "seat"], [("w1", 1), ("w2", 2)])
        self.assertEqual([c[1] for c in self.calls if c[0] == "register"], ["c1", "w1", "w2"])
        self.assertFalse(out["lead_prompt"])
        # the roster is the team's own, untouched
        entry = self.load_pairs_db()[S]
        self.assertEqual(entry["display_name"], "Persona loop")
        self.assertEqual([w["id"] for w in entry["workers"]], ["w1", "w2"])

    def test_a_chat_lead_starts_on_its_chat_prompt_again(self) -> None:
        from pong import architect as A

        prompt = Path(self.tmp.name) / "a_lead.md"
        prompt.write_text("who you are")
        with A._locked(S) as data:
            data["architects"].append({"id": "a_lead", "seat": "c1", "title": "Marketing agency", "prompt_path": str(prompt),
                                       "graphs": [], "queue": [], "created_at": time.time(), "lead": True})
        out = self.C.start_team(S)
        self.assertTrue(out["lead_prompt"])
        typed = [c for c in self.calls if c[0] == "type"][0][3]
        self.assertIn(str(prompt), typed)
        self.assertIn("Marketing agency", typed)

    def test_a_running_or_unknown_team_is_refused_and_nothing_is_typed(self) -> None:
        self.live = True
        with self.assertRaises(self.C.ComposeError) as e:
            self.C.start_team(S)
        self.assertIn("already running", str(e.exception))
        self.live = False
        with self.assertRaises(self.C.ComposeError):
            self.C.start_team("pong-team-404")
        self.G.isolated_home = lambda: True
        with self.assertRaises(self.C.ComposeError):
            self.C.start_team(S)
        self.assertEqual([c for c in self.calls if c[0] in ("type", "seat")], [])
        self.assertFalse(any(c[:2] == ("tmux", "new-session") for c in self.calls))


if __name__ == "__main__":
    unittest.main()
