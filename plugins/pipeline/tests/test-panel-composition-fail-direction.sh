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

# The RUNNERS the blocks are exercised under. Two are guaranteed and a third is opportunistic.
# `bash-nosplit` is bash with IFS emptied, which disables field splitting: that is the DEFECT
# CONDITION of the second escape (see the matrix section below), reproduced in a shell every
# checkout has, so that dimension is never skipped for want of zsh. Real zsh is added when
# present, and the two are asserted equivalent rather than assumed to be.
RUNNERS=(bash bash-nosplit)
ZSH_PRESENT=no
if command -v zsh >/dev/null 2>&1; then RUNNERS+=(zsh); ZSH_PRESENT=yes; fi

in_shell() {  # $1 = runner name, $2 = script text; runs it, stdout only
  case "$1" in
    bash)         bash -c "$2" 2>/dev/null ;;
    bash-nosplit) bash -c "IFS=; $2" 2>/dev/null ;;
    zsh)          zsh  -c "$2" 2>/dev/null ;;
  esac
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
# The WHOLE delta block, not a reassembly of the two pieces this suite cares about. The
# previous version set FIX_CHANGED itself and spliced in only the probe definition and the
# probe calls, so the lines that PRODUCE the path list -- the ones the zsh word-splitting
# escape lived in -- were supplied by this file rather than observed from the artifact. Two
# placeholders are substituted because they are placeholders in the shipped text: the
# `<first-round-head>` anchor, and the jq line that reads a status.json no fixture has.
DELTA_RUNNABLE="$TEMP_PROJECT/delta-runnable.sh"
sed -e '/^FULL_PANEL=/d' -e 's/<first-round-head>/origin\/main/' "$DELTA_BLOCK" > "$DELTA_RUNNABLE"
run_delta() {  # $1 = WORKTREE_PATH, $2 = CLAUDE_PLUGIN_ROOT, $3 = runner (default bash)
  WORKTREE_PATH="$1" CLAUDE_PLUGIN_ROOT="$2" OBJECTING_ROLES="" \
    in_shell "${3:-bash}" ". \"$DELTA_RUNNABLE\"; printf 'DELTA=%s\n' \"\$ROLES_TO_MERGE\""
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

# =============================================================================
# THE SECOND ESCAPE: SHELL crossed with PATH COUNT.
# =============================================================================
#
# Every fixture above this line is a ONE-PATH diff, and every runner above this line is
# `bash -c`. Both dimensions that produce the defect were pinned to their safe value in every
# assertion, so a 202-line suite full of controls measured a control that did not work.
#
# The defect: `surface_probe <pred> $CHANGED` relies on the shell WORD-SPLITTING an unquoted
# parameter expansion. zsh does not do that -- and zsh is the shell the orchestrator's own
# tool runs -- so a multi-file diff arrived as ONE newline-joined argv element. The surface
# globs compile to `.`-based regexes and `.` does not match a newline, so the predicate
# matched nothing and returned the NO-MATCH sentinel: DBA and DevOps silently dropped, with
# no PANEL-NOTE, while status.json recorded a panel. A one-path diff has nothing to split, so
# it was right under both shells.
#
# The fix removes the shell from the path entirely (a NUL-delimited list read on stdin), so
# the matrix below is the proof that the OUTCOME no longer depends on either dimension.

run_panel_in() {  # $1 = runner, $2 = WORKTREE_PATH, $3 = CLAUDE_PLUGIN_ROOT
  WORKTREE_PATH="$2" CLAUDE_PLUGIN_ROOT="$3" \
    in_shell "$1" ". \"$PANEL_BLOCK\"; printf 'ROLES=%s\n' \"\$PANEL_ROLES\""
}

# MULTI-path fixtures: the dimension that did not exist. Each pairs the surface path with an
# ordinary one, which is what a real diff looks like and what the one-path fixtures could
# never construct.
DL_MULTI="$TEMP_PROJECT/repo-datalayer-multi"
make_diff_repo "$DL_MULTI" "db/migrate/001_add_users.rb" "src/app.ts"
INFRA_MULTI="$TEMP_PROJECT/repo-infra-multi"
make_diff_repo "$INFRA_MULTI" ".github/workflows/ci.yml" "src/app.ts"
CLEAN_MULTI="$TEMP_PROJECT/repo-clean-multi"
make_diff_repo "$CLEAN_MULTI" "docs/notes.txt" "docs/more.txt"

suite "NON-ZERO CONTROL FIRST: the pre-fix shape is OBSERVED failing on exactly this matrix"

# Without this, "the new block is right in every cell" is equally satisfied by a matrix that
# cannot tell the cells apart. This is the shipped shape as of d35da61, verbatim: an unquoted
# $CHANGED passed as argv, and 10 as the no-match sentinel.
OLD_SHAPE="$TEMP_PROJECT/old-shape-block.sh"
cat > "$OLD_SHAPE" <<'EOF'
PANEL_ROLES="ba dev qa secops"
CHANGED="$(git -C "$WORKTREE_PATH" diff --name-only origin/main...HEAD)"
surface_probe() {
  node -e 'import(process.env.CLAUDE_PLUGIN_ROOT + "/scripts/data-layer-surface.mjs").then(m=>{const f=m[process.argv[1]];if(typeof f!=="function")throw new Error("missing export "+process.argv[1]);process.exit(f(process.argv.slice(2))?0:10)}).catch(e=>{console.error("SURFACE-INDETERMINATE: "+process.argv[1]+": "+(e&&e.message));process.exit(1)})' "$@"
}
surface_probe diffTouchesDataLayer $CHANGED; RC=$?
if [ "$RC" -ne 10 ]; then PANEL_ROLES="$PANEL_ROLES dba"; fi
EOF
run_old_in() {  # $1 = runner, $2 = WORKTREE_PATH
  WORKTREE_PATH="$2" CLAUDE_PLUGIN_ROOT="$GOOD_ROOT" \
    in_shell "$1" ". \"$OLD_SHAPE\"; printf 'ROLES=%s\n' \"\$PANEL_ROLES\""
}

assert_contains "the pre-fix shape is RIGHT on a one-path data-layer diff under bash (which is why it shipped)" \
  "$(run_old_in bash "$DL_REPO")" "dba"
assert_contains "and right on a MULTI-path diff under bash, the only cell the old suite ever ran" \
  "$(run_old_in bash "$DL_MULTI")" "dba"
assert_contains "and right on a one-path diff under a NON-SPLITTING shell: nothing to split" \
  "$(run_old_in bash-nosplit "$DL_REPO")" "dba"
# THE CELL. One dimension is not enough; the defect needs both.
assert_not_contains "THE DEFECT: a MULTI-path data-layer diff under a NON-SPLITTING shell drops dba" \
  "$(run_old_in bash-nosplit "$DL_MULTI")" "dba"
assert_eq "and it drops it SILENTLY -- the panel reads as a clean diff, with no note" \
  "$(run_old_in bash-nosplit "$DL_MULTI")" "ROLES=ba dev qa secops"

suite "the bash-nosplit stand-in, and the EXACT boundary of what it stands in for"

# The stand-in is only worth anything if its scope is stated rather than assumed, and measuring
# it turned up a real difference that a looser claim would have hidden:
#
#   construct                          bash    zsh    bash-nosplit
#   set -- $VAR      (parameter)       split   NOT    NOT
#   set -- $(cmd)    (command subst)   split   split  NOT
#
# The defect under test is the PARAMETER form, and on that form the stand-in and zsh agree
# exactly -- which is what the assertion below measures rather than asserts. On the command
# substitution form they DIVERGE, and the divergence runs in the safe direction: bash-nosplit
# splits strictly less than zsh, so it reddens on every shape zsh reddens on and on some it
# does not. Over-detection is the correct direction for a guard; the reverse would be a
# stand-in that quietly passes a shape the real shell breaks on.
assert_eq "zsh availability is REPORTED, so an absent shell is never read as a passing cell" \
  "$([[ "$ZSH_PRESENT" == yes || "$ZSH_PRESENT" == no ]] && echo reported || echo unreported)" "reported"
split_argc() {  # $1 = runner, $2 = shell snippet ending in `set -- ...`
  in_shell "$1" "printf 'a\nb\n' > \"$TEMP_PROJECT/two-lines.txt\"; $2; echo \$#"
}
assert_eq "the two shells word-split an unquoted PARAMETER expansion identically: they do not split it" \
  "$(split_argc bash-nosplit 'V="$(cat '"$TEMP_PROJECT"'/two-lines.txt)"; set -- $V')" \
  "$([[ "$ZSH_PRESENT" == yes ]] && split_argc zsh 'V="$(cat '"$TEMP_PROJECT"'/two-lines.txt)"; set -- $V' || echo 1)"
assert_eq "CONTROL: plain bash DOES split it, which is the whole reason the escape was invisible here" \
  "$(split_argc bash 'V="$(cat '"$TEMP_PROJECT"'/two-lines.txt)"; set -- $V')" "2"
if [[ "$ZSH_PRESENT" == yes ]]; then
  assert_eq "and the boundary is pinned: on COMMAND SUBSTITUTION zsh splits where the stand-in does not" \
    "$(split_argc zsh 'set -- $(cat '"$TEMP_PROJECT"'/two-lines.txt)')/$(split_argc bash-nosplit 'set -- $(cat '"$TEMP_PROJECT"'/two-lines.txt)')" \
    "2/1"
  assert_eq "real zsh reproduces the shipped defect byte-for-byte, same as the stand-in" \
    "$(run_old_in zsh "$DL_MULTI")" "$(run_old_in bash-nosplit "$DL_MULTI")"
  assert_not_contains "and real zsh is the shell the orchestrator runs: it drops dba on the pre-fix shape" \
    "$(run_old_in zsh "$DL_MULTI")" "dba"
else
  assert_eq "zsh is ABSENT on this machine: the real-zsh cells were NOT RUN (the stand-in over-detects, so it still covers the condition)" \
    "not-run" "not-run"
fi

suite "THE FIX: the shipped block gives the same answer in every cell of shell x path count"

# The matrix, run in full. A per-runner loop rather than three hand-written triples, so adding
# a runner adds its whole column instead of one remembered case.
for runner in "${RUNNERS[@]}"; do
  assert_contains "[$runner] one-path data-layer diff seats dba" \
    "$(run_panel_in "$runner" "$DL_REPO" "$GOOD_ROOT")" "dba"
  assert_contains "[$runner] MULTI-path data-layer diff seats dba (the cell the escape lived in)" \
    "$(run_panel_in "$runner" "$DL_MULTI" "$GOOD_ROOT")" "dba"
  assert_contains "[$runner] one-path infra diff seats devops" \
    "$(run_panel_in "$runner" "$INFRA_REPO" "$GOOD_ROOT")" "devops"
  assert_contains "[$runner] MULTI-path infra diff seats devops" \
    "$(run_panel_in "$runner" "$INFRA_MULTI" "$GOOD_ROOT")" "devops"
  # OVER-REFUSAL CONTROL in the same column: a block that seated everyone would pass all four
  # cells above, so each column carries its own negative.
  assert_eq "[$runner] one-path clean diff seats neither" \
    "$(run_panel_in "$runner" "$CLEAN_REPO" "$GOOD_ROOT")" "ROLES=ba dev qa secops"
  assert_eq "[$runner] MULTI-path clean diff seats neither" \
    "$(run_panel_in "$runner" "$CLEAN_MULTI" "$GOOD_ROOT")" "ROLES=ba dev qa secops"
  # The infra column's own negative, which the two assertions above cannot supply: a
  # data-layer-only diff must not seat devops even when the list is multi-path.
  assert_not_contains "[$runner] MULTI-path data-layer diff does NOT seat devops" \
    "$(run_panel_in "$runner" "$DL_MULTI" "$GOOD_ROOT")" "devops"
  assert_not_contains "[$runner] MULTI-path infra diff does NOT seat dba" \
    "$(run_panel_in "$runner" "$INFRA_MULTI" "$GOOD_ROOT")" "dba"
done

suite "THE FIX: the delta round holds across the same matrix (the other two call sites)"

# The delta block is also the only extractable block carrying the FRONTEND probe. Its
# two-outcome shape is out of scope here (#20), but its path plumbing moved onto the same
# NUL-delimited list, so it gets the same matrix: a frontend probe that word-splits drops the
# Design lens on exactly the multi-path diffs a real frontend change produces.
FE_MULTI="$TEMP_PROJECT/repo-frontend-multi"
make_diff_repo "$FE_MULTI" "src/ui/Button.tsx" "src/lib/util.ts"
FE_ONE="$TEMP_PROJECT/repo-frontend-one"
make_diff_repo "$FE_ONE" "src/ui/Button.tsx"

for runner in "${RUNNERS[@]}"; do
  assert_contains "[$runner] a MULTI-path data-layer fix commit adds dba to the delta set" \
    "$(run_delta "$DL_MULTI" "$GOOD_ROOT" "$runner")" "dba"
  assert_contains "[$runner] a MULTI-path infra fix commit adds devops" \
    "$(run_delta "$INFRA_MULTI" "$GOOD_ROOT" "$runner")" "devops"
  assert_contains "[$runner] a one-path frontend fix commit adds design_review" \
    "$(run_delta "$FE_ONE" "$GOOD_ROOT" "$runner")" "design_review"
  assert_contains "[$runner] a MULTI-path frontend fix commit adds design_review" \
    "$(run_delta "$FE_MULTI" "$GOOD_ROOT" "$runner")" "design_review"
  assert_eq "[$runner] CONTROL: a MULTI-path fix commit touching neither surface leaves the seed alone" \
    "$(run_delta "$CLEAN_MULTI" "$GOOD_ROOT" "$runner")" "DELTA=qa secops"
  assert_not_contains "[$runner] CONTROL: a MULTI-path data-layer commit does NOT add design_review" \
    "$(run_delta "$DL_MULTI" "$GOOD_ROOT" "$runner")" "design_review"
done

suite "an unreadable or empty path list is INDETERMINATE, never no-match"

# QA measured the old probe with NO arguments at all returning the no-match sentinel: an empty
# list read as a clean diff. It is now a throw, so it lands in the seat-and-report branch.
EMPTY_REPO="$TEMP_PROJECT/repo-empty-diff"
make_diff_repo "$EMPTY_REPO" >/dev/null 2>&1
assert_eq "the empty-diff fixture really has an empty diff (else the two cases below test nothing)" \
  "$(git -C "$EMPTY_REPO" diff --name-only origin/main...HEAD | wc -l | tr -d ' ')" "0"
for runner in "${RUNNERS[@]}"; do
  EMPTY_OUT="$(run_panel_in "$runner" "$EMPTY_REPO" "$GOOD_ROOT")"
  assert_contains "[$runner] a diff with NO paths seats dba rather than reading as clean" "$EMPTY_OUT" "dba"
  assert_contains "[$runner] and says the seat came from indeterminacy" "$EMPTY_OUT" \
    "PANEL-NOTE: dba SEATED on an INDETERMINATE data-layer probe"
done

# git's own exit status: a WORKTREE_PATH that is not a repository, and a repository with no
# origin/main ref. Both print `fatal:` and yield an EMPTY list on stdout, which a
# `CHANGED="$(git ...)"` capture cannot tell from a clean diff. This one appears in this
# repository's own CI log, so it is not hypothetical.
NO_REMOTE="$TEMP_PROJECT/repo-no-origin-main"
mkdir -p "$NO_REMOTE"
git -C "$NO_REMOTE" init -q
git -C "$NO_REMOTE" -c user.email=t@t -c user.name=t commit -q --allow-empty -m only
for runner in "${RUNNERS[@]}"; do
  assert_contains "[$runner] a WORKTREE_PATH that is not a git repo SEATS dba" \
    "$(run_panel_in "$runner" "$TEMP_PROJECT/does-not-exist" "$GOOD_ROOT")" "dba"
  assert_contains "[$runner] a repo with no origin/main ref SEATS dba" \
    "$(run_panel_in "$runner" "$NO_REMOTE" "$GOOD_ROOT")" "dba"
done
assert_contains "and the git failure is named on stderr with its exit status" \
  "$(WORKTREE_PATH="$TEMP_PROJECT/does-not-exist" CLAUDE_PLUGIN_ROOT="$GOOD_ROOT" bash -c ". \"$PANEL_BLOCK\"; :" 2>&1 >/dev/null)" \
  "SURFACE-INDETERMINATE: git diff --name-only -z exited"

