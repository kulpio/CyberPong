"""Jev: TypeSafe's System One, typed decisions inside graph loops.

Jev never writes text. The engine offers it options it already holds (a
rubric's levels, a node's route labels, the candidates at a join, a gate's
answers) and a JSON state; Jev returns calibrated probabilities in well under
a second. Code turns those into an outcome; a person still presses anything
that goes outside the Mac.

Three rules are enforced here, not left to topology authors:

* **The key is never printed.** It is read, in this order, from the file
  Settings writes (``~/.pong/secrets/jev.env``), from ``TYPESAFE_API_KEY``,
  or from the ``key_file`` ``~/.pong/jev.json`` names; it is used for one
  request header and nowhere else — not in logs, not in the ledger, not in
  errors, not as a prefix in a status line.
* **Private text does not leave.** Before any call the state is scanned:
  anything that looks like a secret refuses the call; email addresses and
  phone numbers are replaced by ``[email]`` / ``[phone]``; a file on the deny
  list (key and credential files, mail, transcripts, client folders) or one
  whose text reads like a transcript is withheld. Client transcript bodies
  are never sent until the owner says TypeSafe's retention terms are settled.
* **No key, no guess.** Without a key, or when TypeSafe is unreachable, every
  question answers "not asked" and the caller routes to a person.

The built-in deny list holds only generic secrets and private data (key and
credential files, mail, transcripts, client folders). A person adds their own
patterns, matched the same way (case-blind, on the path and on where a link
points), under ``deny`` in ``~/.pong/jev.json``, for example::

    {"deny": ["*/private-notes/*", "*/consent.md", "*/people/*.md"]}

``pong jev status --json`` lists the built-in patterns and the added ones together.

Every call is appended to a ledger (``~/.pong/jev/ledger.jsonl``) with the
probabilities, the model, a hash of the state (never its text) and, later,
what a person actually decided, so calibration can be measured.
"""

from __future__ import annotations

import fnmatch
import hashlib
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request
import uuid
from pathlib import Path
from typing import Any

API_URL = "https://api.typesafe.ai/v1/systemone"
#: Pinned: thresholds are tuned against one version; the ``jev-latest`` alias moves on release.
DEFAULT_MODEL = "jev-1.13.0"
#: Where each key came from, as ``pong keys status`` and ``pong jev status`` name it.
KEY_SOURCES = ("settings", "environment", "key_file")
#: Per HTTP attempt, and for the whole decision including backoff (TypeSafe's SDK defaults).
ATTEMPT_TIMEOUT_SEC = 10.0
DEFAULT_TIMEOUT_SEC = 30.0
MAX_RETRIES = 2
#: Retried: 408, 429 and every 5xx (529 is TypeSafe's "overloaded"); never 400/401/403/404/422.
def _retryable(code: int) -> bool:
    return code in (408, 429) or 500 <= code <= 599
#: After this many failed calls in a row, stop calling for BREAKER_SEC (an outage fails fast).
BREAKER_FAILS = 3
BREAKER_SEC = 60.0
#: Jev's state limit is ~32k tokens; characters, not tokens, are what we can count cheaply.
#: The document budget, under the refusal line below (documents + goal + checks + JSON must fit).
STATE_CAP_CHARS = 70_000
#: Jev's limit for the state plus the longest question, and a cautious characters-per-token.
TOKEN_LIMIT = 28_000
CHARS_PER_TOKEN = 3.2
MAX_CHOICE_OPTIONS = 255
NONE_OPTION = "none"

#: Files that never go to Jev, whatever a topology says. Matched case-blind (APFS
#: is case-insensitive) on the path as given AND on where it really points, so a
#: symlink into a private folder is private too. A person's own private files go
#: under ``deny`` in jev.json (see the module docstring), not here.
DENY_ANY = (
    "*.eml", "*/mail/*", "*/.env", "*/.env.*", "*.env", "*.env.*",
    "*/.envrc", "*/secrets/*", "*.pem", "*.key", "*.p12", "*/token", "*/sessions/*/token",
    "*/.ssh/*", "*/.aws/*", "*/client_secret*.json", "*service-account*.json", "*/.netrc",
    "*/.pgpass", "*/.npmrc",
)
#: Data files only (notes, exports, captions): a transcript *parser* in code is not a transcript.
DENY_DATA = ("*transcript*", "*/transcripts/*", "*/clients/*", "*/calls/*", "*/recordings/*")
DATA_EXT = frozenset({"", ".md", ".markdown", ".txt", ".json", ".jsonl", ".csv", ".tsv", ".vtt", ".srt", ".html",
                      ".htm", ".rtf", ".docx", ".pdf", ".log", ".yaml", ".yml", ".xml"})
DEFAULT_DENY = DENY_ANY + DENY_DATA

#: Token shapes of the services this Mac uses, each behind a boundary so "task-…" or
#: "risk-…" slugs are not mistaken for "sk-…" keys. Scanned string by string.
_SECRET = re.compile(
    r"(?<![A-Za-z0-9_])(?:"
    r"apikey_[A-Za-z0-9_]{20,}|pplx-[A-Za-z0-9]{20,}|sk-(?:ant-|proj-)?[A-Za-z0-9_-]{20,}|xai-[A-Za-z0-9]{20,}|"
    r"gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}|AKIA[0-9A-Z]{16}|sb_secret_[A-Za-z0-9_-]{16,}|"
    r"sbp_[0-9a-f]{40}|GOCSPX-[\w-]{20,}|1//0[\w-]{30,}|ya29\.[\w-]{30,}|AIza[\w-]{35}|"
    r"1000\.[0-9a-f]{32}\.[0-9a-f]{32}|re_[A-Za-z0-9_]{24,}|[sr]k_(?:live|test)_[A-Za-z0-9]{20,}|xox[abprs]-[A-Za-z0-9-]{20,}|"
    r"eyJ[A-Za-z0-9_-]{30,}\.[A-Za-z0-9_-]{10,}"
    r")|-----BEGIN [A-Z ]*PRIVATE KEY(?: BLOCK)?-----|\b[a-z][a-z0-9+.-]*://[^\s:/@]+:[^\s@/]{6,}@")
#: A credential by its name rather than its shape (a UUID or plain hex under NOTETAKER_API_KEY=,
#: a JSON "client_secret"): the value must look like a token (16+ token characters with a digit)
#: and not be code that reads one (process.env.X, os.environ[...], a placeholder).
_SECRET_NAMED = re.compile(
    r"(?m)^\s*(?:export\s+)?[A-Z][A-Z0-9_]*(?:TOKEN|SECRET|API_?KEY|PASSWORD|PRIVATE_KEY|ACCESS_KEY)[A-Z0-9_]*"
    r"\s*[=:]\s*['\"]?(?![$<{(\[])(?!(?:process\.env|os\.environ|Deno\.env|import\.meta|env\.|config\.|settings\.))"
    r"(?=[A-Za-z0-9+/._~-]*\d)[A-Za-z0-9+/._~-]{16,}"
    r"|\"(?:client_secret|refresh_token|access_token|private_key|api_key)\"\s*:\s*\"(?=[^\"]*\d)[A-Za-z0-9+/._~=-]{16,}\"")


def has_secret(text: str) -> bool:
    """A key or token in *text*: a known service's shape, or a credential by its name."""
    return bool(_SECRET.search(text) or _SECRET_NAMED.search(text))


_EMAIL = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")
_PHONE = re.compile(r"(?<![\w.])(?:\+?1[ .-]?)?\(?\d{3}\)?[ .-]?\d{3}[ .-]?\d{4}(?![\w.])")
#: A labelled line of a call: "Speaker 1: …", "[00:12:31] Sam: …", "Sam (00:12): …",
#: a notetaker's "[00:41:12] **Sam:** …" and "**Sam**: …", a diff's +/- in front of any of them.
_SPEAKER = re.compile(
    r"^\s*[-+]?\s*(?:[>*-]\s+)?"
    r"(?:\[?\(?(?P<ts>\d{1,2}:\d{2}(?::\d{2})?)\)?\]?\s*[-–—]?\s*)?"
    r"(?P<bold>\*\*|__)?(?P<who>(?(bold)[^\W\d_]|[A-Z])[\w .'’-]{0,40}?)(?:\s*\((?P<ts2>\d{1,2}:\d{2}(?::\d{2})?)\))?"
    r"\s*(?::\s*(?:\*\*|__)|(?:\*\*|__)\s*:|:)\s+\S")
_TIMESTAMP = re.compile(r"\b\d{1,2}:\d{2}(?::\d{2})?\b")
_WINDOW = 40


def _window_is_call(rows: list[str]) -> bool:
    """Forty lines of a call: many timestamped speaker lines, or (untimed, as some
    notetakers' exports are) nearly every line labelled by a small cast taking turns."""
    n = len(rows)
    if n < 8:
        return False
    whos: list[str] = []
    stamped = 0
    for ln in rows:
        m = _SPEAKER.match(ln)
        if m and 2 <= len(m.group("who").strip()) and len(m.group("who").split()) <= 4:
            whos.append(m.group("who").strip().casefold())
        if _TIMESTAMP.search(ln):
            stamped += 1
    k = len(whos)
    if k >= 8 and k / n >= 0.35 and stamped / n >= 0.15:
        return True
    if k / n >= 0.8 and k >= 8:
        from collections import Counter

        cast = Counter(whos)
        if len(cast) >= 3:
            # a form repeats its field labels in a fixed cycle (Goal, Audience, Ideas, Goal, …);
            # three or more people on a call do not take turns in strict rotation
            p = len(cast)
            if sum(1 for i in range(p, k) if whos[i] == whos[i - p]) >= 0.9 * max(1, k - p):
                return False
        # turns, not lines: one speaker's turn is often several lines (some notetakers write a
        # line per sentence), so a call can have few switches per line and still be a call
        turns = [w for i, w in enumerate(whos) if i == 0 or w != whos[i - 1]]
        tcast = Counter(turns)
        return 2 <= len(cast) <= 8 and len(turns) >= 6 and all(c >= 2 for c in tcast.values())
    return False


