#!/usr/bin/env python3
"""What the notch panel reads about each graph and each team (2.1).

The 2.0 notch panel read one team's terminals for its closed state, so a working graph showed as idle,
and its graph line was a step id with the dashes taken out plus the time since the graph was made. It
never said step N of M, which AI, what the step was doing, a quiet step, a pause for Claude's limits or
the runner being off. These pin what the engine now sends so the app never has to guess:

- ``graphs[].now``: the graph's one state and the step to show, its place ("3 of 4"), AI, round, how
  often it was sent back, the doing line in plain words and how old it is, a pause and when it lifts;
- ``nodes[].title`` / ``step_name`` / ``rank``; ``live.doing_plain`` and when the line changed;
- the team's ``alive``, each member's doing line, the graph step a member is on, the lead's latest
  message, ``team_label`` from the team's own name, and the snapshot's top-level ``limits``/``runner``;
- the size cuts that keep the compact snapshot under the app's pipe guard.
"""
from __future__ import annotations

import json
import os
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "python"))

S = "pong-team"
GRAPHS = ROOT / "python" / "pong" / "loops" / "graphs"


def node(g, nid):
    return next(n for n in g["nodes"] if n["id"] == nid)


def record(topo: dict) -> dict:
    """A graph record's shape (nodes, edges, topology starts) from a design, as the engine stores it."""
    from pong.graph_engine import lint

    t = lint(topo)
    return {"nodes": t["nodes"], "edges": t["edges"], "topology": {"start": t["start"], "starts": t["starts"]}}


def template(name: str) -> dict:
    return json.loads((GRAPHS / f"{name}.json").read_text())


# ------------------------------------------------------------------ places ---

class StepPlaceTests(unittest.TestCase):
    """Step N of M: the longest path from the start, work sent back not counted, copies sharing a place."""

    def places(self, topo):
        from pong.graph_engine import step_places

        return step_places(record(topo))

    def test_write_review_asks_the_person_at_step_3_of_3(self) -> None:
        p, total = self.places(template("write-review"))
        self.assertEqual((p["draft"], p["review"], p["me"], total), (1, 2, 3, 3))
        self.assertNotIn("end", p, "the end step has no place and doesn't count")

    def test_build_verify_builds_at_step_1_of_4(self) -> None:
        p, total = self.places(template("build-verify"))
        self.assertEqual((p["build"], p["tests"], p["judge"], p["ship"], total), (1, 2, 3, 4, 4))

    def test_fan_out_plans_at_1_of_5_and_its_copies_share_place_2(self) -> None:
        p, total = self.places(template("fanout-synthesize"))
        self.assertEqual((p["plan"], total), (1, 5))
        self.assertEqual({p[f"work#{i}"] for i in range(1, 5)}, {2})
        self.assertEqual((p["gather"], p["synth"], p["ok"]), (3, 4, 5), "node order said gather was 6 of 8")

    def test_work_sent_back_to_copies_does_not_push_them_forward(self) -> None:
        # walked copy by copy, the edge from "fix" back to a panel copy not yet reached read as a step
        # forward: the panel came out 8 of 8 and the next generation 6 of 6
        p, total = self.places(template("scout-panel"))
        self.assertEqual(({p[f"scout#{i}"] for i in (1, 2, 3)}, p["all"], p["draft"]), ({1}, 2, 3))
        self.assertEqual(({p[f"panel#{i}"] for i in (1, 2, 3)}, p["votes"], p["read"], p["fix"], total),
                         ({4}, 5, 6, 7, 7))
        p, total = self.places(template("tournament-evolve"))
        self.assertEqual(({p[f"gen#{i}"] for i in range(1, 5)}, p["pool"], p["rank"], {p["evolve#1"], p["evolve#2"]},
                          p["meta"], p["pick"], total), ({1}, 2, 3, {4}, 5, 6, 6))

    def test_an_edge_that_sends_work_back_does_not_push_steps_forward(self) -> None:
        topo = {"start": "a", "nodes": [{"id": "a", "role": "builder"}, {"id": "b", "role": "critic"},
                                        {"id": "c", "role": "writer"}, {"id": "ok", "role": "human"},
                                        {"id": "end", "role": "end"}],
                "edges": [{"from": "a", "to": "b"}, {"from": "b", "to": "a", "on": "fail"},
                          {"from": "b", "to": "c", "on": "win"}, {"from": "c", "to": "b"},
                          {"from": "c", "to": "ok"}, {"from": "ok", "to": "a", "on": "rejected"},
                          {"from": "ok", "to": "end", "on": "approved"}]}
        p, total = self.places(topo)
        self.assertEqual((p["a"], p["b"], p["c"], p["ok"], total), (1, 2, 3, 4, 4))

    def test_a_graph_of_cycles_with_no_start_has_no_places_and_no_total(self) -> None:
        from pong.graph_engine import step_places

        g = {"nodes": [{"id": "a", "role": "builder"}, {"id": "b", "role": "critic"}],
             "edges": [{"from": "a", "to": "b"}, {"from": "b", "to": "a"}]}
        self.assertEqual(step_places(g), ({}, None))
        self.assertEqual(step_places({"nodes": [], "edges": []}), ({}, None))

    def test_without_a_named_start_the_steps_nothing_leads_to_start_it(self) -> None:
        from pong.graph_engine import step_places

        g = {"nodes": [{"id": "a", "role": "builder"}, {"id": "b", "role": "builder"}, {"id": "c", "role": "critic"},
                       {"id": "e", "role": "end"}],
             "edges": [{"from": "a", "to": "b"}, {"from": "b", "to": "c"}, {"from": "c", "to": "b", "on": "fail"},
                       {"from": "c", "to": "e"}]}
        self.assertEqual(step_places(g), ({"a": 1, "b": 2, "c": 3}, 3))

    def test_a_copied_start_step_is_its_copies(self) -> None:
        topo = {"start": "w", "nodes": [{"id": "w", "role": "scout", "count": 3}, {"id": "j", "role": "join"},
                                        {"id": "ok", "role": "human"}, {"id": "end", "role": "end"}],
                "edges": [{"from": "w", "to": "j", "on": "*"}, {"from": "j", "to": "ok", "on": "*"},
                          {"from": "ok", "to": "end", "on": "approved"}]}
        p, total = self.places(topo)
        self.assertEqual(({p["w#1"], p["w#2"], p["w#3"]}, p["j"], p["ok"], total), ({1}, 2, 3, 3))


