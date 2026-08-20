#!/usr/bin/env bash
# The claims about issue #17's own DELIVERY that no unit suite can make: that the new suites
# are actually RUN, that CI runs them, that the commits split the way the spec requires, that
# the documentation corrections landed, and that the pinned gate suite still passes untouched.
#
# Every one of these is a place where a correct artifact can exist and change nothing. A suite
# run.sh's flat glob never reaches reports the same green as no suite at all; a workflow that
# exists is not a workflow that runs; a commit series that looks separable is not one that
# reverts cleanly.

. "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
require_node

make_temp_project || exit 90

PLUGIN_DIR="$PLUGIN_ROOT"
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$PLUGIN_DIR/../.." && pwd)"
PIPELINE_MD="$PLUGIN_DIR/commands/pipeline.md"

NEW_SUITES="test-data-layer-surface.sh test-mis-tier-tripwire.sh test-dispatch-model-resolver.sh test-dispatch-model-sites.sh test-config-doctor-surfaces.sh test-pipeline-telemetry.sh test-issue17-integration.sh"

# run.sh's discovery rule is READ OUT OF run.sh and EXPANDED, never re-derived inline. Three
# assertions below used to spell the glob themselves, and every one of them was unfalsifiable in
# both directions: widening run.sh to `for t in test-*.sh fixtures/*.sh; do` left the two
# fixture-placement guards printing 0 and still satisfied an `assert_contains` for
# "for t in test-*.sh", and a planted tests/test-zz-planted.sh produced 0 from both guards too.
# An assertion that cannot print anything but its expected value is a deleted assertion wearing
# a green tick, so the rule is extracted once here and every consumer uses this one reading.
run_sh_patterns() {  # <run.sh> -> the literal glob patterns from its discovery line
  sed -n 's/^[[:space:]]*for t in \(.*\); do[[:space:]]*$/\1/p' "$1" | head -1
}
discovered_by() {  # <tests dir> <patterns> -> the files run.sh would run, one per line
  ( cd "$1" && eval "for t in $2; do [ -f \"\$t\" ] && printf '%s\n' \"\$t\"; done" )
}
discovered_outside_flat() {  # <tests dir> <patterns> -> discovered names that are not flat in it
  local dir="$1"
  local pats="$2"
  local t
  local out=""
  while IFS= read -r t; do
    [[ -n "$t" ]] || continue
    case "$t" in */*) out="$out $t" ;; esac
  done < <(discovered_by "$dir" "$pats")
  printf '%s' "$out"
}
discovered_under() {  # <tests dir> <patterns> <abs subdir> -> discovered names resolving inside it
  local dir="$1"
  local pats="$2"
  local sub="$3"
  local t
  local d
  local out=""
  while IFS= read -r t; do
    [[ -n "$t" ]] || continue
    d="$(cd "$dir/$(dirname "$t")" 2>/dev/null && pwd)" || continue
    [[ "$d" == "$sub" ]] && out="$out $t"
  done < <(discovered_by "$dir" "$pats")
  printf '%s' "$out"
}

# =============================================================================
# AC35 -- THE NEW SUITES ACTUALLY RUN.
# =============================================================================
suite "AC35: run.sh's flat glob reaches every suite this change adds"

# Verified against run.sh's OWN discovery rule, executed here, rather than by reading the
# filenames: the rule is a flat `test-*.sh` glob with no recursion, so a suite one directory
# down is a file nobody runs. run.sh itself is not invoked, because run.sh invokes THIS file:
# the recursion would never terminate, and a suite that skipped itself to avoid that would be
# the self-skip this repo refuses. The glob is therefore reproduced from run.sh's source line.
#
# EQUALITY on the extracted patterns, not containment. `assert_contains ... "for t in test-*.sh"`
# was satisfied by the widened line `for t in test-*.sh fixtures/*.sh; do`, which is exactly the
# drift this assertion exists to refuse.
RUN_PATTERNS="$(run_sh_patterns "$TESTS_DIR/run.sh")"
assert_eq "run.sh's discovery line was READ, and it is exactly the flat test-*.sh glob" \
  "$RUN_PATTERNS" "test-*.sh"
assert_eq "and it has no recursive discovery that could reach a subdirectory instead" \
  "$(grep -c 'find\|\*\*/' "$TESTS_DIR/run.sh" | tr -d ' ')" "0"

MISSED=""
for s in $NEW_SUITES; do
  [[ -f "$TESTS_DIR/$s" ]] || { MISSED="$MISSED $s(absent)"; continue; }
  # The exact expansion run.sh performs, in the directory run.sh cd's to.
  ( cd "$TESTS_DIR" && for t in test-*.sh; do [[ "$t" == "$s" ]] && exit 0; done; exit 1 ) || MISSED="$MISSED $s"
done
assert_eq "every suite this change adds is reached by that expansion" "$MISSED" ""
# NON-ZERO CONTROL: the same check must be able to report a MISS, or the empty string above is
# a statement about a loop that never looked.
( cd "$TESTS_DIR" && for t in test-*.sh; do [[ "$t" == "nested/test-not-reachable.sh" ]] && exit 0; done; exit 1 )
assert_eq "CONTROL: the same expansion does NOT reach a suite in a subdirectory" "$?" "1"

# And the transcript claim itself: run.sh prints each suite's name as it runs it.
assert_contains "run.sh prints the suite name it is about to run" \
  "$(grep '== %s ==' "$TESTS_DIR/run.sh")" "printf"

# =============================================================================
# AC41 -- CI ACTUALLY RUNS THE SUITE.
# =============================================================================
suite "AC41: a workflow runs run.sh on pull_request and on push to main"

WF_DIR="$REPO_ROOT/.github/workflows"
WF_MATCHES="$(grep -rl 'plugins/pipeline/tests/run.sh' "$WF_DIR" 2>/dev/null | grep -c . | tr -d ' ')"
WF_WITH_SUITE="$(grep -rl 'plugins/pipeline/tests/run.sh' "$WF_DIR" 2>/dev/null | head -1)"
assert_eq "at least one workflow invokes tests/run.sh (a rename cannot silently drop it)" \
  "$([[ -n "$WF_WITH_SUITE" ]] && echo yes || echo "no: nothing in .github/workflows runs the suite")" "yes"
# `head -1` is only honest while there is nothing to choose between. Two workflows running the
# suite would leave every assertion below describing whichever sorted first, and a second one
# added with a broken trigger would be invisible here forever.
assert_eq "and exactly one does, so the head -1 below is not silently picking a winner" \
  "$WF_MATCHES" "1"
WF_TWO="$TEMP_PROJECT/two-workflows"
mkdir -p "$WF_TWO"
printf 'run: bash plugins/pipeline/tests/run.sh\n' > "$WF_TWO/a.yml"
printf 'run: bash plugins/pipeline/tests/run.sh\n' > "$WF_TWO/b.yml"
assert_eq "CONTROL: the same count reports 2 when two files match, so the 1 above is a measurement" \
  "$(grep -rl 'plugins/pipeline/tests/run.sh' "$WF_TWO" 2>/dev/null | grep -c . | tr -d ' ')" "2"
assert_contains "the run step is the exact command" "$(cat "$WF_WITH_SUITE")" "bash plugins/pipeline/tests/run.sh"
assert_contains "it triggers on pull_request" "$(cat "$WF_WITH_SUITE")" "pull_request"
assert_contains "and on push to main" "$(cat "$WF_WITH_SUITE")" "branches: [main]"
assert_not_contains "with no install step (matching the repo's dependency-free CI constraint)" \
  "$(cat "$WF_WITH_SUITE")" "npm install"
assert_not_contains "and no package.json dependency" "$(cat "$WF_WITH_SUITE")" "npm ci"

# The file must PARSE as YAML, not merely exist. No YAML parser ships with node, so the
# structural properties are asserted directly: a top-level `on:` with both triggers, a `jobs:`
# mapping, and a `run:` step under it, each at its expected indentation.
assert_eq "the workflow has a top-level on: trigger block" \
  "$(grep -c '^on:$' "$WF_WITH_SUITE" | tr -d ' ')" "1"
assert_eq "and a top-level jobs: block" "$(grep -c '^jobs:$' "$WF_WITH_SUITE" | tr -d ' ')" "1"
assert_eq "and the command sits under a run: key inside a step" \
  "$(grep -c '^        run: bash plugins/pipeline/tests/run.sh$' "$WF_WITH_SUITE" | tr -d ' ')" "1"
# BSD grep has no -P, and a `grep -cP` that ERRORS prints nothing, which would have compared
# an empty string to "0" forever. The tab is matched as a literal character instead.
TAB="$(printf '\t')"
assert_eq "no tab characters (YAML forbids them, and a tab makes the file unparseable)" \
  "$(grep -c "$TAB" "$WF_WITH_SUITE" | tr -d ' ')" "0"
TABPROBE="$TEMP_PROJECT/tab-probe.yml"
printf 'a:\n\tb: c\n' > "$TABPROBE"
assert_eq "CONTROL: the same check DOES find a tab when one is present" \
  "$(grep -c "$TAB" "$TABPROBE" | tr -d ' ')" "1"

suite "AC41(b) GATE-BITES PROOF: run.sh exits NON-ZERO on a failing assertion, which is what fails the job"

# The job fails when its `run:` command exits non-zero; that is the runner's contract, and the
# half this suite can OBSERVE is the other one: that run.sh really does exit non-zero when a
# suite inside it fails. Proven by PLANTING a failing assertion and watching the exit code
# move, then removing it and watching it move back.
#
# The planted defect goes in a MINIMAL scratch tests tree (run.sh, harness.sh, one planted
# suite, one passing control), never in the checkout and never in a full copy of tests/. Two
# reasons, both learned here: an interrupted battery that left a planted defect in a tracked
# file is a documented way to ship one, and a full copy would contain THIS suite, whose own
# proof copies the tree again -- unbounded recursion that ran for five minutes before it was
# killed.
BITE="$TEMP_PROJECT/bite-tests"
mkdir -p "$BITE"
cp "$TESTS_DIR/run.sh" "$TESTS_DIR/harness.sh" "$BITE/"
cat > "$BITE/test-passing-control.sh" <<'EOF'
. "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
suite "control"
assert_eq "this assertion passes" "x" "x"
finish
EOF

( bash "$BITE/run.sh" >/dev/null 2>&1 )
assert_eq "the scratch tree starts GREEN, so the red below is the plant and not the fixture" "$?" "0"

cat > "$BITE/test-planted-failure.sh" <<'EOF'
. "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
suite "planted"
assert_eq "this assertion is planted and must fail" "actual" "expected"
finish
EOF
assert_eq "the plant really landed (the file the glob will reach exists)" \
  "$([[ -f "$BITE/test-planted-failure.sh" ]] && echo yes || echo no)" "yes"
BITE_OUT="$( bash "$BITE/run.sh" 2>&1 )"
BITE_RC="$?"
assert_eq "run.sh exits NON-ZERO with the planted failure present: the CI job goes red" "$BITE_RC" "1"
assert_contains "and it names the failing suite in its transcript" "$BITE_OUT" "test-planted-failure.sh"
assert_contains "and reports the failure count rather than swallowing it" "$BITE_OUT" "1 suite(s) FAILED"

rm -f "$BITE/test-planted-failure.sh"
( bash "$BITE/run.sh" >/dev/null 2>&1 )
assert_eq "and the SAME tree exits 0 once the plant is removed" "$?" "0"

# Backticks are DELIBERATELY absent from this title. Written as "the SAME `local` statement"
# inside a double-quoted argument, the shell ran `local` as a command substitution and printed
# "local: can only be used in a function" to stderr, leaving the suite header with a hole in it.
suite 'AC41(d): no suite reads a variable declared in the SAME local statement'

# The construct that made this suite pass here and fail in CI, and it is worth a detector
# because the two shells disagree SILENTLY in one direction:
#
#   local sha="$1" wt="pre-${sha:0:7}"
#
# bash 3.2 (macOS, where these suites are written) expands ${sha} to the EMPTY string -- no
# error, a quietly wrong value. bash 5 (ubuntu-latest, where CI runs them) trips `set -u` with
# "sha: unbound variable", the enclosing function returns NOTHING, and six assertions compared
# against an empty string that was neither of the two answers the function can give. A local
# green therefore said nothing about the runner.
same_local_offenders() {  # <file>... -> count of offending statements
  local n=0
  local f line trimmed seg names rest v prior
  for f in "$@"; do
    while IFS= read -r line; do
      trimmed="${line#"${line%%[![:space:]]*}"}"
      # A line that is PROSE about the construct is not the construct. This file documents the
      # defect in its own comments and builds it as a printf fixture, and a detector that
      # counted those would be un-passable for the wrong reason -- the same self-counting trap
      # the AC5 grep in test-mis-tier-tripwire.sh already had to sidestep.
      case "$trimmed" in '#'*) continue ;; esac
      case "$line" in *local\ *) ;; *) continue ;; esac
      # One LINE can hold several statements. Split on `;` so `f() { local a=$1; local b=$a; }`
      # is read as the two statements it is, then strip through a block-opening `{ ` so the
      # one-line function body is reached. Brace-SPACE, never a bare brace: splitting on `{`
      # alone tore `${sha:0:7}` in half and the detector reported zero on the exact line it
      # exists to catch. A `local` inside a quoted string is NOT reliably invisible, which is
      # the opposite of what this comment used to claim: a multi-line `printf 'f() {\n local'`
      # fixture has no brace-SPACE and is skipped, but the one-line `printf 'f() { local'`
      # spelling does, and it counted. The detector is deliberately left conservative -- it
      # cannot tell code from a string literal and should not pretend to -- so the construct
      # is kept out of the shipped suites entirely and lives in fixtures/ instead.
      while IFS= read -r seg; do
        seg="${seg##*\{ }"
        seg="${seg#"${seg%%[![:space:]]*}"}"
        case "$seg" in "local "*) ;; *) continue ;; esac
        names=""
        # Walk the assignments left to right; an expansion naming a variable assigned EARLIER
        # in the SAME statement is the defect. Reading a GLOBAL is fine and common.
        for v in ${seg#local }; do
          case "$v" in
            *=*)
              rest="${v#*=}"
              for prior in $names; do
                case "$rest" in *"\$$prior"*|*"\${$prior"*) n=$((n + 1)); break ;; esac
              done
              names="$names ${v%%=*}"
              ;;
            *) names="$names $v" ;;
          esac
        done
      done < <(printf '%s\n' "$line" | tr ';' '\n')
    done < "$f"
  done
  printf '%s' "$n"
}
assert_eq "no shipped suite or hook carries the construct" \
  "$(same_local_offenders "$TESTS_DIR"/*.sh "$PLUGIN_DIR"/hooks/*.sh)" "0"
