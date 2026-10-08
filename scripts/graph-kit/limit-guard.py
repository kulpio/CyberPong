#!/usr/bin/env python3
"""Keep a team's graphs alive through Claude's usage limits while nobody is at the Mac.

    python3 limit-guard.py --team pong-team-N [--week-alert 97] [--fable-alert 90] <graph id> [...]
    python3 limit-guard.py --probe [--team pong-team-N]      (print the usage it reads, then exit)

Run it in the background from the Claude session that runs the graphs. The session runs on the same
Claude account as the seats, so when a limit hits, the session is blocked too: whatever must happen
at the limit has to happen here, without it.

How it reads usage: an idle Claude Code pane (tmux session `usage-probe`, started here if missing, in
the team's project folder so no trust question appears) shows `/usage`, which costs no model tokens.
Every 3 minutes it reads the session, weekly and Fable percentages and their reset times. Every minute
it also reads the screens of the running steps' Claude seats for a usage-limit message.

What it does:
- The 5-hour limit is hit (session at 99% or a seat shows the limit): it pauses each watched graph
  (`goal pause`, which holds new dispatches; nothing is lost), waits for the reset time, checks usage
  fell, lifts only the pauses it made (a bare `goal resume` on a manually paused graph lifts the pause
  and never answers a gate), tells each blocked Claude seat to continue, and exits so the session wakes.
  A step's timeout keeps counting during the pause; a step that times out is retried after the resume.
- This week passes --week-alert (default 85) or Fable's week passes --fable-alert (default 90): it exits
  with that line, so the session can act while it still can (the weekly "Reset for free" button is on
  claude.ai; it has to be pressed before the limit, because at the limit the session is blocked too).
- A weekly limit is actually hit (or a seat's limit resets more than six hours out): it pauses the
  graphs and exits with that line; only a reset brings them back.
- A Claude seat stopped on an API or network error (the Mac lost its connection) is told to continue
  once the network answers: at most three times per step, 15 minutes apart, never within 10 minutes of
  the step's timeout (the engine retries it then).
- Nothing is typed into a seat that shows a question, a menu or a permission prompt (Enter there would
  answer it): only into Claude's empty input line.
While it runs it writes ~/.pong/sessions/<team>/graph-kit/limit-state.json: a heartbeat every minute, and
the limit while it holds one. watch.py stays quiet while a limit is held, and CyberPong's runner leaves the
team to this guard while the file is fresh, so the two never pause or resume the same graphs.

Since 2.0 the runner does all of this by itself for every team (Settings › Limits & keys; `pong limits
status`). Run this guard by hand only for its early alerts (--week-alert, --fable-alert), or when the
person switched the runner's handling off. The reading and the regular expressions are the engine's
(pong.limits) when it is installed beside this file, so the two read a screen the same way.
"""

import argparse, json, os, re, subprocess, sys, time
from datetime import datetime, timedelta

HOME = os.path.expanduser("~")
PONG_HOME = os.environ.get("PONG_HOME") or os.path.join(HOME, ".pong")
PONG = os.environ.get("PONG_BIN") or f"{HOME}/bin/pong"
PROBE = "usage-probe"
# Claude Code's own limit banner only: it starts the line and names its reset (a reply, test output or a
# diff quoting these words is not a limit). The same as pong.limits.LIMIT_LINE.
LIMIT_LINE = re.compile(
    r"^[ \t⎿⏺●⚠]*(?:claude (?:ai )?usage limit reached|"
    r"(?:(?:opus|fable|sonnet) )?(?:5-hour|session|weekly|usage|opus|fable|sonnet) limit reached|"
    r"you(?:['’]ve| have) hit your (?:session |weekly |usage |5-hour |opus |fable |sonnet )?limit|"
    r"you(?:['’]re| are) out of (?:extra )?usage)\b.*\b(?:resets?|will reset)\b", re.I)
# A screen waiting for a person (a permission prompt, a menu): Enter there takes "1. Yes", so nothing is typed.
ASKING = re.compile(r"enter to select|↑/↓ to navigate|arrow keys to navigate|tab/arrow keys|esc to cancel|"
                    r"do you want to (proceed|make this edit|create|run|allow|continue)|allow (reads|writes|this)|"
                    r"permission to|❯\s*\d+\.|\b1\. yes\b", re.I)
