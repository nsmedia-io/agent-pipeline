#!/usr/bin/env bash
# Minimal assertion harness for the hook tests. Sourced by each test-*.sh file.
# Dependency-free bash so it runs anywhere the hooks themselves run.

set -u

HOOKS_DIR="${HOOKS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../hooks" && pwd)}"
PLUGIN_ROOT="${PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# The .mjs scripts under test. This is a READ path into the checkout (the scripts live here);
# every root/output/cwd a test BINDS still resolves inside a per-case temp dir.
SCRIPTS_DIR="${SCRIPTS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd)}"

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
# Pre-existing helper, used by the three hook suites. Left exactly as it was: those suites
# keep their own inline rm -rf and are NOT refactored onto the guarded helper below.
make_repo() {
  local dir
  dir=$(mktemp -d)
  git -C "$dir" init -q
  git -C "$dir" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  printf '%s' "$dir"
}

# ---- node requirement -------------------------------------------------------
#
# DELIBERATE INVERSION of the hooks' fail-open posture. hooks/lib.sh (read_config) and
# hooks/session-start.sh:84 both gate their node calls behind `command -v node` and degrade
# QUIETLY on purpose: a hook that wedges a session over missing tooling is worse than a stale
# default. A TEST suite is the opposite case. run.sh is this repo's checkCommand and the Stop
# hook runs it at every dirty-tree turn end, so a suite that skipped silently when node is
# absent would report SUCCESS while every line of the .mjs scripts it gates went unexercised
# -- the "gate quietly stops firing" failure this suite exists to prevent.
# Do NOT "fix" this back to a silent skip by analogy with the hooks.
require_node() {
  if ! command -v node >/dev/null 2>&1; then
    printf 'FATAL: `node` is not on PATH, and %s tests the .mjs scripts that need it.\n' \
      "$(basename "${BASH_SOURCE[1]:-this suite}")" >&2
    printf '       Refusing to pass by skipping: a silent skip would leave run.sh green with the scripts untested.\n' >&2
    exit 91
  fi
}

# ---- guarded temp dirs: the ONLY destructive path in the new suites ----------
#
# Why one helper instead of a per-suite `rm -rf "$dir"`: a variable assigned from a FAILED
# mktemp is set-and-EMPTY, which `set -u` does NOT catch, so an inline `rm -rf "$dir"/*`
# expands to a removal at the filesystem root. Every removable path in the new suites is
# therefore created here, recorded here by EXACT path, and removed only from the single trap
# installed below. Suites added by this change must not call rm -rf themselves.
TMP_REGISTRY=""   # newline-delimited EXACT paths created by new_tmpdir (not a prefix test)
NEW_TMPDIR=""
TEMP_PROJECT=""
TEMP_ISSUE_DIR=""

_tmp_is_owned() {
  local needle="${1:-}" line
  [[ -n "$needle" ]] || return 1
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    [[ "$line" == "$needle" ]] && return 0
  done <<< "$TMP_REGISTRY"
  return 1
}

# The single destructive statement in this file. Refuses anything it does not own.
_remove_owned_tmpdir() {
  local d="${1:-}"
  if [[ -z "$d" ]]; then
    printf 'cleanup refused: empty path\n' >&2
    return 1
  fi
  if [[ "$d" == "/" ]]; then
    printf 'cleanup refused: will not remove "/"\n' >&2
    return 1
  fi
  if ! _tmp_is_owned "$d"; then
    printf 'cleanup refused: %s was not created by new_tmpdir\n' "$d" >&2
    return 1
  fi
  [[ -d "$d" ]] || return 0            # already gone: nothing to do
  rm -rf "$d"                          # the exact registered dir; never a "$d"/* glob
}

_cleanup_tmpdirs() {
  local rc=$? line registry="$TMP_REGISTRY"
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    _remove_owned_tmpdir "$line"
  done <<< "$registry"
  TMP_REGISTRY=""                      # idempotent: a second run removes nothing
  return $rc
}

# Sets NEW_TMPDIR to a fresh, registered temp dir. Returns non-zero (and registers nothing)
# when mktemp fails, so a caller can never proceed with an empty path.
# It sets a global rather than echoing because a `$(...)` capture runs in a SUBSHELL, where
# the registry update would be lost and the trap would then never own the dir it handed out.
new_tmpdir() {
  local d
  d=$(mktemp -d 2>/dev/null) || d=""
  if [[ -z "$d" || ! -d "$d" ]]; then
    NEW_TMPDIR=""
    printf 'FATAL: mktemp -d failed (TMPDIR=%s). Refusing to continue: an empty temp path is a destructive-cleanup hazard.\n' \
      "${TMPDIR:-<unset>}" >&2
    return 90
  fi
  # Canonicalize. On macOS $TMPDIR is reached through a symlink (/var -> /private/var), and a
  # LOGICAL path breaks any script that compares its own resolved module URL against
  # process.argv[1] (knowledge-store.mjs's entrypoint guard), producing a false failure that
  # has nothing to do with the behavior under test. `pwd -P` is portable; `readlink -f` is not
  # (BSD readlink has no -f).
  d=$(cd "$d" && pwd -P) || return 90
  TMP_REGISTRY="${TMP_REGISTRY}${d}
"
  NEW_TMPDIR="$d"
  return 0
}

# make_temp_project [<issue>] -> TEMP_PROJECT (registered temp dir usable as a project root)
#                               TEMP_ISSUE_DIR (<TEMP_PROJECT>/.pipeline/<issue>)
# Everything a node-backed case reads or writes lives under TEMP_PROJECT: pass it as
# --root / --output / CLAUDE_PROJECT_DIR and spawn with it as cwd. run.sh executes as the
# Stop-hook checkCommand at every dirty-tree turn end, i.e. DURING live pipeline runs, so a
# case that touched the checkout's own .pipeline/ or knowledge/ would corrupt real state.
make_temp_project() {
  local issue="${1:-1}"
  new_tmpdir || return 90
  TEMP_PROJECT="$NEW_TMPDIR"
  TEMP_ISSUE_DIR="$TEMP_PROJECT/.pipeline/$issue"
  mkdir -p "$TEMP_ISSUE_DIR"
}

# ONE trap, installed here, AFTER the registry is initialized, so no suite registers its own
# and no trap can fire against an unassigned variable. INT/TERM are covered as well as EXIT: a
# bare EXIT trap does not fire on ^C, and an interrupted run would leak temp dirs.
trap '_cleanup_tmpdirs' EXIT
trap '_cleanup_tmpdirs; exit 130' INT
trap '_cleanup_tmpdirs; exit 143' TERM

finish() {
  printf '\npassed=%s failed=%s\n' "$TESTS_PASSED" "$TESTS_FAILED"
  [[ "$TESTS_FAILED" -eq 0 ]]
}
