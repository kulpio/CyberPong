"""Claude's usage limits, handled by the runner (2.0).

The graph kit's ``limit-guard.py`` did this from a Claude session, started by hand beside each graph; a
person who never started it lost a night's run at the first limit. This is the same logic as one cheap
tick of the runner (:func:`pong.runtime.run`), governed by the switches in Settings › Limits & keys
(``settings.json`` ``limits``):

- **Pause at Claude's 5-hour limit** (``ride_out_5h``). When the no-token ``/usage`` screen says this
  session is at 99%, or a running Claude step's screen shows Claude Code's own limit banner, every running
  graph with a Claude step is paused (``goal pause``: nothing new is dispatched; nothing is lost); a graph
  that runs only on other AIs keeps going. After the reset time (plus a minute) it lifts **only the pauses
  it made** — never a person's — each under its own team's name, and tells each Claude step still showing
  the limit, once, to continue. A Claude step stopped on a network error is told to go on once the network
  answers: at most three times per step visit, fifteen minutes apart, never in the last ten minutes before
  the step times out (the engine retries it then). Nothing is ever typed into a step that shows a question,
  a menu or a permission prompt: only into Claude's empty input line.
- **Stop near the weekly limit** (``week_stop_pct``, 0 = off). When this week's use passes the bar, running
  graphs with a Claude step pause until the weekly reset, or until the person presses Resume
  (``pong limits resume``). At 100% they pause even with the bar off (Claude has stopped), unless Claude's
  own usage credits are on (it goes on working on them).

With Claude switched off in Settings it does nothing at all (no probe, no screen read) and lifts any hold
it made. It acts only while a graph runs. It reads the running Claude steps' screens about once a minute and the
``/usage`` screen about every three minutes, in a pane of its own (tmux session ``usage-probe``, started in an
empty folder of its own, ``<pong home>/usage-probe``, never in a team's session), and only when Claude Code is
installed and signed in. Claude Code's question whether to trust that empty folder is answered, as the engine
answers it for a team's own folder; any other question there (a login, a theme) is never answered: the pane is
closed, ``pong limits status`` says what the person can do, and a fresh pane tries again later. The usage
screen also says whether Claude's own "usage credits" are on; that is only reported, never changed.

A team whose ``graph-kit/limit-state.json`` is fresh (a hand-run ``limit-guard.py`` holds it) is left to
that guard. State: ``<pong home>/limits-state.json``::

    {"state": "ok" | "paused_5h" | "paused_week", "until": ts | null,
     "paused": [{"session", "graph"}], "usage": {"session_pct", "week_pct", "fable_pct",
     "session_reset", "week_reset", "read_at"}, "credits": "on" | "off" | null, "note": "plain words"}
"""
from __future__ import annotations

import fcntl
import json
import os
import re
import time
from contextlib import contextmanager
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any, Iterator

STATE_FILE = "limits-state.json"
PROBE_SESSION = "usage-probe"
SEAT_EVERY_S = 60           # running Claude steps' screens
PROBE_EVERY_S = 180         # the /usage screen
PROBE_SETTLE_S = 5          # between typing /usage and reading it (the next tick)
PROBE_START_S = 15          # a probe pane just started: let Claude Code draw before typing
PROBE_RETRY_S = 900         # after a screen that could not be read
SIGNIN_EVERY_S = 1800       # `claude auth status`, cached
USAGE_FRESH_S = 600         # a reading older than this does not pause anything
VIEW_FRESH_S = 3600         # nor shows in the app
RESUME_GRACE_S = 60         # resume a minute after the stated reset
GUARD_FRESH_S = 300         # a hand-run guard's heartbeat
SESSION_HIT_PCT = 99
FIVE_HOUR_FALLBACK_S = 30 * 60
WEEK_FALLBACK_S = 24 * 3600
FAR_RESET_S = 6 * 3600      # a seat whose limit resets further out than this hit a weekly limit
NET_NUDGES = 3
NET_GAP_S = 15 * 60
NET_TIMEOUT_MARGIN_S = 600
STALE_LINE_S = 20 * 3600    # a limit line left on a screen after its hold ended is not read as a new limit
FIVE_HOUR_WINDOW_S = 5 * 3600 + 30 * 60  # a 5-hour limit resets at most this long after it is hit
RESET_MAX_S = 8 * 86400     # no limit resets further out than this: a farther date is an old line's

REASON_5H = "paused for Claude's 5-hour limit"
REASON_WEEK = "paused near Claude's weekly limit"
OUR_REASONS = (REASON_5H, REASON_WEEK)

#: Claude Code's own limit banner, and only that: it starts the line (after blanks and Claude Code's own
#: glyphs, never a quote, a line number or a diff's +/-) and names its reset ("You've hit your session limit ·
#: resets 3pm", "5-hour limit reached ∙ resets 3pm", "Opus weekly limit reached ∙ resets Oct 9 at 11am", "Claude
#: usage limit reached. Your limit will reset at 3pm"). A reply, a test's output or a diff that quotes these
#: words is not a limit.
LIMIT_LINE = re.compile(
    r"^[ \t⎿⏺●⚠]*(?:claude (?:ai )?usage limit reached|"
    r"(?:(?:opus|fable|sonnet) )?(?:5-hour|session|weekly|usage|opus|fable|sonnet) limit reached|"
    r"you(?:['’]ve| have) hit your (?:session |weekly |usage |5-hour |opus |fable |sonnet )?limit|"
    r"you(?:['’]re| are) out of (?:extra )?usage)\b.*\b(?:resets?|will reset)\b", re.I)
TIME_RX = re.compile(r"(?:(\b[A-Z][a-z]{2})\s+(\d{1,2})\s+at\s+)?(\d{1,2})(?::(\d{2}))?\s*(am|pm)", re.I)
NUDGE = "Your usage limit has reset. Please continue the job you were working on, from where you stopped."
NET_ERR = re.compile(r"api error|can't reach the api server|enotfound|econnrefused|econnreset|network error|fetch failed|"
                     r"overloaded|request timed out|internal server error|connection error", re.I)
