"""Graph architects: one Claude session per project that designs, launches, watches and edits its graphs.

What a person does with CyberPong on a big job, three days of long rounds in September showed: talk with one
Claude session that writes the brief and the topology, dry-runs it, attaches it, then stays with it,
answering gates within what the person delegated, sending a step back with a note, retrying what a
network drop stalled, and fixing CyberPong itself when a run exposed a bug. That session watched the
graph with scripts that woke it when something happened. An architect is that session made a
first-class part of CyberPong:

- ``new`` gives a project a team of its own whose lead seat starts as the architect;
  ``start`` adds an architect seat (``<owner>.arch``) to a team that already exists.
- It starts on a pointer to its prompt file: the playbook (``architect_playbook.md``) plus who it is,
  which folder and which graph. Nothing is pasted into a TUI that is still drawing.
- Every event the engine already posts to a graph's owner (a gate opening or answered, a seat that
  needs a look, a refusal, the graph finishing or stopping) is also queued for the graph's architect,
  and the runner's tick delivers the queue into the architect's pane as one line starting
  "[CyberPong]" when the architect is idle and its input box is empty. A step quiet 25 minutes is
  queued the same way. So the person's chat and the graph's news arrive in one conversation.
- ``screen``, ``send`` and ``key`` are what the app's chat panel uses: read the pane, type a message,
  press Escape or an arrow.

Architects live in ``~/.pong/sessions/<team>/architects.json``. Nothing here decides anything: the
architect proposes and acts only within what its person told it, and a person presses anything that
sends, posts, spends, merges or migrates, exactly as for every other seat.
"""
from __future__ import annotations

import fcntl
import os
import re
import secrets
import time
from contextlib import contextmanager
from pathlib import Path
from typing import Any, Iterator

ARCH_FILE = "architects.json"
QUIET_S = 25 * 60
REQUEUE_QUIET_S = 30 * 60
MAX_LINE = 900          # one delivered line; a long queue says how many more wait
MAX_QUEUE = 40          # a queue nobody reads keeps its newest events
PLAYBOOK = Path(__file__).with_name("architect_playbook.md")
#: Fixing CyberPong itself: appended only on the owner's Mac (settings ``developer``).
PLAYBOOK_DEV = Path(__file__).with_name("architect_playbook_dev.md")
OWNER_RULES = Path.home() / ".pong" / "owner-rules.md"
#: Runtimes an architect can start on: its first message rides on the CLI's command line. Hermes takes no
#: first message there, and typing the pointer into a TUI that is still drawing is how messages get lost,
#: so a Hermes architect is refused with a plain error rather than started without its instructions.
ARCHITECT_RUNTIMES = ("claude", "grok", "codex")
RUNTIME_LABELS = {"claude": "Claude Code", "grok": "Grok Build", "codex": "Codex", "hermes": "Hermes"}

KEYS = {  # what the chat panel may press, by name → tmux key
    "enter": "Enter", "escape": "Escape", "up": "Up", "down": "Down", "left": "Left", "right": "Right",
    "tab": "Tab", "btab": "BTab", "ctrl-c": "C-c", "y": "y", "n": "n", "1": "1", "2": "2", "3": "3",
}


class ArchitectError(ValueError):
    pass


# ------------------------------------------------------------------ storage ---

def _path(session: str) -> Path:
    from .paths import sessions_dir

    return sessions_dir(session) / ARCH_FILE


@contextmanager
def _locked(session: str) -> Iterator[dict[str, Any]]:
    """Read-modify-write under a file lock: the tick and a CLI call can both touch the queue."""
    from .jsonutil import read_json, write_json

    p = _path(session)
    p.parent.mkdir(parents=True, exist_ok=True)
    with open(str(p) + ".lock", "a+") as lk:
        fcntl.flock(lk, fcntl.LOCK_EX)
        data = read_json(p) or {}
        if not isinstance(data.get("architects"), list):
            data["architects"] = []
        yield data
        write_json(p, data)


def _read(session: str) -> dict[str, Any]:
    from .jsonutil import read_json

    data = read_json(_path(session)) or {}
    if not isinstance(data.get("architects"), list):
        data["architects"] = []
    return data


def list_for(session: str) -> list[dict[str, Any]]:
    return [a for a in _read(session)["architects"] if isinstance(a, dict)]


def get(session: str, arch_id: str) -> dict[str, Any]:
    for a in list_for(session):
        if a.get("id") == arch_id:
            return a
    raise ArchitectError(f"no architect {arch_id!r} on {session}")


