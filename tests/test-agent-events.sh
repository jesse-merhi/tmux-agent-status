#!/usr/bin/env bash
# Behavior tests for agent-events.sh on a throwaway tmux server.
# Each test asserts externally visible state: the @agent_ready pane option.
# shellcheck source=tests/require-modern-bash.sh
source "$(cd "$(dirname "$0")" && pwd)/require-modern-bash.sh"
require_modern_bash "$@" || exit 1
set -u

SOCK="agent-events-test-$$"
SCRIPT="$(cd "$(dirname "$0")/../scripts" && pwd)/agent-events.sh"
LISTENER_PID=""
EVENTS_PIDFILE="/tmp/test-agent-events-$$.pid"

T() { command tmux -L "$SOCK" "$@"; }

# tmux 3.7 rejects command-client send-keys when this detached test server's
# only attached client is the listener's read-only client. A real session has
# a writable user client; toggle the listener only for the input injection,
# then immediately restore read-only and ignore-size.
send_keys() {
  local rc
  T send-keys "$@" 2>/dev/null && return 0
  T switch-client -r 2>/dev/null || return 1
  T send-keys "$@"
  rc=$?
  T switch-client -r 2>/dev/null || true
  return "$rc"
}

cleanup() {
  [ -n "$LISTENER_PID" ] && kill "$LISTENER_PID" 2>/dev/null
  T kill-server 2>/dev/null
  rm -f "$EVENTS_PIDFILE"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2 # stderr: never swallowed by a redirect
  exit 1
}
pass() { printf 'ok: %s\n' "$1"; }

now_ms() {
  local t="${EPOCHREALTIME/./}"
  printf '%s' "${t:0:13}"
}

# Poll a pane option until it equals $2; elapsed ms lands in $ELAPSED.
# Never call in a subshell: fail() must be able to stop the whole run.
wait_opt() { # pane want timeout_ms what
  local pane="$1" want="$2" timeout="$3" what="$4" start v
  start="$(now_ms)"
  while :; do
    v="$(T display -p -t "$pane" '#{@agent_ready}' 2>/dev/null)"
    if [ "$v" = "$want" ]; then
      ELAPSED="$(($(now_ms) - start))"
      return 0
    fi
    [ $(($(now_ms) - start)) -lt "$timeout" ] || fail "$what: @agent_ready=$v after ${timeout}ms (wanted $want)"
    sleep 0.05
  done
}

# A long-but-finite stream: a missed ^C can never wedge a later test.
# Expanded inside the throwaway pane, not by this test process.
# shellcheck disable=SC2016
stream_cmd='for i in $(seq 1 300); do echo stream-chunk; sleep 0.05; done'
stop_stream() { # pane
  send_keys -t "$1" C-c
  sleep 0.1
  send_keys -t "$1" C-c
}

[ -x "$SCRIPT" ] || fail "agent-events.sh missing or not executable at $SCRIPT"

T -f /dev/null new-session -d -s t -x 80 -y 24 bash || fail "scratch tmux server"
T set -g status off
agent_pane="$(T display -p -t t '#{pane_id}')"
T split-window -d -t t bash
plain_pane="$(T list-panes -t t -F '#{pane_id}' | grep -v "$agent_pane")"
T set-option -p -t "$agent_pane" @agent_icon '✳'

# Grace must be >3: the stamp is integer seconds, so an N-second grace
# holds for N-1..N real seconds and the in-grace check happens at +2.2s.
AGENT_EVENTS_SOCKET="$SOCK" AGENT_EVENTS_PIDFILE="$EVENTS_PIDFILE" \
  AGENT_READY_AGE=2 AGENT_HOOK_GRACE=4 AGENT_INPUT_MIN_READY=2 "$SCRIPT" t &
LISTENER_PID=$!

# Listener publishes its owned session once attached and scanned.
start="$(now_ms)"
until [ "$(T display -p '#{@agent_events}' 2>/dev/null)" = t ]; do
  [ $(($(now_ms) - start)) -lt 5000 ] || fail "listener never published @agent_events=t"
  sleep 0.05
done
pass "listener attached and published its session"

