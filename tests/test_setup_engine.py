#!/usr/bin/env python3
"""The engine side of first-run setup (2.0), each rule pinned by what it has to do.

- Settings are read, never written, by the engine: a missing or garbled file gives every default.
- A key typed into Settings lives in a 0600 file in a 0700 folder, comes first in the lookup, and is never
  printed: not by `keys set`, not by `keys status`, not as a prefix in `jev status`.
- `jev key test` makes one trivial call, says works / key refused / unreachable / no key, never touches the
  breaker, and is in the ledger as a key test.
- `pong doctor` answers what the setup sheet asks, without spending a token.
- The runner's launchd agent is written from the installed engine, and loaded or restarted as it should be.
- An AI switched off in Settings is never picked; the architect's AI follows the flag, then the saved
  default, then the lead policy; Hermes is refused in plain words.
- The playbook finds the graph kit on this Mac, and the developer part only shows on the owner's Mac.
- Seats find `pong` and their CLI, and start in auto mode when the person allowed it.
- The AIs call the person by the name they gave.
"""
from __future__ import annotations

import contextlib
import io
import json
import os
import plistlib
import stat
import sys
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "python"))

S = "pong-team"
KEY = "apikey_" + "Zq7" * 14  # fake: shaped like a TypeSafe key, used nowhere else


