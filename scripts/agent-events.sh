#!/usr/bin/env bash
# Event-driven busy/ready state for agent panes, via tmux control mode.
#
# Attaches a read-only control-mode client (read-only,ignore-size: it can
# never resize windows or inject input) and watches %output notifications.
# A pane with @agent_icon set is an agent pane; BUSY_CHUNKS output chunks
# inside BUSY_WINDOW_MS flips it busy immediately (a lone keystroke echo
# does not), and READY_AGE seconds of silence flips it ready. Busy agent
# TUIs redraw their spinner continuously (~40 chunks/s measured), so
# silence is a reliable end-of-turn signal.
#
# agent-monitor.sh keeps discovery, naming, pulse and wrap; while this
# listener is alive (global @agent_events=1 plus pidfile) the monitor
# skips its per-second capture-pane hash polling.
#
# One control client sees one session. Argument 1 is the target session
# (default: the session of the first agent pane found, falling back to
# the most recently used session). AGENT_EVENTS_SOCKET selects a tmux
# -L socket for tests.
if [ "${BASH_VERSINFO[0]:-0}" -lt 5 ]; then
  for candidate in "${AGENT_STATUS_BASH:-}" /opt/homebrew/bin/bash /usr/local/bin/bash; do
    if [ -z "$candidate" ] || [ ! -x "$candidate" ]; then
      continue
    fi
    if "$candidate" -c '((BASH_VERSINFO[0] >= 5))' 2>/dev/null; then
      exec "$candidate" "$0" "$@"
    fi
  done
  printf 'agent-events: Bash 5 or newer is required. Set AGENT_STATUS_BASH to its path.\n' >&2
  exit 1
fi
set -u
PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

SOCKET="${AGENT_EVENTS_SOCKET:-}"
READY_AGE="${AGENT_READY_AGE:-5}"
HOOK_GRACE="${AGENT_HOOK_GRACE:-5}"
INPUT_MIN_READY="${AGENT_INPUT_MIN_READY:-10}" # ready this long before busy = user input
PENDING_RECHECK="${AGENT_PENDING_RECHECK:-15}"
DEBUG_LOG="${AGENT_EVENTS_DEBUG:-}"

dbg() { [ -n "$DEBUG_LOG" ] && printf '%s %s\n' "$(now_ms)" "$*" >>"$DEBUG_LOG"; return 0; }
BUSY_CHUNKS=3
BUSY_WINDOW_MS=500
SWEEP_MS=300
RESYNC_MS=2000

tmx() {
  if [ -n "$SOCKET" ]; then
    command tmux -L "$SOCKET" "$@"
  else
    command tmux "$@"
  fi
}

SESSION="${1:-}"
if [ -z "$SESSION" ]; then
  SESSION="$(tmx list-panes -a -F '#{?#{@agent_icon},#{session_name},}' 2>/dev/null | grep -m1 .)"
fi

server_key="$(tmx display-message -p '#{socket_path}' 2>/dev/null | cksum | awk '{ print $1 }')"
pidfile="${AGENT_EVENTS_PIDFILE:-/tmp/tmux-agent-events-$(id -u)-${server_key:-default}.pid}"
if [ -f "$pidfile" ] && kill -0 "$(cat "$pidfile" 2>/dev/null)" 2>/dev/null; then
  exit 0
fi
printf '%s' "$$" >"$pidfile"

in_fifo="$(mktemp -u "${TMPDIR:-/tmp}/agent-events-XXXXXX")"
mkfifo "$in_fifo" || exit 1
cleanup() {
  rm -f "$pidfile" "$in_fifo"
  tmx set-option -g -u @agent_events 2>/dev/null
}
trap cleanup EXIT
# A bare SIGTERM skips the EXIT trap (bash runs it only on normal exit or
# trapped signals) — that is how a killed listener once orphaned its
# control client for 10 hours.
trap 'exit 143' TERM
trap 'exit 130' INT
trap 'exit 129' HUP

now_ms() {
  local t="${EPOCHREALTIME/./}"
  printf '%s' "${t:0:13}"
}

declare -A agents last_out state win_start win_count hook_ts inputs ready_since pending_recheck

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

pane_busy_marker() { # pane
  tmx capture-pane -p -t "$1" 2>/dev/null |
    grep -qiE 'Working \([^)]*esc to interrupt\)'
}

seed_agents() { # initial scan; control-mode notifications keep it fresh after
  local pane icon ready ts ni now="$1"
  while IFS='|' read -r pane icon ready ts ni; do
    [ -n "$icon" ] || continue
    agents[$pane]=1
    last_out[$pane]="$now"
    state[$pane]="${ready:-}"
    hook_ts[$pane]="${ts:-0}"
    inputs[$pane]="${ni:-0}"
    # ready_since stays unset (treated as 0): a seeded ready pane's first
    # busy flip counts as an input.
  done < <(tmx list-panes -s -t "$SESSION" \
    -F '#{pane_id}|#{@agent_icon}|#{@agent_ready}|#{@agent_state_ts}|#{@agent_inputs}' 2>/dev/null)
}

