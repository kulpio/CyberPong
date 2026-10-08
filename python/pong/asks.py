"""Questions an AI asks the person outside a graph's gates (1.9).

An architect used to ask its questions as a menu inside its own terminal: they showed up nowhere else,
so the person had to find them. ``pong ask new`` puts the question where every question is: the app's Needs you
page, a Mac notification, the chat's own page and the notch panel, as the same question card a gate gets.
The answer comes back into the asker's chat as one ``[CyberPong]`` line, sent when it is idle (the same
queue a graph's news uses), so the AI reads it exactly like any other news.

The asker words the question and each option's meaning; the app never rewords a button. A question is
data, never an instruction: the app shows it and sends back what the person pressed.

A question also carries up to six points that explain the decision in more depth (2.0, ``detail``),
each with the file it comes from, so the person decides without reading the whole file. The asker
writes them (``pong ask new --detail "fact::file::where"``). A question filed without any gets them
from the helper model in the background (``pong ask explain``, the same model and checks as a gate's
plain words): ``detail_pending`` is true while it writes, and only on the real home with the helper
switched on (``PONG_ASK_DETAIL=off`` turns it off; ``PONG_PLAIN_ASK_CMD`` names a fake model in tests).
"""

from __future__ import annotations

import fcntl
import os
import secrets
import subprocess
import sys
import time
from contextlib import contextmanager
from pathlib import Path
from typing import Any, Iterator

ASK_FILE = "asks.json"
MAX_OPTIONS = 4
MAX_QUESTION = 300
MAX_CONTEXT = 3
MAX_FILES = 6
KEEP_ANSWERED = 60
#: Where the helper model's prompt, answer and log for a question's points are kept (per team).
DETAIL_DIR = "ask-detail"


class AskError(ValueError):
    pass


def _path(session: str) -> Path:
    from .paths import sessions_dir

    return sessions_dir(session) / ASK_FILE


@contextmanager
def _locked(session: str) -> Iterator[dict[str, Any]]:
    from .jsonutil import read_json, write_json

    p = _path(session)
    p.parent.mkdir(parents=True, exist_ok=True)
    with open(str(p) + ".lock", "a+") as lk:
        fcntl.flock(lk, fcntl.LOCK_EX)
        data = read_json(p) or {}
        if not isinstance(data.get("asks"), list):
            data["asks"] = []
        yield data
        write_json(p, data)


def _view(rec: dict[str, Any]) -> dict[str, Any]:
    """A question as it is read: points still "coming" from a helper that died long ago are not coming."""
    if rec.get("detail_pending"):
        from .plain_ask import TIMEOUT_S

        try:
            started = float(rec.get("detail_started") or 0)
        except (TypeError, ValueError):
            started = 0.0
        if time.time() - started > TIMEOUT_S + 60:
            rec = dict(rec)
            rec.pop("detail_pending", None)
    return rec


def _read(session: str) -> list[dict[str, Any]]:
    from .jsonutil import read_json

    data = read_json(_path(session)) or {}
    return [_view(a) for a in data.get("asks") or [] if isinstance(a, dict)]


def _clean(s: Any, limit: int) -> str:
    return " ".join(str(s or "").split())[:limit]


def parse_option(raw: str) -> dict[str, str]:
    """``"Start round 3::Launches it now; the week's budget allows it"`` → label and what it does."""
    label, _, what = str(raw or "").partition("::")
    label, what = _clean(label, 60), _clean(what, 200)
    if not label:
        raise AskError("an option needs a label")
    return {"label": label, "what": what}


def _abs(f: Any, cwd: str | None = None) -> str:
    """A file the asker named, as a full path (a relative one is under the asker's folder)."""
    p = os.path.expanduser(str(f or "").strip())
    return os.path.abspath(os.path.join(cwd or os.getcwd(), p)) if p else ""


