# UI contract (foundation)

The macOS panel (and any future dashboard) is a **read-mostly consumer** of the control plane.  
It must not invent job state, invent worker rosters, or use tmux paste as truth.

## Principle

```text
Control plane (Python / disk)  ──authoritative──►  UI (Swift)
UI  ──user intent only──►  CLI / control plane APIs
```

**Do:** call `pong snapshot`, read `~/.pong/…`, invoke `pong job …`  
**Don’t:** parse tmux panes for job status; write ad-hoc JSON shapes; dual-write pairs without schema_version

## Primary read API

### `pong snapshot [--session S] [--json]`

Returns one JSON document (also written to `~/.pong/snapshot.json` when session is active/all):

```json
{
  "schema_version": 2,
  "contract_version": 1,
  "generated_at": 0.0,
  "state_dir": "/Users/…/.pong",
  "bound_session": "pong-team",
  "bridge": "BRIDGE_ON session=… conductor=grok …",
  "bridge_on": true,
  "teams": [ { /* TeamSnapshot */ } ],
  "ledger": { "rounds": 0, "accept_rate": 0, "reject_streak": 0, "last": null },
  "events_tail": [ /* last N events */ ]
}
```

### TeamSnapshot

```json
{
  "session": "pong-team",
  "display_name": "Auth",
  "stowed": false,
  "schema_version": 2,
  "conductor": { "id": "c1", "type": "grok", "label": "Grok Build", "cmd": "grok", "window_id": "…", "mode": "tmux" },
  "workers": [ { "id": "w1", "type": "claude", "label": "…", "status_hint": "idle|busy|unknown", "open_jobs": 1 } ],
  "project_root": "",
  "team_brief": "",
  "transport_default": "job+paste",
  "jobs": {
    "open": [ /* JobSummary */ ],
    "recent": [ /* JobSummary, last 10 terminal states */ ]
  },
  "artifacts": {
    "last_sent": "…/sessions/pong-team/last-sent.txt",
    "last_reply": "…/sessions/pong-team/last-reply.txt",
    "bind_card": "…/binds/pong-team.md"
  }
}
```

### JobSummary

```json
{
  "id": "job_…",
  "worker": "w1",
  "status": "queued|notified|running|done|failed|rejected|human_takeover|cancelled",
  "round": 1,
  "task_preview": "first 80 chars…",
  "updated_at": 0.0,
  "human_takeover": false
}
```

Full job body remains at `jobs/<session>/<id>.json` — UI opens that on demand via `pong job show`.

## Write APIs the UI may invoke

| User action | Control-plane call |
|-------------|-------------------|
| Refresh panel | `pong snapshot` (or read `snapshot.json` if fresh) |
| Create task from panel (later) | `pong job create --worker w1 --task '…'` |
| Mark human takeover | `pong job status <id> human_takeover` |
| Cancel job | `pong job status <id> cancelled` |
| Record verdict | `pong ledger record …` |
| Save pair fields | write `pairs.json` **only** via validated `pong pair upsert` (or Swift using same schema_version 2 shape) |

Swift may still write `pairs.json` for window ids / stow / colors (layout concerns).  
It must preserve `schema_version`, `conductor`, `workers`, `transport_default`.

## Events log

Append-only: `~/.pong/events.jsonl`

```json
{"ts": 0, "type": "job.created", "session": "pong-team", "job_id": "…", "worker": "w1"}
{"ts": 0, "type": "job.status", "session": "…", "job_id": "…", "status": "notified", "from": "queued"}
{"ts": 0, "type": "job.claim", "session": "…", "job_id": "…"}
{"ts": 0, "type": "verdict", "session": "…", "task_id": "…", "verdict": "accept"}
{"ts": 0, "type": "pair.saved", "session": "…"}
```

UI can tail last N via snapshot `events_tail` — no need to parse jsonl itself.

## Status machine (jobs)

