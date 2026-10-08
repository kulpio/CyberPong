#!/bin/bash
# Install launchd agent com.cyberpong.runtime — cron + drain without the panel.
# `pong runtime install-agent` writes the same plist from the installed engine
# (no checkout needed); install.sh and setup.sh use that. This script stays for
# a checkout-only setup and for DEST= test installs.
#
# Does NOT rsync onto live ~/.pong/lib unless DEST is set to a path inside
# this repo or a temp dir. Default: PYTHONPATH points at the installed engine.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LABEL="com.cyberpong.runtime"
PLIST_DIR="${HOME}/Library/LaunchAgents"
PLIST="${PLIST_DIR}/${LABEL}.plist"
DEST="${DEST:-}"
INTERVAL="${INTERVAL:-30}"

# Default to the installed control plane — the same one every seat's `pong`
# runs — so the runner and the panes never disagree. Override with PYTHONPATH_VAL.
PYTHONPATH_VAL="${PYTHONPATH_VAL:-${HOME}/.pong/lib}"
# Any python3 of 3.9 or newer runs the engine (the test suite passes on Apple's
# /usr/bin/python3 3.9 once the command line tools are installed; without them
# that path is a stub that only opens an install dialog).
PYBIN="$(command -v python3)"
# launchd starts agents with a bare PATH (/usr/bin:/bin:/usr/sbin:/sbin), so the
# runner could tick a graph but never find tmux to spawn a seat or paste a job
# (a team's runner once reported "tmux session ... is not running" while it was).
# Give it the PATH the engine gives its runner (runtime.runner_path_env, the same
# one `pong runtime install-agent` writes): tmux's own folder, the AI CLIs' folders
# (npm, nvm, volta, bun, pnpm, mise, asdf, Claude Code's local install), Homebrew,
# ~/bin, then the system. This checkout's engine answers; without a python3 that
# can run it, the fixed list below is the fallback.
if [[ -z "${PATH_VAL:-}" && -n "$PYBIN" ]]; then
  PATH_VAL="$(PYTHONPATH="${ROOT}/python" "$PYBIN" -c \
    'from pong.runtime import runner_path_env; print(runner_path_env())' 2>/dev/null || true)"
fi
if [[ -z "${PATH_VAL:-}" ]]; then
  TMUX_DIR="$(dirname "$(command -v tmux 2>/dev/null || echo /opt/homebrew/bin/tmux)")"
  PATH_VAL="${TMUX_DIR}:${HOME}/.local/bin:${HOME}/.grok/bin:/opt/homebrew/bin:/usr/local/bin:${HOME}/bin:/usr/bin:/bin:/usr/sbin:/sbin"
fi
# CRON=1 lets schedule rows fire. Default: drain + goal ticks only.
CRON_FLAG="--no-cron"
if [[ "${CRON:-0}" == "1" ]]; then CRON_FLAG=""; fi
if [[ -n "$DEST" ]]; then
  case "$DEST" in
    "${ROOT}"/*|"${TMPDIR:-/tmp}"/*|/tmp/*|/var/folders/*)
      mkdir -p "$DEST"
      rsync -a --delete \
        --exclude='__pycache__' \
        --exclude='*.pyc' \
        "${ROOT}/python/pong/" "${DEST}/pong/"
      PYTHONPATH_VAL="$DEST"
      echo "→ installed package to ${DEST}/pong (explicit DEST)"
      ;;
    *)
      echo "error: refusing DEST=${DEST} — must be inside ${ROOT} or a temp dir" >&2
      exit 2
      ;;
  esac
fi

mkdir -p "$PLIST_DIR" "${HOME}/.pong/logs"
LOG="${HOME}/.pong/logs/runtime.log"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${PYBIN}</string>
    <string>-m</string>
    <string>pong.cli.main</string>
    <string>runtime</string>
    <string>run</string>
    <string>--interval</string>
    <string>${INTERVAL}</string>
$( [[ -n "$CRON_FLAG" ]] && printf "    <string>%s</string>\n" "$CRON_FLAG" )  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PYTHONPATH</key>
    <string>${PYTHONPATH_VAL}</string>
    <key>PONG_HOME</key>
    <string>${HOME}/.pong</string>
    <key>PATH</key>
    <string>${PATH_VAL}</string>
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StartInterval</key>
  <integer>${INTERVAL}</integer>
  <key>StandardOutPath</key>
  <string>${LOG}</string>
  <key>StandardErrorPath</key>
  <string>${LOG}</string>
</dict>
</plist>
EOF

chmod 644 "$PLIST"
if command -v launchctl >/dev/null 2>&1; then
  launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null || launchctl load -w "$PLIST" || true
fi
echo "installed ${PLIST}"
echo "python=${PYBIN} cron=${CRON:-0} (${CRON_FLAG:-schedules fire})"
echo "PYTHONPATH=${PYTHONPATH_VAL}"
echo "PATH=${PATH_VAL}"
echo "log=${LOG}"
