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
# The registry is no longer empty at source time -- harness.sh registers its own ledger dir --
# so this compares the registry ACROSS the failed call instead of against []. That is the
# property that was meant all along: a failed mktemp adds nothing. The line count is asserted
# too, so a registry that silently grew somewhere else cannot satisfy "unchanged" vacuously.
cat > "$SCRATCH/child-mktemp-fail.sh" <<CHILD
export PATH="$SCRATCH/stub-bin:\$PATH"
. "$TESTS_DIR/harness.sh"
REGISTRY_BEFORE="\$TMP_REGISTRY"
new_tmpdir
printf 'rc=%s\n' "\$?"
printf 'NEW_TMPDIR=[%s]\n' "\$NEW_TMPDIR"
printf 'registry_unchanged=[%s]\n' "\$([[ "\$TMP_REGISTRY" == "\$REGISTRY_BEFORE" ]] && echo yes || echo no)"
printf 'registry_lines=[%s]\n' "\$(printf '%s' "\$TMP_REGISTRY" | grep -c . | tr -d ' ')"
CHILD
run_child "$SCRATCH/child-mktemp-fail.sh"
assert_contains "a failed mktemp returns non-zero from new_tmpdir" "$OUT" "rc=90"
assert_contains "a failed mktemp says so, loudly" "$ERR" "mktemp -d failed"
assert_contains "the message explains why an empty path is refused" "$ERR" "destructive-cleanup hazard"
assert_contains "a failed mktemp hands back NO path" "$OUT" "NEW_TMPDIR=[]"
assert_contains "a failed mktemp registers NOTHING for removal" "$OUT" "registry_unchanged=[yes]"
assert_contains "  and the registry holds only the ledger dir harness.sh registered for itself" \
  "$OUT" "registry_lines=[1]"
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

suite "harness: the ledger cannot truncate a name it did not create (SEC-D1)"

# THE DEFECT, measured before the fix: the ledger path was `${TMPDIR:-/tmp}/.pipeline-test-
# harness-ledger.$$`, opened with `: >`. TMPDIR is unset on ubuntu-latest, so that is literally
# /tmp; with a symlink pre-placed at that name a 49-byte file elsewhere went to 9 bytes holding
# this harness's own ledger line, and the same run with no symlink left it byte-identical.
#
# The two legs below are split on purpose. The PRIMITIVE leg is deterministic -- it holds the
# path fixed and changes only the opening call -- because the end-to-end attack is not: the
# harness now picks its name with $$ AND $RANDOM, so squatting the real name is a race, and a
# race makes a poor gate on a suite stop.sh runs at every turn end. The SHAPE leg then pins that
# harness.sh is holding the refusing primitive, so a regression to `: >` goes red here.
new_tmpdir || exit 90
SQUAT="$NEW_TMPDIR"
printf 'IMPORTANT-VICTIM-DATA-that-must-not-be-truncated\n' > "$SQUAT/victim"
VICTIM_BYTES_BEFORE=$(wc -c < "$SQUAT/victim" | tr -d ' ')
ln -s "$SQUAT/victim" "$SQUAT/squatted-name"

# The old primitive, run against the squatted name. This is the CONTROL that makes the leg below
# a measurement: without it, "the victim survived" is satisfied by a symlink that never resolved.
( : > "$SQUAT/squatted-name" ) 2>/dev/null
assert_eq "CONTROL: the OLD truncating open really does follow the symlink and empty the victim" \
  "$(wc -c < "$SQUAT/victim" | tr -d ' ')" "0"

# The new primitive, same squatted name. mkdir is atomic, fails on an existing path, and does
# not follow a symlink to create at its target.
printf 'IMPORTANT-VICTIM-DATA-that-must-not-be-truncated\n' > "$SQUAT/victim"
mkdir -m 700 "$SQUAT/squatted-name" 2>/dev/null; MKDIR_RC=$?
assert_eq "the NEW create REFUSES a pre-placed name instead of opening it" "$MKDIR_RC" "1"
assert_eq "  and the victim behind the symlink is byte-for-byte untouched" \
  "$(wc -c < "$SQUAT/victim" | tr -d ' ')" "$VICTIM_BYTES_BEFORE"
assert_eq "  and the squatted name is still the attacker's symlink, not a dir this run owns" \
  "$([[ -L "$SQUAT/squatted-name" ]] && echo symlink || echo replaced)" "symlink"

# SHAPE. Comment lines are stripped: the rationale above the code says `: >` and
# `.pipeline-test-harness-ledger` on purpose, and counting those would measure the prose.
assert_not_contains "harness.sh no longer opens the ledger with a truncating redirect" \
  "$(code_only "$TESTS_DIR/harness.sh")" ': > "$_ASSERT_LEDGER"'
assert_not_contains "  and the predictable pid-only ledger name is gone from the code" \
  "$(code_only "$TESTS_DIR/harness.sh")" '.pipeline-test-harness-ledger'
assert_contains "  the ledger dir is created with mkdir, whose failure on an existing path is the guard" \
  "$(code_only "$TESTS_DIR/harness.sh")" 'mkdir -m 700 "$_LEDGER_DIR"'