def parse_detail(raw: str, cwd: str | None = None) -> dict[str, str]:
    """``"Edit 19 changes the quote on page 2::UPDATE.md::Edit 19"`` → a point: its text, the file it comes
    from (a full path, against the asker's folder) and where in it. The file and the where are optional."""
    text, _, rest = str(raw or "").partition("::")
    f, _, where = rest.partition("::")
    text = _clean(text, 2000)
    if not text:
        raise AskError("a detail point needs its text before any ::")
    point = {"text": text}
    if f.strip():
        point["file"] = _abs(f, cwd)
    if _clean(where, 200):
        point["where"] = _clean(where, 200)
    return point


def _asker(session: str, seat: str) -> str:
    """The architect whose seat asks (newest first: a dead architect's seat name can be reused)."""
    seat = str(seat or "").strip()
    if not seat:
        return ""
    try:
        from .architect import list_for

        for a in reversed(list_for(session)):
            if a.get("seat") == seat:
                return str(a.get("id") or "")
    except Exception:
        pass
    return ""


def new(session: str, question: str, *, context: list[str] | None = None, options: list[dict[str, str]] | None = None,
        files: list[str] | None = None, seat: str = "", arch_id: str = "", detail: Any = None,
        detail_by: str = "the chat", cwd: str | None = None) -> dict[str, Any]:
    """Post a question for the person. Returns the record (its ``id`` answers it).

    ``files`` and each detail point's ``file`` become full paths against ``cwd`` (the asker's folder by
    default); a point's file that does not exist is left off the point (its text stays)."""
    from .plain_ask import _clamp, clean_detail

    q = _clean(question, MAX_QUESTION)
    if not q:
        raise AskError("a question is needed")
    opts = list(options or [])[:MAX_OPTIONS]
    for i, o in enumerate(opts, 1):
        o["key"] = str(i)
    seat = str(seat or os.environ.get("PONG_SEAT") or "").strip()
    points = clean_detail(detail or [], lambda f: _abs(f, cwd) if os.path.exists(_abs(f, cwd)) else "")
    rec = {
        "id": "q_" + secrets.token_hex(4),
        "session": session,
        "seat": seat,
        "architect": arch_id or _asker(session, seat),
        "question": q,
        # a long line is cut where a sentence (or a clause) ends, never inside a word
        "context": [_clamp(c, 240) for c in (context or []) if _clamp(c, 240)][:MAX_CONTEXT],
        "options": opts,
        "files": list(dict.fromkeys(_abs(f, cwd) for f in (files or []) if str(f).strip()))[:MAX_FILES],
        "created_at": time.time(),
        "status": "open",
    }
    if points:
        rec["detail"] = points
        rec["detail_by"] = str(detail_by or "the chat")
    with _locked(session) as data:
        data["asks"].append(rec)
        # answered questions are history: keep the last ones
        done = [a for a in data["asks"] if a.get("status") != "open"]
        if len(done) > KEEP_ANSWERED:
            drop = {id(a) for a in done[:-KEEP_ANSWERED]}
            data["asks"] = [a for a in data["asks"] if id(a) not in drop]
    return rec


def list_open(session: str | None = None) -> list[dict[str, Any]]:
    """Open questions, oldest first: one team's, or every team's on this Mac."""
    from .paths import sessions_dir

    sessions = [session] if session else []
    if not session:
        base = sessions_dir()
        if base.is_dir():
            sessions = [d.name for d in sorted(base.iterdir())
                        if d.is_dir() and not d.name.startswith(("_", ".")) and (d / ASK_FILE).exists()]
    out = [a for s in sessions for a in _read(s) if a.get("status") == "open"]
    return sorted(out, key=lambda a: float(a.get("created_at") or 0))


def get(session: str, ask_id: str) -> dict[str, Any]:
    for a in _read(session):
        if a.get("id") == ask_id:
            return a
    raise AskError(f"no question {ask_id!r} on {session}")