NET_NUDGE = "The connection is back. Please continue the job you were working on, from where you stopped."
CREDITS = re.compile(r"usage credits\s*(?:are|:)?\s*(on|off)\b", re.I)
#: Claude Code's first-run screens in the probe pane: the folder-trust question (for the probe's own empty
#: folder, answered) and anything else that waits for a person (never answered).
PROBE_TRUST = re.compile(r"do you trust the files in this folder|trust this folder\?|is this a project you (created|trust)", re.I)
#: An "update available" notice is not among them: it sits on the idle screen until Claude Code updates, and
#: read as a question it would stop every reading; a screen an update really took fails to read, and the
#: pane is started again later.
PROBE_QUESTION = re.compile(r"select login method|please run /login|not logged in|choose the text style|"
                            r"dark mode|light mode|press enter to continue|do you want to", re.I)
PROBE_TRUST_MAX = 2
USAGE_HEADS = (("session", "Current session"), ("week", "Current week (all models)"), ("fable", "Current week (Fable)"))


# ------------------------------------------------------------------ reading ---

def next_time(text: str, now: datetime | None = None) -> datetime | None:
    """The next moment matching '2:20am' or 'Oct 1 at 11am' in the Mac's local time, or None."""
    m = TIME_RX.search(text or "")
    if not m:
        return None
    now = now or datetime.now()
    mon, day, hh, mm, ap = m.groups()
    h = int(hh) % 12 + (12 if ap.lower() == "pm" else 0)
    mi = int(mm or 0)
    if h > 23 or mi > 59:
        return None
    if mon:
        try:
            t = datetime.strptime(f"{mon} {day} {now.year} {h}:{mi}", "%b %d %Y %H:%M")
        except ValueError:
            return None
        if t < now - timedelta(days=1):
            t = t.replace(year=now.year + 1)
        return t
    t = now.replace(hour=h, minute=mi, second=0, microsecond=0)
    return t if t > now - timedelta(minutes=5) else t + timedelta(days=1)


def parse_usage(text: str, now: datetime | None = None) -> dict[str, Any]:
    """``{'session': (pct, reset), 'week': (...), 'fable': (...), 'credits': 'on'|'off'|None}`` from Claude
    Code's ``/usage`` screen; a bucket that is not on the screen is left out."""
    lines = [ln.strip() for ln in (text or "").splitlines() if ln.strip()]
    res: dict[str, Any] = {}
    for key, head in USAGE_HEADS:
        for i, ln in enumerate(lines):
            if ln.startswith(head):
                pct = next((int(m.group(1)) for x in lines[i + 1:i + 3] for m in [re.search(r"(\d+)% used", x)] if m), None)
                rs = next((x for x in lines[i + 1:i + 4] if x.startswith("Resets")), "")
                if pct is not None:
                    res[key] = (pct, next_time(rs, now))
                break
    m = CREDITS.search(text or "")
    res["credits"] = m.group(1).lower() if m else None
    return res


def tail_lines(text: str, n: int = 8) -> list[str]:
    return [ln for ln in (text or "").splitlines() if ln.strip()][-n:]


def working(tail: list[str]) -> bool:
    return any("esc to interrupt" in ln for ln in tail[-4:])


def limit_hit(text: str) -> str:
    """The usage-limit line a stopped step's screen ends on, or ''."""
    tail = tail_lines(text)
    if not tail or working(tail):
        return ""
    return next((ln.strip()[:160] for ln in reversed(tail) if LIMIT_LINE.search(ln)), "")


def network_stopped(text: str) -> bool:
    """A stopped step whose screen ends on an API or network error (and not on a usage limit)."""
    tail = tail_lines(text)
    if not tail or working(tail) or any(LIMIT_LINE.search(ln) for ln in tail):
        return False
    return any(NET_ERR.search(ln) for ln in tail)


#: A screen that waits for a person: a permission prompt, a menu, a numbered choice. Enter there takes the
#: highlighted answer ("1. Yes"), so nothing is ever typed into it.
ASKING = re.compile(r"enter to select|↑/↓ to navigate|arrow keys to navigate|tab/arrow keys|esc to cancel|"
                    r"do you want to (proceed|make this edit|create|run|allow|continue)|allow (reads|writes|this)|"
                    r"permission to|❯\s*\d+\.|\b1\. yes\b", re.I)


def ready_for_input(text: str) -> bool:
    """Claude finished its turn and shows its empty input line: no question, no menu, no half-typed draft.
    The only screen a line may be typed into (as :func:`pong.architect.idle_and_empty` delivers a message)."""
    lines = [ln.rstrip() for ln in (text or "").splitlines() if ln.strip()]
    tail = lines[-12:]
    if not tail or working(tail) or any(ASKING.search(ln) for ln in tail):
        return False
    for ln in reversed(tail[-8:]):
        s = ln.strip().strip("│").strip()
        if s.startswith(("❯", ">")):
            rest = s[1:].strip()
            return rest == "" or rest.startswith('Try "')
    return False


# ------------------------------------------------------------------ state ---

def state_path() -> Path:
    from .paths import state_dir

    return state_dir() / STATE_FILE


def _empty() -> dict[str, Any]:
    return {"state": "ok", "until": None, "paused": [], "usage": None, "credits": None, "note": "", "_": {}}


def load_state() -> dict[str, Any]:
    from .jsonutil import read_json

    st = _empty()
    raw = read_json(state_path())
    if raw:
        st.update({k: raw[k] for k in st if k in raw})
    if st["state"] not in ("ok", "paused_5h", "paused_week"):
        st["state"] = "ok"
    if not isinstance(st["paused"], list):
        st["paused"] = []
    st["paused"] = [p for p in st["paused"] if isinstance(p, dict) and p.get("session") and p.get("graph")]
    if not isinstance(st["_"], dict):
        st["_"] = {}
    if not isinstance(st["usage"], dict):
        st["usage"] = None
    try:
        st["until"] = float(st["until"]) if st["until"] is not None else None
    except (TypeError, ValueError):
        st["until"] = None
    return st


def save_state(st: dict[str, Any]) -> None:
    from .jsonutil import write_json

    write_json(state_path(), st)


