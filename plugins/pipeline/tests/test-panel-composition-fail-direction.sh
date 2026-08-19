#!/usr/bin/env bash
# Phase 4 panel composition, and the ONE thing about it that is a control rather than a
# convenience: what it does when the surface predicate cannot be evaluated at all.
#
# THE ESCAPE THIS SUITE EXISTS FOR. Issue #17 replaced four `grep -qE` panel-composition
# calls with `node -e '...process.exit(pred?0:1)'`. Against a ${CLAUDE_PLUGIN_ROOT} with no
# scripts/ directory -- a live condition on a machine with a stale installed plugin cache --
# that shape exits 1 with ZERO bytes on stdout and ZERO bytes on stderr, which is
# byte-identical to "the diff does not touch the surface". DBA and DevOps were dropped from
# the panel while status.json recorded a panel and the PR summary claimed it reviewed the
# diff. A grep cannot fail that way, so the change INTRODUCED the failure mode.
#
# The fix is three outcomes rather than two (match / no-match / INDETERMINATE), and the
# direction is the one the mis-tier tripwire already states: an unevaluable check cannot know
# the answer is negative. The tripwire HALTS because it cannot know the diff was clean; panel
# composition SEATS because it cannot know the diff misses the surface.
#
# Every case below runs the block EXTRACTED FROM commands/pipeline.md verbatim, against a
# real throwaway git repo, because the shipped artifact is that text and a test over a
# hand-copied paraphrase tracks the copier's attention rather than what the orchestrator runs.

. "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
require_node

make_temp_project || exit 90

PIPELINE_MD="$PLUGIN_ROOT/commands/pipeline.md"

# ---- extraction -------------------------------------------------------------
PANEL_BLOCK="$TEMP_PROJECT/panel-block.sh"
awk '/^PANEL_ROLES="ba dev qa secops"$/{f=1} f{print} f&&/^```$/{exit}' "$PIPELINE_MD" \
  | grep -v '^```' > "$PANEL_BLOCK"
DELTA_BLOCK="$TEMP_PROJECT/delta-block.sh"
awk '/^# The FULL panel is whatever was recorded in status.json panel_roles on the first$/{f=1} f{print} f&&/^```$/{exit}' "$PIPELINE_MD" \
  | grep -v '^```' > "$DELTA_BLOCK"

suite "the blocks under test were actually extracted (without this, every case below measures an empty file)"

assert_eq "the standard-tier panel-composition block is non-empty" \
  "$([[ -s "$PANEL_BLOCK" ]] && echo yes || echo no)" "yes"
assert_eq "the delta re-review block is non-empty" \
  "$([[ -s "$DELTA_BLOCK" ]] && echo yes || echo no)" "yes"
assert_eq "the panel block carries both surface probes" \
  "$(grep -c '^surface_probe diffTouches' "$PANEL_BLOCK" | tr -d ' ')" "2"
assert_eq "and so does the delta block" \
  "$(grep -c '^surface_probe diffTouches' "$DELTA_BLOCK" | tr -d ' ')" "2"

suite "the two probe definitions are byte-identical, so a delta round cannot drift from round 1"

