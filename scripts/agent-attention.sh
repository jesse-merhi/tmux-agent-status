#!/usr/bin/env bash
# Flag the tmux window containing $TMUX_PANE with an agent-attention state.
#
# Usage: agent-attention.sh <ready|busy|pending|claude-stop|register|off> [icon] [session_id]
#   ready        agent finished or wants input -> bright icon in the window list
#   busy         agent is working              -> dim icon + spinner
#   pending      agent turn ended with background work still running
#   claude-stop  derive ready/pending from Claude's Stop hook JSON
#   register     mark this window as agent-run; agent-monitor.sh decides state
#   off          agent exited                  -> remove the indicator
#
# Agents call this from their lifecycle hooks (Claude Code hooks, Codex
# notify, etc). agent-monitor.sh keeps states honest between hook calls.
if [ "${BASH_VERSINFO[0]:-0}" -lt 5 ]; then
  for candidate in "${AGENT_STATUS_BASH:-}" /opt/homebrew/bin/bash /usr/local/bin/bash; do
    if [ -z "$candidate" ] || [ ! -x "$candidate" ]; then
      continue
    fi
    if "$candidate" -c '((BASH_VERSINFO[0] >= 5))' 2>/dev/null; then
      exec "$candidate" "$0" "$@"
    fi
  done
  printf 'agent-attention: Bash 5 or newer is required. Set AGENT_STATUS_BASH to its path.\n' >&2
  exit 1
fi
set -euo pipefail

[ -n "${TMUX_PANE:-}" ] || exit 0
command -v tmux >/dev/null 2>&1 || exit 0

state="${1:-ready}"
icon="${2:-●}"

color_for_icon() {
  case "$1" in
    ✳) printf '173' ;; # Claude orange
    ⬢) printf '141' ;; # Codex purple
    *) printf '114' ;;
  esac
}

set_icon_and_start_monitor() {
  tmux set-option -p -t "$TMUX_PANE" @agent_icon "$icon" 2>/dev/null || true
  tmux set-option -p -t "$TMUX_PANE" @agent_color "$(color_for_icon "$icon")" 2>/dev/null || true
  nohup "$(dirname "$0")/agent-monitor.sh" >/dev/null 2>&1 &
  nohup "$(dirname "$0")/agent-events.sh" >/dev/null 2>&1 & # event-driven @agent_ready
}

has_running_tasks() { # session_id
  local sid="$1" path lsof_cmd
  local -a paths=()
  if [ -n "${AGENT_TASKS_ROOT:-}" ]; then
    for path in "$AGENT_TASKS_ROOT"/*/"$sid"/tasks/*.output; do
      [ -e "$path" ] || [ -L "$path" ] || continue
      paths+=("$path")
    done
  else
    for path in /private/tmp/claude-"$(id -u)"/*/"$sid"/tasks/*.output \
      /tmp/claude-"$(id -u)"/*/"$sid"/tasks/*.output; do
      [ -e "$path" ] || [ -L "$path" ] || continue
      paths+=("$path")
    done
  fi
  [ "${#paths[@]}" -gt 0 ] || return 1

  if command -v lsof >/dev/null 2>&1; then
    lsof_cmd="$(command -v lsof)"
  elif [ -x /usr/sbin/lsof ]; then
    lsof_cmd=/usr/sbin/lsof
  else
    return 1
  fi
  # Write-mode holders only: the task's shell keeps its output file open
  # for writing, but readers (tail -f, a grep over old outputs) would
  # otherwise hold a finished session pending forever. Plain grep, not -q:
  # under pipefail an early -q exit SIGPIPEs lsof mid-write and the
  # pipeline reports 141 on what was a positive match.
  [ -n "$("$lsof_cmd" -F a -- "${paths[@]}" 2>/dev/null | grep '^a[wu]' || true)" ]
}

case "$state" in
  ready | busy)
    [ "$state" = ready ] && value=1 || value=0
    pending=""
    ;;
  pending)
    value=0
    pending="${3:-1}"
    ;;
  claude-stop)
    sid=""
    if [ ! -t 0 ]; then
      input="$(cat 2>/dev/null || true)"
      sid="$(printf '%s' "$input" | tr '\n' ' ' |
        sed -nE 's/.*"session_id"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p')"
    fi
    if [ -n "$sid" ] && has_running_tasks "$sid"; then
      value=0
      pending="$sid"
    else
      value=1
      pending=""
    fi
    ;;
  register)
    set_icon_and_start_monitor
    exit 0
    ;;
  off)
    tmux set-option -p -t "$TMUX_PANE" -u @agent_ready 2>/dev/null || exit 0
    tmux set-option -p -t "$TMUX_PANE" -u @agent_icon 2>/dev/null || true
    tmux set-option -p -t "$TMUX_PANE" -u @agent_color 2>/dev/null || true
    tmux set-option -p -t "$TMUX_PANE" -u @agent_state_ts 2>/dev/null || true
    tmux set-option -p -t "$TMUX_PANE" -u @agent_pending 2>/dev/null || true
    tmux refresh-client -S 2>/dev/null || true
    exit 0
    ;;
  *) exit 0 ;;
esac

tmux set-option -p -t "$TMUX_PANE" @agent_ready "$value" 2>/dev/null || exit 0
if [ -n "$pending" ]; then
  tmux set-option -p -t "$TMUX_PANE" @agent_pending "$pending" 2>/dev/null || true
else
  tmux set-option -p -t "$TMUX_PANE" -u @agent_pending 2>/dev/null || true
fi
tmux set-option -p -t "$TMUX_PANE" @agent_state_ts "$(date +%s)" 2>/dev/null || true
set_icon_and_start_monitor
tmux refresh-client -S 2>/dev/null || true
