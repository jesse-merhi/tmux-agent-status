#!/usr/bin/env bash
# Keep agent panes' attention state accurate and animate their icons.
#
# Discovery (every DISCOVER_EVERY seconds): walk every pane's full process
# tree for known agent binaries; set/clear pane-scoped @agent_icon and
# @agent_color (brand colour shown when ready), so a window with two
# agents shows two icons. Auto-named agent windows are renamed to what
# their agent is doing — pane-label.sh's semantic task title, the codex
# thread prompt, or the agent's command line, falling back to the working
# directory. Names are cached per pane and recomputed only when the
# pane's agent process changes, plus one amortised NAME_TTL drift refresh
# per pass, so steady-state discovery does no expensive label work.
# Windows we renamed are tracked via @agent_named and given back to
# automatic-rename when their agents exit. When @agent_rename_manual_windows
# is on, restored/manual agent windows are reclaimed too, unless that window
# has @agent_rename_lock=1.
#
# State (every RECONCILE_SECS, on a fixed clock independent of the pulse
# rate): a working agent TUI redraws constantly, so BUSY_RUNS consecutive
# polls with changed visible pane content means busy; READY_AGE seconds
# without change means ready for input. Hook-driven writes from
# agent-attention.sh stamp @agent_state_ts and win for HOOK_GRACE seconds.
#
# Pulse: while anything is busy, breathe @agent_pulse through grey shades
# every PULSE_SLEEP seconds; busy icons render in that colour, so the icon
# itself is the loading animation. One tmux call per frame, in a dedicated
# child process so discovery/naming work can never stall the animation.
#
# Singleton via pidfile; stays available for hookless discovery until the
# tmux server goes away. Started by agent-attention.sh and on config load.
if [ "${BASH_VERSINFO[0]:-0}" -lt 5 ]; then
  for candidate in "${AGENT_STATUS_BASH:-}" /opt/homebrew/bin/bash /usr/local/bin/bash; do
    if [ -z "$candidate" ] || [ ! -x "$candidate" ]; then
      continue
    fi
    if "$candidate" -c '((BASH_VERSINFO[0] >= 5))' 2>/dev/null; then
      exec "$candidate" "$0" "$@"
    fi
  done
  printf 'agent-monitor: Bash 5 or newer is required. Set AGENT_STATUS_BASH to its path.\n' >&2
  exit 1
fi
set -u
PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

tmux_option() {
  tmux show-option -gqv "$1" 2>/dev/null || true
}

option_or_default() {
  local value
  value="$(tmux_option "$1")"
  printf '%s' "${value:-$2}"
}

integer_option() {
  local value
  value="$(tmux_option "$1")"
  case "$value" in
    '' | *[!0-9]*) printf '%s' "$2" ;;
    *) printf '%s' "$value" ;;
  esac
}

expand_home_path() {
  # These are literal prefixes accepted from tmux options, not shell paths.
  # shellcheck disable=SC2016,SC2088
  local home_prefix='$HOME/' tilde_prefix='~/'
  case "$1" in
    "$home_prefix"*) printf '%s/%s' "$HOME" "${1#"$home_prefix"}" ;;
    "$tilde_prefix"*) printf '%s/%s' "$HOME" "${1#"$tilde_prefix"}" ;;
    *) printf '%s' "$1" ;;
  esac
}

# 0.22s frames: with many busy agents the tmux server spends 40%+ of a
# core parsing their output, and each pulse frame is one server round
# trip that queues behind that parsing (measured 50-250ms). At 8fps the
# queueing reads as stutter; at ~4.5fps with a coarser ramp a delayed
# frame just looks like a slow breath.
PULSE_SLEEP="$(option_or_default @agent_status_pulse_interval 0.22)"
RECONCILE_SECS=1
DISCOVER_EVERY=10
NAME_TTL=600  # fallback mode: refresh a pane's cached name at most this often
NAME_FLOOR=60 # events mode: at least this many seconds between retitles
STATUS_MIN_LINES="$(integer_option @agent_status_min_lines 1)"
STATUS_MAX_LINES="$(integer_option @agent_status_max_lines 5)"
[ "$STATUS_MIN_LINES" -lt 1 ] && STATUS_MIN_LINES=1
[ "$STATUS_MIN_LINES" -gt 5 ] && STATUS_MIN_LINES=5
[ "$STATUS_MAX_LINES" -gt 5 ] && STATUS_MAX_LINES=5
[ "$STATUS_MAX_LINES" -lt "$STATUS_MIN_LINES" ] && STATUS_MAX_LINES="$STATUS_MIN_LINES"
WRAP_STATUS="$(option_or_default @agent_status_wrap on)"
RENAME_WINDOWS="$(option_or_default @agent_status_rename_windows on)"

