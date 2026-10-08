"""One append-only log per graph, and a trace that puts one step's whole story in one place.

Why: when a step went wrong in a long run of rounds, finding out why meant stitching
together the graph's history (capped at 400 entries, summaries cut at 240 characters), its notes,
the job files, Jev's ledger (hashes, no graph ids) and whatever was still on a seat's screen. The
log keeps all of it, per graph, uncapped, in the order it happened:

- every history event the engine records (dispatch, claim, verdict, route, retry, timeout, error,
  refusal, attention, gate, pause, stop) with its full summary;
- which seat, runtime, model, job and prompt file each dispatch went to;
- every Jev decision on a step (mode, outcome, probabilities, each rubric line's verdict and P, the
  call ids that join Jev's ledger) and Jev's advice at a gate, never the text Jev read;
- every gate answer with its outcome, its note and who pressed it;
- the architect's side: the events queued for it and delivered to it, and each message a person
  typed into its chat from the app.

``trace`` adds, for each job of a step, the AI's own transcript on this Mac, whichever tool ran it: Claude
Code (``~/.claude/projects/<folder>/``), Grok Build (``~/.grok/sessions/<folder>/``), Codex
(``~/.codex/sessions/<date>/``), Hermes (``~/.hermes/sessions/``). Each holds the job's id because the seat
starts on a pointer to its job file. And whatever ran, the step's whole terminal is saved when it ends
(``save_pane``), into ``panes/`` beside the log.

The log lives beside the graph's notes, ``~/.pong/sessions/<team>/graphs/<id>/log.jsonl``: outside
any project folder, like the notes and the job files, so nothing a step reads ends up in the repo.
"""
from __future__ import annotations

import json
import os
import re
import time
import urllib.parse
from pathlib import Path
from typing import Any

MAX_TEXT = 4000


def path_for(graph: dict[str, Any]) -> Path | None:
    notes = str(graph.get("notes_path") or "")
    return Path(notes).parent / "log.jsonl" if notes else None


def _cap(v: Any) -> Any:
    if isinstance(v, str):
        return v if len(v) <= MAX_TEXT else v[:MAX_TEXT] + f"… (+{len(v) - MAX_TEXT} chars)"
    if isinstance(v, list):
        return [_cap(x) for x in v[:200]]
    if isinstance(v, dict):
        return {str(k): _cap(x) for k, x in list(v.items())[:200]}
    return v


#: Every record of Jev being asked something: a step's grade, route or ranking, a gate's advice, a claim read.
JEV_KINDS = ("jev", "jev_advice", "jev_claim_read")


def append(graph: dict[str, Any], kind: str, **fields: Any) -> None:
    """One line. Best effort: logging never stops a graph."""
    p = path_for(graph)
    if p is None:
        return
    rec = {"t": round(time.time(), 3), "graph": graph.get("id"), "kind": kind}
    rec.update({k: _cap(v) for k, v in fields.items() if v is not None and v != ""})
    try:
        p.parent.mkdir(parents=True, exist_ok=True)
        with p.open("a", encoding="utf-8") as fh:
            fh.write(json.dumps(rec, ensure_ascii=False, default=str) + "\n")
    except OSError:
        pass


def read(session: str, graph_id: str, *, node: str | None = None, kinds: list[str] | None = None,
         tail: int | None = None) -> list[dict[str, Any]]:
    from .paths import sessions_dir

    p = sessions_dir(session) / "graphs" / graph_id / "log.jsonl"
    out: list[dict[str, Any]] = []
    try:
        with p.open(encoding="utf-8") as fh:
            for line in fh:
                try:
                    rec = json.loads(line)
                except ValueError:
                    continue
                if node and rec.get("node") != node and not str(rec.get("node") or "").startswith(node + "#"):
                    continue
                if kinds and rec.get("kind") not in kinds:
                    continue
                out.append(rec)
    except OSError:
        return []
    return out[-tail:] if tail else out


def who() -> str:
    """Who pressed: a seat names itself through PONG_SEAT; the app and a person's terminal do not."""
    seat = (os.environ.get("PONG_SEAT") or "").strip()
    return f"seat {seat}" if seat else "a person (app or terminal)"


# ------------------------------------------------------------------ transcripts ---

def _claude_dir(cwd: str) -> Path:
    base = Path(os.environ.get("PONG_CLAUDE_PROJECTS") or (Path.home() / ".claude" / "projects"))
    return base / re.sub(r"[^A-Za-z0-9]", "-", cwd)


def _grok_dir(cwd: str) -> Path:
    base = Path(os.environ.get("PONG_GROK_SESSIONS") or (Path.home() / ".grok" / "sessions"))
    return base / urllib.parse.quote(cwd, safe="")


def _mentions(path: Path, needle: str) -> bool:
    try:
        with path.open("rb") as fh:
            while chunk := fh.read(1 << 20):
                if needle.encode() in chunk:
                    return True
        return False
    except OSError:
        return False


def _home_store(env: str, *parts: str) -> Path:
    return Path(os.environ.get(env) or Path.home().joinpath(*parts))


def _stores(cwd: str) -> list[tuple[str, Path, str, bool]]:
    """(runtime, folder, file pattern, recursive) for every AI CLI a seat may run, on this Mac.

    Claude Code and Grok Build file sessions under the working folder's name; Codex by date; Hermes
    under its own sessions folder. Each seat starts on a pointer that names its job file, so the job
    id is in the transcript whichever tool wrote it."""
    return [
        ("claude", _claude_dir(cwd), "*.jsonl", False),
        ("grok", _grok_dir(cwd), "*/chat_history.jsonl", False),
        ("codex", _home_store("PONG_CODEX_SESSIONS", ".codex", "sessions"), "rollout-*.jsonl", True),
        ("hermes", _home_store("PONG_HERMES_SESSIONS", ".hermes", "sessions"), "*", True),
    ]


