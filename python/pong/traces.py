"""Append-only run traces — one JSONL file per job.

    <PONG_HOME|~/.pong>/traces/<session>/<job_id>.jsonl

Every line is one JSON object using the **langsmith-sdk export field names**
(``id``, ``trace_id``, ``parent_run_id``, ``name``, ``run_type``,
``start_time``, ``end_time``, ``inputs``, ``outputs``, ``error``, ``tags``,
``extra``) so the log can be replayed into a self-hosted, open-source viewer
(Langfuse, MIT) without paying anyone or calling out to a vendor. Nothing in
this module opens a socket, reads a key, or imports a third-party package —
it is stdlib only, on purpose. See ``docs/observability.md``.

Pong specifics (session, seat, mission_role, parent seat, job status) live
under ``extra``; the top-level names stay exactly what the exporter expects.

**Tracing must never break the control plane.** Every public entry point is
wrapped by :func:`_safe`: any exception — full disk, read-only path, bad
JSON — is caught, reported once on stderr, and the caller proceeds. Set
``PONG_TRACE=0`` to disable writing entirely.
"""

from __future__ import annotations

import json
import os
import sys
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, TypeVar

from .paths import secure_file, state_dir

RUN_TYPES = ("chain", "tool", "llm")

# One stderr line per failing reason, so a broken traces dir is visible once
# instead of either silent (bad) or screaming on every job (worse).
_warned: set[str] = set()

# Keep single values bounded — a task or claim body should not turn the trace
# into the payload store. Truncation is marked so a reader is not misled.
_MAX_STR = 4000

_T = TypeVar("_T")


def enabled() -> bool:
    """False when ``PONG_TRACE`` is 0/false/off/no. Default on."""
    v = (os.environ.get("PONG_TRACE") or "").strip().lower()
    return v not in ("0", "false", "off", "no")


def _warn_once(key: str, exc: BaseException) -> None:
    if key in _warned:
        return
    _warned.add(key)
    try:
        sys.stderr.write(
            f"pong: trace write disabled for this reason ({key}): "
            f"{type(exc).__name__}: {exc}\n"
        )
    except Exception:
        pass


def _safe(fn: Callable[..., _T]) -> Callable[..., _T | None]:
    """Never let tracing raise into a job, a claim, or a dispatch."""

    def wrapper(*args: Any, **kwargs: Any) -> _T | None:
        try:
            return fn(*args, **kwargs)
        except BaseException as exc:  # noqa: BLE001 - deliberate: see module doc
            if isinstance(exc, KeyboardInterrupt):
                raise
            _warn_once(f"{fn.__name__}:{type(exc).__name__}", exc)
            return None

    wrapper.__name__ = fn.__name__
    wrapper.__doc__ = fn.__doc__
    return wrapper


# --- paths -----------------------------------------------------------------


def traces_dir(session: str | None = None) -> Path:
    """``<state_dir>/traces[/<session>]`` — honours PONG_HOME via state_dir()."""
    base = state_dir() / "traces"
    if session:
        return base / _slug(str(session))
    return base


def trace_path(session: str, job_id: str) -> Path:
    return traces_dir(session) / f"{_slug(str(job_id))}.jsonl"


def _slug(s: str) -> str:
    """Keep a session/job id to one safe path segment."""
    keep = [c if (c.isalnum() or c in "-_.") else "-" for c in s.strip()]
    out = "".join(keep).strip("-.") or "unknown"
    return out[:120]


# --- run ids ---------------------------------------------------------------

_NS = uuid.UUID("6f4c0f0e-9f2a-5f4b-9a2f-0c1d2e3f4a5b")


def root_run_id(job_id: str) -> str:
    """Deterministic root run id for a job, so every line shares one trace."""
    return str(uuid.uuid5(_NS, f"pong-job:{job_id}"))


def _iso(ts: float | None = None) -> str:
    t = time.time() if ts is None else float(ts)
    return datetime.fromtimestamp(t, tz=timezone.utc).isoformat()


# --- value shaping ---------------------------------------------------------


def _clip(v: Any) -> Any:
    if isinstance(v, str):
        return v if len(v) <= _MAX_STR else v[:_MAX_STR] + f"…[+{len(v) - _MAX_STR}]"
    if isinstance(v, dict):
        return {str(k): _clip(x) for k, x in v.items()}
    if isinstance(v, (list, tuple)):
        return [_clip(x) for x in list(v)[:200]]
    if isinstance(v, (int, float, bool)) or v is None:
        return v
    return _clip(str(v))


