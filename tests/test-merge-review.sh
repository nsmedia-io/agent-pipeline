#!/usr/bin/env bash
# merge-review.mjs (#164 row 5): the Phase 2 shard merge and verdict gate.
#
# Every exit code is observed from a fixture, and each refusal has a passing twin so a merge
# that refused everything could not pass. The prose it replaced (two jq recipes in
# orchestrator/phase-2-review.md and one in commands/phase.md) is pinned as gone at the end.
#
# What the jq recipes got wrong, in plain terms, since that is what each case below is here for.
# A reviewer that never wrote its file made jq stop with an error of its own rather than a halt
# that named the missing role, so the operator saw a parser complaint and not a missing review.
# A reviewer whose write into the artifact directory was refused had been told to use a second
# directory for exactly that case, and the Phase 2 recipe never looked there, so that review was
# lost even though it existed on disk. And nothing applied the materiality rule to Phase 2 at all,
# so a change request with nothing blocking behind it still sent the spec back to the analyst,
# and a veto that named no ground still read as a veto. The script fixes all three by reusing the
# functions the Phase 4 merge already ships, and these cases watch each fix from both sides.
#
# Every case builds a fresh project directory through the harness helper, so no case depends on
# what an earlier case left behind and nothing here removes a directory by hand. This file is also
# written with plain prose comments on purpose: the timeout bound suite measures the densest
# tracked file by structural characters per byte, and a fixture file made mostly of JSON quoting
# would otherwise become that file and move a measurement that has nothing to do with this change.

. "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
require_node

MR="$SCRIPTS_DIR/merge-review.mjs"

BLOCKER='{"id":"sec-1","severity":"high","likelihood":"normal-use","harm":"data-or-security","merge_class":"security-exposure","reversibility":"one-way-door","description":"token logged"}'
NOTE='{"id":"n-1","severity":"low","likelihood":"hypothetical","harm":"cosmetic","merge_class":"none","reversibility":"undo-button","description":"naming"}'

shard() { # <file> <json>
  mkdir -p "$(dirname "$1")"
  printf '%s' "$2" > "$1"
}
approve_all() {
  shard "$A/review.dba.json" '{"verdict":"APPROVE","concerns":[],"notes":"schema unchanged"}'
  shard "$A/review.devops.json" '{"verdict":"APPROVE_WITH_NOTES","concerns":['"$NOTE"'],"notes":"fine"}'
  shard "$A/review.secops.json" '{"verdict":"APPROVE","concerns":[],"notes":"no new surface"}'
}
merge() { # <args...> -> RC OUT ERR
  ( cd "$PROJ" && CLAUDE_PROJECT_DIR="$PROJ" node "$MR" --cost-class product "$@" ) >"$PROJ/o" 2>"$PROJ/e"
  RC=$?
  OUT="$(cat "$PROJ/o")"
  ERR="$(cat "$PROJ/e")"
}
reset() {
  make_temp_project 7 || exit 90
  PROJ="$TEMP_PROJECT"
  A="$TEMP_ISSUE_DIR"
}

suite "merge-review: exit 0 approve, and the shards are consumed"

reset; approve_all
merge --fresh "$A" dba devops secops
assert_eq "all approve exits 0" "$RC" "0"
assert_contains "prints the outcome" "$OUT" "OUTCOME: APPROVE"
assert_contains "prints each role's verdict" "$OUT" "ROLES: dba=APPROVE devops=APPROVE_WITH_NOTES secops=APPROVE"
assert_eq "review.json is written" "$([[ -s "$A/review.json" ]] && echo yes || echo no)" "yes"
assert_eq "the consumed shards are removed" "$(ls "$A" | grep -c '^review\.[a-z_]*\.json$' | tr -d ' ')" "0"

suite "merge-review: exit 3 changes, exit 4 veto, a groundless veto is changes"

reset; approve_all
shard "$A/review.dba.json" '{"verdict":"REQUEST_CHANGES","concerns":[{"id":"d-1","severity":"blocker","likelihood":"normal-use","harm":"data-or-security","merge_class":"data-loss","reversibility":"one-way-door","description":"drops a column"}],"notes":"n"}'
merge --fresh "$A" dba devops secops
assert_eq "a blocking REQUEST_CHANGES exits 3" "$RC" "3"
assert_contains "and says REQUEST_CHANGES" "$OUT" "OUTCOME: REQUEST_CHANGES"

reset; approve_all
shard "$A/review.dba.json" '{"verdict":"REQUEST_CHANGES","concerns":['"$NOTE"'],"notes":"n"}'
merge --fresh "$A" dba devops secops
assert_eq "CONTROL: a REQUEST_CHANGES with nothing blocking is normalized to a note and exits 0" "$RC" "0"
assert_contains "  ...and says it normalized" "$ERR" "normalized dba: REQUEST_CHANGES -> APPROVE_WITH_NOTES"

