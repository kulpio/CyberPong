"""Coding groups — a lead seat and the seats that report to it.

A team can carry several coding groups: Engineering — CyberPong, — Website,
— Projects, each a lead plus its own reviewer, migrator and fixer. c1 delegates
to the leads; children claim back to their lead and nowhere else.

Two things a group needs that nothing else in the control plane owns:

* **Its seats have to exist.** The roster can name w25–w32 long before any tmux
  window or single-seat view session does. Spawning is idempotent here — an
  existing window is left exactly as it is, because the alternative is killing a
  running agent to recreate something already correct.

* **It has to be able to start a new project without disturbing the rest of the
  team.** Resetting the whole session to give one group a clean slate would take
  twenty-odd other seats down with it. `new_project` saves a continuity recap
  first, then restarts only that group's panes and hands the recap back as their
  first message, so the new project starts knowing what the old one learned.

Nothing here ever touches a protected seat: one whose label holds a word listed
under ``protected_labels`` in settings.json (a person's own seat that is not part
of any product group, say). None is protected by default; the guard is explicit
rather than assumed from the roster shape.
"""

from __future__ import annotations

import os
import subprocess
import time
from pathlib import Path
from typing import Any


def protected_labels() -> tuple[str, ...]:
    """Seat labels never swept up in a group operation, whatever the roster says
    (settings.json ``protected_labels``; none by default)."""
    from .settings import protected_labels as _labels

    return _labels()


_TMUX_BIN: str | None = None


def tmux_bin() -> str | None:
    """Where tmux is: PATH plus the Homebrew and CLI folders (``models.search_path``), so a tmux that
    Homebrew installed but the shell's PATH does not reach (its "Next steps" skipped) is the one every
    call runs, and the one ``architect``'s check found. Kept once found; looked for again until then,
    and again when the one kept is gone (uninstalled, moved), so a long-running process follows it."""
    global _TMUX_BIN
    if not _TMUX_BIN or not os.access(_TMUX_BIN, os.X_OK):
        try:
            from .models import find_binary

            _TMUX_BIN = find_binary("tmux")
        except Exception:
            _TMUX_BIN = None
    return _TMUX_BIN


def _tmux(*args: str) -> tuple[bool, str]:
    try:
        r = subprocess.run([tmux_bin() or "tmux", *args], text=True, capture_output=True, timeout=20)
        return r.returncode == 0, ((r.stdout or "") + (r.stderr or "")).strip()
    except Exception as e:  # tmux missing or wedged — caller reports it
        return False, str(e)


def start_dir(state: dict[str, Any] | None) -> str:
    """The folder a team's new terminal opens in: its project folder, else the home folder.

    tmux run from outside tmux opens a new session or window in the folder the command was run from, and
    the app runs every command from ``/``: a chat made from the New graph sheet started Claude Code at the
    disk root (where it stops to ask whether to trust that folder) instead of in the project. A relative
    folder (a team made before 2.0 with ``--project .``) says nothing about where it was: the home folder."""
    root = os.path.expanduser(str((state or {}).get("project_root") or "").strip())
    return root if os.path.isabs(root) and os.path.isdir(root) else str(Path.home())


def start_dir_args(state: dict[str, Any] | None) -> list[str]:
    """``-c <folder>`` for a ``new-session`` / ``new-window`` of this team (:func:`start_dir`)."""
    return ["-c", start_dir(state)]


def session_exists(name: str) -> bool:
    # "=name:" is an exact session match. A bare name is split at "." into
    # window.pane, so a seat view like "pong-team-90-c1.b" was never found
    # ("can't find pane: b"), and a bare name also matches by prefix.
    ok, _ = _tmux("has-session", "-t", f"={name}:")
    return ok


def window_exists(session: str, idx: int) -> bool:
    ok, out = _tmux("list-windows", "-t", session, "-F", "#{window_index}")
    return ok and str(idx) in out.split()


def view_name(session: str, seat_id: str) -> str:
    """Seat-id naming, matching TerminalTheme.viewToken on the Swift side."""
    return f"{session}-{seat_id}"


def is_protected(worker: dict[str, Any], labels: tuple[str, ...] | None = None) -> bool:
    label = str(worker.get("label") or "").lower()
    return any(p in label for p in (protected_labels() if labels is None else labels))


def group_members(state: dict[str, Any], lead_id: str) -> list[dict[str, Any]]:
    """The lead plus every seat whose parent is that lead, lead first."""
    from .state import workers_from_state

    lead = None
    kids: list[dict[str, Any]] = []
    for w in workers_from_state(state):
        wid = str(w.get("id") or "")
        if wid == lead_id:
            lead = w
        elif str(w.get("parent_id") or "") == lead_id:
            kids.append(w)
    if lead is None:
        return []
    return [lead, *sorted(kids, key=lambda w: str(w.get("id") or ""))]


