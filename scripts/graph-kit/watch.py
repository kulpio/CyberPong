#!/usr/bin/env python3
"""Wake the Claude session that runs a graph when the graph needs it.

    python3 watch.py --team <team> <graph id> [<graph id> ...]

Run it in the background from a Claude session: it exits (printing why) when
- a gate opens, a seat needs a look, a running step is quiet 25+ minutes, or a graph stops;
- a running step's seat is blocked on its screen: a login, a folder-trust or "allow reads" question,
  a permission dialog, a usage or rate limit, an API error, or a bare shell where the agent should be.
The session is woken when it exits. Read-only: it runs `pong graph list --json` and reads the seats'
screens with `tmux capture-pane`. A blocker already reported is reported again only if it is still
there 30 minutes later (state in ~/.pong/sessions/<team>/graph-kit/watch-state.json: graph and step
ids, never screen text). A Claude usage limit or a network error on a Claude seat is left to
limit-guard.py, and while that guard holds a limit this watcher stays quiet: the session could not
act anyway, and a wake-up it cannot answer is lost.

It works for any team on this Mac, and with any graph: it catches, for example, a plan step that went
quiet after a network outage.
"""

import argparse, json, os, re, subprocess, sys, time

HOME = os.path.expanduser("~")
PONG = os.environ.get("PONG_BIN") or f"{HOME}/bin/pong"
REPORT_AGAIN_S = 30 * 60
QUIET_S = 25 * 60

# phrases that mean a person (or Claude) must act on the seat's screen; read only when the step is not working
BLOCKERS = [
    ("folder trust", r"trust the files in this folder|is this a project you created or one you trust|do you trust the contents of this directory|trust this folder"),
    ("reads outside the working folder", r"allow reads? outside|outside (of )?the working director"),
    ("permission question", r"do you want to (proceed|make this edit|create|run|allow)|allow this (command|tool)|requires approval"),
    ("login", r"select login method|please run /login|run /login|not logged in|invalid api key|oauth token (has )?expired|authentication_error|api error: 401|grok login|please (log|sign) in|unauthorized"),
    ("usage or rate limit", r"usage limit|limit reached|you've hit your|credit balance is too low|api error: (429|529)|overloaded_error|rate[ _-]?limit(ed)? (hit|exceeded|reached)|quota (exceeded|reached)"),
    ("API error", r"api error|can't reach the api server|enotfound|econnrefused|request timed out|connection error|fetch failed"),
    ("press enter", r"press enter to continue"),
]
AGENT_UI = re.compile(r"esc to interrupt|⏵⏵|shift\+tab|ctrl\+x:shortcuts|always-approve|╭|╰|❯")
SHELL_PROMPT = re.compile(r"(^|\s)[\w.@~/:-]*[%$#]\s*$")
LONG_TOKEN = re.compile(r"[A-Za-z0-9_\-]{32,}")


def kit_dir(team):
    d = os.path.join(HOME, ".pong", "sessions", team, "graph-kit")
    os.makedirs(d, exist_ok=True)
    return d


def load_json(path, default):
    try:
        with open(path) as f:
            return json.load(f)
    except Exception:
        return default


def save_json(path, data):
    try:
        tmp = path + ".tmp"
        with open(tmp, "w") as f:
            json.dump(data, f)
        os.replace(tmp, path)
    except Exception:
        pass


def panes(team):
    return load_json(os.path.join(HOME, ".pong", "sessions", team, "panes.json"), {})


def pane_text(team, seat):
    pid = (panes(team).get(seat) or {}).get("pane_id")
    if not pid:
        return None, "no pane recorded for this seat"
    r = subprocess.run(["tmux", "capture-pane", "-p", "-t", pid, "-S", "-40"], capture_output=True, text=True, timeout=20)
    if r.returncode != 0:
        return None, "its tmux pane is gone"
    lines = [ln.rstrip() for ln in r.stdout.splitlines()]
    while lines and not lines[-1].strip():
        lines.pop()
    return lines, None


