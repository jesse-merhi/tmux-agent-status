#!/usr/bin/env bash
# Fresh-home installation and real tmux state transitions for generated hooks.
# shellcheck source=tests/require-modern-bash.sh
# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")" && pwd)/require-modern-bash.sh"
require_modern_bash "$@" || exit 1
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALLER="$ROOT/scripts/install-hooks.sh"
TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/agent-hook-install.XXXXXX")"
export HOME="$TMPROOT/home"
export CODEX_HOME="$HOME/.codex"
SOCK="agent-hook-install-$$"
MONITOR_PIDFILE="$TMPROOT/monitor.pid"
EVENTS_PIDFILE="$TMPROOT/events.pid"

T() { command tmux -L "$SOCK" "$@"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok: %s\n' "$1"; }

cleanup() {
  [[ -f "$MONITOR_PIDFILE" ]] && kill "$(cat "$MONITOR_PIDFILE")" 2>/dev/null || true
  [[ -f "$EVENTS_PIDFILE" ]] && kill "$(cat "$EVENTS_PIDFILE")" 2>/dev/null || true
  T kill-server 2>/dev/null || true
  rm -rf "$TMPROOT"
}
trap cleanup EXIT

hook_command() {
  local file="$1"
  local event="$2"
  jq -er --arg event "$event" --arg marker 'TMUX_AGENT_STATUS_HOOK=1' \
    '.hooks[$event][]?.hooks[]? | select((.command // "") | contains($marker)) | .command' "$file"
}

run_hook() {
  local file="$1"
  local event="$2"
  local payload="${3:-}"
  local command
  [[ -n "$payload" ]] || payload='{}'
  command="$(hook_command "$file" "$event")"
  printf '%s\n' "$payload" | \
    TMUX="$socket_path,0,0" \
    TMUX_PANE="$pane" \
    AGENT_TASKS_ROOT="$TMPROOT/tasks" \
    AGENT_EVENTS_SOCKET="$SOCK" \
    AGENT_MONITOR_PIDFILE="$MONITOR_PIDFILE" \
    AGENT_MONITOR_LOCKDIR="$MONITOR_PIDFILE.lock" \
    AGENT_EVENTS_PIDFILE="$EVENTS_PIDFILE" \
    bash -c "$command"
}

opt() { T display-message -p -t "$pane" "#{@$1}" 2>/dev/null; }

mkdir -p "$HOME"
dry_home="$TMPROOT/dry-home"
HOME="$dry_home" CODEX_HOME="$dry_home/.codex" "$INSTALLER" --all --dry-run >/dev/null
[[ ! -e "$dry_home" ]] || fail 'dry run changed the filesystem'
pass 'dry run left a fresh home untouched'

"$INSTALLER" --all

[[ -L "$HOME/.local/bin/tmux-agent-status-hook" ]] || fail 'hook executable was not linked'
[[ "$(readlink "$HOME/.local/bin/tmux-agent-status-hook")" == "$ROOT/scripts/agent-attention.sh" ]] || fail 'hook link target'
jq -e '.hooks.SessionStart and .hooks.UserPromptSubmit and .hooks.Stop and .hooks.StopFailure and .hooks.Notification and .hooks.SessionEnd' "$HOME/.claude/settings.json" >/dev/null || fail 'Claude lifecycle events'
jq -e '.hooks.SessionStart and .hooks.UserPromptSubmit and .hooks.Stop and .hooks.SessionEnd' "$CODEX_HOME/hooks.json" >/dev/null || fail 'Codex lifecycle events'
pass 'fresh install configured Claude and Codex hooks'

before_claude="$(cksum "$HOME/.claude/settings.json")"
before_codex="$(cksum "$CODEX_HOME/hooks.json")"
"$INSTALLER" --all >/dev/null
[[ "$(cksum "$HOME/.claude/settings.json")" == "$before_claude" ]] || fail 'Claude reinstall changed config'
[[ "$(cksum "$CODEX_HOME/hooks.json")" == "$before_codex" ]] || fail 'Codex reinstall changed config'
pass 'reinstall was idempotent'

T -f /dev/null new-session -d -s t -x 80 -y 24 bash
pane="$(T display-message -p -t t '#{pane_id}')"
socket_path="$(T display-message -p '#{socket_path}')"

run_hook "$HOME/.claude/settings.json" UserPromptSubmit '{"session_id":"claude-test"}'
[[ "$(opt agent_icon)" == '✳' && "$(opt agent_ready)" == 0 ]] || fail 'Claude prompt did not set busy'
run_hook "$HOME/.claude/settings.json" Stop '{"session_id":"claude-test"}'
[[ "$(opt agent_icon)" == '✳' && "$(opt agent_ready)" == 1 ]] || fail 'Claude stop did not set ready'
pass 'Claude generated hooks drove busy and ready tmux states'

run_hook "$CODEX_HOME/hooks.json" UserPromptSubmit '{"session_id":"codex-test"}'
[[ "$(opt agent_icon)" == '⬢' && "$(opt agent_ready)" == 0 ]] || fail 'Codex prompt did not set busy'
run_hook "$CODEX_HOME/hooks.json" Stop '{"session_id":"codex-test"}'
[[ "$(opt agent_icon)" == '⬢' && "$(opt agent_ready)" == 1 ]] || fail 'Codex stop did not set ready'
run_hook "$CODEX_HOME/hooks.json" SessionEnd '{"session_id":"codex-test"}'
[[ -z "$(opt agent_icon)" ]] || fail 'Codex session end did not clear state'
pass 'Codex generated hooks drove busy, ready, and off tmux states'

merge_home="$TMPROOT/merge-home"
mkdir -p "$merge_home/.claude" "$merge_home/.codex"
printf '%s\n' '{"theme":"dark","hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo custom-claude"}]}]}}' >"$merge_home/.claude/settings.json"
printf '%s\n' '{"description":"mine","hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo custom-codex"}]}]}}' >"$merge_home/.codex/hooks.json"
HOME="$merge_home" CODEX_HOME="$merge_home/.codex" "$INSTALLER" --all >/dev/null
jq -e '.theme == "dark" and any(.hooks.Stop[].hooks[]; .command == "echo custom-claude")' "$merge_home/.claude/settings.json" >/dev/null || fail 'Claude custom config was not preserved'
jq -e '.description == "mine" and any(.hooks.Stop[].hooks[]; .command == "echo custom-codex")' "$merge_home/.codex/hooks.json" >/dev/null || fail 'Codex custom hooks were not preserved'
pass 'existing unrelated settings and hooks were preserved'

printf 'ALL TESTS PASSED\n'