resync_agents() { # now_ms — subscription safety net for panes/windows created while listener lives
  local pane icon ready ts ni now="$1"
  local -A seen=()
  while IFS='|' read -r pane icon ready ts ni; do
    [ -n "$icon" ] || continue
    seen[$pane]=1
    if [ -z "${agents[$pane]:-}" ]; then
      agents[$pane]=1
      last_out[$pane]="$now"
      win_start[$pane]=0
      win_count[$pane]=0
    fi
    state[$pane]="${ready:-${state[$pane]:-}}"
    hook_ts[$pane]="${ts:-0}"
    inputs[$pane]="${ni:-${inputs[$pane]:-0}}"
    if [ "${state[$pane]:-}" = 1 ] && [ -z "${ready_since[$pane]:-}" ]; then
      ready_since[$pane]="$now"
    fi
  done < <(tmx list-panes -s -t "$SESSION" \
    -F '#{pane_id}|#{@agent_icon}|#{@agent_ready}|#{@agent_state_ts}|#{@agent_inputs}' 2>/dev/null)

  for pane in "${!agents[@]}"; do
    [ -n "${seen[$pane]:-}" ] || forget_pane "$pane"
  done
}

# A ready->busy transition after a real ready spell means the user just
# gave the agent a new instruction. @agent_inputs accumulates these so
# the monitor retitles windows right when the task changes — the fresh
# prompt is still in the pane tail for the titler to read.
count_input() { # pane
  inputs[$1]=$((${inputs[$1]:-0} + 1))
  dbg "input $1 -> ${inputs[$1]}"
  tmx set-option -p -t "$1" @agent_inputs "${inputs[$1]}" 2>/dev/null
}

set_ready() { # pane value
  dbg "set_ready $1 -> $2"
  state[$1]="$2"
  tmx set-option -p -t "$1" @agent_ready "$2" 2>/dev/null || forget_pane "$1"
}

forget_pane() {
  unset "agents[$1]" "last_out[$1]" "state[$1]" "win_start[$1]" \
    "win_count[$1]" "hook_ts[$1]" "inputs[$1]" "ready_since[$1]" \
    "pending_recheck[$1]" 2>/dev/null
}

in_hook_grace() { # pane — agent-attention.sh hooks win for HOOK_GRACE secs
  local ts="${hook_ts[$1]:-0}"
  [ "$ts" -gt 0 ] 2>/dev/null && [ $(($(date +%s) - ts)) -lt "$HOOK_GRACE" ]
}

on_output() { # pane now_ms
  local pane="$1" now="$2"
  [ -n "${agents[$pane]:-}" ] || return 0
  last_out[$pane]="$now"
  if [ $((now - ${win_start[$pane]:-0})) -gt "$BUSY_WINDOW_MS" ]; then
    win_start[$pane]="$now"
    win_count[$pane]=1
  else
    win_count[$pane]=$((${win_count[$pane]:-0} + 1))
  fi
  if [ "${state[$pane]:-}" != 0 ] && [ "${win_count[$pane]}" -ge "$BUSY_CHUNKS" ]; then
    in_hook_grace "$pane" && return 0
    local was="${state[$pane]:-}"
    # Only a flip after a real ready spell is a user input; a pane that
    # went quiet mid-turn (long tool call) re-busies within seconds.
    if [ "$was" = 1 ] &&
      [ $((now - ${ready_since[$pane]:-0})) -ge $((INPUT_MIN_READY * 1000)) ]; then
      count_input "$pane"
    fi
    # Publish the input count first so observers can never see busy state
    # paired with the previous count between two tmux option writes.
    set_ready "$pane" 0
  fi
}

