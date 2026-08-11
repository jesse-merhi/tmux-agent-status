#!/usr/bin/env bash
# Verify agent icons follow current pane indexes rather than pane creation order.
set -euo pipefail

SOCK="agent-icon-order-test-$$"
CONF="$(cd "$(dirname "$0")/.." && pwd)/tmux-agent-status.tmux"

T() { command tmux -L "$SOCK" "$@"; }

cleanup() {
  T kill-server 2>/dev/null || true
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}
pass() { printf 'ok: %s\n' "$1"; }

format_count="$(awk '{ count += gsub(/#\{P\/i:/, "&") } END { print count + 0 }' "$CONF")"
[ "$format_count" = 1 ] || fail "expected the shared status segment to use P/i once, found $format_count"
pass "status segment requests pane-index order"

T -f /dev/null new-session -d -s t -x 120 -y 40
p1="$(T display -p -t t '#{pane_id}')"
p2="$(T split-window -h -P -F '#{pane_id}' -t t)"
p3="$(T split-window -v -P -F '#{pane_id}' -t "$p1")"
p4="$(T split-window -v -P -F '#{pane_id}' -t "$p2")"
T select-layout -t t tiled >/dev/null

T set-option -p -t "$p1" @agent_icon A
T set-option -p -t "$p2" @agent_icon B
T set-option -p -t "$p3" @agent_icon C
T set-option -p -t "$p4" @agent_icon D

visual="$(T list-panes -t t -F '#{@agent_icon}' | tr -d '\n')"
indexed="$(T display -p -t t '#{P/i:#{@agent_icon}}')"
if [ "$indexed" = ABCD ]; then
  printf 'skip: %s does not support P/i pane-index sorting\n' "$(tmux -V)"
  exit 0
fi
[ "$indexed" = "$visual" ] || fail "initial icons were $indexed, visual pane order was $visual"
pass "initial icons follow pane-index order ($indexed)"

T swap-pane -s "$p1" -t "$p4"
visual="$(T list-panes -t t -F '#{@agent_icon}' | tr -d '\n')"
indexed="$(T display -p -t t '#{P/i:#{@agent_icon}}')"
[ "$indexed" = "$visual" ] || fail "swapped icons were $indexed, visual pane order was $visual"
pass "icons follow panes after a swap ($indexed)"

printf 'ALL TESTS PASSED\n'