# NON-ZERO CONTROL for the detector, in the exact shape that broke, or the zero above is a
# statement about a walk that cannot see anything.
LOCAL_PROBE="$TEMP_PROJECT/same-local-probe.sh"
printf 'f() {\n  local sha="$1" wt="$T/revert-${sha:0:7}"\n  echo "$wt"\n}\n' > "$LOCAL_PROBE"
assert_eq "CONTROL: the same detector reports 1 for the exact line that broke CI" \
  "$(same_local_offenders "$LOCAL_PROBE")" "1"
# ...and it does NOT report the split form, or it would refuse every correct spelling too.
LOCAL_OK="$TEMP_PROJECT/split-local-probe.sh"
printf 'f() {\n  local sha="$1"\n  local wt="$T/revert-${sha:0:7}"\n  echo "$wt"\n}\n' > "$LOCAL_OK"
assert_eq "CONTROL: and reports 0 for the split form, so it is not refusing all locals" \
  "$(same_local_offenders "$LOCAL_OK")" "0"
# ...nor the ordinary multi-assignment that only reads GLOBALS, which several suites use.
LOCAL_GLOBAL="$TEMP_PROJECT/global-local-probe.sh"
printf 'f() {\n  local outf="$TEMP_PROJECT/out.txt" errf="$TEMP_PROJECT/err.txt"\n  echo "$outf $errf"\n}\n' > "$LOCAL_GLOBAL"
assert_eq "CONTROL: and reports 0 when both assignments read a global" \
  "$(same_local_offenders "$LOCAL_GLOBAL")" "0"
# ...and it reaches a ONE-LINE function body, which is where the `;`-split plus block-opening
# `{ ` strip earns its keep. Without that reach the detector is blind to the commonest way to
# write the defect compactly, and its zero above would cover less than it appears to.
#
# THE ONE-LINE PAIR IS ON DISK IN fixtures/, not built by printf here, and that placement is
# the fix for a self-counting bug rather than a preference. The detector strips through a
# block-opening `{ `, so a printf format string spelling `f() { local a="$1" b="${a:0:3}" }`
# put a countable segment inside this file: the zero it must reach was unreachable while the
# fixture lived here, and the comment above claiming a quoted fixture "never counts itself"
# was true only of the multi-line `{\n` spellings. fixtures/ is outside the flat tests/*.sh
# population the assertion walks and outside run.sh's discovery glob, so the construct exists
# exactly once, in a file whose whole purpose is to carry it. The detector is untouched.
FIXTURES_DIR="$TESTS_DIR/fixtures"
assert_eq "the one-line fixture pair exists (both controls below measure nothing without it)" \
  "$([[ -f "$FIXTURES_DIR/same-local-oneline.sh" && -f "$FIXTURES_DIR/split-local-oneline.sh" ]] \
     && echo both || echo "MISSING under $FIXTURES_DIR")" "both"
assert_eq "CONTROL: the detector reaches the defect written as a one-line function body" \
  "$(same_local_offenders "$FIXTURES_DIR/same-local-oneline.sh")" "1"
assert_eq "CONTROL: and reports 0 for the same body split in two, so it is not refusing the spelling" \
  "$(same_local_offenders "$FIXTURES_DIR/split-local-oneline.sh")" "0"
# And the fixtures are NOT in the population the assertion above walks, or that zero is a
# statement about a detector pointed away from the only files that carry the construct.
#
# BOTH HALVES READ run.sh's OWN discovery line (via run_sh_patterns, defined at the top of this
# file) and EXPAND IT. The previous spelling re-derived the glob inline -- `for t in test-*.sh;
# do [[ "$t" == fixtures/* ]]` -- so it could not print anything but 0 no matter what run.sh
# said. Two reviewers found it independently and both proved it: widening run.sh to
# `for t in test-*.sh fixtures/*.sh; do` left the integration suite at 93/0, and planting
# tests/test-zz-planted.sh returned 0 from both guards. The property is real and is genuinely
# covered by the run.sh-source read at the top of AC35; what was missing was any way for THESE
# two lines to fail.
assert_eq "run.sh's discovery line was read here too (an empty extraction reaches nothing, forever)" \
  "$([[ -n "$RUN_PATTERNS" ]] && echo read || echo "EXTRACTION FAILED")" "read"
