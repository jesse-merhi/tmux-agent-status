#!/usr/bin/env bash
# Install user-level Claude Code and Codex lifecycle hooks without replacing
# unrelated settings or hooks.
set -euo pipefail

plugin_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
hook_source="$plugin_root/scripts/agent-attention.sh"
hook_link="$HOME/.local/bin/tmux-agent-status-hook"
claude_settings="$HOME/.claude/settings.json"
codex_hooks="${CODEX_HOME:-$HOME/.codex}/hooks.json"

install_claude=0
install_codex=0
dry_run=0

usage() {
  cat <<'EOF'
Usage: scripts/install-hooks.sh [--all | --claude | --codex] [--dry-run]

Installs tmux-agent-status lifecycle hooks into the current user's Claude Code
and/or Codex configuration. The default is --all. Existing unrelated settings
and hooks are preserved; changed JSON files receive a timestamped backup.
EOF
}

while (($#)); do
  case "$1" in
    --all)
      install_claude=1
      install_codex=1
      ;;
    --claude)
      install_claude=1
      ;;
    --codex)
      install_codex=1
      ;;
    --dry-run)
      dry_run=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'install-hooks: unknown option: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

if ((install_claude == 0 && install_codex == 0)); then
  install_claude=1
  install_codex=1
fi

if ! command -v jq >/dev/null 2>&1; then
  printf 'install-hooks: jq is required to merge hook configuration safely.\n' >&2
  exit 1
fi

if [[ ! -x "$hook_source" ]]; then
  printf 'install-hooks: hook executable is missing: %s\n' "$hook_source" >&2
  exit 1
fi

hook_command() {
  local state="$1"
  local icon="${2:-}"
  local command
  # $HOME expands later in the agent's hook shell.
  # shellcheck disable=SC2016
  command='if [ -x "$HOME/.local/bin/tmux-agent-status-hook" ]; then TMUX_AGENT_STATUS_HOOK=1 "$HOME/.local/bin/tmux-agent-status-hook"'
  command+=" $state"
  if [[ -n "$icon" ]]; then
    command+=" '$icon'"
  fi
  command+='; fi; true'
  printf '%s' "$command"
}

backup_file() {
  local target="$1"
  local backup
  backup="$target.bak.$(date +%Y%m%d-%H%M%S).$$"
  cp -p "$target" "$backup"
  printf 'Backed up %s to %s\n' "$target" "$backup"
}

merge_json() {
  local target="$1"
  local filter="$2"
  shift 2

  local target_dir input output
  target_dir="$(dirname "$target")"
  input="$target"
  if [[ ! -f "$input" ]]; then
    input=/dev/null
  fi
  if ((dry_run)); then
    output="$(mktemp "${TMPDIR:-/tmp}/tmux-agent-status.XXXXXX")"
  else
    mkdir -p "$target_dir"
    output="$(mktemp "$target_dir/.tmux-agent-status.XXXXXX")"
  fi

  if [[ "$input" == /dev/null ]]; then
    if ! printf '{}\n' | jq "$@" "$filter" >"$output"; then
      rm -f "$output"
      return 1
    fi
  elif ! jq "$@" "$filter" "$input" >"$output"; then
    rm -f "$output"
    return 1
  fi

  if [[ -f "$target" ]] && cmp -s "$output" "$target"; then
    rm -f "$output"
    printf 'Already configured: %s\n' "$target"
    return 0
  fi

  if ((dry_run)); then
    rm -f "$output"
    printf 'Would update %s\n' "$target"
    return 0
  fi

  if [[ -f "$target" ]]; then
    backup_file "$target"
  fi
  mv "$output" "$target"
  printf 'Updated %s\n' "$target"
}

install_hook_link() {
  if [[ -L "$hook_link" && "$(readlink "$hook_link")" == "$hook_source" ]]; then
    printf 'Already linked: %s\n' "$hook_link"
    return 0
  fi
  if [[ -e "$hook_link" || -L "$hook_link" ]]; then
    printf 'install-hooks: refusing to replace existing path: %s\n' "$hook_link" >&2
    return 1
  fi
  if ((dry_run)); then
    printf 'Would link %s -> %s\n' "$hook_link" "$hook_source"
    return 0
  fi
  mkdir -p "$(dirname "$hook_link")"
  ln -s "$hook_source" "$hook_link"
  printf 'Linked %s -> %s\n' "$hook_link" "$hook_source"
}