def claude_seat(team, seat):
    return (panes(team).get(seat) or {}).get("start_command") == "claude"


def blocked(lines):
    """(kind, line) when the screen shows a blocker, else None."""
    tail = lines[-30:]
    for kind, pat in BLOCKERS:
        rx = re.compile(pat)
        for ln in tail:
            if rx.search(ln.lower()):
                return kind, LONG_TOKEN.sub("<…>", ln.strip())[:140]
    last = [ln for ln in tail if ln.strip()][-6:]
    if last and not any(AGENT_UI.search(ln) for ln in last) and SHELL_PROMPT.search(last[-1]):
        return "bare shell (the agent is not running)", LONG_TOKEN.sub("<…>", last[-1].strip())[:140]
    return None


def main():
    ap = argparse.ArgumentParser(description="Exit with a line when a graph needs its Claude session.")
    ap.add_argument("--team", default=os.environ.get("PONG_SESSION"), help="the CyberPong team (pong-team-N)")
    ap.add_argument("ids", nargs="+", help="graph ids to watch")
    a = ap.parse_args()
    if not a.team:
        sys.exit("name the team with --team pong-team-N")
    state_path = os.path.join(kit_dir(a.team), "watch-state.json")
    limit_path = os.path.join(kit_dir(a.team), "limit-state.json")  # written by limit-guard.py
    st = load_json(state_path, {})
    seen_attention = set()
    while True:
        lim = load_json(limit_path, {})
        if time.time() < float(lim.get("limited_until") or 0) + 600:
            time.sleep(60)
            continue
        try:
            out = subprocess.run([PONG, "-s", a.team, "graph", "list", "--json"],
                                 capture_output=True, text=True, timeout=120).stdout
            d = json.loads(out)
        except Exception:
            time.sleep(60)
            continue
        events = []
        now = time.time()
        for g in d.get("graphs", []):
            if g.get("id") not in a.ids:
                continue
            title = f"{g['id']} ({g.get('title')})"
            if g.get("status") != "running":
                events.append(f"{title} stopped: {g.get('status')} {g.get('stop_reason')}")
            for gt in g.get("gates") or []:
                events.append(f"{title} gate open at {gt.get('node')}: {gt.get('reason')}")
            for at in g.get("attention") or []:
                key = (g["id"], at.get("node"), at.get("what"))
                if key not in seen_attention:
                    events.append(f"{title} needs a look: {at.get('node')} on {at.get('seat')}: {at.get('what')}")
                    seen_attention.add(key)
            for n in g.get("nodes") or []:
                if n.get("status") != "running":
                    continue
                lv = n.get("live") or {}
                if lv.get("state") == "quiet" and lv.get("changed_at") and now - lv["changed_at"] > QUIET_S:
                    key = f"{g['id']}|{n['id']}|quiet"
                    if now - st.get(key, 0) > REPORT_AGAIN_S:
                        events.append(f"{title} quiet 25+ min: {n['id']} on {n.get('seat')}")
                        st[key] = now
                if lv.get("state") == "working":
                    continue  # a working seat's screen scrolls with its own output; do not read phrases into it
                seat = str(n.get("seat") or "")
                lines, problem = pane_text(a.team, seat)
                found = ("pane", problem) if problem else (blocked(lines) if lines else None)
                if found and found[0] in ("usage or rate limit", "API error") and claude_seat(a.team, seat):
                    found = None  # limit-guard.py rides out Claude limits and nudges Claude seats after a network error
                if found:
                    key = f"{g['id']}|{n['id']}|{found[0]}"
                    if now - st.get(key, 0) > REPORT_AGAIN_S:
                        events.append(f"{title} seat blocked: {n['id']} on {seat}: {found[0]}: {found[1]}")
                        st[key] = now
        if events:
            save_json(state_path, st)
            print("\n".join(events))
            sys.exit(0)
        time.sleep(60)


if __name__ == "__main__":
    main()
