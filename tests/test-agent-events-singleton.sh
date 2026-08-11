#!/usr/bin/env bash
# A missing pidfile must not let a second listener attach to the same server.
# shellcheck source=tests/require-modern-bash.sh
source "$(cd "$(dirname "$0")" && pwd)/require-modern-bash.sh"
require_modern_bash "$@" || exit 1
set -u

SOCK="agent-events-singleton-test-$$"
SCRIPT="$(cd "$(dirname "$0")/../scripts" && pwd)/agent-events.sh"
EVENTS_PIDFILE="/tmp/test-agent-events-singleton-$$.pid"
LISTENER_PIDS=()

T() { command tmux -L "$SOCK" "$@"; }

cleanup() {
  local pid
  for pid in "${LISTENER_PIDS[@]:-}"; do
    kill "$pid" 2>/dev/null || true
  done
  T kill-server 2>/dev/null || true
  rm -f "$EVENTS_PIDFILE"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}
pass() { printf 'ok: %s\n' "$1"; }

now_ms() {
  local t="${EPOCHREALTIME/./}"
  printf '%s' "${t:0:13}"
}

control_clients() {
  T list-clients -F '#{client_control_mode}' 2>/dev/null | grep -cx 1 || true
}

start_listener() {
  AGENT_EVENTS_SOCKET="$SOCK" AGENT_EVENTS_PIDFILE="$EVENTS_PIDFILE" "$SCRIPT" t &
  STARTED_PID=$!
  LISTENER_PIDS+=("$STARTED_PID")
}

wait_for_first_listener() {
  local start
  start="$(now_ms)"
  until [ "$(control_clients)" = 1 ] && [ -s "$EVENTS_PIDFILE" ] &&
    [ -n "$(T show-option -gqv @agent_events_pid 2>/dev/null)" ]; do
    [ $(( $(now_ms) - start )) -lt 5000 ] || fail 'first listener did not attach'
    sleep 0.05
  done
}

wait_for_duplicate_result() { # candidate pid
  local candidate="$1" start
  start="$(now_ms)"
  while kill -0 "$candidate" 2>/dev/null && [ "$(control_clients)" -lt 2 ]; do
    [ $(( $(now_ms) - start )) -lt 5000 ] || break
    sleep 0.05
  done
}

T -f /dev/null new-session -d -s t -x 80 -y 24 bash || fail 'scratch tmux server'
T set -g status off
T set-option -p -t t @agent_icon '✳'

for _ in {1..16}; do
  start_listener
done
wait_for_first_listener
sleep 0.5
count="$(control_clients)"
[ "$count" = 1 ] || fail "concurrent launch created $count control clients"
first_pid="$(T show-option -gqv @agent_events_pid)"
kill -0 "$first_pid" 2>/dev/null || fail 'published listener owner is not alive'
pass 'concurrent launch produced one listener'

# Reproduce the live failure: an older listener cleanup removed the shared
# pidfile while the original listener and its control client remained alive.
rm -f "$EVENTS_PIDFILE"
start_listener
second_pid="$STARTED_PID"
wait_for_duplicate_result "$second_pid"

count="$(control_clients)"
[ "$count" = 1 ] || fail "missing pidfile created $count control clients"
kill -0 "$first_pid" 2>/dev/null || fail 'original listener exited'
if kill -0 "$second_pid" 2>/dev/null; then
  fail 'second listener remained alive'
fi
pass 'missing pidfile did not create a second listener'

owner="$(T show-option -gqv @agent_events_pid 2>/dev/null)"
[ "$owner" = "$first_pid" ] || fail "server owner is $owner, want $first_pid"
pass 'tmux server retained the original listener owner'

printf 'ALL TESTS PASSED\n'
