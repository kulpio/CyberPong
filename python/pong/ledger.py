"""Verdict ledger (accept / reject / escalate)."""

from __future__ import annotations

import json
import time
from pathlib import Path
from typing import Any

from . import traces
from .paths import ledger_dir
from .state import detect_bound_session, load_session_state, workers_from_state


def _paths() -> tuple[Path, Path]:
    d = ledger_dir()
    d.mkdir(parents=True, exist_ok=True)
    return d / "verdicts.jsonl", d / "patterns.md"


def record(
    *,
    task_id: str,
    round_n: int,
    verdict: str,
    evidence: str = "",
    session: str | None = None,
    worker: str | None = None,
) -> dict[str, Any]:
    if verdict not in ("accept", "reject", "escalate"):
        raise ValueError("verdict must be accept|reject|escalate")
    sess = detect_bound_session(session)
    state = load_session_state(sess)
    if not sess or not workers_from_state(state):
        raise RuntimeError("ledger record requires an ACTIVE pair (BRIDGE_ON)")
    row = {
        "ts": time.time(),
        "session": sess,
        "task_id": task_id,
        "round": round_n,
        "verdict": verdict,
        "evidence": evidence,
        "worker": worker,
    }
    vpath, _ = _paths()
    with vpath.open("a", encoding="utf-8") as f:
        f.write(json.dumps(row) + "\n")
    traces.verdict(
        session=str(sess),
        task_id=task_id,
        verdict=verdict,
        round_n=round_n,
        evidence=evidence,
        worker=worker,
    )
    try:
        from . import events

        events.emit(
            "verdict",
            session=sess,
            task_id=task_id,
            verdict=verdict,
            round=round_n,
            worker=worker,
        )
    except Exception:
        pass
    return row


def summary(limit: int = 50) -> dict[str, Any]:
    vpath, ppath = _paths()
    rows: list[dict[str, Any]] = []
    if vpath.exists():
        for line in vpath.read_text(encoding="utf-8").splitlines()[-limit:]:
            try:
                rows.append(json.loads(line))
            except Exception:
                continue
    accepts = sum(1 for r in rows if r.get("verdict") == "accept")
    rejects = sum(1 for r in rows if r.get("verdict") == "reject")
    escalations = sum(1 for r in rows if r.get("verdict") == "escalate")
    total = len(rows) or 1
    streak = 0
    for r in reversed(rows):
        if r.get("verdict") == "reject":
            streak += 1
        else:
            break
    patterns = ppath.read_text(encoding="utf-8") if ppath.exists() else ""
    return {
        "rounds": len(rows),
        "accepts": accepts,
        "rejects": rejects,
        "escalations": escalations,
        "accept_rate": accepts / total,
        "reject_streak": streak,
        "last": rows[-1] if rows else None,
        "patterns": patterns[:2000],
    }


def distill() -> str:
    """Append a short note from recent rejects into patterns.md."""
    s = summary(100)
    _, ppath = _paths()
    lines = [
        f"\n## Distill {time.strftime('%Y-%m-%d %H:%M')}",
        f"- rounds={s['rounds']} accept_rate={s['accept_rate']:.0%} reject_streak={s['reject_streak']}",
    ]
    if s.get("last"):
        lines.append(f"- last: {s['last']}")
    ppath.parent.mkdir(parents=True, exist_ok=True)
    with ppath.open("a", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    return str(ppath)