# ------------------------------------------------------------------- words ---

class PlainDoingTests(unittest.TestCase):
    """The doing line in plain words: tool calls by what they do; any other tool text hidden."""

    def test_the_table(self) -> None:
        from pong.graph_engine import plain_doing

        cases = {
            "Read(src/app/Views/Main.swift)": "Reading Main.swift",
            "Read(file_path: \"/tmp/notes/PLAN.md\")": "Reading PLAN.md",
            "Read(docs/GUIDE.md · lines 10-80)": "Reading GUIDE.md",
            "Write(FAQ.md)": "Editing FAQ.md",
            "Update(src/pong/graph_engine.py)": "Editing graph_engine.py",
            "Edit(README.md)": "Editing README.md",
            "MultiEdit(a/b/c.py)": "Editing c.py",
            "Bash(make test && ./scripts/check.sh --all)": "Running a command",
            "Search(pattern: \"TODO\", path: \"src\")": "Searching the files",
            "Grep(needle)": "Searching the files",
            "Glob(**/*.swift)": "Searching the files",
            "WebSearch(query: \"pricing\")": "Looking on the web",
            "WebFetch(https://example.com)": "Looking on the web",
            # Claude Code's screen names, some of them two words (raw tool text reached the panel)
            "Web Search(\"pricing page best practices 2026\")": "Looking on the web",
            "Fetch(https://example.com)": "Looking on the web",
            "Edit Notebook(nb/a.ipynb)": "Editing a.ipynb",
            "NotebookEdit(notebook_path: \"/tmp/b.ipynb\")": "Editing b.ipynb",
            "BashOutput(abc123)": "Running a command",
            "Shell(ls -la)": "Running a command",
            "Task(Research the market)": "Asking a helper",
            "Agent(write the tests)": "Asking a helper",
            "Bash(npm run build": "Running a command",  # cut off at 160 characters: still a command
            "Read(": "Reading a file",
        }
        for raw, want in cases.items():
            self.assertEqual(plain_doing(raw), want, raw)

    def test_other_tool_text_is_hidden(self) -> None:
        from pong.graph_engine import plain_doing

        for raw in ("TodoWrite(3 items)", "KillShell(abc123)", "mcp__notes__list_files(team: 1)",
                    "notes - list_files (MCP)(team: 1)", "ExitPlanMode(plan)", "Kill Shell(abc123)"):
            self.assertIsNone(plain_doing(raw), raw)

    def test_a_two_word_tool_on_a_seats_screen_is_never_shown_raw(self) -> None:
        from pong.graph_engine import hide_keys, plain_doing, seat_doing

        screen = "⏺ I'll look at how others price this.\n\n⏺ Web Search(\"pricing page best practices 2026\")\n" \
                 "  ⎿  Did 1 search in 4s\n\n✶ Pondering… (12s)\n" + "─" * 40 + "\n❯\n"
        raw = hide_keys(seat_doing(screen), screen)
        self.assertEqual(raw, "Web Search(\"pricing page best practices 2026\")")
        self.assertEqual(plain_doing(raw), "Looking on the web")

    def test_plain_sentences_pass_through_cut_at_80_on_a_word(self) -> None:
        from pong.graph_engine import plain_doing

        self.assertEqual(plain_doing("Checking the test results."), "Checking the test results.")
        long = ("Now I have the material and I am writing the research summary for the pricing page, "
                "section by section, with sources")
        out = plain_doing(long)
        self.assertTrue(out.endswith("…"), out)
        self.assertLessEqual(len(out), 81)
        self.assertTrue(long.startswith(out[:-1]), "cut between words, never inside one")
        self.assertEqual(plain_doing("Read 3 files (ctrl+o to expand)"), "Read 3 files")
        self.assertEqual(plain_doing("Update Todos"), "Updating its to-do list")
        # not read as a two-word tool (the app's Words.doing checks it first too)
        self.assertEqual(plain_doing("Update Todos(3 items)"), "Updating its to-do list")

    def test_nothing_or_a_hidden_line_or_a_key_shows_nothing(self) -> None:
        from pong.graph_engine import HIDDEN_DOING, plain_doing

        for raw in ("", None, "   ", HIDDEN_DOING, "export OPENAI_API_KEY=sk-proj-abcdefghijklmnopqrstuvwxyz0123456789ABCD"):
            self.assertIsNone(plain_doing(raw), raw)

    def test_step_names_are_titles_or_role_words_never_ids(self) -> None:
        from pong.graph_engine import step_name

        self.assertEqual(step_name({}, {"id": "t1", "role": "check", "title": "Run  the tests"}), "Run the tests")
        self.assertEqual(step_name({}, {"id": "b", "role": "builder"}), "The builder")
        self.assertEqual(step_name({}, {"id": "c2", "role": "critic"}), "A reviewer")
        self.assertEqual(step_name({}, {"id": "ok", "role": "human"}), "Your answer")
        self.assertEqual(step_name({}, {"id": "x9", "role": "mystery"}), "A step")


