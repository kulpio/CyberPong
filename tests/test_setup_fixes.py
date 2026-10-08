#!/usr/bin/env python3
"""2.0 review fixes on the engine side of setup, the architect and the doctor, each pinned by what it has to do.

- `scripts/install.sh --developer` is the one writer of `developer`: merged in, every other key kept, 0600.
- What setup calls "Recommended" for the planning chat is what `architect new` starts on.
- An AI that is installed but switched off is never "installed again"; Hermes is refused in plain words.
- A key someone gave Claude Code's Perplexity connector is only used on the owner's Mac.
- tmux that Homebrew installed off the shell's PATH is the tmux every call runs; a chat whose terminal
  could not start is never reported as made, and leaves no team behind.
- An AI CLI installed with npm under nvm (or found by the person's own shell) is found, and its seat finds node.
- Every install hint is a command; graphs are not all called by their template's name; the Screen tab and
  the activity say plain, true things.
"""
from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import os
import re
import stat
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "python"))

from test_jev import JevEngineBase, node  # noqa: E402

S = "pong-team"
ENV_KEYS = ("PONG_HOME", "PONG_RUNTIMES", "PONG_SESSION", "PONG_SEAT", "TYPESAFE_API_KEY", "PONG_JEV_FAKE",
            "PERPLEXITY_API_KEY", "PONG_NAMES", "HOME", "PATH", "NVM_DIR", "SHELL")


class _Home(unittest.TestCase):
    """A throwaway HOME whose CyberPong home is HOME/.pong (the "real home" shape), PATH without the CLIs."""

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.home = Path(self.tmp.name) / "user"
        self.state = self.home / ".pong"
        self.state.mkdir(parents=True)
        self._env = {k: os.environ.get(k) for k in ENV_KEYS}
        for k in ("PONG_RUNTIMES", "PONG_SESSION", "PONG_SEAT", "TYPESAFE_API_KEY", "PONG_JEV_FAKE",
                  "PERPLEXITY_API_KEY", "NVM_DIR"):
            os.environ.pop(k, None)
        os.environ["HOME"] = str(self.home)
        os.environ["PONG_HOME"] = str(self.state)
        os.environ["PATH"] = "/usr/bin:/bin"
        from pong import groups, models

        self._saved = (models._login_tried_at, models._ask_login_shell, groups._TMUX_BIN)
        models._login_tried_at = 0.0
        groups._TMUX_BIN = None

    def tearDown(self) -> None:
        from pong import groups, models

        models._login_tried_at, models._ask_login_shell, groups._TMUX_BIN = self._saved
        for k, v in self._env.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        self.tmp.cleanup()

    def settings(self, **kw) -> None:
        (self.state / "settings.json").write_text(json.dumps(kw))

    def tool(self, folder: Path, name: str, body: str, shebang: str = "#!/bin/sh") -> Path:
        folder.mkdir(parents=True, exist_ok=True)
        p = folder / name
        p.write_text(f"{shebang}\n{body}\n")
        p.chmod(0o755)
        return p

    def cli(self, argv: list[str]) -> tuple[int, str, str]:
        from pong.cli.main import main

        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = main(argv)
        return code, out.getvalue(), err.getvalue()


# ------------------------------------------------------------------ developer (finding 10) ---