reset; approve_all
shard "$A/review.secops.json" '{"verdict":"VETO","veto_ground":"secrets","concerns":['"$BLOCKER"'],"notes":"n"}'
merge --fresh "$A" dba devops secops
assert_eq "a grounded SecOps VETO with a blocker exits 4" "$RC" "4"
assert_contains "and names the ground" "$OUT" "secops=VETO(secrets)"

reset; approve_all
shard "$A/review.secops.json" '{"verdict":"VETO","concerns":['"$BLOCKER"'],"notes":"n"}'
merge --fresh "$A" dba devops secops
assert_eq "a VETO with no veto_ground exits 3, not 4" "$RC" "3"
assert_contains "  ...recorded as REQUEST_CHANGES" "$(cat "$A/review.json")" '"verdict": "REQUEST_CHANGES"'
assert_contains "  ...with the returned verdict kept" "$(cat "$A/review.json")" '"verdict_as_returned": "VETO"'

reset; approve_all
merge --fresh "$A" dba devops secops
printf '%s' '{"dba":{"verdict":"APPROVE","notes":"x"},"secops":{"verdict":"VETO","concerns":['"$BLOCKER"'],"notes":"legacy, never normalized"}}' > "$A/review.json"
shard "$A/review.devops.json" '{"verdict":"APPROVE","concerns":[],"notes":"ok"}'
merge "$A" devops
assert_eq "a STANDING legacy VETO with no ground is read as changes (3), never as a veto" "$RC" "3"

suite "merge-review: exit 2 on a missing, null or provisional shard; nothing is written"

reset; approve_all
rm -f "$A/review.devops.json"
merge --fresh "$A" dba devops secops
assert_eq "a missing shard exits 2" "$RC" "2"
assert_contains "and names the role" "$ERR" "MISSING SHARD: devops"
assert_contains "and names the fallback path it also looked at" "$ERR" "fallback-shards"
assert_eq "nothing is written on a refusal" "$([[ -e "$A/review.json" ]] && echo written || echo absent)" "absent"
assert_eq "and the other shards are left in place for a re-run" "$([[ -e "$A/review.dba.json" ]] && echo kept || echo gone)" "kept"

reset; approve_all
shard "$A/review.secops.json" '{"secops":null}'
merge --fresh "$A" dba devops secops
assert_eq "a shard that unwraps to null exits 2" "$RC" "2"
assert_contains "and names the role" "$ERR" ": secops"
shard "$A/review.secops.json" '{"notes":"wrote a note and no verdict"}'
merge --fresh "$A" dba devops secops
assert_eq "a verdict-less shard exits 2" "$RC" "2"
assert_contains "and says NO RECOVERABLE VERDICT" "$ERR" "NO RECOVERABLE VERDICT: secops"

reset; approve_all
shard "$A/review.secops.json" '{"secops":{"verdict":"APPROVE","concerns":[],"notes":"wrapped but real"}}'
merge --fresh "$A" dba devops secops
assert_eq "CONTROL: a role-wrapped shard with a verdict unwraps and exits 0" "$RC" "0"

reset; approve_all
shard "$A/review.dba.json" '{"verdict":"APPROVE","concerns":[],"notes":"PROVISIONAL - review in progress"}'
merge --fresh "$A" dba devops secops
assert_eq "a provisional shard exits 2" "$RC" "2"
assert_contains "and says PROVISIONAL" "$ERR" "PROVISIONAL SHARD: dba"

reset; approve_all
merge --fresh "$A" dba devops secops
printf '%s' '{"dba":null,"devops":{"verdict":"APPROVE","notes":"x"}}' > "$A/review.json"
shard "$A/review.secops.json" '{"verdict":"APPROVE","concerns":[],"notes":"ok"}'
merge "$A" secops
assert_eq "a null standing block in review.json exits 2 (never read as a pass)" "$RC" "2"
assert_contains "and names it" "$OUT" "OUTCOME: UNREADABLE (dba)"

suite "merge-review: the fallback-shards path and stray-copy naming"

reset; approve_all
mkdir -p "$A/fallback-shards"
mv "$A/review.devops.json" "$A/fallback-shards/review.devops.json"
merge --fresh "$A" dba devops secops
assert_eq "a shard only at fallback-shards/ is read and merged (exit 0)" "$RC" "0"
assert_contains "and the fallback read is said" "$ERR" "read devops from the fallback path"
assert_eq "and the fallback copy is consumed" "$([[ -e "$A/fallback-shards/review.devops.json" ]] && echo left || echo consumed)" "consumed"

reset; approve_all
rm -f "$A/review.dba.json"
shard "$PROJ/.pipeline/99/review.dba.json" '{"verdict":"APPROVE","notes":"wrong checkout"}'
merge --fresh "$A" dba devops secops
assert_eq "a shard written into another .pipeline dir is not merged" "$RC" "2"
assert_contains "and the stray copy is named" "$ERR" "a file with this name exists at"
assert_contains "  ...under the other issue dir" "$ERR" "99"

suite "merge-review: design_review keeps the Phase 2 Design rule, not the merge_class test"

