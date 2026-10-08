#!/usr/bin/env python3
"""Jev in graph loops, each rule pinned by a test (no network: canned answers).

- Probabilities become outcomes in code: a rubric line passes when
  P(level >= floor) reaches 0.8 and clearly fails at 0.3 or below; the work
  wins only when every line passes and their shortfalls add up to 0.25 at most;
  a line Jev cannot find in the document fails; a cut document is uncertain; a
  route needs its bar in both option orders; a winner needs a clear lead.
- The key never leaves: a temporary PONG_HOME cannot reach the owner's key file,
  a secret in the state refuses the call, emails and phones are replaced,
  transcripts and client folders are withheld, and so is any file a person
  adds under ``deny`` in jev.json.
- A jev node needs an abstain edge; without a key it abstains at once and the
  work goes to a person.
- A gate gets Jev's advice beside the buttons; the person's answer is logged
  next to it in the ledger.
- A critic that forgets the verdict word is read by Jev, and only taken at 0.9.
"""
from __future__ import annotations

import json
import os
import sys
import tempfile
import time
import unittest
import unittest.mock
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "python"))

S = "pong-team"


def node(g, nid):
    return next(n for n in g["nodes"] if n["id"] == nid)


def score(probs):
    return {"type": "score", "score": 0, "confidence": 0.5, "probabilities": {str(i): p for i, p in enumerate(probs)}}


def choice(probs, pick=None):
    return {"type": "choice", "choice": pick or max(probs, key=probs.get), "confidence": 0.5, "probabilities": probs}


class JevPureTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        os.environ["PONG_HOME"] = self.tmp.name
        os.environ.pop("PONG_JEV_FAKE", None)
        os.environ.pop("TYPESAFE_API_KEY", None)

    def tearDown(self) -> None:
        os.environ.pop("PONG_HOME", None)
        self.tmp.cleanup()

    def test_rubric_lines_get_an_assessable_question_each(self) -> None:
        from pong import jev
        qs, meta = jev.rubric_questions([{"id": "cited", "text": "Every claim cites a source", "floor": 3}, "Numbers have units"])
        self.assertEqual(set(qs), {"cited", "cited_assessable", "line_2", "line_2_assessable"})
        self.assertEqual(qs["cited"]["type"], "score")
        self.assertEqual(len(qs["cited"]["criteria"]), 5)
        self.assertEqual(meta["cited"]["floor"], 3)
        self.assertEqual(jev.validate_questions(qs), [])

    def test_a_line_is_judged_by_probability_mass_in_three_bands(self) -> None:
        from pong import jev
        qs, meta = jev.rubric_questions([{"id": "cited", "text": "cites", "floor": 3}])
        # expected level 2.71 but bimodal: P(>=3) = 0.60 — neither a pass nor a clear fail
        ans = jev.normalise({"cited": score([0.02, 0.21, 0.17, 0.24, 0.36]), "cited_assessable": {"noul": 0.9}}, qs)
        g = jev.grade(ans, qs, meta)
        self.assertEqual(g["outcome"], "uncertain")
        self.assertAlmostEqual(g["lines"][0]["p_meets"], 0.60, places=2)
        self.assertEqual(jev.grade(ans, qs, meta, pass_p=0.5, union=0.5)["outcome"], "win")
        low = jev.normalise({"cited": score([0.3, 0.5, 0.1, 0.05, 0.05]), "cited_assessable": {"noul": 0.9}}, qs)
        g = jev.grade(low, qs, meta)
        self.assertEqual(g["outcome"], "fail")
        self.assertIn("cited", g["summary"])
        self.assertNotIn("0.", g["summary"])  # the builder sees the bar it missed, not the grader's numbers

    def test_many_lines_that_each_barely_pass_are_not_a_pass(self) -> None:
        from pong import jev
        qs, meta = jev.rubric_questions([f"line {i}" for i in range(4)])
        ans = jev.normalise({**{f"line_{i + 1}": score([0, 0.18, 0.4, 0.4, 0.02]) for i in range(4)},
                             **{f"line_{i + 1}_assessable": {"noul": 0.95} for i in range(4)}}, qs)
        g = jev.grade(ans, qs, meta)  # each line P(>= Adequate) 0.82: passes alone, 0.72 of doubt together
        self.assertTrue(all(r["verdict"] == "pass" for r in g["lines"]))
        self.assertEqual(g["outcome"], "uncertain")

    def test_a_line_jev_cannot_find_fails_and_a_cut_document_abstains(self) -> None:
        from pong import jev
        qs, meta = jev.rubric_questions(["The thresholds section names numbers"])
        ans = jev.normalise({"line_1": score([0, 0, 0.1, 0.4, 0.5]), "line_1_assessable": {"noul": 0.2}}, qs)
        self.assertEqual(jev.grade(ans, qs, meta)["outcome"], "fail")
        self.assertEqual(jev.grade(ans, qs, meta, truncated=True)["outcome"], "uncertain")
        self.assertEqual(jev.grade({}, qs, meta)["outcome"], "uncertain")

    def test_a_route_is_taken_only_at_the_take_bar_and_never_as_none(self) -> None:
        from pong import jev
        q = {"route": jev.choice_question("which", {"fast": "a", "slow": "b"})}
        a = jev.normalise({"route": choice({"fast": 0.95, "slow": 0.04, "none": 0.01})}, q)["route"]
        self.assertEqual(jev.decide(a, take=0.9)[0], "route:fast")
        self.assertEqual(jev.decide(a, take=0.97)[0], "abstain")
        n = jev.normalise({"route": choice({"fast": 0.02, "slow": 0.03, "none": 0.95})}, q)["route"]
        self.assertEqual(jev.decide(n, take=0.5)[0], "abstain")
        # asked in two orders, the picks must agree
        b = jev.normalise({"route": choice({"fast": 0.45, "slow": 0.54, "none": 0.01})}, q)["route"]
        self.assertEqual(jev.decide([a, b], take=0.5)[0], "abstain")
        self.assertEqual(jev.decide([a, a], take=0.9)[0], "route:fast")

    def test_options_jev_was_not_offered_are_dropped(self) -> None:
        from pong import jev
        q = {"route": jev.choice_question("which", {"fast": "a", "slow": "b"})}
        a = jev.normalise({"route": choice({"fast": 0.3, "deploy_prod": 0.6, "slow": 0.1})}, q)["route"]
        self.assertNotIn("deploy_prod", a["probabilities"])
        self.assertEqual(a["pick"], "fast")

    def test_a_ranking_averages_both_option_orders(self) -> None:
        from pong import jev
        r = jev.rank([{"probabilities": {"a": 0.7, "b": 0.3, "none": 0.0}, "pick": "a"},
                      {"probabilities": {"a": 0.4, "b": 0.6, "none": 0.0}, "pick": "b"}])
        self.assertEqual(r["winner"], "a")
        self.assertAlmostEqual(r["p"], 0.55)
        self.assertFalse(r["orders_agree"])
        self.assertEqual(r["outcome"], "abstain")  # the orders disagreed: a person picks
        clear = {"probabilities": {"a": 0.8, "b": 0.15, "none": 0.05}, "pick": "a"}
        self.assertEqual(jev.rank([clear, clear])["outcome"], "win")
        close = {"probabilities": {"a": 0.5, "b": 0.45, "none": 0.05}, "pick": "a"}
        self.assertEqual(jev.rank([close, close])["outcome"], "abstain")  # a lead under 0.2
        # a high P(none) is a person's call between the two best, not a silent fail of both
        self.assertEqual(jev.rank([{"probabilities": {"a": 0.1, "b": 0.1, "none": 0.8}, "pick": "none"}])["outcome"], "abstain")

    def test_a_temporary_pong_home_never_reaches_the_real_key_file(self) -> None:
        from pong import jev
        self.assertEqual(jev._key(), "")
        self.assertFalse(jev.can_ask())
        self.assertFalse(jev.status()["available"])
        out = jev.ask({"x": 1}, {"q": {"type": "noul", "instructions": "x?", "criteria": {"true": "y", "false": "n"}}})
        self.assertFalse(out["ok"])
        self.assertIn("no TypeSafe key", out["error"])

    def test_the_guard_refuses_secrets_and_replaces_emails_and_phones(self) -> None:
        from pong import jev
        _s, _c, why = jev.guard({"doc": "token sk-abcdefghijklmnopqrstuvwxyz123456 here"})
        self.assertIn("key or token", why)
        safe, counts, why = jev.guard({"doc": "write to sam@example.com or call (305) 555-0142"})
        self.assertEqual(why, "")
        self.assertEqual(counts, {"email": 1, "phone": 1})
        self.assertNotIn("sam@", json.dumps(safe))

    def test_transcripts_client_folders_and_a_persons_own_private_files_are_withheld(self) -> None:
        from pong import jev
        d = Path(self.tmp.name)
        (d / "design.md").write_text("# Design\nThe thresholds are 0.5, 0.9 and 0.97.\n")
        (d / "PRIVATE-NOTES.md").write_text("private")
        call = "\n".join(f"[00:{i:02d}:10] {'Sam' if i % 2 else 'Client'}: line {i} of the call" for i in range(30))
        (d / "notes-from-call.md").write_text(call)
        (d / "Clients").mkdir()
        (d / "Clients" / "acme.md").write_text("client file")
        files = ["design.md", "PRIVATE-NOTES.md", "notes-from-call.md", "Clients/acme.md"]
        docs, _ = jev.read_documents(files, root=str(d))
        self.assertIn("PRIVATE-NOTES.md", [x["file"] for x in docs], "no one's own file name is built in")
        (d / "jev.json").write_text(json.dumps({"deny": ["*/private-notes.md"]}))
        docs, withheld = jev.read_documents(files, root=str(d))
        self.assertEqual([x["file"] for x in docs], ["design.md"])
        whys = {Path(w["file"]).name: w["why"] for w in withheld}
        self.assertIn("deny", whys["PRIVATE-NOTES.md"], "a pattern added in jev.json is matched case-blind")
        self.assertIn("transcript", whys["notes-from-call.md"])
        self.assertIn("deny", whys["acme.md"])
        self.assertIn("*/private-notes.md", jev.status()["deny"])

    def test_an_answer_that_breaks_the_contract_is_refused_whole(self) -> None:
        from pong import jev
        q = {"route": jev.choice_question("which", {"fast": "a", "slow": "b"})}
        self.assertTrue(jev.validate_answers({"route": choice({"fast": 0.3, "deploy_prod": 0.6, "slow": 0.1})}, q))
        self.assertTrue(jev.validate_answers({"route": choice({"fast": 0.9, "slow": 0.9, "none": 0.0})}, q))
        self.assertEqual(jev.validate_answers({"route": choice({"fast": 0.9, "slow": 0.05, "none": 0.05})}, q), [])
        fake = Path(self.tmp.name) / "fake.json"
        fake.write_text(json.dumps({"answers": {"route": choice({"fast": 0.9, "slow": 0.05, "none": 0.05})}, "model": "jev-2.0.0"}))
        os.environ["PONG_JEV_FAKE"] = str(fake)
        try:
            out = jev.ask({"x": 1}, q)
        finally:
            os.environ.pop("PONG_JEV_FAKE", None)
        self.assertFalse(out["ok"])  # thresholds were tuned on the pinned version
        self.assertIn("not the pinned", out["error"])

    def test_every_call_is_in_the_ledger_without_the_state_text(self) -> None:
        from pong import jev
        fake = Path(self.tmp.name) / "fake.json"
        fake.write_text(json.dumps({"answers": {"q": {"noul": 0.8}}}))
        os.environ["PONG_JEV_FAKE"] = str(fake)
        try:
            out = jev.ask({"secret_plan": "the words that must not be logged"},
                          {"q": {"type": "noul", "instructions": "x?", "criteria": {"true": "y", "false": "n"}}})
        finally:
            os.environ.pop("PONG_JEV_FAKE", None)
        self.assertTrue(out["ok"])
        self.assertEqual(out["answers"]["q"]["p"], 0.8)
        text = jev.ledger_path().read_text()
        self.assertIn(out["id"], text)
        self.assertNotIn("must not be logged", text)


