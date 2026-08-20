#!/usr/bin/env bash
# harness.sh's own contracts, plus run.sh's discovery/exit contract.
#
# Two things are load-bearing enough to deserve their own suite:
#   (1) The guarded temp-dir helper (AC22). It is the ONLY destructive path in the suites
#       added by this change, so its refusal behavior is tested directly, including the
#       forced-mktemp-failure case where it must remove NOTHING.
#   (2) run.sh's glob + exit contract (AC2). run.sh is pipeline.config.json's checkCommand
#       AND the command hooks/stop.sh executes, so "one suite fails => non-zero" is a
#       consumer contract, not an internal detail.
#
# This suite needs no node: it exercises bash plumbing only.

. "$(dirname "${BASH_SOURCE[0]}")/harness.sh"

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# run_child <script-path> [env assignments via caller] -> sets RC, OUT, ERR
run_child() {
  local script="$1"
  local outf errf
  outf="$SCRATCH/child.out"
  errf="$SCRATCH/child.err"
  bash "$script" >"$outf" 2>"$errf"
  RC=$?
  OUT=$(cat "$outf")
  ERR=$(cat "$errf")
}

new_tmpdir || exit 90
SCRATCH="$NEW_TMPDIR"

suite "harness: guarded temp dirs (AC22)"

new_tmpdir || exit 90
LIVE="$NEW_TMPDIR"
assert_eq "new_tmpdir hands back a usable directory" "$([[ -d "$LIVE" ]] && echo dir)" "dir"
touch "$LIVE/file"
assert_eq "the temp dir is writable" "$([[ -f "$LIVE/file" ]] && echo file)" "file"

# A child suite records the path it was given, so the parent can prove the trap removed it
# after the child exited. The trap only fires in the process that owns the registry, which is
# why this cannot be asserted in-process.
cat > "$SCRATCH/child-pass.sh" <<CHILD
. "$TESTS_DIR/harness.sh"
new_tmpdir || exit 90
printf '%s' "\$NEW_TMPDIR" > "$SCRATCH/pass.path"
touch "\$NEW_TMPDIR/payload"
suite "scratch"
assert_eq "passing case" "a" "a"
finish
CHILD
run_child "$SCRATCH/child-pass.sh"
assert_eq "a passing child suite exits 0" "$RC" "0"
assert_eq "its temp dir is removed on normal completion" \
  "$([[ -e "$(cat "$SCRATCH/pass.path")" ]] && echo present || echo gone)" "gone"

# Cleanup must not depend on the suite succeeding: a failed assertion is exactly when a
# developer re-runs, and leaked dirs would accumulate every run.
cat > "$SCRATCH/child-fail.sh" <<CHILD
. "$TESTS_DIR/harness.sh"
new_tmpdir || exit 90
printf '%s' "\$NEW_TMPDIR" > "$SCRATCH/fail.path"
touch "\$NEW_TMPDIR/payload"
suite "scratch"
assert_eq "deliberately failing case" "a" "b"
finish
CHILD
run_child "$SCRATCH/child-fail.sh"
assert_eq "a failing child suite exits non-zero" "$RC" "1"
assert_eq "its temp dir is removed even after a FAILED assertion" \
  "$([[ -e "$(cat "$SCRATCH/fail.path")" ]] && echo present || echo gone)" "gone"

# Forced mktemp failure. TMPDIR is NOT the lever here: BSD mktemp (macOS) ignores TMPDIR when
# invoked without a template and falls back to the darwin per-user temp dir, so a
# TMPDIR-pointed-at-garbage test would silently succeed and prove nothing. A PATH stub fails
# deterministically on both BSDs and GNU.
mkdir -p "$SCRATCH/stub-bin"
cat > "$SCRATCH/stub-bin/mktemp" <<'STUB'
#!/usr/bin/env bash
echo "mktemp: stubbed failure" >&2
exit 1
STUB
chmod +x "$SCRATCH/stub-bin/mktemp"
mkdir -p "$SCRATCH/sentinel"
touch "$SCRATCH/sentinel/must-survive"
cat > "$SCRATCH/child-mktemp-fail.sh" <<CHILD
export PATH="$SCRATCH/stub-bin:\$PATH"
. "$TESTS_DIR/harness.sh"
new_tmpdir
printf 'rc=%s\n' "\$?"
printf 'NEW_TMPDIR=[%s]\n' "\$NEW_TMPDIR"
printf 'registry=[%s]\n' "\$TMP_REGISTRY"
CHILD
run_child "$SCRATCH/child-mktemp-fail.sh"
assert_contains "a failed mktemp returns non-zero from new_tmpdir" "$OUT" "rc=90"
assert_contains "a failed mktemp says so, loudly" "$ERR" "mktemp -d failed"
assert_contains "the message explains why an empty path is refused" "$ERR" "destructive-cleanup hazard"
assert_contains "a failed mktemp hands back NO path" "$OUT" "NEW_TMPDIR=[]"
assert_contains "a failed mktemp registers NOTHING for removal" "$OUT" "registry=[]"
assert_eq "a failed mktemp removes nothing: an unrelated dir survives" \
  "$([[ -f "$SCRATCH/sentinel/must-survive" ]] && echo present || echo gone)" "present"