assert_eq "every suite run.sh discovers is flat in tests/, i.e. inside the population the ratchet walks" \
  "$(discovered_outside_flat "$TESTS_DIR" "$RUN_PATTERNS")" ""
assert_eq "and no fixture is reached by run.sh's own rule, so neither is ever run as a suite" \
  "$(discovered_under "$TESTS_DIR" "$RUN_PATTERNS" "$FIXTURES_DIR")" ""
# NON-ZERO CONTROL, and it is the exact mutation that walked past the previous spelling. The
# widened copy is built in the scratch project and its CHANGED LINE IS ASSERTED first: a
# substitution that silently matched nothing would otherwise pass as a control while proving
# that a rule identical to the real one reaches no fixture.
WIDE_RUN="$TEMP_PROJECT/wide-run.sh"
sed 's|^for t in test-\*\.sh; do$|for t in test-*.sh fixtures/*.sh; do|' "$TESTS_DIR/run.sh" > "$WIDE_RUN"
assert_eq "the widened copy really carries the wider rule" \
  "$(run_sh_patterns "$WIDE_RUN")" "test-*.sh fixtures/*.sh"
assert_contains "CONTROL: that widened rule reaches a file outside the ratchet's flat population" \
  "$(discovered_outside_flat "$TESTS_DIR" "$(run_sh_patterns "$WIDE_RUN")")" "fixtures/same-local-oneline.sh"
assert_contains "CONTROL: and it reaches the fixtures, so the two empty results above are verdicts" \
  "$(discovered_under "$TESTS_DIR" "$(run_sh_patterns "$WIDE_RUN")" "$FIXTURES_DIR")" "fixtures/same-local-oneline.sh"

# The behavioural half, EXECUTED rather than described, and executed by the same interpreter
# this suite is running under (`$BASH`, not whatever `bash` PATH resolves to -- the two differ
# on any machine with a newer bash installed alongside the system one, and the expectation
# below is version-dependent).
#
# PINNED PER SHELL, not merely "the two spellings differ". The looser version was satisfied by a
# fixture that never ran the function at all: QA deleted the `f abcdefg` invocation, leaving the
# construct on disk and unexecuted, and the detector still counted 1, SAME_OUT was empty,
# "differs" held, the suite stayed 93/0, and the transcript printed the measurement `[]` on a
# PASSING line. A demo that passes without demonstrating anything is not a demo.
#
# Each shell's outcome is stated in full instead, which needs no guess about the runner because
# the two behaviours are properties of the two bashes:
#   bash 3.2 declares both names before assigning, so ${a} is set-and-empty and the answer is a
#     quietly wrong "pre-", with a zero exit -- the reason a local run said nothing about CI;
#   bash 4+ leaves `a` unset until its own assignment, so `set -u` aborts the script, stdout is
#     empty and the exit is non-zero.
# Both arms pin stdout AND the exit status, so an unexecuted fixture reddens on whichever shell
# is running rather than passing on both.
SPLIT_OUT="$("${BASH:-bash}" "$FIXTURES_DIR/split-local-oneline.sh" 2>/dev/null)"
SPLIT_RC=$?
SAME_OUT="$("${BASH:-bash}" "$FIXTURES_DIR/same-local-oneline.sh" 2>/dev/null)"
SAME_RC=$?
assert_eq "the split form produces the value it is supposed to, in this shell" "$SPLIT_OUT" "pre-abc"
assert_eq "and it exits 0, so the correct spelling really ran" "$SPLIT_RC" "0"
if [[ "${BASH_VERSINFO[0]}" -le 3 ]]; then
  assert_eq "PINNED on bash ${BASH_VERSINFO[0]}: the same-statement form returns the quietly wrong 'pre-'" \
    "$SAME_OUT" "pre-"
  assert_eq "and exits 0, which is exactly why the wrongness is silent on this shell" "$SAME_RC" "0"
else
  assert_eq "PINNED on bash ${BASH_VERSINFO[0]}: the same-statement form returns NOTHING" "$SAME_OUT" ""
  assert_eq "and exits NON-ZERO, because set -u aborts the script before it can print" \
    "$([[ "$SAME_RC" -ne 0 ]] && echo non-zero || echo "ZERO (rc=$SAME_RC)")" "non-zero"
fi
assert_eq "and either way it is NOT the value the correct spelling produces" \
  "$([[ "$SAME_OUT" == "$SPLIT_OUT" ]] && echo "SAME: the construct is harmless on bash ${BASH_VERSINFO[0]}" || echo differs)" \
  "differs"
# Both readings are REPORTED, and they go in the assertion NAME rather than in its two operands:
# the harness prints the name on a pass and the operands only on a FAILURE, so a value carried in
# the operands of a self-equal assertion is visible exactly when the run went red. That is
# backwards for a line whose only job is to tell a reader of a GREEN transcript what was measured.
assert_eq "MEASURED under bash-${BASH_VERSINFO[0]}: the split form returned [$SPLIT_OUT], the same-statement form [$SAME_OUT]" \
  "reported" "reported"

suite "AC41(c): run.sh passes in a FRESH CHECKOUT, not only in the worktree it was written in"

# "The suite passes" meant "in this worktree" for the whole life of this branch, and the two
# are not the same statement. A fresh clone has no untracked files and, before this change, no
# corpus for the telemetry partition to walk; a shallow one has no commit series for the AC24
# reverts to find. Both were true of CI, which was RED from the commit that added it while
# every local run was green. This case makes the two statements the same one.
#
# ONE LEVEL OF NESTING, bounded by an environment variable rather than by a comment: the inner
# run.sh runs this same file, and an unguarded clone-and-run recurses forever. The inner run
# reports that it deferred, so the guard is visible in the transcript instead of being a silent
# skip. Cost: this roughly doubles run.sh's wall time, which is the price of the statement.
if [[ -n "${PIPELINE_TESTS_FRESH_CHECKOUT:-}" ]]; then
  assert_eq "nested run: the fresh-checkout case defers to the OUTER run (one level, by design)" \
    "deferred" "deferred"
else
  FRESH="$TEMP_PROJECT/fresh-checkout"
  # `file://` forces a real clone rather than a local-directory copy, which is what a CI
  # checkout is. --no-hardlinks so the clone cannot share objects with the source.
  git clone -q --no-hardlinks "file://$REPO_ROOT" "$FRESH" >/dev/null 2>&1
  # `git clone` copies refs/heads and refs/tags and NOTHING ELSE, so the source's
  # refs/remotes/origin/main does not come with it: the clone of a checkout that HAS origin/main
  # does not have one. Several suites resolve their base through that ref, so it is copied over
  # explicitly. When the source has no origin/main either, this fails and the assertion below
  # REPORTS that rather than the suite failing somewhere further downstream with a bad revision.
  git -C "$FRESH" fetch -q --no-tags "file://$REPO_ROOT" \
    '+refs/remotes/origin/main:refs/remotes/origin/main' >/dev/null 2>&1
  assert_eq "the fresh checkout was created (without this, every assertion below measures nothing)" \
    "$([[ -f "$FRESH/plugins/pipeline/tests/run.sh" ]] && echo cloned || echo "clone FAILED")" "cloned"
  assert_eq "and it is a DIFFERENT tree from the one under test, with no untracked files carried over" \
    "$(cd "$FRESH" && git status --porcelain | wc -l | tr -d ' ')" "0"
  # It must also carry the commit series, because that is the other half of what CI lacked.
  assert_eq "it carries more than one commit, so the AC24 series lookups can resolve" \
    "$([[ "$(git -C "$FRESH" log --oneline | wc -l | tr -d ' ')" -ge 2 ]] && echo ">=2" || echo "SHALLOW")" ">=2"
  assert_eq "and origin/main resolves in it, which is what the diff-based blocks need" \
    "$(git -C "$FRESH" rev-parse --verify origin/main >/dev/null 2>&1 && echo resolves || echo MISSING)" "resolves"

  FRESH_OUT="$(PIPELINE_TESTS_FRESH_CHECKOUT=1 bash "$FRESH/plugins/pipeline/tests/run.sh" </dev/null 2>&1)"
  FRESH_RC="$?"
  assert_eq "run.sh exits 0 in the fresh checkout" "$FRESH_RC" "0"
  assert_contains "and says so" "$FRESH_OUT" "All test suites passed."
  # NON-ZERO CONTROL for that exit code: a run that produced nothing also exits 0 on some
  # shapes, so the transcript is checked against the population it should have covered. Every
  # test-*.sh in the fresh tree must have reported a result line.
  FRESH_SUITES="$(cd "$FRESH/plugins/pipeline/tests" && ls test-*.sh | wc -l | tr -d ' ')"
  assert_eq "every suite in the fresh tree reported a result (a silent run is not a passing run)" \
    "$(printf '%s' "$FRESH_OUT" | grep -c '^passed=' | tr -d ' ')" "$FRESH_SUITES"
  # The inner failure is NAMED, and its assertions are echoed. Counting "23 of 24 reported
  # failed=0" tells a reader that something inside a run they cannot see went red and nothing
  # else -- which is precisely what happened on the CI run that produced this change: the case
  # failed once, passed on a rerun of the identical tree, and left no way to tell WHICH suite
  # flaked. A gate that goes red without saying why is a gate someone eventually switches off.
  failed_suites_in() {  # run.sh transcript on STDIN -> names of the suites that reported a failure
    sed -E 's/'"$(printf '\033')"'\[[0-9;]*m//g' \
      | awk '/^== test-.*\.sh ==$/{name=$2} /^passed=/{ if ($0 !~ /failed=0$/) printf "%s ", name }'
  }
  FRESH_FAILED_SUITES="$(printf '%s\n' "$FRESH_OUT" | failed_suites_in)"
  assert_eq "and every one of them reported zero failures" \
    "$([[ -z "$FRESH_FAILED_SUITES" ]] && echo all-green || echo "RED INSIDE THE CLONE: $FRESH_FAILED_SUITES")" \
    "all-green"
  if [[ -n "$FRESH_FAILED_SUITES" ]]; then
    printf '        inner failures from the fresh checkout:\n%s\n' \
      "$(printf '%s\n' "$FRESH_OUT" | grep -A3 '  FAIL' | head -40)"
  fi
  # The count is kept alongside the names: a transcript whose suite headers were mangled would
  # yield an empty name list and an "all-green" that means nothing.
  #
  # ANCHORED TO THE RESULT LINE, not to the substring anywhere in the transcript. An unanchored
  # `grep -c failed=0` counts any ASSERTION NAME that happens to quote the token, and the
  # #30 suites carry two ("AC19: the gate suite reports failed=0" and its telemetry twin), so
  # the count read 31 against 29 suites and this case went red while every suite was green. The
  # guard belonged on the line the runner emits, not on the spelling that reaches the pipe.
  assert_eq "and the failed=0 count agrees with the suite count, independently of the names" \
    "$(printf '%s' "$FRESH_OUT" | grep -c '^passed=.*failed=0$' | tr -d ' ')" "$FRESH_SUITES"
  # NON-ZERO CONTROL for the extractor, through the SAME function: it must be able to name a
  # failure, and must not name a suite that passed.
  assert_eq "CONTROL: the same extractor names the failing suite in a transcript that has one" \
    "$(printf '== test-alpha.sh ==\npassed=3 failed=0\n== test-beta.sh ==\npassed=2 failed=1\n' | failed_suites_in)" \
    "test-beta.sh "
  assert_eq "CONTROL: and names nothing in an all-green transcript" \
    "$(printf '== test-alpha.sh ==\npassed=3 failed=0\n' | failed_suites_in)" ""
  assert_eq "the fresh tree has the same number of suites as this one, so none went missing in the clone" \
    "$FRESH_SUITES" "$(cd "$TESTS_DIR" && ls test-*.sh | wc -l | tr -d ' ')"
  # The guard is OBSERVED, not assumed: the inner run must have taken the deferred branch, or
  # this case is silently recursing.
  assert_contains "the inner run took the nesting guard, so this is one level deep and not many" \
    "$FRESH_OUT" "the fresh-checkout case defers to the OUTER run"
