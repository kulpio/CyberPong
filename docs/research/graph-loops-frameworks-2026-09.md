# Graph loops in production agent frameworks: what CyberPong should adopt (2026-09)

Research date: 2026-09-24. Scope: how the main agent-graph and durable-execution frameworks implement graph loops, compared with CyberPong's custom-graph engine (`python/pong/work_graph.py` as committed in 1.6.x, and `python/pong/graph_engine.py`, the rewrite committed as "Graph engine 1.7" (6c090dc, 2026-09-24 17:11), with further uncommitted edits in progress; the hazards listed below were rechecked against the working copy). Every claim about a framework carries the URL it came from. Where I read source code rather than docs, the link points at the file on the default branch, and the version is the one I downloaded that day.

## Versions read

| Framework | Package and version (release date) | Source |
|---|---|---|
| LangGraph | `langgraph` 1.2.12 (2026-09-21); 1.2 line released 2026-05-11 | https://pypi.org/project/langgraph/ , https://github.com/langchain-ai/langgraph/releases/tag/1.2.12 , https://docs.langchain.com/oss/python/releases/changelog |
| OpenAI Agents SDK | `openai-agents` 0.22.3 (2026-09-17) | https://pypi.org/project/openai-agents/ |
| Google ADK | `google-adk` 2.9.2 (2026-09-18); 2.0 GA for Python on 2026-05-19, Go on 2026-06-30 | https://pypi.org/project/google-adk/ , https://developers.googleblog.com/announcing-adk-go-20/ |
| Microsoft Agent Framework | `agent-framework` 1.19.0 (2026-09-18) | https://pypi.org/project/agent-framework/ |
| AutoGen (legacy) | `autogen-agentchat` 0.7.5 (2025-09-30), maintenance mode | https://github.com/microsoft/autogen |
| CrewAI Flows | `crewai` 1.15.22 (2026-09-16) | https://pypi.org/project/crewai/ |
| Pydantic AI graph | `pydantic-graph` 2.49.0 (2026-09-24) | https://pypi.org/project/pydantic-graph/ |
| Mastra | `@mastra/core` 1.70.0 (2026-09-24) | https://www.npmjs.com/package/@mastra/core |
| Temporal / Restate / Inngest / DBOS | `temporalio` 1.33.0, `restate-sdk` 1.0.5, `inngest` 0.5.19, `dbos` 3.1.0 | https://pypi.org/project/temporalio/ , https://pypi.org/project/restate-sdk/ , https://pypi.org/project/inngest/ , https://pypi.org/project/dbos/ |
| Claude Agent SDK / Claude Code | `claude-agent-sdk` 0.2.159 (2026-09-23); Claude Code docs as served 2026-09-24 | https://pypi.org/project/claude-agent-sdk/ , https://code.claude.com/docs/en/sub-agents |
| Strands Agents (newcomer that matters) | `strands-agents` 1.57.0 (2026-09-22) | https://pypi.org/project/strands-agents/ |

## Executive summary

1. **Nobody leaves "which edges fire" implicit.** The frameworks split into two explicit camps. *Exclusive* routing: Microsoft Agent Framework switch-case groups ("route messages to exactly one destination", default only "when every case predicate returns False"), Pydantic graph decisions ("The first matching branch is taken"), OpenAI handoffs (the first handoff wins; the others get "Multiple handoffs detected, ignoring this one."). *All-match* routing: LangGraph (every outgoing edge runs in the next superstep), ADK 2.0 (every matching route plus unconditioned edges; `DEFAULT_ROUTE` only when nothing specific matched), AutoGen GraphFlow, Mastra's engine. CyberPong's 1.6 bug #1 (`done` also matching `win`) is exactly the ambiguity these APIs are designed to rule out. The draft engine's "most specific tier wins, ties fan out" fixes the bug, but it is still an implicit rule.
2. **Joins are barriers with a declared scope.** LangGraph (`add_edge([a, b], c)`, `defer=True`), MAF (fan-in edge group buffers per source, and the buffer is checkpointed), ADK `JoinNode` (waits for *all static* predecessors), Pydantic (a join waits for all tasks of *its parent fork*), and AutoGen (`activation_condition` `all` or `any`) all make the wait explicit. The known trap: a join that waits on a branch that a router never took hangs forever (ADK, MAF). Pydantic's "parent fork" scoping and Strands' "live sources" rule are the two designs that avoid it.
3. **Timeouts come in three kinds, and retries depend on the failure type.** Temporal separates Schedule-To-Start, Start-To-Close and Heartbeat. LangGraph 1.2 added `run_timeout` and an `idle_timeout` that resets whenever the node makes progress. Retry policies have `retry_on` and non-retryable errors, and LangGraph, ADK, Mastra and Temporal all add error handlers that run once retries are exhausted. For a tmux seat these three timeouts are "never submitted", "went silent" and "ran too long", and the first of them is CyberPong bug #4.
4. **Durability means a checkpoint history, not just the latest state.** LangGraph checkpoints every superstep, and you can list them, fork from one, or edit state and resume. MAF checkpoints each superstep together with its pending requests and fan-in buffers. DBOS `fork_workflow` copies a run's steps up to a chosen step and runs on from there. Mastra `timeTravel` does the same from a chosen step. CyberPong overwrites one JSON record per graph.
5. **Human gates carry a typed value, can edit state, and can time out.** LangGraph `interrupt()` plus `Command(resume=value)` (with `response_schema` since 1.2.12). ADK `RequestInput(response_schema=...)`. MAF `request_info(response_type=...)`, where pending requests are re-emitted when a checkpoint is restored. Mastra `resumeSchema`. CrewAI `default_outcome`. Temporal `wait_condition(timeout=...)`. CyberPong's `goal resume` passes a single outcome word.
6. **Critics get fresh, filtered context by design.** Claude Code subagents start with "a fresh, isolated context window". OpenAI's agents-as-tools receive only generated input (a handoff sees the full history unless an `input_filter` removes it). Strands has `reset_on_revisit`, and its TS SDK is stateless unless `preserveContext` is set. AutoGen has `MessageFilterAgent`. The draft gives critics a fresh pane but still tells every node to read the shared notes file.
7. **What not to copy:** synchronous supersteps (BSP), because a 30-minute CLI job would stall every other branch; replay-by-re-execution, because a CLI session is not deterministic; pickle checkpoints; LLM-chosen routing on every round; and hosted trace backends. Take the semantics. Leave the servers.

The ranked adoption list is in the section "What CyberPong's graph engine should adopt" near the end.

---

## CyberPong today, in one paragraph

A topology is `start`, `max_rounds` (1..12), `nodes[] {id, role, task}` and `edges[] {from, to, on}`. Every non-human node becomes a job on an ephemeral tmux seat running a CLI. A claim ends the job, and the job's outcome picks the next edges. The 30 s launchd runner calls `tick`, which is serialized by a non-blocking lock (`work_graph.tick`, which returns `skipped` when another tick holds the lock). The committed 1.6 `_tick_custom` dispatches **every** matching edge, ends the graph at the first `join`/`end`, and stores a human gate on `graph.paused`, where a sibling branch can overwrite it (bugs 1 to 3 in the brief). The 1.7 `graph_engine.py` (called "the draft" below, since it is still being edited) already adds several things: most-specific-tier edge selection, a required verdict for critics, joins with `wait: all|any` ("fires when no node upstream of it is still in flight"), per-node gates, pause that holds dispatch without freezing, one retry for `lost`/`timeout`, `fresh` seats for critics, `max_rounds`/`max_jobs`/`max_wall_min`/`timeout_min`, and a shared notes file. The comparisons below take that draft as the baseline.

---

## 1. LangGraph (1.2.12)

