"""State roots: ~/.pong preferred; ~/.hermes-pong legacy."""

from __future__ import annotations

import os
import shutil
from pathlib import Path

PRIMARY = Path.home() / ".pong"
LEGACY = Path.home() / ".hermes-pong"


def _secure_dir(p: Path, mode: int = 0o700) -> None:
    """mkdir parents + chmod (best-effort)."""
    p.mkdir(parents=True, exist_ok=True)
    try:
        p.chmod(mode)
    except Exception:
        pass


def state_dir() -> Path:
    """Resolve writable state directory.

    Prefer ~/.pong when it exists or when nothing exists yet.
    If only ~/.hermes-pong has data, keep using it until migrate() is called.
    Override with PONG_HOME.
    """
    env = (os.environ.get("PONG_HOME") or "").strip()
    if env:
        p = Path(env).expanduser()
        _secure_dir(p)
        return p
    if PRIMARY.exists():
        try:
            PRIMARY.chmod(0o700)
        except Exception:
            pass
        return PRIMARY
    if LEGACY.exists() and any(LEGACY.iterdir()):
        return LEGACY
    _secure_dir(PRIMARY)
    return PRIMARY


def migrate_legacy_to_primary(*, force: bool = False) -> Path:
    """Copy legacy tree into ~/.pong if needed. Returns active state_dir."""
    if not LEGACY.exists():
        PRIMARY.mkdir(parents=True, exist_ok=True)
        return PRIMARY
    if PRIMARY.exists() and any(PRIMARY.iterdir()) and not force:
        return PRIMARY
    PRIMARY.mkdir(parents=True, exist_ok=True)
    for item in LEGACY.iterdir():
        dest = PRIMARY / item.name
        if dest.exists() and not force:
            continue
        if item.is_dir():
            if dest.exists():
                shutil.rmtree(dest)
            shutil.copytree(item, dest)
        else:
            shutil.copy2(item, dest)
    return PRIMARY


def pairs_path() -> Path:
    return state_dir() / "pairs.json"


def active_path() -> Path:
    return state_dir() / "active-pair.json"


def jobs_dir(session: str | None = None) -> Path:
    base = state_dir() / "jobs"
    if session:
        return base / session
    return base


def sessions_dir(session: str | None = None) -> Path:
    base = state_dir() / "sessions"
    if session:
        return base / session
    return base


def ledger_dir() -> Path:
    return state_dir() / "ledger"


def binds_dir() -> Path:
    return state_dir() / "binds"


def briefs_dir() -> Path:
    return state_dir() / "briefs"


def ensure_layout(session: str | None = None) -> None:
    root = state_dir()
    try:
        root.chmod(0o700)
    except Exception:
        pass
    for sub in ("jobs", "sessions", "ledger", "binds", "briefs", "templates"):
        d = root / sub
        d.mkdir(parents=True, exist_ok=True)
        try:
            d.chmod(0o700)
        except Exception:
            pass
    if session:
        for d in (jobs_dir(session), sessions_dir(session)):
            d.mkdir(parents=True, exist_ok=True)
            try:
                d.chmod(0o700)
            except Exception:
                pass


def secure_file(path: Path, mode: int = 0o600) -> None:
    """Best-effort chmod for prompt/session artifacts."""
    try:
        if path.exists():
            path.chmod(mode)
    except Exception:
        pass