# agent-events.sh owns @agent_ready while it runs (instant flips from tmux
# control-mode %output events, and @agent_inputs prompt counting); the
# capture-pane hash loop below is the fallback when it is not running.
events_script="$(cd "$(dirname "$0")" && pwd)/agent-events.sh"
server_key="$(tmux display-message -p '#{socket_path}' 2>/dev/null | cksum | awk '{ print $1 }')"
events_pidfile="${AGENT_EVENTS_PIDFILE:-/tmp/tmux-agent-events-$(id -u)-${server_key:-default}.pid}"
events_alive() {
  local owner
  owner="$(tmux show -gqv @agent_events_pid 2>/dev/null)"
  if [[ "$owner" =~ ^[0-9]+$ ]] && kill -0 "$owner" 2>/dev/null; then
    return 0
  fi
  [ -f "$events_pidfile" ] && kill -0 "$(cat "$events_pidfile" 2>/dev/null)" 2>/dev/null
}
# The session the listener owns (a control client sees one session);
# panes elsewhere keep the hash-polling fallback.
events_session() { tmux show -gv @agent_events 2>/dev/null; }

# Local model for window titles (free, offline). When ollama is down the
# regex chain below takes over.
OLLAMA_URL="$(option_or_default @agent_status_ollama_url http://127.0.0.1:11434)"
AI_MODEL="$(tmux_option @agent_status_ollama_model)"
HOOK_GRACE=5
READY_AGE=5
BUSY_RUNS=2
STALE_HOOK_SECS=60
NAME_MAX=28
label_script="$(expand_home_path "$(tmux_option @agent_status_label_command)")"
codex_db="$(expand_home_path "$(option_or_default @agent_status_codex_db "${CODEX_HOME:-$HOME/.codex}/state_5.sqlite")")"

# pane-label.sh keyword-bucket outputs: too vague to be a window name.
GENERIC_TITLES='^(setup|cleanup|deploy|review|code review|testing|remote access|remote desktop)$'

AGENTS="$(option_or_default @agent_status_agents 'claude|codex|pi|opencode')"

visible_client() { # client_flags client_tty
  case ",${1:-}," in
    *,control-mode,*) return 1 ;;
  esac
  [ -n "${2:-}" ]
}

if [ "${AGENT_MONITOR_SELFTEST:-}" = visible-clients ]; then
  while IFS='|' read -r flags tty width; do
    visible_client "$flags" "$tty" && printf '%s\n' "$width"
  done
  exit 0
fi

pidfile="${AGENT_MONITOR_PIDFILE:-/tmp/tmux-agent-monitor-$(id -u)-${server_key:-default}.pid}"
lockdir="${AGENT_MONITOR_LOCKDIR:-${pidfile}.lock}"

pid_alive() {
  [ -n "${1:-}" ] && kill -0 "$1" 2>/dev/null
}

cleanup_lock() {
  local owner
  owner="$(cat "$lockdir/pid" 2>/dev/null || true)"
  [ "$owner" = "$$" ] && rm -rf "$lockdir"
  owner="$(cat "$pidfile" 2>/dev/null || true)"
  [ "$owner" = "$$" ] && rm -f "$pidfile"
}

acquire_lock() {
  local owner
  while ! mkdir "$lockdir" 2>/dev/null; do
    owner="$(cat "$lockdir/pid" 2>/dev/null || true)"
    if pid_alive "$owner"; then
      exit 0
    fi
    rm -rf "$lockdir" 2>/dev/null || exit 0
  done
  printf '%s' "$$" >"$lockdir/pid"

  owner="$(cat "$pidfile" 2>/dev/null || true)"
  if [ "$owner" != "$$" ] && pid_alive "$owner"; then
    cleanup_lock
    exit 0
  fi
  printf '%s' "$$" >"$pidfile"
}

owns_lock() {
  [ "$(cat "$lockdir/pid" 2>/dev/null || true)" = "$$" ]
}

acquire_lock
trap cleanup_lock EXIT
trap 'exit 143' TERM # SIGTERM must run the EXIT trap (kills the pulse child)
trap 'exit 130' INT
trap 'exit 129' HUP

icon_for() {
  case "${1##*/}" in
    claude) printf '✳' ;;
    codex | codex-aarch64-a) printf '⬢' ;;
    *) printf '●' ;;
  esac
}

color_for() {
  case "${1##*/}" in
    claude) printf '173' ;;                  # Claude orange
    codex | codex-aarch64-a) printf '141' ;; # Codex purple
    *) printf '114' ;;
  esac
}

