#!/usr/bin/env python3
"""pong — Agent mission control CLI."""

from __future__ import annotations

import argparse
import os
import json
import sys
from pathlib import Path

# Allow running from repo without install
_ROOT = Path(__file__).resolve().parents[2]
if str(_ROOT) not in sys.path:
    sys.path.insert(0, str(_ROOT))


def _cmd_status(args: argparse.Namespace) -> int:
    from pong.paths import state_dir
    from pong.state import (
        detect_bound_session,
        format_team_roster,
        gate_text,
        load_session_state,
        write_bind_card,
    )

    sess = detect_bound_session(args.session)
    state = load_session_state(sess)
    g, _ = gate_text(sess)
    print(f"state_dir: {state_dir()}")
    print(f"bound_session: {sess or '(none)'}")
    print(f"gate: {g}")
    if state:
        print(f"roster: {format_team_roster(state)}")
        print(f"transport_default: {state.get('transport_default')}")
        print(f"project_root: {state.get('project_root') or '(unset)'}")
        c = state.get("conductor") or {}
        print(f"conductor: {c.get('label')} ({c.get('type')}) cmd={c.get('cmd')}")
        if sess:
            p = write_bind_card(str(sess))
            print(f"bind_card: {p}")
    return 0


def _cmd_gate(args: argparse.Namespace) -> int:
    from pong.ledger import summary
    from pong.state import (
        detect_bound_session,
        format_team_roster,
        gate_text,
        load_session_state,
    )

    sess = detect_bound_session(args.session)
    state = load_session_state(sess)
    line, code = gate_text(sess)
    print(line)
    if state and workers_ok(state):
        print(f"TEAM: {format_team_roster(state)}", file=sys.stderr)
        try:
            s = summary()
            print(
                f"LEDGER: rounds={s['rounds']} accept_rate={s['accept_rate']:.0%} "
                f"reject_streak={s['reject_streak']}",
                file=sys.stderr,
            )
            if s.get("patterns"):
                print("PATTERNS: (see ~/.pong/ledger/patterns.md)", file=sys.stderr)
        except Exception:
            pass
    return code


def workers_ok(state: dict) -> bool:
    from pong.state import workers_from_state

    return bool(workers_from_state(state))


def _route_err(e: BaseException) -> int:
    from pong.routing import RouteRefused

    if isinstance(e, RouteRefused):
        print(f"error: {e}", file=sys.stderr)
        return int(getattr(e, "exit_code", 2) or 2)
    print(f"error: {e}", file=sys.stderr)
    return 2


def _cmd_job_create(args: argparse.Namespace) -> int:
    from pong.jobs import create_job
    from pong.routing import RouteRefused
    from pong.transports.dispatch import dispatch_job, parse_transport_plan

    task = args.task
    if args.file:
        task = Path(args.file).read_text(encoding="utf-8")
    if not task or not str(task).strip():
        print("error: empty task", file=sys.stderr)
        return 2
    extra: dict = {}
    parent = getattr(args, "parent", None)
    if parent:
        extra["parent_worker"] = parent
        extra["ephemeral_seat"] = True
        extra["kind"] = "subagent"
    if getattr(args, "ephemeral", False):
        extra["ephemeral_seat"] = True
        extra["kind"] = extra.get("kind") or "subagent"
    try:
        job = create_job(
            session=args.session,
            worker_key=args.worker,
            task=task.strip(),
            require_claim=not args.no_claim,
            round_n=args.round,
            extra=extra or None,
        )
    except RouteRefused as e:
        return _route_err(e)
    except Exception as e:
        print(f"error: {e}", file=sys.stderr)
        return 2
    plan = parse_transport_plan(
        str(job["_state"].get("transport_default") or "job+paste"),
        no_paste=args.no_paste,
        headless_only=args.headless,
        paste_only=args.paste_only,
    )
    force_paste = bool(getattr(args, "force_paste", False))
    results = dispatch_job(
        job, job["_worker"], job["_state"], plan=plan, force_paste=force_paste
    )
    print(f"job_id={job['id']}")
    print(f"session={job['session']} worker={job['worker']} status={job['status']}")
    print(f"prompt={job.get('prompt_path')}")
    if job.get("delivery") == "waitroom" or any(
        r.name == "waitroom" and r.ok for r in results
    ):
        print(
            f"(paste deferred — seat {job.get('worker')} busy; "
            f"`pong seat available --seat {job.get('worker')}` or `pong waitroom try-deliver`)"
        )
    for r in results:
        flag = "ok" if r.ok else "FAIL"
        print(f"  transport[{flag}] {r.name}: {r.detail}")
    # Success: notified/done, or job-file-only plan that intentionally stays queued.
    # Failure: paste/headless was attempted and every notify transport failed — do not
    # exit 0 while the conductor believes the worker was pinged (audit SEV-0).
    st = str(job.get("status") or "")
    if st in ("notified", "done"):
        return 0
    notify_results = [r for r in results if r.name != "job_file"]
    if not notify_results:
        # job-file only (--no-paste or transport_default=job)
        return 0 if st == "queued" else 1
    if any(r.ok for r in notify_results):
        return 0
    print(
        "error: job file written but no notify transport succeeded "
        f"(status={st}, error={job.get('error')!r})",
        file=sys.stderr,
    )
    return 2


def _cmd_job_list(args: argparse.Namespace) -> int:
    from pong.jobs import list_jobs
    from pong.routing import resolve_read_session

    sess = resolve_read_session(args.session)
    if not sess:
        print("error: no session", file=sys.stderr)
        return 2
    for j in list_jobs(sess, status=args.status):
        print(
            f"{j.get('id')}\t{j.get('status')}\t{j.get('worker')}\t"
            f"{(j.get('task') or '')[:60].replace(chr(10), ' ')}"
        )
    return 0


def _cmd_job_show(args: argparse.Namespace) -> int:
    from pong.jobs import load_job
    from pong.routing import resolve_read_session

    sess = resolve_read_session(args.session)
    if not sess:
        print("error: no session", file=sys.stderr)
        return 2
    j = load_job(sess, args.job_id)
    if not j:
        print("error: not found", file=sys.stderr)
        return 2
    print(json.dumps(j, indent=2))
    return 0


def _cmd_job_status(args: argparse.Namespace) -> int:
    from pong.jobs import set_status
    from pong.routing import RouteRefused, resolve_write_session

    try:
        sess = resolve_write_session(args.session)
        j = set_status(sess, args.job_id, args.status)
    except RouteRefused as e:
        return _route_err(e)
    except Exception as e:
        print(f"error: {e}", file=sys.stderr)
        return 2
    print(f"{j['id']} → {j['status']}")
    return 0


def _cmd_job_harvest(args: argparse.Namespace) -> int:
    from pong.claim_harvest import harvest_session
    from pong.routing import RouteRefused, resolve_write_session

    try:
        sess = resolve_write_session(getattr(args, "session", None))
        claimed = harvest_session(sess)
    except RouteRefused as e:
        return _route_err(e)
    except Exception as e:
        print(f"error: {e}", file=sys.stderr)
        return 2
    if not claimed:
        print(f"harvest {sess}: nothing to recover")
        return 0
    for j in claimed:
        print(f"harvested {j.get('id')} status={j.get('status')} worker={j.get('worker')}")
    return 0


def _cmd_job_claim(args: argparse.Namespace) -> int:
    from pong.jobs import record_claim
    from pong.routing import RouteRefused, resolve_write_session

    files = [x.strip() for x in (args.files or "").split(",") if x.strip()]
    try:
        sess = resolve_write_session(args.session)
        j = record_claim(
            sess,
            args.job_id,
            files=files,
            commands=args.commands or "",
            summary=args.summary or "",
            raw=args.raw,
            notify_paste=bool(getattr(args, "notify_paste", False)),
        )
    except RouteRefused as e:
        return _route_err(e)
    except Exception as e:
        print(f"error: {e}", file=sys.stderr)
        return 2
    print(f"claimed {j['id']} status={j['status']}")
    if not getattr(args, "notify_paste", False):
        print(
            "(claim queued in waitroom — `pong waitroom list` / `pong waitroom drain`)"
        )
    return 0


def _cmd_claims(args: argparse.Namespace) -> int:
    """Read-only claim board. No paste, no tmux, no pane-idle requirement."""
    from pong.claims import claim_board, format_board
    from pong.routing import resolve_read_session

    sess = resolve_read_session(getattr(args, "session", None))
    if not sess:
        print("error: no session (pass -s/--session)", file=sys.stderr)
        return 2
    board = claim_board(
        sess,
        seat=getattr(args, "seat", None),
        unread_only=bool(getattr(args, "unread", False)),
        limit=getattr(args, "limit", None),
    )
    if getattr(args, "json", False):
        print(json.dumps(board, indent=2, ensure_ascii=False))
        return 0
    for line in format_board(board):
        print(line)
    return 0


def _cmd_traces(args: argparse.Namespace) -> int:
    """Read-only run traces. Reads JSONL from disk; never writes a trace."""
    from pong.traces import (
        find_trace,
        format_index,
        format_trace,
        list_traces,
        read_trace,
    )
    from pong.routing import resolve_read_session

    sess = resolve_read_session(getattr(args, "session", None))
    sub = getattr(args, "traces_cmd", "list")

    if sub == "show":
        job_id = str(getattr(args, "job_id", "") or "")
        hit = find_trace(job_id, sess)
        if not hit:
            where = f" in session {sess}" if sess else ""
            print(f"error: no trace for {job_id}{where}", file=sys.stderr)
            return 2
        found_sess, path = hit
        rows = read_trace(found_sess, job_id)
        if getattr(args, "json", False):
            print(json.dumps(rows, indent=2, ensure_ascii=False))
            return 0
        print(f"# {job_id}  session={found_sess}  runs={len(rows)}")
        print(f"# {path}")
        for line in format_trace(rows):
            print(line)
        return 0

    rows = list_traces(limit=getattr(args, "limit", 20) or 0, session=sess)
    if getattr(args, "json", False):
        print(json.dumps(rows, indent=2, ensure_ascii=False))
        return 0
    for line in format_index(rows):
        print(line)
    return 0


def _resolve_session_arg(args: argparse.Namespace) -> str | None:
    from pong.routing import RouteRefused, resolve_write_session
    from pong.state import detect_bound_session

    try:
        sess = detect_bound_session(getattr(args, "session", None))
        if not sess:
            sess = resolve_write_session(getattr(args, "session", None))
        return sess
    except RouteRefused:
        return detect_bound_session(getattr(args, "session", None))
    except Exception:
        return detect_bound_session(getattr(args, "session", None))


def _cmd_waitroom(args: argparse.Namespace) -> int:
    """Delivery waitroom: list / drain only when seat available (unless --force)."""
    from pong.waitroom import (
        can_deliver,
        format_digest,
        list_items,
        try_deliver,
        waitroom_path,
    )

    sub = getattr(args, "waitroom_cmd", None) or ""
    sess = _resolve_session_arg(args)
    if not sess:
        print("error: no session (pass -s/--session)", file=sys.stderr)
        return 2

    if sub in ("list", "inbox"):
        status = getattr(args, "status", None) or "queued"
        if status == "all":
            status = None
        items = list_items(sess, status=status, to=getattr(args, "to", None))
        if getattr(args, "json", False):
            print(json.dumps(items, indent=2))
            return 0
        if not items:
            print(f"(waitroom empty for {sess}" + (f" status={status}" if status else "") + ")")
            print(f"path: {waitroom_path(sess)}")
            return 0
        print(f"waitroom {sess} · {len(items)} item(s) · {waitroom_path(sess)}")
        for it in items:
            print(
                f"  {it.get('status')}\t{it.get('kind')}\t{it.get('id')}\t"
                f"{it.get('from')}→{it.get('to')}\t{it.get('job_id')}\t"
                f"{it.get('summary')}"
            )
        return 0

    if sub in ("drain", "deliver", "try-deliver", "try_deliver"):
        force = bool(getattr(args, "force", False))
        to = getattr(args, "to", None) or None
        pending = list_items(sess, status="queued", to=to)
        if not pending:
            print(f"(nothing to drain for {sess})")
            return 0
        seats = sorted({str(it.get("to") or "c1") for it in pending})
        # drain/deliver ⇒ human ready to receive → mark available then deliver
        # try-deliver ⇒ only if already available (no auto-interrupt)
        imply = sub in ("drain", "deliver")
        if not force and not imply:
            for seat in seats:
                seat_items = [
                    it for it in pending if str(it.get("to") or "c1") == seat
                ]
                kinds = {str(it.get("kind") or "claim") for it in seat_items}
                preview_kind = "claim" if "claim" in kinds else "job"
                ok, reason = can_deliver(sess, seat, force=False, kind=preview_kind)
                if not ok:
                    print(
                        f"hold {seat}: {reason} "
                        f"(use `pong seat available --seat {seat}` or drain --force)"
                    )
        result = try_deliver(
            sess,
            to=to,
            force=force,
            set_available_first=imply or force,
        )
        for d in result.get("delivered") or []:
            kind = d.get("kind") or "claim"
            print(f"delivered → {d.get('to')} · {kind} · {d.get('count')}")
        for h in result.get("held") or []:
            print(f"held → {h.get('to')} · {h.get('count')} · {h.get('reason')}")
        if result.get("empty"):
            print("(nothing to drain)")
        return 0

    if sub == "show-digest":
        items = list_items(sess, status="queued", to=getattr(args, "to", None))
        claims = [it for it in items if str(it.get("kind") or "claim") == "claim"]
        if not claims:
            print("(no queued claims)")
            return 0
        by: dict[str, list] = {}
        for it in claims:
            by.setdefault(str(it.get("to") or "c1"), []).append(it)
        for seat, group in by.items():
            print(format_digest(group, seat=seat), end="")
        return 0

    print(f"error: unknown waitroom subcommand {sub!r}", file=sys.stderr)
    return 2


def _cmd_brief_send(args: argparse.Namespace) -> int:
    """Sole legitimate inter-team channel — file drop, never auto-pasted."""
    from pong.routing import RouteRefused, brief_send, resolve_write_session

    body = " ".join(args.body or []).strip()
    if args.file:
        body = Path(args.file).read_text(encoding="utf-8")
    if not body.strip():
        print("error: empty brief body", file=sys.stderr)
        return 2
    if not args.to:
        print("error: --to <session> required", file=sys.stderr)
        return 2
    try:
        src = resolve_write_session(args.session)
        path = brief_send(
            source_session=src,
            to_session=args.to.strip(),
            body=body,
            subject=args.subject,
        )
    except RouteRefused as e:
        return _route_err(e)
    except Exception as e:
        print(f"error: {e}", file=sys.stderr)
        return 2
    print(f"brief_sent path={path}")
    print("note: file-based only — target team must pull; never auto-pasted")
    return 0


def _cmd_pane_register(args: argparse.Namespace) -> int:
    from pong.routing import (
        RouteRefused,
        exact_window_title,
        register_worker_pane,
        resolve_write_session,
    )

    try:
        sess = resolve_write_session(args.session)
        if not args.worker or not args.pane_id:
            print("error: --worker and --pane-id required", file=sys.stderr)
            return 2
        title = args.title or exact_window_title(sess, args.worker)
        path = register_worker_pane(
            sess,
            args.worker,
            pane_id=args.pane_id,
            start_command=args.cmd or "",
            title=title,
        )
    except RouteRefused as e:
        return _route_err(e)
    except Exception as e:
        print(f"error: {e}", file=sys.stderr)
        return 2
    print(f"pane_registered session={sess} worker={args.worker} pane_id={args.pane_id}")
    print(f"path={path}")
    return 0


def _cmd_token_ensure(args: argparse.Namespace) -> int:
    """Create/show session token (spawn-time / local admin)."""
    from pong.routing import ensure_session_token, resolve_read_session

    sess = resolve_read_session(args.session)
    if not sess:
        print("error: no session", file=sys.stderr)
        return 2
    tok = ensure_session_token(sess)
    if args.print_token:
        print(tok)
    else:
        print(f"session={sess} token_set=yes (use PONG_TOKEN; file chmod 600)")
    return 0


def _cmd_delegate(args: argparse.Namespace) -> int:
    """Compat: create job + transports (like old pong-delegate)."""
    ns = argparse.Namespace(
        session=args.session,
        worker=args.worker,
        task=" ".join(args.prompt) if args.prompt else "",
        file=args.criteria,
        no_claim=False,
        round=1,
        no_paste=args.no_paste,
        headless=args.headless,
        paste_only=args.paste_only,
    )
    if args.dry_run:
        from pong.state import (
            detect_bound_session,
            format_team_roster,
            load_session_state,
            resolve_worker,
        )

        sess = detect_bound_session(args.session)
        state = load_session_state(sess)
        try:
            w = resolve_worker(state, args.worker)
        except Exception as e:
            print(f"[delegate] {e}", file=sys.stderr)
            return 2
        print(f"bound_session={sess}")
        print(f"roster={format_team_roster(state)}")
        print(f"worker={w.get('id')}={w.get('label')}")
        print("DRY-RUN (no job created)")
        return 0
    if not ns.task and not ns.file:
        print("Usage: pong delegate [--worker w1] 'task…'", file=sys.stderr)
        return 2
    # If criteria file, prepend task
    if args.criteria and ns.task:
        body = Path(args.criteria).read_text(encoding="utf-8")
        ns.task = ns.task + "\n\n" + body
        ns.file = None
    return _cmd_job_create(ns)


def _cmd_subagent(args: argparse.Namespace) -> int:
    from pong.routing import RouteRefused, resolve_read_session, resolve_write_session
    from pong import subagents

    cmd = args.subagent_cmd
    try:
        if cmd == "list":
            sess = resolve_read_session(args.session)
            if not sess:
                print("error: no session", file=sys.stderr)
                return 2
            for r in subagents.load_registry(sess):
                print(
                    f"{r.get('id')}\tparent={r.get('parent_id')}\t"
                    f"{r.get('label')}\t{(r.get('task') or '')[:50]}"
                )
            return 0
        sess = resolve_write_session(args.session)
        if cmd == "up":
            row = subagents.register(
                sess,
                parent_id=args.parent,
                label=args.label or args.task or "Subagent",
                task=args.task or args.label or "",
                sub_id=args.id,
                mission_role=args.role or "coder",
            )
            print(f"subagent_id={row['id']}")
            print(f"session={sess} parent={row['parent_id']} label={row['label']}")
            print("# appears on 3D SUB layer until: pong subagent down", row["id"])
            return 0
        if cmd == "down":
            ok = subagents.unregister(sess, args.id)
            if not ok:
                print(f"error: not found: {args.id}", file=sys.stderr)
                return 2
            print(f"removed {args.id}")
            return 0
    except RouteRefused as e:
        return _route_err(e)
    except Exception as e:
        print(f"error: {e}", file=sys.stderr)
        return 2
    return 2


def _cmd_ledger(args: argparse.Namespace) -> int:
    from pong import ledger

    if args.ledger_cmd == "record":
        try:
            row = ledger.record(
                task_id=args.task_id,
                round_n=args.round,
                verdict=args.verdict,
                evidence=args.evidence or "",
                session=args.session,
                worker=args.worker,
            )
        except Exception as e:
            print(f"error: {e}", file=sys.stderr)
            return 2
        print(json.dumps(row))
        return 0
    if args.ledger_cmd == "summary":
        print(json.dumps(ledger.summary(), indent=2))
        return 0
    if args.ledger_cmd == "distill":
        print(ledger.distill())
        return 0
    return 2