def assert_is_lead(state: dict[str, Any], lead_id: str) -> list[dict[str, Any]]:
    """A group is addressed by its lead. Refuse anything else, loudly."""
    members = group_members(state, lead_id)
    if not members:
        raise ValueError(f"no such seat on this team: {lead_id}")
    lead = members[0]
    if str(lead.get("parent_id") or ""):
        raise ValueError(
            f"{lead_id} reports to {lead.get('parent_id')} — address the group by "
            "its lead, not by one of its children"
        )
    keep = protected_labels()
    protected = [str(m.get("id")) for m in members if is_protected(m, keep)]
    if protected:
        raise ValueError(f"refusing: group contains a protected seat ({', '.join(protected)})")
    return members


def model_plan(worker: dict[str, Any], *, task: str = "", session: str | None = None):
    """Runtime + model this seat should run on, with the reason attached.

    The policy tables that used to sit here — role→model defaults and the CLI
    alias map — now live in ``models/catalog.json`` so one file answers the
    question for the roster, for disposable loop seats, and for the app. See
    :mod:`pong.models`.
    """
    from .models import plan_for_worker

    return plan_for_worker(worker, task=task, session=session)


def model_for(worker: dict[str, Any]) -> str | None:
    """The model id a seat should be pointed at, as its CLI wants to hear it.

    A roster label like "opus 5" comes back as ``opus``; unknown names pass
    through so a model that ships today works today. ``None`` only when the
    catalog has no model for that runtime at all.
    """
    try:
        return model_plan(worker).model
    except Exception:
        # A broken or missing catalog must not stop a seat from coming up.
        stored = str(worker.get("model") or "").strip()
        return stored or None


def send_model_command(session: str, worker: dict[str, Any]) -> str:
    """Switch a seat that is already up onto the model it should be running.

    New seats no longer need this — :func:`_launch_command` puts ``--model`` on
    the launch line, which is deterministic in a way that typing into a TUI is
    not. This stays for a pane that is already live, and only once it has
    settled: the same readiness gate the recap seeding uses, and for the same
    reason. Typing into a launcher that is still drawing, or that is asking its
    own startup question, is how a seat gets told something it never meant to
    hear.

    Runtimes with no in-TUI switch (Grok Build) are left alone — sending
    ``/model`` there posts the literal text as a prompt.
    """
    from .models import model_command

    seat = str(worker.get("id") or "")
    plan = model_plan(worker, session=session)
    switch = model_command(plan.runtime, plan.model, session)
    if not switch:
        return f"{seat}: {plan.label} has no in-TUI switch — left on its default"
    model = plan.model
    if isolated_home():
        return f"{seat}: isolated PONG_HOME — not typing into the live tmux server"
    idx = worker.get("tmux_index")
    if not isinstance(idx, int) or not window_exists(session, idx):
        return f"{seat}: no live window — model not set"
    ready, why = _pane_ready(session, idx)
    if not ready:
        return f"{seat}: model not set — {why}"
    target = f"{session}:{idx}"
    _tmux("send-keys", "-t", target, "-l", switch)
    time.sleep(0.08)
    _tmux("send-keys", "-t", target, "Enter")
    time.sleep(1.5)

    # A seat with cached history asks before switching, because the switch costs
    # it a re-read of the conversation. That dialog is this command's own
    # confirmation — answering it completes the action we were asked to take,
    # which is a different thing from answering a question the agent raised on
    # its own, and those are still refused by the readiness gate above.
    pane = _capture(target)
    if "switch model?" in pane.lower() and "yes, switch to" in pane.lower():
        _tmux("send-keys", "-t", target, "-l", "1")
        time.sleep(0.1)
        _tmux("send-keys", "-t", target, "Enter")
        time.sleep(1.5)
        pane = _capture(target)

    # Report the EFFECT, not the keystroke. "It was typed" is not evidence that
    # the model changed, and a rejected alias looks identical from the outside.
    low = pane.lower()
    if f"model '{model.lower()}' not found" in low or "not found" in low.split("/model")[-1][:80]:
        return f"{seat}: REFUSED — the CLI does not know a model called {model!r}"
    for line in reversed(pane.split("\n")):
        if "set model to" in line.lower():
            return f"{seat}: {line.strip().lstrip('⎿ ').strip()}"
    return f"{seat}: `{switch}` sent, but no confirmation appeared — check the pane"


def _capture(target: str) -> str:
    ok, out = _tmux("capture-pane", "-p", "-J", "-t", target, "-S", "-25")
    return out if ok else ""