TIME_RX = re.compile(r"(?:(\b[A-Z][a-z]{2})\s+(\d{1,2})\s+at\s+)?(\d{1,2})(?::(\d{2}))?\s*(am|pm)", re.I)
NUDGE = "Your usage limit has reset. Please continue the job you were working on, from where you stopped."
NET_ERR = re.compile(r"api error|can't reach the api server|enotfound|econnrefused|econnreset|network error|fetch failed|"
                     r"overloaded|request timed out|internal server error|connection error", re.I)
NET_NUDGE = "The connection is back. Please continue the job you were working on, from where you stopped."
NUDGES = {}  # (graph, node, started_at) -> [times]: at most 3 network nudges per step visit, 15 minutes apart
TEAM = ""


def _shared():
    """pong.limits, when the engine sits beside this file (installed, bundled or a checkout); else None."""
    here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    for root in (here, os.path.join(here, "python"), os.path.join(os.path.dirname(here), "python")):
        if os.path.isfile(os.path.join(root, "pong", "limits.py")) and root not in sys.path:
            sys.path.insert(0, root)
            break
    try:
        from pong import limits
        return limits
    except Exception:
        return None


L = _shared()
if L is not None:  # one reading of a screen, shared with the runner
    LIMIT_LINE, TIME_RX, NUDGE, NET_ERR, NET_NUDGE = L.LIMIT_LINE, L.TIME_RX, L.NUDGE, L.NET_ERR, L.NET_NUDGE
    ASKING = getattr(L, "ASKING", ASKING)


def ready_for_input(text):
    """Claude finished its turn and shows its empty input line: the only screen a line is typed into."""
    if L is not None and hasattr(L, "ready_for_input"):
        return L.ready_for_input(text)
    lines = [ln.rstrip() for ln in (text or "").splitlines() if ln.strip()]
    tail = lines[-12:]
    if not tail or any("esc to interrupt" in ln for ln in tail[-4:]) or any(ASKING.search(ln) for ln in tail):
        return False
    for ln in reversed(tail[-8:]):
        s = ln.strip().strip("│").strip()
        if s.startswith(("❯", ">")):
            rest = s[1:].strip()
            return rest == "" or rest.startswith('Try "')
    return False


def type_line(pid, text):
    """Type a line and Enter into a seat, only when its screen (read again now) is Claude's empty input line."""
    r = sh(["tmux", "capture-pane", "-p", "-J", "-t", pid, "-S", "-30"], timeout=20)
    if r.returncode != 0 or not ready_for_input(r.stdout):
        return False
    sh(["tmux", "send-keys", "-t", pid, "-l", text])
    time.sleep(1)
    sh(["tmux", "send-keys", "-t", pid, "Enter"])
    return True


def log(msg):
    print(f"{datetime.now():%H:%M} {msg}", flush=True)


def sh(args, timeout=60):
    try:
        return subprocess.run(args, capture_output=True, text=True, timeout=timeout)
    except Exception as e:
        return subprocess.CompletedProcess(args, 1, "", str(e))


def kit_dir(team):
    d = os.path.join(PONG_HOME, "sessions", team, "graph-kit")
    os.makedirs(d, exist_ok=True)
    return d


def panes():
    try:
        with open(os.path.join(PONG_HOME, "sessions", TEAM, "panes.json")) as f:
            return json.load(f)
    except Exception:
        return {}


def project_root(team):
    try:
        with open(os.path.join(PONG_HOME, "pairs.json")) as f:
            root = str((json.load(f).get(team) or {}).get("project_root") or "")
        return root if root and os.path.isdir(root) else HOME
    except Exception:
        return HOME


def next_time(text, now=None):
    """The next moment matching '2:20am' or 'Oct 1 at 11am' in the Mac's local time, or None."""
    if L is not None:
        return L.next_time(text, now)
    m = TIME_RX.search(text or "")
    if not m:
        return None
    now = now or datetime.now()
    mon, day, hh, mm, ap = m.groups()
    h = int(hh) % 12 + (12 if ap.lower() == "pm" else 0)
    mi = int(mm or 0)
    if mon:
        try:
            t = datetime.strptime(f"{mon} {day} {now.year} {h}:{mi}", "%b %d %Y %H:%M")
        except ValueError:
            return None
        if t < now - timedelta(days=1):
            t = t.replace(year=now.year + 1)
        return t
    t = now.replace(hour=h, minute=mi, second=0, microsecond=0)
    return t if t > now - timedelta(minutes=5) else t + timedelta(days=1)


