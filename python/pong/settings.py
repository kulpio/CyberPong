"""The person's settings, as the app saved them (2.0), and the key files Settings writes.

``<state_dir>/settings.json`` is written by the app, and by ``scripts/install.sh --developer``, which only
merges ``"developer": true`` into it (every other key kept, through a 0600 temp file renamed into place);
the engine only reads it. Every reader here is tolerant: a missing file, a garbled file or a key of the
wrong type gives the default, never an error, so a hand-edited file can never stop a graph. The keys the
engine reads:

- ``owner_name``: what the AIs call the person ("the person" when unset);
- ``architect``: ``{"runtime", "model"}`` the graph-planning chat runs on (unset: the catalog's lead policy);
- ``ai_enabled``: ``{"claude": true, "codex": false, ...}``; an AI switched off is never picked (absent = on);
- ``seat_permissions``: ``"auto"`` starts Claude and Grok seats in their own auto mode; anything else asks;
- ``limits``: the switches under Settings › Limits & keys (see :data:`LIMIT_DEFAULTS`);
- ``protected_labels``: seat labels a group operation never reassigns or stops (``["personal"]``, say;
  none by default), added by hand: the app has no switch for it;
- ``developer``: true only on the owner's Mac, where the graph-planning chat may fix CyberPong itself
  (``scripts/install.sh --developer`` sets it; the app has no switch for it).

Keys typed into Settings live in ``<state_dir>/secrets/<name>.env`` (folder 0700, file 0600, one
``NAME=value`` line), written atomically: the temporary file is created at 0600 in the same folder and
renamed over the old one, so the key is never readable by anyone else, not even for a moment. Nothing here
prints, logs or returns a key except to the one caller that puts it in a request header.
"""
from __future__ import annotations

import json
import os
import re
import tempfile
from pathlib import Path
from typing import Any

FILE = "settings.json"
SECRETS_DIR = "secrets"
DEFAULT_OWNER = "the person"
RUNTIMES = ("claude", "grok", "codex", "hermes")

#: The switches under Settings › Limits & keys, and what each is when the app never wrote it.
LIMIT_DEFAULTS: dict[str, Any] = {
    "ride_out_5h": True,          # at Claude's 5-hour limit: pause running graphs, resume after the reset
    "week_stop_pct": 97,          # pause running graphs when Claude's weekly use passes this %; 0 = off
    "helper_ai": True,            # Claude Haiku writes plain-words questions, details and names
    "jev": True,                  # Jev second opinions (needs a key)
    "perplexity": True,           # web research through Perplexity (needs a key)
    "perplexity_daily_usd": 15.0,  # daily spending cap for Perplexity
}

#: Key files Settings writes, by name: the variable each holds.
KEY_VARS = {"jev": "TYPESAFE_API_KEY", "perplexity": "PERPLEXITY_API_KEY"}

_NAME_BAD = re.compile(r"[\x00-\x1f\x7f`$<>{}\\]")
_KEY_OK = re.compile(r"^[\x21-\x7e]{8,512}$")  # printable, no spaces: a token, not a sentence


def path() -> Path:
    from .paths import state_dir

    return state_dir() / FILE


