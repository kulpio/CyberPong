#!/usr/bin/env python3
"""Python-layer proof for the cron token fix — the refusal lives in routing.py.

Takes the shell script the Swift harness captured out of CronSchedule.file()
(tests/swift/.out/captured.json, so this is the app's real command shape, not a
paraphrase) and runs it through /bin/bash exactly the way Pong.sh does, against
a THROWAWAY session inside a temp PONG_HOME. Never pong-team, never ~/.pong.

  1. old shape (no PONG_TOKEN)  -> refused, "caller=none"
  2. new shape (token exported) -> accepted, job_id= and a job file on disk
  3. ps on the live bash -c     -> the token PATH is in argv, the token is not

Run: tests/swift/run.sh && tests/swift/token_proof.py
"""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import uuid
from pathlib import Path

HERE = Path(__file__).resolve().parent
CAPTURED = HERE / ".out" / "captured.json"

# Anything that could make the CLI think it is a real seat in a real team.
SCRUB = [
    "PONG_SESSION", "PONG_SEAT", "PONG_TOKEN", "PONG_SESSION_TOKEN", "PONG_ROLE",
    "HERMES_PONG_SESSION", "HERMES_PONG_ROLE", "TMUX", "TMUX_PANE",
]

fails = 0


def check(ok: bool, label: str, detail: str = "") -> None:
    global fails
    if ok:
        print(f"  ok   {label}")
    else:
        fails += 1
        print(f"  FAIL {label}")
        if detail:
            print("       " + detail.replace("\n", "\n       "))


def run(script: str, home: Path) -> subprocess.CompletedProcess:
    env = {k: v for k, v in os.environ.items() if k not in SCRUB}
    env["PONG_HOME"] = str(home)          # isolation only — the app never sets this
    return subprocess.run(
        ["/bin/bash", "-c", script],
        capture_output=True, text=True, env=env, timeout=120,
    )


def main() -> int:
    if not CAPTURED.is_file():
        print(f"error: {CAPTURED} missing — run tests/swift/run.sh first", file=sys.stderr)
        return 2
    cap = json.loads(CAPTURED.read_text())
    script = cap["script"]

    home = Path(tempfile.mkdtemp(prefix="pong-token-proof-"))
    session = "throwaway-cron-proof-" + uuid.uuid4().hex[:6]   # never pong-team
    try:
        (home / "sessions" / session).mkdir(parents=True, exist_ok=True)
        pairs = {
            session: {
                "schema_version": 2,
                "conductor": {"id": "c1", "type": "grok", "label": "Grok", "cmd": "grok",
                              "mode": "tmux", "tmux_index": 0},
                "workers": [{"id": "w1", "type": "claude", "label": "Claude", "cmd": "claude",
                             "mode": "tmux", "tmux_index": 1,
                             "done_marker": "##CLAUDE_DONE##"}],
                "transport_default": "job",      # job-file only: wakes nothing
                "project_root": str(home),
                "team_brief": "throwaway — token proof",
            }
        }
        (home / "pairs.json").write_text(json.dumps(pairs), encoding="utf-8")

        task = home / "task.md"
        task.write_text("Throwaway task — token proof only.\n", encoding="utf-8")

        # The token the control plane itself creates, at the path Swift reads.
        ens = run(f'export PYTHONPATH="$HOME/.pong/lib"; '
                  f'python3 -m pong.cli.main -s {session} token ensure', home)
        token_path = home / "sessions" / session / "token"
        check(token_path.is_file(), "routing.ensure_session_token created the token file",
              ens.stdout + ens.stderr)
        token = token_path.read_text().strip()
        check(bool(token), "token is non-empty")
        print(f"  ->   session={session}  token_path={token_path}  (PONG_HOME={home})")

        # Re-point the captured script at the throwaway session / paths. --no-paste
        # is the one addition the app does not make: nothing may wake a seat here.
        new_script = (script
                      .replace(cap["token_path"], str(token_path))
                      .replace(f"-s {cap['session']} ", f"-s {session} ")
                      .replace("--worker c1", "--worker w1"))
        new_script = re.sub(r"--file '[^']*'", f"--file '{task}' --no-paste", new_script)
        check("export PONG_TOKEN=\"$(cat '" + str(token_path) + "'" in new_script,
              "script under test reads the token by path", new_script)

        # The pre-fix shape is this one minus the export line.
        old_script = "\n".join(l for l in new_script.splitlines()
                               if not l.strip().startswith("export PONG_TOKEN="))

        print("\n--- 1. OLD shape (no PONG_TOKEN) — what the eight live crons ran ---")
        print(old_script)
        r_old = run(old_script, home)
        out_old = (r_old.stdout + r_old.stderr).strip()
        print(f"  exit={r_old.returncode}\n  {out_old}")
        check("refused" in out_old and "PONG_TOKEN" in out_old, "refused")
        check("caller=none" in out_old, "message says caller=none — the live Pong.log line")
        check("job_id=" not in out_old, "no job was created")

        jobs_dir = home / "jobs" / session
        check(not list(jobs_dir.glob("job_*.json")) if jobs_dir.is_dir() else True,
              "no job file on disk after the refusal")

        print("\n--- 2. NEW shape (token read from the file by bash) ---")
        print(new_script)
        r_new = run(new_script, home)
        out_new = (r_new.stdout + r_new.stderr).strip()
        print(f"  exit={r_new.returncode}\n  {out_new}")
        check("job_id=" in out_new, "accepted — job_id printed", out_new)
        check("refused" not in out_new, "no refusal", out_new)
        check(token not in out_new, "the token value is not echoed anywhere in the output")
        created = sorted(jobs_dir.glob("job_*.json")) if jobs_dir.is_dir() else []
        check(len(created) == 1, f"exactly one job file written ({[p.name for p in created]})")

        print("\n--- 3. ps against the live `bash -c` — token path in argv, token not ---")
        argv_file = home / "argv.txt"
        probe = "\n".join(l for l in new_script.splitlines()
                          if not l.strip().startswith("python3 -m pong.cli.main"))
        probe += (f'\nps -ww -o args= -p $$ > "{argv_file}"\n'
                  f'[ -n "$PONG_TOKEN" ] && echo TOKEN_REACHED_ENV=yes\n')
        r_ps = run(probe, home)
        argv = argv_file.read_text() if argv_file.is_file() else ""
        print(f"  ps argv: {argv.strip()[:400]}")
        check("TOKEN_REACHED_ENV=yes" in r_ps.stdout, "the token did reach the process environment")
        check(token not in argv, "the token value is NOT in the bash -c argv", argv)
        check(str(token_path) in argv, "only the token PATH is in argv")
    finally:
        shutil.rmtree(home, ignore_errors=True)

    print(f"\n{'FAILED (%d)' % fails if fails else 'OK'}")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