#: CLIs that take the first message as an argument, so a new seat can start on
#: its job without anything being pasted into a TUI that is still drawing.
INITIAL_PROMPT_RUNTIMES = ("claude", "grok", "codex")

#: The first thing a seat's shell runs: the folders `pong` and the AI CLIs install into, ahead of
#: whatever PATH the tmux server inherited. A tmux server a person started from a bare shell (or one
#: launchd started) had no ~/bin, so a seat could not run `pong job claim` or even find its own CLI.
SEAT_PATH = 'export PATH="$HOME/bin:$HOME/.local/bin:$HOME/.grok/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"'


def _dq(s: str) -> str:
    """*s* as it may sit inside a double-quoted shell word."""
    return s.replace("\\", "\\\\").replace('"', '\\"').replace("$", "\\$").replace("`", "\\`")


def seat_path(runtime: str = "") -> str:
    """:data:`SEAT_PATH`, with the other folders an AI CLI was found in ahead of the inherited PATH: nvm's
    node versions, volta, bun, an npm prefix (``models.cli_dirs``), and the folder of this seat's own
    CLI. An npm CLI starts with ``#!/usr/bin/env node`` and its node sits in that same folder; a seat
    starts under ``bash -lc``, which never reads ``~/.zshrc`` where nvm sets PATH up."""
    home = str(Path.home())
    known = {f"{home}/bin", f"{home}/.local/bin", f"{home}/.grok/bin", "/opt/homebrew/bin", "/usr/local/bin"}
    extra: list[str] = []
    try:
        from .models import cli_dirs, find_binary, runtime_binary

        dirs = list(cli_dirs())
        if runtime:
            own = find_binary(runtime_binary(runtime))
            if own:
                dirs.append(os.path.dirname(own))
    except Exception:
        dirs = []
    for d in dirs:
        if d and d not in known and d not in extra and ":" not in d and "\n" not in d:
            extra.append(d)
    if not extra:
        return SEAT_PATH
    return SEAT_PATH.replace(":$PATH", ":" + ":".join(_dq(d) for d in extra) + ":$PATH")


#: CLIs whose own "auto" permission mode a seat starts in when the person allowed it (Settings:
#: "Let the AIs work without stopping to ask permission"). Both still block risky actions themselves.
AUTO_PERMISSION_RUNTIMES = ("claude", "grok")
_OWN_PERMISSION_FLAGS = ("--permission-mode", "--dangerously", "--always-approve", "--allow-dangerously")


def permission_flags(runtime: str, cmd: str) -> list[str]:
    """``["--permission-mode", "auto"]`` for a Claude or Grok seat when Settings says ``seat_permissions:
    auto`` and the seat's own command sets no permission flag; otherwise nothing (each CLI asks, as before)."""
    if runtime not in AUTO_PERMISSION_RUNTIMES or any(f in str(cmd or "") for f in _OWN_PERMISSION_FLAGS):
        return []
    try:
        from .settings import seat_permissions

        return ["--permission-mode", "auto"] if seat_permissions() == "auto" else []
    except Exception:
        return []


#: Shell commands a seat without live tools may not run: they write to a git
#: repository (a research or planning graph reads code, it never commits it), or
#: reach a remote (GitHub, Supabase, Vercel, a database). Read commands (git log,
#: git show, git diff, git status, git blame) stay open. Matched as command
#: prefixes; writing files through the shell (`>`, `sed -i`, `cp`) is held by the
#: seat's instructions, and the project's Edit deny rules where a person set them.
NO_LIVE_SHELL = ("git checkout", "git switch", "git reset", "git stash", "git pull", "git push",
                 "git merge", "git rebase", "git commit", "git add", "git apply", "git am",
                 "git cherry-pick", "git revert", "git restore", "git clean", "git rm", "git mv",
                 "git tag", "git worktree", "git config", "git remote", "git fetch", "git branch -",
                 "git bisect", "git update-ref", "git clone", "git submodule",
                 # `git -C <dir> <verb>` would slip past every prefix above: a seat reads another
                 # repository with `cd <dir> && git log` instead (each part is checked on its own)
                 "git -C", "git --git-dir", "git --work-tree",
                 "gh", "supabase", "vercel", "psql", "curl", "wget",
                 # no packages fetched from the internet: code the graph writes runs on what the Mac has
                 "npx", "npm install", "npm ci", "npm add", "npm update", "pnpm", "yarn", "bunx", "bun add",
                 "pip install", "pip3 install", "python -m pip", "python3 -m pip", "uv pip", "uv add", "uv sync",
                 "uvx", "brew", "cargo install", "go install", "gem install")


