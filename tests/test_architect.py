#!/usr/bin/env python3
"""Graph architects and graph logs, each pinned by the job it has to do.

- A graph's news reaches its architect as one line, only when the architect is idle and nobody types.
- A long queue is cut to one line that says how many more wait; a busy architect keeps its queue.
- A step quiet 25 minutes is news once, not every tick.
- A graph attached from an architect's pane is that architect's (the newest one on the seat).
- A person's message is one line (an Enter inside it would send half), and it is logged.
- A new project gets a team of its own whose lead is the architect, starting on its prompt file.
- Every history event, dispatch, Jev decision and gate answer lands in the graph's log.
- A step's transcript is found whichever AI wrote it (Claude, Grok, Codex, Hermes).
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

S = "pong-team"
IDLE = "⏺ Done.\n────────\n❯ \n────────\n  ⏵⏵ auto mode on (shift+tab to cycle)\n"
HINT = '⏺ Done.\n────────\n❯ Try "write a test for <filepath>"\n────────\n  ⏵⏵ auto mode on\n'
TYPING = "⏺ Done.\n────────\n❯ I think we should\n────────\n  ⏵⏵ auto mode on\n"
WORKING = "⏺ Reading files\n✽ Roosting… (12s)\n────────\n❯ \n────────\n  ⏵⏵ auto mode on · esc to interrupt\n"
DIALOG = "Do you want to proceed?\n  1. Yes\n  2. No, and tell Claude what to do\n"


def node(g, nid):
    return next(n for n in g["nodes"] if n["id"] == nid)


class _Home(unittest.TestCase):
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
        self.project = Path(self.tmp.name) / "project"
        self.project.mkdir()
        pair = {"schema_version": 2, "project_root": str(self.project),
                "conductor": {"id": "c1", "type": "claude", "label": "lead", "cmd": "claude", "mode": "tmux", "tmux_index": 0},
                "workers": [], "transport_default": "job", "flow_graph": {"edges": []}}
        write_json(pairs_path(), {S: pair})
        active = dict(pair)
        active["session"] = S
        write_json(active_path(), active)
        ensure_session_token(S)
        from pong import architect as A

        self.A = A
        self.screens: dict[str, str] = {}
        self.typed: list[tuple[str, str]] = []
        self._orig = (A._capture, A._type)
        A._capture = lambda session, seat, lines=80: self.screens.get(seat)
        A._type = lambda session, seat, text, enter=True: self.typed.append((seat, text)) or True

    def tearDown(self) -> None:
        self.A._capture, self.A._type = self._orig
        for k in ("PONG_HOME", "PONG_RUNTIMES", "PONG_SESSION", "PONG_TOKEN", "PONG_SEAT"):
            os.environ.pop(k, None)
        self.tmp.cleanup()

    def arch(self, seat="c1.arch", graphs=("g_1",)) -> str:
        with self.A._locked(S) as data:
            aid = self.A._new_id()
            data["architects"].append({"id": aid, "title": "t", "seat": seat, "cwd": str(self.project),
                                       "graphs": list(graphs), "queue": [], "seen": {}, "created_at": time.time()})
        return aid


class ArchitectEvents(_Home):
    def test_idle_means_finished_and_nobody_typing(self) -> None:
        self.assertTrue(self.A.idle_and_empty(IDLE))
        self.assertTrue(self.A.idle_and_empty(HINT), "Claude's dimmed hint prints as text; it is still an empty box")
        self.assertFalse(self.A.idle_and_empty(TYPING), "a person is typing: never type over them")
        self.assertFalse(self.A.idle_and_empty(WORKING))
        self.assertFalse(self.A.idle_and_empty(DIALOG), "a question on screen is the person's")
        self.assertFalse(self.A.idle_and_empty(""))

    def test_news_waits_for_idle_then_arrives_as_one_line(self) -> None:
        aid = self.arch()
        g = {"id": "g_1", "title": "Website round 3"}
        self.A.queue_event(S, g, kind="gate", summary_text="me opened: critique finished (win)")
        self.A.queue_event(S, g, kind="attention", summary_text="plan on c1.u asks for permission")
        self.A.queue_event(S, {"id": "g_other"}, kind="gate", summary_text="not this architect's graph")
        self.screens["c1.arch"] = WORKING
        self.assertEqual(self.A.pump(S), [])
        self.assertEqual(len(self.A.get(S, aid)["queue"]), 2, "a busy architect keeps its queue")
        self.screens["c1.arch"] = IDLE
        self.assertEqual(self.A.pump(S), [f"{aid}: 2 event(s)"])
        self.assertEqual(len(self.typed), 1)
        line = self.typed[0][1]
        self.assertTrue(line.startswith("[CyberPong] g_1 (Website round 3): gate: me opened"), line)
        self.assertIn("plan on c1.u asks for permission", line)
        self.assertNotIn("not this architect's graph", line)
        self.assertNotIn("\n", line, "an Enter inside the line would send half of it")
        self.assertEqual(self.A.get(S, aid)["queue"], [])
        self.assertEqual(self.A.chat_log(S, aid)[-1]["who"], "cyberpong")

    def test_a_long_queue_says_how_many_more_wait(self) -> None:
        self.arch()
        for i in range(40):
            self.A.queue_event(S, {"id": "g_1"}, kind="refusal", summary_text=f"step {i}: " + "x" * 60)
        self.screens["c1.arch"] = IDLE
        self.A.pump(S)
        line = self.typed[0][1]
        self.assertLessEqual(len(line), self.A.MAX_LINE + 120)
        self.assertIn("more: `pong architect events --id", line)

    def test_a_quiet_step_is_news_once(self) -> None:
        self.arch()
        now = time.time()
        graphs = [{"id": "g_1", "status": "running", "kind": "graph",
                   "nodes": [{"id": "plan", "seat": "c1.u", "status": "running",
                              "live": {"state": "quiet", "changed_at": now - 40 * 60}}]}]
        self.screens["c1.arch"] = IDLE
        self.A.pump(S, graphs)
        self.A.pump(S, graphs)
        self.assertEqual(len(self.typed), 1)
        self.assertIn("plan on c1.u has shown nothing new for 40 min", self.typed[0][1])

    def test_a_graph_attached_from_an_architects_pane_is_its_own(self) -> None:
        old = self.arch(seat="c1.arch", graphs=())
        new = self.arch(seat="c1.arch", graphs=())
        self.assertEqual(self.A.link_by_seat(S, "c1.arch", "g_9"), new, "the newest architect on a reused seat")
        self.assertIn("g_9", self.A.get(S, new)["graphs"])
        self.assertNotIn("g_9", self.A.get(S, old)["graphs"])
        self.assertIsNone(self.A.link_by_seat(S, "c1.b", "g_9"), "a graph step's seat is not an architect")

    def test_a_persons_message_is_one_line_and_logged(self) -> None:
        aid = self.arch()
        self.assertTrue(self.A.send(S, aid, "approve the gate\nbut first check §4"))
        self.assertEqual(self.typed[-1], ("c1.arch", "approve the gate but first check §4"))
        self.assertEqual(self.A.chat_log(S, aid)[-1]["who"], "person")
        with self.assertRaises(self.A.ArchitectError):
            self.A.key(S, aid, "cmd-q")

    def test_a_new_project_gets_a_team_whose_lead_is_the_architect(self) -> None:
        rules = Path(self.tmp.name) / "owner-rules.md"
        rules.write_text("- Never delete anything on a remote.\n")
        orig = self.A.OWNER_RULES
        self.A.OWNER_RULES = rules
        try:
            r = self.A.new("Intake app", str(self.project))
        finally:
            self.A.OWNER_RULES = orig
        self.assertNotEqual(r["session"], S)
        self.assertEqual(r["seat"], "c1")
        from pong.state import load_pairs_db

        # kept resolved (macOS's own temp folder is reached through a link: /var → /private/var)
        self.assertEqual(load_pairs_db()[r["session"]]["project_root"], str(self.project.resolve()))
        a = self.A.get(r["session"], r["id"])
        prompt = Path(a["prompt_path"]).read_text()
        self.assertIn("You are the graph architect for: Intake app", prompt)
        self.assertIn("Never delete anything on a remote", prompt, "the person's rules come first")
        self.assertIn("## 4. Answering a gate", prompt, "the playbook ships with the package")
        self.assertIn("## 1. Before you design: ask", prompt, "the intake comes before any design")
        self.assertIn("run the intake (section 1)", prompt)
        with self.assertRaises(self.A.ArchitectError):
            self.A.new("x", str(self.project / "missing"))

    def test_a_chat_on_a_team_with_earlier_graphs_is_told_what_they_were(self) -> None:
        from pong.work_graph import start as start_graph
        g = start_graph(S, owner="c1", loop="graph", task="round 1 plan",
                        topology={"name": "site-allnight-r1", "start": "w",
                                  "nodes": [{"id": "w", "role": "writer"}, {"id": "end", "role": "end"}],
                                  "edges": [{"from": "w", "to": "end"}]})
        from pong import groups
        orig = groups.ensure_ephemeral_window
        groups.ensure_ephemeral_window = lambda state, worker, **kw: {"note": "stub"}
        try:
            r = self.A.start(S, "the next round", cwd=str(self.project))
        finally:
            groups.ensure_ephemeral_window = orig
        prompt = Path(self.A.get(S, r["id"])["prompt_path"]).read_text()
        self.assertIn("## What this team has done", prompt)
        self.assertIn(f"`{g['id']}` · site-allnight-r1", prompt)
        self.assertIn("notes: `", prompt)
        self.assertIn("prepare from it first", prompt)
        self.assertIn("start the intake", self.A._pointer("t", Path("/x.md")))

    def test_the_new_graph_sheets_request_reaches_the_architect_as_one_line(self) -> None:
        p = self.A._pointer("t", Path("/x.md"), "Compare our three\ncompetitors'   prices")
        self.assertIn("\u00abCompare our three competitors' prices\u00bb", p)
        self.assertIn("ask only what it leaves open", p)
        self.assertNotIn("\n", p)
        self.assertNotIn("request", self.A._pointer("t", Path("/x.md"), "   "))

    def test_a_chat_on_a_team_whose_terminal_is_closed_opens_it_first(self) -> None:
        from pong import groups
        calls: list[tuple] = []
        orig = (groups.isolated_home, groups.session_exists, groups._tmux, groups.ensure_ephemeral_window)
        groups.isolated_home = lambda: False
        groups.session_exists = lambda name: any(c[0] == "new-session" for c in calls)  # closed until opened
        groups._tmux = lambda *a: calls.append(a) or (True, "")
        groups.ensure_ephemeral_window = lambda state, worker, **kw: calls.append(("window", worker.get("seat") or worker.get("id"))) or {"note": "stub"}
        try:
            r = self.A.start(S, "the website rounds", cwd=str(self.project))
        finally:
            groups.isolated_home, groups.session_exists, groups._tmux, groups.ensure_ephemeral_window = orig
        # in the team's project folder, never where the command ran (the app runs from /)
        self.assertEqual(calls[0], ("new-session", "-d", "-s", S, "-n", "lead", "-c", str(self.project)))
        self.assertEqual(calls[1], ("window", r["seat"]), "the session first, then the chat's window in it")

    def test_a_new_chat_opens_its_terminal_in_the_project_folder_and_keeps_it_absolute(self) -> None:
        """A chat made from the app (whose folder is /) starts in the project; "." is kept as a full path."""
        from pong import groups
        calls: list[tuple] = []
        orig = (groups.isolated_home, groups.session_exists, groups._tmux, groups.type_launch)
        groups.isolated_home = lambda: False
        groups.session_exists = lambda name: False
        groups._tmux = lambda *a: calls.append(a) or (True, "%1" if a[:1] == ("display-message",) else "")
        groups.type_launch = lambda target, cmd, **kw: calls.append(("type", target))
        old_tmux, old_cwd = self.A._tmux_path, os.getcwd()
        self.A._tmux_path = lambda: "/usr/bin/true"
        try:
            os.chdir(str(self.project))
            r = self.A.new("Intake app", ".")
        finally:
            os.chdir(old_cwd)
            self.A._tmux_path = old_tmux
            groups.isolated_home, groups.session_exists, groups._tmux, groups.type_launch = orig
        real = str(self.project.resolve())
        opened = next(c for c in calls if c[:1] == ("new-session",))
        self.assertEqual(opened[-2:], ("-c", real))
        from pong.state import load_pairs_db
        self.assertEqual(load_pairs_db()[r["session"]]["project_root"], real)
        self.assertEqual(self.A.get(r["session"], r["id"])["cwd"], real)

    def test_a_team_with_no_project_folder_opens_in_the_home_folder(self) -> None:
        from pong import groups
        self.assertEqual(groups.start_dir({"project_root": str(self.project)}), str(self.project))
        self.assertEqual(groups.start_dir({"project_root": str(self.project / "gone")}), str(Path.home()))
        self.assertEqual(groups.start_dir({}), str(Path.home()))
        # a relative folder kept by an older engine says nothing about where it was (the app runs from /)
        self.assertEqual(groups.start_dir({"project_root": "."}), str(Path.home()))
        self.assertEqual(groups.start_dir_args(None), ["-c", str(Path.home())])
        from pong.paths import resolved_folder
        self.assertEqual(resolved_folder(""), "")
        self.assertTrue(os.path.isabs(resolved_folder("some/where")))

    def test_a_new_chat_never_erases_a_team_that_lived_only_in_the_active_file(self) -> None:
        from pong.jsonutil import write_json
        from pong.paths import active_path
        from pong.state import load_active, load_pairs_db

        legacy = {"session": "legacy-team", "schema_version": 2, "project_root": str(self.project),
                  "conductor": {"id": "c1", "type": "claude", "cmd": "claude", "mode": "tmux", "tmux_index": 0},
                  "workers": [], "team_brief": "the old brief", "updated": 1.0}
        write_json(active_path(), legacy)
        self.assertNotIn("legacy-team", load_pairs_db())
        r = self.A.new("Intake app", str(self.project))
        kept = load_pairs_db()["legacy-team"]
        self.assertEqual((kept["project_root"], kept["team_brief"]), (str(self.project), "the old brief"))
        self.assertEqual(load_active()["session"], r["session"])


class GraphLog(_Home):
    def start(self, topo):
        from pong.work_graph import start
        return start(S, owner="c1", loop="graph", task="ship it", topology=topo)

    def g(self, gid):
        from pong.work_graph import find_graph
        return find_graph(S, gid)

    def claim(self, gid, nid, summary):
        from pong.jobs import record_claim
        from pong.work_graph import tick
        record_claim(S, node(self.g(gid), nid)["job_id"], summary=summary, files=[])
        tick(S)
        return self.g(gid)

    def test_every_step_claim_route_and_gate_answer_is_logged(self) -> None:
        from pong.graph_log import read
        from pong.work_graph import resume

        topo = {"start": "w", "nodes": [{"id": "w", "role": "writer", "task": "draft. {prev_summary}"},
                                        {"id": "me", "role": "human"}, {"id": "end", "role": "end"}],
                "edges": [{"from": "w", "to": "me"}, {"from": "me", "to": "end", "on": "approved"},
                          {"from": "me", "to": "w", "on": "rejected"}]}
        g = self.start(topo)
        long_summary = "PLAN.md: " + "a claim longer than the history keeps. " * 20
        self.claim(g["id"], "w", long_summary)
        os.environ["PONG_SEAT"] = "c1.arch"
        resume(S, g["id"], outcome="rejected", node="me", note="half as long")
        os.environ.pop("PONG_SEAT")
        rows = read(S, g["id"])
        kinds = [r["kind"] for r in rows]
        self.assertIn("dispatch", kinds)
        disp = next(r for r in rows if r["kind"] == "dispatch")
        self.assertEqual((disp["node"], disp["seat"]), ("w", node(g, "w")["seat"]))
        self.assertTrue(disp.get("job_id") and disp.get("prompt_path"))
        claim = next(r for r in rows if r["kind"] == "event" and r.get("node") == "w" and "a claim longer" in str(r.get("summary")))
        self.assertGreater(len(claim["summary"]), 240, "the log keeps the whole summary the history cuts")
        ans = next(r for r in rows if r["kind"] == "gate_answer")
        self.assertEqual((ans["node"], ans["outcome"], ans["note"], ans["by"]), ("me", "rejected", "half as long", "seat c1.arch"))

    def test_a_jev_decision_is_logged_with_its_numbers(self) -> None:
        from pong.graph_engine import _record_jev
        from pong.graph_log import read

        g = self.start({"start": "w", "nodes": [{"id": "w", "role": "writer"}, {"id": "end", "role": "end"}],
                        "edges": [{"from": "w", "to": "end"}]})
        graph = self.g(g["id"])
        _record_jev(graph, node(graph, "w"), {"mode": "grade", "outcome": "fail", "model": "jev-1.13.0", "calls": ["jv_1"],
                                              "lines": [{"id": "sourced", "verdict": "under", "p_meets": 0.08, "text": "x"}]}, "s")
        rec = next(r for r in read(S, g["id"]) if r["kind"] == "jev")
        self.assertEqual((rec["node"], rec["outcome"], rec["calls"]), ("w", "fail", ["jv_1"]))
        # the numbers and the rubric's own question; never the documents Jev read (the record holds none to log)
        self.assertEqual(rec["lines"], [{"id": "sourced", "verdict": "under", "p_meets": 0.08, "text": "x"}])
        self.assertNotIn("documents", rec)

    def test_a_steps_transcript_is_found_whichever_ai_wrote_it(self) -> None:
        from pong.graph_log import find_transcripts

        base = Path(self.tmp.name)
        cwd = "/Users/x/Sam's AI Team/jev"
        jid = "job_20260927_101010_abcdef"
        (base / "claude" / "-Users-x-Sam-s-AI-Team-jev").mkdir(parents=True)
        (base / "claude" / "-Users-x-Sam-s-AI-Team-jev" / "s1.jsonl").write_text(f'{{"text":"Your job is in the file {jid}.prompt.txt"}}')
        (base / "claude" / "-Users-x-Sam-s-AI-Team-jev" / "s2.jsonl").write_text('{"text":"another job"}')
        (base / "grok" / "%2FUsers%2Fx%2FSam%27s%20AI%20Team%2Fjev" / "01abc").mkdir(parents=True)
        (base / "grok" / "%2FUsers%2Fx%2FSam%27s%20AI%20Team%2Fjev" / "01abc" / "chat_history.jsonl").write_text(jid)
        (base / "codex" / "2026" / "09" / "27").mkdir(parents=True)
        (base / "codex" / "2026" / "09" / "27" / "rollout-x.jsonl").write_text(jid)
        (base / "hermes" / "s").mkdir(parents=True)
        (base / "hermes" / "s" / "session.json").write_text(jid)
        old = base / "codex" / "2026" / "09" / "27" / "rollout-old.jsonl"
        old.write_text(jid)
        os.utime(old, (time.time() - 86400, time.time() - 86400))
        env = {"PONG_CLAUDE_PROJECTS": "claude", "PONG_GROK_SESSIONS": "grok", "PONG_CODEX_SESSIONS": "codex",
               "PONG_HERMES_SESSIONS": "hermes"}
        for k, v in env.items():
            os.environ[k] = str(base / v)
        try:
            found = find_transcripts(jid, cwd, since=time.time() - 60)
        finally:
            for k in env:
                os.environ.pop(k, None)
        self.assertEqual(sorted(r["runtime"] for r in found), ["claude", "codex", "grok", "hermes"])
        self.assertFalse(any(r["path"].endswith(("s2.jsonl", "rollout-old.jsonl")) for r in found))


if __name__ == "__main__":
    unittest.main()