# 1. Silent agent pane becomes ready after READY_AGE.
wait_opt "$agent_pane" 1 4000 "initial silence -> ready"
pass "silent agent pane flipped ready"

# 2. Streaming output flips busy fast (<1000ms after output starts).
send_keys -t "$agent_pane" "$stream_cmd" Enter
wait_opt "$agent_pane" 0 3000 'stream -> busy'
pass "streaming pane flipped busy in ${ELAPSED}ms"
[ "$ELAPSED" -lt 1000 ] || fail "busy flip took ${ELAPSED}ms (want <1000)"
pass "busy flip under 1s"

# 3. Silence after the stream flips ready again within READY_AGE + slack.
stop_stream "$agent_pane"
sleep 0.3 # let the ^C echo and prompt redraw settle before timing silence
wait_opt "$agent_pane" 1 6000 'silence -> ready'
pass "silent-again pane flipped ready in ${ELAPSED}ms"

# 4. A pending background task holds busy through a silence window; once
# the lifecycle hook clears the hold, the already-silent pane becomes ready.
T set-option -p -t "$agent_pane" @agent_pending 1
T set-option -p -t "$agent_pane" @agent_ready 0
T set-option -p -t "$agent_pane" @agent_state_ts "$(date +%s)"
sleep 5 # exceeds HOOK_GRACE and READY_AGE, including subscription delivery
v="$(T display -p -t "$agent_pane" '#{@agent_ready}' 2>/dev/null)"
[ "$v" = 0 ] || fail "pending hold ignored: @agent_ready=$v after silence"
pass "pending pane stayed busy through silence"
T set-option -p -t "$agent_pane" -u @agent_pending
wait_opt "$agent_pane" 1 3000 'cleared pending -> ready'
pass "pane flipped ready after pending hold cleared"

# 5. Non-agent pane streaming is ignored.
send_keys -t "$plain_pane" 'for i in 1 2 3 4 5 6 7 8 9 10; do echo plain-noise; sleep 0.05; done' Enter
sleep 1.5
v="$(T display -p -t "$plain_pane" '#{@agent_ready}' 2>/dev/null)"
if [ -z "$v" ]; then
  pass "non-agent pane untouched"
else
  fail "non-agent pane got @agent_ready=$v"
fi

# 6. A fresh hook stamp wins over output events for HOOK_GRACE seconds.
T set-option -p -t "$agent_pane" @agent_state_ts "$(date +%s)"
T set-option -p -t "$agent_pane" @agent_ready 1
sleep 1.2 # subscription delivery is at most once a second
send_keys -t "$agent_pane" "$stream_cmd" Enter
sleep 1
v="$(T display -p -t "$agent_pane" '#{@agent_ready}' 2>/dev/null)"
[ "$v" = 1 ] || fail "hook grace ignored: @agent_ready=$v while grace active"
pass "hook stamp held ready through streaming output"
wait_opt "$agent_pane" 0 4000 'post-grace stream -> busy'
pass "busy resumed ${ELAPSED}ms after grace check"
stop_stream "$agent_pane"

# 7. A pane that gains @agent_icon after startup gets managed.
T set-option -p -t "$plain_pane" @agent_icon '⬢'
sleep 1.2 # subscription delivery
send_keys -t "$plain_pane" "$stream_cmd" Enter
wait_opt "$plain_pane" 0 3000 'late agent -> busy'
pass "late-tagged pane flipped busy in ${ELAPSED}ms"
stop_stream "$plain_pane"

# 8. A pane that loses @agent_icon is forgotten: no further state writes.
T set-option -p -t "$plain_pane" -u @agent_icon
sleep 1.2 # subscription delivery
T set-option -p -t "$plain_pane" -u @agent_ready # as discovery cleanup would
send_keys -t "$plain_pane" 'for i in 1 2 3 4 5 6 7 8 9 10; do echo untracked; sleep 0.05; done' Enter
sleep 1.5
v="$(T display -p -t "$plain_pane" '#{@agent_ready}' 2>/dev/null)"
if [ -z "$v" ]; then
  pass "untagged pane forgotten"
else
  fail "untagged pane got @agent_ready=$v"
fi

