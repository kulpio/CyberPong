"""Headless runtime — cron ticks + drain even when the panel is quit.

launchd: ``pong runtime install-agent`` (or ``scripts/install-cron-agent.sh`` from a checkout) →
``~/Library/LaunchAgents/com.cyberpong.runtime.plist``. Each pass also runs the limits tick
(:mod:`pong.limits`): Claude's usage limits, handled by the switches in Settings.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
import time
from pathlib import Path
from typing import Any, Callable
from xml.sax.saxutils import escape

from .cron import status as cron_status
from .cron import tick as cron_tick
from .paths import state_dir

DEFAULT_INTERVAL_SEC = 30.0
PLIST_LABEL = "com.cyberpong.runtime"
#: /usr/bin/python3 without Apple's command line tools is a stub that opens an install dialog;
#: under launchd nobody sees the dialog and the runner never starts.
XCODE_STUB = "/usr/bin/python3"


def heartbeat(ok: bool = True) -> None:
    from .cron import load_run_state, save_run_state

    st = load_run_state()
    st["runner_ok"] = bool(ok)
    st["last_tick_at"] = time.time()
    # the same moment on the clock that stops while the Mac sleeps: a beat from before a sleep is not stale
    # (cron.beat_age)
    st["awake_at"] = time.monotonic()
    st["pid"] = os.getpid()
    save_run_state(st)


#: The last failure of the limits pass the log told, and when: the same one is told again only hourly.
_LIMITS_FAIL: dict[str, Any] = {}


def _limits_pass(session: str | None) -> None:
    """Claude's usage limits (pause at the 5-hour limit, stop near the weekly one). Never fails a pass.

    A failure that repeats every pass is written to the log once an hour, not twice a minute."""
    try:
        from .limits import tick as limits_tick

        limits_tick(session)
        _LIMITS_FAIL.clear()
    except Exception as e:
        import traceback

        what = f"{type(e).__name__}: {e}"
        if _LIMITS_FAIL.get("what") == what and time.time() - float(_LIMITS_FAIL.get("at") or 0) < 3600:
            return
        _LIMITS_FAIL.update(what=what, at=time.time())
        sys.stderr.write(time.strftime("%Y-%m-%d %H:%M:%S ") + f"limits pass failed: {what}\n")
        traceback.print_exc(file=sys.stderr)
        sys.stderr.flush()


def run(
    *,
    session: str | None = None,
    interval: float = DEFAULT_INTERVAL_SEC,
    loops: int | None = None,
    cron: bool = True,
) -> None:
    """Watch loop.

    ``cron=True`` fires due schedules and then drains (goal ticks, waitroom,
    harvest, snapshot). ``cron=False`` only drains: loops still advance and
    mailboxes still fill, but no schedule row creates a job. That is the
    installed default — a runner that starts firing hourly scouting jobs the
    moment it is bootstrapped is a surprise, not a service. Flip it with
    ``CRON=1 pong runtime install-agent`` once the rows are reviewed.
    Each pass ends with the limits tick, which is cheap when no graph runs.
    """
    n = 0
    while True:
        try:
            if cron:
                cron_tick(session)
            else:
                from .drain import run_all

                run_all(session, write_snap=True)
            heartbeat(True)
        except Exception as e:
            import traceback

            sys.stderr.write(time.strftime("%Y-%m-%d %H:%M:%S ") + f"runner pass failed: {type(e).__name__}: {e}\n")
            traceback.print_exc(file=sys.stderr)
            sys.stderr.flush()
            heartbeat(False)
        _limits_pass(session)
        n += 1
        if loops is not None and n >= loops:
            return
        time.sleep(max(1.0, float(interval)))


def agents_dir() -> Path:
    return Path.home() / "Library" / "LaunchAgents"


def plist_path(base: Path | None = None) -> Path:
    return (base or agents_dir()) / f"{PLIST_LABEL}.plist"


def status() -> dict[str, Any]:
    st = cron_status()
    st["label"] = PLIST_LABEL
    st["state_dir"] = str(state_dir())
    p = plist_path()
    st["plist"] = str(p)
    st["installed"] = p.is_file()
    return st


def install_agent_script() -> Path:
    """Repo script that writes the launchd plist (a checkout only; ``install_agent`` needs none)."""
    here = Path(__file__).resolve()
    # python/pong/runtime.py → repo root
    return here.parents[2] / "scripts" / "install-cron-agent.sh"


# ------------------------------------------------------------ the launchd agent ---

def runner_python() -> str:
    """The interpreter the runner starts with: this one, unless it is Apple's ``/usr/bin/python3`` stub.

    When a stable ``python3`` on the search path is the same interpreter (Homebrew's
    ``/opt/homebrew/bin/python3`` for ``…/Cellar/python@3.x/…``), that name is used instead, so a
    Homebrew upgrade does not leave the agent pointing at a folder that is gone."""
    from .models import search_path

    exe = sys.executable or ""
    # every python3 on the search path, in order: a bare PATH lists /usr/bin before Homebrew, and the
    # first one alone would hide Homebrew's stable link
    cands: list[str] = []
    for d in search_path().split(os.pathsep):
        c = shutil.which("python3", path=d) if d else None
        if c and c not in cands:
            cands.append(c)
    if not exe or exe == XCODE_STUB or os.path.realpath(exe) == XCODE_STUB:
        for c in cands:
            if c != XCODE_STUB:
                return c
        return exe or XCODE_STUB
    for c in cands:
        try:
            if c != XCODE_STUB and os.path.realpath(c) == os.path.realpath(exe):
                return c
        except OSError:
            continue
    return exe


def runner_path_env() -> str:
    """The PATH the runner gets: tmux's own folder, the CLIs' folders, Homebrew, ~/bin, then the system.
    launchd starts agents with a bare PATH, so a runner without this could tick a graph but never find
    tmux to start a seat.

    The CLIs' folders include the ones a Node or package manager installs into (nvm's node versions,
    volta, bun, an npm prefix, pnpm, Claude Code's local install, mise and asdf: ``models.cli_dirs``): an
    AI CLI installed with ``npm install -g`` starts with ``#!/usr/bin/env node``, and the runner's own
    calls to it (the usage check, a seat's window) only find that node when its folder is on PATH."""
    from .models import cli_dirs, find_binary

    home = str(Path.home())
    tmux = find_binary("tmux") or "/opt/homebrew/bin/tmux"
    try:
        extra = cli_dirs()
    except Exception:  # a folder that can't be listed never stops the runner being installed
        extra = []
    dirs: list[str] = []
    for d in [os.path.dirname(tmux), f"{home}/.local/bin", f"{home}/.grok/bin", "/opt/homebrew/bin",
              "/usr/local/bin", f"{home}/bin", *extra, "/usr/bin", "/bin", "/usr/sbin", "/sbin"]:
        if d and d not in dirs and ":" not in d and "\n" not in d:
            dirs.append(d)
    return ":".join(dirs)


def plist_text(*, python: str | None = None, interval: int | None = None, cron: bool | None = None,
               path_env: str | None = None) -> str:
    """The agent's plist: the same content ``scripts/install-cron-agent.sh`` writes, with the installed
    engine (``<pong home>/lib``) on PYTHONPATH."""
    home = state_dir()
    py = python or runner_python()
    iv = int(interval if interval is not None else (os.environ.get("INTERVAL") or DEFAULT_INTERVAL_SEC))
    with_cron = (os.environ.get("CRON") == "1") if cron is None else bool(cron)
    args = [py, "-m", "pong.cli.main", "runtime", "run", "--interval", str(iv)] + ([] if with_cron else ["--no-cron"])
    log = home / "logs" / "runtime.log"
    env = {"PYTHONPATH": str(home / "lib"), "PONG_HOME": str(home), "PATH": path_env or runner_path_env()}
    lines = [
        '<?xml version="1.0" encoding="UTF-8"?>',
        '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">',
        '<plist version="1.0">',
        "<dict>",
        "  <key>Label</key>",
        f"  <string>{PLIST_LABEL}</string>",
        "  <key>ProgramArguments</key>",
        "  <array>",
        *[f"    <string>{escape(a)}</string>" for a in args],
        "  </array>",
        "  <key>EnvironmentVariables</key>",
        "  <dict>",
        *[f"    <key>{k}</key>\n    <string>{escape(v)}</string>" for k, v in env.items()],
        "  </dict>",
        "  <key>RunAtLoad</key>",
        "  <true/>",
        "  <key>KeepAlive</key>",
        "  <true/>",
        "  <key>StartInterval</key>",
        f"  <integer>{iv}</integer>",
        "  <key>StandardOutPath</key>",
        f"  <string>{escape(str(log))}</string>",
        "  <key>StandardErrorPath</key>",
        f"  <string>{escape(str(log))}</string>",
        "</dict>",
        "</plist>",
    ]
    return "\n".join(lines) + "\n"


def _launchctl(args: list[str]) -> tuple[int, str]:
    try:
        r = subprocess.run(["launchctl", *args], capture_output=True, text=True, timeout=30)
        return r.returncode, ((r.stdout or "") + (r.stderr or "")).strip()
    except Exception as e:  # no launchctl (not a Mac), or it hung
        return 127, str(e)


def _own_home() -> bool:
    """This process works on the Mac's own CyberPong: ``PONG_HOME`` is unset or ``~/.pong``, and ``HOME`` is
    the account's own home folder. A preview, a test or a dry run points one of them elsewhere."""
    from .groups import isolated_home

    if isolated_home():
        return False
    try:
        import pwd

        return Path.home().resolve() == Path(pwd.getpwuid(os.getuid()).pw_dir).resolve()
    except Exception:  # no account record to compare with: PONG_HOME already said it is the real one
        return True


def _tilde(p: Path) -> str:
    s, home = str(p), str(Path.home())
    return "~" + s[len(home):] if home and (s == home or s.startswith(home + os.sep)) else s


def install_agent(*, launchctl: Callable[[list[str]], tuple[int, str]] | None = None,
                  base: Path | None = None, python: str | None = None,
                  wait: Callable[[float], Any] = time.sleep) -> dict[str, Any]:
    """``pong runtime install-agent``: write the runner's plist and load it. Works from the installed
    engine; no checkout needed.

    Loaded already with the same plist: ``kickstart -k`` restarts it on the engine just installed.
    Loaded with an older plist: ``bootout`` then ``bootstrap``, since launchd keeps the definition it
    loaded. Not loaded: ``bootstrap``. *launchctl* replaces the real command and *wait* the pause
    between bootstrap attempts (tests).

    Refused, with nothing written and launchd untouched:
    - when ``PONG_HOME`` is not this Mac's ``~/.pong``, or ``HOME`` not the account's home folder (a
      preview's fake state, a test) and the real ``launchctl`` would run: there is one runner per Mac, under
      one label, and it must never be booted out or pointed at a throwaway folder;
    - when the engine the runner would start (``<pong home>/lib/pong``) is not there: launchd would start
      it again every few seconds, failing each time, while this said it was on."""
    home = state_dir()
    p = plist_path(base)
    py = python or runner_python()
    if launchctl is None and not _own_home():  # a plist folder of its own still loads under the one label
        from .groups import isolated_home

        why = ("This was run on a copy of CyberPong in another folder (PONG_HOME is set, as for a test or a "
               "preview), not this Mac's own, so the graph runner was left alone." if isolated_home() else
               "This was run with a home folder other than your account's own (HOME is set, as for a test), "
               "so the graph runner was left alone.")
        return {"ok": False, "plist": str(p), "loaded": False, "python": py, "steps": [], "reason": "not_this_home",
                "error": why}
    lib = home / "lib"
    if not (lib / "pong" / "cli" / "main.py").is_file():
        return {"ok": False, "plist": str(p), "loaded": False, "python": py, "steps": [], "reason": "no_engine",
                "error": f"CyberPong's engine isn't installed in {_tilde(lib)} yet, so the runner would have nothing "
                         "to run. Open CyberPong (or run scripts/install-control-plane.sh from a checkout), then turn "
                         "the runner on again."}
    lc = launchctl or _launchctl
    (home / "logs").mkdir(parents=True, exist_ok=True)
    text = plist_text(python=py)
    try:
        before = p.read_text(encoding="utf-8")
    except OSError:
        before = None
    p.parent.mkdir(parents=True, exist_ok=True)
    tmp = p.with_name(p.name + ".tmp")
    tmp.write_text(text, encoding="utf-8")
    os.chmod(tmp, 0o644)
    os.replace(tmp, p)
    domain = f"gui/{os.getuid()}"
    target = f"{domain}/{PLIST_LABEL}"
    loaded = lc(["print", target])[0] == 0
    steps: list[str] = []
    if loaded and before == text:
        rc, out = lc(["kickstart", "-k", target])
        steps.append("kickstart")
    else:
        if loaded:
            lc(["bootout", target])
            steps.append("bootout")
        rc, out = lc(["bootstrap", domain, str(p)])
        steps.append("bootstrap")
        # bootout returns before launchd has let go of the old job, and a bootstrap that comes too soon
        # fails ("Bootstrap failed: 5: Input/output error"): give it a moment and try again
        for _ in range(3 if loaded else 0):
            if rc == 0:
                break
            wait(1.0)
            rc, out = lc(["bootstrap", domain, str(p)])
            steps.append("bootstrap")
        if rc != 0:  # an older macOS, or a half-unloaded agent: the legacy verb still loads it
            rc, out = lc(["load", "-w", str(p)])
            steps.append("load")
    now_loaded = lc(["print", target])[0] == 0
    res: dict[str, Any] = {"ok": now_loaded, "plist": str(p), "loaded": now_loaded, "python": py, "steps": steps}
    if not now_loaded:
        res["error"] = "the runner could not be loaded" + (f" ({out[:200]})" if out else "")
    return res
