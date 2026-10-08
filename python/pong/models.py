"""Which runtime and which model a seat should run — decided from the work.

Two different questions get confused constantly, so they are named apart here:

* **Runtime** is the CLI in the pane — ``claude``, ``grok``, ``codex``,
  ``hermes``. It decides what the seat *can do*: whether it has MCP servers,
  skills, a filesystem, a browser. Swapping it is a respawn.
* **Model** is what that runtime is pointed at — ``fable``, ``opus``,
  ``grok-4.6``. It decides how well the seat thinks. Both Claude Code and Grok
  Build take it as a launch flag (``--model``), which is the only way to set it
  that is actually deterministic; typing ``/model`` into a TUI that is still
  drawing is not.

The pairing is a routing decision, and until now it was three hardcoded tables
in two files: :mod:`pong.groups` knew Claude aliases, :mod:`pong.work_graph`
opened every disposable loop seat on ``claude`` no matter what the loop was for,
and nothing anywhere looked at the task. This module is the one place that
decides, and the policy it applies is :mod:`pong.models`' ``models/catalog.json``
— data, on the same contract as ``loops/*.json``. Adding a model that shipped
this morning is a file edit.

Three things shape a pick, in this order:

1. **What the work needs.** Task text is scanned for demand markers (``tools``,
   ``deep``, ``web``, ``fast``, ``long``). A bare Grok seat has no MCP and no
   skills, so work that needs a tool cannot go there however cheap it is.
2. **What the seat is for.** A critic grades; grading on a weaker model than the
   work was built with is how a published bar quietly drops.
3. **What is installed.** A rule naming a runtime that is not on PATH is skipped
   rather than obeyed, and the skip is reported. Routing to a CLI that does not
   exist is how a seat comes up empty and nobody can say why.

Every pick carries its reason. ``plan(...).why`` is meant to be shown — in
``pong model plan``, in the loop sheet, in the job trace — because a routing
decision nobody can read is indistinguishable from a random one.
"""

from __future__ import annotations

import json
import os
import re
import shutil
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Iterable

from .paths import sessions_dir, state_dir

_PKG = Path(__file__).resolve().parent / "models"

#: Roles that mean the same thing to a router even though the graph, the org
#: roster and the loop catalog each have their own word for them.
_ROLE_SYNONYMS = {
    "build": "builder",
    "builder": "builder",
    "coder": "coder",
    "dev": "coder",
    "engineer": "coder",
    "critic": "critic",
    "reviewer": "reviewer",
    "judge": "critic",
    "research": "researcher",
    "researcher": "researcher",
    "scout": "scout",
    "task_runner": "task_runner",
    "taskrunner": "task_runner",
    "runner": "task_runner",
    "operator": "operator",
    "ops": "operator",
    "orchestrator": "orchestrator",
    "lead": "orchestrator",
    "router": "router",
    "join": "join",
    "fan": "builder",
    "migrator": "migrator",
    "writer": "writer",
    "write": "writer",
    "drafter": "writer",
    "human": "human",
}


class ModelCatalogError(ValueError):
    pass


@dataclass
class Plan:
    """One routing decision, with the reasoning attached."""

    runtime: str
    model: str | None
    cmd: str
    label: str
    pool: str
    shared_pool: bool
    rule: str
    why: str
    flags: list[str] = field(default_factory=list)
    demands: list[str] = field(default_factory=list)
    skipped: list[str] = field(default_factory=list)

    @property
    def launch_cmd(self) -> str:
        """The full shell command for a pane, model flag included."""
        return " ".join([self.cmd] + self.flags)

    def as_dict(self) -> dict[str, Any]:
        return {
            "runtime": self.runtime,
            "model": self.model,
            "cmd": self.cmd,
            "launch_cmd": self.launch_cmd,
            "label": self.label,
            "pool": self.pool,
            "shared_pool": self.shared_pool,
            "rule": self.rule,
            "why": self.why,
            "demands": list(self.demands),
            "skipped": list(self.skipped),
        }

    def one_line(self) -> str:
        model = f" · {self.model}" if self.model else ""
        return f"{self.label}{model} — {self.why}"


# ---------------------------------------------------------------- catalog ---


def _read_json(path: Path) -> dict[str, Any] | None:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None
    return data if isinstance(data, dict) else None