```text
queued ──► notified ──► running ──► done
                │            │         │
                │            ├──► failed
                │            ├──► rejected
                │            └──► human_takeover
                └──► cancelled
done|failed|rejected|cancelled|human_takeover are terminal
  (except rejected → new job round; not a transition on same id)
```

Illegal transitions raise; UI should not force them.

## Polling guidance

- Panel refresh: every 1–2s while visible, or on focus — call `pong snapshot --json`
- Do not run heavy headless transports from the UI event loop
- File watchers optional later; snapshot is enough for alpha

## Compatibility

| Env / path | Support |
|------------|---------|
| `PONG_SESSION` | Preferred bind |
| `HERMES_PONG_SESSION` | Legacy bind |
| `~/.hermes-pong` | Read until migrate |
| `hermes-pair*` sessions | Load + normalize to v2 |
| `pong-team*` | Preferred session names |

## Contract versioning

- `schema_version` — pair/job document shape (currently **2**)
- `contract_version` — snapshot envelope for UI (currently **1**)

Bump `contract_version` when snapshot fields break; keep generators backward-compatible for one minor when possible.

## Proven before UI features

Foundation is “proven” when:

1. Unit tests cover status transitions, snapshot shape, multi-team isolation  
2. `pong snapshot` works with zero teams, one team, legacy hermes-pair  
3. Job create → status → claim → ledger leaves consistent events  
4. UI only renders snapshot + pair layout fields (window ids, colors)

Mission dashboard UI should land **after** these hold — not before.

## Graphs (1.7)

The Graphs page reads `pong graph list --json` (all teams, files only, no side effects), not the team snapshot. Each graph carries the v1 fields (`id, session, owner, kind, status, stop_reason, round, max_rounds, edges, nodes[], wiring, paused, topology`) plus:

