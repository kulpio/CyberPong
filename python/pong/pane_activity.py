"""Whether a TUI pane is actually generating an answer right now.

Job files and `pong seat available` miss this: the chief thinking in Grok has
no open Pong job and has usually marked itself available. The island then
shows quiet.

Looks at pane text, not at whether the window redrew. Idle Claude repaints
clocks; that is not work. A `[stop]` control, `ctrl+c to interrupt`, or a
spinner next to a running timer is.
"""

from __future__ import annotations

import re
import subprocess
from concurrent.futures import ThreadPoolExecutor
from typing import Iterable

_STOP = re.compile(r"\[stop\]", re.I)
_INTERRUPT = re.compile(r"(?:ctrl\s*\+\s*c|esc)\s+to interrupt", re.I)
_RUNNING = re.compile(
    r"(?:[\u2800-\u28FF⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏]|[✶✻✽])\s+\S.+\d+(?:\.\d+)?s\b"
)
# Claude's finished-turn line: "✻ Churned for 37s" (verb changes every build).
_CLAUDE_DONE = re.compile(r"[✻✽]\s+\S.+\s+for\s+\d+")
_PAST_DONE = re.compile(
    r"(?:crunched|cogitated|baked|cooked|worked|thought|churned)\s+for\s+",
    re.I,
)


def is_thinking(pane: str) -> bool:
    """True when the visible pane is mid-turn, not sitting at a prompt."""
    if not (pane or "").strip():
        return False
    if _STOP.search(pane):
        return True
    if _INTERRUPT.search(pane):
        return True
    if _CLAUDE_DONE.search(pane) or _PAST_DONE.search(pane):
        return False
    if _RUNNING.search(pane):
        return True
    return False


def _tmux(*args: str) -> tuple[bool, str]:
    try:
        from .groups import tmux_bin  # Homebrew's tmux, even off the shell's PATH

        r = subprocess.run(
            [tmux_bin() or "tmux", *args], text=True, capture_output=True, timeout=8
        )
        return r.returncode == 0, ((r.stdout or "") + (r.stderr or "")).strip()
    except Exception:
        return False, ""


def session_alive(session: str) -> bool:
    """Whether the team's own tmux session is there. The target is exact ("=name:"): with a bare name
    tmux takes the one session whose name starts with it, so a stopped pong-team-9 read pong-team-91."""
    if not session:
        return False
    ok, _ = _tmux("has-session", "-t", f"={session}:")
    return ok


def capture_pane(session: str, idx: int) -> tuple[bool, str]:
    """``(ok, text)`` for one pane.

    ``ok=False`` means tmux could not read the pane at all. That is not the
    same as a pane that is genuinely empty, and a caller gating a paste on
    "is this seat mid-turn" must not read an unreadable pane as "idle".
    The session name is matched exactly, never as the start of another team's name.
    """
    return _tmux("capture-pane", "-p", "-J", "-t", f"={session}:{idx}", "-S", "-16")


def capture(session: str, idx: int) -> str:
    """Pane text, or ``""`` when tmux could not read it.

    Use ``capture_pane`` where the empty/unreadable difference decides
    something.
    """
    ok, out = capture_pane(session, idx)
    return out if ok else ""


def capture_all(session: str, indices: Iterable[int]) -> dict[int, str]:
    """idx → pane text. One tmux capture per pane, in parallel.

    Same capture as ``scan`` / ``capture`` — this is the shared scrape,
    not a second one. Callers that need thinking and usage both read
    this dict rather than hitting tmux again.
    """
    return capture_all_alive(session, indices)[1]


def capture_all_alive(session: str, indices: Iterable[int]) -> tuple[bool, dict[int, str]]:
    """``(alive, idx → pane text)``: :func:`capture_all` plus whether the team's tmux session is
    there at all (the check it already makes), so the snapshot can say a team is up without asking
    tmux twice."""
    if not session_alive(session):
        return False, {}
    idxs = [i for i in indices if isinstance(i, int) and i >= 0]
    if not idxs:
        return True, {}

    def one(i: int) -> tuple[int, str]:
        return i, capture(session, i)

    if len(idxs) == 1:
        i, t = one(idxs[0])
        return True, {i: t}
    out: dict[int, str] = {}
    with ThreadPoolExecutor(max_workers=min(8, len(idxs))) as pool:
        for i, t in pool.map(one, idxs):
            out[i] = t
    return True, out


def scan(session: str, indices: Iterable[int]) -> dict[int, bool]:
    """idx → thinking, for windows that exist. Missing session → empty."""
    return {i: is_thinking(t) for i, t in capture_all(session, indices).items()}


