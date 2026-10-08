"""``pong doctor``: is this Mac ready for CyberPong? (2.0)

Read-only and fast: it looks for files and commands, asks Claude Code whether it is signed in
(``claude auth status --json``, which spends no tokens) and reads the runner's heartbeat. It never starts
an AI, never prints a key, and never changes anything. The app's first-run setup and Settings show its
answer; ``pong doctor`` prints the same as a short checklist.
"""
from __future__ import annotations

import json
import os
import platform
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

#: The AIs CyberPong runs, with the command that signs each in and a plain way to install it.
AIS: dict[str, dict[str, str]] = {
    "claude": {"label": "Claude Code", "login": "claude auth login",
               "install": "curl -fsSL https://claude.ai/install.sh | bash",
               "install_npm": "npm install -g @anthropic-ai/claude-code"},
    # Grok Build's README: its official installer, then `grok login` (a browser sign-in)
    "grok": {"label": "Grok Build", "login": "grok login", "install": "curl -fsSL https://x.ai/cli/install.sh | bash"},
    "codex": {"label": "Codex", "login": "codex login", "install": "npm install -g @openai/codex"},
    # Hermes Agent's README (NousResearch/hermes-agent): its official installer, then `hermes`
    "hermes": {"label": "Hermes", "login": "hermes login",
               "install": "curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash"},
}
#: Where a key in use came from, in the words ``pong doctor`` and ``pong keys`` print.
KEY_SOURCE_WORDS = {"settings": "from Settings", "environment": "from the environment",
                    "key_file": "from jev.json's key file",
                    "claude_connector": "from Claude Code's Perplexity connector"}
CLAUDE_STATUS_TIMEOUT_S = 8.0


def _tilde(p: Path | str) -> str:
    s, home = str(p), str(Path.home())
    return "~" + s[len(home):] if home and (s == home or s.startswith(home + os.sep)) else s


def _which(name: str) -> str | None:
    from .models import find_binary

    return find_binary(name)


def claude_signin(timeout: float = CLAUDE_STATUS_TIMEOUT_S) -> tuple[bool | None, str | None]:
    """(signed in, plan) from ``claude auth status --json``; (None, None) when it cannot tell.
    Only ``loggedIn`` and ``subscriptionType`` are read; nothing else it prints is kept."""
    exe = _which("claude")
    if not exe:
        return None, None
    try:
        from .models import path_for

        # an npm-installed claude runs `env node`, and node sits in a folder only the CLI search knows
        env = {**os.environ, "PATH": path_for(exe)}
    except Exception:
        env = None
    try:
        r = subprocess.run([exe, "auth", "status", "--json"], capture_output=True, text=True, timeout=timeout,
                           stdin=subprocess.DEVNULL, env=env)
        d = json.loads(r.stdout or "{}")
    except Exception:
        return None, None
    if not isinstance(d, dict) or "loggedIn" not in d:
        return None, None
    plan = d.get("subscriptionType")
    return bool(d.get("loggedIn")), (str(plan) if d.get("loggedIn") and isinstance(plan, str) and plan else None)


def _file_signin(path: Path) -> bool:
    try:
        return path.is_file() and path.stat().st_size > 0
    except OSError:
        return False


def _binaries() -> dict[str, str]:
    out = {}
    for rid in AIS:
        try:
            from .models import runtime_binary

            out[rid] = runtime_binary(rid)
        except Exception:
            out[rid] = rid
    return out