# WHERE IT LANDS, on the real harness rather than on the primitive. A child reports the two
# paths it was actually given.
cat > "$SCRATCH/child-ledger-paths.sh" <<CHILD
. "$TESTS_DIR/harness.sh"
printf '%s' "\$_LEDGER_DIR" > "$SCRATCH/ledger.dir"
suite "scratch"
assert_eq "passing case" "a" "a"
printf 'LEDGER=[%s]\n' "\$_ASSERT_LEDGER"
printf 'MODE=[%s]\n' "\$(ls -ld "\$_LEDGER_DIR" | cut -c1-10)"
printf 'INSIDE=[%s]\n' "\$([[ "\$_ASSERT_LEDGER" == "\$_LEDGER_DIR"/* ]] && echo yes || echo no)"
finish
CHILD
run_child "$SCRATCH/child-ledger-paths.sh"
assert_eq "a real suite still gets a working ledger" "$RC" "0"
assert_contains "the ledger file lives INSIDE the dir this process created" "$OUT" "INSIDE=[yes]"
assert_contains "that dir is owner-only, so no other user can plant inside it either" "$OUT" "MODE=[drwx------]"
assert_not_contains "the ledger is not sitting directly in the shared temp dir" "$OUT" "LEDGER=[$SCRATCH]"

# SecOps' EXPECTED SURVIVOR, closed. Nothing asserted the ledger was ever cleaned up: deleting
# the removal left 8 orphaned files per run with the suite still exiting 0. It is removed through
# the SAME registry as every other temp dir, so this also proves the registration happened.
assert_eq "the ledger dir is removed when the suite exits" \
  "$([[ -e "$(cat "$SCRATCH/ledger.dir")" ]] && echo present || echo gone)" "gone"

suite "harness: an unavailable ledger ANNOUNCES its disarm (SEC-D2)"

# THE DEFECT, measured before the fix: with an unwritable TMPDIR the ledger path went empty and
# _assert_count_guard returned 0 -- the same fail-open-in-silence shape the guard exists to
# catch. Identical suite, one genuinely uncounted assertion: writable tmp exited 1 naming the
# offender, unwritable tmp exited 0 with BYTE-IDENTICAL stdout. The only signal was bash's own
# redirection diagnostic, which never mentions the guard and does not appear at all for a later
# append failure.
#
# ANNOUNCE rather than FATAL, deliberately, and QA dissented. QA read require_node's exit 91 as
# the precedent and would fail hard. require_node gates a PREREQUISITE (without node the .mjs
# scripts go wholly unexercised); this gates a GUARD over assertions that still run and still
# print either way, and TMPDIR is writable on every common path. The precedent taken is the
# once-per-session disarm notice in hooks/session-start.sh, which is also a guard reporting its
# own absence rather than wedging the operator over their tooling.
new_tmpdir || exit 90
RO_PARENT="$NEW_TMPDIR"
RO_TMP="$RO_PARENT/unwritable"
mkdir -p "$RO_TMP"
chmod 500 "$RO_TMP"
# PRECONDITION. Running as root ignores the mode bits, and then every assertion below would be
# measuring a writable dir while claiming an unwritable one.
touch "$RO_TMP/probe" 2>/dev/null
assert_eq "  precondition: the fixture TMPDIR really is unwritable to this user" \
  "$([[ -e "$RO_TMP/probe" ]] && echo writable || echo unwritable)" "unwritable"

# The child from the count-guard suite below, reused verbatim: one counted assertion, one
# evaluated in a subshell where the counter cannot survive. Every assertion in it PASSES, so
# only the guard can fail it. TMPDIR is exported INSIDE each child rather than prefixed onto the
# run_child call: a `VAR=x func` assignment leaks past a shell FUNCTION in bash, which would
# silently carry the unwritable dir into the control below and into every later suite here.
write_uncounted_child() {
  cat > "$1" <<CHILD
export TMPDIR="$2"
. "$TESTS_DIR/harness.sh"
suite "scratch"
assert_eq "counted normally" "a" "a"
( assert_eq "evaluated where the counters do not survive" "b" "b" )
finish
CHILD
}

write_uncounted_child "$SCRATCH/child-uncounted-ro.sh" "$RO_TMP"
run_child "$SCRATCH/child-uncounted-ro.sh"
RO_RC="$RC"; RO_OUT="$OUT"; RO_ERR="$ERR"
assert_contains "an unavailable ledger SAYS the guard is disabled" "$RO_ERR" \
  "the uncounted-assertion guard is DISABLED for this suite"
assert_contains "  and names the path it could not use" "$RO_ERR" "$RO_TMP/.pipeline-harness."
assert_contains "  the suite still RUNS: assertions are announced, not refused" "$RO_OUT" "passed=1 failed=0"

# NON-ZERO CONTROL, on the same child with the only difference being a writable TMPDIR. Without
# it, the announce above is satisfied by a harness that announces unconditionally, and the
# disarm it reports would be indistinguishable from the normal case.
write_uncounted_child "$SCRATCH/child-uncounted-rw.sh" "$SCRATCH"
run_child "$SCRATCH/child-uncounted-rw.sh"
assert_not_contains "CONTROL: a writable TMPDIR announces NOTHING" "$ERR" \
  "the uncounted-assertion guard is DISABLED"
assert_eq "CONTROL: and the guard bites there, so the announce marks a REAL loss of coverage" "$RC" "1"
assert_eq "  which is the loss: the identical suite exits 0 once the ledger is unavailable" "$RO_RC" "0"

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
# mkdir is on this list because harness.sh creates its ledger DIRECTORY at source time. Leave it
# off and the fixture also constructs "no mkdir", which fires the ledger-unavailable notice and
# makes this cell test two conditions while claiming one.
for tool in dirname basename mktemp mkdir rm; do
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
