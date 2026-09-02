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

# ---- the assertion LEDGER: a counter that survives a subshell ----------------
#
# WHY A FILE. TESTS_PASSED/TESTS_FAILED are shell variables, so an assertion evaluated inside a
# `( ... )`, a `$( ... )` or a pipeline element increments a COPY that is discarded when that
# subshell exits. assert_* also returns 0 on both branches (the printf succeeds either way), so
# the subshell's own exit status carries nothing either. The result is an assertion that PRINTS
# its FAIL line and cannot fail the build: seven of them shipped in one suite, including two
# non-zero CONTROLs whose only job was to be falsifiable, and the suite reported failed=0.
#
# Every assertion therefore records itself HERE as well, by appending a line. A file append
# crosses a subshell boundary where a variable increment does not, so finish() can compare what
# was RECORDED against what was COUNTED and refuse the mismatch. $BASH_SUBSHELL (present in bash
# 3.2, which is what macOS ships) names the offenders rather than only reporting an arithmetic
# gap.
#
# NOT mktemp: test-harness.sh sources this file with a deliberately failing mktemp stub on PATH,
# and a harness that could not be sourced under that stub would break the suite that proves
# new_tmpdir refuses an empty path. $$ is the SUITE's pid and stays the suite's pid inside a
# subshell, which is exactly the scope wanted.
#
# The ledger FILE is created further down, once the temp registry it is removed through exists.
_ASSERT_LEDGER=""

# _ledger <ok|FAIL> <name>. Called AFTER the counter increment, so the recorded index is the
# value the incrementing shell saw.
_ledger() {
  [[ -n "$_ASSERT_LEDGER" ]] || return 0
  printf '%s\t%s\t%s\t%s\n' "$((TESTS_PASSED + TESTS_FAILED))" "$BASH_SUBSHELL" "$1" "$2" \
    >> "$_ASSERT_LEDGER" 2>/dev/null
  return 0
}

suite() {
  CURRENT_SUITE="$1"
  printf '\n%s\n' "$CURRENT_SUITE"
}

# ok <name> <condition-description> <actual> <expected>
assert_eq() {
  local name="$1" actual="$2" expected="$3"
  if [[ "$actual" == "$expected" ]]; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    _ledger ok "$name"
    printf '  ok    %s\n' "$name"
  else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    _ledger FAIL "$name"
    printf '  FAIL  %s\n        expected: %s\n        actual:   %s\n' "$name" "$expected" "$actual"
  fi
}

assert_contains() {
  local name="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    _ledger ok "$name"
    printf '  ok    %s\n' "$name"
  else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    _ledger FAIL "$name"
    printf '  FAIL  %s\n        expected to contain: %s\n        actual: %s\n' \
      "$name" "$needle" "$(printf '%s' "$haystack" | head -3)"
  fi
}

assert_not_contains() {
  local name="$1" haystack="$2" needle="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    _ledger ok "$name"
    printf '  ok    %s\n' "$name"
  else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    _ledger FAIL "$name"
    printf '  FAIL  %s\n        expected NOT to contain: %s\n' "$name" "$needle"
  fi
}

# ---- REPORTING lines, which are counted but are not tests --------------------
#
# A suite sometimes needs to put a MEASUREMENT in the transcript that has no pass/fail sense:
# which shell it found, what two constructs returned, that a remote lookup was unavailable. The
# shape reached for is `assert_eq "<name>" "reported" "reported"` -- an assertion whose two
# operands are the same literal, so it cannot fail. That reads in a green transcript exactly
# like a real assertion and reads in the ledger exactly like a real assertion, which is how a
# skipped column came to be indistinguishable from a passing one (#47).
#
# `record` is the honest spelling. It counts (so the ledger and the tally still agree) and it
# prints, but it claims nothing, and its name is what a reader greps for when asking which lines
# in this suite could never have gone red. Use it for a measurement; use assert_* for a claim.
record() {
  TESTS_PASSED=$((TESTS_PASSED + 1))
  _ledger ok "$1"
  printf '  ok    %s\n' "$1"
}

