#!/usr/bin/env bash
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for test_script in "$TEST_DIR"/test-*.sh; do
  printf '\n==> %s\n' "${test_script##*/}"
  "$test_script"
done