def list_all() -> list[dict[str, Any]]:
    """Every architect on this Mac, newest first, as the app's rail shows them."""
    from .paths import sessions_dir

    base = sessions_dir()
    out: list[dict[str, Any]] = []
    if not base.is_dir():
        return out
    for d in sorted(base.iterdir()):
        if not d.is_dir() or d.name.startswith(("_", ".")) or not (d / ARCH_FILE).exists():
            continue
        for a in list_for(d.name):
            out.append(summary(d.name, a))
    out.sort(key=lambda r: -float(r.get("created_at") or 0))
    return out


def find_session(arch_id: str) -> str:
    """The team an architect id belongs to (ids are unique across teams)."""
    from .paths import sessions_dir

    base = sessions_dir()
    if base.is_dir():
        for d in sorted(base.iterdir()):
            if d.is_dir() and (d / ARCH_FILE).exists() and any(a.get("id") == arch_id for a in list_for(d.name)):
                return d.name
    raise ArchitectError(f"no architect {arch_id!r} on this Mac")


def summary(session: str, a: dict[str, Any]) -> dict[str, Any]:
    alive = _alive(session, str(a.get("seat") or ""))
    return {"id": a.get("id"), "session": session, "title": a.get("title"), "seat": a.get("seat"),
            "runtime": a.get("runtime") or "claude", "model": a.get("model") or "",
            "pane_id": _pane(session, str(a.get("seat") or "")) if alive else "",
            "cwd": a.get("cwd"), "graphs": list(a.get("graphs") or []), "alive": alive,
            "queued": len(a.get("queue") or []), "created_at": a.get("created_at"),
            "last_delivered_at": a.get("last_delivered_at")}


def for_graph(session: str, graph_id: str) -> dict[str, Any] | None:
    for a in list_for(session):
        if graph_id in (a.get("graphs") or []):
            return a
    return None


def chat_log_path(session: str, arch_id: str) -> Path:
    from .paths import sessions_dir

    return sessions_dir(session) / "architects" / f"{arch_id}.chat.jsonl"


def _chat_log(session: str, arch_id: str, who: str, text: str, **extra: Any) -> None:
    """Every line that went into an architect's chat from outside it: a person's message from the app,
    a key they pressed, a batch of CyberPong events. Its own replies are in its Claude transcript."""
    import json

    p = chat_log_path(session, arch_id)
    try:
        p.parent.mkdir(parents=True, exist_ok=True)
        with p.open("a", encoding="utf-8") as fh:
            fh.write(json.dumps({"t": round(time.time(), 3), "who": who, "text": text, **extra}, ensure_ascii=False) + "\n")
    except OSError:
        pass


def chat_log(session: str, arch_id: str, *, tail: int = 200) -> list[dict[str, Any]]:
    import json

    out = []
    try:
        with chat_log_path(session, arch_id).open(encoding="utf-8") as fh:
            for line in fh:
                try:
                    out.append(json.loads(line))
                except ValueError:
                    continue
    except OSError:
        return []
    return out[-tail:]


def transcripts(session: str, arch_id: str) -> list[dict[str, Any]]:
    """The architect's own Claude transcript(s): they carry its prompt file's name from the pointer."""
    from .graph_log import find_transcripts

    a = get(session, arch_id)
    return find_transcripts(f"{arch_id}.md", str(a.get("cwd") or ""), since=float(a.get("created_at") or 0))


# ------------------------------------------------------------------ panes ---

def _pane(session: str, seat: str) -> str:
    from .routing import load_pane_registration

    return str((load_pane_registration(session, seat) or {}).get("pane_id") or "")


def _alive(session: str, seat: str) -> bool:
    pane = _pane(session, seat)
    if not pane:
        return False
    try:
        from .groups import _pane_alive, pane_owned

        return pane_owned(pane, session, seat) if "." in seat else _pane_alive(pane)
    except Exception:
        return False


def _capture(session: str, seat: str, lines: int = 80) -> str | None:
    """The pane's last lines, or None when it is gone. Tests replace this."""
    pane = _pane(session, seat)
    if not pane or not _alive(session, seat):
        return None
    from .groups import _tmux

    ok, text = _tmux("capture-pane", "-p", "-J", "-t", pane, "-S", f"-{max(10, min(int(lines), 2000))}")
    return text if ok else None


def _type(session: str, seat: str, text: str, *, enter: bool = True) -> bool:
    """Type ``text`` into the architect's pane and press Enter. Tests replace this."""
    pane = _pane(session, seat)
    if not pane or not _alive(session, seat):
        return False
    from .groups import _tmux

    ok, _ = _tmux("send-keys", "-t", pane, "-l", text)
    if ok and enter:
        time.sleep(0.08)  # the TUI takes the paste before the Enter; together, some Enters were eaten
        ok, _ = _tmux("send-keys", "-t", pane, "Enter")
    return ok


def _press(session: str, seat: str, key: str) -> bool:
    pane = _pane(session, seat)
    if not pane or not _alive(session, seat):
        return False
    from .groups import _tmux

    ok, _ = _tmux("send-keys", "-t", pane, key)
    return ok


