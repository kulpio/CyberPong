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

Actions are commands: `goal resume --id G [--node N] --outcome O [--note T]`, `goal pause`, `goal cancel`, `graph retry --id G --node N`, `graph peek --seat S`, `graph seat-view --seat S`, `graph attach --owner O --file F --task T`.
