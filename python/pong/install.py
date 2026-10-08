"""Is the control plane the seats actually run the one in this checkout?

Every seat's shell has ``~/bin/pong``, and that script sets
``PYTHONPATH=~/.pong/lib`` — so ``pong job claim`` in a worker pane runs
whatever was last copied there, not this repo. The app is the other way round:
:class:`LoopStore` puts the checkout first. The two can drift, and when they do
nothing says so.

They had drifted. The installed copy was missing ``mailbox``, ``work_graph``,
``loops``, ``cron``, ``drain``, ``runtime`` and ``examples`` — every module
CyberPong 2 added. From a pane, ``pong mailbox peek`` was *invalid choice*, and
a child's ``pong job claim`` wrote no mailbox item, which is the one signal the
whole design rests on. Meanwhile the app started loops perfectly well, so the
feature looked shipped from the only window anyone watches.

A stale install is a normal thing to have. Silence about it is not, so this
makes it a line in ``pong check`` rather than a mystery in a pane.
"""

from __future__ import annotations

import hashlib
from pathlib import Path
from typing import Any

from .paths import state_dir

#: Modules a seat needs for the v2 control plane to work from a pane. Anything
#: whose absence turns a documented command into "invalid choice" belongs here.
REQUIRED_MODULES = (
    "claim_harvest",
    "claims",
    "cron",
    "doctor",
    "drain",
    "examples",
    "flow",
    "groups",
    "jobs",
    "limits",
    "loops",
    "mailbox",
    "models",
    "runtime",
    "seat_status",
    "settings",
    "snapshot",
    "state",
    "traces",
    "waitroom",
    "work_graph",
    "cli/main",
)

#: Data directories that ship with the package. A catalog that did not get
#: copied fails at read time, not import time, which is worse.
REQUIRED_DATA = ("loops", "models", "review/bars")


def running_dir() -> Path:
    """The package directory this process actually imported."""
    return Path(__file__).resolve().parent


def installed_dir() -> Path:
    """Where ``~/bin/pong`` looks."""
    return state_dir() / "lib" / "pong"


def _sha(path: Path) -> str:
    try:
        return hashlib.sha256(path.read_bytes()).hexdigest()[:16]
    except OSError:
        return ""


def installed_version() -> str:
    """Version recorded by the installer, or "" when it predates the stamp."""
    stamp = installed_dir() / "INSTALL_STAMP"
    try:
        for line in stamp.read_text(encoding="utf-8").splitlines():
            if line.startswith("version="):
                return line.split("=", 1)[1].strip()
    except OSError:
        pass
    return ""


def status() -> dict[str, Any]:
    """Compare the installed control plane with the one running now."""
    run = running_dir()
    inst = installed_dir()
    same = run.resolve() == inst.resolve()

    missing: list[str] = []
    for mod in REQUIRED_MODULES:
        if not (inst / f"{mod}.py").is_file():
            missing.append(f"{mod}.py")
    for data in REQUIRED_DATA:
        if not (inst / data).is_dir():
            missing.append(f"{data}/")

    drift: list[str] = []
    if not same and inst.is_dir():
        for src in sorted(run.rglob("*.py")):
            if "__pycache__" in src.parts:
                continue
            rel = src.relative_to(run)
            dst = inst / rel
            if not dst.is_file():
                if str(rel) not in missing:
                    missing.append(str(rel))
                continue
            if _sha(src) != _sha(dst):
                drift.append(str(rel))

    from . import __version__

    ok = inst.is_dir() and not missing and not drift
    return {
        "running_from": str(run),
        "running_version": __version__,
        "installed_version": installed_version(),
        "installed_dir": str(inst),
        "installed_exists": inst.is_dir(),
        "same_tree": same,
        "missing": missing,
        "drift": drift,
        "ok": ok,
        "hint": (
            "bash scripts/install-control-plane.sh   # sync ~/.pong/lib with this checkout"
            if not ok
            else ""
        ),
    }


def format_status(st: dict[str, Any]) -> list[str]:
    """Lines for ``pong check``. Short when healthy, specific when not."""
    stamped = st.get("installed_version") or "unstamped"
    lines = [
        f"control_plane_installed={st['installed_dir']} "
        f"version={stamped} (this checkout: {st.get('running_version')})"
    ]
    if not st["installed_exists"]:
        lines.append("FAIL: no installed control plane — every seat's `pong` will fail")
        lines.append(f"  fix: {st['hint']}")
        return lines
    if st["same_tree"]:
        lines.append("running from the installed copy — nothing to compare")
    if st["missing"]:
        shown = ", ".join(st["missing"][:8])
        more = f" (+{len(st['missing']) - 8} more)" if len(st["missing"]) > 8 else ""
        lines.append(f"FAIL: installed copy is missing {shown}{more}")
        lines.append("  seats will get `invalid choice` for the commands those provide")
    if st["drift"]:
        shown = ", ".join(st["drift"][:8])
        more = f" (+{len(st['drift']) - 8} more)" if len(st["drift"]) > 8 else ""
        lines.append(f"WARN: installed copy differs from this checkout: {shown}{more}")
    if st["hint"]:
        lines.append(f"  fix: {st['hint']}")
    elif not st["same_tree"]:
        lines.append("installed copy matches this checkout")
    return lines