class DeveloperSettingTests(_Home):
    def write_developer(self) -> subprocess.CompletedProcess:
        text = (ROOT / "scripts" / "install.sh").read_text()
        m = re.search(r"^write_developer_setting\(\) \{\n.*?^\}\n", text, re.S | re.M)
        self.assertIsNotNone(m, "install.sh defines write_developer_setting")
        script = m.group(0) + "write_developer_setting\n"
        env = {**os.environ, "PATH": "/usr/bin:/bin:" + os.path.dirname(sys.executable)}
        return subprocess.run(["/bin/bash", "-c", script], capture_output=True, text=True, env=env, timeout=30)

    def test_install_developer_merges_one_key_and_keeps_the_rest(self) -> None:
        from pong import settings as St

        keep = {"app_ai": {"onboarding_complete": True}, "coachmarks": {"x": 1}, "owner_name": "Sam",
                "limits": {"week_stop_pct": 0}}
        self.settings(**keep)
        r = self.write_developer()
        self.assertEqual(r.returncode, 0, r.stderr)
        data = json.loads((self.state / "settings.json").read_text())
        self.assertEqual(data, {**keep, "developer": True}, "every other key is kept")
        self.assertEqual(stat.S_IMODE((self.state / "settings.json").stat().st_mode), 0o600)
        self.assertEqual(sorted(p.name for p in self.state.iterdir()), ["settings.json"], "no temp file left")
        self.assertTrue(St.developer())
        from pong import doctor

        self.assertIn("Developer: on", "\n".join(doctor.format_text(doctor.check())))
        self.assertTrue(doctor.check()["settings"]["developer"])

    def test_no_file_yet_and_a_garbled_file(self) -> None:
        r = self.write_developer()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(json.loads((self.state / "settings.json").read_text()), {"developer": True})
        (self.state / "settings.json").write_text("{not json")
        r = self.write_developer()
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual((self.state / "settings.json").read_text(), "{not json", "a file it can't read is left alone")

    def test_the_flag_is_parsed_and_the_docstrings_name_the_writer(self) -> None:
        text = (ROOT / "scripts" / "install.sh").read_text()
        self.assertIn("--developer) DEVELOPER=1", text)
        self.assertIn('if [[ "$LOGIN" == 1 ]]', text, "--login works wherever it is on the line")
        from pong import settings as St

        self.assertIn("install.sh --developer", St.__doc__)
        self.assertIn("install.sh --developer", St.developer.__doc__)


# ------------------------------------------------------------------ recommended (finding 14) ---

class RecommendedTests(_Home):
    def plan_cli(self) -> dict:
        code, out, err = self.cli(["model", "plan", "--role", "orchestrator", "--json"])
        self.assertEqual(code, 0, err)
        return json.loads(out)

    def test_recommended_is_what_the_chat_starts_on(self) -> None:
        from pong import architect as A

        for rts, settings, want in (("grok", {}, "grok"),
                                    ("claude,grok,codex,hermes", {"ai_enabled": {"claude": False}}, "codex"),
                                    ("claude,grok", {}, "claude"),
                                    ("codex,hermes", {}, "codex")):
            os.environ["PONG_RUNTIMES"] = rts
            self.settings(**settings)
            d = self.plan_cli()
            self.assertEqual(d["runtime"], want, rts)
            self.assertEqual(d["runtime"], A.choose_runtime(None, None)["effective"], rts)
        os.environ["PONG_RUNTIMES"] = "claude,grok"
        self.settings()
        self.assertEqual(self.plan_cli()["model"], "fable")

    def test_hermes_alone_has_no_recommendation(self) -> None:
        from pong import architect as A

        os.environ["PONG_RUNTIMES"] = "hermes"
        d = self.plan_cli()
        self.assertIsNone(d["runtime"])
        self.assertIsNone(d["model"])
        with self.assertRaises(A.ArchitectError):
            A.choose_runtime(None, None)
        os.environ["PONG_RUNTIMES"] = ","
        self.assertIsNone(self.plan_cli()["runtime"])

    def test_other_roles_keep_the_catalogs_answer(self) -> None:
        os.environ["PONG_RUNTIMES"] = "claude,grok"
        code, out, _ = self.cli(["model", "plan", "--role", "critic", "--json"])
        self.assertEqual(code, 0)
        self.assertIn("launch_cmd", json.loads(out))


# ------------------------------------------------------------------ switched off, Hermes (15, 33) ---

