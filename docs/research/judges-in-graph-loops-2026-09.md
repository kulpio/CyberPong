# Judges, verifiers and routers inside graph loops, and where Jev fits (research note, 2026-09-24)

Question: how do labs and agent frameworks put judges, verifiers, graders, reward models and routers *inside* multi-step loops, and what does that mean for a calibrated typed-decision model (Jev, TypeSafe System One) in CyberPong's graph engine?

Method: primary sources (papers, official docs, lab engineering posts), 2024–2026, read on 2026-09-24. Every finding carries a URL, and secondary sources are marked as such. No TypeSafe call was made. Nothing in the repo was changed except this file.

Already covered elsewhere, so not repeated here:
- **Labs note** ([graph-loops-labs-2026-09.md](graph-loops-labs-2026-09.md) §5–6): the loop shapes, AlphaEvolve's evaluator cascade, MT-Bench biases, PoLL, the pairwise-vs-pointwise flip rates, Trust or Escalate, and ImpossibleBench and METR reward hacking.
- **Frameworks note** ([graph-loops-frameworks-2026-09.md](graph-loops-frameworks-2026-09.md)): edge and join semantics.
- **X note** ([x-graph-loops-2026-09-24.md](x-graph-loops-2026-09-24.md) §4): rubric-order bias, the 21-judge reliability study, and the Jev vs LLM-judge position test.
- **An earlier Jev design note**, already settled: acceptance commands before any verdict, a typed Score per rubric line, an "assessable" Noul beside each line, `none` on every Choice, per-question calibration (ECE and kappa targets), and thresholds proportional to cost.

Engine state was read (read-only) from `python/pong/graph_engine.py` (working tree) and `python/pong/jev.py` (untracked, in progress).

---

## Executive summary

