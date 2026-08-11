#!/usr/bin/env bash
# Behavior tests for agent-attention.sh on a throwaway tmux server.
# Each test asserts the pane options observed by the status-line renderers.
# shellcheck source=tests/require-modern-bash.sh
source "$(cd "$(dirname "$0")" && pwd)/require-modern-bash.sh"
require_modern_bash "$@" || exit 1
set -u

SOCK="agent-attention-test-$$"
SCRIPT="$(cd "$(dirname "$0")/../scripts" && pwd)/agent-attention.sh"
TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/agent-attention-test.XXXXXX")"
MONITOR_PIDFILE="/tmp/test-agent-attention-monitor-$$.pid"
EVENTS_PIDFILE="/tmp/test-agent-attention-events-$$.pid"
WRITER_PID=""

T() { command tmux -L "$SOCK" "$@"; }

cleanup() {
  [ -n "$WRITER_PID" ] && kill "$WRITER_PID" 2>/dev/null
  [ -f "$MONITOR_PIDFILE" ] && kill "$(cat "$MONITOR_PIDFILE")" 2>/dev/null
  [ -f "$EVENTS_PIDFILE" ] && kill "$(cat "$EVENTS_PIDFILE")" 2>/dev/null
  T kill-server 2>/dev/null
  rm -f "$MONITOR_PIDFILE" "$EVENTS_PIDFILE"
  rm -rf "$MONITOR_PIDFILE.lock" "$TMPROOT"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}
pass() { printf 'ok: %s\n' "$1"; }

opt() { T display -p -t "$pane" "#{@$1}" 2>/dev/null; }

run_attention() {
  TMUX="$socket_path,0,0" \
    TMUX_PANE="$pane" \
    AGENT_TASKS_ROOT="$TMPROOT" \
    AGENT_EVENTS_SOCKET="$SOCK" \
    AGENT_MONITOR_PIDFILE="$MONITOR_PIDFILE" \
    AGENT_MONITOR_LOCKDIR="$MONITOR_PIDFILE.lock" \
    AGENT_EVENTS_PIDFILE="$EVENTS_PIDFILE" \
    "$SCRIPT" "$@"
}

[ -x "$SCRIPT" ] || fail "agent-attention.sh missing or not executable at $SCRIPT"

T -f /dev/null new-session -d -s t -x 80 -y 24 bash || fail "scratch tmux server"
pane="$(T display -p -t t '#{pane_id}')"
socket_path="$(T display -p '#{socket_path}')"
sid='11111111-2222-3333-4444-555555555555'

run_attention pending '✳' "$sid"
[ "$(opt agent_ready)" = 0 ] || fail "pending set @agent_ready=$(opt agent_ready)"
[ "$(opt agent_pending)" = "$sid" ] || fail "pending set @agent_pending=$(opt agent_pending)"
pass "pending set busy state and session hold"

run_attention ready '✳'
[ "$(opt agent_ready)" = 1 ] || fail "ready set @agent_ready=$(opt agent_ready)"
[ -z "$(opt agent_pending)" ] || fail "ready left @agent_pending=$(opt agent_pending)"
pass "ready cleared pending hold"

run_attention pending '✳' "$sid"
printf '{"session_id":"%s"}\n' "$sid" | run_attention claude-stop '✳'
[ "$(opt agent_ready)" = 1 ] || fail "claude-stop without task set @agent_ready=$(opt agent_ready)"
[ -z "$(opt agent_pending)" ] || fail "claude-stop without task left @agent_pending=$(opt agent_pending)"
pass "claude-stop without running tasks became ready"

task_file="$TMPROOT/x/$sid/tasks/f.output"
mkdir -p "${task_file%/*}"
sleep 30 >"$task_file" 2>&1 &
WRITER_PID=$!
sleep 0.1 # let sleep inherit the redirected stdout/stderr before lsof runs
printf '{"session_id":"%s"}\n' "$sid" | run_attention claude-stop '✳'
[ "$(opt agent_ready)" = 0 ] || fail "claude-stop with task set @agent_ready=$(opt agent_ready)"
[ "$(opt agent_pending)" = "$sid" ] || fail "claude-stop with task set @agent_pending=$(opt agent_pending)"
pass "claude-stop with running task held busy"

# A read-only holder (tail -f over an old task's output) is not a running
# task: only write-mode opens may hold the session pending.
kill "$WRITER_PID" 2>/dev/null
wait "$WRITER_PID" 2>/dev/null
tail -f "$task_file" >/dev/null 2>&1 &
WRITER_PID=$!
sleep 0.1
printf '{"session_id":"%s"}\n' "$sid" | run_attention claude-stop '✳'
[ "$(opt agent_ready)" = 1 ] || fail "claude-stop with reader set @agent_ready=$(opt agent_ready)"
[ -z "$(opt agent_pending)" ] || fail "claude-stop with reader left @agent_pending=$(opt agent_pending)"
pass "read-only holder did not hold busy"

printf 'ALL TESTS PASSED\n'