@contextmanager
def _state_lock(*, blocking: bool = True) -> Iterator[bool]:
    """One reader-writer of the state file at a time. The runner's tick and the person's Resume each read the
    file, change it and write it back: a tick that read it just before a Resume wrote it would put the hold
    back, and the Resume would be lost. The tick does not wait (``blocking=False`` yields False: the next
    pass comes in seconds); a Resume waits for the tick to finish."""
    p = state_path()
    p.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(str(p.with_name(p.name + ".lock")), os.O_CREAT | os.O_RDWR, 0o600)
    held = False
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX if blocking else fcntl.LOCK_EX | fcntl.LOCK_NB)
            held = True
        except OSError:
            if blocking:
                raise
        yield held
    finally:
        if held:
            try:
                fcntl.flock(fd, fcntl.LOCK_UN)
            except OSError:
                pass
        os.close(fd)


def public(st: dict[str, Any]) -> dict[str, Any]:
    """The state as the contract names it (no bookkeeping)."""
    return {"state": st.get("state") or "ok", "until": st.get("until"),
            "paused": [{"session": p.get("session"), "graph": p.get("graph")} for p in st.get("paused") or []],
            "usage": st.get("usage"), "credits": st.get("credits"), "note": st.get("note") or ""}


def view(now: float | None = None) -> dict[str, Any] | None:
    """What ``pong graph list --json`` carries as ``limits``: the state, or None when all is well and no
    recent usage was read."""
    now = time.time() if now is None else now
    st = load_state()
    u = st.get("usage") or {}
    recent = bool(u) and now - float(u.get("read_at") or 0) <= VIEW_FRESH_S
    if st["state"] == "ok" and not recent:
        return None
    out = public(st)
    if not recent:
        out["usage"] = None
    return out


def _clock(ts: float | None, now: float) -> str:
    """'3:10 pm', or 'Thu 11:00 am' when it is not today."""
    if not ts:
        return ""
    t, n = datetime.fromtimestamp(ts), datetime.fromtimestamp(now)
    hm = f"{t.hour % 12 or 12}:{t.minute:02d} {'am' if t.hour < 12 else 'pm'}"
    return hm if t.date() == n.date() else f"{t:%a} {hm}"


@contextmanager
def _as_team(session: str) -> Iterator[None]:
    """The process speaks for *session* (its name and its token, as ``drain.run`` binds each team) inside the
    block; whatever was bound before is put back after. Another team's token is never carried in."""
    from .cron import apply_token

    keep = {k: os.environ.get(k) for k in ("PONG_SESSION", "PONG_TOKEN")}
    os.environ.pop("PONG_TOKEN", None)
    try:
        apply_token(session)
        yield
    finally:
        for k, v in keep.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v


# ------------------------------------------------------------------ the Mac ---