- **Model.** A Pregel-style message-passing engine: "A super-step can be considered a single iteration over the graph nodes", and a run ends when no node is active and no message is in transit (https://docs.langchain.com/oss/python/langgraph/graph-api).
- **Edges and multiple matches.** "If a node has multiple outgoing edges, all of those destination nodes will be executed in parallel as a part of the next superstep" (https://docs.langchain.com/oss/python/langgraph/graph-api). A conditional edge's router function picks the targets and can return several. `Command(update=..., goto=...)` combines the state write and the routing decision in one return value (same page). Exclusivity is the router function's job. There is no declarative switch.
- **Fan-out / fan-in.** `Send(node, private_state)` gives each map task its own input (https://docs.langchain.com/oss/python/langgraph/graph-api). With a list-form edge, `add_edge(["b_2", "c"], "d")`, "d runs once, after both b_2 and c complete". With separate edges the target runs once per superstep in which any branch arrives. `defer=True` "postpones the node until no tasks are pending anywhere in the graph" (https://docs.langchain.com/oss/python/langgraph/use-graph-api).
- **Merging.** Every state key has a reducer. With no reducer, updates override. If two parallel nodes write the same key without a reducer, the graph raises `INVALID_CONCURRENT_GRAPH_UPDATE` "because there is uncertainty around how to update the internal state" (https://docs.langchain.com/oss/python/langgraph/errors/INVALID_CONCURRENT_GRAPH_UPDATE).
- **Transactional supersteps.** "If any of these branches raises an exception, none of the updates are applied", but with a checkpointer "results from successful nodes within a superstep are saved" (https://docs.langchain.com/oss/python/langgraph/use-graph-api). These are the "pending writes": "successful nodes' writes are already durable and don't need to be re-run on resume" (https://docs.langchain.com/oss/python/langgraph/checkpointers).
- **Cycles and bounds.** The default `recursion_limit` has been 1000 supersteps since 1.0.6. Exceeding it raises `GraphRecursionError`, and the `RemainingSteps` managed value lets a node degrade gracefully before the limit (https://docs.langchain.com/oss/python/langgraph/graph-api , https://docs.langchain.com/oss/python/langgraph/use-graph-api).
- **HITL.** `interrupt(payload)` requires a checkpointer and a `thread_id`. A resume passes `Command(resume=value)`, and that value "becomes the return value of the `interrupt()` call". The node "restarts from the beginning", so side effects placed before the interrupt must be idempotent. Several interrupts in one node are matched "strictly index-based". Parallel interrupts are resumed with a map `{interrupt_id: value}`. The patterns covered are approve/reject, review-and-edit, and approval of a tool call from inside the tool. Static breakpoints are `interrupt_before` / `interrupt_after` (https://docs.langchain.com/oss/python/langgraph/interrupts). Version 1.2.12 adds `response_schema` to `interrupt()` (https://github.com/langchain-ai/langgraph/releases/tag/1.2.12).
- **Checkpoints, replay, time travel.** A checkpoint is written at every superstep. A `StateSnapshot` holds `values`, `next`, `config`, `metadata`, `created_at` and `parent_config`. `get_state_history` lists snapshots newest first. `update_state(..., as_node=...)` passes through the reducers. Replaying from a `checkpoint_id` skips the steps already done and forks the rest. Durability modes are `exit`, `async` and `sync` (https://docs.langchain.com/oss/python/langgraph/checkpointers). In time travel, nodes after the checkpoint "re-execute, including any LLM calls", and "interrupts are always re-triggered" (https://docs.langchain.com/oss/python/langgraph/use-time-travel).
- **Failure handling (1.2).** `add_node(timeout=...)` accepts a number or a `TimeoutPolicy(run_timeout, idle_timeout, refresh_on)`. `run_timeout` is "a hard wall-clock cap on a single attempt". `idle_timeout` "fires only when the node stops making observable progress". A timeout "clears any writes from the failed attempt" before retry is considered. Timeouts are **async-only**. `RetryPolicy` defaults to `max_attempts=3`, `initial_interval=0.5`, `backoff_factor=2.0`, `max_interval=128`, `jitter=True`, and `retry_on=default_retry_on` (which skips ValueError, TypeError and others, and retries HTTP only on 5xx). `error_handler=` runs "after a node fails and all retries are exhausted", receives a `NodeError`, and can return a `Command` that routes elsewhere. `set_node_defaults(...)` applies graph-wide values (https://docs.langchain.com/oss/python/langgraph/fault-tolerance). There is an open bug: error handlers ignore node timeouts (https://github.com/langchain-ai/langgraph/issues/8842).
- **Graceful drain.** `RunControl.request_drain()` stops at the next superstep boundary, saves a checkpoint and raises `GraphDrained`. A running node "runs to completion" (https://docs.langchain.com/oss/python/langgraph/fault-tolerance).
- **Subgraphs.** A subgraph is either added as a node over shared keys or called inside a node over transformed, private state. Checkpointing is per invocation (the default), per thread (`checkpointer=True`) or off (`False`) (https://docs.langchain.com/oss/python/langgraph/use-subgraphs).
- **Observability.** Stream modes are `values`, `updates`, `messages`, `custom`, `checkpoints`, `tasks` ("Task start/finish events with results and errors") and `debug`. `subgraphs=True` namespaces events (https://docs.langchain.com/oss/python/langgraph/streaming). Studio visualizes the graph, intermediate states and threads, and supports "Debug agent state via time travel" (https://docs.langchain.com/langsmith/studio).
- **Fresh vs shared context.** State is shared by default. Private context comes from `Send` payloads or from a subgraph with transformed state ("a private message history for each agent", https://docs.langchain.com/oss/python/langgraph/use-subgraphs).
- **Lesson for CyberPong.** Take the idle-vs-run timeout split, the error handler that routes after retries run out, the checkpoint history with fork, and drain. Leave supersteps and reducers.

## 2. OpenAI Agents SDK (0.22.3)

- **Model.** There is no graph, only a loop: call the model, then return the final output, follow a handoff, or run tools and loop again (https://openai.github.io/openai-agents-python/running_agents/).
- **Edges and multiple matches.** A handoff is a tool named `transfer_to_<agent>` (https://openai.github.io/openai-agents-python/handoffs/). If the model calls several handoffs in one turn, **the first wins**. Every later one gets the tool output "Multiple handoffs detected, ignoring this one." (`run_handoffs[0]` in https://github.com/openai/openai-agents-python/blob/main/src/agents/run_internal/turn_resolution.py).
- **Fan-out / fan-in.** None built in. Agents-as-tools (`Agent.as_tool`) keep the orchestrator in control and can be called several times. The orchestrator merges the results itself (https://openai.github.io/openai-agents-python/tools/).
- **State passing.** On a handoff, the receiver "gets to see the entire previous conversation history". An `input_filter` (for example `remove_all_tools`) or the beta `nest_handoff_history` trims it. An agent-as-tool gets only the input generated for that call, and `custom_output_extractor` shapes what comes back (https://openai.github.io/openai-agents-python/handoffs/ , https://openai.github.io/openai-agents-python/tools/).
- **Bounds.** `DEFAULT_MAX_TURNS = 10` (https://github.com/openai/openai-agents-python/blob/main/src/agents/run_config.py). Exceeding it raises `MaxTurnsExceeded`, unless `error_handlers={"max_turns": ...}` returns a controlled `final_output` (https://openai.github.io/openai-agents-python/running_agents/).
- **HITL.** `needs_approval` on a tool pauses the run and fills `result.interruptions`. From there you call `result.to_state()`, then `state.approve()` or `state.reject(rejection_message=...)`, and resume with `Runner.run(agent, state)`. `always_approve` / `always_reject` make the decision sticky. `RunState.to_json()` / `from_json()` persist a paused run across processes (https://openai.github.io/openai-agents-python/human_in_the_loop/).
- **Guardrails.** Input guardrails run only for the first agent, and output guardrails only for the agent that produces the final output. Tool guardrails wrap every function tool. A tripwire raises and "halts agent execution". Input guardrails can run in parallel with the agent or block it (https://openai.github.io/openai-agents-python/guardrails/).
- **Durability.** The SDK does not provide it. For "long-running agents, human-in-the-loop workflows, and handoffs" it delegates to Temporal, Restate or DBOS (https://openai.github.io/openai-agents-python/running_agents/).
- **Observability.** A trace has `workflow_name`, `trace_id` and `group_id`, with spans for agent, generation, function, guardrail, handoff and custom work (https://openai.github.io/openai-agents-python/tracing/).
- **Lesson for CyberPong.** Exclusive routing is decided in code, with an explicit rule for several simultaneous transfers, and hitting the turn limit can return a controlled result instead of an exception.

## 3. Google ADK (2.9.2): 1.x workflow agents and the 2.0 graph runtime

- **1.x templates.** `LoopAgent` runs its sub-agents in order until `max_iterations` is reached or a sub-agent sets `actions.escalate = True`. "The `LoopAgent` itself does not inherently decide when to stop looping" (https://adk.dev/agents/workflow-agents/loop-agents/). `ParallelAgent` branches have "no automatic sharing of conversation history" but do share `session.state`, and results are collected per branch through `output_key` (https://adk.dev/agents/workflow-agents/parallel-agents/). As of 2.0 these templates are "superseded by ... graph-based workflows and dynamic workflows" (https://adk.dev/agents/workflow-agents/loop-agents/).
- **2.0 rationale.** Keep routing out of the LLM: "programmatic routing", and "strict state boundaries" that pass "only the necessary subset of data to subsequent agent nodes" (https://developers.googleblog.com/why-we-built-adk-20/, 2026-07-01).
- **Edges and multiple matches (source).** `get_next_pending_nodes` triggers every edge with no route tag, **every** edge whose route matches, and the `DEFAULT_ROUTE` edges only if no specific route matched. When nothing matches it logs "The branch will end." (https://github.com/google/adk-python/blob/main/src/google/adk/workflow/_graph.py). A node emits `Event(route=...)`, and a list of routes fans out (https://adk.dev/graphs/routes/).
- **Fan-in.** `JoinNode` "waits for all specified predecessors". The barrier fires only when **every static predecessor** has the status COMPLETED, and it passes on a dict of outputs keyed by predecessor (https://github.com/google/adk-python/blob/main/src/google/adk/workflow/_join_node.py , `_buffer_barrier_trigger` in https://github.com/google/adk-python/blob/main/src/google/adk/workflow/_workflow.py). A predecessor that a router skipped therefore never completes, and the join never fires. The Go announcement calls joins "fan-in barriers: they wait for all predecessors and hand you a map of their outputs" (https://developers.googleblog.com/announcing-adk-go-20/).
- **State passing.** "Each node's return value is passed to the next node as its input", and session state is scoped by the prefixes `app:`, `user:` and `temp:` (https://adk.dev/graphs/ , https://adk.dev/graphs/data-handling/).
- **Cycles and bounds.** In ADK Go 2.0 "cycles are first-class" (https://developers.googleblog.com/announcing-adk-go-20/). The Python workflow has no loop counter. The global guard is `RunConfig.max_llm_calls`, default 500 (https://github.com/google/adk-python/blob/main/src/google/adk/agents/run_config.py). `max_concurrency` caps the number of parallel tasks (https://github.com/google/adk-python/blob/main/src/google/adk/workflow/_workflow.py).
- **Failure handling.** A node has `timeout` (on expiry it "is cancelled and treated as a failure (raising `NodeTimeoutError`)", which can be retried) and `retry_config`. A retried sub-workflow replays children that already produced an output instead of re-running them (https://github.com/google/adk-python/blob/main/src/google/adk/workflow/_base_node.py). `RetryConfig` defaults to 5 attempts, a 1.0 s initial delay, a 60 s cap, backoff factor 2.0 and jitter 1.0 (https://github.com/google/adk-python/blob/main/src/google/adk/workflow/_retry_config.py).
- **HITL.** A node yields `RequestInput(message=..., response_schema=...)`. The schema "travels on the interrupt" for a client form, but it "does not reformat a human reply". On resume, `rerun_on_resume` decides whether the node runs again or the reply becomes the node's output (https://adk.dev/graphs/human-input/). In Go, workflows "reconstruct a paused workflow by scanning session history" after a restart (https://developers.googleblog.com/announcing-adk-go-20/).
- **Callbacks.** `before_agent` / `before_model` / `before_tool` can return a value that short-circuits the call (https://adk.dev/callbacks/).
- **UI.** `adk web` shows the event history, the state, "the agent structure graph" and a trace view (https://adk.dev/runtime/web-interface/ , https://adk.dev/observability/traces/).
- **Lesson for CyberPong.** A typed `RequestInput` and a per-node timeout plus retry config are the shape to copy. The static-predecessor join is the shape to avoid.

## 4. Microsoft Agent Framework (1.19.0), with AutoGen GraphFlow and Magentic-One

- **Model.** A modified Pregel / BSP model. Each superstep delivers pending messages, runs the targets concurrently and then "waits for all executors to complete before advancing". The docs warn that a chain on one branch "cannot advance until the long-running executor completes" (https://learn.microsoft.com/en-us/agent-framework/concepts/workflows/builder-and-execution).
- **Edge groups (explicit).** The groups are direct, conditional, **switch-case** (ordered cases plus `Default`, where the default is "selected only when every case predicate returns False", and "If a predicate raises an exception, the workflow fails"), **multi-selection** (a `selection_func` returns the list of targets), fan-out and fan-in. Switch-case "route[s] messages to exactly one destination" (https://learn.microsoft.com/en-us/agent-framework/workflows/edges, updated 2026-09-21).
- **Fan-in.** `add_fan_in_edges([w1, w2, w3], agg)`. `FanInEdgeRunner` buffers messages per source and delivers "only once every source has produced a message", as a list. The partial buffer goes into the checkpoint (https://github.com/microsoft/agent-framework/blob/main/python/packages/core/agent_framework/_workflows/_edge_runner.py). As with ADK, a source that never sends blocks the fan-in.
- **Bounds.** `max_iterations` defaults to 100 supersteps. Running out raises `WorkflowConvergenceException("Runner did not converge after 100 iterations.")` (https://github.com/microsoft/agent-framework/blob/main/python/packages/core/agent_framework/_workflows/_runner.py). Build-time validation checks type compatibility, reachability and duplicate edges (https://learn.microsoft.com/en-us/agent-framework/concepts/workflows/builder-and-execution).
- **HITL.** Python uses `ctx.request_info(request_data, response_type)` with a `@response_handler`. The run emits a `request_info` event, and you resume with `workflow.run(responses={request_id: value})`. "Pending requests are also saved as part of the checkpoint", and they are "re-emitted" when the checkpoint is restored. Agent tool approval arrives as a `function_approval_request` through the same channel (https://learn.microsoft.com/en-us/agent-framework/workflows/human-in-the-loop).
- **Checkpoints.** A checkpoint is written at the end of every superstep and holds executor state, pending messages, pending requests and shared state. Since 1.13.0 there are also entry checkpoints, so "the complete workflow run [is] replayable". Storage is in-memory, file or Cosmos. You can resume by `checkpoint_id` or rehydrate a new instance, but only with the "same topology and executor identities". The file and Cosmos stores use a restricted unpickler (https://learn.microsoft.com/en-us/agent-framework/workflows/checkpoints).
- **Failure handling.** The Python workflow core has no per-executor retry or timeout (grep of `_executor.py`, `_runner.py` and `_workflow.py` on main, 2026-09-24). Failures surface as events.
- **Magentic.** The manager keeps a task ledger (facts and plan) and a progress ledger that is updated each round: `is_request_satisfied`, `is_in_loop`, `is_progress_being_made`, next speaker and instruction. The bounds are `max_round_count`, `max_stall_count` ("Consecutive non-progressing rounds increment a stall counter, and exceeding the configured maximum triggers an automatic reset and replan") and `max_reset_count`. The optional human plan review can approve or revise (https://learn.microsoft.com/en-us/agent-framework/workflows/orchestrations/magentic).
- **Observability.** Spans are `workflow.run`, `executor.process {id}`, `edge_group.process {type}` and `message.send`. A fan-in span is *linked* to several source spans. The attribute `edge_group.delivery_status` takes one of `delivered`, `dropped type mismatch`, `dropped target mismatch`, `dropped condition false`, `exception` or `buffered` (https://learn.microsoft.com/en-us/agent-framework/workflows/observability). DevUI is a sample, development-only UI with OpenTelemetry tracing and an input form generated from the first executor's type (https://learn.microsoft.com/en-us/agent-framework/devui/).
- **AutoGen GraphFlow (legacy).** AutoGen "is now in maintenance mode" and points to MAF (https://github.com/microsoft/autogen). `DiGraphBuilder.add_edge(condition=str|callable)`: all edges whose conditions hold fire. `activation_group` plus `activation_condition="all"|"any"` defines the join over the edges into a target. Loops need an explicit exit condition. `MessageFilterAgent` with `PerSourceFilter(source, position, count)` controls which messages each agent sees (https://microsoft.github.io/autogen/stable/user-guide/agentchat-user-guide/graph-flow.html , https://microsoft.github.io/autogen/stable/reference/python/autogen_agentchat.teams.html).
- **Lesson for CyberPong.** Name the edge-group kinds, checkpoint the pending requests and join buffers, and record a delivery status for every edge. Magentic's stall counter is a cheap loop detector.

## 5. CrewAI Flows (1.15.22)

- **Edges.** `@listen(x)` fires when `x` finishes. `or_(a, b)` fires "when any" of them emits, and a multi-event OR listener fires once per run until a router re-arms it. `and_(a, b)` accumulates the events it has seen per listener and fires when all have arrived, after which that accumulation is cleared. `@router` returns a **label**, and only listeners on that label run, so a router is exclusive (https://docs.crewai.com/en/concepts/flows ; `_find_triggered_methods`, `_condition_met` in https://github.com/crewAIInc/crewAI/blob/main/lib/crewai/src/crewai/flow/runtime/__init__.py).
- **Parallelism.** "Normal listeners are executed in parallel" (`asyncio.gather`), while routers run sequentially (same source file).
- **Cycles and bounds.** A router's label can re-trigger a completed start method ("Cyclic re-execution"). A per-method counter `max_method_calls` (default 100) raises `RecursionError` (same source file).
- **State.** State is either an unstructured dict or a Pydantic model, always with an `id`. `@persist` works at class or method level and saves to SQLite by default. `kickoff(inputs={"id": ...})` resumes a run, and `kickoff(restore_from_state_id=...)` **forks** it under a new id (https://docs.crewai.com/en/concepts/flows).
- **HITL.** `@human_feedback(message, emit=[...], llm=..., default_outcome=...)`: an LLM collapses free text into one of the `emit` labels, using structured output. An async provider raises `HumanFeedbackPending`, the flow "automatically persists state", and it is resumed with `flow.resume(feedback)` or `from_pending(flow_id)` (https://docs.crewai.com/en/learn/human-feedback-in-flows).
- **Observability.** `flow.plot()` draws HTML, and `usage_metrics` aggregates tokens (https://docs.crewai.com/en/concepts/flows).
- **Lesson for CyberPong.** Resume-by-id vs fork-by-id is a clean CLI split, and a gate's `default_outcome` keeps a forgotten gate from hanging the graph.

## 6. Pydantic AI graph (pydantic-graph 2.49.0)

- **Two APIs.** In the original `BaseNode` API, "The return type annotation determines outgoing edges" (https://pydantic.dev/docs/ai/graph/graph/). `GraphBuilder` has steps, decisions, broadcast/map forks and joins (https://pydantic.dev/docs/ai/graph/builder/).
- **Edges.** Decisions are exclusive and ordered: "The first matching branch is taken, similar to ... `if-elif-else`" (https://pydantic.dev/docs/ai/graph/builder/decisions/).
- **Joins.** A join "Identifies its parent fork", "Waits for all tasks from that fork", calls `reduce()` for each incoming value and `finalize()` once all have arrived. The reducers are `reduce_list_append`, `reduce_list_extend`, `reduce_dict_update`, `reduce_sum` and `reduce_null`. `ReduceFirstValue` "returns the first value it receives and cancels all other parallel tasks", and `ReducerContext.cancel_sibling_tasks()` lets a reducer stop early (https://pydantic.dev/docs/ai/graph/builder/joins/).
- **Persistence.** "Neither the graph builder API nor the original Graph API snapshots graph state" (https://pydantic.dev/docs/ai/graph/builder/). The 2.49.0 wheel ships no persistence module (its files are `graph_builder`, `join`, `decision`, `node`, `step` and similar). Durability is delegated to Temporal, DBOS, Prefect, Restate or AWS Lambda, which wrap "model requests and tool calls as activities/steps" (https://pydantic.dev/docs/ai/durable-execution/overview/).
- **Lesson for CyberPong.** Scoping a join by its **parent fork** is the cleanest answer to "which branches am I waiting for". A first-value reducer that cancels the siblings is `wait: any` done right.

## 7. Mastra workflows (@mastra/core 1.70.0)

- **Control flow.** `.parallel()`: "All parallel steps must complete", the output is keyed by step id, and one failure fails the block. `.dowhile` / `.dountil` are loops, and the docs tell you to bound them yourself with `iterationCount` ("throw an error to fail the step"). `.foreach(step, {concurrency})` defaults to a concurrency of 1 (https://mastra.ai/docs/workflows/control-flow).
- **Branching: the docs and the code disagree.** The docs say "Only one branch executes" and "Conditions are evaluated in the order they're defined" (https://mastra.ai/docs/workflows/control-flow). The 1.70.0 default engine's `executeConditional` instead evaluates **all** conditions concurrently, keeps every truthy index and runs all of those steps with `Promise.all` (except when stepping one step at a time or time-travelling). I read this in the npm dist, region `src/workflows/handlers/control-flow.ts`, from https://www.npmjs.com/package/@mastra/core. The safe reading is that branch conditions must be mutually exclusive. This is the same class of ambiguity as CyberPong bug #1.
- **Suspend / resume.** `suspend(payload)` is validated against a `suspendSchema`, and `run.resume({step, resumeData})` against a `resumeSchema`. The snapshot "persist[s] across deployments and application restarts". Several steps can be suspended at once (https://mastra.ai/docs/workflows/suspend-and-resume).
- **Failure handling.** `retryConfig {attempts, delay}` is set per workflow, and a step's own `retries` override it. `onError` / `onFinish` callbacks run on failure or completion. `bail()` exits early (https://mastra.ai/docs/workflows/error-handling).
- **Time travel.** Earlier step results are "reconstructed from the snapshot", and the step you choose runs afresh with the given or reconstructed input. Storage is required (https://mastra.ai/docs/workflows/time-travel).
- **Studio.** Shows the step graph with live per-step status, the input, output, state and logs for each step, and step replay (https://mastra.ai/docs/workflows/overview).
- **Lesson for CyberPong.** Schema-checked suspend and resume, and time travel from a named step. The branch discrepancy is a warning: write down exclusivity and test it.

## 8. Durable execution engines: Temporal, Restate, Inngest (and AgentKit), DBOS

- **Temporal.** The agent loop runs in a deterministic workflow, and LLM and tool calls are Activities (https://docs.temporal.io/ai-cookbook). Activities retry by default: initial interval 1 s, backoff 2.0, max interval 100 s, **unlimited** attempts, with an opt-in list of non-retryable errors. Workflows do not retry by default, because they "must be deterministic to support replay" (https://docs.temporal.io/encyclopedia/retry-policies). There are four timeouts. **Schedule-To-Start** covers queued-but-not-picked-up work and "cannot trigger retries". **Start-To-Close** covers one attempt. **Schedule-To-Close** covers all attempts. **Heartbeat** times out when progress pings stop, and a ping can carry a progress payload that the next attempt resumes from (https://docs.temporal.io/encyclopedia/detecting-activity-failures). For HITL, a Signal handler sets the decision and `workflow.wait_condition(..., timeout=...)` waits for it. On timeout the workflow completes with a timeout result, and "Durable timers ... survive any execution disruptions" (https://docs.temporal.io/ai-cookbook/human-in-the-loop-python).
- **Restate.** Each `ctx.run()` step is journaled, so an agent can "retry and recover from failures without repeating completed steps". Awakeables are durable promises for approvals "even across restarts". Virtual objects give keyed sessions with concurrency control. Restate integrates with the OpenAI Agents SDK, the Vercel AI SDK, Pydantic AI, LangChain and ADK (https://docs.restate.dev/ai).
- **Inngest.** `step.run` results are memoized. On re-execution, "completed steps return memoized results" (https://www.inngest.com/docs/features/inngest-functions/steps-workflows). The default is 4 retries after the first attempt, counted per step, with backoff; `NonRetriableError` and `RetryAfterError` override that (https://www.inngest.com/docs/features/inngest-functions/error-retries/retries). `step.waitForEvent(id, {event, timeout, match|if})` returns `null` on timeout (https://www.inngest.com/docs/reference/functions/step-wait-for-event). An AgentKit network is "while loops with memory (State)": a router gets `lastResult`, `callCount` and the network, returns the next agent or `undefined`, and `maxIter` stops the loop (https://agentkit.inngest.com/concepts/networks).
- **DBOS** (a library over Postgres or SQLite, closest to CyberPong's shape). It recovers "from the last completed step". Workflows must be deterministic, and steps are "tried at least once but are never re-executed after they complete". The workflow ID is an idempotency key ("executes only once"). Step retries have `max_attempts` and `backoff_rate`. Workflow timeouts are "durable" (https://docs.dbos.dev/python/tutorials/workflow-tutorial). `fork_workflow` "copies ... all its steps up to the selected step, then begins executing the new workflow from the selected step". `resume_workflow` and `cancel_workflow` are available too, and cancel takes effect "at the beginning of its next step" (https://docs.dbos.dev/python/tutorials/workflow-management).
- **Lesson for CyberPong.** From Temporal, the four-timeout vocabulary and non-retryable errors. From DBOS, three rules: a recorded step is never re-run, the ID is the idempotency key, and fork copies the steps done so far. From Inngest, a wait that returns "nothing" on timeout instead of hanging.

## 9. Claude Agent SDK subagents and Claude Code agent teams

- **Subagents.** "Each subagent starts with a fresh, isolated context window. It doesn't see your conversation history." A subagent returns only its summary, can have its tools restricted by allowlist or denylist and its model overridden, nests up to 3 levels deep by default, runs up to 20 at once by default, and can be resumed by ID through `SendMessage`. `SubagentStart` / `SubagentStop` hooks are available (https://code.claude.com/docs/en/sub-agents).
- **SDK options.** `max_turns`, `max_budget_usd` ("Stop when client-side cost estimate reaches this USD value"), `agents: dict[str, AgentDefinition]`, `can_use_tool` (per-call approval that can rewrite the input or deny with `interrupt=True`), `resume` / `fork_session`, and `enable_file_checkpointing` with `rewind_files` (https://code.claude.com/docs/en/agent-sdk/python).
- **Agent teams** (experimental, `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`). Split panes can run in **tmux** or iTerm2. Tasks are `pending`, `in progress` or `completed`, with dependencies: "a pending task with unresolved dependencies cannot be claimed", and dependents are unblocked automatically. "Task claiming uses file locking to prevent race conditions". Each mailbox is a JSON file, and "Claude Code reports a message as sent only when the write to the recipient's mailbox file succeeds". The `TeammateIdle`, `TaskCreated` and `TaskCompleted` hooks can "Exit with code 2 to prevent completion and send feedback". Known limits: "Task status can lag", with no resume of in-process teammates and no nested teams (https://code.claude.com/docs/en/agent-teams). It is the closest production analog to CyberPong: a lead, seats in tmux panes, claims, and a file-based queue.
- **Lesson for CyberPong.** Acknowledged delivery, file-locked claims, dependency unblocking, and quality-gate hooks that can refuse a completion. Subagents also show what the default for a judge should be: fresh context.

## 10. Newcomer that matters: Strands Agents Graph (1.57.0)

- **Bounds are first-class.** `max_node_executions`, `execution_timeout`, `node_timeout` and `reset_on_revisit` (https://strandsagents.com/docs/api/python/strands.multiagent.graph/). The TS SDK has `maxSteps`, `maxConcurrency`, `timeout` and `nodeTimeout`, "If neither `maxSteps` nor `timeout` is set, the SDK emits a one-time warning" for cyclic graphs (https://strandsagents.com/docs/user-guide/concepts/multi-agent/graph/).
- **Join.** In a normal run a target is ready as soon as **any** incoming edge from the just-completed batch is satisfied (`_is_node_ready_with_conditions`). On resume, readiness is an AND over *live* sources only: "Edges from bypassed dead branches ... are dropped, since they will never fire" (`_is_node_ready_for_resume` in https://github.com/strands-agents/sdk-python/blob/main/src/strands/multiagent/graph.py, read from the 1.57.0 wheel).
- **Node input.** "Original Task" plus "Inputs from previous nodes", grouped by source (`_build_node_input`, same file). Interrupt responses are routed to the node that raised them, and `invocation_state` is "Persisted across interrupt/resume cycles".
- **Fresh context.** Python nodes accumulate agent state unless `reset_on_revisit` is set. TS nodes are stateless by default and opt in with `preserveContext: true` (https://strandsagents.com/docs/user-guide/concepts/multi-agent/graph/).
- **Also seen.** Agno Workflows offers `Parallel`, `Condition`, `Loop(max_iterations, end_condition)`, `Router` and early stop via `StepOutput(stop=True)` (https://docs.agno.com/workflows/overview). Nothing there is new relative to the systems above.
- **Lesson for CyberPong.** Separate graph-wide and per-node time budgets, a warning for unbounded cycles, and the "live vs dead branch" rule for joins after a resume.

---

## Comparison across the nine semantics

| Framework | 1 Edges and multiple matches | 2 Fan-in and merge | 3 State passing | 4 Cycles and bounds | 5 HITL | 6 Checkpoint and replay | 7 Failures | 8 Observability | 9 Critic context |
|---|---|---|---|---|---|---|---|---|---|
| LangGraph 1.2 | all out-edges fire; router returns list; `Command(goto)` | list-edge barrier; `defer` waits for whole graph; reducers per key, error on conflict | shared typed state; `Send` private input | `recursion_limit` 1000 supersteps; `RemainingSteps` | `interrupt()` + `Command(resume)`, `response_schema`, edit via `update_state`, parallel resume map | checkpoint per superstep, history, fork, pending writes, drain | `RetryPolicy`, `TimeoutPolicy` run and idle, `error_handler` | stream modes (tasks, checkpoints, debug); Studio time travel | subgraph private state, `Send` |
| OpenAI Agents SDK | first handoff wins, rest ignored | none (orchestrator merges tool results) | handoff: full history plus `input_filter`; as-tool: generated input | `max_turns` 10, `error_handlers` | `needs_approval`, approve or reject, `RunState` JSON | via Temporal, Restate, DBOS | guardrail tripwires | traces and spans (agent, handoff, guardrail) | as-tool is fresh |
| Google ADK 2.x | all matching routes plus unrouted edges; `DEFAULT` if none | `JoinNode` waits for all static preds (dead-branch hang) | output becomes next input; scoped session state | cycles allowed; `max_llm_calls` 500 | `RequestInput` + `response_schema`; `rerun_on_resume` | session event log; resume after restart | `RetryConfig` (5 tries), node `timeout` | `adk web`: events, state, graph, trace | "strict state boundaries" |
| MS Agent Framework 1.19 | switch-case (exactly one), multi-select, fan-out (explicit groups) | fan-in buffers until every source sent; checkpointed | typed messages plus shared state | `max_iterations` 100, then convergence error | typed `request_info`/`response_handler`; re-emitted on restore | checkpoint per superstep incl. requests | none built in (events) | OTel spans, edge `delivery_status`, fan-in links; DevUI | per-executor conversation |
| AutoGen GraphFlow | all satisfied conditions fire | `activation_condition` all or any | shared chat, filterable | exit conditions, termination | via termination/handoff | limited | n/a | n/a | `MessageFilterAgent` |
| CrewAI Flows | router label exclusive; listeners parallel | `and_` accumulates, `or_` fires once | shared flow state (dict or Pydantic) | `max_method_calls` 100 per method | `@human_feedback` emit, LLM collapse, `default_outcome`, pending | `@persist` SQLite; resume by id, fork by `restore_from_state_id` | exceptions caught per listener | `plot()`, usage metrics | n/a |
| Pydantic graph 2.49 | decisions first match | join per parent fork; reducers; `ReduceFirstValue` cancels siblings | shared state plus step inputs | none built in | between steps (`iter`) | none; delegate to Temporal, DBOS | delegate | Mermaid render | n/a |
| Mastra 1.70 | docs: first match; code: all truthy run | `.parallel` all, keyed by step id | `inputData`, `getStepResult`, `setState` | `dountil` plus your `iterationCount` guard | `suspend`/`resume` with schemas | snapshots; `timeTravel` from step | `retryConfig`, `onError`, `bail` | Studio live step status | n/a |
| Temporal / DBOS / Inngest / Restate | code decides | code decides (futures) | workflow locals, journaled | code decides; AgentKit `maxIter` | signals/`wait_condition`, `waitForEvent` (timeout gives null), awakeables | event history or step journal; DBOS `fork_workflow` | retry policies, non-retryable, 4 timeout kinds (Temporal) | Temporal UI history | n/a |
| Claude Code / Agent SDK | lead decides; task dependencies | dependency unblocking on completion | mailbox messages, task list | `max_turns`, `max_budget_usd`, spawn depth 3 | `can_use_tool` allow or deny, plan approval, hooks exit 2 | `resume`, `fork_session`, `rewind_files` | "Agents stopping early" is manual | agent panel, transcripts | fresh isolated context by default |
| Strands Graph 1.57 | all satisfied conditional edges | any-by-default; AND over live sources on resume | original task plus inputs by source | `max_node_executions`, execution and node timeouts, warns if unbounded | interrupts routed per node; state persisted | `session_manager` persists graph | node timeout | hooks, trace attributes | `reset_on_revisit` / `preserveContext` |
| CyberPong draft (`graph_engine.py`) | most-specific tier; ties fan out | join `wait: all` (no in-flight ancestor) or `any` (cancels rest); summaries concatenated | claim summary, artifacts, history, notes file | `max_rounds` per node, `max_jobs`, `max_wall_min` | gate per node; `resume --outcome` word | one JSON record, overwritten per tick | one retry on lost/timeout; `timeout_min` | history events, snapshot, 3D map | `fresh` pane for critics |

---

## Hazards in the `graph_engine.py` draft that the comparison exposes

These are bugs of the same kind as those in the brief. I found them by reading the draft next to the frameworks. I did not run them.

1. **Infrastructure loss takes the verdict edge.** `FAIL_FAMILY` contains `timeout` and `lost`. Once the single retry is used up, a lost seat on a critic or builder follows the `on: fail` edge back into the build loop as if the work had been judged bad. LangGraph, ADK and Temporal keep these apart: retries and error handlers deal with infrastructure failures, and verdicts deal with the work (items 3 and 4 below).
2. **A `wait: all` join can wait on a branch that will never arrive.** `_check_joins` waits while any *ancestor* is `running`, `waiting_human` or `held`. An ancestor gate on a sibling path that never leads to this join, or a cycle that makes downstream nodes into ancestors, holds the join open. This is a milder form of the ADK and MAF static-predecessor hang. Pydantic's parent-fork scoping avoids it (item 2).
3. **A mixed result at a `wait: all` join becomes `done`.** `_check_joins` gives `win` only if every arrival won and `fail` only if every arrival failed. Anything else is `done`, so a panel of three judges with 2 wins and 1 fail comes out as `done`. If the join has a `done` edge, that counts as a pass. If it has only `win`/`fail` edges, `done` matches neither, and `_route` records the branch as a finished sink. Either way nobody decided it, and "majority" cannot be expressed (item 2).
4. **A pasted job that never starts looks like a slow job.** The draft only notices it when `timeout_min` expires or the pane dies. It has no Schedule-To-Start check (item 4), and no acknowledged-delivery state (item 5).
5. **A "fresh" critic is not fresh in its prompt.** The pane is new, but every node is told to read the shared notes file, and `extra` carries `graph_history`, so the grader reads the builder's narrative (item 9).
6. **Hitting a bound is always a hard stop.** `failed_bounded:rounds` cancels everything, including a gate that could have granted another round (item 8).
7. **No state history.** `graph` is rewritten in place each tick. `history[]` records what happened, but it cannot restore the joins' arrivals, the held queue or the gates at a past tick, so fork and rewind cannot be built on it (item 7).

## What CyberPong's graph engine should adopt (ranked)

Each item gives the exact semantic, the frameworks that implement it, how it maps onto nodes, edges, jobs and seats, and where the `graph_engine.py` draft stands.

### 1. Declare each node's out-edges as `switch` (exactly one) or `fanout` (all matching)

- **Semantic.** A node's outgoing edges form one group with a declared mode. `switch`: evaluate in declaration order, take the **first** match, and take `default` only if nothing matched. `fanout`: take every match. Record the result for every edge (`taken`, `not_matched`, `shadowed_by_first_match`).
- **Who does it.** MAF switch-case vs multi-selection vs fan-out, with default only when every predicate is false and a predicate exception failing the workflow (https://learn.microsoft.com/en-us/agent-framework/workflows/edges). Pydantic decisions take the first match (https://pydantic.dev/docs/ai/graph/builder/decisions/). OpenAI takes the first handoff (https://github.com/openai/openai-agents-python/blob/main/src/agents/run_internal/turn_resolution.py). ADK's all-match with `DEFAULT_ROUTE` is the fan-out form (https://github.com/google/adk-python/blob/main/src/google/adk/workflow/_graph.py). Mastra's docs/code split shows what happens when this is left implicit (https://mastra.ai/docs/workflows/control-flow).
- **CyberPong mapping.** Add `"branch": "switch" | "fanout"` on a node, or on an edge group. Make `switch` the default for `critic`, `router` and `human`, and `fanout` the default for `scout`/`researcher` nodes with several `done` edges. Keep the draft's specificity rule (`win` > `done` > `*`) as the order *within* a switch. Lint should reject a `switch` with two edges on the same `on`, and warn when a `switch` has no `*`/default. A `route:<label>` outcome is exclusive by construction.
- **Draft status.** Partial. "Most specific tier wins; several edges at the same specificity ... all run" fixes bug #1, but a topology author cannot tell a deliberate fan-out from an accidental duplicate.

### 2. Scope each join to the fork that feeds it, with `all`, `any` or a quorum, and a pass rule

- **Semantic.** A dispatch that fans out stamps a `fork_id` and the set of branch node ids it started. A join counts arrivals **for that fork**. `wait: all` means every branch started under this fork has ended (win, fail, timeout or lost all count as arrivals). `wait: any` fires on the first arrival and cancels the siblings. `wait: <k>` is a quorum. A separate `pass: all | majority | <k>` computes the join's outcome from the arrivals (for judge panels and best-of-N). Branches the router never started are not waited for.
- **Who does it.** Pydantic joins "Waits for all tasks from that fork", with `ReduceFirstValue` cancelling siblings (https://pydantic.dev/docs/ai/graph/builder/joins/). AutoGen `activation_condition` `all`/`any` (https://microsoft.github.io/autogen/stable/user-guide/agentchat-user-guide/graph-flow.html). LangGraph list-edge barriers and `defer` (https://docs.langchain.com/oss/python/langgraph/use-graph-api). Strands drops "bypassed dead branches" (https://github.com/strands-agents/sdk-python/blob/main/src/strands/multiagent/graph.py). ADK `JoinNode` (https://github.com/google/adk-python/blob/main/src/google/adk/workflow/_join_node.py) and the MAF fan-in (https://github.com/microsoft/agent-framework/blob/main/python/packages/core/agent_framework/_workflows/_edge_runner.py) show the hang you get from waiting on **static** predecessors.
- **CyberPong mapping.** When `_route` dispatches several targets that lead to a join, write `graph.forks[fork_id] = {join, expect: [...], arrived: {...}}`. `advance(..., role == "join")` appends the arrival under its fork. `_check_joins` fires per fork. The next node's `prev` is the ordered list of `{node, outcome, summary, artifacts}`, which is the reducer: concatenate the summaries and union the artifacts. The draft already does exactly that.
- **Draft status.** Partial. The draft has `wait: all|any`. `all` means "no ancestor in flight", the same idea as LangGraph `defer`. Two hazards: (a) an ancestor human gate in `waiting_human` on a path that does not lead to this join blocks it, and (b) inside a cycle, nodes downstream of the join are also its ancestors. There is no quorum and no pass rule. Joined outcomes are all-win → win, all-fail → fail, anything else → `done`.

### 3. Separate "the work failed" from "the machinery failed", and retry only the second

- **Semantic.** Keep two outcome families. `fail` is a verdict from the seat. `error` covers `lost`, `timeout`, `never_started`, `dispatch_failed` and `seat_refused`. A per-node retry policy `{max_attempts, backoff_s, factor, retry_on: [error kinds]}` handles `error`. A verdict is never retried. After retries run out, an `on: error` edge (the error handler) routes the node, for example to a human gate. If the node has no `error` edge, the graph stops with `failed:error:<kind>`.
- **Who does it.** LangGraph `RetryPolicy(retry_on=...)` plus `error_handler` "after ... all retries are exhausted" (https://docs.langchain.com/oss/python/langgraph/fault-tolerance). ADK `RetryConfig.exceptions` and `NodeTimeoutError` as a retryable failure (https://github.com/google/adk-python/blob/main/src/google/adk/workflow/_retry_config.py). Temporal non-retryable errors (https://docs.temporal.io/encyclopedia/retry-policies). Inngest `NonRetriableError` (https://www.inngest.com/docs/features/inngest-functions/error-retries/retries). Mastra `onError` (https://mastra.ai/docs/workflows/error-handling).
- **CyberPong mapping.** `outcome_of` already returns `(outcome, explicit)`, so non-explicit `lost`/`timeout` become `error:<kind>`. `_complete` retries on `error` kinds with backoff and a fresh seat, which it already does once. Add `on: error` to `EDGE_ON`.
- **Draft status.** Partial. The draft retries `lost`/`timeout` once, without backoff, and then puts `timeout` and `lost` in `FAIL_FAMILY`. An infrastructure loss therefore takes a critic's `on: fail` edge back to the builder as if the work had been judged bad.

### 4. Give every job three timeouts: start, idle and run

- **Semantic.** `start_timeout`: the job was pasted, but the CLI has not acknowledged or started working within N seconds. This is Temporal's Schedule-To-Start. `idle_timeout`: the pane's output has not changed for N minutes. This is the heartbeat, refreshed on progress. `run_timeout`: a wall-clock cap on one attempt. All three produce `error:<kind>`, which item 3 then retries.
- **Who does it.** Temporal Schedule-To-Start, Start-To-Close and Heartbeat (https://docs.temporal.io/encyclopedia/detecting-activity-failures). LangGraph `TimeoutPolicy(run_timeout, idle_timeout)`, where the idle timeout "fires only when the node stops making observable progress" (https://docs.langchain.com/oss/python/langgraph/fault-tolerance). ADK node `timeout` (https://github.com/google/adk-python/blob/main/src/google/adk/workflow/_base_node.py). Strands `node_timeout` and `execution_timeout` (https://strandsagents.com/docs/api/python/strands.multiagent.graph/).
- **CyberPong mapping.** The start check targets bug #4 directly: a paste still sitting in Claude Code's input box, or one that landed on the folder-trust prompt, never starts, so it times out in about 90 s instead of after the full `timeout_min`. The idle check hashes `tmux capture-pane` each tick, and the runner already ticks every 30 s.
- **Draft status.** Partial. The draft has `timeout_min` (the run timeout) and `lost` (pane gone 150 s after dispatch). It has no start timeout and no idle timeout.

### 5. Count a job as delivered only when the seat acknowledges it, and make dispatch idempotent

- **Semantic.** Record a job as delivered only after the write is verified: the pane shows the prompt submitted, or the CLI has echoed the job id. Otherwise record `delivery_failed`, which item 3 retries. Each dispatch carries a key `graph:node:visit:attempt`. A tick that finds that key already dispatched does nothing. A node whose claim is recorded is never dispatched again on resume.
- **Who does it.** Claude Code agent teams report a message "as sent only when the write to the recipient's mailbox file succeeds" (https://code.claude.com/docs/en/agent-teams). DBOS workflow IDs are idempotency keys, and a step is "never re-executed after [it completes]" (https://docs.dbos.dev/python/tutorials/workflow-tutorial). LangGraph pending writes keep successful nodes from re-running (https://docs.langchain.com/oss/python/langgraph/checkpointers).
- **CyberPong mapping.** The brief's bug #4 says a refused tmux paste is still recorded as delivered. Fix that in the delivery layer, then key `dispatch()` on `(node_id, visits, retry_count)`.
- **Draft status.** Missing. The tick lock prevents concurrent ticks, but the job has no acknowledgement state.

### 6. Human gates with a typed value, an edit before resume, and a timeout

- **Semantic.** A `human` node declares `ask` (the question), `schema` (the allowed outcomes plus optional fields such as `note`, `pick: <branch id>` or `budget_rounds`), `timeout_min` and `default` (the outcome to use when the timeout expires). `pong goal resume --node <gate> --outcome approved --value '{"note": "..."}'` validates the value against the schema, and the value reaches the next node's prompt as `{gate_value}`. `--edit` lets the person amend the summary or artifacts that flow on (this is `update_state`). Pending gates stay listed until they are answered, and they survive restarts.
- **Who does it.** LangGraph `interrupt(response_schema=...)`, `Command(resume=value)` and `update_state` (https://github.com/langchain-ai/langgraph/releases/tag/1.2.12 , https://docs.langchain.com/oss/python/langgraph/interrupts , https://docs.langchain.com/oss/python/langgraph/checkpointers). ADK `RequestInput(response_schema)` (https://adk.dev/graphs/human-input/). MAF typed `request_info` with requests "re-emitted" on restore (https://learn.microsoft.com/en-us/agent-framework/workflows/human-in-the-loop). Mastra `resumeSchema` (https://mastra.ai/docs/workflows/suspend-and-resume). CrewAI `default_outcome` (https://docs.crewai.com/en/learn/human-feedback-in-flows). Temporal `wait_condition(timeout=...)` (https://docs.temporal.io/ai-cookbook/human-in-the-loop-python). Magentic plan review approve/revise (https://learn.microsoft.com/en-us/agent-framework/workflows/orchestrations/magentic). OpenAI `reject(rejection_message=...)` (https://openai.github.io/openai-agents-python/human_in_the_loop/).
- **CyberPong mapping.** The island and the Mission page render the form from `schema`. The snapshot exposes `gates[]` with their schemas. Only a person's resume can answer a gate. A value sent in another seat's claim is data, not an answer, which is the rule agent teams enforce for relayed approvals (https://code.claude.com/docs/en/agent-teams).
- **Draft status.** Partial. The draft has per-node gates, several open gates, and `--node` to name one. `resume` still takes only an outcome word, with no value, no edit and no timeout.

### 7. Write a checkpoint log per tick, resume from a node, and fork a run

- **Semantic.** After every tick that changed a graph, append a checkpoint `{ckpt_id, parent, at, nodes (status, visits, job_id), forks, gates, held, ends, history_len}` to `graphs/<gid>/checkpoints.jsonl`. `pong graph history <gid>` lists the checkpoints. `pong graph fork <gid> --from <ckpt|node>` starts a new graph that reuses every recorded claim up to that point and dispatches from the chosen node, optionally with an edited `prev`. `pong graph rewind` is the same operation applied in place, and only when nothing is running.
- **Who does it.** LangGraph checkpoints per superstep, with `get_state_history` and fork from a `checkpoint_id` (https://docs.langchain.com/oss/python/langgraph/checkpointers , https://docs.langchain.com/oss/python/langgraph/use-time-travel). MAF checkpoints per superstep, including pending requests and fan-in buffers (https://learn.microsoft.com/en-us/agent-framework/workflows/checkpoints). DBOS `fork_workflow` (https://docs.dbos.dev/python/tutorials/workflow-management). Mastra `timeTravel` (https://mastra.ai/docs/workflows/time-travel). CrewAI `restore_from_state_id` (https://docs.crewai.com/en/concepts/flows).
- **CyberPong mapping.** A fork has code side effects, so it also needs a git worktree or branch. The CLI seat's own session is never replayed. The new graph starts fresh seats that read the recorded claims.
- **Draft status.** Missing. The draft keeps one record per graph, rewritten on every tick. `history[]` is append-only, but it is not a restorable state.

### 8. Bound every loop, route to a `bounded` edge at the limit, show the remaining budget, and detect stalls

- **Semantic.** At `max_rounds`, `max_jobs` or `max_wall_min`, take an `on: bounded` edge (typically to a human gate that can grant more rounds), and stop only if there is no such edge. Render `{rounds_left}` into every prompt. Detect a stall: when the same node fails twice with near-identical summaries, or the critic's reason repeats, take `on: stalled`, or escalate to the gate.
- **Who does it.** OpenAI `error_handlers={"max_turns": ...}` returns a controlled output (https://openai.github.io/openai-agents-python/running_agents/). LangGraph `RemainingSteps` for "graceful degradation" (https://docs.langchain.com/oss/python/langgraph/graph-api). MAF `max_iterations` 100 (https://github.com/microsoft/agent-framework/blob/main/python/packages/core/agent_framework/_workflows/_runner.py). CrewAI `max_method_calls` 100 (https://github.com/crewAIInc/crewAI/blob/main/lib/crewai/src/crewai/flow/runtime/__init__.py). Magentic `max_stall_count` then replan (https://learn.microsoft.com/en-us/agent-framework/workflows/orchestrations/magentic). Strands warns about unbounded cycles (https://strandsagents.com/docs/user-guide/concepts/multi-agent/graph/). Claude Agent SDK `max_budget_usd` (https://code.claude.com/docs/en/agent-sdk/python).
- **CyberPong mapping.** `advance()` currently calls `stop(..., "failed_bounded:rounds")`. Route through `select_edges(..., "bounded")` first. A cost budget can come later, when the CLIs report usage.
- **Draft status.** Partial. The draft has the bounds, but reaching one is always a hard stop, and the draft has no stall detection.

### 9. Set a context policy and an input contract per node

- **Semantic.** `context: fresh | reuse | resume`: a fresh pane every visit, the same pane, or the same CLI session. `inputs:` is a whitelist of what the node's prompt may contain, from `goal`, `prev.summary`, `prev.artifacts`, `history`, `notes` and `gate_value`. Critics and judges default to `fresh` with inputs `goal`, `bar` and `prev.artifacts` only. They do not get the builder's narrative.
- **Who does it.** Claude Code subagents start in "a fresh, isolated context window" (https://code.claude.com/docs/en/sub-agents). OpenAI handoff `input_filter` vs agents-as-tools (https://openai.github.io/openai-agents-python/handoffs/ , https://openai.github.io/openai-agents-python/tools/). AutoGen `PerSourceFilter` (https://microsoft.github.io/autogen/stable/user-guide/agentchat-user-guide/graph-flow.html). Strands `reset_on_revisit` / `preserveContext` (https://strandsagents.com/docs/user-guide/concepts/multi-agent/graph/). ADK "strict state boundaries" (https://developers.googleblog.com/why-we-built-adk-20/).
- **Draft status.** Partial. `fresh` gives critics a clean pane. But the module docstring says "Every node is told where the graph's shared notes file is, to read first", and `extra` carries `graph_history` and `graph_notes` for every node, so a fresh critic still reads the builder's account.

### 10. Log every edge evaluation and show it on the map

- **Semantic.** For each completion, append events with a type and a delivery status: `dispatch`, `ack`, `claim`, `edge_eval {edge, on, outcome, status: taken|not_matched|shadowed|held|buffered_at_join}`, `join_fire`, `gate_open`, `gate_answer`, `retry`, `cancel` and `bounded`. The snapshot carries the most recent events per edge, so the 3D map can colour edges and show why a branch did not run.
- **Who does it.** MAF `edge_group.delivery_status` (delivered, dropped condition false, buffered) plus span links for fan-in (https://learn.microsoft.com/en-us/agent-framework/workflows/observability). LangGraph `tasks` and `checkpoints` stream modes (https://docs.langchain.com/oss/python/langgraph/streaming). Mastra Studio live step status (https://mastra.ai/docs/workflows/overview). OpenAI handoff and guardrail spans (https://openai.github.io/openai-agents-python/tracing/).
- **Draft status.** Partial. `_history(..., event=...)` exists for dispatch, retry, gate, join and cancel. It has no per-edge evaluation record.

### 11. Drain the runner before a restart

- **Semantic.** `pong runtime drain` stops new dispatches in every graph, lets running jobs finish and be harvested, writes a checkpoint and exits. Reinstalling the launchd agent then loses nothing.
- **Who does it.** LangGraph `RunControl.request_drain()`: "Drain is cooperative and operates between supersteps, never preempting work that is already running" (https://docs.langchain.com/oss/python/langgraph/fault-tolerance).
- **Draft status.** Mostly there. The draft's manual pause already "holds, it does not freeze". What is missing is a global switch that `install.sh` can call.

### 12. Lint the failure shapes the frameworks warn about

- **Semantic.** Lint should reject or warn on these shapes: a cycle with no path out that could win; a `wait: all` join downstream of a `switch` that can skip one of its inputs, which is the ADK/MAF dead-branch hang; a `switch` with no default; a join that only one branch can reach; a critic with no `fail` edge (the draft already checks this); and a graph with no gate (also already checked).
- **Who does it.** MAF build validation (https://learn.microsoft.com/en-us/agent-framework/concepts/workflows/builder-and-execution). AutoGen's rule that loops need an exit condition (https://microsoft.github.io/autogen/stable/reference/python/autogen_agentchat.teams.html). ADK's "The branch will end." warning (https://github.com/google/adk-python/blob/main/src/google/adk/workflow/_graph.py). The Strands unbounded-cycle warning (https://strandsagents.com/docs/user-guide/concepts/multi-agent/graph/).
- **Draft status.** Partial. `_warnings()` covers the critic, gate and no-edge cases, but not the join or switch interactions.

### A topology that uses items 1 to 9

```json
{
  "start": "plan", "max_rounds": 4,
  "boundaries": {"max_wall_min": 240, "max_jobs": 30},
  "nodes": [
    {"id": "plan", "role": "builder", "task": "{goal}"},
    {"id": "build", "role": "builder", "count": 2, "timeout": {"start_s": 90, "idle_min": 10, "run_min": 45},
     "retries": {"max": 2, "backoff_s": 60, "on": ["lost", "never_started", "timeout"]}},
    {"id": "pick", "role": "join", "wait": "all", "pass": "any"},
    {"id": "judge", "role": "critic", "count": 3, "context": "fresh", "inputs": ["goal", "prev.artifacts"]},
    {"id": "panel", "role": "join", "wait": 3, "pass": "majority"},
    {"id": "gate", "role": "human", "schema": {"outcomes": ["approved", "rejected"], "fields": {"note": "string"}},
     "timeout_min": 720, "default": "rejected"},
    {"id": "ship", "role": "end"}
  ],
  "edges": [
    {"from": "plan", "to": "build", "on": "done"},
    {"from": "build", "to": "pick", "on": "*"},
    {"from": "pick", "to": "judge", "on": "done"},
    {"from": "judge", "to": "panel", "on": "*"},
    {"from": "panel", "branch": "switch", "to": "gate", "on": "win"},
    {"from": "panel", "branch": "switch", "to": "build", "on": "fail"},
    {"from": "build", "to": "gate", "on": "error"},
    {"from": "build", "to": "gate", "on": "bounded"},
    {"from": "gate", "to": "ship", "on": "approved"},
    {"from": "gate", "to": "build", "on": "rejected"}
  ]
}
```

---

## What not to copy

- **Synchronous supersteps (BSP).** In MAF, a superstep "waits for all executors to complete before advancing", and the docs admit a chain "cannot advance until the long-running executor completes" (https://learn.microsoft.com/en-us/agent-framework/concepts/workflows/builder-and-execution). With CLI jobs of 5 to 60 minutes, that would stall every independent branch behind the slowest seat. CyberPong's asynchronous tick (dispatch as soon as a node is ready, then check the joins) is the right model. Take only the idea of a consistent checkpoint per tick.
- **Replay by re-execution and determinism rules.** Temporal, DBOS and Restate rebuild state by replaying deterministic workflow code against a journal (https://docs.temporal.io/encyclopedia/retry-policies , https://docs.dbos.dev/python/tutorials/workflow-tutorial). LangGraph restarts an interrupted node "from the beginning" (https://docs.langchain.com/oss/python/langgraph/interrupts). A Claude Code or Grok session in a pane cannot be replayed, and re-pasting a job is itself a side effect. Resume at the granularity of a whole job and never re-run a claimed node, which is the DBOS rule "never re-executed after they complete".
- **In-process timeout mechanics.** LangGraph timeouts "only apply to async nodes" (https://docs.langchain.com/oss/python/langgraph/fault-tolerance). CyberPong's work lives in external panes, so the timeouts have to be computed from timestamps and pane probes on each tick, which the draft already does.
- **A superstep-count recursion limit.** LangGraph's 1000 supersteps and MAF's 100 iterations count engine steps (https://docs.langchain.com/oss/python/langgraph/graph-api , https://github.com/microsoft/agent-framework/blob/main/python/packages/core/agent_framework/_workflows/_const.py). Neither maps to 30-second ticks. Keep counting visits, jobs and wall time.
- **A shared mutable state dict with per-key reducers.** Seats write files and claims, not typed channels. Concurrent writers need reducers or raise `INVALID_CONCURRENT_GRAPH_UPDATE` (https://docs.langchain.com/oss/python/langgraph/errors/INVALID_CONCURRENT_GRAPH_UPDATE). Keep state narrow (claim summary, artifacts, notes file) and reduce only at joins.
- **LLM routing on every round.** The Magentic manager and AgentKit's routing agent spend a model call per step to pick the next speaker (https://learn.microsoft.com/en-us/agent-framework/workflows/orchestrations/magentic , https://agentkit.inngest.com/concepts/networks). ADK 2.0 was built to move routing back into code (https://developers.googleblog.com/why-we-built-adk-20/). CyberPong routes on claim verdicts, and should keep doing so. Magentic's *stall counter* is worth borrowing (item 8); its manager is not.
- **Handoffs that move the whole conversation.** An OpenAI handoff gives the receiver "the entire previous conversation history" (https://openai.github.io/openai-agents-python/handoffs/). A transcript cannot move between different CLIs. Hand over the summary, the artifacts and the notes.
- **Letting an LLM turn a person's free text into an outcome by default.** CrewAI does this with `emit` plus `llm` (https://docs.crewai.com/en/learn/human-feedback-in-flows). A gate outcome should come from a button or a flag. Free text belongs in `--value`.
- **Pickle checkpoints and hosted tracing backends.** MAF needs a restricted unpickler for its checkpoints (https://learn.microsoft.com/en-us/agent-framework/workflows/checkpoints). LangSmith, the OpenAI traces backend and OTel collectors are services to run. Keep JSONL in `~/.pong` (or `PONG_HOME`), readable by the app and by `pong snapshot`.
- **Running a durable-execution server.** Temporal, Restate and Inngest are servers or clusters, which is out of proportion for one Mac. DBOS (a library over SQLite) is the closest in shape. Emulate its three rules in `~/.pong` rather than depending on it: a recorded step is never re-run, the ID is the idempotency key, and fork copies the steps done so far.
- **Agent-team style self-claiming.** In Claude Code agent teams, teammates "self-claim" the next unblocked task, "Task status can lag", and a lead can "stop early" (https://code.claude.com/docs/en/agent-teams). CyberPong's engine assigns every node to a seat and harvests the claims itself. Keep it that way. Borrow the acknowledged-delivery rule and the `TaskCompleted` exit-2 gate idea (a verdict check before a claim counts), not the self-claiming.

---

## Source index (primary pages and source files read on 2026-09-24)

LangGraph
- https://docs.langchain.com/oss/python/langgraph/graph-api
- https://docs.langchain.com/oss/python/langgraph/use-graph-api
- https://docs.langchain.com/oss/python/langgraph/errors/INVALID_CONCURRENT_GRAPH_UPDATE
- https://docs.langchain.com/oss/python/langgraph/interrupts
- https://docs.langchain.com/oss/python/langgraph/checkpointers
- https://docs.langchain.com/oss/python/langgraph/use-time-travel
- https://docs.langchain.com/oss/python/langgraph/fault-tolerance
- https://docs.langchain.com/oss/python/langgraph/streaming
- https://docs.langchain.com/oss/python/langgraph/use-subgraphs
- https://docs.langchain.com/oss/python/releases/changelog
- https://docs.langchain.com/langsmith/studio
- https://github.com/langchain-ai/langgraph/releases/tag/1.2.12
- https://github.com/langchain-ai/langgraph/issues/8842

OpenAI Agents SDK
- https://openai.github.io/openai-agents-python/running_agents/
- https://openai.github.io/openai-agents-python/handoffs/
- https://openai.github.io/openai-agents-python/tools/
- https://openai.github.io/openai-agents-python/guardrails/
- https://openai.github.io/openai-agents-python/human_in_the_loop/
- https://openai.github.io/openai-agents-python/tracing/
- https://github.com/openai/openai-agents-python/blob/main/src/agents/run_config.py
- https://github.com/openai/openai-agents-python/blob/main/src/agents/run_internal/turn_resolution.py

Google ADK
- https://developers.googleblog.com/why-we-built-adk-20/
- https://developers.googleblog.com/announcing-adk-go-20/
- https://adk.dev/graphs/ , https://adk.dev/graphs/routes/ , https://adk.dev/graphs/data-handling/ , https://adk.dev/graphs/human-input/
- https://adk.dev/agents/workflow-agents/loop-agents/ , https://adk.dev/agents/workflow-agents/parallel-agents/
- https://adk.dev/callbacks/ , https://adk.dev/runtime/web-interface/ , https://adk.dev/observability/traces/
- https://github.com/google/adk-python/blob/main/src/google/adk/workflow/_graph.py
- https://github.com/google/adk-python/blob/main/src/google/adk/workflow/_workflow.py
- https://github.com/google/adk-python/blob/main/src/google/adk/workflow/_join_node.py
- https://github.com/google/adk-python/blob/main/src/google/adk/workflow/_base_node.py
- https://github.com/google/adk-python/blob/main/src/google/adk/workflow/_retry_config.py
- https://github.com/google/adk-python/blob/main/src/google/adk/agents/run_config.py

Microsoft Agent Framework and AutoGen
- https://learn.microsoft.com/en-us/agent-framework/workflows/edges
- https://learn.microsoft.com/en-us/agent-framework/concepts/workflows/builder-and-execution
- https://learn.microsoft.com/en-us/agent-framework/workflows/checkpoints
- https://learn.microsoft.com/en-us/agent-framework/workflows/human-in-the-loop
- https://learn.microsoft.com/en-us/agent-framework/workflows/orchestrations/magentic
- https://learn.microsoft.com/en-us/agent-framework/workflows/observability
- https://learn.microsoft.com/en-us/agent-framework/devui/
- https://github.com/microsoft/agent-framework/blob/main/python/packages/core/agent_framework/_workflows/_edge_runner.py
- https://github.com/microsoft/agent-framework/blob/main/python/packages/core/agent_framework/_workflows/_runner.py
- https://github.com/microsoft/agent-framework/blob/main/python/packages/core/agent_framework/_workflows/_const.py
- https://github.com/microsoft/autogen
- https://microsoft.github.io/autogen/stable/user-guide/agentchat-user-guide/graph-flow.html
- https://microsoft.github.io/autogen/stable/reference/python/autogen_agentchat.teams.html

CrewAI, Pydantic, Mastra
- https://docs.crewai.com/en/concepts/flows , https://docs.crewai.com/en/learn/human-feedback-in-flows
- https://github.com/crewAIInc/crewAI/blob/main/lib/crewai/src/crewai/flow/runtime/__init__.py
- https://pydantic.dev/docs/ai/graph/graph/ , https://pydantic.dev/docs/ai/graph/builder/
- https://pydantic.dev/docs/ai/graph/builder/decisions/ , https://pydantic.dev/docs/ai/graph/builder/joins/
- https://pydantic.dev/docs/ai/durable-execution/overview/
- https://mastra.ai/docs/workflows/overview , https://mastra.ai/docs/workflows/control-flow
- https://mastra.ai/docs/workflows/suspend-and-resume , https://mastra.ai/docs/workflows/error-handling
- https://mastra.ai/docs/workflows/time-travel , https://www.npmjs.com/package/@mastra/core (1.70.0 dist read locally)

Durable execution
- https://docs.temporal.io/encyclopedia/retry-policies , https://docs.temporal.io/encyclopedia/detecting-activity-failures
- https://docs.temporal.io/ai-cookbook , https://docs.temporal.io/ai-cookbook/human-in-the-loop-python
- https://docs.restate.dev/ai
- https://www.inngest.com/docs/features/inngest-functions/steps-workflows
- https://www.inngest.com/docs/features/inngest-functions/error-retries/retries
- https://www.inngest.com/docs/reference/functions/step-wait-for-event
- https://agentkit.inngest.com/concepts/networks
- https://docs.dbos.dev/python/tutorials/workflow-tutorial , https://docs.dbos.dev/python/tutorials/workflow-management

Claude, Strands, Agno
- https://code.claude.com/docs/en/sub-agents
- https://code.claude.com/docs/en/agent-teams
- https://code.claude.com/docs/en/agent-sdk/python
- https://strandsagents.com/docs/user-guide/concepts/multi-agent/graph/
- https://strandsagents.com/docs/api/python/strands.multiagent.graph/
- https://github.com/strands-agents/sdk-python/blob/main/src/strands/multiagent/graph.py (1.57.0 wheel read locally)
- https://docs.agno.com/workflows/overview

CyberPong files compared
- python/pong/work_graph.py (committed 1.6.x custom-graph runtime)
- python/pong/graph_engine.py (Graph engine 1.7, commit 6c090dc, plus working-tree edits on 2026-09-24)