class RefusalWordsTests(_Home):
    def test_installed_but_switched_off_is_never_install_it(self) -> None:
        from pong import architect as A

        os.environ["PONG_RUNTIMES"] = "claude,grok,codex,hermes"
        for off in ({"claude": False, "grok": False, "codex": False},
                    {"claude": False, "grok": False, "codex": False, "hermes": False}):
            self.settings(ai_enabled=off)
            with self.assertRaises(A.ArchitectError) as e:
                A.choose_runtime()
            msg = str(e.exception)
            self.assertIn("switched off in Settings", msg)
            self.assertIn("Claude Code, Grok Build and Codex are switched off", msg)
            self.assertNotIn("Install", msg)
        os.environ["PONG_RUNTIMES"] = "claude,hermes"
        self.settings(ai_enabled={"claude": False})
        with self.assertRaises(A.ArchitectError) as e:
            A.choose_runtime()
        self.assertIn("Claude Code is switched off in Settings › AI accounts. Switch it on there", str(e.exception))

    def test_nothing_installed_still_says_install(self) -> None:
        from pong import architect as A

        for rts in (",", "hermes"):
            os.environ["PONG_RUNTIMES"] = rts
            self.settings()
            with self.assertRaises(A.ArchitectError) as e:
                A.choose_runtime()
            self.assertIn("Install Claude Code", str(e.exception))

    def test_hermes_in_plain_words(self) -> None:
        from pong import architect as A

        os.environ["PONG_RUNTIMES"] = "claude,hermes"
        with self.assertRaises(A.ArchitectError) as e:
            A.choose_runtime("hermes")
        self.assertEqual(str(e.exception), "Hermes can't plan graphs yet. Pick Claude Code, Grok Build or Codex for this chat.")
        os.environ["PONG_RUNTIMES"] = "hermes"
        with self.assertRaises(A.ArchitectError) as e:
            A.choose_runtime()
        self.assertTrue(str(e.exception).startswith("Hermes can't plan graphs yet. Install Claude Code ("))
        self.assertNotIn("instructions", str(e.exception))


# ------------------------------------------------------------------ Perplexity (finding 19) ---

class PerplexityConnectorTests(_Home):
    KEY = "pplx-" + "c0nnect0r" * 4

    def setUp(self) -> None:
        super().setUp()
        (self.home / ".claude.json").write_text(json.dumps(
            {"mcpServers": {"perplexity": {"env": {"PERPLEXITY_API_KEY": self.KEY}}}}))

    def test_someone_elses_mac_never_spends_their_connector_key(self) -> None:
        from pong import settings as St

        self.assertEqual(St.perplexity_key(), ("", ""))
        self.assertFalse(St.keys_status()["perplexity"]["set"])

    def test_the_owners_mac_names_where_it_comes_from(self) -> None:
        from pong import settings as St

        self.settings(developer=True)
        self.assertEqual(St.perplexity_key(), (self.KEY, "claude_connector"))
        code, out, _ = self.cli(["keys", "status"])
        self.assertIn("Perplexity: set (from Claude Code's Perplexity connector)", out)
        self.assertNotIn(self.KEY, out)
        code, out, _ = self.cli(["keys", "clear", "--name", "perplexity"])
        self.assertEqual(code, 0)
        self.assertIn("Settings held no Perplexity key.", out)
        self.assertIn("Remove can't take that one away", out)
        self.assertIn("Switch Perplexity off in Settings › Limits & keys", out)
        self.assertNotIn(self.KEY, out)
        from pong import doctor

        self.assertIn("from Claude Code's Perplexity connector", "\n".join(doctor.format_text(doctor.check())))

    def test_a_temporary_home_never_reads_it(self) -> None:
        from pong import settings as St

        self.settings(developer=True)
        os.environ["PONG_HOME"] = str(Path(self.tmp.name) / "elsewhere")
        self.assertEqual(St.perplexity_key(), ("", ""))

    def test_pplx_without_the_engine_ignores_the_connector(self) -> None:
        spec = importlib.util.spec_from_file_location("pplx_under_test", ROOT / "scripts" / "graph-kit" / "pplx.py")
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        mod.S = None  # as on a Mac where the kit sits with no engine beside it
        self.assertEqual(mod.key(), "")
        os.environ["PERPLEXITY_API_KEY"] = "pplx-from-the-environment-1"
        self.assertEqual(mod.key(), "pplx-from-the-environment-1")
        self.assertNotIn(".claude.json", (ROOT / "scripts" / "graph-kit" / "pplx.py").read_text().split("def key")[1].split("def budget")[0])


# ------------------------------------------------------------------ tmux off PATH (finding 22) ---

