#!/usr/bin/env bash
# Behavior tests for Codex window-name context selection.
# shellcheck source=tests/require-modern-bash.sh
source "$(cd "$(dirname "$0")" && pwd)/require-modern-bash.sh"
require_modern_bash "$@" || exit 1
set -u

SOCK="monitor-context-test-$$"
SCRIPT="$(cd "$(dirname "$0")/../scripts" && pwd)/agent-monitor.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/agent-monitor-context.XXXXXX")"
MONITOR_PIDFILE="$TEST_ROOT/monitor.pid"
HOLDER_PID=""

T() { command tmux -L "$SOCK" "$@"; }

cleanup() {
  [ -n "$HOLDER_PID" ] && kill "$HOLDER_PID" 2>/dev/null
  T kill-server 2>/dev/null
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}
pass() { printf 'ok: %s\n' "$1"; }

command -v sqlite3 >/dev/null 2>&1 || fail "sqlite3 is required"
[ -x "$SCRIPT" ] || fail "agent-monitor.sh missing or not executable at $SCRIPT"

T -f /dev/null new-session -d -s t bash || fail "scratch tmux server"
socket_path="$(T display -p '#{socket_path}')"
db="$TEST_ROOT/state.sqlite"
root_id="11111111-1111-4111-8111-111111111111"
child_id="22222222-2222-4222-8222-222222222222"
resumed_id="33333333-3333-4333-8333-333333333333"
root_rollout="$TEST_ROOT/rollout-2026-08-13T10-00-00-$root_id.jsonl"
child_rollout="$TEST_ROOT/rollout-2026-08-13T10-01-00-$child_id.jsonl"
resumed_rollout="$TEST_ROOT/rollout-2026-08-13T10-02-00-$resumed_id.jsonl"

cat >"$root_rollout" <<'EOF'
{"type":"response_item","payload":{"type":"custom_tool_call_output","output":"Fix Bitbucket switcher"}}
{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Upgrade PR proof-pack evidence"}]}}
{"type":"response_item","payload":{"type":"message","role":"assistant","phase":"final_answer","content":[{"type":"output_text","text":"Proof requirements are implemented"}]}}
EOF
cat >"$child_rollout" <<'EOF'
{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Fix Bitbucket switcher"}]}}
EOF
cat >"$resumed_rollout" <<'EOF'
{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Audit Signal setup variants"}]}}
EOF

sqlite3 "$db" <<SQL
CREATE TABLE threads (
  id TEXT PRIMARY KEY,
  rollout_path TEXT NOT NULL,
  updated_at INTEGER NOT NULL,
  cwd TEXT NOT NULL,
  title TEXT NOT NULL,
  archived INTEGER NOT NULL
);
CREATE TABLE thread_spawn_edges (
  parent_thread_id TEXT NOT NULL,
  child_thread_id TEXT NOT NULL PRIMARY KEY,
  status TEXT NOT NULL
);
INSERT INTO threads VALUES ('$root_id', '$root_rollout', 10, '/repo/skills', 'Original proof-pack task
with evidence', 0);
INSERT INTO threads VALUES ('$child_id', '$child_rollout', 20, '/repo/skills', 'Child Bitbucket task', 0);
INSERT INTO threads VALUES ('$resumed_id', '$resumed_rollout', 30, '/repo/openclaw', 'Old Signal task', 0);
INSERT INTO thread_spawn_edges VALUES ('$root_id', '$child_id', 'running');
SQL
T set -g @agent_status_codex_db "$db"

bash -c 'exec 3<"$1" 4<"$2"; sleep 60' _ "$root_rollout" "$child_rollout" &
HOLDER_PID=$!
sleep 0.2

context="$({
  TMUX="$socket_path,0,0" \
    AGENT_MONITOR_PIDFILE="$MONITOR_PIDFILE" \
    AGENT_MONITOR_SELFTEST=codex-context \
    AGENT_MONITOR_SELFTEST_ARGS=codex \
    AGENT_MONITOR_SELFTEST_PID="$HOLDER_PID" \
    AGENT_MONITOR_SELFTEST_PATH=/repo/skills \
    "$SCRIPT"
} 2>/dev/null)"

[[ "$context" == *"Upgrade PR proof-pack evidence"* ]] || fail "root conversation missing: $context"
[[ "$context" == *"Original proof-pack task"* ]] || fail "root title missing: $context"
[[ "$context" == *"with evidence"* ]] || fail "multiline root title was truncated: $context"
[[ "$context" != *"Bitbucket switcher"* ]] || fail "tool or child context leaked: $context"
pass "bare Codex resolves its root rollout and ignores tool output"

context="$({
  TMUX="$socket_path,0,0" \
    AGENT_MONITOR_PIDFILE="$MONITOR_PIDFILE" \
    AGENT_MONITOR_SELFTEST=codex-context \
    AGENT_MONITOR_SELFTEST_ARGS="codex resume $resumed_id" \
    AGENT_MONITOR_SELFTEST_PID="$HOLDER_PID" \
    AGENT_MONITOR_SELFTEST_PATH=/repo/skills \
    "$SCRIPT"
} 2>/dev/null)"

[[ "$context" == *"Audit Signal setup variants"* ]] || fail "resumed conversation missing: $context"
[[ "$context" == *"Old Signal task"* ]] || fail "resumed title missing: $context"
[[ "$context" != *"proof-pack"* ]] || fail "open rollout overrode resumed thread: $context"
pass "resume UUID stays paired with its own rollout"

printf 'ALL TESTS PASSED\n'