_WORKING = re.compile(r"esc to interrupt|esc to cancel|\(esc to|thinking", re.I)


def idle_and_empty(text: str) -> bool:
    """The architect finished its turn and nobody is typing: the one moment a line may be delivered.

    Claude Code's input box is the line that starts with ❯ between two rules; empty, it shows either
    nothing or a dimmed hint ('Try "…"'), which capture-pane prints as plain text. A question on
    screen (a permission dialog, a menu) has no empty ❯ line, so the queue waits for the person.
    """
    lines = [ln.rstrip() for ln in (text or "").splitlines() if ln.strip()]
    tail = lines[-8:]
    if not tail or any(_WORKING.search(ln) for ln in tail[-4:]):
        return False
    for ln in reversed(tail):
        s = ln.strip().strip("│").strip()
        if s.startswith("❯") or s.startswith(">"):
            rest = s[1:].strip()
            return rest == "" or rest.startswith('Try "')
    return False


# ------------------------------------------------------------------ prompts ---

def _owner_rules() -> str:
    try:
        return OWNER_RULES.read_text(encoding="utf-8").strip()
    except OSError:
        return ""


def _tilde(p: Path) -> str:
    """A path as a shell reads it, with the home folder as ``~`` (an unquoted ``~/`` expands)."""
    s, home = str(p), str(Path.home())
    return "~" + s[len(home):] if home and (s == home or s.startswith(home + os.sep)) else s


def kit_dir() -> Path:
    """The graph kit (dryrun, pplx, limit-guard, watch) on this Mac: the installed copy under
    ``<pong home>/lib/graph-kit`` first (the one seats see), then the app bundle's
    ``Resources/graph-kit``, then a checkout's ``scripts/graph-kit``. When none exists yet, the installed
    place, which the app's engine refresh fills."""
    from .paths import state_dir

    here = Path(__file__).resolve().parent  # …/lib/pong, …/Resources/python/pong or <repo>/python/pong
    installed = state_dir() / "lib" / "graph-kit"
    for cand in (installed, here.parent / "graph-kit", here.parent.parent / "graph-kit",
                 here.parent.parent / "scripts" / "graph-kit"):
        if (cand / "dryrun.py").is_file():
            return cand
    return installed


def _repo_dir() -> str:
    """The CyberPong checkout the installed engine came from (its install stamp), or this package's own
    checkout; '' when neither is a repository. Only the developer playbook names it."""
    from .paths import state_dir

    cands: list[Path] = []
    try:
        for line in (state_dir() / "lib" / "pong" / "INSTALL_STAMP").read_text(encoding="utf-8").splitlines():
            if line.startswith("source="):
                cands.append(Path(line.split("=", 1)[1].strip()))
    except OSError:
        pass
    cands.append(Path(__file__).resolve().parents[2])
    for c in cands:
        if str(c) and (c / "python" / "pong").is_dir() and (c / "scripts").is_dir():
            return _tilde(c)
    return ""


def playbook_text() -> str:
    """The playbook as an architect reads it: ``{KIT}`` filled with the graph kit's folder, and the
    developer part (fixing CyberPong itself) only on a Mac whose settings say ``developer``."""
    try:
        text = PLAYBOOK.read_text(encoding="utf-8")
    except OSError:
        text = "(the playbook file is missing: ask the person, and read `pong architect --help`)"
    try:
        from .settings import developer

        dev = developer()
    except Exception:
        dev = False
    if dev:
        try:
            extra = PLAYBOOK_DEV.read_text(encoding="utf-8").strip()
        except OSError:
            extra = ""
        if extra:
            repo = _repo_dir() or "the CyberPong checkout (ask the person where it is)"
            text = text.rstrip() + "\n\n" + extra.replace("{REPO}", repo) + "\n"
    return text.replace("{KIT}", _tilde(kit_dir()))