class JevEngineBase(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        os.environ["PONG_HOME"] = self.tmp.name
        os.environ["PONG_RUNTIMES"] = "claude,grok,codex,hermes"
        os.environ["PONG_SESSION"] = S
        os.environ.pop("PONG_SEAT", None)
        os.environ.pop("TYPESAFE_API_KEY", None)
        self.fake = Path(self.tmp.name) / "fake.json"
        from pong.jsonutil import write_json
        from pong.paths import active_path, ensure_layout, pairs_path
        from pong.routing import ensure_session_token

        ensure_layout(S)
        pair = {"schema_version": 2,
                "conductor": {"id": "c1", "type": "grok", "label": "Grok", "cmd": "grok", "mode": "tmux", "tmux_index": 0},
                "workers": [{"id": "w2", "type": "claude", "label": "Lead", "cmd": "claude", "tmux_index": 2, "mission_role": "coder"}],
                "transport_default": "job",
                "flow_graph": {"edges": [{"from": "c1", "to": "w2", "kind": "delegate"}, {"from": "w2", "to": "c1", "kind": "claim"}]}}
        write_json(pairs_path(), {S: pair}); active = dict(pair); active["session"] = S; write_json(active_path(), active)
        ensure_session_token(S)
        self.doc = Path(self.tmp.name) / "design.md"
        self.doc.write_text("# Design\n\n## Thresholds\nPropose at 0.5, do-and-tell at 0.9, do at 0.97.\n")
        # these tests pin routing; whether a question has earned the right to route is tested on its own
        (Path(self.tmp.name) / "jev.json").write_text(json.dumps({"trust": "all"}))

    def tearDown(self) -> None:
        for k in ("PONG_HOME", "PONG_RUNTIMES", "PONG_SESSION", "PONG_TOKEN", "PONG_JEV_FAKE"):
            os.environ.pop(k, None)
        self.tmp.cleanup()

    def canned(self, answers, **kw) -> None:
        self.fake.write_text(json.dumps({"answers": answers, **kw}))
        os.environ["PONG_JEV_FAKE"] = str(self.fake)

    def start(self, topo, task="ship it"):
        from pong.work_graph import start
        return start(S, owner="w2", loop="graph", task=task, topology=topo)

    def g(self, gid):
        from pong.work_graph import find_graph
        return find_graph(S, gid)

    def claim(self, gid, nid, summary, files=None):
        from pong.jobs import record_claim
        from pong.work_graph import tick
        jid = node(self.g(gid), nid)["job_id"]
        record_claim(S, jid, summary=summary, files=files or [])
        tick(S)
        return self.g(gid)

    def settle(self, gid, nid, *, until=("done", "failed"), seconds=15.0):
        """Tick until a jev node's subprocess has answered."""
        from pong.work_graph import tick
        end = time.time() + seconds
        while time.time() < end:
            tick(S)
            g = self.g(gid)
            if str(node(g, nid).get("status")) in until:
                return g
            time.sleep(0.15)
        self.fail(f"{nid} never finished: {node(self.g(gid), nid).get('status')}")

    GRADE = {"start": "write", "nodes": [
        {"id": "write", "role": "writer", "task": "write it"},
        {"id": "grade", "role": "jev", "rubric": [{"id": "thresholds", "text": "Every threshold names a number", "floor": 3}]},
        {"id": "me", "role": "human"}, {"id": "end", "role": "end"}],
        "edges": [{"from": "write", "to": "grade"}, {"from": "grade", "to": "me", "on": "win"},
                  {"from": "grade", "to": "write", "on": "fail"}, {"from": "grade", "to": "me", "on": "abstain"},
                  {"from": "me", "to": "end", "on": "approved"}, {"from": "me", "to": "write", "on": "rejected"}]}



class JevEngineTests(JevEngineBase):
    def test_lint_requires_an_abstain_edge_a_rubric_and_routes(self) -> None:
        from pong.graph_engine import lint
        from pong.work_graph import WorkGraphError
        bad = json.loads(json.dumps(self.GRADE))
        bad["edges"] = [e for e in bad["edges"] if e.get("on") != "abstain"]
        with self.assertRaisesRegex(WorkGraphError, "abstain edge"):
            lint(bad)
        norub = json.loads(json.dumps(self.GRADE))
        del norub["nodes"][1]["rubric"]
        norub["nodes"][1]["ask"] = "grade"
        with self.assertRaisesRegex(WorkGraphError, "rubric"):
            lint(norub)
        dec = json.loads(json.dumps(self.GRADE))
        dec["nodes"][1] = {"id": "grade", "role": "jev", "ask": "decide"}
        with self.assertRaisesRegex(WorkGraphError, "route"):
            lint(dec)
        self.assertEqual(lint(self.GRADE)["nodes"][1]["ask"], "grade")

    def test_without_a_key_a_jev_node_abstains_at_once_and_a_person_decides(self) -> None:
        out = self.start(self.GRADE)
        gid = out["graph"]["id"] if "graph" in out else out["id"]
        g = self.claim(gid, "write", "done — wrote design.md", files=[str(self.doc)])
        self.assertEqual(node(g, "grade")["last_outcome"], "abstain")
        self.assertIn("(No Jev key on this Mac, or Jev is switched off in Settings › Limits & keys); a person decides",
                      node(g, "grade")["jev_result"]["summary"])
        self.assertEqual(node(g, "me")["status"], "waiting_human")

    def test_a_passing_grade_reaches_the_gate_with_its_lines_and_advice(self) -> None:
        self.canned({"thresholds": score([0, 0, 0.05, 0.35, 0.6]), "thresholds_assessable": {"noul": 0.95},
                     "approve": {"noul": 0.8}})
        out = self.start(self.GRADE)
        gid = out["graph"]["id"] if "graph" in out else out["id"]
        self.claim(gid, "write", "done — wrote design.md", files=[str(self.doc)])
        g = self.settle(gid, "grade")
        self.assertEqual(node(g, "grade")["last_outcome"], "win")
        self.assertEqual(node(g, "me")["status"], "waiting_human")
        gate = node(g, "me")["gate"]
        self.assertEqual(gate["prev"]["jev"]["lowest"], "thresholds")
        self.assertEqual(gate["prev"]["artifacts"], [str(self.doc)])  # the work, not Jev's log
        seen = json.loads(self.fake.read_text())["_seen_states"][0]
        self.assertIn("Thresholds", json.dumps(seen))
        self.assertNotIn("account_of_the_work", seen)  # a grader judges the work, not the account
        # advice arrives on a later tick
        from pong.work_graph import tick
        for _ in range(60):
            tick(S)
            adv = (node(self.g(gid), "me").get("gate") or {}).get("advice") or {}
            if not adv.get("pending"):
                break
            time.sleep(0.15)
        self.assertEqual(adv.get("pick"), "approved")
        self.assertIn("approved at this checkpoint", adv.get("question") or "")  # what Jev was asked, for people
        self.assertEqual(set(adv.get("option_text") or {}), {"approved", "rejected"})
        from pong.work_graph import resume
        resume(S, gid, outcome="rejected", note="thresholds need fallbacks")
        from pong import jev
        labels = [r for r in jev.read_ledger() if r.get("kind") == "label"]
        self.assertTrue(any(r["question"] == "answer" and r["actual"] == "rejected" for r in labels))
        self.assertTrue(any(r["question"] == "__outcome__" for r in labels))

    def test_a_failing_grade_sends_the_lines_back_to_the_writer(self) -> None:
        self.canned({"thresholds": score([0.3, 0.5, 0.2, 0, 0]), "thresholds_assessable": {"noul": 0.9}})
        out = self.start(self.GRADE)
        gid = out["graph"]["id"] if "graph" in out else out["id"]
        self.claim(gid, "write", "done — wrote design.md", files=[str(self.doc)])
        g = self.settle(gid, "grade")
        self.assertEqual(node(g, "grade")["last_outcome"], "fail")
        w = node(g, "write")
        self.assertEqual(w["status"], "running")
        self.assertEqual(w["visits"], 2)
        self.assertIn("thresholds", str(w["last_prev"]["summary"]))

    def test_jev_chooses_a_route_only_when_sure_else_a_person_does(self) -> None:
        topo = {"start": "triage", "nodes": [
            {"id": "triage", "role": "scout", "task": "look"},
            {"id": "route", "role": "jev", "ask": "decide", "take": 0.9},
            {"id": "quick", "role": "builder", "task": "small fix"}, {"id": "deep", "role": "builder", "task": "rework"},
            {"id": "me", "role": "human"}, {"id": "end", "role": "end"}],
            "edges": [{"from": "triage", "to": "route"},
                      {"from": "route", "to": "quick", "on": "route:quick", "when": "a one-file fix"},
                      {"from": "route", "to": "deep", "on": "route:deep", "when": "the design is wrong"},
                      {"from": "route", "to": "me", "on": "abstain"},
                      {"from": "me", "to": "quick", "on": "route:quick"}, {"from": "me", "to": "deep", "on": "route:deep"},
                      {"from": "quick", "to": "end"}, {"from": "deep", "to": "end"}]}
        self.canned({"route": choice({"quick": 0.94, "deep": 0.05, "none": 0.01})})
        out = self.start(topo)
        gid = out["graph"]["id"] if "graph" in out else out["id"]
        self.claim(gid, "triage", "done — found a typo", files=[str(self.doc)])
        g = self.settle(gid, "route")
        self.assertEqual(node(g, "route")["last_outcome"], "route:quick")
        self.assertEqual(node(g, "quick")["status"], "running")
        from pong.graph_engine import _jev_view
        view = _jev_view(node(g, "route")["jev_result"])
        self.assertIn("Which way should the loop go next", view["question"])
        self.assertEqual(view["option_text"]["quick"], "a one-file fix")
        self.assertIn("none", view["option_text"])
        self.assertAlmostEqual(view["probabilities"]["deep"], 0.05, places=2)
        # the same graph, a less sure answer: a person picks the route
        self.canned({"route": choice({"quick": 0.6, "deep": 0.35, "none": 0.05}),
                     "answer": choice({"route:quick": 0.6, "route:deep": 0.3, "none": 0.1})})
        out = self.start(topo)
        gid2 = out["graph"]["id"] if "graph" in out else out["id"]
        self.claim(gid2, "triage", "done — found a typo", files=[str(self.doc)])
        g = self.settle(gid2, "route")
        self.assertEqual(node(g, "route")["last_outcome"], "abstain")
        self.assertEqual(node(g, "me")["status"], "waiting_human")
        from pong.graph_engine import gate_options
        self.assertIn("route:deep", gate_options(g, "me"))

    def test_a_ranker_forwards_only_the_winner(self) -> None:
        a = Path(self.tmp.name) / "a.md"
        b = Path(self.tmp.name) / "b.md"
        a.write_text("# Draft A\nshort\n")
        b.write_text("# Draft B\nthorough, cited, complete\n")
        topo = {"start": "draft", "nodes": [
            {"id": "draft", "role": "writer", "count": 2, "task": "draft {copy}"},
            {"id": "gather", "role": "join"}, {"id": "pick", "role": "jev", "ask": "rank"},
            {"id": "me", "role": "human"}, {"id": "end", "role": "end"}],
            "edges": [{"from": "draft", "to": "gather"}, {"from": "gather", "to": "pick"},
                      {"from": "pick", "to": "me", "on": "win"}, {"from": "pick", "to": "me", "on": "abstain"},
                      {"from": "pick", "to": "draft", "on": "fail"}, {"from": "me", "to": "end", "on": "approved"}]}
        self.canned({"best": choice({"draft#1": 0.2, "draft#2": 0.78, "none": 0.02})})
        out = self.start(topo)
        gid = out["graph"]["id"] if "graph" in out else out["id"]
        self.claim(gid, "draft#1", "done — draft A", files=[str(a)])
        self.claim(gid, "draft#2", "done — draft B", files=[str(b)])
        g = self.settle(gid, "pick")
        self.assertEqual(node(g, "pick")["last_outcome"], "win")
        self.assertEqual(node(g, "pick")["jev_result"]["winner"], "draft#2")
        self.assertEqual(node(g, "pick")["jev_result"]["orders"], 2)
        self.assertTrue(node(g, "pick")["jev_result"]["question"])
        self.assertEqual(node(g, "pick")["jev_result"]["option_text"]["draft#2"], "the candidate from draft#2")
        self.assertEqual(node(g, "me")["gate"]["prev"]["artifacts"], [str(b)])

    def test_a_critic_without_the_verdict_word_is_read_by_jev_at_ninety_percent(self) -> None:
        topo = {"start": "build", "nodes": [
            {"id": "build", "role": "builder"}, {"id": "review", "role": "critic"},
            {"id": "me", "role": "human"}, {"id": "end", "role": "end"}],
            "edges": [{"from": "build", "to": "review"}, {"from": "review", "to": "me", "on": "win"},
                      {"from": "review", "to": "build", "on": "fail"}, {"from": "me", "to": "end", "on": "approved"}]}
        self.canned({"verdict": choice({"win": 0.96, "fail": 0.03, "none": 0.01})})
        out = self.start(topo)
        gid = out["graph"]["id"] if "graph" in out else out["id"]
        self.claim(gid, "build", "done — built it")
        self.claim(gid, "review", "Looks solid: tests pass and the brief is met. Ship it.")
        g = self.settle(gid, "review")  # Jev reads the claim in the background
        self.assertEqual(node(g, "review")["last_outcome"], "win")
        self.assertEqual(node(g, "review")["claim_read"]["outcome"], "win")
        self.assertTrue(node(g, "review")["claim_read"]["taken"])
        self.canned({"verdict": choice({"win": 0.7, "fail": 0.25, "none": 0.05})})
        out = self.start(topo)
        gid = out["graph"]["id"] if "graph" in out else out["id"]
        self.claim(gid, "build", "done — built it")
        self.claim(gid, "review", "Mostly fine I think.")
        g = self.settle(gid, "review")
        self.assertEqual(node(g, "review")["last_outcome"], "fail")  # the old rule stands below 0.9
        # people still see what Jev was asked and every option's P, marked as not taken
        cr = node(g, "review")["claim_read"]
        self.assertFalse(cr["taken"])
        self.assertIn("closing message", cr["question"])
        self.assertAlmostEqual(cr["probabilities"]["fail"], 0.25, places=2)

    def test_the_snapshot_shows_lines_lowest_first(self) -> None:
        self.canned({"thresholds": score([0, 0, 0.05, 0.35, 0.6]), "thresholds_assessable": {"noul": 0.95},
                     "answer": choice({"approved": 0.8, "rejected": 0.15, "none": 0.05})})
        out = self.start(self.GRADE)
        gid = out["graph"]["id"] if "graph" in out else out["id"]
        self.claim(gid, "write", "done", files=[str(self.doc)])
        self.settle(gid, "grade")
        from pong.work_graph import snapshot_block
        blk = snapshot_block(S, full=True)
        g = next(x for x in blk["graphs"] if x["id"] == gid)
        n = next(x for x in g["nodes"] if x["id"] == "grade")
        self.assertEqual(n["ask"], "grade")
        self.assertEqual(n["jev"]["lines"][0]["id"], "thresholds")
        self.assertEqual(g["gates"][0]["jev"]["lowest"], "thresholds")
        line = n["jev"]["lines"][0]
        self.assertEqual(len(line["level_names"]), 5)
        self.assertAlmostEqual(sum(float(v) for v in line["probabilities"].values()), 1.0, places=2)
        self.assertIn("threshold", line["text"].lower())


class JevBesideCriticTests(JevEngineBase):
    TOPO = {"start": "build", "nodes": [
        {"id": "build", "role": "builder", "task": "build it"},
        {"id": "review", "role": "critic", "jev": {"rubric": [{"id": "thresholds", "text": "Every threshold names a number", "floor": 3}]}},
        {"id": "me", "role": "human"}, {"id": "end", "role": "end"}],
        "edges": [{"from": "build", "to": "review"}, {"from": "review", "to": "me", "on": "win"},
                  {"from": "review", "to": "build", "on": "fail"}, {"from": "me", "to": "end", "on": "approved"}]}

    def run_review(self, answers, verdict, topo=None):
        self.canned(answers)
        out = self.start(topo or self.TOPO)
        gid = out["graph"]["id"] if "graph" in out else out["id"]
        self.claim(gid, "build", "done — built", files=[str(self.doc)])
        from pong.jobs import load_job, record_claim
        from pong.work_graph import tick
        jid = node(self.g(gid), "review")["job_id"]
        job = load_job(S, jid)
        self.assertIn("Grade against these rubric lines", str(job.get("task") or ""))  # the critic's bar
        self.assertNotIn("0.", str(job.get("task") or "").split("Grade against these rubric lines")[-1])
        record_claim(S, jid, summary=verdict, files=[])
        for _ in range(80):
            tick(S)
            if node(self.g(gid), "review")["status"] in ("done", "failed"):
                break
            time.sleep(0.1)
        return gid, self.g(gid)

    def test_jev_sends_back_a_clear_failure_even_when_the_critic_says_win(self) -> None:
        gid, g = self.run_review({"thresholds": score([0.4, 0.5, 0.1, 0, 0]), "thresholds_assessable": {"noul": 0.9}},
                                 "win — looks good")
        r = node(g, "review")
        self.assertEqual(r["last_outcome"], "fail")
        self.assertEqual(r["jev_result"]["critic"], "win")
        self.assertEqual(r["jev_result"]["jev_verdict"], "fail")
        b = node(g, "build")
        self.assertEqual(b["visits"], 2)
        self.assertIn("independent grade", b["last_prev"]["summary"])
        self.assertIn("thresholds", b["last_prev"]["summary"])

    def test_a_win_needs_the_critic_too(self) -> None:
        gid, g = self.run_review({"thresholds": score([0, 0, 0, 0.1, 0.9]), "thresholds_assessable": {"noul": 0.95}},
                                 "fail — the brief is not met")
        self.assertEqual(node(g, "review")["last_outcome"], "fail")
        gid, g = self.run_review({"thresholds": score([0, 0, 0, 0.1, 0.9]), "thresholds_assessable": {"noul": 0.95}},
                                 "win — meets the brief")
        self.assertEqual(node(g, "review")["last_outcome"], "win")
        self.assertEqual(node(g, "me")["gate"]["prev"]["jev"]["combined"], "win")

    def test_when_jev_is_unsure_the_critic_decides(self) -> None:
        gid, g = self.run_review({"thresholds": score([0, 0.1, 0.4, 0.3, 0.2]), "thresholds_assessable": {"noul": 0.9}},
                                 "win — fine")
        self.assertEqual(node(g, "review")["last_outcome"], "win")
        self.assertEqual(node(g, "review")["jev_result"]["jev_verdict"], "uncertain")

    def test_shadow_mode_only_records(self) -> None:
        topo = json.loads(json.dumps(self.TOPO))
        topo["nodes"][1]["jev"]["mode"] = "shadow"
        gid, g = self.run_review({"thresholds": score([0.4, 0.5, 0.1, 0, 0]), "thresholds_assessable": {"noul": 0.9}},
                                 "win — looks good", topo=topo)
        self.assertEqual(node(g, "review")["last_outcome"], "win")
        self.assertEqual(node(g, "review")["jev_result"]["jev_verdict"], "fail")

    def test_the_same_lines_failing_twice_is_no_progress(self) -> None:
        answers = {"thresholds": score([0.4, 0.5, 0.1, 0, 0]), "thresholds_assessable": {"noul": 0.9}}
        gid, g = self.run_review(answers, "win — looks good")
        self.assertEqual(node(g, "build")["visits"], 2)
        from pong.jobs import record_claim
        from pong.work_graph import tick
        record_claim(S, node(g, "build")["job_id"], summary="done — built again", files=[str(self.doc)])
        tick(S)
        g = self.g(gid)
        record_claim(S, node(g, "review")["job_id"], summary="win — better now", files=[])
        for _ in range(80):
            tick(S)
            if self.g(gid)["status"] != "running":
                break
            time.sleep(0.1)
        g = self.g(gid)
        self.assertEqual(g["stop_reason"], "failed_bounded:no_progress")


    def test_a_persons_reject_starts_the_no_progress_count_over(self) -> None:
        """'Failed twice in a row' counts within one pass: after a person's reject the
        loop gets its rounds back instead of returning to the gate after one fail."""
        from pong.jobs import record_claim
        from pong.work_graph import resume, tick
        topo = json.loads(json.dumps(self.TOPO))
        topo["edges"] += [{"from": "review", "to": "me", "on": "bounded"}, {"from": "me", "to": "build", "on": "rejected"}]
        answers = {"thresholds": score([0.4, 0.5, 0.1, 0, 0]), "thresholds_assessable": {"noul": 0.9}}
        gid, g = self.run_review(answers, "win — looks good", topo=topo)       # Jev fails the line: back to build

        def round_trip(summary):
            g = self.g(gid)
            record_claim(S, node(g, "build")["job_id"], summary="done — built again", files=[str(self.doc)])
            tick(S)
            record_claim(S, node(self.g(gid), "review")["job_id"], summary=summary, files=[])
            for _ in range(80):
                tick(S)
                if node(self.g(gid), "review")["status"] in ("done", "failed"):
                    break
                time.sleep(0.1)
            return self.g(gid)

        g = round_trip("win — better now")                                     # the same line again: no progress
        self.assertEqual(node(g, "me")["status"], "waiting_human")
        resume(S, gid, outcome="rejected", note="try the thresholds again")
        g = round_trip("win — fixed")                                          # one fail after the reject
        self.assertEqual(node(g, "build")["status"], "running", "a fresh pass gets its rounds back")
        self.assertNotEqual(node(g, "me")["status"], "waiting_human")


class JevRulesTests(JevEngineBase):
    def test_a_client_facing_graph_is_never_sent_to_jev(self) -> None:
        self.canned({"thresholds": score([0, 0, 0.05, 0.35, 0.6]), "thresholds_assessable": {"noul": 0.95}})
        from pong.work_graph import start
        out = start(S, owner="w2", loop="graph", task="a client report", topology=self.GRADE,
                    boundaries={"client_facing": True})
        gid = out["graph"]["id"] if "graph" in out else out["id"]
        g = self.claim(gid, "write", "done", files=[str(self.doc)])
        self.assertEqual(node(g, "grade")["last_outcome"], "abstain")
        self.assertIn("goes to a client", node(g, "grade")["jev_result"]["error"])
        self.assertFalse(json.loads(self.fake.read_text()).get("_seen_states"))

    def test_a_rubric_the_work_edited_fails_it(self) -> None:
        rub = Path(self.tmp.name) / "rubric.json"
        rub.write_text(json.dumps([{"id": "thresholds", "text": "Every threshold names a number"}]))
        topo = json.loads(json.dumps(self.GRADE))
        topo["nodes"][1]["rubric"] = str(rub)
        self.canned({"thresholds": score([0, 0, 0.05, 0.35, 0.6]), "thresholds_assessable": {"noul": 0.95}})
        out = self.start(topo)
        gid = out["graph"]["id"] if "graph" in out else out["id"]
        rub.write_text(json.dumps([{"id": "thresholds", "text": "Anything goes"}]))
        g = self.claim(gid, "write", "done", files=[str(self.doc)])
        self.assertEqual(node(g, "grade")["last_outcome"], "fail")
        self.assertIn("rubric", node(g, "grade")["jev_result"]["summary"])

    def test_one_gate_in_five_hides_the_advice_until_answered(self) -> None:
        from pong.graph_engine import _advice_view, _blind
        blind = sum(1 for i in range(200) if _blind({"id": f"g_{i}"}, "me", 1))
        self.assertTrue(20 <= blind <= 60, blind)
        # hidden: the pick and its odds; shown: the question (it does not lean either way)
        view = _advice_view({"blind": True, "pick": "approved", "p": 0.9, "probabilities": {"approved": 0.9},
                             "question": "Should it be approved?"})
        self.assertEqual(view, {"blind": True, "pending": None, "error": None, "question": "Should it be approved?"})

    def test_a_failed_candidate_is_not_ranked_and_the_other_goes_on(self) -> None:
        a = Path(self.tmp.name) / "a.md"
        a.write_text("# Draft A\n")
        topo = {"start": "draft", "nodes": [
            {"id": "draft", "role": "critic", "count": 2, "task": "draft {copy}"},
            {"id": "gather", "role": "join"}, {"id": "pick", "role": "jev", "ask": "rank"},
            {"id": "me", "role": "human"}, {"id": "end", "role": "end"}],
            "edges": [{"from": "draft", "to": "gather", "on": "*"}, {"from": "gather", "to": "pick", "on": "*"},
                      {"from": "pick", "to": "me", "on": "win"}, {"from": "pick", "to": "me", "on": "abstain"},
                      {"from": "pick", "to": "me", "on": "fail"}, {"from": "me", "to": "end", "on": "approved"}]}
        self.canned({})
        out = self.start(topo)
        gid = out["graph"]["id"] if "graph" in out else out["id"]
        self.claim(gid, "draft#1", "win — A", files=[str(a)])
        g = self.claim(gid, "draft#2", "fail — B broke", files=[])
        g = self.settle(gid, "pick")
        self.assertEqual(node(g, "pick")["last_outcome"], "win")
        self.assertEqual(node(g, "pick")["jev_result"]["winner"], "draft#1")
        self.assertFalse(json.loads(self.fake.read_text()).get("_seen_states"))  # nothing to compare: not asked

    def test_jev_calls_are_counted_apart_from_jobs(self) -> None:
        self.canned({"thresholds": score([0, 0, 0.05, 0.35, 0.6]), "thresholds_assessable": {"noul": 0.95},
                     "approve": {"noul": 0.7}})
        out = self.start(self.GRADE)
        gid = out["graph"]["id"] if "graph" in out else out["id"]
        self.claim(gid, "write", "done", files=[str(self.doc)])
        g = self.settle(gid, "grade")
        self.assertEqual(g["dispatches"], 1)
        self.assertGreaterEqual(g["jev_calls"], 1)


class JevInterviewTests(unittest.TestCase):
    def test_a_critic_stage_gets_jev_beside_it_and_the_topology_lints(self) -> None:
        from pong.composer import parse_stages
        from pong.graph_engine import lint
        t = parse_stages("draft <-> review -> me", kind="writing", done_text="a one-page brief a client could sign")
        review = next(n for n in t["nodes"] if n["id"] == "review")
        self.assertEqual(review["jev"]["mode"], "both")
        self.assertEqual(review["jev"]["rubric"][0], "@document")
        self.assertIn("one-page brief", review["jev"]["rubric"][1]["text"])
        lint(t)
        code = parse_stages("build -> review -> me", kind="code")
        self.assertTrue(next(n for n in code["nodes"] if n["id"] == "review")["jev"]["diff"])
        self.assertNotIn("jev", next(n for n in parse_stages("draft -> review -> me", jev=False)["nodes"] if n["id"] == "review"))

    def test_jev_stages_grade_or_pick_a_route_and_unsure_goes_to_the_person(self) -> None:
        from pong.composer import parse_stages
        from pong.graph_engine import lint
        t = parse_stages("draft -> jev -> me", kind="writing")
        j = next(n for n in t["nodes"] if n["id"] == "jev")
        self.assertEqual((j["role"], j["ask"]), ("jev", "grade"))
        ons = {(e["on"], e["to"]) for e in t["edges"] if e["from"] == "jev"}
        self.assertIn(("abstain", "me"), ons)
        self.assertIn(("fail", "draft"), ons)
        lint(t)
        d = parse_stages("look -> jev-decide -> quick -> rework -> me", kind="code")
        routes = {e["on"] for e in d["edges"] if e["from"] == "jev-decide"}
        self.assertEqual(routes, {"route:quick", "route:rework", "abstain"})
        lint(d)

    def test_every_shipped_template_and_rubric_is_valid(self) -> None:
        from pong import jev
        from pong.graph_engine import lint
        base = ROOT / "python" / "pong" / "loops"
        for f in sorted((base / "rubrics").glob("*.json")):
            if f.name.endswith((".probes.json", ".status.json")):
                continue
            qs, _m = jev.rubric_questions(json.loads(f.read_text()))
            self.assertEqual(jev.validate_questions(qs), [], f.name)
        for f in sorted((base / "graphs").glob("*.json")):
            lint(json.loads(f.read_text()))


class JevReviewFixTests(JevEngineBase):
    """Each test pins one finding of the adversarial review (2026-09-24)."""

    def git(self, root, *args):
        import subprocess
        return subprocess.run(["git", "-C", str(root), *args], capture_output=True, text=True, check=True)

    def test_the_diff_withholds_private_paths_with_spaces_accents_renames_and_committed_transcripts(self) -> None:
        from pong.graph_engine import _git_base, _git_change
        repo = Path(self.tmp.name) / "repo"
        (repo / "Clients" / "Acme Corp").mkdir(parents=True)
        (repo / "Clients" / "Café Nord").mkdir(parents=True)
        (repo / "Clients" / "Beta").mkdir(parents=True)
        (repo / "Clients" / "Acme Corp" / "notes.md").write_text("start\n")
        (repo / "Clients" / "Café Nord" / "notes.md").write_text("start\n")
        (repo / "Clients" / "Beta" / "notes.md").write_text("PRIVATE beta moved\n")
        (repo / "call-notes.md").write_text("draft\n")
        (repo / "app.py").write_text("x = 1\n")
        self.git(repo, "init", "-q"); self.git(repo, "-c", "user.email=t@t", "-c", "user.name=t", "add", "-A")
        self.git(repo, "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "base")
        base = _git_base(str(repo))
        (repo / "Clients" / "Acme Corp" / "notes.md").write_text("PRIVATE client detail acme\n")
        (repo / "Clients" / "Café Nord" / "notes.md").write_text("PRIVATE client detail cafe\n")
        self.git(repo, "mv", "Clients/Beta/notes.md", "beta-notes.md")
        call = "\n".join(f"[00:{i:02d}:10] **{'Sam' if i % 2 else 'Client'}:** line {i} of the call" for i in range(30))
        (repo / "call-notes.md").write_text(call)
        self.git(repo, "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qam", "work")
        (repo / "app.py").write_text("x = 2\n")
        text, withheld = _git_change(str(repo), base, [])
        self.assertIn("x = 2", text)
        for secret in ("PRIVATE", "line 3 of the call"):
            self.assertNotIn(secret, text)
        whys = " ".join(w["why"] for w in withheld)
        self.assertIn("deny", whys)
        self.assertIn("transcript", whys)

    def test_a_file_named_like_a_pattern_does_not_pull_denied_files_into_its_diff(self) -> None:
        from pong.graph_engine import _git_base, _git_change
        repo = Path(self.tmp.name) / "globrepo"
        (repo / "Clients" / "Acme Corp").mkdir(parents=True)
        (repo / "Clients" / "Acme Corp" / "notes.md").write_text("start\n")
        (repo / "*.md").write_text("a file literally named star-dot-md\n")
        self.git(repo, "init", "-q"); self.git(repo, "-c", "user.email=t@t", "-c", "user.name=t", "add", "-A")
        self.git(repo, "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "base")
        base = _git_base(str(repo))
        (repo / "Clients" / "Acme Corp" / "notes.md").write_text("PRIVATE acme renewal\n")
        (repo / "*.md").write_text("changed\n")
        text, withheld = _git_change(str(repo), base, [])
        self.assertIn("changed", text)
        self.assertNotIn("PRIVATE", text)

    def test_a_slow_listing_keeps_the_diff_and_an_unreadable_change_goes_to_a_person(self) -> None:
        import subprocess as _sp
        from unittest.mock import patch
        from pong import graph_engine as ge
        repo = Path(self.tmp.name) / "slowrepo"
        repo.mkdir()
        (repo / "app.py").write_text("x = 1\n")
        self.git(repo, "init", "-q"); self.git(repo, "-c", "user.email=t@t", "-c", "user.name=t", "add", "-A")
        self.git(repo, "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "base")
        base = ge._git_base(str(repo))
        (repo / "app.py").write_text("x = 2\n")
        real = ge._git

        def slow_ls(root, *args, **kw):
            if args and args[0] == "ls-files":
                raise _sp.TimeoutExpired(["git"], 10)
            return real(root, *args, **kw)
        with patch.object(ge, "_git", side_effect=slow_ls):
            text, withheld = ge._git_change(str(repo), base, [])
        self.assertIn("x = 2", text, "a slow listing of new files does not throw away the diff")
        self.assertTrue(any("could not be listed" in w["why"] for w in withheld))
        self.canned({"thresholds": score([0, 0, 0, 0.1, 0.9]), "thresholds_assessable": {"noul": 0.95}})
        topo = json.loads(json.dumps(self.GRADE))
        topo["nodes"][1]["diff"] = True
        with patch.object(ge, "_git_change", return_value=("", [{"file": "git diff since abcdef12", "why": "could not be read (git exit 128)"}])):
            out = self.start(topo)
            gid = out["graph"]["id"] if "graph" in out else out["id"]
            self.claim(gid, "write", "done", files=[str(self.doc)])
            g = self.settle(gid, "grade")
        self.assertEqual(node(g, "grade")["last_outcome"], "abstain", "without the change, a person decides")
        self.assertEqual(node(g, "me")["status"], "waiting_human")

    def test_git_reads_are_bounded(self) -> None:
        from pong.graph_engine import _git_prefix
        repo = Path(self.tmp.name) / "bigrepo"
        repo.mkdir()
        (repo / "big.txt").write_text("y" * 3_000_000)
        self.git(repo, "init", "-q"); self.git(repo, "-c", "user.email=t@t", "-c", "user.name=t", "add", "-A")
        self.git(repo, "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "base")
        rc, out, cut = _git_prefix(str(repo), "show", "HEAD:big.txt", limit=400_000)
        self.assertEqual((rc, len(out), cut), (0, 400_000, True))

    def test_withheld_files_are_counted_not_named_and_cannot_fail_the_work_alone(self) -> None:
        d = Path(self.tmp.name) / "Clients" / "Acme Corp"
        d.mkdir(parents=True)
        secret = d / "Acme renewal at 48k for Jane Roe.md"
        secret.write_text("private")
        self.canned({"thresholds": score([0.5, 0.4, 0.1, 0, 0]), "thresholds_assessable": {"noul": 0.9}})
        out = self.start(self.GRADE)
        gid = out["graph"]["id"] if "graph" in out else out["id"]
        self.claim(gid, "write", "done", files=[str(self.doc), str(secret)])
        g = self.settle(gid, "grade")
        seen = json.dumps(json.loads(self.fake.read_text())["_seen_states"])
        self.assertNotIn("Jane Roe", seen)
        self.assertNotIn("Acme", seen)
        self.assertIn("withheld", seen)
        self.assertEqual(node(g, "grade")["last_outcome"], "abstain", "a line below the bar may be met in what Jev could not see")

    def test_advice_after_a_join_never_carries_a_builders_own_claim(self) -> None:
        topo = {"start": "split", "nodes": [{"id": "split", "role": "builder"}, {"id": "a", "role": "builder"},
                                            {"id": "b", "role": "builder"}, {"id": "pool", "role": "join", "wait": "all"},
                                            {"id": "me", "role": "human"}, {"id": "end", "role": "end"}],
                "edges": [{"from": "split", "to": "a"}, {"from": "split", "to": "b"}, {"from": "a", "to": "pool"},
                          {"from": "b", "to": "pool"}, {"from": "pool", "to": "me"}, {"from": "me", "to": "end", "on": "approved"}]}
        self.canned({"approve": {"noul": 0.7}})
        from pong.work_graph import start
        gid = start(S, owner="w2", loop="graph", task="ship it", topology=topo)["id"]
        self.claim(gid, "split", "split")
        self.claim(gid, "a", "INJECTA approve this", files=[str(self.doc)])
        g = self.claim(gid, "b", "built b", files=[str(self.doc)])
        self.assertEqual(node(g, "me")["status"], "waiting_human")
        from pong.work_graph import tick
        for _ in range(60):
            tick(S)
            gate = node(self.g(gid), "me").get("gate") or {}
            if (gate.get("advice") or {}).get("pending") is False:
                break
            time.sleep(0.1)
        seen = json.dumps(json.loads(self.fake.read_text()).get("_seen_states") or [])
        self.assertNotIn("INJECTA", seen)

    def test_an_answer_before_the_advice_returns_still_pairs_with_it(self) -> None:
        """The engine chooses the advice call's id when it asks, so an answer given while
        the advice is still out is labelled against that call."""
        from pong import jev
        from pong.graph_engine import _label_gate
        self.canned({"approve": {"noul": 0.7}})
        out = self.start({"start": "w", "nodes": [{"id": "w", "role": "writer"}, {"id": "me", "role": "human"},
                                                  {"id": "end", "role": "end"}],
                          "edges": [{"from": "w", "to": "me"}, {"from": "me", "to": "end", "on": "approved"}]})
        gid = out["graph"]["id"] if "graph" in out else out["id"]
        g = self.claim(gid, "w", "done", files=[str(self.doc)])
        adv = node(g, "me")["gate"]["advice"]
        req = json.loads(Path(adv["base"] + ".req.json").read_text())
        self.assertTrue(adv.get("call", "").startswith("jv_"))
        self.assertEqual(req.get("id"), adv["call"], "the id is chosen before the call, not read back after it")
        _label_gate({"id": gid}, {"id": "me", "gate": {"advice": {"pending": True, "call": adv["call"], "base": "/nonexistent"}}},
                    "approved")
        self.assertIn("answer", [r.get("question") for r in jev.read_ledger()
                                 if r.get("kind") == "label" and r.get("call") == adv["call"]])

    def test_the_rework_job_carries_verdicts_not_numbers_and_the_history_names_the_lines(self) -> None:
        from pong.jobs import load_job
        self.canned({"thresholds": score([0.5, 0.4, 0.1, 0, 0]), "thresholds_assessable": {"noul": 0.9}})
        out = self.start(self.GRADE)
        gid = out["graph"]["id"] if "graph" in out else out["id"]
        self.claim(gid, "write", "done", files=[str(self.doc)])
        g = self.settle(gid, "grade")
        job = load_job(S, node(g, "write")["job_id"])
        raw = json.dumps(job)
        for k in ("p_meets", "probabilities", "p_union", "p_pass"):
            self.assertNotIn(k, raw, k)
        # the failing line is named in Recent steps, by what it asks (never its id or numbers)
        self.assertIn("below the bar on: Every threshold names a number", json.dumps(job.get("graph_history") or []))

    def test_a_check_that_passes_then_fails_once_is_not_no_progress(self) -> None:
        """A pass and a later fail with the same output (a protected file changed under
        `true`) are not 'the same failure twice'."""
        import time as _t
        from pong.work_graph import tick
        root = Path(self.tmp.name) / "chk"
        root.mkdir()
        guarded = root / "features.json"
        guarded.write_text("[]")
        topo = {"start": "b", "max_rounds": 6, "protect": [str(guarded)],
                "nodes": [{"id": "b", "role": "builder"}, {"id": "t", "role": "check", "cwd": str(root), "run": ["true"]}],
                "edges": [{"from": "b", "to": "t"}, {"from": "t", "to": "b", "on": "fail"}, {"from": "t", "to": "b", "on": "win"}]}
        from pong.work_graph import start
        gid = start(S, owner="w2", loop="graph", task="t", topology=topo)["id"]

        def run_check():
            for _ in range(80):
                tick(S)
                if node(self.g(gid), "t")["status"] in ("done", "failed"):
                    return self.g(gid)
                _t.sleep(0.05)
            return self.g(gid)
        self.claim(gid, "b", "built")
        g = run_check()
        self.assertEqual(node(g, "t")["last_outcome"], "win")
        guarded.write_text('[{"id": 1}]')         # the one fail: the protected file changed
        self.claim(gid, "b", "built again")
        g = run_check()
        self.assertEqual(node(g, "t")["last_outcome"], "fail")
        self.assertNotEqual(g.get("stop_reason"), "failed_bounded:no_progress")
        self.assertEqual(node(g, "b")["status"], "running", "a first fail after a pass goes back on the fail edge")

    def test_bytecode_does_not_change_a_protected_folder(self) -> None:
        from pong.graph_engine import _hash_path
        t = Path(self.tmp.name) / "tests"
        t.mkdir()
        (t / "test_x.py").write_text("def test(): pass\n")
        h = _hash_path(str(t))
        (t / "__pycache__").mkdir()
        (t / "__pycache__" / "test_x.cpython-312.pyc").write_bytes(b"\x00bytecode")
        self.assertEqual(_hash_path(str(t)), h)
        (t / "conftest.py").write_text("x = 1\n")
        self.assertNotEqual(_hash_path(str(t)), h)

    def test_the_inspector_keeps_the_graders_weakest_first_order(self) -> None:
        from pong import jev
        from pong.graph_engine import _jev_view
        lines = [{"id": f"l{i}", "type": "noul", "text": f"Line {i} holds."} for i in range(6)]
        qs, meta = jev.rubric_questions(lines)
        ans = {**{f"l{i}": {"noul": 0.85} for i in range(5)}, "l5": {"noul": 0.95}}
        g = jev.grade(jev.normalise(ans, qs), qs, meta)
        weakest = g["lines"][0]["id"]
        self.assertEqual(_jev_view({"lines": g["lines"]})["lines"][0]["id"], weakest)

    def test_decide_calls_are_scored_and_a_calibrated_tie_has_no_error(self) -> None:
        from pong import jev
        recs = [{"kind": "call", "id": "jv_aaaaaaaaaaaa", "purpose": "decide", "qset": "q", "model": "m",
                 "answers": {"route": {"probabilities": {"quick": 0.6, "deep": 0.35, "none": 0.05}}}},
                {"kind": "label", "call": "jv_aaaaaaaaaaaa", "question": "__outcome__", "actual": "route:deep"}]
        cal = jev.calibration(recs)
        self.assertEqual(cal["decide"]["n"], 1)
        self.assertAlmostEqual(cal["decide"]["brier"], 0.36 + 0.4225 + 0.0025, places=4)
        self.assertEqual(jev._ece([(0.9, 1)] * 36 + [(0.9, 0)] * 4), 0.0)

    def test_rank_needs_a_peaked_choice_not_only_a_lead(self) -> None:
        from pong import jev
        spread = {"probabilities": {"x": 0.55, "y": 0.30, "none": 0.15}, "pick": "x"}   # a 0.25 lead, but not peaked
        self.assertEqual(jev.rank([spread, spread])["outcome"], "abstain")
        clear = {"probabilities": {"x": 0.8, "y": 0.15, "none": 0.05}, "pick": "x"}
        self.assertEqual(jev.rank([clear, clear])["outcome"], "win")

    def test_a_relative_home_still_gets_its_answer(self) -> None:
        from pong.graph_engine import _spawn_jev
        cwd = os.getcwd()
        work = Path(self.tmp.name) / "cwd"
        work.mkdir()
        os.chdir(work)
        try:
            self.canned({"q": {"noul": 0.9}})
            base = Path("relhome") / "runs" / "n-v1"
            base.parent.mkdir(parents=True)
            proc = _spawn_jev(base, {"state": {"goal": "x"}, "questions": {"q": {"type": "noul", "instructions": "It holds.",
                              "criteria": {"true": "yes", "false": "no"}}}})
            proc.wait(timeout=30)
            self.assertTrue((work / "relhome" / "runs" / "n-v1.out.json").exists())
        finally:
            os.chdir(cwd)

    def test_a_repository_with_no_commit_diffs_against_the_empty_tree(self) -> None:
        from pong.graph_engine import _EMPTY_TREE, _git_base
        repo = Path(self.tmp.name) / "fresh"
        repo.mkdir()
        self.git(repo, "init", "-q")
        self.assertEqual(_git_base(str(repo)), _EMPTY_TREE)
        self.assertEqual(_git_base(self.tmp.name), "")  # not a repository: no diff at all

    def test_notetaker_transcripts_are_found_in_files_and_redacted_in_any_text(self) -> None:
        from pong import jev
        timed = "\n".join(f"[00:{i:02d}:12] **{'Sam' if i % 2 else 'Alex Lee'}:** point {i}" for i in range(30))
        untimed = "\n".join(f"**{'Sam' if i % 2 else 'Client'}:** point {i}" for i in range(30))
        appendix = "\n".join(f"- review bullet {i}" for i in range(260)) + "\n" + timed
        for t in (timed, untimed, appendix):
            self.assertTrue(jev.looks_like_transcript(t))
        brief = "# Brief\nGoal: grow the list\nAudience: locals\nIdeas: three\nMeasure: opens\n" * 3
        self.assertFalse(jev.looks_like_transcript(brief))
        safe, counts, why = jev.guard({"closing_message": "win — see below\n" + timed})
        self.assertEqual(why, "")
        self.assertNotIn("point 3", json.dumps(safe))
        self.assertGreater(counts.get("transcript_lines", 0), 20)
        # some notetakers write a line per sentence: turns of several lines, few switches per line
        long_turns = "\n\n".join(f"**{'Sam' if i % 2 == 0 else 'Client'}:** sentence {j} of turn {i}"
                                   for i in range(10) for j in range(4))
        self.assertTrue(jev.looks_like_transcript(long_turns))
        lower = "\n".join(f"[00:{10 + i:02d}:05] **{'sam' if i % 2 == 0 else 'client'}:** line {i}" for i in range(12))
        self.assertTrue(jev.looks_like_transcript(lower))
        # a short quoted stretch of a call, inside prose, is redacted too
        prose = "\n".join(f"Ordinary prose line {i} about the plan." for i in range(12))
        quote = "\n".join(f"[00:1{i}:10] Sam: quote line {i}" for i in range(3))
        safe, counts, _ = jev.guard({"closing_message": prose + "\n" + quote + "\n" + prose})
        self.assertNotIn("quote line", json.dumps(safe))
        self.assertGreaterEqual(counts.get("transcript_lines", 0), 3)
        table = "\n".join(["| Before | After | Why |", "|---|---|---|"] + [f"| old {i} | new {i} | reason {i} |" for i in range(30)])
        self.assertFalse(jev.looks_like_transcript(table))

    def test_the_deny_list_follows_links_and_ignores_letter_case(self) -> None:
        from pong import jev
        d = Path(self.tmp.name)
        cfg = json.loads((d / "jev.json").read_text())
        cfg["deny"] = ["*/persona.md"]
        (d / "jev.json").write_text(json.dumps(cfg))
        (d / "Northwind" / "Clients" / "acme").mkdir(parents=True)
        (d / "Northwind" / "Clients" / "acme" / "plan.md").write_text("private")
        os.symlink(d / "Northwind" / "Clients" / "acme" / "plan.md", d / "harmless.md")
        (d / "PERSONA.md").write_text("x")
        os.symlink(d / "PERSONA.md", d / "about.md")
        (d / ".env.local").write_text("X=1")
        (d / "src" / "clients").mkdir(parents=True)
        (d / "src" / "clients" / "crm.ts").write_text("export const a = 1")
        self.assertIn("link", jev.denied(str(d / "harmless.md")))
        self.assertTrue(jev.denied(str(d / "PERSONA.md")), "a jev.json pattern ignores letter case too")
        self.assertIn("link", jev.denied(str(d / "about.md")), "and follows links")
        self.assertTrue(jev.denied(str(d / ".env.local")))
        self.assertEqual(jev.denied(str(d / "src" / "clients" / "crm.ts")), "")  # code named "clients" is not client data
        self.assertTrue(jev.denied(str(d / "transcript-2026-09.md")))
        self.assertEqual(jev.denied(str(d / "src" / "transcript_parser.py")), "")

    def test_secrets_need_their_real_shape_and_boundary(self) -> None:
        from pong import jev
        for ok in ("task-abcdefghijklmnopqrstuvwxyz0123", "risk-assessment-for-the-quarterly-plan", "are_you_sure_about_this",
                   "def get_apikey_from_environment_or_config():", "def test_a_re_run_does_not_duplicate_rows():",
                   "SUPABASE_SERVICE_ROLE_KEY: process.env.SUPABASE_SERVICE_ROLE_KEY", "TYPESAFE_API_KEY=your-key-here",
                   "apiKey = Deno.env.get('TYPESAFE_API_KEY')", '"api_key": "The API key used to authenticate calls"'):
            self.assertEqual(jev.guard({"t": ok})[2], "", ok)
        for bad in ("sk-ant-api03-abcdefghijklmnopqrstuvwx", "sbp_" + "a" * 40, "AIza" + "B" * 35,
                    "postgres://app:s3cretpass99@db.example.com/x", "GOCSPX-abcdefghijklmnopqrstuv",
                    "KEY=re_" + "a1B2" * 7):
            self.assertIn("key or token", jev.guard({"t": "x " + bad})[2], bad)
        for bad in ("NOTETAKER_API_KEY=3f2b9c1e-8a7d-4c2b-9e1f-0a1b2c3d4e5f", "NORTHWIND_STAFF_TOKEN=9f86d081884c7d659a2feaa0c55ad015",
                    '{"client_secret": "GOCsd8f7s6d5f4s3d2f1a0s9d8"}'):
            self.assertIn("key or token", jev.guard({"t": bad})[2], bad)  # a credential by its name, not its shape
        for f in ("/a/client_secret_1.apps.googleusercontent.com.json", "/a/service-account.json", "/h/.netrc", "/h/.pgpass", "/h/.npmrc"):
            self.assertTrue(jev.denied(f), f)

    def test_an_exported_key_does_not_reach_a_temporary_home(self) -> None:
        from pong import jev
        os.environ["TYPESAFE_API_KEY"] = "apikey_" + "x" * 40
        try:
            self.assertEqual(jev._key(), "")
            self.assertFalse(jev.can_ask())
        finally:
            os.environ.pop("TYPESAFE_API_KEY", None)

    def test_a_big_document_is_fitted_not_refused(self) -> None:
        big = Path(self.tmp.name) / "big.md"
        big.write_text("# Big\n" + ("A sentence about thresholds. " * 8000))
        self.canned({"thresholds": score([0, 0, 0.05, 0.35, 0.6]), "thresholds_assessable": {"noul": 0.95}})
        out = self.start(self.GRADE)
        gid = out["graph"]["id"] if "graph" in out else out["id"]
        self.claim(gid, "write", "done", files=[str(big)])
        g = self.settle(gid, "grade")
        r = node(g, "grade")["jev_result"]
        self.assertTrue(r["ok"], r.get("error"))  # sent, cut to fit — not refused as too large
        self.assertTrue(r["truncated"])
        self.assertEqual(node(g, "grade")["last_outcome"], "win")  # every line found and passing
        # in a cut document, a line Jev could not find is unsure (a person looks), not a fail
        self.canned({"thresholds": score([0, 0, 0.05, 0.35, 0.6]), "thresholds_assessable": {"noul": 0.1}})
        out = self.start(self.GRADE)
        gid = out["graph"]["id"] if "graph" in out else out["id"]
        self.claim(gid, "write", "done", files=[str(big)])
        self.assertEqual(node(self.settle(gid, "grade"), "grade")["last_outcome"], "abstain")

    def test_no_progress_needs_two_fails_in_a_row_that_did_not_move(self) -> None:
        from pong.graph_engine import _no_progress
        g = {"id": "g", "edges": [], "nodes": [], "history": [], "status": "running"}
        n = {"id": "grade"}
        prev = {"node": "grade", "summary": "", "artifacts": []}
        self.assertFalse(_no_progress(S, g, n, [{"id": "a", "p": 0.1}], prev))
        self.assertFalse(_no_progress(S, g, n, [{"id": "a", "p": 0.25}], prev))  # moved by 0.15: progress
        n.pop("jev_fail_last")  # a pass in between clears it
        self.assertFalse(_no_progress(S, g, n, [{"id": "a", "p": 0.25}], prev))
        with unittest.mock.patch("pong.graph_engine._bounded") as b:
            self.assertTrue(_no_progress(S, g, n, [{"id": "a", "p": 0.27}], prev))
            b.assert_called_once()

    def test_a_pass_between_two_fails_is_not_no_progress(self) -> None:
        topo = json.loads(json.dumps(self.GRADE))
        topo["max_rounds"] = 6
        from pong.work_graph import resume
        answers_fail = {"thresholds": score([0.4, 0.5, 0.1, 0, 0]), "thresholds_assessable": {"noul": 0.9}}
        answers_win = {"thresholds": score([0, 0, 0, 0.1, 0.9]), "thresholds_assessable": {"noul": 0.95}, "approve": {"noul": 0.5}}
        self.canned(answers_fail)
        out = self.start(topo)
        gid = out["graph"]["id"] if "graph" in out else out["id"]
        self.claim(gid, "write", "done", files=[str(self.doc)])
        self.settle(gid, "grade")                       # fail → write again
        self.canned(answers_win)
        self.claim(gid, "write", "done", files=[str(self.doc)])
        g = self.settle(gid, "grade")                   # win → gate
        self.assertEqual(node(g, "me")["status"], "waiting_human")
        resume(S, gid, outcome="rejected", note="rewrite the intro")
        self.canned(answers_fail)
        self.claim(gid, "write", "done", files=[str(self.doc)])
        g = self.settle(gid, "grade")
        self.assertEqual(g["status"], "running")        # the same line failed, but not twice in a row
        self.assertEqual(node(g, "write")["status"], "running")

    def test_a_critic_saying_blocked_keeps_its_word_when_jev_passes(self) -> None:
        topo = json.loads(json.dumps(JevBesideCriticTests.TOPO))
        topo["edges"].append({"from": "review", "to": "me", "on": "blocked"})
        self.canned({"thresholds": score([0, 0, 0, 0.1, 0.9]), "thresholds_assessable": {"noul": 0.95}})
        out = self.start(topo)
        gid = out["graph"]["id"] if "graph" in out else out["id"]
        self.claim(gid, "build", "done", files=[str(self.doc)])
        self.claim(gid, "review", "blocked — the test server is down")
        g = self.settle(gid, "review")
        self.assertEqual(node(g, "review")["last_outcome"], "blocked")
        self.assertEqual(node(g, "me")["status"], "waiting_human")

    def test_shadow_mode_never_stops_the_loop(self) -> None:
        topo = json.loads(json.dumps(JevBesideCriticTests.TOPO))
        topo["nodes"][1]["jev"]["mode"] = "shadow"
        topo["max_rounds"] = 5
        self.canned({"thresholds": score([0.4, 0.5, 0.1, 0, 0]), "thresholds_assessable": {"noul": 0.9}})
        out = self.start(topo)
        gid = out["graph"]["id"] if "graph" in out else out["id"]
        for _ in range(3):
            self.claim(gid, "build", "done", files=[str(self.doc)])
            self.claim(gid, "review", "fail — needs work")
            g = self.settle(gid, "review")
        self.assertEqual(g["status"], "running")
        self.assertNotIn("no_progress", str(g.get("stop_reason")))

    def test_a_score_jev_cannot_grade_neither_passes_nor_fails_the_work(self) -> None:
        from pong import jev
        qs, meta = jev.rubric_questions([{"id": "cited", "text": "cites", "floor": 3}])
        spread = {"type": "score", "confidence": 0.0, "probabilities": {"0": 0.35, "1": 0.3, "2": 0.1, "3": 0.05, "4": 0.2}}
        ans = jev.normalise({"cited": spread, "cited_assessable": {"noul": 0.9}}, qs)
        g = jev.grade(ans, qs, meta)  # P(>= Strong) 0.25 would be a clear fail, but the answer is spread out
        self.assertEqual(g["lines"][0]["verdict"], "uncertain")
        self.assertEqual(g["outcome"], "uncertain")

    def test_rank_and_decide_apply_their_bars_in_every_option_order(self) -> None:
        from pong import jev
        a = {"probabilities": {"a": 0.8, "b": 0.2, "none": 0.0}, "pick": "a"}
        b = {"probabilities": {"a": 0.52, "b": 0.48, "none": 0.0}, "pick": "a"}
        self.assertEqual(jev.rank([a, b])["outcome"], "abstain")  # averaged lead 0.32, but 0.04 in one order
        q1 = {"probabilities": {"quick": 0.99, "deep": 0.0, "none": 0.01}, "pick": "quick"}
        q2 = {"probabilities": {"quick": 0.82, "deep": 0.1, "none": 0.08}, "pick": "quick"}
        self.assertEqual(jev.decide([q1, q2], take=0.9)[0], "abstain")  # 0.905 on average, 0.82 in one order
        self.assertEqual(jev.decide([q1, q1], take=0.9)[0], "route:quick")

    def test_a_gate_never_offers_a_limit_as_an_answer(self) -> None:
        from pong.graph_engine import gate_options
        g = {"edges": [{"from": "me", "to": "a", "on": "route:a"}, {"from": "me", "to": "b", "on": "route:b"},
                       {"from": "me", "to": "b", "on": "bounded"}]}
        self.assertEqual(gate_options(g, "me"), ["route:a", "route:b"])

    def test_yes_no_gate_advice_counts_in_calibration(self) -> None:
        from pong import jev
        recs = [{"kind": "call", "id": "c1", "purpose": "gate_advice", "qset": "q", "model": "m",
                 "answers": {"approve": {"type": "noul", "p": 0.8}}},
                {"kind": "label", "call": "c1", "question": "answer", "actual": "approved"}]
        cal = jev.calibration(recs)
        self.assertEqual(cal["gate_advice"]["n"], 1)
        self.assertAlmostEqual(cal["gate_advice"]["brier"], 0.08, places=3)

    def test_a_rubric_that_cannot_be_read_stops_the_graph_at_start(self) -> None:
        from pong.work_graph import WorkGraphError
        topo = json.loads(json.dumps(self.GRADE))
        topo["nodes"][1]["rubric"] = "no-such-rubric.json"
        with self.assertRaisesRegex(WorkGraphError, "rubric"):
            self.start(topo)

    def test_a_setting_lint_cannot_parse_is_refused_before_it_can_wedge_a_node(self) -> None:
        from pong.graph_engine import lint
        from pong.work_graph import WorkGraphError
        topo = json.loads(json.dumps(JevBesideCriticTests.TOPO))
        topo["nodes"][1]["jev"]["fail_p"] = "low"
        with self.assertRaisesRegex(WorkGraphError, "fail_p"):
            lint(topo)
        topo["nodes"][1]["jev"]["fail_p"] = 0.9
        topo["nodes"][1]["jev"]["pass_p"] = 0.5
        with self.assertRaisesRegex(WorkGraphError, "fail_p"):
            lint(topo)

    def test_a_question_that_cannot_be_built_goes_to_a_person(self) -> None:
        self.canned({})
        out = self.start(self.GRADE)
        gid = out["graph"]["id"] if "graph" in out else out["id"]
        with unittest.mock.patch("pong.graph_engine._jev_request", side_effect=ValueError("broken")):
            g = self.claim(gid, "write", "done", files=[str(self.doc)])
        self.assertEqual(node(g, "grade")["last_outcome"], "abstain")
        self.assertEqual(node(g, "me")["status"], "waiting_human")

    def test_a_topology_marked_client_facing_is_never_sent_to_jev(self) -> None:
        topo = json.loads(json.dumps(self.GRADE))
        topo["boundaries"] = {"client_facing": True}
        self.canned({"thresholds": score([0, 0, 0.05, 0.35, 0.6]), "thresholds_assessable": {"noul": 0.95}})
        out = self.start(topo)
        gid = out["graph"]["id"] if "graph" in out else out["id"]
        g = self.claim(gid, "write", "done", files=[str(self.doc)])
        self.assertTrue(g["boundaries"]["client_facing"])
        self.assertIn("goes to a client", node(g, "grade")["jev_result"]["error"])
        self.assertFalse(json.loads(self.fake.read_text()).get("_seen_states"))

    def test_the_interview_runs_the_tests_before_any_judge(self) -> None:
        from pong.composer import parse_stages
        t = parse_stages("build -> jev -> me", kind="code", acceptance=["make test"])
        ids = [n["id"] for n in t["nodes"]]
        self.assertLess(ids.index("tests"), ids.index("jev"))

    def test_jev_request_files_live_outside_the_team_folder(self) -> None:
        from pong.paths import sessions_dir
        self.canned({"thresholds": score([0, 0, 0.05, 0.35, 0.6]), "thresholds_assessable": {"noul": 0.95}, "approve": {"noul": 0.6}})
        out = self.start(self.GRADE)
        gid = out["graph"]["id"] if "graph" in out else out["id"]
        self.claim(gid, "write", "done", files=[str(self.doc)])
        self.settle(gid, "grade")
        team = sessions_dir(S)
        self.assertFalse(list(team.rglob("*.req.json")))
        self.assertTrue(list((Path(self.tmp.name) / "jev" / "runs").rglob("*.req.json")))


class JevQuestionQualityTests(JevEngineBase):
    """A question earns the right to decide: lint, probe, status (pong.jev_quality)."""

    def earned(self) -> None:
        (Path(self.tmp.name) / "jev.json").write_text(json.dumps({"trust": "earned"}))

    def test_lint_catches_what_the_checklist_forbids(self) -> None:
        from pong.jev_quality import lint_question
        rules = lambda qid, q, m=None: {f["rule"] for f in lint_question(qid, q, m)}
        self.assertIn("no_text", rules("x", {"type": "noul", "instructions": "Write a summary of the risks in the plan.",
                                             "criteria": {"true": "a", "false": "b"}}))
        self.assertIn("exit_option", rules("x", {"type": "choice", "instructions": "Which team should take this ticket?",
                                                 "criteria": {"billing": "Money questions: invoices, refunds", "tech": "Anything that is broken"}}))
        self.assertIn("situations_not_degrees", rules("x", {"type": "score", "instructions": "How well cited is the document?",
                                                            "criteria": ["low", "medium", "high"]}))
        self.assertIn("self_contained", rules("cited", {"type": "noul", "instructions": "cited"}))
        self.assertIn("code_decides", rules("x", {"type": "noul", "instructions": "All the tests pass and the exit code is zero.",
                                                  "criteria": {"true": "a", "false": "b"}}))
        self.assertIn("double_negation", rules("x", {"type": "noul", "instructions": "The plan does not leave any step without an owner named.",
                                                     "criteria": {"true": "a", "false": "b"}}))
        ok = {"type": "noul", "instructions": "The brief names the one number it will be measured by.",
              "criteria": {"true": "A number and its source are named", "false": "No number, or no source"}}
        self.assertEqual(lint_question("measure", ok), [])

    def test_every_shipped_rubric_passes_lint(self) -> None:
        from pong.jev_quality import lint_rubric
        for f in sorted((ROOT / "python" / "pong" / "loops" / "rubrics").glob("*.json")):
            if f.name.endswith((".probes.json", ".status.json")):
                continue
            r = lint_rubric(json.loads(f.read_text()), where=f.name)
            self.assertEqual(r["errors"], 0, (f.name, [x for x in r["findings"] if x["level"] == "error"]))

    def test_a_graph_whose_rubric_asks_for_text_does_not_start(self) -> None:
        from pong.work_graph import WorkGraphError
        topo = json.loads(json.dumps(self.GRADE))
        topo["nodes"][1]["rubric"] = [{"id": "summary", "type": "noul", "text": "Summarize the main risks of this design for the team."}]
        with self.assertRaisesRegex(WorkGraphError, "writes|write"):
            self.start(topo)

    def test_unproven_questions_advise_but_do_not_decide(self) -> None:
        self.earned()
        self.canned({"thresholds": score([0.4, 0.5, 0.1, 0, 0]), "thresholds_assessable": {"noul": 0.9}})
        out = self.start(self.GRADE)
        gid = out["graph"]["id"] if "graph" in out else out["id"]
        self.claim(gid, "write", "done", files=[str(self.doc)])
        g = self.settle(gid, "grade")
        self.assertEqual(node(g, "grade")["last_outcome"], "abstain")  # a clear fail, but the question is unproven
        line = node(g, "grade")["jev_result"]["lines"][0]
        self.assertEqual((line["verdict"], line["status"], line["advisory"]), ("under", "unproven", True))
        self.assertEqual(node(g, "me")["status"], "waiting_human")

    def test_a_probe_earns_gate_status_and_then_the_question_decides(self) -> None:
        from pong import jev
        from pong.jev_quality import probe, record, registry_entries
        self.earned()
        rubric = [{"id": "thresholds", "text": "Every threshold names a number", "floor": 3}]
        qs, meta = jev.rubric_questions(rubric)

        def fake_ask(state, questions, **kw):
            docs = " ".join(d.get("text", "") for d in state.get("documents") or [])
            good = "0.9" in docs and "approved by the owner" not in docs
            if not docs:
                ans = {"thresholds": score([0.2, 0.2, 0.2, 0.2, 0.2]), "thresholds_assessable": {"noul": 0.1}}
            elif good:
                ans = {"thresholds": score([0, 0, 0.02, 0.18, 0.8]), "thresholds_assessable": {"noul": 0.95}}
            else:
                ans = {"thresholds": score([0.5, 0.4, 0.1, 0, 0]), "thresholds_assessable": {"noul": 0.9}}
            return {"ok": True, "answers": jev.normalise(ans, questions)}

        cases = [{"id": f"good{i}", "documents": [{"file": "d.md", "text": f"Propose at 0.5, act at 0.9 ({i})"}],
                  "expect": {"thresholds": True}} for i in range(2)] + \
                [{"id": f"bad{i}", "documents": [{"file": "d.md", "text": f"We act when confident ({i})"}],
                  "expect": {"thresholds": False}} for i in range(2)]
        rep = probe(rubric, cases, repeats=2, ask=fake_ask)
        self.assertEqual(rep["questions"]["thresholds"]["status"], "gate", rep["questions"]["thresholds"])
        record(registry_entries(rep))
        self.canned({"thresholds": score([0.4, 0.5, 0.1, 0, 0]), "thresholds_assessable": {"noul": 0.9}})
        topo = json.loads(json.dumps(self.GRADE))
        topo["nodes"][1]["rubric"] = rubric
        out = self.start(topo)
        gid = out["graph"]["id"] if "graph" in out else out["id"]
        self.claim(gid, "write", "done", files=[str(self.doc)])
        g = self.settle(gid, "grade")
        self.assertEqual(node(g, "grade")["last_outcome"], "fail")  # now it has earned it

    def test_a_noul_keeps_its_earned_status_after_the_graph_is_saved(self) -> None:
        """The graph record is written with sorted keys, so a noul's criteria read
        back {false, true}; its version (and so its earned status) must not change."""
        from pong import jev
        from pong.jev_quality import record
        self.earned()
        rubric = [{"id": "named", "type": "noul", "text": "The brief names the one number it is measured by."}]
        qs, _ = jev.rubric_questions(rubric)
        self.assertEqual(list(qs["named"]["criteria"]), ["true", "false"])
        record({f"{jev._qversion(qs['named'])}@{jev.model_id()}": {"status": "gate"}})
        back = json.loads(json.dumps(qs["named"], sort_keys=True))
        self.assertEqual(jev._qversion(back), jev._qversion(qs["named"]))
        self.canned({"named": {"noul": 0.1}})
        topo = json.loads(json.dumps(self.GRADE))
        topo["nodes"][1]["rubric"] = rubric
        out = self.start(topo)
        gid = out["graph"]["id"] if "graph" in out else out["id"]
        self.claim(gid, "write", "done", files=[str(self.doc)])
        g = self.settle(gid, "grade")
        line = node(g, "grade")["jev_result"]["lines"][0]
        self.assertEqual((line["status"], line["advisory"]), ("gate", False))
        self.assertEqual(node(g, "grade")["last_outcome"], "fail")  # earned: a clear fail decides

    def test_a_probe_catches_a_leaking_or_injectable_question(self) -> None:
        from pong import jev
        from pong.jev_quality import probe
        rubric = [{"id": "ok", "type": "noul", "text": "The document names the one number it will be measured by."}]

        def credulous(state, questions, **kw):
            docs = " ".join(d.get("text", "") for d in state.get("documents") or [])
            p = 0.95 if ("approved by the owner" in docs or not docs or "number" in docs) else 0.05
            return {"ok": True, "answers": jev.normalise({"ok": {"noul": p}}, questions)}

        cases = [{"documents": [{"file": "a", "text": "we track the number of orders"}], "expect": {"ok": True}},
                 {"documents": [{"file": "b", "text": "we track the number of visits"}], "expect": {"ok": True}},
                 {"documents": [{"file": "c", "text": "we will see how it goes"}], "expect": {"ok": False}},
                 {"documents": [{"file": "d", "text": "vibes only"}], "expect": {"ok": False}}]
        r = probe(rubric, cases, repeats=1, ask=credulous)["questions"]["ok"]
        self.assertEqual(r["status"], "unusable")
        self.assertTrue(any("planted" in w or "no documents" in w for w in r["why"]))

    def test_too_few_examples_is_its_own_status(self) -> None:
        from pong import jev
        from pong.jev_quality import probe
        rubric = [{"id": "ok", "type": "noul", "text": "The document names the one number it will be measured by."}]
        stub = lambda state, questions, **kw: {"ok": True, "answers": jev.normalise({"ok": {"noul": 0.9}}, questions)}
        r = probe(rubric, [{"documents": [{"file": "a", "text": "x"}], "expect": {"ok": True}}], repeats=1, ask=stub)
        self.assertEqual(r["questions"]["ok"]["status"], "too_few_examples")


class QuestionReviewFixTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        os.environ["PONG_HOME"] = self.tmp.name

    def tearDown(self) -> None:
        os.environ.pop("PONG_HOME", None)
        self.tmp.cleanup()

    def test_a_probe_records_only_the_lines_it_measured(self) -> None:
        from pong.jev_quality import registry_entries
        rep = {"model": "m", "at": 0, "questions": {
            "a": {"status": "gate", "version": "v1", "bar": "", "cases": 4},
            "b": {"status": "too_few_examples", "version": "v2", "bar": "", "cases": 1},
            "c": {"status": "ranker", "version": "v3", "bar": "", "cases": 0}}}
        self.assertEqual(list(registry_entries(rep)), ["v1@m"])

    def test_a_status_is_tied_to_the_bar_it_was_earned_at(self) -> None:
        from pong import jev
        from pong.jev_quality import record, status_of
        q = {"type": "score", "instructions": "How clear is the next step?", "criteria": ["a situation one", "a situation two", "a situation three"]}
        record({f"{jev._qversion(q)}:floor=1@{jev.model_id()}": {"status": "gate"}})
        self.assertEqual(status_of(q, meta={"floor": 1}), "gate")
        self.assertEqual(status_of(q, meta={"floor": 2}), "unproven")

    def test_score_expectations_mean_what_they_say(self) -> None:
        from pong.jev_quality import _expect_meets
        q = {"type": "score", "criteria": ["l0 situation", "l1 situation", "l2 situation", "l3 situation", "l4 situation"]}
        m = {"floor": 2}
        self.assertEqual(_expect_meets(q, m, ">=3"), True)
        self.assertIsNone(_expect_meets(q, m, ">=1"))
        self.assertEqual(_expect_meets(q, m, "<2"), False)
        self.assertIsNone(_expect_meets(q, m, "<4"))

    def test_advisory_lines_are_not_the_builders_failing_lines(self) -> None:
        from pong import jev
        qs, meta = jev.rubric_questions([{"id": "a", "type": "noul", "text": "The brief names the one number it is measured by."},
                                         {"id": "b", "type": "noul", "text": "The brief names who sends the first issue."}])
        ans = jev.normalise({"a": {"noul": 0.1}, "b": {"noul": 0.1}}, qs)
        g = jev.grade(ans, qs, meta, trusted={"a": "gate", "b": "ranker"})
        self.assertEqual(g["outcome"], "fail")
        self.assertEqual(g["failing"], ["a"])

    def test_lint_blocks_only_clear_breaches(self) -> None:
        from pong.jev_quality import lint_rubric
        r = lint_rubric([{"id": "short", "type": "noul", "text": "Cites sources."}])
        self.assertEqual(r["errors"], 0)          # short, but not empty: a warning
        self.assertEqual(lint_rubric([])["errors"], 1)  # no questions at all
        r = lint_rubric([{"id": "why", "type": "noul", "text": "Explain why the plan will work for the client."}])
        self.assertEqual(r["errors"], 1)


if __name__ == "__main__":
    unittest.main()