def transcript_spans(text: str) -> list[tuple[int, int]]:
    """Line ranges [start, end) of *text* that read like a call transcript
    (every 40-line window, stepping 10, so an appendix after prose is found too)."""
    lines = str(text or "").splitlines()
    idx = [i for i, ln in enumerate(lines) if ln.strip()]
    if len(idx) < 8:
        return []
    size = min(_WINDOW, len(idx))
    starts = list(range(0, len(idx) - size + 1, 10))
    if starts[-1] != len(idx) - size:
        starts.append(len(idx) - size)
    spans: list[tuple[int, int]] = []
    for s0 in starts:
        win = idx[s0:s0 + size]
        if _window_is_call([lines[i] for i in win]):
            a, b = win[0], win[-1] + 1
            if spans and a <= spans[-1][1]:
                spans[-1] = (spans[-1][0], max(spans[-1][1], b))
            else:
                spans.append((a, b))
    return spans


def looks_like_transcript(text: str) -> bool:
    """Speaker-labelled turns anywhere in the text: a call transcript, whatever the file is called."""
    return bool(transcript_spans(text))


def _stamped_runs(lines: list[str]) -> list[tuple[int, int]]:
    """Runs of 3+ consecutive lines that are each a timestamped speaker line: a quoted
    stretch of a call, too short for a 40-line window to call a transcript."""
    runs: list[tuple[int, int]] = []
    start = None
    for i, ln in enumerate(lines + [""]):
        m = _SPEAKER.match(ln) if ln.strip() else None
        stamped = bool(m and (m.group("ts") or m.group("ts2")))
        if stamped and start is None:
            start = i
        elif not stamped and start is not None:
            if i - start >= 3:
                runs.append((start, i))
            start = None
    return runs


def redact_transcripts(text: str) -> tuple[str, int]:
    """*text* with every stretch that reads like a call replaced by a one-line note:
    a 40-line window that reads like a call, or 3+ timestamped speaker lines in a row."""
    lines = str(text).splitlines()
    spans = sorted(transcript_spans(text) + _stamped_runs(lines))
    merged: list[tuple[int, int]] = []
    for a, b in spans:
        if merged and a <= merged[-1][1]:
            merged[-1] = (merged[-1][0], max(merged[-1][1], b))
        else:
            merged.append((a, b))
    spans = merged
    if not spans:
        return text, 0
    out: list[str] = []
    cut = 0
    pos = 0
    for a, b in spans:
        out.extend(lines[pos:a])
        out.append(f"[withheld: {b - a} lines that read like a call transcript]")
        cut += b - a
        pos = b
    out.extend(lines[pos:])
    return "\n".join(out), cut


# ---------------------------------------------------------------- config ---

def _pong_home() -> Path:
    from .paths import state_dir

    return state_dir()


def config() -> dict[str, Any]:
    """``~/.pong/jev.json``; every field optional."""
    p = _pong_home() / "jev.json"
    try:
        d = json.loads(p.read_text(encoding="utf-8"))
        return d if isinstance(d, dict) else {}
    except (OSError, ValueError):
        return {}


def model_id(override: str | None = None) -> str:
    return str(override or config().get("model") or DEFAULT_MODEL)


def _real_home() -> bool:
    try:
        return _pong_home().resolve() == (Path.home() / ".pong").resolve()
    except OSError:
        return False


def _key_file() -> Path | None:
    """The file holding ``TYPESAFE_API_KEY=…`` when no Settings key or exported key is used:
    the ``key_file`` jev.json names, or None. A temporary PONG_HOME (tests, a sandbox) has its
    own jev.json, so it never reaches the owner's key file unless that jev.json names it.
    """
    named = str(config().get("key_file") or "")
    if named:
        return Path(os.path.expanduser(named))
    return None


def settings_key_path() -> Path:
    """The file Settings writes (folder 0700, file 0600): ``<pong home>/secrets/jev.env``."""
    from .settings import key_path

    return key_path("jev")


def _read_key_file(p: Path) -> str:
    from .settings import read_key_line

    return read_key_line(p, "TYPESAFE_API_KEY")


def key_source() -> tuple[str, str, str]:
    """(key, source, where): the key, which of :data:`KEY_SOURCES` gave it, and where that is in words.

    Looked up fresh on every call, in this order: the file Settings writes; ``TYPESAFE_API_KEY`` from the
    environment (only for the real ~/.pong, or when jev.json sets ``allow_env_key``); the ``key_file``
    jev.json names. A temporary PONG_HOME reaches only keys under its own home. ``PONG_JEV_DISABLED``
    hides every key. Never log or return the key outside a request header."""
    if os.environ.get("PONG_JEV_DISABLED"):
        return "", "", "PONG_JEV_DISABLED is set"
    sp = settings_key_path()
    v = _read_key_file(sp)
    if v:
        return v, "settings", str(sp)
    cfg = config()
    v = (os.environ.get("TYPESAFE_API_KEY") or "").strip()
    if v and (_real_home() or cfg.get("allow_env_key")):
        return v, "environment", "TYPESAFE_API_KEY in the environment"
    p = _key_file()
    if p is not None:
        v = _read_key_file(p)
        return (v, "key_file", str(p)) if v else ("", "", str(p))
    # a temporary home (a test, a preview) reaches only its own keys: not "this Mac's"
    return "", "", "no Jev key on this Mac" if _real_home() else "no Jev key in this CyberPong folder"


def _key() -> str:
    """The API key, or ''. Never log or return this outside a request header."""
    return key_source()[0]


def enabled() -> bool:
    """Jev is switched on: Settings › Limits & keys, ``jev.json`` ``enabled`` and ``PONG_JEV_DISABLED`` all agree."""
    if os.environ.get("PONG_JEV_DISABLED") or config().get("enabled") is False:
        return False
    try:
        from .settings import limits

        return bool(limits()["jev"])
    except Exception:
        return True


def _off_reason() -> str:
    if config().get("enabled") is False:
        return "Jev is turned off in ~/.pong/jev.json"
    if os.environ.get("PONG_JEV_DISABLED"):
        return "Jev is turned off (PONG_JEV_DISABLED)"
    return "Jev is turned off in Settings"


def status() -> dict[str, Any]:
    """Whether Jev can be asked, in words, without revealing the key (or any part of it)."""
    cfg = config()
    key, src, where = key_source()
    on = enabled()
    return {
        "available": bool(key) and on,
        "key": ("set" if key else "missing") + f" ({where})",
        "key_note": "" if key else where,
        "source": src,
        "key_shape": _shape(key),
        "enabled": on,
        "model": model_id(),
        "ledger": str(ledger_path()),
        "deny": list(DEFAULT_DENY) + [str(x) for x in cfg.get("deny") or []],
        "retention_settled": bool(cfg.get("retention_settled")),
    }


def _shape(key: str) -> str:
    """The key's length only: never its first letters (a key can sit in a prefix)."""
    if not key:
        return "none"
    return f"{len(key)} chars"


# ----------------------------------------------------------------- guard ---

def denied(path: str, extra: list[str] | None = None) -> str:
    """Why *path* may not be sent to Jev, or ''. Checked on the path as given and
    on its real target, case-blind; data-file rules apply to data files only."""
    given = os.path.abspath(os.path.expanduser(str(path)))
    try:
        real = os.path.realpath(given)
    except OSError:
        real = given
    user = [str(x) for x in (extra or [])] + [str(x) for x in config().get("deny") or []]
    for cand in dict.fromkeys((given, real)):
        low = cand.casefold()
        name = os.path.basename(low)
        data = os.path.splitext(name)[1] in DATA_EXT
        for pat in list(DENY_ANY) + user + (list(DENY_DATA) if data else []):
            pl = pat.casefold()
            if fnmatch.fnmatchcase(low, pl) or fnmatch.fnmatchcase(name, pl):
                return f"on the deny list ({pat})" + ("" if cand == given else " through a link")
    return ""


