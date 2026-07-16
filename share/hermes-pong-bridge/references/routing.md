# Bridge routing

## State files
- `~/.hermes-pong/active-pair.json` — session, window ids, `claude_mode`, `autonomy_level`
- `~/.hermes-pong/pairs.json` — all pairs
- `~/.hermes-pong/last-sent.txt` — last bridge prompt
- `~/.hermes-pong/last-claude.txt` — last captured reply (stronger in tmux mode)
- `~/.hermes-pong/relay.pid` — window-mode relay process

## Decision tree
1. Read `active-pair.json`.
2. If `claude_mode == window` and `claude_window_id` set → paste into that Terminal window.
3. Else if tmux session exists → paste into `session:1` (New pair Claude pane).
4. Else fail: ask the user to Link or New pair in Hermes Pong.

## “Sent” but Claude idle
- Prefer `claude-delegate.py` only (not raw `tmux send-keys`).
- Link/window mode uses `claude-window-relay.py` when Hermes types into a hidden pane.
- Log: `~/Library/Logs/HermesPong-relay.log`

## Accessibility
System Settings → Privacy & Security → Accessibility for Terminal / Python if paste fails.

## Mid-session drop
After a few handoffs Hermes may forget the bridge. Re-run `pong-gate.py` before every coding step. If `BRIDGE_ON`, only `claude-delegate.py`.