def load() -> dict[str, Any]:
    """The whole file, or ``{}`` when it is missing, unreadable or not an object."""
    try:
        data = json.loads(path().read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def _bool(v: Any, default: bool) -> bool:
    if isinstance(v, bool):
        return v
    if isinstance(v, (int, float)) and v in (0, 1):
        return bool(v)
    if isinstance(v, str) and v.strip().lower() in ("true", "on", "yes", "1"):
        return True
    if isinstance(v, str) and v.strip().lower() in ("false", "off", "no", "0"):
        return False
    return default


def _num(v: Any, default: float, lo: float, hi: float) -> float:
    if isinstance(v, bool):
        return default
    try:
        f = float(v)
    except (TypeError, ValueError):
        return default
    if f != f:  # NaN
        return default
    return max(lo, min(hi, f))


def owner_name(*, capital: bool = False, data: dict[str, Any] | None = None) -> str:
    """What the AIs call the person: the name they gave, or "the person" ("The person" to start a sentence).

    The name goes into text the AIs read, so it is one short line: control characters and the characters a
    shell or a template would act on are dropped, whitespace is collapsed, and it is cut at 40 characters."""
    raw = (load() if data is None else data).get("owner_name")
    name = " ".join(_NAME_BAD.sub("", raw).split())[:40].strip() if isinstance(raw, str) else ""
    if not name:
        return DEFAULT_OWNER.capitalize() if capital else DEFAULT_OWNER
    return name


def architect_default(data: dict[str, Any] | None = None) -> dict[str, str]:
    """``{"runtime", "model"}`` the person picked for the graph-planning chat; each "" when unset."""
    a = (load() if data is None else data).get("architect")
    a = a if isinstance(a, dict) else {}
    rt = str(a.get("runtime") or "").strip().lower() if isinstance(a.get("runtime"), str) else ""
    model = str(a.get("model") or "").strip() if isinstance(a.get("model"), str) else ""
    if rt and not re.fullmatch(r"[a-z0-9_-]{1,32}", rt):
        rt = ""
    if model and not re.fullmatch(r"[A-Za-z0-9 ._:/-]{1,64}", model):
        model = ""
    return {"runtime": rt, "model": model}


def ai_enabled(runtime: str, data: dict[str, Any] | None = None) -> bool:
    """False only when the person switched this AI off; absent or garbled means on."""
    m = (load() if data is None else data).get("ai_enabled")
    if not isinstance(m, dict):
        return True
    rt = str(runtime or "").strip().lower()
    if rt == "openai":
        rt = "codex"
    v = m.get(rt)
    return _bool(v, True) if v is not None else True


def disabled_runtimes(data: dict[str, Any] | None = None) -> set[str]:
    m = (load() if data is None else data).get("ai_enabled")
    if not isinstance(m, dict):
        return set()
    return {str(k).strip().lower() for k, v in m.items() if v is not None and not _bool(v, True)}


def limits(data: dict[str, Any] | None = None) -> dict[str, Any]:
    """Every switch of Settings › Limits & keys, with its default where the app wrote nothing usable."""
    raw = (load() if data is None else data).get("limits")
    raw = raw if isinstance(raw, dict) else {}
    d = LIMIT_DEFAULTS
    return {
        "ride_out_5h": _bool(raw.get("ride_out_5h"), d["ride_out_5h"]),
        "week_stop_pct": int(_num(raw.get("week_stop_pct"), d["week_stop_pct"], 0, 100)),
        "helper_ai": _bool(raw.get("helper_ai"), d["helper_ai"]),
        "jev": _bool(raw.get("jev"), d["jev"]),
        "perplexity": _bool(raw.get("perplexity"), d["perplexity"]),
        "perplexity_daily_usd": round(_num(raw.get("perplexity_daily_usd"), d["perplexity_daily_usd"], 0, 10000), 2),
    }


def seat_permissions(data: dict[str, Any] | None = None) -> str:
    """"auto" when the person let the AIs work without stopping to ask; otherwise "ask" (today's behaviour)."""
    v = (load() if data is None else data).get("seat_permissions")
    return "auto" if isinstance(v, str) and v.strip().lower() == "auto" else "ask"


def protected_labels(data: dict[str, Any] | None = None) -> tuple[str, ...]:
    """Seat labels the engine never reassigns or stops in a group operation (``protected_labels``: a list of
    strings, matched case-blind as a part of a seat's label). Empty when unset or garbled; at most 32 labels
    of up to 64 characters, so a hand-edited file cannot make every seat untouchable by accident."""
    raw = (load() if data is None else data).get("protected_labels")
    if not isinstance(raw, list):
        return ()
    out: list[str] = []
    for v in raw:
        s = " ".join(v.split()).lower()[:64] if isinstance(v, str) else ""
        if s and s not in out:
            out.append(s)
    return tuple(out[:32])


def developer(data: dict[str, Any] | None = None) -> bool:
    """True only on the owner's own Mac: ``scripts/install.sh --developer`` writes it (the app never does,
    and nothing else turns it on). The graph-planning chat may then fix CyberPong itself, and Perplexity
    may use the key in Claude Code's own connector settings."""
    return (load() if data is None else data).get("developer") is True


def summary(data: dict[str, Any] | None = None) -> dict[str, Any]:
    """The settings the engine acts on, effective values, for ``pong doctor``."""
    data = load() if data is None else data
    return {"owner_name": owner_name(data=data), "architect": architect_default(data),
            "ai_enabled": {rt: ai_enabled(rt, data) for rt in RUNTIMES},
            "seat_permissions": seat_permissions(data), "limits": limits(data), "developer": developer(data),
            "protected_labels": list(protected_labels(data))}


# ------------------------------------------------------------------ key files ---

def secrets_dir() -> Path:
    from .paths import state_dir

    return state_dir() / SECRETS_DIR


def key_path(name: str) -> Path:
    if name not in KEY_VARS:
        raise ValueError(f"unknown key {name!r} (one of: {', '.join(KEY_VARS)})")
    return secrets_dir() / f"{name}.env"


def read_key_line(p: Path, var: str) -> str:
    """The value of ``var`` in a ``KEY=value`` file (``export`` and quotes allowed), or ''."""
    try:
        text = p.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        return ""
    rx = re.compile(r"\s*(?:export\s+)?" + re.escape(var) + r"\s*=\s*(.*)$")
    for line in text.splitlines():
        m = rx.match(line)
        if m:
            return m.group(1).strip().strip('"').strip("'").strip()
    return ""


def settings_key(name: str) -> str:
    """The key Settings saved for *name*, or ''."""
    return read_key_line(key_path(name), KEY_VARS[name])


def valid_key(value: str) -> bool:
    return bool(_KEY_OK.match(value or ""))


def write_key(name: str, value: str) -> Path:
    """Save a key the way the app does: folder 0700, file created at 0600, then renamed into place."""
    value = (value or "").strip()
    if not valid_key(value):
        raise ValueError("that does not look like a key: one line, no spaces, 8 to 512 characters")
    p = key_path(name)
    d = p.parent
    d.mkdir(mode=0o700, parents=True, exist_ok=True)
    try:
        d.chmod(0o700)
    except OSError:
        pass
    fd, tmp = tempfile.mkstemp(prefix=f".{p.name}.", suffix=".tmp", dir=str(d))  # mkstemp creates it 0600
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(f"{KEY_VARS[name]}={value}\n")
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, p)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise
    return p