def _launch_command(
    state: dict[str, Any], worker: dict[str, Any], *, task: str = "", initial_prompt: str = ""
) -> str:
    """What a seat's pane runs. Mirrors the exports CyberPong sends on spawn.

    The model goes on the launch line rather than being typed in afterwards.
    Both Claude Code and Grok Build take ``--model``, and a flag is settled
    before the first token; the ``/model`` dance had to wait for the TUI to
    settle, could hit a "switch model?" confirmation, and reported success on a
    keystroke rather than on the effect.
    """
    session = str(state.get("session") or "")
    seat = str(worker.get("id") or "")
    cmd = str(worker.get("cmd") or "").strip() or "claude"
    label = str(worker.get("label") or seat)
    if "--model" not in cmd and "-m " not in cmd:
        try:
            flags = model_plan(worker, task=task, session=session).flags
            if flags:
                cmd = " ".join([cmd] + flags)
        except Exception:
            pass  # a seat that comes up on its default beats a seat that does not
    parts = [
        seat_path(str(worker.get("type") or "")),
        f"export PONG_SESSION={session}",
        f"export HERMES_PONG_SESSION={session}",
        f"export PONG_SEAT={seat}",
    ]
    # The token is read from its 0600 file by the seat's own shell. Typing the
    # value itself left it in `ps` and in ~/.zsh_history (369 lines, 2026-09-24).
    if session:
        try:
            from .routing import session_token_path

            parts.append(f'export PONG_TOKEN="$(cat {_shq(str(session_token_path(session)))} 2>/dev/null)"')
        except Exception:
            pass
    rt = str(worker.get("type") or "")
    if worker.get("no_live_tools") and rt == "claude":
        # read before Claude Code starts: no claude.ai connectors (Gmail, Supabase, …) in this seat
        parts.append("export ENABLE_CLAUDEAI_MCP_SERVERS=false")
    banner = f"WORKER · {label} · {session}:{worker.get('tmux_index')}"
    parts.append(f'printf "\\n  {banner}\\n\\n"')
    # The prompt goes first (the CLI's positional), then Claude's --add-dir for
    # the team's state folder: the job's prompt file, the graph's notes and the
    # team's lessons live there, outside the project, and auto mode does not
    # cover reads outside the working folders (a seat stalled on exactly that,
    # 2026-09-23). --add-dir takes several values, so a flag must follow it —
    # which is why it sits before the model flag and never after the prompt.
    head, _, tail = cmd.partition(" ")
    pieces = [head]
    if initial_prompt and rt in INITIAL_PROMPT_RUNTIMES:
        pieces.append(_shq(initial_prompt))
    if rt == "claude" and session:
        from .paths import sessions_dir

        pieces += ["--add-dir", _shq(str(sessions_dir(session)))]
    if rt == "claude" and worker.get("no_live_tools"):
        pieces.append("--strict-mcp-config")  # no --mcp-config given: no MCP servers at all
        # and no shell route to a remote or a working tree that is not the seat's
        pieces += ["--disallowedTools", _shq(",".join(f"Bash({c}:*)" for c in NO_LIVE_SHELL))]
    if rt == "grok" and worker.get("no_live_tools"):
        pieces += ["--deny", "MCPTool"]  # a deny rule beats always-approve: every MCP call is refused
        for c in NO_LIVE_SHELL:
            pieces += ["--deny", _shq(f"Bash({c}*)")]
    # after the list-taking flags above (--add-dir, --disallowedTools): a flag ends their lists
    pieces += permission_flags(rt, cmd)
    if tail:
        pieces.append(tail)
    parts.append("exec " + " ".join(pieces))
    return "; ".join(parts)


#: A line typed into a pane goes through the terminal's line discipline, which keeps at
#: most MAX_CANON bytes of one line (1024 on macOS) and drops the rest. With the live-tools
#: denies a seat's launch line ran to about 2.9 KB, so the pane got a cut-off command with an
#: open quote and never started its model (2026-09-25). A longer line goes to a file under the
#: team's state folder and the pane sources that instead.
TYPED_LINE_MAX = 900


def launch_line(cmd: str, *, session: str, seat: str) -> str:
    """What to type into a pane to run ``cmd``: the command, or ``source <file>`` when it is long."""
    if len(cmd.encode()) <= TYPED_LINE_MAX or not session or not seat:
        return cmd
    try:
        from .paths import sessions_dir

        folder = sessions_dir(session) / "launch"
        folder.mkdir(parents=True, exist_ok=True)
        path = folder / f"{seat.replace('/', '_')}.sh"
        tmp = path.with_suffix(".sh.tmp")
        tmp.write_text(cmd + "\n")
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    except OSError:
        return cmd  # a cut-off line shows in the pane; no line at all would not
    return f"source {_shq(str(path))}"