class TmuxOffPathTests(_Home):
    def fake_tmux(self, new_session_ok: bool = True) -> Path:
        log = self.home / "tmux.log"
        body = (f'echo "$@" >> {log}\n'
                'case "$1" in\n'
                '  -V) echo "tmux 3.5a" ;;\n'
                '  has-session) exit 1 ;;\n'
                f'  new-session) {"exit 0" if new_session_ok else "echo no server; exit 1"} ;;\n'
                'esac\nexit 0')
        return self.tool(self.home / ".local" / "bin", "tmux", body)

    def team(self) -> Path:
        from pong.jsonutil import write_json
        from pong.paths import active_path, ensure_layout, pairs_path
        from pong.routing import ensure_session_token

        os.environ["PONG_RUNTIMES"] = "claude"
        os.environ["PONG_SESSION"] = S
        ensure_layout(S)
        project = self.home / "project"
        project.mkdir()
        pair = {"schema_version": 2, "project_root": str(project),
                "conductor": {"id": "c1", "type": "claude", "label": "lead", "cmd": "claude", "mode": "tmux", "tmux_index": 0},
                "workers": [], "transport_default": "job", "flow_graph": {"edges": []}}
        write_json(pairs_path(), {S: pair})
        write_json(active_path(), {**pair, "session": S})
        ensure_session_token(S)
        return project

    def test_every_call_runs_the_tmux_the_check_found(self) -> None:
        from pong import architect as A
        from pong import groups

        fake = self.fake_tmux()
        self.assertEqual(groups.tmux_bin(), str(fake))
        self.assertEqual(A._tmux_path(), str(fake), "the check and the spawn agree")
        ok, out = groups._tmux("-V")
        self.assertTrue(ok, out)
        self.assertEqual(out, "tmux 3.5a")
        groups._TMUX_BIN = str(self.home / "gone" / "tmux")  # the one kept was uninstalled or moved
        self.assertEqual(groups.tmux_bin(), str(fake), "looked for again")

    def test_a_chat_whose_terminal_could_not_start_is_not_made(self) -> None:
        from pong import architect as A
        from pong import groups
        from pong.paths import jobs_dir, sessions_dir
        from pong.state import load_active, load_pairs_db

        project = self.team()
        self.fake_tmux(new_session_ok=False)
        before, active = set(load_pairs_db()), load_active()
        orig = groups.isolated_home
        groups.isolated_home = lambda: False
        try:
            with self.assertRaises(A.ArchitectError) as e:
                A.new("Intake app", str(project))
            with self.assertRaises(A.ArchitectError):
                A.new("Intake app", str(project))  # a retry makes nothing either
        finally:
            groups.isolated_home = orig
        self.assertIn("The chat's terminal could not start", str(e.exception))
        self.assertIn("Nothing was made", str(e.exception))
        self.assertEqual(set(load_pairs_db()), before, "no half-made team")
        self.assertFalse(sessions_dir("pong-team-1").exists())
        self.assertFalse(jobs_dir("pong-team-1").exists(), "an empty jobs folder would hold the name")
        self.assertEqual(load_active()["session"], active["session"], "the active team is put back")

    def test_a_new_mac_keeps_no_pointer_to_the_team_taken_back(self) -> None:
        from pong import architect as A
        from pong import groups
        from pong.paths import active_path

        os.environ["PONG_RUNTIMES"] = "claude"
        project = self.home / "project"
        project.mkdir()
        self.fake_tmux(new_session_ok=False)
        self.assertFalse(active_path().exists())
        orig = groups.isolated_home
        groups.isolated_home = lambda: False
        try:
            with self.assertRaises(A.ArchitectError):
                A.new("Intake app", str(project))
        finally:
            groups.isolated_home = orig
        self.assertFalse(active_path().exists(), "no active team named after one that does not exist")

    def test_tmux_off_path_starts_the_chat(self) -> None:
        from pong import architect as A
        from pong import groups

        project = self.team()
        self.fake_tmux()
        orig = groups.isolated_home
        groups.isolated_home = lambda: False
        try:
            r = A.new("Intake app", str(project))
        finally:
            groups.isolated_home = orig
        self.assertTrue(r["ok"])
        self.assertTrue(r["started"])
        self.assertIn("new-session -d -s pong-team-1", (self.home / "tmux.log").read_text())

    def test_start_refuses_when_the_teams_session_will_not_open(self) -> None:
        from pong import architect as A
        from pong import groups

        project = self.team()
        self.fake_tmux(new_session_ok=False)
        orig = groups.isolated_home
        groups.isolated_home = lambda: False
        try:
            with self.assertRaises(A.ArchitectError) as e:
                A.start(S, "next round", cwd=str(project))
        finally:
            groups.isolated_home = orig
        self.assertIn("could not start", str(e.exception))
        self.assertEqual(A.list_for(S), [], "no chat recorded")


