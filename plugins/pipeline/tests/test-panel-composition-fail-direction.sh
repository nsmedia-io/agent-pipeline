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
PANEL_COMPOSE="$TEMP_PROJECT/panel-compose.sh"
awk '/^PANEL_ROLES="ba dev qa secops"$/{f=1} f{print} f&&/^```$/{exit}' "$PIPELINE_MD" \
  | grep -v '^```' > "$PANEL_COMPOSE"
# The Design block is a SEPARATE fence that runs in the same shell immediately after the one
# above: it uses that block's $CHANGED_PATHS and its surface_probe. Concatenating them is what
# the orchestrator does, and it is the only way the panel-path FRONTEND probe is reachable at
# all -- extracting the first fence alone is why #20 sat untested in a suite named for this
# exact failure direction while the delta block's copy of it was covered.
DESIGN_BLOCK="$TEMP_PROJECT/design-block.sh"
awk '/^# \$CHANGED_PATHS is the NUL-delimited diff path list, and `surface_probe` is the function$/{f=1} f{print} f&&/^```$/{exit}' "$PIPELINE_MD" \
  | grep -v '^```' > "$DESIGN_BLOCK"
PANEL_BLOCK="$TEMP_PROJECT/panel-block.sh"
cat "$PANEL_COMPOSE" "$DESIGN_BLOCK" > "$PANEL_BLOCK"
DELTA_BLOCK="$TEMP_PROJECT/delta-block.sh"
awk '/^# The FULL panel is whatever was recorded in status.json panel_roles on the first$/{f=1} f{print} f&&/^```$/{exit}' "$PIPELINE_MD" \
  | grep -v '^```' > "$DELTA_BLOCK"

suite "the blocks under test were actually extracted (without this, every case below measures an empty file)"

assert_eq "the standard-tier panel-composition block is non-empty" \
  "$([[ -s "$PANEL_COMPOSE" ]] && echo yes || echo no)" "yes"
assert_eq "the Design block is non-empty (its anchor comment is how it is found)" \
  "$([[ -s "$DESIGN_BLOCK" ]] && echo yes || echo no)" "yes"
assert_eq "the delta re-review block is non-empty" \
  "$([[ -s "$DELTA_BLOCK" ]] && echo yes || echo no)" "yes"
assert_eq "the panel path carries all THREE surface probes once the two fences are joined" \
  "$(grep -c '^surface_probe [a-z-]*\.mjs diffTouches' "$PANEL_BLOCK" | tr -d ' ')" "3"
assert_eq "and so does the delta block" \
  "$(grep -c '^surface_probe [a-z-]*\.mjs diffTouches' "$DELTA_BLOCK" | tr -d ' ')" "3"
# Each surface is named EXPLICITLY. Counting to three passes on three copies of one probe,
# which is the shape a careless de-duplication produces.
for pred in diffTouchesDataLayer diffTouchesInfra diffTouchesFrontend; do
  assert_eq "the panel path probes $pred exactly once" \
    "$(grep -c "^surface_probe [a-z-]*\.mjs $pred " "$PANEL_BLOCK" | tr -d ' ')" "1"
  assert_eq "and the delta block probes $pred exactly once" \
    "$(grep -c "^surface_probe [a-z-]*\.mjs $pred " "$DELTA_BLOCK" | tr -d ' ')" "1"
done

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

suite "the MANUAL entry point carries the same contract, and cannot drift from it silently"

# `/phase peer-review` claims in its own text to mirror `/pipeline` Phase 4 "exactly, including
# the delta re-review semantics, so a manual re-run and the auto re-review never diverge". It
# then described the surface test as "the same one-liners /pipeline Phase 4 uses" and named the
# three exports and two modules -- and NOTHING about the reserved exit code, the indeterminate
# branch, or the fail direction. An orchestrator following phase.md alone would have written
# the two-outcome shape this whole suite exists to refuse, at the entry point a human reaches
# for when the automatic round has already gone wrong.
#
# It survived because no suite read that file: `grep -rn 'phase\.md' tests/*.sh` returned
# nothing while two suites extracted and executed pipeline.md. The contract below is therefore
# DERIVED FROM pipeline.md on every run -- the sentinel is read out of the shipped probe, the
# predicate list out of the shipped delta block -- so changing the contract in one file and not
# the other reddens here instead of shipping as a divergence.
PHASE_MD="$PLUGIN_ROOT/commands/phase.md"

