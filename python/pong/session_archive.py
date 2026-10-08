"""Session vault: smart-compress live teams into durable continuity archives.

Archives live under ``~/.pong/session-archive/<id>/`` with:
  meta.json  — id, titles, roster snapshot, stats
  recap.md   — human-readable continuity package

Smart compress uses control-plane artifacts only (jobs, claims, ledger, brief).
No vendor API keys; no full token transcripts.
"""

from __future__ import annotations

import json
import os
import re
import time
import uuid
from datetime import datetime
from pathlib import Path
from typing import Any

from .jsonutil import read_json, write_json
from .paths import ensure_layout, jobs_dir, ledger_dir, sessions_dir, state_dir
from .state import load_session_state, workers_from_state

OPEN_STATUSES = frozenset(
    {"queued", "notified", "running", "human_takeover", "rejected"}
)
DONE_LIKE = frozenset({"done", "failed", "cancelled"})
KEEP_TIMESTAMPED = 12

# Archive ids are single path segments only — never user path fragments.
# Matches _new_id(): sess_YYYYMMDD_HHMMSS_<6 hex>
_ARCHIVE_ID_RE = re.compile(r"^sess_[A-Za-z0-9_]+$")


def archive_root() -> Path:
    d = state_dir() / "session-archive"
    d.mkdir(parents=True, exist_ok=True)
    try:
        d.chmod(0o700)
    except Exception:
        pass
    return d


def safe_archive_id(archive_id: str | None) -> str | None:
    """Return a validated archive id, or None if unsafe/invalid.

    Rejects empty, ``.``, ``..``, slashes, null bytes, and anything that is not
    a single ``sess_[A-Za-z0-9_]+`` segment. Prevents path traversal when
    joining under ``archive_root()``.
    """
    if archive_id is None:
        return None
    if not isinstance(archive_id, str):
        return None
    aid = archive_id.strip()
    if not aid:
        return None
    if "\x00" in aid:
        return None
    if aid in (".", ".."):
        return None
    if "/" in aid or "\\" in aid:
        return None
    # Absolute paths / drive letters / home escapes
    if aid.startswith("~") or (len(aid) >= 2 and aid[1] == ":"):
        return None
    if not _ARCHIVE_ID_RE.match(aid):
        return None
    return aid


def _is_under_archive_root(path: Path, root: Path | None = None) -> bool:
    """True if *path* resolves strictly inside *root* (not root itself for deletes)."""
    root = (root or archive_root()).resolve()
    try:
        resolved = path.resolve()
    except (OSError, RuntimeError):
        return False
    try:
        # Python 3.9+: Path.is_relative_to
        if hasattr(resolved, "is_relative_to"):
            return resolved.is_relative_to(root) and resolved != root
        # Fallback: commonpath
        return os.path.commonpath([str(resolved), str(root)]) == str(root) and resolved != root
    except (ValueError, OSError):
        return False


def archive_dir(archive_id: str | None) -> Path | None:
    """Resolved directory for *archive_id* under archive_root, or None if invalid."""
    aid = safe_archive_id(archive_id)
    if not aid:
        return None
    root = archive_root().resolve()
    # Join only the validated segment (no user path components)
    d = (root / aid).resolve()
    if not _is_under_archive_root(d, root):
        return None
    return d


def _tz_name() -> str:
    try:
        return datetime.now().astimezone().tzname() or time.tzname[0] or "local"
    except Exception:
        return "local"


def _local_date_line() -> str:
    now = datetime.now().astimezone()
    return now.strftime("%Y-%m-%d %H:%M") + f" ({_tz_name()})"


def default_archive_title(display_name: str) -> str:
    """Stable default archive title: ``{display_name} · {local datetime}``.

    Used by CLI ``continuity save`` (no --title), UI empty-title save, and
    New session+recap compress. Always includes the team display name.
    """
    name = (display_name or "").strip() or "team"
    return f"{name} · {_local_date_line()}"


def archive_matches_team(
    meta: dict[str, Any],
    *,
    source_session: str | None = None,
    display_name: str | None = None,
) -> bool:
    """Return True if *meta* belongs to the requested team scope.

    Filters (OR when both are provided):
      - **source_session**: exact match on ``meta.source_session`` (pair id is stable).
      - **display_name**: case-insensitive equality on ``meta.display_name``.

    Rename edge case: if the live team was *renamed* (display_name changed),
    archives still match via ``source_session``. If only ``display_name`` is
    supplied and the team was renamed, older archives under the prior name
    will not match until re-saved — prefer both filters from a live context.
    When neither filter is set, always matches (unscoped list).
    """
    sess = (source_session or "").strip()
    team = (display_name or "").strip()
    if not sess and not team:
        return True
    if sess:
        src = str(meta.get("source_session") or "").strip()
        if src == sess:
            return True
        if not team:
            return False
    # display_name filter (alone, or OR second chance after session miss)
    dn = str(meta.get("display_name") or "").strip()
    return bool(team) and dn.casefold() == team.casefold()