# 9. A ready spell (>= INPUT_MIN_READY) followed by output counts one
# user input; a brief mid-turn ready blip does not.
wait_opt "$agent_pane" 1 8000 'pre-input settle -> ready'
sleep 2.2 # exceed INPUT_MIN_READY: the next stream is a "user input"
base="$(T display -p -t "$agent_pane" '#{@agent_inputs}' 2>/dev/null)"
base="${base:-0}"
send_keys -t "$agent_pane" 'for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do echo turn-output; sleep 0.05; done' Enter
wait_opt "$agent_pane" 0 3000 'input -> busy'
v="$(T display -p -t "$agent_pane" '#{@agent_inputs}' 2>/dev/null)"
if [ "$v" = "$((base + 1))" ]; then
  pass "input counted ($base -> $v)"
else
  fail "@agent_inputs=$v after input from $base"
fi

wait_opt "$agent_pane" 1 6000 'turn end -> ready'
# Immediately stream again: ready spell far below INPUT_MIN_READY = a
# mid-turn blip (long tool call), not a new instruction.
send_keys -t "$agent_pane" 'for i in 1 2 3 4 5 6 7 8 9 10; do echo blip-output; sleep 0.05; done' Enter
wait_opt "$agent_pane" 0 3000 'blip -> busy'
v="$(T display -p -t "$agent_pane" '#{@agent_inputs}' 2>/dev/null)"
if [ "$v" = "$((base + 1))" ]; then
  pass "mid-turn blip not counted"
else
  fail "@agent_inputs=$v after blip (want $((base + 1)))"
fi
wait_opt "$agent_pane" 1 6000 'blip turn end -> ready'

# 10. Claude's own "Working (... esc to interrupt)" line pins a pane busy
# through silence. A long thinking spell or tool call emits no output, so
# the silence heuristic alone calls the pane ready in the middle of a turn.
send_keys -t "$agent_pane" 'clear; printf "Working (12s · esc to interrupt)\n"' Enter
wait_opt "$agent_pane" 0 3000 'marker output -> busy'
sleep 4 # well past READY_AGE: silence alone would have flipped ready
v="$(T display -p -t "$agent_pane" '#{@agent_ready}' 2>/dev/null)"
[ "$v" = 0 ] || fail "working marker ignored: @agent_ready=$v after silence"
pass "working marker held busy through silence"

# Marker gone: the pane is a normal silent pane again.
send_keys -t "$agent_pane" clear Enter
wait_opt "$agent_pane" 1 6000 'marker cleared -> ready'
pass "pane flipped ready once the marker cleared"

# 11. SIGTERM'd listener takes its control-mode client with it (a bare
# TERM skips bash EXIT traps; this once orphaned a client for 10 hours).
kill "$LISTENER_PID"
start="$(now_ms)"
while [ "$(T list-clients -F '#{client_flags}' 2>/dev/null | grep -c control-mode)" != 0 ]; do
  [ $(($(now_ms) - start)) -lt 4000 ] || fail "control client survived listener SIGTERM"
  sleep 0.1
done
pass "SIGTERM cleaned up the control client"
[ -f "$EVENTS_PIDFILE" ] && fail "pidfile survived SIGTERM"
pass "pidfile removed on SIGTERM"

AGENT_EVENTS_SOCKET="$SOCK" AGENT_EVENTS_PIDFILE="$EVENTS_PIDFILE" \
  AGENT_READY_AGE=2 AGENT_HOOK_GRACE=4 "$SCRIPT" t &
LISTENER_PID=$!
start="$(now_ms)"
until [ "$(T display -p '#{@agent_events}' 2>/dev/null)" = t ]; do
  [ $(($(now_ms) - start)) -lt 5000 ] || fail "listener did not come back after restart"
  sleep 0.05
done
pass "listener restarted cleanly"

# 12. Listener exits when the tmux server dies (no orphan daemon).
T kill-server 2>/dev/null
start="$(now_ms)"
while kill -0 "$LISTENER_PID" 2>/dev/null; do
  [ $(($(now_ms) - start)) -lt 5000 ] || fail "listener still alive 5s after kill-server"
  sleep 0.1
done
pass "listener exited after kill-server"
LISTENER_PID=""

printf 'ALL TESTS PASSED\n'