def ensure_probe(cwd):
    if sh(["tmux", "has-session", "-t", PROBE]).returncode == 0:
        return True
    r = sh(["tmux", "new-session", "-d", "-s", PROBE, "-x", "160", "-y", "50", "-c", cwd, "claude --strict-mcp-config"])
    time.sleep(10)
    return r.returncode == 0


def probe_usage(cwd=HOME):
    """{'session': (pct, reset), 'week': (...), 'fable': (...)} from `/usage`, or {} when it cannot be read."""
    if not ensure_probe(cwd):
        return {}
    sh(["tmux", "send-keys", "-t", PROBE, "Escape"])
    time.sleep(1)
    sh(["tmux", "send-keys", "-t", PROBE, "-l", "/usage"])
    time.sleep(1)
    sh(["tmux", "send-keys", "-t", PROBE, "Enter"])
    time.sleep(6)
    out = sh(["tmux", "capture-pane", "-p", "-t", PROBE, "-S", "-80"]).stdout
    sh(["tmux", "send-keys", "-t", PROBE, "Escape"])
    if L is not None:
        res = {k: v for k, v in L.parse_usage(out).items() if k != "credits"}
    else:
        lines = [ln.strip() for ln in out.splitlines() if ln.strip()]
        res = {}
        for key, head in (("session", "Current session"), ("week", "Current week (all models)"), ("fable", "Current week (Fable)")):
            for i, ln in enumerate(lines):
                if ln.startswith(head):
                    pct = next((int(m.group(1)) for x in lines[i + 1:i + 3] for m in [re.search(r"(\d+)% used", x)] if m), None)
                    rs = next((x for x in lines[i + 1:i + 4] if x.startswith("Resets")), "")
                    if pct is not None:
                        res[key] = (pct, next_time(rs))
                    break
    if not res:  # an update or trust screen took the pane: start it again next time
        sh(["tmux", "kill-session", "-t", PROBE])
    return res


def graphs(ids):
    try:
        d = json.loads(sh([PONG, "-s", TEAM, "graph", "list", "--json"], timeout=120).stdout)
    except Exception:
        return []
    return [g for g in d.get("graphs", []) if g.get("id") in ids]


def pane(seat):
    pid = (panes().get(seat) or {}).get("pane_id")
    if not pid:
        return None, None
    r = sh(["tmux", "capture-pane", "-p", "-J", "-t", pid, "-S", "-30"], timeout=20)
    return (pid, r.stdout) if r.returncode == 0 else (pid, None)


def claude_seat(seat):
    return (panes().get(seat) or {}).get("start_command") == "claude"


def limited_seats(gs):
    """[(graph id, node id, seat, pane id, limit line)] for running Claude steps whose screen shows a usage limit."""
    out = []
    for g in gs:
        for n in g.get("nodes") or []:
            if n.get("status") != "running":
                continue
            pid, text = pane(str(n.get("seat") or ""))
            if not text:
                continue
            tail = [ln for ln in text.splitlines() if ln.strip()][-8:]
            if any("esc to interrupt" in ln for ln in tail[-4:]):
                continue  # working
            hit = next((ln.strip() for ln in reversed(tail) if LIMIT_LINE.search(ln)), None)
            if hit:
                out.append((g["id"], n["id"], n.get("seat"), pid, hit[:160]))
    return out


def network_ok():
    r = sh(["curl", "-s", "-o", "/dev/null", "-m", "10", "-w", "%{http_code}", "https://api.anthropic.com"], timeout=20)
    return r.returncode == 0 and r.stdout.strip() not in ("", "000")