# ---- OPTIONAL CAPABILITIES: a population that shrinks must say so, and CI must refuse it -----
#
# THE DEFECT THIS EXISTS FOR (#47). Two suites carry a `[zsh]` column because zsh does not
# word-split an unquoted parameter expansion, and zsh is the shell the orchestrator runs -- that
# column is the regression test for the #17 VETO. Both opened the column with a bare
# `command -v zsh` and closed the else branch with a self-equal assertion. On ubuntu-latest,
# which has no zsh, the two suites ran 70 and 141 assertions against 78 and 165 locally: 32
# assertions vanished, both platforms printed failed=0, and both were green. The guarantee CI
# reported green on was the bash half only. Nothing compared the two totals, and the printed and
# counted numbers agreed on each platform, so the harness's own count guard could not see it
# either -- the POPULATION differed, not the accounting.
#
# THE RULE. A suite may run with a capability absent on a developer's machine. CI may not. So
# the answer is always RECORDED (the transcript names the tool and its state either way), and
# under PIPELINE_TESTS_REQUIRE_CAPABILITIES=1 -- which .github/workflows/tests.yml sets -- an
# absent capability becomes a counted FAILURE naming the tool, instead of a column that quietly
# does not exist.
#
# WHY NOT AN ASSERTED PER-PLATFORM COUNT, which is the other option #47 lists. An integer floor
# is the instrument #33 is open against: it decays every time the suite it guards legitimately
# grows, silently, because nothing forces the literal up -- measured twice already in this repo.
# A capability NAME does not decay, and it fails with the tool named rather than with a delta a
# reader has to interpret. With zsh installed on the runner the population no longer depends on
# the platform at all, which is the precondition #33's label-set pin needs to be stated once for
# every platform rather than once per platform.
CAPABILITY_STRICT="${PIPELINE_TESTS_REQUIRE_CAPABILITIES:-0}"