def _seat_extra(job: dict[str, Any], state: dict[str, Any] | None = None) -> dict[str, Any]:
    """session / seat / mission_role / parent seat / job status, best effort."""
    seat = str(job.get("worker") or "")
    out: dict[str, Any] = {
        "session": str(job.get("session") or ""),
        "seat": seat,
        "seat_label": job.get("worker_label"),
        "seat_type": job.get("worker_type"),
        "job_id": str(job.get("id") or ""),
        "job_status": job.get("status"),
        "round": job.get("round"),
    }
    if state and seat:
        try:
            from .state import workers_from_state

            for w in workers_from_state(state):
                if str(w.get("id") or "") == seat:
                    out["parent_seat"] = str(w.get("parent_id") or "") or None
                    break
        except Exception:
            pass
        try:
            from .role_identity import seat_mission_role

            out["mission_role"] = seat_mission_role(state, seat)
        except Exception:
            pass
    return {k: v for k, v in out.items() if v is not None}


# --- write -----------------------------------------------------------------


@_safe
def record(
    *,
    session: str,
    job_id: str,
    name: str,
    run_type: str = "chain",
    inputs: dict[str, Any] | None = None,
    outputs: dict[str, Any] | None = None,
    error: str | None = None,
    tags: list[str] | None = None,
    extra: dict[str, Any] | None = None,
    is_root: bool = False,
    start_time: float | None = None,
    end_time: float | None = None,
) -> dict[str, Any] | None:
    """Append one run to ``traces/<session>/<job_id>.jsonl``.

    Returns the row written, or ``None`` when tracing is off or the write
    failed. Callers never need to check — failure is not their problem.
    """
    if not enabled():
        return None
    jid = str(job_id or "").strip()
    if not jid:
        return None
    rt = run_type if run_type in RUN_TYPES else "chain"
    root = root_run_id(jid)
    started = _iso(start_time)
    row: dict[str, Any] = {
        # langsmith export field names — do not rename, replay depends on them
        "id": root if is_root else str(uuid.uuid4()),
        "trace_id": root,
        "parent_run_id": None if is_root else root,
        "name": str(name),
        "run_type": rt,
        "start_time": started,
        "end_time": _iso(end_time) if end_time is not None else started,
        "inputs": _clip(inputs or {}),
        "outputs": _clip(outputs or {}),
        "error": _clip(error) if error else None,
        "tags": [str(t) for t in (tags or [])],
        "extra": _clip(extra or {}),
    }
    path = trace_path(session, jid)
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as f:
        f.write(json.dumps(row, ensure_ascii=False) + "\n")
    secure_file(path, 0o600)
    return row


@_safe
def job_created(job: dict[str, Any], *, state: dict[str, Any] | None = None) -> None:
    """Root run for the job: who it went to, from whom, and the task."""
    task = str(job.get("task") or "")
    record(
        session=str(job.get("session") or ""),
        job_id=str(job.get("id") or ""),
        name="job.create",
        run_type="chain",
        is_root=True,
        inputs={
            "worker": job.get("worker"),
            "from_seat": job.get("from_seat"),
            "task": task.strip().splitlines()[0][:300] if task.strip() else "",
            "project_root": job.get("project_root") or "",
            "acceptance_count": len(job.get("acceptance") or []),
        },
        outputs={"status": job.get("status")},
        tags=["job", "create"],
        extra=_seat_extra(job, state),
        start_time=job.get("created_at"),
    )


@_safe
def job_status(job: dict[str, Any], *, previous: str, status: str) -> None:
    record(
        session=str(job.get("session") or ""),
        job_id=str(job.get("id") or ""),
        name=f"job.status.{status}",
        run_type="chain",
        inputs={"from": previous},
        outputs={"to": status},
        error=str(job.get("error")) if job.get("error") else None,
        tags=["job", "status", status],
        extra=_seat_extra(job),
    )


@_safe
def job_claim(job: dict[str, Any], claim: dict[str, Any], *, previous: str) -> None:
    record(
        session=str(job.get("session") or ""),
        job_id=str(job.get("id") or ""),
        name="job.claim",
        run_type="chain",
        inputs={"from": previous},
        outputs={
            "files": list(claim.get("files") or []),
            "commands": str(claim.get("commands") or ""),
            "summary": str(claim.get("summary") or ""),
            "token_ok": bool(claim.get("token_ok")),
        },
        tags=["job", "claim"],
        extra=_seat_extra(job),
        end_time=claim.get("at"),
    )