class Env:
    """Everything the tick reads or does outside its own file. Tests pass a fake.

    Nothing here touches tmux when PONG_HOME is a temporary home: tests and dry runs share the one tmux
    server on the Mac with the person's live teams."""

    def _live(self) -> bool:
        try:
            from .groups import isolated_home

            return not isolated_home()
        except Exception:
            return False

    def _tmux(self, *args: str) -> tuple[bool, str]:
        from .groups import _tmux

        return _tmux(*args)

    def running_graphs(self, session: str | None = None) -> list[dict[str, Any]]:
        from .paths import sessions_dir
        from .work_graph import load

        if session:
            teams = [session]
        else:
            base = sessions_dir()
            teams = [d.name for d in sorted(base.iterdir()) if d.is_dir() and not d.name.startswith(("_", "."))
                     and (d / "work_graph.json").exists()] if base.is_dir() else []
        out: list[dict[str, Any]] = []
        for t in teams:
            try:
                data = load(t)
            except Exception:
                continue
            for g in data.get("graphs") or []:
                if isinstance(g, dict) and g.get("kind") == "graph" and g.get("status") == "running":
                    out.append({**g, "session": t})
        return out

    def pause(self, session: str, gid: str, reason: str) -> float | None:
        from .work_graph import pause

        g = pause(session, gid, reason=reason)
        p = g.get("paused") if isinstance(g.get("paused"), dict) else {}
        return float(p["at"]) if p.get("manual") and p.get("reason") == reason and p.get("at") else None

    def resume_ours(self, session: str, gid: str, rec: dict[str, Any]) -> bool:
        """Lift a pause this tick made, checked and lifted under the graph's own lock, as the graph's own team.

        Checked first and resumed after, a person who resumed the graph in between (and left a question
        open) would have had that question answered "approved" by the resume. Under the lock the pause is
        still ours when it is lifted, so only the pause is lifted.

        Lifting it sends out the steps held during the pause, and a step is filed under a team's name: the
        runner reaches this after draining every team (the process is still bound to the last one), and a
        Resume lifts one team after another. Bound to another team, the write was refused, the held step
        failed and the graph closed as finished. So the graph's own team is bound for the lift, as the drain
        binds each team, and the binding before it is put back after."""
        from . import graph_engine
        from .work_graph import _graph_lock, load, save

        with _as_team(session), _graph_lock(session):
            data = load(session)
            g = next((x for x in data.get("graphs") or [] if isinstance(x, dict) and str(x.get("id") or "") == gid), None)
            if not _is_ours(g, rec) or str((g or {}).get("kind") or "") != "graph":
                return False
            graph_engine.resume(session, g)
            save(session, data)
        return True

    def seat_runtime(self, session: str, seat: str) -> str:
        from .routing import load_pane_registration

        cmd = str((load_pane_registration(session, seat) or {}).get("start_command") or "").strip()
        return cmd.split()[0] if cmd else ""

    def _seat_pane(self, session: str, seat: str) -> str:
        from .groups import _pane_alive, pane_owned
        from .routing import load_pane_registration

        pane = str((load_pane_registration(session, seat) or {}).get("pane_id") or "")
        if not pane:
            return ""
        alive = pane_owned(pane, session, seat) if "." in seat else _pane_alive(pane)
        return pane if alive else ""

    def seat_screen(self, session: str, seat: str) -> str | None:
        if not self._live():
            return None
        pane = self._seat_pane(session, seat)
        if not pane:
            return None
        return self._capture(pane)

    def _capture(self, pane: str) -> str | None:
        # -J: a line the pane wrapped is read whole (a narrow seat wraps the limit banner before its reset)
        ok, text = self._tmux("capture-pane", "-p", "-J", "-t", pane, "-S", "-30")
        return text if ok else None

    def type_into(self, session: str, seat: str, text: str) -> bool:
        """Type a line and Enter, only into Claude's empty input line. The screen is read again first: the
        one the tick decided on can be seconds old, and a permission prompt that came up since would take
        the Enter as its highlighted "Yes"."""
        if not self._live():
            return False
        pane = self._seat_pane(session, seat)
        if not pane:
            return False
        if not ready_for_input(self._capture(pane) or ""):
            return False
        ok, _ = self._tmux("send-keys", "-t", pane, "-l", text)
        if ok:
            time.sleep(0.3)  # the TUI takes the text before the Enter
            ok, _ = self._tmux("send-keys", "-t", pane, "Enter")
        return ok

    def claude_ready(self) -> bool:
        if not self._live():  # a temporary home starts no probe, so it need not ask Claude Code anything
            return False
        from .doctor import claude_signin

        # `claude auth status`, run with claude's own folder and the CLIs' folders on PATH
        # (``models.path_for``): an npm-installed claude under nvm, volta or bun runs `env node`
        signed_in, _plan = claude_signin()
        return signed_in is True

    def probe_exists(self) -> bool:
        if not self._live():
            return False
        return self._tmux("has-session", "-t", f"={PROBE_SESSION}:")[0]

    def probe_dir(self) -> Path:
        """The probe's own empty folder: never a project, never the whole home folder."""
        from .paths import state_dir

        d = state_dir() / PROBE_SESSION
        d.mkdir(mode=0o700, parents=True, exist_ok=True)
        return d

    def probe_start(self) -> bool:
        if not self._live():
            return False
        from .groups import _shq
        from .models import find_binary, path_for

        claude = find_binary("claude") or "claude"
        # a tmux server started from a bare PATH (launchd, the Dock) has no node for an npm-installed
        # claude (`#!/usr/bin/env node`): the probe gets claude's own folder and the CLIs' folders
        run = f"env PATH={_shq(path_for(claude))} {_shq(claude)}" if os.path.isabs(claude) else _shq(claude)
        ok, _ = self._tmux("new-session", "-d", "-s", PROBE_SESSION, "-x", "160", "-y", "50",
                           "-c", str(self.probe_dir()), f"{run} --strict-mcp-config")
        return ok

    def probe_send(self) -> str:
        """Type ``/usage``: "sent"; or "trusted" when Claude first asked to trust the probe's own empty folder
        (answered, as the engine answers it for a team's own folder); or "blocked" when it asks anything else
        (a login, a theme), which is the person's to answer; or "failed"."""
        if not self._live():
            return "failed"
        t = f"={PROBE_SESSION}:"
        ok, screen = self._tmux("capture-pane", "-p", "-t", t, "-S", "-30")
        if not ok:
            return "failed"
        tail = "\n".join(tail_lines(screen, 12))
        if PROBE_TRUST.search(tail):
            ok, _ = self._tmux("send-keys", "-t", t, "Enter")
            return "trusted" if ok else "failed"
        if PROBE_QUESTION.search(tail):
            return "blocked"
        self._tmux("send-keys", "-t", t, "Escape")
        time.sleep(0.3)
        ok, _ = self._tmux("send-keys", "-t", t, "-l", "/usage")
        time.sleep(0.3)
        ok2, _ = self._tmux("send-keys", "-t", t, "Enter")
        return "sent" if ok and ok2 else "failed"

    def probe_read(self) -> str:
        if not self._live():
            return ""
        t = f"={PROBE_SESSION}:"
        ok, text = self._tmux("capture-pane", "-p", "-t", t, "-S", "-80")
        self._tmux("send-keys", "-t", t, "Escape")
        return text if ok else ""

    def probe_reset(self) -> None:
        if self._live():
            self._tmux("kill-session", "-t", f"={PROBE_SESSION}:")

    def network_ok(self) -> bool:
        if not self._live():  # nothing is typed from a temporary home, so nothing is worth a request
            return False
        import urllib.error
        import urllib.request

        try:
            urllib.request.urlopen(urllib.request.Request("https://api.anthropic.com", method="HEAD"), timeout=8)
            return True
        except urllib.error.HTTPError:
            return True  # an answer, even a refusal, means the network is back
        except Exception:
            return False

    def pid_alive(self, pid: int) -> bool:
        try:
            os.kill(int(pid), 0)
            return True
        except (OSError, ValueError, TypeError):
            return False