# Duplicated text is only safe when the duplication is checkable. Extract each definition and
# diff them, rather than asserting a substring appears twice: a substring assertion passes on
# two definitions that differ anywhere outside the substring.
probe_def() { awk '/^surface_probe\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "$1"; }
assert_eq "the panel-block definition and the delta-block definition are the same text" \
  "$(diff <(probe_def "$PANEL_BLOCK") <(probe_def "$DELTA_BLOCK") >/dev/null && echo identical || echo DIVERGED)" \
  "identical"
assert_eq "CONTROL: the diff comparison is live -- a one-character edit reads as DIVERGED" \
  "$(diff <(probe_def "$PANEL_BLOCK") <(probe_def "$DELTA_BLOCK" | sed 's/exit(1)/exit(2)/') >/dev/null && echo identical || echo DIVERGED)" \
  "DIVERGED"

suite "the shape cannot swallow an exit status"

# The defect class in one line: `<probe> | grep -q` discards the probe's status, so an absent
# module reads as a clean diff. Asserted over the shipped text of BOTH blocks.
assert_eq "no probe invocation is piped in the panel block" \
  "$(grep -c 'surface_probe.*|' "$PANEL_BLOCK" | tr -d ' ')" "0"
assert_eq "no probe invocation is piped in the delta block" \
  "$(grep -c 'surface_probe.*|' "$DELTA_BLOCK" | tr -d ' ')" "0"
assert_eq "the old two-outcome shape is gone from the whole file" \
  "$(grep -c 'diffTouchesDataLayer(process.argv.slice(1))?0:1' "$PIPELINE_MD" | tr -d ' ')" "0"
assert_eq "and so is its infra twin" \
  "$(grep -c 'diffTouchesInfra(process.argv.slice(1))?0:1' "$PIPELINE_MD" | tr -d ' ')" "0"

# ---- fixtures ---------------------------------------------------------------
#
# A repo whose origin/main...HEAD diff is exactly the paths passed in. `origin/main` is created
# as a local ref of that name, which is what the block's `git diff origin/main...HEAD` resolves.
make_diff_repo() {  # $1 = dest dir, remaining args = paths to add in the HEAD commit
  local dir="$1"; shift
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
  git -C "$dir" branch origin/main
  local p
  for p in "$@"; do
    mkdir -p "$dir/$(dirname "$p")"
    printf 'x\n' > "$dir/$p"
    git -C "$dir" add "$p"
  done
  git -C "$dir" -c user.email=t@t -c user.name=t commit -q -m change
}

# Runs the extracted panel block and echoes the resolved PANEL_ROLES plus any PANEL-NOTE.
run_panel() {  # $1 = WORKTREE_PATH, $2 = CLAUDE_PLUGIN_ROOT
  WORKTREE_PATH="$1" CLAUDE_PLUGIN_ROOT="$2" bash -c \
    ". \"$PANEL_BLOCK\"; printf 'ROLES=%s\n' \"\$PANEL_ROLES\"" 2>/dev/null
}
run_panel_stderr() {
  WORKTREE_PATH="$1" CLAUDE_PLUGIN_ROOT="$2" bash -c \
    ". \"$PANEL_BLOCK\"; :" 2>&1 >/dev/null
}
run_delta() {  # $1 = WORKTREE_PATH, $2 = CLAUDE_PLUGIN_ROOT
  WORKTREE_PATH="$1" CLAUDE_PLUGIN_ROOT="$2" bash -c \
    "FIX_CHANGED=\"\$(git -C \"\$WORKTREE_PATH\" diff --name-only origin/main...HEAD)\"
     DELTA=\"qa secops\"
     $(probe_def "$DELTA_BLOCK")
     $(awk '/^surface_probe diffTouches/{f=1} f{print}' "$DELTA_BLOCK")
     printf 'DELTA=%s\n' \"\$DELTA\"" 2>/dev/null
}

DL_REPO="$TEMP_PROJECT/repo-datalayer"; make_diff_repo "$DL_REPO" "db/queries/orders.ts"
INFRA_REPO="$TEMP_PROJECT/repo-infra"; make_diff_repo "$INFRA_REPO" ".github/workflows/ci.yml"
# The clean repo's path must miss ALL THREE surfaces, not just the two under test: the delta
# block also carries the (pre-existing, out-of-scope) frontend probe, and a `src/ui/*.tsx`
# fixture seats design_review there, which would read as a failure of this suite's control.
CLEAN_REPO="$TEMP_PROJECT/repo-clean"; make_diff_repo "$CLEAN_REPO" "docs/notes.txt"

# The real plugin root, and a BROKEN one: a directory that exists but has no scripts/, which
# is exactly the stale-cache shape QA reproduced.
GOOD_ROOT="$PLUGIN_ROOT"
BROKEN_ROOT="$TEMP_PROJECT/stale-plugin-cache"
mkdir -p "$BROKEN_ROOT"

suite "NON-ZERO CONTROLS FIRST: with a working module the probe still discriminates"

# Without these three, "dba is seated" below would be indistinguishable from a block that
# seats everyone unconditionally, and the whole suite would be a rubber stamp.
assert_contains "a data-layer path SEATS dba" "$(run_panel "$DL_REPO" "$GOOD_ROOT")" "dba"
assert_not_contains "and that same clean-module run does NOT seat devops" "$(run_panel "$DL_REPO" "$GOOD_ROOT")" "devops"
assert_contains "an infra path SEATS devops" "$(run_panel "$INFRA_REPO" "$GOOD_ROOT")" "devops"
assert_not_contains "and that same run does NOT seat dba" "$(run_panel "$INFRA_REPO" "$GOOD_ROOT")" "dba"
assert_eq "a diff that touches neither surface seats neither" \
  "$(run_panel "$CLEAN_REPO" "$GOOD_ROOT")" "ROLES=ba dev qa secops"
assert_eq "no PANEL-NOTE is emitted when the probe actually ran" \
  "$(run_panel "$CLEAN_REPO" "$GOOD_ROOT" | grep -c 'PANEL-NOTE' | tr -d ' ')" "0"

suite "THE BLOCKER: an UNEVALUABLE probe seats the specialist instead of silently dropping it"

BROKEN_OUT="$(run_panel "$CLEAN_REPO" "$BROKEN_ROOT")"
assert_contains "with no scripts/ under CLAUDE_PLUGIN_ROOT, dba is SEATED" "$BROKEN_OUT" "dba"
assert_contains "and devops is SEATED" "$BROKEN_OUT" "devops"
# The seat alone is not enough: an over-seated panel that says nothing is a panel whose
# recorded panel_roles lies about WHY the role is there.
assert_contains "a PANEL-NOTE names dba as seated on indeterminacy, not on a match" "$BROKEN_OUT" \
  "PANEL-NOTE: dba SEATED on an INDETERMINATE data-layer probe"
assert_contains "and one names devops" "$BROKEN_OUT" \
  "PANEL-NOTE: devops SEATED on an INDETERMINATE infra probe"
assert_contains "the underlying failure is reported on stderr, not swallowed" \
  "$(run_panel_stderr "$CLEAN_REPO" "$BROKEN_ROOT")" "SURFACE-INDETERMINATE: diffTouchesDataLayer"

# The same input the escape was measured on: a CLEAN diff plus a broken root. Before the fix
# this produced "ROLES=ba dev qa secops" with zero output on both streams.
assert_eq "the indeterminate panel is materially different from the clean-diff panel" \
  "$([[ "$(run_panel "$CLEAN_REPO" "$BROKEN_ROOT" | grep '^ROLES=')" == "$(run_panel "$CLEAN_REPO" "$GOOD_ROOT" | grep '^ROLES=')" ]] && echo IDENTICAL || echo different)" \
  "different"

suite "the indeterminate branch catches failures nobody enumerated, not just a missing module"

# A blocklist over one failure spelling is the wrong side of the transformation. The property
# is OUTCOME-shaped: the seat is withheld only on the single code that means "ran, said no".
# A module that EXISTS but throws on import, and a module missing the export, both seat.
THROW_ROOT="$TEMP_PROJECT/throwing-plugin"
mkdir -p "$THROW_ROOT/scripts"
printf 'throw new Error("boom on import");\n' > "$THROW_ROOT/scripts/data-layer-surface.mjs"
assert_contains "a module that THROWS on import seats dba" "$(run_panel "$CLEAN_REPO" "$THROW_ROOT")" "dba"

RENAMED_ROOT="$TEMP_PROJECT/renamed-export-plugin"
mkdir -p "$RENAMED_ROOT/scripts"
printf 'export function somethingElse(){return false}\n' > "$RENAMED_ROOT/scripts/data-layer-surface.mjs"
assert_contains "a module whose export was RENAMED seats dba" "$(run_panel "$CLEAN_REPO" "$RENAMED_ROOT")" "dba"
assert_contains "and says which export it could not find" \
  "$(run_panel_stderr "$CLEAN_REPO" "$RENAMED_ROOT")" "missing export diffTouchesDataLayer"

# A module that loads and answers FALSE must still withhold the seat, or the three cases above
# prove nothing beyond "this block seats dba whenever the module is not the real one".
FALSE_ROOT="$TEMP_PROJECT/honest-false-plugin"
mkdir -p "$FALSE_ROOT/scripts"
printf 'export function diffTouchesDataLayer(){return false}\nexport function diffTouchesInfra(){return false}\n' \
  > "$FALSE_ROOT/scripts/data-layer-surface.mjs"
assert_eq "CONTROL: a module that loads and honestly answers false seats NOBODY" \
  "$(run_panel "$CLEAN_REPO" "$FALSE_ROOT")" "ROLES=ba dev qa secops"

suite "the DELTA re-review round fails the same direction (the other two of the four sites)"

assert_contains "a data-layer fix commit adds dba to the delta set" "$(run_delta "$DL_REPO" "$GOOD_ROOT")" "dba"
assert_eq "CONTROL: a fix commit touching neither surface leaves the delta seed alone" \
  "$(run_delta "$CLEAN_REPO" "$GOOD_ROOT")" "DELTA=qa secops"
BROKEN_DELTA="$(run_delta "$CLEAN_REPO" "$BROKEN_ROOT")"
assert_contains "an unevaluable delta probe adds dba" "$BROKEN_DELTA" "dba"
assert_contains "and devops" "$BROKEN_DELTA" "devops"
assert_contains "and emits the note" "$BROKEN_DELTA" "PANEL-NOTE: dba SEATED on an INDETERMINATE"

suite "the orchestrator is told to record the note it is now given"

assert_contains "the file states the three-outcome contract" "$(cat "$PIPELINE_MD")" \
  "Three outcomes, never two, and the third one SEATS."
assert_contains "and tells the orchestrator to record a PANEL-NOTE in status.json flags" \
  "$(cat "$PIPELINE_MD")" 'record that sentence in `status.json` (`flags`)'
assert_contains "and keeps the no-pipe rule at the point of use" "$(cat "$PIPELINE_MD")" \
  'Never write this as `surface_probe ... | grep -q ...`'

finish
