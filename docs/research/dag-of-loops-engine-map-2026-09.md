# A DAG of loops: engine map (2026-09-24)

**Question.** The owner asked whether CyberPong should combine DAGs with loops, pointing at a VisualSim post whose one design claim is that "directed acyclic graphs with loops may be more efficient than directed graphs, where extra states may precede an equivalent loop" (https://www.mirabilisdesign.com/directed-graph-no-loops-vs-acyclic-directed-graph-w-loops/, as quoted in the request; this map did not re-read the page). The idea developed here: every directed graph condenses to a DAG of its strongly connected components (https://en.wikipedia.org/wiki/Strongly_connected_component), so a topology can be an **acyclic backbone whose cycles are packaged as first-class, bounded loops** with an entry, exits, a budget and a stop rule, and Jev can judge each loop's stop / continue / escalate.

**Scope.** This file maps the engine as it is on branch `cyberpong-1.7-graphs` (working tree, 2026-09-24): how cycles run today, what is awkward, and the exact places a loop construct would plug in. Paths are relative to the repository root. `GE` = `python/pong/graph_engine.py`, `WG` = `python/pong/work_graph.py`, `CO` = `python/pong/composer.py`, `SM` = `src/GraphStudioModel.swift`, `DV` = `src/GraphDeckView.swift`, `SV` = `src/GraphStudioView.swift`, `T/` = `python/pong/loops/graphs/`. Findings marked *(code reading)* were derived from the source, not observed on a live team.

## 0. The short answer

1. There is **no loop object** in the engine. A cycle is just edges that point backwards. The only cycle-aware code is Tarjan's SCC in lint, used for one warning (GE:291-299, `_scc` GE:303-338), and the same algorithm again in the Swift layout (SM:519-521, 526-553).
2. **"Round" is not counted anywhere as a round.** Each node counts its own `visits` (GE:739-741). `max_rounds` is a per-node visit cap applied uniformly to every non-gate, non-join node (`_cap` GE:535-540); `graph["round"]` is just the max visits seen, for display (GE:817, 926, 1471), never enforced.
3. Visits **never reset**. A nested (inner) loop re-entered by an outer loop keeps its spent visits, so inner and outer loops share one budget per node (planner-sprints works around it with `max_visits: 12`, T/planner-sprints.json:26, 36, 42).
4. At a limit, the engine looks for a `bounded` edge on the **node that tried to send the work** (not on the loop), else it **stops the whole graph**, cancelling every parallel branch (GE:1956-1961, 1904-1918, 2116-2129).
5. A join's barrier is "no ancestor in flight" over the **whole edge set** (GE:2067-2069, `_ancestors` GE:2000-2013). Inside a cycle every node of the SCC is an ancestor, so a join can wait on, or with `any`/number/timeout **cancel**, work in an unrelated sibling loop *(code reading)*.
6. A loop exits only when one node's verdict takes an edge out (critic/check/jev win, a route label, a gate answer). There is no loop-level stop rule beyond two per-node `no_progress` detectors (GE:1031-1049, 1623-1635).
7. Loop state crosses iterations only as `prev` (summary ≤600/2400 chars, GE:2334), the notes file, the last 8 history lines (GE:583-589) and a few per-node scalars. There is no best-so-far or per-iteration trajectory.
8. The deck draws one flat graph with a dashed ring per SCC; nested loops merge into one ring, and the ring and every "visit n/N" label divide by `max_rounds` even where `max_visits` applies, because the Swift model never reads `max_visits` (SM:137-195, DV:177-179, DV:406, SV:754).
9. The cheapest plug-in is a **flattening pass** like `_expand_copies` (GE:341-381): lint turns declared loops into flat nodes plus a `loops` table, and `advance`/`dispatch` do per-activation accounting. The tick, harvest and Jev plumbing stay as they are.

## 1. How cycles work today

### 1.1 Lint accepts any cycle and warns about one kind
- `lint` (GE:96-255) refuses unknown roles/edges, duplicate ids, `#` in ids (reserved for copies, GE:116-117), unreachable nodes (GE:213-223), and `max_rounds` outside 1..12 (GE:238-244; default 3). `max_visits` only has to be positive, with no upper bound (GE:181-187).
- `_warnings` (GE:258-300) runs `_scc` and, for each non-trivial SCC, warns only when no edge leaves it **and** no human node is inside (GE:292-299). A gate counts as a way out even if all its edges stay in the cycle.
- The normalised topology keeps name, start, starts, max_rounds, nodes, edges, notes, warnings, plus boundaries/protect/jev (GE:250-254). No SCC or loop data is stored; `WG.start` keeps only start, name, notes, starts under `graph.topology` (WG:903, 916-917).

### 1.2 What counts a round
- `dispatch` increments `node.visits` unless it is a retry (GE:739-741), sets `node.round = visits` (GE:814) and raises `graph.round` to the max (GE:817). Checks and Jev nodes do the same (GE:921-926, 1470-1471).
- The prompt's `{round}` is the node's own visit count (`round_n=visits`, GE:771); `{visits_left}` is `cap - visits` (GE:773) and the job carries `graph_visit: "k of cap"` (GE:796).
- History rows carry the node's round (GE:527). The Swift budget line prints `round {graph.round}/{maxRounds}` (SM:350-351).

### 1.3 `max_rounds` vs `max_visits`
- `_cap(graph, node)` = `node.max_visits` if set, else `graph.max_rounds` (GE:535-540). There is no graph-wide round counter and no per-loop cap.
- The cap is checked only in `advance`, before a dispatch (GE:1956-1961). Gates (`human`) increment visits but are never capped (GE:1928-1940); joins and ends return before the check (GE:1941-1951). A join's `visits` is bumped when it fires (GE:2088).
- The interview sets `max_rounds` from one efficiency answer: thorough 4, balanced 3, fast 1 (CO:131, 369, 403). With `fast`, a `write <-> grade` loop can never iterate.

### 1.4 What happens at a limit
- `advance` → target at cap → `_bounded(source=the sending node)` (GE:1956-1961). `_bounded` takes that node's `on: bounded` edges only (exact match; `select_edges` never falls back to `*` for `bounded`, GE:472, 1908-1909) and advances with `bounded_ok=True`, which skips the next target's own cap (GE:1915-1916, 1957). With no bounded edge it calls `stop` (GE:1918), which cancels every node in the graph (GE:2116-2129).
- Other limits: `max_jobs` stops the graph at dispatch, with Jev nodes exempt (GE:735-738); `max_wall_min` stops it in `tick` (GE:2394-2399). Neither has a bounded-edge path.
- Tested: `tests/test_graph_engine.py:446-457` (a critic's bounded edge to a person), `tests/test_graph_kind.py:83-113` (a third build stops as `failed_bounded:rounds`).

### 1.5 `no_progress`
- **Check nodes**: a fingerprint of the last 40 log lines (digits masked) plus the exit code (GE:1031); two identical failing results in a row (`no_progress`, default 2) → `_bounded(the check itself, "failed_bounded:no_progress")` (GE:1040-1049). A win resets `stuck` (GE:1032-1036).
- **Jev grades** (a `jev` node, or a critic with a Jev block): the same sorted set of failing rubric lines on two fails in a row → `_bounded` (GE:1623-1635, called at GE:1655-1658 and GE:2370-2373). The signature is only updated on a fail, so fail {a}, win, fail {a} also counts as "in a row" *(code reading)*.
- Both are per node. Neither looks at a trajectory (improving vs flat) or across the nodes of a loop.

### 1.6 Joins inside cycles
- `advance` into a join appends an arrival and sets `waiting` (GE:1941-1946). `_check_joins` (GE:2059-2111) computes `busy` = in-flight nodes among the join's **ancestors over all edges** (GE:2067-2069). `IN_FLIGHT` includes `waiting_human` and `held` (GE:75).
- `wait: all` fires when `busy` is empty; a number fires at that many arrivals; `any`, a number or a timeout cancels every busy non-human ancestor (GE:2076-2086). Arrivals are cleared on firing (GE:2087), so a join can fire once per iteration.
- The join does not know how many arrivals to expect; `pass: all` is computed over whoever arrived (GE:2041-2056). A branch that ended on `error` with no edge simply never arrives.
- The snapshot's `waiting_for` uses the same ancestor set (GE:2749-2752).

### 1.7 Copies inside cycles
- `count: k` expands into `id#1..#k`, and every edge is rewritten as the cross product of copies (GE:376-380). A copy is its own node with its own visits and cap.
- Copies feeding a **non-join** node: the first arrival dispatches it; a second arrival while it runs is recorded as `merged` and its output is not passed on (GE:1952-1955); an arrival after it finished dispatches it again and spends another visit.

### 1.8 How the shipped templates use cycles

| template | cycle(s) (SCC) | exit | cap |
|---|---|---|---|
| build-verify | {build, tests, judge, ship}: inner build⇄tests⇄judge plus outer `ship → build rejected` (T/build-verify.json:51-101) | judge win → ship; bounded from tests and judge (:73, :93) | max_rounds 4 (:5), shared by both loops |
| write-review | {draft, review, me} (:39-69) | review win/abstain/bounded → me | 4 |
| planner-sprints | {plan, gate0} and {sprint, tests, eval, ship}; `eval → sprint` on win **and** fail (:103-110), `ship → sprint rejected` (:128) | eval `route:complete` (:113-115), bounded (:98, :118) | max_visits 12 on the inner three, 3 elsewhere |
| scout-panel | {panel#1-3, votes, fix, read}, a join inside (:25-32) | votes win; fix bounded → read (:30) | 2 |
| fanout-synthesize | {plan, work#1-4, gather, synth, ok}; `synth → plan route:more` (:59-61) | synth done/bounded → ok | 2 |
| tournament-evolve | {gen#1-4, pool, rank, evolve#1-2, meta}; `meta → gen` (:90-92) | rank `route:plateau` (:80-82), meta bounded (:95-97) | 4 |
| brain-loop | {synthesize, grade, review} | grade win → review | 3 |
| jev-triage | {look, route, quick, rework, choose, me}, only through `me → look rejected` | me approved → end | 3 |
| best-of-n | none | | 1 |

## 2. What goes wrong or is awkward

**W1. Nested loops share one budget.** Visits accumulate for the life of the graph (GE:739-741) and the cap is per node (GE:535-540). In build-verify (max_rounds 4), one judge fail puts `build` on visit 2; two rejections at `ship` (T/build-verify.json:100-104) put it on visits 3 and 4. A third rejection makes `advance` find `build` at its cap and call `_bounded(ship)`; `ship` has only `approved` and `rejected` edges (T/build-verify.json:95-104), so the graph stops as `failed_bounded:rounds` *(code reading)*. The person's third "change this" ends the run because the inner loop spent the budget earlier. planner-sprints raises three nodes to 12 (T/planner-sprints.json:26, 36, 42) instead of saying "3 tries per feature, up to N features"; and because `eval → sprint` fires on win as well as fail (T/planner-sprints.json:103-110), feature iterations and fix iterations draw on the same 12.

**W2. One number for every loop.** `max_rounds` bounds a 12-minute critic loop and a 2-hour outer loop identically. The composer sets it from one efficiency answer (CO:403) and `parse_stages` never emits a `bounded` edge (CO:303-339), so any composed loop that runs out of rounds stops the graph instead of going to the `me` gate.

**W3. A limit in one loop stops parallel loops.** With no bounded edge on the sender, `stop` cancels every node, including a sibling loop that was converging (GE:1918, 2120-2122). The same applies to `no_progress` (GE:1049, 1634) and to `max_jobs` (GE:737).

**W4. Join scope is the SCC, not the iteration** *(code reading)*. Example: A fans out to loop L1 (b1 → k#1,k#2 → J1 → b1 on fail, J1 → M on win) and loop L2 (b2 ⇄ c2, c2 win → M); M → gate G; `G → A` on rejected. Because of the outer back edge, b2 and c2 are ancestors of J1 (GE:2000-2013). J1 (`wait: all`) waits while L2 iterates, even after both k copies arrived; with `wait: any`, a number or `timeout_min`, J1 cancels L2's running seats (GE:2082-2086). The inspector would list b2/c2 under "waiting on" (GE:2749-2752, SV:757).

**W5. Copies into a non-join inside a loop.** tournament-evolve sends `evolve#1, evolve#2 → meta` on `*` (T/tournament-evolve.json:41, 85-87), and `meta` is a writer. Depending on timing, the second candidate is `merged` and never reaches meta's prompt, or meta runs twice in the round, spending two of its four visits and sending `meta → gen#1..4` twice, where each gen copy either starts again or is `merged` if still running (GE:1952-1968) *(code reading)*. Lint does not warn about it.

**W6. The exit is a node's verdict; the stop rule is a count.** A loop ends when a critic/check/jev takes an edge out, a router picks a route, or a cap or a per-node `no_progress` fires. Nothing asks "is another iteration worth it?" once per iteration. The research already asks for `stop_when: {no_progress_rounds: 2}` over the failing set or the best score (docs/research/graph-loops-labs-2026-09.md:674), and for a max-iterations cap with a fallback of escalate or best-so-far (graph-loops-labs-2026-09.md:112). tournament-evolve leaves plateau detection to the ranker's own prose (`route:plateau`, T/tournament-evolve.json:31, 80-82).

**W7. `bounded` belongs to the wrong owner.** The bounded edge is looked up on whichever node was sending into the capped target (GE:1958-1960), so a loop needs a bounded edge on every node that has a back edge (build-verify puts one on `tests` and one on `judge`, :73, :93). The target of a bounded edge also escapes its own cap (`bounded_ok`, GE:1957), so a bounded edge into another loop bypasses that loop's budget.

**W8. Loop state is thin.** Across iterations the next visit gets `prev` (one step's summary and artifacts, GE:2377-2378), `last_prev` for a retry (GE:742), the notes file and team lessons (GE:559-580), the last 8 history rows (GE:583-589, 80), and per-node scalars: `last_fingerprint`/`stuck` (GE:1033-1036), `jev_fail_sig` (GE:1628), `jev_runs` (last 12, GE:1612-1614). `jev_runs` does **not** keep `p_pass` (GE:1613), so even a Jev-graded loop has no per-iteration score trajectory. There is no "best attempt so far" to return when a loop is bounded, which the research names as the fallback (graph-loops-labs-2026-09.md:112).

**W9. The UI shows one flat graph, with the wrong denominators.** `GraphLayout.compute` finds back edges by DFS from in-degree-0 roots (SM:470-486), layers the rest (SM:487-495) and rings each SCC (SM:519-521). Because SCCs are maximal, build-verify's inner and outer loops are one ring. The ring's "spent" is the max visits of any member divided by `maxRounds` (DV:177-179); `GNode` has no `max_visits` (SM:137-195) although the snapshot sends it (GE:2740). planner-sprints on its fifth sprint therefore shows `visit 5/3` (DV:406), `visits 5 of 3` (SV:754), `round 5/3` (SM:351) and a full amber arc (DV:548-550) *(code reading)*.

**W10. Wiring and loops disagree.** Planning treats every node of a graph as `in_cycle` (WG:973); dispatch only does so for the fixed `cycle`/`gauntlet` kinds (WG:393). `in_cycle` makes work "heavy" for the shared-pool floor (python/pong/wiring.py:166-168). An earlier engine audit asked for `graph["cycle_nodes"]` from lint's SCCs; a loop table would supply it.

**W11. A Jev hop costs a tick.** A `jev` node spawns its request (GE:1498) and the answer is read by `_tick_jev` on a later pass (GE:1509-1518, 2412-2415); the runner ticks every 30 s (docs/GRAPH-LOOPS.md:3). A per-iteration stop question asked as a node adds that latency to every iteration. There is a synchronous precedent: `_read_claim` calls `jev.ask(..., timeout=12)` inside the tick (GE:1774-1775).

## 3. Where a first-class loop would plug in

### 3.0 Three templates as a DAG of loops
What the condensation gives today versus what a declared nesting would give (edges from §1.8):

- **build-verify.** Today: `start → {build, tests, judge, ship} → end`, one SCC, one ring. Declared: `start → Review[ Fix[build → tests → judge] → ship ] → end`. `Fix` iterates on `tests fail` / `judge fail` (entry `build`) and exits on `judge win`, `abstain`, `bounded` and `build blocked`, all to `ship`. `Review` iterates on `ship rejected` (entry: the `Fix` loop) and exits on `approved`. Each `Review` iteration would open a fresh `Fix` activation with its own budget (W1).
- **planner-sprints.** Today: `start → {plan, gate0} → {sprint, tests, eval, ship} → end`. Declared: `Plan[plan → gate0] → Features[ Fix[sprint → tests → eval] ] → ship`. Here two loops **share an entry node**: `eval → sprint` on `win` means "next feature" and on `fail` means "fix again" (T/planner-sprints.json:103-110), and `tests → sprint fail` means "fix again". A loop construct therefore has to say which loop a back edge iterates (an `iterates: <loop id>` on the edge in option A below, or two scopes in option B). An SCC cannot express it.
- **tournament-evolve.** Today: one SCC `{gen#1-4, pool, rank, evolve#1-2, meta}` with exits `rank route:plateau` and `meta bounded`, both to `pick`. Declared: `Evolve[gen×4 → pool → rank → evolve×2 → join → meta] → pick → end`. It is a single loop, and its stop rule ("the best has not improved for two rounds", T/tournament-evolve.json:3) is exactly what a loop-level judge would own. Today that rule is the ranker's prose. The missing join before `meta` is W5.

### 3.1 Topology syntax (three options)
- **A. Annotate the flat graph** (backward compatible): `"loops": [{"id": "fix", "nodes": ["build","tests","judge"], "entry": "build", "max_iters": 3, "exits": {"win": "ship", "bounded": "ship", "escalate": "ship"}, "stop": {"no_progress": 2, "jev": {"rubric": ["@code-change"], "mode": "advise"}}}]`. Lint checks that the declared set is closed under the loop's own back edges and that every edge leaving it is a declared exit. A back edge carries `"iterates": "<loop id>"` when two nested loops share an entry (planner-sprints, §3.0); otherwise it iterates the innermost loop that contains both of its ends.
- **B. A `loop` node with a body** (hierarchical, like LangGraph subgraphs or ADK `LoopAgent`, docs/research/graph-loops-frameworks-2026-09.md:53, 73): `{"id": "fix", "role": "loop", "max_iters": 3, "body": {"start": "build", "nodes": […], "edges": […]}, "stop": {…}}`, with ordinary edges out of `fix` on `win | bounded | escalate`. Lint flattens it the way `_expand_copies` flattens `count` (GE:341-381), with body ids scoped under the loop id (`#` is taken by copies, GE:116-117; which separator is safe in job files, seat names and check file names is **unknown**, though checks and Jev sanitise ids, GE:891, 1420). This makes nesting explicit and keeps the runtime flat.
- **C. Infer loops from SCCs** with no syntax: each SCC is a loop, its entry is the node with in-edges from outside, its exits are the edges leaving it. Free, but it cannot see nesting (Tarjan returns maximal components, GE:325-333), so it fits single-level loops only.
- Recommendation for the design doc to weigh: **C by default for display and for `cycle_nodes`, A or B when a person wants per-loop budgets, nesting or a stop judge.**

### 3.2 Lint (`lint` GE:96-255, `_warnings` GE:258-300)
- Build the condensation once from `_scc` and store `sccs`, `cycle_nodes` and `loops` in the lint output next to `starts` (GE:250).
- For declared loops: the family must be laminar (nested or disjoint), each loop has one entry (or declares one), every exit edge leaves to a node outside it, `max_iters` ≤ graph cap. Upgrade "cycle has no way out" (GE:298-299) to an error for a declared loop.
- New warnings: copies feeding a non-join (W5); a join whose ancestor set crosses a loop it does not belong to (W4); a loop with no `bounded` exit (W2, W7).

### 3.3 Start (`start_nodes` GE:2602-2672, `WG.start` WG:873-917)
- Copy the lint `loops` into the graph record (today only four topology keys survive, WG:903, 916-917) and create per-loop runtime state: `{id, activation, iter, status, best, trajectory, stop_log}`.
- Add loop-level keys to the node fields copied into the record (GE:2623-2628): `loop`, `loop_depth`.

### 3.4 Dispatch, advance, route: per-iteration accounting
- **Entering a loop** (`advance`, GE:1921): source outside L, target is L's entry → new activation, `iter = 1`, reset per-activation visits of L's members.
- **Iterating**: an edge from inside L to L's entry (or one tagged `iterates: L`) → `iter += 1`, and every loop nested inside L starts a new activation on its next entry. At `iter > max_iters`, take L's `bounded` exit (loop-owned, W7) instead of `_bounded(source)`; with no exit, end only this loop's branch (record an end like `_route`'s no-edge end, GE:1974-1988) rather than `stop` the graph (W3).
- **Visits**: count `node.loop_visits` per activation next to the lifetime `visits` (GE:739-741). `_cap` (GE:535-540) becomes `min(node.max_visits, loop.max_iters)` per activation, with `graph.max_rounds` kept as a lifetime backstop. `render_task` gains `{iteration}`, `{iterations_left}`, `{loop_best}` (GE:592-614), and `extra.graph_visit` (GE:796) names the loop.
- **Leaving**: `_route` (GE:1971-1997) sees an edge from inside L to outside L → close the activation (`won | bounded | escalated`) and put `loop` and the best attempt into `prev`.
- **Bounded targets**: keep `bounded_ok` (GE:1957) for the gate it was meant for, but do not let it skip another loop's budget.

### 3.5 Joins (`_check_joins` GE:2059-2111)
- For a join inside L: compute ancestors on L's body minus L's back edges (this iteration's upstream), not on all edges (GE:2067). For a join outside any loop: treat each loop as one node of the condensation, so it waits for the loop as a unit.
- Let the loop's fan-out record the expected arrival count so `pass: all` can count a missing branch as a fail (GE:2041-2056).

### 3.6 Jev as the loop's stop / continue / escalate judge
- **When**: at each iteration boundary (the back edge to the entry), before the entry is dispatched again, and at exit.
- **What it sees** (typed state, never builder prose by default, GE:1104-1109): goal, `iter k of N`, a per-iteration trajectory of rubric lines (`jev_runs` needs `p_pass` and the failing lines, GE:1612-1614), check pass counts (the `passed/total` in the check summary, GE:1018-1019) and failure fingerprints (GE:1031), plus the current documents via `_upstream_work`/`read_documents` (GE:1083-1101, 1356).
- **Question**: a Choice over `continue | stop | escalate` with a none option (`jev.choice_question`, python/pong/jev.py:345), asked in two option orders and merged by `jev.decide` with a take bar (python/pong/jev.py:854; the node version is GE:1571-1585).
- **Authority** (mirrors the critic rule "either may send the work back, a win needs the critic", GE:1066-1069): Jev may **end a loop early** (escalate on a plateau, or `stop` → the win exit only if the loop's own critic/check also said win), and never extends one past `max_iters`. When Jev is unsure, unavailable or blocked (`_jev_blocked`, GE:1256-1265), the loop's existing rule stands.
- **How to call it**: synchronously with a short timeout like `_read_claim` (GE:1759-1781) to avoid a 30 s tick per iteration (W11), or asynchronously with the `_ask_async`/`_read_answer` pair (GE:1425-1461) while the entry waits `held`.
- **Ledger**: label each stop call with what happened next (the next iteration's grade, the gate answer), as `_label_gate` does for gates (GE:1883-1899), so the thresholds can be refitted.

### 3.7 `no_progress` per loop
Generalise GE:1031-1049 and GE:1623-1635 to the loop: compare the failing set (tests or rubric lines) and the best score across iterations of the activation, reset on activation, and on a plateau take the loop's `escalate` exit with the best attempt, not the latest.

### 3.8 Snapshot (`snapshot_fields` GE:2677-2725, `snapshot_node` GE:2728-2774, `WG.snapshot_block` WG:1549-1607)
- Add `loops: [{id, members, entry, exits, depth, parent, iter, max_iters, status, best, stop: {pick, p, at}}]` and `sccs` to `snapshot_fields`; add `loop`, `loop_visits`, `loop_cap` to `snapshot_node`. `max_visits` is already sent (GE:2740).

### 3.9 The Swift deck
- `GNode` must read `max_visits` (SM:137-195); the ring and labels should divide by it (DV:177-179, DV:406, SV:754) and `budgetLine` should stop printing `graph.round/maxRounds` (SM:350-351).
- `GraphLayout.compute` (SM:460-523): lay out the condensation (each loop one block), then lay out a block's body only when it is expanded. Back edges then come from the loop table instead of the DFS heuristic (SM:473-486).
- `GraphDeckView.buildWiring` (DV:147-216): replace the SCC ring (DV:169-180, `addRing` DV:543-556) with a collapsible loop block labelled `iter k/N` and the last stop call ("Jev: continue 0.82"); `visualSignature` (SM:319-326) must include loop `iter` and `status` or the block will not redraw.

### 3.10 The interview (`parse_stages` CO:230-345)
Today `a <-> b` only matters when b is not a critic (CO:307, 337-339); a critic's fail always returns to the last producer (CO:308-312) and a `me` gate's reject does too (CO:313-317), so every `me` creates an outer loop around the inner one. A bracket form such as `gather -> [write <-> grade]x3 -> me -> done` would need a pre-pass before `_ARROW.split` (CO:215, 253), and should emit a `bounded` exit to the next `me` (W2).

### 3.11 Tests to add
Next to `tests/test_graph_engine.py:446-457` and `tests/test_graph_kind.py:83-113`: an inner loop re-entered by an outer rejection gets a fresh budget; a bounded inner loop with no exit ends its branch without stopping a parallel loop; a join inside L1 does not wait on L2; copies into a non-join are refused or warned; the Jev stop call can only shorten a loop.

## 4. Unknowns
- Whether W4 or W5 has happened on a live team: **unknown**; both come from code reading, and the shipped templates (§1.8) run serially enough that W4 needs a parallel-loop topology to show.
- Iteration latency on a live team (tick, seat start, harvest): **unknown**; only the 30 s tick is documented (docs/GRAPH-LOOPS.md:3).
- Which node-id separator is safe for scoped loop bodies across jobs, seats, mailboxes and the app: **unknown**.
- Whether Jev's calibration on a three-way stop / continue / escalate question matches its calibration on grades and routes: **unknown**; the ledger has no such calls yet (the ledger is described at docs/GRAPH-LOOPS.md:123).
- The Mirabilis post's own argument beyond the quoted sentence: not re-read for this map.