fi

# =============================================================================
# AC24 -- THE COMMITS SPLIT THE WAY THE SPEC REQUIRES.
# =============================================================================
suite "AC24: the commit order, and each revert applying cleanly on its own"

# THE WINDOW IS DELIMITED BY SUBJECT AT BOTH ENDS, and that is the whole reason this block
# survives its own merge. It used to read `merge-base origin/main HEAD`..HEAD, which is the
# BRANCH'S development range and therefore describes nothing once the branch lands: on main the
# merge-base and HEAD are the same commit, the range is empty, every sha_of below returned "",
# eighteen assertions went red and the suite then died on an unbound array before it could print
# a passed= line. A range expressed against a ref that MOVES cannot outlive the merge that moves
# it, and `gh pr merge --rebase` rewrites every sha on the way in, so pinning shas would not have
# helped either. That is a defect in the assertion, not in the merge choice.
#
# What a rebase DOES preserve is each commit's SUBJECT and their ORDER. So the series is named by
# the subject of its first commit and the subject of its last, resolved against FULL history, and
# every lookup below reads that one fixed window. The same two subjects select the same two
# commits before the merge, after a rebase merge, and on a pull_request build whose HEAD is a
# merge commit this branch never authored -- which also retires the --no-merges HEAD-tip dance
# that case used to need. Nothing here reads origin/main any more.
SERIES_FIRST_SUBJECT='test: author failing behavioral contract for the data-layer surface'
SERIES_LAST_SUBJECT="docs: the delta block's round-1 anchor cannot be run as a redirection"

subject_shas_from() {  # <start-ish> <subject substring> -> matching shas reachable from it, newest first
  git -C "$REPO_ROOT" log --format='%H %s' "$1" 2>/dev/null | grep -F "$2" | cut -d' ' -f1
}
SERIES_FIRST_SHA="$(subject_shas_from HEAD "$SERIES_FIRST_SUBJECT" | head -1)"
SERIES_HEAD_SHA="$(subject_shas_from HEAD "$SERIES_LAST_SUBJECT" | head -1)"
BASE="$(git -C "$REPO_ROOT" rev-parse --verify "${SERIES_FIRST_SHA:-no-such-rev}^" 2>/dev/null)"
LOG="$(git -C "$REPO_ROOT" log --reverse --no-merges --format='%H %s' "$BASE".."${SERIES_HEAD_SHA:-no-such-rev}" 2>/dev/null)"
sha_of() { printf '%s\n' "$LOG" | grep -m1 -F "$1" | cut -d' ' -f1; }
pos_of() { printf '%s\n' "$LOG" | grep -n -F "$1" | head -1 | cut -d: -f1; }

# The window is asserted BEFORE anything is looked up inside it. An unresolved delimiter yields an
# empty LOG, and every assertion downstream then compares one empty string against another --
# which is exactly the shape that let this suite die quietly rather than say what was wrong.
assert_eq "the series' FIRST commit resolves by subject (the window starts nowhere without it)" \
  "$([[ -n "$SERIES_FIRST_SHA" ]] && echo found || echo "UNRESOLVED: $SERIES_FIRST_SUBJECT")" "found"
assert_eq "and its LAST commit does too" \
  "$([[ -n "$SERIES_HEAD_SHA" ]] && echo found || echo "UNRESOLVED: $SERIES_LAST_SUBJECT")" "found"
assert_eq "the first delimiter names exactly ONE commit, so the window cannot open at the wrong one" \
  "$(subject_shas_from HEAD "$SERIES_FIRST_SUBJECT" | grep -c . | tr -d ' ')" "1"
assert_eq "and the last names exactly one, so it cannot close at the wrong one" \
  "$(subject_shas_from HEAD "$SERIES_LAST_SUBJECT" | grep -c . | tr -d ' ')" "1"
assert_eq "the window holds the whole series (a truncated window would sweep cleanly over nothing)" \
  "$(printf '%s\n' "$LOG" | grep -c . | tr -d ' ')" "31"

# THE MERGE-SURVIVAL PROPERTY ITSELF, executed rather than described: the window must resolve to
# the same commits no matter WHAT HEAD is, because that independence is the fix. Walking from the
# series head instead of from HEAD is the same question a post-merge main, a pull_request merge
# HEAD, and a future main carrying unrelated work all ask.
window_size_from() {  # <start-ish> -> commit count of the subject-delimited window, or UNRESOLVED
  local start="$1"
  local first
  local last
  first="$(subject_shas_from "$start" "$SERIES_FIRST_SUBJECT" | head -1)"
  last="$(subject_shas_from "$start" "$SERIES_LAST_SUBJECT" | head -1)"
  [[ -n "$first" && -n "$last" ]] || { printf 'UNRESOLVED'; return 0; }
  git -C "$REPO_ROOT" log --no-merges --format=%H "$first^..$last" 2>/dev/null | grep -c . | tr -d ' '
}
assert_eq "the window resolves identically when walked from the series head rather than from HEAD" \
  "$(window_size_from "$SERIES_HEAD_SHA")" "$(window_size_from HEAD)"
# NON-ZERO CONTROL: the same resolver must be able to report that it could NOT find the series, or
# the agreement above is a statement about a function that says the same thing everywhere.
assert_eq "CONTROL: the same resolver reports UNRESOLVED from a commit that predates the series" \
  "$(window_size_from "$BASE")" "UNRESOLVED"

CI_SHA="$(sha_of 'ci: run the plugin test suite')"
SURFACE_SHA="$(sha_of 'feat: one data-layer surface module')"
TABLE_SHA="$(sha_of 'feat: one dispatch routing table')"

assert_eq "the branch carries all three commits this criterion is about" \
  "$([[ -n "$CI_SHA" && -n "$SURFACE_SHA" && -n "$TABLE_SHA" ]] && echo found || echo "missing: ci=$CI_SHA surface=$SURFACE_SHA table=$TABLE_SHA")" \
  "found"
assert_eq "the CI workflow commit lands FIRST, so the suites are covered as they land" \
  "$([[ "$(pos_of 'ci: run the plugin test suite')" -lt "$(pos_of 'feat: one data-layer surface module')" ]] && echo first || echo not-first)" "first"
assert_eq "then the surface module, then the routing table" \
  "$([[ "$(pos_of 'feat: one data-layer surface module')" -lt "$(pos_of 'feat: one dispatch routing table')" ]] && echo ordered || echo out-of-order)" "ordered"

# Each revert is asserted SEPARATELY and in its own scratch clone. A single combined
# assertion cannot distinguish a clean split from a lucky one, and reverting in the working
# tree would leave the checkout mutated if the suite were interrupted.
#
# THE ANCHOR IS THE IMPLEMENTATION SERIES TIP, NOT HEAD, and that is a correction rather than a
# convenience. R17's property is that the implementation splits into independently revertable
# units -- that each commit is separable from the OTHER COMMITS IN ITS OWN SERIES. Anchoring at
# HEAD silently widens it to "and from every repair anyone ever lands on top", which is not
# separability and is not achievable: a Phase 4 fix round that repairs a line a commit
# introduced MUST conflict with reverting that commit, because the two edits are the same
# lines. (Round 1 of this issue's panel did exactly that to the four panel-composition call
# sites the surface commit added.) Anchored here, the assertion keeps measuring the split it
# was written for and stops changing its answer every time a later round touches the file.
SERIES_TIP_SHA="$(sha_of 'test: repair two unsatisfiable assertions')"
assert_eq "the implementation series tip is identifiable (without it the reverts below anchor nowhere)" \
  "$([[ -n "$SERIES_TIP_SHA" ]] && echo found || echo "missing")" "found"