def _roots(session: str | None = None) -> list[Path]:
    """Nearest first — session override, then machine, then the shipped file."""
    roots: list[Path] = []
    if session:
        roots.append(sessions_dir(session) / "models")
    roots.append(state_dir() / "models")
    roots.append(_PKG)
    return roots


def _merge(base: dict[str, Any], over: dict[str, Any]) -> dict[str, Any]:
    """Overlay one catalog onto another.

    ``runtimes`` merges per runtime and per model, so a machine can add
    ``grok-5`` without restating Claude. ``rules`` and ``demands`` replace
    wholesale when present: they are ordered, and a half-merged ordered list
    means the override changed the priority of rules it never mentioned.
    """
    out = dict(base)
    for key, val in over.items():
        if key == "runtimes" and isinstance(val, dict):
            rts = {k: dict(v) for k, v in (out.get("runtimes") or {}).items() if isinstance(v, dict)}
            for rid, row in val.items():
                if not isinstance(row, dict):
                    continue
                cur = dict(rts.get(rid) or {})
                models = dict(cur.get("models") or {})
                for mid, m in (row.get("models") or {}).items():
                    if isinstance(m, dict):
                        models[mid] = {**(models.get(mid) or {}), **m}
                cur.update({k: v for k, v in row.items() if k != "models"})
                if models:
                    cur["models"] = models
                rts[rid] = cur
            out["runtimes"] = rts
        elif key == "pools" and isinstance(val, dict):
            pools = dict(out.get("pools") or {})
            for pid, row in val.items():
                if isinstance(row, dict):
                    pools[pid] = {**(pools.get(pid) or {}), **row}
            out["pools"] = pools
        else:
            out[key] = val
    return out


#: One routing decision reads the catalog several times — rules, then aliases,
#: then the model flag. Keyed on the mtimes of the files that compose it, so an
#: edit is picked up on the next call and nothing has to be restarted.
_CACHE: dict[tuple[Any, ...], dict[str, Any]] = {}


def _catalog_key(session: str | None) -> tuple[Any, ...]:
    stamps: list[Any] = [session or ""]
    for root in _roots(session):
        path = root / "catalog.json"
        try:
            stamps.append(path.stat().st_mtime_ns)
        except OSError:
            stamps.append(None)
    return tuple(stamps)


def load_catalog(session: str | None = None) -> dict[str, Any]:
    """Shipped catalog with machine and session overrides layered on top."""
    key = _catalog_key(session)
    hit = _CACHE.get(key)
    if hit is not None:
        return hit
    merged: dict[str, Any] = {}
    for root in reversed(_roots(session)):  # farthest first, nearest wins
        data = _read_json(root / "catalog.json")
        if data:
            merged = _merge(merged, data)
    if not merged.get("runtimes"):
        raise ModelCatalogError(
            f"no model catalog found — looked in {[str(r) for r in _roots(session)]}"
        )
    _CACHE.clear()  # only ever one live composition per process
    _CACHE[key] = merged
    return merged


def runtimes(session: str | None = None) -> dict[str, dict[str, Any]]:
    cat = load_catalog(session)
    return {
        str(k): v for k, v in (cat.get("runtimes") or {}).items() if isinstance(v, dict)
    }


# ------------------------------------------------------------ availability ---


def _env_runtimes() -> set[str] | None:
    """``PONG_RUNTIMES=claude,grok`` pins availability.

    Tests need a fixed answer, and a machine where the CLI lives somewhere PATH
    does not reach needs a way to say so that is not "edit the catalog".
    """
    raw = (os.environ.get("PONG_RUNTIMES") or "").strip()
    if not raw:
        return None
    return {p.strip().lower() for p in raw.split(",") if p.strip()}


#: Folders under the home folder where a CLI installed through a Node or package manager lives:
#: ``npm install -g`` under volta, bun, an npm prefix or pnpm, Claude Code's own local install, and
#: the shims of mise and asdf. nvm's are found by version (:func:`_nvm_dirs`).
MANAGER_DIRS = (".volta/bin", ".bun/bin", ".npm-global/bin", "Library/pnpm", ".claude/local",
                ".local/share/mise/shims", ".asdf/shims")
#: The folders the person's own login shell adds to PATH for the AI CLIs, as last found (see
#: :func:`login_shell_dirs`); in the CyberPong home.
CLI_PATH_FILE = "cli-path.json"
LOGIN_SHELL_TIMEOUT_S = 3.0
LOGIN_SHELL_MAX_AGE_S = 24 * 3600
_LOGIN_MARK = "__PONG_PATH__"
_login_tried_at = 0.0


