# Graph loops (CyberPong 2.0)

A graph loop is work you describe as **nodes** (each one a step done by an AI CLI in a real terminal, by the engine itself, or by you) and **edges** (which step comes next, on what outcome). The runner ticks every graph on the Mac every 30 seconds; the **Graphs** page shows them; you answer the gates.

This page is the contract. The research behind each choice is in `docs/research/` (`graph-loops-labs-2026-09.md`, `graph-loops-frameworks-2026-09.md`, `x-graph-loops-2026-09-24.md`).

## Start one

```bash
pong graph examples                       # the templates, with their notes
pong graph lint --file topo.json          # errors refuse it; warnings name what will misbehave
pong -s <team> graph attach --owner c1 --file topo.json --task "what done means" \
     [--max-wall 180] [--max-jobs 16] [--node-timeout 45] [--pin judge=grok]
pong graph new                            # eight questions in a terminal, a proposal, Start
```

Or in the app: **Graphs → From template** (pick a template, a team, the lead seat, type the goal) or **New graph** (the interview in Terminal).

## Watch and answer

```bash
pong graph list                           # every graph on this Mac, waiting-on-you first
pong -s <team> graph show [--id g_…]      # one graph in words, with the exact commands for its open gates
pong -s <team> goal resume --id g_… --outcome approved|rejected [--node <gate>] [--note "what to change"]
pong -s <team> goal pause --id g_…        # holds new dispatches; finished work is still harvested
pong -s <team> goal resume --id g_…       # lifts a pause (when no gate is open)
pong -s <team> goal cancel --id g_…
pong -s <team> graph retry --id g_… --node <id>   # run a failed step again
pong -s <team> graph peek --seat c1.c     # the seat's terminal, read-only
```

## Nodes

| role | who does it | notes |
|---|---|---|
| `builder`, `writer`, `scout`, `researcher`, `operator`, `router` | an AI CLI seat (Claude Code, Grok Build, Codex, Hermes), chosen per node by the wiring solver | each has its own playbook; `pin` or `--pin node=grok` overrides the platform |
| `critic` | an AI CLI seat on a **fresh pane every visit** | must say `win`, `fail` or `abstain`; sees the artifacts, not the builder's own account |
| `check` | **the engine**: runs `run: [commands]` in the project, exit codes decide | `win` when all exit 0; `protect` files that changed since the start fail it; the same failure twice stops the loop as `no_progress` |
| `human` | you | a gate: the graph asks, you answer `approved`, `rejected`, or a label the gate's edges name, with an optional note. The designer's words for the card: `ask` (the question, at most 15 words), `answers` (`{outcome: what it does}`) and `explain` (what is being decided and what to check, at most 600 characters, or a list of points, each a line or `{"text", "file", "where"}` with the file relative to the project; shown first under the question) — see *The question card* |
| `join` | the engine | a barrier: `wait: all` (default), `any` (first wins, the rest are cancelled) or a number; `pass: all \| majority \| any` for judge panels; `timeout_min` goes ahead with what arrived |
| `jev` | **the engine, asking Jev** | `ask: grade` (rubric lines over the work), `decide` (one of its `route:` edges) or `rank` (the best of the candidates a join brought); needs an `abstain` edge — see *Jev in the loop* |
| `end` | the engine | a branch ends here |

Node options: `task` (with `{goal} {round} {prev_summary} {prev_artifacts} {prev_node} {history} {notes} {copy} {visits_left}`), `count: k` (k copies, with `pins: [...]` per copy: best-of-N, judge panels), `max_visits`, `timeout_min`, `retries` (default 1), `fresh`, `sees: [artifacts, summary, notes, history]`, `family: different` (another model family than the step before), `branch: switch` (first matching edge only).

## The question card

Every gate opens with a card, and a chat's own question (`pong ask new`) gets the same one:

- **The question**: one plain question, at most 15 words, naming the actual thing.
- **Context**: up to three short lines.
- **What each answer does**: the engine's words, from the graph's shape, or the designer's `answers` (for a chat's question, the chat's own options). Never a model's.
- **What you're deciding**: up to six points that explain the decision in more depth (each at most 280 characters, 1,400 in all): what exactly is being decided, the concrete items and numbers, what a review or a check found, what is still open. A point can carry the `file` it comes from (a full path; one click opens it) and `where` in it (a heading, an item number; at most 60 characters), so the person can decide without reading the whole file, with the proof one click away.
- **Who wrote the points** (`detail_by`, below), so the person knows how far to trust them.