| field | meaning |
|---|---|
| `title`, `goal_text` | the topology's name, else the goal's first line; the goal (up to 1600 chars) |
| `gates[]` | open gates: `node, at, from, reason, summary, artifacts[], options[]` (the answers the gate's edges accept) |
| `attention[]` | running nodes a person must look at: the seat asks a question only a person should answer, or its terminal is at a shell prompt with no model running (`what` says which) |
| `manual_pause`, `held` | a person's pause, and how many steps it holds |
| `budget` | `max_rounds, max_wall_min, wall_min, people_wait_min, max_jobs, jobs, node_timeout_min` (`wall_min` is working time: minutes spent waiting only on a person are in `people_wait_min`, not in `wall_min`) |
| `recent[]` | the last 60 history events: `round, node, outcome, event, summary, at, job_id` (event ∈ dispatch, claim, check, join, gate_open, gate_answer, route, retry, held, cancel, merged, seat, progress, stop; `progress` is a file in the working folder that changed while a step ran, at most 6 per step visit) |
| `files[]` | files in the working folder changed since the graph started, newest first (20; 5 in the lean form): `path` (relative to `files_root`), `kb`, `at`, `node` (the running step it most likely belongs to: the only one running, or the one whose task names the file; null when that cannot be told). The engine walks the folder at most once a minute while a seat runs, skipping hidden, dependency and build folders, and never a whole home folder |
| `files_root` | the folder `files[].path` is relative to |
| `refusal_items[]`, `ends[]`, `notes_path`, `protected[]`, `last_error` | what was refused, how branches ended, the notes file, protected files, a tick error |

Node additions: `visits, max_visits, last_outcome, started_at, finished_at, task_preview, wait, pass, arrivals, waiting_for[], fresh, retry_count, timeout_min, copy_of, branch, family, taken_over, attention, live, check_log, runtime, model, why, rule, rejected{}, pin`.

`live` (running seat steps only, else null) is what the seat's screen showed on the engine's last look, every 30 s: `state` (working: mid-turn or its screen changed in the last 10 minutes; quiet: neither; no_model: the pane has been a shell prompt for 45 s, which also sets `attention`), `doing` (its latest step line, at most 160 chars), `busy` (mid-turn), `changed_at` (the last look at which the screen differed, spinners and timers aside), `seen_at`.

The team snapshot (`pong snapshot`) carries the same graph block in a lean form (10 recent events, a shorter goal). One-team snapshots are written beside the team (`sessions/<s>/snapshot.json`); `~/.pong/snapshot.json` is always the all-teams view.

## Notch panel data (2.1)

What the notch panel reads, so it never has to guess from ids or terminal text. Additive: an older app ignores it, and the app keeps its own fallbacks for an older engine.

**`graphs[].now`** (running graphs only, else null; in `pong graph list --json` and the team snapshot): the graph's one state and the step to show.

| field | meaning |
|---|---|
| `state` | `needs_you` (a question is open, or a step asks for something), `no_model` (a step's AI is not running), `paused_limit` (the runner's pause for Claude's limits), `paused` (the person's), `working`, `quiet` (every running step quiet: no change on screen for 10 minutes), `between_steps` |
| `step`, `step_name` | the step shown: the oldest open question, else a step asking, else the running step started last. `step_name` is its title, else what it does ("The builder", "A reviewer", "Your answer"); never an id |
| `step_n`, `steps` | its place and the total, by the longest path from the start with the edges that send work back removed; a step's copies are walked as one step and share its place (walked one by one, work sent back to a copy not yet reached would read as a step forward); the end step doesn't count. null when no start can be found ("step 2", never a guess) |
| `at_once`, `at_once_names`, `at_once_done` | steps running now, their names (up to 3, no repeats), and copies at the shown step's place that already finished this round |
| `runtime`, `model` | the shown step's AI (running steps only) |
| `step_started_at` | this visit of the step (a question: when it opened) |
| `doing`, `doing_plain`, `doing_changed_at` | its latest screen line (≤160, keys hidden), the same in plain words (null when it would only be tool text), and when the line last changed |
| `last_file` | `{path, kb, at, step}`: the newest file written in the working folder |
| `round`, `rounds` | the innermost loop's round and limit, else the graph's |
| `sent_back` | times this step was sent back (visits − 1) |
| `waiting_since` | when the question opened (or the step started asking) |
| `pause_reason`, `limit_until` | why it is paused; when the limit pause lifts |
| `held` | steps waiting to start |
| `quiet_since` (quiet), `next_name` (between steps) | when the screen last changed; the step that comes next |

The graph also carries `steps` (the total) and, in both reads, `owner_label` ("Lead", "Helper 1", "Chat"). Each node adds `title`, `step_name` and `rank` (its place, null for the end step or an unreachable one); `live` adds `doing_plain` and `doing_at`. `pong graph list` fills `team_label` from the team's `display_name`.

**Team snapshot additions:** `teams[].alive` (its tmux session is there), `teams[].last_message` (`{text ≤200, at}`: the lead's latest message in `human/<team>/chat.jsonl`; automatic job recaps are not the lead speaking), and on the conductor and each worker `doing`, `doing_plain`, `doing_at` (from the 16 screen lines already captured, keys hidden; the line's time is kept across passes in `sessions/<team>/seat-doing.json`) and `graph` (`{graph_id, title, step_name}` when the member is a running step's own seat, or, for a helper, runs a graph of its own; else null). The snapshot's top level carries `limits` and `runner`, the same as `pong graph list --json`.

**Size:** the all-teams `work_graph` copy at the top level is gone (each team's graphs are under `teams[].work_graph`); a finished graph in the team snapshot is `{id, title, status, stop_reason, finished_at}` only; `paused` no longer carries the step's whole report (`prev`). The `--compact` (pipe) copy also leaves out the graph page's inspector details (`jev`, `why`, `rejected`, `rule`, `claim_read`, `advice_log`, `task_preview` on nodes, the gate's `jev`, the wiring's reasons) and keeps 4 recent events, so forty running graphs stay well under the 500,000 bytes the app reads.

Actions are commands: `goal resume --id G [--node N] --outcome O [--note T]`, `goal pause`, `goal cancel`, `graph retry --id G --node N`, `graph peek --seat S`, `graph seat-view --seat S`, `graph attach --owner O --file F --task T`.