def _cmd_continuity(args: argparse.Namespace) -> int:
    """Session vault: save / list / show / delete / recap / rename."""
    from pong.session_archive import (
        build_recap_markdown,
        delete_archive,
        get_archive,
        list_archives,
        rename_archive,
        save_archive,
    )
    from pong.state import detect_bound_session

    sub = getattr(args, "continuity_cmd", None) or ""
    if sub == "save":
        sess = detect_bound_session(args.session)
        if not sess:
            print("error: no session (pass -s/--session)", file=sys.stderr)
            return 2
        out = save_archive(sess, title=args.title)
        if args.json:
            print(json.dumps(out, indent=2))
        else:
            print(f"saved {out['id']}")
            print(out["recap_path"])
        return 0
    if sub == "list":
        from pong.session_archive import archive_row_label

        # Team scope: global -s/--session filters source_session; --team filters display_name.
        # Default (neither) lists all teams. OR match when both set (see archive_matches_team).
        filter_session = (getattr(args, "session", None) or "").strip() or None
        filter_team = (
            getattr(args, "filter_display_name", None) or ""
        ).strip() or None
        rows = list_archives(
            source_session=filter_session,
            display_name=filter_team,
        )
        if args.json:
            # Picker-sized rows only. Full meta (team_brief, roster, recap)
            # overflows the CyberPong pipe: Pong.sh waitUntilExit() before
            # reading stdout, so a fat list deadlocks the main thread and the
            # app looks like it will not open.
            keep = (
                "id",
                "title",
                "source_session",
                "display_name",
                "project_root",
                "created_at",
                "updated_at",
            )
            clean = [{k: r.get(k) for k in keep if k in r} for r in rows]
            print(json.dumps(clean, separators=(",", ":")))
        else:
            if not rows:
                if filter_session or filter_team:
                    bits = []
                    if filter_team:
                        bits.append(f"team={filter_team!r}")
                    if filter_session:
                        bits.append(f"session={filter_session}")
                    print(f"(no saved sessions for {', '.join(bits)})")
                else:
                    print("(no saved sessions)")
            for r in rows:
                label = archive_row_label(r)
                src = r.get("source_session") or "?"
                team = r.get("display_name") or ""
                team_bit = f"\tteam={team}" if team else ""
                print(f"{r.get('id')}\t{label}\tfrom={src}{team_bit}")
        return 0
    if sub == "show":
        meta = get_archive(args.id)
        if not meta:
            print(f"error: archive not found: {args.id}", file=sys.stderr)
            return 1
        if args.recap_only:
            print(meta.get("recap") or "", end="")
            return 0
        if args.json:
            print(json.dumps({k: v for k, v in meta.items() if not str(k).startswith("_")}, indent=2))
        else:
            print(f"id: {meta.get('id')}")
            print(f"title: {meta.get('title')}")
            print(f"source: {meta.get('source_session')}")
            print(f"display: {meta.get('display_name')}")
            print("--- recap ---")
            print(meta.get("recap") or "")
        return 0
    if sub == "recap":
        sess = detect_bound_session(args.session)
        if not sess:
            print("error: no session (pass -s/--session)", file=sys.stderr)
            return 2
        print(build_recap_markdown(sess, title=args.title), end="")
        return 0
    if sub == "delete":
        ok = delete_archive(args.id)
        if not ok:
            print(f"error: archive not found: {args.id}", file=sys.stderr)
            return 1
        print(f"deleted {args.id}")
        return 0
    if sub == "rename":
        meta = rename_archive(args.id, args.title)
        if not meta:
            print(f"error: archive not found: {args.id}", file=sys.stderr)
            return 1
        if args.json:
            print(json.dumps({k: v for k, v in meta.items() if not str(k).startswith("_")}, indent=2))
        else:
            print(f"renamed {meta.get('id')} → {meta.get('title')}")
        return 0
    print(f"error: unknown continuity subcommand {sub!r}", file=sys.stderr)
    return 2


def _cmd_migrate(args: argparse.Namespace) -> int:
    from pong.paths import migrate_legacy_to_primary, state_dir

    p = migrate_legacy_to_primary(force=args.force)
    print(f"state_dir={p} (was preferring legacy if present)")
    print(f"active={state_dir()}")
    return 0


def _compact_snapshot_for_pipe(snap: dict) -> dict:
    """Small enough that CyberPong's Pong.sh pipe cannot deadlock.

    The app does waitUntilExit() before reading stdout. A compact snapshot
    over ~64 KiB fills the pipe and freezes the window (looks like it
    will not open). File snapshot.json stays the full object.
    """
    import copy

    out = copy.deepcopy(snap)
    out["events_tail"] = (out.get("events_tail") or [])[:8]
    for team in out.get("teams") or []:
        if not isinstance(team, dict):
            continue
        brief = team.get("team_brief")
        if isinstance(brief, str) and len(brief) > 200:
            team["team_brief"] = brief[:200] + "…"
        jobs = team.get("jobs")
        if isinstance(jobs, list) and len(jobs) > 4:
            team["jobs"] = jobs[:4]
        for job in team.get("jobs") or []:
            if not isinstance(job, dict):
                continue
            for key in ("task", "team_brief", "prompt"):
                val = job.get(key)
                if isinstance(val, str) and len(val) > 160:
                    job[key] = val[:160] + "…"
    return out


def _cmd_snapshot(args: argparse.Namespace) -> int:
    from pong.snapshot import build_snapshot, write_snapshot

    snap = build_snapshot(session=args.session, events_n=args.events)
    path = write_snapshot(snap, session=args.session)
    if args.write_only:
        print(path)
        return 0
    if args.json or True:
        # always JSON for machine/UI consumers; pretty by default
        payload = _compact_snapshot_for_pipe(snap) if args.compact else snap
        if args.compact:
            print(json.dumps(payload, separators=(",", ":")))
        else:
            print(json.dumps(payload, indent=2))
    if args.write:
        print(f"# wrote {path}", file=sys.stderr)
    elif not args.session:
        # still refresh snapshot.json for panel file watchers (all-teams only)
        write_snapshot(snap)
    return 0


def _cmd_events(args: argparse.Namespace) -> int:
    from pong import events

    rows = events.tail(args.n, session=args.session)
    if args.json:
        print(json.dumps(rows, indent=2))
        return 0
    for r in rows:
        print(f"{r.get('ts')}\t{r.get('type')}\t{r.get('session', '')}\t{json.dumps({k:v for k,v in r.items() if k not in ('ts','type','session')})}")
    return 0


def _cmd_check(args: argparse.Namespace) -> int:
    """Foundation self-check for UI readiness."""
    from pong import __version__
    from pong.schema import CONTRACT_VERSION, SCHEMA_VERSION
    from pong.snapshot import build_snapshot
    from pong.paths import state_dir

    snap = build_snapshot(session=args.session)
    problems: list[str] = []
    if snap.get("contract_version") != CONTRACT_VERSION:
        problems.append("contract_version mismatch")
    if "teams" not in snap or not isinstance(snap["teams"], list):
        problems.append("snapshot.teams missing")
    if "ledger" not in snap:
        problems.append("snapshot.ledger missing")
    for t in snap.get("teams") or []:
        if "conductor" not in t or "workers" not in t or "jobs" not in t:
            problems.append(f"team {t.get('session')} incomplete")
    print(f"pong_version={__version__}")
    print(f"schema_version={SCHEMA_VERSION} contract_version={CONTRACT_VERSION}")
    print(f"state_dir={state_dir()}")
    print(f"teams={len(snap.get('teams') or [])} bridge_on={snap.get('bridge_on')}")
    # The panel runs the checkout; every seat's `pong` runs ~/.pong/lib. Drift
    # between them is invisible from the only window anyone watches.
    try:
        from pong.install import format_status
        from pong.install import status as install_status

        lib = install_status()
        for line in format_status(lib):
            print(line)
        if not lib["ok"]:
            problems.append("installed control plane is stale")
    except Exception as e:
        print(f"WARN: install status unavailable: {e}")
    if problems:
        print("FAIL: " + "; ".join(problems))
        return 1
    print("OK foundation ready for UI consumers")
    return 0


def _cmd_architecture(args: argparse.Namespace) -> int:
    """Architecture helpers (recap for a seat)."""
    from pong.flow import effective_edges
    from pong.handoff_recap import architecture_recap_for_seat
    from pong.state import detect_bound_session, load_session_state

    if args.architecture_cmd != "recap":
        print("error: unknown architecture subcommand", file=sys.stderr)
        return 2
    sess = detect_bound_session(args.session)
    if not sess:
        print("error: no session (pass -s / --session)", file=sys.stderr)
        return 2
    state = load_session_state(sess)
    seat = (args.seat or "").strip()
    if not seat:
        print("error: --seat required (e.g. w1, c1)", file=sys.stderr)
        return 2
    if args.json:
        edges = effective_edges(state)
        print(
            json.dumps(
                {
                    "session": sess,
                    "seat": seat,
                    "edges": edges,
                    "recap": architecture_recap_for_seat(state, seat),
                },
                indent=2,
            )
        )
        return 0
    text = architecture_recap_for_seat(state, seat)
    sys.stdout.write(text)
    return 0


def _cmd_review(args: argparse.Namespace) -> int:
    """Set up a review bar by interview, rather than by handing over a schema."""
    from pong.review_bar import load_bars, seats_covered_by
    from pong.review_init import run_init
    from pong.state import load_session_state

    sess = _resolve_session_arg(args)
    if not sess:
        print("error: no session (pass -s/--session)", file=sys.stderr)
        return 2
    state = load_session_state(sess)
    sub = getattr(args, "review_cmd", None) or ""

    if sub == "list":
        for bid, bar in sorted(load_bars(str(state.get("project_root") or "")).items()):
            seats = ", ".join((bar.get("scope") or {}).get("seats") or []) or "(by role)"
            revs = ", ".join((bar.get("scope") or {}).get("reviewer_seats") or []) or "(by role)"
            print(f"{bid:<10} {bar.get('title', ''):<22} builders: {seats:<16} held by: {revs}")
        return 0

    if sub == "create":
        # Non-interactive twin of `init`, for CyberPong's form. Same builder and
        # the same refusals — the GUI asks the questions, this still decides what
        # a bar is.
        import json as _json

        from pong.review_init import run_answers

        try:
            raw = (
                Path(args.answers).read_text(encoding="utf-8")
                if args.answers and args.answers != "-"
                else sys.stdin.read()
            )
            res = run_answers(_json.loads(raw), state)
        except Exception as e:
            print(f"refused: {e}", file=sys.stderr)
            return 1
        print(_json.dumps({
            "bar_path": res["bar_path"],
            "references_dir": res["references_dir"],
            "stubs": res["stubs"],
            # Which already-scored anchors were carried into an override rather
            # than replaced by a blank stub. Silence here would look identical to
            # having quietly wiped them.
            "carried": res.get("carried") or [],
            "scope": res["scope"],
            "covers": (res["bar"].get("scope") or {}).get("seats") or [],
            "held_by": (res["bar"].get("scope") or {}).get("reviewer_seats") or [],
        }, indent=2))
        return 0

    if sub != "init":
        print(f"error: unknown review command {sub!r}", file=sys.stderr)
        return 2

    # An interview that cannot ask has nothing to write. Failing here beats
    # writing a bar full of defaults nobody chose.
    if not sys.stdin.isatty():
        print(
            "error: `pong review init` is an interview and needs a terminal.\n"
            "Run it in a shell you can type into.",
            file=sys.stderr,
        )
        return 2

    def ask(prompt: str, default: str = "") -> str:
        suffix = f" [{default}]" if default else ""
        print(f"\n{prompt}{suffix}")
        try:
            got = input("> ").strip()
        except EOFError:
            return default
        return got or default

    print("Setting up a review bar. Nine questions; the answers are the bar.")
    try:
        res = run_init(ask, state)
    except (ValueError, KeyboardInterrupt) as e:
        # Refusals here are deliberate — no anchor, nobody holding it, or a seat
        # grading itself. Each makes the bar worse than not having one.
        print(f"\nrefused: {e or 'cancelled'}", file=sys.stderr)
        return 1

    bar = res["bar"]
    covered = (bar.get("scope") or {}).get("seats") or []
    held = (bar.get("scope") or {}).get("reviewer_seats") or []
    print(f"\nWrote {res['bar_path']}  ({res['scope']} scope)")
    print(f"References live in {res['references_dir']}")
    for s in res["stubs"]:
        print(f"  stub: {s}")
    print(f"\nCovers: {', '.join(covered)}")
    print(f"Held by: {', '.join(held)}")
    try:
        print(f"Cross-check — {held[0]} now covers: {', '.join(seats_covered_by(state, held[0]))}")
    except Exception:
        pass
    print("\nThe next job to any covered seat carries this bar in its acceptance block.")
    return 0


def _cmd_group(args: argparse.Namespace) -> int:
    """Coding groups: spawn a group's seats, or start a new project on one."""
    import json as _json

    from pong.groups import list_groups, new_project, spawn_group
    from pong.state import load_session_state

    sess = _resolve_session_arg(args)
    if not sess:
        print("error: no session (pass -s/--session)", file=sys.stderr)
        return 2
    state = load_session_state(sess)
    sub = getattr(args, "group_cmd", None) or ""

    if sub == "list":
        rows = list_groups(state)
        if getattr(args, "json", False):
            print(_json.dumps(rows, indent=2))
            return 0
        for r in rows:
            flag = "  (protected)" if r["protected"] else ""
            print(f"{r['lead']:<5} {r['label']:<26} {' '.join(r['seats'])}{flag}")
        return 0

    try:
        if sub == "spawn":
            res = spawn_group(state, args.lead)
        elif sub == "new-project":
            res = new_project(
                state, args.lead, title=args.title, dry_run=args.dry_run
            )
        else:
            print(f"error: unknown group command {sub!r}", file=sys.stderr)
            return 2
    except Exception as e:
        # Refusals here are deliberate (not a lead, protected seat, no recap).
        # They must read as a decision, not as a crash.
        print(f"refused: {e}", file=sys.stderr)
        return 1

    if getattr(args, "json", False):
        print(_json.dumps(res, indent=2))
        return 0
    for k, v in res.items():
        if isinstance(v, list):
            print(f"{k}:")
            for item in v:
                print(f"  {item}")
        else:
            print(f"{k}: {v}")
    return 0


def _cmd_seat(args: argparse.Namespace) -> int:
    """Seat helpers: brief (identity) + busy/available delivery protocol."""
    from pong.state import detect_bound_session, load_session_state

    sub = getattr(args, "seat_cmd", None) or ""

    # —— busy / available / status (delivery waitroom) ——
    if sub in ("status", "busy", "available"):
        from pong.seat_status import (
            all_statuses,
            seat_status_path,
            set_available,
            set_busy,
        )
        from pong.waitroom import try_deliver

        sess = _resolve_session_arg(args)
        if not sess:
            print("error: no session (pass -s/--session)", file=sys.stderr)
            return 2
        if sub == "status":
            rows = all_statuses(sess)
            if getattr(args, "json", False):
                print(json.dumps(rows, indent=2))
                return 0
            print(f"seat status · {sess} · {seat_status_path(sess)}")
            for sid, row in rows.items():
                q = int(row.get("queue_depth") or 0)
                free = row.get("free_in_sec")
                free_s = f" free_in={free:.0f}s" if free is not None else ""
                q_s = f" queue={q}" if q else ""
                print(
                    f"  {sid}\t{row.get('state')}\t{row.get('reason')}"
                    f"\tjob={row.get('job_id') or '-'}{q_s}{free_s}"
                )
            return 0
        seat = (getattr(args, "seat", None) or "").strip()
        if not seat:
            print("error: --seat required", file=sys.stderr)
            return 2
        if sub == "busy":
            row = set_busy(
                sess,
                seat,
                reason=getattr(args, "reason", None) or "manual",
                job_id=getattr(args, "job_id", None),
            )
            print(
                f"busy {seat} reason={row.get('reason')} job={row.get('job_id') or '-'}"
            )
            return 0
        # available
        row = set_available(
            sess,
            seat,
            reason=getattr(args, "reason", None) or "manual",
        )
        print(f"available {seat} reason={row.get('reason')}")
        result = try_deliver(sess, to=seat, force=False)
        for d in result.get("delivered") or []:
            print(f"delivered → {d.get('to')} · {d.get('kind')} · {d.get('count')}")
        for h in result.get("held") or []:
            print(f"held → {h.get('to')} · {h.get('reason')}")
        return 0

    # —— brief (identity + architecture road) ——
    if sub != "brief":
        print(f"error: unknown seat subcommand {sub!r}", file=sys.stderr)
        return 2
    from pong.role_identity import (
        format_architecture_guardrails,
        format_seat_identity,
        seat_mission_role,
    )

    sess = detect_bound_session(args.session)
    if not sess:
        print("error: no session (pass -s / --session)", file=sys.stderr)
        return 2
    state = load_session_state(sess)
    seat = (args.seat or "").strip()
    if not seat:
        print("error: --seat required (e.g. w1, c1)", file=sys.stderr)
        return 2
    if args.json:
        print(
            json.dumps(
                {
                    "session": sess,
                    "seat": seat,
                    "mission_role": seat_mission_role(state, seat),
                    "identity": format_seat_identity(state, seat),
                    "architecture": format_architecture_guardrails(state, seat),
                },
                indent=2,
            )
        )
        return 0
    sys.stdout.write(format_seat_identity(state, seat))
    sys.stdout.write("\n")
    sys.stdout.write(format_architecture_guardrails(state, seat))
    return 0


def _examples_from_args(args: argparse.Namespace) -> list:
    """Both spellings, one shape.

    `--examples a,b` is one comma list and `--example URL` is repeatable;
    `normalize_selected` already accepts a comma string or a list and dedups by
    URL, so the two are merged and handed to it rather than each growing its
    own parsing.
    """
    from pong.examples import normalize_selected

    raw: list = []
    listed = (getattr(args, "examples", None) or "").strip()
    if listed:
        raw.extend(p.strip() for p in listed.split(",") if p.strip())
    raw.extend(getattr(args, "example", None) or [])
    return normalize_selected(raw)


def _cmd_examples(args: argparse.Namespace) -> int:
    """Search the live web for candidate bar references.

    Read-only and it publishes nothing: it fetches public search results so a
    human can pick a comparison set. A person still chooses which rows become
    the bar — this only proposes.
    """
    from pong.examples import ExampleError, search

    sub = getattr(args, "examples_cmd", None)
    if sub != "search":
        print(f"error: unknown examples subcommand {sub!r}", file=sys.stderr)
        return 2
    query = " ".join(getattr(args, "query", None) or []).strip()
    if not query:
        print("error: say what to search for", file=sys.stderr)
        return 2
    try:
        rows = search(query, limit=int(getattr(args, "limit", 8) or 8))
    except ExampleError as e:
        print(f"error: {e}", file=sys.stderr)
        return 2
    except Exception as e:
        # The network is the usual failure here and it is not a crash. Say so
        # on stderr and return empty, so --json still emits parseable JSON and
        # a caller parsing stdout is never handed a traceback.
        print(f"error: search could not reach the network: {e}", file=sys.stderr)
        if getattr(args, "json", False):
            print("[]")
        return 2
    if getattr(args, "json", False):
        # Clean JSON on stdout and nothing else — the island parses this.
        print(json.dumps(rows, indent=2, ensure_ascii=False))
        return 0
    if not rows:
        print("no results")
        return 0
    for r in rows:
        print(f"{r.get('kind','page'):<8} {r.get('title','')}")
        print(f"         {r.get('url','')}")
    return 0


