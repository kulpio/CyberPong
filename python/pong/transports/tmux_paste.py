"""Optional: paste + Enter into a registered tmux pane (pinned by pane id)."""

from __future__ import annotations

import subprocess
import os
import time
from typing import Any

from .base import TransportResult


def _tmux_exe() -> str:
    """tmux as every other call finds it (``groups.tmux_bin``): Homebrew's, even when the shell's PATH
    does not reach it."""
    try:
        from ..groups import tmux_bin

        return tmux_bin() or "tmux"
    except Exception:
        return "tmux"


def _isolated_home() -> bool:
    try:
        from ..groups import isolated_home

        return isolated_home()
    except Exception:
        return True  # can't tell: type nothing


def _run(cmd: list[str], input_text: str | None = None) -> tuple[bool, str]:
    if cmd and cmd[0] == "tmux":
        cmd = [_tmux_exe(), *cmd[1:]]
    try:
        r = subprocess.run(
            cmd,
            input=input_text,
            text=True,
            capture_output=True,
            timeout=30,
        )
        out = (r.stdout or "") + (r.stderr or "")
        return r.returncode == 0, out
    except Exception as e:
        return False, str(e)


def _pane_info(pane_id: str) -> dict[str, str] | None:
    """Query live tmux pane fields. pane_id is e.g. %3."""
    ok, out = _run(
        [
            "tmux",
            "display-message",
            "-t",
            pane_id,
            "-p",
            "#{pane_id}|#{pane_start_command}|#{pane_title}|#{session_name}|#{window_index}|#{window_name}",
        ]
    )
    if not ok or not out.strip():
        return None
    parts = out.strip().split("|")
    # tmux answers a missing pane on stderr (sometimes with exit 0): the first
    # field must be the pane we asked about.
    if len(parts) < 4 or parts[0] != pane_id:
        return None
    if len(parts) > 6:  # a | inside the start command or title
        parts = [parts[0], "|".join(parts[1:-4]), parts[-4], parts[-3], parts[-2], parts[-1]]
    return {
        "pane_id": parts[0],
        "start_command": parts[1] if len(parts) > 1 else "",
        "title": parts[2] if len(parts) > 2 else "",
        "session_name": parts[3] if len(parts) > 3 else "",
        "window_index": parts[4] if len(parts) > 4 else "",
        "window_name": parts[5] if len(parts) > 5 else "",
    }


def _resolve_pane_id(
    session: str, worker: dict[str, Any]
) -> tuple[str | None, str | None]:
    """
    Return (pane_id, error). Never guesses window index (V3).
    Preference: worker.pane_id → panes.json registration.
    """
    pid = worker.get("pane_id")
    if pid:
        return str(pid), None
    try:
        from ..routing import load_pane_registration

        reg = load_pane_registration(session, str(worker.get("id") or ""))
        if reg and reg.get("pane_id"):
            return str(reg["pane_id"]), None
    except Exception:
        pass
    return None, (
        f"no pane_id registration for worker {worker.get('id')!r} "
        f"in session {session!r} (refusing default index)"
    )


def _verify_registration(
    session: str,
    worker: dict[str, Any],
    live: dict[str, str],
) -> str | None:
    """Return error string if live pane does not match registration.

    Claude/Grok TUIs overwrite pane titles (e.g. \"✳ Claude Code\"). The immutable
    pane_id is the source of truth — never refuse a matching pane_id just because
    the TUI rewrote the title (that forced silent headless fallback).
    """
    from ..routing import exact_window_title, load_pane_registration

    wid = str(worker.get("id") or "")
    reg = load_pane_registration(session, wid) or {}
    expected_title = reg.get("title") or exact_window_title(session, wid)
    live_title = (live.get("title") or "").strip()
    live_start = (live.get("start_command") or "").strip()
    reg_start = (reg.get("start_command") or worker.get("cmd") or "").strip()

    # Session must be the pair (or a view session rooted on it)
    live_sess = (live.get("session_name") or "").strip()
    if live_sess and live_sess != session and not live_sess.startswith(session + "-"):
        return (
            f"pane session mismatch: live={live_sess!r} expected={session!r} "
            f"(or view {session}-*)"
        )

    # A disposable seat's window is named <role>:<seat>. tmux reuses pane ids
    # after a restart, so an id alone can point at somebody else's seat.
    if "." in wid:
        wname = (live.get("window_name") or "").strip()
        if wname and not (wname == wid or wname.endswith(":" + wid)):
            return f"pane {live.get('pane_id')} is window {wname!r}, not seat {wid!r} (stale registration)"

    # Strongest signal: registered / worker pane_id matches live pane
    reg_pid = str(reg.get("pane_id") or worker.get("pane_id") or "").strip()
    live_pid = str(live.get("pane_id") or "").strip()
    if reg_pid and live_pid and reg_pid == live_pid:
        return None

    # Title check: exact recovery token, or registered title, must appear
    title_ok = False
    if expected_title and (
        live_title == expected_title or expected_title in live_title
    ):
        title_ok = True
    if wid and f"pong.{session}.{wid}" in live_title:
        title_ok = True
    # start_command match (optional if title ok)
    start_ok = False
    if reg_start and live_start:
        # pane_start_command is often the shell; worker cmd may be substring of history
        if reg_start in live_start or live_start in reg_start:
            start_ok = True
    if title_ok:
        return None
    if start_ok:
        return None
    if reg:
        return (
            f"pane verify failed for {wid}: title={live_title!r} "
            f"expected≈{expected_title!r} start={live_start!r} pane={live_pid!r}"
        )
    # No registration beyond existence (already checked)
    return None


