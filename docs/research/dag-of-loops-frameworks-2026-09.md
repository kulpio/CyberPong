# A DAG of loops: how workflow and agent frameworks put bounded loops inside an acyclic flow, and what CyberPong should take (2026-09)

Research date: 2026-09-24. Read-only research; the only file written is this one. Every claim about a framework carries the URL it came from (official docs, or the source file on the default branch when the docs were silent). Every claim about CyberPong carries a `file:line` from this working copy (branch `cyberpong-1.7-graphs`, uncommitted edits included). "Unknown" means I looked and did not find it.

**What this note adds.** `graph-loops-frameworks-2026-09.md` compared edges, joins, timeouts, gates and checkpoints across frameworks. `judges-in-graph-loops-2026-09.md` §8 set Jev's thresholds. This note covers one question only: how an acyclic flow and loops are combined, i.e. how a loop is declared, bounded and exited, whether loops nest or run in parallel inside a DAG, what carries across iterations, and how the UI shows it. It ends with what CyberPong should adopt, with Jev as each loop's stop/continue/escalate judge.

**The trigger.** The owner's link is a Mirabilis Design (VisualSim) post. WebFetch returned HTTP 403. The sentence the owner quoted (a DAG with loops may be more efficient than a general directed graph in which extra states precede an equivalent loop) appears in the search index for https://www.mirabilisdesign.com/directed-graph-no-loops-vs-acyclic-directed-graph-w-loops/ . I could not read any mechanism behind it, so this note does not rely on the post. The graph theory it points at is standard. Contracting every strongly connected component (SCC) of a directed graph to one vertex gives a DAG, the *condensation* (https://en.wikipedia.org/wiki/Strongly_connected_component). In compiler terms, a *reducible* flow graph is one whose forward edges form a DAG and whose loops each have a single header that dominates the loop body (https://en.wikipedia.org/wiki/Control-flow_graph).

---

## Executive summary