def nudge_network_errors(gs):
    """A running Claude step whose seat stopped on an API or network error: once the network answers, tell it to go on."""
    done = []
    for g in gs:
        bnd = g.get("boundaries") or {}
        for n in g.get("nodes") or []:
            if n.get("status") != "running" or not claude_seat(str(n.get("seat") or "")):
                continue
            pid, text = pane(str(n.get("seat") or ""))
            if not text:
                continue
            tail = [ln for ln in text.splitlines() if ln.strip()][-8:]
            if any("esc to interrupt" in ln for ln in tail[-4:]) or any(LIMIT_LINE.search(ln) for ln in tail):
                continue
            if not any(NET_ERR.search(ln) for ln in tail):
                continue
            started = float(n.get("started_at") or 0)
            tmo = float(n.get("timeout_min") or bnd.get("node_timeout_min") or 120) * 60
            if started and time.time() - started > tmo - 600:
                continue  # the engine times it out and retries it soon; a nudge now would be cut off
            key = (g["id"], n["id"], started)
            past = NUDGES.setdefault(key, [])
            if not ready_for_input(text) or n.get("attention"):
                continue  # a permission prompt or a menu: the person's to answer
            if len(past) >= 3 or (past and time.time() - past[-1] < 900) or not network_ok():
                continue
            if not type_line(pid, NET_NUDGE):
                continue
            past.append(time.time())
            done.append(f"{n['id']} on {n.get('seat')}")
    if done:
        log("told to continue after an API or network error: " + ", ".join(done))


def save(st):
    """The guard's state, always with its pid: the runner leaves this team alone while the guard is alive."""
    path = os.path.join(kit_dir(TEAM), "limit-state.json")
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump({**st, "pid": os.getpid()}, f)
    os.replace(tmp, path)


def beat():
    """A heartbeat, once a minute: the runner skips a team whose guard beat in the last five minutes."""
    path = os.path.join(kit_dir(TEAM), "limit-state.json")
    try:
        with open(path) as f:
            st = json.load(f)
        st = st if isinstance(st, dict) else {}
    except Exception:
        st = {}
    st["beat_at"] = time.time()
    try:
        save(st)
    except OSError:
        pass


def drop_state():
    try:
        os.remove(os.path.join(kit_dir(TEAM), "limit-state.json"))
    except OSError:
        pass


def ride_out(ids, until, why, cwd, weekly=False):
    """Pause, wait for the reset, lift only our pauses, nudge the blocked seats. Returns the lines to report."""
    report = [f"Usage limit: {why}. Pausing the runs until {until:%a %H:%M}."]
    mine = []
    for g in graphs(ids):
        p = g.get("paused") if isinstance(g.get("paused"), dict) else None
        if g.get("status") == "running" and not (p and p.get("manual")):
            if sh([PONG, "-s", TEAM, "goal", "pause", "--id", g["id"]]).returncode == 0:
                mine.append(g["id"])
    report.append(f"Paused: {', '.join(mine) or 'none (already paused or not running)'}.")
    save({"limited_until": until.timestamp(), "why": why, "paused": mine, "at": time.time()})
    log(" ".join(report))
    if weekly:
        return report + ["A weekly limit does not reset for days: press 'Reset for free' (Settings, Usage), then resume the runs with "
                         f"`pong -s {TEAM} goal resume --id <id>` for each graph named above."]
    while datetime.now() < until + timedelta(minutes=2):
        beat()
        time.sleep(60)
    for _ in range(12):  # up to an hour past the stated reset
        u = probe_usage(cwd)
        if u.get("session") and u["session"][0] < 95 and (not u.get("week") or u["week"][0] < 100):
            break
        time.sleep(300)
    lifted = []
    for g in graphs(ids):
        p = g.get("paused") if isinstance(g.get("paused"), dict) else None
        # only a pause this guard made, and only while it is still a manual pause: a bare resume on a
        # graph with an open gate and no manual pause would answer the gate
        if g["id"] in mine and g.get("status") == "running" and p and p.get("manual"):
            if sh([PONG, "-s", TEAM, "goal", "resume", "--id", g["id"]]).returncode == 0:
                lifted.append(g["id"])
    time.sleep(20)
    nudged = []
    for gid, nid, seat, pid, _ in limited_seats(graphs(ids)):
        if type_line(pid, NUDGE):  # never into a question or a menu: Enter would answer it
            nudged.append(f"{nid} on {seat}")
    drop_state()
    return report + [f"Limit over at {datetime.now():%H:%M}. Pause lifted on: {', '.join(lifted) or 'none'}.",
                     f"Told to continue: {', '.join(nudged) or 'no seat was still showing the limit'}."]