def archive_row_label(meta: dict[str, Any]) -> str:
    """Human list/picker label: title, with team name if title lacks it."""
    title = str(meta.get("title") or meta.get("id") or "").strip()
    team = str(meta.get("display_name") or "").strip()
    if not team:
        return title
    if team.casefold() in title.casefold():
        return title
    return f"{title} · {team}"


def _truncate(s: str, max_chars: int) -> str:
    t = (s or "").strip()
    if len(t) <= max_chars:
        return t
    return t[: max_chars - 1].rstrip() + "…"


def _task_title(task: str, limit: int = 120) -> str:
    raw = (task or "").strip()
    if not raw:
        return "(no task text)"
    # Prefer first markdown heading or first non-empty line
    for line in raw.splitlines():
        line = line.strip()
        if not line:
            continue
        line = re.sub(r"^#+\s*", "", line)
        return _truncate(line, limit)
    return _truncate(raw, limit)


def _claim_summary(job: dict[str, Any]) -> str:
    claim = job.get("claim")
    if isinstance(claim, dict):
        s = claim.get("summary") or claim.get("raw") or ""
        return _truncate(str(s), 280)
    if isinstance(claim, str):
        return _truncate(claim, 280)
    return ""


def _list_jobs(session: str) -> list[dict[str, Any]]:
    d = jobs_dir(session)
    if not d.exists():
        return []
    out: list[dict[str, Any]] = []
    for p in sorted(d.glob("job_*.json"), reverse=True):
        j = read_json(p)
        if j and isinstance(j, dict):
            out.append(j)
    return out


def _ledger_rows(session: str, limit: int = 80) -> list[dict[str, Any]]:
    path = ledger_dir() / "verdicts.jsonl"
    if not path.exists():
        return []
    rows: list[dict[str, Any]] = []
    try:
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return []
    for line in reversed(lines):
        line = line.strip()
        if not line:
            continue
        try:
            row = json.loads(line)
        except json.JSONDecodeError:
            continue
        if str(row.get("session") or "") != session:
            continue
        rows.append(row)
        if len(rows) >= limit:
            break
    rows.reverse()
    return rows


def _snippet_file(session: str, name: str, max_chars: int = 400) -> str:
    # Prefer session-scoped, then global
    candidates = [
        sessions_dir(session) / name,
        state_dir() / name,
    ]
    for p in candidates:
        if not p.is_file():
            continue
        try:
            text = p.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        if text.strip():
            return _truncate(text, max_chars)
    return ""


def _pair_meta(session: str) -> dict[str, Any]:
    state = load_session_state(session) or {}
    display = str(state.get("display_name") or session).strip() or session
    root = str(state.get("project_root") or "").strip()
    brief = str(state.get("team_brief") or "").strip()
    cond = state.get("conductor") if isinstance(state.get("conductor"), dict) else {}
    roster: list[dict[str, Any]] = []
    if cond:
        roster.append(
            {
                "id": str(cond.get("id") or "c1"),
                "role": "orchestrator",
                "type": str(cond.get("type") or cond.get("id") or ""),
                "label": str(cond.get("label") or "Conductor"),
            }
        )
    for w in workers_from_state(state):
        roster.append(
            {
                "id": str(w.get("id") or ""),
                "role": str(w.get("mission_role") or "coder"),
                "type": str(w.get("type") or ""),
                "label": str(w.get("label") or w.get("id") or ""),
            }
        )
    return {
        "display_name": display,
        "project_root": root,
        "team_brief": brief,
        "roster": roster,
        "state": state,
    }