phase_peer_review_section() {  # <phase.md> -> the text of its "### peer-review" section
  awk '/^### peer-review$/{f=1;next} f&&/^### /{exit} f{print}' "$1"
}
probe_sentinel() {  # <pipeline.md> -> the reserved NO-MATCH code, read from the probe itself
  grep -o 'process\.exit(f(paths)?0:[0-9]\{1,\})' "$1" | head -1 | sed 's/.*?0://;s/)$//'
}
delta_predicates() {  # <delta block> -> the predicate each shipped probe call names
  grep '^surface_probe ' "$1" | awk '{print $3}' | sort -u
}
phase_md_drift() {  # <phase.md> <pipeline.md> <delta block> -> "" when the two agree
  local phase="$1"
  local pipeline="$2"
  local delta="$3"
  local sec
  local sentinel
  local pred
  local out=""
  sec="$(phase_peer_review_section "$phase")"
  [[ -n "$sec" ]] || { printf 'no ### peer-review section in %s' "$phase"; return 0; }
  sentinel="$(probe_sentinel "$pipeline")"
  [[ -n "$sentinel" ]] || { printf 'no probe sentinel found in %s' "$pipeline"; return 0; }
  case "$sec" in *"$sentinel"*) ;; *) out="$out|does not state the reserved no-match code $sentinel" ;; esac
  case "$sec" in *INDETERMINATE*) ;; *) out="$out|does not name the INDETERMINATE outcome" ;; esac
  case "$sec" in *PANEL-NOTE*) ;; *) out="$out|does not carry the PANEL-NOTE record of a seat-on-indeterminate" ;; esac
  case "$sec" in *surface_probe*) ;; *) out="$out|does not name surface_probe, the shared definition" ;; esac
  case "$sec" in *commands/pipeline.md*) ;; *) out="$out|does not point at the file that holds the one definition" ;; esac
  while IFS= read -r pred; do
    [[ -n "$pred" ]] || continue
    case "$sec" in *"$pred"*) ;; *) out="$out|never names $pred, which the delta block probes" ;; esac
  done < <(delta_predicates "$delta")
  printf '%s' "$out"
}

# The inputs first. A drift check over an empty section or an unfound sentinel reports whatever
# its author's optimism supplies, and both failure shapes print something other than "" above.
assert_eq "phase.md exists and has a peer-review section to check" \
  "$([[ -n "$(phase_peer_review_section "$PHASE_MD")" ]] && echo present || echo "ABSENT")" "present"
assert_eq "the reserved no-match code is READ from pipeline.md's probe, not remembered here" \
  "$(probe_sentinel "$PIPELINE_MD")" "20"
assert_eq "and the delta block names three predicates for the check to walk" \
  "$(delta_predicates "$DELTA_BLOCK" | grep -c . | tr -d ' ')" "3"

assert_eq "phase.md's manual peer-review carries the same three-outcome contract as pipeline.md" \
  "$(phase_md_drift "$PHASE_MD" "$PIPELINE_MD" "$DELTA_BLOCK")" ""

# ONE DEFINITION, not two. The fix for the divergence is a POINTER at pipeline.md's probe, so a
# second copy of the probe body in phase.md would re-create the thing that drifted.
assert_eq "phase.md keeps no second copy of the probe body" \
  "$(grep -c 'process.exit(f(paths)?0:' "$PHASE_MD" | tr -d ' ')" "0"
