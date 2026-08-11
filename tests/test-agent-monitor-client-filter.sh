#!/usr/bin/env bash
# Behavior test for the client filter used by agent-monitor.sh wrap logic.
set -u

SCRIPT="$(cd "$(dirname "$0")/../scripts" && pwd)/agent-monitor.sh"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}
pass() { printf 'ok: %s\n' "$1"; }

[ -x "$SCRIPT" ] || fail "agent-monitor.sh missing or not executable at $SCRIPT"

actual="$(
  AGENT_MONITOR_SELFTEST=visible-clients "$SCRIPT" <<'EOF'
attached,focused,control-mode,ignore-size,read-only,UTF-8||80
attached,focused,control-mode,ignore-size,no-output,read-only,UTF-8||80
attached,focused,UTF-8|/dev/ttys012|349
attached,focused,UTF-8||80
EOF
)"

[ "$actual" = 349 ] || fail "visible client widths were '$actual' (wanted 349)"
pass "control-mode and tty-less clients ignored for wrap width"

printf 'ALL TESTS PASSED\n'
