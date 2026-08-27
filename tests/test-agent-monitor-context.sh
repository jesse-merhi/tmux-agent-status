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

[ -x "$SCRIPT" ] || fail "agent-monitor.sh missing or not executable at $SCRIPT"

T -f /dev/null new-session -d -s t bash || fail "scratch tmux server"
socket_path="$(T display -p '#{socket_path}')"
T set -g @agent_status_codex_db "$TEST_ROOT/missing.sqlite"

context="$({
  TMUX="$socket_path,0,0" \
    AGENT_MONITOR_PIDFILE="$MONITOR_PIDFILE" \
    AGENT_MONITOR_SELFTEST=codex-context \
    AGENT_MONITOR_SELFTEST_ARGS="codex exec --sandbox workspace-write Review PR 4" \
    "$SCRIPT"
} 2>/dev/null)"

[[ "$context" == *"Current task: Review PR 4"* ]] ||
  fail "command-line fallback missing without a readable database: $context"
pass "Codex falls back to its command-line task without a readable database"

if ! command -v sqlite3 >/dev/null 2>&1; then
  printf 'SKIP: sqlite3 is not installed; semantic Codex context is optional\n'
  exit 0
fi

db="$TEST_ROOT/state.sqlite"
root_id="11111111-1111-4111-8111-111111111111"
child_id="22222222-2222-4222-8222-222222222222"
resumed_id="33333333-3333-4333-8333-333333333333"
cwd_id="44444444-4444-4444-8444-444444444444"
orphan_child_id="55555555-5555-4555-8555-555555555555"
legacy_id="66666666-6666-4666-8666-666666666666"
sessions_dir="$TEST_ROOT/custom-codex-home/sessions/2026/08/13"
mkdir -p "$sessions_dir"
root_rollout="$sessions_dir/rollout-2026-08-13T10-00-00-$root_id.jsonl"
child_rollout="$sessions_dir/rollout-2026-08-13T10-01-00-$child_id.jsonl"
resumed_rollout="$sessions_dir/rollout-2026-08-13T10-02-00-$resumed_id.jsonl"
cwd_rollout="$sessions_dir/rollout-2026-08-13T10-03-00-$cwd_id.jsonl"
orphan_child_rollout="$sessions_dir/rollout-2026-08-13T10-04-00-$orphan_child_id.jsonl"
legacy_rollout="$sessions_dir/rollout-2026-08-13T10-05-00-$legacy_id.jsonl"

