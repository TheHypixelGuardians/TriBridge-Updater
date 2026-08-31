#!/usr/bin/env bash
#
# TriBridge weekly auto-update.
#
#   ./update.sh            fetch, and only restart if there are new commits
#   ./update.sh start      start the bot
#   ./update.sh stop       stop the bot
#   ./update.sh restart    stop and start the bot
#   ./update.sh status     show state, paths and the cron line
#
# TRIBRIDGE_DIR must point at the bot's checkout. See README.md.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"

# The bot's checkout. This script lives in its own repository, so it cannot
# infer the location — set TRIBRIDGE_DIR in the cron line or the environment.
REPO_DIR="${TRIBRIDGE_DIR:-}"

# Set this if node is not on cron's PATH and nvm is not being used, e.g.
# NODE_BIN=/usr/local/bin/node. Can also be exported alongside TRIBRIDGE_DIR.
NODE_BIN="${NODE_BIN:-}"

# All state stays beside this script, so the bot's checkout is never written to
# and a pull can never conflict with anything here.
PID_FILE="$SCRIPT_DIR/.bot.pid"
LOCK_FILE="$SCRIPT_DIR/.update.lock"
LOG_DIR="$SCRIPT_DIR/logs"
UPDATE_LOG="$LOG_DIR/update.log"
BOT_LOG="$LOG_DIR/bot.log"

# Seconds to wait for a clean shutdown before SIGKILL, and how long to watch a
# freshly started bot before calling the start a success.
STOP_TIMEOUT=15
HEALTH_WAIT=5

# Bytes. The log is halved once it grows past this.
MAX_LOG_BYTES=$((2 * 1024 * 1024))

mkdir -p "$LOG_DIR"

log() {
  printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$UPDATE_LOG"
}

die() {
  log "ERROR: $*"
  exit 1
}

resolve_repo() {
  [ -n "$REPO_DIR" ] ||
    die "TRIBRIDGE_DIR is not set. Point it at the bot's checkout, e.g. TRIBRIDGE_DIR=/home/bot/TriBridge"
  [ -d "$REPO_DIR" ] || die "TRIBRIDGE_DIR points at $REPO_DIR, which does not exist."
  REPO_DIR="$(cd "$REPO_DIR" && pwd)"
  ENTRY="$REPO_DIR/src/index.js"
  [ -f "$ENTRY" ] ||
    die "$REPO_DIR does not look like a TriBridge checkout: no src/index.js in it."
}

rotate_log() {
  [ -f "$UPDATE_LOG" ] || return 0
  local size
  size=$(wc -c <"$UPDATE_LOG")
  if [ "$size" -gt "$MAX_LOG_BYTES" ]; then
    tail -c $((MAX_LOG_BYTES / 2)) "$UPDATE_LOG" >"$UPDATE_LOG.tmp"
    mv "$UPDATE_LOG.tmp" "$UPDATE_LOG"
  fi
}

# One run at a time: a slow update must never be overlapped by the next cron
# tick, which could restart the bot mid-pull. The lock is held on fd 9 rather
# than by wrapping the script in `flock <file> <command>`, because the bot is
# started as a background child and would inherit the descriptor — holding the
# lock for as long as it runs, which means forever.
acquire_lock() {
  command -v flock >/dev/null 2>&1 || return 0
  exec 9>"$LOCK_FILE" || die "Could not open $LOCK_FILE."
  if ! flock -n 9; then
    log "Another run is still in progress; skipping this one."
    exit 0
  fi
}

# cron runs with a minimal PATH, so a node installed by nvm — the common case —
# is invisible here even though it works fine in an interactive shell.
resolve_node() {
  if [ -n "$NODE_BIN" ]; then
    [ -x "$NODE_BIN" ] || die "NODE_BIN is set to $NODE_BIN but that is not executable."
    PATH="$(dirname "$NODE_BIN"):$PATH"
    export PATH
    return 0
  fi

  if ! command -v node >/dev/null 2>&1; then
    local nvm_sh="${NVM_DIR:-$HOME/.nvm}/nvm.sh"
    if [ -s "$nvm_sh" ]; then
      # nvm.sh is not written for `set -u`.
      set +u
      # shellcheck disable=SC1090
      . "$nvm_sh"
      set -u
    fi
  fi

  command -v node >/dev/null 2>&1 ||
    die "node was not found. Set NODE_BIN to its full path."
}

# The pid in the file is only trustworthy if the process behind it is still this
# checkout's bot — pids are recycled, and signalling a stranger is worse than
# doing nothing.
running_pid() {
  [ -f "$PID_FILE" ] || return 1
  local pid args
  pid="$(cat "$PID_FILE" 2>/dev/null || true)"
  case "$pid" in
    "" | *[!0-9]*) return 1 ;;
  esac
  kill -0 "$pid" 2>/dev/null || return 1
  args="$(ps -p "$pid" -o args= 2>/dev/null || true)"
  case "$args" in
    *"$ENTRY"*) ;;
    *) return 1 ;;
  esac
  printf '%s' "$pid"
}

start_bot() {
  local pid
  if pid="$(running_pid)"; then
    log "Bot is already running (pid $pid)."
    return 0
  fi

  resolve_node
  cd "$REPO_DIR"
  # 9>&- so the bot does not inherit, and keep alive, this run's lock.
  nohup node "$ENTRY" >>"$BOT_LOG" 2>&1 9>&- &
  pid=$!
  printf '%s\n' "$pid" >"$PID_FILE"
  log "Started the bot (pid $pid), logging to $BOT_LOG."

  sleep "$HEALTH_WAIT"
  if ! running_pid >/dev/null; then
    rm -f "$PID_FILE"
    log "The bot exited within ${HEALTH_WAIT}s of starting. Last lines of $BOT_LOG:"
    tail -n 20 "$BOT_LOG" | tee -a "$UPDATE_LOG"
    return 1
  fi
  log "The bot is still up after ${HEALTH_WAIT}s."
}

