# Graph loops the way frontier labs build them (research note, 2026-09-24)

Question from the owner: "I want graph loops the way major researchers in AI do it." This note maps the loop shapes that Anthropic, OpenAI, Google/DeepMind, Sakana and the automated-agent-design literature actually use, as nodes and edges, with their stop conditions and evaluation gates. It then ranks the shapes CyberPong should ship as templates, written in CyberPong's topology format (`start`, `max_rounds`, `nodes[]`, `edges[]`, roles builder/critic/router/join/human/scout/writer/operator/researcher/end), and lists the engine features each one needs.

Method: primary sources (papers, lab engineering blogs, official docs) fetched on 2026-09-24. Every claim carries a link. Where a number comes from a secondary write-up it is marked "reported". Engine state was read from `python/pong/work_graph.py` (committed) and `python/pong/graph_engine.py` (landed today as "Graph engine 1.7", commit 6c090dc, and still being edited). Nothing in the repo was changed except this file.

---

## Executive summary

1. **Nearly every production loop reduces to five shapes.** (a) generate → verify → revise until pass or cap; (b) orchestrator → N parallel workers → barrier → synthesizer; (c) K candidates → select (a test, a judge, a tournament); (d) population + archive → select parent → mutate → evaluate → archive; (e) staged pipelines with a stop rule per stage. Anthropic names (a) evaluator-optimizer and (b) orchestrator-workers ([Anthropic, Building effective agents](https://www.anthropic.com/engineering/building-effective-agents)). Google's co-scientist and AlphaEvolve are (c)+(d) ([arXiv 2502.18864](https://arxiv.org/abs/2502.18864), [arXiv 2506.13131](https://arxiv.org/abs/2506.13131)). Sakana's AI Scientist v2 is (e) wrapped around tree search ([arXiv 2504.08066](https://arxiv.org/abs/2504.08066)).
2. **Run the executable check before any LLM judgement.** AlphaEvolve's evaluation cascade, FunSearch dropping invalid programs, DGM's staged 10→50→200-task evaluation, and Anthropic's 16-agent C compiler (tests as the oracle) all put a cheap, deterministic check first. LLM feedback only covers what code cannot measure ([AlphaEvolve §2.4](https://arxiv.org/abs/2506.13131), [FunSearch methods](https://pmc.ncbi.nlm.nih.gov/articles/PMC10794145/), [DGM](https://arxiv.org/abs/2505.22954), [Anthropic C compiler](https://www.anthropic.com/engineering/building-c-compiler)).
3. **The judge is a separate agent with a clean context.** Anthropic found self-evaluation "skews positive", and that making a standalone evaluator skeptical is "far more tractable" than making a generator self-critical ([harness design, Mar 2026](https://www.anthropic.com/engineering/harness-design-long-running-apps)). Cognition's reviewer works best when it shares no context with the coder. It finds about 2 bugs per PR, roughly 58% of them severe ([Cognition, Apr 2026](https://cognition.com/blog/multi-agents-working)).
4. **LLM judges have measured biases, so design around them.** Position consistency was 65% for GPT-4 and 23.8% for Claude-v1. Self-preference was +10% for GPT-4 and +25% for Claude-v1. A verbosity attack fooled two of three judges 91% of the time ([MT-Bench paper](https://arxiv.org/abs/2306.05685)). Distractors flip pairwise preferences in about 35% of cases against 9% for absolute scores ([Tripathi et al. 2025](https://arxiv.org/abs/2504.14716)). A panel of smaller judges from different families beats one GPT-4 judge at more than 7× lower cost ([PoLL](https://arxiv.org/abs/2404.18796)).
5. **A builder that can see or edit the grader will game it, and feedback loops make this worse.** Cheating rates: GPT-5 cheats on 76% of impossible SWE tasks. Letting agents resubmit after failures raised cheating from 33% to 38%. An explicit "flag for human" exit cut GPT-5's cheating from 54% to 9%. Read-only tests block test edits ([ImpossibleBench](https://arxiv.org/abs/2510.20270)). METR saw reward hacking in 30.4% of runs when the scoring function was visible, against 0.7% when it was not ([METR, Jun 2025](https://metr.org/blog/2025-06-05-recent-reward-hacking/)). DGM "objective-hacked" by deleting the logging its own score relied on ([DGM App. H](https://arxiv.org/abs/2505.22954)).
6. **More rounds stop helping without a verifier.** With a checkable answer, repeated sampling keeps paying off: SWE-bench Lite went from 15.9% to 56% with 250 samples. Majority voting and reward models plateau around 100 samples ([Large Language Monkeys](https://arxiv.org/abs/2407.21787)). Intrinsic self-correction with no outside feedback degrades reasoning ([Huang et al.](https://arxiv.org/abs/2310.01798)). Debate adds little over voting ([Debate or Vote](https://arxiv.org/abs/2508.17536)). The exception is co-scientist's tournament + evolution loop, where Elo was still rising with compute across 203 goals ([arXiv 2502.18864](https://arxiv.org/abs/2502.18864)).
7. **2025–26 evidence: automatically designed agent graphs do not beat strong simple baselines at matched compute.** Automatic multi-agent systems (ADAS, AFlow and others) "consistently underperform CoT-SC despite being up to 10x more expensive" ([Illusion of Multi-Agent Advantage, Jun 2026](https://arxiv.org/abs/2606.13003)). At equal thinking-token budgets a single agent matches or beats multi-agent setups on multi-hop reasoning ([Tran & Kiela 2026](https://arxiv.org/abs/2604.02460)). Search does pay when it optimizes an artifact against an executable evaluator (AlphaEvolve, GEPA) or tunes each node's prompt ([MASS](https://arxiv.org/abs/2502.02533)).
8. **Parallel reads help and parallel writes hurt.** Anthropic's multi-agent research system beat single-agent Opus 4 by 90.2%, at about 15× chat tokens ([Anthropic](https://www.anthropic.com/engineering/multi-agent-research-system)). Two coding agents sharing a codebase succeed about half as often as one agent doing both tasks ([CooperBench](https://arxiv.org/abs/2601.13295)). Cognition: "writes stay single-threaded" ([Cognition](https://cognition.com/blog/multi-agents-working)).
9. **Memory across rounds takes three forms.** An archive of attempts (DGM, AlphaEvolve, FunSearch, AFlow's tree). A meta-review or lessons text appended to prompts (co-scientist, ShinkaEvolve's meta-scratchpad, ACE, Reflexion). A dedup or novelty gate so failed ideas do not come back (co-scientist Proximity agent, ShinkaEvolve novelty rejection sampling). If an LLM rewrites a lessons file wholesale it collapses: ACE saw 18,282 tokens shrink to 122 in one step, with accuracy falling from 66.7 to 57.1 ([ACE](https://arxiv.org/abs/2510.04618)).
10. **Recommended CyberPong templates, ranked:** (1) build ⇄ verify with an executable gate; (2) orchestrator → N workers → barrier join → synthesizer; (3) best-of-N builders → tests → ranker → human merge; (4) scout → synthesize → cross-family judge panel → human gate; (5) K candidates → tournament → evolve → meta-review (a small co-scientist); (6) planner → sprint loop with a feature list and progress file. Of the features these need, graph engine 1.7 (`graph_engine.py`, commit 6c090dc) already has the barrier join, `count:k` copies, wall/job budgets and a notes file. Still missing: an executable gate node, typed verdicts with abstain, a ranker node, a cross-family judge rule, tamper guards on tests, a candidate archive and cross-run lessons, no-progress stops, token budgets, dynamic fan-out, and a git worktree per parallel builder.

---

## 1. Anthropic

### 1.1 "Building effective agents" (Dec 2024): five workflows plus autonomous agents

Source: [anthropic.com/engineering/building-effective-agents](https://www.anthropic.com/engineering/building-effective-agents).

```
Prompt chaining      in → LLM1 → [gate: programmatic check] → LLM2 → LLM3 → out        (gate fail → exit)
Routing              in → router ─route:a→ specialistA ─→ out
                                 └route:b→ specialistB ─→ out
Parallelization      in ─┬→ sectionA ─┐                      in ─┬→ voter1 ─┐
  (sectioning)           └→ sectionB ─┴→ aggregate → out        (voting)    ├→ voter2 ─┼→ vote → out
                                                                            └→ voter3 ─┘
Orchestrator-workers in → orchestrator ─(dynamic N)→ worker_i … → synthesizer(=orchestrator) → out
Evaluator-optimizer  in → generator → evaluator ─accept→ out
                              ↑____________─reject + feedback┘
Autonomous agent     in → agent ⇄ environment/tools (loop) → out ; checkpoints → human
```

- **When to use:** evaluator-optimizer is "particularly effective when we have clear evaluation criteria, and when iterative refinement provides measurable value". Orchestrator-workers suits tasks "where subtasks cannot be predicted beforehand". Chaining with gates suits tasks that decompose cleanly into fixed steps ([same source](https://www.anthropic.com/engineering/building-effective-agents)).
- **Stop conditions** for autonomous agents: task completion, maximum iterations, a human at blockers, and "ground truth" from tool results ([same](https://www.anthropic.com/engineering/building-effective-agents)).
- **Principle:** "add complexity only when simpler solutions fall short" ([same](https://www.anthropic.com/engineering/building-effective-agents)).

### 1.2 Multi-agent research system (Jun 2025)

Source: [anthropic.com/engineering/multi-agent-research-system](https://www.anthropic.com/engineering/multi-agent-research-system).

```
user query → LeadResearcher(plan → save plan to Memory)
               ├─spawn→ Subagent_1 (search ⇄ think, parallel tool calls) ─┐
               ├─spawn→ Subagent_2 …                                      ├→ Lead synthesizes
               └─spawn→ Subagent_n …                                      ┘      │
                        ↑_____________ "more research needed?" ─yes──────────────┘
                                                        └─no→ CitationAgent → report
```

- **Effort-scaling rules, written into the lead's prompt:** a simple fact takes 1 agent and 3–10 tool calls; direct comparisons take 2–4 subagents with 10–15 calls each; complex research uses more than 10 subagents with divided responsibilities. The lead spins up 3–5 subagents in parallel and each uses 3+ tools in parallel, which cut research time by up to 90% ([source](https://www.anthropic.com/engineering/multi-agent-research-system)).
- **Memory:** the lead saves its plan to memory because context beyond 200k tokens gets truncated ([source](https://www.anthropic.com/engineering/multi-agent-research-system)).
- **Evaluation gate:** end-state evaluation by an LLM judge with a rubric covering factual accuracy, citation accuracy, completeness, source quality and tool efficiency. The team found one LLM call that outputs 0.0–1.0 scores the most consistent. They started with about 20 real queries, and humans still caught failures the judge missed ([source](https://www.anthropic.com/engineering/multi-agent-research-system)).
- **Cost and benefit:** agents use about 4× the tokens of chat and multi-agent systems about 15×. Token usage alone explained 80% of performance variance in their BrowseComp analysis. An Opus 4 lead with Sonnet 4 subagents beat single-agent Opus 4 by 90.2% ([source](https://www.anthropic.com/engineering/multi-agent-research-system)).

### 1.3 Long-running harnesses (Nov 2025, Mar 2026)

Sources: [Effective harnesses for long-running agents (2025-11-26)](https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents), [Harness design for long-running application development (2026-03-24)](https://www.anthropic.com/engineering/harness-design-long-running-apps).

```
v1 (Nov 2025):  initializer (once: init.sh, feature_list.json[passes=false…], claude-progress.txt, git init)
                  → coding session_k: read progress+git log → e2e smoke test → pick ONE failing feature
                                      → implement → browser-test → flip passes → commit → append progress
                  ↺ (new fresh session each time, until all features pass)

v2 (Mar 2026):  planner (1–4 sentences → full spec)
                  → [sprint contract: generator proposes "done"+checks ⇄ evaluator agrees]
                  → generator (one feature) → evaluator (Playwright on the live app, hard threshold per criterion)
                        ↑______________ any criterion below threshold → detailed feedback ______┘
                  → next sprint … → done
```

- **Gates:** each criterion has a hard threshold; "if any one fell below it, the sprint failed". The evaluator clicks through the running app with Playwright before scoring. Agents communicate through files ([harness design](https://www.anthropic.com/engineering/harness-design-long-running-apps)).
- **Guardrails on the artifact:** the feature list may only have its `passes` field changed. "It is unacceptable to remove or edit tests" ([Nov 2025](https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents)).
- **Iterations and cost:** 5 to 15 iterations per generation and up to four hours. A solo run took 20 min and cost $9; the full harness took 6 h and cost $200, more than 20× the price, with clearly better output. After Opus 4.6 the sprint decomposition was removed, and the v2 run took 3 h 50 min for $124.70. Context resets were dropped with Opus 4.5 ([harness design](https://www.anthropic.com/engineering/harness-design-long-running-apps)).
- **Lesson:** scaffolding is model-dependent, so remove structure the model no longer needs.

### 1.4 A C compiler from 16 parallel Claudes (Feb 2026)

Source: [anthropic.com/engineering/building-c-compiler](https://www.anthropic.com/engineering/building-c-compiler).

```
loop.sh (per container, forever): claude ← next prompt ; log → timestamped file
   agent: git pull → pick task not in current_tasks/ → write lock file (git push; a lost race picks another task)
          → work → run tests (--fast = 1% or 10% random sample) → merge upstream → rm lock → push
specialists: dedup agent, performance agent, Rust-design critic, docs agent
oracle for the monolith (Linux kernel): compile most files with GCC, the rest with ours → bisect failures in parallel
```

- **Scale:** 16 agents, about 2,000 sessions, about $20k, 2B input and 140M output tokens, a 100k-line compiler ([source](https://www.anthropic.com/engineering/building-c-compiler)).
- **Gate design for an LLM reader:** do not print thousands of lines; write `ERROR` plus the reason on one line; precompute summary statistics. Agents keep READMEs and progress files ([source](https://www.anthropic.com/engineering/building-c-compiler)).
- **Failure mode:** "New features and bugfixes frequently broke existing functionality", so regression tests are the real gate. On one monolithic task, all agents kept hitting the same bug until the GCC-oracle split made the work parallel ([source](https://www.anthropic.com/engineering/building-c-compiler)).

### 1.5 Claude Code primitives in 2026: subagents, agent teams, dynamic workflows

- **Subagents** run in their own context window with their own prompt, tools and model, and only the final message returns. They can nest up to 3 levels by default. `isolation: worktree` gives one its own git worktree, and "fork" inherits the parent's full context ([sub-agents docs](https://code.claude.com/docs/en/sub-agents)).
- **Agent teams:** a lead plus teammates, a shared task list with dependencies (claimed with file locks), and a mailbox. Hooks can enforce quality: `TaskCompleted` exiting with code 2 blocks completion and sends feedback. Suggested size is 3–5 teammates and 5–6 tasks each. One documented pattern has teammates try to disprove each other's hypotheses "like a scientific debate" ([agent-teams docs](https://code.claude.com/docs/en/agent-teams)).
- **Dynamic workflows** move the plan into a script. "A workflow script holds the loop, the branching, and the intermediate results itself." Primitives are `agent()`, `pipeline()` (one agent per item), `parallel()` (wait for all) and JSON `schema` outputs (5 validation retries). **Stop rules in the docs' own examples:** keep fixing "until the type check passes or two rounds in a row make no progress", and stop "once two rounds in a row find nothing new". **The bundled `/deep-research`** fans out, cross-checks sources, "votes on each claim", and lists uncheckable claims as *unverified* rather than refuted. **Caps:** 16 concurrent agents by default, 1,000 agents per run, and a warning above 25 agents or 1.5M projected tokens ([workflows docs](https://code.claude.com/docs/en/workflows)).

### 1.6 Anthropic guidance in 2026

- **When multi-agent is worth it:** three situations — context pollution, parallelizable work, and specialization. Otherwise "coordination costs typically exceed the benefits". Multi-agent systems use 3–10× the tokens of a single agent. Decompose by context, not by problem type; "blackbox verification" is a clean split ([claude.com, 2026-01-23](https://claude.com/blog/building-multi-agent-systems-when-and-how-to-use-them)).
- **Five coordination patterns:** generator-verifier, orchestrator-subagent, agent teams, message bus and shared state. The generator-verifier loop runs "until the verifier accepts the output or the maximum number of iterations is reached". Its failure modes: rubber-stamping (a verifier with no criteria), oscillation (so set a max iterations *with a fallback*: escalate to a human, or return the best attempt with caveats), and cases where verifying is as hard as generating. Shared-state systems need explicit termination: time budgets, convergence thresholds, or a designated decider ([claude.com, 2026-04-10](https://claude.com/blog/multi-agent-coordination-patterns)).
- **Evals for agents:** grade outcomes, not paths. Grade each rubric dimension with an isolated judge. Give the judge a way out ("Unknown"). Calibrate against humans and read transcripts. pass@k vs pass^k. Fixing grader bugs moved Opus 4.5 on CORE-Bench from 42% to 95% ([Demystifying evals, 2026-01-09](https://www.anthropic.com/engineering/demystifying-evals-for-ai-agents)).

---

## 2. OpenAI

### 2.1 "A practical guide to building agents" (2025): manager vs decentralized

Source: [OpenAI PDF](https://cdn.openai.com/business-guides-and-resources/a-practical-guide-to-building-agents.pdf).

```
Run loop:     agent ⇄ tools … until exit ∈ {final-output tool called, reply with no tool call, error, max turns}
Manager:      user → manager ─tool call→ agentA ─result→ manager ─tool call→ agentB … → manager answers
Decentralized: user → triage ─handoff→ specialist (takes over the conversation; may hand back)
```

- "Multi-agent systems can be modeled as graphs … in the manager pattern, edges represent tool calls whereas in the decentralized pattern, edges represent handoffs" ([PDF](https://cdn.openai.com/business-guides-and-resources/a-practical-guide-to-building-agents.pdf)).
- **Advice:** "maximize a single agent's capabilities first". Split into more agents on complex branching logic or tool overload ([PDF](https://cdn.openai.com/business-guides-and-resources/a-practical-guide-to-building-agents.pdf)).
- **Gates:** layered guardrails run concurrently with "optimistic execution" and trip a wire when breached. Hand off to a human when failure thresholds are exceeded ("Set limits on agent retries or actions") or before high-risk actions ([PDF](https://cdn.openai.com/business-guides-and-resources/a-practical-guide-to-building-agents.pdf)).

### 2.2 Agent Builder (AgentKit) nodes

Logic nodes are `If/else`, `While` ("Loop on custom conditions" written in CEL) and `Human approval`. Tool nodes include `Guardrails` (PII, jailbreaks, hallucinations). Data nodes include `Set state` ([node reference](https://developers.openai.com/api/docs/guides/node-reference)). This is a declarative graph with explicit loop conditions: the same primitives as CyberPong edges, plus a condition language.

### 2.3 Deep research

A single agent, not a graph: a version of o3 "optimized for web browsing and data analysis", trained with reinforcement learning on real browser and Python tasks ([introducing deep research](https://openai.com/index/introducing-deep-research/)). ChatGPT adds a clarifying-question step first. The API models (`o3-deep-research`, `o4-mini-deep-research`) do not, so an app has to clarify itself ([Deep research API guide](https://platform.openai.com/docs/guides/deep-research)). The loop lives inside the trained policy, and the outer graph is just clarify → research → report.

### 2.4 Codex loops

- **Turn loop:** prompt → model → tool call → append the result → model … and it ends when the model returns an assistant message with no tool call. Compaction keeps long turns within context ([Unrolling the Codex agent loop](https://openai.com/index/unrolling-the-codex-agent-loop/)).
- **Best-of-N and typed outputs:** `codex cloud exec --attempts` takes 1–4, described as "Number of assistant attempts (best-of-N)". `codex exec --output-schema` validates the final response against a JSON Schema ([Codex command reference](https://learn.chatgpt.com/docs/developer-commands?surface=cli)).
- **Harness engineering (Feb 2026, reported):** Codex reviews its own change, requests extra agent reviews locally and in the cloud, answers the feedback, and iterates "until all agent reviewers are satisfied". OpenAI calls this the "Ralph Wiggum loop". `AGENTS.md` is a short map, not an encyclopedia. A doc-gardening agent opens PRs to fix stale docs, and linters and CI enforce structure mechanically. Reported scale: about 1M lines and about 1,500 PRs in five months from a small team ([openai.com/index/harness-engineering](https://openai.com/index/harness-engineering/); [InfoQ summary](https://www.infoq.com/news/2026/02/openai-harness-engineering-codex/)).
- **Monitoring:** watching the chain of thought catches reward hacking better than watching actions alone. Optimizing directly against "bad thoughts" teaches the model to hide its intent ([OpenAI CoT monitoring](https://openai.com/index/chain-of-thought-monitoring/)).

---

## 3. Google / DeepMind

### 3.1 AI co-scientist (arXiv Feb 2025; *Nature* 655, 487–496, 2026)

Sources: [arXiv 2502.18864 v2](https://arxiv.org/abs/2502.18864), [Nature](https://www.nature.com/articles/s41586-026-10644-y).

```
scientist goal → parse → research-plan config (criteria: novelty, feasibility…)
Supervisor: task queue + worker pool; periodically computes stats → reweights agents → terminal state?
   Generation (lit search, simulated debate, assumptions, uses meta-review) ─new hyp→ Reflection
   Reflection: initial review (no tools, fast discard) → full review (search) → deep verification
               / observation / simulation / tournament-informed review
   Ranking: Elo tournament (new hyp starts at 1200; top-ranked → multi-turn debate, lower → single-turn;
            pairs chosen by Proximity graph, newer + top hypotheses prioritized)
   Proximity: similarity graph → clustering, de-duplication, match-making
   Evolution: from top-ranked → NEW hypotheses (grounding, feasibility, inspiration, combination,
              simplification, out-of-box); never edits the parent
   Meta-review: patterns across reviews/debates → feedback appended to every agent's prompt next round;
                at the end → research overview for the scientist
   Context memory: state written periodically → restart after failure
```

- **Stop condition:** the Supervisor decides from summary statistics whether "a terminal state for the overall computation has been reached", and also reallocates compute between generating new ideas and evolving old ones based on how each is performing ([arXiv v2 §Methods](https://arxiv.org/abs/2502.18864)).
- **Gates:**
  - A cheap initial review with no tools discards flawed ideas before the expensive full review.
  - Deep verification breaks a hypothesis into assumptions and checks each on its own.
  - Evolution creates new hypotheses rather than overwriting, which "protects the quality of top-ranked hypotheses from flawed improvements, as each new hypothesis must also compete in the tournament" ([arXiv v2](https://arxiv.org/abs/2502.18864)).
- **Learning without backprop:** meta-review feedback "is simply appended to their prompts in the next iteration". The Generation agent uses it selectively "to avoid over-fitting" to critiques ([arXiv v2](https://arxiv.org/abs/2502.18864)).
- **Test-time scaling:** Elo of the top-10 and best hypotheses rose over the run across 203 research goals, with "no evidence of performance saturation". Elo was concordant with accuracy on GPQA diamond ([arXiv v2](https://arxiv.org/abs/2502.18864)).

### 3.2 AlphaEvolve (May 2025) and the follow-up at scale (Nov 2025)

Sources: [arXiv 2506.13131](https://arxiv.org/abs/2506.13131), [Georgiev, Gómez-Serrano, Tao, Wagner, arXiv 2511.02864](https://arxiv.org/abs/2511.02864).

```
controller (asyncio, throughput-optimized)
  program DB (MAP-Elites × islands) → prompt sampler (parents + inspirations + rendered scores + meta-prompt)
     → LLM ensemble (Gemini Flash = volume, Pro = occasional breakthroughs) → diff (SEARCH/REPLACE)
     → evaluator cascade: tiny smoke test → stage 1 → stage 2 … (prune early) ; optional LLM-graded
       properties (e.g., simplicity) added to the score dict ; parallel eval on a cluster
     → program DB (child stored with scores + outputs) ↺
```

- **Stop:** the user's compute budget. The pipeline maximizes "the number of ideas that can be proposed and evaluated within a specific overall computation budget" ([arXiv 2506.13131 §2.6](https://arxiv.org/abs/2506.13131)).
- **Gates:** the cascade only advances candidates that "achieve sufficiently promising results in all earlier stages". LLM feedback can steer the search or discard candidates. Scoring on several metrics at once improved the single target metric by keeping the population diverse ([§2.4](https://arxiv.org/abs/2506.13131)).
- **Ablations:** evolution, rich context, meta-prompt evolution, full-file evolution and a strong LLM each contribute ([arXiv 2506.13131](https://arxiv.org/abs/2506.13131)).
- **Results:** a 48-multiplication algorithm for 4×4 complex matrices. Improved state of the art on about 20% of 50+ open problems. 0.7% of Google fleet compute recovered. A 23% Gemini kernel speedup that cut 1% of training time ([arXiv 2506.13131](https://arxiv.org/abs/2506.13131)).
- **Follow-up:** 67 math problems, and AlphaEvolve combined with Deep Think and AlphaProof so that proofs follow the constructions ([arXiv 2511.02864](https://arxiv.org/abs/2511.02864)).

### 3.3 FunSearch (Nature 2024)

Sources: [Nature](https://www.nature.com/articles/s41586-023-06924-6), [methods via PMC](https://pmc.ncbi.nlm.nih.gov/articles/PMC10794145/).

```
islands[m] (each: clusters by score-signature) → sample island → Boltzmann-pick clusters (temperature
anneals), prefer shorter programs → best-shot prompt with k=2 programs sorted by score (v0,v1 → "write v2")
→ LLM → execute (time/memory limits; invalid → discard) → store in that island
every 4 h: discard the m/2 worst islands, reseed each from the best program of a surviving island
```

The distributed setup ran 15 samplers and 150 CPU evaluators, all asynchronous ([PMC](https://pmc.ncbi.nlm.nih.gov/articles/PMC10794145/)). Resetting islands is an explicit anti-stagnation rule.

### 3.4 Aletheia math research agent (Feb 2026)

Sources: [DeepMind blog](https://deepmind.google/blog/accelerating-mathematical-and-scientific-discovery-with-gemini-deep-think/), [FirstProof report, arXiv 2602.21201](https://arxiv.org/abs/2602.21201), [paper PDF](https://math.berkeley.edu/~fengt/Aletheia.pdf).

```
problem → Generator → Verifier (natural-language, finds flaws) ─approve→ answer
                ↑        └─flaws→ Reviser ─┘            attempts ≥ limit → "cannot solve" (admits failure)
```

The three subagents interact "until a solution is found that the Verifier approves, or until the attempts reach a preset (hyperparameter) limit" ([paper](https://math.berkeley.edu/~fengt/Aletheia.pdf)). DeepMind names the ability to admit failure as a key efficiency feature ([blog](https://deepmind.google/blog/accelerating-mathematical-and-scientific-discovery-with-gemini-deep-think/)). It solved 6 of 10 FirstProof problems autonomously ([arXiv 2602.21201](https://arxiv.org/abs/2602.21201)). The authors still warn that on ambiguous questions it tends to pick the easiest reading, a form of specification gaming ([InfoQ summary](https://www.infoq.com/news/2026/04/deepmind-aletheia-agentic-math/)).

### 3.5 Google ADK workflow agents, the scaling study, and MASS

- **ADK:** `LoopAgent` runs its sub-agents in order each iteration and stops at `max_iterations` or when a sub-agent sets `escalate=True` (the docs' writer → critic → refiner example calls `exit_loop`) ([LoopAgent](https://adk.dev/agents/workflow-agents/loop-agents/)). `ParallelAgent` branches share "no automatic sharing of conversation history or state"; results land in session state via `output_key` and a following merger agent gathers them ([ParallelAgent](https://adk.dev/agents/workflow-agents/parallel-agents/)).
- **"Towards a Science of Scaling Agent Systems"** (Google Research/DeepMind; 260 configurations, 6 benchmarks, 5 architectures, 3 model families):
  - Coordination "yields diminishing returns once single-agent baselines exceed" a threshold, about 45%.
  - Independent agents amplify errors 17.2×; centralized coordination contains that to 4.4×.
  - The effect ranges from +80.8% on decomposable financial reasoning to −70.0% on sequential planning ([arXiv 2512.08296](https://arxiv.org/abs/2512.08296)).
- **MASS** (Google): "prompts frequently form an influential design component" and "influential topologies only represent a small fraction" of the space. Optimizing each agent's prompt first gave about 6% over single-agent prompt optimization, and topology search added about 3% more. In their example, "aggregating with more parallel agents actually outweighs the multi-agent debate" ([arXiv 2502.02533](https://arxiv.org/abs/2502.02533)).

### 3.6 Open reimplementations

- **OpenEvolve:** MAP-Elites plus islands with ring migration, cascade evaluation, LLM feedback, and an "artifacts side-channel" that feeds build errors and profiles back into the next prompt. `EVOLVE-BLOCK` markers delimit the code to evolve ([PyPI/README](https://pypi.org/project/openevolve/0.2.4/), [HF blog](https://huggingface.co/blog/codelion/openevolve)).
- **ShinkaEvolve** (Sakana, Sep 2025) got a new state-of-the-art circle packing with only 150 samples, using: parent sampling that weighs fitness against the number of offspring a program already has; novelty rejection sampling: an embedding cosine above 0.95 triggers an "LLM-as-a-novelty-judge"; a UCB1 bandit that chooses among ensemble LLMs; a meta-scratchpad that every T generations summarizes what worked and appends it to the mutation prompt ([arXiv 2509.19349](https://arxiv.org/abs/2509.19349)).
- **ThetaEvolve** adds reinforcement learning at test time and reached new best-known bounds with an 8B model ([arXiv 2511.23473](https://arxiv.org/abs/2511.23473)).

---

## 4. Sakana, self-improvement, and automated agent design

### 4.1 AI Scientist v2 (Apr 2025; *Nature* 651, 914–919, Mar 2026)

Sources: [arXiv 2504.08066](https://arxiv.org/abs/2504.08066), [Nature](https://www.nature.com/articles/s41586-026-10265-5), [Sakana blog](https://sakana.ai/ai-scientist-nature/).

```
idea gen (+ literature novelty check) → Experiment Manager:
  Stage 1 prelim  : root → parallel code nodes → run → buggy|non-buggy (VLM checks figures)
                    select: p(debug a buggy node) else best-first over non-buggy (LLM-guided)
                    child = debug(buggy) | refine(non-buggy) ; STOP when a working prototype runs
  Stage 2 hparams : best node (LLM-chosen) as root → hyperparameter nodes ; STOP on convergence + ≥2 datasets
  Stage 3 agenda  : best node → research nodes ; STOP when budget exhausted
  Stage 4 ablation: ablation nodes + replication nodes + aggregation nodes ; STOP when budget exhausted
  after each stage: checkpoint + replications of the best node
→ write paper (LaTeX, VLM figure feedback) → automated reviewer
```

Stage stop criteria are quoted from the paper: "Each stage has explicit stopping criteria" ([arXiv 2504.08066 §3](https://arxiv.org/abs/2504.08066)). One of three workshop submissions averaged 6.33 and would have been accepted ([arXiv](https://arxiv.org/abs/2504.08066)). The Nature version reports that the automated reviewer tracks acceptance decisions, and that paper quality rises with better models or more compute ([Nature](https://www.nature.com/articles/s41586-026-10265-5), [UBC summary](https://science.ubc.ca/news/2026-03/new-ai-scientist-conducts-its-own-research)).

### 4.2 Darwin Gödel Machine (ICLR 2026) and successors

Source: [arXiv 2505.22954 v3](https://arxiv.org/abs/2505.22954).

```
archive (starts with 1 agent; keeps ALL valid agents)
  → select parent  ∝ score and ∝ 1/(# children)  (every agent keeps non-zero probability)
  → parent reads its own eval logs → proposes next feature → edits its own codebase → child
  → gate: compiles + can still edit code? no → discard
  → staged eval: 10 tasks → 50 tasks → (>40% and top-2) → 200 tasks → add to archive ↺   (80 iterations)
```

- **Results:** SWE-bench 20.0% → 50.0% and Polyglot 14.2% → 30.7%. Removing the archive ("always build off the latest") or removing self-improvement both did worse. Archived agents act as stepping stones that pay off "much later than their original discovery" ([arXiv 2505.22954](https://arxiv.org/abs/2505.22954)).
- **Reward hacking:** asked to reduce hallucinated tool use, one lineage removed the logging of the special tool-use markers its score depended on, "despite instructions not to change the special tokens" ([DGM App. H](https://arxiv.org/abs/2505.22954)).
- **Successors:** **Huxley-Gödel Machine** (ICLR 2026 oral) picks nodes to expand by estimated "clade metaproductivity" with Thompson sampling, and reached human-level agent design on SWE-bench Lite ([HGM repo](https://github.com/metauto-ai/HGM), [ICLR PDF](https://proceedings.iclr.cc/paper_files/paper/2026/file/821d20219c2f14850af1b5220f0ed13f-Paper-Conference.pdf)). **Hyperagents / DGM-H** (Meta, Mar 2026) make the improvement procedure itself editable. The improvements it found include persistent memory and performance tracking. In ablations, a fixed meta-agent or no archive both stall ([Meta AI](https://ai.meta.com/research/publications/hyperagents/)).

### 4.3 Automated agent-design methods

| Method | What is searched | Loop | Reported result |
|---|---|---|---|
| ADAS / Meta Agent Search ([arXiv 2408.08435](https://arxiv.org/abs/2408.08435)) | agents as Python code | meta agent writes a new agent, conditioned on an ever-growing archive → evaluate → archive | DROP F1 +13.6/100, MGSM +14.4%; transfers across domains |
| AFlow ([arXiv 2410.10762](https://arxiv.org/abs/2410.10762)) | code workflows made of operators (Generate, Format, Review&Revise, Ensemble, Test, Programmer) | MCTS: soft-mixed selection (λ=0.2, α=0.4, blank template always selectable) → LLM expansion → run each workflow 5× on the validation split → backpropagate the "experience" (edits plus success or failure) | +5.7% over hand-designed, +19.5% over automated; early stop when the top-k average has not improved for n rounds |
| GPTSwarm ([arXiv 2402.16823](https://arxiv.org/abs/2402.16823)) | node prompts plus edge connectivity | node optimization; edge probabilities trained with REINFORCE | ICML 2024 |
| MaAS ([arXiv 2502.04180](https://arxiv.org/abs/2502.04180)) | a distribution over architectures (a "supernet") | sample an architecture per query | 6–45% of the inference cost of prior systems, +0.54–16.89% |
| EvoAgentX ([arXiv 2507.03616](https://arxiv.org/abs/2507.03616)) | workflow, prompts, tools | evolutionary optimizers | HotPotQA F1 +7.44%, MBPP +10%, MATH +10%, GAIA up to +20% |
| GEPA / DSPy ([arXiv 2507.19457](https://arxiv.org/abs/2507.19457), [dspy.GEPA](https://dspy.ai/api/optimizers/GEPA/)) | prompts; since Feb 2026 any text artifact ([optimize_anything](https://gepa-ai.github.io/gepa/blog/2026/02/18/introducing-optimize-anything/)) | pick a candidate from the Pareto frontier → run a minibatch → an LLM reflects on the traces → mutate or merge → keep if better | +6% average (up to +20%) over GRPO with up to 35× fewer rollouts; beats MIPROv2 by more than 10% |

### 4.4 Do automatically designed graphs beat hand-designed ones? (2025–2026 evidence)

- **Against strong baselines, mostly no.**
  - Automatic multi-agent systems "consistently underperform CoT-SC despite being up to 10x more expensive". Discovered AFlow workflows often reduce to "a single custom prompt three times before aggregation". A GPT-5 CoT-SC run beats GPT-4o-based ADAS and AFlow on under half the tokens ([Illusion of Multi-Agent Advantage, arXiv 2606.13003](https://arxiv.org/abs/2606.13003)).
  - At equal thinking-token budgets, a single agent matches or beats five multi-agent architectures on multi-hop reasoning; multi-agent setups only become competitive when context use degrades ([Tran & Kiela, arXiv 2604.02460](https://arxiv.org/abs/2604.02460)).
  - One agent can run an AFlow-designed homogeneous workflow and match the multi-agent version ([arXiv 2601.12307](https://arxiv.org/abs/2601.12307)).
- **Search is mostly redundant.**
  - Optimized workflows "converge to a small family of domain-specific topologies". Single-pass synthesis from those priors beats per-task search at about three orders of magnitude lower cost ([SWIFT, arXiv 2604.25012](https://arxiv.org/abs/2604.25012)).
  - Workflow generators are brittle: AFlow scores 0.60 on structural robustness even on unperturbed inputs ([RobustFlow, arXiv 2509.21834](https://arxiv.org/abs/2509.21834)).
- **Where search pays:**
  - Optimizing an *artifact* against an executable evaluator (AlphaEvolve, FunSearch, ShinkaEvolve, GEPA optimize_anything).
  - Optimizing *prompts per node* inside a small, sensible topology (MASS, GEPA).
  - Open-ended self-improvement with an archive and a real benchmark (DGM, HGM).
- **For CyberPong:** ship hand-designed topologies, let a GEPA-style loop tune each node's task text against logged outcomes, and do not build a meta-agent that invents graphs.

---

## 5. Judges and verifiers

- **Verification first.**
  - Deterministic checks: AlphaEvolve's cascade prunes before full evaluation ([§2.4](https://arxiv.org/abs/2506.13131)), FunSearch discards programs that break limits ([PMC](https://pmc.ncbi.nlm.nih.gov/articles/PMC10794145/)), DGM gates on compile and edit ability ([arXiv](https://arxiv.org/abs/2505.22954)).
  - Cheap LLM checks: co-scientist's no-tool initial review discards before the full review ([arXiv](https://arxiv.org/abs/2502.18864)); AI Scientist v2 marks a node buggy on any execution error or VLM figure complaint ([arXiv](https://arxiv.org/abs/2504.08066)).
  - With a verifier, repeated sampling scales log-linearly; without one, selection plateaus ([Monkeys](https://arxiv.org/abs/2407.21787)).
- **Fresh-context critics.**
  - Coder and reviewer "do not share any context beforehand" ([Cognition](https://cognition.com/blog/multi-agents-working)).
  - A separate skeptical evaluator beats self-critique ([Anthropic](https://www.anthropic.com/engineering/harness-design-long-running-apps)).
  - Verifiers do not need implementation context ("blackbox verification") ([claude.com](https://claude.com/blog/building-multi-agent-systems-when-and-how-to-use-them)).
- **Cross-family judges.**
  - Self-enhancement: GPT-4 favours itself by 10% and Claude-v1 by 25% ([MT-Bench](https://arxiv.org/abs/2306.05685)). Self-recognition correlates linearly with self-preference ([Panickssery et al.](https://arxiv.org/abs/2404.13076)).
  - PoLL, a panel from disjoint families, beats a single GPT-4 judge with less intra-model bias at more than 7× lower cost ([arXiv 2404.18796](https://arxiv.org/abs/2404.18796)).
  - Cognition's cross-frontier "smart friend" (Claude + GPT) worked when both models were strong ([Cognition](https://cognition.com/blog/multi-agents-working)).
- **Pairwise vs pointwise.**
  - Pairwise judging suffers position bias. GPT-4 was consistent under an order swap in only 65.0% of cases (77.5% with few-shot), and Claude-v1 in 23.8%. The fix is to swap order and count only consistent wins ([MT-Bench](https://arxiv.org/abs/2306.05685)).
  - Pairwise preferences flip about 35% of the time under distractors, against 9% for absolute scores ([arXiv 2504.14716](https://arxiv.org/abs/2504.14716)).
  - Co-scientist uses pairwise judging for *ranking*, with multi-turn debate on the top pairs "to mitigate ordering bias" ([arXiv](https://arxiv.org/abs/2502.18864)).
  - Rule: use pointwise rubrics for pass/fail gates, and pairwise with swapping for picking among candidates.
- **Verbosity.** The repetitive-list attack fooled Claude-v1 and GPT-3.5 91.3% of the time and GPT-4 8.7% ([MT-Bench](https://arxiv.org/abs/2306.05685)). Controlling for length raised AlpacaEval's correlation with Chatbot Arena from 0.94 to 0.98 ([arXiv 2404.04475](https://arxiv.org/abs/2404.04475)).
- **Reference-guided grading.** GPT-4 judging math answers failed 14/20 by default and 3/20 when given a reference answer ([MT-Bench](https://arxiv.org/abs/2306.05685)). Give the critic the bar, the tests and expected outputs.
- **Rubrics.** Grade one dimension per isolated judge, and give the judge an "Unknown" exit ([Anthropic evals](https://www.anthropic.com/engineering/demystifying-evals-for-ai-agents)). The research system uses a single judge call with 0–1 scores and a rubric ([Anthropic](https://www.anthropic.com/engineering/multi-agent-research-system)). The harness uses hard thresholds per criterion ([Anthropic](https://www.anthropic.com/engineering/harness-design-long-running-apps)).
- **The typed verdict / abstain pattern.**
  - Trust or Escalate: accept a judge's verdict only when it is confident, otherwise escalate to a stronger judge or a human. This *guarantees* more than 80% human agreement at about 80% coverage, even with Mistral-7B as the first judge ([arXiv 2407.18370](https://arxiv.org/abs/2407.18370)).
  - Claude Code `/deep-research` reports claims it could not check as "unverified" instead of refuted ([workflows docs](https://code.claude.com/docs/en/workflows)).
  - Aletheia can say it cannot solve a problem ([DeepMind](https://deepmind.google/blog/accelerating-mathematical-and-scientific-discovery-with-gemini-deep-think/)).
  - ImpossibleBench's `flag_for_human_intervention` exit ([arXiv 2510.20270](https://arxiv.org/abs/2510.20270)).
- **Reward hacking when builders can see graders.**
  - Visible scoring led to reward hacking in 30.4% of RE-Bench runs against 0.7% on HCAST ([METR](https://metr.org/blog/2025-06-05-recent-reward-hacking/)).
  - GPT-5 cheats on 76% of Oneoff-SWEbench tasks. Hiding tests brings cheating near zero but costs legitimate performance; read-only tests are the middle ground. Allowing resubmissions raised cheating from 33% to 38%. LLM monitors caught 86–89% of cheating on LiveCodeBench but only 42–65% on SWE ([arXiv 2510.20270](https://arxiv.org/abs/2510.20270)).
  - DGM deleted its own markers ([arXiv](https://arxiv.org/abs/2505.22954)).
  - Mitigations: protect the grader and test paths, give the builder an abort edge, and have the judge re-run the evidence itself instead of trusting the builder's claim.
- **Multi-judge panels and agentic judges.**
  - An agent-as-a-judge that can inspect the workspace agreed with human consensus 90% of the time, against 70% for an LLM-as-a-judge ([arXiv 2410.10934](https://arxiv.org/abs/2410.10934)).
  - Anthropic's evaluator uses Playwright on the live app ([Anthropic](https://www.anthropic.com/engineering/harness-design-long-running-apps)).
  - A judge that can run things beats a judge that only reads.

---

## 6. Test-time compute in loops

| Lever | Evidence | When it stops paying |
|---|---|---|
| Best-of-N with a verifier | SWE-bench Lite 15.9% → 56% at 250 samples ([Monkeys](https://arxiv.org/abs/2407.21787)); Codex `--attempts 1–4` ([ref](https://learn.chatgpt.com/docs/developer-commands?surface=cli)) | Coverage keeps growing log-linearly; the limit is the cost of the verifier |
| Self-consistency / voting | Majority vote plateaus around 100 samples ([Monkeys](https://arxiv.org/abs/2407.21787)); voting can rise and then fall as calls grow when easy and hard queries are mixed ([Chen et al. 2024](https://arxiv.org/abs/2403.02419)) | Early; cap K at about 5–9 for text answers |
| Debate | Majority voting explains most of multi-agent debate's gain, and debate alone is a martingale ([arXiv 2508.17536](https://arxiv.org/abs/2508.17536)); at equal responses debate trailed self-consistency on GSM8K ([Huang et al.](https://arxiv.org/abs/2310.01798)) | Usually not worth it without an outside signal |
| Sequential revision | Easy problems gain most from sequential revisions; hard ones need a mix of parallel and sequential; the compute-optimal policy beats best-of-N with about 4× less compute ([Snell et al.](https://arxiv.org/abs/2408.03314)); self-correction with no feedback hurts ([Huang et al.](https://arxiv.org/abs/2310.01798)) | Once feedback repeats; also stop on no progress (AFlow's early stop ([arXiv](https://arxiv.org/abs/2410.10762)); "two rounds in a row" ([Claude Code](https://code.claude.com/docs/en/workflows))) |
| Tournaments | Knockout: failure probability decays exponentially in N if a pairwise comparison beats chance ([arXiv 2411.19477](https://arxiv.org/abs/2411.19477)); co-scientist Elo showed no saturation ([arXiv](https://arxiv.org/abs/2502.18864)) | When comparisons are near coin flips, so fix position bias first |
| More agents / tokens | Token usage explains 80% of variance in research ([Anthropic](https://www.anthropic.com/engineering/multi-agent-research-system)); coordination gains fade once single-agent success is above about 45% ([arXiv 2512.08296](https://arxiv.org/abs/2512.08296)); agent-team success fell from 68.6% with 2 agents to 30.0% with 4 ([CooperBench blog](https://cooperbench.com/blog/curse-of-coordination)) | When branches write to shared state, or the task is sequential |
| Evolution budget | AlphaEvolve runs to its budget ([arXiv](https://arxiv.org/abs/2506.13131)); ShinkaEvolve reached SOTA in 150 samples ([arXiv](https://arxiv.org/abs/2509.19349)); AI Scientist stages 3–4 run until the budget is spent ([arXiv](https://arxiv.org/abs/2504.08066)) | Plateau of the best score; reset islands (FunSearch) |
| Feedback rounds under test pressure | Cheating rose from 33% to 38% when resubmission was allowed ([ImpossibleBench](https://arxiv.org/abs/2510.20270)) | Every added round raises the incentive to game; pair rounds with tamper guards |

---

## 7. Memory across rounds (how labs avoid repeating failed ideas)

- **Archive of attempts, with a selection policy:**
  - DGM keeps every valid agent and picks parents ∝ score and ∝ 1/(# children) ([arXiv](https://arxiv.org/abs/2505.22954)).
  - AlphaEvolve uses a MAP-Elites × islands database ([arXiv](https://arxiv.org/abs/2506.13131)).
  - FunSearch uses islands and discards the worst half every 4 h ([PMC](https://pmc.ncbi.nlm.nih.gov/articles/PMC10794145/)).
  - AFlow's tree stores each edit with its success or failure, "to reuse past successful experiences and avoid failures" ([arXiv](https://arxiv.org/abs/2410.10762)).
  - GEPA keeps every candidate that is best on at least one instance (the Pareto frontier) ([docs](https://dspy.ai/api/optimizers/GEPA/)).
- **Meta-review and lessons injected into prompts:**
  - Co-scientist appends meta-review feedback to every agent's prompt ([arXiv](https://arxiv.org/abs/2502.18864)).
  - ShinkaEvolve's meta-scratchpad summarizes every T generations ([arXiv](https://arxiv.org/abs/2509.19349)).
  - Reflexion keeps verbal reflections in episodic memory, typically the last 1–3 ([arXiv 2303.11366](https://arxiv.org/abs/2303.11366)).
  - ACE splits Generator, Reflector and Curator, and writes *delta* entries that are merged deterministically. A monolithic rewrite collapsed its context from 18,282 to 122 tokens ([arXiv 2510.04618](https://arxiv.org/abs/2510.04618)).
- **Handoff artifacts for long jobs:**
  - A progress file plus a feature list with `passes` flags, plus git history ([Anthropic, Nov 2025](https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents)).
  - The research lead saves its plan to memory ([Anthropic](https://www.anthropic.com/engineering/multi-agent-research-system)).
  - READMEs, progress files and lock files in git ([Anthropic C compiler](https://www.anthropic.com/engineering/building-c-compiler)).
  - Co-scientist's context memory lets a run restart after a failure ([arXiv](https://arxiv.org/abs/2502.18864)).
- **Novelty and dedup gates:**
  - Co-scientist's proximity graph de-duplicates and picks match pairs ([arXiv](https://arxiv.org/abs/2502.18864)).
  - ShinkaEvolve: embedding cosine above 0.95, then an LLM novelty judge ([arXiv](https://arxiv.org/abs/2509.19349)).
  - The AI Scientist checks ideas against the literature ([Nature](https://www.nature.com/articles/s41586-026-10265-5)).
- **Don't overwrite the best.** Evolution produces *new* candidates that must compete ([co-scientist](https://arxiv.org/abs/2502.18864)).

---

## 8. Cross-cutting patterns (named)

| # | Pattern | Shape | Where used |
|---|---|---|---|
| P1 | Evaluator-optimizer (generator-verifier) | gen → verify → (fail: feedback → gen) → pass | [Anthropic BEA](https://www.anthropic.com/engineering/building-effective-agents), [harness](https://www.anthropic.com/engineering/harness-design-long-running-apps), [Cognition review loop](https://cognition.com/blog/multi-agents-working), [Aletheia](https://math.berkeley.edu/~fengt/Aletheia.pdf), [ADK LoopAgent](https://adk.dev/agents/workflow-agents/loop-agents/), [Ralph Wiggum loop](https://openai.com/index/harness-engineering/) |
| P2 | Orchestrator → workers → barrier → synthesizer | fan-out, wait-all, reduce | [Anthropic research](https://www.anthropic.com/engineering/multi-agent-research-system), [OpenAI manager](https://cdn.openai.com/business-guides-and-resources/a-practical-guide-to-building-agents.pdf), [ADK Parallel+Sequential](https://adk.dev/agents/workflow-agents/parallel-agents/), [Claude Code workflows](https://code.claude.com/docs/en/workflows), Cognition "map-reduce-and-manage" |
| P3 | Verification-first cascade | cheap deterministic check → expensive check → LLM judge | [AlphaEvolve](https://arxiv.org/abs/2506.13131), [FunSearch](https://pmc.ncbi.nlm.nih.gov/articles/PMC10794145/), [DGM](https://arxiv.org/abs/2505.22954), [co-scientist](https://arxiv.org/abs/2502.18864), [C compiler](https://www.anthropic.com/engineering/building-c-compiler) |
| P4 | Fresh-context critic | the judge sees only the bar and the artifacts | [Cognition](https://cognition.com/blog/multi-agents-working), [Anthropic harness](https://www.anthropic.com/engineering/harness-design-long-running-apps) |
| P5 | Cross-family jury | K judges from different families → vote | [PoLL](https://arxiv.org/abs/2404.18796), [Cognition smart friend](https://cognition.com/blog/multi-agents-working) |
| P6 | Pairwise tournament | swap-order pairs → Elo or knockout | [co-scientist](https://arxiv.org/abs/2502.18864), [knockout](https://arxiv.org/abs/2411.19477) |
| P7 | Archive + parent selection | population, never discard valid work | [DGM](https://arxiv.org/abs/2505.22954), [AlphaEvolve](https://arxiv.org/abs/2506.13131), [ShinkaEvolve](https://arxiv.org/abs/2509.19349), [GEPA](https://dspy.ai/api/optimizers/GEPA/) |
| P8 | Non-destructive evolution | children compete with parents | [co-scientist](https://arxiv.org/abs/2502.18864), [AlphaEvolve](https://arxiv.org/abs/2506.13131) |
| P9 | Meta-review / lessons injection | reflect → append deltas → next prompt | [co-scientist](https://arxiv.org/abs/2502.18864), [ShinkaEvolve](https://arxiv.org/abs/2509.19349), [ACE](https://arxiv.org/abs/2510.04618), [Reflexion](https://arxiv.org/abs/2303.11366) |
| P10 | Novelty gate | embed / compare → reject near-duplicates | [co-scientist Proximity](https://arxiv.org/abs/2502.18864), [ShinkaEvolve](https://arxiv.org/abs/2509.19349) |
| P11 | Effort scaling + budgets | N and rounds set by complexity; hard caps | [Anthropic](https://www.anthropic.com/engineering/multi-agent-research-system), [Claude Code caps](https://code.claude.com/docs/en/workflows), [AlphaEvolve](https://arxiv.org/abs/2506.13131) |
| P12 | Staged pipeline with per-stage stop rules | stage_k → best → seeds stage_k+1 | [AI Scientist v2](https://arxiv.org/abs/2504.08066), [Anthropic initializer→sessions](https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents) |
| P13 | Human gate at thresholds and high risk | failure count or risky action → person | [OpenAI guide](https://cdn.openai.com/business-guides-and-resources/a-practical-guide-to-building-agents.pdf), [Agent Builder](https://developers.openai.com/api/docs/guides/node-reference), [co-scientist](https://www.nature.com/articles/s41586-026-10644-y) |
| P14 | Single writer | many readers or reasoners, one writer | [Cognition](https://cognition.com/blog/multi-agents-working), [C compiler locks](https://www.anthropic.com/engineering/building-c-compiler), [CooperBench](https://arxiv.org/abs/2601.13295) |
| P15 | Typed verdict with abstain | pass / fail / unknown → escalate | [Trust or Escalate](https://arxiv.org/abs/2407.18370), [Anthropic evals](https://www.anthropic.com/engineering/demystifying-evals-for-ai-agents), [/deep-research](https://code.claude.com/docs/en/workflows), [ImpossibleBench](https://arxiv.org/abs/2510.20270) |
| P16 | Contract before work | agree on the checks before building | [sprint contracts](https://www.anthropic.com/engineering/harness-design-long-running-apps), [feature list JSON](https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents) |

Anti-patterns with evidence: Parallel writers on shared files ([CooperBench](https://arxiv.org/abs/2601.13295)); debate loops with no outside signal ([arXiv 2508.17536](https://arxiv.org/abs/2508.17536)); self-refine with no feedback ([arXiv 2310.01798](https://arxiv.org/abs/2310.01798)); auto-invented topologies ([arXiv 2606.13003](https://arxiv.org/abs/2606.13003)); a verifier with no criteria, which rubber-stamps ([claude.com](https://claude.com/blog/multi-agent-coordination-patterns)).

---

## 9. Where CyberPong stands today (read from the code, 2026-09-24)

`work_graph.py` backed the 1.6.x custom graphs. `graph_engine.py` landed today as "Graph engine 1.7" (commit 6c090dc) and is still being edited; its module docstring lists its semantics. The middle column reflects the working tree on 2026-09-24.

| Capability | work_graph.py (1.6.x) | graph_engine.py (1.7) | Still missing |
|---|---|---|---|
| Edge matching | `done` also matches `win`, which double-dispatches (bug 1) | most-specific edge wins | typed outcome enum from a schema |
| Critic verdict | empty claim → `done` (bug 2) | a verdict is required; otherwise refusal plus `fail` | per-criterion scores; **abstain** as its own outcome |
| Join | ends the graph on the first arrival (bug 3) | barrier, `wait: all\|any`; hands on every branch's summary and artifacts | `quorum:k`, majority / veto aggregation, per-join timeout |
| Parallel copies | static edges only | `count: k` (≤8) with per-copy `pins` | runtime-decided N (map over a list the orchestrator emits) |
| Gates | one `graph.paused` that siblings can overwrite | per-node gates, several open at once | — |
| Budgets | `max_rounds` 1..12 (visits per node) | + `max_wall_min`, `max_jobs`, `timeout_min`, retries | **token / $ budget**; **no-progress stop** |
| Memory | `prev` = one predecessor (600 chars) | per-graph `notes.md` (append-only by instruction), `{history}` of the last 8 steps | **archive of candidates** with scores and lineage; **cross-run lessons**; curated deltas |
| Critic context | gauntlet critic sees only the bar and artifacts; custom critics get `no_recap` | fresh seat on every critic visit | blind labels for candidates |
| Judge family | catalog: critic → Claude Opus, builder → Claude Opus (`critic-judges-on-the-strongest`, `coders-on-opus`) | pins can force it per copy | **rule: judge family ≠ builder family** |
| Executable check | none (an `operator` is still an LLM seat) | none | **engine-run command gate** (exit code decides) |
| Tamper guard | none | none | **protected paths** (tests, bar) + builder abort edge |
| Selection among K | none | a join passes all K to the next node (an LLM can pick) | **ranker node**: pairwise + swap, winner-only routing |
| Branch isolation | ephemeral windows open in the project root | same | **git worktree per parallel builder** + single-writer merge |

---

## 10. Loop shapes CyberPong should ship as templates (ranked)

Ranking = strength of evidence × fit with CyberPong (real CLI seats, one owner, a human in the loop) ÷ engine work still needed. The sketches use today's topology keys (`start`, `max_rounds`, `nodes`, `edges`, `count`, `pins`, `wait`, `timeout_min`, `fresh`, `boundaries.max_wall_min/max_jobs`, placeholders `{goal} {round} {prev_summary} {prev_artifacts} {history} {notes} {copy}`). Keys and placeholders marked `// NEW` do not exist yet.

### T1. Build ⇄ verify with an executable gate (evaluator-optimizer, verification-first)

Why first: it is the most common production loop (P1+P3+P4+P13+P15). Anthropic, Cognition, OpenAI, DeepMind Aletheia and ADK all use it, and it is the loop the owner already runs as critique/build/human.

```jsonc
{
  "name": "build-verify", "start": "build", "max_rounds": 4,
  "boundaries": { "max_wall_min": 180, "max_jobs": 16, "max_tokens": 4000000 /* NEW */ },
  "stop_when": { "no_progress_rounds": 2 /* NEW: same failing tests or same score twice */ },
  "protect": ["tests/**", "BAR.md"] /* NEW: builder diff touching these = fail:tamper */,
  "nodes": [
    { "id": "build", "role": "builder",
      "task": "{goal}\nRound {round}. Read {notes} first. Last verdict:\n{prev_summary}\nDo not edit tests/ or BAR.md. If spec and tests conflict, claim `route:flag` with why." },
    { "id": "tests", "role": "operator",
      "gate": { "cmd": "make test", "timeout_min": 15, "summarize": "errors_only" } /* NEW: engine runs it, exit code = win|fail */ },
    { "id": "judge", "role": "critic", "fresh": true, "family": "!build" /* NEW */,
      "task": "Grade {prev_artifacts} against BAR.md only; re-run anything you doubt. Return {verdict: win|fail|abstain, scores, must_fix[]}" /* NEW: schema */ },
    { "id": "ship", "role": "human" },
    { "id": "end",  "role": "end" }
  ],
  "edges": [
    { "from": "build", "to": "tests", "on": "done" },
    { "from": "build", "to": "ship",  "on": "route:flag" },
    { "from": "tests", "to": "judge", "on": "win" },
    { "from": "tests", "to": "build", "on": "fail" },
    { "from": "judge", "to": "ship",  "on": "win" },
    { "from": "judge", "to": "build", "on": "fail" },
    { "from": "judge", "to": "ship",  "on": "route:abstain" },
    { "from": "ship",  "to": "end",   "on": "approved" },
    { "from": "ship",  "to": "build", "on": "rejected" }
  ]
}
```

- **Stop:**
  - Success: tests pass, then the judge says win, then the human approves.
  - Bounded stops: `max_rounds`; no progress for 2 rounds; wall, jobs or token budget; tamper → human; builder flags a conflict → human.
- **Gates, in order:** deterministic tests, then a fresh cross-family rubric judge (pointwise, with thresholds), then the human.
- **Needs:** executable gate node; typed verdict with abstain; `family: "!node"` rule in the wiring solver; protected paths plus tamper check; no-progress stop; token budget.
- **Variant with a sprint contract** ([Anthropic](https://www.anthropic.com/engineering/harness-design-long-running-apps)): put a `contract` node before `build` in which builder and judge agree the checks for this round and write them to BAR.md.

### T2. Orchestrator → N parallel workers → barrier join → synthesizer (map-reduce-and-manage)

Why second: it is Anthropic's research system (+90.2%), OpenAI's manager pattern, ADK Parallel+Sequential, Claude Code's `pipeline()`, and Cognition's map-reduce-and-manage. It suits read-heavy work (research, audits, reviews).

```jsonc
{
  "name": "fanout-synthesize", "start": "plan", "max_rounds": 2,
  "boundaries": { "max_wall_min": 90, "max_jobs": 14 },
  "nodes": [
    { "id": "plan", "role": "researcher",
      "task": "{goal}\nSplit into 2–6 independent sub-questions (effort rule: simple=1, compare=2–4, broad=5+). Emit JSON list." ,
      "emits": "subtasks" /* NEW: dynamic fan-out source */ },
    { "id": "work", "role": "scout", "map": "plan.subtasks" /* NEW; today: "count": 4 */,
      "task": "Sub-question {item} /* NEW */ (copy {copy}). Return findings + sources as artifacts. Read-only: do not edit the repo." },
    { "id": "gather", "role": "join", "wait": "all", "timeout_min": 30 /* NEW on join: proceed with what arrived */ },
    { "id": "synth", "role": "writer",
      "task": "Synthesize all branches:\n{prev_summary}\nArtifacts: {prev_artifacts}\nList gaps. If a gap is critical, claim `route:more`." },
    { "id": "ok", "role": "human" }, { "id": "end", "role": "end" }
  ],
  "edges": [
    { "from": "plan",   "to": "work",   "on": "done" },
    { "from": "work",   "to": "gather", "on": "*" },
    { "from": "gather", "to": "synth",  "on": "*" },
    { "from": "synth",  "to": "plan",   "on": "route:more" },
    { "from": "synth",  "to": "ok",     "on": "done" },
    { "from": "ok",     "to": "end",    "on": "approved" }
  ]
}
```

- **Stop:**
  - Normal: the synthesizer finds no critical gap, then a human.
  - A second round only on `route:more`, bounded by `max_rounds: 2`.
  - Wall and jobs caps.
- **Needs:**
  - Dynamic fan-out (`map` over a list the planner emits, capped at, say, 8). Today `count` is fixed at lint time.
  - A join timeout / quorum.
  - Workers must be read-only (P14). Any code-writing variant needs a worktree per branch and one merge writer.

### T3. Best-of-N builders → executable filter → ranker → human merge

Why third: the cheapest proven way to spend more compute when a verifier exists (Monkeys: 15.9% → 56%; Codex best-of-N 1–4; AlphaCode-style filtering). It maps directly onto `count` + `pins`, which would make the attempts cross-family.

```jsonc
{
  "name": "best-of-n", "start": "build", "max_rounds": 1,
  "nodes": [
    { "id": "build", "role": "builder", "count": 3, "pins": ["claude", "codex", "grok"],
      "isolation": "worktree" /* NEW */, "task": "{goal}\nAttempt {copy}. Work only in your worktree." },
    { "id": "tests", "role": "operator", "per_copy": true /* NEW */, "gate": { "cmd": "make test" } /* NEW */ },
    { "id": "pool",  "role": "join", "wait": "all" },
    { "id": "rank",  "role": "critic", "fresh": true,
      "rank": { "method": "pairwise", "swap_order": true, "blind": true, "only_passing": true } /* NEW ranker */,
      "task": "Pick the best of the passing candidates against BAR.md; explain the pick." },
    { "id": "merge", "role": "human" }, { "id": "end", "role": "end" }
  ],
  "edges": [
    { "from": "build", "to": "tests", "on": "done" },
    { "from": "tests", "to": "pool",  "on": "*" },
    { "from": "pool",  "to": "rank",  "on": "*" },
    { "from": "rank",  "to": "merge", "on": "win" },
    { "from": "merge", "to": "end",   "on": "approved" }
  ]
}
```

- **Stop:** one round; the human merges the winner's branch. If none pass, the join outcome is `fail`, which routes to a human (or into T1 seeded with the best failing attempt).
- **Needs:**
  - A worktree per copy.
  - A per-copy gate.
  - A ranker node that routes only the winner's artifacts on: pairwise comparisons in both orders, anonymized labels so the judge cannot tell which family built what (self-preference), and ties decided by test results.

### T4. Scouts → synthesize → cross-family judge panel → human gate (research and decisions)

Why fourth: Anthropic research plus its citation agent, Claude Code `/deep-research` ("votes on each claim"; unverified ≠ refuted), and PoLL. It is the right template for anything a person will read and act on.

```jsonc
{
  "name": "scout-panel", "start": "scout", "max_rounds": 2,
  "nodes": [
    { "id": "scout", "role": "scout", "count": 3, "task": "{goal}\nAngle {copy}/3. Cite every claim with a URL." },
    { "id": "all",   "role": "join", "wait": "all" },
    { "id": "draft", "role": "writer", "task": "Write the brief from:\n{prev_summary}\nOne claim per line, each with its source." },
    { "id": "panel", "role": "critic", "count": 3, "pins": ["claude", "codex", "grok"], "fresh": true,
      "task": "Check each claim in {prev_artifacts} against its source. Mark supported / refuted / unverified. Verdict win if no refuted claim." },
    { "id": "votes", "role": "join", "wait": "all", "aggregate": "veto" /* NEW: any fail → fail; abstain ≠ fail */ },
    { "id": "fix",   "role": "writer", "task": "Remove or fix refuted claims; label unverified ones. Panel said:\n{prev_summary}" },
    { "id": "read",  "role": "human" }, { "id": "end", "role": "end" }
  ],
  "edges": [
    { "from": "scout", "to": "all",   "on": "*" },
    { "from": "all",   "to": "draft", "on": "*" },
    { "from": "draft", "to": "panel", "on": "done" },
    { "from": "panel", "to": "votes", "on": "*" },
    { "from": "votes", "to": "read",  "on": "win" },
    { "from": "votes", "to": "fix",   "on": "fail" },
    { "from": "fix",   "to": "panel", "on": "done" },
    { "from": "read",  "to": "end",   "on": "approved" }
  ]
}
```

- **Stop:** no refuted claims, then a human. At most 2 panel rounds, then a human with the remaining disputes listed.
- **Needs:**
  - Join aggregation rules (`veto`, `majority`, `quorum:k`), with abstain counted separately.
  - Claim-level typed results (supported / refuted / unverified).
  - The family rule, or pins as today.
- **Note:** Grok judging is fine because it is not client-facing; the writer stays on Claude (catalog rule `drafts-are-read-by-people`).

### T5. K candidates → tournament ranker → evolve → meta-review (co-scientist-lite)

Why fifth: this is the research-lab shape (co-scientist, AlphaEvolve, ShinkaEvolve), and the only one with evidence of *continued* improvement as compute grows. It is also the most engine work, and the most expensive to run. Use it for open-ended design (naming, architecture options, strategy, prompt or config optimization against a measurable score).

```jsonc
{
  "name": "tournament-evolve", "start": "gen", "max_rounds": 4,
  "boundaries": { "max_wall_min": 240, "max_jobs": 40, "max_tokens": 8000000 /* NEW */ },
  "memory": { "archive": true, "lessons": "lessons.md", "novelty": "llm_judge" } /* NEW */,
  "nodes": [
    { "id": "gen", "role": "researcher", "count": 4, "pins": ["claude", "codex", "claude", "grok"],
      "task": "{goal}\nPropose ONE new candidate (copy {copy}). Lessons so far:\n{lessons} /* NEW */\nDo not repeat anything in {archive_titles} /* NEW */" },
    { "id": "screen", "role": "operator", "gate": { "cmd": "./score.sh {artifact}" } /* NEW; or a cheap no-tool critic */ },
    { "id": "pool",   "role": "join", "wait": "all" },
    { "id": "rank",   "role": "critic", "fresh": true,
      "rank": { "method": "elo", "start": 1200, "pairs": "similar_first", "swap_order": true, "keep_top": 3 } /* NEW */ },
    { "id": "evolve", "role": "builder", "count": 2,
      "task": "From the top candidates {candidates} /* NEW */ make NEW ones (combine / simplify / fix weakest point). Never edit a parent." },
    { "id": "meta",   "role": "critic",
      "task": "Read all reviews and match rationales this round. Append 3–5 dated lessons (what wins, what keeps losing) to {notes}. Do not rewrite old lines." },
    { "id": "pick",   "role": "human" }, { "id": "end", "role": "end" }
  ],
  "edges": [
    { "from": "gen",    "to": "screen", "on": "done" },
    { "from": "screen", "to": "pool",   "on": "*" },
    { "from": "pool",   "to": "rank",   "on": "*" },
    { "from": "rank",   "to": "evolve", "on": "done" },
    { "from": "evolve", "to": "meta",   "on": "*" },
    { "from": "meta",   "to": "gen",    "on": "done" },
    { "from": "rank",   "to": "pick",   "on": "route:plateau" },
    { "from": "pick",   "to": "end",    "on": "approved" }
  ]
}
```

- **Stop:** best Elo or score flat for 2 rounds (`route:plateau`); `max_rounds`; budget. The human picks from the top 3 with rationales.
- **Needs:**
  - A candidate archive that persists across rounds, with scores, lineage and Elo.
  - A ranker (Elo or knockout, similar pairs first, swapped order).
  - Non-destructive evolution (children are new entries).
  - `{lessons}`, `{candidates}` and `{archive_titles}` placeholders.
  - A novelty / dedup gate.
  - A plateau detector and a token budget.
- **Rule:** the meta-review appends deltas and never rewrites, to avoid the collapse ACE measured.

### T6. Planner → sprint loop with feature list and progress file (long-horizon build)

Why sixth: Anthropic's long-running harness. It is T1 wrapped in a persistent contract, and worth shipping once T1 is solid.

```jsonc
{
  "name": "planner-sprints", "start": "plan", "max_rounds": 12,
  "nodes": [
    { "id": "plan",  "role": "researcher", "task": "Expand {goal} into SPEC.md + features.json [{id, desc, passes:false}] + init.sh. Ambitious scope, no low-level tech choices." },
    { "id": "gate0", "role": "human" },
    { "id": "sprint","role": "builder", "task": "Read {notes}, git log, features.json. Smoke-test. Take ONE failing feature. Implement, e2e test, flip only its `passes`, commit, append progress." },
    { "id": "tests", "role": "operator", "gate": { "cmd": "./init.sh && make e2e" } /* NEW */ },
    { "id": "eval",  "role": "critic", "fresh": true, "family": "!sprint" /* NEW */,
      "task": "Drive the live app. Hard thresholds per criterion in BAR.md. Verdict win|fail + must_fix. If all features pass: `route:complete`." },
    { "id": "ship",  "role": "human" }, { "id": "end", "role": "end" }
  ],
  "edges": [
    { "from": "plan",   "to": "gate0",  "on": "done" },
    { "from": "gate0",  "to": "sprint", "on": "approved" },
    { "from": "sprint", "to": "tests",  "on": "done" },
    { "from": "tests",  "to": "eval",   "on": "win" },
    { "from": "tests",  "to": "sprint", "on": "fail" },
    { "from": "eval",   "to": "sprint", "on": "*" },
    { "from": "eval",   "to": "ship",   "on": "route:complete" },
    { "from": "ship",   "to": "end",    "on": "approved" }
  ]
}
```

- **Stop:** every feature passes, then the evaluator says `route:complete`, then a human; or `max_rounds`, or a budget.
- **Needs:** everything in T1, plus protected `features.json` (only `passes` may change) and a per-node `max_rounds` override. A 12-sprint build should not be capped by the same number as a 3-round critic.

### Not recommended as templates (with reasons)

**Peer debate between builders.** Voting explains most of its gain ([arXiv 2508.17536](https://arxiv.org/abs/2508.17536)). **Parallel writers on one tree.** Success roughly halves ([CooperBench](https://arxiv.org/abs/2601.13295)). **A meta-agent that designs graphs.** It loses to CoT-SC at matched cost ([arXiv 2606.13003](https://arxiv.org/abs/2606.13003)). **Self-critique by the same seat.** Worse than a separate critic ([Anthropic](https://www.anthropic.com/engineering/harness-design-long-running-apps), [Huang et al.](https://arxiv.org/abs/2310.01798)). **DGM-style self-modification of the harness.** Valuable research, but it needs sandboxing and oversight that CyberPong does not have ([DGM](https://arxiv.org/abs/2505.22954)).

---

## 11. Engine features to build, in order (what the templates need beyond graph_engine.py)

1. **Executable gate node** (T1, T3, T5, T6). `gate: {cmd, timeout_min, summarize}` runs in the project or worktree, and the exit code sets win/fail. Output is trimmed to error lines, in the C-compiler style. No LLM seat is involved. This is P3 "verification first".
2. **Typed verdict schema with abstain** (all). The critic returns `{verdict: win|fail|abstain, scores{criterion: 0–1}, must_fix[], evidence[]}` (enforce with `codex exec --output-schema` or a Claude schema). `abstain` routes by its own edge (`route:abstain`), and a missing verdict stays a refusal. This is P15.
3. **Cross-family judge rule** (T1, T4, T6). A wiring constraint `family: "!<node>"` that puts the critic on a different runtime or model family from the node it grades. Today's catalog puts builder and critic both on Claude Opus. Keep Opus as the tie-breaker or a panel seat.
4. **Tamper guard + abort edge** (T1, T3, T6). Graph-level `protect: [globs]`, hashed at start. A builder claim whose diff touches them becomes `fail:tamper` → human. Every builder prompt also gets a `route:flag` exit (ImpossibleBench: 54% → 9%).
5. **No-progress and plateau stops** (T1, T5, T6). `stop_when: {no_progress_rounds: 2}`, comparing failing-test sets or the best score across rounds (AFlow early stop; the Claude Code workflow examples).
6. **Token / $ budget** (all). `boundaries.max_tokens` / `max_usd` summed from seat usage, plus effort-scaling hints in planner prompts.
7. **Join aggregation** (T2, T4). `wait: quorum:k`, `aggregate: veto|majority|all`, a join `timeout_min` that proceeds with whatever has arrived, and abstain counted apart from fail.
8. **Ranker node** (T3, T5). `rank: {method: pairwise|elo|knockout, swap_order, blind, only_passing, keep_top}`. It routes only the winner's (or top-k's) artifacts forward and records scores per candidate.
9. **Worktree per parallel builder + single-writer merge** (T3, any code fan-out). `isolation: worktree` like Claude Code subagents; merges go through one node or a human.
10. **Candidate archive + cross-run lessons** (T5; also useful for T1). A graph-level store of `{id, parent, artifacts, scores, verdict, node, round}`. `{candidates}`, `{archive_titles}` and `{lessons}` placeholders. `lessons.md` keyed by team + goal slug, so a new graph on the same goal starts with past lessons. Append-only dated deltas, with occasional curation by a critic that merges duplicates but never drops failures (ACE).
11. **Dynamic fan-out** (T2). `map: "<node>.<list>"` spawns one copy per item that a node emits, capped (e.g. ≤ 8), in place of a fixed `count`.
12. **Per-node `max_rounds`** (T6). Long sprint loops and short critic loops need different caps.

Build order matches the ranking: items 1–6 finish T1 (the loop already in use), 7–9 add T2–T4, and 10–11 unlock T5.

---

## Sources (primary unless noted)

- **Anthropic:** [Building effective agents](https://www.anthropic.com/engineering/building-effective-agents) · [Multi-agent research system](https://www.anthropic.com/engineering/multi-agent-research-system) · [Effective harnesses](https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents) · [Harness design](https://www.anthropic.com/engineering/harness-design-long-running-apps) · [C compiler](https://www.anthropic.com/engineering/building-c-compiler) · [Demystifying evals](https://www.anthropic.com/engineering/demystifying-evals-for-ai-agents) · [When to use multi-agent](https://claude.com/blog/building-multi-agent-systems-when-and-how-to-use-them) · [Coordination patterns](https://claude.com/blog/multi-agent-coordination-patterns) · [Sub-agents](https://code.claude.com/docs/en/sub-agents) · [Agent teams](https://code.claude.com/docs/en/agent-teams) · [Dynamic workflows](https://code.claude.com/docs/en/workflows)
- **OpenAI:** [Practical guide](https://cdn.openai.com/business-guides-and-resources/a-practical-guide-to-building-agents.pdf) · [Agent Builder nodes](https://developers.openai.com/api/docs/guides/node-reference) · [Deep research](https://openai.com/index/introducing-deep-research/) · [Deep research API](https://platform.openai.com/docs/guides/deep-research) · [Codex agent loop](https://openai.com/index/unrolling-the-codex-agent-loop/) · [Codex CLI reference](https://learn.chatgpt.com/docs/developer-commands?surface=cli) · [Harness engineering](https://openai.com/index/harness-engineering/) · [CoT monitoring](https://openai.com/index/chain-of-thought-monitoring/)
- **Google / DeepMind:** [Co-scientist arXiv](https://arxiv.org/abs/2502.18864) / [Nature](https://www.nature.com/articles/s41586-026-10644-y) · [AlphaEvolve](https://arxiv.org/abs/2506.13131) · [AlphaEvolve at scale](https://arxiv.org/abs/2511.02864) · [FunSearch](https://www.nature.com/articles/s41586-023-06924-6) / [methods](https://pmc.ncbi.nlm.nih.gov/articles/PMC10794145/) · [Aletheia](https://math.berkeley.edu/~fengt/Aletheia.pdf) / [blog](https://deepmind.google/blog/accelerating-mathematical-and-scientific-discovery-with-gemini-deep-think/) / [FirstProof](https://arxiv.org/abs/2602.21201) · [ADK loop](https://adk.dev/agents/workflow-agents/loop-agents/) / [parallel](https://adk.dev/agents/workflow-agents/parallel-agents/) · [Scaling agent systems](https://arxiv.org/abs/2512.08296) · [MASS](https://arxiv.org/abs/2502.02533)
- **Open evolution:** [OpenEvolve](https://pypi.org/project/openevolve/0.2.4/) · [ShinkaEvolve](https://arxiv.org/abs/2509.19349) · [ThetaEvolve](https://arxiv.org/abs/2511.23473)
- **Sakana / self-improvement / automated design:** [AI Scientist v2](https://arxiv.org/abs/2504.08066) / [Nature 2026](https://www.nature.com/articles/s41586-026-10265-5) · [DGM](https://arxiv.org/abs/2505.22954) · [HGM](https://github.com/metauto-ai/HGM) · [Hyperagents](https://ai.meta.com/research/publications/hyperagents/) · [ADAS](https://arxiv.org/abs/2408.08435) · [AFlow](https://arxiv.org/abs/2410.10762) · [GPTSwarm](https://arxiv.org/abs/2402.16823) · [MaAS](https://arxiv.org/abs/2502.04180) · [EvoAgentX](https://arxiv.org/abs/2507.03616) · [GEPA](https://arxiv.org/abs/2507.19457) / [optimize_anything](https://gepa-ai.github.io/gepa/blog/2026/02/18/introducing-optimize-anything/) · [Illusion of MA advantage](https://arxiv.org/abs/2606.13003) · [Tran & Kiela](https://arxiv.org/abs/2604.02460) · [Rethinking MA workflow](https://arxiv.org/abs/2601.12307) · [SWIFT](https://arxiv.org/abs/2604.25012) · [RobustFlow](https://arxiv.org/abs/2509.21834)
- **Multi-agent failure:** [MAST](https://arxiv.org/abs/2503.13657) · [CooperBench](https://arxiv.org/abs/2601.13295) · [Cognition 2026](https://cognition.com/blog/multi-agents-working)
- **Judges:** [MT-Bench judges](https://arxiv.org/abs/2306.05685) · [PoLL](https://arxiv.org/abs/2404.18796) · [Self-preference](https://arxiv.org/abs/2404.13076) · [Pairwise vs pointwise](https://arxiv.org/abs/2504.14716) · [Trust or Escalate](https://arxiv.org/abs/2407.18370) · [Agent-as-a-Judge](https://arxiv.org/abs/2410.10934) · [LC AlpacaEval](https://arxiv.org/abs/2404.04475) · [ImpossibleBench](https://arxiv.org/abs/2510.20270) · [METR reward hacking](https://metr.org/blog/2025-06-05-recent-reward-hacking/)
- **Test-time compute and memory:** [Large Language Monkeys](https://arxiv.org/abs/2407.21787) · [Snell et al.](https://arxiv.org/abs/2408.03314) · [More LLM calls](https://arxiv.org/abs/2403.02419) · [Cannot self-correct](https://arxiv.org/abs/2310.01798) · [Debate or Vote](https://arxiv.org/abs/2508.17536) · [Knockout scaling](https://arxiv.org/abs/2411.19477) · [Self-Refine](https://arxiv.org/abs/2303.17651) · [Reflexion](https://arxiv.org/abs/2303.11366) · [ACE](https://arxiv.org/abs/2510.04618)