def type_launch(target: str, cmd: str, *, session: str, seat: str) -> None:
    """Type a seat's launch command into ``target`` and press Enter."""
    _tmux("send-keys", "-t", target, "-l", launch_line(cmd, session=session, seat=seat))
    time.sleep(0.08)
    _tmux("send-keys", "-t", target, "Enter")


def ensure_seat_window(state: dict[str, Any], worker: dict[str, Any]) -> str:
    """Create this seat's pane if it has none. Never disturbs a live one."""
    session = str(state.get("session") or "")
    seat = str(worker.get("id") or "")
    idx = worker.get("tmux_index")
    if not isinstance(idx, int):
        return f"{seat}: no tmux_index on the roster — skipped"
    if isolated_home():
        return f"{seat}: isolated PONG_HOME — not spawning into the live tmux server"
    if window_exists(session, idx):
        return f"{seat}: window {idx} already there — left alone"
    label = str(worker.get("label") or seat).replace("'", "")
    ok, out = _tmux("new-window", "-d", "-t", f"{session}:{idx}", "-n", label, *start_dir_args(state))
    if not ok:
        return f"{seat}: new-window failed — {out}"
    type_launch(f"{session}:{idx}", _launch_command(state, worker), session=session, seat=seat)
    return f"{seat}: spawned window {idx}"


def ensure_view_session(state: dict[str, Any], worker: dict[str, Any]) -> str:
    """One single-window view session per seat, named for the seat id.

    Linking one window rather than joining the session group matters: a grouped
    client can page through every seat, so a click on the status bar lands you
    in somebody else's agent.
    """
    session = str(state.get("session") or "")
    seat = str(worker.get("id") or "")
    idx = worker.get("tmux_index")
    wid = str(worker.get("window_id") or "")
    # A window id ("@12") names the seat's window in every session it is linked into. An
    # index asked of the pane is the view's own 0 once the seat has been opened, and
    # "team:0" is the lead: a second open linked the lead into the seat's view.
    source = wid if wid.startswith("@") else (f"={session}:{idx}" if isinstance(idx, int) else "")
    if not source:
        return f"{seat}: no tmux_index — no view session"
    view = view_name(session, seat)
    if session_exists(view):
        _tmux("link-window", "-dk", "-s", source, "-t", f"={view}:0")
        return f"{seat}: view {view} already there — relinked"
    # its placeholder window is replaced by the seat's own at once; it still opens in the team's folder
    ok, out = _tmux("new-session", "-d", "-s", view, "-n", "seat", *start_dir_args(state))
    if not ok:
        return f"{seat}: view session failed — {out}"
    _tmux("link-window", "-dk", "-s", source, "-t", f"={view}:0")
    _tmux("select-window", "-t", f"={view}:0")
    return f"{seat}: view {view} created"


def isolated_home() -> bool:
    """True when ``PONG_HOME`` points somewhere other than the live ``~/.pong``.

    tmux has no equivalent of ``PONG_HOME``: a test that redirects state to a
    temp directory still talks to the one tmux server on the machine, so a spawn
    helper called from a test lands real windows in the human's real team. That
    is not hypothetical — the first run of the loop-spawn tests opened eighteen
    of them in ``pong-team``. Anything that mutates tmux checks this first.
    """
    home = (os.environ.get("PONG_HOME") or "").strip()
    if not home:
        return False
    try:
        return Path(home).expanduser().resolve() != (Path.home() / ".pong").resolve()
    except OSError:
        return True


def _pane_alive(pane_id: str) -> bool:
    if not pane_id:
        return False
    # tmux exits 0 for a pane that no longer exists (it prints "can't find pane"
    # on stderr and nothing on stdout), so a dead seat looked alive and was never
    # respawned (2026-09-23: c1.d stayed registered to a closed pane for an hour).
    # Alive means tmux echoes the same pane id back.
    ok, out = _tmux("display-message", "-t", pane_id, "-p", "#{pane_id}")
    return ok and out.strip() == pane_id


def pane_owned(pane_id: str, session: str, seat: str) -> bool:
    """The pane exists, sits in *session*, and its window is this seat's.

    tmux reuses pane ids after its server restarts, so a stale id in panes.json
    can name another seat's live pane (2026-09-24: a retire closed another
    team's builder that way). Ephemeral windows are named ``<role>:<seat>`` with
    automatic rename off, so the name is the proof.
    """
    if not pane_id or not session or not seat:
        return False
    # Membership, not the session tmux resolves the pane to: once a person opens a
    # seat, its window is linked into a view session too, and display-message then
    # names the view. The seat read as gone and its step was cancelled and run again
    # (a review step, 47 s after someone opened it).
    # a space, not a tab: tmux prints a tab as "_" to a client without a UTF-8 locale
    ok, out = _tmux("list-panes", "-s", "-t", f"={session}:", "-F", "#{pane_id} #{window_name}")
    if not ok:
        return False
    for row in out.splitlines():
        pid, _, name = row.partition(" ")
        if pid.strip() == pane_id:
            name = name.strip()
            return name == seat or name.endswith(":" + seat)
    return False