class LiveDoingTests(unittest.TestCase):
    """The engine's 30 s look keeps the doing line's plain words and when the line changed."""

    def see(self, n, text, at):
        from pong import graph_engine as ge

        with patch("pong.graph_engine._now", return_value=at):
            return ge._see_live(n, text, "2.1.278")

    def test_the_plain_line_and_its_time(self) -> None:
        n = {"id": "tests", "started_at": 1000.0}
        self.see(n, "⏺ Bash(make test)\n✶ Doing… (1m 2s)\n" + "─" * 40 + "\n❯\n", 1030.0)
        self.assertEqual((n["live"]["doing"], n["live"]["doing_plain"], n["live"]["doing_at"]),
                         ("Bash(make test)", "Running a command", 1030.0))
        self.see(n, "⏺ Bash(make test)\n✳ Pondering… (2m 4s)\n" + "─" * 40 + "\n❯\n", 1090.0)
        self.assertEqual(n["live"]["doing_at"], 1030.0, "the same line keeps its time")
        self.see(n, "⏺ Bash(make test)\n⏺ Update(PLAN.md)\n" + "─" * 40 + "\n❯\n", 1150.0)
        self.assertEqual((n["live"]["doing_plain"], n["live"]["doing_at"]), ("Editing PLAN.md", 1150.0))

    def test_a_key_on_screen_hides_the_line_and_its_plain_words(self) -> None:
        from pong.graph_engine import HIDDEN_DOING

        n = {"id": "b", "started_at": 1000.0}
        self.see(n, "API_TOKEN=abcdefghijklmnopqrstuvwxyz012345\n⏺ Read(app.py)\n", 1030.0)
        self.assertEqual(n["live"]["doing"], HIDDEN_DOING)
        self.assertIsNone(n["live"]["doing_plain"])


# --------------------------------------------------------------- the engine ---

