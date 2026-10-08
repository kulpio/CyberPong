# graph-kit: running a CyberPong graph from a Claude session

Small tools for running a graph from a Claude Code session, for any team. They need the Python standard library, tmux and the installed `pong`, and nothing else. The app and `scripts/install-control-plane.sh` install `dryrun.py`, `watch.py`, `limit-guard.py` and `pplx.py` to `~/.pong/lib/graph-kit/`; the architect's instructions point there.

| Tool | What it does | Run it |
|---|---|---|
| `dryrun.py` | Walks a topology end to end in a throwaway CyberPong home (no seats, no tokens). Critics fail once, then win; gates are approved. It prints the path, each step's seat, runtime and model, and every problem: a leftover `{placeholder}`, a missing `--expect` string, a refusal, or a graph that does not finish with a win. | `python3 dryrun.py --file build/loop.json --team <team> --pin scout-x=grok --expect "BRIEF.md"` |
| `watch.py` | Exits with one line when a graph needs its Claude session, which wakes it. It fires on a gate opening, a seat needing a look, a step quiet 25+ minutes, a graph stopping, or a seat blocked on its screen (login, folder trust, "allow reads", a permission question, a bare shell). | `python3 watch.py --team <team> g_… g_…` (in the background) |
| `limit-guard.py` | Since 2.0 the graph runner rides out Claude's usage limits by itself (Settings › Limits & keys; `pong limits status`). Run this guard by hand only for its early alerts, or when that handling is switched off. At the 5-hour limit it pauses, waits for the reset, resumes and tells the stuck seats to continue. It alerts before the weekly limit, while the session can still act. It nudges a Claude seat after a network drop. `--probe` prints usage (no tokens). | `python3 limit-guard.py --team <team> --week-alert 97 g_…` (in the background) |
| `pplx.py` | Web research through Perplexity's Agent API, for research seats. It prints an answer with numbered, dated sources and never prints the key. It refuses questions carrying an email, a phone number or a key-like string. It uses the key saved in Settings › Limits & keys, and its daily spending cap (\$15 unless changed there); at most 400 calls and 25 deep calls a day across every project (`~/.pong/pplx-usage.json`). | `python3 pplx.py [--preset low\|medium\|high] "question"` |

**State.** State lives in `~/.pong/sessions/<team>/graph-kit/`: graph and step ids and times, never screen text. While `limit-guard.py` holds a limit, `watch.py` stays quiet and the runner leaves that team to the guard. The session runs on the same Claude account as the seats, so a wake-up during a limit could not be answered.

**Lessons behind them** (from long unattended runs):
- **Timeouts:** a step's timeout counts from its start whatever happens, including a pause. It gets one automatic retry, then errors to its edge. A plan that errors to the gate is re-run cleanly by answering the gate `rejected` with a note.
- **Attaching:** attach a new graph while the previous one still sits at its gate, so the new graph takes no seat name the old one used.
- **Jev reads its scoring lines literally.** A signable exception to a person's rule (a standing authorisation for posts) fails the same line every round. Say it is the owner's choice, and answer the gate yourself.
- **Mac sleep:** a Mac that sleeps or drops its network stalls a step for hours. Keep it on power with the lid open during runs.
- **The weekly "Reset for free"** has to be pressed before 100%, because at the limit the session is blocked too. Computer use cannot drive the Claude app; the button is also on claude.ai.