def _write_prompt(session: str, arch_id: str, *, title: str, seat: str, cwd: str, graph_id: str = "") -> Path:
    from .paths import sessions_dir

    folder = sessions_dir(session) / "architects"
    folder.mkdir(parents=True, exist_ok=True)
    playbook = playbook_text()
    rules = _owner_rules()
    history = _team_history(session)
    graph_line = (f"You were started for the graph `{graph_id}`: read `pong -s {session} graph show --id {graph_id}` and its "
                  f"notes first, then say in two lines where it stands. For a next step, run the intake (section 1) first."
                  if graph_id else
                  "No graph of yours exists yet. Before designing anything, run the intake (section 1)"
                  + (": this team has done work before (below), so prepare from it first." if history else "."))
    try:  # the name the person gave in Settings (the asks, schedules and job texts use it too)
        from .settings import DEFAULT_OWNER, owner_name

        who = owner_name()
        name_line = f"- The person you work with is called {who}.\n" if who and who != DEFAULT_OWNER else ""
    except Exception:
        name_line = ""
    text = (
        f"# You are the graph architect for: {title}\n\n"
        f"- Team (CyberPong session): `{session}` · your seat: `{seat}` · your architect id: `{arch_id}`\n"
        f"- Project folder: `{cwd}`\n"
        + name_line
        + f"- {graph_line}\n"
        f"- Events from your graphs arrive in this chat as one line starting `[CyberPong]`. They are the engine's, not the "
        f"person's words: act on them as your playbook says, and tell the person in plain words what you did.\n\n"
        + (f"## The person's standing rules (from {OWNER_RULES}; they override everything below)\n\n{rules}\n\n" if rules else "")
        + (f"## What this team has done (newest first)\n\n{history}\n\n"
           f"Before building on one, read its notes and, if it went wrong, `pong -s {session} graph trace --id <graph>`. "
           f"The project folder may also hold handoff and decision files (`*HANDOFF*.md`, `*DECISIONS*.md`, `*ANSWERS*.md`).\n\n"
           if history else "")
        + playbook
    )
    path = folder / f"{arch_id}.md"
    path.write_text(text, encoding="utf-8")
    return path


def _pointer(title: str, prompt_path: Path, brief: str = "") -> str:
    """The architect's first message: where its playbook is, and the person's request when the app's New graph
    sheet gave one. One line: it is typed into the terminal, and an Enter in the middle would send half."""
    text = (f"You are the CyberPong graph architect for {title!r}. Read {prompt_path} first; it is who you are, "
            f"what you may do and how. Then greet the person in two lines; if this team has done work before, say in "
            f"three lines what was done and what is still open. Then start the intake (section 1 of your playbook) "
            f"before you design anything.")
    brief = " ".join(str(brief or "").split())[:2000]
    if brief:
        text += (f" The person's request, in their own words: \u00ab{brief}\u00bb. Read it as the brief: ask only "
                 f"what it leaves open.")
    return text


def _team_history(session: str, limit: int = 12) -> str:
    """This team's graphs, newest first, so an architect can pick up earlier work: what each was, how it ended,
    where its notes are, and the files that changed in the folder while it ran (another run's, too, when two
    overlapped)."""
    try:
        from .work_graph import load

        graphs = [g for g in load(session).get("graphs") or [] if isinstance(g, dict)]
    except Exception:
        return ""
    graphs.sort(key=lambda g: -float(g.get("created_at") or 0))
    out: list[str] = []
    for g in graphs[:limit]:
        title = str((g.get("topology") or {}).get("name") or g.get("title") or g.get("id") or "")
        status, end = str(g.get("status") or ""), str(g.get("stop_reason") or "")
        when = time.strftime("%d %b %Y", time.localtime(float(g["created_at"]))) if g.get("created_at") else ""
        files = sorted(((rel, f) for rel, f in (g.get("files") or {}).items() if isinstance(f, dict)),
                       key=lambda kv: -float(kv[1].get("at") or 0))
        line = f"- `{g.get('id')}` · {title} · {status}" + (f" ({end})" if end and end != status else "") + (f" · started {when}" if when else "")
        if g.get("notes_path"):
            line += f"\n  notes: `{g['notes_path']}`"
        if files:
            line += "\n  files changed in the folder while it ran, newest first: " + ", ".join(f"`{rel}`" for rel, _ in files[:6])
        out.append(line)
    return "\n".join(out)


# ------------------------------------------------------------------ start ---

def _new_id() -> str:
    return "a_" + secrets.token_hex(4)


def _label(rt: str) -> str:
    return RUNTIME_LABELS.get(str(rt or ""), str(rt or "that AI"))


def _tmux_path() -> str | None:
    """Where tmux is: the same tmux every spawn runs (``groups.tmux_bin``), so the check before a chat
    starts and the start itself agree. Tests replace this."""
    from .groups import tmux_bin

    return tmux_bin()


def _names(rts: list[str]) -> str:
    labels = [_label(r) for r in rts]
    return labels[0] if len(labels) == 1 else ", ".join(labels[:-1]) + " and " + labels[-1]


def recommended(goal: str = "") -> dict[str, Any]:
    """The lead policy's pick for a planning chat on this Mac (``wiring.plan_node('orchestrator')``), which
    respects what is installed and what the person switched off. What setup and Settings show as
    "Recommended" (``pong model plan --role orchestrator``) and what :func:`choose_runtime` starts with no
    pick are this one answer. ``runtime`` and ``model`` are None when nothing that can run a planning chat
    is left (Hermes alone cannot)."""
    from . import models as M
    from .wiring import plan_node

    if not M.available_runtimes():
        return {"runtime": None, "model": None, "role": "orchestrator", "rule": "none",
                "why": "No AI that can plan graphs is installed and switched on."}
    p = plan_node("orchestrator", goal, session=None)
    if p.get("runtime") not in ARCHITECT_RUNTIMES:
        p = {**p, "runtime": None, "model": None}
    return p