# The registry is an EXACT-match list of dirs this harness created, not a prefix test: a path
# that merely looks like a temp path is still refused.
mkdir -p "$SCRATCH/not-ours"
ERRMSG=$(_remove_owned_tmpdir "$SCRATCH/not-ours" 2>&1); RC=$?
assert_eq "removing an unowned dir is refused" "$RC" "1"
assert_contains "the refusal names the unowned path" "$ERRMSG" "was not created by new_tmpdir"
assert_eq "the unowned dir survives the refusal" \
  "$([[ -d "$SCRATCH/not-ours" ]] && echo present || echo gone)" "present"

ERRMSG=$(_remove_owned_tmpdir "" 2>&1); RC=$?
assert_eq "removing an empty path is refused" "$RC" "1"
assert_contains "the empty-path refusal says so" "$ERRMSG" "empty path"

ERRMSG=$(_remove_owned_tmpdir "/" 2>&1); RC=$?
assert_eq 'removing "/" is refused' "$RC" "1"
assert_contains 'the "/" refusal says so' "$ERRMSG" 'will not remove "/"'

# Static: the destructive statement exists exactly once, and never with a glob suffix. A
# `rm -rf "$dir"/*` form is what turns an empty variable into a root-level removal.
# Comment lines are stripped first: the prose above and below explains rm -rf repeatedly, and
# counting those would make this assertion measure documentation instead of code.
code_only() { grep -v '^[[:space:]]*#' "$1"; }
RM_LINES=$(code_only "$TESTS_DIR/harness.sh" | grep -c 'rm -rf' | tr -d ' ')
assert_eq "harness.sh executes exactly one rm -rf" "$RM_LINES" "1"
assert_eq "that rm -rf carries no glob suffix" \
  "$(code_only "$TESTS_DIR/harness.sh" | grep 'rm -rf' | sed 's/#.*//' | grep -c '\*' | tr -d ' ')" "0"

# The suites added by this change route every removal through the helper. Discovery is by the
# SAME test-*.sh glob run.sh uses, with an explicit exemption list -- never an enumeration of
# suite filenames. An enumeration leaves suite number 9 unguarded the day it lands, and a
# renamed suite silently unguarded forever: a control that quietly stops firing, which is the
# exact failure this file exists to catch. EXAMINED is asserted too, so a broken glob or a
# swallowed rename goes red instead of passing vacuously against an empty loop.
RM_VIOLATORS=""
RM_EXAMINED=0
for f in "$TESTS_DIR"/test-*.sh; do
  [[ -f "$f" ]] || continue
  case "$(basename "$f")" in
    # Pre-existing hook suites: they keep their inline rm -rf and AC16 requires them unedited.
    test-stop-hook.sh | test-session-start-hook.sh | test-subagent-stop-hook.sh) continue ;;
    # This file NAMES the string inside the assertions above rather than executing it; the
    # single real removal in harness.sh is pinned by the two static checks a few lines up.
    test-harness.sh) continue ;;
  esac
  RM_EXAMINED=$((RM_EXAMINED + 1))
  if code_only "$f" | grep -q 'rm -rf'; then RM_VIOLATORS="$RM_VIOLATORS $(basename "$f")"; fi
done
assert_eq "no new script suite hand-rolls rm -rf" "${RM_VIOLATORS:-none}" "none"
assert_eq "and the rm -rf check actually examined the script suites" \
  "$([[ "$RM_EXAMINED" -ge 8 ]] && echo ok || echo "only $RM_EXAMINED examined")" "ok"

suite "harness: an UNCOUNTED assertion fails the suite"

# The defect this guards, measured: seven assertions in test-gate-phase-entry.sh sat inside
# `( unset ...; assert_eq ... )` subshells. Their increments died with the subshell and assert_*
# returns 0 either way, so a FAIL among them printed and the suite still reported failed=0 and
# exited 0. Two of the seven were the non-zero CONTROLs for the criterion above them.
#
# The child below is that exact shape, reduced: ONE assertion in the parent shell, ONE inside a
# subshell. Every assertion in it PASSES, so nothing but the count guard can fail it -- which is
# what makes this a test of the guard rather than of the assertion.
cat > "$SCRATCH/child-subshell.sh" <<CHILD
. "$TESTS_DIR/harness.sh"
suite "scratch"
assert_eq "counted normally" "a" "a"
( assert_eq "evaluated where the counters do not survive" "b" "b" )
finish
CHILD
run_child "$SCRATCH/child-subshell.sh"
assert_eq "a suite with an uncounted assertion exits non-zero" "$RC" "1"
# The discriminating assertion: the child's OWN tally says nothing is wrong. Without this, the
# red above is satisfied by a child that simply had a failing assertion.
assert_contains "  even though its own tally reports no failures" "$OUT" "passed=1 failed=0"
assert_contains "the guard says how many ran versus how many counted" "$ERR" "2 assertion(s) ran but 1 were counted"
assert_contains "  and names the assertion that could not fail the build" "$ERR" \
  "evaluated where the counters do not survive"