class _Home(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.home = Path(self.tmp.name)
        self._env = {k: os.environ.get(k) for k in ("PONG_HOME", "PONG_RUNTIMES", "PONG_SESSION", "PONG_SEAT",
                                                    "TYPESAFE_API_KEY", "PONG_JEV_FAKE", "PERPLEXITY_API_KEY",
                                                    "PONG_JEV_DISABLED", "PONG_NAMES", "PONG_NAMES_CMD", "HOME", "PATH")}
        os.environ["PONG_HOME"] = self.tmp.name
        for k in ("PONG_SEAT", "TYPESAFE_API_KEY", "PONG_JEV_FAKE", "PERPLEXITY_API_KEY", "PONG_JEV_DISABLED",
                  "PONG_NAMES", "PONG_NAMES_CMD", "PONG_RUNTIMES", "PONG_SESSION"):
            os.environ.pop(k, None)

    def tearDown(self) -> None:
        for k, v in self._env.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        self.tmp.cleanup()

    def settings(self, **kw) -> None:
        (self.home / "settings.json").write_text(json.dumps(kw))

    def cli(self, argv: list[str], stdin: str = "") -> tuple[int, str, str]:
        from pong.cli.main import main

        out, err = io.StringIO(), io.StringIO()
        old_in = sys.stdin
        sys.stdin = io.StringIO(stdin)
        try:
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                code = main(argv)
        finally:
            sys.stdin = old_in
        return code, out.getvalue(), err.getvalue()


# ------------------------------------------------------------------ settings ---

class SettingsTests(_Home):
    def test_a_missing_file_gives_every_default(self) -> None:
        from pong import settings as St

        self.assertEqual(St.load(), {})
        self.assertEqual(St.owner_name(), "the person")
        self.assertEqual(St.owner_name(capital=True), "The person")
        self.assertEqual(St.architect_default(), {"runtime": "", "model": ""})
        self.assertTrue(St.ai_enabled("claude"))
        self.assertEqual(St.limits(), {"ride_out_5h": True, "week_stop_pct": 97, "helper_ai": True, "jev": True,
                                       "perplexity": True, "perplexity_daily_usd": 15.0})
        self.assertEqual(St.seat_permissions(), "ask")
        self.assertFalse(St.developer())

    def test_a_garbled_file_never_stops_anything(self) -> None:
        from pong import settings as St

        for text in ("{not json", "[1, 2]", '"a string"', ""):
            (self.home / "settings.json").write_text(text)
            self.assertEqual(St.limits()["week_stop_pct"], 97, text)
            self.assertEqual(St.owner_name(), "the person", text)
        self.settings(owner_name=42, architect="claude", ai_enabled=["grok"], seat_permissions=True, developer="yes",
                      limits={"ride_out_5h": "maybe", "week_stop_pct": "lots", "perplexity_daily_usd": -5, "jev": 0})
        self.assertEqual(St.owner_name(), "the person")
        self.assertEqual(St.architect_default(), {"runtime": "", "model": ""})
        self.assertTrue(St.ai_enabled("grok"))
        self.assertEqual(St.seat_permissions(), "ask")
        self.assertFalse(St.developer(), "only a real true turns the developer part on")
        lim = St.limits()
        self.assertTrue(lim["ride_out_5h"])
        self.assertEqual(lim["week_stop_pct"], 97)
        self.assertEqual(lim["perplexity_daily_usd"], 0.0)
        self.assertFalse(lim["jev"])

    def test_values_the_app_wrote_are_read_and_clamped(self) -> None:
        from pong import settings as St

        self.settings(owner_name="  Sam\n `rm -rf`  Lee ", architect={"runtime": "Grok", "model": "grok-4.7"},
                      ai_enabled={"codex": False, "claude": True}, seat_permissions="auto", developer=True,
                      limits={"week_stop_pct": 150, "ride_out_5h": False, "perplexity_daily_usd": "7.5"})
        self.assertEqual(St.owner_name(), "Sam rm -rf Lee", "one plain line: no backticks, no newline")
        self.assertEqual(St.architect_default(), {"runtime": "grok", "model": "grok-4.7"})
        self.assertFalse(St.ai_enabled("codex"))
        self.assertFalse(St.ai_enabled("openai"), "the Guide's openai is Codex")
        self.assertEqual(St.disabled_runtimes(), {"codex"})
        self.assertEqual(St.seat_permissions(), "auto")
        self.assertTrue(St.developer())
        self.assertEqual(St.limits()["week_stop_pct"], 100)
        self.assertEqual(St.limits()["perplexity_daily_usd"], 7.5)
        self.assertFalse(St.limits()["ride_out_5h"])


# ------------------------------------------------------------------ keys ---

class KeyTests(_Home):
    def test_a_saved_key_is_0600_in_a_0700_folder_and_nothing_is_left_behind(self) -> None:
        from pong import settings as St

        p = St.write_key("jev", KEY)
        self.assertEqual(p, self.home / "secrets" / "jev.env")
        self.assertEqual(stat.S_IMODE(p.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(p.parent.stat().st_mode), 0o700)
        self.assertEqual(p.read_text(), f"TYPESAFE_API_KEY={KEY}\n")
        self.assertEqual(sorted(x.name for x in p.parent.iterdir()), ["jev.env"], "no temporary file is left")
        St.write_key("jev", KEY + "x")  # replaced in place, still 0600
        self.assertEqual(stat.S_IMODE(p.stat().st_mode), 0o600)
        with self.assertRaises(ValueError):
            St.write_key("jev", "two words here")
        with self.assertRaises(ValueError):
            St.write_key("other", KEY)

    def test_the_jev_key_is_looked_up_in_order(self) -> None:
        from pong import jev
        from pong import settings as St

        kf = self.home / "my.env"
        kf.write_text("export TYPESAFE_API_KEY='from-the-key-file-123'\n")
        (self.home / "jev.json").write_text(json.dumps({"key_file": str(kf), "allow_env_key": True}))
        self.assertEqual(jev.key_source()[:2], ("from-the-key-file-123", "key_file"))
        os.environ["TYPESAFE_API_KEY"] = "from-the-environment-123"
        self.assertEqual(jev.key_source()[:2], ("from-the-environment-123", "environment"))
        St.write_key("jev", KEY)
        self.assertEqual(jev.key_source()[:2], (KEY, "settings"), "the key typed into Settings comes first")
        self.assertTrue(St.clear_key("jev"))
        self.assertEqual(jev.key_source()[1], "environment")
        self.assertTrue(kf.exists(), "clearing never touches another key file")
        self.assertFalse(St.clear_key("jev"))
        os.environ["PONG_JEV_DISABLED"] = "1"
        self.assertEqual(jev.key_source()[0], "")

    def test_there_is_no_built_in_key_file_even_on_the_real_home(self) -> None:
        from pong import doctor, jev
        from pong import settings as St

        self.assertEqual(jev.KEY_SOURCES, ("settings", "environment", "key_file"))
        self.assertFalse(hasattr(jev, "DEFAULT_KEY_FILE"), "no one's own key file is built in")
        self.assertTrue(set(jev.KEY_SOURCES) <= set(doctor.KEY_SOURCE_WORDS), "every source has words")
        old = jev._real_home
        jev._real_home = lambda: True
        try:
            self.assertEqual(jev.key_source()[:2], ("", ""), "no Settings key, no env, no jev.json: no key")
            self.assertIsNone(jev._key_file())
            self.assertEqual(St.keys_status()["jev"], {"set": False, "source": "", "enabled": jev.enabled()})
            kf = self.home / "elsewhere.env"
            kf.write_text("TYPESAFE_API_KEY=from-the-named-file-123\n")
            (self.home / "jev.json").write_text(json.dumps({"key_file": str(kf)}))
            self.assertEqual(jev.key_source()[:2], ("from-the-named-file-123", "key_file"),
                             "a key file is used only when jev.json names it")
        finally:
            jev._real_home = old

    def test_status_never_shows_a_prefix(self) -> None:
        from pong import jev
        from pong import settings as St

        St.write_key("jev", KEY)
        st = jev.status()
        self.assertTrue(st["available"])
        self.assertEqual(st["source"], "settings")
        self.assertEqual(st["key_shape"], f"{len(KEY)} chars")
        self.assertNotIn("apikey", json.dumps(st))
        code, out, err = self.cli(["jev", "status"])
        self.assertEqual(code, 0)
        self.assertNotIn("apikey", out + err)
        self.assertNotIn(KEY, out + err)

    def test_keys_set_reads_stdin_and_never_prints_the_key(self) -> None:
        code, out, err = self.cli(["keys", "set", "--name", "perplexity"], stdin="pplx-" + "a1" * 20 + "\n")
        self.assertEqual(code, 0, err)
        self.assertNotIn("pplx-", out + err)
        self.assertEqual(stat.S_IMODE((self.home / "secrets" / "perplexity.env").stat().st_mode), 0o600)
        code, out, err = self.cli(["jev", "key", "set"], stdin=KEY)
        self.assertEqual(code, 0, err)
        self.assertNotIn(KEY, out + err)
        code, out, err = self.cli(["jev", "key", "set"], stdin="not a key")
        self.assertEqual(code, 2)
        self.assertNotIn("not a key", out + err)
        os.environ["PONG_SEAT"] = "w2"
        code, _out, err = self.cli(["keys", "set", "--name", "jev"], stdin=KEY)
        self.assertEqual(code, 2, "a seat never sets a key")
        os.environ.pop("PONG_SEAT")

    def test_keys_status_has_the_contracts_shape_and_no_length(self) -> None:
        from pong import settings as St

        St.write_key("jev", KEY)
        self.settings(limits={"perplexity": False})
        code, out, _err = self.cli(["keys", "status", "--json"])
        self.assertEqual(code, 0)
        st = json.loads(out)
        self.assertEqual(st, {"jev": {"set": True, "source": "settings", "enabled": True},
                              "perplexity": {"set": False, "source": "", "enabled": False}})
        self.assertNotIn(str(len(KEY)), out)
        code, out, _err = self.cli(["keys", "clear", "--name", "jev", "--json"])
        self.assertEqual(json.loads(out), {"ok": True, "name": "jev", "removed": True})

    def test_a_perplexity_key_from_settings_beats_the_environment(self) -> None:
        from pong import settings as St

        os.environ["PERPLEXITY_API_KEY"] = "pplx-from-the-environment-1"
        self.assertEqual(St.perplexity_key(), ("pplx-from-the-environment-1", "environment"))
        St.write_key("perplexity", "pplx-from-settings-000001")
        self.assertEqual(St.perplexity_key(), ("pplx-from-settings-000001", "settings"))

    def test_jev_switched_off_in_settings_is_not_asked(self) -> None:
        from pong import jev
        from pong import settings as St

        St.write_key("jev", KEY)
        self.assertTrue(jev.can_ask())
        self.settings(limits={"jev": False})
        self.assertFalse(jev.can_ask())
        self.assertFalse(jev.status()["available"])
        out = jev.ask({"x": 1}, {"q": {"type": "noul", "instructions": "x?", "criteria": {"true": "y", "false": "n"}}})
        self.assertFalse(out["ok"])
        self.assertEqual(out["error"], "Jev is turned off in Settings")


class KeyTestCallTests(_Home):
    def run_test(self, answer):
        from pong import jev

        calls = []

        def post(body, key, budget):
            calls.append((json.loads(body.decode()), budget))
            return answer

        return jev.key_test(post=post), calls

    def test_each_answer_in_plain_words(self) -> None:
        from pong import jev
        from pong import settings as St

        r, calls = self.run_test((200, {"answers": {}}, {}, 1, ""))
        self.assertEqual(r, {"ok": False, "result": "no key", "ms": 0})
        self.assertEqual(calls, [], "no key, no call")
        St.write_key("jev", KEY)
        r, calls = self.run_test((200, {"answers": {"key_test": {"noul": 0.99}}}, {}, 1, ""))
        self.assertEqual((r["ok"], r["result"]), (True, "works"))
        body = calls[0][0]
        self.assertEqual(set(body), {"state", "model", "questions"})
        self.assertNotIn("documents", json.dumps(body["state"]), "a trivial call: no documents")
        r, _ = self.run_test((401, "bad key " + KEY, {}, 1, "http"))
        self.assertEqual((r["ok"], r["result"], r["http"]), (False, "key refused", 401))
        r, _ = self.run_test((0, None, {}, 3, "URLError"))
        self.assertEqual(r["result"], "unreachable")
        r, _ = self.run_test((503, None, {}, 3, "http"))
        self.assertEqual(r["result"], "unreachable")
        self.assertEqual(jev._breaker_open(), 0.0)
        self.assertFalse(jev._breaker_path().exists(), "a key test never counts toward the breaker")
        recs = [r for r in jev.read_ledger() if r.get("kind") == "call"]
        self.assertEqual({r["purpose"] for r in recs}, {"key_test"})
        self.assertNotIn(KEY, jev.ledger_path().read_text(), "not even inside an error")

    def test_the_cli_answers_in_json(self) -> None:
        code, out, _ = self.cli(["jev", "key", "test", "--json"])
        self.assertEqual(code, 0)
        self.assertEqual(json.loads(out), {"ok": False, "result": "no key", "ms": 0})


# ------------------------------------------------------------------ doctor ---

class DoctorTests(_Home):
    def setUp(self) -> None:
        super().setUp()
        self.fake_home = self.home / "user"
        self.bin = self.home / "fakebin"
        self.bin.mkdir()
        (self.fake_home / "bin").mkdir(parents=True)
        os.environ["HOME"] = str(self.fake_home)
        os.environ["PATH"] = str(self.bin) + ":/usr/bin:/bin"

    def tool(self, name: str, body: str = "exit 0") -> None:
        p = self.bin / name
        p.write_text("#!/bin/sh\n" + body + "\n")
        p.chmod(0o755)

    def test_the_answer_the_setup_sheet_reads(self) -> None:
        from pong import doctor

        self.tool("tmux")
        self.tool("claude", 'if [ "$1 $2 $3" = "auth status --json" ]; then '
                            'echo \'{"loggedIn": true, "subscriptionType": "max", "email": "someone@example.com"}\'; fi')
        self.tool("grok")
        (self.fake_home / ".grok").mkdir()
        (self.fake_home / ".grok" / "auth.json").write_text('{"x": 1}')
        launcher = self.fake_home / "bin" / "pong"
        launcher.write_text("#!/bin/sh\n")
        launcher.chmod(0o755)
        self.settings(owner_name="Sam", ai_enabled={"grok": False}, seat_permissions="auto")
        t0 = time.time()
        d = doctor.check()
        self.assertLess(time.time() - t0, 3.0)
        self.assertEqual(set(d), {"version", "python", "tmux", "brew", "launcher", "engine", "runner", "ais", "keys", "settings"})
        self.assertEqual(d["version"], __import__("pong").__version__)
        self.assertTrue(d["python"]["ok"])
        self.assertEqual((d["tmux"]["ok"], d["tmux"]["fix"]), (True, "brew install tmux"))
        self.assertEqual(d["launcher"], {"ok": True, "path": "~/bin/pong"})
        self.assertFalse(d["engine"]["ok"])
        self.assertEqual(d["runner"], {"ok": False, "installed": False, "running": False, "last_beat_s": None})
        c = d["ais"]["claude"]
        self.assertEqual((c["installed"], c["signed_in"], c["plan"], c["enabled"]), (True, True, "max", True))
        self.assertEqual(c["login"], "claude auth login")
        self.assertIn("claude", c["install"])
        g = d["ais"]["grok"]
        self.assertEqual((g["installed"], g["signed_in"], g["enabled"], g["login"]), (True, True, False, "grok login"))
        self.assertIsNone(d["ais"]["hermes"]["signed_in"], "no cheap way to tell: null")
        for row in d["ais"].values():
            self.assertTrue({"label", "installed", "signed_in", "enabled", "login", "install"} <= set(row))
        self.assertEqual(d["keys"], {"jev": {"set": False, "source": "", "enabled": True},
                                     "perplexity": {"set": False, "source": "", "enabled": True}})
        self.assertEqual(d["settings"]["owner_name"], "Sam")
        self.assertEqual(d["settings"]["seat_permissions"], "auto")
        self.assertNotIn("someone@example.com", json.dumps(d), "only loggedIn and the plan are kept")
        lines = "\n".join(doctor.format_text(d))
        self.assertIn("Claude Code: signed in · Max plan", lines)
        self.assertIn("Graph runner: not installed", lines)
        # No engine yet: install-agent would refuse, so the runner line says to get the engine in place first.
        self.assertIn("open CyberPong first so the engine is in place, then turn the runner on: pong runtime install-agent",
                      lines)
        d["engine"]["ok"] = True
        lines = "\n".join(doctor.format_text(d))
        self.assertIn("graphs stop after their first step. Fix: pong runtime install-agent", lines)
        self.assertNotIn("open CyberPong first", lines)

    def test_a_signed_out_claude_and_a_missing_tmux(self) -> None:
        from pong import doctor

        self.tool("claude", 'echo \'{"loggedIn": false}\'')
        d = doctor.check()
        self.assertEqual(d["ais"]["claude"]["signed_in"], False)
        if not d["tmux"]["ok"]:  # tmux may also live in /opt/homebrew/bin on the Mac running the tests
            self.assertIn("brew install tmux", "\n".join(doctor.format_text(d)))
        self.assertFalse(doctor.essentials_ok(d))

    def test_the_cli(self) -> None:
        code, out, _ = self.cli(["doctor", "--json"])
        self.assertEqual(code, 0)
        self.assertIn("ais", json.loads(out))


# ------------------------------------------------------------------ the runner's agent ---

class InstallAgentTests(_Home):
    def setUp(self) -> None:
        super().setUp()
        self.agents = self.home / "LaunchAgents"
        self.calls: list[list[str]] = []
        self.loaded = False
        engine = self.home / "lib" / "pong" / "cli"  # the engine the runner starts (python -m pong.cli.main)
        engine.mkdir(parents=True)
        (engine / "main.py").write_text("")

    def launchctl(self, args: list[str]) -> tuple[int, str]:
        self.calls.append(args)
        verb = args[0]
        if verb == "print":
            return (0 if self.loaded else 113), ""
        if verb in ("bootstrap", "load"):
            self.loaded = True
        if verb == "bootout":
            self.loaded = False
        return 0, ""

    def test_writes_the_plist_and_loads_it(self) -> None:
        from pong import runtime as R

        r = R.install_agent(launchctl=self.launchctl, base=self.agents, python="/opt/homebrew/bin/python3")
        self.assertEqual(r["ok"], True)
        self.assertEqual(r["loaded"], True)
        p = self.agents / "com.cyberpong.runtime.plist"
        self.assertEqual(r["plist"], str(p))
        d = plistlib.loads(p.read_bytes())
        self.assertEqual(d["Label"], "com.cyberpong.runtime")
        self.assertEqual(d["ProgramArguments"], ["/opt/homebrew/bin/python3", "-m", "pong.cli.main", "runtime", "run",
                                                 "--interval", "30", "--no-cron"])
        env = d["EnvironmentVariables"]
        self.assertEqual(env["PYTHONPATH"], str(self.home / "lib"))
        self.assertEqual(env["PONG_HOME"], str(self.home))
        self.assertIn("/opt/homebrew/bin", env["PATH"])
        self.assertTrue(d["RunAtLoad"] and d["KeepAlive"])
        self.assertEqual(d["StandardOutPath"], str(self.home / "logs" / "runtime.log"))
        self.assertEqual([c[0] for c in self.calls], ["print", "bootstrap", "print"])
        self.assertTrue(self.calls[1][1].startswith("gui/"))

    def test_a_loaded_runner_is_restarted_and_a_changed_one_reloaded(self) -> None:
        from pong import runtime as R

        R.install_agent(launchctl=self.launchctl, base=self.agents, python="/x/python3")
        self.calls.clear()
        R.install_agent(launchctl=self.launchctl, base=self.agents, python="/x/python3")
        self.assertEqual([c[0] for c in self.calls], ["print", "kickstart", "print"])
        self.assertIn("-k", self.calls[1])
        self.calls.clear()
        R.install_agent(launchctl=self.launchctl, base=self.agents, python="/y/python3")
        self.assertEqual([c[0] for c in self.calls], ["print", "bootout", "bootstrap", "print"],
                         "launchd keeps the definition it loaded: a changed plist is loaded again")

    def test_a_bootstrap_too_soon_after_bootout_is_tried_again(self) -> None:
        from pong import runtime as R

        R.install_agent(launchctl=self.launchctl, base=self.agents, python="/x/python3")
        fails = {"left": 2}
        real = self.launchctl

        def slow_launchd(args: list[str]) -> tuple[int, str]:
            if args[0] == "bootstrap" and fails["left"]:
                fails["left"] -= 1
                self.calls.append(args)
                return 5, "Bootstrap failed: 5: Input/output error"
            return real(args)

        waits: list[float] = []
        self.calls.clear()
        r = R.install_agent(launchctl=slow_launchd, base=self.agents, python="/y/python3", wait=waits.append)
        self.assertTrue(r["ok"] and r["loaded"])
        self.assertEqual([c[0] for c in self.calls], ["print", "bootout", "bootstrap", "bootstrap", "bootstrap", "print"])
        self.assertEqual(waits, [1.0, 1.0])

    def test_apples_stub_is_never_the_runners_python(self) -> None:
        from pong import runtime as R

        fake_bin = self.home / "fakebin"
        fake_bin.mkdir()
        py = fake_bin / "python3"
        py.write_text("#!/bin/sh\n")
        py.chmod(0o755)
        os.environ["PATH"] = str(fake_bin)
        old = sys.executable
        try:
            sys.executable = R.XCODE_STUB
            self.assertEqual(R.runner_python(), str(py), "a real python3 on the search path instead of the stub")
            sys.executable = str(py)
            self.assertEqual(R.runner_python(), str(py))
        finally:
            sys.executable = old
        self.assertTrue(os.path.isabs(R.runner_python()))

    def test_a_stable_link_to_the_same_python_is_found_behind_another(self) -> None:
        from pong import runtime as R

        cellar = self.home / "Cellar" / "python@3.x" / "bin"
        cellar.mkdir(parents=True)
        real = cellar / "python3.x"
        real.write_text("#!/bin/sh\n")
        real.chmod(0o755)
        first, linked = self.home / "first", self.home / "linked"
        first.mkdir()
        linked.mkdir()
        (first / "python3").write_text("#!/bin/sh\n")
        (first / "python3").chmod(0o755)
        os.symlink(real, linked / "python3")
        os.environ["PATH"] = f"{first}:{linked}"
        old = sys.executable
        try:
            sys.executable = str(real)
            self.assertEqual(R.runner_python(), str(linked / "python3"),
                             "the link that survives an upgrade, even when another python3 comes first")
        finally:
            sys.executable = old

    def test_no_engine_means_no_runner_and_launchd_is_left_alone(self) -> None:
        import shutil

        from pong import runtime as R

        shutil.rmtree(self.home / "lib")
        r = R.install_agent(launchctl=self.launchctl, base=self.agents, python="/x/python3")
        self.assertEqual((r["ok"], r["loaded"], r["reason"]), (False, False, "no_engine"))
        self.assertIn("isn't installed", r["error"])
        self.assertEqual(self.calls, [], "launchd would start it every few seconds, failing each time")
        self.assertFalse((self.agents / "com.cyberpong.runtime.plist").exists())
        self.assertIn("plist", r, "the text answer names it")

    def recorder(self):
        from pong import runtime as R

        old = R._launchctl
        R._launchctl = self.launchctl
        self.addCleanup(setattr, R, "_launchctl", old)

    def test_a_throwaway_pong_home_never_touches_the_macs_runner(self) -> None:
        from pong import runtime as R

        self.recorder()
        user = self.home / "user"
        os.environ["HOME"] = str(user)  # PONG_HOME is a temporary folder, not ~/.pong
        r = R.install_agent()
        self.assertEqual((r["ok"], r["reason"]), (False, "not_this_home"))
        self.assertEqual(self.calls, [], "one runner per Mac, under one label: never booted out from a preview")
        self.assertFalse(R.plist_path().exists())
        r = R.install_agent(base=self.agents)  # a plist folder of its own, but the real launchctl and its one label
        self.assertEqual((r["ok"], r["reason"], self.calls), (False, "not_this_home", []))
        self.assertFalse((self.agents / "com.cyberpong.runtime.plist").exists())
        code, out, _ = self.cli(["runtime", "install-agent", "--json"])
        self.assertEqual((code, json.loads(out)["ok"]), (0, False))
        code, _, err = self.cli(["runtime", "install-agent"])
        self.assertEqual(code, 1)
        self.assertIn("left alone", err)
        self.assertEqual(self.calls, [])

    def test_a_throwaway_home_folder_never_touches_the_macs_runner(self) -> None:
        from pong import runtime as R

        self.recorder()
        os.environ.pop("PONG_HOME", None)
        os.environ["HOME"] = str(self.home / "user")  # ~/.pong in a home folder that is not the account's own
        r = R.install_agent()
        self.assertEqual((r["ok"], r["reason"]), (False, "not_this_home"))
        self.assertEqual(self.calls, [])

    def test_status_keeps_its_shape(self) -> None:
        code, out, _ = self.cli(["runtime", "status", "--json"])
        self.assertEqual(code, 0)
        st = json.loads(out)
        self.assertIn("runner_ok", st)
        self.assertIn("label", st)


# ------------------------------------------------------------------ routing and the architect ---

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
        pair = {"schema_version": 2, "project_root": str(self.project),
                "conductor": {"id": "c1", "type": "claude", "label": "lead", "cmd": "claude", "mode": "tmux", "tmux_index": 0},
                "workers": [], "transport_default": "job", "flow_graph": {"edges": []}}
        write_json(pairs_path(), {S: pair})
        write_json(active_path(), {**pair, "session": S})
        ensure_session_token(S)
        from pong import architect as A

        self.A = A


class RoutingTests(_Team):
    def test_an_ai_switched_off_is_never_available_or_picked(self) -> None:
        from pong import models as M
        from pong.wiring import plan_node

        self.settings(ai_enabled={"grok": False})
        self.assertNotIn("grok", M.available_runtimes())
        p = plan_node("researcher", "scout the open web", pin="grok")
        self.assertNotEqual(p["runtime"], "grok")
        self.assertEqual(p["rejected"]["grok"], "switched off in Settings")
        os.environ["PONG_RUNTIMES"] = "grok"
        self.assertEqual(M.available_runtimes(), set())
        self.assertNotEqual(plan_node("coder", "fix it")["runtime"], "grok",
                            "nothing else installed still never means the AI the person switched off")

    def test_a_refused_pin_drops_the_model_that_belonged_to_it(self) -> None:
        from pong.composer import new_team

        os.environ["PONG_RUNTIMES"] = "claude"
        pair = new_team({"title": "t", "goal": "plan the work", "team": {"project_root": str(self.project)},
                         "pins": {"lead": "grok"}, "lead_model": "grok-4.7"}, session="pong-team-9")
        self.assertEqual(pair["conductor"]["type"], "claude")
        self.assertNotEqual(pair["conductor"]["model"], "grok-4.7")


class ArchitectChoiceTests(_Team):
    def test_flag_then_saved_default_then_policy(self) -> None:
        A = self.A
        c = A.choose_runtime()
        self.assertEqual((c["runtime"], c["effective"], c["source"]), (None, "claude", "policy"))
        self.settings(architect={"runtime": "grok", "model": "grok-4.7"})
        c = A.choose_runtime()
        self.assertEqual((c["runtime"], c["model"], c["source"]), ("grok", "grok-4.7", "settings"))
        c = A.choose_runtime("claude")
        self.assertEqual((c["runtime"], c["model"], c["source"]), ("claude", None, "you"),
                         "the saved model belongs to the saved AI, not to the one passed")
        c = A.choose_runtime(None, "opus")
        self.assertEqual((c["runtime"], c["model"]), ("claude", "opus"), "--model opus alone means Claude's Opus")
        self.settings(architect={"runtime": "claude", "model": "fable"})
        self.assertEqual(A.choose_runtime("claude")["model"], "fable")

    def test_what_cannot_run_an_architect_is_refused_in_plain_words(self) -> None:
        A = self.A
        with self.assertRaises(A.ArchitectError) as e:
            A.choose_runtime("hermes")
        self.assertIn("Hermes can't plan graphs", str(e.exception))
        self.settings(architect={"runtime": "hermes"})
        c = A.choose_runtime()
        self.assertEqual((c["runtime"], c["effective"], c["source"]), (None, "claude", "policy"),
                         "a saved default that cannot run is passed over, not a wall")
        self.assertIn("can't plan graphs yet", c["note"])
        self.settings(architect={"runtime": "codex", "model": "gpt-5.1-codex"}, ai_enabled={"codex": False})
        c = A.choose_runtime()
        self.assertEqual((c["effective"], c["model"]), ("claude", None))
        self.assertIn("switched off in Settings", c["note"])
        self.settings(ai_enabled={"codex": False})
        with self.assertRaises(A.ArchitectError) as e:
            A.choose_runtime("codex")
        self.assertIn("switched off in Settings", str(e.exception))
        os.environ["PONG_RUNTIMES"] = "claude"
        with self.assertRaises(A.ArchitectError) as e:
            A.choose_runtime("grok")
        self.assertIn("isn't installed", str(e.exception))
        os.environ["PONG_RUNTIMES"] = ","  # pinned to nothing installed
        with self.assertRaises(A.ArchitectError) as e:
            A.choose_runtime()
        self.assertIn("Install Claude Code first", str(e.exception))
        os.environ["PONG_RUNTIMES"] = "hermes"  # Hermes alone: say what to install, not "pick Claude"
        with self.assertRaises(A.ArchitectError) as e:
            A.choose_runtime()
        self.assertIn("Install Claude Code", str(e.exception))
        self.assertNotIn("Pick Claude", str(e.exception))

    def test_no_tmux_means_no_chat_and_nothing_created(self) -> None:
        from pong import groups
        from pong.state import load_pairs_db

        A = self.A
        before = set(load_pairs_db())
        old = (groups.isolated_home, A._tmux_path)
        groups.isolated_home = lambda: False
        A._tmux_path = lambda: None
        try:
            with self.assertRaises(A.ArchitectError) as e:
                A.new("Intake app", str(self.project))
            self.assertIn("tmux isn't installed", str(e.exception))
            with self.assertRaises(A.ArchitectError):
                A.start(S, "next round", cwd=str(self.project))
        finally:
            groups.isolated_home, A._tmux_path = old
        self.assertEqual(set(load_pairs_db()), before, "no team is made for a chat that cannot start")

    def test_new_follows_the_saved_default_and_says_whether_the_chat_started(self) -> None:
        self.settings(architect={"runtime": "grok", "model": "grok-4.7"})
        r = self.A.new("Intake app", str(self.project))
        self.assertTrue(r["ok"])
        self.assertEqual((r["runtime"], r["model"]), ("grok", "grok-4.7"))
        self.assertFalse(r["started"], "a temporary home starts no terminal")
        self.assertIn("isolated", r["spawn_note"])
        self.assertEqual(r["chosen_by"], "settings")

    def test_start_has_no_hard_coded_claude(self) -> None:
        from pong import groups

        self.settings(architect={"runtime": "grok"})
        seen = {}
        orig = groups.ensure_ephemeral_window
        groups.ensure_ephemeral_window = lambda state, worker, **kw: seen.update(worker) or {"note": "stub"}
        try:
            r = self.A.start(S, "next round", cwd=str(self.project))
        finally:
            groups.ensure_ephemeral_window = orig
        self.assertEqual(seen["type"], "grok")
        self.assertTrue(r["ok"])
        self.assertFalse(r["started"])

    def test_the_cli_answers_a_refusal_in_json(self) -> None:
        code, out, err = self.cli(["architect", "new", "--title", "x", "--project", str(self.project),
                                   "--runtime", "hermes", "--json"])
        self.assertEqual(code, 0)
        r = json.loads(out)
        self.assertEqual(r["ok"], False)
        self.assertIn("Hermes", r["error"])
        code, out, err = self.cli(["architect", "new", "--title", "x", "--project", str(self.project), "--json"])
        self.assertEqual(code, 0, err)
        r = json.loads(out)
        self.assertTrue(r["ok"])
        self.assertIn("spawn_note", r)


class PlaybookTests(_Team):
    def test_the_kit_is_filled_in_and_the_owners_paths_are_gone(self) -> None:
        A = self.A
        raw = A.PLAYBOOK.read_text() + A.PLAYBOOK_DEV.read_text()
        # the checkout's parent folder as a path prefix (a bare "/Applications" would match the dev
        # playbook's prose when the checkout sits there), and any home folder at all
        for word in (str(ROOT.parent).rstrip("/") + "/", "/Users/", "kulpio", "~/.pong/lib", "HermesPong"):
            self.assertNotIn(word, raw, "the shipped playbook names no one's folders or accounts")
        text = A.playbook_text()
        self.assertNotIn("{KIT}", text)
        self.assertIn("scripts/graph-kit/pplx.py", text, "a checkout's kit when nothing is installed")
        kit = self.home / "lib" / "graph-kit"
        kit.mkdir(parents=True)
        (kit / "dryrun.py").write_text("")
        self.assertEqual(A.kit_dir(), kit)
        self.assertIn(f"{A._tilde(kit)}/dryrun.py", A.playbook_text())
        self.assertIn("pong keys status --json", text)
        r = A.new("Intake app", str(self.project))
        prompt = Path(A.get(r["session"], r["id"])["prompt_path"]).read_text()
        self.assertNotIn("{KIT}", prompt)

    def test_the_developer_part_shows_only_on_the_owners_mac(self) -> None:
        A = self.A
        self.assertNotIn("Fixing CyberPong itself", A.playbook_text())
        self.settings(developer=True)
        text = A.playbook_text()
        self.assertIn("## 8. Fixing CyberPong itself", text)
        self.assertNotIn("{REPO}", text)
        self.assertIn("python3 -m unittest discover", text)


# ------------------------------------------------------------------ seats ---

class LaunchTests(_Home):
    def line(self, rt: str, cmd: str = "") -> str:
        from pong.groups import _launch_command

        return _launch_command({"session": S}, {"id": "c1.a", "type": rt, "cmd": cmd or rt}, initial_prompt="go")

    def test_every_seat_finds_pong_and_its_cli(self) -> None:
        for rt in ("claude", "grok", "codex", "hermes"):
            first = self.line(rt).split("; ")[0]
            # the usual five first; then any folder a CLI was found in on this Mac (nvm, volta, …), then PATH
            self.assertTrue(first.startswith('export PATH="$HOME/bin:$HOME/.local/bin:$HOME/.grok/bin:/opt/homebrew/bin:'
                                             '/usr/local/bin:'), rt)
            self.assertTrue(first.endswith(':$PATH"'), rt)

    def test_auto_mode_only_when_the_person_allowed_it(self) -> None:
        for rt in ("claude", "grok"):
            self.assertNotIn("--permission-mode", self.line(rt), "absent means ask: today's behaviour")
        self.settings(seat_permissions="auto")
        for rt in ("claude", "grok"):
            self.assertIn("--permission-mode auto", self.line(rt), rt)
        for rt in ("codex", "hermes"):
            self.assertNotIn("--permission-mode", self.line(rt), rt)
        self.assertNotIn("--permission-mode auto", self.line("claude", "claude --dangerously-skip-permissions"))
        self.assertNotIn("--permission-mode auto", self.line("grok", "grok --always-approve"))
        self.assertEqual(self.line("claude", "claude --permission-mode plan").count("--permission-mode"), 1)
        self.settings(seat_permissions="ask")
        self.assertNotIn("--permission-mode", self.line("claude"))


# ------------------------------------------------------------------ the person's name ---

class OwnerNameTests(_Home):
    def test_asks_cron_and_claims_use_the_name_given(self) -> None:
        from pong import architect as A
        from pong import asks as Q
        from pong.cron import draft_only_task
        from pong.jobs import build_task_prompt
        from pong.paths import ensure_layout

        ensure_layout(S)
        with A._locked(S) as data:
            data["architects"].append({"id": "a_1", "seat": "c1.arch", "title": "t", "graphs": [], "queue": [],
                                       "created_at": time.time()})
        orig = A._capture
        A._capture = lambda session, seat, lines=80: None  # no tmux: the answer waits in the chat's queue
        try:
            r = Q.new(S, "Start round 3 now?", options=[Q.parse_option("Start::go"), Q.parse_option("Wait::later")],
                      seat="c1.arch")
            Q.answer(S, r["id"], choice="1")
            self.assertEqual(Q.get(S, r["id"])["answer"]["by"], "The person")
            self.assertTrue(A.get(S, "a_1")["queue"][-1]["text"].startswith("The person answered your question"))
            self.settings(owner_name="Sam")
            r2 = Q.new(S, "Send it?", options=[Q.parse_option("Yes::send"), Q.parse_option("No::hold")], seat="c1.arch")
            rec = Q.answer(S, r2["id"], choice="2", note="not yet")
            self.assertEqual(rec["answer"]["by"], "Sam")
            text = A.get(S, "a_1")["queue"][-1]["text"]
            self.assertTrue(text.startswith("Sam answered your question"), text)
            self.assertIn("Sam's note: not yet", text)
            self.assertEqual(Q.answer(S, Q.new(S, "Why?", seat="c1.arch")["id"], note="because", who="Alex")["answer"]["by"],
                             "Alex", "a name passed in wins")
        finally:
            A._capture = orig
        self.assertIn("put it where Sam can see it", draft_only_task({"name": "x"}, "send the mail"))
        prompt = build_task_prompt({"id": "job_x", "session": S, "worker": "w1", "task": "do it", "require_claim": True},
                                   {"session": S, "conductor": {"id": "c1"}, "workers": []})
        self.assertIn("Do not message Sam instead of claiming", prompt)
        self.settings()
        self.assertIn("put it where the person can see it", draft_only_task({"name": "x"}, "send the mail"))

    def test_naming_respects_the_helper_ai_switch(self) -> None:
        from pong import names

        os.environ["PONG_NAMES_CMD"] = "/bin/echo"
        self.assertTrue(names.enabled())
        self.settings(limits={"helper_ai": False})
        self.assertFalse(names.enabled())
        self.settings(ai_enabled={"claude": False})
        self.assertFalse(names.enabled())  # the names come from Claude Haiku
        self.settings(ai_enabled={"grok": False})
        self.assertTrue(names.enabled())


if __name__ == "__main__":
    unittest.main()