def _cmd_goal(args: argparse.Namespace) -> int:
    """Start, cancel or read a disposable work-graph loop under a main.

    The org graph is not touched by any of these — a loop is ephemeral
    structure layered over a fixed roster, never an edit to it.
    """
    import os as _os

    from pong.routing import RouteRefused
    from pong.work_graph import WorkGraphError, cancel, delete, find_graph, load, pause, resume, start, tick

    sub = getattr(args, "goal_cmd", None) or "status"
    sess = _resolve_session_arg(args)
    if not sess:
        print("error: no session (pass -s/--session)", file=sys.stderr)
        return 2

    if sub == "start":
        # The GUI and a bare `pong -s SESSION goal start` have no PONG_SESSION
        # exported, and create_job's write gate compares caller to target. Bind
        # it here or every loop job is refused as a cross-team write.
        if not (_os.environ.get("PONG_SESSION") or "").strip():
            _os.environ["PONG_SESSION"] = sess
        try:
            graph = start(
                sess,
                owner=getattr(args, "owner"),
                loop=getattr(args, "loop"),
                task=getattr(args, "task") or "",
                bar=getattr(args, "bar", None),
                fan_n=int(getattr(args, "pieces", 2) or 2),
                max_rounds=getattr(args, "max_rounds", None),
                participants=getattr(args, "with_seats", None),
                examples=_examples_from_args(args),
                boundaries={
                    "client_facing": bool(getattr(args, "client_facing", False)),
                    "agency": getattr(args, "agency", None) or "gated",
                    "pause_on": getattr(args, "pause_on", None) or "win",
                    "efficiency": getattr(args, "efficiency", None) or "balanced",
                    "allowed": [x.strip() for x in str(getattr(args, "allow", "") or "").split(",") if x.strip()],
                },
                pins=_pins_from_args(args),
            )
        except (WorkGraphError, ValueError, RouteRefused) as e:
            print(f"error: {e}", file=sys.stderr)
            return 2
        if getattr(args, "json", False):
            public = {k: v for k, v in graph.items() if not str(k).startswith("_")}
            print(json.dumps(public, indent=2, default=str))
            return 0
        parts = ",".join(graph.get("participants") or [graph.get("owner") or ""])
        print(
            f"goal {graph['id']} kind={graph['kind']} owner={graph['owner']} "
            f"participants={parts} status={graph['status']}"
        )
        wiring = graph.get("wiring") or {}
        for n in graph.get("nodes") or []:
            print(
                f"  node {n.get('id')} seat={n.get('seat')} "
                f"job={n.get('job_id') or '-'} status={n.get('status')}"
            )
            w = wiring.get(str(n.get("id") or "")) or {}
            if w.get("runtime"):
                print(f"       runs on {w.get('runtime')} · {w.get('model') or '-'} — {w.get('why') or ''}")
        return 0

    if sub in ("cancel", "delete", "tick", "resume", "pause") and not (_os.environ.get("PONG_SESSION") or "").strip():
        # A person's terminal has no team bound; the next job a resume files is
        # attributed to the team named with -s, as `goal start` already does.
        _os.environ["PONG_SESSION"] = sess

    if sub == "cancel":
        try:
            graph = cancel(sess, getattr(args, "id", None) or "")
        except (WorkGraphError, ValueError) as e:
            print(f"error: {e}", file=sys.stderr)
            return 2
        print(f"cancelled {graph['id']} status={graph.get('status')}")
        return 0

    if sub == "delete":
        try:
            graph = delete(sess, getattr(args, "id", None) or "")
        except (WorkGraphError, ValueError) as e:
            print(f"error: {e}", file=sys.stderr)
            return 2
        print(f"deleted {graph['id']} (was {graph.get('status')})")
        return 0

    if sub == "tick":
        r = tick(sess, graph_id=getattr(args, "id", None))
        print(json.dumps(r, indent=2, default=str))
        return 0

    if sub in ("resume", "pause"):
        try:
            g = (resume(sess, getattr(args, "id", None) or "", outcome=getattr(args, "outcome", None) or "approved",
                        node=getattr(args, "node", None), note=getattr(args, "note", None) or "",
                        extend=int(getattr(args, "extend", 0) or 0))
                 if sub == "resume" else pause(sess, getattr(args, "id", None) or ""))
        except (WorkGraphError, ValueError) as e:
            print(f"error: {e}", file=sys.stderr)
            return 2
        if sub == "resume":
            did = f" — {g['_did']}" if g.get("_did") else ""
            print(f"resumed {g['id']} round={g.get('round')} status={g.get('status')}"
                  + (f" stop_reason={g.get('stop_reason')}" if g.get("stop_reason") else "") + did)
        else:
            print(f"paused {g['id']} — nothing further is dispatched until `pong goal resume --id {g['id']}`")
        return 0

    if sub == "status":
        gid = getattr(args, "id", None)
        if gid:
            g = find_graph(sess, gid)
            if not g:
                print(f"error: no graph {gid}", file=sys.stderr)
                return 2
            print(json.dumps(g, indent=2, default=str))
            return 0
        print(json.dumps(load(sess), indent=2, default=str))
        return 0

    print(f"error: unknown goal subcommand {sub!r}", file=sys.stderr)
    return 2


def _odds(probs: Any) -> str:
    """Every option's P, most likely first: "approved 0.82, rejected 0.18"."""
    if not isinstance(probs, dict):
        return ""
    rows = sorted(((str(k), float(v)) for k, v in probs.items() if isinstance(v, (int, float))), key=lambda kv: -kv[1])
    return ", ".join(f"{k} {v:.2f}" for k, v in rows)


def _log_line(r: dict[str, Any]) -> str:
    import time as _t

    when = _t.strftime("%m-%d %H:%M:%S", _t.localtime(float(r.get("t") or 0)))
    kind, node = str(r.get("kind") or ""), str(r.get("node") or "")
    skip = {"t", "graph", "kind", "node"}
    if kind == "event":
        head = f"{r.get('event')} {r.get('outcome') or ''}".strip()
        body = str(r.get("summary") or "")
        skip |= {"event", "outcome", "summary"}
    elif kind in ("jev", "jev_advice", "jev_claim_read"):
        head = f"{kind} {r.get('mode') or r.get('kind') or ''} → {r.get('outcome') or r.get('verdict') or r.get('pick') or ''}".strip()
        parts = [f"asked: {str(r['question'])[:160]}"] if r.get("question") else []
        parts += [_odds(r.get("probabilities"))] if r.get("probabilities") else []
        parts += [f"{ln.get('id')} {ln.get('verdict')} P {ln.get('p_meets')}" for ln in (r.get("lines") or [])[:8]]
        body = " · ".join(x for x in parts if x)
        skip |= {"mode", "outcome", "verdict", "lines", "question", "probabilities", "pick", "p"}
    else:
        head, body = kind, ""
    rest = " ".join(f"{k}={v}" for k, v in r.items() if k not in skip and v not in (None, "", [], {}))
    return f"{when}  {node:18} {head}" + (f" · {body[:300]}" if body else "") + (f"  [{rest[:300]}]" if rest else "")


def _print_trace(t: dict[str, Any]) -> None:
    import time as _t

    def ts(x: Any) -> str:
        return _t.strftime("%m-%d %H:%M", _t.localtime(float(x))) if x else "?"

    print(f"{t['graph']} · {t.get('title') or ''} · {t.get('status')} {t.get('stop_reason') or ''}")
    print(f"  log: {t.get('log_path')}\n  notes: {t.get('notes_path')}")
    for g in t.get("gates") or []:
        print(f"  gate {g.get('node')}: {g.get('outcome')} by {g.get('by')} ({ts(g.get('t'))})"
              + (f" — {str(g.get('note'))[:200]}" if g.get("note") else ""))
    for s in t.get("steps") or []:
        print(f"\n{s['node']} ({s.get('role')}) · {s.get('status')} · visits {s.get('visits')} · seat {s.get('seat')}")
        for j in s.get("jev") or []:
            print(f"  jev {ts(j.get('t'))}: {j.get('mode') or j.get('kind')} → {j.get('outcome') or j.get('pick') or ''}"
                  + (f" · calls {j.get('calls') or j.get('call')}" if j.get("calls") or j.get("call") else ""))
            if j.get("question"):
                print(f"    asked: {str(j['question'])[:400]}")
            if j.get("probabilities"):
                print(f"    odds: {_odds(j['probabilities'])}")
            for ln in j.get("lines") or []:
                print(f"    {ln.get('id')}: {ln.get('verdict')} · P meets {ln.get('p_meets')}"
                      + (f" · levels {_odds(ln['probabilities'])}" if ln.get("probabilities") else ""))
                if ln.get("text"):
                    print(f"      asked: {str(ln['text'])[:300]}")
        for job in s.get("jobs") or []:
            print(f"  job {job['job_id']} · {job.get('runtime')} · {job.get('model')} · {job.get('status')} · {ts(job.get('created_at'))}")
            print(f"    prompt: {job.get('prompt_path')}")
            c = job.get("claim") or {}
            if c.get("summary"):
                print(f"    claim: {str(c['summary'])[:240]}")
            for tr in job.get("transcripts") or []:
                print(f"    transcript ({tr['runtime']}): {tr['path']}")
            for pn in job.get("panes") or []:
                print(f"    terminal saved: {pn}")
            if not (job.get("transcripts") or job.get("panes")):
                print("    (no transcript found on this Mac for this job)")


def _cmd_team(args: argparse.Namespace) -> int:
    """A team as a whole (1.9): start a stopped one again under its own name."""
    from pong.composer import ComposeError, start_team

    session = getattr(args, "session", None) or ""
    if not session:
        print("error: which team? -s <team>", file=sys.stderr)
        return 2
    try:
        out = start_team(session)
    except ComposeError as e:
        if getattr(args, "json", False):
            print(json.dumps({"ok": False, "error": str(e)}))
        else:
            print(f"error: {e}", file=sys.stderr)
        return 1
    if getattr(args, "json", False):
        print(json.dumps({"ok": True, **out}, ensure_ascii=False))
    else:
        print(f"started {session}:")
        for line in out["started"]:
            print(f"  {line}")
    return 0


def _cmd_ask(args: argparse.Namespace) -> int:
    """Questions an AI asks the person, shown in the app as the same card a gate gets (1.9)."""
    from pong import asks as Q

    sub = getattr(args, "ask_cmd", None)
    as_json = getattr(args, "json", False)

    def out(obj: Any, text: str) -> int:
        print(json.dumps(obj, ensure_ascii=False, default=str) if as_json else text)
        return 0

    try:
        if sub == "list":
            sess = None if getattr(args, "all", False) else _resolve_session_arg(args)
            rows = Q.list_open(sess)
            if as_json:
                print(json.dumps(rows, ensure_ascii=False, default=str))
                return 0
            if not rows:
                print("no open questions")
            for r in rows:
                opts = " / ".join(o.get("label", "") for o in r.get("options") or []) or "(a note)"
                print(f"{r.get('session'):16} {r.get('id')}  {r.get('question')}  [{opts}]")
            return 0
        sess = _resolve_session_arg(args)
        if not sess:
            print("error: no session (pass -s/--session)", file=sys.stderr)
            return 2
        if sub == "new":
            question = getattr(args, "question", "")
            if question == "-":
                question = sys.stdin.read()
            opts = [Q.parse_option(o) for o in getattr(args, "option", None) or []]
            raw_detail = getattr(args, "detail", None) or []
            files = getattr(args, "file", None) or []
            if len(raw_detail) > 6:
                print(f"warning: {len(raw_detail)} --detail points given; the first 6 are kept", file=sys.stderr)
            detail = [Q.parse_detail(d) for d in raw_detail]
            for p in detail:
                if p.get("file") and not os.path.exists(p["file"]):
                    print(f"warning: {p['file']} does not exist; that point is kept without its file", file=sys.stderr)
            if files and not detail:
                print('hint: add --detail "fact::file::where" points (2-5) so the person can decide without opening '
                      "the file: what exactly is decided, the numbers, what each answer leads to", file=sys.stderr)
            r = Q.new(sess, question, context=getattr(args, "context", None) or [], options=opts,
                      files=files, seat=getattr(args, "seat", "") or "", detail=detail)
            try:
                started = not r.get("detail") and Q.start_explain(sess, r["id"])
            except Exception:  # the question is posted; the points are extra
                started = False
            if started:
                r = Q.get(sess, r["id"])  # the helper AI writes its points in the background
            return out(r, f"asked {r['id']}: the app shows it on Needs you. The answer arrives here as a [CyberPong] line.")
        if sub == "explain":
            r = Q.explain(sess, getattr(args, "id"))
            n = len(r.get("detail") or [])
            return out(r, f"{r['id']}: {n} detail point(s) by {r.get('detail_by')}" if n
                       else f"{r['id']}: no detail written ({r.get('detail_error') or 'nothing to explain'})")
        if sub == "answer":
            r = Q.answer(sess, getattr(args, "id"), choice=str(getattr(args, "choice", "") or ""),
                         note=getattr(args, "note", "") or "")
            return out(r, f"answered {r['id']}: {(r.get('answer') or {}).get('label') or 'with a note'} ({r.get('delivery')})")
        if sub == "withdraw":
            r = Q.withdraw(sess, getattr(args, "id"))
            return out(r, f"{r['id']}: {r.get('status')}")
        if sub == "show":
            r = Q.get(sess, getattr(args, "id"))
            return out(r, _ask_words(r))
    except Q.AskError as e:
        print(f"error: {e}", file=sys.stderr)
        return 2
    print("error: unknown ask subcommand", file=sys.stderr)
    return 2


def _ask_words(r: dict[str, Any]) -> str:
    """``pong ask show``: one question as the person reads it, in plain text (``--json`` for the record)."""
    state = {"open": "waiting for an answer", "answered": "answered", "withdrawn": "taken back"}
    lines = [f"{r.get('id')} · {state.get(str(r.get('status')), str(r.get('status') or ''))} · {r.get('session')}",
             str(r.get("question") or "")]
    lines += [f"  · {c}" for c in r.get("context") or []]
    detail = [p for p in r.get("detail") or [] if isinstance(p, dict) and p.get("text")]
    if detail:
        lines.append(f"What you're deciding (by {r.get('detail_by') or 'the chat'}):")
        for p in detail:
            src = " · ".join(x for x in (str(p.get("file") or ""), str(p.get("where") or "")) if x)
            lines.append(f"  - {p['text']}" + (f"  [{src}]" if src else ""))
    elif r.get("detail_pending"):
        lines.append("(details coming)")
    opts = [o for o in r.get("options") or [] if isinstance(o, dict)]
    if opts:
        lines.append("Answers:")
        lines += [f"  {o.get('key')}. {o.get('label')}" + (f": {o['what']}" if o.get("what") else "") for o in opts]
    else:
        lines.append("Answer with a note.")
    files = [str(f) for f in r.get("files") or []]
    if files:
        lines.append("Files: " + files[0])
        lines += ["       " + f for f in files[1:]]
    ans = r.get("answer") if isinstance(r.get("answer"), dict) else None
    if ans:
        said = f"“{ans['label']}”" if ans.get("label") else "with a note"
        lines.append(f"Answered {said} by {ans.get('by') or 'the person'}" + (f": {ans['note']}" if ans.get("note") else ""))
    elif r.get("status") == "open":
        lines.append(f"To answer: pong -s {r.get('session')} ask answer --id {r.get('id')} "
                     + ("--choice <number> [--note \"…\"]" if opts else "--note \"…\""))
    return "\n".join(lines)


def _cmd_names(args: argparse.Namespace) -> int:
    """Short names for chats and graphs (1.9): fill the missing ones, list them, or set one by hand."""
    from pong import names as N

    sub = getattr(args, "names_cmd", None)
    if sub == "fill":
        r = N.fill(limit=int(getattr(args, "limit", N.PER_FILL) or N.PER_FILL))
        print(f"named {r['named']} of {r['wanted']}")
        return 0
    if sub == "list":
        rows = N.known()
        if getattr(args, "json", False):
            print(json.dumps(rows, ensure_ascii=False, indent=1))
            return 0
        if not rows:
            print("no names yet")
        for k, rec in sorted(rows.items()):
            print(f"{k:44} {rec.get('name') or '(none yet)'}" + ("  (yours)" if rec.get("by") == "person" else ""))
        return 0
    kind = "chat" if getattr(args, "chat", "") else "graph"
    ident = getattr(args, "chat", "") or getattr(args, "graph", "")
    sess = _resolve_session_arg(args)
    if not ident or not sess:
        print("error: name a chat (--chat a_…) or a graph (--graph g_…), and its team (-s pong-team-N)", file=sys.stderr)
        return 2
    if sub == "set":
        try:
            n = N.set_name(kind, sess, ident, getattr(args, "name", ""))
        except ValueError as e:
            print(f"error: {e}", file=sys.stderr)
            return 2
        print(f"{kind} {ident}: {n}")
        return 0
    if sub == "forget":
        print(f"{kind} {ident}: " + ("forgotten; the next fill names it again" if N.forget(kind, sess, ident) else "had no name"))
        return 0
    print("error: unknown names subcommand", file=sys.stderr)
    return 2


def _cmd_architect(args: argparse.Namespace) -> int:
    from pong import architect as A

    sub = getattr(args, "architect_cmd", None)
    as_json = getattr(args, "json", False)

    def out(obj: Any, text: str) -> int:
        print(json.dumps(obj, ensure_ascii=False, default=str) if as_json else text)
        return 0

    try:
        brief = str(getattr(args, "brief", "") or "")
        if brief == "-":
            brief = sys.stdin.read()
        if sub == "new":
            r = A.new(getattr(args, "title"), getattr(args, "project"), runtime=getattr(args, "runtime", None),
                      model=getattr(args, "model", None), brief=brief)
            return out(r, f"architect {r['id']} on {r['session']} (lead seat c1) in {r.get('cwd')} · {r.get('spawn_note')}\n"
                          + (f"{r['choice_note']}\n" if r.get("choice_note") else "")
                          + f"chat: open CyberPong's Graphs page, or `tmux attach -t '={r['session']}:0'`")
        if sub == "start":
            sess = _resolve_session_arg(args)
            if not sess:
                print("error: no session (pass -s/--session)", file=sys.stderr)
                return 2
            r = A.start(sess, getattr(args, "title", "") or "", cwd=getattr(args, "cwd", "") or "",
                        graph_id=getattr(args, "graph", "") or "", runtime=getattr(args, "runtime", None) or None,
                        model=getattr(args, "model", None), brief=brief)
            return out(r, f"architect {r['id']} on {sess} seat {r['seat']} · {r.get('spawn_note')}")
        if sub == "list":
            rows = A.list_all()
            if as_json:
                print(json.dumps(rows, ensure_ascii=False, default=str))
                return 0
            for r in rows:
                print(f"{r['id']}  {r['session']:14} {str(r.get('seat')):9} {'live' if r.get('alive') else 'gone':5} "
                      f"queued {r.get('queued')}  graphs {','.join(r.get('graphs') or []) or '-'}  {r.get('title')}")
            return 0
        arch_id = getattr(args, "id")
        sess = _resolve_session_arg(args) if getattr(args, "session", None) else A.find_session(arch_id)
        if sub == "link":
            return out(A.link(sess, arch_id, getattr(args, "graph")), f"{arch_id} now watches {getattr(args, 'graph')}")
        if sub == "screen":
            r = A.screen(sess, arch_id, lines=int(getattr(args, "lines", 200) or 200))
            return out(r, r.get("text") or r.get("note") or "")
        if sub == "send":
            text = getattr(args, "text")
            if text == "-":
                text = sys.stdin.read()
            ok = A.send(sess, arch_id, text)
            return out({"ok": ok}, "sent" if ok else "not sent: the architect's pane is gone")
        if sub == "note":
            A.note(sess, arch_id, getattr(args, "text"))
            return out({"ok": True}, "logged")
        if sub == "key":
            ok = A.key(sess, arch_id, getattr(args, "key"))
            return out({"ok": ok}, "pressed" if ok else "not pressed: the architect's pane is gone")
        if sub == "events":
            a = A.get(sess, arch_id)
            r = {"queued": a.get("queue") or [], "delivered": (a.get("delivered") or [])[-40:]}
            return out(r, "\n".join([f"queued: {e['text']}" for e in r["queued"]] + [f"delivered: {e['text']}" for e in r["delivered"]]) or "(no events)")
        if sub == "log":
            r = {"chat": A.chat_log(sess, arch_id), "transcripts": A.transcripts(sess, arch_id),
                 "chat_log_path": str(A.chat_log_path(sess, arch_id))}
            lines = [f"{e.get('who')}: {str(e.get('text'))[:300]}" for e in r["chat"]]
            lines += [f"transcript ({t['runtime']}): {t['path']}" for t in r["transcripts"]]
            return out(r, "\n".join(lines) or "(nothing logged yet)")
    except A.ArchitectError as e:
        if as_json and sub in ("new", "start"):  # the New graph sheet shows this sentence as it is
            print(json.dumps({"ok": False, "error": str(e)}, ensure_ascii=False))
            return 0
        print(f"error: {e}", file=sys.stderr)
        return 2
    print(f"error: unknown architect subcommand {sub!r}", file=sys.stderr)
    return 2