1. **Everyone grades per criterion, then combines in code.**
   - OpenAI's `multi` grader combines sub-graders with a formula that allows `min`/`max` ([OpenAI graders](https://developers.openai.com/api/docs/guides/graders)).
   - ADK scores each rubric yes/no and averages them ([ADK criteria](https://adk.dev/evaluate/criteria/)). HealthBench sums signed points ([arXiv 2505.08775](https://arxiv.org/html/2505.08775)).
   - Checklist and unit-test grading beats holistic scores for agreement with humans ([TICK](https://arxiv.org/abs/2410.03608), [LMUnit](https://aclanthology.org/2025.findings-emnlp.176.pdf)).
   - That is Jev's native shape: one Score or Noul per line, with the combining done in engine code.
2. **Gates are conjunctive, and rankings are compensatory.**
   - Anthropic's harness fails a sprint if any criterion is under its threshold (labs note §1.3). Hamel Husain reports a "pass all" rate ([evals FAQ](https://hamel.dev/blog/posts/evals-faq/)).
   - Weighted sums (HealthBench, TypeSafe composite scoring) are for ranking and benchmarking, not for pass/fail ([TypeSafe](https://docs.typesafe.ai/patterns/composite-scoring.md)).
3. **A verifier's false positives cap what resampling can buy.**
   - Past a handful of attempts, extra samples mostly add false passes ([Inference Scaling fLaws](https://arxiv.org/abs/2411.17501)).
   - Best-of-n against a proxy score rises and then falls on the true score ([Gao et al.](https://arxiv.org/abs/2210.10760)).
   - Execution-based and model-based verifiers fail differently, and combining them wins ([R2E-Gym](https://arxiv.org/abs/2504.07164)).
4. **Grade the outcome and treat process signals as hints.**
   - Outcome supervision matches final-answer accuracy but lets flawed reasoning through ([Uesato et al.](https://arxiv.org/abs/2211.14275)).
   - Process reward models (PRMs) are hard to define, hard to label and hackable, and DeepSeek dropped them ([DeepSeek-R1 §4.2](https://arxiv.org/html/2501.12948v1)).
5. **Abstention is a first-class outcome, with thresholds set by costs.**
   - Chow's reject rule ([1970](https://doi.org/10.1109/TIT.1970.1054406)), Elkan's cost threshold ([2001](https://www.ijcai.org/Proceedings/01/Papers/061.pdf)) and OpenAI's "answer only if > t confident" ([Kalai et al.](https://arxiv.org/html/2509.04664)) agree.
   - The action threshold is a cost ratio, and the band between two thresholds goes to a person.
6. **The best-documented production gate is Claude Code auto mode.**
   - It runs a two-stage classifier that sees neither the agent's reasoning nor tool outputs. It escalates after 3 consecutive or 20 total denials.
   - Published errors: 0.4% FPR (n=10,000) and 17% FNR (n=52) ([Anthropic](https://www.anthropic.com/engineering/claude-code-auto-mode)).
   - Humans approve 97% of per-action prompts but reject 39% of plans ([claude.com](https://claude.com/blog/auto-mode-default-in-claude-code)). People belong at plan and merge gates, not at every step.
7. **At low volume, calibration is limited by labels.**
   - Isotonic regression needs about 1,000 labels ([scikit-learn](https://scikit-learn.org/stable/modules/calibration.html)).
   - If only escalated items get labels, estimates are biased ([selective labels](https://www.kdd.org/kdd2017/papers/view/the-selective-labels-problem-evaluating-algorithmic-predictions-in-the-pres)).
   - Showing the model's answer anchors the person ([Buçinca et al.](https://arxiv.org/abs/2102.09692)).
   - A judge can at best halve the human labels needed ([Dorner et al.](https://arxiv.org/abs/2410.13341)).
8. **Judges get fooled by the text they grade.**
   - A single ":" or "Thought process:" fools judges ([One Token to Fool](https://arxiv.org/abs/2507.08794)).
   - Absolute scoring is more attackable than comparison ([Raina et al.](https://arxiv.org/abs/2402.14016)), and detector defences fail ([JudgeDeceiver](https://arxiv.org/abs/2403.17710)).
   - Spotlighting (marking which text is untrusted) cut attacks from above 50% to below 2% ([Hines et al.](https://arxiv.org/abs/2403.14720)).
9. **For CyberPong:**
   - Run Jev after `check` nodes and beside the critic until it has labels.
   - Pass a line on P(level ≥ floor), using two thresholds per line plus a union bound across lines. The outcome is win, fail or escalate.
   - Log the thresholds in force and the person's later decision, and audit a random share of automatic calls. Section 8 has the defaults.

---

## 1. Rubric grading inside loops: how the platforms implement it

- **OpenAI graders** ([guide](https://developers.openai.com/api/docs/guides/graders), [API reference](https://developers.openai.com/api/reference/resources/graders)).
  - `string_check` returns 0/1. `text_similarity` has a `pass_threshold`. `python` defines `grade(sample, item) -> float`.
  - `score_model`: "The output of the grader will be truncated to the given `range`, and default to 0 for all non-numeric outputs."
  - `label_model`: `labels` plus `passing_labels` (which "must be a subset of labels"); the model "must support structured outputs".
  - `multi`: `calculate_output` combines sub-scores with `+ - * / ^` and `min`, `max`, `abs`, `sqrt`, `log`.
  - Guidance: "produce a smooth score, not a pass/fail stamp" when the grade is a training signal, and "guard against reward hacking".
- **OpenAI RFT** ([guide](https://developers.openai.com/api/docs/guides/reinforcement-fine-tuning)).
  - Models "reward hack your grader", so make tasks "guess-proof".
  - Weight properties in the formula (`0.5 * compliant + 0.5 * explanation`). Check that experts agree on the ideal output.
  - "Start small—between several dozen and a few hundred examples."
- **Rubric RL at scale.**
  - HealthBench ([arXiv 2505.08775](https://arxiv.org/html/2505.08775)):
    - Rubric: 48,562 criteria, a median of 11 per conversation, points from −10 to 10. The score is the points met over the maximum possible, clipped to [0,1].
    - Grader check: the GPT-4.1 grader reaches macro-F1 ≈ 0.71 against physicians, while physician-to-physician agreement by theme ranges from 0.569 to 0.730.
  - Rubrics as Rewards: up to 31% relative gain on HealthBench and 7% on GPQA over LLM-judge rewards, with "better alignment for smaller judges" ([arXiv 2507.17746](https://arxiv.org/abs/2507.17746)).
  - RL from checklist feedback is the only method that improved every benchmark: FollowBench +4, InFoBench +6, Arena-Hard +3 ([arXiv 2507.18624](https://arxiv.org/abs/2507.18624)).
- **Checklists raise agreement.**
  - TICK's instruction-specific yes/no checklists raised exact agreement with human preferences from 46.4% to 52.2%, and human inter-annotator agreement from 0.194 to 0.256 ([arXiv 2410.03608](https://arxiv.org/abs/2410.03608)).
  - With natural-language unit tests, human Fleiss' κ went from 0.04 to 0.52, and raters picked the response with the most satisfied tests 89% of the time ([LMUnit](https://aclanthology.org/2025.findings-emnlp.176.pdf)).
- **Anthropic.**
  - The grading preference order is code, then LLM, then human. Tips for LLM grading: "detailed rubrics", discrete outputs ("correct"/"incorrect" or 1–5), reason first and then discard the reasoning, and "prioritize volume over quality" ([Claude docs](https://platform.claude.com/docs/en/test-and-evaluate/develop-tests)).
  - For agents ([Demystifying evals](https://www.anthropic.com/engineering/demystifying-evals-for-ai-agents)):
    - calibrate model graders "closely ... with human experts";
    - give the grader "a way out" by letting it return "Unknown";
    - "grade each dimension with an isolated LLM-as-judge";
    - build in partial credit;
    - "20-50 simple tasks drawn from real failures is a great start".
- **Google ADK** ([criteria](https://adk.dev/evaluate/criteria/)).
  - `rubric_based_final_response_quality_v1` and `rubric_based_tool_use_quality_v1` give each rubric 1.0 or 0.0, take a majority vote over `num_samples`, and average across rubrics. A threshold in [0,1] passes the case.
  - Averaging is compensatory: a missed rubric can be offset by others.
- **LangSmith / LangGraph.**
  - Align Evals shows an "alignment score", the percentage of examples where the judge matches a human label, fed by annotation queues ([docs](https://docs.langchain.com/langsmith/improve-judge-evaluator-feedback), [announcement 2025-07-29](https://www.langchain.com/blog/introducing-align-evals)).
  - LangGraph's evaluator-optimizer is `llm.with_structured_output(Feedback)` with `grade: Literal[...]` plus free-text `feedback`, and a conditional edge on the grade ([workflows](https://docs.langchain.com/oss/python/langgraph/workflows-agents)).
- **Practitioner consensus (Husain/Shankar, updated 2026-09-18)** ([evals FAQ](https://hamel.dev/blog/posts/evals-faq/), [binary vs Likert](https://hamel.dev/blog/posts/evals-faq/why-do-you-recommend-binary-passfail-evaluations-instead-of-1-5-ratings-likert-scales.html)).
  - Use binary pass/fail rather than Likert scales. Track progress as separate binary checks ("4 out of 5 expected facts"), and report a "pass all" rate.
  - Label 100–200 examples per failure mode, with 30–50 passes and 30–50 fails in each of dev and test. Never put dev or test examples in the prompt.
  - Once the judge's true-positive and true-negative rates are known, use them to correct its raw failure rate.
  - The FAQ names "a zero-shot classifier like Jev" as a judge option.

## 2. Verifiers, best-of-n, and process vs outcome reward

- **Verifier reranking works.** On GSM8K, 6B verification "slightly outperforms a finetuned 175B model ... approximately equivalent to a 30x model size increase" ([Cobbe et al.](https://arxiv.org/html/2110.14168v2)).
- **A generative verifier's score is P(Yes).** GenRM scores a candidate as `p(Yes | x, y, I)`, the same shape as a Noul ([arXiv 2408.15240](https://arxiv.org/html/2408.15240)).
  - Best-of-N on algorithmic tasks rose from 5% to 45.3%.
  - GSM8K rose from 73% to 93.4%, with CoT and 32-way voting.
- **Imperfect verifiers set a ceiling** ([arXiv 2411.17501](https://arxiv.org/abs/2411.17501)).
  - Resampling cannot reduce the chance that a wrong candidate passes, so false positives cap accuracy "regardless of compute budget".
  - The optimal number of attempts is "often fewer than 10". False-positive code is also worse in other ways, such as style.
- **Goodhart applies to best-of-n.** Against a proxy reward model, best-of-n raises the gold score and then lowers it. The coefficients scale smoothly with reward-model size ([arXiv 2210.10760](https://arxiv.org/abs/2210.10760)).
- **Mix verifier types** ([R2E-Gym](https://arxiv.org/abs/2504.07164)).
  - "Test-based verifiers suffer from low distinguishability, while execution-free verifiers are biased and often rely on stylistic features."
  - Each plateaus around 42–43%. Hybrid best-of-N reaches 51% on SWE-bench Verified.
- **Process vs outcome.**
  - Outcome and process supervision reach similar final-answer error (16.8% → 12.7%). Only process-based signals cut reasoning errors among correct answers (14.0% → 3.4%) ([Uesato et al.](https://arxiv.org/abs/2211.14275)).
  - A process reward model beat an outcome one at best-of-1860 on MATH: 78.2% vs 72.4%, against 69.6% for majority vote ([Lightman et al.](https://ar5iv.labs.arxiv.org/html/2305.20050)).
  - Best-of-N evaluation of PRMs is biased (correct answers with flawed steps pass), and PRMs "drift" toward outcome judgement ([Qwen lessons](https://arxiv.org/abs/2501.07301)).
  - DeepSeek lists three problems with PRMs: steps are hard to define, step labels are hard to get, and a model-based PRM "inevitably leads to reward hacking". It kept rule-based outcome rewards ([DeepSeek-R1](https://arxiv.org/html/2501.12948v1)).

## 3. LLM-judge reliability: what the earlier notes did not cover

- **Hard correctness pairs defeat strong judges.** On JudgeBench, "many strong models (e.g., GPT-4o) [perform] just slightly better than random guessing" ([arXiv 2410.12784](https://arxiv.org/abs/2410.12784)).
- **Panels are less independent than they look** ([Kim et al., ICML 2025](https://arxiv.org/abs/2506.07962)).
  - When two models both err, they agree 60% of the time on one leaderboard.
  - Larger and more accurate models are highly correlated even across providers, and this affects LLM-as-judge.
  - A two-judge agreement is weaker evidence than two independent votes.
- **Judges save human labels, but at most half of them.** When the judge is no more accurate than the model it evaluates, "no debiasing method can decrease the required amount of ground truth labels by more than half". Measured savings were smaller still ([Dorner, Nastl, Hardt, ICLR 2025](https://arxiv.org/abs/2410.13341)).
- **Use the distribution, not the argmax.**
  - "Taking the mean of the judgment distribution consistently outperforms taking the mode", and chain-of-thought "can collapse the spread of the judgment distribution" ([arXiv 2503.03064](https://arxiv.org/abs/2503.03064)).
  - G-Eval's probability-weighted score reached Spearman 0.514 with humans on summarization ([arXiv 2303.16634](https://arxiv.org/abs/2303.16634)).
- **Forcing an LLM to answer in JSON costs it reasoning** ([Tam et al., EMNLP 2024](https://arxiv.org/abs/2408.02442)).
  - JSON mode degrades reasoning, stricter formats degrade it more, and an "answer" field placed before "reason" skips the reasoning.
  - A model that is typed by construction (Jev) does not pay this cost. An LLM critic forced into a schema does, so let it reason first and put the verdict field last.
- **Calibration, head to head** ([OpenRouter, 2026-09-21](https://openrouter.ai/blog/tutorials/jev-vs-llm-as-a-judge/); a vendor-adjacent tutorial with a small n, so treat it as a hint).
  - Accuracy was equal: 84 vs 83 of 88 HaluEval items.
  - The LLM judge's confidences "landed near 0 or near 1" with six distinct values. Brier score: 0.043 for Jev vs 0.054 for the LLM judge.
  - Cost per 1,000 judgments: $0.021 vs $0.114. Median latency: 171 ms vs 1,662 ms.

## 4. Selective prediction, abstention and escalation

- **Decision theory.**
  - Chow: with a unit error cost and reject cost r, reject when 1 − max posterior > r ([Chow 1970](https://doi.org/10.1109/TIT.1970.1054406)).
  - Elkan: act when p > c_FP / (c_FP + c_FN) ([Elkan 2001](https://www.ijcai.org/Proceedings/01/Papers/061.pdf)).
  - Kalai et al. (OpenAI): "Answer only if you are >t confident, since mistakes are penalized t/(1−t) points". Under binary grading, "abstaining is strictly sub-optimal" ([arXiv 2509.04664](https://arxiv.org/html/2509.04664)).
  - On SimpleQA, the model that abstained 52% of the time made errors on 26% of questions; the one that abstained 1% of the time erred on 75%, at similar accuracy (22% vs 24%) ([OpenAI](https://openai.com/index/why-language-models-hallucinate/)).
- **Guaranteed-risk abstention.** Each of the methods below needs a labelled calibration set drawn from the same distribution as live traffic.
  - Selective classification picks a threshold so that error on the accepted items is ≤ r* with probability ≥ 1−δ. The paper reports 1% error at more than 78% coverage on images ([Geifman & El-Yaniv](https://arxiv.org/html/1705.08500v2)).
  - Conformal risk control bounds the expected value of any monotone loss, given exchangeable calibration data ([arXiv 2208.02814](https://arxiv.org/abs/2208.02814)). Learn-then-Test treats the choice of threshold as multiple hypothesis testing ([arXiv 2110.01052](https://arxiv.org/abs/2110.01052)).
  - LLM versions exist for sampled answer sets ([Conformal LM](https://arxiv.org/abs/2306.10193)) and for abstaining to hold a target hallucination rate ([DeepMind](https://arxiv.org/abs/2405.01563)).
- **A deployed gate with published errors: Claude Code auto mode** ([Anthropic, 2026-03-25](https://www.anthropic.com/engineering/claude-code-auto-mode)).
  - The classifier sees "user messages and the agent's tool calls". It is deliberately blind to assistant reasoning (so the agent cannot talk its way past it) and to tool outputs ("where hostile content enters").
  - Stage 1 is a single-token filter tuned for recall: 8.5% FPR, 6.6% FNR. Stage 2 reasons only on what stage 1 flagged.
  - The whole pipeline: 0.4% FPR on 10,000 real calls, and 17% FNR on 52 real overeager actions.
  - It escalates to a person after "3 consecutive denials or 20 total".
  - A secondary summary of an independent stress test reports 81% FNR end to end on ambiguous DevOps tasks, because about 37% of state-changing actions never reach the classifier ([secondary](https://grimoire.artificerdigital.com/scouts/2026-05-03-auto-mode-permission-classifier-stress-tests/)). The lesson: measure a gate's coverage, not only its accuracy.
- **Where people actually review.**
  - Users approve 97% of permission prompts but reject 39% of plans ([claude.com, 2026-08-07](https://claude.com/blog/auto-mode-default-in-claude-code)).
  - In a 1,053-tester study, "human review caught just 13.6% of dangerous commands, while auto mode caught 89%" (same source).
  - Autonomy is a design choice separate from capability. The person's role can be operator, collaborator, consultant, approver or observer ([Feng et al.](https://arxiv.org/abs/2506.12469)).
- **What Jev's own docs say.**
  - Confidence = (n·max − 1)/(n − 1), which measures how concentrated the distribution is. A Noul has no confidence value, because its value already is P(yes).
  - The docs describe tiers (act; confirm or flag; do not act) and say "Start with conservative thresholds, test with your own data" ([confidence](https://docs.typesafe.ai/confidence.md)).
  - Thresholds are set per action by the cost of being wrong, for example 0.6 for a low-stakes action and above 0.85 for a high-stakes one ([confidence routing](https://docs.typesafe.ai/patterns/confidence-routing.md)).
  - A Score is a probability-weighted level, so identical scores can come from different distributions ([Score](https://docs.typesafe.ai/primitives/score.md)).
  - Once thresholds are tuned, pin the versioned model id rather than `jev-latest` ([Models](https://docs.typesafe.ai/models)).

## 5. Measuring calibration in production

- **Brier score and reliability diagrams** ([scikit-learn](https://scikit-learn.org/stable/modules/calibration.html), [Niculescu-Mizil & Caruana](https://doi.org/10.1145/1102351.1102430)).
  - Brier mixes calibration, resolution and uncertainty (Murphy's decomposition), so a lower Brier can come with worse calibration.
  - Plot reliability curves with `strategy='quantile'`.
  - Use Platt scaling with little data. Isotonic "will perform as well as or better than 'sigmoid' when there is enough data (greater than ~ 1000 samples)".
  - Fit calibrators on data disjoint from the rows being judged.
- **ECE is biased at small n.** Equal-width bins are more biased than equal-mass bins. Use equal-mass bins or `ECE_sweep`, and report n beside the figure ([Roelofs et al., AISTATS 2022](https://arxiv.org/abs/2012.08668)).
- **How many labels.**
  - 100–200 per failure mode, with 30–50 of each class in each of dev and test ([Husain/Shankar](https://hamel.dev/blog/posts/evals-faq/)).
  - With zero errors in n cases, the 95% upper bound on the true error rate is about 3/n ("rule of three"). Claiming under 1% false wins therefore takes about 300 clean audited wins ([Hanley & Lippman-Hand, JAMA 1983](https://pubmed.ncbi.nlm.nih.gov/6827763/)).
  - Prediction-powered inference combines many model predictions with a few human labels into valid confidence intervals ([Angelopoulos et al., Science 2023](https://doi.org/10.1126/science.adi6000)).
- **The labels you get are biased.**
  - When outcomes are observed only for cases a decision let through, comparing humans and machines "can lead to erroneous estimates" ([Lakkaraju et al., KDD 2017](https://www.kdd.org/kdd2017/papers/view/the-selective-labels-problem-evaluating-algorithmic-predictions-in-the-pres)).
  - In a loop, a Jev "win" that nobody reviews never gets a label unless it is sampled for audit.
- **The label is anchored if the person saw Jev.** "Cognitive forcing significantly reduced overreliance", but people liked those designs least ([Buçinca et al.](https://arxiv.org/abs/2102.09692)).
- **Schema.**
  - OpenTelemetry's `gen_ai.evaluation.result` event carries `gen_ai.evaluation.name`, `score.value`, `score.label` and `explanation`, parented to the evaluated span ([OTel GenAI events](https://github.com/open-telemetry/semantic-conventions-genai/blob/main/docs/gen-ai/gen-ai-events.md)).
  - It has no field for thresholds, model version or evidence digest, so CyberPong has to add its own ([discussion, 2026-08-23](https://eunomia.dev/ebpf-qa/2026-08-23-opentelemetry-genai-evaluation-evidence-reference/)).

## 6. Routers that choose branches by probability

- **Keep the routing decision typed.** LangGraph's router is `with_structured_output(Route)` with `step: Literal[...]` feeding a conditional edge ([workflows](https://docs.langchain.com/oss/python/langgraph/workflows-agents)). The frameworks note records ADK 2.0's move of routing out of the LLM.
- **Threshold on a win probability.**
  - RouteLLM sends a query to the strong model when P(strong wins | q) ≥ α, with α calibrated to a target share of strong calls. Its best MT-Bench router recovers 50% of the quality gap with 13.4% strong calls, and saves up to 3.66× ([arXiv 2406.18665](https://arxiv.org/html/2406.18665)).
  - FrugalGPT cascades models, with a scorer deciding whether to accept a cheap answer: "up to 98% cost reduction" at GPT-4 quality ([arXiv 2305.05176](https://arxiv.org/abs/2305.05176)).
  - Arch-Router (1.5B) maps queries to domain/action policies that people write ([arXiv 2506.16655](https://arxiv.org/abs/2506.16655)).
- **Pattern:** "The answer tells you what; confidence tells you whether to act", with a threshold per action ([TypeSafe](https://docs.typesafe.ai/patterns/confidence-routing.md)).

## 7. Guarding judges against the artifacts they grade

- **Trivial strings flip judges.**
  - "Master keys" such as ":" or "Thought process:" produce false-positive rewards across judges, GPT-o1 and Claude-4 included ([arXiv 2507.08794](https://arxiv.org/abs/2507.08794)).
  - Short universal phrases inflate absolute scores. Comparative assessment is "significantly" more robust ([arXiv 2402.14016](https://arxiv.org/abs/2402.14016)).
  - Optimised injections beat known-answer and perplexity detectors ([JudgeDeceiver](https://arxiv.org/abs/2403.17710)).
- **Defences that work are architectural.**
  - Spotlighting (delimiting, datamarking or encoding untrusted text) took attack success from above 50% to below 2% ([arXiv 2403.14720](https://arxiv.org/abs/2403.14720)).
  - Six design patterns share one rule: after reading untrusted input, it must be "impossible for that input to trigger any consequential actions" ([arXiv 2506.08837](https://arxiv.org/html/2506.08837)). The patterns are action-selector, plan-then-execute, map-reduce, dual LLM, code-then-execute and context-minimization.
  - Auto mode's classifier does not read the agent's prose or tool output at all ([Anthropic](https://www.anthropic.com/engineering/claude-code-auto-mode)).
  - TypeSafe's state docs do not address injection ([State](https://docs.typesafe.ai/concepts/state.md)). The earlier Jev design note found that authority claims planted in state flipped 147 of 200 tickets, so CyberPong has to supply the defence itself.

---

## 8. What this means for Jev in CyberPong

**Where the engine stands (read-only).**
- `graph_engine.py` has a seatless `jev` node with `ask: grade | decide | rank`. Lint requires an abstain edge and warns when that edge does not lead to a person (lines 139–268).
- `jev.py` defaults:
  - a line passes at P(level ≥ floor) ≥ 0.5, and "assessable" is cut at 0.5;
  - any line under the bar fails the grade;
  - `decide` takes a route at P ≥ 0.9;
  - `rank` averages two option orders, and `take` defaults to 0.0.
- It keeps a ledger of calls and labels with state hashes and no text (lines 515–720).

The recommendations below adjust these defaults; they do not replace the design.

### 8.1 Where a typed judge belongs in a loop

1. **After `check`, never before.**
   - Grade a rubric only on work whose commands passed. This is verification-first (labs note P3) and Anthropic's code → model → human order.
   - At 70–500 ms, Jev can afford to see every surviving candidate. It must never grade something that failed a test, because verifier false positives are the loop's ceiling (§2).
2. **Beside the LLM critic first. Instead of it later, only on closed lines.**
   - Jev writes no `must_fix` text, and the builder needs that text.
   - Start with critic plus Jev: the critic reasons in prose and ends with a verdict, Jev scores each line, the engine routes on Jev's typed outcome, and the critic's verdict breaks ties in the uncertain band.
   - Let Jev replace the critic only on closed-check lines ("every claim cites a URL", "the section exists", "numbers match the table"). Require ≥ 50 labels at κ ≥ 0.6 on that line first (§5; the kappa target is from the earlier Jev design note).
   - Keep a fresh cross-family LLM critic for open-ended flaws. Hard correctness is where every judge, typed or not, is weakest (JudgeBench).
3. **As a router (`ask: decide`) only among edges already drawn, and always with `none`.**
   - The route threshold follows the route's cost (§4): 0.7 to send work back to a builder (reversible; costs one round), 0.9 to skip a person or spend money, never for anything that leaves the Mac.
   - Below the threshold, or on `none`, take the abstain edge to a person.
   - Jev chooses among options; it never plans them (frameworks note: no LLM routing each round).
4. **As a ranker at a join (`ask: rank`), over passing candidates only.**
   - A winner needs P(winner) − P(runner-up) ≥ 0.2, both option orders agreeing, and `none` < 0.2. Otherwise send the top two to the human merge gate.
   - Cap best-of-N at K ≤ 4, because false passes grow with K ([arXiv 2411.17501](https://arxiv.org/abs/2411.17501)).
   - Today `rank` declares a winner at any probability (`take` defaults to 0.0). That is too permissive.
5. **As a recommender at `human` gates, blinded one time in five.**
   - Jev orders the queue and shows the lowest line first, as the earlier Jev design note settled.
   - On a random 20% of gates, show Jev's numbers only after the person answers, so those labels are not anchored ([Buçinca](https://arxiv.org/abs/2102.09692)).
   - Put gates at plan and merge, where people actually review, not on every step ([claude.com](https://claude.com/blog/auto-mode-default-in-claude-code)).
6. **Not as a process grader of builder transcripts, and not as a tool the builder can call.**
   - Step grading is hard to define and gets hacked (§2). A builder that can query its grader games it (labs note §5, METR).
   - The builder sees the rubric lines (the bar) and, after a fail, the failing line ids plus the critic's text. It never sees Jev's probabilities.

### 8.2 Turning probabilities into outcomes

- **Per line, use the tail probability, not the expected score.**
  - Score line: p_i = P(level ≥ floor_i), which `p_at_least` already computes. Noul line: P(yes).
  - The expected score hides bimodal answers ([Score docs](https://docs.typesafe.ai/primitives/score.md)).
- **Two thresholds per line give three bands:** pass if p_i ≥ t_hi, clear fail if p_i ≤ t_lo, uncertain in between.
  - Start at **t_hi = 0.8, t_lo = 0.3**.
  - Why 0.8: by Elkan's rule, t_hi = 0.8 means a false "win" (a person's time wasted, or a defect shipped) costs four times a needless extra round ([Elkan](https://www.ijcai.org/Proceedings/01/Papers/061.pdf)).
- **Combine lines conjunctively with a union bound, not with a minimum taken at 0.5.**
  - By the Fréchet bounds, P(all lines pass) lies between max(0, Σp_i − (k−1)) and min p_i ([Fréchet inequalities](https://en.wikipedia.org/wiki/Fr%C3%A9chet_inequalities)). The minimum is the *optimistic* bound.
  - Example: eight lines at 0.55 each pass today's rule. Their joint pass probability could be 0, and is about 0.008 if the lines are independent.
  - **Win:** every assessable line has p_i ≥ t_hi **and** Σ(1 − p_i) ≤ 0.25. That guarantees P(all pass) ≥ 0.75 whatever the correlation between lines.
  - **Fail:** any assessable line has p_i ≤ t_lo.
  - **Escalate:** everything else, via the existing `abstain` edge, with lines sorted weakest first.
  - Weighted means are for ranking candidates that all passed, and for the gate's display, never for the gate itself ([Husain pass-all](https://hamel.dev/blog/posts/evals-faq/); the labs note on Anthropic's per-criterion thresholds).
- **"Assessable" is its own question with its own band.**
  - Below 0.3 means not assessable: fail if the section is missing (the builder's to fill), abstain if the state was truncated (as the code already does). Treat 0.3–0.6 as uncertain and escalate.
  - Jev's Noul runs under-confident (the earlier Jev design note), so a single cut at 0.5 fires on noise.
- **Confidence floor for Choice and Score.** An automatic route or ranking also needs confidence ≥ 0.5 (TypeSafe's (n·max−1)/(n−1)); otherwise escalate. A Noul has no confidence value, so its band is its floor.
- **Repeated failure goes to a person.**
  - Two fails in a row on the *same* line: take the engine's `no_progress` stop and escalate instead of running another round. Cheating rises with each resubmission (labs note §5).
  - A timeout on an escalation never becomes a pass.

### 8.3 What to log so calibration can be measured against the person's later decisions

Extend each ledger `call` record (`jev.py` `_log`), still with no state text.
- **Identity:**
  - graph id, node id, visit/round, and a hash of the topology;
  - rubric or question-card id, its version, and `instructions_sha` (already logged);
  - the requested model and the *returned* versioned model id, plus a shadow flag.
- **Inputs:**
  - `state_sha` (already logged);
  - the source of each state field (engine-computed, artifact text, or untrusted);
  - whether the state was truncated, and what was redacted;
  - the preceding `check` results, the builder's model family, and the critic's verdict when a critic ran beside Jev.
- **Outputs:**
  - for each line: the probabilities, p_i, assessable and confidence;
  - the thresholds in force (t_hi, t_lo, union budget, take);
  - the engine's outcome and the edge taken, and the latency.
- **Labels** (`label` records):
  - the person's gate answer, with the line they cite if any;
  - whether Jev's numbers were shown or blinded;
  - an audit flag with its sampling probability, so estimates can be reweighted ([selective labels](https://www.kdd.org/kdd2017/papers/view/the-selective-labels-problem-evaluating-algorithmic-predictions-in-the-pres));
  - the time the person took to decide;
  - a delayed outcome: reverted, reopened, or reworked within 14 days.
- **Weekly, per question:**
  - volume: n;
  - calibration: Brier, ECE with equal-mass bins printed beside its n ([Roelofs](https://arxiv.org/abs/2012.08668)), and a reliability plot once n ≥ 100;
  - agreement: κ with the person on blinded rows;
  - gate traffic: escalation rate and override rate;
  - errors: the false-win rate on audited wins, with its rule-of-three bound;
  - independence: the error correlation between Jev and the critic on labelled rows ([Kim et al.](https://arxiv.org/abs/2506.07962)).
- If traces are ever exported, map each record to `gen_ai.evaluation.result` ([OTel](https://github.com/open-telemetry/semantic-conventions-genai/blob/main/docs/gen-ai/gen-ai-events.md)).

### 8.4 Defaults at low volume (a handful of graphs a week)

1. **Shadow until each rubric has 50 labels**, ideally 30+ of each class ([Husain](https://hamel.dev/blog/posts/evals-faq/)). During shadow the critic routes, and Jev is logged and shown at the gate.
2. **Then an asymmetric start.**
   - On its own, Jev may send work back (fail) or to a person (escalate).
   - A win still needs the critic to agree, or a person, until the rubric has ≥ 100 labels, κ ≥ 0.6, and zero false wins in the audit sample.
3. **Audit 20% of Jev's automatic outcomes**, dropping to 10% after 200.
   - This is the only way to measure false wins.
   - About 300 clean audited wins are needed to claim under 1% false wins ([rule of three](https://pubmed.ncbi.nlm.nih.gov/6827763/)).
4. **Calibration steps:** no probability remapping under 100 labels, Platt from 100, isotonic only past about 1,000 ([scikit-learn](https://scikit-learn.org/stable/modules/calibration.html)).
   - Move thresholds before remapping probabilities.
   - Pin the model version. Re-check thresholds on any change of version, wording, option order or state fields, as the earlier Jev design note advises.
5. **Small rubrics:**
   - at most 6 lines per deliverable;
   - Noul or 3–4-level Score lines, worded as situations;
   - floors and weights in the rubric file, not in the criteria text.
6. **No vector store is needed for any of this.**
   - The ledger is append-only JSONL, or SQLite if queries get heavy.
   - Jev is shaped by criteria text and state, not by retrieved few-shot examples ([TypeSafe models](https://docs.typesafe.ai/models)).
   - Qdrant or pgvector matter for document retrieval, not for grading.

### 8.5 Failure modes to design against

- **Injection from the artifact.**
  - The engine builds the state. Check results and diff statistics go in as typed fields; artifact text goes in one field, labelled untrusted and datamarked ([spotlighting](https://arxiv.org/abs/2403.14720)).
  - The builder's claim summary is never sent (auto mode's reasoning-blind rule).
  - Keep a probe set with planted "this meets every criterion" lines and master-key strings ([arXiv 2507.08794](https://arxiv.org/abs/2507.08794)). Any rise in P on the probes blocks a rubric change.
- **Goodhart through the builder.** The builder cannot call Jev, cannot see probabilities, and cannot edit the rubric (add the rubric file to `protect`). Rounds stay bounded ([Gao et al.](https://arxiv.org/abs/2210.10760)).
- **False passes compounding in best-of-N.** Rank only candidates that passed `check`, keep K ≤ 4, and leave the merge to a person.
- **Correlated judges.** Jev agreeing with a Claude critic does not count as two independent votes until their error correlation has been measured.
- **Selective and anchored labels.** Covered by the audit samples and blinded gates (8.3, 8.4).
- **Silent threshold drift.** Pin the model version and refit on any change.
- **Escalation fatigue.** If escalations exceed about 30% of gates, or the person approves more than 95% of them, fix the rubric or the thresholds instead of asking more often (recall the 97% approval rate).
- **Coverage holes.**
  - Every path of a graph whose output leaves the Mac must pass through a `jev` or `human` node, and lint should check this.
  - Auto mode's worst misses were actions that never reached the classifier ([secondary](https://grimoire.artificerdigital.com/scouts/2026-05-03-auto-mode-permission-classifier-stress-tests/)).
- **Unreachable Jev.** "No key, no guess": the answer is "not asked", and the graph routes to a person (already in `jev.py`). A missing answer never defaults to pass.