revert_touches() { # <sha> -> "clean:<files>" | "NOWORKTREE" | "CONFLICT"
  # SPLIT `local` declarations, deliberately. `local sha="$1" wt="...${sha:0:7}"` does NOT see
  # `sha` in the same statement: bash 3.2 (macOS, where this was written) expanded it to the
  # empty string and every probe silently shared one worktree path, while bash 5 (the CI runner)
  # tripped `set -u` with "sha: unbound variable" and the function returned NOTHING -- neither
  # clean: nor CONFLICT -- so six assertions compared against an empty string. That is the whole
  # reason this suite passed here and failed there.
  local sha="$1"
  local wt="$TEMP_PROJECT/revert-${sha:0:7}"
  git -C "$REPO_ROOT" worktree add -q --detach "$wt" "${SERIES_TIP_SHA:-HEAD}" >/dev/null 2>&1 || { printf 'NOWORKTREE'; return 0; }
  if git -C "$wt" revert --no-commit --no-edit "$sha" >/dev/null 2>&1; then
    printf 'clean:%s' "$(git -C "$wt" diff --cached --name-only | tr '\n' ' ')"
  else
    printf 'CONFLICT'
  fi
  git -C "$wt" revert --abort >/dev/null 2>&1
  git -C "$REPO_ROOT" worktree remove --force "$wt" >/dev/null 2>&1
}

TABLE_REVERT="$(revert_touches "$TABLE_SHA")"
assert_eq "reverting the routing-table commit applies cleanly" \
  "$([[ "$TABLE_REVERT" == clean:* ]] && echo clean || echo "$TABLE_REVERT")" "clean"
assert_not_contains "and it does not touch the surface module" "$TABLE_REVERT" "data-layer-surface.mjs"
assert_not_contains "nor the CI workflow" "$TABLE_REVERT" ".github/workflows"

SURFACE_REVERT="$(revert_touches "$SURFACE_SHA")"
assert_eq "reverting the surface-module commit applies cleanly" \
  "$([[ "$SURFACE_REVERT" == clean:* ]] && echo clean || echo "$SURFACE_REVERT")" "clean"
assert_not_contains "and it does not touch the CI workflow" "$SURFACE_REVERT" ".github/workflows"
# NON-ZERO CONTROL for the probe: it must be able to report a non-clean result, or "clean"
# twice is a statement about a function that always says clean.
assert_eq "CONTROL: the same probe reports CONFLICT for a sha that cannot be reverted here" \
  "$(revert_touches "$(git -C "$REPO_ROOT" hash-object -t commit /dev/null 2>/dev/null || echo 0000000000000000000000000000000000000000)")" \
  "CONFLICT"
# ...and it is a CONFLICT rather than a NOWORKTREE, i.e. the probe got as far as running
# `git revert`. Without this the control above is satisfied by a probe that never built a
# worktree at all, which is exactly the state CI was in.
assert_not_contains "and it got far enough to actually attempt the revert" \
  "$(revert_touches "$(git -C "$REPO_ROOT" hash-object -t commit /dev/null 2>/dev/null || echo 0000000000000000000000000000000000000000)")" \
  "NOWORKTREE"

suite "AC24: each Phase 4 fix ROUND splits the same way, anchored at its own round's tip"

# ANCHORED PER ROUND, not at HEAD, and this is the second time the same correction has been
# needed. R17's property is that a series splits into independently revertable units -- each
# commit separable from the OTHER COMMITS IN ITS OWN SERIES. Anchoring a round's commits at
# HEAD silently widens that to "and from every later round too", which is not the property and
# is not achievable: round 2 repaired lines round 1 had introduced (the surface probes in
# commands/pipeline.md, the telemetry corpus), so reverting a round-1 commit at a round-2 HEAD
# MUST conflict. Measured: four of the six round-1 commits conflicted the moment round 2
# landed. The assertion was right and its anchor had gone stale. Anchoring each round at its
# own tip keeps every round measuring the split it was written for, forever.
revert_touches_at() { # <anchor-ish> <sha> -> "clean:<files>" | "NOWORKTREE" | "CONFLICT"
  # Split for the same reason as revert_touches above, and the two failure causes are now told
  # apart: an unusable ANCHOR and an unrevertable COMMIT are different problems, and collapsing
  # both to CONFLICT let a control pass for the wrong reason.
  local anchor="$1"
  local sha="$2"
  local wt="$TEMP_PROJECT/revert-at-${anchor:0:7}-${sha:0:7}"
  git -C "$REPO_ROOT" worktree add -q --detach "$wt" "$anchor" >/dev/null 2>&1 || { printf 'NOWORKTREE'; return 0; }
  if git -C "$wt" revert --no-commit --no-edit "$sha" >/dev/null 2>&1; then
    printf 'clean:%s' "$(git -C "$wt" diff --cached --name-only | tr '\n' ' ')"
  else
    printf 'CONFLICT'
  fi
  git -C "$wt" revert --abort >/dev/null 2>&1
  git -C "$REPO_ROOT" worktree remove --force "$wt" >/dev/null 2>&1
}

# Each round's tip, by subject. ROUND 2 has nothing after it, so its anchor is HEAD.
ROUND1_TIP_SHA="$(sha_of 'test: decouple the HEAD-anchored revert probe')"
assert_eq "the round-1 tip is identifiable (without it the round-1 reverts below anchor nowhere)" \
  "$([[ -n "$ROUND1_TIP_SHA" ]] && echo found || echo missing)" "found"

# NON-ZERO CONTROL FOR THE PROBE ITSELF, and it is the assertion this section shipped without.
# QA replaced revert_touches_at with a version that never created a worktree and never ran
# `git revert`, returning a bare `clean:` every time: 63 passed, 0 failed, nothing caught it.
# The two assert_not_contains companions below passed VACUOUSLY on that empty file list, which
# is the documented shape of a `not.toContain` over a population nothing ever fills. Both holes
# are closed here: the probe must be OBSERVED reporting CONFLICT, and the file lists it returns
# must be observed NON-EMPTY before anything is asserted absent from them.
EMPTY_TREE_SHA="$(git -C "$REPO_ROOT" hash-object -t commit /dev/null 2>/dev/null || echo 0000000000000000000000000000000000000000)"
assert_eq "CONTROL: the probe reports CONFLICT for a sha that cannot be reverted here" \
  "$(revert_touches_at "$SERIES_HEAD_SHA" "$EMPTY_TREE_SHA")" "CONFLICT"
assert_eq "CONTROL: and it reports NOWORKTREE for an anchor that does not exist, rather than a bare clean:" \
  "$(revert_touches_at 'no-such-anchor-ref' "$(sha_of 'fix: panel composition seats the specialist')")" \
  "NOWORKTREE"

# R17 applies to a fix round too. Each commit is looked up by subject, so the loop reports which
# one is missing rather than measuring an empty sha.
ROUND1_SUBJECTS=(
  'fix: panel composition seats the specialist'
  'fix: telemetry attributes suffixed phase labels'
  'docs: scope the upgrade note to Markdown'
  'fix: a role-level dispatchModels key cannot flatten'
  'fix: tripwireReport no longer returns a hit'
  'docs: worktree_path is omitted from status.json'
)
# A ROUND IS DELIMITED BY ITS TIP. This is the THIRD correction to this section's anchor, and the
# first two both moved the anchor without CLOSING the round, which is why the same red came back:
# "round 2 is everything after round 1" silently absorbs round 3, so round 3's repairs to lines
# round 2 introduced are reported as round 2 failing R17. They are the same lines. The conflict is
# arithmetic, not a defect, and it arrived on schedule every time a new round landed.
#
# EVERY ROUND IS CLOSED NOW, including the last, and that is what the merge changed. While the
# branch was live the newest round could not be listed -- a hand-maintained list cannot contain
# its own last commit, since adding that entry needs a further commit that becomes the new last
# one -- so it was derived open-endedly as "everything after the last closed tip, up to HEAD".
# That derivation is what broke on main: it is a range against a moving ref, it went empty the
# moment the branch merged, and an empty round then failed its own non-emptiness guard and left
# OPEN_ROUND_SHAS unset under `set -u`. The merge also DISSOLVED the reason for it. The series is
# frozen between two fixed commits now, nothing can be inserted into it, so its last commit is
# nameable and is named below. No round is derived open-endedly any more, and the accounting
# assertion further down proves the four tips partition the window with nothing left over -- so
# closing the last round is not a way to stop checking it.
#
# This also retires the pull_request special case. The old derivation ran to HEAD, and on a
# pull_request build actions/checkout checks out a MERGE of the branch into the base, so HEAD was
# a commit this branch never authored: it appeared in the derived set, could not be reverted
# without -m, and was reported as a round commit failing R17. A window that ends at a named
# subject never sees that merge commit at all.
CLOSED_ROUND_TIPS=(
  'test: decouple the HEAD-anchored revert probe'                       # round 1 tip
  'fix: the telemetry partition counts the events it dropped'           # round 2 tip
  'docs: the README checkCommand default was a promise'                 # round 3 tip
  "$SERIES_LAST_SUBJECT"                                                # round 4 tip = series head
)
round_commits() {  # <from-ish> <to-ish> -> one sha per line, oldest first
  git -C "$REPO_ROOT" log --reverse --no-merges --format='%H' "$1".."$2" 2>/dev/null
}