def _pins_from_args(args: argparse.Namespace) -> dict[str, str]:
    """``--pin node=platform`` (repeatable) → {node: platform}."""
    out: dict[str, str] = {}
    for raw in getattr(args, "pin", None) or []:
        if "=" in str(raw):
            k, v = str(raw).split("=", 1)
            if k.strip() and v.strip():
                out[k.strip()] = v.strip().lower()
    return out


def _cmd_mailbox(args: argparse.Namespace) -> int:
    from pong import mailbox
    from pong.routing import resolve_read_session

    sess = resolve_read_session(getattr(args, "session", None)) or _resolve_session_arg(args)
    if not sess:
        print("error: no session (pass -s/--session)", file=sys.stderr)
        return 2
    sub = getattr(args, "mailbox_cmd", None) or "peek"
    seat = getattr(args, "seat", None) or ""
    if sub == "post":
        if not seat:
            print("error: --seat required", file=sys.stderr)
            return 2
        item = mailbox.post(
            sess,
            seat,
            kind=getattr(args, "kind", None) or "note",
            from_seat=getattr(args, "from_seat", None) or "",
            job_id=getattr(args, "job_id", None) or "",
            summary=getattr(args, "summary", None) or " ".join(getattr(args, "text", None) or []),
        )
        print(f"posted {item['id']} → {seat}")
        return 0
    if sub == "retry":
        import os as _os2
        from pong.work_graph import WorkGraphError, retry as _retry

        sess = _resolve_session_arg(args)
        if not sess:
            print("error: no session (pass -s/--session)", file=sys.stderr)
            return 2
        if not (_os2.environ.get("PONG_SESSION") or "").strip():
            _os2.environ["PONG_SESSION"] = sess
        try:
            g = _retry(sess, getattr(args, "id"), getattr(args, "node"))
        except (WorkGraphError, ValueError) as e:
            print(f"error: {e}", file=sys.stderr)
            return 2
        print(f"{g['id']}: {g.get('_did')} · status={g.get('status')}")
        return 0
    if sub == "seat-view":
        from pong.graph_engine import seat_view

        sess = _resolve_session_arg(args)
        if not sess:
            print("error: no session (pass -s/--session)", file=sys.stderr)
            return 2
        r = seat_view(sess, getattr(args, "seat"))
        if getattr(args, "json", False):
            print(json.dumps(r, ensure_ascii=False))
        else:
            print(f"tmux attach-session -t '={r['view']}:'" if r.get("ok") else f"error: {r.get('note')}")
        return 0 if r.get("ok") else 1
    if sub == "peek":
        if not seat:
            print("error: --seat required", file=sys.stderr)
            return 2
        items = mailbox.peek(sess, seat, limit=getattr(args, "limit", 50))
        if getattr(args, "json", False):
            print(json.dumps(items, indent=2, ensure_ascii=False))
            return 0
        if not items:
            print(f"(mailbox empty / all acked for {seat})")
            return 0
        print(f"mailbox peek {sess} · {seat} · {len(items)} unread")
        for it in items:
            print(
                f"  {it.get('id')}\t{it.get('kind')}\t{it.get('from')}→{it.get('to')}\t"
                f"{it.get('job_id')}\t{it.get('summary')}"
            )
        return 0
    if sub == "ack":
        if not seat:
            print("error: --seat required", file=sys.stderr)
            return 2
        ids = [x for x in (getattr(args, "ids", None) or []) if x]
        acked = mailbox.ack(sess, seat, ids or None)
        print(f"acked {len(acked)} item(s) for {seat}")
        return 0
    if sub == "list":
        items = mailbox.list_items(
            sess,
            seat or None,
            unread_only=bool(getattr(args, "unread", False)),
        )
        if getattr(args, "json", False):
            print(json.dumps(items, indent=2, ensure_ascii=False))
            return 0
        print(f"mailbox {sess} · {len(items)} item(s)")
        for it in items:
            mark = "unread" if not it.get("acked") else "acked "
            print(
                f"  {mark}\t{it.get('id')}\t{it.get('kind')}\t"
                f"{it.get('from')}→{it.get('to')}\t{it.get('job_id')}\t"
                f"{it.get('summary')}"
            )
        return 0
    print(f"error: unknown mailbox subcommand {sub!r}", file=sys.stderr)
    return 2


def _cmd_drain(args: argparse.Namespace) -> int:
    from pong.drain import run_all, watch

    sess = _resolve_session_arg(args)
    if getattr(args, "watch", False):
        interval = float(getattr(args, "interval", 2.0) or 2.0)
        watch(sess, interval=interval, force=bool(getattr(args, "force", False)))
        return 0
    result = run_all(sess, force=bool(getattr(args, "force", False)))
    if getattr(args, "json", False):
        print(json.dumps(result, indent=2, default=str))
        return 0
    for r in result.get("results") or []:
        print(
            f"drain {r.get('session')}: harvested={len(r.get('harvested') or [])} "
            f"delivered={len((r.get('waitroom') or {}).get('delivered') or [])} "
            f"held={len((r.get('waitroom') or {}).get('held') or [])} "
            f"released={len(r.get('released') or [])} advanced={len(r.get('advanced') or [])}"
        )
    if not result.get("results"):
        print("drain: no sessions")
    return 0


def _cmd_cron(args: argparse.Namespace) -> int:
    from pong import cron
    from pong import runtime as runtime_mod

    sub = getattr(args, "cron_cmd", None) or "status"
    sess = _resolve_session_arg(args)
    if sub == "tick":
        result = cron.tick(sess)
        if getattr(args, "json", False):
            print(json.dumps(result, indent=2, default=str))
            return 0
        print(f"fired={len(result.get('fired') or [])} skipped={len(result.get('skipped') or [])}")
        for f in result.get("fired") or []:
            res = f.get("result") or {}
            gate = " (gated: draft only)" if res.get("gated") else ""
            print(f"  {f.get('session')} {f.get('id')} {f.get('verb')} ok={res.get('ok')}{gate}")
        return 0
    if sub == "status":
        print(json.dumps(cron.status(), indent=2, default=str))
        return 0
    if sub == "run":
        runtime_mod.run(
            session=sess,
            interval=float(getattr(args, "interval", 30) or 30),
            cron=not bool(getattr(args, "no_cron", False)),
        )
        return 0
    if sub == "install-agent":
        return _install_agent(args)
    if sub == "add":
        if not sess:
            print("error: no session (pass -s/--session)", file=sys.stderr)
            return 2
        row = cron.upsert(
            sess,
            name=getattr(args, "name"),
            cadence=getattr(args, "cadence"),
            task=getattr(args, "task") or "",
            owner_id=getattr(args, "owner") or "c1",
            verb=getattr(args, "verb") or "job.create",
        )
        print(f"cron {row['id']} {row['name']} {row['cadence']} verb={row['verb']}")
        return 0
    print(f"error: unknown cron subcommand {sub!r}", file=sys.stderr)
    return 2


def _cmd_runtime(args: argparse.Namespace) -> int:
    from pong import runtime as runtime_mod

    sub = getattr(args, "runtime_cmd", None) or "status"
    if sub == "run":
        # No -s means every team. Resolving the bound pair here (as other
        # commands do) left the launchd runner draining one team: graphs under
        # every other team never advanced (2026-09-24).
        runtime_mod.run(
            session=(getattr(args, "session", None) or None),
            interval=float(getattr(args, "interval", 30) or 30),
            cron=not bool(getattr(args, "no_cron", False)),
        )
        return 0
    if sub == "status":
        print(json.dumps(runtime_mod.status(), indent=2, default=str))
        return 0
    if sub == "install-agent":
        return _install_agent(args)
    print(f"error: unknown runtime subcommand {sub!r}", file=sys.stderr)
    return 2


def _install_agent(args: argparse.Namespace) -> int:
    """Write and load ~/Library/LaunchAgents/com.cyberpong.runtime.plist from the installed engine."""
    from pong import runtime as runtime_mod

    r = runtime_mod.install_agent()
    if getattr(args, "json", False):  # the answer is in the JSON
        print(json.dumps(r, ensure_ascii=False))
        return 0
    if r.get("ok"):
        print(f"installed {r['plist']} and loaded it (python={r.get('python')})")
    else:
        print(f"error: {r.get('error') or 'the runner could not be loaded'} ({r['plist']})", file=sys.stderr)
    return 0 if r.get("ok") else 1


def _cmd_doctor(args: argparse.Namespace) -> int:
    """``pong doctor``: is this Mac ready? Read-only; no tokens; never a key."""
    from pong import doctor

    d = doctor.check()
    if getattr(args, "json", False):
        print(json.dumps(d, ensure_ascii=False, default=str))
        return 0
    print("\n".join(doctor.format_text(d)))
    return 0 if doctor.essentials_ok(d) else 1


def _read_secret() -> str:
    """A key from stdin, never from argv (argv shows in `ps`). A terminal gets a prompt that does not echo."""
    if sys.stdin is None:
        return ""
    if sys.stdin.isatty():
        import getpass

        return getpass.getpass("Paste the key (it is not shown): ")
    data = sys.stdin.read(8192)
    return next((ln.strip() for ln in data.splitlines() if ln.strip()), "")


def _key_set(name: str, as_json: bool) -> int:
    from pong import settings as S

    if (os.environ.get("PONG_SEAT") or "").strip():
        print("error: keys are set by people in Settings, not by seats", file=sys.stderr)
        return 2
    value = _read_secret()
    try:
        S.write_key(name, value)
    except ValueError as e:
        print(f"error: {e}", file=sys.stderr)  # the message never contains the key
        return 2
    finally:
        value = ""
    label = "Jev" if name == "jev" else "Perplexity"
    print(json.dumps({"ok": True, "name": name}) if as_json else f"{label} key saved in Settings (it is not shown).")
    return 0


def _key_clear(name: str, as_json: bool) -> int:
    from pong import settings as S

    if (os.environ.get("PONG_SEAT") or "").strip():
        print("error: keys are removed by people in Settings, not by seats", file=sys.stderr)
        return 2
    had = S.clear_key(name)
    label = "Jev" if name == "jev" else "Perplexity"
    if as_json:
        print(json.dumps({"ok": True, "name": name, "removed": had}))
        return 0
    print(f"{label} key removed from Settings." if had else f"Settings held no {label} key.")
    # Remove takes only what Settings saved: say so when a key from somewhere else is still in use
    left = S.keys_status().get(name) or {}
    if left.get("set"):
        print(f"A {label} key is still used {_KEY_SOURCE_WORDS.get(left.get('source'), 'from elsewhere')}: "
              f"Remove can't take that one away. Switch {label} off in Settings › Limits & keys to stop using it.")
    return 0


_KEY_SOURCE_WORDS = {"settings": "from Settings", "environment": "from the environment",
                     "key_file": "from jev.json's key file",
                     "claude_connector": "from Claude Code's Perplexity connector"}


def _cmd_keys(args: argparse.Namespace) -> int:
    """``pong keys``: set or not and where from, never the key, a prefix or a length."""
    from pong import settings as S

    sub = getattr(args, "keys_cmd", None) or "status"
    as_json = bool(getattr(args, "json", False))
    if sub == "set":
        return _key_set(str(getattr(args, "name")), as_json)
    if sub == "clear":
        return _key_clear(str(getattr(args, "name")), as_json)
    st = S.keys_status()
    if as_json:
        print(json.dumps(st))
        return 0
    from pong.doctor import key_words

    for k, label in (("jev", "Jev"), ("perplexity", "Perplexity")):
        print(key_words(label, st[k]))
    return 0


def _cmd_limits(args: argparse.Namespace) -> int:
    """``pong limits``: what the runner holds for Claude's usage limits, and Resume."""
    from pong import limits as L

    sub = getattr(args, "limits_cmd", None) or "status"
    as_json = bool(getattr(args, "json", False))
    if sub == "resume":
        if (os.environ.get("PONG_SEAT") or "").strip():
            # going on past a limit the person set is their call ("Resume anyway"), never an AI's
            print("error: pong limits resume is the person's button, not a seat's", file=sys.stderr)
            return 2
        r = L.resume_now()
        if as_json:
            print(json.dumps(r, ensure_ascii=False))
        elif not r.get("was"):
            print(r.get("note") or "Nothing was paused for a limit.")
        else:
            print(f"Resumed: {', '.join(r['resumed']) or 'nothing was still paused'}.")
            if r.get("note"):
                print(r["note"])
        return 0
    st = L.status()
    if as_json:
        print(json.dumps(st, ensure_ascii=False, default=str))
        return 0
    words = {"ok": "No graph is held for a limit.", "paused_5h": "Graphs are paused for Claude's 5-hour limit.",
             "paused_week": "Graphs are paused near Claude's weekly limit."}
    print(st.get("note") or words.get(st["state"], st["state"]))
    u = st.get("usage") or {}
    if u:
        import datetime as _dt

        when = _dt.datetime.fromtimestamp(float(u.get("read_at") or 0)).strftime("%H:%M")
        print(f"Claude use (read at {when}): this session {u.get('session_pct')}%, this week {u.get('week_pct')}%"
              + (f", Fable this week {u.get('fable_pct')}%" if u.get("fable_pct") is not None else ""))
    if st.get("usage_note"):
        print(st["usage_note"])
    if st.get("credits"):
        print(f"Claude's usage credits are {st['credits']} (change them in your Claude account: https://claude.ai/settings/usage)")
    cfg = st["settings"]
    if st.get("claude_on") is False:
        print("Claude is switched off in Settings, so its limits are not watched and no graph is paused for them.")
        return 0
    print(f"Switches: pause at the 5-hour limit {'on' if cfg['ride_out_5h'] else 'off'} · "
          f"weekly stop {str(cfg['week_stop_pct']) + '%' if cfg['week_stop_pct'] else 'off'}")
    return 0


def _cmd_model(args: argparse.Namespace) -> int:
    """Show the catalog, or explain one routing decision."""
    from pong import models as M

    session = getattr(args, "session", None)
    sub = getattr(args, "model_cmd", None)

    if sub == "list":
        have = M.available_runtimes(session)
        rows = M.runtimes(session)
        if getattr(args, "json", False):
            print(json.dumps({"available": sorted(have), "runtimes": rows}, indent=2, ensure_ascii=False))
            return 0
        for rid in sorted(rows):
            row = rows[rid]
            mark = "●" if rid in have else "○"
            pool = row.get("pool") or "-"
            print(f"{mark} {rid:8} {str(row.get('label') or ''):16} pool={pool}"
                  f" tools={'yes' if row.get('tools') else 'no'}")
            for mid, m in (row.get("models") or {}).items():
                default = " (default)" if mid == row.get("default_model") else ""
                tier = (m or {}).get("tier") or ""
                print(f"    {mid:16} {tier:9}{default}")
            st = row.get("strengths") or {}
            if st:
                print("    strengths: " + " ".join(f"{k}={v}" for k, v in st.items()))
            if row.get("note"):
                print(f"    note: {row['note']}")
        if not have:
            print("no runtime binaries found on PATH", file=sys.stderr)
        return 0

    if sub == "plan":
        task = " ".join(getattr(args, "task", None) or []).strip()
        loop = (getattr(args, "loop", "") or "").strip().lower()
        if loop:
            from pong.loops import LoopError, load_loop

            try:
                spec = load_loop(loop, session)
            except LoopError as e:
                print(f"error: {e}", file=sys.stderr)
                return 2
            rows = []
            for node in spec.get("nodes") or []:
                if not isinstance(node, dict):
                    continue
                role = str(node.get("role") or node.get("kind") or "")
                p = M.plan(task, role, session=session)
                rows.append({"node": node.get("id"), "role": role, **p.as_dict()})
            if getattr(args, "json", False):
                print(json.dumps(rows, indent=2, ensure_ascii=False))
                return 0
            for r in rows:
                print(f"{r['node']:8} {r['role']:8} {r['runtime']:7} {r['model'] or '-':10} {r['why']}")
            return 0
        role = getattr(args, "role", "") or ""
        if M.normalize_role(role) == "orchestrator":
            # what setup and Settings call "Recommended" for the planning chat: the same answer
            # `architect new` starts with (installed, switched on, able to plan), not a catalog fallback
            from pong.architect import recommended

            d = recommended(task)
            if getattr(args, "json", False):
                print(json.dumps(d, indent=2, ensure_ascii=False))
                return 0
            print(f"runtime : {d.get('runtime') or '-'}")
            print(f"model   : {d.get('model') or '-'}")
            print(f"rule    : {d.get('rule')}")
            print(f"why     : {d.get('why')}")
            return 0
        p = M.plan(task, role, session=session)
        if getattr(args, "json", False):
            print(json.dumps(p.as_dict(), indent=2, ensure_ascii=False))
            return 0
        print(f"runtime : {p.runtime} ({p.label})")
        print(f"model   : {p.model or '-'}")
        print(f"launch  : {p.launch_cmd}")
        print(f"pool    : {p.pool}{'  [shared allowance]' if p.shared_pool else ''}")
        print(f"rule    : {p.rule}")
        print(f"why     : {p.why}")
        print(f"demands : {', '.join(p.demands) or '-'}")
        for s in p.skipped:
            print(f"skipped : {s}")
        return 0

    print(f"error: unknown model subcommand {sub!r}", file=sys.stderr)
    return 2


def _step_name(nid: str) -> str:
    """A step as the app names it: "baseline-review" → "Baseline review", the person's own step ("me") →
    "Your answer" (src/GraphWords.swift, Words.name)."""
    t = nid.strip()
    if not t or "." in t or "/" in t:
        return t
    if t.lower() in ("me", "you", "human", "person", "owner"):
        return "Your answer"
    spaced = t.replace("_", " ").replace("-", " ")
    return spaced[:1].upper() + spaced[1:]