def _free_window_index(session: str, *, start: int = 1, limit: int = 200) -> int | None:
    ok, out = _tmux("list-windows", "-t", session, "-F", "#{window_index}")
    if not ok:
        return None
    used = {int(x) for x in out.split() if x.strip().isdigit()}
    for i in range(start, start + limit):
        if i not in used:
            return i
    return None


def ensure_ephemeral_window(
    state: dict[str, Any], worker: dict[str, Any], *, task: str = "", initial_prompt: str = ""
) -> dict[str, Any]:
    """Give a disposable work-graph seat a real terminal.

    Roster seats carry a ``tmux_index`` a human picked; a loop seat like
    ``w16.a`` exists only for as long as the loop does, so it has none and
    :func:`ensure_seat_window` skips it. Without this the whole spawn path ends
    at ``no pane_id registration for worker 'w16.a' (refusing default index)``:
    the job file is written, the paste is refused, and the loop sits at
    ``running`` forever with nobody in the chair. The refusal is correct — never
    guess an index — so the fix is to allocate one and register it.

    Idempotent: a seat whose registered pane is still alive is left exactly as
    it is.
    """
    session = str(state.get("session") or "")
    seat = str(worker.get("id") or "").strip()
    out: dict[str, Any] = {"seat": seat, "spawned": False, "pane_id": "", "note": ""}
    if not session or not seat:
        out["note"] = "no session or seat"
        return out
    if isolated_home():
        out["note"] = "isolated PONG_HOME — refusing to spawn into the live tmux server"
        return out
    if not session_exists(session):
        out["note"] = f"tmux session {session!r} is not running"
        return out

    from .routing import exact_window_title, load_pane_registration, register_worker_pane

    reg = load_pane_registration(session, seat) or {}
    pane_id = str(reg.get("pane_id") or worker.get("pane_id") or "")
    if pane_owned(pane_id, session, seat):
        out.update(pane_id=pane_id, note="pane already live — left alone")
        return out

    idx = worker.get("tmux_index")
    if not isinstance(idx, int) or window_exists(session, idx):
        # Disposable seats take indices from 50 up: the roster's seats live low,
        # and a graph window that took index 2 received w2's paste (the index
        # fallback in flow guesses by number).
        idx = _free_window_index(session, start=50)
    if idx is None:
        out["note"] = "no free tmux window index"
        return out

    label = str(worker.get("label") or seat).replace("'", "")[:40]
    # Start the pane in the team's project root. A Claude Code seat treats every
    # read or write outside its working directory as a permission question, so a
    # seat spawned from wherever `pong` happened to run sat on "Allow reads outside
    # the working directories?" for an hour (2026-09-23) instead of doing its job.
    # With no project folder, the home folder: never the folder `pong` was run from (the app's is /).
    cwd_args = start_dir_args(state)
    # A step's whole terminal is saved when it ends (graph_log.save_pane), and tmux keeps 2,000 lines by
    # default: a research step scrolls past that in minutes. The team's own session only, never -g.
    _tmux("set-option", "-t", f"={session}", "history-limit", "50000")
    ok, err = _tmux("new-window", "-d", "-t", f"{session}:{idx}", "-n", label, *cwd_args)
    if not ok:
        out["note"] = f"new-window failed — {err}"
        return out
    target = f"{session}:{idx}"
    ok, live = _tmux("display-message", "-t", target, "-p", "#{pane_id}")
    pane_id = live.strip() if ok else ""
    if not pane_id:
        out["note"] = "window created but tmux reported no pane id"
        return out

    worker = dict(worker)
    worker["tmux_index"] = idx
    worker["pane_id"] = pane_id
    cmd = _launch_command(state, worker, task=task, initial_prompt=initial_prompt)
    type_launch(target, cmd, session=session, seat=seat)
    out["with_prompt"] = bool(initial_prompt) and str(worker.get("type") or "") in INITIAL_PROMPT_RUNTIMES
    register_worker_pane(
        session,
        seat,
        pane_id=pane_id,
        start_command=str(worker.get("cmd") or ""),
        title=exact_window_title(session, seat),
    )
    out.update(
        spawned=True,
        pane_id=pane_id,
        tmux_index=idx,
        note=f"spawned window {idx} ({pane_id})",
        launch=cmd,
    )
    return out