# SUPERSEDED PAIRS: `<superseded subject>||<repairing subject>`, both in the same round.
#
# Generalising the loop over WHOLE rounds turned up a pair the previous, narrower population
# never looked at: round 1's written subject list named six fix commits and silently omitted the
# two test commits at the end, one of which repairs the other. A commit whose lines a later
# commit rewrites cannot be reverted at a tip that contains the rewrite -- the same arithmetic
# that makes a round un-revertable at a later round's tip, one level down.
#
# The pair is EXEMPTED FROM THE TIP CHECK AND CHECKED HARDER SOMEWHERE ELSE, because an
# exemption nobody can falsify is just a deleted assertion: the superseded commit must revert
# cleanly at the PARENT of its repairer (it was separable right up to the repair), the repairer
# must really touch a file the superseded commit touched (or the exemption is unearned), and the
# two must sit in that order. Adding a line here is therefore not a way to quiet a red.
SUPERSEDED_PAIRS=(
  'test: assert the Phase 4 fix round is separately revertable per R17||test: decouple the HEAD-anchored revert probe'
)
is_superseded() {  # <sha> -> 0 when this commit is the superseded half of a listed pair
  local sha="$1"
  local pair
  for pair in "${SUPERSEDED_PAIRS[@]}"; do
    [[ "$(sha_of "${pair%%||*}")" == "$sha" ]] && return 0
  done
  return 1
}
# FIRST-MATCH FRAGILITY, closed here rather than left to the corpus. sha_of and pos_of resolve a
# commit by grepping the log for a SUBSTRING of its subject and taking the first hit, so two
# commits whose subjects share that substring resolve silently to the older one and every
# assertion downstream measures a commit nobody named. Every lookup in this file is 1:1 today
# BECAUSE OF WHICH COMMITS HAPPEN TO EXIST, which is a fact about this branch and not a property
# of the lookup; a later round that repeats a subject prefix would go green while checking the
# wrong commit. The uniqueness is therefore asserted, so that day is a red rather than a silence.
#
# The subject list is DERIVED from this file, not hand-maintained: every literal sha_of/pos_of
# argument, plus the three subject collections that reach those functions by variable. A lookup
# added later is covered without anyone remembering to add it here.
subject_hits() {  # <subject substring> -> how many commits on the branch it matches
  printf '%s\n' "$LOG" | grep -c -F "$1" | tr -d ' '
}
AMBIGUOUS=""
UNRESOLVED=""
SUBJECTS_CHECKED=0
while IFS= read -r subj; do
  [[ -n "$subj" ]] || continue
  SUBJECTS_CHECKED=$((SUBJECTS_CHECKED + 1))
  HITS="$(subject_hits "$subj")"
  case "$HITS" in
    1) ;;
    0) UNRESOLVED="$UNRESOLVED|$subj" ;;
    *) AMBIGUOUS="$AMBIGUOUS|$HITS commits match [$subj]" ;;
  esac
done < <(
  { grep -oE "(sha_of|pos_of) '[^']+'" "${BASH_SOURCE[0]}" | sed "s/^[a-z_]* '//" | sed "s/'\$//"
    printf '%s\n' "${ROUND1_SUBJECTS[@]}" "${CLOSED_ROUND_TIPS[@]}"
    for pair in "${SUPERSEDED_PAIRS[@]}"; do printf '%s\n%s\n' "${pair%%||*}" "${pair##*||}"; done
  } | sort -u
)
assert_eq "the subject sweep has a population to be about (a zero-subject sweep reports no ambiguity forever)" \
  "$([[ "$SUBJECTS_CHECKED" -ge 12 ]] && echo ">=12" || echo "ONLY $SUBJECTS_CHECKED SUBJECTS")" ">=12"
assert_eq "every subject this suite looks up matches exactly one commit, so grep -m1 cannot pick the wrong one" \
  "$AMBIGUOUS" ""
assert_eq "and every one of them resolves at all" "$UNRESOLVED" ""
# NON-ZERO CONTROLS in both directions, or the two empty strings above are statements about a
# counter that always says 1.
assert_eq "CONTROL: the same counter reports more than one for a substring the subjects share" \
  "$([[ "$(subject_hits '(#17)')" -ge 2 ]] && echo ">=2" || echo "ONLY $(subject_hits '(#17)')")" ">=2"
assert_eq "CONTROL: and zero for a subject no commit on this branch carries" \
  "$(subject_hits 'chore: a subject no commit on this branch carries')" "0"

LAST_CLOSED_SUBJECT="${CLOSED_ROUND_TIPS[${#CLOSED_ROUND_TIPS[@]}-1]}"
LAST_CLOSED_SHA="$(sha_of "$LAST_CLOSED_SUBJECT")"
check_round() { # <anchor> <subject>... -> "all-clean" | "missing:..." | "conflicts:..."
  local anchor="$1"; shift
  local s sha missing="" conflicts=""
  for s in "$@"; do
    sha="$(sha_of "$s")"
    if [[ -z "$sha" ]]; then missing="$missing|$s"; continue; fi
    [[ "$(revert_touches_at "$anchor" "$sha")" == clean:* ]] || conflicts="$conflicts|$s"
  done
  if [[ -n "$missing" ]]; then printf 'missing:%s' "$missing"
  elif [[ -n "$conflicts" ]]; then printf 'conflicts:%s' "$conflicts"
  else printf 'all-clean'; fi
}

assert_eq "every round-1 commit is on the branch and reverts cleanly at the round-1 tip" \
  "$(check_round "$ROUND1_TIP_SHA" "${ROUND1_SUBJECTS[@]}")" "all-clean"
# EVERY CLOSED ROUND, each at its OWN tip, derived from the delimiter list rather than named
# commit by commit. Round 1 keeps its written subject list above because that list documents
# what the panel reviewed; this loop is the property, and it covers rounds the list never named.
CLOSED_BASE="$SERIES_TIP_SHA"
CLOSED_CONFLICTS=""
CLOSED_CHECKED=0
CLOSED_N=0
SUPERSEDED_SEEN=0
# Which TIP each exempted commit was skipped at, so the necessity check below can re-run the
# exact comparison the exemption suppressed rather than a nearby one.
SUPERSEDED_AT=""
for subj in "${CLOSED_ROUND_TIPS[@]}"; do
  CLOSED_N=$((CLOSED_N + 1))
  TIP="$(sha_of "$subj")"
  if [[ -z "$TIP" ]]; then CLOSED_CONFLICTS="$CLOSED_CONFLICTS|round $CLOSED_N tip NOT ON BRANCH: $subj"; continue; fi
  while IFS= read -r h; do
    [[ -n "$h" ]] || continue
    CLOSED_CHECKED=$((CLOSED_CHECKED + 1))
    if is_superseded "$h"; then
      SUPERSEDED_SEEN=$((SUPERSEDED_SEEN + 1))
      SUPERSEDED_AT="$SUPERSEDED_AT $h:$TIP"
      continue
    fi
    [[ "$(revert_touches_at "$TIP" "$h")" == clean:* ]] \
      || CLOSED_CONFLICTS="$CLOSED_CONFLICTS|round $CLOSED_N: $(git -C "$REPO_ROOT" log -1 --format=%s "$h") [$(revert_touches_at "$TIP" "$h")]"
  done < <(round_commits "$CLOSED_BASE" "$TIP")
  CLOSED_BASE="$TIP"