def _graph_show(args: argparse.Namespace) -> int:
    """One graph in words, with the exact command that answers each open gate."""
    import time as _t

    from pong.work_graph import snapshot_block

    sess = _resolve_session_arg(args)
    if not sess:
        print("error: no session (pass -s/--session)", file=sys.stderr)
        return 2
    graphs = [g for g in snapshot_block(sess).get("graphs") or [] if g.get("kind") == "graph"]
    gid = getattr(args, "id", None)
    if gid:
        graphs = [g for g in graphs if g.get("id") == gid]
    else:
        running = [g for g in graphs if g.get("status") == "running"]
        graphs = (running or graphs)[-1:]
    if not graphs:
        print("error: no graph" + (f" {gid}" if gid else " in this session"), file=sys.stderr)
        return 2
    g = graphs[0]
    if getattr(args, "json", False):
        print(json.dumps(g, indent=2, ensure_ascii=False, default=str))
        return 0
    b = g.get("budget") or {}
    print(f"{g.get('id')} · {g.get('title') or ''}")
    print(f"  status {g.get('status')}" + (f" ({g.get('stop_reason')})" if g.get("stop_reason") else "")
          + f" · owner {g.get('owner')}" + ("" if g.get("loops") else f" · round {g.get('round')}/{g.get('max_rounds')}")
          + f" · jobs {b.get('jobs')}"
          + (f"/{b.get('max_jobs')}" if b.get("max_jobs") else "") + f" · {b.get('wall_min')} min"
          + (f"/{b.get('max_wall_min')}" if b.get("max_wall_min") else "")
          + (f" · Jev calls {b.get('jev_calls')}" if b.get("jev_calls") else ""))
    if g.get("manual_pause") and g.get("status") == "running":  # a stopped graph's old pause flag is no news
        why = str(g.get("pause_reason") or "paused by you")
        print(f"  {why} · {g.get('held')} step(s) held — lift with: pong -s {sess} goal resume --id {g.get('id')}")
    for n in g.get("nodes") or []:
        who = f"{n.get('runtime')}·{n.get('model') or '-'}" if n.get("runtime") else ""
        extra = f" last={n.get('last_outcome')}" if n.get("last_outcome") else ""
        print(f"  {str(n.get('id')):14} {str(n.get('role')):10} {str(n.get('status')):14} visits={n.get('visits', 0)}"
              f" seat={n.get('seat')} {who}{extra}")
        for a_ in (n.get("advice_log") or [])[-2:]:
            if a_.get("pick"):
                print(f"    Jev had suggested {a_.get('pick')} (P {float(a_.get('p') or 0):.2f}); you said {a_.get('answer')}")
        j = n.get("jev") or {}
        if j:
            if j.get("attached"):
                print(f"    Jev beside the critic ({(n.get('jev_block') or {}).get('mode') or 'both'}): critic {j.get('critic')},"
                      f" Jev {j.get('jev_verdict')} → {j.get('combined')}")
            elif j.get("mode") in ("decide", "rank"):
                probs = ", ".join(f"{k} {float(v):.2f}" for k, v in sorted((j.get("probabilities") or {}).items(), key=lambda kv: -float(kv[1]))[:4])
                print(f"    Jev {j.get('mode')}: {j.get('outcome')} ({probs})")
            elif not j.get("ok"):
                print(f"    Jev not asked: {j.get('error')}")
            for ln in (j.get("lines") or [])[:6]:
                if ln.get("verdict") != "pass":
                    tag = f"  (advises only: {ln.get('status')})" if ln.get("advisory") else ""
                    print(f"    {ln.get('verdict'):>14}  {ln.get('id')}  P {float(ln.get('p_meets') or 0):.2f}{tag}")
    for e in g.get("edges") or []:
        print(f"    {e.get('from')} → {e.get('to')}  on: {e.get('on')}")
    for L in g.get("loops") or []:
        who = "you decide" if L.get("kind") == "person" else "AIs"
        print(f"  loop {L.get('id'):<12} {who:<10} round {L.get('round')}/{L.get('max_iters')} · {L.get('status')}"
              + (f" · inside {L.get('parent')}" if L.get("parent") else "") + f" · activation {L.get('activation')}")
    many = len(g.get("gates") or []) > 1
    for gate in g.get("gates") or []:
        ask = gate.get("ask") or {}
        step = _step_name(str(gate.get("node") or ""))
        if ask.get("question"):
            # the designer's own question stays as it is: only its details are still coming
            coming = "  (details coming)" if ask.get("own") or ask.get("by") == "the graph's designer" \
                else "  (plain words coming)"
            print("  QUESTION FOR YOU" + (f" ({step})" if many else "") + f": {ask['question']}"
                  + (coming if gate.get("ask_pending") else ""))
            for line in ask.get("context") or []:
                print(f"    · {line}")
            detail = [p for p in ask.get("detail") or [] if isinstance(p, dict) and p.get("text")]
            if detail:
                print(f"    What you're deciding (by {ask.get('detail_by') or 'CyberPong'}):")
                for p in detail:
                    src = " · ".join(x for x in (str(p.get("file") or ""), str(p.get("where") or "")) if x)
                    print(f"      - {p['text']}" + (f"  [{src}]" if src else ""))
            for o, what in (ask.get("choices") or {}).items():
                print(f"    {o}: {what}")
        print(f"  {step}: {gate.get('reason')}")
        if gate.get("summary"):
            print(f"    last step said: {str(gate.get('summary'))[:300]}")
        files = [str(a) for a in gate.get("artifacts") or []]
        if files:
            print(f"    files: {files[0]}")
            for a in files[1:]:
                print(f"           {a}")
        adv = gate.get("advice") or {}
        if adv.get("blind"):
            print("    Jev: hidden on this question until you answer (one question in five)")
        elif adv.get("pick"):
            probs = ", ".join(f"{k} {float(v):.2f}" for k, v in sorted((adv.get("probabilities") or {}).items(), key=lambda kv: -float(kv[1]))[:3])
            print(f"    Jev suggests: {probs}")
        jv = gate.get("jev") or {}
        weak = [ln for ln in (jv.get("lines") or []) if ln.get("verdict") != "pass"]
        if weak:
            from pong.plain_ask import JEV_WORDS, _line_words

        for ln in weak[:4]:  # a point of Jev's check by what it asks, never its id
            print(f"    Jev's check {JEV_WORDS.get(str(ln.get('verdict')), 'is unsure about this')}: "
                  f"{_line_words(ln, 100)}")
        node_flag = f" --node {gate.get('node')}" if many else ""
        for o in gate.get("options") or ["approved", "rejected"]:
            print(f"    {o + ':':9} pong -s {sess} goal resume --id {g.get('id')}{node_flag} --outcome {o}")
    for r in g.get("refusal_items") or []:
        print(f"  refusal at {r.get('node')}: {r.get('reason')}")
    if g.get("last_error"):
        print(f"  last error: {(g.get('last_error') or {}).get('error')}")
    if g.get("notes_path"):
        print(f"  notes: {g.get('notes_path')}")
    return 0


def _cmd_jev(args: argparse.Namespace) -> int:
    """``pong jev``: status, a grade or a decision by hand, and the ledger. Never prints the key."""
    from pong import jev

    sub = getattr(args, "jev_cmd", None) or "status"
    as_json = bool(getattr(args, "json", False))
    if sub in ("grade", "decide", "probe") and (os.environ.get("PONG_SEAT") or "").strip():
        # a builder that can query its grader games it (docs/research/judges-in-graph-loops-2026-09.md §8.5)
        print("error: pong jev grade/decide is for people, not seats — the graph asks Jev itself", file=sys.stderr)
        return 2
    if sub == "key":
        kc = getattr(args, "key_cmd", None) or "test"
        if kc == "set":
            return _key_set("jev", as_json)
        if kc == "clear":
            return _key_clear("jev", as_json)
        r = jev.key_test()
        if as_json:  # the answer is in the JSON; the app reads it whatever it says
            print(json.dumps(r))
            return 0
        else:
            print({"works": "Jev's key works.", "key refused": "Jev refused the key.",
                   "unreachable": "Can't reach Jev right now.", "no key": "No Jev key is set."}[r["result"]]
                  + (f" ({r['ms']} ms)" if r.get("ms") else ""))
        return 0 if r.get("ok") else 1
    if sub == "status":
        st = jev.status()
        cal = jev.calibration()
        if as_json:
            print(json.dumps({**st, "calibration": cal}, indent=2))
            return 0
        if st["source"]:
            print(f"Jev: {'available' if st['available'] else 'switched off'} · model {st['model']} · "
                  f"key {st['key']} ({st['key_shape']})")
        else:  # no key: say so, and where one goes
            note = str(st.get("key_note") or "no Jev key on this Mac")
            print(f"Jev: {note}. Add one in Settings › Limits & keys, or: pong jev key set < file"
                  if note.startswith("no Jev key") else f"Jev: no key ({note})")  # a key file named but empty
        print(f"ledger: {st['ledger']} · {cal.get('calls', 0)} call(s), {cal.get('labels', 0)} label(s)")
        print("client transcript bodies: never sent" + ("" if not st.get("retention_settled") else " (retention marked settled in jev.json)"))
        return 0 if st["available"] else 1
    if sub == "ledger":
        recs = jev.read_ledger()
        cal = jev.calibration(recs)
        answered = {str(r.get("call")) for r in recs if r.get("kind") == "label" and r.get("question") == "answer"}
        calls = [r for r in recs if r.get("kind") == "call"][-max(1, int(getattr(args, "last", 15) or 15)):]
        # a blind gate's advice stays hidden until the person has answered it
        calls = [({**r, "answers": "(hidden until the gate is answered)"} if r.get("purpose") == "gate_advice"
                  and (r.get("meta") or {}).get("blind") and str(r.get("id")) not in answered else r) for r in calls]
        if as_json:
            print(json.dumps({"calibration": cal, "recent": calls}, indent=2, ensure_ascii=False))
            return 0
        import datetime as _dt
        for r in calls:
            when = _dt.datetime.fromtimestamp(float(r.get("at") or 0)).strftime("%m-%d %H:%M")
            meta = r.get("meta") or {}
            where = f"{meta.get('graph', '')} {meta.get('node', '')}".strip()
            head = f"{when}  {str(r.get('purpose') or 'ask'):<12} {('ok' if r.get('ok') else 'NOT ASKED'):<9} {int(r.get('ms') or 0):>5} ms  {where}"
            print(head + (f"  — {r.get('error')}" if r.get("error") else ""))
        print()
        ga, gr = cal.get("gate_advice"), cal.get("grades")
        print(f"gate advice vs your answers: {ga['n']} · Brier {ga['brier']} · pick matched {ga['pick_matched']:.0%}" if ga
              else "gate advice vs your answers: no answered gates yet")
        print(f"grades vs your next gate: {gr['n']} · Brier {gr['brier']}" + (f" · ECE {gr['ece']}" if gr and gr.get('ece') is not None else "")
              if gr else "grades vs your next gate: none yet")
        qrows = cal.get("questions") or []
        if qrows:
            print("\nrubric questions in use (the ones a person overruled most first):")
            for r in qrows[:15]:
                flag = "  ← review this question" if (r.get("overruled") or 0) >= 0.5 and r["failed"] >= 2 else ""
                print(f"  {r['id']:<24} v{r['version'][:6]} graded {r['graded']:>3} · decisive {r['coverage'] or 0:.0%}"
                      f" · failed {r['failed']} (critic said win {r['failed_critic_won']}, you approved {r['failed_person_approved']}){flag}")
        return 0
    def load_rubric_arg(ref: str) -> tuple[Any, str]:
        from pong.graph_engine import _shipped_rubric

        rpath = _shipped_rubric(ref) if str(ref).startswith("@") else os.path.expanduser(ref)
        return json.loads(Path(rpath).read_text(encoding="utf-8")), rpath

    if sub in ("lint", "probe", "questions") and getattr(args, "rubric", None):
        try:
            rubric, rpath = load_rubric_arg(args.rubric)
        except Exception as e:
            print(f"error: cannot read rubric {args.rubric}: {e}", file=sys.stderr)
            return 2
    if sub == "lint":
        from pong.jev_quality import lint_rubric

        r = lint_rubric(rubric, where=rpath)
        if as_json:
            print(json.dumps(r, indent=2, ensure_ascii=False))
        else:
            print(f"{r['questions']} question(s) · {r['errors']} error(s) · {r['warnings']} warning(s) · {rpath}")
            for f in r["findings"]:
                print(f"  {'ERROR' if f['level'] == 'error' else 'warn '} {f['question']:<24} {f['rule']:<22} {f['message']}")
        return 1 if r["errors"] else 0
    if sub == "questions":
        from pong import jev as _jev
        from pong.jev_quality import load_registry, status_of

        reg = load_registry()
        rows = []
        if getattr(args, "rubric", None):
            from pong.jev_quality import question_key

            qs, _meta = _jev.rubric_questions(rubric)
            for k, q in qs.items():
                if k.endswith("_assessable"):
                    continue
                rec = reg.get(question_key(q, _meta.get(k), None)) or {}
                rows.append({"id": k, "status": status_of(q, None, reg, _meta.get(k)),
                             **{x: rec.get(x) for x in ("accuracy", "stability_sd", "injection_shift", "state_blind_leak", "why")}})
        else:
            rows = [{"id": v.get("id"), "status": v.get("status"), "model": v.get("model"),
                     **{x: v.get(x) for x in ("accuracy", "stability_sd", "injection_shift", "state_blind_leak", "why")}}
                    for v in reg.values()]
        if as_json:
            print(json.dumps(rows, indent=2, ensure_ascii=False))
            return 0
        for r_ in rows:
            acc = f"acc {r_['accuracy']:.2f}" if isinstance(r_.get("accuracy"), (int, float)) else ""
            print(f"  {str(r_['status']):<17} {str(r_['id']):<26} {acc:<9} {'; '.join(r_.get('why') or [])[:90]}")
        if not rows:
            print("no question has been probed yet (pong jev probe --rubric …)")
        return 0
    if sub == "probe":
        from pong.jev_quality import probe, record, registry_entries

        cpath = getattr(args, "cases", None) or (rpath[:-5] + ".probes.json" if rpath.endswith(".json") else rpath + ".probes.json")
        try:
            cases = json.loads(Path(os.path.expanduser(cpath)).read_text(encoding="utf-8"))
            cases = cases.get("cases") if isinstance(cases, dict) else cases
        except Exception as e:
            print(f"error: cannot read probe cases {cpath}: {e}", file=sys.stderr)
            return 2
        from pong import jev as _jev

        if not _jev.can_ask():
            print("error: Jev is not available (pong jev status)", file=sys.stderr)
            return 2
        rep = probe(rubric, cases or [], repeats=max(1, int(args.repeats or 1)))
        if not args.no_record:
            record(registry_entries(rep))
        if as_json:
            print(json.dumps(rep, indent=2, ensure_ascii=False))
        else:
            print(f"{len(rep['questions'])} question(s) · {rep['cases']} case(s) × {rep['repeats']} · {rep['calls']} call(s) · {rep['model']}"
                  + ("" if args.no_record else " · recorded"))
            for k, q in rep["questions"].items():
                acc = f"acc {q['accuracy']:.2f}" if q.get("accuracy") is not None else "acc —   "
                print(f"  {q['status']:<17} {k:<26} {acc}  sd {q['stability_sd']:.3f}  blind {q['state_blind_accuracy']:.2f}/{q['chance']:.2f}"
                      f"  inject {q['injection_shift']:+.2f}  {'; '.join(q['why'])[:70]}" + (f"  misses: {', '.join(q['misses'])}" if q.get("misses") else ""))
        ok_statuses = {"gate"} if getattr(args, "require", "gate") == "gate" else {"gate", "ranker"}
        measured = [q for q in rep["questions"].values() if int(q.get("cases") or 0)]
        return 0 if measured and all(q["status"] in ok_statuses for q in measured) else 1
    if sub == "grade":
        try:
            from pong.graph_engine import _shipped_rubric

            rpath = _shipped_rubric(args.rubric) if str(args.rubric).startswith("@") else os.path.expanduser(args.rubric)
            rubric = json.loads(Path(rpath).read_text(encoding="utf-8"))
        except Exception as e:
            print(f"error: cannot read rubric {args.rubric}: {e}", file=sys.stderr)
            return 2
        qs, meta = jev.rubric_questions(rubric)
        problems = jev.validate_questions(qs)
        if problems:
            print("error: " + "; ".join(problems), file=sys.stderr)
            return 2
        docs, withheld = jev.read_documents(list(args.file), root=os.getcwd())
        for w in withheld:
            print(f"withheld {w['file']}: {w['why']}", file=sys.stderr)
        if not docs:
            print("error: nothing Jev may read", file=sys.stderr)
            return 2
        res = jev.ask({"goal": args.goal, "documents": docs}, qs, purpose="grade_by_hand")
        if not res.get("ok"):
            print(f"not asked: {res.get('error')}", file=sys.stderr)
            return 1
        trusted = None
        if getattr(args, "trust", "earned") != "all":
            from pong.jev_quality import trusted_lines

            trusted = trusted_lines(qs, res.get("model"), meta=meta)
        g = jev.grade(res["answers"], qs, meta, floor=args.floor, pass_p=args.pass_p,
                      truncated=any(d.get("truncated") for d in docs), trusted=trusted)
        if as_json:
            print(json.dumps({"call": res["id"], "model": res["model"], "ms": res["ms"], **g}, indent=2, ensure_ascii=False))
            return 0
        print(g["summary"])
        print(f"({res['model']}, {res['ms']} ms, call {res['id']})")
        for ln in sorted([x for x in g["lines"] if x.get("p_meets") is not None or x["verdict"] == "not_assessable"],
                         key=lambda x: -1 if x["verdict"] == "not_assessable" else float(x["p_meets"])):
            mark = {"pass": "ok ", "under": "LOW", "not_assessable": "N/A", "uncertain": " ? "}.get(ln["verdict"], "   ")
            if ln.get("advisory"):
                mark = mark.lower().strip().ljust(3) if mark.strip() else mark
            exp = f"exp {float(ln['expected']):.1f}/{int(ln['levels']) - 1} " if ln.get("expected") is not None else ""
            print(f"  {mark} {ln['id']:<28} {exp}P(meets) {float(ln.get('p_meets') or 0):.2f}")
        return 0 if g["outcome"] == "win" else 1
    if sub == "decide":
        opts: dict[str, str] = {}
        for o in args.option:
            k, _, v = str(o).partition("=")
            if k.strip():
                opts[k.strip()] = v.strip() or k.strip()
        docs, withheld = jev.read_documents(list(args.file), root=os.getcwd()) if args.file else ([], [])
        q = {"route": jev.choice_question(args.question, opts)}
        res = jev.ask({"documents": docs}, q, purpose="decide_by_hand")
        if not res.get("ok"):
            print(f"not asked: {res.get('error')}", file=sys.stderr)
            return 1
        a = res["answers"]["route"]
        outcome, pick, p = jev.decide(a, take=args.take)
        if as_json:
            print(json.dumps({"call": res["id"], "outcome": outcome, "pick": pick, "p": p, "probabilities": a["probabilities"]}, indent=2))
            return 0
        print(f"{'choose ' + str(pick) if outcome.startswith('route:') else 'not sure enough — a person decides'} (P {p:.2f})")
        for k, v in sorted(a["probabilities"].items(), key=lambda kv: -kv[1]):
            print(f"  {k:<20} {v:.3f}")
        return 0
    print(f"error: unknown jev command {sub}", file=sys.stderr)
    return 2