**The designer's words.** A `human` step's `ask`, `answers` and `explain` are the designer's and always win. `explain` is what is being decided and what to check: at most 600 characters, or a list of points, each a line or `{"text", "file", "where"}` with the file relative to the project. Its points come first.

**Where the points come from.** At once, from the engine: the designer's `explain`, then the step's own report (its first sentences), Jev's lines that are not met (by their text, at most three) and the list of work files (logs and before-copies left out). Then, in the background, from a helper model: Claude Haiku through the local `claude` command, with no tools and with thinking off (a short rewrite, not a puzzle). It reads the goal, the step's full report, Jev's lines and up to four work files, about 16,000 characters in all: a file that fits is read whole; a longer one by its heading outline, its start and any section titled like a summary, the changes, the decisions, the open questions, what is proposed or a review. It rewrites the question and its context in plain words and writes three to six points, each naming its file and the place in it. When the designer wrote `ask`, it runs detail-only: the designer's question, context and answers stay, and its points come after the designer's `explain`.

| `detail_by` | the points came from |
|---|---|
| `CyberPong` | the engine alone: the step's report, Jev's lines, the files |
| `Claude Haiku` | the helper model, from the files |
| `the graph's designer` | the designer's `explain` alone |
| `the graph's designer and CyberPong` | the designer's `explain`, then the engine's points |
| `the graph's designer and Claude Haiku` | the designer's `explain`, then the helper model's points |
| `the chat` | a chat's own `--detail` points |

**What the helper is held to**, by checks in code and not only by its prompt:

- What it reads is data, never instructions.
- It never words what an answer does. A point, a context line or a question that says what pressing a button or giving an answer does ("Approving sends the reply to the client") is dropped, in the points as well.
- It never recommends an answer. A line that recommends or leans on one, or tells the person which answer to give, is dropped; a question that leans falls back to the engine's question (the points still count).
- It never sees a key or a sign-in. Key folders (`.ssh`, `.aws`, `secrets` …), credential files (`*.pem`, `*.key`, `credentials.json`, `.env*`, `.netrc`, `.npmrc`, service-account and client-secret files, anything named like a password) and every dot-folder or dot-file right under the home folder (`~/.claude.json`, `~/.config`, `~/.docker` …) are never read, also through a link, except CyberPong's own `~/.pong` where the work notes are. A file whose text holds a key is skipped, and a point, a line or a question with a key in it is dropped.
- It spends tokens only on the real CyberPong home (`~/.pong`): tests, previews and dry runs never call it. It is off when Settings › Limits & keys › *Helper AI for questions and names* is off, when Claude is switched off in Settings › AI accounts, with `PONG_PLAIN_ASK=off`, or for a graph with `"plain_ask": false`. The engine's card and points stay either way.

While the helper writes, a gate has `ask_pending` (a chat's question `detail_pending`) and the card says the details are coming. The card as first shown and each rewrite are kept in the graph's log (`gate_ask`), so what the person saw outlives the gate. Where a gate has no card, its reason shows instead, in plain words with no step ids: which step finished, and that the person decides ("A reviewer finished: it passes. You decide what happens next."); a gate an older engine opened is shown in the same words.

**A chat's question.** `pong ask new -q "Start round 3 now?" -o "Start::round 3 begins now" -o "Not yet::nothing starts" --detail "Round 3 covers pricing.::PLAN.md::Scope" --file PLAN.md` (`--detail` repeats, at most six; file paths are made absolute against the asker's folder). A question filed with a readable file and no points gets them from the same helper, once, in the background (`pong -s <team> ask explain --id <q>`, `detail_by: "Claude Haiku"`, under the same rules); `PONG_ASK_DETAIL=off` turns that off.

## Edges and outcomes

`on:` is `done`, `fail`, `win`, `approved`, `rejected`, `error`, `abstain`, `blocked`, `bounded`, `route:<label>` or `*`.

