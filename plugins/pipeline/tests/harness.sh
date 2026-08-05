#!/usr/bin/env bash
# Minimal assertion harness for the hook tests. Sourced by each test-*.sh file.
# Dependency-free bash so it runs anywhere the hooks themselves run.

set -u

HOOKS_DIR="${HOOKS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../hooks" && pwd)}"
PLUGIN_ROOT="${PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

TESTS_PASSED=0
TESTS_FAILED=0
CURRENT_SUITE=""

suite() {
  CURRENT_SUITE="$1"
  printf '\n%s\n' "$CURRENT_SUITE"
}

# ok <name> <condition-description> <actual> <expected>
assert_eq() {
  local name="$1" actual="$2" expected="$3"
  if [[ "$actual" == "$expected" ]]; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    printf '  ok    %s\n' "$name"
  else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf '  FAIL  %s\n        expected: %s\n        actual:   %s\n' "$name" "$expected" "$actual"
  fi
}

assert_contains() {
  local name="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    printf '  ok    %s\n' "$name"
  else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf '  FAIL  %s\n        expected to contain: %s\n        actual: %s\n' \
      "$name" "$needle" "$(printf '%s' "$haystack" | head -3)"
  fi
}

assert_not_contains() {
  local name="$1" haystack="$2" needle="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    printf '  ok    %s\n' "$name"
  else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf '  FAIL  %s\n        expected NOT to contain: %s\n' "$name" "$needle"
  fi
}

# Create a throwaway git repo. Echoes its path; caller removes it.
make_repo() {
  local dir
  dir=$(mktemp -d)
  git -C "$dir" init -q
  git -C "$dir" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  printf '%s' "$dir"
}

finish() {
  printf '\npassed=%s failed=%s\n' "$TESTS_PASSED" "$TESTS_FAILED"
  [[ "$TESTS_FAILED" -eq 0 ]]
}