def build_recap_markdown(
    session: str,
    *,
    title: str | None = None,
    max_jobs: int = 40,
    max_ledger: int = 40,
) -> str:
    """Render the smart-compress continuity package (pure control-plane inputs)."""
    meta = _pair_meta(session)
    display = meta["display_name"]
    root = meta["project_root"] or "(unset)"
    brief = meta["team_brief"] or "(none recorded)"
    jobs = _list_jobs(session)[:max_jobs]
    ledger = _ledger_rows(session, limit=max_ledger)

    accepts: list[str] = []
    rejects: list[str] = []
    decisions: list[str] = []

    # Ledger first — explicit accept/reject path = “how we decided”
    for row in ledger:
        verdict = str(row.get("verdict") or "").lower()
        jid = str(row.get("task_id") or row.get("job_id") or "?")
        evidence = _truncate(str(row.get("evidence") or ""), 220)
        line = f"- **{verdict}** `{jid}`"
        if evidence:
            line += f" — {evidence}"
        decisions.append(line)
        if verdict == "accept":
            accepts.append(f"- `{jid}`: {evidence or '(accepted)'}")
        elif verdict == "reject":
            rejects.append(f"- `{jid}`: {evidence or '(rejected)'}")

    # Job claims fill gaps when ledger is sparse
    done_jobs: list[str] = []
    open_jobs: list[str] = []
    for j in jobs:
        jid = str(j.get("id") or "?")
        status = str(j.get("status") or "")
        worker = str(j.get("worker") or "")
        title_line = _task_title(str(j.get("task") or ""))
        summary = _claim_summary(j)
        if status in OPEN_STATUSES or status not in DONE_LIKE:
            if status in OPEN_STATUSES:
                open_jobs.append(
                    f"- `{jid}` [{status}] {worker}: {title_line}"
                )
        if status == "done":
            bit = summary or title_line
            done_jobs.append(f"- `{jid}` ({worker}): {bit}")
            if summary and not any(jid in a for a in accepts):
                accepts.append(f"- `{jid}`: {summary}")
            if summary and not any(jid in d for d in decisions):
                decisions.append(f"- **claim** `{jid}` — {summary}")

    last_reply = _snippet_file(session, "last-reply.txt")
    last_sent = _snippet_file(session, "last-sent.txt")
    human_notes: list[str] = []
    if last_sent:
        human_notes.append(f"- Last human send (trunc): {last_sent}")
    if last_reply:
        human_notes.append(f"- Last orch reply (trunc): {last_reply}")
    if rejects:
        human_notes.append("- Recent rejects (revisit only if still open):")
        human_notes.extend(f"  {r}" for r in rejects[:8])

    roster_lines = "\n".join(
        f"- {r['id']} · {r['label']} · {r['type']} · role={r['role']}"
        for r in meta["roster"]
    ) or "- (no roster snapshot)"

    header_title = (title or f"{display} continuity").strip()
    md = f"""# {header_title}

## CONTINUITY RECAP (prior session compressed)

### 1. Date / session identity
- **Date:** {_local_date_line()}
- **Team:** {display}
- **Session:** `{session}`
- **project_root:** `{root}`

### 2. Goals / destination
{brief}

### 3. Decisions & rationale
{chr(10).join(decisions) if decisions else "- (no ledger verdicts or claim summaries yet)"}

### 4. Done (accepted / completed)
{chr(10).join(accepts[:24]) if accepts else (chr(10).join(done_jobs[:16]) if done_jobs else "- (none recorded)")}

### 5. Open / next
{chr(10).join(open_jobs[:20]) if open_jobs else "- (no open jobs in control plane)"}

### 6. Risks / human notes
{chr(10).join(human_notes) if human_notes else "- (none)"}

### Roster snapshot (roles only)
{roster_lines}

---
Continue from here. Do not re-litigate settled accepts unless the human asks.
Mission roles and architecture edges still apply — run `pong gate` / `pong status`.
"""
    return md.strip() + "\n"


def _new_id() -> str:
    ts = time.strftime("%Y%m%d_%H%M%S")
    aid = f"sess_{ts}_{uuid.uuid4().hex[:6]}"
    # Defensive: generator must always satisfy the safe-id grammar
    if safe_archive_id(aid) is None:
        raise RuntimeError(f"generated archive id failed validation: {aid!r}")
    return aid


def save_archive(
    session: str,
    *,
    title: str | None = None,
) -> dict[str, Any]:
    """Write a new archive entry. Does not kill or reset any live team."""
    ensure_layout(session)
    meta_pair = _pair_meta(session)
    display = meta_pair["display_name"]
    aid = _new_id()
    entry_dir = archive_dir(aid)
    if entry_dir is None:
        raise RuntimeError("refusing to write archive outside session-archive root")
    # Empty / whitespace title → always include team display name
    t = (title or "").strip() or default_archive_title(display)
    now = time.time()
    recap = build_recap_markdown(session, title=t)

    jobs = _list_jobs(session)
    open_n = sum(1 for j in jobs if str(j.get("status")) in OPEN_STATUSES)
    done_n = sum(1 for j in jobs if str(j.get("status")) == "done")
    ledger = _ledger_rows(session, limit=200)
    accepts = sum(1 for r in ledger if str(r.get("verdict")) == "accept")
    rejects = sum(1 for r in ledger if str(r.get("verdict")) == "reject")

    entry_dir.mkdir(parents=True, exist_ok=True)
    try:
        entry_dir.chmod(0o700)
    except Exception:
        pass

    meta: dict[str, Any] = {
        "id": aid,
        "title": t,
        "source_session": session,
        "created_at": now,
        "updated_at": now,
        "display_name": display,
        "project_root": meta_pair["project_root"],
        "team_brief": meta_pair["team_brief"],
        "roster": meta_pair["roster"],
        "stats": {
            "jobs_seen": len(jobs),
            "open_jobs": open_n,
            "done_jobs": done_n,
            "ledger_accepts": accepts,
            "ledger_rejects": rejects,
        },
        "last_job_ids": [str(j.get("id")) for j in jobs[:12] if j.get("id")],
    }
    write_json(entry_dir / "meta.json", meta)
    (entry_dir / "recap.md").write_text(recap, encoding="utf-8")

    # Also mirror latest + timestamped under the live session dir
    sess_dir = sessions_dir(session)
    sess_dir.mkdir(parents=True, exist_ok=True)
    latest = sess_dir / "continuity-recap.md"
    latest.write_text(recap, encoding="utf-8")
    stamped = sess_dir / f"continuity-recap-{int(now)}.md"
    stamped.write_text(recap, encoding="utf-8")
    _prune_timestamped(sess_dir)

    return {
        "id": aid,
        "title": t,
        "path": str(entry_dir),
        "recap_path": str(entry_dir / "recap.md"),
        "latest_session_recap": str(latest),
        "meta": meta,
    }