def guard(state: Any) -> tuple[Any, dict[str, int], str]:
    """(redacted state, redaction counts, refusal reason or '').

    Every string (and key) in the state is checked, whatever path it came by —
    documents, a claim, the goal, a check's output:
    * a secret refuses the call (something upstream is wrong);
    * a stretch that reads like a call transcript is replaced by a note;
    * email addresses, phone numbers and the names under ``redact_words`` in
      ~/.pong/jev.json (client names, say) are replaced, so a document that
      names a person can still be graded without the address leaving the Mac.
    """
    key = _key()
    counts: dict[str, int] = {"email": 0, "phone": 0, "transcript_lines": 0, "name": 0}
    words = sorted({str(w).strip() for w in (config().get("redact_words") or []) if len(str(w).strip()) >= 3},
                   key=len, reverse=True)
    word_re = re.compile(r"\b(" + "|".join(re.escape(w) for w in words) + r")\b", re.I) if words else None
    refused: list[str] = []

    def scrub(v: Any) -> Any:
        if isinstance(v, str):
            if (key and key in v) or has_secret(v):
                refused.append("secret")
                return v
            s2 = v
            if s2.count("\n") >= 2:
                s2, n = redact_transcripts(s2)
                counts["transcript_lines"] += n
            s2, n = _EMAIL.subn("[email]", s2)
            counts["email"] += n
            s2, n = _PHONE.subn("[phone]", s2)
            counts["phone"] += n
            if word_re is not None:
                s2, n = word_re.subn("[name]", s2)
                counts["name"] += n
            return s2
        if isinstance(v, list):
            return [scrub(x) for x in v]
        if isinstance(v, dict):
            return {(scrub(k) if isinstance(k, str) else k): scrub(x) for k, x in v.items()}
        return v

    out = scrub(state)
    if refused:
        return state, {}, "the state contains a key or token"
    return out, {k: n for k, n in counts.items() if n}, ""


def _read_prefix(path: str, limit: int) -> tuple[bytes | None, int, str]:
    """(bytes, full size, why not): at most *limit* bytes of a regular file.
    Opened non-blocking and checked on the open descriptor: a FIFO or a device
    never blocks the tick, and a path swapped after a stat is not followed."""
    import stat as _stat

    try:
        fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
    except OSError as e:
        return None, 0, f"unreadable ({e.__class__.__name__})"
    try:
        st = os.fstat(fd)
        if not _stat.S_ISREG(st.st_mode):
            return None, 0, "not a regular file"
        chunks: list[bytes] = []
        got = 0
        while got < limit:
            b = os.read(fd, min(1 << 16, limit - got))
            if not b:
                break
            chunks.append(b)
            got += len(b)
        return b"".join(chunks), int(st.st_size), ""
    except OSError as e:
        return None, 0, f"unreadable ({e.__class__.__name__})"
    finally:
        os.close(fd)


#: Below this share per file a document is not worth sending; read fewer files instead.
MIN_SHARE = 2000


