#!/usr/bin/env bash
# Runs every hook test suite. Exit 0 only when all pass.
#
# Wire this as your checkCommand to gate the plugin's own development:
#   { "checkCommand": "bash plugins/pipeline/tests/run.sh" }
set -u

cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1

FAILED=0
for t in test-*.sh; do
  [[ -f "$t" ]] || continue
  printf '\n\033[1m== %s ==\033[0m\n' "$t"
  bash "$t" || FAILED=$((FAILED + 1))
done

printf '\n'
if [[ "$FAILED" -eq 0 ]]; then
  printf 'All hook suites passed.\n'
  exit 0
fi
printf '%s suite(s) FAILED.\n' "$FAILED"
exit 1
