# A DAG of loops: iteration and stopping inside AI pipelines, and Jev as each loop's judge (research note, 2026-09-24)

**Question (from the owner).** Can CyberPong combine a DAG with loops, "especially with Jev in the architecture"? The prompt was a Mirabilis Design (VisualSim) post whose one relevant sentence is "Directed acyclic graphs with loops may be more efficient than directed graphs, where extra states may precede an equivalent loop" ([mirabilisdesign.com](https://www.mirabilisdesign.com/directed-graph-no-loops-vs-acyclic-directed-graph-w-loops/)). The page returned a Cloudflare challenge (HTTP 403) to both WebFetch and curl on 2026-09-24, so only that sentence was confirmed, through a search index. The rest of the page and any evidence behind the sentence are **unknown**.

**Method.** Full-text reads (PDF to text) of 40+ primary papers from 2023–2026, plus classic sources on stopping rules. Repo claims cite `file:line` in this checkout (branch `cyberpong-1.7-graphs`). Earlier notes are cited rather than repeated: `graph-loops-labs-2026-09.md` (AlphaEvolve, FunSearch, AFlow, ADAS), `graph-loops-frameworks-2026-09.md` (loop primitives) and `judges-in-graph-loops-2026-09.md` (thresholds, calibration, labels). Where no evidence was found, the note says **unknown**.

---

## Executive summary

1. **The structure is ordinary graph theory, and CyberPong already computes it.**
   - Contracting every strongly connected component (SCC) of a directed graph yields a DAG, called the condensation ([Wikipedia](https://en.wikipedia.org/wiki/Strongly_connected_component)).
   - `graph_engine._scc` (graph_engine.py:303) and the Swift layout (GraphStudioModel.swift:449–519) already find those components.
   - What is missing is to treat each SCC as an object with its own entry, exits, budget, stop rule and best-so-far result. Today a budget belongs to each node's visit count (graph_engine.py:536–540), and a limit hands the *last* round to the gate (graph_engine.py:1904–1918).
2. **Published pipelines are already a DAG with packaged loops.**
   - MaAS restricts the multi-agent graph to a DAG and puts iteration inside operators (Refine, Debate), with a learned early-exit operator ([arXiv 2502.04180](https://arxiv.org/abs/2502.04180)).
   - AFlow's Test operator is a bounded loop (`test_loop=3`) inside one node ([arXiv 2410.10762](https://arxiv.org/abs/2410.10762)).
   - Graph of Thoughts models refinement as a self-loop and runs a static plan ([arXiv 2308.09687](https://arxiv.org/abs/2308.09687)).
   - AlphaEvolve nests an evolutionary loop around a staged evaluation cascade ([arXiv 2506.13131](https://arxiv.org/abs/2506.13131)).
3. **Most of what a refinement loop gains, it gains in the first rounds, and quality can go down after that.**
   - Self-Refine: most of the gain comes in the first iterations, and multi-aspect tasks go up and down between rounds ([arXiv 2303.17651](https://arxiv.org/abs/2303.17651)).
   - Snell et al.: about 38% of correct answers were turned wrong by a naive revision model ([arXiv 2408.03314](https://arxiv.org/abs/2408.03314)).
   - VRR-Stop: validity peaks and then declines when a repair can damage a correct plan ([arXiv 2607.17641](https://arxiv.org/abs/2607.17641)).
   - **So a loop should return its best round (the incumbent), not its last.**
4. **The value of a self-correction loop lies in its stopping signal. The model that did the work cannot supply that signal.**
   - The earlier gains in Reflexion and RCI came from oracle labels deciding when to stop. Without those labels, accuracy fell ([Huang et al., arXiv 2310.01798](https://arxiv.org/abs/2310.01798)).
   - Self-correction works "in tasks that can use reliable external feedback" ([Kamoi et al., arXiv 2406.01297](https://arxiv.org/abs/2406.01297)).
   - That is the role Jev can fill: an outside, typed judge that answers in under a second (TypeSafe's API documentation, https://docs.typesafe.ai).
5. **The best-supported stopping rules estimate whether one more round will add anything.**
   - TUMIX stops when the expected gain of another round is no more than λ times its cost, using an LLM judge with at least 2 rounds. That gave nearly the same accuracy at 49% of the cost ([arXiv 2510.01279](https://arxiv.org/abs/2510.01279)).
   - VRR-Stop repairs only while (1−b)·α − b·β > 0 (b = belief the plan is valid; α, β = chance a repair fixes or damages it). It gained 60.6 points over a fixed five-round loop at 0.72 repair rounds on average ([arXiv 2607.17641](https://arxiv.org/abs/2607.17641)).
6. **Jev's current numbers are not yet calibrated enough to drive that formula alone.**
   - An independent write-up calls Jev's outputs "good scores rather than good probabilities" (quoted in an earlier review of TypeSafe's API).
   - VRR-Stop shows that as the verifier's discrimination approaches zero, errors in the estimates can flip the stop decision ([arXiv 2607.17641](https://arxiv.org/abs/2607.17641)).
   - Start in shadow mode. Each round's grade gives a free, noisy label for the previous round's continue prediction. Clean labels come from the gate answers.
7. **Agents do not stop well on their own.**
   - A scan of 6,549 agent repositories confirmed 68 infinite-loop failures ([arXiv 2607.01641](https://arxiv.org/abs/2607.01641)).
   - An agent's own "DONE" is a weak signal: evidence-carrying termination made 0/288 unsafe completions, against 252/288 for a termination-critic core ([arXiv 2608.23623](https://arxiv.org/abs/2608.23623)).
   - Keep hard caps. A judge stops a loop early; it never extends it.

---

## 1. What "a DAG of loops" means for a CyberPong topology

- **The condensation.** Every loop in a topology is part of one SCC, and the SCCs form a DAG ([Wikipedia](https://en.wikipedia.org/wiki/Strongly_connected_component)).
  - Lint already warns about a cycle with no way out (graph_engine.py:292–299).
  - The deck already draws a dashed ring per cycle, labelled with rounds spent against `max_rounds` (GraphDeckView.swift:169–179).
- **Single entry.** A control-flow graph is *reducible* when every retreating edge is a back edge. A reducible loop has one header, the entry block that dominates the loop. Structured IF, FOR and WHILE statements always produce reducible graphs ([Wikipedia](https://en.wikipedia.org/wiki/Control-flow_graph)).
  - A packaged loop should have **one entry node**, so that "round k" has a single meaning.
- **What an explicit loop buys (our reasoning, not from the Mirabilis post):**
  1. Progress is guaranteed along the backbone's topological order.
  2. A worst-case cost can be computed: the sum, along the longest path of the condensation, of each loop's rounds times the jobs per round. Lint can print it beside `max_jobs`.
  3. Each loop gets its own stop rule and incumbent, instead of the single graph-wide `max_rounds` of 1–12 (graph_engine.py:238–244).
- **The same shape elsewhere:**
  - ADK `LoopAgent` stops at `max_iterations` or when a sub-agent sets `escalate` (graph-loops-frameworks-2026-09.md:73).
  - LangGraph bounds subgraph cycles with `recursion_limit` and `RemainingSteps` (graph-loops-frameworks-2026-09.md:48).
  - Agno has `Loop(max_iterations, end_condition)` (graph-loops-frameworks-2026-09.md:148).

| System | Acyclic backbone | Packaged loop | Stop rule |
|---|---|---|---|
| MaAS ([2502.04180](https://arxiv.org/abs/2502.04180)) | "G is constrained as a direct acyclic graph" | Refine, Debate and ReAct operators | a learned early-exit operator makes depth depend on the query |
| AFlow ([2410.10762](https://arxiv.org/abs/2410.10762)) | the workflow as code | Test operator: run, reflect, retry, `test_loop=3` | the outer search stops when the top-k average has not improved for n rounds, or after N rounds |
| Graph of Thoughts ([2308.09687](https://arxiv.org/abs/2308.09687)) | a static "Graph of Operations" | refine = self-loop edge (v, v); Repeat(k) | fixed k, then KeepBest(N) |
| AlphaEvolve ([2506.13131](https://arxiv.org/abs/2506.13131) §2.4) | an evaluation cascade: a candidate reaches the next stage only if "sufficiently promising" in all earlier ones | evolution over a program database | the compute budget (graph-loops-labs-2026-09.md:193) |
| FunSearch (graph-loops-labs-2026-09.md:199–210) | sample → execute → store | islands | discard the worst half of the islands every 4 h (an anti-stagnation reset) |

---

## 2. What 2023–2026 evidence says about iterating

### 2.1 Self-refinement: gains come early, can reverse, and the best round should be kept

- **Self-Refine** ([arXiv 2303.17651](https://arxiv.org/abs/2303.17651)).
  - The loop stops at a fixed step or on a stop indicator from the feedback, with at most 4 iterations.
  - Code optimization went 22.0 → 27.0 → 27.9 → 28.8, and constrained generation 29.0 → 40.3 → 46.7 → 49.7. The authors point out "the diminishing returns".
  - Acronym generation scored 11 → 17 → 12 → 17 over four rounds, so the algorithm returns the output with the best score across iterations.
  - On math, ChatGPT's feedback said "everything looks good" 94% of the time. With an outside signal that the answer was wrong, GPT-3.5 rose from 64.1 to 68.9.
- **Reflexion** ([arXiv 2303.11366](https://arxiv.org/abs/2303.11366)).
  - It loops "until the Evaluator deems τt to be correct" or a trial cap, keeping at most 1–3 reflections in memory.
  - The stuck heuristic: the same action and response for more than 3 cycles, or more than 30 actions.
  - HotPotQA retries stopped after 3 consecutive failures. WebShop runs were ended after 4 trials with no improvement.
  - False passes from its own tests: 16.3% on MBPP against 1.4% on HumanEval. The loop's ceiling is its verifier.

### 2.2 Self-correction limits: the stopping signal has to come from outside

- **Huang et al.** ([arXiv 2310.01798](https://arxiv.org/abs/2310.01798)).
  - Earlier gains "use the correct label to determine when to stop the self-correction loop".
  - Without oracle labels, GPT-4 on GSM8K went 95.5 → 91.5 → 89.0 over two rounds, and GPT-3.5 on CommonSenseQA went 75.8 → 38.1 → 41.8.
  - The model changed more correct answers to wrong ones than the reverse.
- **Kamoi et al.** ([arXiv 2406.01297](https://arxiv.org/abs/2406.01297)) found three things:
  - no work shows success with feedback from prompted LLMs, except on tasks unusually suited to it;
  - self-correction works with reliable external feedback;
  - large-scale fine-tuning enables it.
- **Tyen et al.** ([arXiv 2311.08516](https://arxiv.org/abs/2311.08516)): LLMs cannot find reasoning errors, but can correct them once given the location. **A critic that names the failing line is worth more than one that only says "fail".**
- **Stechly et al.** ([arXiv 2402.08115](https://arxiv.org/abs/2402.08115)): self-critique made performance collapse, a sound external verifier gave large gains, and "merely re-prompting with a sound verifier maintains most of the benefits".
- **Tsui** ([arXiv 2507.02778](https://arxiv.org/abs/2507.02778)): the same error is corrected when it is attributed to the user and missed when attributed to the model. That gap averaged 64.5% across 14 models.
- **SCoRe** ([arXiv 2409.12917](https://arxiv.org/abs/2409.12917)): a positive gain from a second attempt needed multi-stage reinforcement learning training (+15.6% on MATH, +9.1% on HumanEval).

### 2.3 Sequential vs parallel compute, and matching the loop to difficulty

- **Snell et al.** ([arXiv 2408.03314](https://arxiv.org/abs/2408.03314)).
  - Easy questions do best with purely sequential revisions. Hard questions need a mix of parallel and sequential compute.
  - Choosing the mix per difficulty beats best-of-N "using up to 4x less test-time compute".
  - Difficulty *predicted by the model* worked for choosing the strategy.
  - About 38% of correct answers were revised into wrong ones, so the final answer is picked from the whole chain by a verifier or a vote.
- **MAgICoRe** ([arXiv 2409.12147](https://arxiv.org/abs/2409.12147)).
  - It names "excessive refinement" and "insufficient refinement" as failures.
  - Easy problems are aggregated without refinement. Hard problems go review → refine "until either of the two conditions passes, or a maximum iteration is reached".
  - One iteration beat self-consistency by 3.4%, best-of-k by 3.2% and Self-Refine by 4.0%.
- **Rewarding progress** ([Setlur et al., arXiv 2410.08146](https://arxiv.org/abs/2410.08146)): score a step by the *change* in the likelihood of eventual success. Search against these process advantage verifiers was more than 8% more accurate and 1.5–5× more compute-efficient than against outcome reward models.
  - **For CyberPong:** a loop's stop judge should be asked about *progress*, not only level.

### 2.4 Longer is not always better

- **Inverse scaling in test-time compute** ([arXiv 2507.14417](https://arxiv.org/abs/2507.14417)): accuracy fell with longer reasoning, through five failure modes including distraction and drift to spurious features.
- **Overthinking in agents** ([arXiv 2502.08235](https://arxiv.org/abs/2502.08235)): picking the run with the lower overthinking score raised SWE-bench results by almost 30% and cut cost by 43%.
- **s1 budget forcing** ([arXiv 2501.19393](https://arxiv.org/abs/2501.19393)): extending thinking with "Wait" flattens out at 6× and can fall into "repetitive loops".
- **Self-conditioning** ([arXiv 2509.09677](https://arxiv.org/abs/2509.09677)): models make more mistakes when the context holds their own earlier errors.
  - **For CyberPong:** pass a builder distilled lessons (Reflexion keeps 1–3), not the full failed history. Consider a fresh seat when a loop stalls.

### 2.5 Search loops, and agents that do not stop

- **LATS** ([arXiv 2310.04406](https://arxiv.org/abs/2310.04406)): runs "until the budget is reached or the task is successful", with value V(s) = λ·LM(s) + (1−λ)·SC(s).
- **Tree search for LM agents** ([Koh et al., arXiv 2407.01476](https://arxiv.org/abs/2407.01476)): stop when value ≥ θ or the budget c is spent, then "navigate to the best state found thus far".
- **Automated workflow search.** ADAS runs a fixed 25 iterations ([arXiv 2408.08435](https://arxiv.org/abs/2408.08435)). Whether automatically found graphs beat hand-built ones is doubtful (graph-loops-labs-2026-09.md:287–300).
- **Infinite agentic loops** ([arXiv 2607.01641](https://arxiv.org/abs/2607.01641)): 68 confirmed failures in 47 projects. 69.1% were unbounded retry feedback, unbounded tool-call iteration, or multi-agent chat with no turn bound.
- **Agentic abstention** ([arXiv 2606.28733](https://arxiv.org/abs/2606.28733)): 13 agent systems on more than 28,000 tasks.
  - The hard part is *when* to stop. Larger models were sometimes worse at stopping in time.
  - Distilling past trajectories into stopping rules raised Llama-3.3-70B's timely recall from 26.7 to 57.4.
- **Evidence-carrying termination** ([arXiv 2608.23623](https://arxiv.org/abs/2608.23623)): a completion is allowed only with a typed certificate binding each claim to trace evidence. This gave 0/66 premature unsupported terminations, against 40/66 for the controller.
- **CaRT** ([arXiv 2510.08517](https://arxiv.org/abs/2510.08517)): fine-tunes when to terminate from counterfactual pairs of trajectories.

---

## 3. Stopping rules, cheapest first

| Rule | Evidence | Needs | Known failure |
|---|---|---|---|
| Hard cap | everywhere; Prechelt: no criterion "can guarantee termination", so pair each with a cap ([Prechelt 1998](https://page.mi.fu-berlin.de/prechelt/Biblio/stop_tricks1997.pdf)) | nothing | wastes rounds, or stops early |
| Same failure twice | CyberPong `no_progress` (graph_engine.py:1033–1048, 1623–1634); Reflexion's repetition heuristic | a fingerprint | misses slow drift |
| Patience on the best score | AFlow: top-k unchanged for n rounds; Prechelt UP_s (validation got worse s times in a row) and GL (relative loss over the best so far); the result is the best checkpoint, `E_opt` | a scalar per round | noisy scores trigger it falsely |
| Answers stop changing | ESC: stop when a window of samples agrees (GSM8K −80.1% samples) ([2401.10480](https://arxiv.org/abs/2401.10480)); Adaptive-Consistency: Beta/Dirichlet P(majority holds) > 0.95, 3.3× fewer on average, up to 7.9×, under 0.1% accuracy lost ([2305.11860](https://arxiv.org/abs/2305.11860)); Certaindex: up to 50% compute saved ([2412.20993](https://arxiv.org/abs/2412.20993)) | several samples per round | consistent but wrong answers; TUMIX found "majority stabilizes across two rounds" worse than a judge |
| Confident early exit | DEER: CoT 19.1–80.1% shorter at +0.3–5.0% accuracy ([2504.15895](https://arxiv.org/abs/2504.15895)); hidden-state probe "highly calibrated", 24% fewer tokens ([2504.05419](https://arxiv.org/abs/2504.05419)) | a confidence signal | our CLIs expose no hidden states |
| Value at or above a threshold | Koh θ; Pandora's box: keep sampling until the best so far reaches the fair-cap τ, where E[(v−τ)+] = c, giving 15–35% fewer generations ([2510.01394](https://arxiv.org/abs/2510.01394)); BEACON: up to 80% fewer samples ([2510.15945](https://arxiv.org/abs/2510.15945)) | a reward per candidate plus a cost | the reward model's own bias |
| Marginal gain vs cost | TUMIX: Δr = E[A(r+1) − A(r) \| signals] ≤ λ·cost, with signals "diversity collapse", "vote margin", "answer entropy" ([2510.01279](https://arxiv.org/abs/2510.01279)); VRR-Stop: G = (1−b)α − bβ ([2607.17641](https://arxiv.org/abs/2607.17641)) | b, α, β, or a judge | low verifier discrimination J = 1 − FPR − FNR can flip the sign |
| Sequential test | SPRT ([Wald 1945](https://doi.org/10.1214/aoms/1177731118)); anytime-valid confidence sequences ([arXiv 1810.08240](https://arxiv.org/abs/1810.08240)); optstop removed 57–97% of planned eval trials ([2608.14425](https://arxiv.org/abs/2608.14425)) | repeated noisy readings | assumes the readings are exchangeable |
| Learned halting | ACT halts once the summed halting output reaches 1 − ε (ε = 0.01), with a ponder cost τ ([1603.08983](https://arxiv.org/abs/1603.08983)); PonderNet: a per-step halting probability with a geometric prior ([2107.05407](https://arxiv.org/abs/2107.05407)); MaAS early exit; CaRT | training data | nothing to train on at CyberPong's volume |
| Value of information about the judge | Pandora's Router: a cheap noisy estimator vs an expensive accurate one. Closed-form value of information decides when to pay, matching exhaustive routing quality with far fewer expensive calls ([2608.20316](https://arxiv.org/abs/2608.20316)) | the two estimators' noise | noisy competing estimates |

**Smaller models as the stop judge.** ART lets a smaller model decide *when* to refine, and whether to trust the refinement by ranking it against the first answer. It gained 5 points over self-refinement ([arXiv 2311.07961](https://arxiv.org/abs/2311.07961)).
- **For CyberPong:** Jev plays that role. The LLM critic is the "expensive estimator", called when Jev's answer leaves the decision open.

---

## 4. Jev as each loop's continue / stop / escalate judge

### 4.1 Why Jev, and the limits

- **Why:**
  - Jev is outside the loop, typed, and never writes text (GRAPH-LOOPS.md:100).
  - It answers in 70–500 ms (TypeSafe's API documentation), so asking it every round costs almost nothing next to a seat's round.
- **Limits** (from an earlier review of TypeSafe's API):
  - Its probabilities rank well but are not yet calibrated.
  - A Noul repeated 15 times ranged 0.43–0.53, crossing 0.5.
  - A Choice cannot say "unknowable" unless offered `none`.
  - Whether Jev reads round-over-round numbers in the state reliably is **unknown**. Test it in shadow before trusting it.

### 4.2 Three typed questions per round (one call; questions over one state run in parallel)

1. **Level: is the incumbent good enough?** This is the existing grade.
   - The lower bound on the chance that every line passes is 1 − Σ(1 − p_i), the Fréchet bound (judges-in-graph-loops-2026-09.md:255), which is `1 − shortfall` (jev.py:787).
   - Use it as b, the belief that the work is valid.
2. **Progress: is this round better than the incumbent?** A Choice {better, same, worse, none}, asked in two option orders like `rank` (jev.py:871).
   - This catches the reversals Snell (38%), Huang and Self-Refine document.
   - Comparison is harder to fool than absolute scoring (judges-in-graph-loops-2026-09.md:48).
3. **Outlook: what should happen next?** A Choice {continue, ship_incumbent, escalate, change_strategy, none}.
   - This is TUMIX's judge-decides-termination, made typed and given a `none` option.
   - `change_strategy` exits the loop to parallel attempts with fresh seats. Snell supports this for hard problems, Reflexion's WebShop failure calls for diversity, and FunSearch resets islands.

**How the engine combines them (code, not Jev):**
- Continue only while the hard cap is not reached (the budget is left) and one of these holds:
  - rounds < `min_rounds` (TUMIX uses 2);
  - Outlook says `continue` at or above `take`, and Level has not passed.
- Later, once rates are measured, also require the VRR-style gain (1 − b)·α̂ − b·β̂ > cost:
  - α̂ = the loop type's measured rate at which a round fixes failing work;
  - β̂ = its measured rate at which a round damages passing work (from the ledger).
- Every exit carries the **incumbent**, not the last round.

### 4.3 Signals Jev should see (engine-computed, typed; artifact text stays labelled untrusted, judges-in-graph-loops-2026-09.md:321–325)

- **Budget:**
  - round k, `min_rounds`, rounds left;
  - wall time and jobs left (TUMIX's cost term).
- **Rubric trajectory** (Setlur's "progress" and the TUMIX signals):
  - per-line p_meets for the last 3 rounds and their deltas;
  - shortfall per round;
  - which lines failed in two rounds in a row.
- **Checks:**
  - exit codes;
  - count of failing tests;
  - whether the failure fingerprint repeated (graph_engine.py:1033).
- **Critic:**
  - the verdict word this round and last;
  - whether its must-fix list repeats.
  - Never the builder's own account (judges-in-graph-loops-2026-09.md:325).
- **Change size:**
  - diff lines this round vs last. Near zero means a stall; a large diff means thrash.
- **Incumbent:**
  - which round it is;
  - its shortfall.
- **Difficulty prior:**
  - the first round's shortfall. Snell's difficulty bins came from the model's own estimate.

### 4.4 Labels come almost for free

- Round k+1's grade is a label for round k's Outlook and Progress answers. It is noisy, because the grader is the same Jev.
- The gate answer is the clean label.
- Caution: VRR-Stop shows the verification rate rising while true validity falls ([arXiv 2607.17641](https://arxiv.org/abs/2607.17641)). Keep the 20% audit and the blinded gates (judges-in-graph-loops-2026-09.md:300–310).
- Estimate J = 1 − FPR − FNR per rubric against the person's answers. While J is low, use VRR-Guard's rule: replace the incumbent only by a clear margin.

---

## 5. A loop as a first-class topology object (proposal)

```json
{"loops": [{"id": "polish", "members": ["draft", "review"], "entry": "draft",
            "budget": {"rounds": 4, "min_rounds": 2, "wall_min": 90, "jobs": 10},
            "stop": {"judge": "jev", "rubric": ["@document"], "patience": 2, "min_gain": 0.05,
                     "keep": "best", "mode": "shadow"},
            "exits": {"win": "me", "ship": "me", "escalate": "me", "change_strategy": "fanout", "bounded": "me"}}]}
```

**Lint rules:**
1. Every SCC with two or more nodes, or with a self-loop, is a loop. If undeclared, it is packaged automatically with the graph's `max_rounds`.
2. Warn when an SCC has more than one entry node. It is not reducible, and "round" becomes ambiguous.
3. Nested loops must sit wholly inside the outer loop. Print the worst-case jobs, which multiply by nesting.
4. Every loop has an exit that reaches a person.

The deck already lays the backbone out in layers and rings each loop. It could show the budget, the incumbent's round and Jev's latest Outlook on the ring.

---

## 6. What to build first (smallest, best supported first)

1. **Incumbent per loop.** `bounded`, `no_progress` and stop exits pass the best round, not the last. Supported by Self-Refine, Snell, Prechelt `E_opt` and Koh. Today `_bounded` forwards `prev` (graph_engine.py:1913–1916).
2. **Per-loop round counter and trajectory in the ledger**, recorded as `meta`: loop id, round, incumbent, shortfall, and the check fingerprint. Without it, α̂ and β̂ cannot be measured.
3. **Patience on shortfall.** Stop to a person when the incumbent's shortfall has not improved by at least `min_gain` in 2 rounds, beside the existing same-lines-twice rule (AFlow, Prechelt).
4. **Progress and Outlook questions in shadow.** Show them on the ring and at the gate; route nothing.
5. **`change_strategy` exit to a best-of-n branch** with fresh seats, when a loop stalls on a hard task (Snell, self-conditioning).
6. **Turn on the marginal-gain rule** only after about 50–100 labelled transitions per loop type, with Platt scaling first (judges-in-graph-loops-2026-09.md:309).

**Not recommended:**
- learned halting or CaRT-style fine-tuning (no training volume);
- letting Jev extend a loop past its cap;
- a meta-agent that designs loops (graph-loops-labs-2026-09.md:300).

## 7. Unknown

- The Mirabilis post's argument and evidence (page blocked).
- Whether Jev reads numeric trajectories in the state reliably.
- α and β for CyberPong's loops.
- Whether any published system uses a typed-probability API as a loop's stop judge. The closest found are ART (a small model decides when to refine) and TUMIX (an LLM judge decides termination).