def ai_rows() -> dict[str, dict[str, Any]]:
    from .settings import ai_enabled

    try:
        from .models import runtimes

        labels = {k: str(v.get("label") or "") for k, v in runtimes(None).items()}
    except Exception:
        labels = {}
    home = Path.home()
    out: dict[str, dict[str, Any]] = {}
    binaries = _binaries()
    paths = {rid: _which(b) for rid, b in binaries.items()}
    if not any(paths.values()):
        # none found where the CLIs install: ask the person's own shell where its PATH leads (an npm CLI
        # under a version manager nothing names), at most once a minute while setup re-checks
        try:
            from .models import login_shell_dirs

            login_shell_dirs(max_age=60)
            paths = {rid: _which(b) for rid, b in binaries.items()}
        except Exception:
            pass
    for rid, meta in AIS.items():
        path = paths.get(rid)
        row: dict[str, Any] = {"label": meta["label"] or labels.get(rid) or rid, "installed": bool(path),
                               "path": _tilde(path) if path else None, "signed_in": None, "enabled": ai_enabled(rid),
                               "login": meta["login"], "install": meta["install"]}
        if rid == "claude":
            row["install_npm"] = meta["install_npm"]
            row["plan"] = None
            if path:
                row["signed_in"], row["plan"] = claude_signin()
        elif rid == "grok" and path:
            row["signed_in"] = _file_signin(home / ".grok" / "auth.json")
        elif rid == "codex" and path:
            row["signed_in"] = _file_signin(home / ".codex" / "auth.json")
        out[rid] = row  # hermes: no cheap way to tell, so null ("can't tell")
    return out


def _engine() -> dict[str, Any]:
    from .install import installed_dir, installed_version

    d = installed_dir()
    ok = (d / "__init__.py").is_file()
    ver = installed_version()
    if ok and not ver:
        try:
            import re

            m = re.search(r'__version__\s*=\s*"([^"]+)"', (d / "__init__.py").read_text(encoding="utf-8"))
            ver = m.group(1) if m else ""
        except OSError:
            ver = ""
    from . import __version__

    return {"ok": ok, "path": _tilde(d), "version": ver or None, "same_as_this": bool(ok and ver == __version__)}


def _runner(now: float, mono: float | None = None) -> dict[str, Any]:
    """The graph runner: its plist is in place and its last beat is fresh, in time the Mac was awake (a
    beat from before the Mac slept is not a runner that stopped: ``cron.beat_age``). *mono* replaces the
    clock that stops in sleep (tests)."""
    from .cron import beat_age, load_run_state, runner_beating
    from .runtime import plist_path

    st = load_run_state()
    running = runner_beating(st, now, mono)
    age = beat_age(st, now, mono)
    installed = plist_path().is_file()
    return {"ok": installed and running, "installed": installed, "running": running,
            "last_beat_s": int(age) if age is not None else None}


def check(now: float | None = None) -> dict[str, Any]:
    """The whole answer, as ``pong doctor --json`` prints it."""
    from . import __version__
    from .settings import keys_status, load, summary

    now = time.time() if now is None else now
    # the AIs first: when none is where the CLIs install, they ask the login shell for its folders, and
    # tmux and brew are then looked for there too (tmux looked up first read missing, then found, a run apart)
    ais = ai_rows()
    tmux = _which("tmux")
    brew = _which("brew")
    launcher = Path.home() / "bin" / "pong"
    py_ok = sys.version_info >= (3, 9)
    data = load()
    s = summary(data)
    return {
        "version": __version__,
        "python": {"ok": py_ok, "path": _python_path(), "version": platform.python_version(),
                   **({} if py_ok else {"fix": "xcode-select --install"})},
        "tmux": {"ok": bool(tmux), "path": tmux, "fix": "brew install tmux"},
        "brew": {"ok": bool(brew), "path": brew, **({} if brew else {"fix": "see https://brew.sh"})},
        "launcher": {"ok": launcher.is_file() and os.access(launcher, os.X_OK), "path": _tilde(launcher)},
        "engine": _engine(),
        "runner": _runner(now),
        "ais": ais,
        "keys": keys_status(),
        "settings": {k: s[k] for k in ("owner_name", "architect", "seat_permissions", "limits", "developer",
                                       "protected_labels")},
    }


def _python_path() -> str:
    """This interpreter, by the stable name the runner would use (Homebrew's python3 link, say)."""
    try:
        from .runtime import runner_python

        return runner_python()
    except Exception:
        return sys.executable


def _install_words(how: str) -> str:
    return how if how.startswith("See ") else f"Install: {how}"