marker='TMUX_AGENT_STATUS_HOOK=1'
# $marker is a jq variable in this filter, not a shell variable.
# shellcheck disable=SC2016
strip_filter='def without_agent_status:
  map(.hooks = ((.hooks // []) | map(select((((.command // "") | contains($marker))) | not))))
  | map(select((.hooks | length) > 0));'

if ((install_claude)) && [[ -f "$claude_settings" ]] && ! jq empty "$claude_settings" >/dev/null; then
  printf 'install-hooks: refusing to modify invalid JSON: %s\n' "$claude_settings" >&2
  exit 1
fi
if ((install_codex)) && [[ -f "$codex_hooks" ]] && ! jq empty "$codex_hooks" >/dev/null; then
  printf 'install-hooks: refusing to modify invalid JSON: %s\n' "$codex_hooks" >&2
  exit 1
fi

install_hook_link

if ((install_claude)); then
  claude_filter="$strip_filter
    .hooks //= {} |
    .hooks.SessionStart = ((.hooks.SessionStart // [] | without_agent_status) + [{hooks: [{type: \"command\", command: \$register, timeout: 5, async: true}]}]) |
    .hooks.UserPromptSubmit = ((.hooks.UserPromptSubmit // [] | without_agent_status) + [{hooks: [{type: \"command\", command: \$busy, timeout: 5, async: true}]}]) |
    .hooks.Stop = ((.hooks.Stop // [] | without_agent_status) + [{hooks: [{type: \"command\", command: \$claude_stop, timeout: 5, async: true}]}]) |
    .hooks.StopFailure = ((.hooks.StopFailure // [] | without_agent_status) + [{hooks: [{type: \"command\", command: \$ready, timeout: 5, async: true}]}]) |
    .hooks.Notification = ((.hooks.Notification // [] | without_agent_status) + [{matcher: \"permission_prompt|idle_prompt|agent_needs_input|agent_completed\", hooks: [{type: \"command\", command: \$ready, timeout: 5, async: true}]}]) |
    .hooks.SessionEnd = ((.hooks.SessionEnd // [] | without_agent_status) + [{hooks: [{type: \"command\", command: \$off, timeout: 3}]}])"
  merge_json "$claude_settings" "$claude_filter" \
    --arg marker "$marker" \
    --arg register "$(hook_command register '✳')" \
    --arg busy "$(hook_command busy '✳')" \
    --arg claude_stop "$(hook_command claude-stop '✳')" \
    --arg ready "$(hook_command ready '✳')" \
    --arg off "$(hook_command off)"
fi

if ((install_codex)); then
  codex_filter="$strip_filter
    .description //= \"User lifecycle hooks.\" |
    .hooks //= {} |
    .hooks.SessionStart = ((.hooks.SessionStart // [] | without_agent_status) + [{hooks: [{type: \"command\", command: \$register, timeout: 5}]}]) |
    .hooks.UserPromptSubmit = ((.hooks.UserPromptSubmit // [] | without_agent_status) + [{hooks: [{type: \"command\", command: \$busy, timeout: 5}]}]) |
    .hooks.Stop = ((.hooks.Stop // [] | without_agent_status) + [{hooks: [{type: \"command\", command: \$ready, timeout: 5}]}]) |
    .hooks.SessionEnd = ((.hooks.SessionEnd // [] | without_agent_status) + [{hooks: [{type: \"command\", command: \$off, timeout: 3}]}])"
  merge_json "$codex_hooks" "$codex_filter" \
    --arg marker "$marker" \
    --arg register "$(hook_command register '⬢')" \
    --arg busy "$(hook_command busy '⬢')" \
    --arg ready "$(hook_command ready '⬢')" \
    --arg off "$(hook_command off)"
fi

if ((install_codex)); then
  printf 'Codex requires one manual trust step: start Codex, open /hooks, and trust the new user hooks.\n'
fi