def _base_dirs() -> list[str]:
    home = os.path.expanduser("~")
    return [f"{home}/.local/bin", f"{home}/.grok/bin", f"{home}/bin", "/opt/homebrew/bin", "/usr/local/bin"]


def _version_key(name: str) -> tuple[int, ...]:
    return tuple(int(p) for p in re.findall(r"\d+", name)[:3]) or (0,)


def _nvm_dirs() -> list[str]:
    """nvm's node versions' bin folders, newest first, with the version nvm's ``default`` alias names
    (when it is installed) ahead of them: that is the node a new Terminal window runs."""
    root = os.environ.get("NVM_DIR") or os.path.join(os.path.expanduser("~"), ".nvm")
    base = os.path.join(root, "versions", "node")
    try:
        names = [n for n in os.listdir(base) if os.path.isdir(os.path.join(base, n, "bin"))]
    except OSError:
        return []
    names.sort(key=_version_key, reverse=True)
    try:
        with open(os.path.join(root, "alias", "default"), encoding="utf-8") as fh:
            alias = fh.read().strip().lstrip("v")
    except OSError:
        alias = ""
    if alias and re.fullmatch(r"\d+(\.\d+){0,2}", alias):
        pick = next((n for n in names if n.lstrip("v") == alias or n.lstrip("v").startswith(alias + ".")), "")
        if pick:
            names.remove(pick)
            names.insert(0, pick)
    return [os.path.join(base, n, "bin") for n in names]


def _cli_path_file() -> Path:
    """``<pong home>/cli-path.json``, found without creating anything: every command search reads it."""
    env = (os.environ.get("PONG_HOME") or "").strip()
    return (Path(env).expanduser() if env else Path.home() / ".pong") / CLI_PATH_FILE