def _deliver(session: str, rec: dict[str, Any], text: str) -> str:
    """The answer goes to the asker as news: typed now when its chat is idle, else queued for the next tick."""
    arch = str(rec.get("architect") or "")
    if arch:
        from . import architect as A

        with A._locked(session) as data:
            for a in data["architects"]:
                if a.get("id") == arch:
                    q = a.setdefault("queue", [])
                    q.append({"at": time.time(), "kind": "answer", "graph": "", "text": text})
                    del q[:-A.MAX_QUEUE]
                    break
            else:
                arch = ""
        if arch:
            try:
                A.pump(session)
            except Exception:
                pass
            return "queued"
    seat = str(rec.get("seat") or "")
    if seat:
        from .architect import _capture, _type, idle_and_empty

        screen = _capture(session, seat, 40)
        if screen is not None and idle_and_empty(screen) and _type(session, seat, "[CyberPong] " + text):
            return "typed"
    return "kept"


def answer(session: str, ask_id: str, *, choice: str = "", note: str = "", who: str = "") -> dict[str, Any]:
    """Record the person's answer and send it back to the asker."""
    from .settings import owner_name  # the name the person gave in Settings, else "The person"
    who = str(who or "").strip() or owner_name(capital=True)
    note = _clean(note, 600)
    with _locked(session) as data:
        rec = next((a for a in data["asks"] if a.get("id") == ask_id), None)
        if rec is None:
            raise AskError(f"no question {ask_id!r} on {session}")
        if rec.get("status") != "open":
            raise AskError(f"question {ask_id} is already {rec.get('status')}")
        opts = {str(o.get("key")): o for o in rec.get("options") or []}
        if opts and choice not in opts:
            raise AskError(f"no option {choice!r}: the options are {', '.join(opts)}")
        if not opts and not note:
            raise AskError("this question has no options: answer it with a note")
        label = str(opts[choice].get("label")) if choice in opts else ""
        rec["status"] = "answered"
        rec["answer"] = {"key": choice, "label": label, "note": note, "by": who, "at": time.time()}
    said = f"“{label}”" if label else "with a note"
    text = f"{who} answered your question {ask_id} (“{rec['question']}”): {said}." + (f" {who}'s note: {note}" if note else "")
    rec["delivery"] = _deliver(session, rec, text)
    with _locked(session) as data:
        for a in data["asks"]:
            if a.get("id") == ask_id:
                a["delivery"] = rec["delivery"]
    return rec


def withdraw(session: str, ask_id: str) -> dict[str, Any]:
    """The asker takes its question back (it found the answer, or the moment passed)."""
    with _locked(session) as data:
        for a in data["asks"]:
            if a.get("id") == ask_id:
                if a.get("status") == "open":
                    a["status"] = "withdrawn"
                    a["withdrawn_at"] = time.time()
                return dict(a)
    raise AskError(f"no question {ask_id!r} on {session}")


# ------------------------------------------------------------- the points, from the helper model ---

def explain_enabled() -> bool:
    """The helper model writes a question's points only where a gate's plain words may be written (the
    real home, the person's "Helper AI" switch on, Claude switched on in Settings › AI accounts (the helper
    is Claude Haiku: ``ai_enabled.claude`` false stops it too), ``claude`` installed, or a fake command in
    tests), and not with ``PONG_ASK_DETAIL=off``."""
    if str(os.environ.get("PONG_ASK_DETAIL") or "").strip().lower() in ("off", "0", "no", "false"):
        return False
    from .plain_ask import enabled

    return enabled({})


def _detail_dir(session: str) -> Path:
    from .paths import sessions_dir

    return sessions_dir(session) / DETAIL_DIR