def clear_key(name: str) -> bool:
    """Remove only the key Settings saved (never a key file jev.json names). True when there was one."""
    p = key_path(name)
    try:
        p.unlink()
        return True
    except FileNotFoundError:
        return False


def _real_home() -> bool:
    from .paths import state_dir

    try:
        return state_dir().resolve() == (Path.home() / ".pong").resolve()
    except OSError:
        return False


def perplexity_key() -> tuple[str, str]:
    """(key, source) for Perplexity: Settings' file, then ``PERPLEXITY_API_KEY``, then (owner's Mac only:
    the real CyberPong home and ``developer`` true) the key in Claude Code's own Perplexity connector entry
    in ``~/.claude.json``, source ``claude_connector``. On anyone else's Mac a key they gave Claude Code is
    never spent by CyberPong unless they save it in Settings. (Jev has no such fallback: its key comes from
    Settings, the environment or the ``key_file`` jev.json names, nowhere else.)"""
    k = settings_key("perplexity")
    if k:
        return k, "settings"
    k = (os.environ.get("PERPLEXITY_API_KEY") or "").strip()
    if k:
        return k, "environment"
    if _real_home() and developer():
        try:
            d = json.loads((Path.home() / ".claude.json").read_text(encoding="utf-8"))
            k = str(((((d.get("mcpServers") or {}).get("perplexity") or {}).get("env") or {})
                     .get("PERPLEXITY_API_KEY")) or "").strip()
        except (OSError, ValueError, AttributeError):
            k = ""
        if k:
            return k, "claude_connector"
    return "", ""


def keys_status() -> dict[str, dict[str, Any]]:
    """``pong keys status``: set or not, where from, and whether its switch is on. Never a key, a prefix or a length."""
    from . import jev

    lim = limits()
    jk, jsrc, _ = jev.key_source()
    pk, psrc = perplexity_key()
    return {
        "jev": {"set": bool(jk), "source": jsrc if jk else "", "enabled": jev.enabled()},
        "perplexity": {"set": bool(pk), "source": psrc if pk else "", "enabled": bool(lim["perplexity"])},
    }