# --- usage, from the same pane text ---------------------------------------
# Only patterns we have actually seen (or the job named). Nothing is guessed,
# cached, or carried forward: no match this poll → no field this poll.

_WEEKLY = re.compile(
    r"You'?ve used\s+(\d+(?:\.\d+)?)\s*%\s+of your weekly limit",
    re.I,
)
_RESET = re.compile(r"resets?\s+([^\n·|]{3,48})", re.I)
_REMAINING_PCT = re.compile(
    r"(\d+(?:\.\d+)?)\s*%\s+(?:of (?:your )?weekly (?:limit )?remaining|remaining)\b",
    re.I,
)
_SAVE_TOKENS = re.compile(
    r"(?:/clear to save|to save)\s+(\d+(?:\.\d+)?)\s*([kKmM])\s*tokens?\b",
    re.I,
)
_TOKENS = re.compile(r"\b(\d+(?:\.\d+)?)\s*([kKmM])\s*tokens?\b", re.I)
_CONTEXT_FRAC = re.compile(
    r"\b(\d+(?:\.\d+)?)\s*([kKmM])\s*/\s*(\d+(?:\.\d+)?)\s*([kKmM])\b",
    re.I,
)
_GROK_METER = re.compile(r"⇣\s*(\d+(?:\.\d+)?)\s*([kKmM])\b")
_KEYISH = re.compile(
    r"(?i)(sk-|ghp_|gho_|github_pat_|xai-|api[_-]?key|secret|password|bearer\s)",
)


def _qty(num: str, suffix: str) -> str:
    n = (num or "").strip()
    if n.endswith(".0"):
        n = n[:-2]
    return f"{n}{(suffix or '').lower()}"


def _ok_chip(s: str) -> str | None:
    t = (s or "").strip()
    if not t or len(t) > 12:
        return None
    if _KEYISH.search(t):
        return None
    if re.fullmatch(r"\d+(?:\.\d+)?%?", t):
        return t
    if re.fullmatch(r"\d+(?:\.\d+)?[kKmM]", t):
        return t
    return None


def _ok_reset(s: str) -> str | None:
    t = " ".join((s or "").split())
    if not t or len(t) > 48:
        return None
    if _KEYISH.search(t) or "=" in t:
        return None
    return t


def parse_usage(pane: str) -> dict | None:
    """Pull usage counts out of one pane. ``None`` if nothing real is there.

    Never invents, never estimates remaining from a percentage, never keeps
    a previous poll's number. The snapshot field is absent unless this
    text just produced a match.
    """
    text = pane or ""
    if not text.strip():
        return None

    out: dict = {}

    wm = _WEEKLY.search(text)
    if wm:
        try:
            pct = float(wm.group(1))
        except ValueError:
            pct = None
        if pct is not None and 0 <= pct <= 100:
            chip = f"{int(pct)}%" if pct == int(pct) else f"{pct}%"
            if _ok_chip(chip):
                out["weekly_pct"] = pct
                out["weekly_chip"] = chip
            tail = text[wm.end() : wm.end() + 80]
            rm = _RESET.search(tail) or _RESET.search(text)
            if rm:
                reset = _ok_reset(rm.group(1).strip(" ."))
                if reset:
                    out["reset"] = reset

    rem = _REMAINING_PCT.search(text)
    if rem:
        try:
            rp = float(rem.group(1))
        except ValueError:
            rp = None
        if rp is not None and 0 <= rp <= 100:
            remaining = f"{int(rp)}%" if rp == int(rp) else f"{rp}%"
            if _ok_chip(remaining):
                out["remaining"] = remaining

    tokens = None
    sm = _SAVE_TOKENS.search(text) or _TOKENS.search(text)
    if sm:
        tokens = _ok_chip(_qty(sm.group(1), sm.group(2)))
    if tokens is None:
        fm = _CONTEXT_FRAC.search(text)
        if fm:
            tokens = _ok_chip(_qty(fm.group(1), fm.group(2)))
            limit = _ok_chip(_qty(fm.group(3), fm.group(4)))
            if tokens:
                out["used"] = tokens
            if limit:
                out["limit"] = limit
    if tokens is None:
        gm = _GROK_METER.search(text)
        if gm:
            tokens = _ok_chip(_qty(gm.group(1), gm.group(2)))
    if tokens:
        out["tokens"] = tokens

    # Row chip: a token count if we just read one, else a weekly percent.
    chip = tokens or out.get("weekly_chip")
    if chip:
        out["chip"] = chip

    return out or None