def start_explain(session: str, ask_id: str) -> bool:
    """Start ``pong -s <team> ask explain --id <q>`` in the background for an open question with no points.
    True when it started: the question then reads ``detail_pending`` until the helper is done.

    Only for a question that names a file the helper can read: without one there is nothing to explain
    beyond what the card already says, and no token is spent."""
    from .plain_ask import readable

    if not explain_enabled():
        return False
    with _locked(session) as data:
        rec = next((a for a in data["asks"] if a.get("id") == ask_id), None)
        if rec is None or rec.get("status") != "open" or rec.get("detail") or _view(rec).get("detail_pending"):
            return False
        if not any(readable(f) for f in rec.get("files") or []):
            return False
        rec["detail_pending"] = True
        rec["detail_started"] = time.time()
        rec.pop("detail_error", None)
    try:
        work = _detail_dir(session)
        work.mkdir(parents=True, exist_ok=True)
        env = dict(os.environ)
        pkg = str(Path(__file__).resolve().parent.parent)  # this engine, whichever copy of it runs
        env["PYTHONPATH"] = pkg + (os.pathsep + env["PYTHONPATH"] if env.get("PYTHONPATH") else "")
        with open(work / f"{ask_id}.log", "ab") as log:
            subprocess.Popen([sys.executable, "-m", "pong.cli.main", "-s", session, "ask", "explain", "--id", ask_id],
                             stdin=subprocess.DEVNULL, stdout=log, stderr=log, cwd=str(work), env=env,
                             start_new_session=True)
        return True
    except Exception as e:
        _finish_explain(session, ask_id, [], f"not started — {e}"[:200])
        return False


def _finish_explain(session: str, ask_id: str, detail: list[dict[str, str]], error: str) -> dict[str, Any]:
    from .plain_ask import BY_MODEL

    with _locked(session) as data:
        for a in data["asks"]:
            if a.get("id") == ask_id:
                a.pop("detail_pending", None)
                a.pop("detail_started", None)
                if detail and not a.get("detail"):
                    a["detail"] = detail
                    a["detail_by"] = BY_MODEL
                    a.pop("detail_error", None)
                elif error:
                    a["detail_error"] = error
                return dict(a)
    raise AskError(f"no question {ask_id!r} on {session}")


def explain(session: str, ask_id: str) -> dict[str, Any]:
    """Write an open question's points with the helper model, once (what ``ask explain`` runs).

    The model reads the question, its context and options and up to four of its files (never a key
    file), and writes only the points, with thinking off; they are checked as a gate's are (a point that
    recommends an answer, says what one of the options does or holds a key is dropped, a file is kept
    only when it is one the question names). ``detail_pending`` is cleared whatever happens, and a
    question that already has points keeps them."""
    from . import plain_ask as P

    rec = get(session, ask_id)
    if rec.get("detail") or rec.get("status") != "open":
        return _finish_explain(session, ask_id, [], "")
    if not explain_enabled():  # the person's helper switch (and a test's temporary home) hold for a run by hand too
        return _finish_explain(session, ask_id, [], "not run — the helper AI is off here")
    work = _detail_dir(session)
    work.mkdir(parents=True, exist_ok=True)
    base = str(work / ask_id)
    files = [str(f) for f in rec.get("files") or []]
    detail: list[dict[str, str]] = []
    error = ""
    try:
        prompt = P.ask_prompt(rec)
        Path(base + ".prompt.txt").write_text(prompt, encoding="utf-8")
        r = subprocess.run(P._command(), input=prompt, capture_output=True, encoding="utf-8", errors="replace",
                           timeout=P.TIMEOUT_S, cwd=str(work))
        Path(base + ".out.json").write_text(r.stdout or "", encoding="utf-8")
        Path(base + ".err.txt").write_text(r.stderr or "", encoding="utf-8")
        if r.returncode != 0:
            error = "the helper did not answer"
        else:
            labels = [str(o.get("label") or "") for o in rec.get("options") or [] if isinstance(o, dict)]
            parsed = P.parse(r.stdout or "", [], files=files, detail_only=True, labels=labels)
            detail = (parsed or {}).get("detail") or []
            error = "" if detail else "no usable answer"
    except subprocess.TimeoutExpired:
        error = "took too long"
    except Exception as e:
        error = f"not run — {e}"[:200]
    return _finish_explain(session, ask_id, detail, error)