def _mark(ok: Any) -> str:
    return "✓" if ok is True else ("✗" if ok is False else "?")


def format_text(d: dict[str, Any]) -> list[str]:
    """``pong doctor``: the checklist in plain words, one line per thing."""
    out = [f"CyberPong {d['version']}: is this Mac ready?"]
    py = d["python"]
    out.append(f"  {_mark(py['ok'])} Python {py['version']}" + ("" if py["ok"] else f" is too old. Fix: {py.get('fix')}"))
    t = d["tmux"]
    out.append(f"  {_mark(t['ok'])} tmux" + ("" if t["ok"] else f": not installed, so no AI can start. Fix: {t['fix']}"
                                             + ("" if d["brew"]["ok"] else " (first install Homebrew: see https://brew.sh)")))
    ln = d["launcher"]
    out.append(f"  {_mark(ln['ok'])} The pong command ({ln['path']})" + ("" if ln["ok"] else ": missing. Opening CyberPong writes it."))
    e = d["engine"]
    out.append(f"  {_mark(e['ok'])} Engine {e.get('version') or ''} ({e['path']})".replace("Engine  (", "Engine (")
               + ("" if e["ok"] else ": missing. Opening CyberPong installs it."))
    r = d["runner"]
    # The runner runs the installed engine, and install-agent refuses while it is missing: get it in place first.
    fix = ("Fix: open CyberPong first so the engine is in place, then turn the runner on: pong runtime install-agent"
           if not e["ok"] else "Fix: pong runtime install-agent")
    if r["ok"]:
        out.append(f"  ✓ Graph runner: running (last beat {r['last_beat_s']} s ago)")
    elif r["installed"]:
        out.append(f"  ✗ Graph runner: installed but not running, so graphs stop after their first step. {fix}")
    else:
        out.append(f"  ✗ Graph runner: not installed, so graphs stop after their first step. {fix}")
    out.append("  AIs:")
    for rid, a in d["ais"].items():
        if not a["installed"]:
            out.append(f"    ✗ {a['label']}: not installed. {_install_words(a['install'])}")
            continue
        off = "" if a["enabled"] else " · switched off in Settings"
        if a["signed_in"] is True:
            plan = f" · {str(a['plan']).capitalize()} plan" if a.get("plan") else ""
            out.append(f"    ✓ {a['label']}: signed in{plan}{off}")
        elif a["signed_in"] is False:
            out.append(f"    ◆ {a['label']}: installed, not signed in. Sign in: {a['login']}{off}")
        else:
            out.append(f"    ? {a['label']}: installed (can't tell whether it is signed in){off}")
    out.append("  Keys:")
    for k, label in (("jev", "Jev"), ("perplexity", "Perplexity")):
        out.append(f"    {key_words(label, d['keys'][k])}")
    settings = d.get("settings") or {}
    if settings.get("protected_labels"):
        # settings' protected_labels: parts of an AI's name the engine never moves or stops in a team change
        out.append("  Never moved or stopped in a team change: AIs whose name includes "
                   + ", ".join(settings["protected_labels"]))
    if settings.get("developer"):
        out.append("  Developer: on (the graph-planning chat may fix CyberPong itself on this Mac)")
    return out


def key_words(label: str, v: dict[str, Any]) -> str:
    """One key's line, as ``pong doctor`` and ``pong keys`` print it: "Jev: no key yet", "Jev: set (from
    Settings)", and " · switched off in Settings" after either when its switch is off. Never the key, a
    prefix or a length."""
    src = str(v.get("source") or "")
    state = f"set ({KEY_SOURCE_WORDS.get(src, src or 'from elsewhere')})" if v.get("set") else "no key yet"
    return f"{label}: {state}" + ("" if v.get("enabled", True) else " · switched off in Settings")


def essentials_ok(d: dict[str, Any]) -> bool:
    ready = any(a["installed"] and a["enabled"] and a["signed_in"] is not False for a in d["ais"].values())
    return all(d[k]["ok"] for k in ("python", "tmux", "launcher", "engine", "runner")) and ready