def read_documents(paths: list[str], *, root: str = "", cap: int = STATE_CAP_CHARS,
                   deny: list[str] | None = None) -> tuple[list[dict[str, Any]], list[dict[str, str]]]:
    """Text of the files Jev may see, within *cap* characters in all; (documents, withheld).

    Each file is checked against the deny list (as given and where it really
    points), read with a bound, and withheld if it reads like a call
    transcript. When there are more files than the budget can hold at
    MIN_SHARE each, the rest are withheld as "over the size budget".
    """
    docs: list[dict[str, Any]] = []
    withheld: list[dict[str, str]] = []
    files: list[str] = []
    for p in paths:
        if not str(p).strip():
            continue
        full = os.path.expanduser(str(p))
        if not os.path.isabs(full) and root:
            full = os.path.join(root, full)
        if os.path.isdir(full):
            why = denied(full, deny)
            if why:
                withheld.append({"file": full, "why": why})
                continue
            seen_dirs = 0
            for dp, dns, fns in os.walk(full, followlinks=False):
                dns[:] = [d for d in dns if not d.startswith(".") and d not in ("node_modules", "__pycache__")]
                for f in sorted(fns):
                    if f.endswith((".md", ".txt", ".json", ".py", ".ts", ".tsx", ".js", ".swift", ".sql", ".yaml", ".yml", ".csv", ".html")):
                        files.append(os.path.join(dp, f))
                seen_dirs += 1
                if len(files) > 40 or seen_dirs >= 400:  # a huge tree with few matches is not walked whole in the tick
                    break
        else:
            files.append(full)
    files = list(dict.fromkeys(files))[:40]
    ok: list[str] = []
    for f in files:
        why = denied(f, deny)
        if why:
            withheld.append({"file": f, "why": why})
        else:
            ok.append(f)
    room = max(1, cap // MIN_SHARE)
    for f in ok[room:]:
        withheld.append({"file": f, "why": "over the size budget"})
    ok = ok[:room]
    if not ok:
        return docs, withheld
    share = max(MIN_SHARE, cap // len(ok))
    for f in ok:
        raw, size, why = _read_prefix(os.path.realpath(f), 4 * share + 4)
        if raw is None:
            withheld.append({"file": f, "why": why})
            continue
        if b"\x00" in raw[:4096]:
            withheld.append({"file": f, "why": "binary"})
            continue
        text = raw.decode("utf-8", errors="replace")
        if looks_like_transcript(text):
            withheld.append({"file": f, "why": "reads like a call transcript"})
            continue
        name = os.path.relpath(f, root) if root and f.startswith(root.rstrip("/") + "/") else f
        docs.append({"file": name, "text": text[:share], "truncated": size > len(raw) or len(text) > share,
                     "chars": max(size, len(text))})
    return docs, withheld


def fit_state(state: dict[str, Any], questions: dict[str, Any]) -> tuple[dict[str, Any], bool]:
    """Shorten the longest document texts until the request fits Jev's state limit.

    The limit is in tokens and the tokenizer is not published, so it is
    measured the way ask() refuses: (serialized state + the longest question)
    / 3.2 characters per token against 28,000 tokens. Each document cut here
    is marked ``truncated``; the caller passes that on, so a grade knows Jev
    may not have seen a section. Returns (state, trimmed).
    """
    import copy

    longest = max((len(json.dumps(q, ensure_ascii=False)) for q in questions.values()), default=0)
    limit = int(TOKEN_LIMIT * CHARS_PER_TOKEN) - longest - 1500
    size = len(json.dumps(state, ensure_ascii=False))
    if size <= limit:
        return state, False
    st = copy.deepcopy(state)
    texts: list[dict[str, Any]] = []
    for d in st.get("documents") or []:
        if isinstance(d, dict) and isinstance(d.get("text"), str):
            texts.append(d)
    for c in (st.get("candidates") or {}).values():
        for d in (c.get("documents") or []) if isinstance(c, dict) else []:
            if isinstance(d, dict) and isinstance(d.get("text"), str):
                texts.append(d)
    for _ in range(6):
        size = len(json.dumps(st, ensure_ascii=False))
        if size <= limit or not texts:
            break
        total = sum(len(json.dumps(d["text"], ensure_ascii=False)) for d in texts) or 1
        keep = max(0.0, 1.0 - (size - limit) / total) * 0.97
        for d in texts:
            n = max(400, int(len(d["text"]) * keep))
            if n < len(d["text"]):
                d["text"] = d["text"][:n]
                d["truncated"] = True
    return st, True


# ------------------------------------------------------------- questions ---

LEVELS_5 = [
    "Absent or wrong",
    "Present but weak: vague, uncited or inconsistent",
    "Adequate: present, cited, one gap",
    "Strong: precise, cited, complete",
    "Exemplary: precise, cited, complete, and anticipates the next question",
]


def _qid(s: str) -> str:
    q = re.sub(r"[^a-z0-9_]+", "_", str(s).strip().lower()).strip("_")
    return q[:60] or "q"


def rubric_questions(rubric: Any) -> tuple[dict[str, dict[str, Any]], dict[str, dict[str, Any]]]:
    """(questions for Jev, per-line meta) from a rubric.

    A rubric is either the jev folder's format (``{"questions": {id: {type,
    instructions, criteria}}}``, with ``<id>_assessable`` nouls beside score
    lines) or a list of lines (``[{"id", "text", "floor"?, "levels"?}]`` or
    plain strings). Every score line gets an "assessable" noul if it has none:
    a judge that must pick a level will pick one confidently when the honest
    answer is "not in the document" (research/jev-case-studies.md).
    """
    qs: dict[str, dict[str, Any]] = {}
    meta: dict[str, dict[str, Any]] = {}
    if isinstance(rubric, dict) and isinstance(rubric.get("questions"), dict):
        for qid, q in rubric["questions"].items():
            if isinstance(q, dict) and q.get("type") in ("noul", "choice", "score"):
                qs[str(qid)] = {k: q[k] for k in ("type", "instructions", "criteria") if k in q}
                meta[str(qid)] = {k: q[k] for k in ("floor", "weight", "must") if k in q}
    elif isinstance(rubric, list):
        for i, line in enumerate(rubric):
            if isinstance(line, str):
                line = {"text": line}
            if not isinstance(line, dict) or not str(line.get("text") or "").strip():
                continue
            qid = _qid(line.get("id") or f"line_{i + 1}")
            if str(line.get("type") or "") == "noul":
                qs[qid] = {"type": "noul", "instructions": str(line["text"]),
                           "criteria": {"true": str(line.get("yes") or "Yes, as stated"),
                                        "false": str(line.get("no") or "No, or the document does not show it")}}
            else:
                qs[qid] = {"type": "score", "instructions": str(line["text"]),
                           "criteria": list(line.get("levels") or LEVELS_5)}
            meta[qid] = {k: line[k] for k in ("floor", "weight", "must") if k in line}
    for qid, q in list(qs.items()):
        if q["type"] == "score" and not qid.endswith("_assessable") and f"{qid}_assessable" not in qs:
            qs[f"{qid}_assessable"] = {
                "type": "noul",
                "instructions": "The document contains enough to judge this: " + str(q.get("instructions") or ""),
                "criteria": {"true": "The relevant section exists and can be judged",
                             "false": "The section is missing, a placeholder, or too thin to judge"}}
    return qs, meta


def choice_question(instructions: str, options: dict[str, str], *, none: str = "") -> dict[str, Any]:
    """A choice over options code already holds, always with an explicit way out."""
    crit = {str(k): str(v) for k, v in options.items()}
    if NONE_OPTION not in crit:
        crit[NONE_OPTION] = none or "None of these fits, or the state does not say enough to choose"
    if len(crit) > MAX_CHOICE_OPTIONS:
        raise ValueError(f"a choice takes at most {MAX_CHOICE_OPTIONS} options")
    return {"type": "choice", "instructions": instructions, "criteria": crit}


def validate_questions(qs: dict[str, Any]) -> list[str]:
    """Problems that would make TypeSafe refuse the request (it answers only 'Invalid request.')."""
    out: list[str] = []
    if not qs:
        out.append("no questions")
    for qid, q in qs.items():
        if not re.match(r"^[A-Za-z0-9_.-]{1,80}$", str(qid)):
            out.append(f"{qid}: ids are letters, digits, _ . -")
        if not isinstance(q, dict):
            out.append(f"{qid}: not an object")
            continue
        t = q.get("type")
        if t not in ("noul", "choice", "score"):
            out.append(f"{qid}: type must be noul, choice or score")
        if not str(q.get("instructions") or "").strip():
            out.append(f"{qid}: no instructions")
        c = q.get("criteria")
        if t == "choice" and (not isinstance(c, dict) or len(c) < 2 or len(c) > MAX_CHOICE_OPTIONS):
            out.append(f"{qid}: a choice needs 2..{MAX_CHOICE_OPTIONS} named options")
        if t == "score" and (not isinstance(c, list) or not 2 <= len(c) <= 10):
            out.append(f"{qid}: a score needs 2..10 levels")
        if t == "noul" and c is not None and not isinstance(c, dict):
            out.append(f"{qid}: noul criteria are {{true, false}}")
    return out


# ------------------------------------------------------------------- ask ---

def _qversion(q: dict[str, Any]) -> str:
    """A question's version: its type, wording and options in order (a change resets calibration).

    A noul's two criteria are hashed true-then-false whatever order the dict
    holds them in: a record saved with sorted keys (jsonutil.write_json) reads
    back ``{false, true}``, and the version must not change on a round trip
    (every noul on disk is written true-first, so recorded statuses keep their
    keys). A choice's option order is part of its wording; the engine records
    versions at send time (``qversions``) so a reload cannot reorder them."""
    crit = q.get("criteria")
    if q.get("type") == "noul" and isinstance(crit, dict):
        crit = {**{k: crit[k] for k in ("true", "false") if k in crit},
                **{k: crit[k] for k in sorted(crit) if k not in ("true", "false")}}
    return hashlib.sha256(json.dumps([q.get("type"), q.get("instructions"), crit],
                                     sort_keys=False, ensure_ascii=False).encode()).hexdigest()[:12]


def _breaker_path() -> Path:
    return _pong_home() / "jev" / "breaker.json"


def _breaker_open() -> float:
    """Seconds left on an open breaker, or 0."""
    try:
        d = json.loads(_breaker_path().read_text(encoding="utf-8"))
        left = float(d.get("open_until") or 0) - time.time()
        return left if left > 0 else 0.0
    except (OSError, ValueError, TypeError):
        return 0.0


def _breaker(ok: bool) -> None:
    p = _breaker_path()
    try:
        d = json.loads(p.read_text(encoding="utf-8")) if p.exists() else {}
    except (OSError, ValueError):
        d = {}
    if ok:
        d = {"fails": 0, "open_until": 0}
    else:
        d["fails"] = int(d.get("fails") or 0) + 1
        if d["fails"] >= BREAKER_FAILS:
            d["open_until"] = time.time() + BREAKER_SEC
    try:
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(json.dumps(d), encoding="utf-8")
    except OSError:
        pass


def _post(body: bytes, key: str, budget: float) -> tuple[int, Any, dict[str, str], int, str]:
    """(status, payload or error detail, headers, attempts, error class). Retries only what can succeed later."""
    t0 = time.time()
    attempts = 0
    last: tuple[int, Any, dict[str, str], str] = (0, None, {}, "")
    delay = 0.5
    while attempts <= MAX_RETRIES:
        attempts += 1
        left = budget - (time.time() - t0)
        if left <= 0.5:
            break
        req = urllib.request.Request(API_URL, data=body, method="POST",
                                     headers={"Authorization": "Bearer " + key, "Content-Type": "application/json"})
        retry_after = 0.0
        try:
            with urllib.request.urlopen(req, timeout=min(ATTEMPT_TIMEOUT_SEC, left)) as r:
                return r.status, json.loads(r.read().decode("utf-8")), dict(r.headers.items()), attempts, ""
        except urllib.error.HTTPError as e:
            detail: Any = ""
            try:
                detail = json.loads(e.read().decode("utf-8")).get("detail")
            except Exception:
                pass
            hdrs = dict(e.headers.items()) if e.headers else {}
            last = (int(e.code), detail, hdrs, "http")
            if not _retryable(int(e.code)):
                break
            try:
                ra = hdrs.get("retry-after-ms") or hdrs.get("Retry-After-Ms")
                retry_after = float(ra) / 1000.0 if ra else float(hdrs.get("retry-after") or hdrs.get("Retry-After") or 0)
            except (TypeError, ValueError):
                retry_after = 0.0
        except (urllib.error.URLError, TimeoutError, OSError) as e:
            last = (0, None, {}, e.__class__.__name__)
        except ValueError:
            last = (0, None, {}, "bad JSON")
            break
        except Exception as e:  # http.client.IncompleteRead, BadStatusLine … : a protocol error, retried
            last = (0, None, {}, e.__class__.__name__)
        if attempts > MAX_RETRIES:
            break  # no sleep after the last attempt
        wait = max(retry_after, delay * (1.0 + 0.25 * ((attempts * 7919) % 100) / 100.0))
        if time.time() - t0 + wait >= budget - 0.5:
            break
        time.sleep(min(wait, 5.0 if not retry_after else 60.0))
        delay = min(delay * 2, 5.0)
    return last[0], last[1], last[2], attempts, last[3]


def ask(state: Any, questions: dict[str, Any], *, model: str | None = None,
        timeout: float | None = None, purpose: str = "", meta: dict[str, Any] | None = None,
        call_id: str | None = None) -> dict[str, Any]:
    """One decision. Never raises. ``ok`` false means "not asked" — route to a person.

    The result carries the guarded state's hash and redaction counts, never
    the state or the key; it is appended to the ledger either way. An answer
    that breaks the contract (an option that was not offered, probabilities
    that do not sum to one, a model other than the pinned one) is refused
    whole: a wrong number is worse than no number.
    """
    # the caller may choose the id (the engine does for gate advice, so a person's answer
    # given before the advice comes back can still be labelled against it)
    call_id = str(call_id) if call_id and re.fullmatch(r"jv_[0-9a-f]{12}", str(call_id)) else "jv_" + uuid.uuid4().hex[:12]
    pinned = model_id(model)
    out: dict[str, Any] = {"id": call_id, "ok": False, "model": pinned, "pinned": pinned, "answers": {}, "usage": None,
                           "ms": 0, "error": "", "redactions": {}, "purpose": purpose, "at": time.time(), "attempts": 0}
    problems = validate_questions(questions)
    if problems:
        out["error"] = "bad questions: " + "; ".join(problems[:4])
        return _log(out, questions, meta)
    fake = (os.environ.get("PONG_JEV_FAKE") or "").strip()
    if fake:  # tests: canned answers, the same guard and checks, no network
        safe, counts, refusal = guard(state)
        out["redactions"] = counts
        out["state_sha"] = hashlib.sha256(json.dumps(safe, sort_keys=True).encode()).hexdigest()[:16]
        if refusal:
            out["error"] = "refused: " + refusal
            return _log(out, questions, meta)
        if _too_big(json.dumps(safe, ensure_ascii=False, sort_keys=True), questions):
            out["error"] = "refused: the state is too large for Jev (cut the documents)"
            return _log(out, questions, meta)
        try:
            canned = json.loads(Path(fake).read_text(encoding="utf-8"))
        except (OSError, ValueError):
            canned = {}
        if canned.get("error"):
            out["error"] = str(canned["error"])
            return _log(out, questions, meta)
        canned.setdefault("_seen_states", []).append(safe)
        try:
            Path(fake).write_text(json.dumps(canned), encoding="utf-8")
        except OSError:
            pass
        raw = {k: v for k, v in (canned.get("answers") or {}).items() if k in questions}
        return _answered(out, questions, raw, str(canned.get("model") or pinned), None, meta, fake=True)
    key = _key()
    if not key or not enabled():
        out["error"] = "no TypeSafe key" if not key else _off_reason()
        return _log(out, questions, meta)
    left = _breaker_open()
    if left:
        out["error"] = f"unavailable: {BREAKER_FAILS} failed calls in a row; not calling for another {left:.0f} s"
        return _log(out, questions, meta)
    safe, counts, refusal = guard(state)
    out["redactions"] = counts
    blob = json.dumps(safe, ensure_ascii=False, sort_keys=True)
    out["state_sha"] = hashlib.sha256(blob.encode()).hexdigest()[:16]
    out["state_chars"] = len(blob)
    if refusal:
        out["error"] = "refused: " + refusal
        return _log(out, questions, meta)
    if _too_big(blob, questions):
        out["error"] = "refused: the state is too large for Jev (cut the documents)"
        return _log(out, questions, meta)
    body = json.dumps({"state": safe, "model": pinned, "questions": questions}).encode()
    t0 = time.time()
    status_code, payload, headers, attempts, err = _post(body, key, float(timeout or config().get("timeout_sec") or DEFAULT_TIMEOUT_SEC))
    out["ms"] = int((time.time() - t0) * 1000)
    out["attempts"] = attempts
    rid = headers.get("x-typesafe-request-id") or headers.get("X-Typesafe-Request-Id")
    if rid:
        out["request_id"] = rid
    if status_code == 200 and isinstance(payload, dict):
        _breaker(True)
        out["usage"] = payload.get("usage")
        return _answered(out, questions, payload.get("answers") or {}, str(payload.get("model") or ""), key, meta)
    _breaker(False)
    if status_code:
        detail = payload
        if isinstance(detail, dict):
            detail = detail.get("message") or detail
        if isinstance(detail, list):  # FastAPI 422: [{loc, msg, type}]
            detail = "; ".join(f"{'.'.join(str(x) for x in (d.get('loc') or []))}: {d.get('msg')}" for d in detail[:3] if isinstance(d, dict))
        out["error"] = f"HTTP {status_code}" + (f": {str(detail)[:200]}" if detail else "")
    else:
        out["error"] = f"unreachable: {err or 'no answer'}"
    out["error"] = out["error"].replace(key, "[key]")
    return _log(out, questions, meta)


def _too_big(blob: str, questions: dict[str, Any]) -> bool:
    longest = max((len(json.dumps(q, ensure_ascii=False)) for q in questions.values()), default=0)
    return (len(blob) + longest) / CHARS_PER_TOKEN > TOKEN_LIMIT


def _answered(out: dict[str, Any], questions: dict[str, Any], raw: dict[str, Any], model: str,
              key: str | None, meta: dict[str, Any] | None, *, fake: bool = False) -> dict[str, Any]:
    bad = validate_answers(raw, questions)
    if not model:
        bad.append("the answer does not say which model gave it")
    elif out.get("pinned") and model != out["pinned"] and not (fake and model.startswith("jev-fake")):
        bad.append(f"answered by {model}, not the pinned {out['pinned']}")
    out["model"] = model or "unknown"
    if bad:
        out["error"] = "invalid answer: " + "; ".join(bad[:3])
        out["raw_rejected"] = True
        return _log(out, questions, meta)
    out["answers"] = normalise(raw, questions)
    out["ok"] = True
    return _log(out, questions, meta)


def validate_answers(raw: dict[str, Any], questions: dict[str, Any]) -> list[str]:
    """The response contract, checked the way jev-voice checks it: every question
    answered with its own type, choices only over the offered options, finite
    probabilities that sum to one, scores over exactly the offered levels."""
    out: list[str] = []
    for qid, q in questions.items():
        a = raw.get(qid)
        if not isinstance(a, dict):
            out.append(f"{qid}: no answer")
            continue
        t = q.get("type")
        if a.get("type") and a.get("type") != t:
            out.append(f"{qid}: answered as {a.get('type')}, asked as {t}")
            continue
        if t == "noul":
            v = _num(a.get("noul"))
            if v is None or not 0.0 <= v <= 1.0:
                out.append(f"{qid}: P(yes) is not a probability")
            continue
        probs = a.get("probabilities")
        if not isinstance(probs, dict) or not probs:
            out.append(f"{qid}: no probabilities")
            continue
        vals = [_num(v) for v in probs.values()]
        if any(v is None or not 0.0 <= v <= 1.0 for v in vals):
            out.append(f"{qid}: a probability outside [0, 1]")
            continue
        if abs(sum(v for v in vals if v is not None) - 1.0) > 0.02:
            out.append(f"{qid}: probabilities sum to {sum(v for v in vals if v is not None):.3f}")
        if t == "choice":
            offered = set((q.get("criteria") or {}).keys())
            if set(str(k) for k in probs) != offered:
                extra = sorted(set(str(k) for k in probs) - offered)
                out.append(f"{qid}: options differ from those offered" + (f" (not offered: {', '.join(extra[:3])})" if extra else ""))
        elif t == "score":
            n = len(q.get("criteria") or [])
            if set(str(k) for k in probs) != {str(i) for i in range(n)}:
                out.append(f"{qid}: levels differ from the {n} offered")
    return out


def normalise(answers: dict[str, Any], questions: dict[str, Any]) -> dict[str, dict[str, Any]]:
    """One shape per answer: type, probabilities over the offered options, pick, confidence.

    Options Jev returns that were not offered are dropped (it may only pick
    among what code offered); probabilities are renormalised over the rest.
    Choice confidence is recomputed as TypeSafe defines it, (n·p_max − 1)/(n − 1).
    """
    out: dict[str, dict[str, Any]] = {}
    for qid, q in questions.items():
        a = answers.get(qid)
        if not isinstance(a, dict):
            continue
        t = q.get("type")
        if t == "noul":
            try:
                p = float(a.get("noul"))
            except (TypeError, ValueError):
                continue
            out[qid] = {"type": "noul", "p": max(0.0, min(1.0, p))}
        elif t == "choice":
            offered = list((q.get("criteria") or {}).keys())
            probs = {str(k): float(v) for k, v in (a.get("probabilities") or {}).items()
                     if str(k) in offered and isinstance(v, (int, float))}
            tot = sum(probs.values())
            if tot <= 0:
                continue
            probs = {k: v / tot for k, v in probs.items()}
            pick = max(probs, key=lambda k: probs[k])
            n = len(offered)
            conf = max(0.0, (n * probs[pick] - 1) / (n - 1)) if n > 1 else 1.0
            out[qid] = {"type": "choice", "probabilities": probs, "pick": pick, "p": probs[pick],
                        "confidence": round(conf, 4), "said_confidence": _num(a.get("confidence")), "said": a.get("choice")}
        elif t == "score":
            levels = list(q.get("criteria") or [])
            probs: dict[int, float] = {}
            for k, v in (a.get("probabilities") or {}).items():
                try:
                    i = int(k)
                except (TypeError, ValueError):
                    continue
                if 0 <= i < len(levels) and isinstance(v, (int, float)):
                    probs[i] = float(v)
            tot = sum(probs.values())
            if tot <= 0:
                continue
            probs = {i: v / tot for i, v in probs.items()}
            exp = sum(i * v for i, v in probs.items())
            out[qid] = {"type": "score", "probabilities": {str(i): round(v, 4) for i, v in sorted(probs.items())},
                        "expected": round(exp, 3), "score": _num(a.get("score")), "confidence": _num(a.get("confidence")),
                        "levels": len(levels), "mode": max(probs, key=lambda i: probs[i])}
    return out


def _num(v: Any) -> float | None:
    try:
        return float(v)
    except (TypeError, ValueError):
        return None


def p_at_least(answer: dict[str, Any], floor: int) -> float:
    """P(level >= floor) for a score answer: the chance the line meets its bar."""
    probs = answer.get("probabilities") or {}
    return round(sum(float(v) for k, v in probs.items() if int(k) >= int(floor)), 4)


def can_ask() -> bool:
    """A key is set and Jev is on (or tests supplied canned answers). No network."""
    if (os.environ.get("PONG_JEV_FAKE") or "").strip():
        return True
    return bool(_key()) and enabled()


# -------------------------------------------------------------- key test ---

#: One trivial question with no documents: enough for TypeSafe to check the key and answer.
_KEY_TEST_Q = {"key_test": {"type": "noul", "instructions": "Is the number two greater than the number one?",
                            "criteria": {"true": "Two is greater than one", "false": "Two is not greater than one"}}}
KEY_TEST_TIMEOUT_SEC = 15.0


def key_test(*, post: Any = None) -> dict[str, Any]:
    """``pong jev key test``: one trivial call, no documents, so Settings can say whether the key works.

    Returns ``{"ok", "result", "ms"}`` with result "works", "key refused", "unreachable" or "no key".
    It never touches the breaker (a wrong key typed into Settings must not hold back a running graph's
    calls for a minute), is logged to the ledger with purpose ``key_test``, and never shows the key,
    even inside an error. *post* replaces the HTTP layer (tests)."""
    key = _key()
    call_id = "jv_" + uuid.uuid4().hex[:12]
    pinned = model_id()
    out: dict[str, Any] = {"id": call_id, "ok": False, "model": pinned, "pinned": pinned, "answers": {}, "usage": None,
                           "ms": 0, "error": "", "redactions": {}, "purpose": "key_test", "at": time.time(), "attempts": 0}
    if not key:
        out["error"] = "no TypeSafe key"
        _log(out, _KEY_TEST_Q, {"key_test": True})
        return {"ok": False, "result": "no key", "ms": 0}
    body = json.dumps({"state": {"note": "a connection test from CyberPong's Settings"}, "model": pinned,
                       "questions": _KEY_TEST_Q}).encode()
    t0 = time.time()
    try:
        status_code, payload, _headers, attempts, err = (post or _post)(body, key, KEY_TEST_TIMEOUT_SEC)
    except Exception as e:  # a test must answer, whatever the network does
        status_code, payload, attempts, err = 0, None, 1, e.__class__.__name__
    out["ms"] = int((time.time() - t0) * 1000)
    out["attempts"] = attempts
    if status_code == 200 and isinstance(payload, dict):
        result = "works"
        out["ok"] = True
        out["usage"] = payload.get("usage")
    elif status_code in (401, 403):
        result = "key refused"
        out["error"] = f"HTTP {status_code}"
    else:
        result = "unreachable"
        out["error"] = f"HTTP {status_code}" if status_code else f"unreachable: {err or 'no answer'}"
    out["error"] = str(out["error"]).replace(key, "[key]")
    _log(out, _KEY_TEST_Q, {"key_test": True})
    res: dict[str, Any] = {"ok": result == "works", "result": result, "ms": out["ms"]}
    if status_code and result != "works":
        res["http"] = int(status_code)
    return res


# ------------------------------------------------------- interpretation ---
#
# Probabilities become outcomes here, in code a person can read. The rules and
# numbers come from docs/research/judges-in-graph-loops-2026-09.md §8; a
# topology can move any of them per node.
#
# A rubric line is a probability p that it meets its bar: P(level >= floor)
# for a score line, P(yes) for a noul line. Three bands, not one cut:
#   p >= PASS_P   the line passes
#   p <= FAIL_P   the line clearly fails
#   otherwise     uncertain
# The work wins only when every line passes AND the lines' shortfalls add up
# to at most UNION (Σ(1 − p) <= 0.25 keeps P(all pass) >= 0.75 whatever the
# lines' correlation — eight lines at 0.55 each are not a pass). It fails when
# any line clearly fails. Anything else is uncertain: a critic breaks the tie,
# or a person decides.

PASS_P = 0.8
FAIL_P = 0.3
UNION = 0.25
#: "Assessable" below this: the document does not hold what the line grades.
NOT_ASSESSABLE_P = 0.3
#: "Assessable" below this (and above the last): not sure the line could be judged.
ASSESSABLE_P = 0.6
#: A score answer this spread out cannot pass or fail a line on its own.
SCORE_CONFIDENCE_FLOOR = 0.2
#: Take a route without a person at or above this (0.7 is enough to send work back a round).
DEFAULT_TAKE = 0.9
#: A choice acted on without a person needs at least this peakedness, (n·p_max − 1)/(n − 1).
CHOICE_CONFIDENCE_FLOOR = 0.5
#: A ranking needs the winner this far ahead of the runner-up, and "none" under NONE_P.
RANK_MARGIN = 0.2
NONE_P = 0.2


_EPS = 5e-4
_VERDICT_RANK = {"not_assessable": 0, "under": 1, "uncertain": 2, "pass": 3, "info": 4, "unanswered": 5}


def line_order(r: dict[str, Any]) -> tuple[int, float]:
    """Weakest first: not in the document, below the bar, unsure, passing; then the rest."""
    p = r.get("p_meets")
    return (_VERDICT_RANK.get(str(r.get("verdict")), 6), float(p) if p is not None else 2.0)


def default_floor(levels: int) -> int:
    """The level a line must reach: "Adequate" on the five-level scale (index 2 of 0..4)."""
    return max(1, (int(levels) - 1) // 2)


def grade(answers: dict[str, Any], questions: dict[str, Any], meta: dict[str, Any] | None = None, *,
          floor: int | None = None, pass_p: float | None = None, fail_p: float | None = None,
          union: float | None = None, truncated: bool = False,
          trusted: dict[str, str] | None = None, withheld: bool = False) -> dict[str, Any]:
    """A rubric's answers → per-line verdicts and one outcome: win, fail or uncertain.

    Line verdicts: ``pass``, ``under`` (clearly fails), ``uncertain``,
    ``not_assessable`` (the document does not hold it: the builder's to fill,
    so it fails — unless the document was cut to fit, when Jev may simply not
    have seen it), ``info`` (a choice line that does not gate), ``unanswered``.
    """
    meta = meta or {}
    hi = float(pass_p if pass_p is not None else PASS_P)
    lo = float(fail_p if fail_p is not None else FAIL_P)
    lo = min(lo, hi)
    budget = float(union if union is not None else UNION)
    lines: list[dict[str, Any]] = []
    for qid, q in questions.items():
        if qid.endswith("_assessable") and qid[: -len("_assessable")] in questions:
            continue
        a = answers.get(qid)
        m = meta.get(qid) or {}
        row: dict[str, Any] = {"id": qid, "text": str(q.get("instructions") or "")[:400], "type": q.get("type")}
        if not a:
            row.update(verdict="unanswered", p_meets=None)
            lines.append(row)
            continue
        ass = (answers.get(f"{qid}_assessable") or {}).get("p")
        if q.get("type") == "score":
            levels = list(q.get("criteria") or [])
            fl = m.get("floor", floor)
            fl = default_floor(len(levels)) if fl is None else int(fl)
            fl = max(0, min(len(levels) - 1, fl))
            pm = p_at_least(a, fl)
            conf = a.get("confidence")
            row.update(expected=a.get("expected"), levels=len(levels), floor=fl, floor_name=str(levels[fl])[:60],
                       p_meets=pm, assessable=ass, confidence=conf, probabilities=a.get("probabilities"),
                       level_names=[str(x)[:60] for x in levels])
            spread = conf is not None and float(conf) <= SCORE_CONFIDENCE_FLOOR
        elif q.get("type") == "noul":
            pm = round(float(a.get("p") or 0.0), 4)
            row.update(p_meets=pm, assessable=ass)
            spread = False
        else:  # a choice line gates only when the rubric names the option it must be
            row.update(pick=a.get("pick"), p=a.get("p"), probabilities=a.get("probabilities"))
            must = m.get("must")
            if not must:
                row["verdict"] = "info"
                lines.append(row)
                continue
            pm = round(float((a.get("probabilities") or {}).get(must, 0.0)), 4)
            row["p_meets"] = pm
            spread = False
        if ass is not None and ass < NOT_ASSESSABLE_P:
            row["verdict"] = "not_assessable"
        elif (ass is not None and ass < ASSESSABLE_P) or (spread and _EPS < pm < 1.0 - _EPS):
            # an answer this spread out straddles the bar: it can neither pass nor fail the line
            row["verdict"] = "uncertain"
        elif pm >= hi:
            row["verdict"] = "pass"
        elif pm <= lo:
            row["verdict"] = "under"
        else:
            row["verdict"] = "uncertain"
        lines.append(row)
    gating = [r for r in lines if r["verdict"] not in ("info", "unanswered")]
    # A question earns the right to decide (pong.jev_quality): a line whose question has not been
    # probed to "gate" is shown and logged, but can neither fail nor pass the work on its own.
    if trusted is not None:
        for r in lines:
            r["status"] = trusted.get(r["id"], "unproven")
            r["advisory"] = r["status"] != "gate" and r["verdict"] not in ("info", "unanswered")
    decisive = [r for r in gating if not r.get("advisory")]
    under = [r for r in decisive if r["verdict"] == "under"]
    missing = [r for r in decisive if r["verdict"] == "not_assessable"]
    shortfall = round(sum(1.0 - float(r["p_meets"]) for r in gating if r.get("p_meets") is not None
                          and r["verdict"] in ("pass", "uncertain", "under")), 4)
    if any(r["verdict"] == "unanswered" for r in lines) or not gating:
        outcome = "uncertain"
    elif (under or (missing and not truncated)) and withheld:
        # part of the work was withheld from Jev: a line it found wanting may be met in
        # what it could not see, so this is not a fail it can send back on its own
        outcome = "uncertain"
    elif under or (missing and not truncated):
        outcome = "fail"
    elif missing:
        outcome = "uncertain"  # the document was cut: Jev may not have seen the section
    elif all(r["verdict"] == "pass" and not r.get("advisory") for r in gating) and shortfall <= budget:
        outcome = "win"
    else:
        outcome = "uncertain"

    lines.sort(key=line_order)
    ordered = [r for r in lines if r["verdict"] not in ("info", "unanswered")]
    return {"outcome": outcome, "lines": lines, "lowest": ordered[0]["id"] if ordered else None,
            "failing": [r["id"] for r in ordered if r["verdict"] in ("under", "not_assessable") and not r.get("advisory")],
            "advisory": sum(1 for r in gating if r.get("advisory")),
            "pass_p": hi, "fail_p": lo, "union": budget, "shortfall": shortfall, "truncated": truncated,
            "summary": grade_summary(outcome, ordered, len(gating), truncated, shortfall, budget)}


def grade_summary(outcome: str, ordered: list[dict[str, Any]], n: int, truncated: bool,
                  shortfall: float = 0.0, budget: float = UNION) -> str:
    """What the next step reads. Code writes it, and it names lines, not numbers:
    a builder is shown the bar it missed, never the grader's probabilities
    (so the work improves rather than the score)."""
    bad = [r for r in ordered if r["verdict"] in ("under", "not_assessable")]
    unsure = [r for r in ordered if r["verdict"] == "uncertain"]

    def line(r: dict[str, Any]) -> str:
        why = " (not found in the document)" if r["verdict"] == "not_assessable" else ""
        return f"{r['id']}{why}: {r['text']}"

    if outcome == "win":
        return f"win — Jev: all {n} rubric line(s) meet the bar"
    if outcome == "fail":
        return f"fail — Jev: {len(bad)} of {n} rubric line(s) below the bar —\n" + "\n".join("- " + line(r) for r in bad[:8])
    if truncated and any(r["verdict"] == "not_assessable" for r in ordered):
        return "uncertain — the document was cut to fit Jev's limit and a line could not be found; a person or critic decides"
    if unsure:
        return (f"uncertain — Jev could not settle {len(unsure)} of {n} line(s): "
                + "; ".join(r["id"] for r in unsure[:8]) + " — a person or critic decides")
    if any(r.get("advisory") for r in ordered):
        return ("uncertain — Jev graded with questions that have not yet earned the right to decide on their own "
                "(pong jev probe); a person or critic decides")
    if n and shortfall > budget:
        return f"uncertain — every line passes on its own, but together they leave too much doubt; a person or critic decides"
    return "uncertain — Jev did not answer every line; a person or critic decides"


def _merge_orders(answers: list[dict[str, Any] | None]) -> dict[str, Any]:
    """Average a choice asked in several option orders; say whether the picks agreed,
    and keep each order's own probabilities so rules can be applied order by order."""
    got = [a for a in answers if a and a.get("probabilities")]
    if not got:
        return {}
    keys: list[str] = []
    for a in got:
        for k in a["probabilities"]:
            if k not in keys:
                keys.append(k)
    avg = {k: round(sum(float(a["probabilities"].get(k, 0.0)) for a in got) / len(got), 4) for k in keys}
    pick = max(avg, key=lambda k: avg[k])
    n = len(keys)
    conf = max(0.0, (n * avg[pick] - 1) / (n - 1)) if n > 1 else 1.0
    return {"probabilities": avg, "pick": pick, "p": avg[pick], "confidence": round(conf, 4),
            "orders": len(got), "orders_agree": len({a.get("pick") for a in got}) == 1,
            "per_order": [{str(k): float(v) for k, v in a["probabilities"].items()} for a in got]}


def decide(answers: Any, *, take: float | None = None, takes: dict[str, float] | None = None) -> tuple[str, str | None, float]:
    """Route choice(s) → ``route:<label>`` when Jev is sure enough, else ``abstain``.

    Sure enough: the pick is not ``none``, every option order asked picked it,
    its probability reaches its route's bar (``takes[label]``, else ``take``)
    in every order — not only on average — and the averaged choice is peaked.
    """
    merged = _merge_orders(answers if isinstance(answers, list) else [answers])
    if not merged:
        return "abstain", None, 0.0
    pick, p = str(merged["pick"]), float(merged["p"])
    bar = float((takes or {}).get(pick) or (take if take is not None else DEFAULT_TAKE))
    worst = min(o.get(pick, 0.0) for o in merged["per_order"])
    if (pick == NONE_OPTION or worst + _EPS < bar or merged["confidence"] < CHOICE_CONFIDENCE_FLOOR
            or not merged["orders_agree"]):
        return "abstain", pick, p
    return f"route:{pick}", pick, p


def rank(answers: list[dict[str, Any] | None], *, take: float | None = None) -> dict[str, Any]:
    """Candidates → one winner, or the top two go to a person.

    Asked in two option orders (most position bias cancels). A winner needs:
    both orders to pick it, a lead of RANK_MARGIN over the runner-up in each
    order, P(none) under NONE_P in each order, and a peaked averaged choice
    (confidence ≥ CHOICE_CONFIDENCE_FLOOR). Anything less — including a high
    P(none) — is a person's call between the two best.
    """
    merged = _merge_orders(answers)
    if not merged:
        return {"outcome": "abstain", "winner": None, "p": 0.0, "probabilities": {}, "orders": 0}
    avg = merged["probabilities"]
    cands = {k: v for k, v in avg.items() if k != NONE_OPTION}
    ordered = sorted(cands.items(), key=lambda kv: -kv[1])
    winner = ordered[0][0] if ordered else None
    runner = ordered[1][0] if len(ordered) > 1 else None
    leads, nones = [], []
    for o in merged["per_order"]:
        others = [v for k, v in o.items() if k not in (winner, NONE_OPTION)]
        leads.append(round(o.get(winner or "", 0.0) - (max(others) if others else 0.0), 4))
        nones.append(float(o.get(NONE_OPTION, 0.0)))
    margin = min(leads) if leads else 0.0
    none_p = max(nones) if nones else 0.0
    t = float(take if take is not None else 0.0)
    ok = (winner is not None and merged["orders_agree"] and merged["pick"] == winner and margin + _EPS >= RANK_MARGIN
          and none_p < NONE_P and merged["confidence"] >= CHOICE_CONFIDENCE_FLOOR and cands[winner] >= t)
    return {"outcome": "win" if ok else "abstain", "winner": winner, "p": cands.get(winner or "", 0.0),
            "none": round(none_p, 4), "probabilities": avg, "orders": merged["orders"],
            "orders_agree": merged["orders_agree"], "runner_up": runner, "margin": margin,
            "confidence": merged["confidence"]}


def reorder_choice(q: dict[str, Any], order: list[str]) -> dict[str, Any]:
    """The same choice with its options (``none`` included) in *order*."""
    crit = q.get("criteria") or {}
    return {**q, "criteria": {k: crit[k] for k in order if k in crit}}


def gate_advice_probs(answers: dict[str, Any]) -> dict[str, float]:
    """Jev's distribution over a gate's answers, whichever way it was asked (a
    yes/no gate is asked as a Noul, 'approve'; any other as a Choice, 'answer')."""
    a = answers.get("approve") if isinstance(answers, dict) else None
    if isinstance(a, dict) and a.get("p") is not None:
        p = float(a["p"])
        return {"approved": round(p, 4), "rejected": round(1.0 - p, 4)}
    if isinstance(a, dict) and a.get("noul") is not None:
        p = float(a["noul"])
        return {"approved": round(p, 4), "rejected": round(1.0 - p, 4)}
    c = answers.get("answer") if isinstance(answers, dict) else None
    return {str(k): float(v) for k, v in ((c or {}).get("probabilities") or {}).items()}


# ---------------------------------------------------------------- ledger ---

def ledger_path() -> Path:
    return _pong_home() / "jev" / "ledger.jsonl"


def _log(out: dict[str, Any], questions: dict[str, Any], meta: dict[str, Any] | None) -> dict[str, Any]:
    """Append the call (never the state text, never the key)."""
    rec = {
        "kind": "call", "id": out["id"], "at": out["at"], "ok": out["ok"], "model": out["model"], "ms": out["ms"],
        "error": out["error"], "purpose": out.get("purpose") or "", "state_sha": out.get("state_sha"),
        "state_chars": out.get("state_chars"), "redactions": out.get("redactions") or {}, "usage": out.get("usage"),
        "qset": hashlib.sha256(json.dumps(sorted((qid, _qversion(q)) for qid, q in questions.items() if isinstance(q, dict))).encode()).hexdigest()[:12],
        "questions": {qid: {"type": q.get("type"), "version": _qversion(q),
                            "options": list(q["criteria"].keys()) if isinstance(q.get("criteria"), dict) and q.get("type") == "choice"
                            else (len(q["criteria"]) if isinstance(q.get("criteria"), list) else None),
                            "instructions_sha": hashlib.sha256(str(q.get("instructions") or "").encode()).hexdigest()[:12]}
                      for qid, q in questions.items() if isinstance(q, dict)},
        "answers": out.get("answers") or {},
        **({"meta": meta} if meta else {}),
    }
    try:
        p = ledger_path()
        p.parent.mkdir(parents=True, exist_ok=True)
        with p.open("a", encoding="utf-8") as fh:
            fh.write(json.dumps(rec, ensure_ascii=False) + "\n")
    except OSError:
        pass
    return out


def label(call_id: str, question: str, actual: str, *, source: str, meta: dict[str, Any] | None = None) -> None:
    """What actually happened for a question Jev answered (a person's gate answer, say)."""
    rec = {"kind": "label", "at": time.time(), "call": call_id, "question": question, "actual": str(actual),
           "source": source, **({"meta": meta} if meta else {})}
    try:
        p = ledger_path()
        p.parent.mkdir(parents=True, exist_ok=True)
        with p.open("a", encoding="utf-8") as fh:
            fh.write(json.dumps(rec, ensure_ascii=False) + "\n")
    except OSError:
        pass


def read_ledger(limit: int = 5000) -> list[dict[str, Any]]:
    try:
        lines = ledger_path().read_text(encoding="utf-8").splitlines()[-limit:]
    except OSError:
        return []
    out = []
    for ln in lines:
        try:
            d = json.loads(ln)
        except ValueError:
            continue
        if isinstance(d, dict):
            out.append(d)
    return out


def _ece_bins(pairs: list[tuple[float, int]], bins: int = 5) -> list[dict[str, float]]:
    """Equal-mass bins by forecast, a tie never split across two bins (sorting on the
    outcome too would group a tie's hits and misses apart and inflate the error)."""
    rows = sorted(pairs, key=lambda t: t[0])
    size = max(1, len(rows) // bins)
    out: list[dict[str, float]] = []
    i = 0
    while i < len(rows):
        end = min(len(rows), i + size)
        while end < len(rows) and rows[end][0] == rows[end - 1][0]:
            end += 1
        b = rows[i:end]
        out.append({"n": len(b), "p_mean": round(sum(p for p, _ in b) / len(b), 4),
                    "y_mean": round(sum(y for _, y in b) / len(b), 4)})
        i = end
    return out


def _ece(pairs: list[tuple[float, int]], bins: int = 5) -> float | None:
    """Expected calibration error over equal-mass bins (each bin about the same number of rows)."""
    if len(pairs) < 20:
        return None
    total = len(pairs)
    return round(sum(b["n"] / total * abs(b["p_mean"] - b["y_mean"]) for b in _ece_bins(pairs, bins)), 4)


def question_record(calls: dict[str, Any], labels: dict[str, dict[str, Any]]) -> list[dict[str, Any]]:
    """Each rubric question version's record in real use: how often it decided (pass or
    clear fail, not unsure), and how often its fail met a critic's win or a person's
    approval — the disagreements a question owner reviews (suite-question-governance §3)."""
    rows: dict[tuple[str, str], dict[str, Any]] = {}
    for cid, lab in labels.items():
        v = lab.get("__verdict__")
        c = calls.get(cid) or {}
        if not v or c.get("purpose") != "grade":
            continue
        lines = (v.get("meta") or {}).get("lines") or {}
        critic = str((lab.get("__critic__") or {}).get("actual") or "")
        person = str((lab.get("__outcome__") or {}).get("actual") or "")
        for qid, lv in lines.items():
            verdict, advisory = (lv.get("v"), bool(lv.get("a"))) if isinstance(lv, dict) else (lv, False)
            ver = str(((c.get("questions") or {}).get(qid) or {}).get("version") or "?")
            r = rows.setdefault((qid, ver), {"id": qid, "version": ver, "model": c.get("model"), "graded": 0, "decisive": 0,
                                             "advisory": 0, "failed": 0, "failed_seen": 0, "failed_critic_won": 0,
                                             "failed_person_approved": 0, "unsure": 0})
            r["graded"] += 1
            if advisory:
                r["advisory"] += 1
            elif verdict in ("pass", "under", "not_assessable"):
                r["decisive"] += 1
            if verdict == "uncertain":
                r["unsure"] += 1
            if verdict in ("under", "not_assessable"):
                r["failed"] += 1
                r["failed_critic_won"] += int(critic == "win")
                if person:
                    r["failed_seen"] += 1
                    r["failed_person_approved"] += int(person in ("approved", "done"))
    out = []
    for r in rows.values():
        r["coverage"] = round(r["decisive"] / r["graded"], 3) if r["graded"] else None
        r["overruled"] = round(r["failed_person_approved"] / r["failed_seen"], 3) if r["failed_seen"] else None
        out.append(r)
    return sorted(out, key=lambda r: (-(r["overruled"] or 0), -r["graded"]))


def calibration(records: list[dict[str, Any]] | None = None) -> dict[str, Any]:
    """How well Jev's probabilities matched what people then decided.

    Rows are grouped by (purpose, question-set version, model): numbers from
    different rubrics or model versions are never mixed.
    * gate advice: Jev's distribution over a gate's answers vs the answer a
      person gave (multi-class Brier; how often the pick matched);
    * grades: P(every line meets its bar) vs whether the person approved at
      the next gate, scored twice — with the union-bound lower bound
      max(0, 1 − Σ(1 − p)) the engine acts on, and with the weakest line (the
      optimistic bound); binary Brier, and the calibration error over five
      equal-mass bins once there are 20 or more.
    Lower Brier is better; 0.25 is what always saying 0.5 scores on a yes/no.
    """
    recs = records if records is not None else read_ledger()
    calls = {r.get("id"): r for r in recs if r.get("kind") == "call" and r.get("id")}
    labels: dict[str, dict[str, dict[str, Any]]] = {}
    for r in recs:
        if r.get("kind") == "label" and r.get("call"):
            labels.setdefault(str(r["call"]), {})[str(r.get("question"))] = r
    advice: dict[tuple[str, str], list[tuple[dict[str, float], str]]] = {}
    decides: dict[tuple[str, str], list[tuple[dict[str, float], str]]] = {}
    grades: dict[tuple[str, str], list[tuple[float, float, int]]] = {}
    for cid, lab in labels.items():
        c = calls.get(cid) or {}
        group = (str(c.get("qset") or "?"), str(c.get("model") or "?"))
        if c.get("purpose") == "gate_advice" and "answer" in lab:
            probs = gate_advice_probs(c.get("answers") or {})
            if probs:
                advice.setdefault(group, []).append((probs, str(lab["answer"].get("actual"))))
        if c.get("purpose") == "decide" and "__outcome__" in lab:
            # a decide that came to a person: its route odds against the route the person took
            actual = str(lab["__outcome__"].get("actual") or "")
            route = ((c.get("answers") or {}).get("route") or {}) if isinstance(c.get("answers"), dict) else {}
            probs = route.get("probabilities") if isinstance(route, dict) else None
            if actual.startswith("route:") and isinstance(probs, dict) and probs:
                decides.setdefault(group, []).append(({str(k): float(v) for k, v in probs.items()}, actual[6:]))
        if "__verdict__" in lab and "__outcome__" in lab:
            m = lab["__verdict__"].get("meta") or {}
            if isinstance(m.get("p_pass"), (int, float)):
                pu = m.get("p_union")
                y = 1 if str(lab["__outcome__"].get("actual")) in ("approved", "done") else 0
                grades.setdefault(group, []).append((float(pu) if isinstance(pu, (int, float)) else float(m["p_pass"]),
                                                     float(m["p_pass"]), y))
    out: dict[str, Any] = {"calls": len(calls), "labels": sum(len(v) for v in labels.values()),
                           "questions": question_record(calls, labels)}
    rows = []
    for (qset, model), items in advice.items():
        brier = sum(sum((probs.get(k, 0.0) - (1.0 if k == actual else 0.0)) ** 2 for k in set(probs) | {actual})
                    for probs, actual in items) / len(items)
        hits = sum(1 for probs, actual in items if max(probs, key=lambda k: probs[k]) == actual)
        rows.append({"qset": qset, "model": model, "n": len(items), "brier": round(brier, 4),
                     "pick_matched": round(hits / len(items), 3)})
    if rows:
        n = sum(r["n"] for r in rows)
        out["gate_advice"] = {"n": n, "brier": round(sum(r["brier"] * r["n"] for r in rows) / n, 4),
                              "pick_matched": round(sum(r["pick_matched"] * r["n"] for r in rows) / n, 3), "groups": rows}
    rows = []
    for (qset, model), items in decides.items():
        brier = sum(sum((probs.get(k, 0.0) - (1.0 if k == actual else 0.0)) ** 2 for k in set(probs) | {actual})
                    for probs, actual in items) / len(items)
        hits = sum(1 for probs, actual in items if max(probs, key=lambda k: probs[k]) == actual)
        rows.append({"qset": qset, "model": model, "n": len(items), "brier": round(brier, 4),
                     "pick_matched": round(hits / len(items), 3)})
    if rows:
        n = sum(r["n"] for r in rows)
        out["decide"] = {"n": n, "brier": round(sum(r["brier"] * r["n"] for r in rows) / n, 4),
                         "pick_matched": round(sum(r["pick_matched"] * r["n"] for r in rows) / n, 3), "groups": rows}
    rows = []
    for (qset, model), items in grades.items():
        rows.append({"qset": qset, "model": model, "n": len(items),
                     "brier": round(sum((pu - y) ** 2 for pu, _pm, y in items) / len(items), 4),
                     "brier_weakest_line": round(sum((pm - y) ** 2 for _pu, pm, y in items) / len(items), 4),
                     "approved_rate": round(sum(y for *_x, y in items) / len(items), 3),
                     "ece": _ece([(pu, y) for pu, _pm, y in items]),
                     "bins": _ece_bins([(pu, y) for pu, _pm, y in items]) if len(items) >= 20 else []})
    if rows:
        n = sum(r["n"] for r in rows)
        out["grades"] = {"n": n, "brier": round(sum(r["brier"] * r["n"] for r in rows) / n, 4),
                         "ece": rows[0]["ece"] if len(rows) == 1 else None, "groups": rows}
    return out


# ---------------------------------------------------------------- worker ---

def run_request(req_path: str, out_path: str) -> int:
    """The engine's subprocess: read a request file, ask, write the result atomically.

    A request is ``{"state", "questions", "model"?, "purpose"?, "meta"?, "timeout"?}``.
    Running outside the tick keeps a slow network from holding every team's lock.
    """
    def one(req: dict[str, Any]) -> dict[str, Any]:
        try:
            return ask(req.get("state"), req.get("questions") or {}, model=req.get("model"),
                       timeout=req.get("timeout"), purpose=str(req.get("purpose") or ""), meta=req.get("meta"),
                       call_id=req.get("id"))
        except Exception as e:  # a result file is always written: the engine must never wait on a crash
            return {"ok": False, "error": f"the Jev client failed ({e.__class__.__name__})", "answers": {}}

    try:
        req = json.loads(Path(req_path).read_text(encoding="utf-8"))
    except (OSError, ValueError) as e:
        res: dict[str, Any] = {"ok": False, "error": f"bad request file: {e.__class__.__name__}", "answers": {}}
    else:
        if isinstance(req.get("requests"), list):  # several asks (a ranking in two option orders)
            results = [one(r) for r in req["requests"] if isinstance(r, dict)]
            res = {"ok": all(r.get("ok") for r in results) and bool(results), "results": results,
                   "error": "; ".join(sorted({str(r.get("error")) for r in results if r.get("error")}))}
        else:
            res = one(req)
    tmp = out_path + ".tmp"
    Path(tmp).write_text(json.dumps(res, ensure_ascii=False), encoding="utf-8")
    os.replace(tmp, out_path)
    return 0


if __name__ == "__main__":  # python -m pong.jev run REQ OUT
    if len(sys.argv) == 4 and sys.argv[1] == "run":
        sys.exit(run_request(sys.argv[2], sys.argv[3]))
    print("usage: python -m pong.jev run REQUEST.json RESULT.json", file=sys.stderr)
    sys.exit(2)