def guard_holds(team: str, now: float, env: Env) -> bool:
    """A hand-run ``limit-guard.py`` holds this team: its heartbeat is fresh, or it holds a limit and is alive."""
    from .paths import sessions_dir

    try:
        d = json.loads((sessions_dir(team) / "graph-kit" / "limit-state.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return False
    if not isinstance(d, dict):
        return False
    beat = float(d.get("beat_at") or 0)
    if beat and now - beat <= GUARD_FRESH_S:
        return True
    until = float(d.get("limited_until") or 0)
    pid = d.get("pid")
    return bool(until and now < until + 600 and pid and env.pid_alive(int(pid)))


# ------------------------------------------------------------------ acting ---

def _is_ours(g: dict[str, Any] | None, rec: dict[str, Any]) -> bool:
    p = (g or {}).get("paused") if isinstance((g or {}).get("paused"), dict) else None
    if not g or str(g.get("status") or "") != "running" or not p or not p.get("manual"):
        return False
    if str(p.get("reason") or "") not in OUR_REASONS:
        return False
    at = rec.get("at")
    return at is None or abs(float(p.get("at") or 0) - float(at)) < 1.0


def _paused_by_anyone(g: dict[str, Any]) -> bool:
    p = g.get("paused") if isinstance(g.get("paused"), dict) else None
    return bool(p and p.get("manual"))


def _pause_all(st: dict[str, Any], graphs: list[dict[str, Any]], env: Env, reason: str) -> list[str]:
    done = []
    have = {(p["session"], p["graph"]) for p in st["paused"]}
    for g in graphs:
        key = (str(g.get("session")), str(g.get("id")))
        if key in have or _paused_by_anyone(g):
            continue
        try:
            at = env.pause(key[0], key[1], reason)
        except Exception:
            continue
        st["paused"].append({"session": key[0], "graph": key[1], "at": at})
        done.append(f"{key[0]}/{key[1]}")
    return done


def _lift(st: dict[str, Any], env: Env) -> list[str]:
    """Lift the pauses this tick made, and only those still in place as it made them.

    A lift that failed (the graph's file could not be read or written) keeps its record, so a later pass
    tries again: dropped, the graph would stay paused for a limit that is over, with nothing left to lift it."""
    lifted, kept = [], []
    for rec in st["paused"]:
        try:
            if env.resume_ours(str(rec["session"]), str(rec["graph"]), rec):
                lifted.append(f"{rec['session']}/{rec['graph']}")
        except Exception as e:
            kept.append({**rec, "tries": int(rec.get("tries") or 0) + 1, "error": f"{type(e).__name__}: {e}"[:200]})
    st["paused"] = kept
    return lifted


#: Steps the engine runs itself (graph_engine.SEATLESS): no AI's allowance is spent on them.
_NO_AI_ROLES = frozenset({"human", "join", "end", "check", "jev"})


def _uses_claude(g: dict[str, Any], env: Env) -> bool:
    """A graph with a step wired to Claude, in any state (a loop runs a finished step again), or a step
    running on a Claude seat. Only these are paused for Claude's limits: a graph on other AIs goes on."""
    if _claude_steps([g], env):
        return True
    wiring = g.get("wiring") if isinstance(g.get("wiring"), dict) else {}
    for n in g.get("nodes") or []:
        if not isinstance(n, dict):
            continue
        w = wiring.get(str(n.get("id"))) or {}
        w = w if isinstance(w, dict) else {}
        if str(n.get("role") or w.get("role") or "") in _NO_AI_ROLES:
            continue
        rt = str(w.get("runtime") or "")
        if not rt and n.get("seat"):
            rt = env.seat_runtime(str(g.get("session")), str(n["seat"]))
        if rt == "claude":
            return True
    return False


def _claude_steps(graphs: list[dict[str, Any]], env: Env) -> list[tuple[dict[str, Any], dict[str, Any], str]]:
    """(graph, node, seat) for every running step on a Claude seat."""
    out = []
    for g in graphs:
        wiring = g.get("wiring") if isinstance(g.get("wiring"), dict) else {}
        for n in g.get("nodes") or []:
            if not isinstance(n, dict) or n.get("status") != "running" or not n.get("seat"):
                continue
            seat = str(n["seat"])
            rt = str((wiring.get(str(n.get("id"))) or {}).get("runtime") or "") or env.seat_runtime(str(g["session"]), seat)
            if rt == "claude":
                out.append((g, n, seat))
    return out


def _mark_stale(st: dict[str, Any], seat: str, line: str, now: float) -> None:
    """A limit line whose hold is over: still on a seat's screen until the AI moves on, never a new limit."""
    if seat and line:
        st["_"].setdefault("stale_lines", {})[seat] = {"line": line, "at": now}


def _end_hold(st: dict[str, Any], now: float) -> None:
    """The lines that started the hold are history now, and so is any usage read before it ended."""
    inner = st["_"]
    inner["hold_ended_at"] = now
    for seat, line in (inner.pop("hold_lines", None) or {}).items():
        _mark_stale(st, str(seat), str(line), now)
    inner.pop("why", None)


def _fresh(st: dict[str, Any], now: float) -> bool:
    """A usage reading recent enough to act on, and taken after the last hold ended (a reading from just
    before a reset would pause the graphs again the moment they resumed)."""
    u = st.get("usage") or {}
    read = float(u.get("read_at") or 0)
    return bool(u) and now - read <= USAGE_FRESH_S and read >= float(st["_"].get("hold_ended_at") or 0)


def _later(now: float, *times: Any) -> float | None:
    """The first of *times* still ahead of now (a reset that has passed is no time to resume at)."""
    for t in times:
        try:
            if t and float(t) > now:
                return float(t)
        except (TypeError, ValueError):
            continue
    return None


def _stale_line(st: dict[str, Any], seat: str, line: str, now: float) -> bool:
    """A limit line that is not news: its own reset time has passed, or its hold already ended.

    A line gives its reset as a clock time ("resets 3am") or a date ("resets Oct 1 at 11am"). Read after
    that time, a clock time points at tomorrow and a date at next year, so a line left on a screen would
    look like a new limit that holds for a day, or a year: a clock time further out than a 5-hour window
    (unless the line says it is the weekly limit), or a date further out than a week, is a reset that has
    already passed."""
    rs = next_time(line, datetime.fromtimestamp(now))
    if rs:
        ahead = rs.timestamp() - now
        m = TIME_RX.search(line)
        dated = bool(m and m.group(1))
        if ahead <= 0 or ahead > RESET_MAX_S:
            return True
        if not dated and ahead > FIVE_HOUR_WINDOW_S and "week" not in line.lower():
            return True
    old = (st["_"].get("stale_lines") or {}).get(seat) or {}
    return old.get("line") == line and now - float(old.get("at") or 0) < STALE_LINE_S


def _nudge_limited(st: dict[str, Any], graphs: list[dict[str, Any]], env: Env, now: float) -> list[str]:
    """Tell each Claude step still showing a limit, once per step visit, to continue."""
    inner = st["_"]
    told = inner.setdefault("told", {})
    done = []
    for g, n, seat in _claude_steps(graphs, env):
        key = f"{g['session']}|{g['id']}|{n.get('id')}|{n.get('started_at')}"
        if key in told:
            continue
        text = env.seat_screen(str(g["session"]), seat)
        line = limit_hit(text) if text else ""
        # only at Claude's empty input line: on a question or a menu, Enter would answer it
        if line and ready_for_input(text or "") and not n.get("attention") and env.type_into(str(g["session"]), seat, NUDGE):
            told[key] = now
            _mark_stale(st, seat, line, now)
            done.append(f"{n.get('id')} on {seat}")
    for k in [k for k, t in told.items() if now - float(t or 0) > 2 * 86400]:
        told.pop(k, None)
    return done


def _network_nudges(st: dict[str, Any], steps: list[tuple[dict[str, Any], dict[str, Any], str, str]],
                    env: Env, now: float) -> list[str]:
    net = st["_"].setdefault("net", {})
    done = []
    checked: bool | None = None
    for g, n, seat, text in steps:
        # a permission prompt that mentions an API error is the person's question, not a stopped step
        if not network_stopped(text) or not ready_for_input(text) or n.get("attention"):
            continue
        started = float(n.get("started_at") or 0)
        bnd = g.get("boundaries") if isinstance(g.get("boundaries"), dict) else {}
        tmo = float(n.get("timeout_min") or bnd.get("node_timeout_min") or 120) * 60
        if started and now - started > tmo - NET_TIMEOUT_MARGIN_S:
            continue  # the engine times it out and retries it soon; a nudge now would be cut off
        key = f"{g['session']}|{g['id']}|{n.get('id')}|{started}"
        past = [float(t) for t in net.get(key) or []]
        if len(past) >= NET_NUDGES or (past and now - past[-1] < NET_GAP_S):
            continue
        if checked is None:
            checked = env.network_ok()
        if not checked:
            continue
        if env.type_into(str(g["session"]), seat, NET_NUDGE):
            net[key] = past + [now]
            done.append(f"{n.get('id')} on {seat}")
    for k in [k for k, v in net.items() if not v or now - float(v[-1]) > 2 * 86400]:
        net.pop(k, None)
    return done


def _read_probe(st: dict[str, Any], env: Env, now: float) -> None:
    """One step of the two-step ``/usage`` read: type it on one tick, read it on the next, so no tick waits."""
    inner = st["_"]
    sent = float(inner.get("probe_sent_at") or 0)
    if sent:
        if now - sent < PROBE_SETTLE_S:
            return
        inner.pop("probe_sent_at", None)
        text = env.probe_read()
        u = parse_usage(text, datetime.fromtimestamp(now))
        if any(k in u for k, _h in USAGE_HEADS):
            def pct(k: str) -> int | None:
                return u[k][0] if k in u else None

            def reset(k: str) -> float | None:
                return u[k][1].timestamp() if k in u and u[k][1] else None

            st["usage"] = {"session_pct": pct("session"), "week_pct": pct("week"), "fable_pct": pct("fable"),
                           "session_reset": reset("session"), "week_reset": reset("week"), "read_at": now}
            if u.get("credits"):
                st["credits"] = u["credits"]
            inner["probe_at"] = now
            inner.pop("probe_failed_at", None)
        else:  # an update or trust screen took the pane: start it again later
            inner["probe_failed_at"] = now
            inner["probe_at"] = now
            env.probe_reset()
        return
    if now - float(inner.get("probe_at") or 0) < PROBE_EVERY_S or now - float(inner.get("probe_failed_at") or 0) < PROBE_RETRY_S:
        return
    try:
        from .settings import ai_enabled

        claude_on = ai_enabled("claude")
    except Exception:
        claude_on = True
    if not claude_on:  # switched off in Settings: Claude Code is not started, not even for a reading
        inner["probe_at"] = now
        return
    signin = inner.get("signin") if isinstance(inner.get("signin"), dict) else {}
    if now - float(signin.get("at") or 0) >= SIGNIN_EVERY_S:
        try:
            ok = bool(env.claude_ready())
        except Exception:
            ok = False
        signin = {"ok": ok, "at": now}
        inner["signin"] = signin
    if not signin.get("ok"):
        inner["probe_at"] = now  # look again on the next round, not every tick
        return
    if not env.probe_exists():
        if float(inner.get("probe_started_at") or 0) and now - float(inner["probe_started_at"]) < PROBE_START_S:
            return
        if env.probe_start():
            inner["probe_started_at"] = now
        else:
            inner["probe_failed_at"] = now
        return
    if float(inner.get("probe_started_at") or 0) and now - float(inner["probe_started_at"]) < PROBE_START_S:
        return
    inner.pop("probe_started_at", None)
    res = env.probe_send()
    res = "sent" if res is True else ("failed" if res is False else str(res))
    if res == "sent":
        inner["probe_sent_at"] = now
        inner.pop("probe_note", None)
    elif res == "trusted" and int(inner.get("probe_trusted") or 0) < PROBE_TRUST_MAX:
        inner["probe_trusted"] = int(inner.get("probe_trusted") or 0) + 1
        inner["probe_started_at"] = now  # let Claude Code draw again before typing
    else:
        inner["probe_failed_at"] = now
        if res in ("blocked", "trusted"):
            # Closed, not left waiting: once the person has answered Claude Code's first-run questions in
            # their own Terminal, the pane started next time (in 15 minutes) no longer asks them.
            env.probe_reset()
            inner["probe_note"] = ("Claude Code is waiting for an answer to its first-run questions, so this week's "
                                   "use can't be read yet. Open Terminal, type claude, answer them, then quit it.")


def _settings() -> dict[str, Any]:
    """The limit switches, and whether Claude is switched on at all (``claude``)."""
    from .settings import ai_enabled, limits

    return {**limits(), "claude": ai_enabled("claude")}


#: The probe's own bookkeeping: gone with the pane when Claude is switched off, so switched on again it reads at once.
_PROBE_KEYS = ("probe_at", "probe_sent_at", "probe_started_at", "probe_failed_at", "probe_trusted", "probe_note", "signin")


def tick(session: str | None = None, *, env: Env | None = None, now: float | None = None,
         cfg: dict[str, Any] | None = None) -> dict[str, Any]:
    """One runner pass. Cheap when nothing runs: one small file and the teams' graph files are read.
    A pass that finds the state file busy (a Resume being written, another runner) does nothing."""
    with _state_lock(blocking=False) as held:
        if not held:
            return {**public(load_state()), "did": ["skipped: the limits state is busy"]}
        return _tick(session, env=env, now=now, cfg=cfg)


def _tick(session: str | None, *, env: Env | None, now: float | None, cfg: dict[str, Any] | None) -> dict[str, Any]:
    env = env or Env()
    now = time.time() if now is None else float(now)
    cfg = cfg or _settings()
    # Claude switched off in Settings: nothing Claude-related happens (no reading, no pause), and a hold
    # this made ends. Tests that pass their own switches keep Claude on.
    claude_on = bool(cfg.get("claude", True))
    watch = claude_on and bool(cfg["ride_out_5h"] or cfg["week_stop_pct"] > 0)
    st = load_state()
    before = json.dumps(st, sort_keys=True, default=str)
    inner = st["_"]
    did: list[str] = []
    u = st.get("usage") or {}
    fresh = _fresh(st, now)
    _prune(inner, now)
    retry = st["state"] == "ok" and bool(st["paused"])  # lifts that failed on an earlier pass
    if not claude_on and any(k in inner for k in _PROBE_KEYS):
        env.probe_reset()  # a reading pane started before Claude was switched off
        for k in _PROBE_KEYS:
            inner.pop(k, None)

    # A hold the person switched off, or a weekly bar raised above today's use, ends now.
    why = str(inner.get("why") or "")
    lift_now = ""
    if st["state"] in ("paused_5h", "paused_week") and not claude_on:
        lift_now = "Claude was switched off"
    elif st["state"] == "paused_5h" and not cfg["ride_out_5h"]:
        lift_now = "the 5-hour pause was switched off"
    elif st["state"] == "paused_week":
        if why == "week_pct" and cfg["week_stop_pct"] <= 0:
            lift_now = "the weekly stop was switched off"
        elif why == "week_pct" and fresh and u.get("week_pct") is not None and u["week_pct"] < cfg["week_stop_pct"]:
            lift_now = f"this week's use ({u['week_pct']}%) is under the bar again"
        elif why == "week_limit" and not cfg["ride_out_5h"] and cfg["week_stop_pct"] <= 0:
            lift_now = "the limit switches were turned off"
        elif why == "week_limit" and cfg["week_stop_pct"] <= 0 and st.get("credits") == "on" and not inner.get("hold_lines"):
            # held on the 100% reading alone, and Claude goes on working on the person's usage credits
            lift_now = "Claude's usage credits are on"
    if lift_now:
        lifted = _lift(st, env)
        did.append(f"resumed ({lift_now}): {', '.join(lifted) or 'none'}")
        st.update(state="ok", until=None, note="")
        _end_hold(st, now)

    # The reset came: lift our pauses, then tell the steps still showing the limit to continue.
    if st["state"] in ("paused_5h", "paused_week") and st["until"] and now >= float(st["until"]) + RESUME_GRACE_S:
        kind = st["state"]
        gids = {(p["session"], p["graph"]) for p in st["paused"]}
        lifted = _lift(st, env)
        resumed = [g for g in env.running_graphs(session) if (str(g.get("session")), str(g.get("id"))) in gids]
        told = _nudge_limited(st, resumed, env, now)
        did.append(f"limit over ({kind}): resumed {', '.join(lifted) or 'none'}; told to continue: {', '.join(told) or 'none'}")
        st.update(state="ok", until=None, note="")
        _end_hold(st, now)
        inner["last_event"] = {"at": now, "text": f"Claude's limit has reset · graphs resumed at {_clock(now, now)}"}

    # A lift that failed when its hold ended (its record was kept): tried again on each later pass until it
    # takes, or the graph is no longer paused by this (resumed or stopped by the person, finished).
    if retry and st["state"] == "ok" and st["paused"]:
        lifted = _lift(st, env)
        if lifted:
            did.append(f"resumed (a lift that had failed): {', '.join(lifted)}")

    graphs = env.running_graphs(session)
    if not graphs:
        # nothing runs, so nothing is held (a paused graph still counts as running): a hold whose graphs
        # were all cancelled or finished is stale, and goes (a runner kept to one team judges only that team)
        if session is None and (st["state"] != "ok" or st["paused"]):
            did.append(f"cleared a stale {st['state']} hold: no graph is running")
            st.update(state="ok", until=None, paused=[], note="")
            _end_hold(st, now)
            inner.pop("seen", None)
        _save_if_changed(st, before)
        return {**public(st), "did": did}

    held: dict[str, bool] = {}
    mine = []
    for g in graphs:
        team = str(g.get("session"))
        if team not in held:
            held[team] = guard_holds(team, now, env)
        if not held[team]:
            mine.append(g)
    active = [g for g in mine if not _paused_by_anyone(g)]
    # Only a graph with a Claude step is held for Claude's limits: one on other AIs goes on (and with
    # Claude switched off, none is held).
    claude_active = [g for g in active if _uses_claude(g, env)] if claude_on else []

    # Screens of running Claude steps, about once a minute.
    hits: list[dict[str, Any]] = []
    if claude_active and watch and now - float(inner.get("seat_at") or 0) >= SEAT_EVERY_S:
        inner["seat_at"] = now
        screens = []
        for g, n, seat in _claude_steps(claude_active, env):
            text = env.seat_screen(str(g["session"]), seat)
            if not text:
                continue
            line = limit_hit(text)
            if line and _stale_line(st, seat, line, now):
                continue  # the limit it reports is over; the AI just has not moved on yet
            if line:
                rs = next_time(line, datetime.fromtimestamp(now))
                hits.append({"session": g["session"], "graph": g["id"], "node": n.get("id"), "seat": seat,
                             "line": line, "reset": rs.timestamp() if rs else None})
            else:
                screens.append((g, n, seat, text))
        if cfg["ride_out_5h"]:
            told = _network_nudges(st, screens, env, now)
            if told:
                did.append("told to continue after a network error: " + ", ".join(told))

    # The /usage screen, about every three minutes, while a Claude graph runs or waits on a limit.
    if watch and (claude_active or st["state"] != "ok"):
        _read_probe(st, env, now)
    u = st.get("usage") or {}
    fresh = _fresh(st, now)

    if st["state"] == "ok" and claude_active:
        ov = inner.get("override") if isinstance(inner.get("override"), dict) else {}
        week_pct = u.get("week_pct") if fresh else None
        week_seat = [h for h in hits if "week" in h["line"].lower() or (h["reset"] and h["reset"] - now > FAR_RESET_S)]
        # 100% of the week stops Claude, unless its usage credits are on: then it goes on, paid by the person
        week_real = bool(week_seat) or (week_pct is not None and week_pct >= 100 and st.get("credits") != "on")
        week_bar = cfg["week_stop_pct"] > 0 and week_pct is not None and week_pct >= cfg["week_stop_pct"]
        five = (fresh and u.get("session_pct") is not None and u["session_pct"] >= SESSION_HIT_PCT) or bool(hits)
        if ((week_real and (cfg["ride_out_5h"] or cfg["week_stop_pct"] > 0)) or week_bar) \
                and now >= float(ov.get("week_until") or 0):
            until = _later(now, u.get("week_reset") if fresh else None, *[h["reset"] for h in week_seat]) \
                or (now + WEEK_FALLBACK_S if week_real else None)
            paused = _pause_all(st, claude_active, env, REASON_WEEK)
            inner["why"] = "week_limit" if week_real else "week_pct"
            inner["hold_lines"] = {h["seat"]: h["line"] for h in hits}
            st.update(state="paused_week", until=until)
            when = f" ({_clock(until, now)})" if until else ""
            if week_real:
                st["note"] = f"Claude's weekly limit is reached · graphs paused until the weekly reset{when}"
            else:
                st["note"] = (f"This week's Claude use is at {week_pct}% · graphs paused until the weekly reset{when}, "
                              f"or until you resume them")
            did.append(f"paused for the week: {', '.join(paused) or 'none'}")
        elif cfg["ride_out_5h"] and five and now >= float(ov.get("h5_until") or 0):
            until = _later(now, u.get("session_reset") if fresh and (u.get("session_pct") or 0) >= SESSION_HIT_PCT else None,
                           *[h["reset"] for h in hits], u.get("session_reset") if fresh else None) \
                or now + FIVE_HOUR_FALLBACK_S
            paused = _pause_all(st, claude_active, env, REASON_5H)
            inner["why"] = "five_hour"
            inner["hold_lines"] = {h["seat"]: h["line"] for h in hits}
            st.update(state="paused_5h", until=until, note=f"Graphs paused for Claude's 5-hour limit · back at {_clock(until, now)}")
            did.append(f"paused for the 5-hour limit: {', '.join(paused) or 'none'}")
    elif st["state"] != "ok" and claude_active:
        # a Claude graph started during the hold would only run into the same limit
        reason = REASON_5H if st["state"] == "paused_5h" else REASON_WEEK
        have = {(p["session"], p["graph"]) for p in st["paused"]}
        new = [g for g in claude_active if (str(g.get("session")), str(g.get("id"))) not in have and not inner.get("seen", {}).get(f"{g.get('session')}/{g.get('id')}")]
        if new:
            paused = _pause_all(st, new, env, reason)
            if paused:
                did.append(f"paused (started during the hold): {', '.join(paused)}")
    if st["state"] != "ok":
        # graphs this hold has already seen: one the person resumed by hand stays resumed. A graph left
        # running because it has no Claude step is not counted: when a step of it goes out on Claude during
        # the hold, it is held then, as a graph started during the hold is (and told to go on at the reset).
        seen = inner.setdefault("seen", {})
        spared = {(str(g.get("session")), str(g.get("id"))) for g in active} \
            - {(str(g.get("session")), str(g.get("id"))) for g in claude_active}
        for g in mine:
            if (str(g.get("session")), str(g.get("id"))) not in spared:
                seen[f"{g.get('session')}/{g.get('id')}"] = now
    else:
        inner.pop("seen", None)
    if st["state"] == "ok":
        st["note"] = ""
    _save_if_changed(st, before)
    return {**public(st), "did": did}


def _prune(inner: dict[str, Any], now: float) -> None:
    """Bookkeeping that has done its job: a Resume whose reset passed, limit lines long gone."""
    ov = inner.get("override")
    if isinstance(ov, dict):
        for k in [k for k, v in ov.items() if not isinstance(v, (int, float)) or float(v) <= now]:
            ov.pop(k, None)
        if not ov:
            inner.pop("override", None)
    stale = inner.get("stale_lines")
    if isinstance(stale, dict):
        for k in [k for k, v in stale.items() if not isinstance(v, dict) or now - float(v.get("at") or 0) > STALE_LINE_S]:
            stale.pop(k, None)
        if not stale:
            inner.pop("stale_lines", None)


def _save_if_changed(st: dict[str, Any], before: str) -> None:
    if json.dumps(st, sort_keys=True, default=str) != before:
        save_state(st)


def resume_now(*, env: Env | None = None, now: float | None = None) -> dict[str, Any]:
    """``pong limits resume``: lift the limit pauses now (the person pressed Resume). The same limit does not
    pause the graphs again until its reset has passed."""
    with _state_lock():
        return _resume_now(env or Env(), time.time() if now is None else float(now))


def _resume_now(env: Env, now: float) -> dict[str, Any]:
    st = load_state()
    was = st["state"]
    if was == "ok" and not st["paused"]:
        return {"ok": True, "resumed": [], "state": "ok", "note": "Nothing was paused for a limit."}
    lifted = _lift(st, env)
    if was != "ok":
        u = st.get("usage") or {}
        ov = st["_"].setdefault("override", {})
        if was == "paused_week":
            ov["week_until"] = float(_later(now, st.get("until"), u.get("week_reset")) or now + WEEK_FALLBACK_S)
        else:
            ov["h5_until"] = float(_later(now, st.get("until"), u.get("session_reset")) or now + 3600)
        st.update(state="ok", until=None, note="")
        _end_hold(st, now)
        st["_"].pop("seen", None)
    st["_"]["last_event"] = {"at": now, "text": f"Resumed by you at {_clock(now, now)}"}
    save_state(st)
    res: dict[str, Any] = {"ok": True, "resumed": lifted, "state": "ok", "was": was}
    left = [f"{p['session']}/{p['graph']}" for p in st["paused"]]
    if left:
        res["not_resumed"] = left
        res["note"] = (f"{len(left)} graph{'s' if len(left) != 1 else ''} could not be resumed yet; "
                       "the runner tries again in a moment.")
    return res


def status() -> dict[str, Any]:
    """``pong limits status``: the state, the effective limit switches (``settings``, as in settings.json's
    ``limits``) and whether Claude is switched on at all (``claude_on``: off, nothing is watched)."""
    st = load_state()
    cfg = _settings()
    claude_on = cfg.pop("claude", True)  # Claude's own switch (Settings › AI accounts), not a limit switch
    return {**public(st), "settings": cfg, "claude_on": claude_on,
            "last_event": (st["_"].get("last_event") if isinstance(st["_"].get("last_event"), dict) else None),
            "usage_note": str(st["_"].get("probe_note") or "")}