done
# The population first: a loop over zero commits reports all-clean, which is the shape where
# "checked and fine" and "never looked" print the same thing.
assert_eq "the closed rounds contain commits to check (a clean sweep over zero proves nothing)" \
  "$([[ "$CLOSED_CHECKED" -ge "${#CLOSED_ROUND_TIPS[@]}" ]] && echo ">=1 each" || echo "ONLY $CLOSED_CHECKED COMMITS ACROSS $CLOSED_N ROUNDS")" \
  ">=1 each"
assert_eq "every commit of every CLOSED round reverts cleanly at its own round's tip" \
  "$([[ -z "$CLOSED_CONFLICTS" ]] && echo all-clean || echo "conflicts:$CLOSED_CONFLICTS")" "all-clean"

# THE EXEMPTION, EARNED RATHER THAN DECLARED. Each listed pair is put through three checks the
# tip check cannot make, so a line in SUPERSEDED_PAIRS costs more than it saves if it is untrue.
assert_eq "every listed superseded commit was actually reached by the loop (a stale entry exempts nothing)" \
  "$SUPERSEDED_SEEN" "${#SUPERSEDED_PAIRS[@]}"
PAIR_FAILURES=""
for pair in "${SUPERSEDED_PAIRS[@]}"; do
  SUP_SHA="$(sha_of "${pair%%||*}")"
  REP_SHA="$(sha_of "${pair##*||}")"
  if [[ -z "$SUP_SHA" || -z "$REP_SHA" ]]; then PAIR_FAILURES="$PAIR_FAILURES|unresolvable pair: $pair"; continue; fi
  # 1. The repairer comes AFTER the superseded commit.
  [[ "$(git -C "$REPO_ROOT" merge-base --is-ancestor "$SUP_SHA" "$REP_SHA" && echo yes || echo no)" == yes ]] \
    || PAIR_FAILURES="$PAIR_FAILURES|not an ancestor: ${pair%%||*}"
  # 2. They really share a file, so the conflict is a REPAIR and not an unrelated failure the
  #    list is being used to hide.
  SHARED="$(comm -12 \
    <(git -C "$REPO_ROOT" show --name-only --format= "$SUP_SHA" | sort -u) \
    <(git -C "$REPO_ROOT" show --name-only --format= "$REP_SHA" | sort -u) | grep -c .)"
  [[ "$SHARED" -ge 1 ]] || PAIR_FAILURES="$PAIR_FAILURES|no shared file: $pair"
  # 3. It was separable right up to the repair: it reverts cleanly at the repairer's PARENT.
  [[ "$(revert_touches_at "$REP_SHA^" "$SUP_SHA")" == clean:* ]] \
    || PAIR_FAILURES="$PAIR_FAILURES|not separable before its repair: ${pair%%||*}"
  # 4. THE EXEMPTION IS NECESSARY, which is the only one of the four an ADJACENT pair cannot
  #    satisfy for free. For the single entry listed today `git rev-parse REP^` IS `SUP`, so
  #    check 3 reverts a commit at its own tip -- measured clean for every commit that has ever
  #    existed -- and check 1's `--is-ancestor` is automatic for an adjacent pair. Only check 2
  #    could refuse anything. So the comparison the exemption SUPPRESSED is re-run here: the
  #    superseded commit must really CONFLICT at its round's tip. An exemption nobody has watched
  #    be needed is not an exemption, it is a way to stop checking a commit.
  SUP_TIP=""
  for at in $SUPERSEDED_AT; do
    [[ "${at%%:*}" == "$SUP_SHA" ]] && SUP_TIP="${at##*:}"
  done
  if [[ -z "$SUP_TIP" ]]; then
    PAIR_FAILURES="$PAIR_FAILURES|no round tip recorded, so necessity was never tested: ${pair%%||*}"
  elif [[ "$(revert_touches_at "$SUP_TIP" "$SUP_SHA")" == clean:* ]]; then
    PAIR_FAILURES="$PAIR_FAILURES|UNNECESSARY exemption (reverts cleanly at its round tip): ${pair%%||*}"
  fi
done
assert_eq "and each one is an earned exemption: later, overlapping, separable until the repair, and NEEDED" \
  "$PAIR_FAILURES" ""
# The necessity check, stated on its own so a green transcript records WHICH way it came out
# rather than only that four checks collectively passed.
assert_eq "the listed exemption really is needed: the superseded commit conflicts at its round tip" \
  "$(revert_touches_at "$ROUND1_TIP_SHA" "$(sha_of "${SUPERSEDED_PAIRS[0]%%||*}")")" "CONFLICT"
# CONTROL for check 4, in the other direction: the same necessity test over a commit of the SAME
# round that needs no exemption returns clean:, so the CONFLICT above discriminates rather than
# being what this probe says about everything.
assert_eq "CONTROL: the same necessity test reports clean: for a commit that needs no exemption" \
  "$([[ "$(revert_touches_at "$ROUND1_TIP_SHA" "$(sha_of 'fix: panel composition seats the specialist')")" == clean:* ]] \
     && echo clean || echo NOT-CLEAN)" "clean"
# CONTROL: the earning checks must be able to REFUSE, or the empty string above is a statement
# about three checks that always pass. Two unrelated commits share no file and are not a repair.
assert_eq "CONTROL: two unrelated commits do NOT satisfy the shared-file test" \
  "$(comm -12 \
      <(git -C "$REPO_ROOT" show --name-only --format= "$(sha_of 'ci: run the plugin test suite')" | sort -u) \
      <(git -C "$REPO_ROOT" show --name-only --format= "$(sha_of 'docs: worktree_path is omitted from status.json')" | sort -u) | grep -c .)" \
  "0"

# NOTHING FALLS BETWEEN THE DELIMITERS: every non-merge commit after the implementation series
# tip belongs to exactly one round. This is what stops "close the last round" from being a way to
# stop checking it -- the four tips have to partition the window exactly, so a fifth round landing
# unlisted, or a tip moved to skip commits, is arithmetic that does not add up rather than a
# silence. It replaces the open round's non-emptiness guard and carries the same weight: a sweep
# over zero commits cannot satisfy an equality against 22.
assert_eq "the closed rounds account for every commit after the series tip, with none left over" \
  "$CLOSED_CHECKED" \
  "$(round_commits "$SERIES_TIP_SHA" "$SERIES_HEAD_SHA" | grep -c . | tr -d ' ')"
assert_eq "and that population is the whole post-implementation series, not a truncated slice" \
  "$CLOSED_CHECKED" "22"
# The last round's tip IS the series head, i.e. the delimiter list runs to the end of the window
# rather than stopping short of it. Stated as an assertion rather than a comment so the two
# cannot drift apart silently.
assert_eq "the last closed round's tip is the series head itself, so no commit sits past the list" \
  "$LAST_CLOSED_SHA" "$SERIES_HEAD_SHA"
# CONTROL for check_round: it must be able to report a MISSING subject, or "all-clean" is a
# statement about a loop that never looked anything up.
assert_contains "CONTROL: check_round reports a subject that is not in the series window" \
  "$(check_round "$SERIES_HEAD_SHA" 'chore: a subject no commit on this branch carries')" "missing:"

# The two round-1 blockers are separable from each other in particular: they were the two
# REQUEST_CHANGES items, and backing one out must not drag the other.
PANEL_FIX_REVERT="$(revert_touches_at "$ROUND1_TIP_SHA" "$(sha_of 'fix: panel composition seats the specialist')")"
TELEM_FIX_REVERT="$(revert_touches_at "$ROUND1_TIP_SHA" "$(sha_of 'fix: telemetry attributes suffixed phase labels')")"
# ...and the file lists are OBSERVED NON-EMPTY first. Without these two lines the assertions
# below are satisfied by a probe that returns `clean:` with nothing after the colon.
assert_eq "the panel-fix revert names at least one file, so the absence asserted next is a verdict" \
  "$([[ "$PANEL_FIX_REVERT" == clean:?* ]] && echo non-empty || echo "EMPTY: $PANEL_FIX_REVERT")" "non-empty"
assert_eq "and so does the telemetry-fix revert" \
  "$([[ "$TELEM_FIX_REVERT" == clean:?* ]] && echo non-empty || echo "EMPTY: $TELEM_FIX_REVERT")" "non-empty"
assert_not_contains "reverting the panel-composition fix does not touch the telemetry module" \
  "$PANEL_FIX_REVERT" "pipeline-telemetry.mjs"
assert_not_contains "and reverting the telemetry fix does not touch commands/pipeline.md" \
  "$TELEM_FIX_REVERT" "commands/pipeline.md"
# CONTROL for the pair above: the same two probes DO name the files each commit really touched,
# so "does not contain X" is measured against a list that contains something.
assert_contains "CONTROL: the panel-fix revert names the file it really touched" \
  "$PANEL_FIX_REVERT" "commands/pipeline.md"
assert_contains "CONTROL: and the telemetry-fix revert names its own" \
  "$TELEM_FIX_REVERT" "pipeline-telemetry.mjs"

# =============================================================================
# AC6 / AC23 -- the pinned gate suite, and the pointers inside it.
# =============================================================================
suite "AC6: the shipped gate suite still passes, and its assertions are untouched"

GATE_OUT="$(bash "$TESTS_DIR/test-gate-pre-phase4.sh" 2>&1)"
assert_contains "test-gate-pre-phase4.sh passes in full" "$GATE_OUT" "passed=95 failed=0"
# The count is pinned as well as the verdict: a suite that passes with FEWER assertions than
# it shipped with has had a case deleted, which is exactly how a fail-closed gate loses its
# deletion-exemption coverage quietly.
#
# 56 -> 95 for #31 and #48, and the two literals below are NOT the same number wearing two
# hats. This one tracks the LIVE suite and moves whenever it legitimately grows; the CONTROL
# further down counts assertion lines in the historical commit that authored the suite, and 56
# is a fact about that commit forever. Raising both together is the mistake this note exists to
# prevent -- it would retire the only non-zero control the pattern above has.
assert_eq "and it still carries all 95 assertions (a green with fewer is a deleted case)" \
  "$(printf '%s' "$GATE_OUT" | grep -c '^  ok' | tr -d ' ')" "95"
# Measured across the SERIES WINDOW, for the same reason the round lookups are: `origin/main...HEAD`
# is an empty diff on main, so after the merge this line was green because it compared a commit
# with itself. A vacuous pass is the worse half of the same defect -- the round assertions at
# least went red about it.
#
# THE PATTERN IS `^[+-][[:space:]]*assert_`, and the previous `^[+-][^+-].*assert_` was a second,
# independent way for this line to be un-failable: the assertions in that suite start at column 0,
# so `[^+-]` consumed their leading `a` and `.*assert_` then had only "ssert_" left to find. The
# control below measures it -- the old pattern reports 0 over the commit that ADDS 56 of them.
# `[[:space:]]*` still cannot match the `+++`/`---` file headers, which is what the old character
# class was for.
assert_eq "no assertion line in it was modified anywhere in the series" \
  "$(git -C "$REPO_ROOT" diff "$BASE".."$SERIES_HEAD_SHA" -- plugins/pipeline/tests/test-gate-pre-phase4.sh | grep -cE '^[+-][[:space:]]*assert_')" "0"
# The 0 above is only a verdict if the diff it counted was non-empty. The series DOES touch this
# file (one commit corrects comments in it), so the grep really walked a diff and found no
# assertion line in it, rather than finding nothing because there was nothing to find.
assert_eq "the series really does touch that file, so the 0 above counted a diff that exists" \
  "$([[ "$(git -C "$REPO_ROOT" log --format=%H "$BASE".."$SERIES_HEAD_SHA" -- plugins/pipeline/tests/test-gate-pre-phase4.sh | grep -c .)" -ge 1 ]] \
     && echo touched || echo "UNTOUCHED: the assertion above counted an empty diff")" "touched"
# NON-ZERO CONTROL: the same grep over the commit that AUTHORED the suite must report a large
# count, or the 0 above is a statement about a pattern that never matches anything.
GATE_AUTHORED_SHA="$(subject_shas_from HEAD 'test(scripts): author the failing behavioral contract for the 8 .mjs scripts' | head -1)"
# It sits BEFORE the series window, so the in-window uniqueness sweep cannot cover it; its 1:1
# resolution is asserted here instead, against full history, for the same reason every other
# lookup's is -- head -1 over an ambiguous subject silently measures a commit nobody named.
assert_eq "CONTROL: the commit that authored the gate suite resolves to exactly one commit" \
  "$(subject_shas_from HEAD 'test(scripts): author the failing behavioral contract for the 8 .mjs scripts' | grep -c . | tr -d ' ')" "1"
assert_eq "CONTROL: the same grep counts all 56 added assertion lines across that commit" \
  "$(git -C "$REPO_ROOT" diff "$GATE_AUTHORED_SHA^".."$GATE_AUTHORED_SHA" -- plugins/pipeline/tests/test-gate-pre-phase4.sh | grep -cE '^[+-][[:space:]]*assert_')" \
  "56"
# ...and the pattern this line replaced reports 0 on that same commit, which is why it is not
# still in use. Stated as an assertion so the two patterns cannot quietly swap back.
assert_eq "CONTROL: the OLD pattern saw none of those 56, which is the bug it is retired for" \
  "$(git -C "$REPO_ROOT" diff "$GATE_AUTHORED_SHA^".."$GATE_AUTHORED_SHA" -- plugins/pipeline/tests/test-gate-pre-phase4.sh | grep -c '^[+-][^+-].*assert_')" \
  "0"

suite "AC23: the false pointers in that suite are corrected, and its rationale survives verbatim"

GATE_SUITE="$TESTS_DIR/test-gate-pre-phase4.sh"
assert_eq "the claim that the docstring is WRONG about migrationGlobs is gone" \
  "$(grep -c 'is WRONG on this point' "$GATE_SUITE" | tr -d ' ')" "0"
# This file QUOTES the deleted claim in order to search for it, so it excludes itself by name.
# Without that, the assertion is un-passable for a reason that has nothing to do with the code.
SELF="$(basename "${BASH_SOURCE[0]}")"
claim_files() { { grep -rl 'is WRONG on this point' "$PLUGIN_DIR" 2>/dev/null || true; } | grep -v "$SELF"; }
assert_eq "and no comment anywhere in the plugin still makes that claim" \
  "$(claim_files | wc -l | tr -d ' ')" "0"
CLAIMPROBE="$TEMP_PROJECT/claim-probe.sh"
printf '%s\n' "# the docstring is WRONG on this point" > "$CLAIMPROBE"
assert_eq "CONTROL: the same grep DOES find the claim when it is present" \
  "$(grep -c 'is WRONG on this point' "$CLAIMPROBE" | tr -d ' ')" "1"
assert_eq "the tracking claim pointing at doc issue 3 is gone" \
  "$(grep -c 'tracked as follow-up doc' "$GATE_SUITE" | tr -d ' ')" "0"
# What must SURVIVE, quoted verbatim: the behavioral rationale and the if-this-goes-red note.
assert_contains "the behavioral rationale survives" "$(cat "$GATE_SUITE")" \
  "a discovery FILTER must never override an"
assert_contains "and so does the 'if this case ever goes red' instruction" "$(cat "$GATE_SUITE")" \
  "that change would be a bypass on a fail-closed gate"
# UPDATED, not deleted, when issue #30 closed the executable-down gap: the site no longer
# points at a TRACKED gap, because there is no longer a gap to track. It now asserts the
# CLOSED state -- the case survives, inverted, stating the guarantee. Asserting the absence of
# the tracking pointer AND the presence of the guarantee is what keeps "the gap closed" and
# "somebody deleted the case" from looking the same from this file.
assert_eq "the executable-down case no longer points at a tracked follow-up" \
  "$(grep -c 'Tracked as follow-up issue' "$GATE_SUITE" | tr -d ' ')" "0"
assert_contains "and states the executable-down GUARANTEE in its place" "$(cat "$GATE_SUITE")" \
  "an executable (uncommented) down region now halts"

# The pointer is resolved against the ISSUE'S TITLE, not by asserting a digit is present: #4
# is a merged voice fix, and a digit-only check would have accepted it. It stays a LIVE lookup
# after the close, because the title is what identifies WHICH gap the guarantee above closed;
# a hand-copied title would restate the contract instead of observing it. Skipped, loudly, when
# no GitHub CLI credential is available, because an unauthenticated `gh` cannot distinguish
# "the title does not match" from "I could not look".
if gh issue view 16 --json title >/dev/null 2>&1; then
  TITLE16="$(gh issue view 16 --json title -q .title 2>/dev/null)"
  assert_contains "#16's live title names the executable down section the gate now refuses" \
    "$TITLE16" "executable down section"
else
  assert_eq "gh is unavailable, so the title resolution is UNVERIFIED here (not passed)" \
    "gh-unavailable: title not resolved" "gh-unavailable: title not resolved"
fi

# =============================================================================
# AC36 / AC42 -- the documentation corrections.
# =============================================================================
suite "AC36: the mechanical tripwire is no longer credited with catching an auth surface"

assert_eq "the overclaiming phrase is gone from every command and agent file" \
  "$( { grep -rl 'migration/access-control/auth' "$PLUGIN_DIR"/commands "$PLUGIN_DIR"/agents 2>/dev/null || true; } | wc -l | tr -d ' ')" "0"
assert_contains "and the sentence now names WHICH tripwire it means" "$(cat "$PIPELINE_MD")" \
  "MECHANICAL path tripwire above, which is a data-layer PATH predicate"
assert_contains "and says what it does NOT cover" "$(cat "$PIPELINE_MD")" "NOT auth and NOT authorization code"
# NON-ZERO CONTROL for that grep: the same invocation against a file carrying the phrase.
PROBE="$TEMP_PROJECT/overclaim-probe.md"
printf '%s\n' 'the mis-tier tripwire still catches a migration/access-control/auth surface' > "$PROBE"
assert_eq "CONTROL: the same grep DOES find the phrase when it is present" \
  "$(grep -c 'migration/access-control/auth' "$PROBE" | tr -d ' ')" "1"

suite "AC42: the upgrade note exists AND names all three behaviour changes"

README="$PLUGIN_DIR/README.md"
assert_eq "there is an Upgrading section" "$(grep -c '^### Upgrading' "$README" | tr -d ' ')" "1"
# Each of the three is asserted SEPARATELY: a single "the section exists" check passes a stub.
assert_contains "(1) the widened preset defaults and the un-narrowable tripwire" "$(cat "$README")" \
  "the mis-tier tripwire can no longer be narrowed by config"
assert_contains "(1b) with extraMigrationGlobs named as the widening escape" "$(cat "$README")" \
  "Widen with \`extraMigrationGlobs\`"
assert_contains "(2) pipeline.config.json becoming an architectural trigger" "$(cat "$README")" \
  "Editing \`pipeline.config.json\` now forces the architectural tier"
assert_contains "(3) the copied-example hazard" "$(cat "$README")" \
  "If you copied the example config, DELETE its \`migrationGlobs\` line"

suite "AC42(b): the upgrade note's exclusion sentence matches what the code actually excludes"

# The sentence said "Markdown is excluded from the narrow set in code, so a docs path under
# migrations/ does not halt". The code excludes .md/.mdx and nothing else, so
# docs/migrations/notes.txt DOES halt and the second clause was false. An adopter reading it
# would plan a docs move that eats a halt.
assert_eq "the over-broad 'a docs path ... does not halt' claim is gone" \
  "$(grep -c 'so a docs path under `migrations/` does not halt' "$README" | tr -d ' ')" "0"
assert_contains "the claim is scoped to MARKDOWN" "$(cat "$README")" \
  "A Markdown docs path is excluded from the narrow set in code"
assert_contains "and the README says out loud that other extensions there DO halt" "$(cat "$README")" \
  "Any other extension there does, including \`.txt\` and images"
# The sentence is only true because of what the code does. Verified against the real predicate,
# so this pair goes red if either the prose or the exclusion list moves.
DL_MOD=""
for f in "$SCRIPTS_DIR"/*.mjs; do
  [[ -f "$f" ]] || continue
  if grep -q 'migrationGlobsForTripwire' "$f" 2>/dev/null; then DL_MOD="$f"; break; fi
done
excl() { MOD="$DL_MOD" P="$1" node --input-type=module -e '
  const m = await import(process.env.MOD);
  console.log(String(m.isMigrationPath(process.env.P, m.DEFAULT_MIGRATION_GLOBS)));
'; }
assert_eq "CODE CHECK: docs/migrations/notes.txt really does halt, as the README now says" \
  "$(excl 'docs/migrations/notes.txt')" "true"
assert_eq "CODE CHECK: docs/migrations/diagram.png really does halt too" \
  "$(excl 'docs/migrations/diagram.png')" "true"
assert_eq "CONTROL: the .md sibling really does not, so the README's Markdown clause is true as well" \
  "$(excl 'docs/migrations/upgrade-v2.md')" "false"

finish