assert_eq "CONTROL: the same grep DOES find the body in pipeline.md, where it is defined twice" \
  "$(grep -c 'process.exit(f(paths)?0:' "$PIPELINE_MD" | tr -d ' ')" "2"

# NON-ZERO CONTROLS, one per way the two files can drift apart. Each mutates a COPY in the
# scratch project; nothing in the checkout is touched.
DRIFT_PHASE="$TEMP_PROJECT/phase-no-sentinel.md"
# EVERY occurrence, not the bolded one: the first spelling of this control replaced `**20**`
# alone and the check stayed green, because the same sentence states the code three more times
# in plain text. A mutation that leaves the property standing measures nothing, so the mutated
# copy is asserted to have really lost it before the control is read.
sed 's/20/NN/g' "$PHASE_MD" > "$DRIFT_PHASE"
assert_eq "the mutated phase.md really lost the sentinel (or the control below measures nothing)" \
  "$(phase_peer_review_section "$DRIFT_PHASE" | grep -c '20' | tr -d ' ')" "0"
assert_contains "CONTROL: a phase.md that stops stating the sentinel is reported" \
  "$(phase_md_drift "$DRIFT_PHASE" "$PIPELINE_MD" "$DELTA_BLOCK")" "does not state the reserved no-match code 20"
DRIFT_PHASE2="$TEMP_PROJECT/phase-no-indeterminate.md"
sed 's/INDETERMINATE/a no-match/g' "$PHASE_MD" > "$DRIFT_PHASE2"
assert_contains "CONTROL: a phase.md that loses the indeterminate branch is reported" \
  "$(phase_md_drift "$DRIFT_PHASE2" "$PIPELINE_MD" "$DELTA_BLOCK")" "does not name the INDETERMINATE outcome"
# THE DRIFT DIRECTION THAT ACTUALLY HAPPENED: pipeline.md moves and phase.md is left behind.
DRIFT_PIPELINE="$TEMP_PROJECT/pipeline-sentinel-21.md"
sed 's/process\.exit(f(paths)?0:20)/process.exit(f(paths)?0:21)/g' "$PIPELINE_MD" > "$DRIFT_PIPELINE"
assert_eq "the mutated pipeline.md really carries the new sentinel (or the control below measures nothing)" \
  "$(probe_sentinel "$DRIFT_PIPELINE")" "21"
assert_contains "CONTROL: moving the sentinel in pipeline.md alone reddens this check" \
  "$(phase_md_drift "$PHASE_MD" "$DRIFT_PIPELINE" "$DELTA_BLOCK")" "does not state the reserved no-match code 21"
# ...and the same direction for a NEW probe: adding a fourth surface to the delta block without
# telling phase.md about it is the divergence one size up.
DRIFT_DELTA="$TEMP_PROJECT/delta-fourth-probe.sh"
cp "$DELTA_BLOCK" "$DRIFT_DELTA"
printf 'surface_probe some-surface.mjs diffTouchesSomethingNew < "$FIX_CHANGED_PATHS"; RC=$?\n' >> "$DRIFT_DELTA"
assert_contains "CONTROL: a fourth probe in the delta block that phase.md never names is reported" \
  "$(phase_md_drift "$PHASE_MD" "$PIPELINE_MD" "$DRIFT_DELTA")" "never names diffTouchesSomethingNew"

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
# The FRONTEND twin outlived both by a whole round, in the same file, four hundred lines under
# the paragraph that states the rule. The property is spelled over the outcome rather than over
# one remembered spelling: no `?0:1` survives anywhere in the file, whatever it wraps.
assert_eq "and the frontend twin, which shipped a round later than the other two" \
  "$(grep -c 'diffTouchesFrontend(fs.readFileSync(0,"utf8").split("\\0").filter(Boolean))?0:1' "$PIPELINE_MD" | tr -d ' ')" "0"
