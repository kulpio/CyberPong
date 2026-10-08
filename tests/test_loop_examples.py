#!/usr/bin/env python3
"""Examples as a bar, and stop-vs-forget for a loop.

Three things the owner asked for, at the control-plane level: paste URLs as the
comparison set, search for candidates from the task text, and be able to
delete a loop off the list rather than only cancel it.

No test here touches the network. `search` is exercised through its two
source seams with those patched, because a test that reaches DuckDuckGo is a
test that fails on a train.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "python"))

URL_A = "https://github.com/crewaiinc/crewai"
URL_B = "https://github.com/deepset-ai/haystack"


def _pair(tmp, session="pong-team"):
    os.environ["PONG_HOME"] = tmp
    os.environ["PONG_SESSION"] = session
    from pong.paths import ensure_layout, pairs_path, active_path
    from pong.jsonutil import write_json
    from pong.routing import ensure_session_token

    ensure_layout(session)
    pair = {
        "schema_version": 2,
        "conductor": {
            "id": "c1", "type": "grok", "label": "Grok",
            "cmd": "grok", "mode": "tmux", "tmux_index": 0,
        },
        "workers": [
            {"id": "w1", "type": "claude", "label": "Builder",
             "cmd": "claude", "tmux_index": 1, "mission_role": "coder"},
            {"id": "w2", "type": "claude", "label": "Lead",
             "cmd": "claude", "tmux_index": 2, "mission_role": "coder"},
        ],
        "transport_default": "job",
        "flow_graph": {"edges": [
            {"from": "c1", "to": "w1", "kind": "delegate"},
            {"from": "w1", "to": "c1", "kind": "claim"},
            {"from": "c1", "to": "w2", "kind": "delegate"},
            {"from": "w2", "to": "c1", "kind": "claim"},
        ]},
    }
    write_json(pairs_path(), {session: pair})
    active = dict(pair)
    active["session"] = session
    write_json(active_path(), active)
    ensure_session_token(session)
    return pair


class LoopBase(unittest.TestCase):
    SESSION = "pong-team"

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        _pair(self.tmp.name)
        self._saved_seat = os.environ.pop("PONG_SEAT", None)

    def tearDown(self) -> None:
        self.tmp.cleanup()
        for key in ("PONG_HOME", "PONG_SESSION", "PONG_TOKEN"):
            os.environ.pop(key, None)
        if self._saved_seat is not None:
            os.environ["PONG_SEAT"] = self._saved_seat
        else:
            os.environ.pop("PONG_SEAT", None)


class ExamplesAsTheBarTests(LoopBase):
    def test_examples_reach_the_graph(self) -> None:
        from pong.work_graph import find_graph, start

        graph = start(self.SESSION, owner="w1", loop="fan", task="cover it",
                      fan_n=2, examples=[URL_A, URL_B])
        stored = find_graph(self.SESSION, graph["id"])
        urls = [e["url"] for e in stored.get("examples") or []]
        self.assertEqual(urls, [URL_A, URL_B])

    def test_examples_reach_the_task_the_seat_is_given(self) -> None:
        """A bar nobody is told about is not a bar."""
        from pong.work_graph import start

        graph = start(self.SESSION, owner="w1", loop="fan", task="cover it",
                      fan_n=2, examples=[URL_A])
        jobs = graph.get("_jobs") or []
        self.assertTrue(jobs, "start produced no jobs")
        self.assertIn(URL_A, jobs[0].get("task") or "")
        self.assertIn("Quality examples", jobs[0].get("task") or "")

    def test_gauntlet_with_examples_and_no_bar_writes_one(self) -> None:
        from pong.work_graph import start

        graph = start(self.SESSION, owner="w1", loop="gauntlet",
                      task="match this quality", examples=[URL_A, URL_B])
        bar = graph.get("bar") or ""
        self.assertTrue(bar, "gauntlet started with examples but no bar was written")
        text = Path(bar).read_text(encoding="utf-8")
        self.assertIn(URL_A, text)
        self.assertIn(URL_B, text)
        self.assertIn("open these URLs", text)

    def test_gauntlet_with_neither_bar_nor_examples_still_refuses(self) -> None:
        """Starting a grader with nothing to grade against is meaningless."""
        from pong.work_graph import WorkGraphError, start

        with self.assertRaises(WorkGraphError) as caught:
            start(self.SESSION, owner="w1", loop="gauntlet", task="ship it")
        self.assertIn("bar", str(caught.exception))

    def test_an_explicit_bar_is_kept_and_no_examples_file_is_invented(self) -> None:
        from pong.work_graph import start

        bar = Path(self.tmp.name) / "hand-written-bar.md"
        bar.write_text("# bar\n", encoding="utf-8")
        graph = start(self.SESSION, owner="w1", loop="gauntlet",
                      task="ship it", bar=str(bar))
        self.assertEqual(graph.get("bar"), str(bar))


class BothArgSpellingsTests(unittest.TestCase):
    """`--examples a,b` and repeatable `--example` land in one shape."""

    def _args(self, examples=None, example=None):
        return argparse.Namespace(examples=examples, example=example or [])

    def test_comma_list_and_repeated_flag_merge_and_dedup(self) -> None:
        from pong.cli.main import _examples_from_args

        rows = _examples_from_args(self._args(examples=f"{URL_A},{URL_B}",
                                              example=[URL_A]))
        self.assertEqual([r["url"] for r in rows], [URL_A, URL_B])

    def test_neither_flag_is_an_empty_set_not_an_error(self) -> None:
        from pong.cli.main import _examples_from_args

        self.assertEqual(_examples_from_args(self._args()), [])


class CancelVersusDeleteTests(LoopBase):
    """Stop and forget are different, and only one of them loses the record."""

    def _three(self):
        from pong.work_graph import start

        a = start(self.SESSION, owner="w1", loop="fan", task="a", fan_n=2)
        b = start(self.SESSION, owner="w1", loop="cycle", task="b", max_rounds=2)
        c = start(self.SESSION, owner="w1", loop="fan", task="c", fan_n=2)
        return a["id"], b["id"], c["id"]

    def _ids(self):
        from pong.work_graph import load

        return [str(g.get("id")) for g in load(self.SESSION).get("graphs") or []]

    def test_cancel_keeps_the_graph_as_history(self) -> None:
        from pong.work_graph import cancel, find_graph

        _, b, _ = self._three()
        cancel(self.SESSION, b)
        stored = find_graph(self.SESSION, b)
        self.assertIsNotNone(stored, "cancel removed the graph; it should keep it")
        self.assertEqual(stored["status"], "cancelled")
        self.assertEqual(len(self._ids()), 3)

    def test_delete_removes_only_that_graph(self) -> None:
        from pong.work_graph import delete, find_graph

        a, b, c = self._three()
        delete(self.SESSION, b)
        self.assertIsNone(find_graph(self.SESSION, b))
        self.assertEqual(self._ids(), [a, c])

    def test_delete_cancels_a_running_graph_before_forgetting_it(self) -> None:
        """Otherwise its jobs outlive the only record that explains them."""
        from pong.schema import TERMINAL_STATUSES
        from pong.jobs import load_job
        from pong.work_graph import delete, find_graph, start

        graph = start(self.SESSION, owner="w1", loop="fan", task="a", fan_n=2)
        job_ids = [j["id"] for j in (graph.get("_jobs") or [])]
        self.assertTrue(job_ids, "start produced no jobs to strand")
        removed = delete(self.SESSION, graph["id"])
        self.assertTrue(removed.get("deleted"))
        self.assertIsNone(find_graph(self.SESSION, graph["id"]))
        for jid in job_ids:
            job = load_job(self.SESSION, jid)
            self.assertIn(str(job.get("status")), TERMINAL_STATUSES,
                          f"job {jid} left live after its graph was deleted")

    def test_delete_is_safe_to_call_on_an_already_cancelled_graph(self) -> None:
        from pong.work_graph import cancel, delete, find_graph

        a, b, _ = self._three()
        cancel(self.SESSION, b)
        delete(self.SESSION, b)
        self.assertIsNone(find_graph(self.SESSION, b))
        self.assertIn(a, self._ids())

    def test_delete_an_unknown_id_errors_rather_than_silently_passing(self) -> None:
        from pong.work_graph import WorkGraphError, delete

        self._three()
        with self.assertRaises(WorkGraphError):
            delete(self.SESSION, "g_not_here")
        self.assertEqual(len(self._ids()), 3)

    def test_delete_without_an_id_errors(self) -> None:
        from pong.work_graph import WorkGraphError, delete

        with self.assertRaises(WorkGraphError):
            delete(self.SESSION, "")


class SearchWithoutTheNetworkTests(unittest.TestCase):
    """`search` is exercised at its two source seams, both patched."""

    GH = [{"url": URL_A, "title": "crewai", "snippet": "agents", "kind": "repo",
           "host": "github.com", "id": "ex_a", "stars": 900}]
    WEB = [{"url": "https://example.com/quiet-dashboards", "title": "Quiet dashboards",
            "snippet": "a page", "kind": "page", "host": "example.com", "id": "ex_b"}]

    def test_rows_come_back_and_nothing_is_fetched(self) -> None:
        import pong.examples as ex

        with patch.object(ex, "_search_github_repos", return_value=list(self.GH)) as gh, \
             patch.object(ex, "_web_search_query", return_value=list(self.WEB)) as web, \
             patch.object(ex, "_fetch", side_effect=AssertionError("network touched")):
            rows = ex.search("quiet dashboard design", limit=5)
        self.assertTrue(gh.called and web.called)
        urls = {r["url"] for r in rows}
        self.assertIn(URL_A, urls)
        for r in rows:
            self.assertTrue(r.get("url") and r.get("title"))

    def test_json_shape_is_serialisable_because_the_island_parses_it(self) -> None:
        import pong.examples as ex

        with patch.object(ex, "_search_github_repos", return_value=list(self.GH)), \
             patch.object(ex, "_web_search_query", return_value=list(self.WEB)):
            rows = ex.search("quiet dashboard design", limit=5)
        json.loads(json.dumps(rows))          # would raise if a row held a non-JSON type

    def test_no_sources_answering_returns_nothing_rather_than_inventing(self) -> None:
        import pong.examples as ex

        with patch.object(ex, "_search_github_repos", return_value=[]), \
             patch.object(ex, "_web_search_query", return_value=[]):
            self.assertEqual(ex.search("nothing matches this", limit=5), [])

    def test_every_source_failing_is_raised_not_swallowed(self) -> None:
        """A dead network must not read as 'no results'."""
        import pong.examples as ex

        boom = OSError("no route to host")
        with patch.object(ex, "_search_github_repos", side_effect=boom), \
             patch.object(ex, "_web_search_query", side_effect=boom):
            with self.assertRaises(ex.ExampleError):
                ex.search("quiet dashboard design", limit=5)

    def test_an_empty_query_is_empty_not_a_search(self) -> None:
        import pong.examples as ex

        with patch.object(ex, "_fetch", side_effect=AssertionError("network touched")):
            self.assertEqual(ex.search("   "), [])


if __name__ == "__main__":
    unittest.main()
