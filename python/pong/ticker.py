"""One short line for the island's right ear.

The ear is a sliver of menu bar, so this is not a feed — it is the single most
important thing the team currently has to say, in as few words as will carry it.
Three tones, and only ever one of them:

* **orange** — somebody needs the owner. Beats everything, because it is the only
  state that does not resolve itself.
* **green** — a goal just closed. Worth a glance, not an interruption.
* **purple** — the chief said something mid-task.

Composed here rather than in the island so the display never parses prose: the
island receives a tone and a string that already fits, and draws it.
"""

from __future__ import annotations

import json
import time
from typing import Any

#: What actually fits inside the ear once the shape's own chrome is subtracted:
#: the clip body is inset by the shoulder, the bottom corner curve takes more,
#: and a real margin has to survive after the last glyph. At 18 the text overran
#: the usable width by about 5pt and the final letter was cut in half.
MAX_CHARS = 16
#: A finished goal is news for this long, then it is just history.
FRESH_DONE_SEC = 10 * 60


def _short(text: str, limit: int = MAX_CHARS) -> str:
    """Shorten by dropping words, not by shrinking type or cutting mid-word."""
    t = " ".join(str(text or "").split())
    if len(t) <= limit:
        return t
    words: list[str] = []
    for w in t.split(" "):
        if len(" ".join(words + [w])) > limit - 1:
            break
        words.append(w)
    return (" ".join(words) + "…") if words else t[: limit - 1] + "…"


def _first_name(label: str) -> str:
    """'Engineering — CyberPong' is too long for the ear; 'Engineering' is not."""
    return str(label or "").split("—")[0].split("·")[0].strip() or str(label or "")


def _who_and(who: str, tail: str) -> str:
    """Fit "<who> <tail>" by shortening the NAME, never the message.

    "Deck Writer needs you" does not fit and truncating it leaves "Deck Writer
    needs…", which drops the only word that matters. Cutting the name instead
    gives "Deck needs you", which still says the thing.
    """
    full = f"{who} {tail}".strip()
    if len(full) <= MAX_CHARS:
        return full
    short_who = who.split(" ")[0]
    trimmed = f"{short_who} {tail}".strip()
    return trimmed if len(trimmed) <= MAX_CHARS else _short(trimmed)


def _clean_lead(text: str) -> str:
    """Drop leading TUI furniture so the ear starts on a word.

    Chief cards are captured from a pane, and one arrived as "❙ ◆ Run Show…" —
    two box glyphs and a fragment. Nothing before the first letter or digit is
    ever the message.
    """
    t = str(text or "").lstrip()
    for i, ch in enumerate(t):
        if ch.isalnum():
            return t[i:]
    return ""


def _strip_label(text: str, labels: list[str]) -> str:
    """Drop a leading seat label so the ear shows the news, not the name.

    Seat labels contain em-dashes themselves, so this matches whole known
    labels rather than guessing at a separator.
    """
    t = str(text or "").lstrip()
    for lab in sorted(labels, key=len, reverse=True):
        if not lab:
            continue
        for sep in (" — ", " - ", ": ", " · ", " "):
            if t.startswith(lab + sep):
                return t[len(lab) + len(sep):].lstrip()
    return t


def _chat_rows(session: str, limit: int = 40) -> list[dict[str, Any]]:
    from .paths import state_dir

    path = state_dir() / "human" / session / "chat.jsonl"
    try:
        lines = path.read_text(encoding="utf-8").splitlines()[-limit:]
    except Exception:
        return []
    out: list[dict[str, Any]] = []
    for line in lines:
        line = line.strip()
        if not line:
            continue
        try:
            out.append(json.loads(line))
        except Exception:
            continue
    return out


#: The ear rotates, but it is still an ear — past a handful of lines nobody is
#: reading them, they are just moving.
MAX_LINES = 4


def build_ticker(
    session: str,
    state: dict[str, Any],
    jobs: dict[str, Any] | None = None,
    *,
    now: float | None = None,
) -> list[dict[str, str]]:
    """Every line the ear should rotate through, most urgent first.

    A list rather than one line: with several agents live there can genuinely be
    more than one thing worth saying, and picking a single winner threw the rest
    away. Priority still decides the ORDER — needs-you leads — but nothing is
    dropped for being second.

    An empty list is a real answer: a quiet ear means nothing needs saying, and
    filling it with the last thing that happened teaches you to stop reading it.
    """
    now = now if now is not None else time.time()
    jobs = jobs or {}
    labels = {
        str(w.get("id")): str(w.get("label") or w.get("id"))
        for w in (state.get("workers") or [])
    }

    lines: list[dict[str, str]] = []

    def add(tone: str, text: str) -> None:
        if not text:
            return
        if any(l["text"] == text for l in lines):      # same seat, two signals
            return
        lines.append({"tone": tone, "text": text})

    # ORANGE — someone is stopped and only a person can move them. Every one of
    # them, not just the first: two blocked agents is worse than one, and the ear
    # now has room to say so.
    for j in jobs.get("open") or []:
        status = str(j.get("status") or "").lower()
        if j.get("human_takeover") or "human" in status or "ask" in status:
            who = _first_name(labels.get(str(j.get("worker")), str(j.get("worker") or "")))
            add("orange", _who_and(who, "needs you"))
    for row in _chat_rows(session):
        if str(row.get("kind")) == "ask":
            who = _first_name(labels.get(str(row.get("seat_id")), "Someone"))
            add("orange", _who_and(who, "needs you"))

    # GREEN — goals that just closed. Recent only; a win from an hour ago is not
    # news, and the ear is not a log.
    fresh = [
        j for j in (jobs.get("recent") or [])
        if str(j.get("status") or "").lower() in ("done", "accepted")
        and now - float(j.get("updated_at") or 0) <= FRESH_DONE_SEC
    ]
    for j in sorted(fresh, key=lambda j: float(j.get("updated_at") or 0), reverse=True):
        who = _first_name(labels.get(str(j.get("worker")), str(j.get("worker") or "")))
        add("green", _who_and(who, "done"))

    # PURPLE — the chief talking mid-task, in its own words.
    #
    # Only cards with no job_id. The ones carrying a job id are the automatic
    # "X finished" recaps, and a finished job is already what green says;
    # shortening one of those to sixteen characters yields a fragment of a seat
    # label rather than news. A card with no job behind it is the chief speaking.
    for row in reversed(_chat_rows(session)):
        if str(row.get("kind")) != "from_orch":
            continue
        if str(row.get("seat_id") or "") != "c1":
            continue
        if str(row.get("job_id") or "").strip():
            continue
        add("purple", _short(_clean_lead(
            _strip_label(_clean_lead(str(row.get("text") or "")), list(labels.values())))))
        break

    return lines[:MAX_LINES]