def main():
    global TEAM
    ap = argparse.ArgumentParser(description="Ride a team's graphs through Claude's usage limits.")
    ap.add_argument("--team", default=os.environ.get("PONG_SESSION"), help="the CyberPong team (pong-team-N)")
    ap.add_argument("--probe", action="store_true", help="print the usage it reads, then exit")
    ap.add_argument("--week-alert", type=int, default=85, help="exit with an alert at this weekly %% (raise it once handled)")
    ap.add_argument("--fable-alert", type=int, default=90, help="exit with an alert at this Fable weekly %%")
    ap.add_argument("ids", nargs="*", help="graph ids to guard")
    a = ap.parse_args()
    TEAM = a.team or ""
    cwd = project_root(TEAM) if TEAM else HOME
    if a.probe:
        u = probe_usage(cwd)
        for k, (pct, t) in u.items():
            print(f"{k}: {pct}% used, resets {t:%a %d %b %H:%M}" if t else f"{k}: {pct}% used, reset time unread")
        if not u:
            print("usage could not be read")
        return
    if not TEAM or not a.ids:
        sys.exit("name the team with --team pong-team-N and the graph ids to guard")
    try:
        watch(a, cwd)
    finally:
        end()


def end():
    """The guard stops: a heartbeat alone goes (the runner takes the team back at once); a weekly hold
    stays for watch.py, and the runner sees its guard is gone."""
    path = os.path.join(kit_dir(TEAM), "limit-state.json")
    try:
        with open(path) as f:
            st = json.load(f)
    except Exception:
        return
    if not isinstance(st, dict) or not st.get("limited_until"):
        drop_state()
        return
    st.pop("beat_at", None)
    try:
        save(st)
    except OSError:
        pass


def watch(a, cwd):
    last_probe, u = 0.0, {}
    while True:
        beat()
        if time.time() - last_probe > 180:
            u = probe_usage(cwd) or u
            last_probe = time.time()
        gs = graphs(a.ids)
        if gs and all(g.get("status") != "running" for g in gs):
            print(f"{datetime.now():%H:%M} every guarded graph has stopped; the guard ends")
            return
        seats = limited_seats(gs)
        nudge_network_errors(gs)
        s, w, f = u.get("session"), u.get("week"), u.get("fable")
        far = [x for x in seats if next_time(x[4]) and next_time(x[4]) - datetime.now() > timedelta(hours=6)]
        if (w and w[0] >= 100) or any("week" in x[4].lower() for x in seats) or far:
            until = (w[1] if w and w[1] else datetime.now() + timedelta(days=1))
            print("\n".join(ride_out(a.ids, until, f"the weekly limit is reached ({w[0] if w else '?'}% this week)", cwd, weekly=True)))
            return
        if (s and s[0] >= 99) or seats:
            until = (s[1] if s and s[1] else None) or next((next_time(x[4]) for x in seats if next_time(x[4])), None) \
                or datetime.now() + timedelta(minutes=30)
            why = f"the 5-hour limit ({s[0] if s else '?'}% of this session)" + (f"; seats showing it: {len(seats)}" if seats else "")
            print("\n".join(ride_out(a.ids, until, why, cwd)))
            return
        if w and w[0] >= a.week_alert:
            print(f"{datetime.now():%H:%M} This week's Claude usage is at {w[0]}% (resets {w[1]:%a %d %b %H:%M}); press 'Reset for free' "
                  "before it reaches 100%, or the runs stop until the reset." if w[1] else f"This week's Claude usage is at {w[0]}%.")
            return
        if f and f[0] >= a.fable_alert:
            print(f"{datetime.now():%H:%M} Fable's weekly usage is at {f[0]}%; move the Fable steps (writer, critic) to Opus in "
                  f"~/.pong/sessions/{TEAM}/models/catalog.json before it runs out.")
            return
        time.sleep(60)


if __name__ == "__main__":
    main()