suite "the no-match sentinel is outside node's own reserved exit range"

# node RESERVES 1-14 (doc/api/process.md, "Exit codes"), and 10 is "Internal JavaScript
# Run-Time Failure" -- so the previous sentinel was a code node can emit on its own, which the
# block would have read as "the predicate ran and said no". 126/127/128+n belong to the shell.
assert_eq "the shipped blocks branch on 20, not on a code node reserves" \
  "$(grep -c '\-ne 10' "$PANEL_BLOCK" "$DELTA_BLOCK" | grep -cv ':0$' | tr -d ' ')" "0"
assert_eq "and 20 is what the probe returns on a real no-match" \
  "$(WORKTREE_PATH="$CLEAN_REPO" CLAUDE_PLUGIN_ROOT="$GOOD_ROOT" bash -c \
      "CHANGED_PATHS=\"\$(mktemp)\"; git -C \"\$WORKTREE_PATH\" diff --name-only -z origin/main...HEAD > \"\$CHANGED_PATHS\"
       $(probe_def "$PANEL_BLOCK")
       surface_probe diffTouchesDataLayer < \"\$CHANGED_PATHS\"; echo \$?; rm -f \"\$CHANGED_PATHS\"" 2>/dev/null)" \
  "20"
# CONTROL for that number: node reaches into the same band unprompted, which is the whole
# reason the sentinel moved. 13 is "Unsettled Top-Level Await", emitted with no process.exit.
assert_eq "CONTROL: node itself emits a code in the reserved band with no process.exit call" \
  "$(node --input-type=module -e 'await new Promise(() => {})' >/dev/null 2>&1; echo $?)" "13"
assert_contains "and the file states why 20 was chosen, at the point of use" "$(cat "$PIPELINE_MD")" \
  "20 is the no-match code because node RESERVES 1 through 14 for itself"

suite "the orchestrator is told to record the note it is now given"

assert_contains "the file states the three-outcome contract" "$(cat "$PIPELINE_MD")" \
  "Three outcomes, never two, and the third one SEATS."
assert_contains "and tells the orchestrator to record a PANEL-NOTE in status.json flags" \
  "$(cat "$PIPELINE_MD")" 'record that sentence in `status.json` (`flags`)'
assert_contains "and keeps the no-pipe rule at the point of use" "$(cat "$PIPELINE_MD")" \
  'Never write this as `surface_probe ... | grep -q ...`'

finish