def retire_ephemeral_window(session: str, seat: str) -> str:
    """Close a disposable seat's pane so the next dispatch spawns a fresh one.

    A graph node gets a clean context this way: a critic re-grading round three
    must not remember what it thought of round two, and a seat name like
    ``c1.c`` is reused by the next graph under the same owner. Only ephemeral
    children of a main are ever passed here; a person's roster seat is theirs.
    """
    seat = str(seat or "").strip()
    if not session or "." not in seat:
        return "not an ephemeral seat — left alone"
    if isolated_home():
        return "isolated PONG_HOME — left alone"
    from .routing import forget_worker_pane, load_pane_registration

    reg = load_pane_registration(session, seat) or {}
    pane = str(reg.get("pane_id") or "")
    note = "no pane registered"
    if pane and pane_owned(pane, session, seat):
        ok, err = _tmux("kill-pane", "-t", pane)
        note = f"closed {pane}" if ok else f"kill-pane failed — {err}"
    elif pane:
        note = f"{pane} is gone or belongs to another seat now — left alone"
    forget_worker_pane(session, seat)
    try:
        from .seat_status import set_available

        set_available(session, seat)
    except Exception:
        pass
    return note


def spawn_group(state: dict[str, Any], lead_id: str) -> dict[str, Any]:
    """Make every seat in a group real. Safe to re-run."""
    members = assert_is_lead(state, lead_id)
    session = str(state.get("session") or "")
    actions: list[str] = []
    spawned: list[dict[str, Any]] = []
    for w in members:
        result = ensure_seat_window(state, w)
        actions.append(result)
        actions.append(ensure_view_session(state, w))
        if "spawned window" in result:
            spawned.append(w)
    # Only seats that just came up — an existing seat may have been switched by
    # hand since, and re-sending would stomp that.
    for w in spawned:
        actions.append(send_model_command(session, w))
    return {
        "lead": lead_id,
        "seats": [str(m.get("id")) for m in members],
        "actions": actions,
    }


def new_project(
    state: dict[str, Any],
    lead_id: str,
    *,
    title: str | None = None,
    dry_run: bool = False,
) -> dict[str, Any]:
    """Start a fresh project on one group, carrying its memory across.

    Order matters and is the whole point: the recap is written and verified
    BEFORE anything is reset, because a reset that loses the previous project's
    context is worse than no reset at all. Only this group's panes restart; the
    rest of the team keeps working through it.
    """
    from .events import emit
    from .session_archive import save_archive

    session = str(state.get("session") or "")
    members = assert_is_lead(state, lead_id)
    seats = [str(m.get("id")) for m in members]

    if dry_run:
        return {
            "dry_run": True,
            "lead": lead_id,
            "would_reset": seats,
            "untouched": _other_seats(state, seats),
        }

    # 1. Memory first.
    archive = save_archive(session, title=title or f"Before new project on {lead_id}")
    recap = str(archive.get("recap") or "")
    archive_id = str(archive.get("id") or "")
    if not archive_id:
        raise RuntimeError("continuity save produced no archive — refusing to reset")

    # 2. Restart only this group's panes.
    #
    # A pane whose command exits takes its window with it, and tmux then drops
    # the linked view session too — so a launch that fails on one seat would
    # silently DELETE that seat rather than reset it. remain-on-exit holds the
    # window open across the restart, which turns that into a dead pane we can
    # see, report, and put a shell back into. Restoring the option afterwards
    # keeps normal teardown behaving the way the rest of the app expects.
    restarted: list[str] = []
    for w in members:
        seat = str(w.get("id"))
        idx = w.get("tmux_index")
        if not isinstance(idx, int) or not window_exists(session, idx):
            restarted.append(f"{seat}: no live window — skipped")
            continue
        target = f"{session}:{idx}"
        _tmux("set-option", "-t", target, "remain-on-exit", "on")
        ok, out = _tmux(
            "respawn-pane", "-k", "-t", target, *start_dir_args(state),  # in the team's folder, as it opened
            f"/bin/bash -lc {_shq(_launch_command(state, w))}",
        )
        if not ok:
            restarted.append(f"{seat}: respawn failed — {out}")
        else:
            # Give a launcher that dies on startup time to actually die.
            time.sleep(0.6)
            _, flag = _tmux("display-message", "-p", "-t", target, "#{pane_dead}")
            if flag.strip() == "1":
                # Seat survives with a shell so it can be relaunched by hand.
                _tmux("respawn-pane", "-k", "-t", target, *start_dir_args(state))
                restarted.append(
                    f"{seat}: launcher exited immediately — seat kept with a shell, "
                    f"relaunch `{w.get('cmd')}` by hand"
                )
            else:
                restarted.append(f"{seat}: restarted")
        _tmux("set-option", "-t", target, "remain-on-exit", "off")

    # 3. Hand the recap back as the first thing the new project reads.
    #
    # Only the lead gets the full recap. It owns the project's context and the
    # children take their work from it, so posting the same few thousand words
    # into all four seats would buy nothing and spend four agents' attention to
    # do it. The children get a pointer and the archive id.
    seeded: list[str] = []
    lead = members[0]
    for w in members:
        idx = w.get("tmux_index")
        if not isinstance(idx, int) or not window_exists(session, idx):
            continue
        # Never type into a TUI that is still coming up. Grok opens on a trust
        # prompt that takes y or n, and pasting a few thousand words of recap
        # plus Enter into it answers "quit" — which exits the agent, kills the
        # pane and takes the window and its view session with it. That is how a
        # reset managed to delete a seat outright.
        ready, why = _pane_ready(session, idx)
        if not ready:
            seeded.append(f"{w.get('id')}: not seeded — {why}")
            continue
        # Model first, so the recap is read by the model this seat is meant to
        # run on rather than by whatever the CLI defaulted to.
        model_note = send_model_command(session, w)
        if "/model" in model_note:
            seeded.append(model_note)
            time.sleep(0.6)
        if str(w.get("id")) == str(lead.get("id")):
            note = (
                f"NEW PROJECT on {w.get('label')} ({w.get('id')}). The previous "
                f"project is archived as {archive_id}; the recap below is your "
                f"starting context. Wait for c1 to say what the new project is.\n\n"
                f"{recap[:4000]}"
            )
        else:
            note = (
                f"NEW PROJECT on {lead.get('label')} — your group restarted. "
                f"Previous work is archived as {archive_id} "
                f"(`pong continuity show {archive_id}`). Take your work from "
                f"{lead.get('id')} as usual; nothing to do until it assigns you something."
            )
        _tmux("send-keys", "-t", f"{session}:{idx}", "-l", note)
        time.sleep(0.08)
        _tmux("send-keys", "-t", f"{session}:{idx}", "Enter")
        seeded.append(f"{w.get('id')}: seeded")

    emit(
        "group_new_project",
        session=session,
        lead=lead_id,
        seats=seats,
        archive_id=archive_id,
    )
    return {
        "lead": lead_id,
        "archive_id": archive_id,
        "reset": seats,
        "restarted": restarted,
        "seeded": seeded,
        "untouched": _other_seats(state, seats),
    }


