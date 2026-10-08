# Observability — local run traces

Phase 0 Part B. Every job the control plane runs leaves an append-only trace on
disk. Stdlib only, no new dependencies, **no outbound network calls at all**.

## Money rule (read this first)

**LangSmith cloud (`smith.langchain.com`) and paid self-hosted LangSmith are off
the table.** No account, no API key, no signup, no egress. This module never
opens a socket. `langchain`, `langgraph`, `langsmith` and `deepagents` are not
dependencies of Pong and are not being added; rewriting seats into
`create_deep_agent` is explicitly out of scope.

What we borrowed is *free*: the **field names** from the langsmith-sdk run
export. Names cost nothing and buy us a replay path into an open-source viewer
later, without a rewrite.

## Layout

```
$PONG_HOME/traces/<session>/<job_id>.jsonl      # PONG_HOME defaults to ~/.pong
```

One directory per session, one file per job, one JSON object per line, appended
in the order things happened. Files are `0600`, like `events.jsonl`.

Each line:

| field | meaning |
|---|---|
| `id` | this run's UUID |
| `trace_id` | the job's root run id — same on every line in the file |
| `parent_run_id` | root run id, or `null` on the root (`job.create`) |
| `name` | `job.create`, `job.status.<status>`, `job.claim`, `ledger.verdict.<verdict>`, `transport.<name>` |
| `run_type` | `chain` \| `tool` \| `llm` — transports are `tool`, the rest are `chain` |
| `start_time` / `end_time` | ISO 8601 with timezone (UTC) |
| `inputs` / `outputs` | what went in, what came out |
| `error` | non-null when the run failed |
| `tags` | flat strings for filtering |
| `extra` | **all pong specifics**: `session`, `seat`, `seat_label`, `mission_role`, `parent_seat`, `job_id`, `job_status`, `round` |

The root run id is `uuid5(NS, "pong-job:<job_id>")` — deterministic, so a
process that crashes and restarts still writes into the same trace instead of
forking it. Top-level names stay exactly what the exporter expects; anything
pong-shaped goes under `extra`. String values are clipped at 4000 chars with a
visible `…[+N]` marker, so a large claim can't turn a trace into a blob store.

## Where records are made

Five choke points, no sprinkling:

| file | function | records |
|---|---|---|
| `pong/jobs.py` | `create_job` | root run: worker, assigning seat, task one-liner, project root |
| `pong/jobs.py` | `set_status` | every status transition, `from` → `to` |
| `pong/jobs.py` | `record_claim` | the claim: files, commands, summary, token check |
| `pong/ledger.py` | `record` | the verdict for that job id — accept/reject/escalate + evidence |
| `pong/transports/dispatch.py` | `dispatch_job` | one `tool` run per transport: `job_file`, `tmux_paste`, `window_paste`, `headless`, and `waitroom` with the reason it queued |

## Safety

Tracing is observability. It gets zero votes on whether work happens.

Every entry point in `pong/traces.py` is wrapped by `_safe`: an exception —
ENOSPC, a read-only path, `traces/` existing as a file — is caught and the
caller proceeds. A job still gets created, a claim still gets recorded, a
dispatch still runs.

It degrades **visibly, not silently**: the first failure of each distinct kind
writes one line to stderr (`pong: trace write disabled for this reason …`) and
subsequent ones are quiet, so a broken traces dir is reported once instead of
either invisibly or on every job.

`tests/test_traces.py` covers this directly — an unwritable `traces/`, a
scoped ENOSPC on the trace file, and a `record()` that raises outright, each
asserting the job and the claim still land.

### Disabling

```bash
PONG_TRACE=0 pong job send …    # also: false, off, no
```

Nothing is written and the `traces/` directory is never created.

## Reading

```bash
pong traces list [--limit N] [--json]   # newest-first index across sessions
pong traces show <job_id> [--json]      # every run for one job
```

Read-only by construction: both open files for reading and never call `record`.
`show` searches every session directory when `-s/--session` is not given.

## Replaying into a self-hosted UI (optional, free)

If a timeline UI is ever wanted, **Langfuse** (MIT, self-hostable) runs on
localhost and its ingestion accepts the same shape. Nobody has to sign up for
anything and nothing leaves the machine.

Deliberately **not** included here: no `docker-compose.yml`, and no container is
started by this work. That is a decision for a named human, not for a job.

The mapping, for whoever does it:

| trace field | Langfuse |
|---|---|
| `trace_id` | trace id |
| `id` | observation id |
| `parent_run_id` | parent observation id |
| `name` | observation name |
| `run_type` | `chain`/`tool` → `span`, `llm` → `generation` |
| `start_time` / `end_time` | start / end |
| `inputs` / `outputs` | input / output |
| `error` | level `ERROR` + status message |
| `extra` | metadata |
| `tags` | tags (trace level) |

A replay script is `for line in file: post(json.loads(line))` against a local
Langfuse — one file is one trace, already in order. Because the field names are
the langsmith export names, the same JSONL also loads into any other tool that
reads that format, without re-instrumenting the control plane.