# Over the EXTRACTED BLOCKS, not the whole file. The prose around them describes the defective
# shape in order to explain why it is gone -- twice, now -- and a whole-file grep counts those
# sentences, so it could never reach zero and would be un-passable for a reason that has nothing
# to do with what the orchestrator runs. The executable text is the population that matters.
assert_eq "no two-outcome predicate exit survives in any block the orchestrator runs" \
  "$(cat "$PANEL_BLOCK" "$DELTA_BLOCK" | grep -c 'process.exit(.*?0:1)' | tr -d ' ')" "0"
TWO_OUTCOME_PROBE="$TEMP_PROJECT/two-outcome-probe.sh"
printf '%s\n' 'if node -e "...then(m=>process.exit(m.diffTouchesFrontend(x)?0:1))" < "$P"; then' > "$TWO_OUTCOME_PROBE"
assert_eq "CONTROL: that same grep DOES find the shape when it is present" \
  "$(grep -c 'process.exit(.*?0:1)' "$TWO_OUTCOME_PROBE" | tr -d ' ')" "1"
# ...and the blocks are non-empty, or the zero above is a statement about two empty files.
assert_eq "and those blocks carry executable probe lines for that zero to be about" \
  "$(cat "$PANEL_BLOCK" "$DELTA_BLOCK" | grep -c '^surface_probe ' | tr -d ' ')" "6"

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
FE_REPO="$TEMP_PROJECT/repo-frontend"; make_diff_repo "$FE_REPO" "src/ui/Button.tsx"
# The clean repo's path misses ALL THREE surfaces, and that is the definition of clean here
# rather than a way to keep the frontend probe quiet: every "seats nobody" assertion below is
# a negative control for all three, so a path that hits any one of them would make the control
# report a failure of the block instead of a property of the fixture.
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
assert_contains "a frontend path SEATS design_review" "$(run_panel "$FE_REPO" "$GOOD_ROOT")" "design_review"
assert_not_contains "and that same run does NOT seat dba" "$(run_panel "$FE_REPO" "$GOOD_ROOT")" "dba"
assert_not_contains "nor devops" "$(run_panel "$FE_REPO" "$GOOD_ROOT")" "devops"
assert_not_contains "and a data-layer path does NOT seat design_review" \
  "$(run_panel "$DL_REPO" "$GOOD_ROOT")" "design_review"
assert_eq "a diff that touches no surface seats nobody" \
  "$(run_panel "$CLEAN_REPO" "$GOOD_ROOT")" "ROLES=ba dev qa secops"
assert_eq "no PANEL-NOTE is emitted when the probe actually ran" \
  "$(run_panel "$CLEAN_REPO" "$GOOD_ROOT" | grep -c 'PANEL-NOTE' | tr -d ' ')" "0"

suite "THE BLOCKER: an UNEVALUABLE probe seats the specialist instead of silently dropping it"

BROKEN_OUT="$(run_panel "$CLEAN_REPO" "$BROKEN_ROOT")"
assert_contains "with no scripts/ under CLAUDE_PLUGIN_ROOT, dba is SEATED" "$BROKEN_OUT" "dba"
assert_contains "and devops is SEATED" "$BROKEN_OUT" "devops"
# THE #20 CELL. The same stale-cache root that dropped DBA and DevOps went on dropping DESIGN
# for a further round, because only two of the three probes were converted. The frontend module
# is a different file, so this is not a repeat of the assertion above: a fix that converted the
# probe but pointed it at data-layer-surface.mjs would pass every other case in this suite.
assert_contains "and design_review is SEATED, on the probe that stayed two-outcome a round longer" \
  "$BROKEN_OUT" "design_review"
assert_contains "with a note naming it as seated on indeterminacy" "$BROKEN_OUT" \
  "PANEL-NOTE: design_review SEATED on an INDETERMINATE frontend probe"
assert_contains "and the frontend module is named on stderr, not the data-layer one" \
  "$(run_panel_stderr "$CLEAN_REPO" "$BROKEN_ROOT")" "SURFACE-INDETERMINATE: diffTouchesFrontend"