1. **Three families.** (a) *The loop is a first-class block with its own bound*: ADK `LoopAgent(max_iterations)`, DSPy `Refine(N, threshold)` and `ReAct(max_iters=20)`, Microsoft Agent Framework (MAF) declarative `Foreach`/`GotoAction`, Step Functions `Map`, n8n Loop Over Items, and ComfyUI loop open/close node pairs. (b) *The loop is a raw back edge in a general graph* with one global counter: LangGraph (1000 supersteps), MAF graphs (100 supersteps), Haystack (100 runs per component), CrewAI (100 calls per method), AutoGen (a termination condition or `max_turns` is required). Some graphs of this kind have no bound at all: ADK 2.x graph routes, Burr, and n8n IF loops. (c) *Acyclic engines* refuse cycles and offer something else: for-each fan-out, recursion, or re-running the whole DAG (Airflow, Argo DAG templates, Dagster), or they leave loops to plain code (Temporal, Prefect, ADK dynamic workflows).
2. **A DAG of loops is what families (a) and (c) already build.** The outer flow is acyclic, and each loop is a sealed sub-workflow with one entry. Step Functions writes the rule down: states inside a Map's `ItemProcessor` can only move to each other, and nothing outside can move into them. MAF sub-workflows exchange messages only through their own edges.
3. **There are two kinds of loop, and the frameworks keep them apart.** *Repeat-until* runs sequentially and exits on a condition. *For-each* runs in parallel and exits when the items are used up. Examples of the split: ADK Loop vs Parallel, MAF `GotoAction` vs `Foreach`, Step Functions Choice loop vs Map, n8n IF loop vs Loop Over Items, Mastra `dountil` vs `foreach`. CyberPong has repeat-until (cycles) and a fixed fan-out (`count: k`). It has no for-each sized by data (GRAPH-LOOPS.md:88).
4. **Exit is decided by one of four things**: a counter, a code predicate, the loop body signalling (ADK `escalate`, AutoGen's "APPROVE" edge condition, the OpenAI SDK judge example returning `pass`), or a numeric reward threshold (DSPy). Stall detectors exist in Magentic (`max_stall_count`) and in CyberPong (`no_progress`). **None of the systems I read asks a calibrated judge, one that can abstain, whether another iteration is worth running.** That is the slot Jev fits.
5. **Only DSPy returns the best iterate** (`Refine`/`BestOfN` keep the highest-reward prediction). Every other loop hands on its last iterate.
6. **Parallel loops inside a DAG work best as isolated children.** Step Functions Distributed Map gives each item its own child execution and history, a `MaxConcurrency`, and a tolerated failure count or percentage. MAF's superstep barrier makes a slow branch hold up the others.
7. **Long loops get their history folded.** Temporal uses Continue-As-New (hard limit 51,200 events). Step Functions starts a new execution (25,000 events). Airflow's maintainers say to treat one DAG run as one pass of the loop.
8. **CyberPong finding 1.** Condensing the nine shipped templates (§1) shows that in 7 of them the gate's `rejected` edge merges the critic loop and the approval loop into one SCC. The ring on the Graphs page is one SCC (GraphStudioModel.swift:519), so it cannot show that one loop is nested inside another.
9. **CyberPong finding 2.** Visit caps are per node and cumulative (graph_engine.py:535-540, 1956-1960). An outer loop therefore cannot re-enter an inner loop that has spent its budget. Reading `advance` and `_bounded` (1904-1918): in `write-review`, if the person answers `rejected` after the critic loop has used its 4 rounds, the graph stops with `failed_bounded:rounds`, because `me` has no `bounded` edge. I did not run this. It needs a test.
10. **Recommendation (§4).** Declare loops, or infer them from the SCCs. Give each loop one header, a counter that resets when an outer loop re-enters it, and a budget. Ask Jev at the back edge whether to stop, continue or escalate. Exit with the best iterate. Add for-each later.

---

## 1. CyberPong today, condensed

**What the engine does.** `lint` bounds every cycle with `max_rounds` (1..12, graph_engine.py:238-244). It runs Tarjan's algorithm (`_scc`, 303-338) only to warn about a cycle with no way out and no gate (291-299). A node's cap is its `max_visits`, else `max_rounds` (`_cap`, 535-540). `advance` refuses a visit past the cap and takes the source node's `on: bounded` edge; if there is none, the graph stops (1956-1960, 1904-1918). A node's `round` is its visit count, and the graph's round is the maximum over nodes (814-817). `no_progress` stops a loop when a check fails the same way twice (1040-1048) or Jev fails the same rubric lines twice (1623-1634). History is capped at 400 rows (532). Prompts can use `{visits_left}` (592, 773). The deck draws one dashed ring per SCC, labelled `spent/g.maxRounds`, where spent is the maximum visit count in the component (GraphDeckView.swift:169-180). It uses `g.maxRounds` even when the nodes carry `max_visits`: planner-sprints' nodes allow 12 visits but the ring reads `/3`.

**The templates, condensed.** I ran `lint` and `_scc` over `python/pong/loops/graphs/*.json`, read-only. "Entry" means a loop member with an edge from outside the loop; when the start node is inside the loop, that list is empty.

| template | loop (one SCC) | entry | exits | what is merged |
|---|---|---|---|---|
| write-review | draft, review, me | (start) | me approved→end | critic loop draft⇄review + approval loop via me rejected→draft |
| build-verify | build, tests, judge, ship | (start) | ship approved→end | tests loop + critic loop + approval loop |
| planner-sprints | sprint, tests, eval, ship; and plan, gate0 | sprint; (start) | ship approved→end; gate0 approved→sprint | the only template with two loops in sequence, i.e. a real DAG of loops |
| scout-panel | panel#1-3, votes, fix, read | panel#1-3 (copies of one node) | read approved→end | fix⇄panel loop + approval loop |
| fanout-synthesize | the whole graph (plan, work#1-4, gather, synth, ok) | (start) | ok approved→end | a fan-out/join *inside* a loop (synth route:more→plan) |
| jev-triage | look, route, choose, quick, rework, me | (start) | me approved→end | the route loop + approval loop |
| brain-loop | synthesize, grade, review | synthesize | review approved→done | grade loop + approval loop |
| tournament-evolve | gen#1-4, pool, rank, evolve#1-2, meta | (start) | rank route:plateau→pick, meta bounded→pick | the loop's stop rule is a seat claiming `route:plateau` (tournament-evolve.json:31) |
| best-of-n | none | | | acyclic |

**What this means.** (1) Every loop in the shipped templates has one entry once the `count` copies are grouped and the start node is treated as the header. A single-header rule would reject none of them. (2) Nesting is real but invisible. Inner critic loops sit inside outer approval loops, share a header (the builder), and condense into one SCC. Compilers merge loops that share a header for the same reason (https://en.wikipedia.org/wiki/Control-flow_graph), so structure alone cannot recover the nesting. It has to be declared. (3) A loop's budget is really a per-node visit count shared by every loop that passes through the node. That is how the write-review stop in summary item 9 happens.

---

## 2. Framework by framework

For each system: **declared** (how a loop is written), **bounded**, **exit** (what decides it), **nest**, **parallel** (loops running in parallel inside a DAG), **state** (what carries across iterations), **UI**.

**Google ADK (1.x workflow agents, 2.x graphs and dynamic workflows)**
- Declared: `LoopAgent(sub_agents=[...], max_iterations=N)`. Bounded: it stops after N iterations. Exit: a sub-agent sets `actions.escalate = True`, usually from a tool such as `exit_loop`. The LoopAgent never decides to stop by itself (https://adk.dev/agents/workflow-agents/loop-agents/). Nest: the docs' example puts the loop inside `SequentialAgent(sub_agents=[initial_writer_agent, refinement_loop])` (same page). State: shared session-state keys (`current_document`, `criticism`) are read and written each iteration (same page). `ParallelAgent` branches share `session.state` but not history (https://adk.dev/agents/workflow-agents/parallel-agents/). The agent-types page presents the three templates as orchestration with no LLM in it, deterministic by design (https://adk.dev/agents/workflow-agents/).
- 2.x graph: a loop is a back edge, e.g. `[critic, {REVISE: refine, DONE: finalize}], [refine, critic]`, and the docs warn that a graph cycle is **not** bounded automatically (https://adk.dev/graphs/routes/). The only global guard is `RunConfig.max_llm_calls`, default 500 (https://github.com/google/adk-python/blob/main/src/google/adk/agents/run_config.py). 2.x dynamic workflows write the loop in plain code (`while` + `ctx.run_node`, e.g. `MAX_FIX_ROUNDS = 3`). Completed sub-nodes are skipped on resume. Parallelism uses `asyncio.gather`. A dynamic node can sit inside a graph as a single node (https://adk.dev/graphs/dynamic/). UI: `adk web` shows the agent structure graph and traces (https://adk.dev/runtime/web-interface/).

**LangGraph**
- Declared: an edge back to an earlier node, plus a conditional edge that returns `END` (https://docs.langchain.com/oss/python/langgraph/use-graph-api). Bounded: `recursion_limit` counts **supersteps across the whole run**, default 1000 since 1.0.6; hitting it raises `GraphRecursionError`. A node can read the `RemainingSteps` managed value and wind down before the limit (https://docs.langchain.com/oss/python/langgraph/graph-api). Exit: the router function (code), or `Command(update=..., goto=...)` returned by a node (same page).
- Nest: a compiled subgraph can be a node over shared keys, or be called inside a node with its own schema (https://docs.langchain.com/oss/python/langgraph/use-subgraphs). `Command.PARENT` lets a subgraph node jump into the parent graph (graph-api page). Parallel: `Send` fans out map tasks, each with its own state, in a number known only at runtime (graph-api page). Since a compiled subgraph is a node, a loop packaged as a subgraph can be the target of `Send`; this is my inference, and I found no doc example. Whether a subgraph gets its own recursion counter: unknown. UI: `get_graph(xray=True|n)` draws subgraphs down to depth n (https://reference.langchain.com/python/langgraph/pregel/remote/RemoteGraph/get_graph).

**AutoGen GraphFlow (maintenance mode; see MAF)**
- Declared: `add_edge(reviewer, generator, condition=...)` back to an earlier agent. `set_entry_point` is required when a cycle leaves no source node (https://microsoft.github.io/autogen/stable/user-guide/agentchat-user-guide/graph-flow.html). Bounded and exit: validation raises `Cycle detected without exit condition` if every edge in a cycle is unconditional, and it forbids a node that mixes conditional and unconditional out-edges. A cyclic graph must have a `termination_condition` or `max_turns`, or construction fails (`has_cycles_with_exit`, `graph_validate` and the constructor at lines 149-190, 207-231 and 340-341 of https://github.com/microsoft/autogen/blob/main/python/packages/autogen-agentchat/src/autogen_agentchat/teams/_group_chat/_graph/_digraph_group_chat.py). Exit conditions are string or callable tests on the last message (lines 41-43).
- Nest: unknown (the docs show no team nested in a graph). Parallel: fan-out and joins are supported. `activation_group` / `activation_condition` (`all`/`any`) keep a cycle's re-entry edge from waiting on the forward edge into the same node (lines 45-60 of the same file). State: the shared message thread, filtered per agent with `MessageFilterAgent` (graph-flow page).

**Microsoft Agent Framework (graphs, sub-workflows, declarative YAML, Magentic)**
- Graph: a modified Pregel/BSP model. Every superstep waits for all executors, so a long executor on one branch holds up the chained executors on another (https://learn.microsoft.com/en-us/agent-framework/concepts/workflows/builder-and-execution). Bounded: 100 supersteps by default, then `WorkflowConvergenceException` (https://github.com/microsoft/agent-framework/blob/main/python/packages/core/agent_framework/_workflows/_runner.py).
- Nest: `WorkflowExecutor(workflow=inner)` runs a whole workflow as one executor. It has isolated state, messages cross its boundary only through its edges, and it nests to arbitrary depth with an overhead per level. All concurrent runs of one `WorkflowExecutor` share the inner workflow instance, so the executors inside it should be stateless (https://learn.microsoft.com/en-us/agent-framework/concepts/workflows/advanced/sub-workflows).
- Declarative YAML: `Foreach` (`source`, `itemName`, `indexName`, `actions`), `BreakLoop`, `ContinueLoop`, and `GotoAction(actionId)`. The documented repeat-until patterns are a counter variable checked by `If`/`ConditionGroup` before a `GotoAction` (e.g. `Local.TurnCount < 4`, with a separate "turn limit reached" branch), plus an agent `externalLoop.when` (https://learn.microsoft.com/en-us/agent-framework/workflows/declarative). The bound is the author's own variable; a built-in cap for `GotoAction`: unknown.
- Magentic: the manager's progress ledger (satisfied, in a loop, making progress) with `max_round_count`, `max_stall_count` (a stall leads to reset and replan) and `max_reset_count` (https://learn.microsoft.com/en-us/agent-framework/workflows/orchestrations/magentic).

**OpenAI Agents SDK**
- There is no graph. The docs contrast orchestration by LLM (handoffs) with orchestration by code. The code patterns are chaining, routing on structured output, running an evaluator in a `while` loop, and running agents in parallel with `asyncio.gather` (https://openai.github.io/openai-agents-python/multi_agent/). The official judge example has the evaluator return `pass | needs_improvement | fail`, loops `while True`, and bounds the loop at 3 rounds only in auto mode (`max_rounds = 3 if auto_mode else None`, lines 28 and 51-79 of https://github.com/openai/openai-agents-python/blob/main/examples/agent_patterns/llm_as_a_judge.py). Each `Runner.run` is capped by `max_turns` (default 10; https://github.com/openai/openai-agents-python/blob/main/src/agents/run_config.py).

**CrewAI Flows**
- Declared: a `@router` label re-triggers an earlier `@listen` method ("cyclic re-execution"). Bounded: `max_method_calls` (default 100) per method, then `RecursionError` (lines 642 and 3315-3317 of https://github.com/crewAIInc/crewAI/blob/main/lib/crewai/src/crewai/flow/runtime/__init__.py). Exit: the router's code. State: the flow's state object, with `@persist` for resume or fork. UI: `flow.plot()` draws HTML (https://docs.crewai.com/en/concepts/flows). Nesting a flow inside a flow: unknown.

**AWS Step Functions**
- Repeat-until: a `Choice` state whose `Next` points back. The official pattern is a Lambda that increments `index` and returns `continue`; `IsCountReached` routes back to the work or to `Done` (https://docs.aws.amazon.com/step-functions/latest/dg/tutorial-create-iterate-pattern-section.html). A Choice with no matching rule and no `Default` fails the execution (https://docs.aws.amazon.com/step-functions/latest/dg/state-choice.html).
- For-each: `Map` runs an `ItemProcessor` sub-workflow per item. **States inside the `ItemProcessor` can only transition to each other; no state outside can transition in** (https://docs.aws.amazon.com/step-functions/latest/dg/state-map-inline.html). Inline mode: up to 40 concurrent iterations; `MaxConcurrency` 0 means no limit, and 1 means one at a time in order; one failed iteration fails the Map; `Retry` applies to all iterations (same page). Distributed mode: each item runs as a child execution with its own history, up to 10,000 in parallel; `ToleratedFailurePercentage`/`ToleratedFailureCount` exceeded gives `States.ExceedToleratedFailureThreshold`; the console has a Map Run page; not available in Express workflows (https://docs.aws.amazon.com/step-functions/latest/dg/state-map-distributed.html). Nest: an Inline Map inside each Distributed Map child (https://docs.aws.amazon.com/step-functions/latest/dg/tutorial-itembatcher-single-item-process.html).
- Long loops: a Standard execution is capped at one year and 25,000 events; continue in a new execution with `StartExecution` (https://docs.aws.amazon.com/step-functions/latest/dg/tutorial-continue-new.html).

**Argo Workflows**
- The DAG template (`dag.tasks` with dependencies) is acyclic; it fails fast by default, and `failFast: false` lets all branches finish (https://argo-workflows.readthedocs.io/en/latest/walk-through/dag/). For-each: `withItems`/`withParam`/`withSequence` run the template once per item, in parallel (https://argo-workflows.readthedocs.io/en/latest/walk-through/loops/). `parallelism` caps parallel pods per workflow (https://argo-workflows.readthedocs.io/en/latest/fields/).
- Repeat-until is recursion: a template calls itself under a `when` (the coinflip example, https://argo-workflows.readthedocs.io/en/latest/walk-through/recursion/). The controller caps recursion at 100 template calls unless `DISABLE_MAX_RECURSION=true` (https://argo-workflows.readthedocs.io/en/latest/scaling/). `retryStrategy` (`limit`, `retryPolicy`, `backoff`, and an `expression` over `lastRetry.exitCode/status/duration`) is a bounded retry-until-OK loop on one step (https://argo-workflows.readthedocs.io/en/latest/retries/). UI rendering of recursion: unknown.

**Temporal**
- Loops, branches and parallelism are ordinary workflow code. Bound: the event history is limited to 51,200 events or 50 MB, with a warning at 10,240 events or 10 MB, and to 2,000 pending activities or children (https://docs.temporal.io/workflow-execution/limits). Continue-As-New checkpoints the state into the arguments of a fresh run: same Workflow Id, new Run Id, new history (https://docs.temporal.io/workflow-execution/continue-as-new). Nest: child workflows have their own histories to partition work, and a child can Continue-As-New without growing the parent (https://docs.temporal.io/child-workflows). Exit: code.

**Apache Airflow**
- A Dag is acyclic by definition. TaskGroups group tasks in the Graph view, and `@task.branch` picks the next task id(s) (https://airflow.apache.org/docs/apache-airflow/stable/core-concepts/dags.html). For-each: `expand()` creates n task copies at runtime; `max_map_length` defaults to 1024; `max_active_tis_per_dag` caps concurrency; a `@task_group` can be mapped, but mapping nested inside a mapped task group is not permitted (https://airflow.apache.org/docs/apache-airflow/stable/authoring-and-scheduling/dynamic-task-mapping.html).
- Faking a loop: a maintainer (potiuk) advises treating each DAG run as one pass of the loop and driving the runs from outside, and calls in-DAG task clearing unmaintainable (https://github.com/apache/airflow/discussions/21726). Having a Dag trigger itself uses `TriggerDagRunOperator` (https://airflow.apache.org/docs/apache-airflow-providers-standard/stable/_api/airflow/providers/standard/operators/trigger_dagrun/index.html).

**Prefect and Dagster**
- Prefect: flows are decorated Python functions, so loops and conditionals are plain code. Flows call flows, and in the UI each child flow run is linked to its parent (https://docs.prefect.io/v3/concepts/flows). Prefect markets itself as not needing DAGs (https://www.prefect.io/opensource). A built-in loop bound: unknown.
- Dagster: a job is a DAG of ops (https://docs.dagster.io/getting-started/concepts). Graphs nest ("op graphs can contain other op graphs", https://docs.dagster.io/guides/build/ops/graphs). For-each is `DynamicOut` with `.map()`/`.collect()` (https://docs.dagster.io/guides/build/ops/dynamic-graphs). I found no repeat-until construct.

**n8n**
- Nodes run once per item by default, which is an implicit for-each. Repeat-until: wire a node's output back to an earlier node and add an IF node to stop. Loop Over Items batches the items, has `loop` and `done` outputs, stops by itself when the items run out, and has a Reset option for pagination (https://docs.n8n.io/build/flow-logic/loop.md, https://docs.n8n.io/integrations/builtin/core-nodes/n8n-nodes-base.splitinbatches/). A cap on IF loops: none documented (unknown). UI: the loop is drawn as a wire back across the canvas (loop page image).

**ComfyUI**
- Execution changed from back-to-front recursion to a front-to-back topological sort. A node can expand into a subgraph at runtime, which is how loops are implemented, by tail recursion. Inputs can be lazy (https://docs.comfy.org/development/comfyui-server/execution_model_inversion_guide). Core ships no loop node. For/While Loop Open/Close pairs come from custom packs (https://github.com/akatz-ai/Akatz-Loop-Nodes, derived from BadCafeCode's demo). Bound on a while loop: unknown.

**DSPy 3.3.1 (PyPI)**
- `Refine(module, N, reward_fn, threshold, fail_count)` makes up to N attempts, each with a fresh rollout id at temperature 1.0. It stops when `reward >= threshold`. Otherwise an `OfferFeedback` predictor writes advice for each module, which is injected as a `hint_` input on the next attempt. It returns the **best-reward** prediction (lines 100-175 of https://github.com/stanfordnlp/dspy/blob/main/dspy/predict/refine.py). `BestOfN` is the same loop without the advice (https://github.com/stanfordnlp/dspy/blob/main/dspy/predict/best_of_n.py). `ReAct(max_iters=20)` loops until the finish tool is chosen, or ends on an error or a context overflow (lines 17 and 95-110 of https://github.com/stanfordnlp/dspy/blob/main/dspy/predict/react.py). These loops are modules, so they compose inside larger programs.

**Apache Burr**
- Transitions are `(from, to, condition)`; the first condition in declaration order that is true wins, and `default` catches everything else (https://burr.apache.org/concepts/transitions/). Cycles are allowed. To run forever, pass empty `halt_after`/`halt_before`. No iteration limit is documented, and halting because no transition is left is unsupported (https://burr.apache.org/concepts/state-machine/). Parallel: `MapStates`/`MapActions` run sub-applications and reduce their results into state; sub-applications can themselves loop; the UI shows each as a child application (https://burr.apache.org/concepts/parallelism/, https://burr.apache.org/concepts/recursion/).

**Haystack**
- Declared: connect a later component back to an earlier one. Bounded: `max_runs_per_component` (default 100) raises `PipelineMaxComponentRuns`. Exit: `ConditionalRouter`. State: `BranchJoiner` merges the first input with the looped-back one; greedy variadic sockets take one value per run, lazy ones accumulate across iterations (https://docs.haystack.deepset.ai/docs/pipeline-loops). Parallel: `AsyncPipeline.run_async` runs independent branches concurrently, with `concurrency_limit` defaulting to 4 (https://docs.haystack.deepset.ai/docs/asyncpipeline). UI: `pipe.draw()`/`show()` (pipeline-loops page).

**Also seen (from the companion note, same URLs):** Mastra `.dowhile`/`.dountil` (bounded by your own `iterationCount`) and `.foreach(step, {concurrency})`, default concurrency 1 (https://mastra.ai/docs/workflows/control-flow). Agno `Loop(max_iterations, end_condition)` (https://docs.agno.com/workflows/overview). Inngest AgentKit networks as "while loops with memory", stopped by `maxIter` (https://agentkit.inngest.com/concepts/networks).

### The matrix

| system | repeat-until declared as | its bound | exit decided by | nests | for-each / parallel loops | best iterate kept |
|---|---|---|---|---|---|---|
| ADK 1.x | `LoopAgent` block | `max_iterations` (local) | sub-agent `escalate` | yes (in Sequential) | `ParallelAgent` | no |
| ADK 2.x graph | back edge + routes | none (global `max_llm_calls` 500) | route value | workflow as node | routes fan out | no |
| LangGraph | back edge + conditional edge | 1000 supersteps (global) | router / `Command` | subgraph | `Send` | no |
| AutoGen GraphFlow | conditional back edge | termination condition or `max_turns` (required) | edge condition on message | unknown | fan-out, activation groups | no |
| MAF | back edge / `GotoAction` | 100 supersteps / author's counter | code, condition | `WorkflowExecutor`, any depth | fan-out (barrier), `Foreach` | no |
| OpenAI SDK | `while` in code | author's (example: 3 in auto mode only) | evaluator output | code | `asyncio.gather` | no |
| CrewAI | router label → earlier method | 100 calls/method (global) | router code | unknown | parallel listeners | no |
| Step Functions | Choice back edge | author's counter; 25,000 events | Choice rule | Map in Map | `Map` + `MaxConcurrency` + tolerated failures | no |
| Argo | recursion + `when` | depth 100 | `when` expression | templates | `withItems` + `parallelism` | no |
| Temporal / Prefect | code | 51,200 events (Temporal) / unknown | code | child workflow / subflow | code | no |
| Airflow / Dagster | none (acyclic) | n/a | n/a | task groups / graphs | `expand` (1024) / `DynamicOut` | n/a |
| n8n | wire back + IF | none documented | IF node | sub-workflows | implicit per item, Loop Over Items | no |
| ComfyUI | loop open/close pair (custom) | loop count / unknown | loop node | node expansion | unknown | no |
| DSPy | `Refine` / `ReAct` module | N / `max_iters` 20 (local) | reward ≥ threshold / finish tool | modules compose | `BestOfN` (sequential) | **yes** |
| Burr | cycle in transitions | none | first true condition | sub-applications | `MapStates` | no |
| Haystack | back connection | 100 runs/component | `ConditionalRouter` | unknown | `AsyncPipeline` (4) | no |

---

## 3. The patterns that recur

1. **The loop becomes a node of the outer flow.** Wherever loops are first-class, the outer graph sees the loop as one step with one entry and declared exits: an ADK `LoopAgent` inside a `SequentialAgent`, a Step Functions `ItemProcessor`, a MAF `WorkflowExecutor`, a LangGraph subgraph node, a DSPy module, a Burr sub-application. That is the condensation made explicit by the author, not inferred. It also sidesteps the fact that loops sharing a header cannot be told apart from structure alone (§1).
2. **Repeat-until and for-each are different constructs** with different bounds. Repeat-until is bounded by iterations. For-each is bounded by the number of items (Airflow 1024, Step Functions 10,000 children), concurrency and a failure tolerance.
3. **A local bound where the loop is first-class, a global counter where it is a back edge.** Global counters (LangGraph 1000 supersteps, MAF 100, Haystack 100, CrewAI 100) stop a runaway run but cannot say which loop ran away, or give each loop a different budget. Three systems ship cycles with no bound at all (ADK 2.x graphs, Burr, n8n). AutoGen is the only one that refuses to build a cyclic graph without a stop rule.
4. **The loop body usually signals the exit, and whoever grades it is uncalibrated.** ADK's refiner calls `exit_loop`. AutoGen tests the last message for "APPROVE". The OpenAI example trusts a judge's `pass`. CyberPong's tournament ranker claims `route:plateau`. Only DSPy turns the stop into a numeric threshold, and only Magentic and CyberPong detect a stall. No system estimates whether one more iteration is likely to pass.
5. **The best iterate is thrown away**, except by DSPy. A bounded loop that runs out of budget hands on its *last* attempt, which is not always its best.
6. **Parallel loops need isolation and a tolerance.** Step Functions gives each child its own history, `MaxConcurrency` and a tolerated failure count. Airflow caps map length and concurrency. MAF warns that its barrier couples branches. In CyberPong, a builder working in parallel also needs its own worktree (GRAPH-LOOPS.md:88).
7. **History is folded per iteration or per run** (Temporal Continue-As-New, Step Functions new execution and child histories, Airflow's one run per pass). The API form of "how much budget is left" is LangGraph's `RemainingSteps`; CyberPong has `{visits_left}`.
8. **The UI collapses a loop into a box that opens**: the Step Functions Map Run page, Airflow TaskGroups, LangGraph `xray`, Burr child applications, Prefect child flow runs. Of the UIs I read, none put the per-loop iteration counter on the box (for most of them: unknown).

---

## 4. What CyberPong should adopt (ranked)

### 4.1 Declare loops; infer the rest from the SCCs
Add an optional `loops` block. `lint` checks it against `_scc`. When the block is missing, every non-trivial SCC becomes an implicit loop with `max_iters = max_rounds`, which is today's behaviour, so existing topologies keep working. Lint rules:
- A loop's nodes lie inside one SCC and are strongly connected.
- Loops are nested or disjoint (a laminar family).
- The **header** is the only member entered from outside the loop, with `count` copies grouped and the start node counting as entered. Pattern 1 supports this rule, and no shipped template breaks it (§1).
- Every loop has an exit edge that is not `bounded`, or has a gate.
- A cycle with no stop rule and no gate is an **error**, not a warning, as in AutoGen, since the budget is now explicit.

### 4.2 Loop-scoped counters that reset on outer re-entry
An iteration of loop L is an edge into L's header from a node inside L. The same edge **resets** every loop with that header that does not contain the edge's source. So `me rejected → draft` resets `revise` and counts one iteration of `approve`. This fixes the write-review stop (summary item 9) without raising any cap. It matches how nested `for` loops behave and ADK's per-`LoopAgent` count. `max_visits` stays as a per-node cap. The graph-wide `max_jobs` / `max_wall_min` (GRAPH-LOOPS.md:54) stay as the global guard, like LangGraph's `recursion_limit`.

### 4.3 A budget per loop, in the units the graph already counts
`max_iters`, plus optional `jobs` and `wall_min` for each loop. Jev calls should count too; an earlier integration review raised this for `max_jobs`. When a loop runs out, take the loop's `bounded` exit, which is today's `_bounded` mechanism at loop scope, carrying the best iterate (4.5).

### 4.4 Jev decides stop, continue or escalate at the back edge
When a back edge is about to be taken and the loop has `"stop": {"by": "jev"}`, the engine asks Jev before dispatching the header again. It asks in the two option orders it already uses (GRAPH-LOOPS.md:108), and it offers only edges the topology holds (GRAPH-LOOPS.md:100). The state it sends is the goal, the current artifacts, the per-line probabilities of every iteration so far, and the iterations and budget left. Two questions:
- **Grade now.** This is the existing rubric grade, often already asked because Jev sits beside the critic. If it is a win, take the win exit.
- **"Will one more iteration make every line pass?"**, a Noul. This is the "will another round pass?" question an earlier integration review placed at the visit cap, moved to every back edge.

Code turns the probabilities into an outcome using the thresholds already in the judges note (§8.2):
- **continue** only when P ≥ the loop's `continue_at` (default 0.7, the send-back threshold in GRAPH-LOOPS.md:108) and budget remains;
- **escalate** to the loop's gate with the best iterate when P ≤ 0.3, or when the same lines fail twice (`no_progress`, graph_engine.py:1623-1634);
- **abstain** to a person in between.

Jev never extends a budget. Only a person does, by answering the gate with a label its edges name (GRAPH-LOOPS.md:39). This generalises four stop rules from §2: ADK's body-signalled `escalate`, DSPy's threshold, Magentic's stall counter, and tournament-evolve's self-claimed plateau. What it adds is calibration and an abstain band, and at under a second per call it can be asked at every iteration. **A useful property:** this forecast labels itself. The next iteration's grade is the outcome, so the ledger (GRAPH-LOOPS.md:123) can score it without a person. The labels are selective, though: a loop that stopped has no next grade. The judges note warns about exactly this bias (judges-in-graph-loops-2026-09.md:43). Audit a sample of stops with one extra iteration.

### 4.5 Exit with the best iterate, not the last
Copy each iteration's artifacts to `sessions/<team>/graphs/<id>/iters/<loop>/<n>/`, or to a git ref for code. On a `bounded` or escalate exit, hand on the iterate with the fewest doubts (Σ(1−p), GRAPH-LOOPS.md:113), and show the person which iteration it was. DSPy `Refine` does the same. Prerequisite: snapshotting artifacts, which is not built.

### 4.6 A for-each node, later
`{"role": "foreach", "over": "<list the planner emits>", "body": "<loop id>", "max_concurrency": 2, "tolerate": 1}`. Each item runs the sealed body loop with its own counters, and the results meet at a join. Two more rules: cap the list at 8 to match `count`, and count failures against `tolerate` the way Step Functions counts `ToleratedFailureCount`. This is the "fan-out sized by a list the planner emits" and "worktree per parallel builder" items already on the not-built list (GRAPH-LOOPS.md:88). Do not add it before worktrees exist.

### 4.7 Show loops as loops
- One ring per declared loop, nested rings for nested loops, and each ring labelled with its own counter and Jev's forecast, e.g. `revise 2/4 · next passes 0.64`.
- Fix the ring denominator, which uses `g.maxRounds` even for `max_visits` nodes (GraphDeckView.swift:177-179).
- In Orbit, draw a loop collapsed to one node, i.e. the condensation.
- Fold history to one row per iteration (the graph keeps 400 rows, graph_engine.py:532), with a loop summary in `{history}`.

### A topology sketch (write-review with declared loops)
```json
{
  "start": "draft", "max_rounds": 4,
  "loops": [
    {"id": "revise", "header": "draft", "nodes": ["draft", "review"], "max_iters": 4,
     "budget": {"jobs": 10, "wall_min": 90},
     "stop": {"by": "jev", "rubric": ["@document"], "continue_at": 0.7, "escalate_at": 0.3},
     "keep": "best"},
    {"id": "approve", "header": "draft", "nodes": ["draft", "review", "me"], "max_iters": 2}
  ],
  "edges": "unchanged: draft→review done; review→me win|abstain|bounded; review→draft fail; me→end approved; me→draft rejected"
}
```

---

## 5. What not to copy

- **A global step counter as the only bound** (LangGraph, MAF, Haystack, CrewAI). Keep one as a backstop, but budgets belong to loops.
- **Unbounded cycles** (ADK 2.x graphs, Burr, n8n IF loops), and AutoGen's example of exiting on a substring match. CyberPong already parses first-word verdicts (GRAPH-LOOPS.md:51).
- **Recursion as the loop mechanism** (Argo, ComfyUI tail recursion). Each iteration becomes a nested call with a depth cap. **Re-running the whole DAG as the loop** (Airflow) loses the loop's context between passes.
- **A superstep barrier around parallel loops** (MAF). A 30-minute seat would hold up every sibling.
- **Letting the looping seat declare its own plateau** (tournament-evolve.json:31). Compute plateau in the engine from Jev's per-iteration grades.

## 6. Unknowns and limits of this note

Unknown or not verified:
- the Mirabilis page body (403);
- whether a LangGraph subgraph gets its own recursion counter;
- whether ADK's docs show a `LoopAgent` inside a `ParallelAgent` (the types allow it);
- MAF's cap on `GotoAction` loops;
- n8n's and ComfyUI's caps on while loops;
- Prefect's loop bound;
- nesting in AutoGen and CrewAI;
- how the Argo and Temporal UIs draw loops.

The write-review stop in summary item 9 comes from reading the code, not a test run. Versions: DSPy 3.3.1 on PyPI (source read from `main`); for the other frameworks, the versions in `graph-loops-frameworks-2026-09.md`, and docs as served on 2026-09-24.