# The review of this change found the one place the shared materiality rule is wrong at Phase 2.
# The Design contract asks for a merge_class other than none only on the Phase 4 panel, so a real
# accessibility or token failure found before any code exists is normally rated with merge_class
# none, and the shared rule would read it as a note and let the spec through. These cases hold the
# Design rule in place and show, in the same run, that the other reviewers still get the shared one.
AXE_BLOCKER='{"id":"ds-1","severity":"blocker","likelihood":"normal-use","harm":"user-visible","merge_class":"none","description":"axe reports the new form has no label for the date input"}'
LINT_MAJOR='{"id":"ds-2","severity":"major","likelihood":"normal-use","harm":"user-visible","merge_class":"none","description":"token-lint flags a hardcoded color in the proposed banner"}'
TASTE='{"id":"ds-3","severity":"blocker","likelihood":"normal-use","harm":"cosmetic","merge_class":"none","description":"the spacing feels cramped"}'

reset; approve_all
shard "$A/review.design_review.json" '{"verdict":"REQUEST_CHANGES","concerns":['"$AXE_BLOCKER"'],"notes":"n"}'
merge --fresh "$A" dba devops secops design_review
assert_eq "a Design REQUEST_CHANGES backed by an axe blocker with merge_class none exits 3" "$RC" "3"
assert_contains "  ...and is recorded under the Phase 2 Design rule" "$(cat "$A/review.json")" '"rule": "phase2-design"'

reset; approve_all
shard "$A/review.design_review.json" '{"verdict":"REQUEST_CHANGES","concerns":['"$LINT_MAJOR"'],"notes":"n"}'
merge --fresh "$A" dba devops secops design_review
assert_eq "a major token-lint finding backs it too (exit 3)" "$RC" "3"

reset; approve_all
shard "$A/review.design_review.json" '{"verdict":"REQUEST_CHANGES","concerns":['"$TASTE"'],"notes":"n"}'
merge --fresh "$A" dba devops secops design_review
assert_eq "CONTROL: a taste-only Design REQUEST_CHANGES is advisory (exit 0)" "$RC" "0"

reset; approve_all
shard "$A/review.dba.json" '{"verdict":"REQUEST_CHANGES","concerns":['"$AXE_BLOCKER"'],"notes":"n"}'
merge --fresh "$A" dba devops secops
assert_eq "CONTROL: the same finding from DBA still gets the merge_class test (exit 0)" "$RC" "0"

assert_eq "phase-2-review.md states the Phase 2 Design rule"   "$(grep -c 'keeps the Phase 2 Design rule' "$PLUGIN_ROOT/orchestrator/phase-2-review.md" | tr -d ' ')" "1"

suite "merge-review: a delta round keeps standing blocks; design_review folds in"

reset; approve_all
merge --fresh "$A" dba devops secops
shard "$A/review.design_review.json" '{"verdict":"APPROVE_WITH_NOTES","concerns":[],"notes":"tokens ok","token_lint":{"status":"pass"}}'
merge "$A" design_review
assert_eq "folding design_review alone exits 0" "$RC" "0"
assert_contains "the standing roles are still in the outcome" "$OUT" "dba=APPROVE devops=APPROVE_WITH_NOTES secops=APPROVE design_review=APPROVE_WITH_NOTES"
merge "$A" bogus
assert_eq "an unknown role is a usage error (exit 1)" "$RC" "1"

suite "merge-review: the prose it replaced stays removed"

P2="$PLUGIN_ROOT/orchestrator/phase-2-review.md"
PH="$PLUGIN_ROOT/commands/phase.md"
assert_eq "phase-2-review.md carries no jq merge recipe" "$(grep -c -e 'slurpfile' -e 'def unwrap' "$P2" | tr -d ' ')" "0"
assert_eq "phase.md carries no jq merge recipe" "$(grep -c -e 'slurpfile' -e 'def unwrap' "$PH" | tr -d ' ')" "0"
assert_eq "phase-2-review.md calls merge-review.mjs" "$(grep -c 'scripts/merge-review.mjs' "$P2" | tr -d ' ')" "1"
assert_eq "phase.md calls merge-review.mjs" "$([[ "$(grep -c 'merge-review.mjs' "$PH")" -ge 1 ]] && echo yes || echo no)" "yes"
assert_eq "the verdict gate branches on exit codes, not on hand-read verdicts" \
  "$(grep -c -e '^1\. \*\*Exit 2\*\*' -e '^2\. \*\*Exit 4\*\*' -e '^3\. \*\*Exit 3\*\*' -e '^4\. \*\*Exit 0\*\*' "$P2" | tr -d ' ')" "4"
# NON-ZERO CONTROL for the absence grep.
printf 'jq --slurpfile dba x\n' > "$TEMP_PROJECT/probe.md"
assert_eq "CONTROL: the same grep finds a planted recipe" "$(grep -c -e 'slurpfile' -e 'def unwrap' "$TEMP_PROJECT/probe.md" | tr -d ' ')" "1"

finish