# optional_tool <name> -> 0 when <name> is on PATH, 1 when it is not.
# Emits exactly one line either way, so `if optional_tool zsh; then RUNNERS+=(zsh); fi` reads
# the way the bare `command -v` did and cannot skip in silence.
optional_tool() {
  local name="$1" state=absent
  command -v "$name" >/dev/null 2>&1 && state=present
  if [[ "$CAPABILITY_STRICT" == "1" ]]; then
    # The label carries the tool, not the verdict: this is the line that must be readable in a
    # CI log as "the column that covers the zsh half of the #17 veto did not run".
    assert_eq "CAPABILITY \`$name\` is present (strict: an absent tool SHRINKS this suite's population)" \
      "$state" "present"
  else
    record "CAPABILITY \`$name\` is $state (PIPELINE_TESTS_REQUIRE_CAPABILITIES=1, as CI sets, refuses an absent one)"
  fi
  [[ "$state" == "present" ]]
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

# ---- run records ------------------------------------------------------------
#
# write_run_record <file> <phase> [ago-ms]
#
# A SCHEMA-SHAPED, IN-FLIGHT status.json. It exists because #109 made the SubagentStop sweep
# resolve its scope by RUN OWNERSHIP rather than by newest status.json mtime, so a `{"current_
# phase":"2-review"}` stub -- which several suites used as a placeholder before that -- is no
# longer a run any consumer will own a stop for: it carries no `updated_at`, and an undatable
# record is deliberately never the resolved owner.
#
# `updated_at` IS WRITTEN AS CONTENT, NOT AS AN MTIME, and that is the whole point of the helper
# rather than a `touch`. The two clocks disagree by construction on the tree an adopting project
# checks out: a clone refreshes every mtime and touches no `updated_at`. A fixture that sets the
# recency it wants via `touch` is testing the wrong term and passes for the wrong reason.
write_run_record() {
  local file="$1" phase="$2" ago="${3:-60000}"
  mkdir -p "$(dirname "$file")"
  node -e '
    const fs = require("fs");
    const [, file, phase, ago] = process.argv;
    fs.writeFileSync(file, JSON.stringify({
      current_phase: phase,
      started_at: "2026-01-01T00:00:00Z",
      updated_at: new Date(Date.now() - Number(ago)).toISOString(),
      branch: "test-branch",
      events: [],
    }));' "$file" "$phase" "$ago"
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

# ---- the ledger FILE, created inside a directory this process proved it owns ----------------
#
# The earlier shape composed a PREDICTABLE path directly in a world-writable dir and opened it
# with truncation and no exclusivity (`: > "$path"`). MEASURED: with a symlink pre-placed at
# that name, a 49-byte file elsewhere on disk went to 9 bytes and came back holding this
# harness's own ledger line; the same run with no symlink left it byte-identical. TMPDIR is
# unset on ubuntu-latest, so the dir was literally /tmp, and the sticky bit does not help --
# it stops you deleting someone else's file, not creating an untaken name. run.sh is this
# project's checkCommand, which stop.sh executes at every dirty-tree turn end, and each
# run_child gets its own pid, so the blast radius is dozens of predictable names per run.
#
# mkdir is the fix that keeps the no-mktemp constraint above: it is atomic, it FAILS on an
# existing path, and it does not follow a symlink. The ledger then lives inside a dir this
# process is the only writer of. $RANDOM widens the name beyond the pid so a pre-placed
# squat has to win a race rather than read a counter.
_LEDGER_DIR="${TMPDIR:-/tmp}/.pipeline-harness.$$.${RANDOM}"
if mkdir -m 700 "$_LEDGER_DIR" 2>/dev/null; then
  TMP_REGISTRY="${TMP_REGISTRY}${_LEDGER_DIR}
"
  _ASSERT_LEDGER="$_LEDGER_DIR/ledger"
else
  # ANNOUNCE, do not refuse. An unwritable TMPDIR is a tooling condition in the operator's
  # environment, and a harness that refused over it would be the wrong fail direction (this is
  # a guard, not a prerequisite like require_node). But the DISARM must not be silent: measured
  # on the old shape, an identical suite carrying one genuinely uncounted assertion exited 1
  # with the offender named on a writable tmp and 0 with byte-identical stdout on an unwritable
  # one. The only signal was bash's own redirection diagnostic, which says nothing about the
  # guard and does not appear at all for a later append failure. Same shape as the once-per-
  # session disarm notice in hooks/session-start.sh, for the same reason.
  printf 'HARNESS: assertion ledger unavailable at %s; the uncounted-assertion guard is DISABLED for this suite.\n' \
    "$_LEDGER_DIR" >&2
fi

_cleanup_tmpdirs() {
  local rc=$? line registry="$TMP_REGISTRY"
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    _remove_owned_tmpdir "$line"
  done <<< "$registry"
  TMP_REGISTRY=""                      # idempotent: a second run removes nothing
  # The ledger needs no special case: its DIRECTORY is registered like any other, so the loop
  # above removed it by exact path through the same refusing helper.
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

# Every assertion this suite RAN, versus every assertion it COUNTED. A mismatch means at least
# one assert_* ran somewhere its increment could not survive -- a subshell, a command
# substitution, a pipeline element -- so its FAIL would print and the suite would still exit 0.
# That is an assertion which cannot fail the build, and it is indistinguishable from a passing
# one in the output. Reported as a FAILURE of the suite, because a suite whose count is wrong
# cannot support any claim about what it checked.
_assert_count_guard() {
  [[ -n "$_ASSERT_LEDGER" && -f "$_ASSERT_LEDGER" ]] || return 0
  local recorded counted
  recorded="$(grep -c . "$_ASSERT_LEDGER" | tr -d ' ')"
  counted=$((TESTS_PASSED + TESTS_FAILED))
  [[ "$recorded" -eq "$counted" ]] && return 0
  printf '\nHARNESS: %s assertion(s) ran but %s were counted.\n' "$recorded" "$counted" >&2
  printf 'An uncounted assertion prints its result and cannot fail the build.\n' >&2
  printf 'Ran outside the shell that owns the counters (level > 0):\n' >&2
  awk -F'\t' '$2 != 0 { printf "  [subshell level %s] %s  %s\n", $2, $3, $4 }' "$_ASSERT_LEDGER" >&2
  printf 'Scope the environment/cwd around the CHILD PROCESS, not around the assertion.\n' >&2
  return 1
}

finish() {
  printf '\npassed=%s failed=%s\n' "$TESTS_PASSED" "$TESTS_FAILED"
  _assert_count_guard || return 1
  [[ "$TESTS_FAILED" -eq 0 ]]
}

# copy_script_with_deps <scripts-dir> <script.mjs> <dest-dir>
# Copies a bundled script into a scratch dir ALONG WITH the shared lib.mjs it imports.
# A scratch copy missing lib.mjs dies with ERR_MODULE_NOT_FOUND, which reads as a failure of
# the behavior under test rather than of the fixture. Same false-red class as copying scripts/
# without its schemas/ sibling, which is already recorded in the bite-proof notes.
copy_script_with_deps() {
  local src_dir="$1" script="$2" dest="$3"
  cp "$src_dir/$script" "$dest/" || return 1
  cp "$src_dir/lib.mjs" "$dest/" || return 1
}
