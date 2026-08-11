#!/usr/bin/env bash
# shellcheck source=tests/require-modern-bash.sh
source "$(cd "$(dirname "$0")" && pwd)/require-modern-bash.sh"
require_modern_bash "$@" || exit 1
set -euo pipefail

SOCK="agent-plugin-init-test-$$"
PLUGIN="$(cd "$(dirname "$0")/.." && pwd)/tmux-agent-status.tmux"

T() { command tmux -L "$SOCK" "$@"; }
cleanup() { T kill-server 2>/dev/null || true; }
trap cleanup EXIT
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok: %s\n' "$1"; }

T -f /dev/null new-session -d -s t
T set-option -g @agent_status_start off
TMUX="$(T display-message -p '#{socket_path}'),0,0" "$PLUGIN"

plugin_dir="$(T show-option -gqv @agent_status_plugin_dir)"
[ "$plugin_dir" = "${PLUGIN%/*}" ] || fail "plugin dir was '$plugin_dir'"
pass "plugin publishes its installation directory"

for option in window-status-format window-status-current-format; do
  format="$(T show-option -gwqv "$option")"
  count="$(printf '%s' "$format" | awk '{ print gsub(/#\{P\/i:/, "&") }')"
  [ "$count" -eq 1 ] || fail "$option has $count agent status segments"
done
pass "both window formats render pane-ordered agent state"

pane="$(T display-message -p -t t '#{pane_id}')"
T set-option -p -t "$pane" @agent_icon '✳'
T set-option -p -t "$pane" @agent_color 173
rendered="$(T display-message -p -t t '#{T:window-status-current-format}')"
case "$rendered" in
  *'✳'*) pass "newly discovered agent renders busy before its first state event" ;;
  *) fail "newly discovered agent did not render: $rendered" ;;
esac

TMUX="$(T display-message -p '#{socket_path}'),0,0" "$PLUGIN"
for option in window-status-format window-status-current-format; do
  format="$(T show-option -gwqv "$option")"
  count="$(printf '%s' "$format" | awk '{ print gsub(/#\{P\/i:/, "&") }')"
  [ "$count" -eq 1 ] || fail "$option duplicated the segment on reload"
done
pass "plugin reload is idempotent"

printf 'ALL TESTS PASSED\n'