def _cmd_graph(args: argparse.Namespace) -> int:
    """``pong graph new``: a graph from a short interview, refined by the model,
    shown to you, started only when you say so."""
    from pong import composer
    from pong.composer import ComposeError

    sub = getattr(args, "graph_cmd", None) or "new"
    if sub == "questions":
        print(json.dumps(composer.QUESTIONS, indent=2, ensure_ascii=False))
        return 0
    if sub == "attach":
        import os as _os
        from pong.routing import RouteRefused
        from pong.work_graph import WorkGraphError, start

        sess = _resolve_session_arg(args)
        if not sess:
            print("error: no session (pass -s/--session)", file=sys.stderr)
            return 2
        path = Path(getattr(args, "file") or "")
        try:
            topo = json.loads(path.read_text(encoding="utf-8"))
        except Exception as e:
            print(f"error: cannot read topology {path}: {e}", file=sys.stderr)
            return 2
        if not (_os.environ.get("PONG_SESSION") or "").strip():
            _os.environ["PONG_SESSION"] = sess
        try:
            bnd = {"pause_on": "win", "agency": getattr(args, "agency", None) or "gated"}
            if getattr(args, "client_facing", False):
                bnd["client_facing"] = True
            for flag, key in (("max_wall", "max_wall_min"), ("max_jobs", "max_jobs"), ("node_timeout", "node_timeout_min")):
                if getattr(args, flag, None):
                    bnd[key] = getattr(args, flag)
            if getattr(args, "max_rounds", None):
                topo = {**topo, "max_rounds": getattr(args, "max_rounds")}
            graph = start(sess, owner=getattr(args, "owner"), loop="graph", task=getattr(args, "task") or str(topo.get("goal") or topo.get("notes") or ""),
                          max_rounds=getattr(args, "max_rounds", None), participants=getattr(args, "with_seats", None),
                          topology=topo, boundaries=bnd,
                          pins=_pins_from_args(args))
        except (WorkGraphError, ValueError, RouteRefused) as e:
            print(f"error: {e}", file=sys.stderr)
            return 2
        for w in graph.get("warnings") or []:
            print(f"warning: {w}", file=sys.stderr)
        try:  # attached from an architect's own pane: the graph is that architect's (its news goes to its chat)
            from pong.architect import link_by_seat

            arch = link_by_seat(sess, _os.environ.get("PONG_SEAT") or "", str(graph.get("id") or ""))
            if arch:
                graph["architect"] = arch
        except Exception:
            pass
        if getattr(args, "json", False):
            print(json.dumps({k: v for k, v in graph.items() if not str(k).startswith("_")}, indent=2, default=str))
            return 0
        print(f"graph {graph['id']} attached under {graph['owner']} · {len(graph.get('nodes') or [])} nodes · {len(graph.get('edges') or [])} edges · max_rounds {graph.get('max_rounds')}")
        for n in graph.get("nodes") or []:
            w = (graph.get("wiring") or {}).get(str(n.get("id"))) or {}
            who = f" — {w.get('runtime')} · {w.get('model')}" if w.get("runtime") else ""
            print(f"  {n.get('id'):12} {n.get('role'):10} seat={n.get('seat'):8} status={n.get('status')}{who}")
        for e in graph.get("edges") or []:
            print(f"  {e.get('from')} → {e.get('to')}  on: {e.get('on')}")
        return 0
    if sub == "lint":
        from pong.work_graph import WorkGraphError, lint_topology

        path = Path(getattr(args, "file") or "")
        try:
            t = lint_topology(json.loads(path.read_text(encoding="utf-8")))
        except (OSError, json.JSONDecodeError) as e:
            print(f"error: cannot read topology {path}: {e}", file=sys.stderr)
            return 2
        except WorkGraphError as e:
            print(f"refused: {e}", file=sys.stderr)
            return 1
        if getattr(args, "json", False):
            print(json.dumps(t, indent=2, ensure_ascii=False))
            return 0
        print(f"ok · {len(t['nodes'])} nodes · {len(t['edges'])} edges · start {', '.join(t['starts'])} · max_rounds {t['max_rounds']}")
        if t.get("loops"):
            from pong.graph_loops import table as _loop_table

            print("loops (outermost first):")
            for line in _loop_table(t["loops"]):
                print("  " + line)
            mj = (t.get("boundaries") or {}).get("max_jobs")
            print(f"worst case {t.get('worst_jobs')} job(s)" + (f"; max_jobs {mj} ends it first" if mj and int(mj) < int(t.get('worst_jobs') or 0) else ""))
        for w in t.get("warnings") or []:
            print(f"warning: {w}")
        return 0
    if sub == "show":
        return _graph_show(args)
    if sub == "list":
        from pong.graph_engine import list_all

        rows = list_all(done_limit=int(getattr(args, "done", 12) or 0))
        if getattr(args, "json", False):
            try:
                from pong.architect import list_all as _architects

                archs = _architects()
            except Exception:
                archs = []
            by_graph = {(a.get("session"), g): a for a in archs for g in a.get("graphs") or []}
            for g in rows:
                a = by_graph.get((g.get("session"), g.get("id")))
                if a:
                    g["architect"] = {k: a.get(k) for k in ("id", "seat", "alive", "queued", "title")}
            try:
                from pong.asks import list_open as _asks

                open_asks = _asks()
            except Exception:
                open_asks = []
            payload = {"generated_at": __import__("time").time(), "graphs": rows, "architects": archs,
                       "asks": open_asks}
            try:  # what the runner holds for Claude's usage limits (2.0); null when all is well
                from pong.limits import view as _limits_view

                payload["limits"] = _limits_view()
            except Exception:
                payload["limits"] = None
            try:  # only the runner moves a graph past its first step: Home says so when it is off (2.0)
                from pong.doctor import _runner as _runner_check

                payload["runner"] = _runner_check(__import__("time").time())
            except Exception:
                payload["runner"] = None
            try:  # short names in place of the first words of a request (1.9); never in the way of the list
                from pong import names as _names

                _names.apply(payload)
                _names.kick(payload)
            except Exception:
                pass
            print(json.dumps(payload, ensure_ascii=False, default=str))
            return 0
        for g in rows:
            n_q = len(g.get("gates") or [])
            gates = f" · {n_q} question{'' if n_q == 1 else 's'} waiting" if n_q else ""
            print(f"{g.get('session'):16} {g.get('id')}  {str(g.get('status')):8} {str(g.get('stop_reason') or ''):22} {g.get('title') or ''}{gates}")
        return 0
    if sub == "retry":
        import os as _os2
        from pong.work_graph import WorkGraphError, retry as _retry

        sess = _resolve_session_arg(args)
        if not sess:
            print("error: no session (pass -s/--session)", file=sys.stderr)
            return 2
        if not (_os2.environ.get("PONG_SESSION") or "").strip():
            _os2.environ["PONG_SESSION"] = sess
        try:
            g = _retry(sess, getattr(args, "id"), getattr(args, "node"))
        except (WorkGraphError, ValueError) as e:
            print(f"error: {e}", file=sys.stderr)
            return 2
        print(f"{g['id']}: {g.get('_did')} · status={g.get('status')}")
        return 0
    if sub == "seat-view":
        from pong.graph_engine import seat_view

        sess = _resolve_session_arg(args)
        if not sess:
            print("error: no session (pass -s/--session)", file=sys.stderr)
            return 2
        r = seat_view(sess, getattr(args, "seat"))
        if getattr(args, "json", False):
            print(json.dumps(r, ensure_ascii=False))
        else:
            print(f"tmux attach-session -t '={r['view']}:'" if r.get("ok") else f"error: {r.get('note')}")
        return 0 if r.get("ok") else 1
    if sub == "peek":
        from pong.graph_engine import peek_seat

        sess = _resolve_session_arg(args)
        if not sess:
            print("error: no session (pass -s/--session)", file=sys.stderr)
            return 2
        r = peek_seat(sess, getattr(args, "seat"), lines=int(getattr(args, "lines", 80) or 80))
        if getattr(args, "json", False):
            print(json.dumps(r, ensure_ascii=False))
            return 0
        print(r.get("text") or r.get("note") or "")
        return 0
    if sub in ("log", "trace"):
        from pong.graph_log import read as _read_log, trace as _trace

        sess = _resolve_session_arg(args)
        if not sess:
            print("error: no session (pass -s/--session)", file=sys.stderr)
            return 2
        gid, node = getattr(args, "id"), getattr(args, "node", None)
        if sub == "log":
            rows = _read_log(sess, gid, node=node, kinds=list(getattr(args, "kind", None) or []) or None,
                             tail=getattr(args, "tail", None))
            if getattr(args, "json", False):
                print(json.dumps(rows, ensure_ascii=False, default=str))
                return 0
            if not rows:
                print(f"(no log lines for {gid}{' ' + node if node else ''}: the log starts with CyberPong 1.8)")
            for r in rows:
                print(_log_line(r))
            return 0
        try:
            t = _trace(sess, gid, node)
        except ValueError as e:
            print(f"error: {e}", file=sys.stderr)
            return 2
        if getattr(args, "json", False):
            print(json.dumps(t, ensure_ascii=False, default=str))
            return 0
        _print_trace(t)
        return 0
    if sub == "examples":
        from pong.loops import _PKG
        if getattr(args, "json", False):
            rows = []
            for p in sorted((_PKG / "graphs").glob("*.json")):
                try:
                    t = json.loads(p.read_text(encoding="utf-8"))
                except Exception:
                    continue
                rows.append({"name": p.stem, "path": str(p), "notes": t.get("notes") or "",
                             "nodes": len(t.get("nodes") or []), "edges": len(t.get("edges") or [])})
            print(json.dumps(rows, ensure_ascii=False))
            return 0
        for p in sorted((_PKG / "graphs").glob("*.json")):
            t = json.loads(p.read_text(encoding="utf-8"))
            print(f"{p.stem:16} {len(t.get('nodes') or [])} nodes · {len(t.get('edges') or [])} edges · {t.get('notes') or ''}")
            print(f"{'':16} {p}")
        return 0
    if sub != "new":
        print(f"error: unknown graph subcommand {sub!r}", file=sys.stderr)
        return 2

    sess = _resolve_session_arg(args)
    answers_arg = getattr(args, "answers", None)
    interactive = False
    if answers_arg:
        raw = Path(answers_arg).read_text(encoding="utf-8") if answers_arg != "-" else sys.stdin.read()
        try:
            answers = json.loads(raw)
        except json.JSONDecodeError as e:
            print(f"error: answers are not JSON: {e}", file=sys.stderr)
            return 2
    else:
        if not sys.stdin.isatty():
            print(
                "error: `pong graph new` is an interview and needs a terminal.\n"
                "  Non-interactive: pong graph new --answers answers.json  (see `pong graph questions`)",
                file=sys.stderr,
            )
            return 2
        interactive = True
        print("New graph. Enter takes the * default.\n")
        answers = composer.interview(lambda q: input(q), under_default=getattr(args, "under", None) or "")
    if getattr(args, "under", None):
        answers["team"] = "under"
        answers["under"] = getattr(args, "under")
    if getattr(args, "project_root", None):
        answers["project_root"] = getattr(args, "project_root")
    try:
        proposal = composer.compose(answers)
    except ComposeError as e:
        print(f"error: {e}", file=sys.stderr)
        return 2
    if not getattr(args, "no_model", False):
        if interactive:
            print("\nAsking Claude to refine the shape …", flush=True)
        proposal = composer.propose(proposal, session=sess)

    pins = _pins_from_args(args)
    if pins:
        proposal["pins"] = {**(proposal.get("pins") or {}), **pins}

    # Who would run it, from the same solver Start uses.
    try:
        from pong.wiring import plan_loop, plan_node

        if proposal.get("topology"):
            wiring = {}
            for n in proposal["topology"].get("nodes") or []:
                if n.get("role") in ("human", "join", "end"):
                    continue
                if n.get("role") in ("check", "jev"):  # run by the engine, not a seat
                    wiring[n["id"]] = {"runtime": "engine" if n["role"] == "check" else "jev",
                                       "model": None if n["role"] == "check" else "jev (TypeSafe)",
                                       "why": "commands run by the engine" if n["role"] == "check" else "the engine asks Jev"}
                    continue
                row = plan_node(n["role"], proposal["goal"], session=sess, boundaries=proposal["boundaries"],
                                pin=(proposal.get("pins") or {}).get(n["id"]) or (proposal.get("pins") or {}).get(n["role"]) or (proposal.get("pins") or {}).get("*"),
                                in_cycle=True)
                wiring[n["id"]] = row
        else:
            wp = plan_loop(proposal["loop"], proposal["goal"], session=sess,
                           boundaries=proposal["boundaries"], pins=proposal.get("pins"),
                           roles={"builder": proposal.get("wire_role") or "builder", "fan": proposal.get("wire_role") or "builder"})
            wiring = {nid: row for nid, row in wp["nodes"].items()}
    except Exception:
        wiring = {}

    if getattr(args, "json", False) and not getattr(args, "start", False):
        print(json.dumps({"proposal": proposal, "wiring": wiring}, indent=2, ensure_ascii=False, default=str))
        return 0
    print()
    for line in composer.format_proposal(proposal, wiring):
        print(line)

    start_now = bool(getattr(args, "start", False))
    if interactive and not start_now and not getattr(args, "dry_run", False):
        ans = input("\nStart now? [Y/n] ").strip().lower()
        start_now = ans in ("", "y", "yes")
    if not start_now:
        print("\n(not started — re-run with --start, or answer Y)")
        return 0
    try:
        graph = composer.apply(proposal, session=sess)
    except (ComposeError, Exception) as e:  # noqa: BLE001 — one line, in the island too
        print(f"error: {e}", file=sys.stderr)
        return 2
    session_used = graph.get("_session")
    print(f"\nstarted {graph['id']} · {proposal['loop']} under {graph.get('_owner')} on team {session_used}")
    if graph.get("_spawn_note"):
        print(f"  {graph['_spawn_note']}")
    for n in graph.get("nodes") or []:
        w = (graph.get("wiring") or {}).get(str(n.get("id") or "")) or {}
        who = f" — {w.get('runtime')} · {w.get('model')}" if w.get("runtime") else ""
        print(f"  node {n.get('id')} seat={n.get('seat')} job={n.get('job_id') or '-'} status={n.get('status')}{who}")
    print(f"  follow: pong -s {session_used} goal status --id {graph['id']} · mailbox: pong -s {session_used} mailbox peek --seat {graph.get('_owner')}")
    if getattr(args, "json", False):
        public = {k: v for k, v in graph.items() if not str(k).startswith("_")}
        print(json.dumps(public, indent=2, default=str))
    return 0


def _cmd_wire(args: argparse.Namespace) -> int:
    """Who runs each node of a loop, and why — before anything is spawned."""
    from pong import wiring
    from pong.loops import LoopError

    sess = _resolve_session_arg(args)
    sub = getattr(args, "wire_cmd", None) or "plan"
    if sub != "plan":
        print(f"error: unknown wire subcommand {sub!r}", file=sys.stderr)
        return 2
    raw_task = getattr(args, "task", None)
    task = " ".join(raw_task).strip() if isinstance(raw_task, list) else str(raw_task or "").strip()
    try:
        plan = wiring.plan_loop(
            getattr(args, "loop"),
            task,
            session=sess,
            owner=getattr(args, "owner", None),
            boundaries={
                "client_facing": bool(getattr(args, "client_facing", False)),
                "agency": getattr(args, "agency", None) or "gated",
            },
            pins=_pins_from_args(args),
        )
    except LoopError as e:
        print(f"error: {e}", file=sys.stderr)
        return 2
    if getattr(args, "json", False):
        print(json.dumps(plan, indent=2, ensure_ascii=False, default=str))
        return 0
    for line in wiring.format_plan(plan):
        print(line)
    return 0


def _cmd_pool(args: argparse.Namespace) -> int:
    """The shared allowances the solver keeps heavy work away from."""
    from pong import wiring

    sess = _resolve_session_arg(args)
    sub = getattr(args, "pool_cmd", None) or "show"
    if sub == "show":
        rows = wiring.read_pools(sess)
        if getattr(args, "json", False):
            print(json.dumps(rows, indent=2))
            return 0
        if not rows:
            print("(no pools.json — every pool counts as full; `pong pool set xai 0.6`)")
            return 0
        for pid, row in rows.items():
            rem = float(row.get("weekly_remaining", 1.0)) * 100
            floor = float(row.get("floor", wiring.DEFAULT_POOL_FLOOR)) * 100
            print(f"{pid:10} {rem:5.0f}% of the week left · floor {floor:.0f}%")
        return 0
    if sub == "set":
        row = wiring.set_pool(
            getattr(args, "pool"),
            float(getattr(args, "remaining")),
            floor=getattr(args, "floor", None),
            session=sess if getattr(args, "team", False) else None,
        )
        print(f"{getattr(args, 'pool')}: weekly_remaining={row['weekly_remaining']:.2f} floor={row['floor']:.2f}")
        return 0
    print(f"error: unknown pool subcommand {sub!r}", file=sys.stderr)
    return 2