def choose_runtime(runtime: str | None = None, model: str | None = None, *, goal: str = "") -> dict[str, Any]:
    """The AI and model a new architect runs on, and where the choice came from.

    Precedence: what the person passed (``--runtime``/``--model``), then the default they saved in Settings
    (``settings.json`` ``architect``), then the model catalog's lead policy (:func:`recommended`). A saved
    model is used only with its own runtime, and a model that belongs to another runtime is dropped rather
    than put on a seat that cannot run it. A saved default that cannot run here (switched off, not
    installed, Hermes) is passed over for the lead policy, with a plain ``note``. Raises
    :class:`ArchitectError` in plain words when the AI the person passed, or the only one left, cannot run
    an architect: not installed, switched off in Settings (said so, never "install it"), or Hermes (it
    can't take its first message on the command line)."""
    from . import models as M

    rt = str(runtime or "").strip().lower()
    md = str(model or "").strip()
    source = "you" if (rt or md) else ""
    note = ""
    if md and not rt:  # "--model opus" alone means Claude's Opus, whatever the saved default runs on
        try:
            owners = [r for r, row in M.runtimes(None).items() if md.lower() in M._model_names(row)]
        except Exception:
            owners = []
        if len(owners) == 1:
            rt = owners[0]
    try:
        from .settings import ai_enabled, architect_default

        saved = architect_default()
    except Exception:  # pragma: no cover - settings ships with the package
        saved = {"runtime": "", "model": ""}

        def ai_enabled(_rt: str) -> bool:
            return True
    avail = M.available_runtimes()
    if not rt and saved.get("runtime"):
        why = _cannot_run(saved["runtime"], avail, ai_enabled)
        if why:
            note = (f"Your saved AI for planning graphs ({_label(saved['runtime'])}) {why}, "
                    f"so the recommended AI runs this chat.")
            saved = {"runtime": "", "model": ""}
        else:
            rt, source = saved["runtime"], source or "settings"
    if not md and saved.get("model") and (not saved.get("runtime") or saved.get("runtime") == rt):
        md, source = saved["model"], source or "settings"
    if rt and not ai_enabled(rt):
        raise ArchitectError(f"{_label(rt)} is switched off in Settings › AI accounts. Switch it on there, or pick another AI.")
    if not rt and not any(r in avail for r in ARCHITECT_RUNTIMES):
        # nothing left that can plan: an AI that is installed but switched off is not one to install again
        try:
            installed = M.installed_runtimes()
        except Exception:
            installed = set()
        off = [r for r in ARCHITECT_RUNTIMES if r in installed and not ai_enabled(r)]
        if off:
            raise ArchitectError(f"{_names(off)} {'is' if len(off) == 1 else 'are'} switched off in Settings › "
                                 f"AI accounts. Switch {'it' if len(off) == 1 else 'one'} on there to plan graphs.")
    planned = ""
    if not rt:
        if not avail:
            from .doctor import AIS

            raise ArchitectError("No AI is installed on this Mac yet. Install Claude Code first "
                                 f"({AIS['claude']['install']}), sign in, then try again.")
        try:
            planned = str(recommended(goal).get("runtime") or "")
        except Exception:
            planned = ""
        if not planned and "hermes" in avail and not any(r in avail for r in ARCHITECT_RUNTIMES):
            planned = "hermes"  # the only AI left: refused below, in its own words
        source = source or "policy"
    eff = rt or planned
    if eff == "hermes":
        if not rt and not any(r in avail for r in ARCHITECT_RUNTIMES):  # the policy had nothing else to pick
            from .doctor import AIS

            raise ArchitectError("Hermes can't plan graphs yet. "
                                 f"Install Claude Code ({AIS['claude']['install']}), sign in, then try again.")
        raise ArchitectError("Hermes can't plan graphs yet. Pick Claude Code, Grok Build or Codex for this chat.")
    if eff and eff not in avail:
        raise ArchitectError(f"{_label(eff)} isn't installed on this Mac. Install it, or pick another AI.")
    if md and eff:
        try:
            if M._belongs_elsewhere(M.runtimes(None), eff, md):
                md = ""
        except Exception:
            pass
    return {"runtime": rt or None, "model": md or None, "effective": eff or None, "source": source, "note": note}


def _cannot_run(rt: str, avail: set[str], ai_enabled: Any) -> str:
    """Why *rt* cannot run an architect on this Mac, in words, or ''."""
    if not ai_enabled(rt):
        return "is switched off in Settings"
    if rt not in ARCHITECT_RUNTIMES:
        return "can't plan graphs yet"
    if rt not in avail:
        return "isn't installed on this Mac"
    return ""