stop_bot() {
  local pid
  if ! pid="$(running_pid)"; then
    rm -f "$PID_FILE"
    log "The bot is not running."
    return 0
  fi

  log "Stopping the bot (pid $pid)."
  kill -TERM "$pid" 2>/dev/null || true

  local waited=0
  while [ "$waited" -lt "$STOP_TIMEOUT" ] && kill -0 "$pid" 2>/dev/null; do
    sleep 1
    waited=$((waited + 1))
  done

  if kill -0 "$pid" 2>/dev/null; then
    log "It did not exit within ${STOP_TIMEOUT}s; sending SIGKILL."
    kill -KILL "$pid" 2>/dev/null || true
    sleep 1
  fi

  rm -f "$PID_FILE"
  log "Stopped."
}

restart_bot() {
  stop_bot
  start_bot
}

# git refuses to work in a repository owned by another user, which is easy to
# hit when cron runs as root against a checkout owned by someone else.
run_git() {
  local output status
  set +e
  output="$(git -C "$REPO_DIR" "$@" 2>&1)"
  status=$?
  set -e
  # Only failures reach the log; successful rev-parse output is just a hash and
  # the narrative is carried by the explicit log() calls.
  if [ "$status" -ne 0 ] && [ -n "$output" ]; then
    printf '%s\n' "$output" >>"$UPDATE_LOG"
  fi
  if [ "$status" -ne 0 ] && printf '%s' "$output" | grep -q "dubious ownership"; then
    log "git refuses to read the bot's checkout because it is owned by another user."
    die "Run: git config --global --add safe.directory $REPO_DIR"
  fi
  printf '%s' "$output"
  return "$status"
}

check_and_update() {
  git -C "$REPO_DIR" rev-parse --git-dir >/dev/null 2>&1 ||
    die "$REPO_DIR is not a git repository."

  local branch upstream
  branch="$(run_git rev-parse --abbrev-ref HEAD)" ||
    die "Could not read the current branch."
  # Whichever remote this branch actually tracks — the checkout may have more
  # than one, and a hardcoded origin/master would silently follow the wrong one.
  upstream="$(run_git rev-parse --abbrev-ref '@{u}' 2>/dev/null)" ||
    die "Branch $branch tracks no upstream. Set one with: git branch --set-upstream-to=origin/$branch"

  log "Checking $branch against $upstream."
  run_git fetch --prune "${upstream%%/*}" >/dev/null ||
    die "git fetch failed. See $UPDATE_LOG."

  local before after
  before="$(run_git rev-parse HEAD)" || die "Could not read the local commit."
  after="$(run_git rev-parse "$upstream")" || die "Could not read $upstream after fetching."

  if [ "$before" = "$after" ]; then
    log "Already up to date at ${before:0:8}. The bot was left alone."
    return 0
  fi

  log "New commits: ${before:0:8} -> ${after:0:8}. Pulling."
  run_git pull --ff-only >/dev/null || {
    log "A fast-forward is not possible — the checkout has diverged from $upstream."
    die "Resolve it by hand in $REPO_DIR. The bot was left running."
  }

  local changed
  changed="$(run_git diff --name-only "$before" "$after" -- package.json package-lock.json)"
  if [ -n "$changed" ]; then
    log "Dependency manifests changed; running npm install."
    resolve_node
    (cd "$REPO_DIR" && npm install --omit=dev >>"$UPDATE_LOG" 2>&1) ||
      die "npm install failed. See $UPDATE_LOG. The bot was left running on the old code."
  else
    log "No dependency changes; skipping npm install."
  fi

  restart_bot
  log "Update complete, now at ${after:0:8}."
}

show_status() {
  local pid
  if pid="$(running_pid)"; then
    printf 'Bot:      running (pid %s)\n' "$pid"
  else
    printf 'Bot:      not running\n'
  fi
  printf 'Bot repo: %s\n' "$REPO_DIR"
  printf 'Commit:   %s\n' "$(git -C "$REPO_DIR" log -1 --format='%h %s' 2>/dev/null || echo 'unknown')"
  printf 'Bot log:  %s\n' "$BOT_LOG"
  printf 'Run log:  %s\n' "$UPDATE_LOG"
  printf '\nWeekly cron entry (crontab -e), Sundays at 05:00:\n'
  # Quoted, because cron hands the line to sh and a path with a space in it
  # would otherwise split into a command and a stray argument.
  printf '  0 5 * * 0 TRIBRIDGE_DIR="%s" "%s/update.sh" >> "%s/cron.log" 2>&1\n' \
    "$REPO_DIR" "$SCRIPT_DIR" "$LOG_DIR"
}

main() {
  case "${1:-check}" in
    check) rotate_log && check_and_update ;;
    start) start_bot ;;
    stop) stop_bot ;;
    restart) restart_bot ;;
    status) show_status ;;
    *)
      printf 'Usage: %s [check|start|stop|restart|status]\n' "$(basename "$0")" >&2
      exit 2
      ;;
  esac
}

resolve_repo

if [ "${1:-check}" != "status" ]; then
  acquire_lock
fi

main "$@"
