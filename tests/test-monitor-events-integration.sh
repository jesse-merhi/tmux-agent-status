#!/usr/bin/env bash
# Integration: agent-monitor.sh discovers a (fake) agent, starts
# agent-events.sh, leaves state flips to it, keeps headless animation idle,
# and recovers either monitor. Runs on a throwaway tmux server;
# the production monitor/listener are untouched (pidfile overrides).
# shellcheck source=tests/require-modern-bash.sh
source "$(cd "$(dirname "$0")" && pwd)/require-modern-bash.sh"
require_modern_bash "$@" || exit 1
set -u

SOCK="monitor-int-test-$$"
SCRIPTS="$(cd "$(dirname "$0")/../scripts" && pwd)"
MONITOR_PIDFILE="/tmp/test-agent-monitor-$$.pid"
EVENTS_PIDFILE="/tmp/test-agent-events-$$.pid"
MONITOR_PID=""
SECOND_MONITOR_PID=""

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
  [ -f "$MONITOR_PIDFILE" ] && kill "$(cat "$MONITOR_PIDFILE")" 2>/dev/null
  [ -n "$MONITOR_PID" ] && kill "$MONITOR_PID" 2>/dev/null
  [ -n "$SECOND_MONITOR_PID" ] && kill "$SECOND_MONITOR_PID" 2>/dev/null
  [ -f "$EVENTS_PIDFILE" ] && kill "$(cat "$EVENTS_PIDFILE")" 2>/dev/null
  T kill-server 2>/dev/null
  rm -f "$MONITOR_PIDFILE" "$EVENTS_PIDFILE"
  rm -rf "$MONITOR_PIDFILE.lock"
  rm -rf "$TEST_ROOT"
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

wait_for() { # timeout_ms what check...
  local timeout="$1" what="$2" start
  shift 2
  start="$(now_ms)"
  until "$@"; do
    [ $(($(now_ms) - start)) -lt "$timeout" ] || fail "$what (timed out after ${timeout}ms)"
    sleep 0.1
  done
}

events_listener_alive() {
  [ -f "$EVENTS_PIDFILE" ] && kill -0 "$(cat "$EVENTS_PIDFILE" 2>/dev/null)" 2>/dev/null
}
pane_ready_is() { [ "$(T display -p -t "$1" '#{@agent_ready}' 2>/dev/null)" = "$2" ]; }
headless_pane_ready() {
  [ -z "$(T display -p '#{@agent_pulse}')" ] || fail "animated a server without a visible client"
  pane_ready_is "$1" 1
}

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/agent-monitor-integration.XXXXXX")"
mkdir -p "$TEST_ROOT/first-task" "$TEST_ROOT/active-task" "$TEST_ROOT/empty-active"
cat >"$TEST_ROOT/label.sh" <<'EOF'
#!/usr/bin/env bash
[ "$(basename "$3")" = empty-active ] && exit 0
basename "$3"
EOF
chmod +x "$TEST_ROOT/label.sh"

# A pane whose process argv[0] is "claude": discovery sees a real agent
# (claude also keeps window_label off the ollama path).
# Each input line is answered with five spaced output chunks, enough to
# cross the listener's chunks-per-window busy threshold.
# Expanded inside the fake agent process, not by this test process.
# shellcheck disable=SC2016
T -f /dev/null new-session -d -s t -x 80 -y 24 \
  -c "$TEST_ROOT/first-task" \
  bash -c 'exec -a claude bash -c "while read -r l; do for i in 1 2 3 4 5; do echo \"\$l-\$i\"; sleep 0.05; done; done"' ||
  fail "scratch tmux server"
first_pane="$(T display -p -t t '#{pane_id}')"
# shellcheck disable=SC2016
second_pane="$(T split-window -d -P -F '#{pane_id}' -t t -c "$TEST_ROOT/active-task" \
  bash -c 'exec -a claude bash -c "while read -r l; do for i in 1 2 3 4 5; do echo \"\$l-\$i\"; sleep 0.05; done; done"')" ||
  fail "second fake agent pane"
T select-pane -t "$second_pane"
T set -g status off
T set -g @agent_status_rename_manual_windows on
T set -g @agent_status_label_command "$TEST_ROOT/label.sh"
agent_pane="$(T display -p -t t '#{pane_id}')"
socket_path="$(T display -p '#{socket_path}')"

TMUX="$socket_path,0,0" \
  AGENT_MONITOR_PIDFILE="$MONITOR_PIDFILE" \
  AGENT_EVENTS_PIDFILE="$EVENTS_PIDFILE" \
  AGENT_READY_AGE=2 \
  "$SCRIPTS/agent-monitor.sh" >/dev/null 2>&1 &
MONITOR_PID=$!

# 1. Discovery tags the pane and starts the events listener.
wait_for 13000 "discovery never tagged the fake claude pane" \
  bash -c "[ \"\$(tmux -L $SOCK display -p -t $agent_pane '#{@agent_icon}' 2>/dev/null)\" = '✳' ]"
pass "discovery tagged fake claude pane"
wait_for 13000 "window did not use the active agent pane label" \
  bash -c "[ \"\$(tmux -L $SOCK display -p -t t '#{window_name}' 2>/dev/null)\" = 'active-task' ]"
pass "active agent pane names its window"
T select-pane -t "$first_pane"
wait_for 13000 "window did not follow the newly active agent pane" \
  bash -c "[ \"\$(tmux -L $SOCK display -p -t t '#{window_name}' 2>/dev/null)\" = 'first-task' ]"