# Print "name<TAB>pid<TAB>full args" for the agent running in a pane (the pane
# command itself or any descendant), walking the whole process tree:
# agents are often nested under wrapper shells. comm truncates long
# paths, so the first command token covers what comm cannot.
agent_of_pane() { # pane_pid pane_cmd
  awk -v root="$1" -v agents="^(${AGENTS})\$" '
    FNR == NR { par[$1] = $2; n = $3; sub(/.*\//, "", n); comm[$1] = n; next }
    {
      full[$1] = $0
      sub(/^[ ]*[0-9]+[ ]+/, "", full[$1])
      n = $2; sub(/.*\//, "", n); argv0[$1] = n
    }
    END {
      head = 1; tail = 1; q[1] = root
      while (head <= tail) {
        p = q[head++]
        for (c in par) if (par[c] == p) q[++tail] = c
      }
      for (i = 1; i <= tail; i++) {
        p = q[i]
        if (comm[p] ~ agents) { print comm[p] "\t" p "\t" full[p]; exit }
        if (argv0[p] ~ agents) { print argv0[p] "\t" p "\t" full[p]; exit }
      }
    }' <(printf '%s\n' "$ps_tree") <(printf '%s\n' "$ps_args")
}

# Task text from an agent's command line: drop the binary, flags and
# their values, and id-like tokens; whatever remains is the prompt/task.
args_task() {
  [ -n "${1:-}" ] || return 0
  local -a words=()
  # shellcheck disable=SC2086
  set -- $1
  shift || return 0
  while [ $# -gt 0 ]; do
    case "$1" in
      -C | --cd | -m | --model | -p | --profile | -c | --config | -s | --sandbox | -a | --ask-for-approval)
        shift 2 2>/dev/null || break
        ;;
      resume | exec | apply | -*)
        shift
        ;;
      *)
        if printf '%s' "$1" | grep -qE '^[0-9a-f]{8}-[0-9a-f-]{20,}$'; then
          shift
          continue
        fi
        words+=("$1")
        shift
        ;;
    esac
  done
  printf '%s' "${words[*]:-}"
}

# Recent conversation context for a pane: the codex thread's first
# prompt plus the last few rollout messages when a resume uuid exists,
# else the visible tail of the pane itself.
ai_context() { # agent_args pane_id
  local uuid first rp task
  uuid="$(printf '%s' "${1:-}" | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -1)"
  if [ -n "$uuid" ] && [ -r "$codex_db" ]; then
    first="$(sqlite3 -readonly "$codex_db" "SELECT substr(title,1,300) FROM threads WHERE id = '$uuid' LIMIT 1" 2>/dev/null)"
    rp="$(sqlite3 -readonly "$codex_db" "SELECT rollout_path FROM threads WHERE id = '$uuid' LIMIT 1" 2>/dev/null)"
    if [ -n "$first" ]; then
      printf 'Task: %s\n' "$first"
      [ -r "$rp" ] && tail -n 150 "$rp" 2>/dev/null |
        jq -r 'select(.type == "response_item" and .payload.type == "message")
               | (.payload.content // []) | map(.text? // empty) | join(" ")' 2>/dev/null |
        grep -v '^$\|^# AGENTS\|^<' | tail -3 | cut -c1-300
      return 0
    fi
  fi
  # No thread record: the task words from the command line plus the pane
  # tail, minus TUI chrome and sub-agent status noise that produces
  # titles like "waiting for agents".
  task="$(args_task "${1:-}")"
  [ -n "$task" ] && printf 'Task: %s\n' "$task"
  printf 'Recent output:\n'
  tmux capture-pane -p -t "$2" 2>/dev/null | grep -v '^[[:space:]]*$' |
    grep -vE 'esc to interrupt|/ps to view|^[›❯]|tokens|context left|^[─━]+|gpt-|claude-|· Main' |
    grep -vE '[Ww]aiting for [0-9]+ agent|Finished waiting' |
    grep -vE '^[[:space:]•└├·-]*[0-9a-f-]{30,}[[:space:]]*$' |
    tail -8 | cut -c1-200
}

# Ask the local model for a short title. Retries once warmer when the
# first answer is junk; empty output on failure so callers fall through
# to the regex chain.
ai_title() { # context
  local prompt payload out low temp
  [ -n "$AI_MODEL" ] && [ -n "${1:-}" ] || return 0
  prompt="Coding session:
$1

Write a VERY SHORT title — 4 words or fewer if at all possible — describing what this session is working on. Base it on the Task line when present, and be specific (feature, component, or PR number). No punctuation, no quotes, output only the title.
Examples of good titles: fix pagination counts | review imagegen PR 86360 | tmux status icons"
  for temp in 0.2 0.7; do
    payload="$(jq -n --arg m "$AI_MODEL" --arg p "$prompt" --argjson t "$temp" \
      '{model: $m, prompt: $p, stream: false, keep_alive: "30m", options: {num_predict: 16, temperature: $t}}' 2>/dev/null)" || return 0
    out="$(curl -s -m 15 "$OLLAMA_URL/api/generate" -d "$payload" 2>/dev/null | jq -r '.response // empty' 2>/dev/null)"
    out="$(printf '%s' "$out" | tr -d '"`' |
      sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//; s/^[Ss]ession [Tt]itle:? *//; s/^[Tt]itle:? *//; s/[.!?,:]+$//')"
    low="$(printf '%s' "$out" | tr '[:upper:]' '[:lower:]')"
    case "$low" in
      '' | *rules* | *title* | *coding\ session* | *waiting\ for*) continue ;; # parroted or vacuous
      'review' | 'code review' | 'pr review' | 'review pr' | 'code changes' | 'fix bug' | 'fix bugs') continue ;; # too generic to be useful
    esac
    printf '%s' "$out"
    return 0
  done
  return 0
}

# First prompt of a resumed codex thread, looked up by the uuid in the
# agent's args. Beats keyword guessing: it is what the session was
# started to do.
thread_task() { # agent args
  local uuid title
  uuid="$(printf '%s' "${1:-}" | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -1)"
  [ -n "$uuid" ] && [ -r "$codex_db" ] || return 0
  title="$(sqlite3 -readonly "$codex_db" "SELECT title FROM threads WHERE id = '$uuid' LIMIT 1" 2>/dev/null)"
  [ -n "$title" ] || return 0
  printf '%s' "$title" | perl -CS -Mutf8 -pe '
    s#https?://github\.com/[A-Za-z0-9_.-]+/([A-Za-z0-9_.-]+)/(?:pull|issues)/(\d+)#$1\#$2#gi;
    s#https?://\S+##g;
    1 while s/^\s*(someone said:?|help me|please|hey|hi|ok(?:ay)?,?\s*so|can you|could you|can we|let.?s|i\W*(?:d|ll|m)?\s*(?:want|would like|love|need|am trying|trying)\s*(?:to|you to)?|be able to|able to)\s+//i;
    s/\s+(please|thanks|thank you)\b//gi;
    s/\$([A-Za-z0-9_-]+)/$1/g;
    s/\s+/ /g; s/^\s+|\s+$//g;
  ' 2>/dev/null
}

# Short task name. Claude panes use Claude Code's own session summary
# (via pane-label.sh); other agents get a local-model title first, then
# pane-label's semantic label, the originating codex thread prompt, and
# the agent's command line. Short generic titles get the project dir
# appended so two "setup" windows stay distinguishable.
window_label() { # pid cmd path title agent_args agent pane_id
  local out="" dir="$3"
  if [ "${6:-}" != claude ]; then
    out="$(ai_title "$(ai_context "${5:-}" "${7:-}")")"
    if [ -n "$out" ]; then
      if [ -n "$dir" ] && [ $((${#out} + ${#dir} + 3)) -le "$NAME_MAX" ] &&
        [[ "$out" != *"$dir"* ]]; then
        out="$out · $dir"
      fi
      printf '%s' "$out" # used as-is; the status-line wrap absorbs width
      return 0
    fi
  fi
  if [ -n "$label_script" ] && [ -x "$label_script" ]; then
    out="$("$label_script" "$1" "$2" "$3" "$4" 2>/dev/null)" || out=""
  fi
  case "$out" in
    "${2##*/} "*) out="" ;; # "cmd project" fallback: not a real title
    /* | '~'*) out="" ;;    # raw path: never a useful window name
  esac
  out="$(printf '%s' "$out" | sed -E 's/^[A-Za-z_-]+: //')"
  case "$out" in
    *...)
      out="${out%...}"
      out="${out% *}" # pane-label truncated: drop its partial word
      ;;
  esac
  if [ -n "$out" ]; then
    printf '%s' "$out" | grep -qiE "$GENERIC_TITLES" && out="" # keyword-bucket guess
    case "$out" in
      *' -'*) out="" ;; # command soup: "caffeinate -i -t 300"
      */*) out="" ;;    # path soup: "node /Users/me/.codex/…"
    esac
  fi
  [ -n "$out" ] || out="$(thread_task "${5:-}")"
  [ -n "$out" ] || out="$(args_task "${5:-}")"
  [ -n "$out" ] || return 0
  if [ -n "$dir" ] && [ $((${#out} + ${#dir} + 3)) -le "$NAME_MAX" ] &&
    [[ "$out" != *"$dir"* ]]; then
    out="$out · $dir"
  fi
  if [ "${#out}" -gt "$NAME_MAX" ]; then
    case "${out:$NAME_MAX:1}" in
      ' ') out="${out:0:$NAME_MAX}" ;; # cut landed on a word break
      *)
        out="${out:0:$NAME_MAX}"
        case "$out" in
          *' '*) out="${out% *}" ;; # never cut mid-word
          *-*) out="${out%-*}" ;;   # lone long token: cut at a hyphen
        esac
        ;;
    esac
  fi
  printf '%s' "${out%"${out##*[![:space:]]}"}"
}

# --- window-list wrap ------------------------------------------------------
# The monitor owns the status lines with self-contained formats (never unset:
# clearing an array option element blanks the bar). Windows are split into
# contiguous rows, expanding up to tmux's supported status-line limit. Window
# entries keep their mouse-click ranges.

rendered_width() { # strip #[...] style directives, count cells (approx.)
  local s
  s="$(printf '%s' "$1" | sed -E 's/#\[[^]]*\]//g')"
  printf '%s' "${#s}"
}

apply_wrap() { # upper window-index cutoff per row; last cutoff may be 99999
  local signature status_lines row prev upper cond e c fmt
  local -a cutoffs=("$@")
  [ "$WRAP_STATUS" = on ] || return 0
  [ "${#cutoffs[@]}" -gt 0 ] || cutoffs=(99999)

  status_lines="${#cutoffs[@]}"
  [ "$status_lines" -lt "$STATUS_MIN_LINES" ] && status_lines="$STATUS_MIN_LINES"
  [ "$status_lines" -gt "$STATUS_MAX_LINES" ] && status_lines="$STATUS_MAX_LINES"

  # The applied rows live in a tmux option, not process memory, so a restart
  # or an out-of-band format change can never desync the cache.
  signature="${status_lines}|${cutoffs[*]}"
  [ "$(tmux show -gv @agent_wrap_rows 2>/dev/null)" = "$signature" ] && return 0
  tmux set-option -g @agent_wrap_rows "$signature" 2>/dev/null
  tmux set-option -g status "$status_lines" 2>/dev/null

  for ((row = 0; row < status_lines; row++)); do
    upper="${cutoffs[$row]:-99999}"
    if [ "$row" -eq 0 ]; then
      cond="#{e|<=:#{window_index},$upper}"
    else
      prev="${cutoffs[$((row - 1))]}"
      if [ "$upper" = 99999 ]; then
        cond="#{e|>:#{window_index},$prev}"
      else
        cond="#{&&:#{e|>:#{window_index},$prev},#{e|<=:#{window_index},$upper}}"
      fi
    fi

    e="#{?${cond},#[range=window|#{window_index}]#{T:window-status-format}#[norange],}"
    c="#{?${cond},#[range=window|#{window_index}]#{T:window-status-current-format}#[norange],}"
    if [ "$row" -eq 0 ]; then
      fmt="#[align=left range=left]#{T:status-left}#[norange list=on]#{W:${e},${c}}#[nolist align=right range=right]#{T:status-right}#[norange]"
    else
      fmt="#[align=left list=on]#{W:${e},${c}}#[nolist]"
    fi
    tmux set-option -g "status-format[$row]" "$fmt" 2>/dev/null
  done

  for ((row = status_lines; row < STATUS_MAX_LINES; row++)); do
    tmux set-option -g "status-format[$row]" "" 2>/dev/null
  done
  for tty in ${client_ttys[@]+"${client_ttys[@]}"}; do
    tmux refresh-client -S -t "$tty" 2>/dev/null
  done
  return 0
}

compute_wrap() {
  local cw lw rw budget0 budget1 total idx wid text w i row budget start width next
  local -a cutoffs=()
  [ "$WRAP_STATUS" = on ] || return 0
  if [[ "${AGENT_MONITOR_CLIENT_WIDTH_OVERRIDE:-}" =~ ^[0-9]+$ ]]; then
    cw="$AGENT_MONITOR_CLIENT_WIDTH_OVERRIDE"
  else
    cw="$(
      while IFS='|' read -r flags tty width; do
        visible_client "$flags" "$tty" && [ -n "$width" ] && printf '%s\n' "$width"
      done < <(tmux list-clients -F '#{client_flags}|#{client_tty}|#{client_width}' 2>/dev/null) |
        sort -n | head -1
    )"
  fi
  [ -n "$cw" ] || return 0
  lw="$(rendered_width "$(tmux display-message -p '#{T:status-left}' 2>/dev/null)")"
  rw="$(rendered_width "$(tmux display-message -p '#{T:status-right}' 2>/dev/null)")"
  budget0=$((cw - lw - rw - 4))
  budget1=$((cw - 2))

  local -a idxs=() ws=()
  total=0
  while IFS='|' read -r idx wid; do
    text="$(tmux display-message -p -t "$wid" '#{T:window-status-format}' 2>/dev/null)"
    w="$(rendered_width "$text")"
    idxs+=("$idx")
    ws+=("$w")
    total=$((total + w))
  done < <(tmux list-windows -F '#{window_index}|#{window_id}' 2>/dev/null)
  [ "${#idxs[@]}" -gt 0 ] || return 0

  if [ "$total" -le "$budget0" ]; then
    apply_wrap 99999 # single line; keep line 1 empty
    return 0
  fi

  # Overflow: pack rows greedily up to tmux's status-line limit. A single
  # over-wide window still gets its own row instead of blocking progress.
  i=0
  for ((row = 0; row < STATUS_MAX_LINES; row++)); do
    [ "$i" -lt "${#idxs[@]}" ] || break
    if [ "$row" -eq $((STATUS_MAX_LINES - 1)) ]; then
      cutoffs+=(99999)
      break
    fi

    budget="$budget1"
    [ "$row" -eq 0 ] && budget="$budget0"
    [ "$budget" -lt 1 ] && budget=1

    start="$i"
    width=0
    while [ "$i" -lt "${#idxs[@]}" ]; do
      next=$((width + ws[i]))
      if [ "$i" -gt "$start" ] && [ "$next" -gt "$budget" ]; then
        break
      fi
      width="$next"
      i=$((i + 1))
    done

    if [ "$i" -ge "${#idxs[@]}" ]; then
      cutoffs+=(99999)
      break
    fi
    cutoffs+=("${idxs[$((i - 1))]}")
  done

  [ "${#cutoffs[@]}" -gt 0 ] || cutoffs=(99999)
  apply_wrap "${cutoffs[@]}"
}
# ---------------------------------------------------------------------------

clear_pane() {
  tmux set-option -p -t "$1" -u @agent_icon 2>/dev/null
  tmux set-option -p -t "$1" -u @agent_color 2>/dev/null
  tmux set-option -p -t "$1" -u @agent_ready 2>/dev/null
  tmux set-option -p -t "$1" -u @agent_state_ts 2>/dev/null
  tmux set-option -p -t "$1" -u @agent_pending 2>/dev/null
}

pane_busy_marker() { # pane
  tmux capture-pane -p -t "$1" 2>/dev/null |
    grep -qiE '(Working|Waiting for background terminal) \([^)]*esc to interrupt\)'
}

checksum() {
  if command -v md5 >/dev/null 2>&1; then
    md5 -q
  elif command -v md5sum >/dev/null 2>&1; then
    md5sum | awk '{ print $1 }'
  else
    cksum | awk '{ print $1 ":" $2 }'
  fi
}

# Pane name cache. A pane's name is recomputed only when its agent
# process changes (new pid/args = new session or task) — names almost
# never change, so steady-state discovery does no expensive label work.
# One pane per pass may additionally refresh after NAME_TTL to pick up
# slowly evolving session titles.
declare -A name_cache name_key name_time name_inputs

# Scan process trees; maintain pane icons/colours and window names.
discover() {
  local now="$1" ps_tree ps_args refreshed=0 need events_on=0 events_sess="" found_agent=0
  local sess wid pane pid cmd icon color ts dir title ni agent agent_line apid aargs key label
  local name auto named lock det rename_manual
  rename_manual="$(tmux_option @agent_status_rename_manual_windows)"
  [ -n "$rename_manual" ] || rename_manual="$(tmux_option @agent_rename_manual_windows)"
  events_alive && events_on=1 && events_sess="$(events_session)"
  ps_tree="$(ps -ax -o pid=,ppid=,comm= 2>/dev/null)"
  ps_args="$(ps -ax -o pid=,command= 2>/dev/null)"
  local -A detected=() detected_real=() icon_wids=() seen_panes=()

  while IFS='|' read -r sess wid pane pid cmd icon color ts dir title ni; do
    seen_panes[$pane]=1
    agent_line="$(agent_of_pane "$pid" "$cmd")"
    IFS=$'\t' read -r agent apid aargs <<<"$agent_line"
    if [ -n "$agent" ]; then
      icon_wids[$wid]=1
      found_agent=1
      [ "$(icon_for "$agent")" = "$icon" ] || tmux set-option -p -t "$pane" @agent_icon "$(icon_for "$agent")" 2>/dev/null
      [ "$(color_for "$agent")" = "$color" ] || tmux set-option -p -t "$pane" @agent_color "$(color_for "$agent")" 2>/dev/null

      key="${apid:-}|${aargs:-}"
      need=0
      if [ "${name_key[$pane]:-}" != "$key" ]; then
        need=1 # new agent in this pane: name it now
      elif [ "$refreshed" = 0 ] && [ "$events_on" = 1 ] && [ "$sess" = "$events_sess" ]; then
        # Input-driven drift refresh: retitle once the user has given the
        # agent a new instruction since the last title (counted by
        # agent-events.sh — the fresh prompt is still in the pane tail
        # for the titler). One pane per pass, per-pane and global
        # NAME_FLOOR; idle sessions never regenerate.
        if [ $((${ni:-0} - ${name_inputs[$pane]:-0})) -ge 1 ] &&
          [ $((now - ${name_time[$pane]:-0})) -ge "$NAME_FLOOR" ] &&
          [ $((now - last_drift)) -ge "$NAME_FLOOR" ]; then
          need=1
          refreshed=1
          last_drift="$now"
        fi
      elif [ "$refreshed" = 0 ] &&
        [ $((now - ${name_time[$pane]:-0})) -ge "$NAME_TTL" ] &&
        [ "${last_change[$pane]:-0}" -gt "${name_time[$pane]:-0}" ]; then
        # Fallback drift refresh (no listener): wall-clock TTL, and only
        # for panes whose content changed since they were last titled.
        need=1
        refreshed=1
      fi
      if [ "$need" = 1 ]; then
        name_key[$pane]="$key"
        name_time[$pane]="$now"
        name_inputs[$pane]="${ni:-0}"
        name_cache[$pane]="$(window_label "$pid" "$cmd" "$dir" "$title" "${aargs:-}" "$agent" "$pane")"
      fi

      # Any agent pane may supply the window name; a real task label
      # beats another pane's directory fallback.
      label="${name_cache[$pane]:-}"
      if [ -n "$label" ] && [ "${detected_real[$wid]:-}" != 1 ]; then
        detected[$wid]="$label"
        detected_real[$wid]=1
      fi
      [ -n "${detected[$wid]:-}" ] || detected[$wid]="${dir:0:$NAME_MAX}"
    elif [ -n "$icon" ]; then
      icon_wids[$wid]=1 # keep the window claimed until the stale check
      [ $((now - ${ts:-0})) -gt "$STALE_HOOK_SECS" ] && clear_pane "$pane"
    fi
  done < <(tmux list-panes -a -F '#{session_name}|#{window_id}|#{pane_id}|#{pane_pid}|#{pane_current_command}|#{@agent_icon}|#{@agent_color}|#{@agent_state_ts}|#{b:pane_current_path}|#{pane_title}|#{@agent_inputs}' 2>/dev/null)

  if [ "$found_agent" = 1 ] && [ "$events_on" = 0 ] && [ -x "$events_script" ]; then
    nohup "$events_script" >/dev/null 2>&1 & # singleton via its pidfile
  fi

  for pane in "${!name_key[@]}"; do # drop cache entries for dead panes
    if [ -z "${seen_panes[$pane]:-}" ]; then
      unset "name_key[$pane]" "name_cache[$pane]" "name_time[$pane]" "name_inputs[$pane]"
    fi
  done

  while IFS='|' read -r wid name auto named lock; do
    det="${detected[$wid]:-}"
    if [ "$RENAME_WINDOWS" = on ] && [ -n "$det" ]; then
      if [ "$name" != "$det" ] && [ "$lock" != 1 ] &&
        { [ "$auto" = 1 ] || [ "$named" = 1 ] || [ "$rename_manual" = on ]; }; then
        tmux rename-window -t "$wid" "$det" 2>/dev/null
        tmux set-option -w -t "$wid" @agent_named 1 2>/dev/null
      fi
    elif [ "$named" = 1 ] && [ -z "${icon_wids[$wid]:-}" ]; then
      tmux set-option -w -t "$wid" automatic-rename on 2>/dev/null
      tmux set-option -w -t "$wid" -u @agent_named 2>/dev/null
    fi
  done < <(tmux list-windows -a -F '#{window_id}|#{window_name}|#{automatic-rename}|#{@agent_named}|#{@agent_rename_lock}' 2>/dev/null)
}

# One-time migration: state used to be window-scoped; pane lookups would
# inherit stale window values.
while read -r wid; do
  for opt in @agent_ready @agent_icon @agent_color @agent_state_ts; do
    tmux set-option -w -t "$wid" -u "$opt" 2>/dev/null
  done
done < <(tmux list-windows -a -F '#{window_id}' 2>/dev/null)
tmux set-option -g -u @agent_spinner 2>/dev/null # legacy option
tmux set-option -g -u @agent_pulse 2>/dev/null   # stale value from a killed run

pulse=(236 239 242 245 248 250 248 245 242 239)

# The pulse runs in its own child process so a slow discover/naming pass
# can never freeze the animation (measured 1.7-2.2s stalls every 10s when
# it shared this loop). Frames are written to a persistent control-mode
# client instead of forking tmux per frame: under system load every fork
# pays exec + endpoint-security scanning (measured 50-250ms per frame on
# loadavg 35+), while a printf to an open connection costs nothing. The
# no-output flag keeps the pane event stream away from this client. It
# re-checks busy-ness and the client list about once a second and renders
# frames in between.
pulse_loop() {
  local i=0 pulsing=0 busy tty socket fifo cm_pid frame
  local -a ttys
  socket="$(tmux display -p '#{socket_path}' 2>/dev/null)"
  [ -n "$socket" ] || return
  fifo="$(mktemp -u "${TMPDIR:-/tmp}/agent-pulse-XXXXXX")"
  mkfifo "$fifo" || return
  (
    unset TMUX TMUX_PANE
    exec tmux -S "$socket" -C attach -f read-only,ignore-size,no-output <"$fifo" >/dev/null 2>&1
  ) &
  cm_pid=$!
  exec 8>"$fifo"
  rm -f "$fifo"
  trap 'kill "$cm_pid" 2>/dev/null' EXIT
  trap 'exit 143' TERM # the monitor stops us with TERM; the client must die too
  while :; do
    tmux has-session 2>/dev/null || break
    busy="$(tmux list-panes -a -F '#{?#{@agent_icon},#{@agent_ready},}' 2>/dev/null | grep -cx 0)"
    ttys=()
    while read -r tty; do
      [ -n "$tty" ] && ttys+=("$tty")
    done < <(tmux list-clients -F '#{client_tty}' 2>/dev/null)
    if [ "$busy" -gt 0 ]; then
      pulsing=1
      for _ in 1 2 3 4 5; do # ~1s of frames between busy re-checks
        i=$(((i + 1) % ${#pulse[@]}))
        frame="set-option -g @agent_pulse ${pulse[$i]}"$'\n'
        for tty in ${ttys[@]+"${ttys[@]}"}; do
          frame+="refresh-client -S -t ${tty}"$'\n'
        done
        printf '%s' "$frame" >&8 || return # painter died: monitor restarts us
        sleep "$PULSE_SLEEP"
      done
    else
      if [ "$pulsing" = 1 ]; then
        pulsing=0
        frame="set-option -gu @agent_pulse"$'\n'
        for tty in ${ttys[@]+"${ttys[@]}"}; do
          frame+="refresh-client -S -t ${tty}"$'\n'
        done
        printf '%s' "$frame" >&8 || return
      fi
      sleep 0.5
    fi
  done
}

declare -A last_hash act_runs last_change last_seen
client_ttys=()
events_on=0
last_reconcile=0
last_drift=0
next_discover=0
last_cw=""

pulse_loop &
pulse_pid=$!
cleanup_all() {
  kill "$pulse_pid" 2>/dev/null
  cleanup_lock
}
trap cleanup_all EXIT

while owns_lock; do
  tmux has-session 2>/dev/null || break
  now="$(date +%s)"

  if [ $((now - last_reconcile)) -ge "$RECONCILE_SECS" ]; then
    last_reconcile="$now"

    if ! kill -0 "$pulse_pid" 2>/dev/null; then
      pulse_loop & # painter or its control client died: relaunch
      pulse_pid=$!
    fi

    if [ "$now" -ge "$next_discover" ]; then
      next_discover=$((now + DISCOVER_EVERY))
      discover "$now"
      compute_wrap # renames change entry widths
    fi

    events_on=0
    events_sess=""
    events_alive && events_on=1 && events_sess="$(events_session)"

    while IFS='|' read -r sess pane ready icon state_ts pending; do
      [ -n "$icon" ] || continue

      if [ "$events_on" = 1 ] && [ "$sess" = "$events_sess" ]; then
        continue # agent-events.sh owns @agent_ready for this session
      fi

      hash="$(tmux capture-pane -p -t "$pane" 2>/dev/null | checksum)"
      gap=$((now - ${last_seen[$pane]:-0}))
      last_seen[$pane]="$now"
      if [ "${last_hash[$pane]:-}" != "$hash" ]; then
        last_hash[$pane]="$hash"
        last_change[$pane]="$now"
        act_runs[$pane]=$((${act_runs[$pane]:-0} + 1))
      else
        act_runs[$pane]=0
      fi
      if [ "$gap" -gt 3 ]; then
        # Observation gap (slow discover pass): timestamps are stale, so
        # this round only warms the tracking up — no state flips.
        continue
      fi

      if [ $((now - ${state_ts:-0})) -ge "$HOOK_GRACE" ]; then
        if pane_busy_marker "$pane"; then
          last_change[$pane]="$now"
          if [ "$ready" != 0 ]; then
            tmux set-option -p -t "$pane" @agent_ready 0 2>/dev/null
            ready=0
          fi
        elif [ "${act_runs[$pane]}" -ge "$BUSY_RUNS" ] && [ "$ready" != 0 ]; then
          tmux set-option -p -t "$pane" @agent_ready 0 2>/dev/null
          ready=0
        elif [ $((now - ${last_change[$pane]:-0})) -ge "$READY_AGE" ] &&
          [ "$ready" != 1 ] && [ -z "$pending" ]; then
          tmux set-option -p -t "$pane" @agent_ready 1 2>/dev/null
          ready=1
        fi
      fi
    done < <(tmux list-panes -a -F '#{session_name}|#{pane_id}|#{@agent_ready}|#{@agent_icon}|#{@agent_state_ts}|#{@agent_pending}' 2>/dev/null)

    client_ttys=()
    cur_cw=""
    while IFS='|' read -r flags tty w; do
      visible_client "$flags" "$tty" || continue
      client_ttys+=("$tty")
      if [ -n "$w" ] && { [ -z "$cur_cw" ] || [ "$w" -lt "$cur_cw" ]; }; then
        cur_cw="$w"
      fi
    done < <(tmux list-clients -F '#{client_flags}|#{client_tty}|#{client_width}' 2>/dev/null)
    if [ "$cur_cw" != "$last_cw" ]; then
      last_cw="$cur_cw"
      compute_wrap # client resized
    fi
  fi

  sleep "$RECONCILE_SECS"
done

kill "$pulse_pid" 2>/dev/null # stop the frame painter before clearing its option
wait "$pulse_pid" 2>/dev/null
tmux set-option -g -u @agent_pulse 2>/dev/null || true
# Preserve the last valid row split if the monitor is stopped unexpectedly.
# The options disappear naturally when the tmux server exits.