assert_contains "  and says why an uncounted assertion matters" "$ERR" "cannot fail the build"
assert_not_contains "  and does not accuse the one that WAS counted" "$ERR" "counted normally"

# NON-ZERO CONTROL, on the same child minus the parentheses. Without it, the red above could be
# produced by a guard that fails every suite, and the 32 green suites in this directory would be
# the thing disagreeing with it.
cat > "$SCRATCH/child-nosubshell.sh" <<CHILD
. "$TESTS_DIR/harness.sh"
suite "scratch"
assert_eq "counted normally" "a" "a"
assert_eq "evaluated where the counters do not survive" "b" "b"
finish
CHILD
run_child "$SCRATCH/child-nosubshell.sh"
assert_eq "CONTROL: the identical assertions OUTSIDE the subshell exit 0" "$RC" "0"
assert_contains "CONTROL: and both are counted" "$OUT" "passed=2 failed=0"
assert_eq "CONTROL: and the guard stays silent" "$ERR" ""

# A subshell around an assertion that FAILS is the case the seven actually threatened: the FAIL
# is printed, the tally still says zero, and only the guard is left to notice.
cat > "$SCRATCH/child-subshell-fail.sh" <<CHILD
. "$TESTS_DIR/harness.sh"
suite "scratch"
( assert_eq "a real failure, thrown away" "actual" "expected" )
finish
CHILD
run_child "$SCRATCH/child-subshell-fail.sh"
assert_contains "a FAIL inside a subshell is still PRINTED" "$OUT" "FAIL  a real failure, thrown away"
assert_contains "  and still uncounted by the tally" "$OUT" "passed=0 failed=0"
assert_eq "  but the suite no longer exits 0" "$RC" "1"

suite "harness: node is REQUIRED, never skipped (AC3)"

# Build a PATH with the few externals harness.sh itself needs and, pointedly, no node. This is
# the inversion of the hooks' fail-open posture: see require_node's comment before changing it.
mkdir -p "$SCRATCH/nonode-bin"
for tool in dirname basename mktemp rm; do
  ln -sf "$(command -v "$tool")" "$SCRATCH/nonode-bin/$tool"
done
cat > "$SCRATCH/child-nonode.sh" <<CHILD
export PATH="$SCRATCH/nonode-bin"
. "$TESTS_DIR/harness.sh"
require_node
printf 'REACHED_PAST_REQUIRE_NODE\n'
CHILD
run_child "$SCRATCH/child-nonode.sh"
assert_eq "a missing node exits non-zero (never a silent skip)" "$RC" "91"
assert_contains "the failure names the missing interpreter" "$ERR" "node"
assert_contains "the failure says it is on PATH that is missing" "$ERR" "not on PATH"
assert_contains "the failure explains why it does not skip" "$ERR" "silent skip"
assert_not_contains "execution stops at require_node" "$OUT" "REACHED_PAST_REQUIRE_NODE"

suite "run.sh: discovery and exit contract (AC2)"

# A throwaway tests dir with a copy of the real run.sh. Copying (rather than running the real
# one) keeps this from recursing into itself.
new_tmpdir || exit 90
RUNDIR="$NEW_TMPDIR"
cp "$TESTS_DIR/run.sh" "$RUNDIR/run.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$RUNDIR/test-green.sh"
OUT=$(bash "$RUNDIR/run.sh" 2>&1); RC=$?
assert_eq "all suites passing exits 0" "$RC" "0"
assert_contains "a green run says every suite passed" "$OUT" "passed."

printf '#!/usr/bin/env bash\nexit 1\n' > "$RUNDIR/test-red.sh"
OUT=$(bash "$RUNDIR/run.sh" 2>&1); RC=$?
assert_eq "one failing suite exits non-zero" "$RC" "1"
assert_contains "the summary counts the failing suite" "$OUT" "1 suite(s) FAILED."
assert_contains "the failing suite is named in the run" "$OUT" "test-red.sh"

# The glob is the discovery mechanism; a file outside it must not run. Written as a would-be
# failure so that a widened glob shows up as a red suite rather than as silence.
printf '#!/usr/bin/env bash\nexit 1\n' > "$RUNDIR/helper-not-a-suite.sh"
OUT=$(bash "$RUNDIR/run.sh" 2>&1); RC=$?
assert_eq "a non test-*.sh file is not discovered" "$RC" "1"
assert_not_contains "a non test-*.sh file never runs" "$OUT" "helper-not-a-suite.sh"

# run.sh is a consumer contract (checkCommand + stop.sh). These pin the two bytes of it that
# consumers depend on, so a comment/summary refresh cannot quietly change the mechanism.
assert_contains "run.sh still discovers via the test-*.sh glob" "$(cat "$TESTS_DIR/run.sh")" 'for t in test-*.sh'
assert_contains "run.sh still invokes each suite with bash" "$(cat "$TESTS_DIR/run.sh")" 'bash "$t"'

finish