def _preflight(runtime: str | None, model: str | None, *, goal: str) -> dict[str, Any]:
    """What must be true before an architect is started: an AI that can run it, and tmux to run it in."""
    from .groups import isolated_home

    pick = choose_runtime(runtime, model, goal=goal)
    if not isolated_home() and not _tmux_path():
        raise ArchitectError("tmux isn't installed, so the chat has no terminal to run in. " + _tmux_fix())
    return pick


def _tmux_fix() -> str:
    """How to install tmux, Homebrew first when it isn't there (``pong doctor`` says the same)."""
    try:
        from .models import find_binary

        brew = find_binary("brew")
    except Exception:
        brew = None
    if brew:
        return "Run this in Terminal: brew install tmux. Then try again."
    return "Install Homebrew (https://brew.sh), then run: brew install tmux. Then try again."


def _started(note: str, spawned: bool) -> bool:
    return bool(spawned) or note.startswith("pane already live")


def new(title: str, project: str, *, runtime: str | None = None, model: str | None = None,
        brief: str = "") -> dict[str, Any]:
    """A project of its own: a new team whose lead seat is the architect, working in ``project``.

    ``runtime`` (claude, grok, codex) and ``model`` are the person's pick; unset, the default saved in
    Settings, then the lead policy of the model catalog, as for any team's lead (:func:`choose_runtime`).
    Nothing is created when the chat could not start: no AI that can run it, no tmux, or a tmux that would
    not open the team's terminal session (the team just made is taken back, and the reason raised)."""
    from .composer import _next_team_name, _undo_team, new_team
    from .groups import isolated_home
    from .jsonutil import read_json
    from .paths import active_path, ensure_layout, resolved_folder

    title = str(title or "").strip() or "New graph"
    # absolute and resolved ("." would be read from wherever the runner or the app runs)
    project = resolved_folder(project)
    if not project or not os.path.isdir(project):
        raise ArchitectError(f"the project folder {project!r} does not exist")
    goal = f"Graphs for {title}, designed and run by its architect."
    pick = _preflight(runtime, model, goal=goal)
    prev_active = read_json(active_path()) or None
    session = _next_team_name()
    ensure_layout(session)
    arch_id = _new_id()
    prompt = _write_prompt(session, arch_id, title=title, seat="c1", cwd=project)
    proposal = {"title": title, "goal": goal,
                "team": {"mode": "new", "project_root": project},
                "pins": {"lead": pick["runtime"]} if pick["runtime"] else {}, "lead_model": pick["model"] or "",
                "designed_by": "architect"}
    pair = new_team(proposal, session=session, initial_prompt=_pointer(title, prompt, brief))
    lead = pair.get("conductor") or {}
    spawn = pair.get("_spawn") or {}
    if not spawn.get("tmux") and not isolated_home():
        # a team with no terminal would be a dead chat reported as made, and every retry another one
        _undo_team(session, prev_active)
        note = str(spawn.get("note") or "")
        why = note[note.find("(") + 1:].rstrip(")") if "(" in note else ""
        raise ArchitectError("The chat's terminal could not start" + (f" ({why[:160]})" if why else "")
                             + ". Nothing was made. Check that tmux runs in Terminal (tmux -V), then try again.")
    rec = {"id": arch_id, "title": title, "seat": "c1", "cwd": project, "prompt_path": str(prompt),
           "runtime": lead.get("type"), "model": lead.get("model"),
           "graphs": [], "queue": [], "seen": {}, "created_at": time.time(),
           "spawn_note": str(spawn.get("note") or ""), "lead": True}
    with _locked(session) as data:
        data["architects"].append(rec)
    return {"ok": True, "session": session, **summary(session, rec), "spawn_note": rec["spawn_note"],
            "started": bool(spawn.get("tmux")), "chosen_by": pick["source"], "choice_note": pick["note"]}


def _open_team_session(session: str, state: dict[str, Any] | None = None) -> None:
    """A team whose terminal session is closed (a restart, a team closed by hand) gets an empty one back,
    its first window where the lead goes, as a new team's is, in the team's project folder (*state*'s). The
    lead is not started: that is the Team page's Launch team. Without it a chat on an existing team could
    not open."""
    from .groups import _tmux, isolated_home, session_exists, start_dir_args

    if not isolated_home() and not session_exists(session):
        _tmux("new-session", "-d", "-s", session, "-n", "lead", *start_dir_args(state))