sweep_ready() { # now_ms — flip long-silent agent panes ready
  local pane pending now="$1"
  for pane in "${!agents[@]}"; do
    if pane_busy_marker "$pane"; then
      if [ "${state[$pane]:-}" != 0 ]; then
        in_hook_grace "$pane" || set_ready "$pane" 0
      fi
      last_out[$pane]="$now"
      continue
    fi
    [ "${state[$pane]:-}" = 1 ] && continue
    if [ $((now - ${last_out[$pane]:-0})) -ge $((READY_AGE * 1000)) ]; then
      in_hook_grace "$pane" && continue
      pending="$(tmx display -p -t "$pane" '#{@agent_pending}' 2>/dev/null)"
      if [ -n "$pending" ]; then
        if [[ "$pending" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
          if [ $((now - ${pending_recheck[$pane]:-0})) -lt $((PENDING_RECHECK * 1000)) ]; then
            continue
          fi
          pending_recheck[$pane]="$now"
          has_running_tasks "$pending" && continue
          tmx set-option -p -t "$pane" -u @agent_pending 2>/dev/null || continue
        else
          continue # unknown session: only a lifecycle hook can safely clear it
        fi
      fi
      set_ready "$pane" 1
      ready_since[$pane]="$now"
    fi
  done
}

# Subscriptions keep the agent set and hook stamps fresh without polling:
# %subscription-changed fires (at most once a second) when a watched
# format's value changes on any pane in the session.
control_stdin() {
  # Quoted: # would otherwise start a tmux command-line comment.
  printf "refresh-client -B 'icons:%%*:#{@agent_icon}'\n"
  printf "refresh-client -B 'hooks:%%*:#{@agent_state_ts}'\n"
  # Keep the fifo's write end open so the client never sees EOF.
  exec 3>"$in_fifo"
  while kill -0 "$$" 2>/dev/null; do sleep 5; done
}

on_subscription() { # name pane value(may be empty)
  local name="$1" pane="$2" value="$3"
  dbg "sub name=$name pane=$pane value=$value"
  case "$name" in
    icons)
      if [ -n "$value" ]; then
        if [ -z "${agents[$pane]:-}" ]; then
          agents[$pane]=1
          last_out[$pane]="$(now_ms)"
        fi
      else
        [ -n "${agents[$pane]:-}" ] && forget_pane "$pane"
      fi
      ;;
    hooks)
      hook_ts[$pane]="${value:-0}"
      # A hook stamp is fresh evidence; trust the hook's own state writes
      # and restart the silence clock so we don't instantly overrule them.
      [ -n "${agents[$pane]:-}" ] && last_out[$pane]="$(now_ms)"
      local was="${state[$pane]:-}"
      state[$pane]="$(tmx display -p -t "$pane" '#{@agent_ready}' 2>/dev/null)"
      if [ "${state[$pane]}" = 1 ]; then
        ready_since[$pane]="$(now_ms)"
      elif [ "$was" = 1 ] && [ "${state[$pane]}" = 0 ]; then
        count_input "$pane" # a hook-driven busy flip IS a submitted prompt
      fi
      ;;
  esac
}

[ -n "$SESSION" ] || exit 0
start_ms="$(now_ms)"
seed_agents "$start_ms"

control_stdin >"$in_fifo" &
stdin_pid=$!
trap 'cleanup; kill "$stdin_pid" 2>/dev/null' EXIT

# Pin the server socket before unsetting TMUX: the control client must not
# look nested, but without $TMUX a bare tmux would attach the wrong server.
socket_path="$(tmx display -p '#{socket_path}' 2>/dev/null)"
[ -n "$socket_path" ] || exit 0
exec 4< <(
  unset TMUX TMUX_PANE
  command tmux -S "$socket_path" -C attach -t "$SESSION" -f read-only,ignore-size <"$in_fifo" 2>/dev/null
)
# A control client does not exit on stdin EOF: kill it explicitly or it
# outlives us and the server buffers the whole event stream for a client
# nobody reads (leaked once: 10h orphan).
attach_pid=$!
trap 'cleanup; kill "$stdin_pid" "$attach_pid" 2>/dev/null' EXIT

# Publish which session this listener owns: the monitor keeps hash-polling
# panes in other sessions (one control client sees one session).
tmx set-option -g @agent_events "$SESSION" 2>/dev/null
last_sweep="$start_ms"
last_resync="$start_ms"

while :; do
  # shellcheck disable=SC2034 # a2-a4: session/window/index args, unused
  if IFS=' ' read -r -t 0.2 -u 4 tag a1 a2 a3 a4 a5 rest; then
    now="$(now_ms)"
    case "$tag" in
      %output) on_output "$a1" "$now" ;;
      %subscription-changed)
        # %subscription-changed name session window winidx pane ... : value
        value="${rest#*: }"
        [ "$value" = "$rest" ] && value=""
        on_subscription "$a1" "$a5" "$value"
        ;;
      %exit) break ;;
    esac
  else
    rc=$?
    [ "$rc" -gt 128 ] || break # EOF: server died or client detached
    now="$(now_ms)"
  fi
  if [ $((now - last_sweep)) -ge "$SWEEP_MS" ]; then
    last_sweep="$now"
    if [ $((now - last_resync)) -ge "$RESYNC_MS" ]; then
      last_resync="$now"
      resync_agents "$now"
    fi
    sweep_ready "$now"
  fi
done