def _read_login_cache() -> tuple[list[str], float]:
    try:
        data = json.loads(_cli_path_file().read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return [], 0.0
    if not isinstance(data, dict):
        return [], 0.0
    dirs = [str(d) for d in data.get("dirs") or [] if isinstance(d, str) and os.path.isabs(d)]
    try:
        at = float(data.get("at") or 0)
    except (TypeError, ValueError):
        at = 0.0
    return dirs, at


def cli_dirs() -> list[str]:
    """The folders the AI CLIs install into, in the order they are searched: ``~/.local/bin``,
    ``~/.grok/bin``, ``~/bin``, Homebrew's two, then nvm's node versions, then volta, bun, an npm prefix,
    pnpm, Claude Code's local install, mise and asdf, then what the person's login shell added (cached).
    Only folders that exist, besides the first five; no repeats.

    An app opened from the Finder, and the runner launchd starts, get a bare PATH. A CLI installed with
    ``npm install -g`` under nvm lives in ``~/.nvm/versions/node/<v>/bin``, which nothing else names, so
    Claude Code there showed as "not installed" and setup would not go on."""
    home = os.path.expanduser("~")
    out = _base_dirs()
    for d in _nvm_dirs() + [os.path.join(home, m) for m in MANAGER_DIRS] + _read_login_cache()[0]:
        if d and d not in out and ":" not in d and os.path.isdir(d):
            out.append(d)
    return out


def search_path() -> str:
    """PATH plus the folders the CLIs install into (:func:`cli_dirs`).

    launchd and Dock-launched apps get a bare PATH; the CLIs live in the
    user's own bin dirs. Without these the runner found nothing installed
    and the solver read "nothing" as "anything"."""
    return os.pathsep.join([os.environ.get("PATH", ""), *cli_dirs()])


def find_binary(name: str) -> str | None:
    """Where a command lives on this Mac (PATH plus the CLIs' own folders), or None."""
    name = str(name or "").strip().split()[0] if str(name or "").strip() else ""
    return shutil.which(name, path=search_path()) if name else None


def path_for(exe: str) -> str:
    """The PATH to run the CLI at *exe* with: its own folder first, then :func:`search_path`. A CLI installed
    with ``npm install -g`` starts with ``#!/usr/bin/env node``, and its node sits in that same folder (nvm,
    volta, bun), which the runner's and the app's bare PATH never name."""
    own = os.path.dirname(exe) if exe and os.path.isabs(exe) else ""
    return os.pathsep.join([own, search_path()]) if own else search_path()


def runtime_binary(rid: str, session: str | None = None) -> str:
    row = runtimes(session).get(str(rid or "").lower()) or {}
    return str(row.get("bin") or row.get("cmd") or rid).split()[0]


def _login_shell() -> str:
    sh = (os.environ.get("SHELL") or "").strip()
    if not sh:
        try:
            import pwd

            sh = pwd.getpwuid(os.getuid()).pw_shell or ""
        except (KeyError, ImportError, OSError):
            sh = ""
    return sh if os.path.isabs(sh) and os.access(sh, os.X_OK) else "/bin/zsh"


def _ask_login_shell(timeout: float = LOGIN_SHELL_TIMEOUT_S) -> str | None:
    """The PATH a new Terminal window would have: the person's shell, started as a login and interactive
    shell (nvm's setup is in ``~/.zshrc``, which a login shell alone never reads), printing ``$PATH`` and
    nothing else. Its own output, its errors and any prompt it shows are dropped; it is given no input and
    stopped, with whatever it started, after ``timeout`` seconds. None when it says nothing usable.
    Tests replace this."""
    import signal
    import subprocess

    try:
        p = subprocess.Popen([_login_shell(), "-ilc", f'printf "\\n{_LOGIN_MARK}%s\\n" "$PATH"'],
                             stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                             text=True, start_new_session=True)
    except OSError:
        return None
    try:
        out, _ = p.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(p.pid, signal.SIGKILL)
        except OSError:
            pass
        try:
            p.communicate(timeout=1)
        except Exception:
            pass
        return None
    for line in (out or "").splitlines():
        if line.startswith(_LOGIN_MARK):
            return line[len(_LOGIN_MARK):].strip()
    return None


def login_shell_dirs(*, max_age: float = LOGIN_SHELL_MAX_AGE_S) -> list[str]:
    """The folders on the person's own Terminal PATH that hold an AI CLI (or the ``node`` an npm CLI runs
    on), as :func:`cli_dirs` adds them. Asked of their login shell at most once a minute in one process,
    and only when the cached answer (``<pong home>/cli-path.json``) is older than ``max_age``; on a
    temporary home (tests, a preview) never asked at all."""
    global _login_tried_at
    import time

    from .groups import isolated_home

    cached, at = _read_login_cache()
    now = time.time()
    if now - at < max_age or now - _login_tried_at < 60 or isolated_home():
        return cached
    _login_tried_at = now
    raw = _ask_login_shell()
    if raw is None:
        return cached
    try:
        names = {runtime_binary(r) for r in runtimes(None)} | {"node"}
    except Exception:
        names = {"claude", "grok", "codex", "hermes", "node"}
    base = set(_base_dirs()) | {"/usr/bin", "/bin", "/usr/sbin", "/sbin"}
    dirs: list[str] = []
    for d in raw.split(os.pathsep):
        d = d.strip()
        if (not os.path.isabs(d) or ":" in d or d in base or d in dirs
                or not any(os.access(os.path.join(d, n), os.X_OK) for n in names)):
            continue
        dirs.append(d)
    try:
        from .jsonutil import write_json

        write_json(_cli_path_file(), {"dirs": dirs, "at": now})
    except Exception:
        pass
    return dirs


def _found(session: str | None = None) -> set[str]:
    search = search_path()
    return {rid for rid, row in runtimes(session).items()
            if shutil.which(str(row.get("bin") or row.get("cmd") or rid).split()[0], path=search)}


def installed_runtimes(session: str | None = None) -> set[str]:
    """Runtime ids whose binary resolves right now (PATH plus :func:`cli_dirs`), whatever the Settings
    switches say. ``PONG_RUNTIMES`` pins the set (tests). When none is found, the person's login shell is
    asked once where its PATH leads (an AI CLI installed somewhere no list names), and the search is
    made again with what it said."""
    pinned = _env_runtimes()
    if pinned is not None:
        return set(pinned)
    out = _found(session)
    if not out:
        before = _read_login_cache()[0]
        if login_shell_dirs() != before:
            out = _found(session)
    return out


def available_runtimes(session: str | None = None) -> set[str]:
    """Runtime ids that are installed (:func:`installed_runtimes`), less the AIs the person switched off
    in Settings (``ai_enabled``): an AI switched off is never picked, whatever is installed.
    ``PONG_RUNTIMES`` pins the installed set (tests); the switches still apply to it."""
    out = installed_runtimes(session)
    try:
        from .settings import disabled_runtimes

        out -= disabled_runtimes()
    except Exception:
        pass
    return out


# ------------------------------------------------------------------ models ---


def canonical_model(runtime: str, label: str | None, session: str | None = None) -> str | None:
    """A model name as the CLI wants to hear it.

    People write "opus 5" and "Fable"; ``claude --model`` wants ``opus`` and
    ``fable``. Unknown names pass through untouched so a model that ships today
    works today — this table is a convenience, not a gate.
    """
    name = " ".join(str(label or "").strip().lower().split())
    if not name:
        return None
    row = runtimes(session).get(str(runtime or "").lower()) or {}
    models = row.get("models") or {}
    if name in models:
        return name
    for mid, m in models.items():
        if not isinstance(m, dict):
            continue
        aliases = {str(a).strip().lower() for a in (m.get("aliases") or [])}
        aliases.add(str(m.get("label") or "").strip().lower())
        if name in aliases:
            return str(mid)
    return name


def model_args(runtime: str, model: str | None, session: str | None = None) -> list[str]:
    """Launch-flag form, e.g. ``["--model", "fable"]``. Empty when unsupported."""
    if not model:
        return []
    row = runtimes(session).get(str(runtime or "").lower()) or {}
    flag = row.get("model_flag")
    if not flag:
        return []
    return [str(flag), str(model)]


def model_command(runtime: str, model: str | None, session: str | None = None) -> str | None:
    """In-TUI switch for a seat that is already up, e.g. ``/model fable``.

    ``None`` means the runtime has no such command — Grok Build does not, and
    typing one into it posts the literal text as a prompt.
    """
    if not model:
        return None
    row = runtimes(session).get(str(runtime or "").lower()) or {}
    cmd = row.get("model_command")
    if not cmd:
        return None
    return f"{cmd} {model}"


# ----------------------------------------------------------------- demands ---


def _norm_task(task: str | None) -> str:
    return re.sub(r"\s+", " ", str(task or "").lower())


def _hit(text: str, needle: str) -> bool:
    """Whole-word match.

    A plain substring test reads "latest" as "test" and "rapid" as "api", which
    is how a scouting job came back tagged as code work. Boundaries are on
    word characters only, so a marker like ``x.com`` or ``gpt-5`` still matches
    the way it is written.
    """
    n = needle.strip().lower()
    if not n:
        return False
    return re.search(rf"(?<!\w){re.escape(n)}(?!\w)", text) is not None


def demands_for(task: str | None, session: str | None = None) -> list[str]:
    """Demand markers present in the task text, in catalog order."""
    text = _norm_task(task)
    if not text:
        return []
    out: list[str] = []
    for row in load_catalog(session).get("demands") or []:
        if not isinstance(row, dict):
            continue
        did = str(row.get("id") or "").strip()
        if not did:
            continue
        if any(_hit(text, str(needle)) for needle in (row.get("any") or [])):
            out.append(did)
    return out


def demand_reasons(session: str | None = None) -> dict[str, str]:
    return {
        str(r.get("id")): str(r.get("why") or "")
        for r in (load_catalog(session).get("demands") or [])
        if isinstance(r, dict) and r.get("id")
    }


# ------------------------------------------------------------------ routing --


def normalize_role(role: str | None) -> str:
    key = str(role or "").strip().lower().replace("-", "_").replace(" ", "_")
    return _ROLE_SYNONYMS.get(key, key)


def _model_names(row: dict[str, Any]) -> set[str]:
    names: set[str] = set()
    for mid, m in (row.get("models") or {}).items():
        names.add(str(mid).strip().lower())
        if isinstance(m, dict):
            names.update(str(a).strip().lower() for a in (m.get("aliases") or []))
            if m.get("label"):
                names.add(str(m["label"]).strip().lower())
    return names


def _belongs_elsewhere(
    rts: dict[str, Any], runtime: str, model: str
) -> bool:
    """True when this model name is another runtime's, not an unknown one."""
    name = " ".join(str(model or "").strip().lower().split())
    if not name:
        return False
    mine = _model_names(rts.get(runtime) or {})
    if name in mine:
        return False
    return any(
        name in _model_names(row)
        for rid, row in rts.items()
        if rid != runtime and isinstance(row, dict)
    )


def _rule_matches(rule: dict[str, Any], role: str, demands: Iterable[str]) -> bool:
    when = rule.get("when") or {}
    have = set(demands)
    roles = {normalize_role(r) for r in (when.get("roles") or [])}
    if roles and role not in roles:
        return False
    need_any = {str(d) for d in (when.get("demands_any") or [])}
    if need_any and not (have & need_any):
        return False
    forbid = {str(d) for d in (when.get("demands_none") or [])}
    if forbid and (have & forbid):
        return False
    return True


def _build(
    cat: dict[str, Any],
    pick: dict[str, Any],
    *,
    rule: str,
    why: str,
    demands: list[str],
    skipped: list[str],
    session: str | None,
) -> Plan:
    rid = str(pick.get("runtime") or "").lower()
    row = (cat.get("runtimes") or {}).get(rid) or {}
    model = pick.get("model")
    model = canonical_model(rid, str(model), session) if model else row.get("default_model")
    pool = str(row.get("pool") or "")
    pool_row = (cat.get("pools") or {}).get(pool) or {}
    return Plan(
        runtime=rid,
        model=model,
        cmd=str(row.get("cmd") or rid),
        label=str(row.get("label") or rid),
        pool=pool,
        shared_pool=bool(pool_row.get("shared")),
        rule=rule,
        why=why,
        flags=model_args(rid, model, session),
        demands=list(demands),
        skipped=list(skipped),
    )


def _carry_refusal(picked: Plan, refusal: str) -> Plan:
    """Put a refused pin in front of whatever reason the rules gave.

    The rules downstream have no idea a pin was dropped, so their ``why`` reads
    like an ordinary decision. Whoever is looking at this seat needs the pin
    refusal first — it is the actionable half, and on the no-tools-runtime-
    available path it is the only thing that names the problem at all.
    """
    if refusal:
        picked.why = f"{refusal} {picked.why}".strip()
    return picked


def plan(
    task: str | None = "",
    role: str | None = "",
    *,
    session: str | None = None,
    available: Iterable[str] | None = None,
    prefer_runtime: str | None = None,
    prefer_model: str | None = None,
) -> Plan:
    """Pick a runtime + model for one piece of work, and say why.

    ``prefer_model`` is an outright human choice and wins. ``prefer_runtime`` is
    weaker on purpose: a live seat's CLI is a running pane, so it is a
    *constraint* rather than an answer — the rules still choose the model, they
    just may not choose a different runtime. That distinction is what lets a
    Claude seat with no model annotation still land on fable for code and opus
    for review instead of one blanket default.
    """
    cat = load_catalog(session)
    rts = {k: v for k, v in (cat.get("runtimes") or {}).items() if isinstance(v, dict)}
    have = (
        {str(a).lower() for a in available}
        if available is not None
        else available_runtimes(session)
    )
    role_n = normalize_role(role)
    dems = demands_for(task, session)
    skipped: list[str] = []

    pin = str(prefer_runtime or "").lower() or None
    if pin and pin not in rts:
        skipped.append(f"pinned runtime {pin!r} is not in the catalog")
        pin = None

    # A pin is a constraint, not a licence. The catalog already says what the
    # `tools` demand means — "a bare Grok seat has none of those, so routing
    # this work there produces a confident answer with nothing behind it" — but
    # nothing enforced it once a runtime was pinned. Both pinned paths below
    # returned that seat as a clean success: the rule loop skips every rule
    # whose pick is a different runtime and falls through to runtime-default,
    # and an `explicit` roster model returns even earlier. Dropping the pin here,
    # above both, is what makes one guard cover both. The rules then choose
    # normally, so the Plan stays coherent by construction — _build takes cmd
    # and model from the same runtime row, and `grok --model fable` (which does
    # not launch) is not a shape this can produce.
    pin_refused = ""
    if pin and "tools" in dems and not (rts.get(pin) or {}).get("tools"):
        pin_refused = (
            f"Pin refused: the {rts.get(pin, {}).get('label') or pin} runtime has "
            f"no tools and this work demands them — respawn this seat on a tools "
            f"runtime before giving it work like this."
        )
        skipped.append(
            f"pinned runtime {pin!r} has tools=false and the task demands tools "
            f"— pin refused, routing as if unpinned"
        )
        pin = None

    if pin and prefer_model:
        if _belongs_elsewhere(rts, pin, prefer_model):
            # A Claude model on a Grok seat is a roster mistake, not a request:
            # `grok --model fable` fails to launch and the seat never comes up.
            # An unknown name still passes through — that is a model that
            # shipped more recently than this catalog.
            skipped.append(
                f"roster model {prefer_model!r} belongs to another runtime — "
                f"not sent to {pin}"
            )
        else:
            return _carry_refusal(_build(
                cat,
                {"runtime": pin, "model": prefer_model},
                rule="explicit",
                why="Named on the roster — a human already decided this seat.",
                demands=dems,
                skipped=skipped,
                session=session,
            ), pin_refused)

    for rule in cat.get("rules") or []:
        if not isinstance(rule, dict):
            continue
        pick = rule.get("pick") or {}
        rid = str(pick.get("runtime") or "").lower()
        name = str(rule.get("id") or "rule")
        if not _rule_matches(rule, role_n, dems):
            continue
        if pin and rid != pin:
            # The pane is already running this CLI. Keep looking for a rule that
            # speaks to the runtime this seat actually has.
            continue
        if rid not in rts:
            skipped.append(f"{name}: {rid!r} is not in the catalog")
            continue
        if have and rid not in have:
            skipped.append(f"{name}: {rid} is not installed on this machine")
            continue
        picked = _build(
            cat,
            pick,
            rule=name,
            why=str(rule.get("why") or ""),
            demands=dems,
            skipped=skipped,
            session=session,
        )
        return _carry_refusal(
            picked if pin else _pool_guard(cat, picked, dems, have, session),
            pin_refused,
        )

    if pin:
        row = rts.get(pin) or {}
        return _carry_refusal(_build(
            cat,
            {"runtime": pin, "model": row.get("default_model")},
            rule="runtime-default",
            why=(
                f"No rule speaks to a {row.get('label') or pin} seat doing this, "
                "so it stays on that runtime's default."
            ),
            demands=dems,
            skipped=skipped,
            session=session,
        ), pin_refused)

    fb = cat.get("fallback") or {}
    return _carry_refusal(_build(
        cat,
        fb.get("pick") or {"runtime": "claude"},
        rule="fallback",
        why=str(fb.get("why") or "No rule matched."),
        demands=dems,
        skipped=skipped,
        session=session,
    ), pin_refused)


def _pool_guard(
    cat: dict[str, Any],
    picked: Plan,
    demands: list[str],
    have: set[str],
    session: str | None,
) -> Plan:
    """Keep heavy work off a shared allowance when something else can take it.

    Every Grok seat and the Hermes chief spend the same weekly xAI budget, so a
    long or deep job sent to a grok seat is not cheap — it is taken out of every
    other seat's week. Light work is exactly what that pool is for and stays.
    """
    heavy = {"deep", "long"} & set(demands)
    if not picked.shared_pool or not heavy:
        return picked
    needs_tools = "tools" in demands
    for rid, row in (cat.get("runtimes") or {}).items():
        if rid == picked.runtime or not isinstance(row, dict):
            continue
        pool_row = (cat.get("pools") or {}).get(str(row.get("pool") or "")) or {}
        if pool_row.get("shared"):
            continue
        if have and rid not in have:
            continue
        if needs_tools and not row.get("tools"):
            continue
        moved = _build(
            cat,
            {"runtime": rid, "model": row.get("default_model")},
            rule=f"{picked.rule}+pool-guard",
            why=(
                f"{picked.why} Moved off {picked.pool}: that allowance is shared by "
                f"every grok seat and the chief, and this job is "
                f"{' and '.join(sorted(heavy))}."
            ),
            demands=demands,
            skipped=picked.skipped,
            session=session,
        )
        return moved
    return picked


# --------------------------------------------------------------- seat glue ---


def plan_for_worker(
    worker: dict[str, Any],
    *,
    task: str | None = "",
    session: str | None = None,
) -> Plan:
    """Routing decision for a roster row — its own fields win over the rules."""
    return plan(
        task,
        str(worker.get("mission_role") or worker.get("role") or ""),
        session=session,
        prefer_runtime=str(worker.get("type") or "").strip() or None,
        prefer_model=str(worker.get("model") or "").strip() or None,
    )
