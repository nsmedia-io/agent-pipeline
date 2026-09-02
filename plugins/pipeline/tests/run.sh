#!/usr/bin/env bash
# Runs every test suite under this directory: the bash hooks, the bundled .mjs scripts, and
# the harness itself. Exit 0 only when all pass.
#
# Wire this as your checkCommand to gate the plugin's own development:
#   { "checkCommand": "bash plugins/pipeline/tests/run.sh" }
#
# THE SUMMARY NAMES THE SUITES, not only how many there were (#91). A count alone is an
# observability defect with a measured cost: this summary reported "1 suite(s) FAILED" against a
# ~40-suite run during #56's review, and identifying WHICH suite meant grepping back through a
# transcript that scrolls past a terminal's scrollback. The per-suite `== name ==` banner is
# printed BEFORE the suite runs and says nothing about its outcome, so it is not a substitute.
#
# TWO PROPERTIES OF THIS HARNESS THAT LOOK LIKE FLAKES AND ARE NOT (#91, both reproduced during
# #56's review). Read these before concluding that a one-off red is a real regression.
#
#   (a) DO NOT RUN THIS CONCURRENTLY WITH AN IN-FLIGHT EDIT TO ../scripts/*.mjs. Every test-*.sh
#       here shells out to the LIVE checkout path (harness.sh's SCRIPTS_DIR is `../scripts`, a
#       read path into the working tree) rather than to a snapshot taken at the start of the run.
#       An editor or tool save that is mid-write when a suite reads the file yields a partial
#       file, so node reports a transient SyntaxError in exactly one invocation and the same
#       suite is green on the next run. DIRECTION: a FALSE RED, which is the cheap direction, but
#       it costs an investigation each time. It is a TOCTOU window, not a race this harness can
#       close from inside: the fix would be running against a snapshot, which would then test
#       code that is not the code in the tree.
#
#   (b) test-issue17-integration.sh's AC41(c) IS STRUCTURALLY BLIND TO UNCOMMITTED CHANGES. That
#       cell does `git clone file://$REPO_ROOT` into a temp dir and runs this script inside the
#       CLONE. A clone transfers committed refs only, so the nested run tests the tree as of the
#       last commit and never the working tree. If you are iterating on an uncommitted fix, the
#       nested run reports the PRE-implementation pass/fail tally while your outer run reports
#       the post-implementation one, and the two disagree for a reason that has nothing to do
#       with the change. COMMIT FIRST, then re-run, before treating that disagreement as a bug.
set -u

cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1

FAILED=0
# A newline-delimited STRING and not an array, matching harness.sh's TMP_REGISTRY for the same
# reason: bash 3.2 is what macOS ships and what this script runs under, and `"${arr[@]}"` on an
# empty array is an unbound-variable error there under `set -u`.
FAILED_SUITES=""
for t in test-*.sh; do
  [[ -f "$t" ]] || continue
  printf '\n\033[1m== %s ==\033[0m\n' "$t"
  bash "$t" || {
    FAILED=$((FAILED + 1))
    FAILED_SUITES="${FAILED_SUITES}  ${t}
"
  }
done

printf '\n'
if [[ "$FAILED" -eq 0 ]]; then
  printf 'All test suites passed.\n'
  exit 0
fi
printf '%s suite(s) FAILED.\n' "$FAILED"
printf '%s' "$FAILED_SUITES"
exit 1
