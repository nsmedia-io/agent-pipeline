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

# =============================================================================
# AC35 -- THE NEW SUITES ACTUALLY RUN.
# =============================================================================
suite "AC35: run.sh's flat glob reaches every suite this change adds"

# Verified against run.sh's OWN discovery rule, executed here, rather than by reading the
# filenames: the rule is a flat `test-*.sh` glob with no recursion, so a suite one directory
# down is a file nobody runs. run.sh itself is not invoked, because run.sh invokes THIS file:
# the recursion would never terminate, and a suite that skipped itself to avoid that would be
# the self-skip this repo refuses. The glob is therefore reproduced from run.sh's source line.
GLOB_LINE="$(grep -n 'for t in test-' "$TESTS_DIR/run.sh" | head -1)"
assert_contains "run.sh still discovers by a flat test-*.sh glob" "$GLOB_LINE" "for t in test-*.sh"
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
WF_WITH_SUITE="$(grep -rl 'plugins/pipeline/tests/run.sh' "$WF_DIR" 2>/dev/null | head -1)"
assert_eq "at least one workflow invokes tests/run.sh (a rename cannot silently drop it)" \
  "$([[ -n "$WF_WITH_SUITE" ]] && echo yes || echo "no: nothing in .github/workflows runs the suite")" "yes"
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
  assert_eq "and every one of them reported zero failures" \
    "$(printf '%s' "$FRESH_OUT" | grep -c 'failed=0' | tr -d ' ')" "$FRESH_SUITES"
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

BASE="$(git -C "$REPO_ROOT" merge-base origin/main HEAD 2>/dev/null)"
LOG="$(git -C "$REPO_ROOT" log --reverse --format='%H %s' "$BASE"..HEAD 2>/dev/null)"
sha_of() { printf '%s\n' "$LOG" | grep -m1 -F "$1" | cut -d' ' -f1; }
pos_of() { printf '%s\n' "$LOG" | grep -n -F "$1" | head -1 | cut -d: -f1; }

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

revert_touches() { # <sha> -> "clean:<files>" | "CONFLICT"
  local sha="$1" wt="$TEMP_PROJECT/revert-${sha:0:7}"
  git -C "$REPO_ROOT" worktree add -q --detach "$wt" "${SERIES_TIP_SHA:-HEAD}" >/dev/null 2>&1 || { printf 'CONFLICT'; return 0; }
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
revert_touches_at() { # <anchor-ish> <sha> -> "clean:<files>" | "CONFLICT"
  local anchor="$1" sha="$2" wt="$TEMP_PROJECT/revert-at-${anchor:0:7}-${sha:0:7}"
  git -C "$REPO_ROOT" worktree add -q --detach "$wt" "$anchor" >/dev/null 2>&1 || { printf 'CONFLICT'; return 0; }
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
  "$(revert_touches_at HEAD "$EMPTY_TREE_SHA")" "CONFLICT"
assert_eq "CONTROL: and it reports CONFLICT for an anchor that does not exist, rather than a bare clean:" \
  "$(revert_touches_at 'no-such-anchor-ref' "$(sha_of 'fix: panel composition seats the specialist')")" \
  "CONFLICT"

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
# ROUND 2 IS DERIVED FROM GIT, not listed. A hand-maintained list cannot contain the LAST
# commit of its own round -- adding that entry needs a further commit, which then becomes the
# new last commit, forever one behind. Round 2 is by definition everything after the round-1
# tip, which git can answer exactly, so the newest commit is covered the moment it exists.
# Round 1 stays a written list because it is closed history: it names what was reviewed.
ROUND2_SHAS=()
while IFS= read -r h; do [[ -n "$h" ]] && ROUND2_SHAS+=("$h"); done \
  < <(git -C "$REPO_ROOT" log --reverse --format='%H' "$ROUND1_TIP_SHA"..HEAD 2>/dev/null)
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
# The derived set is asserted NON-EMPTY first. `git log A..HEAD` returns nothing when A is
# unresolvable, and a loop over nothing reports all-clean: the exact shape where "checked and
# fine" and "never checked" produce the same output.
assert_eq "round 2 is non-empty (a clean sweep over zero commits proves nothing)" \
  "$([[ "${#ROUND2_SHAS[@]}" -ge 1 ]] && echo ">=1" || echo "EMPTY: nothing after the round-1 tip")" ">=1"
ROUND2_CONFLICTS=""
for h in "${ROUND2_SHAS[@]}"; do
  [[ "$(revert_touches_at HEAD "$h")" == clean:* ]] \
    || ROUND2_CONFLICTS="$ROUND2_CONFLICTS|$(git -C "$REPO_ROOT" log -1 --format=%s "$h")"
done
assert_eq "and every round-2 commit reverts cleanly at HEAD, which is round 2's own tip" \
  "$([[ -z "$ROUND2_CONFLICTS" ]] && echo all-clean || echo "conflicts:$ROUND2_CONFLICTS")" "all-clean"
# CONTROL for check_round: it must be able to report a MISSING subject, or "all-clean" is a
# statement about a loop that never looked anything up.
assert_contains "CONTROL: check_round reports a subject that is not on the branch" \
  "$(check_round HEAD 'chore: a subject no commit on this branch carries')" "missing:"

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
assert_contains "test-gate-pre-phase4.sh passes in full" "$GATE_OUT" "passed=56 failed=0"
# The count is pinned as well as the verdict: a suite that passes with FEWER assertions than
# it shipped with has had a case deleted, which is exactly how a fail-closed gate loses its
# deletion-exemption coverage quietly.
assert_eq "and it still carries all 56 assertions (a green with fewer is a deleted case)" \
  "$(printf '%s' "$GATE_OUT" | grep -c '^  ok' | tr -d ' ')" "56"
assert_eq "no assertion line in it was modified by this change" \
  "$(git -C "$REPO_ROOT" diff origin/main...HEAD -- plugins/pipeline/tests/test-gate-pre-phase4.sh | grep -c '^[+-][^+-].*assert_')" "0"

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
assert_eq "the executable-down boundary now points at #16" \
  "$(grep -c 'Tracked as follow-up issue #16' "$GATE_SUITE" | tr -d ' ')" "1"
assert_eq "and no longer at issue 4" "$(grep -c 'Tracked as follow-up issue 4' "$GATE_SUITE" | tr -d ' ')" "0"

# The pointer is resolved against the ISSUE'S TITLE, not by asserting a digit is present: #4
# is a merged voice fix, and a digit-only check would have accepted it. Skipped, loudly, when
# no GitHub CLI credential is available, because an unauthenticated `gh` cannot distinguish
# "the title does not match" from "I could not look".
if gh issue view 16 --json title >/dev/null 2>&1; then
  TITLE16="$(gh issue view 16 --json title -q .title 2>/dev/null)"
  assert_contains "#16's live title is about the gap the comment describes" "$TITLE16" "executable down section"
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