class EngineCase(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self._env = {k: os.environ.get(k) for k in ("PONG_HOME", "PONG_RUNTIMES", "PONG_SESSION", "PONG_SEAT",
                                                     "TYPESAFE_API_KEY", "PONG_JEV_FAKE", "PONG_TOKEN")}
        os.environ["PONG_HOME"] = self.tmp.name
        os.environ["PONG_RUNTIMES"] = "claude,grok,codex,hermes"
        os.environ["PONG_SESSION"] = S
        for k in ("PONG_SEAT", "TYPESAFE_API_KEY", "PONG_JEV_FAKE"):
            os.environ.pop(k, None)
        from pong.jsonutil import write_json
        from pong.paths import active_path, ensure_layout, pairs_path
        from pong.routing import ensure_session_token

        ensure_layout(S)
        # the team's own folder: a step's commands and the file walk run here, never in the home folder
        self.project = Path(self.tmp.name) / "project"
        self.project.mkdir()
        self.pair = {"schema_version": 2, "display_name": "Northwind", "project_root": str(self.project),
                     "conductor": {"id": "c1", "type": "grok", "label": "Grok", "cmd": "grok", "mode": "tmux", "tmux_index": 0},
                     "workers": [{"id": "w2", "type": "claude", "label": "Lead", "cmd": "claude", "tmux_index": 2,
                                  "mission_role": "coder"}],
                     "transport_default": "job",
                     "flow_graph": {"edges": [{"from": "c1", "to": "w2", "kind": "delegate"},
                                              {"from": "w2", "to": "c1", "kind": "claim"}]}}
        write_json(pairs_path(), {S: self.pair})
        active = dict(self.pair)
        active["session"] = S
        write_json(active_path(), active)
        ensure_session_token(S)

    def tearDown(self) -> None:
        for k, v in self._env.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        self.tmp.cleanup()

    def start(self, topo, task="ship it", **kw):
        from pong.work_graph import start

        return start(S, owner="w2", loop="graph", task=task, topology=topo, **kw)

    def g(self, gid):
        from pong.work_graph import find_graph

        return find_graph(S, gid)

    def claim(self, gid, nid, summary, files=None):
        from pong.jobs import record_claim
        from pong.work_graph import tick

        record_claim(S, node(self.g(gid), nid)["job_id"], summary=summary, files=files or [])
        tick(S)
        return self.g(gid)

    def edit(self, gid, fn):
        """Change the stored graph record (what the engine's own ticks would have written)."""
        from pong.work_graph import _graph_lock, load, save

        with _graph_lock(S):
            data = load(S)
            rec = next(x for x in data["graphs"] if x.get("id") == gid)
            fn(rec)
            save(S, data)
        return self.g(gid)

    def block(self, gid, **kw):
        from pong.work_graph import snapshot_block

        return next(x for x in snapshot_block(S, **kw)["graphs"] if x["id"] == gid)


BUILD = {"start": "build",
         "nodes": [{"id": "build", "role": "builder", "title": "Fix the checkout"},
                   {"id": "tests", "role": "critic", "title": "Run the tests"},
                   {"id": "ship", "role": "human", "title": "Final review"},
                   {"id": "end", "role": "end"}],
         "edges": [{"from": "build", "to": "tests"}, {"from": "tests", "to": "build", "on": "fail"},
                   {"from": "tests", "to": "ship", "on": "win"}, {"from": "ship", "to": "end", "on": "approved"},
                   {"from": "ship", "to": "build", "on": "rejected"}]}


class GraphNowTests(EngineCase):
    def test_a_working_graph_says_its_step_place_ai_and_round(self) -> None:
        g = self.start(BUILD)
        now = self.block(g["id"])["now"]
        self.assertEqual((now["state"], now["step"], now["step_name"], now["step_n"], now["steps"]),
                         ("working", "build", "Fix the checkout", 1, 3))
        self.assertEqual((now["runtime"], now["at_once"], now["at_once_names"], now["sent_back"], now["held"]),
                         ("claude", 1, ["Fix the checkout"], 0, 0))
        self.assertEqual((now["round"], now["pause_reason"], now["limit_until"], now["waiting_since"]), (1, "", None, None))
        self.assertIsNotNone(now["step_started_at"])
        self.assertIsNone(now["doing"], "no look at its screen yet: no doing line, never a guess")
        f = self.claim(g["id"], "build", "built it")
        now = self.block(g["id"])["now"]
        self.assertEqual((now["step"], now["step_n"], now["step_name"]), ("tests", 2, "Run the tests"))
        self.assertEqual(f["status"], "running")

    def test_nodes_carry_their_title_name_and_place(self) -> None:
        g = self.start(BUILD)
        blk = self.block(g["id"])
        b, end = next(n for n in blk["nodes"] if n["id"] == "build"), next(n for n in blk["nodes"] if n["id"] == "end")
        self.assertEqual((b["title"], b["step_name"], b["rank"]), ("Fix the checkout", "Fix the checkout", 1))
        self.assertEqual((end["title"], end["step_name"], end["rank"]), (None, "The end", None))
        self.assertEqual(blk["steps"], 3)

    def test_a_question_is_the_step_shown_and_the_wait_starts_when_it_opened(self) -> None:
        g = self.start(BUILD)
        self.claim(g["id"], "build", "built it")
        f = self.claim(g["id"], "tests", "win — all green")
        self.assertEqual(node(f, "ship")["status"], "waiting_human")
        now = self.block(g["id"])["now"]
        self.assertEqual((now["state"], now["step"], now["step_name"], now["step_n"], now["steps"]),
                         ("needs_you", "ship", "Final review", 3, 3))
        self.assertEqual(now["waiting_since"], int(node(f, "ship")["gate"]["at"]))
        self.assertEqual(now["step_started_at"], int(node(f, "ship")["gate"]["at"]))
        self.assertIsNone(now["runtime"], "nothing runs at the person's step")

    def test_work_sent_back_counts_its_visits(self) -> None:
        from pong.work_graph import resume

        g = self.start(BUILD)
        self.claim(g["id"], "build", "built it")
        self.claim(g["id"], "tests", "win — all green")
        resume(S, g["id"], outcome="rejected", note="the totals are wrong")
        now = self.block(g["id"])["now"]
        self.assertEqual((now["state"], now["step"], now["sent_back"]), ("working", "build", 1))

    def test_a_person_s_pause_and_the_runners_pause_for_claudes_limit(self) -> None:
        from pong.limits import REASON_5H, save_state, load_state
        from pong.work_graph import pause

        g = self.start(BUILD)
        pause(S, g["id"])
        now = self.block(g["id"])["now"]
        self.assertEqual((now["state"], now["pause_reason"], now["limit_until"]), ("paused", "paused by you", None))
        self.assertEqual(now["step"], "build", "a pause lets the step at work finish: it is still the one shown")
        g2 = self.start(BUILD, task="second")
        pause(S, g2["id"], reason=REASON_5H)
        st = load_state()
        st.update(state="paused_5h", until=time.time() + 3600, paused=[{"session": S, "graph": g2["id"]}])
        save_state(st)
        now = self.block(g2["id"])["now"]
        self.assertEqual((now["state"], now["pause_reason"]), ("paused_limit", REASON_5H))
        self.assertEqual(now["limit_until"], int(st["until"]))

    def test_a_held_step_is_the_one_shown_when_nothing_runs_under_a_pause(self) -> None:
        from pong.work_graph import pause

        g = self.start(BUILD)
        pause(S, g["id"])
        self.claim(g["id"], "build", "built it")
        now = self.block(g["id"])["now"]
        self.assertEqual((now["state"], now["step"], now["held"], now["at_once"]), ("paused", "tests", 1, 0))

    def test_quiet_no_model_and_a_step_asking_permission(self) -> None:
        from pong.graph_engine import NO_MODEL_ATTENTION

        g = self.start(BUILD)
        t0 = time.time()

        def quiet(rec):
            node(rec, "build")["live"] = {"since": node(rec, "build")["started_at"], "state": "quiet", "busy": False,
                                          "doing": "Read(PLAN.md)", "changed_at": t0 - 900, "seen_at": t0, "doing_at": t0 - 900}
        self.edit(g["id"], quiet)
        now = self.block(g["id"])["now"]
        self.assertEqual((now["state"], now["quiet_since"], now["doing_plain"]), ("quiet", int(t0 - 900), "Reading PLAN.md"))

        def stale(rec):  # a reading left from before the runner stopped looking: ten minutes on, it is quiet
            node(rec, "build")["live"].update(state="working", busy=False, changed_at=t0 - 700)
        self.edit(g["id"], stale)
        self.assertEqual(self.block(g["id"])["now"]["state"], "quiet")

        def gone(rec):
            node(rec, "build")["live"]["state"] = "no_model"
            node(rec, "build")["attention"] = NO_MODEL_ATTENTION
        self.edit(g["id"], gone)
        self.assertEqual(self.block(g["id"])["now"]["state"], "no_model")

        def asks(rec):
            node(rec, "build")["live"]["state"] = "working"
            node(rec, "build")["attention"] = "is asking your permission. Open its screen to answer."
            node(rec, "build")["attention_at"] = t0 - 60
        self.edit(g["id"], asks)
        now = self.block(g["id"])["now"]
        self.assertEqual((now["state"], now["step"], now["waiting_since"]), ("needs_you", "build", int(t0 - 60)))

    def test_the_doing_line_its_age_and_the_newest_file(self) -> None:
        g = self.start(BUILD)
        t0 = time.time()

        def look(rec):
            n = node(rec, "build")
            n["live"] = {"since": n["started_at"], "state": "working", "busy": True, "doing": "Bash(make test)",
                         "doing_plain": "Running a command", "changed_at": t0 - 5, "seen_at": t0, "doing_at": t0 - 20}
            rec["files"] = {"docs/OLD.md": {"at": t0 - 600, "kb": 1.0, "node": "build"},
                            "docs/PLAN.md": {"at": t0 - 30, "kb": 4.2, "node": "build"}}
        self.edit(g["id"], look)
        now = self.block(g["id"])["now"]
        self.assertEqual((now["doing"], now["doing_plain"], now["doing_changed_at"]),
                         ("Bash(make test)", "Running a command", int(t0 - 20)))
        self.assertEqual(now["last_file"], {"path": "docs/PLAN.md", "kb": 4.2, "at": int(t0 - 30), "step": "build"})

    def test_steps_at_once_name_themselves_and_count_the_copies_done(self) -> None:
        g = self.start(template("fanout-synthesize"), task="research the market")
        f = self.claim(g["id"], "plan", "planned four angles")
        self.assertEqual(sum(1 for n in f["nodes"] if n["id"].startswith("work#") and n["status"] == "running"), 4)
        now = self.block(g["id"])["now"]
        self.assertEqual((now["at_once"], now["at_once_names"], now["step_n"], now["steps"], now["at_once_done"]),
                         (4, ["A researcher"], 2, 5, 0))
        self.claim(g["id"], "work#1", "done — found three")
        self.claim(g["id"], "work#3", "done — found two")
        now = self.block(g["id"])["now"]
        self.assertEqual((now["at_once"], now["at_once_done"], now["step_n"]), (2, 2, 2))

    def test_an_automatic_test_runs_no_ai(self) -> None:
        topo = {"start": "b", "nodes": [{"id": "b", "role": "builder"},
                                        {"id": "t", "role": "check", "run": ["true"], "cwd": str(self.project)},
                                        {"id": "ok", "role": "human"}, {"id": "end", "role": "end"}],
                "edges": [{"from": "b", "to": "t"}, {"from": "t", "to": "ok", "on": "win"},
                          {"from": "t", "to": "b", "on": "fail"}, {"from": "ok", "to": "end", "on": "approved"}]}
        g = self.start(topo)
        f = self.claim(g["id"], "b", "built it")
        self.assertEqual(node(f, "t")["status"], "running")
        now = self.block(g["id"])["now"]
        self.assertEqual((now["step"], now["step_name"], now["step_n"], now["runtime"], now["model"]),
                         ("t", "An automatic test", 2, None, None))
        base = node(f, "t")["check"]["base"]  # let the command finish before its folder is removed
        deadline = time.time() + 10
        while not Path(base + ".exit").exists() and time.time() < deadline:
            time.sleep(0.05)
        time.sleep(0.1)

    def test_between_steps_names_the_next_one(self) -> None:
        g = self.start(BUILD)
        self.claim(g["id"], "build", "built it")

        def between(rec):  # the tick that dispatches the next step hasn't run yet
            n = node(rec, "tests")
            n["status"] = "pending"
        self.edit(g["id"], between)
        now = self.block(g["id"])["now"]
        self.assertEqual((now["state"], now["step"], now["step_n"], now["next_name"]),
                         ("between_steps", "build", 1, "Run the tests"))

    def test_a_finished_graph_has_no_now(self) -> None:
        from pong.work_graph import cancel

        g = self.start(BUILD)
        cancel(S, g["id"])
        self.assertIsNone(self.block(g["id"])["now"])

    def test_now_stays_small(self) -> None:
        g = self.start(BUILD)

        def look(rec):
            n = node(rec, "build")
            n["live"] = {"since": n["started_at"], "state": "working", "busy": True, "doing": "x" * 160,
                         "changed_at": time.time(), "seen_at": time.time(), "doing_at": time.time()}
            rec["files"] = {"docs/" + "y" * 40 + ".md": {"at": time.time(), "kb": 12.5, "node": "build"}}
        self.edit(g["id"], look)
        size = len(json.dumps(self.block(g["id"])["now"], separators=(",", ":")))
        self.assertLess(size, 760, size)


class ListAllTests(EngineCase):
    def test_graph_list_names_the_team_and_the_graphs_owner(self) -> None:
        from pong.graph_engine import list_all

        g = self.start(BUILD)
        row = next(r for r in list_all() if r["id"] == g["id"])
        self.assertEqual(row["team_label"], "Northwind", "it came out empty: pairs.json names a team display_name")
        self.assertEqual(row["owner_label"], "Helper 1")
        self.assertEqual((row["now"]["state"], row["now"]["step_name"]), ("working", "Fix the checkout"))
        self.assertEqual(next(n for n in row["nodes"] if n["id"] == "tests")["rank"], 2)

    def test_owner_words(self) -> None:
        from pong.graph_engine import owner_label, owner_labels

        team = {"conductor": {"id": "c1"}, "workers": [{"id": "w3", "ephemeral": True}, {"id": "w1"}, {"id": "w2"}]}
        labels = owner_labels(team)
        self.assertEqual(labels, {"c1": "Lead", "w1": "Helper 1", "w2": "Helper 2", "w3": "Helper 3"})
        for seat in ("c1.arch", "c1.arch2", "c1.arch12"):
            self.assertEqual(owner_label(labels, seat), "Chat", seat)
        self.assertEqual(owner_label(labels, "w9"), "", "a seat nobody named has no label, never its id")
        # a chat's seat on the roster takes no helper's number: the helpers count on with no gap
        team["workers"].insert(1, {"id": "c1.arch", "ephemeral": True})
        self.assertEqual(owner_labels(team), {"c1": "Lead", "w1": "Helper 1", "w2": "Helper 2", "w3": "Helper 3",
                                              "c1.arch": "Chat"})


# ---------------------------------------------------------------- snapshot ---

LEAD_SCREEN = "⏺ I read the failing test.\n⏺ Checking the test results.\n✶ Doing… (12s)\n" + "─" * 40 + "\n❯\n"
HELPER_SCREEN = "⏺ Update(src/checkout/Cart.swift)\n" + "─" * 40 + "\n❯\n"


class SnapshotTests(EngineCase):
    def snap(self, panes=None, alive=False):
        from pong.snapshot import build_snapshot

        with patch("pong.pane_activity.capture_all_alive", return_value=(alive, dict(panes or {}))):
            return build_snapshot()

    def team(self, snap):
        return next(t for t in snap["teams"] if t["session"] == S)

    def test_top_level_limits_and_runner_and_no_second_copy_of_the_graphs(self) -> None:
        from pong.limits import save_state, load_state

        self.start(BUILD)
        st = load_state()
        st.update(state="paused_5h", until=time.time() + 600)
        save_state(st)
        snap = self.snap()
        self.assertNotIn("work_graph", snap, "the all-teams copy was read by nothing and was half the snapshot")
        self.assertEqual(snap["limits"]["state"], "paused_5h")
        self.assertEqual(set(snap["runner"]), {"ok", "installed", "running", "last_beat_s"})
        self.assertEqual(len(self.team(snap)["work_graph"]["graphs"]), 1)

    def test_a_team_says_whether_its_terminals_are_there(self) -> None:
        self.assertFalse(self.team(self.snap(alive=False))["alive"])
        self.assertTrue(self.team(self.snap(alive=True))["alive"])
        with patch("pong.pane_activity.capture_all_alive", side_effect=RuntimeError("no tmux")):
            from pong.snapshot import build_snapshot

            self.assertFalse(self.team(build_snapshot())["alive"])

    def test_each_member_says_what_it_is_doing_and_since_when(self) -> None:
        t = self.team(self.snap({0: LEAD_SCREEN, 2: HELPER_SCREEN}, alive=True))
        c, w = t["conductor"], t["workers"][0]
        self.assertEqual((c["doing"], c["doing_plain"]), ("Checking the test results.", "Checking the test results."))
        self.assertEqual((w["doing"], w["doing_plain"]), ("Update(src/checkout/Cart.swift)", "Editing Cart.swift"))
        first = w["doing_at"]
        self.assertIsNotNone(first)
        time.sleep(0.15)
        w2 = self.team(self.snap({0: LEAD_SCREEN, 2: HELPER_SCREEN}, alive=True))["workers"][0]
        self.assertEqual(w2["doing_at"], first, "an unchanged line keeps its age from one pass to the next")
        w3 = self.team(self.snap({0: LEAD_SCREEN, 2: "⏺ Bash(swift test)\n"}, alive=True))["workers"][0]
        self.assertEqual(w3["doing_plain"], "Running a command")
        self.assertGreater(w3["doing_at"], first)
        gone = self.team(self.snap({}, alive=False))
        self.assertEqual((gone["conductor"]["doing"], gone["workers"][0]["doing_plain"]), (None, None))

    def test_a_key_on_a_members_screen_is_never_sent(self) -> None:
        w = self.team(self.snap({2: "export GITHUB_TOKEN=ghp_abcdefghijklmnopqrstuvwxyz0123456789\n⏺ Read(a.py)\n"},
                                alive=True))["workers"][0]
        self.assertNotIn("ghp_", json.dumps(w))
        self.assertIsNone(w["doing_plain"])

    def test_a_helper_on_a_graph_names_the_graph_and_its_step(self) -> None:
        g = self.start(BUILD)
        t = self.team(self.snap())
        w = t["workers"][0]
        self.assertEqual(w["graph"], {"graph_id": g["id"], "title": self.block(g["id"])["title"],
                                      "step_name": "Fix the checkout"})
        self.assertIsNone(t["conductor"]["graph"], "the lead's line is its own doing, not one of the graphs it runs")
        gr = t["work_graph"]["graphs"][0]
        self.assertEqual((gr["owner_label"], gr["now"]["step_name"]), ("Helper 1", "Fix the checkout"))

    def test_finished_graphs_go_as_one_line_and_a_pause_drops_the_steps_report(self) -> None:
        from pong.work_graph import cancel

        done = self.start(BUILD, task="first")
        cancel(S, done["id"])
        g = self.start(BUILD, task="second")
        self.claim(g["id"], "build", "built it " * 60)
        self.claim(g["id"], "tests", "win — all green " * 30)
        t = self.team(self.snap())
        by_id = {x["id"]: x for x in t["work_graph"]["graphs"]}
        self.assertEqual(set(by_id[done["id"]]), {"id", "title", "status", "stop_reason", "finished_at"})
        self.assertEqual((by_id[done["id"]]["status"], by_id[done["id"]]["stop_reason"]), ("cancelled", "cancelled"))
        self.assertTrue(by_id[g["id"]]["paused"]["gate"])
        self.assertNotIn("prev", by_id[g["id"]]["paused"])
        # the graph page's own reader still has everything
        from pong.work_graph import snapshot_block

        full = next(x for x in snapshot_block(S, full=True)["graphs"] if x["id"] == done["id"])
        self.assertIn("nodes", full)

    def test_the_leads_latest_message(self) -> None:
        from pong.paths import state_dir

        chat = state_dir() / "human" / S / "chat.jsonl"
        chat.parent.mkdir(parents=True, exist_ok=True)
        rows = [{"kind": "from_you", "text": "How are the tests?", "ts": 100.0},
                {"kind": "from_orch", "text": "The tests pass.\nReview starts next.", "ts": 160.0, "seat_id": "c1"},
                {"kind": "from_orch", "text": "Codex finished the fix", "ts": 170.0, "job_id": "job_1", "seat_id": "c1"},
                {"kind": "from_orch", "text": "Enter to select · ↑/↓ to navigate", "ts": 180.0, "seat_id": "c1"},
                {"kind": "status", "text": "c1 busy", "ts": 190.0}]
        chat.write_text("\n".join(json.dumps(r) for r in rows) + "\nnot json\n")
        t = self.team(self.snap())
        self.assertEqual(t["last_message"], {"text": "The tests pass. Review starts next.", "at": 160.0})
        with chat.open("a") as f:
            f.write(json.dumps({"kind": "from_orch", "text": "word " * 80, "ts": 200.0}) + "\n")
        msg = self.team(self.snap())["last_message"]
        self.assertLessEqual(len(msg["text"]), 200)
        self.assertTrue(msg["text"].endswith("…"))
        chat.unlink()
        # no log yet is nothing to show, never null: null sends the app to the chat log itself, and a log
        # that appears before the app reads it (a new team's first job recaps) would reach the panel
        self.assertEqual(self.team(self.snap())["last_message"], {"text": "", "at": None})

    def write_chat(self, text: str) -> None:
        from pong.paths import state_dir

        chat = state_dir() / "human" / S / "chat.jsonl"
        chat.parent.mkdir(parents=True, exist_ok=True)
        chat.write_text(text)

    def test_a_held_back_message_is_empty_never_null(self) -> None:
        """Null tells the app the engine is older, and the app then reads the chat log itself without the
        engine's tests: the line the engine held back (a key in it, or a job's recap) reached the notch
        panel as the lead's words."""
        held = {"text": "", "at": None}
        key = "Use OPENAI_API_KEY=sk-proj-abcdefghijklmnopqrstuvwxyz0123 for the pricing calls."
        self.write_chat(json.dumps({"kind": "from_orch", "text": key, "ts": 100.0, "seat_id": "c1"}) + "\n")
        t = self.team(self.snap())
        self.assertEqual(t["last_message"], held)
        self.assertNotIn("sk-proj", json.dumps(t))
        recap = {"kind": "from_orch", "text": "w2 finished — the checkout fix", "ts": 110.0, "job_id": "job_1",
                 "seat_id": "c1"}
        self.write_chat(json.dumps({"kind": "from_you", "text": "How is it going?", "ts": 90.0}) + "\n"
                        + json.dumps(recap) + "\n")
        self.assertEqual(self.team(self.snap())["last_message"], held, "a job's recap is not the lead speaking")
        self.write_chat("")
        self.assertEqual(self.team(self.snap())["last_message"], held)
        self.write_chat(json.dumps({"kind": "from_orch", "text": "x " * 40000, "ts": 120.0, "seat_id": "c1"}) + "\n")
        self.assertEqual(self.team(self.snap())["last_message"], held, "a row longer than the tail: nothing")
        with patch("pong.snapshot._last_message", side_effect=RuntimeError("unreadable")):
            self.assertEqual(self.team(self.snap())["last_message"], held)

    def test_a_run_of_job_recaps_never_hides_the_leads_own_words(self) -> None:
        recaps = "".join(json.dumps({"kind": "from_orch", "text": f"w2 finished — part {i}", "ts": 200.0 + i,
                                     "job_id": f"job_{i}", "seat_id": "c1"}) + "\n" for i in range(60))

        def lead(pad: int) -> str:
            return json.dumps({"kind": "from_orch", "text": "Pricing research is under way." + " " * pad,
                               "ts": 100.0, "seat_id": "c1"}) + "\n"

        want = {"text": "Pricing research is under way.", "at": 100.0}
        self.write_chat(lead(0) + recaps)
        self.assertEqual(self.team(self.snap())["last_message"], want)
        # a long log: the tail is its last 64 KB, whole rows only
        from pong.snapshot import LAST_MESSAGE_TAIL

        older = json.dumps({"kind": "from_you", "text": "y" * 5000, "ts": 1.0}) + "\n"
        pad = LAST_MESSAGE_TAIL - len(recaps) - len(lead(0))
        self.assertGreater(pad, 0)
        self.write_chat(older + lead(pad) + recaps)  # the lead's row starts right where the tail does
        self.assertEqual(self.team(self.snap())["last_message"], want)
        self.write_chat(older + lead(pad + 1) + recaps)  # its first character is cut off: not a row
        self.assertEqual(self.team(self.snap())["last_message"], {"text": "", "at": None})


class SnapshotSizeTests(EngineCase):
    """The compact snapshot was 75 KB for one team and three graphs, past the 64 KiB a pipe carries in one
    read; and the app reads at most 500,000 bytes, which broke parsing at about 35–40 graphs."""

    GOAL = ("Rewrite the pricing page for the spring launch. Keep the three tiers, add the annual discount, "
            "check every number against PRICES.md and the finance sheet, and keep the tone of the old page. ") * 8

    def graph_at_a_question(self, i: int) -> str:
        g = self.start(template("write-review"), task=f"{i}: {self.GOAL}")
        self.claim(g["id"], "draft", "Drafted the new page. " * 25, files=[f"docs/PRICING-{i}.md", "docs/NOTES.md"])
        self.claim(g["id"], "review", "win — the numbers match PRICES.md; the tone is close to the old page. " * 8)
        return g["id"]

    def compact(self) -> int:
        from pong.cli.main import _compact_snapshot_for_pipe
        from pong.snapshot import build_snapshot

        with patch("pong.pane_activity.capture_all_alive", return_value=(True, {0: LEAD_SCREEN, 2: HELPER_SCREEN})):
            snap = build_snapshot()
        return len(json.dumps(_compact_snapshot_for_pipe(snap), separators=(",", ":")).encode("utf-8"))

    def test_one_team_and_three_graphs_fit_the_pipe(self) -> None:
        from pong.work_graph import cancel

        for i in range(2):
            self.graph_at_a_question(i)
        g = self.start(BUILD, task="fix the checkout. " + self.GOAL)
        self.claim(g["id"], "build", "Fixed the rounding in the cart. " * 20, files=["src/Cart.swift"])
        for i in range(4):  # finished graphs from earlier today
            done = self.start(template("write-review"), task=f"old {i}: {self.GOAL}")
            cancel(S, done["id"])
        size = self.compact()
        self.assertLess(size, 64 * 1024, size)

    def test_forty_running_graphs_stay_well_under_what_the_app_reads(self) -> None:
        for i in range(40):
            self.graph_at_a_question(i)
        size = self.compact()
        self.assertLess(size, 500_000 * 0.8, size)


if __name__ == "__main__":
    unittest.main()