def send(job: dict[str, Any], worker: dict[str, Any], state: dict[str, Any]) -> TransportResult:
    session = str(job.get("session") or state.get("session") or "")
    prompt = job.get("_prompt") or ""
    if not session:
        return TransportResult("tmux_paste", False, "no session")

    pane_id, err = _resolve_pane_id(session, worker)
    if not pane_id:
        # V3: never default to index 1
        try:
            from .. import events

            events.emit(
                "route.refused",
                session=session,
                reason="tmux_paste_no_pane",
                message=err or "no pane_id",
                worker=worker.get("id"),
            )
        except Exception:
            pass
        return TransportResult("tmux_paste", False, err or "no pane_id")

    live = _pane_info(pane_id)
    if not live:
        try:
            from .. import events

            events.emit(
                "route.refused",
                session=session,
                reason="tmux_paste_pane_missing",
                message=f"pane {pane_id} does not exist",
                worker=worker.get("id"),
            )
        except Exception:
            pass
        return TransportResult(
            "tmux_paste", False, f"pane {pane_id} missing or unreachable"
        )

    verify_err = _verify_registration(session, worker, live)
    if verify_err:
        try:
            from .. import events

            events.emit(
                "route.refused",
                session=session,
                reason="tmux_paste_verify_failed",
                message=verify_err,
                worker=worker.get("id"),
            )
        except Exception:
            pass
        return TransportResult("tmux_paste", False, verify_err)

    # A temporary CyberPong home (a test, a preview, a dry run) still talks to this Mac's one tmux server,
    # where a pane id it registered can be a live seat's pane, and the session check above lets a team
    # named "pong-team" match a live "pong-team-90": nothing is typed from there.
    if _isolated_home():
        return TransportResult(
            "tmux_paste", False, f"not pasted into pane {pane_id}: a temporary CyberPong home types into no live pane"
        )

    target = pane_id  # pin to immutable pane id only
    # Soft status (non-blocking); ignore failures
    _run(["tmux", "display-message", "-t", target, "⚡ CyberPong: submitting job…"])
    time.sleep(0.05)
    # A named buffer per paste: two pastes at once through tmux's one unnamed
    # buffer swapped jobs between seats (25 of 30 trials). Bracketed paste (-p)
    # keeps the prompt's newlines inside the paste instead of pressing Enter at
    # every line (a prompt_toolkit seat got one job as 125 messages).
    buf = f"pong-{os.getpid()}-{int(time.time() * 1000) % 10_000_000}"
    ok, _ = _run(["tmux", "load-buffer", "-b", buf, "-"], input_text=prompt)
    if not ok:
        # chunked fallback
        for i in range(0, len(prompt), 400):
            _run(["tmux", "send-keys", "-t", target, "-l", prompt[i : i + 400]])
            time.sleep(0.02)
    else:
        _run(["tmux", "paste-buffer", "-p", "-b", buf, "-t", target, "-d"])
    # Submit: TUI agents need a real Enter (and sometimes a second for focus)
    time.sleep(0.12)
    _run(["tmux", "send-keys", "-t", target, "Enter"])
    time.sleep(0.08)
    _run(["tmux", "send-keys", "-t", target, "C-m"])
    return TransportResult(
        "tmux_paste",
        True,
        f"pasted into pane {target} ({len(prompt)} chars)",
        meta={"target": target, "pane_id": pane_id},
    )