def start(session: str, title: str = "", *, cwd: str = "", graph_id: str = "", runtime: str | None = None,
          model: str | None = None, brief: str = "") -> dict[str, Any]:
    """An architect seat in a team that already exists (``<owner>.arch``), optionally for one graph.

    Its AI and model follow the same precedence as :func:`new`: what the person passed, then the default
    saved in Settings, then the lead policy. Refused, with nothing written, when the team's terminal session
    cannot be opened."""
    from .groups import ensure_ephemeral_window, isolated_home, session_exists
    from .state import load_session_state
    from .work_graph import _synthetic_worker

    state = dict(load_session_state(session) or {})
    if not state:
        raise ArchitectError(f"no team {session!r}")
    pick = _preflight(runtime, model, goal=str(title or ""))
    runtime, model = pick["runtime"], pick["model"]
    _open_team_session(session, state)
    if not isolated_home() and not session_exists(session):
        raise ArchitectError("The chat's terminal could not start: tmux would not open this team's session. "
                             "Check that tmux runs in Terminal (tmux -V), then try again.")
    state.setdefault("session", session)
    owner = str((state.get("conductor") or {}).get("id") or "c1")
    taken = {str(a.get("seat") or "") for a in list_for(session) if _alive(session, str(a.get("seat") or ""))}
    seat, n = f"{owner}.arch", 2
    while seat in taken:
        seat, n = f"{owner}.arch{n}", n + 1
    title = str(title or "").strip() or (f"graph {graph_id}" if graph_id else str(state.get("display_name") or session))
    from .paths import resolved_folder

    root = resolved_folder(cwd or state.get("project_root") or "")
    arch_id = _new_id()
    prompt = _write_prompt(session, arch_id, title=title, seat=seat, cwd=root, graph_id=graph_id)
    # The lead's policy picks its model: an architect plans and routes, which is what the lead seat does.
    # With no pin (nothing passed, nothing saved) the policy also picks the runtime.
    worker = _synthetic_worker(seat, owner, "orchestrator", task=title, session=session, pin=runtime or pick["effective"],
                               mission="orchestrator", wire_role="orchestrator")
    worker["label"] = f"architect:{seat}"
    if model and not _model_elsewhere(str(worker.get("type") or ""), model):
        worker["model"] = model  # a seat's own model wins over the catalog's rules (models.plan_for_worker)
    if root and os.path.isdir(root):
        state["project_root"] = root
    out = ensure_ephemeral_window(state, worker, task=title, initial_prompt=_pointer(title, prompt, brief))
    note = str(out.get("note") or ("spawned" if out.get("spawned") else ""))
    rec = {"id": arch_id, "title": title, "seat": seat, "cwd": root, "prompt_path": str(prompt),
           "runtime": worker.get("type"), "model": worker.get("model"),
           "graphs": [graph_id] if graph_id else [], "queue": [], "seen": {}, "created_at": time.time(),
           "spawn_note": note, "lead": False}
    with _locked(session) as data:
        data["architects"].append(rec)
    return {"ok": True, "session": session, **summary(session, rec), "spawn_note": rec["spawn_note"],
            "started": _started(note, bool(out.get("spawned"))), "chosen_by": pick["source"],
            "choice_note": pick["note"]}


def _model_elsewhere(runtime: str, model: str) -> bool:
    try:
        from . import models as M

        return M._belongs_elsewhere(M.runtimes(None), runtime, model)
    except Exception:
        return False


def link(session: str, arch_id: str, graph_id: str) -> dict[str, Any]:
    with _locked(session) as data:
        for a in data["architects"]:
            if a.get("id") == arch_id:
                if graph_id not in (a.get("graphs") or []):
                    a.setdefault("graphs", []).append(graph_id)
                return summary(session, a)
    raise ArchitectError(f"no architect {arch_id!r} on {session}")


def link_by_seat(session: str, seat: str, graph_id: str) -> str | None:
    """A graph attached from an architect's own pane belongs to that architect (``PONG_SEAT`` names it)."""
    seat = str(seat or "").strip()
    if not seat or not graph_id or not _path(session).exists():
        return None
    for a in reversed(list_for(session)):  # newest first: a dead architect's seat name can be reused
        if a.get("seat") == seat:
            link(session, str(a["id"]), graph_id)
            return str(a["id"])
    return None


# ------------------------------------------------------------------ chat ---

def screen(session: str, arch_id: str, *, lines: int = 200) -> dict[str, Any]:
    a = get(session, arch_id)
    seat = str(a.get("seat") or "")
    text = _capture(session, seat, lines)
    busy = text is not None and not idle_and_empty(text)
    return {"id": arch_id, "session": session, "seat": seat, "alive": text is not None, "text": text or "",
            "busy": busy, "queued": len(a.get("queue") or []),
            "note": "" if text is not None else "the architect's pane is gone: start a new chat for this graph"}