def _prune_timestamped(sess_dir: Path) -> None:
    files = sorted(
        sess_dir.glob("continuity-recap-*.md"),
        key=lambda p: p.stat().st_mtime,
        reverse=True,
    )
    for old in files[KEEP_TIMESTAMPED:]:
        try:
            old.unlink()
        except OSError:
            pass


def list_archives(
    *,
    source_session: str | None = None,
    display_name: str | None = None,
) -> list[dict[str, Any]]:
    """List archives, newest first.

    Optional team scope (see :func:`archive_matches_team`):
      - ``source_session``: filter by ``meta.source_session`` (pair id)
      - ``display_name``: filter by ``meta.display_name`` (case-insensitive)

    When both are set, an archive matches if **either** field matches (OR).
    Default (no filters) returns every team.
    """
    root = archive_root()
    out: list[dict[str, Any]] = []
    if not root.exists():
        return out
    for d in root.iterdir():
        if not d.is_dir():
            continue
        # Only list validated single-segment ids under root
        if safe_archive_id(d.name) is None:
            continue
        if not _is_under_archive_root(d, root.resolve()):
            continue
        meta = read_json(d / "meta.json")
        if not meta or not meta.get("id"):
            continue
        # Prefer directory name as authority if meta id is weird
        mid = safe_archive_id(str(meta.get("id") or "")) or d.name
        meta = dict(meta)
        meta["id"] = mid
        meta["_dir"] = str(d)
        meta["_recap_path"] = str(d / "recap.md")
        if not archive_matches_team(
            meta, source_session=source_session, display_name=display_name
        ):
            continue
        out.append(meta)
    out.sort(key=lambda m: float(m.get("updated_at") or m.get("created_at") or 0), reverse=True)
    return out


def get_archive(archive_id: str) -> dict[str, Any] | None:
    d = archive_dir(archive_id)
    if d is None or not d.is_dir():
        return None
    meta = read_json(d / "meta.json")
    if not meta:
        return None
    meta = dict(meta)
    aid = safe_archive_id(archive_id)
    meta["id"] = aid or meta.get("id")
    meta["_dir"] = str(d)
    meta["_recap_path"] = str(d / "recap.md")
    recap_p = d / "recap.md"
    if recap_p.is_file():
        try:
            meta["recap"] = recap_p.read_text(encoding="utf-8", errors="replace")
        except OSError:
            meta["recap"] = ""
    else:
        meta["recap"] = ""
    return meta


def delete_archive(archive_id: str) -> bool:
    """Delete one archive directory. Never rmtree outside archive_root."""
    import shutil

    d = archive_dir(archive_id)
    if d is None:
        return False
    root = archive_root().resolve()
    # Double-check after resolve — refuse anything that escaped
    if not _is_under_archive_root(d, root):
        return False
    if not d.is_dir():
        return False
    # Never delete the archive root itself
    if d.resolve() == root:
        return False
    shutil.rmtree(d, ignore_errors=True)
    return not d.exists()


def rename_archive(archive_id: str, title: str) -> dict[str, Any] | None:
    meta = get_archive(archive_id)
    if not meta:
        return None
    t = (title or "").strip()
    if not t:
        return meta
    d = archive_dir(archive_id)
    if d is None or not d.is_dir():
        return None
    m = read_json(d / "meta.json") or {}
    m["title"] = t
    m["updated_at"] = time.time()
    write_json(d / "meta.json", m)
    return get_archive(archive_id)


def load_recap_text(archive_id: str) -> str:
    meta = get_archive(archive_id)
    if not meta:
        return ""
    return str(meta.get("recap") or "")
