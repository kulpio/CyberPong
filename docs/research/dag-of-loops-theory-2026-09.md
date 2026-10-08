# A DAG of loops: theory and modeling tools (2026-09)

The owner's question: can CyberPong combine DAGs with loops, the way the Mirabilis post suggests, with Jev in the architecture? This note covers the theory and the modeling tools behind "an acyclic backbone whose cycles are packaged as bounded loops". It ends with what the graph engine should copy. The engine facts come from `python/pong/graph_engine.py`, `docs/GRAPH-LOOPS.md` and the nine templates in `python/pong/loops/graphs/`. Everything else cites a URL. Where a source could not be read, this note says "unknown".

**How this was researched.** The Mirabilis page returns HTTP 403 (a Cloudflare challenge), so its wording comes from the search index. VisualSim's block documentation sits behind the same wall. The Ptolemy II book chapters, Ullman's lecture notes, Buck and Lee 1993, Murata 1989 and the BPMN 2.0.2 spec were read as PDFs; page numbers below are PDF pages. The template analysis in §3 was computed with a throwaway script (Tarjan SCCs, iterative dominators, natural loops) over the JSON files. Nothing was run against a live graph.

## 0. The answer in brief

1. **Every directed graph already is a DAG of loops.** Contract each strongly connected component (SCC) to one node and what remains is acyclic, the condensation (https://en.wikipedia.org/wiki/Strongly_connected_component). Tarjan's algorithm finds the SCCs in O(V+E) and emits them in reverse topological order (https://en.wikipedia.org/wiki/Tarjan%27s_strongly_connected_components_algorithm). CyberPong runs the same algorithm today (`graph_engine.py:303-335`), but only to print a warning.
2. **An SCC is not yet a loop.** It has no designated entry, can hide nested loops, and can be entered in several places. Compilers solve this with *natural loops* (single entry, the header dominates the body) and a *loop-nesting forest* (https://llvm.org/docs/LoopTerminology.html , https://llvm.org/docs/CycleTerminology.html). Structure is what makes analysis cheap: in a reducible graph, loop information settles in depth+2 passes (Ullman, http://infolab.stanford.edu/~ullman/dragon/w06/lectures/dfa3.pdf slides 25, 28).
3. **Every modeling tool that runs loops for a living packages them as blocks.** Examples: Simulink For/While Iterator subsystems, LabVIEW For/While loops with shift registers, BPMN's Loop Activity, Ptolemy's composite actors and higher-order actors, and statechart compound states. They all fill in the same six slots: a single entry, carried state, a stop test (before or after the iteration), an iteration cap, what happens to state on re-entry, and what flows out (§5).
4. **The guarantees come from the restrictions.** SDF makes deadlock and bounded memory decidable because it has no data-dependent control. Add data-dependent routing (BDF/DDF, Kahn networks) and both become undecidable (Ptolemy Dataflow chapter p.15 and p.20; Buck and Lee 1993 p.4). "Structured dataflow" gets most of the power back by nesting the control constructs (p.30). For an agent engine the lesson is to keep the backbone acyclic and make every cycle a declared, single-entry, integer-budgeted block.
5. **Jev fits as the loop's condition port, not its bound.** It works like LabVIEW's For Loop with a conditional terminal: N stays the maximum, and the condition can only end the loop early (https://www.ni.com/en/support/documentation/supplemental/07/configuring-labview-for-loops-to-exit-conditionally.html). Termination must never depend on Jev. Simulink's While Iterator with no maximum is the cautionary case: "the only way to stop the simulation is to terminate MATLAB" (https://www.mathworks.com/help/simulink/slref/whileiterator.html).
6. **CyberPong's templates are already DAGs of loops.** Eight of the nine are reducible with single-entry loops, and `planner-sprints` is literally two loops in sequence. The engine does not know this. Budgets are per node and cumulative, so nested loops share one counter and a person's reject after the budget is spent stops the graph (§3, §8).

## 1. The Mirabilis claim, stated precisely

The post's key sentence, as indexed: "Directed acyclic graphs with loops may be more efficient than directed graphs, where extra states may precede an equivalent loop" (https://www.mirabilisdesign.com/directed-graph-no-loops-vs-acyclic-directed-graph-w-loops/ , via search; the page itself answers 403). The rest follows Wikipedia's taxonomy. "Simple directed graphs" have no loops, and "Directed graphs with loops may be called loop-digraphs" (https://en.wikipedia.org/wiki/Directed_graph).

- **"Loop" is a term of art in graph theory.** It means a self-loop, "an edge that connects a vertex to itself" (https://en.wikipedia.org/wiki/Loop_(graph_theory)). A self-loop is a cycle of length 1, so a strict DAG has none. The consistent reading of "acyclic directed graph with loops" is therefore **a graph whose only cycles are self-loops**.
- **That is exactly the condensation with a self-loop kept on each collapsed SCC.** Every cycle becomes one node that "loops on itself", and the graph between those nodes is a DAG. This is the formal version of the owner's idea.
- **"Extra states may precede an equivalent loop" is read here as unrolling.** A graph with no loop construct has to spell iterations out as extra states. This is an interpretation, since the full post was unreadable. Harel's statecharts make the same compactness argument. They extend state diagrams with hierarchy, concurrency and communication, so that small diagrams "can express complex behavior" (https://www.sciencedirect.com/science/article/pii/0167642387900359 ; summary via https://www.recurse.com/blog/59-paper-of-the-week-statecharts-a-visual-formalism-for-complex-systems).
- **VisualSim** is "a commercial version of the Ptolemy II research project" at Berkeley (https://en.wikipedia.org/wiki/VisualSim_Architect). Its own loop blocks, and how it bounds them, are **unknown** because the docs are behind Cloudflare. Ptolemy II semantics (§4) are the best public proxy. That is an inference, not a documented fact.

## 2. SCC condensation: what it buys and what it does not

**What it buys**
- **A topological order of the loops.** The DAG of SCCs can be scheduled, laid out and linted like any DAG, and Tarjan's output order already is that order (reverse topological).
- **Deadlock-free clustering in scheduling.** The SDF schedulers use this. "Clustering a strongly connected component into a single actor A never results in deadlock since there can be no cycle containing A." Also, "an arbitrarily connected consistent SDF graph has a valid single appearance schedule if and only if each strongly connected component has" one (https://users.ece.utexas.edu/~bevans/courses/ee382c/lectures/18_sdf_looped/single.html). The whole-graph question reduces to a question per loop, which is the property CyberPong wants.
- **A cheap "no way out" test.** An SCC with no edge leaving it can only end by exhausting its budget. CyberPong's lint already checks this (`graph_engine.py:291-299`).

**What it does not give**
- **No header.** An SCC does not say where an iteration begins.
- **No nesting.** One SCC may contain several loops (see `fanout-synthesize` in §3).
- **No entry discipline.** An SCC may be entered at several nodes. LLVM's definition of a *cycle* is "a maximal strongly connected region", and a cycle "may have multiple entries" (https://llvm.org/docs/CycleTerminology.html).

**CyberPong today**
- **Lint** uses the SCCs only for the warning above.
- **The Swift deck** finds back edges by DFS from the roots and lays out the remaining DAG by longest path (`src/GraphStudioModel.swift:449-505`). It draws one dashed ring per SCC (`GraphStudioModel.swift:519-521`), labelled `spent/maxRounds`, where spent is the largest `visits` in the component (`src/GraphDeckView.swift:169-180`). With `max_visits` set, the label mixes two budgets. `planner-sprints` has `max_rounds` 3 and `sprint` `max_visits` 12, so its ring can read "7/3 rounds".

## 3. Reducible graphs, natural loops, the loop-nesting forest

**Definitions**
- **Dominance and back edges.** Node d *dominates* n if every path from the entry to n goes through d. A *back edge* is an edge whose head dominates its tail.
- **Reducible graphs.** A flow graph is *reducible* if every retreating edge in any DFS tree is a back edge. Test: remove the back edges and check that the rest is acyclic (Ullman, dfa3.pdf slides 17 and 20).
- **Natural loops.** The natural loop of a back edge a→b is "{b} plus the set of nodes that can reach a without going through b". Two natural loops are "either disjoint, identical, or nested" (slide 31). Nested natural loops therefore form a forest.
- **LLVM's terms.** A loop is a strongly connected node set where "all edges from outside point to the same node (the header)". The *latch* has the back edge, *exiting* blocks leave the loop, and *exit* blocks are the targets outside it. Loop-simplify form adds three guarantees: a preheader, a single backedge and dedicated exits. "LoopInfo does not contain information about non-loop cycles" (https://llvm.org/docs/LoopTerminology.html).

**Guarantees**
- **Fast convergence.** With depth-first ordering, iterative dataflow converges in depth+2 passes, where depth is the greatest number of retreating edges on any acyclic path. This holds for "any monotone framework" (slides 25, 28; Kam and Ullman, JACM 1976, https://dl.acm.org/doi/10.1145/321921.321938).
- **Structured code stays reducible.** If a program uses only while, for and repeat loops, if-then-else, break and continue, its flow graph is reducible (slide 20; https://en.wikipedia.org/wiki/Control-flow_graph).
- **Structured control is enough.** Sequence, selection and iteration can express every flow chart (Böhm–Jacopini 1966). Kosaraju showed that doing so without extra variables needs multi-level breaks (https://en.wikipedia.org/wiki/Structured_program_theorem).

**Costs**
- **Irreducible cycles have no canonical forest.** For irreducible cycles the forest "depends on the chosen DFS". Reducible cycles, by contrast, are found in every DFS (https://llvm.org/docs/CycleTerminology.html).
- **Havlak's normalization** maximizes the reducible loops found, at "at most one node and one edge per reducible loop" (TOPLAS 19(4) 1997, https://dl.acm.org/doi/10.1145/262004.262005). Ramalingam gives an axiomatic account of loop-nesting forests and an almost-linear algorithm to build them (TOPLAS 2002, https://dl.acm.org/doi/10.1145/570886.570887).
- **Single-entry single-exit (SESE) regions** of *any* graph, irreducible ones included, nest into a program structure tree built in linear time (Johnson, Pearson, Pingali, PLDI 1994, https://dl.acm.org/doi/10.1145/178243.178258).

**The workflow-patterns vocabulary**
- **WCP-21 Structured Loop** has "a single entry and exit point" and a pre-test or post-test condition.
- **WCP-10 Arbitrary Cycles** are "cycles … that have more than one entry or exit point". Block-structured offerings such as BPEL "are not able to represent" them (http://www.workflowpatterns.com/patterns/control/new/wcp21.php , http://www.workflowpatterns.com/patterns/control/structural/wcp10.php).

**CyberPong's templates, analysed** (SCCs, dominators from `start`, natural loops):

| template | loops (SCC) | entries | back edges (latch → header) | shape |
|---|---|---|---|---|
| best-of-n | none | — | — | pure DAG |
| brain-loop | {synthesize, grade, review} | synthesize | grade→, review→synthesize | one loop, two latches |
| build-verify | {build, tests, judge, ship} | build | tests-fail, judge-fail, ship-rejected → build | one natural loop: three latches share the header, so the tests loop and the judge loop merge |
| fanout-synthesize | {plan, work, gather, synth, ok} | plan | synth route:more → plan; ok-rejected → synth | **nested**: {synth, ok} inside {plan…synth} |
| jev-triage | {look … me} | look | me-rejected → look | one loop, closed only through a person |
| planner-sprints | {plan, gate0} then {sprint, tests, eval, ship} | plan; sprint | gate0→plan; four latches → sprint | **a DAG of two loops** |
| scout-panel | {panel, votes, fix, read} | panel | fix→panel | **irreducible inner cycle**: fix⇄read (fix -bounded→ read, read -rejected→ fix) is entered from votes at both fix and read, and neither dominates the other |
| tournament-evolve | {gen, pool, rank, evolve, meta} | gen | meta→gen | one loop; exits route:plateau and bounded |
| write-review | {draft, review, me} | draft | review-fail, me-rejected → draft | one loop |

Every SCC has a single entry at the SCC level. Only scout-panel has a cycle inside its SCC with two entries (WCP-10). There the person's reject re-enters the fix⇄panel loop at `fix`, not at its header `panel`.

## 4. Dataflow models of computation: how they express iteration

All pages below are from *System Design, Modeling, and Simulation using Ptolemy II* (Ptolemaeus, ed., 2014, https://ptolemy.berkeley.edu/books/Systems/).

**Synchronous dataflow (SDF)** (Lee and Messerschmitt, Proc. IEEE 75(9) 1987; Dataflow.pdf, https://ptolemy.berkeley.edu/books/Systems/chapters/Dataflow.pdf)
- **Fixed rates make the schedule computable.** Every actor has fixed token rates, and the *balance equations* fix how often each actor fires per "complete iteration". A model is *consistent* if the equations have a non-zero solution, and "an inconsistent model has no unbounded execution with bounded buffers" (p.8).
- **Feedback needs initial tokens.** "A feedback loop in SDF must include at least one instance of the SampleDelay actor", or it "would deadlock". The initial tokens count as initial conditions, not as part of the execution (p.13–14). With too few initial tokens, the model deadlocks (p.14).
- **Guarantee.** "Both bounded buffers and deadlock are decidable for SDF models" (p.15).
- **Cost.** "SDF is not very expressive. It cannot directly express conditional firing" (p.20).
- **Nested loops come from the schedule.** Rates imply iteration counts, so a compiler can choose nested *looped schedules* (Bhattacharyya and Lee, "Scheduling synchronous dataflow graphs for efficient looping", J. VLSI Signal Processing 1993, https://link.springer.com/article/10.1007/BF01608539).

**Dynamic and Boolean dataflow (DDF, BDF)**
- **Data-dependent iteration.** DDF expresses it with BooleanSwitch/BooleanSelect on a feedback path, "analogous to a do-while loop" (p.25).
- **Iterations are harder to define.** What counts as *one* iteration needs a `requiredFiringsPerIteration` parameter, or `runUntilDeadlockInOneIteration`. The definition "is complex, and can surprise the designer" (p.25, 28, 31, 35).
- **Cost.** With such routing, deadlock and bounded buffers "are undecidable" (p.20). "Determining whether a BDF graph can be scheduled with bounded memory is undecidable (equivalent to the halting problem); this is because BDF graphs are Turing-equivalent." Graphs "composed only of the 'well-behaved' structures" are still handled (Buck and Lee, ICASSP 1993, https://bears.ece.ucsb.edu/class/ece253/papers/buck93.pdf p.4).

**Structured dataflow** (p.30)
- **Nested control constructs.** "Control constructs are nested hierarchically" and "arbitrary data-dependent token routing" is avoided, "analogous to avoiding arbitrary branches using goto". A Case actor keeps the whole model SDF, so it stays "analyzable for deadlock and bounded buffers".
- **Origin and caveat.** The idea "was introduced in LabVIEW". Iteration uses higher-order actors such as IterateOverArray (BuildingGraphicalModels.pdf p.48). With recursion, "boundedness again becomes undecidable".

**Kahn process networks (KPN)**
- **Guarantee: determinacy.** The token sequence on every connection "is uniquely defined, and specifically is independent of how the processes are scheduled". Blocking reads suffice (Kahn 1974; Kahn and MacQueen 1977; ProcessNetworksandRendezvous.pdf p.4).
- **Cost.** Boundedness and deadlock "are undecidable". Parks' 1995 run-time scheduler is the practical answer (p.7).

**Ptolemy II hierarchical heterogeneity** (Eker et al., "Taming heterogeneity — the Ptolemy approach", Proc. IEEE 91(1) 2003, https://chess.eecs.berkeley.edu/pubs/488.html)
- **A composite actor carries its own director (model of computation).** From outside, it runs the same phases as an atomic actor. "Placing a director into a composite actor endows that composite actor with an executable semantics" (SoftwareArchitecture.pdf p.15).
- **An iteration** is prefire (test), fire (compute and produce outputs) and postfire (commit). "State changes are only committed in the postfire phase" (p.14–15).
- **Modal models give two re-entry policies.** A *reset* transition re-initializes the destination's refinement, and this is the default. A *history* transition resumes it (ModalModels.pdf p.10–11). A *termination* transition fires "when all refinements of the current state have terminated" (p.16).

## 5. Commercial loop blocks: what the block contains

| tool | block | carried state | stop test | cap | on re-entry | what flows out |
|---|---|---|---|---|---|---|
| Simulink | For Iterator subsystem | block states | iteration count | "Iteration limit", internal or external, known before running | "States when starting": held or reset | outputs; the loop finishes within one time step (https://www.mathworks.com/help/simulink/slref/foriterator.html , https://www.mathworks.com/help/simulink/slref/foriteratorsubsystem.html) |
| Simulink | While Iterator subsystem | block states | `cond` port; `while` (with an IC input) or `do-while` | "Maximum number of iterations"; the default −1 is unbounded, and a cond that never goes false runs "an infinite loop" | held or reset | outputs; optional iteration-number port (https://www.mathworks.com/help/simulink/slref/whileiterator.html) |
| LabVIEW | While Loop | shift registers: initialized, or uninitialized (keeps the last call's value); stacked to hold several past iterations (https://labviewwiki.org/wiki/Shift_register) | conditional terminal, Stop/Continue if True, **post-test**, so it "executes at least once" (https://labviewwiki.org/wiki/While_loop) | none | shift-register initialization | output tunnels: Last Value, Indexing or Concatenating (https://www.ni.com/en/support/documentation/supplemental/07/configuring-labview-for-loops-to-exit-conditionally.html) |
| LabVIEW | For Loop + conditional terminal | shift registers | conditional terminal | N "represents the maximum number of possible loop iterations" | same | auto-indexed arrays of unknown size "although you might know the upper bound" (same page) |
| BPMN 2.0.2 | Loop Activity (StandardLoopCharacteristics) | the inner activity's data | `loopCondition`; `testBefore` picks pre- or post-test | `loopMaximum`; "If it is not set, the number is unbounded" | — | the inner activity's output; WCP-21 Structured Loop (https://www.omg.org/spec/BPMN/2.0.2/PDF printed p.190, Table 10.28; §13.3.6, printed p.432) |
| Ptolemy II | composite actor with its own director; IterateOverArray | actor state, committed in postfire | postfire returning false ends the model (ModalModels.pdf p.16–17); termination transition | the director's `iterations` (Dataflow.pdf p.18) | reset or history transition | ports of the composite |
| VisualSim | unknown (docs unreadable) | unknown | unknown | unknown | unknown | unknown |

**Feedback needs a delay in continuous tools too.** In Simulink, a loop of direct-feedthrough blocks is an *algebraic loop*, solved by iterating a nonlinear solver each time step. A Unit Delay or Memory block breaks it (https://www.mathworks.com/help/simulink/ug/algebraic-loops.html). That is the same lesson as SDF's SampleDelay: a feedback edge carries last iteration's value, never this one's.

## 6. Statecharts and Petri nets

**Statecharts** (Harel, Sci. Comput. Program. 8(3) 1987, https://dl.acm.org/doi/10.1016/0167-6423(87)90035-9) add depth, orthogonality, broadcast and history to state machines. SCXML (https://www.w3.org/TR/scxml/) makes the loop block concrete:
- **Compound states (§3.1.2)** hold the iteration.
- **Completion events.** Entering a `<final>` child raises `done.state.id` (§3.7). A `<parallel>` is done when all its children are final (§3.1.3). That is a join and a loop exit in one mechanism.
- **History states (§3.10)** resume the last active substate, the "history vs reset" choice again.
- **Macrosteps (§3.13)** run microsteps until "no transitions are enabled".
- **Guarantees and gaps.** The formalism gives structure and modularity. Searching the SCXML text for an iteration bound on eventless transitions ("infinite loop", "loop forever") found none, so whether processors cap them is **unknown**.

**Petri nets** (Murata, Proc. IEEE 77(4) 1989, http://people.disim.univaq.it/adimarco/teaching/bioinfo15/paper.pdf)
- **Properties.** The net is k-bounded or safe (1-bounded), transitions have liveness levels L0–L4, and there are reachability and coverability questions (PDF p.7–8).
- **Cost.** The reachability problem "is decidable … although it takes at least exponential space (and time)" in general (PDF p.7).

**Workflow nets** add one start place and one end place. *Soundness* is option to complete, proper completion and no dead transitions.
- **Guarantee.** "The eight soundness notions described in the literature are decidable for workflow nets".
- **Cost.** "Most extensions will make all of these notions undecidable" (van der Aalst et al., Formal Aspects of Computing 23(3) 2011, https://doi.org/10.1007/S00165-010-0161-4 ; details via https://research.tue.nl/en/publications/soundness-of-workflow-nets-classification-decidability-and-analys).

For CyberPong the lesson: joins and gates are Petri-net transitions, and "a way out of every loop" is option to complete.

## 7. Guarantees vs cost, side by side

| model | termination | bounded resources | deadlock freedom | determinism | what it costs |
|---|---|---|---|---|---|
| DAG | yes | yes | yes | if nodes are | no iteration at all |
| SCC condensation | no (only orders the loops) | — | clustering an SCC is deadlock-free | — | O(V+E); no headers or nesting |
| reducible + natural loops | per loop, given a variant or cap | — | — | — | multi-entry cycles need splitting or refusal (Havlak) |
| SDF with delays | per iteration: yes | decidable | decidable | yes | no data-dependent control |
| DDF / BDF / KPN | undecidable | undecidable (Parks at run time) | undecidable | KPN: yes | analysis |
| structured dataflow / loop blocks | cap per block | per block | analyzable | yes | fewer shapes |
| Simulink For / LabVIEW For+cond / BPMN with loopMaximum | yes | yes | — | yes | the cap must be chosen |
| Simulink While (−1), BPMN without loopMaximum | **no** | no | — | yes | "terminate MATLAB" |
| statecharts | not by the formalism | — | — | per semantics variant | more semantics to specify |
| workflow nets | soundness decidable | boundedness decidable | yes, if sound | — | extensions make them undecidable |

**Termination proofs follow one pattern everywhere.** A loop terminates if some *variant* strictly decreases in a well-founded order each iteration (https://en.wikipedia.org/wiki/Loop_variant). An integer cap is the trivial variant. "The failing set shrinks" is a semantic one. Nested caps give a lexicographic variant, which still terminates.

## 8. What a graph-loop engine for AI agents should copy

**What CyberPong has today**
- **Every cycle is bounded by per-node visit caps.** Visits are capped by `max_rounds` 1..12 or a node's `max_visits` (`graph_engine.py:238-244`, `535-540`). Counters only grow: they start at 0 (`:2622`) and are incremented on dispatch (`:740`) and when a gate opens (`:1935`). That gives a simple, strong termination bound: jobs ≤ Σ caps × (1 + retries), with `max_jobs` on top (`:736-738`).
- **The price is that the engine cannot express nested loops or re-entry.**
  - In `fanout-synthesize`, `synth` has one counter (cap 2) shared by the inner reject loop and the outer "more" loop.
  - In `build-verify`, suppose tests fail twice and then the judge fails once. `build` has now used 4 of its 4 visits. If the person then answers `rejected`, `advance` finds the cap spent (`:1956-1960`) and calls `_bounded` from the gate (`:2560`). The gate has no `bounded` edge, so the graph **stops** as `failed_bounded:rounds` (`:1904-1917`), and the note is lost. This comes from reading the code; it was not run.
  - The contract's "At a limit, an `on: bounded` edge from the node that hit it is taken" (GRAPH-LOOPS.md:54) cannot help, because a person's answer is not a round of the loop.

**Proposed rules, each tied to its source**
1. **Loops are first-class and declared, or inferred and named.** The lint computes SCCs, then natural loops and the loop-nesting forest (Tarjan → dominators → natural loops; LLVM LoopInfo). It shows the forest in `pong graph lint` and on the deck. Proposed shape:
   `"loops": [{"id": "polish", "entry": "draft", "body": ["draft", "review"], "max_iter": 4, "reenter": "reset", "test": "after", "stop": {…}, "carry": […], "out": "last", "exits": {"done": "me", "bounded": "me", "escalate": "me"}}]`
2. **Single entry, or refuse.** A cycle with two entries (WCP-10; scout-panel's fix⇄read) is refused with the name of the second entry. The fix is to route re-entry to the header, which carries the person's note. Havlak's fix inserts a dispatcher node, and on an agent graph that node would be a job with its own prompt, so refusing is clearer.
3. **Budgets belong to the loop, per entry.** `max_iter` counts iterations of this entry of this loop. `reenter: reset` (the default) gives a fresh budget on each outer iteration or each person's reject; `continue` keeps counting. This mirrors Ptolemy's reset vs history transitions and Simulink's reset vs held states. The worst case is the product of `max_iter` along each nest path. The lint should print it ("worst case: 23 jobs") next to `max_jobs`, the way SDF computes its repetition vector before running. `max_jobs` and `max_wall_min` stay as the graph-wide backstop.
4. **Every loop has three exits.** `done` (the stop rule accepted), `bounded` (the budget is spent) and `escalate` (a person should decide). `bounded` and `escalate` default to the graph's nearest gate, so a spent budget never silently stops the graph. This matches BPMN's loopMaximum and LabVIEW's For with a conditional terminal.
5. **The test position is explicit.** `test: after` is do-while, LabVIEW's only form and BPMN's default. `test: before` lets Jev grade the incoming work first and skip the loop when it already passes, like BPMN `testBefore = true`.
6. **Carried state works like shift registers.** The loop keeps registers across iterations: the notes file (already exists, GRAPH-LOOPS.md:59), the failing rubric lines, the best candidate so far with its score, and `{iteration} of {max_iter}`. `out: last | best | all` copies LabVIEW's Last Value / Indexing tunnels. `best` makes a regression in the last round harmless.
7. **A variant, not only a judge.** `no_progress` already stops on two identical check failures or the same failing rubric lines twice (`:1031-1049`, `:1623-1635`). Generalize it per loop: the failing set must shrink, or the best score must rise, within k iterations, else `escalate`. This is the empirical variant of §7 and the stop rule the labs report (graph-loops-labs-2026-09.md:16, :107, :674).
8. **Iteration ancestry inside loops.** A join's barrier waits on every in-flight ancestor, found by walking all edges (`:2000-2013`, `:2067-2069`). Inside a loop, that is the whole SCC plus everything upstream. The barrier should count only same-iteration predecessors, meaning forward edges inside the loop body. This is SDF's lesson that a feedback edge carries the previous iteration.
9. **The deck draws the forest, not the SCC.** Show nested rings, one per loop, labelled `iteration k / max_iter` for this entry. Show a collapsed condensation view at Orbit altitude, where each loop is one node with its three exits, like a Ptolemy composite actor seen from outside. Drill in to see the body.

## 9. Where Jev sits in this architecture

- **In the backbone (acyclic):** `decide` at route points and `rank` at joins (GRAPH-LOOPS.md:104-109). A wrong route costs one branch, bounded by the DAG.
- **In each loop: the condition port.** After each iteration the engine asks a three-way question: *accept* (exit `done`), *continue* (another iteration), *escalate* (exit to a person). `abstain` or unavailable → escalate. The state it sees: the goal, the artifacts, the failing-line history and the iterations left. The existing rules carry over. Ask in both option orders, take only above threshold, and never write text. The asymmetric thresholds already in the contract fit the theory: continuing is cheap and reversible (0.7), exiting is not (0.9) (GRAPH-LOOPS.md:108, 113).
- **Jev ends loops early; it never extends them.** Termination comes from `max_iter` alone. Jev's value is efficiency: fewer wasted rounds and earlier escalation. An accept that is wrong leaves the loop, so every `done` exit must still reach a check or a person before anything leaves the Mac (GRAPH-LOOPS.md:100).
- **Calibration is unknown until labels exist.** Refitting thresholds from the ledger ("Platt from 100 labels a rubric, isotonic past 1,000") is "not built yet" (GRAPH-LOOPS.md:88). The judges note gives the label counts and an escalation-fatigue alarm above about 30% of gates (judges-in-graph-loops-2026-09.md:42, :332). Until then, the loop variant (rule 7) and the cap are the guarantees, and Jev is advice with a measured error rate.

## 10. Unknowns

- The full text of the Mirabilis post, and anything VisualSim-specific about loop blocks (403 behind Cloudflare).
- Whether SCXML processors bound eventless transition cycles.
- How often real CyberPong loops hit the "reject after budget" stop in §8. The ledger and graph history would show it; they were not queried.
- Whether per-entry budgets change cost in practice. That needs a before/after on live graphs.

## Sources (beyond those inline)

- Ullman, *Flow Graph Theory / Depth-First Ordering* (Stanford CS243 notes): http://infolab.stanford.edu/~ullman/dragon/w06/lectures/dfa3.pdf
- Ptolemy II book chapters: https://ptolemy.berkeley.edu/books/Systems/chapters/ (Dataflow, BuildingGraphicalModels, ProcessNetworksandRendezvous, SoftwareArchitecture, ModalModels)
- Earlier CyberPong research: `graph-loops-labs-2026-09.md` (loop shapes :11, stop rules :107, :674), `graph-loops-frameworks-2026-09.md` (LangGraph `recursion_limit` :48, subgraphs :53), `judges-in-graph-loops-2026-09.md` (thresholds :52, escalation :259-267).