pass "window follows active agent pane changes"
T select-pane -t "$second_pane"
wait_for 13000 "window did not follow the restored active agent pane" \
  bash -c "[ \"\$(tmux -L $SOCK display -p -t t '#{window_name}' 2>/dev/null)\" = 'active-task' ]"
pass "window follows active agent pane restoration"

# An active pane without a useful label must not replace a real task label
# already supplied by another agent pane with its directory fallback.
# shellcheck disable=SC2016
empty_pane="$(T split-window -d -P -F '#{pane_id}' -t t -c "$TEST_ROOT/empty-active" \
  bash -c 'exec -a claude cat')" ||
  fail "empty-label fake agent pane"
T select-pane -t "$empty_pane"
wait_for 13000 "discovery never tagged the empty-label agent pane" \
  bash -c "[ -n \"\$(tmux -L $SOCK display -p -t $empty_pane '#{@agent_icon}' 2>/dev/null)\" ]"
wait_for 13000 "empty active pane overwrote a real task label" \
  bash -c "[ \"\$(tmux -L $SOCK display -p -t t '#{window_name}' 2>/dev/null)\" = 'first-task' ]"
pass "empty active pane preserves another pane's real task label"
T select-pane -t "$second_pane"
wait_for 13000 "window did not restore the labeled active pane" \
  bash -c "[ \"\$(tmux -L $SOCK display -p -t t '#{window_name}' 2>/dev/null)\" = 'active-task' ]"
T kill-pane -t "$empty_pane"
wait_for 5000 "monitor never started agent-events.sh" events_listener_alive
pass "monitor started the events listener"

# 2. The monitor is a singleton; a second copy must exit instead of
# overwriting the pidfile and fighting over window names.
TMUX="$socket_path,0,0" \
  AGENT_MONITOR_PIDFILE="$MONITOR_PIDFILE" \
  AGENT_EVENTS_PIDFILE="$EVENTS_PIDFILE" \
  "$SCRIPTS/agent-monitor.sh" >/dev/null 2>&1 &
SECOND_MONITOR_PID=$!
monitor_exited() { ! kill -0 "$1" 2>/dev/null; }
wait_for 5000 "duplicate monitor stayed alive" monitor_exited "$SECOND_MONITOR_PID"
wait "$SECOND_MONITOR_PID" 2>/dev/null || true
[ "$(cat "$MONITOR_PIDFILE" 2>/dev/null)" = "$MONITOR_PID" ] ||
  fail "duplicate monitor overwrote pidfile"
pass "duplicate monitor refused"

# 3. Restored agent windows can be reclaimed after tmux-resurrect brings
# them back with automatic-rename=off and without @agent_named.
T rename-window -t t 'restored stale title'
T set-option -w -t t -u @agent_named
wait_for 13000 "manual/restored agent window was not reclaimed" \
  bash -c "[ \"\$(tmux -L $SOCK display -p -t t '#{window_name}|#{@agent_named}' 2>/dev/null)\" != 'restored stale title|' ]"
pass "manual/restored agent window reclaimed"

# 4. A per-window lock still preserves an intentional manual name.
T rename-window -t t 'locked manual title'
T set-option -w -t t -u @agent_named
T set-option -w -t t @agent_rename_lock 1
sleep 12
name="$(T display -p -t t '#{window_name}' 2>/dev/null)"
[ "$name" = 'locked manual title' ] || fail "locked manual name changed to '$name'"
T set-option -w -t t -u @agent_rename_lock
pass "rename lock preserves manual window name"

# 5. Output flips busy fast. This server has only control clients, so the
# painter stays idle until a user actually attaches a terminal.
send_keys -t "$agent_pane" 'stream-1 stream-2 stream-3 stream-4 stream-5' Enter
wait_for 2000 "pane never flipped busy on output" pane_ready_is "$agent_pane" 0
pass "event-driven busy flip"

# 6. Silence flips ready.
wait_for 6000 "pane never flipped ready after silence" headless_pane_ready "$agent_pane"
pass "event-driven ready flip"
pass "headless server has no animation work"

# 7. A dead listener is restarted by the next discovery pass.
kill "$(cat "$EVENTS_PIDFILE")" 2>/dev/null
sleep 0.3
wait_for 13000 "monitor never restarted a dead listener" events_listener_alive
pass "dead listener restarted by discovery"

# 8. A killed discovery monitor is recovered by the existing listener,
# without a config reload or a new user prompt. Kill abruptly to exercise
# stale lock recovery as well as the server's published owner.
previous_monitor="$(cat "$MONITOR_PIDFILE")"
previous_painter_client="$(T list-clients -F '#{client_pid}|#{client_flags}' | awk -F '|' '/no-output/ { print $1; exit }')"
[ -n "$previous_painter_client" ] || fail "monitor painter never attached"
previous_painter="$(ps -p "$previous_painter_client" -o ppid= | awk '{ print $1 }')"
[ -n "$previous_painter" ] || fail "monitor painter process was not found"
kill -KILL "$previous_monitor"
wait "$previous_monitor" 2>/dev/null || true
monitor_recovered() {
  MONITOR_PID="$(T show -gqv @agent_monitor_pid)"
  [ "$MONITOR_PID" != "$previous_monitor" ] && kill -0 "$MONITOR_PID" 2>/dev/null
}
wait_for 13000 "listener never recovered the dead monitor" monitor_recovered
pass "listener recovered discovery after an abrupt monitor exit"
painter_stopped() {
  ! kill -0 "$previous_painter" 2>/dev/null && ! kill -0 "$previous_painter_client" 2>/dev/null
}
wait_for 5000 "old painter survived monitor recovery" painter_stopped
pass "recovery stopped the previous painter and its control client"

printf 'ALL TESTS PASSED\n'