@_safe
def verdict(
    *,
    session: str,
    task_id: str,
    verdict: str,
    round_n: int,
    evidence: str = "",
    worker: str | None = None,
) -> None:
    """Ledger verdict, filed against the job id it judged."""
    record(
        session=session,
        job_id=task_id,
        name=f"ledger.verdict.{verdict}",
        run_type="chain",
        inputs={"round": round_n, "worker": worker},
        outputs={"verdict": verdict, "evidence": evidence},
        error=evidence if verdict == "reject" else None,
        tags=["ledger", "verdict", verdict],
        extra={"session": session, "seat": worker, "task_id": task_id},
    )


@_safe
def transport_result(
    job: dict[str, Any],
    *,
    name: str,
    ok: bool,
    detail: str = "",
    meta: dict[str, Any] | None = None,
) -> None:
    """One run per transport attempt — job_file / tmux_paste / waitroom."""
    record(
        session=str(job.get("session") or ""),
        job_id=str(job.get("id") or ""),
        name=f"transport.{name}",
        run_type="tool",
        inputs={"transport": name, "seat": job.get("worker")},
        outputs={"ok": bool(ok), "detail": detail, "meta": meta or {}},
        error=None if ok else (detail or f"{name} failed"),
        tags=["transport", name, "ok" if ok else "error"],
        extra=_seat_extra(job),
    )


# --- read (never writes) ---------------------------------------------------


def read_trace(session: str, job_id: str) -> list[dict[str, Any]]:
    """Rows for one job, oldest first. Unreadable/short lines are skipped."""
    path = trace_path(session, job_id)
    if not path.exists():
        return []
    rows: list[dict[str, Any]] = []
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return []
    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            rows.append(json.loads(line))
        except Exception:
            continue
    return rows


def find_trace(job_id: str, session: str | None = None) -> tuple[str, Path] | None:
    """Locate a job's trace file, searching every session when none given."""
    if session:
        p = trace_path(session, job_id)
        return (session, p) if p.exists() else None
    base = traces_dir()
    if not base.exists():
        return None
    fname = f"{_slug(str(job_id))}.jsonl"
    for d in sorted(base.iterdir()):
        if not d.is_dir():
            continue
        p = d / fname
        if p.exists():
            return (d.name, p)
    return None


def list_traces(limit: int = 20, session: str | None = None) -> list[dict[str, Any]]:
    """Newest-first index of trace files: job id, session, runs, last name."""
    base = traces_dir()
    if not base.exists():
        return []
    dirs = [base / _slug(session)] if session else [d for d in base.iterdir() if d.is_dir()]
    files: list[tuple[float, str, Path]] = []
    for d in dirs:
        if not d.is_dir():
            continue
        for p in d.glob("*.jsonl"):
            try:
                files.append((p.stat().st_mtime, d.name, p))
            except OSError:
                continue
    files.sort(key=lambda t: t[0], reverse=True)
    if limit and limit > 0:
        files = files[:limit]
    out: list[dict[str, Any]] = []
    for mtime, sess, p in files:
        rows = read_trace(sess, p.stem)
        last = rows[-1] if rows else {}
        out.append(
            {
                "job_id": p.stem,
                "session": sess,
                "runs": len(rows),
                "updated": _iso(mtime),
                "last": last.get("name") or "",
                "seat": (last.get("extra") or {}).get("seat") or "",
                "status": (last.get("extra") or {}).get("job_status") or "",
                "path": str(p),
            }
        )
    return out


def format_trace(rows: list[dict[str, Any]]) -> list[str]:
    lines: list[str] = []
    for r in rows:
        extra = r.get("extra") or {}
        head = (
            f"{r.get('start_time', '')}  {r.get('run_type', ''):<5}  {r.get('name', '')}"
        )
        seat = extra.get("seat") or ""
        if seat:
            head += f"  [{seat}]"
        lines.append(head)
        for key in ("inputs", "outputs"):
            val = r.get(key) or {}
            if val:
                lines.append(f"    {key}: {json.dumps(val, ensure_ascii=False)[:400]}")
        if r.get("error"):
            lines.append(f"    error: {str(r['error'])[:400]}")
    return lines


def format_index(rows: list[dict[str, Any]]) -> list[str]:
    if not rows:
        return ["(no traces)"]
    lines = [f"{'job':<32} {'session':<14} {'runs':>4}  last"]
    for r in rows:
        lines.append(
            f"{r['job_id']:<32} {r['session']:<14} {r['runs']:>4}  "
            f"{r['last']} ({r.get('status') or '?'}) {r['updated']}"
        )
    return lines
