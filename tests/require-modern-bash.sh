#!/usr/bin/env bash

require_modern_bash() {
  if [ "${BASH_VERSINFO[0]:-0}" -ge 5 ]; then
    return 0
  fi

  for candidate in "${AGENT_STATUS_BASH:-}" /opt/homebrew/bin/bash /usr/local/bin/bash; do
    [ -n "$candidate" ] && [ -x "$candidate" ] || continue
    if "$candidate" -c '((BASH_VERSINFO[0] >= 5))' 2>/dev/null; then
      exec "$candidate" "$0" "$@"
    fi
  done

  printf 'Bash 5 or newer is required. Set AGENT_STATUS_BASH to its path.\n' >&2
  return 1
}