- **The most specific edge wins.** An exact match beats a family (`done` covers win/approved; `fail` covers the failure words and `blocked`), and a family beats `*`. Several edges at the same level all run (fan-out) unless the node is a `switch`.
- **A step says how it ended with the first word of its claim.** Each prompt lists the words its own edges accept and where each leads. "Verdict: win", `**WIN**` and "win —" all read as win; "Windows build fixed" does not.
- **A critic that claims without a verdict** is recorded as a refusal and counted as `fail` (unless the graph names a `done` edge for that case).
- **The machinery failing is not the work failing.** A seat whose pane died, or a step past its timeout, is retried once and then ends as `error`, which follows only an `error` (or `*`) edge. It never sends a builder back as if a critic had judged it. A job you cancel by hand ends its branch quietly.
- **Limits.** Rounds per loop (see *Loops* below), the graph by `max_wall_min` and `max_jobs` (`max_wall_min` counts working time: while nothing runs and only a person can move the graph, at an open gate or a manual pause, the clock is set aside, so a gate answered the next morning does not stop the graph); a node's explicit `max_visits` stays a lifetime cap. At a loop's limit its way out is taken (usually to you); a loop never stops the whole graph.

## Loops

Every topology is a DAG of loops, and the engine now sees them: `pong graph lint` prints them, outermost first, with the worst-case job count.

- **Agent loops** — a cycle among agent and engine steps (build ⇄ tests ⇄ critic). Its **header** is the one node work enters by; its **latches** are the edges back to the header. A loop is named by its header.
- **Person loops** — a gate whose answer (usually `rejected`) sends the work round again. It is named by the gate. The agent loops inside its cycle are nested in it.
- **Loose cycles** — a cycle with two ways in. Lint warns; its nodes keep per-node lifetime caps.
- **Every cycle is counted.** With every loop's latches removed the graph must be acyclic; a cycle no latch cuts (inside another loop, say) is reported and its steps keep per-node lifetime caps. A loop entered only by a gate's forward answer takes that answer as its way in; a second gate whose reject goes round through another gate's approval is a person loop of its own.