# NON-ZERO CONTROL for that cell: the PRE-FIX frontend shape, verbatim as it shipped, observed
# doing the thing. Without it "design_review is seated" is equally satisfied by a block that was
# never broken, and the assertion would be a statement about nothing.
OLD_FE="$TEMP_PROJECT/old-frontend-shape.sh"
cat > "$OLD_FE" <<'EOF'
PANEL_ROLES="ba dev qa secops"
CHANGED_PATHS="$(mktemp)"
git -C "$WORKTREE_PATH" diff --name-only -z origin/main...HEAD > "$CHANGED_PATHS"
if node -e 'const fs=require("node:fs");import(process.env.CLAUDE_PLUGIN_ROOT + "/scripts/frontend-surface.mjs").then(m=>process.exit(m.diffTouchesFrontend(fs.readFileSync(0,"utf8").split("\0").filter(Boolean))?0:1))' < "$CHANGED_PATHS"; then
  PANEL_ROLES="$PANEL_ROLES design_review"
fi
rm -f "$CHANGED_PATHS"
EOF
run_old_fe() {  # $1 = WORKTREE_PATH, $2 = CLAUDE_PLUGIN_ROOT
  WORKTREE_PATH="$1" CLAUDE_PLUGIN_ROOT="$2" bash -c \
    ". \"$OLD_FE\"; printf 'ROLES=%s\n' \"\$PANEL_ROLES\"" 2>/dev/null
}
assert_contains "the pre-fix frontend shape is RIGHT on a frontend diff with a working module" \
  "$(run_old_fe "$FE_REPO" "$GOOD_ROOT")" "design_review"
assert_eq "and right on a clean diff, which is why it shipped" \
  "$(run_old_fe "$CLEAN_REPO" "$GOOD_ROOT")" "ROLES=ba dev qa secops"
assert_eq "THE #20 DEFECT: on a FRONTEND diff with a stale plugin root it drops design_review" \
  "$(run_old_fe "$FE_REPO" "$BROKEN_ROOT")" "ROLES=ba dev qa secops"
assert_eq "and its output is byte-identical to the honest no-match, which is why nobody saw it" \
  "$([[ "$(run_old_fe "$FE_REPO" "$BROKEN_ROOT")" == "$(run_old_fe "$CLEAN_REPO" "$GOOD_ROOT")" ]] && echo identical || echo different)" \
  "identical"
assert_eq "the SHIPPED block, same input, is materially different" \
  "$([[ "$(run_panel "$FE_REPO" "$BROKEN_ROOT" | grep '^ROLES=')" == "$(run_panel "$CLEAN_REPO" "$GOOD_ROOT" | grep '^ROLES=')" ]] && echo IDENTICAL || echo different)" \
  "different"
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
# Both modules, or this control is not the control it claims: with only the data-layer module
# stubbed, the frontend probe would be indeterminate and design_review would be seated, and
# "seats NOBODY" would be measuring a missing file rather than an honest false.
printf 'export function diffTouchesFrontend(){return false}\n' \
  > "$FALSE_ROOT/scripts/frontend-surface.mjs"
assert_eq "CONTROL: modules that load and honestly answer false seat NOBODY" \
  "$(run_panel "$CLEAN_REPO" "$FALSE_ROOT")" "ROLES=ba dev qa secops"
# And the half that control cannot see: with the data-layer module honest and the FRONTEND one
# absent, exactly one seat is taken and it is the right one.
HALF_ROOT="$TEMP_PROJECT/half-stubbed-plugin"
mkdir -p "$HALF_ROOT/scripts"
cp "$FALSE_ROOT/scripts/data-layer-surface.mjs" "$HALF_ROOT/scripts/data-layer-surface.mjs"
HALF_OUT="$(run_panel "$CLEAN_REPO" "$HALF_ROOT")"
assert_contains "a MISSING frontend module alone seats design_review" "$HALF_OUT" "design_review"
assert_not_contains "and does not seat dba, whose own module answered" "$HALF_OUT" "dba"
assert_not_contains "nor devops" "$HALF_OUT" "devops"

