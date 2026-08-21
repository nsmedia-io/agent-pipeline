#!/usr/bin/env bash
# THE RATCHET: no test population may be pinned to something that moves independently of the
# property under test. Two shapes so far, one per section: a git range against a MOVING REF
# (#37), and an ABSOLUTE LINE RANGE into a shipped document (#68).
#
# THREE OCCURRENCES OF ONE SHAPE, TWICE BREAKING `main` AT MERGE.
#
#   1. #17's merge. test-issue17-integration.sh computed its window as
#      `merge-base origin/main HEAD`..HEAD. On `main` that merge-base IS HEAD, so the range was
#      empty, every subject lookup returned "", and `set -u` killed the suite before it could
#      print a count. Fixed in #26 by delimiting the series on commit SUBJECT and resolving
#      against full history.
#   2. #32's merge. test-claims-consumers.sh built AC30's population from
#      `git log --format=%s <moving-ref>..HEAD`. Empty on `main`, so the control asserting there
#      were subjects failed and the fresh-checkout meta-test cascaded -- five failures. Fixed in
#      #36, and the derivation itself survived that fix until this file was written.
#   3. This ratchet, which exists because occurrence 2 was written three review rounds AFTER
#      occurrence 1 was fixed, in the same repo, by authors who had the first fix in front of
#      them. A rule that lives only in a commit message is a rule the next author does not have.
#
# WHY IT IS A DEFECT AND NOT A STYLE. `origin/main..HEAD` names the BRANCH'S development range,
# so it describes nothing the moment the branch lands: the range goes empty, and an assertion
# over an empty population does not fail loudly -- it passes vacuously, or it dies on an unbound
# variable somewhere downstream. `gh pr merge --rebase` rewrites every sha on the way in, so
# pinning shas is no escape either. What survives a merge is a commit's SUBJECT and full history.
#
# WHAT THIS SUITE IS NOT. It does not refuse the ranges themselves. Two shipped suites build a
# throwaway repo with its own `origin/main` ref precisely so the block under test -- which really
# does run `git diff origin/main...HEAD` in a real worktree -- resolves at all. Those are correct
# and must not be refused: a ratchet that refuses both the defect and the legitimate use is a
# ratchet that gets deleted the first week. The discriminator is which REPOSITORY the command is
# pointed at, and it is asserted in both directions below.
#
# This suite needs no node: it exercises bash plumbing only.

. "$(dirname "${BASH_SOURCE[0]}")/harness.sh"

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

new_tmpdir || exit 90
SCRATCH="$NEW_TMPDIR"

# ---------------------------------------------------------------------------
# the detector
# ---------------------------------------------------------------------------

# ASSEMBLED, NEVER WRITTEN AS ONE TOKEN. This file is inside the population the ratchet walks,
# and it names the construct it hunts on nearly every line. A detector that matched its own
# pattern would be un-passable for a reason that has nothing to do with the corpus -- the
# self-counting trap #30 hit twice, once with a detector matching its own fixture and once with a
# docstring assertion counting its own prose. Every case pattern below therefore needs BOTH the
# remote-ref half (which lives only in this variable) and the range half on the same line, and no
# line in this file has both.
OREF="or""igin"

# The variables that name THE CHECKOUT. A git command pointed at one of these -- or at nothing at
# all, which leaves it in the suite's own cwd, i.e. inside the checkout -- is deriving over the
# real repository. Anything else is a path the fixture built, and is allowed.
ROOT_VARS="REPO_ROOT PLUGIN_ROOT PLUGIN_DIR TESTS_DIR SCRIPTS_DIR HOOKS_DIR"

# repo_target <line> -> the variable name the git command is pointed at, or "" for none.
# `-C` is preferred over `cd` because that is the precedence git itself applies. Pure parameter
# expansion, no sed: the strings being taken apart are shell source containing backslashes,
# nested quotes and `$` -- every one of which is a metacharacter to something in a sed pipeline,
# and the first spelling of this function silently matched nothing on the escaped-quote form
# that two shipped suites use inside their heredoc fixtures.
#
# ONLY a `$VAR` target is recognised. A literal path (`git -C /tmp/x`) reads as NO target and is
# therefore refused, which is the fail-closed direction and costs nothing here: every fixture
# repo in this directory is already named by a variable.
repo_target() {
  local l="$1" seg lead
  case "$l" in
    *"-C "*)  seg="${l#*-C }" ;;
    *"cd "*)  seg="${l#*cd }" ;;
    *) printf ''; return 0 ;;
  esac
  # Strip the leading run of quoting characters: `"$D`, `\"\$D` and `'$D` all reach the same $.
  lead="${seg%%[!\\\"\']*}"
  seg="${seg#"$lead"}"
  case "$seg" in
    '$'*) seg="${seg#\$}"; seg="${seg#\{}" ;;
    *) printf ''; return 0 ;;
  esac
  printf '%s' "${seg%%[!A-Za-z0-9_]*}"
}

