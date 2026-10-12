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

pane="$(T display-message -p -t t '#{pane_id}')"
T set-option -p -t "$pane" @agent_icon '✳'
T set-option -p -t "$pane" @agent_color 173

# Discovery tags an agent before its first ready-state event. Both status
# formats must show it once, and a config reload must not duplicate it.
for load in initial reload; do
  TMUX="$(T display-message -p '#{socket_path}'),0,0" "$PLUGIN"
  for option in window-status-format window-status-current-format; do
    rendered="$(T display-message -p -t t "#{T:$option}")"
    count="$(printf '%s' "$rendered" | awk '{ print gsub(/✳/, "&") }')"
    [ "$count" -eq 1 ] || fail "$load $option rendered $count agent icons"
  done
  pass "$load load renders one agent icon in both status formats"
done

printf 'ALL TESTS PASSED\n'