#: Startup questions an agent CLI asks before it will take any input. Answering
#: one on the human's behalf is not ours to do, and typing past one is how the
#: agent gets told to quit.
_STARTUP_PROMPTS = (
    "yes, proceed",
    "no, quit",
    "do you trust",
    "posing security risks",
    "trust this folder",
    "trust the files",
    "sign in",
    "log in to continue",
)


def _pane_ready(session: str, idx: int, *, settle_tries: int = 6) -> tuple[bool, str]:
    """True once a pane has stopped repainting and is not asking a question.

    Waits for two identical reads rather than sleeping a fixed guess, because
    how long an agent CLI takes to draw its first screen is not something this
    can know in advance.
    """
    target = f"{session}:{idx}"
    last = None
    for _ in range(settle_tries):
        ok, out = _tmux("capture-pane", "-p", "-J", "-t", target, "-S", "-30")
        if not ok:
            return False, "pane could not be read"
        if out == last:
            low = out.lower()
            hit = next((p for p in _STARTUP_PROMPTS if p in low), None)
            if hit:
                return False, (
                    f"waiting on its own startup prompt ({hit!r}) — answer it by "
                    "hand, then re-run; nothing was typed into it"
                )
            return True, ""
        last = out
        time.sleep(1.0)
    return False, "still repainting after 6s — left alone rather than typed into"


def _other_seats(state: dict[str, Any], seats: list[str]) -> list[str]:
    from .state import workers_from_state

    return [
        str(w.get("id"))
        for w in workers_from_state(state)
        if str(w.get("id")) not in seats
    ]


def _shq(s: str) -> str:
    return "'" + s.replace("'", "'\\''") + "'"


def list_groups(state: dict[str, Any]) -> list[dict[str, Any]]:
    """Every lead seat and the seats under it."""
    from .state import workers_from_state

    out: list[dict[str, Any]] = []
    keep = protected_labels()
    for w in workers_from_state(state):
        if str(w.get("parent_id") or ""):
            continue
        members = group_members(state, str(w.get("id")))
        out.append(
            {
                "lead": str(w.get("id")),
                "label": str(w.get("label") or ""),
                "seats": [str(m.get("id")) for m in members],
                "protected": any(is_protected(m, keep) for m in members),
            }
        )
    return out