suite "the DELTA re-review round fails the same direction (the other two of the four sites)"

assert_contains "a data-layer fix commit adds dba to the delta set" "$(run_delta "$DL_REPO" "$GOOD_ROOT")" "dba"
assert_eq "CONTROL: a fix commit touching neither surface leaves the delta seed alone" \
  "$(run_delta "$CLEAN_REPO" "$GOOD_ROOT")" "DELTA=qa secops"
BROKEN_DELTA="$(run_delta "$CLEAN_REPO" "$BROKEN_ROOT")"
assert_contains "an unevaluable delta probe adds dba" "$BROKEN_DELTA" "dba"
assert_contains "and devops" "$BROKEN_DELTA" "devops"
assert_contains "and design_review, the third surface" "$BROKEN_DELTA" "design_review"
assert_contains "and emits the note" "$BROKEN_DELTA" "PANEL-NOTE: dba SEATED on an INDETERMINATE"
assert_contains "and one for the frontend probe too" "$BROKEN_DELTA" \
  "PANEL-NOTE: design_review SEATED on an INDETERMINATE frontend probe"

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
FE_MULTI="$TEMP_PROJECT/repo-frontend-multi"
make_diff_repo "$FE_MULTI" "src/ui/Button.tsx" "src/lib/util.ts"
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
  assert_contains "[$runner] one-path frontend diff seats design_review" \
    "$(run_panel_in "$runner" "$FE_REPO" "$GOOD_ROOT")" "design_review"
  assert_contains "[$runner] MULTI-path frontend diff seats design_review" \
    "$(run_panel_in "$runner" "$FE_MULTI" "$GOOD_ROOT")" "design_review"
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
  # The frontend column's own negative, for the same reason.
  assert_not_contains "[$runner] MULTI-path data-layer diff does NOT seat design_review" \
    "$(run_panel_in "$runner" "$DL_MULTI" "$GOOD_ROOT")" "design_review"
  assert_not_contains "[$runner] MULTI-path frontend diff does NOT seat dba" \
    "$(run_panel_in "$runner" "$FE_MULTI" "$GOOD_ROOT")" "dba"
done

suite "THE FIX: the delta round holds across the same matrix (the other two call sites)"

# The frontend fixtures are the SAME ones the panel matrix above uses, deliberately: the two
# copies of the probe are supposed to behave identically, and giving each its own fixture is
# how a difference between them hides.
for runner in "${RUNNERS[@]}"; do
  assert_contains "[$runner] a MULTI-path data-layer fix commit adds dba to the delta set" \
    "$(run_delta "$DL_MULTI" "$GOOD_ROOT" "$runner")" "dba"
  assert_contains "[$runner] a MULTI-path infra fix commit adds devops" \
    "$(run_delta "$INFRA_MULTI" "$GOOD_ROOT" "$runner")" "devops"
  assert_contains "[$runner] a one-path frontend fix commit adds design_review" \
    "$(run_delta "$FE_REPO" "$GOOD_ROOT" "$runner")" "design_review"
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
       surface_probe data-layer-surface.mjs diffTouchesDataLayer < \"\$CHANGED_PATHS\"; echo \$?; rm -f \"\$CHANGED_PATHS\"" 2>/dev/null)" \
  "20"
assert_eq "and the frontend probe returns the same 20 on its own real no-match" \
  "$(WORKTREE_PATH="$CLEAN_REPO" CLAUDE_PLUGIN_ROOT="$GOOD_ROOT" bash -c \
      "CHANGED_PATHS=\"\$(mktemp)\"; git -C \"\$WORKTREE_PATH\" diff --name-only -z origin/main...HEAD > \"\$CHANGED_PATHS\"
       $(probe_def "$PANEL_BLOCK")
       surface_probe frontend-surface.mjs diffTouchesFrontend < \"\$CHANGED_PATHS\"; echo \$?; rm -f \"\$CHANGED_PATHS\"" 2>/dev/null)" \
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