# ------------------------------------------------------------------ npm under nvm (finding 23) ---

class NvmTests(_Home):
    def nvm_claude(self, version: str = "v22.11.0") -> Path:
        bin_dir = self.home / ".nvm" / "versions" / "node" / version / "bin"
        self.tool(bin_dir, "fakenode", 'echo \'{"loggedIn": true, "subscriptionType": "pro"}\'')
        self.tool(bin_dir, "claude", "", shebang="#!/usr/bin/env fakenode")
        return bin_dir

    def test_claude_under_nvm_is_found_and_signed_in(self) -> None:
        from pong import doctor, groups
        from pong import models as M

        old = self.nvm_claude("v20.1.0")
        new = self.nvm_claude("v22.11.0")
        self.assertEqual(M.cli_dirs()[5:7], [str(new), str(old)], "newest version first, after the usual five")
        row = doctor.ai_rows()["claude"]
        self.assertTrue(row["installed"])
        self.assertIn(".nvm/versions/node/v22.11.0/bin/claude", row["path"])
        self.assertTrue(row["signed_in"], "claude runs `env node`: its folder is on PATH for the check")
        self.assertEqual(row["plan"], "pro")
        self.assertIn("claude", M.available_runtimes())
        line = groups._launch_command({"session": S}, {"id": "c1.a", "type": "claude", "cmd": "claude"}, initial_prompt="go")
        first = line.split("; ")[0]
        self.assertTrue(first.startswith('export PATH="$HOME/bin:$HOME/.local/bin:$HOME/.grok/bin:/opt/homebrew/bin:'
                                         '/usr/local/bin:'))
        self.assertIn(str(new), first, "the seat finds the CLI and the node beside it")
        self.assertTrue(first.endswith(':$PATH"'))

    def test_the_usage_check_the_usage_pane_and_the_runner_find_node_under_nvm(self) -> None:
        import plistlib

        from pong import limits as L
        from pong import models as M
        from pong import runtime as R

        new = self.nvm_claude("v22.11.0")
        volta = self.home / ".volta" / "bin"
        volta.mkdir(parents=True)
        claude = str(new / "claude")
        self.assertEqual(M.path_for(claude).split(os.pathsep)[0], str(new), "claude's own folder first")
        env = L.Env()
        self.assertTrue(env.claude_ready(), "`claude auth status` finds the node beside an npm claude")
        # the usage pane's command, run by a shell whose PATH is as bare as launchd's
        typed: list[tuple[str, ...]] = []
        env._tmux = lambda *a: typed.append(a) or (True, "")
        self.assertTrue(env.probe_start())
        cmd = typed[0][-1]
        self.assertTrue(cmd.startswith("env PATH="), cmd)
        self.assertTrue(cmd.endswith(" --strict-mcp-config"), cmd)
        out = subprocess.run(["/bin/sh", "-c", cmd], capture_output=True, text=True, timeout=10,
                             env={"PATH": "/usr/bin:/bin", "HOME": str(self.home)}).stdout
        self.assertIn('"loggedIn": true', out, "the pane's claude starts: its node is found")
        # the runner launchd starts gets the CLIs' folders on its PATH, ahead of the system's
        dirs = plistlib.loads(R.plist_text(python="/x/python3").encode())["EnvironmentVariables"]["PATH"].split(":")
        self.assertIn(str(new), dirs)
        self.assertIn(str(volta), dirs)
        self.assertLess(dirs.index(str(new)), dirs.index("/usr/bin"))
        self.assertEqual(dirs[-4:], ["/usr/bin", "/bin", "/usr/sbin", "/sbin"])
        self.assertEqual(len(dirs), len(set(dirs)), "no folder twice")

    def test_nvms_default_alias_comes_first(self) -> None:
        from pong import models as M

        self.nvm_claude("v20.1.0")
        self.nvm_claude("v22.11.0")
        (self.home / ".nvm" / "alias").mkdir()
        (self.home / ".nvm" / "alias" / "default").write_text("20\n")
        self.assertTrue(M.cli_dirs()[5].endswith("v20.1.0/bin"))

    def test_the_login_shell_is_asked_once_and_remembered(self) -> None:
        from pong import models as M

        odd = self.home / "tools" / "bin"
        self.tool(odd, "codex", "exit 0")
        asked = []
        M._ask_login_shell = lambda *a, **k: asked.append(1) or f"/usr/bin:/bin:{odd}:{self.home}/nothing-here"
        self.assertEqual(M.available_runtimes(), {"codex"})
        self.assertEqual(len(asked), 1)
        cache = json.loads((self.state / "cli-path.json").read_text())
        self.assertEqual(cache["dirs"], [str(odd)], "only folders that hold an AI CLI or node")
        self.assertIn(str(odd), M.cli_dirs())
        M._login_tried_at = 0.0
        self.assertEqual(M.available_runtimes(), {"codex"})
        self.assertEqual(len(asked), 1, "found through the cache: not asked again")

    def test_a_temporary_home_never_asks_the_persons_shell(self) -> None:
        from pong import models as M

        os.environ["PONG_HOME"] = str(Path(self.tmp.name) / "elsewhere")
        M._ask_login_shell = lambda *a, **k: self.fail("the person's shell was started from a temporary home")
        self.assertEqual(M.login_shell_dirs(), [])
        os.environ["PONG_RUNTIMES"] = "claude"
        self.assertEqual(M.available_runtimes(), {"claude"}, "a pin never searches")