def build_parser() -> argparse.ArgumentParser:
    from pong import __version__

    p = argparse.ArgumentParser(prog="pong", description="Pong — agent mission control")
    p.add_argument("--version", action="version", version=f"CyberPong engine {__version__}",
                   help="the engine's version")
    p.add_argument("-s", "--session", default=None, help="bound team session")
    sub = p.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("status", help="bound session + roster")
    s.set_defaults(func=_cmd_status)

    g = sub.add_parser("gate", help="BRIDGE_ON / BRIDGE_OFF")
    g.set_defaults(func=_cmd_gate)

    snap = sub.add_parser("snapshot", help="UI snapshot JSON (contract v1)")
    snap.add_argument("--json", action="store_true", default=True)
    snap.add_argument("--compact", action="store_true")
    snap.add_argument("--write", action="store_true", help="print path note on stderr")
    snap.add_argument("--write-only", action="store_true", help="only write snapshot.json")
    snap.add_argument("--events", type=int, default=40)
    snap.set_defaults(func=_cmd_snapshot)

    ev = sub.add_parser("events", help="tail events.jsonl")
    ev.add_argument("-n", type=int, default=30)
    ev.add_argument("--json", action="store_true")
    ev.set_defaults(func=_cmd_events)

    chk = sub.add_parser("check", help="foundation self-check (UI readiness)")
    chk.set_defaults(func=_cmd_check)

    arch = sub.add_parser(
        "architecture",
        help="architecture helpers (handoff recap from flow_graph)",
    )
    archsub = arch.add_subparsers(dest="architecture_cmd", required=True)
    ar = archsub.add_parser(
        "recap",
        help="print architecture handoff recap for a seat (claim/assign hops)",
    )
    ar.add_argument("--seat", "-w", required=True, help="seat id e.g. w1, c1")
    ar.add_argument("--json", action="store_true", help="edges + recap as JSON")
    ar.set_defaults(func=_cmd_architecture)

    seat_p = sub.add_parser(
        "seat",
        help="seat identity + busy/available delivery protocol",
    )
    seatsub = seat_p.add_subparsers(dest="seat_cmd", required=True)
    sb = seatsub.add_parser(
        "brief",
        help="print durable seat identity + architecture guardrails",
    )
    sb.add_argument("--seat", "-w", required=True, help="seat id e.g. w1, c1")
    sb.add_argument("--json", action="store_true")
    sb.set_defaults(func=_cmd_seat)
    ss = seatsub.add_parser("status", help="busy/available for all seats")
    ss.add_argument("--json", action="store_true")
    ss.set_defaults(func=_cmd_seat)
    sbusy = seatsub.add_parser("busy", help="mark seat busy (no waitroom paste)")
    sbusy.add_argument("--seat", "-w", required=True)
    sbusy.add_argument("--reason", default="manual")
    sbusy.add_argument("--job-id", default=None)
    sbusy.set_defaults(func=_cmd_seat)
    sav = seatsub.add_parser(
        "available",
        help="mark seat available and try waitroom delivery",
    )
    sav.add_argument("--seat", "-w", required=True)
    sav.add_argument("--reason", default="manual")
    sav.set_defaults(func=_cmd_seat)

    rev = sub.add_parser(
        "review",
        help="review bars: set one up by interview, or list the ones in scope",
    )
    revsub = rev.add_subparsers(dest="review_cmd", required=True)
    ri = revsub.add_parser(
        "init",
        help="interview for a new bar and write it where the job path will find it",
    )
    ri.set_defaults(func=_cmd_review)
    rl = revsub.add_parser("list", help="bars visible to this team, and who holds them")
    rl.set_defaults(func=_cmd_review)
    rc = revsub.add_parser(
        "create",
        help="write a bar from a JSON answer sheet (what CyberPong's form calls)",
    )
    rc.add_argument("--answers", default="-", help="path to JSON, or - for stdin")
    rc.set_defaults(func=_cmd_review)

    grp = sub.add_parser(
        "group",
        help="coding groups: spawn a lead's seats, or start a new project on one",
    )
    grpsub = grp.add_subparsers(dest="group_cmd", required=True)
    gl = grpsub.add_parser("list", help="leads and the seats under them")
    gl.add_argument("--json", action="store_true")
    gl.set_defaults(func=_cmd_group)
    gs = grpsub.add_parser(
        "spawn",
        help="create any missing tmux window / view session for a group (idempotent)",
    )
    gs.add_argument("--lead", required=True, help="lead seat id, e.g. w25")
    gs.add_argument("--json", action="store_true")
    gs.set_defaults(func=_cmd_group)
    gn = grpsub.add_parser(
        "new-project",
        help="save a recap, then reset ONLY this group's seats and seed the recap",
    )
    gn.add_argument("--lead", required=True, help="lead seat id, e.g. w25")
    gn.add_argument("--title", default=None, help="archive title for the recap")
    gn.add_argument(
        "--dry-run",
        action="store_true",
        help="show which seats would reset and which are untouched",
    )
    gn.add_argument("--json", action="store_true")
    gn.set_defaults(func=_cmd_group)

    j = sub.add_parser("job", help="job control plane")
    jsub = j.add_subparsers(dest="job_cmd", required=True)

    jc = jsub.add_parser("create", help="create job + dispatch transports")
    jc.add_argument("--worker", "-w", default=None)
    jc.add_argument("--task", "-t", default="")
    jc.add_argument("--file", "-f", default=None, help="task body from file")
    jc.add_argument("--no-paste", action="store_true", help="job file only")
    jc.add_argument("--headless", action="store_true", help="job + headless CLI")
    jc.add_argument("--paste-only", action="store_true")
    jc.add_argument(
        "--force-paste",
        action="store_true",
        help="paste even if seat is busy (escape hatch)",
    )
    jc.add_argument("--no-claim", action="store_true")
    jc.add_argument("--round", type=int, default=1)
    jc.add_argument(
        "--parent",
        default=None,
        help="parent seat id (w1/c1) — shows as ephemeral subagent on 3D map until done",
    )
    jc.add_argument(
        "--ephemeral",
        action="store_true",
        help="mark job as ephemeral subagent seat on the map",
    )
    jc.set_defaults(func=_cmd_job_create)

    jl = jsub.add_parser("list")
    jl.add_argument("--status", default=None)
    jl.set_defaults(func=_cmd_job_list)

    js = jsub.add_parser("show")
    js.add_argument("job_id")
    js.set_defaults(func=_cmd_job_show)

    jst = jsub.add_parser("status")
    jst.add_argument("job_id")
    jst.add_argument(
        "status",
        choices=[
            "queued",
            "notified",
            "running",
            "done",
            "failed",
            "rejected",
            "human_takeover",
            "cancelled",
        ],
    )
    jst.set_defaults(func=_cmd_job_status)

    jcl = jsub.add_parser("claim")
    jcl.add_argument("job_id")
    jcl.add_argument("--files", default="")
    jcl.add_argument("--commands", default="")
    jcl.add_argument("--summary", default="")
    jcl.add_argument("--raw", default=None)
    jcl.add_argument(
        "--notify-paste",
        action="store_true",
        help="legacy: paste full CLAIM into orchestrator immediately (skip waitroom digest)",
    )
    jcl.set_defaults(func=_cmd_job_claim)

    jhv = jsub.add_parser(
        "harvest",
        help="recover Recap/CLAIM text from idle panes into pong job claim",
    )
    jhv.set_defaults(func=_cmd_job_harvest)

    # Claim board — read side of the same two files the waitroom writes.
    # Deliberately top-level and read-only: any seat can answer "what was
    # claimed, and who has not seen it?" without a paste or an idle pane.
    cb = sub.add_parser(
        "claims",
        help="read-only claim board (job claims + waitroom unread markers)",
    )
    cb.add_argument(
        "--seat",
        default=None,
        help="only claims filed by, or addressed to, this seat (e.g. w16)",
    )
    cb.add_argument(
        "--unread",
        action="store_true",
        help="only claims still queued in the waitroom",
    )
    cb.add_argument(
        "--limit",
        type=int,
        default=20,
        help="max rows, newest first (0 = all; default 20)",
    )
    cb.add_argument("--json", action="store_true")
    cb.set_defaults(func=_cmd_claims)

    # Run traces — read side of traces/<session>/<job>.jsonl. Read-only by
    # construction: it opens files for reading and never records a run.
    tr = sub.add_parser(
        "traces",
        help="read-only run traces (langsmith-shaped JSONL, one file per job)",
    )
    trsub = tr.add_subparsers(dest="traces_cmd", required=True)
    trl = trsub.add_parser("list", help="newest-first index of traced jobs")
    trl.add_argument(
        "--limit", type=int, default=20, help="max rows (0 = all; default 20)"
    )
    trl.add_argument("--json", action="store_true")
    trl.set_defaults(func=_cmd_traces)
    trs = trsub.add_parser("show", help="every run recorded for one job id")
    trs.add_argument("job_id")
    trs.add_argument("--json", action="store_true")
    trs.set_defaults(func=_cmd_traces)

    # Delivery waitroom — claims + deferred job pastes (only when seat available)
    wr = sub.add_parser(
        "waitroom",
        help="delivery inbox: claims + deferred jobs; paste only when seat available",
    )
    wrsub = wr.add_subparsers(dest="waitroom_cmd", required=True)
    wrl = wrsub.add_parser("list", help="list waitroom items (default: queued)")
    wrl.add_argument(
        "--status",
        default="queued",
        help="queued|delivered|all (default queued)",
    )
    wrl.add_argument("--to", default=None, help="filter seat (e.g. c1)")
    wrl.add_argument("--json", action="store_true")
    wrl.set_defaults(func=_cmd_waitroom)
    wri = wrsub.add_parser("inbox", help="alias for list")
    wri.add_argument("--status", default="queued")
    wri.add_argument("--to", default=None)
    wri.add_argument("--json", action="store_true")
    wri.set_defaults(func=_cmd_waitroom)
    wrd = wrsub.add_parser(
        "drain",
        help="mark targets available and deliver waitroom (human ready to receive)",
    )
    wrd.add_argument("--to", default=None, help="only this seat (default: all with queue)")
    wrd.add_argument(
        "--force",
        action="store_true",
        help="bypass busy gate + short grace",
    )
    wrd.set_defaults(func=_cmd_waitroom)
    wrdel = wrsub.add_parser("deliver", help="alias for drain")
    wrdel.add_argument("--to", default=None)
    wrdel.add_argument("--force", action="store_true")
    wrdel.set_defaults(func=_cmd_waitroom)
    wrt = wrsub.add_parser(
        "try-deliver",
        help="deliver only if seat already available (no auto-interrupt)",
    )
    wrt.add_argument("--to", default=None)
    wrt.add_argument("--force", action="store_true")
    wrt.set_defaults(func=_cmd_waitroom)
    wrs = wrsub.add_parser("show-digest", help="print claim digest text without pasting")
    wrs.add_argument("--to", default=None)
    wrs.set_defaults(func=_cmd_waitroom)

    d = sub.add_parser("delegate", help="compat: job create + notify")
    d.add_argument("prompt", nargs="*")
    d.add_argument("--worker", "-w", default=None)
    d.add_argument("--no-wait", action="store_true", help="ignored (async by default)")
    d.add_argument("--dry-run", action="store_true")
    d.add_argument("--no-paste", action="store_true")
    d.add_argument("--headless", action="store_true")
    d.add_argument("--paste-only", action="store_true")
    d.add_argument("--criteria", default=None)
    d.set_defaults(func=_cmd_delegate)

    # Ephemeral subagents (3D map live nodes that vanish when done)
    sa = sub.add_parser(
        "subagent",
        help="ephemeral subagents on the 3D map (appear while active, vanish when down)",
    )
    sasub = sa.add_subparsers(dest="subagent_cmd", required=True)
    sau = sasub.add_parser("up", help="register a live subagent under a parent seat")
    sau.add_argument("--parent", "-p", required=True, help="parent seat id (w1, c1, …)")
    sau.add_argument("--label", "-l", default="", help="short name on the map")
    sau.add_argument("--task", "-t", default="", help="what this sub is doing")
    sau.add_argument("--id", default=None, help="stable id (default: eph_xxxxxxxx)")
    sau.add_argument("--role", default="coder", help="mission role glyph")
    sau.set_defaults(func=_cmd_subagent)
    sad = sasub.add_parser("down", help="remove a subagent from the map")
    sad.add_argument("id", help="subagent id from `pong subagent up`")
    sad.set_defaults(func=_cmd_subagent)
    sal = sasub.add_parser("list", help="list live ephemeral subagents")
    sal.set_defaults(func=_cmd_subagent)

    led = sub.add_parser("ledger")
    lsub = led.add_subparsers(dest="ledger_cmd", required=True)
    lr = lsub.add_parser("record")
    lr.add_argument("--task-id", required=True)
    lr.add_argument("--round", type=int, required=True)
    lr.add_argument("--verdict", required=True, choices=["accept", "reject", "escalate"])
    lr.add_argument("--evidence", default="")
    lr.add_argument("--worker", default=None)
    lr.set_defaults(func=_cmd_ledger)
    ls = lsub.add_parser("summary")
    ls.set_defaults(func=_cmd_ledger)
    ld = lsub.add_parser("distill")
    ld.set_defaults(func=_cmd_ledger)

    m = sub.add_parser("migrate", help="copy ~/.hermes-pong → ~/.pong")
    m.add_argument("--force", action="store_true")
    m.set_defaults(func=_cmd_migrate)

    # Session vault (smart-compress continuity packages)
    cont = sub.add_parser(
        "continuity",
        help="session vault: smart-compress / list / show / delete archives",
    )
    csub = cont.add_subparsers(dest="continuity_cmd", required=True)
    cs = csub.add_parser("save", help="compress live session into archive (does not kill)")
    cs.add_argument("--title", default=None, help="archive title")
    cs.add_argument("--json", action="store_true")
    cs.set_defaults(func=_cmd_continuity)
    cl = csub.add_parser(
        "list",
        help="list archived sessions (optional team filter via -s/--session and/or --team)",
    )
    cl.add_argument("--json", action="store_true")
    cl.add_argument(
        "--team",
        "--display-name",
        dest="filter_display_name",
        default=None,
        metavar="NAME",
        help="only archives whose display_name matches (case-insensitive)",
    )
    cl.set_defaults(func=_cmd_continuity)
    csh = csub.add_parser("show", help="print archive meta + recap")
    csh.add_argument("id", help="archive id sess_…")
    csh.add_argument("--json", action="store_true")
    csh.add_argument("--recap-only", action="store_true")
    csh.set_defaults(func=_cmd_continuity)
    cr = csub.add_parser("recap", help="print smart-compress markdown for a live session")
    cr.add_argument("--title", default=None)
    cr.set_defaults(func=_cmd_continuity)
    cd = csub.add_parser("delete", help="delete an archive")
    cd.add_argument("id")
    cd.set_defaults(func=_cmd_continuity)
    cn = csub.add_parser("rename", help="rename archive title")
    cn.add_argument("id")
    cn.add_argument("--title", required=True)
    cn.add_argument("--json", action="store_true")
    cn.set_defaults(func=_cmd_continuity)

    # Inter-team channel (file-based, never auto-pasted)
    br = sub.add_parser("brief", help="inter-team briefs (file channel only)")
    brsub = br.add_subparsers(dest="brief_cmd", required=True)
    brs = brsub.add_parser("send", help="send brief to another team inbox")
    brs.add_argument("--to", required=True, help="target team session")
    brs.add_argument("--subject", default=None)
    brs.add_argument("--file", "-f", default=None, help="body from file")
    brs.add_argument("body", nargs="*", help="brief body text")
    brs.set_defaults(func=_cmd_brief_send)

    # Pane pin registration (V3)
    pn = sub.add_parser("pane", help="worker pane registration")
    pnsub = pn.add_subparsers(dest="pane_cmd", required=True)
    pnr = pnsub.add_parser("register", help="pin worker to immutable tmux pane id")
    pnr.add_argument("--worker", "-w", required=True)
    pnr.add_argument("--pane-id", required=True, help="tmux pane id e.g. %%3")
    pnr.add_argument("--cmd", default="", help="expected start command")
    pnr.add_argument("--title", default=None, help="exact title pong.<session>.<seat>")
    pnr.set_defaults(func=_cmd_pane_register)

    tok = sub.add_parser("token", help="session isolation token")
    toksub = tok.add_subparsers(dest="token_cmd", required=True)
    te = toksub.add_parser("ensure", help="create token file if missing")
    te.add_argument(
        "--print-token",
        action="store_true",
        help="print raw token (for spawn env export)",
    )
    te.set_defaults(func=_cmd_token_ensure)

    # Disposable work-graph loops under a main. The org flow_graph and the
    # permanent workers[] are never edited by these — see pong/work_graph.py.
    gl = sub.add_parser("goal", help="start a disposable work-graph loop under a main")
    glsub = gl.add_subparsers(dest="goal_cmd", required=True)
    gls = glsub.add_parser(
        "start", help="pong -s SESSION goal start --owner wN --loop fan --task …"
    )
    gls.add_argument("--owner", required=True, help="the main the loop hangs under")
    # A loop can run on ONE seat or on a SET. --owner is the lead either way;
    # --with names the rest. The engine has taken participants since work_graph
    # gained them (test_participants_with_named_mains) — this is the spelling
    # that lets a caller reach it, and `dest` is spelled out because `with` is
    # a Python keyword and `args.with` would not parse.
    gls.add_argument("--with", dest="with_seats", default=None,
                     help="comma-separated extra org mains, e.g. --with w1,w5 "
                          "(omit for an owner-only loop)")
    gls.add_argument("--loop", required=True, help="fan|cycle|gauntlet")
    gls.add_argument("--task", default="")
    gls.add_argument("--pieces", type=int, default=2, help="fan width (cap 4)")
    gls.add_argument("--max-rounds", type=int, default=None, help="cycle rounds")
    gls.add_argument("--bar", default=None,
                     help="required for gauntlet unless --example/--examples")
    gls.add_argument("--examples", default=None,
                     help="comma-separated example URLs (the bar)")
    gls.add_argument("--example", action="append", default=[],
                     help="repeatable example URL")
    gls.add_argument("--pin", action="append", default=[],
                     help="node=platform, repeatable — a pin wins; the solver reports what it would have chosen")
    gls.add_argument("--client-facing", action="store_true",
                     help="output is read by a client: platforms whose boundary forbids that are removed")
    gls.add_argument("--agency", default=None, choices=["report_only", "gated", "unattended"],
                     help="how far this loop may go without a person (default gated)")
    gls.add_argument("--pause-on", default=None, choices=["round", "win", "done"],
                     help="round: every round comes back to you · win: the critic decides · done: unattended")
    gls.add_argument("--efficiency", default=None, choices=["thorough", "balanced", "fast"])
    gls.add_argument("--allow", default="", help="comma list of platforms the loop may use (default any)")
    gls.add_argument("--json", action="store_true", help="print the graph document, wiring included")
    gls.set_defaults(func=_cmd_goal)
    glc = glsub.add_parser("cancel", help="stop a loop; it stays as cancelled history")
    glc.add_argument("--id", required=True)
    glc.set_defaults(func=_cmd_goal)
    gld = glsub.add_parser("delete", help="forget a loop — remove it from work_graph.json")
    gld.add_argument("--id", required=True)
    gld.set_defaults(func=_cmd_goal)
    glt = glsub.add_parser("tick", help="advance joins / cycles / gauntlets from finished jobs")
    glt.add_argument("--id", default=None)
    glt.set_defaults(func=_cmd_goal)
    glr = glsub.add_parser("resume", help="continue a loop that stopped to show you")
    glr.add_argument("--id", required=True)
    glr.add_argument("--outcome", default="approved", help="at a human gate: approved (default), rejected, or a label the graph names")
    glr.add_argument("--node", default=None, help="which gate, when more than one is open")
    glr.add_argument("--note", default="", help="a note from you that travels to the next step (why you rejected, what to change)")
    glr.add_argument("--extend", type=int, default=0, help="allow N more rounds of this gate's loop (max_jobs and max_wall_min rise by what those rounds can cost)")
    glr.set_defaults(func=_cmd_goal)
    glp = glsub.add_parser("pause", help="hold a loop: nothing further is dispatched until resume")
    glp.add_argument("--id", required=True)
    glp.set_defaults(func=_cmd_goal)
    glst = glsub.add_parser("status", help="list work graphs, or show one with --id")
    glst.add_argument("--id", default=None)
    glst.set_defaults(func=_cmd_goal)

    # —— Graph: designed from a short interview ——
    gp = sub.add_parser("graph", help="design a graph by answering a few questions")
    gpsub = gp.add_subparsers(dest="graph_cmd", required=True)
    gpn = gpsub.add_parser("new", help="interview → proposal (refined by Claude) → Start")
    gpn.add_argument("--answers", default=None, help="JSON file, or - for stdin (non-interactive)")
    gpn.add_argument("--under", default=None, help="run under this main instead of a new team")
    gpn.add_argument("--pin", action="append", default=[], help="node=platform or role=platform, repeatable (e.g. --pin critic=grok)")
    gpn.add_argument("--project-root", default=None)
    gpn.add_argument("--start", action="store_true", help="start without asking")
    gpn.add_argument("--dry-run", action="store_true", help="show the proposal only")
    gpn.add_argument("--no-model", action="store_true", help="skip the model refinement")
    gpn.add_argument("--json", action="store_true")
    gpn.set_defaults(func=_cmd_graph)
    gpq = gpsub.add_parser("questions", help="the interview as JSON (for a form)")
    gpq.set_defaults(func=_cmd_graph)
    gpa = gpsub.add_parser("attach", help="a graph loop you describe: nodes, edges with conditions, cycles bounded by max_rounds")
    gpa.add_argument("--owner", required=True, help="the main it hangs under")
    gpa.add_argument("--file", required=True, help="topology JSON — see `pong graph examples`")
    gpa.add_argument("--task", default="", help="the goal text; defaults to the topology's goal/notes")
    gpa.add_argument("--with", dest="with_seats", default=None)
    gpa.add_argument("--max-rounds", type=int, default=None)
    gpa.add_argument("--agency", default=None, choices=["report_only", "gated", "unattended"])
    gpa.add_argument("--max-wall", type=float, default=None, help="minutes the whole graph may run before it stops")
    gpa.add_argument("--max-jobs", type=int, default=None, help="jobs the graph may dispatch in total")
    gpa.add_argument("--node-timeout", type=float, default=None, help="minutes one step may run before it is retried or failed")
    gpa.add_argument("--pin", action="append", default=[])
    gpa.add_argument("--client-facing", action="store_true",
                     help="its work reaches a client: client-facing seat rules apply and nothing is sent to Jev")
    gpa.add_argument("--json", action="store_true")
    gpa.set_defaults(func=_cmd_graph)
    gpe = gpsub.add_parser("examples", help="bundled graph-loop topologies (the research templates)")
    gpe.add_argument("--json", action="store_true")
    gpe.set_defaults(func=_cmd_graph)
    gpl = gpsub.add_parser("lint", help="check a topology file: errors refuse it, warnings name what will misbehave")
    gpl.add_argument("--file", required=True)
    gpl.add_argument("--json", action="store_true")
    gpl.set_defaults(func=_cmd_graph)
    gpls = gpsub.add_parser("list", help="every graph on this Mac, running first (JSON with --json)")
    gpls.add_argument("--json", action="store_true")
    gpls.add_argument("--done", type=int, default=12, help="how many finished graphs to include")
    gpls.set_defaults(func=_cmd_graph)
    gppk = gpsub.add_parser("peek", help="the last lines of a seat's terminal, read-only")
    gppk.add_argument("--seat", required=True)
    gppk.add_argument("--lines", type=int, default=80)
    gppk.add_argument("--json", action="store_true")
    gppk.set_defaults(func=_cmd_graph)
    gprt = gpsub.add_parser("retry", help="run one failed step of a graph again")
    gprt.add_argument("--id", required=True)
    gprt.add_argument("--node", required=True)
    gprt.set_defaults(func=_cmd_graph)
    gpsv = gpsub.add_parser("seat-view", help="a one-window tmux view of a seat, for Terminal to attach to")
    gpsv.add_argument("--seat", required=True)
    gpsv.add_argument("--json", action="store_true")
    gpsv.set_defaults(func=_cmd_graph)
    gpsh = gpsub.add_parser("show", help="one graph in words: nodes, who runs them, open gates and the command to answer them")
    gpsh.add_argument("--id", default=None, help="graph id (default: the newest running graph)")
    gpsh.add_argument("--json", action="store_true", help="the snapshot block for this graph")
    gpsh.set_defaults(func=_cmd_graph)
    gplog = gpsub.add_parser("log", help="a graph's full log: every step, claim, verdict, Jev decision, gate answer, architect message")
    gplog.add_argument("--id", required=True)
    gplog.add_argument("--node", default=None, help="one step (its copies too: research-a covers research-a#1…)")
    gplog.add_argument("--kind", action="append", default=[], help="event, dispatch, jev, jev_advice, jev_claim_read, gate_ask, gate_answer, pause, pane_saved, architect_delivery")
    gplog.add_argument("--tail", type=int, default=None)
    gplog.add_argument("--json", action="store_true")
    gplog.set_defaults(func=_cmd_graph)
    gptr = gpsub.add_parser("trace", help="one step's whole story: its jobs, prompts, claims, Jev lines, the AI's transcript and terminal")
    gptr.add_argument("--id", required=True)
    gptr.add_argument("--node", default=None, help="one step (default: every step)")
    gptr.add_argument("--json", action="store_true")
    gptr.set_defaults(func=_cmd_graph)

    ar = sub.add_parser("architect", help="a Claude session that designs, launches, watches and edits a project's graphs")
    arsub = ar.add_subparsers(dest="architect_cmd", required=True)
    arn = arsub.add_parser("new", help="a new project: a team of its own whose lead seat is the architect")
    arn.add_argument("--title", required=True)
    arn.add_argument("--project", required=True, help="the project's folder (a clone of its repository)")
    arn.add_argument("--runtime", default=None,
                     help="claude, grok or codex (default: the one saved in Settings, else the lead policy's pick)")
    arn.add_argument("--model", default=None, help="a model of that runtime (pong model list), e.g. opus, fable, grok-4.7")
    arn.add_argument("--brief", default="", help="the person's request, handed to the architect as its first message (- reads stdin)")
    arn.add_argument("--json", action="store_true")
    arn.set_defaults(func=_cmd_architect)
    ars = arsub.add_parser("start", help="an architect seat in an existing team (-s), optionally for one graph")
    ars.add_argument("--title", default="")
    ars.add_argument("--cwd", default="", help="its working folder (default: the team's project folder)")
    ars.add_argument("--graph", default="", help="a running graph it takes over watching")
    ars.add_argument("--runtime", default=None,
                     help="claude, grok or codex (default: the one saved in Settings, else the lead policy's pick)")
    ars.add_argument("--model", default=None, help="a model of that runtime (pong model list)")
    ars.add_argument("--brief", default="", help="the person's request, handed to the architect as its first message (- reads stdin)")
    ars.add_argument("--json", action="store_true")
    ars.set_defaults(func=_cmd_architect)
    arl = arsub.add_parser("list", help="every architect on this Mac")
    arl.add_argument("--json", action="store_true")
    arl.set_defaults(func=_cmd_architect)
    for name, hlp in (("link", "tie a graph to an architect: its news goes to that chat"),
                      ("screen", "the architect's terminal, read-only"),
                      ("send", "type a message into the architect's chat and press Enter"),
                      ("key", "press one key in the architect's chat (enter, escape, up, down, tab, btab, ctrl-c, y, n, 1-3)"),
                      ("events", "the events queued for it and the last ones delivered"),
                      ("note", "log a line the person typed straight into the terminal view"),
                      ("log", "its chat log (what went in from outside) and its own transcript")):
        p_ = arsub.add_parser(name, help=hlp)
        p_.add_argument("--id", required=True, help="the architect id (a_…)")
        if name == "link":
            p_.add_argument("--graph", required=True)
        if name == "screen":
            p_.add_argument("--lines", type=int, default=200)
        if name in ("send", "note"):
            p_.add_argument("--text", required=True, help="the message, or - to read it from stdin")
        if name == "key":
            p_.add_argument("--key", required=True)
        p_.add_argument("--json", action="store_true")
        p_.set_defaults(func=_cmd_architect)

    # —— Jev: TypeSafe System One, typed decisions for graph loops ——
    # —— questions an AI asks the person (shown as the app's question card) ——
    nm = sub.add_parser("names", help="short names for chats and graphs: fill, list, or set one by hand")
    nmsub = nm.add_subparsers(dest="names_cmd", required=True)
    nmf = nmsub.add_parser("fill", help="name the chats and graphs that have no name yet (a small model writes them)")
    nmf.add_argument("--limit", type=int, default=12)
    nmf.set_defaults(func=_cmd_names)
    nml = nmsub.add_parser("list", help="every name")
    nml.add_argument("--json", action="store_true")
    nml.set_defaults(func=_cmd_names)
    for name, hlp in (("set", "give a chat or a graph your own name (kept for good)"),
                      ("forget", "drop a name; the next fill writes a new one")):
        p_ = nmsub.add_parser(name, help=hlp)
        p_.add_argument("--chat", default="", help="the chat's id (a_…)")
        p_.add_argument("--graph", default="", help="the graph's id (g_…)")
        if name == "set":
            p_.add_argument("--name", required=True)
        p_.set_defaults(func=_cmd_names)
    ak = sub.add_parser("ask", help="ask the person a question: it shows on the app's Needs you page as a card")
    aksub = ak.add_subparsers(dest="ask_cmd", required=True)
    akn = aksub.add_parser("new", help="post a question; the answer comes back to your terminal as a [CyberPong] line")
    akn.add_argument("--question", "-q", required=True, help="the question, in plain words, 15 words or fewer (- reads stdin)")
    akn.add_argument("--option", "-o", action="append", default=[],
                     help='an answer, "label::what it does" (repeat, at most 4); none: the person answers with a note')
    akn.add_argument("--context", "-c", action="append", default=[], help="a line of context (repeat, at most 3)")
    akn.add_argument("--detail", "-d", action="append", default=[],
                     help='a fact the person needs to decide, "text::file::where" (file and where optional; '
                          'repeat, at most 6): what exactly is decided, the numbers, what each answer leads to')
    akn.add_argument("--file", "-f", action="append", default=[], help="a file the question is about (repeat)")
    akn.add_argument("--seat", default="", help="the asking seat (default: PONG_SEAT)")
    akn.add_argument("--json", action="store_true")
    akn.set_defaults(func=_cmd_ask)
    akl = aksub.add_parser("list", help="open questions (this team, or --all)")
    akl.add_argument("--all", action="store_true")
    akl.add_argument("--json", action="store_true")
    akl.set_defaults(func=_cmd_ask)
    for name, hlp in (("answer", "answer a question (the app does this when the person presses a button)"),
                      ("withdraw", "take your question back"), ("show", "one question and its answer"),
                      ("explain", "write a question's detail points with the helper AI, once (runs in the "
                                  "background when a question is asked without --detail)")):
        p_ = aksub.add_parser(name, help=hlp)
        p_.add_argument("--id", required=True)
        if name == "answer":
            p_.add_argument("--choice", default="", help="the option's number (1-4)")
            p_.add_argument("--note", default="")
        p_.add_argument("--json", action="store_true")
        p_.set_defaults(func=_cmd_ask)

    tm = sub.add_parser("team", help="a team as a whole: start a stopped one again (-s <team>)")
    tmsub = tm.add_subparsers(dest="team_cmd", required=True)
    tms = tmsub.add_parser("start", help="start a stopped team under its own name: its lead and helpers, as set up")
    tms.add_argument("--json", action="store_true")
    tms.set_defaults(func=_cmd_team)

    jv = sub.add_parser("jev", help="Jev (TypeSafe System One): status, grade a document by hand, the ledger")
    jvsub = jv.add_subparsers(dest="jev_cmd", required=True)
    jvs = jvsub.add_parser("status", help="whether Jev can be asked (the key is never shown)")
    jvs.add_argument("--json", action="store_true")
    jvs.set_defaults(func=_cmd_jev)
    jvg = jvsub.add_parser("grade", help="score documents against a rubric, the way a jev grade node does")
    jvg.add_argument("--rubric", required=True, help="rubric JSON: {questions:{…}} or a list of lines")
    jvg.add_argument("--file", action="append", default=[], required=True, help="a document to grade, repeatable")
    jvg.add_argument("--floor", type=int, default=None, help="level every score line must reach (default: Adequate)")
    jvg.add_argument("--pass-p", type=float, default=None, help="P(line meets its floor) for a pass (default 0.8)")
    jvg.add_argument("--goal", default="", help="what the work is for")
    jvg.add_argument("--trust", default="earned", choices=["earned", "all"],
                     help="earned (default): only probed questions decide, as in a graph; all: every line decides")
    jvg.add_argument("--json", action="store_true")
    jvg.set_defaults(func=_cmd_jev)
    jvd = jvsub.add_parser("decide", help='pick among options: --option fast="a one-file fix" --option deep="rework"')
    jvd.add_argument("--question", required=True)
    jvd.add_argument("--option", action="append", default=[], required=True, help="name=description, repeatable")
    jvd.add_argument("--file", action="append", default=[], help="documents Jev may read")
    jvd.add_argument("--take", type=float, default=None, help="probability needed to choose (default 0.9)")
    jvd.add_argument("--json", action="store_true")
    jvd.set_defaults(func=_cmd_jev)
    jvn = jvsub.add_parser("lint", help="check a rubric's questions against the question checklist (free, no call)")
    jvn.add_argument("--rubric", required=True, help="@name, a rubric file, or a question card (JSON)")
    jvn.add_argument("--json", action="store_true")
    jvn.set_defaults(func=_cmd_jev)
    jvp = jvsub.add_parser("probe", help="test a rubric's questions live on labelled cases; each earns a status")
    jvp.add_argument("--rubric", required=True, help="@name or a rubric file")
    jvp.add_argument("--cases", default=None, help="probe cases JSON (default: <rubric>.probes.json beside it)")
    jvp.add_argument("--repeats", type=int, default=3, help="asks per case, for the stability check (default 3)")
    jvp.add_argument("--no-record", action="store_true", help="report only; do not record the statuses")
    jvp.add_argument("--require", default="gate", choices=["gate", "ranker"],
                     help="exit 0 when every measured line is at least this (default gate; ranker: none unusable)")
    jvp.add_argument("--json", action="store_true")
    jvp.set_defaults(func=_cmd_jev)
    jvq = jvsub.add_parser("questions", help="what each question has earned: gate, ranker, unusable, too few examples, unproven")
    jvq.add_argument("--rubric", default=None, help="@name or a rubric file (default: every recorded question)")
    jvq.add_argument("--json", action="store_true")
    jvq.set_defaults(func=_cmd_jev)
    jvl = jvsub.add_parser("ledger", help="recent Jev calls and how well they matched what people decided")
    jvl.add_argument("--last", type=int, default=15)
    jvl.add_argument("--json", action="store_true")
    jvl.set_defaults(func=_cmd_jev)
    jvk = jvsub.add_parser("key", help="Jev's key in Settings: set (from stdin only), clear, or test it")
    jvksub = jvk.add_subparsers(dest="key_cmd", required=True)
    for name, hlp in (("set", "save the key Settings uses (read from stdin, never an argument; never shown)"),
                      ("clear", "remove the key Settings saved (a key file jev.json names is left alone)"),
                      ("test", "one trivial call with no documents: works, key refused, unreachable or no key")):
        p_ = jvksub.add_parser(name, help=hlp)
        p_.add_argument("--json", action="store_true")
        p_.set_defaults(func=_cmd_jev)

    # —— Wiring: who runs each node, and why ——
    wi = sub.add_parser("wire", help="who runs each node of a loop, and why (and why not)")
    wisub = wi.add_subparsers(dest="wire_cmd", required=True)
    wip = wisub.add_parser("plan", help='pong wire plan --loop gauntlet --owner w7 --task "…"')
    wip.add_argument("--loop", required=True, help="fan|join|router|cycle|gauntlet")
    wip.add_argument("--owner", default=None)
    wip.add_argument("--task", default="")
    wip.add_argument("--pin", action="append", default=[], help="node=platform, repeatable")
    wip.add_argument("--client-facing", action="store_true")
    wip.add_argument("--agency", default=None, choices=["report_only", "gated", "unattended"])
    wip.add_argument("--json", action="store_true")
    wip.set_defaults(func=_cmd_wire)

    po = sub.add_parser("pool", help="shared weekly allowances the solver keeps heavy work off")
    posub = po.add_subparsers(dest="pool_cmd", required=True)
    pos = posub.add_parser("show")
    pos.add_argument("--json", action="store_true")
    pos.set_defaults(func=_cmd_pool)
    poset = posub.add_parser("set", help="pong pool set xai 0.62 [--floor 0.25]")
    poset.add_argument("pool")
    poset.add_argument("remaining", type=float, help="0..1 share of the week left")
    poset.add_argument("--floor", type=float, default=None)
    poset.add_argument("--team", action="store_true", help="write the bound team's override, not the machine file")
    poset.set_defaults(func=_cmd_pool)

    md = sub.add_parser("model", help="runtime + model catalog, and why a piece of work routes where it does")
    mdsub = md.add_subparsers(dest="model_cmd", required=True)
    mdl = mdsub.add_parser("list", help="runtimes, their models, strengths, and what is installed")
    mdl.add_argument("--json", action="store_true")
    mdl.set_defaults(func=_cmd_model)
    mdp = mdsub.add_parser("plan", help="pong model plan --role coder 'refactor the waitroom'")
    mdp.add_argument("task", nargs="*", default=[])
    mdp.add_argument("--role", default="", help="mission role of the seat")
    mdp.add_argument("--loop", default="", help="route every node of a loop kind instead of one seat")
    mdp.add_argument("--json", action="store_true")
    mdp.set_defaults(func=_cmd_model)

    # —— Runner: mailbox / drain / cron / runtime ——
    mb = sub.add_parser("mailbox", help="per-seat jsonl inbox (peek / ack / list / post)")
    mbsub = mb.add_subparsers(dest="mailbox_cmd", required=True)
    mbp = mbsub.add_parser("peek", help="unread items (does not ack)")
    mbp.add_argument("--seat", required=True)
    mbp.add_argument("--limit", type=int, default=50)
    mbp.add_argument("--json", action="store_true")
    mbp.set_defaults(func=_cmd_mailbox)
    mba = mbsub.add_parser("ack", help="mark items read")
    mba.add_argument("--seat", required=True)
    mba.add_argument("ids", nargs="*")
    mba.set_defaults(func=_cmd_mailbox)
    mbl = mbsub.add_parser("list", help="all items (acked + unread)")
    mbl.add_argument("--seat", default=None)
    mbl.add_argument("--unread", action="store_true")
    mbl.add_argument("--json", action="store_true")
    mbl.set_defaults(func=_cmd_mailbox)
    mbpo = mbsub.add_parser("post", help="append a mailbox item")
    mbpo.add_argument("--seat", required=True)
    mbpo.add_argument("--summary", default="")
    mbpo.add_argument("--kind", default="note")
    mbpo.add_argument("--from-seat", default="")
    mbpo.add_argument("--job-id", default="")
    mbpo.add_argument("text", nargs="*")
    mbpo.set_defaults(func=_cmd_mailbox)

    dr = sub.add_parser("drain", help="harvest + waitroom + goal ticks + snapshot, panel or no panel")
    dr.add_argument("--watch", action="store_true", help="~2s loop (panel-independent)")
    dr.add_argument("--interval", type=float, default=2.0)
    dr.add_argument("--force", action="store_true")
    dr.add_argument("--json", action="store_true")
    dr.set_defaults(func=_cmd_drain)

    cr = sub.add_parser("cron", help="schedule runner: tick / status / run / add / install-agent")
    crsub = cr.add_subparsers(dest="cron_cmd", required=True)
    crt = crsub.add_parser("tick", help="fire due schedules (outward wording is gated to draft-only), then drain")
    crt.add_argument("--json", action="store_true")
    crt.set_defaults(func=_cmd_cron)
    crs = crsub.add_parser("status", help="runner heartbeat")
    crs.set_defaults(func=_cmd_cron)
    crr = crsub.add_parser("run", help="watch loop")
    crr.add_argument("--interval", type=float, default=30.0)
    crr.add_argument("--no-cron", action="store_true", help="drain + goal ticks only; schedule rows never fire")
    crr.set_defaults(func=_cmd_cron)
    cri = crsub.add_parser("install-agent", help="write and load the launchd agent (drain-only unless CRON=1)")
    cri.set_defaults(func=_cmd_cron)
    cra = crsub.add_parser("add", help="upsert a schedule row")
    cra.add_argument("--name", required=True)
    cra.add_argument("--cadence", required=True, help="every 5m | every 1h | daily 04:00")
    cra.add_argument("--task", default="")
    cra.add_argument("--owner", default="c1")
    cra.add_argument("--verb", default="job.create")
    cra.set_defaults(func=_cmd_cron)

    rt = sub.add_parser("runtime", help="headless runner (launchd): drain + goal ticks, cron when asked")
    rtsub = rt.add_subparsers(dest="runtime_cmd", required=True)
    rtr = rtsub.add_parser("run", help="keep draining (and ticking cron unless --no-cron)")
    rtr.add_argument("--interval", type=float, default=30.0)
    rtr.add_argument("--no-cron", action="store_true")
    rtr.set_defaults(func=_cmd_runtime)
    rts = rtsub.add_parser("status", help="the runner's heartbeat (JSON)")
    rts.add_argument("--json", action="store_true", help="(the output is JSON either way)")
    rts.set_defaults(func=_cmd_runtime)
    rti = rtsub.add_parser("install-agent", help="write and load the runner's launchd agent (no checkout needed)")
    rti.add_argument("--json", action="store_true")
    rti.set_defaults(func=_cmd_runtime)

    dc = sub.add_parser("doctor", help="is this Mac ready: Python, tmux, the pong command, the runner, each AI, the keys")
    dc.add_argument("--json", action="store_true")
    dc.set_defaults(func=_cmd_doctor)

    ky = sub.add_parser("keys", help="keys typed into Settings (Jev, Perplexity): set or not, never the key itself")
    kysub = ky.add_subparsers(dest="keys_cmd", required=True)
    kys = kysub.add_parser("status", help="set or not, where from, and whether each is switched on")
    kys.add_argument("--json", action="store_true")
    kys.set_defaults(func=_cmd_keys)
    for name, hlp in (("set", "save a key (read from stdin, never an argument; never shown)"),
                      ("clear", "remove the key Settings saved (a key from anywhere else is left alone)")):
        p_ = kysub.add_parser(name, help=hlp)
        p_.add_argument("--name", required=True, choices=["jev", "perplexity"])
        p_.add_argument("--json", action="store_true")
        p_.set_defaults(func=_cmd_keys)

    lm = sub.add_parser("limits", help="Claude's usage limits: what the runner is holding, and Resume")
    lmsub = lm.add_subparsers(dest="limits_cmd", required=True)
    lms = lmsub.add_parser("status", help="the limit state (ok, paused at the 5-hour limit, paused for the week) and the switches")
    lms.add_argument("--json", action="store_true")
    lms.set_defaults(func=_cmd_limits)
    lmr = lmsub.add_parser("resume", help="lift the limit pauses now (the same limit does not pause again until its reset)")
    lmr.add_argument("--json", action="store_true")
    lmr.set_defaults(func=_cmd_limits)

    # Candidate references for a gauntlet bar. Read-only: it proposes rows, a
    # person picks which become the bar.
    ex = sub.add_parser("examples", help="search live web references as a quality bar")
    exsub = ex.add_subparsers(dest="examples_cmd", required=True)
    exs = exsub.add_parser("search", help='pong examples search "query" [--json] [--limit N]')
    exs.add_argument("query", nargs="+", help="what to look for")
    exs.add_argument("--json", action="store_true", help="machine-readable list on stdout")
    exs.add_argument("--limit", type=int, default=8)
    exs.set_defaults(func=_cmd_examples)

    return p