# moving_ref_offenders <file>... -> one "<basename>:<lineno>" per offending line, space-joined.
# NAMES the offender rather than counting it: a count tells you something moved, a name tells you
# what to open. Full-line comments are skipped -- this file, and the two suites that legitimately
# use the ranges, all describe the construct in prose directly above the code that uses it.
moving_ref_offenders() {
  local f line trimmed target v n allowed hits=""
  for f in "$@"; do
    [[ -f "$f" ]] || continue
    n=0
    while IFS= read -r line || [[ -n "$line" ]]; do
      n=$((n + 1))
      trimmed="${line#"${line%%[![:space:]]*}"}"
      case "$trimmed" in '#'*) continue ;; esac
      case "$line" in
        *"$OREF"/*..HEAD*) ;;
        *merge-base*"$OREF"/*HEAD*) ;;
        *) continue ;;
      esac
      target="$(repo_target "$line")"
      allowed=no
      if [[ -n "$target" ]]; then
        allowed=yes
        for v in $ROOT_VARS; do
          [[ "$target" == "$v" ]] && allowed=no
        done
      fi
      [[ "$allowed" == yes ]] && continue
      hits="$hits $(basename "$f"):$n"
    done < "$f"
  done
  printf '%s' "${hits# }"
}

# ---------------------------------------------------------------------------
suite "the ratchet: no shipped suite derives a population from a moving ref"
# ---------------------------------------------------------------------------

# Discovery is by the SAME test-*.sh glob run.sh uses, plus the two files run.sh is made of.
# Never an enumeration of suite filenames: an enumeration leaves suite number 34 unguarded the
# day it lands and a renamed suite unguarded forever, which is a control that quietly stops
# firing -- the failure this whole file exists to catch, wearing a different hat.
POPULATION=()
for f in "$TESTS_DIR"/test-*.sh "$TESTS_DIR/harness.sh" "$TESTS_DIR/run.sh"; do
  [[ -f "$f" ]] && POPULATION+=("$f")
done
assert_eq "the population is the whole tests/ directory, discovered by run.sh's own glob" \
  "$([[ "${#POPULATION[@]}" -ge 30 ]] && echo ok || echo "only ${#POPULATION[@]} files found")" "ok"
assert_eq "no test file derives a population from a range against a moving ref" \
  "$(moving_ref_offenders "${POPULATION[@]}")" ""

# The population is asserted to CONTAIN the two suites whose legitimate fixture-repo uses are the
# hard half of this rule. Without this, the empty result above is equally satisfied by a walk that
# never reached them, and the over-refusal control below would be measuring a file nothing scans.
LEGIT_ONE="$TESTS_DIR/test-mis-tier-tripwire.sh"
LEGIT_TWO="$TESTS_DIR/test-panel-composition-fail-direction.sh"
assert_eq "and the walk really reached the two suites that DO use these ranges, legitimately" \
  "$([[ -f "$LEGIT_ONE" && -f "$LEGIT_TWO" ]] && echo both || echo "MISSING")" "both"
assert_eq "CONTROL: those two suites really do carry the construct (else they prove nothing here)" \
  "$(grep -c -e "$OREF/.*\.\.HEAD" "$LEGIT_ONE" "$LEGIT_TWO" | awk -F: '{n+=$2} END {print (n>0 ? "carried" : "ABSENT")}')" \
  "carried"

# ---------------------------------------------------------------------------
suite "GATE BITES: the exact line from occurrence 2, and the legitimate use beside it"
# ---------------------------------------------------------------------------

# #37's own requirement, in its own words: plant the exact line from occurrence 2 and record the
# ratchet catching it, then plant a legitimate fixture-repo use and record it passing. Both
# probes are written here rather than committed under fixtures/, so the corpus assertion above
# never has to except them and can stay a statement about every file run.sh can reach.
PLANT_BAD="$SCRATCH/planted-offender.sh"
printf 'BRANCH_SUBJECTS=$(cd "$REPO_ROOT" && git log --format=%%s %s/main..HEAD 2>/dev/null)\n' "$OREF" > "$PLANT_BAD"
assert_contains "the planted probe really carries occurrence 2's line" "$(cat "$PLANT_BAD")" "REPO_ROOT"
assert_eq "CONTROL: the ratchet CATCHES occurrence 2, named by file and line" \
  "$(moving_ref_offenders "$PLANT_BAD")" "planted-offender.sh:1"

# The same derivation pointed at a fixture repo, which is what the two shipped suites do.
PLANT_GOOD="$SCRATCH/planted-fixture-use.sh"
printf 'CHANGED="$(git -C "$WORKTREE_PATH" diff --name-only %s/main...HEAD)"\n' "$OREF" > "$PLANT_GOOD"
assert_eq "CONTROL: and PASSES the identical range pointed at a fixture repo" \
  "$(moving_ref_offenders "$PLANT_GOOD")" ""

# The three spellings #37 enumerates, so the ratchet is not pinned to the one that broke last.
PLANT_TWODOT="$SCRATCH/planted-twodot.sh"
printf 'git log --format=%%s %s/main..HEAD\n' "$OREF" > "$PLANT_TWODOT"
assert_eq "the two-dot range with NO repo argument at all is caught (it inherits the checkout)" \
  "$(moving_ref_offenders "$PLANT_TWODOT")" "planted-twodot.sh:1"
PLANT_THREEDOT="$SCRATCH/planted-threedot.sh"
printf 'git -C "$REPO_ROOT" diff --name-only %s/main...HEAD\n' "$OREF" > "$PLANT_THREEDOT"
assert_eq "the three-dot range against the checkout is caught" \
  "$(moving_ref_offenders "$PLANT_THREEDOT")" "planted-threedot.sh:1"
PLANT_MERGEBASE="$SCRATCH/planted-mergebase.sh"
printf 'W=$(git -C "$REPO_ROOT" merge-base %s/main HEAD)\n' "$OREF" > "$PLANT_MERGEBASE"
assert_eq "and occurrence 1's merge-base spelling is caught too" \
  "$(moving_ref_offenders "$PLANT_MERGEBASE")" "planted-mergebase.sh:1"

# A branch other than main. The defect is the ref MOVING, not the word `main`.
PLANT_OTHER="$SCRATCH/planted-other-branch.sh"
printf 'git -C "$REPO_ROOT" log --format=%%s %s/develop..HEAD\n' "$OREF" > "$PLANT_OTHER"
assert_eq "any remote-tracking branch is a moving ref, not just main" \
  "$(moving_ref_offenders "$PLANT_OTHER")" "planted-other-branch.sh:1"

# ---------------------------------------------------------------------------
suite "the ratchet does not count prose, and does not count itself"
# ---------------------------------------------------------------------------

# #37 names this explicitly as one of the two things that make the ratchet non-trivial: the
# construct is DESCRIBED in comments all over this repo, directly above the code that uses it.
PLANT_COMMENT="$SCRATCH/planted-comment.sh"
printf '# it used to read `git log --format=%%s %s/main..HEAD` against $REPO_ROOT, and that broke\n' "$OREF" > "$PLANT_COMMENT"
assert_eq "a full-line comment describing the defect is prose, not the defect" \
  "$(moving_ref_offenders "$PLANT_COMMENT")" ""
# ...and the same text UNCOMMENTED is caught, so the exemption above is a discrimination and not
# a hole the next author can widen by shifting a line.
PLANT_UNCOMMENT="$SCRATCH/planted-uncommented.sh"
sed 's/^# it used to read `//; s/` against .*$//' "$PLANT_COMMENT" > "$PLANT_UNCOMMENT"
assert_contains "the uncommented twin really lost its comment marker" "$(cat "$PLANT_UNCOMMENT")" "git log"
assert_eq "CONTROL: uncommented, the identical text IS caught" \
  "$(moving_ref_offenders "$PLANT_UNCOMMENT")" "planted-uncommented.sh:1"

# THE SELF-COUNTING TRAP, closed by construction rather than by an exemption list. This file is in
# the population above and names the construct constantly; it passes because the remote-ref half
# is only ever produced by expanding $OREF at run time.
assert_eq "this suite is inside the population it walks" \
  "$(moving_ref_offenders "$TESTS_DIR/$(basename "${BASH_SOURCE[0]}")")" ""
# ...and it passes BY CONSTRUCTION rather than by an exemption list: every occurrence of the
# remote ref in this file is prose. An exemption would leave this file the one place the rule
# does not apply, which is where the next author would put the next occurrence.
assert_eq "CONTROL: and every occurrence of the ref in THIS file is a comment, never a pattern" \
  "$(grep -n "$OREF/" "${BASH_SOURCE[0]}" | grep -cv ':[[:space:]]*#' | tr -d ' ')" "0"

# =============================================================================
# SHAPE TWO: AN ABSOLUTE LINE RANGE INTO A SHIPPED DOCUMENT (#68).
# =============================================================================
#
# Same family, different moving thing. `sed -n '55,80p' "$PIPELINE_MD"` reads a 1100-line file
# that five lanes edit concurrently, so the population is decided by everyone else's edits
# rather than by the property under test. Measured: thirteen lines added to a section well ABOVE
# the region pushed the paragraph one line past the window and reddened two assertions while
# nothing about the property changed. And the failure invites the wrong remedy, which is to nudge
# the numbers. It is over-falsifiable upward and under-falsifiable downward at the same time:
# moving the sentences anywhere else INSIDE the window kept them green while the claim went false.
#
# THE DISCRIMINATOR IS THE OPERAND, and it is exact rather than heuristic. `sed -n 'N,Mp'` applied
# to a FILE is an offset into a document somebody else owns. The same script reading STDIN is an
# offset into a population this suite already derived for itself, which is a different statement
# and a correct one: test-claims-consumers.sh takes the lead paragraph of a section it extracted
# by heading, and that must not be refused.
#
# Written as case globs rather than as literals, for the same reason as $OREF above: this file is
# inside the population it walks. The globs require a DIGIT after `sed -n '`, and every occurrence
# in this file has a `[` or a `%` there instead.
RANGE_TO_FILE_QUOTED="*sed -n '[0-9]*,[0-9]*p' \"*"
RANGE_TO_FILE_BARE="*sed -n '[0-9]*,[0-9]*p' \$*"

# line_range_offenders <file>... -> one "<basename>:<lineno>" per offending line.
line_range_offenders() {
  local f line trimmed n hits=""
  for f in "$@"; do
    [[ -f "$f" ]] || continue
    n=0
    while IFS= read -r line || [[ -n "$line" ]]; do
      n=$((n + 1))
      trimmed="${line#"${line%%[![:space:]]*}"}"
      case "$trimmed" in '#'*) continue ;; esac
      case "$line" in
        $RANGE_TO_FILE_QUOTED|$RANGE_TO_FILE_BARE) hits="$hits $(basename "$f"):$n" ;;
      esac
    done < "$f"
  done
  printf '%s' "${hits# }"
}

# ---------------------------------------------------------------------------
suite "the ratchet: no test reads a shipped document through an absolute line range"
# ---------------------------------------------------------------------------

assert_eq "no test file pins a line range into a file it does not own" \
  "$(line_range_offenders "${POPULATION[@]}")" ""

# ---------------------------------------------------------------------------
suite "GATE BITES: #68's exact line, and the derived-population read beside it"
# ---------------------------------------------------------------------------

LR_BAD="$SCRATCH/planted-line-range.sh"
printf 'EVENTS_REGION=$(sed -n %s55,80p%s "$PIPELINE_MD")\n' "'" "'" > "$LR_BAD"
assert_contains "the planted probe really carries #68's line" "$(cat "$LR_BAD")" "PIPELINE_MD"
assert_eq "CONTROL: the ratchet CATCHES it, named by file and line" \
  "$(line_range_offenders "$LR_BAD")" "planted-line-range.sh:1"

# The legitimate shape, which is live in this repo today and must not be refused: an offset into
# a population the suite derived for itself, arriving on STDIN rather than as a file operand.
LR_GOOD="$SCRATCH/planted-derived-offset.sh"
printf 'WORDS=$(printf %s%%s\\n%s "$UPGRADE" | sed -n %s1,4p%s | grep -oE x)\n' "'" "'" "'" "'" > "$LR_GOOD"
assert_contains "the legitimate probe really carries the same sed script" "$(cat "$LR_GOOD")" "sed -n"
assert_eq "CONTROL: and PASSES the identical range applied to a derived population on stdin" \
  "$(line_range_offenders "$LR_GOOD")" ""

# The unquoted operand, so the rule is about the OPERAND and not about a quoting habit.
LR_BARE="$SCRATCH/planted-bare-operand.sh"
printf 'R=$(sed -n %s10,20p%s $PIPELINE_MD)\n' "'" "'" > "$LR_BARE"
assert_eq "an unquoted file operand is caught too" \
  "$(line_range_offenders "$LR_BARE")" "planted-bare-operand.sh:1"

# Prose, and its uncommented twin, exactly as for the moving-ref half.
LR_COMMENT="$SCRATCH/planted-line-range-comment.sh"
printf '# it used to read sed -n %s55,80p%s "$PIPELINE_MD", which broke whenever anyone edited above it\n' "'" "'" > "$LR_COMMENT"
assert_eq "a full-line comment describing the defect is prose, not the defect" \
  "$(line_range_offenders "$LR_COMMENT")" ""
LR_UNCOMMENT="$SCRATCH/planted-line-range-uncommented.sh"
sed 's/^# it used to read //; s/, which broke.*$//' "$LR_COMMENT" > "$LR_UNCOMMENT"
assert_contains "the uncommented twin really lost its comment marker" "$(cat "$LR_UNCOMMENT")" "sed -n"
assert_eq "CONTROL: uncommented, the identical text IS caught" \
  "$(line_range_offenders "$LR_UNCOMMENT")" "planted-line-range-uncommented.sh:1"

assert_eq "this suite is inside the population this half walks too" \
  "$(line_range_offenders "$TESTS_DIR/$(basename "${BASH_SOURCE[0]}")")" ""

finish
