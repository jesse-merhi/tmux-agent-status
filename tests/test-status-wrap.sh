#!/usr/bin/env bash
# Regression: an overflow split survives monitor shutdown instead of
# collapsing every window onto the first status row.
# shellcheck source=tests/require-modern-bash.sh
# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")" && pwd)/require-modern-bash.sh"
require_modern_bash "$@" || exit 1
set -euo pipefail

SOCK="agent-wrap-test-$$"
SCRIPT="$(cd "$(dirname "$0")/../scripts" && pwd)/agent-monitor.sh"
TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/agent-wrap-test.XXXXXX")"
MONITOR_PIDFILE="$TMPROOT/monitor.pid"
EVENTS_PIDFILE="$TMPROOT/events.pid"
MONITOR_PID=""

T() { command tmux -L "$SOCK" "$@"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok: %s\n' "$1"; }

cleanup() {
  if [[ -n "$MONITOR_PID" ]]; then
    kill "$MONITOR_PID" 2>/dev/null || true
    wait "$MONITOR_PID" 2>/dev/null || true
  fi
  if [[ -f "$EVENTS_PIDFILE" ]]; then
    kill "$(cat "$EVENTS_PIDFILE")" 2>/dev/null || true
  fi
  T kill-server 2>/dev/null || true
  rm -rf "$TMPROOT"
}
trap cleanup EXIT

wait_for_split() {
  local attempts=50 signature
  while ((attempts--)); do
    signature="$(T show-option -gqv @agent_wrap_rows 2>/dev/null)"
    if [[ "$signature" == '2|'*' 99999' && "$signature" != '2|99999' ]]; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

T -f /dev/null new-session -d -s t -x 80 -y 24 -n 'first deliberately long window'
for index in {2..11}; do
  T new-window -d -t t: -n "window $index with a deliberately long title"
done
T set-option -g status-left ' session '
T set-option -g status-right ' clock '
T set-option -g window-status-format ' #I:#W '
T set-option -g window-status-current-format ' #I:#W '
T set-option -g @agent_status_agents 'no-such-agent-process'
T set-option -g @agent_status_rename_windows off
T set-option -g @agent_status_min_lines 2
T set-option -g @agent_status_max_lines 2
socket_path="$(T display-message -p '#{socket_path}')"

TMUX="$socket_path,0,0" \
  AGENT_MONITOR_CLIENT_WIDTH_OVERRIDE=80 \
  AGENT_MONITOR_PIDFILE="$MONITOR_PIDFILE" \
  AGENT_EVENTS_PIDFILE="$EVENTS_PIDFILE" \
  "$SCRIPT" >/dev/null 2>&1 &
MONITOR_PID=$!

wait_for_split || fail "overflow never split: $(T show-option -gqv @agent_wrap_rows 2>/dev/null)"
signature="$(T show-option -gqv @agent_wrap_rows)"
[[ -n "$(T show-option -gqv 'status-format[1]')" ]] || fail 'second status row was empty'
pass "overflow split across two rows ($signature)"

kill "$MONITOR_PID"
wait "$MONITOR_PID" 2>/dev/null || true
MONITOR_PID=""
[[ "$(T show-option -gqv @agent_wrap_rows)" == "$signature" ]] || fail 'monitor shutdown collapsed the split'
[[ -n "$(T show-option -gqv 'status-format[1]')" ]] || fail 'monitor shutdown emptied the second row'
pass 'monitor shutdown preserved the last valid split'

printf 'ALL TESTS PASSED\n'