# ------------------------------------------------------------------ install hints (finding 29) ---

class InstallHintTests(unittest.TestCase):
    def test_every_hint_is_a_command(self) -> None:
        from pong import doctor

        for rid, meta in doctor.AIS.items():
            self.assertRegex(meta["install"], r"^[a-z]", rid)
        self.assertEqual(doctor.AIS["hermes"]["install"], "curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash")


# ------------------------------------------------------------------ graph titles (walkthrough #5) ---

class GraphTitleTests(unittest.TestCase):
    def test_two_graphs_from_one_template_are_not_both_write_review(self) -> None:
        from pong.graph_engine import graph_title

        t = {"name": "write-review"}
        a = graph_title({"id": "g_1", "topology": t, "goal": "Plan the bakery website refresh: hours, menu, photos."})
        b = graph_title({"id": "g_2", "topology": t, "goal": "Write the October newsletter for the regulars list: new bakes"})
        self.assertEqual(a, "Plan the bakery website refresh")
        self.assertEqual(b, "Write the October newsletter for the regulars list")
        self.assertEqual(graph_title({"id": "g_3", "topology": t,
                                      "goal": "Build the cake pre-order form (change 5): order fields"}),
                         "Build the cake pre-order form")

    def test_a_short_name_wins_and_the_template_is_last(self) -> None:
        from pong.graph_engine import graph_title

        self.assertEqual(graph_title({"topology": {"name": "write-review", "title": "Bakery plan"}, "goal": "x y z"}),
                         "Bakery plan")
        self.assertEqual(graph_title({"title": "Site plan", "topology": {"name": "intake-plan-v1"}, "goal": "x"}),
                         "Site plan")
        self.assertEqual(graph_title({"topology": {"name": "intake-plan-v1"}, "goal": "Plan the intake app"}),
                         "intake-plan-v1", "a design's own name is its short name")
        self.assertEqual(graph_title({"id": "g_9", "topology": {"name": "build-verify"}, "goal": ""}), "build-verify")
        long = graph_title({"topology": {"name": "best-of-n"}, "goal": " ".join(["word"] * 30)})
        self.assertLessEqual(len(long.split()), 8)


# ------------------------------------------------------------------ engine words (walkthrough #6) ---