cat >"$root_rollout" <<'EOF'
{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Ancient task outside the bounded rollout tail"}]}}
{"type":"response_item","payload":{"type":"custom_tool_call_output","output":"Fix Bitbucket switcher"}}
EOF
for ((i = 0; i < 2100; i++)); do
  printf '%s\n' '{"type":"response_item","payload":{"type":"custom_tool_call_output","output":"Old tool noise"}}' >>"$root_rollout"
done
cat >>"$root_rollout" <<'EOF'
{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Upgrade PR proof-pack evidence"}]}}
{"type":"response_item","payload":{"type":"message","role":"assistant","phase":"final_answer","content":[{"type":"output_text","text":"Proof requirements are implemented"}]}}
EOF
cat >"$child_rollout" <<'EOF'
{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Fix Bitbucket switcher"}]}}
EOF
cat >"$resumed_rollout" <<'EOF'
{"type":"event_msg","payload":{"type":"item_completed","item":{"type":"UserMessage","id":"resume-user","content":[{"type":"text","text":"Audit Signal setup variants"}]}}}
{"type":"event_msg","payload":{"type":"item_completed","item":{"type":"AgentMessage","id":"resume-agent","phase":"final_answer","content":[{"type":"Text","text":"Signal audit is complete"}]}}}
EOF
cat >"$cwd_rollout" <<'EOF'
{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Maintain cwd fallback behavior"}]}}
EOF
cat >"$orphan_child_rollout" <<'EOF'
{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Internal cold review worker"}]}}
EOF
cat >"$legacy_rollout" <<'EOF'
{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Maintain legacy schema support"}]}}
EOF

sqlite3 "$db" <<SQL
CREATE TABLE threads (
  id TEXT PRIMARY KEY,
  rollout_path TEXT NOT NULL,
  updated_at INTEGER NOT NULL,
  cwd TEXT NOT NULL,
  title TEXT NOT NULL,
  archived INTEGER NOT NULL,
  thread_source TEXT
);
CREATE TABLE thread_spawn_edges (
  parent_thread_id TEXT NOT NULL,
  child_thread_id TEXT NOT NULL PRIMARY KEY,
  status TEXT NOT NULL
);
INSERT INTO threads VALUES ('$root_id', '$root_rollout', 10, '/repo/skills', 'Original proof-pack task
with evidence', 0, 'user');
INSERT INTO threads VALUES ('$child_id', '$child_rollout', 20, '/repo/skills', 'Child Bitbucket task', 0, 'subagent');
INSERT INTO threads VALUES ('$resumed_id', '$resumed_rollout', 30, '/repo/openclaw', 'Old Signal task', 0, 'user');
INSERT INTO threads VALUES ('$cwd_id', '$cwd_rollout', 40, '/repo/skills', 'Newer cwd fallback title', 0, 'user');
INSERT INTO threads VALUES ('$orphan_child_id', '$orphan_child_rollout', 50, '/repo/skills', 'Orphan cold review worker', 0, 'subagent');
INSERT INTO thread_spawn_edges VALUES ('$root_id', '$child_id', 'running');
SQL
T set -g @agent_status_codex_db "$db"

label="$({
  TMUX="$socket_path,0,0" \
    AGENT_MONITOR_PIDFILE="$MONITOR_PIDFILE" \
    AGENT_MONITOR_SELFTEST=window-label \
    AGENT_MONITOR_SELFTEST_AGENT=pi \
    AGENT_MONITOR_SELFTEST_ARGS="pi Repair parser behavior" \
    AGENT_MONITOR_SELFTEST_DIR=skills \
    AGENT_MONITOR_SELFTEST_PATH=/repo/skills \
    "$SCRIPT"
} 2>/dev/null)"
[[ "$label" == "Repair parser behavior" ]] || fail "Pi inherited Codex context: $label"
pass "non-Codex agents do not inherit Codex thread context"

label="$({
  TMUX="$socket_path,0,0" \
    AGENT_MONITOR_PIDFILE="$MONITOR_PIDFILE" \
    AGENT_MONITOR_SELFTEST=window-label \
    AGENT_MONITOR_SELFTEST_AGENT=codex \
    AGENT_MONITOR_SELFTEST_ARGS=codex \
    AGENT_MONITOR_SELFTEST_DIR=skills \
    AGENT_MONITOR_SELFTEST_PATH=/repo/skills \
    "$SCRIPT"
} 2>/dev/null)"
[[ "$label" == "Newer cwd fallback title" ]] || fail "full-path cwd label missing: $label"
pass "window labeling uses the full pane path for Codex cwd recovery"

bash -c 'exec 3<"$1" 4<"$2" 5<"$3"; sleep 60' _ \
  "$root_rollout" "$child_rollout" "$orphan_child_rollout" &
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
[[ "$context" != *"cold review worker"* ]] || fail "edge-less subagent context leaked: $context"
[[ "$context" != *"Ancient task"* ]] || fail "semantic context scanned beyond its bounded tail: $context"
pass "bare Codex resolves its root rollout from a custom home and ignores tool output"

context="$({
  TMUX="$socket_path,0,0" \
    AGENT_MONITOR_PIDFILE="$MONITOR_PIDFILE" \
    AGENT_MONITOR_SELFTEST=codex-context \
    AGENT_MONITOR_SELFTEST_ARGS=codex \
    AGENT_MONITOR_SELFTEST_PATH=/repo/skills \
    "$SCRIPT"
} 2>/dev/null)"

[[ "$context" == *"Maintain cwd fallback behavior"* ]] || fail "cwd conversation missing: $context"
[[ "$context" == *"Newer cwd fallback title"* ]] || fail "newest cwd title missing: $context"
[[ "$context" != *"proof-pack"* ]] || fail "open rollout leaked into cwd fallback: $context"
pass "Codex falls back to the newest root conversation for its cwd"

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
[[ "$context" == *"Signal audit is complete"* ]] || fail "current agent response missing: $context"
[[ "$context" == *"Old Signal task"* ]] || fail "resumed title missing: $context"
[[ "$context" != *"proof-pack"* ]] || fail "open rollout overrode resumed thread: $context"
pass "resume UUID stays paired with its own rollout"

legacy_db="$TEST_ROOT/legacy-state.sqlite"
sqlite3 "$legacy_db" <<SQL
CREATE TABLE threads (
  id TEXT PRIMARY KEY,
  rollout_path TEXT NOT NULL,
  updated_at INTEGER NOT NULL,
  cwd TEXT NOT NULL,
  title TEXT NOT NULL,
  archived INTEGER NOT NULL
);
INSERT INTO threads VALUES ('$legacy_id', '$legacy_rollout', 10, '/repo/legacy', 'Legacy Codex title', 0);
SQL
T set -g @agent_status_codex_db "$legacy_db"

context="$({
  TMUX="$socket_path,0,0" \
    AGENT_MONITOR_PIDFILE="$MONITOR_PIDFILE" \
    AGENT_MONITOR_SELFTEST=codex-context \
    AGENT_MONITOR_SELFTEST_ARGS=codex \
    AGENT_MONITOR_SELFTEST_PATH=/repo/legacy \
    "$SCRIPT"
} 2>/dev/null)"

[[ "$context" == *"Maintain legacy schema support"* ]] || fail "legacy conversation missing: $context"
[[ "$context" == *"Legacy Codex title"* ]] || fail "legacy title missing: $context"
pass "Codex root selection remains compatible with legacy thread schemas"

printf 'ALL TESTS PASSED\n'