#: The words ``pong jev key …`` and ``pong keys …`` take: anything else there is likely a key typed as an
#: argument, which argparse would print back ("unrecognized arguments: <the key>").
_KEY_WORDS = {"jev": {"set", "clear", "test", "--json", "-h", "--help"},
              "keys": {"status", "set", "clear", "--json", "--name", "jev", "perplexity", "-h", "--help",
                       "--name=jev", "--name=perplexity"}}


def _key_typed_as_argument(argv: list[str]) -> str:
    """The command to use instead when a key command was given a word it does not take (likely the key
    itself, which must come on standard input: argv shows in `ps` and argparse would print it back), or ""."""
    rest: list[str] = []
    i = 0
    while i < len(argv):
        t = str(argv[i])
        if t in ("-s", "--session"):
            i += 2
            continue
        if not t.startswith("--session="):
            rest.append(t)
        i += 1
    if rest[:2] == ["jev", "key"]:
        words, allowed = rest[2:], _KEY_WORDS["jev"]
        hint = "pong jev key set < file"
    elif rest[:1] == ["keys"]:
        words, allowed = rest[1:], _KEY_WORDS["keys"]
        name = "jev" if "jev" in words or "--name=jev" in words else "perplexity"
        hint = f"pong keys set --name {name} < file"
    else:
        return ""
    return hint if any(w not in allowed for w in words) else ""


def main(argv: list[str] | None = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    hint = _key_typed_as_argument(argv)
    if hint:  # never the word itself: it may be the key
        print(f"error: Paste the key on standard input, not as an argument: {hint}", file=sys.stderr)
        return 2
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        return int(args.func(args) or 0)
    except SystemExit:
        raise
    except Exception as e:  # the island shows stderr; a traceback is not a sentence
        if os.environ.get("PONG_DEBUG"):
            raise
        print(f"error: {type(e).__name__}: {e}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