class TraceTitleTests(JevEngineBase):
    TOPO = {"name": "write-review", "start": "write", "nodes": [
        {"id": "write", "role": "builder", "task": "write it"}, {"id": "end", "role": "end"}],
        "edges": [{"from": "write", "to": "end"}]}

    def test_the_logs_title_is_the_one_the_graph_list_shows(self) -> None:
        from pong.graph_engine import graph_title
        from pong.graph_log import trace

        out = self.start(self.TOPO, task="Plan the bakery website refresh: hours, menu, photos.")
        gid = out["graph"]["id"] if "graph" in out else out["id"]
        t = trace(S, gid)
        self.assertEqual(t["title"], graph_title(self.g(gid)))
        self.assertNotEqual(t["title"], "write-review", "not its template's name")
        (Path(self.tmp.name) / "names.json").write_text(json.dumps(
            {"names": {f"graph:{S}/{gid}": {"name": "Bakery site refresh", "by": "model"}}}))
        self.assertEqual(trace(S, gid)["title"], "Bakery site refresh", "a name given to it wins, as in the list")


class ScreenTabWordsTests(unittest.TestCase):
    def test_no_screen_yet_in_plain_words(self) -> None:
        from pong.graph_engine import peek_seat

        with tempfile.TemporaryDirectory() as d:
            old = os.environ.get("PONG_HOME")
            os.environ["PONG_HOME"] = d
            try:
                r = peek_seat(S, "w9")
            finally:
                if old is None:
                    os.environ.pop("PONG_HOME", None)
                else:
                    os.environ["PONG_HOME"] = old
        self.assertEqual(r["note"], "This step has no screen to show yet.")
        for word in ("pane", "seat", "registered"):
            self.assertNotIn(word, r["note"])

    def test_open_in_terminal_says_why_in_plain_words(self) -> None:
        from pong.graph_engine import seat_view

        with tempfile.TemporaryDirectory() as d:
            old = os.environ.get("PONG_HOME")
            os.environ["PONG_HOME"] = d
            try:
                r = seat_view(S, "w9")
            finally:
                if old is None:
                    os.environ.pop("PONG_HOME", None)
                else:
                    os.environ["PONG_HOME"] = old
        self.assertFalse(r["ok"])
        self.assertEqual(r["note"], "There is no terminal to open yet.")
        for word in ("pane", "seat", "registered", "tmux"):
            self.assertNotIn(word, r["note"])


class JevNotAskedTests(JevEngineBase):
    TOPO = {"start": "build", "nodes": [
        {"id": "build", "role": "builder", "task": "build it"},
        {"id": "review", "role": "critic", "jev": {"rubric": [{"id": "thresholds", "text": "Every threshold names a number", "floor": 3}]}},
        {"id": "me", "role": "human"}, {"id": "end", "role": "end"}],
        "edges": [{"from": "build", "to": "review"}, {"from": "review", "to": "me", "on": "win"},
                  {"from": "review", "to": "build", "on": "fail"}, {"from": "me", "to": "end", "on": "approved"}]}

    def test_no_jev_line_when_jev_was_never_asked(self) -> None:
        from pong.graph_log import read
        from pong.jobs import record_claim
        from pong.work_graph import tick

        os.environ["PONG_JEV_DISABLED"] = "1"  # no key, nothing to ask
        try:
            out = self.start(self.TOPO)
            gid = out["graph"]["id"] if "graph" in out else out["id"]
            self.claim(gid, "build", "done — built", files=[str(self.doc)])
            record_claim(S, node(self.g(gid), "review")["job_id"], summary="win — looks good", files=[])
            for _ in range(80):
                tick(S)
                if node(self.g(gid), "review")["status"] in ("done", "failed"):
                    break
                time.sleep(0.1)
        finally:
            os.environ.pop("PONG_JEV_DISABLED", None)
        g = self.g(gid)
        self.assertEqual(node(g, "review")["last_outcome"], "win")
        review = [h for h in g.get("history") or [] if h.get("node") == "review"]
        self.assertTrue(any(h.get("event") == "claim" and h.get("outcome") == "win" for h in review))
        self.assertFalse([h for h in review if h.get("event") == "jev"], "no 'Jev · win' when Jev was not asked")
        self.assertTrue(any(r.get("kind") == "jev_not_asked" for r in read(S, gid)), "the graph's log still says so")


if __name__ == "__main__":
    unittest.main()