**Rounds.** A round is counted when work crosses a latch (feeding four copies of a node counts one). Work entering a loop from outside opens a fresh activation at round 1 — so your reject starts a new inner loop with its full budget, instead of the graph dying because the inner loop's visits were spent earlier. A loop's rounds default to `max_rounds` (a header's explicit `max_visits` wins); a topology can set them: `"loops": {"build": {"max_iters": 6}, "ship": {"max_iters": 2}}`. Prompts can say where they are: `{iteration}`, `{iterations_left}`.

**At a loop's cap** the engine takes the loop's way out, in order: the sending node's `bounded` edge; any member's `bounded` edge out of the loop; the gate of the person loop around it (opened with "loop build ran 4 rounds without passing"); else only that branch ends — other branches keep running, and an idle graph finishes as `failed_bounded:rounds`. The same way out serves a node's `no_progress`.

**Seats without live tools.** A topology can set `"boundaries": {"live_tools": false}`: its Claude seats then start with `ENABLE_CLAUDEAI_MCP_SERVERS=false` and `--strict-mcp-config` (no MCP servers, no claude.ai connectors) and its Grok seats with `--deny MCPTool` (every MCP call refused, even under always-approve), and both are refused the shell commands that write to a git repository or reach a remote (`git checkout/switch/reset/stash/pull/push/fetch/merge/rebase/commit/add/apply/am/cherry-pick/revert/restore/clean/rm/mv/tag/worktree/config/remote`, `gh`, `supabase`, `vercel`, `psql`); `git -C`, `git --git-dir`, `curl`, `wget` and package installs (`npx`, `npm install`, `pnpm`, `yarn`, `pip install`, `uv`, `brew` and the like: code a graph writes runs on what the Mac already has) are refused as well, so a seat reads another repository with `cd <dir> && git log` (each part of a compound command is checked on its own: checked live on both runtimes, `cd <dir> && git commit` is refused). git's read commands (log, show, diff, status, blame) stay open. Writing files through the shell (`>`, `sed -i`, `cp`) is held by the seat's instructions, and by the project's own Edit deny rules where a person has set them. That closes the MCP and connector routes and the obvious shell ones; everything else a seat does is still held by its instructions. Opt-in: other graphs keep the tools their seats are configured with.

**A graph step's scope is its task.** Its prompt shows the team's project root but not the team brief (a brief written for the team's earlier mission once told a later graph's critic to grade the wrong document); it writes only inside the project root and reads other folders only as its task allows. A person's answer at a gate starts Jev's "failed twice in a row" count over, so every reject gives the loop its rounds back.

**How a step's claim ends.** A step that owes a verdict (a critic, or any step with a `win` edge) must start its claim with one of the words its edges name. A step that owes none (a writer, a builder) ends normally with no verdict word, and its prompt says where that goes; `fail` or `abstain`, when it has such edges, are for when it could not do the work. A critic's claim is kept up to 2,400 characters for the next round (other steps' 600), and a revision after a review or a gate names the files that were judged.

**A person's answer never stops a graph.** A reject past the gate's rounds, one `max_jobs` could not pay for, or one into a step that has used its explicit `max_visits`, is refused with the reason and the gate stays open; `pong -s <team> goal resume --id g_… --outcome rejected --extend 1` allows one more round, and raises the budgets by what that round can cost at the most: `max_jobs` by every inner round of the loop, `max_wall_min` (when set) by those jobs at the step timeout, and the explicit `max_visits` of the steps the gate sends work to. A person's note reaches the next step on its own line, before the words of the step that came before the gate. Only a person raises a budget. A bounded way out that would go round an outer loop already at its cap takes the outer loop's way out instead; work arriving at a header that is already running merges and is not a round.

The Graphs page draws one ring per loop, labelled with its own rounds (`build · round 2/4`, `ship · round 1/3 · you`); a node's label shows its loop's round. Next stages (docs/research/dag-of-loops-design-2026-09.md §12): each loop keeps its best round and hands that on, a loop stall rule, joins that wait only for this round, and Jev forecasting whether one more round will pass — in shadow first.

## Context and memory

- Every node's first visit starts on a fresh pane, and a fresh Claude/Grok/Codex seat starts **on** its job: the CLI is launched with a one-line pointer to the job's prompt file, so nothing is pasted into a terminal that is still drawing.
- Critics get a fresh pane every visit and see the artifacts, not the builder's summary.
- Each graph has a notes file (`sessions/<team>/graphs/<id>/notes.md`): every step reads it first and appends what the next step must know. Each team has `lessons.md` across graphs. The last steps' outcomes are in every prompt.
- A seat asking a question only a person should answer (a tool permission) is shown as **needs you** on the page, never answered for you. The one prompt the runner answers is Claude's folder-trust question for the team's own project folder.
- A seat whose terminal is a shell prompt, not a model, for 45 seconds (a launch that never started, or a model that quit) is also **needs you**: nothing is working on that step until a person looks. The Graphs page shows each running step's latest line from its screen and whether it is working or quiet (no change for 10 minutes), and the files the graph changed in its working folder. A launch line longer than 900 bytes is sourced from `sessions/<team>/launch/<seat>.sh` instead of typed: a terminal keeps only 1,024 bytes of one typed line.

## The Graphs page

The app opens on **Graphs**. Left: every graph, the ones waiting on you first. Center, three altitudes:

- **Orbit**: every graph as a ring on its team's row; amber diamond = waiting on you.
- **Wiring**: one graph on its deck. Shape is role (cube = builder/writer/operator, pentagon = scout/researcher, triangle = critic/router, flat triangle = join, disc = end, octahedron = you), the badge is the platform (C Claude, G Grok, X Codex, H Hermes), the outline is status (lime running, amber waiting on you, red failed), the dashed ring is a loop with the rounds it has spent, a packet moves only along an edge work is flowing through.
- **Seat**: the selected node's terminal, live and read-only, with **Open in Terminal**.

Right: the inspector (who runs a node, the rule that chose it and why not the others; the gate you answer, with Approve and Reject with a note). Bottom: what happened, newest first. Every button runs the same `pong` command you could type, and the toast shows it.

## Templates (from the research, `pong graph examples`)

| template | shape | when |
|---|---|---|
| `build-verify` | build → tests (engine) → cross-family critic with Jev beside it (`@code-change-spec`, reads the diff) → you | code with a test command (edit `run` and `protect` first) |
| `fanout-synthesize` | plan → 4 read-only workers → barrier → synthesize → you | research, audits, reviews |
| `best-of-n` | 3 attempts on different platforms → barrier → Jev ranks the ones that finished (two option orders, a clear lead or both go to you) → you | drafts and designs; code needs a worktree per attempt (not built yet) |
| `scout-panel` | 3 scouts → brief → 3-judge panel (any refuted claim fails) → fix ⇄ panel → you | anything a person will read and act on |
| `tournament-evolve` | 4 candidates → rank → evolve → meta-review → … → you | open-ended design where "better" can be judged |
| `planner-sprints` | plan → you → sprint ⇄ tests ⇄ cross-family eval (12 visits) → Jev grades the whole change when eval says complete → you | long builds with a feature list |
| `write-review` | draft ⇄ cross-family critic with Jev beside it (`@document`) → you | documents: specs, briefs, reports for a person |
| `jev-triage` | look → Jev picks the path (small fix at 0.7, rework at 0.9) → fix or plan → you; unsure → you pick | triage where the path depends on what is found |
| `question-review` | draft an edit to a rubric → lint (engine) → probe live (engine) → cross-family critic → you | improving a question Jev is asked |

## Not built yet (the research asks for these next)

A token or dollar budget per graph; a git worktree per parallel builder with one merge step; fan-out sized by a list the planner emits; a candidate archive across runs; refitting Jev's thresholds from the ledger (Platt from 100 labels a rubric, isotonic past 1,000); an audit sample of Jev's automatic outcomes.

## How a step reaches its seat

A fresh Claude, Grok or Codex seat is launched with the job as its first message, a one-line pointer to the prompt file (`claude '<pointer>' --add-dir ~/.pong/sessions/<team> --model …`), so nothing is pasted into a terminal that is still starting. `--add-dir` lets Claude read the prompt, the notes and the lessons, which live outside the project. A seat that is already running gets the prompt as a bracketed paste through its own tmux buffer. A step's claim goes to the graph's owner by mailbox, not into the owner's terminal.

## The interview (`pong graph new`)

"A graph loop I describe" takes stages like `gather -> write <-> grade -> me -> done`. A stage's role comes from its name (`grade`, `review`, `test` are critics; `me` is you; `done` ends it; "finish the draft" is a stage, not the end). A critic's fail and your reject go back to the last stage that made something. If you said "a command must pass", that command runs as an engine `tests` check before the first critic. The topology is linted before a team is created, and a Start that fails takes its new team back.

## This Mac: the runner, limits and keys

```bash
pong doctor [--json]                  # is this Mac ready: Python, tmux, the pong command, the engine, the runner, each AI, the keys
pong runtime install-agent [--json]   # turn the graph runner on (or restart it on the engine just installed)
pong limits status [--json]           # what the runner holds for Claude's usage limits, the last usage reading, the switches
pong limits resume [--json]           # lift the limit pauses now: the person's button (a seat that runs it is refused)
pong keys status [--json]             # the Jev and Perplexity keys: set or not, where from, switched on or off
pong keys set --name perplexity       # save a key, read from stdin only (never an argument); never shown
pong keys clear --name perplexity     # remove the key Settings saved
pong jev key set|test|clear [--json]  # the same for Jev's key; test makes one trivial call: works, key refused, unreachable or no key
```

**`pong doctor`** answers what the first-run setup asks, in a few seconds and without spending a token: a checklist in plain words, one line per thing, and for each thing that is not ready, how to fix it (`--json` gives the app the same answer). Whether an AI is signed in is read without a model call (`claude auth status`, Grok's and Codex's own sign-in files; Hermes: can't tell).

**The graph runner.** A graph moves past its first step only while the runner is on: a launchd agent that ticks every graph on the Mac every 30 seconds. `pong runtime install-agent` (the app's *Turn on*) writes `~/Library/LaunchAgents/com.cyberpong.runtime.plist`, with the installed engine on `PYTHONPATH` and a PATH that reaches tmux, Homebrew and the folders the AI CLIs install into (nvm's node versions, volta, bun, an npm prefix, pnpm, Claude Code's own local install, mise and asdf), then loads it, or restarts it when it is already loaded. It refuses, and touches nothing, while the engine is not in place yet (`no_engine`: open CyberPong first, which installs it) and from a CyberPong folder that is not this Mac's own `~/.pong` (`not_this_home`: a preview or a test).

**Limits & keys.** The switches under Settings › Limits & keys (`limits` in `~/.pong/settings.json`; the app writes the file, the engine only reads it):

| switch | default | what it does |
|---|---|---|
| Pause at Claude's 5-hour limit (`ride_out_5h`) | on | At the 5-hour limit, running graphs with a Claude step pause (nothing new is sent; nothing is lost) and go on a minute after the reset. Only the pauses the runner made are lifted, never a person's, and each Claude step still showing the limit is told once to continue. |
| Stop near the weekly limit (`week_stop_pct`) | 97 | When this week's Claude use passes this %, running graphs with a Claude step pause until the weekly reset, or until the person presses *Resume anyway* (`pong limits resume`). 0 turns it off; at 100% they pause anyway, unless Claude's own usage credits are on. |
| Helper AI for questions and names (`helper_ai`) | on | Claude Haiku writes the questions' plain words and points and names chats and graphs (a little of the Claude allowance). |
| Jev second opinions (`jev`) | on | Jev scores the work beside the reviewers. Needs a Jev key. |
| Perplexity web research (`perplexity`, `perplexity_daily_usd`) | on, $15 a day | Research steps search the web through Perplexity, up to the daily cap. Needs a Perplexity key. |

A graph that runs only on other AIs is never paused for Claude's limits. With Claude switched off in Settings › AI accounts, the runner reads no Claude screen and lifts any hold it made, and the helper AI does not run. The runner reads Claude's `/usage` screen (no tokens) in a pane of its own (tmux session `usage-probe`, started in an empty folder of its own), only while a graph runs and only when Claude Code is installed and signed in; a question on that screen other than trusting its own empty folder is never answered (`pong limits status` says what to do). Whether Claude's own usage credits are on is reported, never changed. `pong graph list --json` carries the limit state (`limits`) and the runner's (`runner`) for the app.

**Keys** typed into Settings live in `~/.pong/secrets/jev.env` and `~/.pong/secrets/perplexity.env` (folder 0700, file 0600, written atomically). `pong keys status`, `pong doctor` and the app say only whether a key is set and where it comes from: never the key, a prefix or a length (`pong jev status` in a terminal adds the key's length, never any of its characters). Jev's key is looked up in the Settings file, then `TYPESAFE_API_KEY`, then the file that `key_file` in `~/.pong/jev.json` names. Perplexity's is looked up in the Settings file, then `PERPLEXITY_API_KEY`; on a Mac set up for working on CyberPong itself (`"developer": true` in settings.json), also the key in Claude Code's own Perplexity connector settings. Remove (`clear`) takes away only the key Settings saved: when a key is still found elsewhere, it says so, and switching that service off in Settings stops its use.

## Jev in the loop

Jev (TypeSafe's System One, `jev-1.13.0`, pinned) answers typed questions with probabilities in under a second and never writes text. The engine offers it only options the topology already holds, and code turns the numbers into an outcome. A person still presses anything that goes outside the Mac. The research behind every rule and number is `docs/research/judges-in-graph-loops-2026-09.md` §8; TypeSafe's API is documented at https://docs.typesafe.ai.

**Four places Jev works:**

| where | topology | what happens |
|---|---|---|
| beside a critic | `{"role": "critic", "jev": {"rubric": ["@document"], "mode": "both"}}` | While the critic works, Jev scores the same artifacts against the rubric. `both` (default): either may send the work back, a win needs the critic, and when Jev is unsure the critic decides. `shadow`: logged and shown only. `jev`: Jev's settled verdict routes. The critic's prompt lists the rubric lines as its bar; neither sees the other's answer. |
| a grade of its own | `{"role": "jev", "ask": "grade", "rubric": …}` | `win`, `fail`, or `abstain` when unsure (to a person). |
| a route | `{"role": "jev", "ask": "decide"}` + `route:<label>` edges with `when` (and optional `take`) | asked in two option orders (every option reversed, `none` included); the route is taken only when both orders pick it, its P reaches the edge's `take` in **each** order (default 0.9; 0.7 is enough to send work back a round) and the choice is peaked; else `abstain`. |
| a ranking | `{"role": "jev", "ask": "rank"}` right after a join (lint requires it) | candidates that failed are dropped (one left: it goes on; none: `fail`); the winner needs both orders to pick it, a 0.2 lead **in each order**, P(none) < 0.2 in each, and a peaked choice — else the top two go to a person. The winner's artifacts alone go forward. |

Plus, without any topology change: at every gate Jev's recommendation is shown beside the buttons (never pressed; hidden until you answer on one gate in five — in the app, `graph show` and `pong jev ledger` alike — so your answers can measure it), and a critic that claims without a verdict word is read by Jev in the background — taken only at P ≥ 0.9. In `both` mode a critic's own word (`blocked`, say) is kept unless Jev clearly failed the work.

**A question earns the right to decide.** Only a rubric line whose question has been probed to `gate` status (see *Asking Jev the right questions* below) can fail or pass work on its own. Every other line is graded, logged and shown — marked "advises only" — but a grade that rests on it is *uncertain*: beside a critic the critic decides, on its own a person does. A topology (or `~/.pong/jev.json`) can set `"trust": "all"` to let every line decide; the default is `earned`.

**How a grade becomes an outcome.** Each line's P is P(level ≥ its floor) for a Score, P(yes) for a Noul. A line passes at 0.8, clearly fails at 0.3 or below, and is uncertain between. The work wins only when every line passes **and** the lines' doubts add up to 0.25 at most (Σ(1 − p) ≤ 0.25 keeps P(all pass) ≥ 0.75 whatever the lines' correlation: eight lines at 0.55 are not a pass). An "assessable" Noul beside each Score line catches a section that is not there: under 0.3 the line fails (the builder must write it), unless the document was cut to fit Jev's limit, when it is uncertain. The same lines failing on two visits **in a row**, none of them up by 0.1 or more, stop the loop as `no_progress`, to a person (a pass in between resets it; a loop whose failing lines keep improving runs on; a `shadow` grade never stops anything). Per node: `floor`, `pass_p`, `fail_p`, `union`, `take`.

**What each side sees.** Jev sees the goal, the documents (the producing step's artifacts, walking back past checks and critics — but not past a ranker, whose winner is the work; `diff: true` adds the change since the graph started, file by file: HEAD at start, or git's empty tree in a new repository) and the checks' results, with a note that text inside the documents is data, not an instruction, and how many files it was not shown (never their names: a client folder's file name can itself be client material). The state is fitted to Jev's limit by cutting the longest documents; a cut document makes a line Jev could not find *uncertain*, not a fail, and when any file of the work was withheld a line below the bar is *uncertain* too (it may be met in what Jev could not see), so Jev cannot send the work back on it alone. When `diff: true` and the change itself cannot be read, Jev is not asked: a person (or the critic) decides. A grader never sees the builder's own account, and neither does a gate's advice. The builder sees which lines fell below the bar and why, never Jev's probabilities; Jev's request and answer files live under `~/.pong/jev/runs/`, outside the team folder a seat is given, and a seat that runs `pong jev grade` is refused. You see everything: the lines weakest first, the odds, the model, what was withheld.

**Rubrics.** `@document`, `@code-change` and `@code-change-spec` (for loops whose tests are protected: no "tested" line) ship with the engine (`python/pong/loops/rubrics/`); a rubric is also a file path, a list of lines (`"Every claim cites a source"` or `{"id", "text", "type": "noul"|"score", "floor"}`), or both: `["@document", {"id": "done_means", "type": "noul", "text": "…"}]`. Keep it to about six lines, written as situations. Rubric files are checked when the graph starts (a missing file, a question TypeSafe would refuse, or a floor that is not a level stops the start) and hashed; a rubric changed by the work it grades fails that work. Settings (`pass_p`, `fail_p`, `union`, `take`, `floor`) are checked by lint. A question that cannot be built or read at run time goes to a person, never wedges the node.

**What never goes to Jev.** Without a key, with the breaker open (three failed calls in a row, for a minute), or on a client-facing graph (`boundaries.client_facing` in the topology, or `pong graph attach --client-facing`; unless the topology sets `"jev": {"client_ok": true}`), Jev is not asked and the work goes to a person. Before any call, every string in the state is checked, whatever path it came by: a key or token (the shapes of this Mac's services, behind word boundaries) refuses the call; a stretch that reads like a call transcript — `Speaker: …`, `[00:41:12] **Sam:** …`, timed or not, turns of one line or many, anywhere in the text, and any three or more timestamped speaker lines in a row — is replaced by a note; a credential named as one (`…_API_KEY=`, `…_TOKEN=`, a JSON `"client_secret"`) refuses the call like a known key shape; email addresses, phone numbers and the names under `redact_words` in `~/.pong/jev.json` are replaced. Files are checked on their path and on where a link really points, case-blind: never mail, `.env*`, `secrets/`, tokens, keys (`*.pem`, `*.key`, `*.p12`, `.ssh/`, `.aws/`), Google client secrets, service-account files, `.netrc`, `.pgpass`, `.npmrc`; data files (not code) named like transcripts or under `clients/`, `calls/`, `recordings/`; any file that reads like a transcript; every pattern a person lists under `deny` in `~/.pong/jev.json`, for their own private files (`"deny": ["*/consent.md", "*/likeness/*"]`, matched the same way); and every pattern the graph's nodes name under `deny` (one list for the whole graph). Transcript bodies are never sent.

**The key** is the one saved in Settings › Limits & keys (or with `pong jev key set`), else `TYPESAFE_API_KEY`, else the file `key_file` in `~/.pong/jev.json` names (see *This Mac* above). It is used for one request header and never printed, logged or kept. A temporary `PONG_HOME` (tests) reaches only keys under its own home.

**The ledger** (`~/.pong/jev/ledger.jsonl`) keeps every call — probabilities, pinned and returned model, question versions, the state's hash (never its text), latency, attempts — and, later, what happened: your gate answer, the critic's verdict, the engine's outcome. `pong jev ledger` prints Brier and calibration error against your answers once there are some.

```bash
pong jev status                                    # available? model, ledger size (the key is never shown)
pong jev grade --rubric @… --file DOC.md           # grade a document by hand, weakest line first
pong jev decide --question "…" --option a="…" --option b="…"
pong jev ledger                                    # recent calls; how Jev's odds matched your answers
```

## Asking Jev the right questions

A live run on 24 September showed why this matters. A good brief was failed by the shipped rubric's "sourced" line, because it asked for a source for "a number, a price or a date" and Jev, reading literally, counted the brief's own "Tuesdays at 7am". A Grok critic had judged it right; Jev's fail overrode it for a wasted round and then stopped the loop. The wording was the fault, not the work. Written criteria move Jev from 70 % to 96 %, wrong criteria drop it to 17 %, and a missing "none" option turns 0.95 into 0.00 (`jev/research/suite-question-governance.md` §2). So every question passes three checks, the same in a CyberPong graph and in any other catalog of questions for Jev:

1. **Lint** — `pong jev lint --rubric <@name|file>`, free, and run on every rubric when a graph starts (errors stop the start, warnings are listed). The checklist of §2.6, applied mechanically. Errors: a question that asks Jev to write; instructions that do not say the whole question (Jev never sees the id); a choice without a none / other / unknown option; score levels that are degrees ("low / medium / high") instead of situations; anything TypeSafe would refuse. Warnings: a question that joins several checks; a double negation; a question phrased so that yes is bad; something code decides better (exit codes, counts, dates, sizes); a policy word ("urgent", "appropriate") with no situation spelled out; a positional reference; more than eight lines in a rubric.
2. **Probe** — `pong jev probe --rubric <@name|file> [--cases file]`, live, a few cents: the rubric over labelled cases (`<rubric>.probes.json`: small documents, each with the lines it should pass and fail — at least two of each per line), asked three times each. It measures accuracy, stability across repeats, a state-blind control (asked with no documents, the answers should not predict the labels better than always guessing the commoner one — else the wording leaks the answer), and an injection probe (a planted line saying the work was approved must not move a line by more than 0.1). The verdict is recorded per question version and model: **gate** (accuracy ≥ 0.9, stable, not leaking, not injectable — it may decide), **ranker** (usable but not reliable enough to decide — it advises), **unusable**, **too_few_examples**; a question never probed is **unproven**. Change a word, the line's bar (a score line's floor, a choice line's required option) or the model and it is unproven again; a probe records only the lines it measured, so a probe of one line never erases what the others earned. `--require ranker` passes a rubric whose lines are all at least usable (the question-review template's check). `pong jev questions --rubric …` shows what each line has earned; the shipped rubrics carry theirs (`rubrics/*.status.json`).
3. **Monitor** — every answer is logged with its question's version. `pong jev ledger` lists each question in use: how often it decided (not unsure), how often it failed work, and how often a critic said win or you approved anyway — the disagreements a question's owner reviews. A question you overrule half the time is flagged for review.

Improving a question is itself a graph: the `question-review` template drafts one edit from real disagreements, lints and probes it in engine checks (the probe cases are protected — the test is not the drafter's to change), has a fresh critic on another model family check the edit, and asks you. The labelled cases are the ground truth, so a person reviews them before they bind; the shipped ones were written by Claude and corrected once where Jev's disagreement showed a contestable label.

The shipped rubrics as probed on 24 September (jev-1.13.0): `@document` — does_the_goal, sourced, complete_sections, reader_can_act **gate**; consistent **ranker** (it missed a Tuesday-vs-Thursday contradiction: Jev reads dates as text). `@code-change` — nothing_unrelated, tested, reviewable **gate**; does_the_goal **ranker** (its answers varied a little across repeats). `@code-change-spec` — the same without `tested`.