def find_transcripts(job_id: str, cwd: str, *, since: float = 0.0) -> list[dict[str, Any]]:
    """Every AI transcript on this Mac that carries ``job_id`` (Claude, Grok, Codex, Hermes), newest first."""
    if not job_id:
        return []
    found: list[dict[str, Any]] = []
    cutoff = since - 120 if since else 0
    for runtime, folder, pattern, recursive in _stores(cwd):
        if not folder.is_dir() or (runtime in ("claude", "grok") and not cwd):
            continue
        files = folder.rglob(pattern) if recursive else folder.glob(pattern)
        for f in files:
            try:
                st = f.stat()
                if not f.is_file() or st.st_mtime < cutoff or st.st_size > 400 * 1024 * 1024:
                    continue
                if _mentions(f, job_id):
                    found.append({"runtime": runtime, "path": str(f), "modified": st.st_mtime})
            except OSError:
                continue
    found.sort(key=lambda r: -float(r["modified"]))
    return found


def save_pane(session: str, graph: dict[str, Any], node: dict[str, Any], job_id: str) -> str:
    """Keep a step's whole terminal when it ends, whatever AI ran in it: the one record that exists for
    every runtime, including one with no transcript store of its own. Returns the file, or ""."""
    seat = str(node.get("seat") or "")
    p = path_for(graph)
    if not seat or p is None:
        return ""
    try:
        from .groups import _pane_alive, _tmux, pane_owned
        from .routing import load_pane_registration

        pane = str((load_pane_registration(session, seat) or {}).get("pane_id") or "")
        if not pane or not (pane_owned(pane, session, seat) if "." in seat else _pane_alive(pane)):
            return ""
        ok, text = _tmux("capture-pane", "-p", "-J", "-t", pane, "-S", "-")
        if not ok or not text.strip():
            return ""
        out = p.parent / "panes" / f"{node.get('id')}__{job_id or int(time.time())}.txt".replace("/", "_")
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(text, encoding="utf-8")
        append(graph, "pane_saved", node=node.get("id"), seat=seat, job_id=job_id, path=str(out), chars=len(text))
        return str(out)
    except Exception:
        return ""


# ------------------------------------------------------------------ trace ---

def trace(session: str, graph_id: str, node: str | None = None) -> dict[str, Any]:
    """Everything about one step (or every step): its jobs, prompts, claims, Jev lines and transcripts."""
    from .jobs import load_job
    from .state import load_session_state
    from .work_graph import find_graph

    graph = find_graph(session, graph_id)
    if graph is None:
        raise ValueError(f"no graph {graph_id!r} on {session}")
    root = str((load_session_state(session) or {}).get("project_root") or "")
    log = read(session, graph_id)
    nodes = [n for n in graph.get("nodes") or [] if isinstance(n, dict) and (not node or n.get("id") == node)]
    if node and not nodes:
        raise ValueError(f"no step {node!r} in {graph_id}")
    steps = []
    for n in nodes:
        nid = str(n.get("id") or "")
        mine = [r for r in log if r.get("node") == nid]
        job_ids = [r.get("job_id") for r in mine if r.get("kind") == "dispatch" and r.get("job_id")]
        # the graph's own history names every job too (retries included), and it predates the log
        for h in graph.get("history") or []:
            if isinstance(h, dict) and h.get("node") == nid and h.get("job_id") and h["job_id"] not in job_ids:
                job_ids.append(str(h["job_id"]))
        if n.get("job_id") and n["job_id"] not in job_ids:
            job_ids.append(n["job_id"])
        jobs = []
        for jid in job_ids:
            job = load_job(session, jid) or {}
            created = float(job.get("created_at") or 0)
            claim = job.get("claim") if isinstance(job.get("claim"), dict) else {}
            jobs.append({
                "job_id": jid, "status": job.get("status"), "seat": job.get("worker") or n.get("seat"),
                "runtime": job.get("runtime"), "model": job.get("model"), "created_at": created or None,
                "prompt_path": job.get("prompt_path"),
                "claim": {k: claim.get(k) for k in ("summary", "files", "at") if claim.get(k)} or None,
                "transcripts": find_transcripts(jid, str(job.get("project_root") or n.get("cwd") or root), since=created),
                "panes": [r.get("path") for r in mine if r.get("kind") == "pane_saved" and r.get("job_id") == jid],
            })
        steps.append({
            "node": nid, "role": n.get("role"), "status": n.get("status"), "visits": n.get("visits"),
            "seat": n.get("seat"), "last_outcome": n.get("last_outcome"),
            "jev": [r for r in mine if r.get("kind") in JEV_KINDS],
            "events": [r for r in mine if r.get("kind") not in JEV_KINDS],
            "jobs": jobs,
        })
    # the graph's name as the graph list shows it: a name the person or the helper gave it, else its own
    # title (never its template's name first, so two graphs from one template aren't both "write-review")
    from .graph_engine import graph_title

    title = graph_title(graph)
    try:
        from .names import name_for

        title = name_for("graph", session, graph_id) or title
    except Exception:
        pass
    return {"graph": graph_id, "session": session, "title": title,
            "status": graph.get("status"), "stop_reason": graph.get("stop_reason"),
            "log_path": str(path_for(graph) or ""), "notes_path": graph.get("notes_path"),
            "gates": [r for r in log if r.get("kind") == "gate_answer"], "steps": steps}