def send(session: str, arch_id: str, text: str) -> bool:
    """A person's message from the app. One line: an Enter in the middle would send half of it."""
    text = " ".join(str(text or "").split())
    if not text:
        return False
    ok = _type(session, str(get(session, arch_id).get("seat") or ""), text[:4000])
    _chat_log(session, arch_id, "person", text[:4000], delivered=ok)
    return ok


def note(session: str, arch_id: str, text: str, *, who: str = "person") -> None:
    """Log a line the person typed straight into the terminal view (the app sends keystrokes to tmux
    itself, so nothing else sees the line whole). The AI's own transcript has it too."""
    get(session, arch_id)
    _chat_log(session, arch_id, who, " ".join(str(text or "").split())[:4000], via="terminal")


def key(session: str, arch_id: str, name: str) -> bool:
    k = KEYS.get(str(name or "").strip().lower())
    if not k:
        raise ArchitectError(f"unknown key {name!r} (one of: {', '.join(KEYS)})")
    ok = _press(session, str(get(session, arch_id).get("seat") or ""), k)
    _chat_log(session, arch_id, "key", str(name).lower(), delivered=ok)
    return ok


# ------------------------------------------------------------------ events ---

def queue_event(session: str, graph: dict[str, Any], *, kind: str, summary_text: str) -> None:
    """Called where the engine posts to a graph's owner. Best effort: the tick never fails on it."""
    gid = str(graph.get("id") or "")
    if not gid or not _path(session).exists():
        return
    title = str(graph.get("title") or graph.get("name") or "")
    line = f"{gid}{' (' + title + ')' if title else ''}: {kind}: {' '.join(str(summary_text or '').split())[:300]}"
    with _locked(session) as data:
        for a in data["architects"]:
            if gid in (a.get("graphs") or []):
                q = a.setdefault("queue", [])
                q.append({"at": time.time(), "kind": kind, "graph": gid, "text": line})
                del q[:-MAX_QUEUE]


def _quiet_events(session: str, graphs: list[dict[str, Any]], a: dict[str, Any], now: float) -> list[dict[str, Any]]:
    out = []
    seen = a.setdefault("seen", {})
    for g in graphs:
        gid = str(g.get("id") or "")
        if gid not in (a.get("graphs") or []) or str(g.get("status") or "") != "running":
            continue
        for n in g.get("nodes") or []:
            if not isinstance(n, dict) or str(n.get("status") or "") != "running":
                continue
            lv = n.get("live") if isinstance(n.get("live"), dict) else {}
            changed = float(lv.get("changed_at") or 0)
            if lv.get("state") == "quiet" and changed and now - changed > QUIET_S:
                k = f"{gid}|{n.get('id')}|quiet"
                if now - float(seen.get(k) or 0) > REQUEUE_QUIET_S:
                    seen[k] = now
                    mins = int((now - changed) // 60)
                    out.append({"at": now, "kind": "quiet", "graph": gid,
                                "text": f"{gid}: quiet: {n.get('id')} on {n.get('seat')} has shown nothing new for {mins} min"})
    return out


def pump(session: str, graphs: list[dict[str, Any]] | None = None) -> list[str]:
    """Deliver each architect's queue as one line when it is idle and nobody is typing. Returns what went out."""
    if not _path(session).exists():
        return []
    now = time.time()
    sent: list[str] = []
    with _locked(session) as data:
        for a in data["architects"]:
            if graphs:
                a.setdefault("queue", []).extend(_quiet_events(session, graphs, a, now))
            q = a.get("queue") or []
            if not q:
                continue
            seat = str(a.get("seat") or "")
            text = _capture(session, seat, 40)
            if text is None or not idle_and_empty(text):
                continue
            head = "[CyberPong] " + " | ".join(e["text"] for e in q)
            if len(head) > MAX_LINE:
                shown, used = [], len("[CyberPong] ")
                for e in q:
                    if used + len(e["text"]) + 3 > MAX_LINE - 60:
                        break
                    shown.append(e["text"])
                    used += len(e["text"]) + 3
                rest = len(q) - len(shown)
                head = "[CyberPong] " + " | ".join(shown) + f" | and {rest} more: `pong architect events --id {a['id']}`"
            if _type(session, seat, head):
                a["delivered"] = (list(a.get("delivered") or []) + q)[-80:]
                a["queue"] = []
                a["last_delivered_at"] = now
                sent.append(f"{a['id']}: {len(q)} event(s)")
                _chat_log(session, str(a["id"]), "cyberpong", head, events=len(q))
                by_id = {str(g.get("id") or ""): g for g in graphs or []}
                from .graph_log import append as _log_append

                for gid in sorted({str(e.get("graph") or "") for e in q}):
                    if gid in by_id:
                        _log_append(by_id[gid], "architect_delivery", architect=a["id"], seat=seat,
                                    events=[e["text"] for e in q if e.get("graph") == gid])
    return sent
