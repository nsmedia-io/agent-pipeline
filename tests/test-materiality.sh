#!/usr/bin/env bash
# materiality.mjs -- the rule that decides what a review finding may BLOCK on, and the
# normalizer merge-peer-review.mjs applies to every shard it folds.
#
# The dangerous shapes here are both silent. Too loose: a genuine normal-use data-loss blocker
# is filed as a note and merges. Too tight: a reviewer writes REQUEST_CHANGES on a real but
# costless finding and the run loops for a day, which is what the review-convergence change was
# measured against (one tooling issue, 21 spec revisions, 8 panel rounds). So every transition is
# pinned in BOTH directions, per cost_class, and every note cell has a blocking control beside it
# that differs in exactly one rating.

. "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
require_node

MAT="$SCRIPTS_DIR/materiality.mjs"
MERGE="$SCRIPTS_DIR/merge-peer-review.mjs"

make_temp_project || exit 90

RATE="$TEMP_PROJECT/rate.mjs"
cat > "$RATE" <<'JS'
// rate <concern-json> [cost_class] -> "blocking|note" plus "unrated" when set
const m = await import(process.env.MOD);
const r = m.rateConcern(JSON.parse(process.argv[2]), process.argv[3]);
console.log((r.blocking ? "blocking" : "note") + (r.unrated ? " unrated" : ""));
JS
NORM="$TEMP_PROJECT/norm.mjs"
cat > "$NORM" <<'JS'
// norm <role> <block-json> [cost_class] -> "<effective>|<as_returned or ->|<blocking_count>"
const m = await import(process.env.MOD);
const out = m.normalizeBlock(JSON.parse(process.argv[3]), process.argv[2], { costClass: process.argv[4] });
console.log([out.verdict, out.verdict_as_returned ?? "-", out.materiality ? out.materiality.blocking_concerns : "?"].join("|"));
JS
FIELD="$TEMP_PROJECT/field.mjs"
cat > "$FIELD" <<'JS'
// field <role> <block-json> <cost_class> <materiality key> -> JSON of that key
const m = await import(process.env.MOD);
const out = m.normalizeBlock(JSON.parse(process.argv[3]), process.argv[2], { costClass: process.argv[4] });
console.log(JSON.stringify(out.materiality[process.argv[5]]));
JS
rate() { MOD="$MAT" node "$RATE" "$@"; }
norm() { MOD="$MAT" node "$NORM" "$@"; }
field() { MOD="$MAT" node "$FIELD" "$@"; }

# concern <severity> <likelihood> <harm> <merge_class>
concern() { printf '{"severity":"%s","likelihood":"%s","harm":"%s","merge_class":"%s","description":"d"}' "$1" "$2" "$3" "$4"; }

suite "materiality: product (the default) -- severity AND merge_class AND normal-use"

assert_eq "normal-use high data-loss blocks" "$(rate "$(concern high normal-use user-visible data-loss)" product)" "blocking"
assert_eq "CONTROL: the same concern with merge_class none is a note" "$(rate "$(concern high normal-use user-visible none)" product)" "note"
assert_eq "CONTROL: the same concern at severity major is a note" "$(rate "$(concern major normal-use user-visible data-loss)" product)" "note"
assert_eq "an edge-case data-loss is a note at product" "$(rate "$(concern blocker edge-case data-or-security data-loss)" product)" "note"
assert_eq "an adversarial money finding is a note at product" "$(rate "$(concern critical adversarial money money)" product)" "note"
assert_eq "an adversarial security-exposure BLOCKS (an exposure is reached outside the documented flow)" "$(rate "$(concern critical adversarial data-or-security security-exposure)" product)" "blocking"
assert_eq "hypothetical NEVER blocks, even a critical security-exposure" "$(rate "$(concern critical hypothetical data-or-security security-exposure)" product)" "note"
assert_eq "normal-use wrong-pass blocks at product" "$(rate "$(concern blocker normal-use internal wrong-pass)" product)" "blocking"
for sev in nit medium low info major; do
  assert_eq "severity $sev is a note even at normal-use data-loss" "$(rate "$(concern $sev normal-use data-or-security data-loss)" product)" "note"
done
assert_eq "no cost_class reads as product (edge-case data-loss is a note)" "$(rate "$(concern blocker edge-case data-or-security data-loss)")" "note"
assert_eq "an off-enum cost_class reads as product too" "$(rate "$(concern blocker edge-case data-or-security data-loss)" cheap)" "note"
C='{"severity":"BLOCKER","likelihood":"Normal-Use","harm":"Internal","merge_class":"Data-Loss"}'
assert_eq "ratings are case-insensitive" "$(rate "$C" product)" "blocking"

suite "materiality: product-money -- edge-case blocks too"

assert_eq "an edge-case money finding BLOCKS at product-money" "$(rate "$(concern high edge-case money money)" product-money)" "blocking"
assert_eq "CONTROL: the same edge-case money finding is a note at product" "$(rate "$(concern high edge-case money money)" product)" "note"
assert_eq "an edge-case merge_class none is still a note at product-money" "$(rate "$(concern high edge-case money none)" product-money)" "note"
assert_eq "an adversarial money finding is still a note at product-money" "$(rate "$(concern high adversarial money money)" product-money)" "note"
assert_eq "normal-use data-loss blocks at product-money" "$(rate "$(concern critical normal-use data-or-security data-loss)" product-money)" "blocking"

suite "materiality: tooling -- only wrong-pass or security-exposure can block"

assert_eq "a normal-use wrong-pass BLOCKS at tooling" "$(rate "$(concern high normal-use internal wrong-pass)" tooling)" "blocking"
assert_eq "a normal-use security-exposure BLOCKS at tooling" "$(rate "$(concern high normal-use data-or-security security-exposure)" tooling)" "blocking"
assert_eq "a normal-use data-loss is a NOTE at tooling" "$(rate "$(concern blocker normal-use data-or-security data-loss)" tooling)" "note"
assert_eq "CONTROL: the same data-loss concern blocks at product" "$(rate "$(concern blocker normal-use data-or-security data-loss)" product)" "blocking"
assert_eq "a normal-use money finding is a NOTE at tooling" "$(rate "$(concern blocker normal-use money money)" tooling)" "note"
assert_eq "an edge-case wrong-pass is a note at tooling" "$(rate "$(concern high edge-case internal wrong-pass)" tooling)" "note"
assert_eq "a hypothetical wrong-pass is a note at tooling" "$(rate "$(concern critical hypothetical internal wrong-pass)" tooling)" "note"

suite "materiality: unrated is a NOTE with a visible flag, never a blocker"

C='{"severity":"blocker","description":"no rating at all"}'
assert_eq "a legacy blocker with no ratings is an unrated note" "$(rate "$C" product)" "note unrated"
C='{"severity":"high","likelihood":"normal-use","harm":"user-visible","description":"no merge_class (a 0.42.0 shard)"}'
assert_eq "a 0.42.0-shaped concern (no merge_class) is an unrated note" "$(rate "$C" product)" "note unrated"
C='{"severity":"high","likelihood":"sometimes","harm":"internal","merge_class":"data-loss"}'
assert_eq "an off-enum likelihood is unrated" "$(rate "$C" product)" "note unrated"
C='{"likelihood":"normal-use","harm":"internal","merge_class":"data-loss"}'
assert_eq "a missing severity is unrated" "$(rate "$C" product)" "note unrated"
assert_eq "a non-object concern is ignored rather than crashing the merge" "$(rate '"just a string"')" "note"
assert_eq "null is ignored too" "$(rate 'null')" "note"
B='{"verdict":"REQUEST_CHANGES","concerns":[{"severity":"blocker","description":"legacy, unrated"}]}'
assert_eq "a legacy REQUEST_CHANGES carrying only an unrated blocker reads as APPROVE_WITH_NOTES" "$(norm dba "$B" product)" "APPROVE_WITH_NOTES|REQUEST_CHANGES|0"
assert_eq "and the unrated id is listed" "$(field dba "$B" product unrated_ids)" '["dba-1"]'
assert_contains "and a note says UNRATED" "$(field dba "$B" product notes)" "UNRATED: dba-1"

suite "materiality: normalizeBlock transitions, and blocks_merge / open_blocker_ids"

BLK="$(concern blocker normal-use user-visible data-loss)"
B="{\"verdict\":\"REQUEST_CHANGES\",\"concerns\":[$BLK]}"
assert_eq "CONTROL: REQUEST_CHANGES on a normal-use data-loss blocker STANDS" "$(norm qa "$B" product)" "REQUEST_CHANGES|-|1"
assert_eq "blocks_merge is true" "$(field qa "$B" product blocks_merge)" "true"
assert_eq "open_blocker_ids names it by role and index" "$(field qa "$B" product open_blocker_ids)" '["qa-1"]'
B="{\"verdict\":\"REQUEST_CHANGES\",\"concerns\":[$(concern blocker normal-use user-visible none)]}"
assert_eq "REQUEST_CHANGES on a merge_class none concern reads as APPROVE_WITH_NOTES" "$(norm qa "$B" product)" "APPROVE_WITH_NOTES|REQUEST_CHANGES|0"
assert_eq "and blocks_merge is false" "$(field qa "$B" product blocks_merge)" "false"
B='{"verdict":"REQUEST_CHANGES","concerns":[]}'
assert_eq "REQUEST_CHANGES with no concerns reads as APPROVE_WITH_NOTES" "$(norm qa "$B")" "APPROVE_WITH_NOTES|REQUEST_CHANGES|0"
B="{\"verdict\":\"APPROVE\",\"concerns\":[$BLK]}"
assert_eq "APPROVE carrying a blocking concern reads as REQUEST_CHANGES (fail closed)" "$(norm dev "$B" product)" "REQUEST_CHANGES|APPROVE|1"
B='{"verdict":"APPROVE_WITH_NITS","concerns":[{"severity":"nit","likelihood":"normal-use","harm":"cosmetic","merge_class":"none"}]}'
assert_eq "the legacy alias is normalized and a nit stays a note" "$(norm dev "$B")" "APPROVE_WITH_NOTES|APPROVE_WITH_NITS|0"
B='{"verdict":"APPROVE","concerns":[]}'
assert_eq "a clean APPROVE is untouched" "$(norm dev "$B")" "APPROVE|-|0"
B="{\"verdict\":\"REQUEST_CHANGES\",\"concerns\":[{\"id\":\"QA-X\",\"severity\":\"high\",\"likelihood\":\"normal-use\",\"harm\":\"internal\",\"merge_class\":\"wrong-pass\"}]}"
assert_eq "a concern's own id is used when it carries one" "$(field qa "$B" tooling open_blocker_ids)" '["QA-X"]'

suite "materiality: REQUEST_REFACTOR obeys the same test"

B='{"verdict":"REQUEST_REFACTOR","concerns":[]}'
assert_eq "REQUEST_REFACTOR with no blocking concern reads as APPROVE_WITH_NOTES" "$(norm qa "$B")" "APPROVE_WITH_NOTES|REQUEST_REFACTOR|0"
B="{\"verdict\":\"REQUEST_REFACTOR\",\"concerns\":[$(concern high normal-use internal wrong-pass)]}"
assert_eq "CONTROL: REQUEST_REFACTOR carrying a blocking wrong-pass STANDS" "$(norm qa "$B" tooling)" "REQUEST_REFACTOR|-|1"
B="{\"verdict\":\"REQUEST_REFACTOR\",\"concerns\":[$(concern high normal-use internal data-loss)]}"
assert_eq "and the same refactor request on a data-loss concern at tooling is a note" "$(norm qa "$B" tooling)" "APPROVE_WITH_NOTES|REQUEST_REFACTOR|0"

suite "materiality: the veto stands only on a ground AND a blocking concern"

SEC="$(concern critical normal-use data-or-security security-exposure)"
B="{\"verdict\":\"VETO\",\"veto_ground\":\"auth\",\"concerns\":[$SEC]}"
assert_eq "a SecOps VETO on a named ground carrying a blocking concern STANDS" "$(norm secops "$B")" "VETO|-|1"
assert_eq "and blocks_merge is true" "$(field secops "$B" product blocks_merge)" "true"
B='{"verdict":"VETO","veto_ground":"auth","concerns":[]}'
assert_eq "a SecOps VETO on a named ground with NO concern downgrades, and nothing blocks" "$(norm secops "$B")" "APPROVE_WITH_NOTES|VETO|0"
assert_contains "and the note says it does not send the spec back to BA" "$(field secops "$B" product notes)" "does not send the spec back to BA"
B="{\"verdict\":\"VETO\",\"veto_ground\":\"auth\",\"concerns\":[$(concern critical normal-use data-or-security none)]}"
assert_eq "a VETO whose only concern has merge_class none reads as APPROVE_WITH_NOTES" "$(norm secops "$B")" "APPROVE_WITH_NOTES|VETO|0"
B="{\"verdict\":\"VETO\",\"concerns\":[$SEC]}"
assert_eq "a SecOps VETO with NO ground but a blocker reads as REQUEST_CHANGES (does not return to BA)" "$(norm secops "$B")" "REQUEST_CHANGES|VETO|1"
B="{\"verdict\":\"VETO\",\"veto_ground\":\"code-style\",\"concerns\":[$SEC]}"
assert_eq "a SecOps VETO on an off-enum ground reads as REQUEST_CHANGES" "$(norm secops "$B")" "REQUEST_CHANGES|VETO|1"
B="{\"verdict\":\"VETO\",\"veto_ground\":\"auth\",\"concerns\":[$SEC]}"
assert_eq "VETO from a non-SecOps role reads as REQUEST_CHANGES even on a valid ground" "$(norm dba "$B")" "REQUEST_CHANGES|VETO|1"
B="{\"verdict\":\"VETO\",\"veto_ground\":\"auth\",\"concerns\":[$(concern critical normal-use data-or-security data-loss)]}"
assert_eq "a VETO on a data-loss concern at tooling (not a tooling merge class) is a note" "$(norm secops "$B" tooling)" "APPROVE_WITH_NOTES|VETO|0"

suite "materiality: the cap DEMOTES, ranked by harm"

B="{\"verdict\":\"REQUEST_CHANGES\",\"concerns\":[$(concern high normal-use cosmetic data-loss),$(concern high normal-use internal data-loss),$(concern high normal-use data-or-security data-loss),$(concern high normal-use money money)]}"
assert_eq "four blockers keep two" "$(norm dba "$B" product)" "REQUEST_CHANGES|-|2"
assert_eq "the two kept rank by merge_class first (money before data-loss), then harm" "$(field dba "$B" product open_blocker_ids)" '["dba-4","dba-3"]'
assert_eq "the rest are demoted, worst first" "$(field dba "$B" product demoted_ids)" '["dba-2","dba-1"]'
assert_eq "over_cap is recorded" "$(field dba "$B" product over_cap)" "true"
assert_contains "and a note names what was demoted" "$(field dba "$B" product notes)" "demoted dba-2, dba-1 to notes"
B="{\"verdict\":\"REQUEST_CHANGES\",\"concerns\":[$(concern high normal-use data-or-security security-exposure),$(concern high normal-use data-or-security security-exposure),$(concern critical normal-use cosmetic data-loss)]}"
assert_eq "REVIEW REPRO: a critical data-loss concern with a mis-rated harm is NOT demoted behind two security-exposure ones" \
  "$(field dba "$B" product open_blocker_ids)" '["dba-3","dba-1"]'
assert_eq "CONTROL: ranked by harm alone it would have been the one demoted" "$(field dba "$B" product demoted_ids)" '["dba-2"]'
B="{\"verdict\":\"REQUEST_CHANGES\",\"concerns\":[$(concern high normal-use user-visible data-loss),$(concern blocker normal-use user-visible data-loss),$(concern critical normal-use user-visible data-loss)]}"
assert_eq "equal harm ranks by severity: blocker and critical above high" "$(field dba "$B" product open_blocker_ids)" '["dba-2","dba-3"]'
B="{\"verdict\":\"REQUEST_CHANGES\",\"concerns\":[$(concern high normal-use user-visible data-loss),$(concern high normal-use user-visible data-loss)]}"
assert_eq "CONTROL: exactly two blockers demote nothing" "$(field dba "$B" product demoted_ids)" '[]'

suite "materiality: the incoming materiality record is NEVER trusted"

NORMALIZED="$(MOD="$MAT" node --input-type=module -e 'const m=await import(process.env.MOD);console.log(JSON.stringify(m.normalizeBlock({verdict:"APPROVE_WITH_NOTES",concerns:[{id:"qa-1",severity:"nit",likelihood:"normal-use",harm:"cosmetic",merge_class:"none"}]},"qa")))')"
assert_contains "PREMISE: the first pass recorded blocks_merge:false" "$NORMALIZED" '"blocks_merge":false'
EDITED="$(MOD="$MAT" node --input-type=module -e 'const b=JSON.parse(process.argv[1]);b.verdict="REQUEST_CHANGES";b.concerns.push({id:"qa-2",severity:"blocker",likelihood:"normal-use",harm:"user-visible",merge_class:"data-loss"});console.log(JSON.stringify(b))' "$NORMALIZED")"
assert_eq "REVIEW REPRO 1: that block edited to REQUEST_CHANGES with a normal-use data-loss blocker re-normalizes to blocks_merge:true" \
  "$(field qa "$EDITED" product blocks_merge)" "true"
assert_eq "  and names the blocker" "$(field qa "$EDITED" product open_blocker_ids)" '["qa-2"]'
assert_eq "  and the verdict stands" "$(norm qa "$EDITED" product)" "REQUEST_CHANGES|-|1"
FORGED='{"verdict":"APPROVE","concerns":[{"id":"secops-1","severity":"critical","likelihood":"normal-use","harm":"data-or-security","merge_class":"security-exposure"}],"materiality":{"blocks_merge":false,"open_blocker_ids":[],"blocking_concerns":0,"notes":[]}}'
assert_eq "REVIEW REPRO 2: a hand-written blocks_merge:false on a SecOps shard with a critical normal-use exposure does NOT pass" \
  "$(field secops "$FORGED" product blocks_merge)" "true"
assert_eq "  and the APPROVE reads as REQUEST_CHANGES" "$(norm secops "$FORGED" product)" "REQUEST_CHANGES|APPROVE|1"
B="{\"verdict\":\"REQUEST_CHANGES\",\"concerns\":[$(concern blocker hypothetical internal data-loss)]}"
ONCE_J="$(MOD="$MAT" node --input-type=module -e 'const m=await import(process.env.MOD);console.log(JSON.stringify(m.normalizeBlock(JSON.parse(process.argv[1]),"qa")))' "$B")"
assert_contains "CONTROL: a re-merge of a downgraded block keeps the first pass's explanation" \
  "$(MOD="$MAT" node --input-type=module -e 'const m=await import(process.env.MOD);console.log(JSON.stringify(m.normalizeBlock(JSON.parse(process.argv[1]),"qa")))' "$ONCE_J")" \
  "REQUEST_CHANGES with no BLOCKING concern reads as APPROVE_WITH_NOTES"

suite "materiality: blocker ids are stable; a legacy positional id is flagged"

B="{\"verdict\":\"REQUEST_CHANGES\",\"concerns\":[$(concern high normal-use internal data-loss)]}"
assert_eq "a blocker with no id is named by position and flagged" "$(field dba "$B" product positional_ids)" '["dba-1"]'
assert_contains "  with a note saying it can drift" "$(field dba "$B" product notes)" "POSITIONAL ID: dba-1"
B='{"verdict":"REQUEST_CHANGES","concerns":[{"id":"dba-orders-index","severity":"high","likelihood":"normal-use","harm":"internal","merge_class":"data-loss"}]}'
assert_eq "CONTROL: a blocker carrying its id is not flagged" "$(field dba "$B" product positional_ids)" '[]'
REORDER='{"verdict":"REQUEST_CHANGES","concerns":[{"id":"n-1","severity":"nit","likelihood":"normal-use","harm":"cosmetic","merge_class":"none"},{"id":"dba-orders-index","severity":"high","likelihood":"normal-use","harm":"internal","merge_class":"data-loss"}]}'
assert_eq "and a delta shard that reorders its concerns keeps the same open blocker id" "$(field dba "$REORDER" product open_blocker_ids)" '["dba-orders-index"]'

suite "materiality: test cost is a note at tooling, never a block"

B='{"verdict":"APPROVE","notes":"ok","test_cost":{"assertions_before":100,"assertions_after":250,"prepush_seconds_before":10,"prepush_seconds_after":12}}'
assert_contains "150 more assertions at tooling earns a consolidation note" "$(field qa "$B" tooling notes)" "TEST COST"
assert_eq "and the verdict is untouched" "$(norm qa "$B" tooling)" "APPROVE|-|0"
B='{"verdict":"APPROVE","notes":"ok","test_cost":{"assertions_before":100,"assertions_after":150,"prepush_seconds_before":10,"prepush_seconds_after":45}}'
assert_contains "35 more seconds at tooling earns it too" "$(field qa "$B" tooling notes)" "s of pre-push time"
B='{"verdict":"APPROVE","notes":"ok","test_cost":{"assertions_before":100,"assertions_after":200,"prepush_seconds_before":10,"prepush_seconds_after":40}}'
assert_not_contains "CONTROL: exactly 100 assertions and 30 seconds is not over" "$(field qa "$B" tooling notes)" "TEST COST"
B='{"verdict":"APPROVE","notes":"ok","test_cost":{"assertions_before":100,"assertions_after":900}}'
assert_not_contains "CONTROL: the same growth at product earns no note" "$(field qa "$B" product notes)" "TEST COST"

suite "materiality: finalVerdict reads blocks_merge, and openBlockerRoles seeds the delta"

FV="$TEMP_PROJECT/fv.mjs"
cat > "$FV" <<'JS'
const m = await import(process.env.MOD);
const pr = JSON.parse(process.argv[2]);
console.log(m.finalVerdict(pr, Object.keys(pr)) + "|" + m.openBlockerRoles(pr).join(","));
JS
fv() { MOD="$MAT" node "$FV" "$1"; }
assert_eq "a REQUEST_CHANGES whose blocks_merge is false does not refuse the merge" \
  "$(fv '{"qa":{"verdict":"REQUEST_CHANGES","materiality":{"blocks_merge":false,"open_blocker_ids":[]}},"secops":{"verdict":"APPROVE"}}')" "null|"
assert_eq "a blocking REQUEST_CHANGES is REQUEST_CHANGES, and seeds its role" \
  "$(fv '{"qa":{"verdict":"REQUEST_CHANGES","materiality":{"blocks_merge":true,"open_blocker_ids":["qa-1"]}},"secops":{"verdict":"APPROVE"}}')" "REQUEST_CHANGES|qa"
assert_eq "a standing VETO wins" \
  "$(fv '{"secops":{"verdict":"VETO","materiality":{"blocks_merge":true,"open_blocker_ids":["secops-1"]}},"qa":{"verdict":"REQUEST_REFACTOR","materiality":{"blocks_merge":true,"open_blocker_ids":["qa-2"]}}}')" "SECOPS_VETO|secops,qa"
assert_eq "REVIEW REPRO: a LEGACY block with blocks_merge:true and no open_blocker_ids is reseated, and still refuses" \
  "$(fv '{"qa":{"verdict":"REQUEST_CHANGES","materiality":{"blocks_merge":true,"blocking_concerns":1}},"secops":{"verdict":"APPROVE"}}')" "REQUEST_CHANGES|qa"
assert_eq "a block with no materiality record whose verdict blocks is reseated too" \
  "$(fv '{"dba":{"verdict":"REQUEST_CHANGES"},"secops":{"verdict":"APPROVE"}}')" "REQUEST_CHANGES|dba"
OB="$TEMP_PROJECT/ob.mjs"
cat > "$OB" <<'JS'
const m = await import(process.env.MOD);
console.log(JSON.stringify(m.openBlockers(JSON.parse(process.argv[2]))));
JS
assert_eq "openBlockers lists demoted ids beside open ones, and an unnamed legacy seat as id null" \
  "$(MOD="$MAT" node "$OB" '{"qa":{"verdict":"REQUEST_CHANGES","materiality":{"blocks_merge":true,"open_blocker_ids":["qa-1","qa-2"],"demoted_ids":["qa-3"]}},"dba":{"verdict":"REQUEST_CHANGES","materiality":{"blocks_merge":true}}}')" \
  '[{"role":"qa","id":"qa-1","demoted":false},{"role":"qa","id":"qa-2","demoted":false},{"role":"qa","id":"qa-3","demoted":true},{"role":"dba","id":null,"demoted":false}]'
assert_eq "notes only is APPROVE_WITH_NOTES" \
  "$(fv '{"qa":{"verdict":"APPROVE_WITH_NOTES","materiality":{"blocks_merge":false,"open_blocker_ids":[]}},"secops":{"verdict":"APPROVE"}}')" "APPROVE_WITH_NOTES|"

suite "materiality: idempotent, and the merge CLI applies it under the run's cost_class"

B="{\"verdict\":\"REQUEST_CHANGES\",\"concerns\":[$(concern blocker hypothetical internal data-loss)]}"
ONCE="$(MOD="$MAT" node --input-type=module -e 'const m=await import(process.env.MOD);console.log(JSON.stringify(m.normalizeBlock(JSON.parse(process.argv[1]),"qa")))' "$B")"
TWICE="$(MOD="$MAT" node --input-type=module -e 'const m=await import(process.env.MOD);console.log(JSON.stringify(m.normalizeBlock(JSON.parse(process.argv[1]),"qa")))' "$ONCE")"
assert_eq "normalizing an already-normalized block changes nothing" "$TWICE" "$ONCE"

W="$TEMP_PROJECT/work"; mkdir -p "$W"
write_shards() {
  printf '%s' "{\"verdict\":\"REQUEST_CHANGES\",\"concerns\":[$(concern high normal-use user-visible data-loss)]}" > "$W/peer-review.qa.json"
  # notes present: 0.42.0's merge (#155) refuses a bare verdict with no concerns and no evidence text.
  printf '%s' '{"verdict":"APPROVE","concerns":[],"notes":"clean"}' > "$W/peer-review.secops.json"
}
write_shards
printf '%s' '{"issue_number":1,"cost_class":"tooling"}' > "$W/status.json"
( cd "$TEMP_PROJECT" && node "$MERGE" --status "$W/status.json" "$W/peer-review.json" "qa=$W/peer-review.qa.json" "secops=$W/peer-review.secops.json" ) >"$W/out.txt" 2>"$W/err.txt"
assert_eq "the merge CLI exits 0" "$?" "0"
assert_eq "at cost_class tooling (read from --status) a data-loss blocker is recorded as a note" \
  "$(node --input-type=module -e 'import {readFileSync} from "node:fs";const j=JSON.parse(readFileSync(process.argv[1]));console.log(j.qa.verdict, j.qa.verdict_as_returned, j.qa.materiality.cost_class)' "$W/peer-review.json")" \
  "APPROVE_WITH_NOTES REQUEST_CHANGES tooling"
assert_contains "and the merge SAYS it normalized, on stderr" "$(cat "$W/err.txt")" "normalized qa"
rm -f "$W/peer-review.json"; write_shards
printf '%s' '{"issue_number":1,"cost_class":"product"}' > "$W/status.json"
( cd "$TEMP_PROJECT" && node "$MERGE" --status "$W/status.json" "$W/peer-review.json" "qa=$W/peer-review.qa.json" "secops=$W/peer-review.secops.json" ) >/dev/null 2>&1
assert_eq "CONTROL: the same shard under a product status STANDS as REQUEST_CHANGES" \
  "$(node --input-type=module -e 'import {readFileSync} from "node:fs";const j=JSON.parse(readFileSync(process.argv[1]));console.log(j.qa.verdict, j.qa.materiality.blocks_merge)' "$W/peer-review.json")" \
  "REQUEST_CHANGES true"
assert_eq "countVerdicts reads the normalized verdict, so the rubric does too" \
  "$(MOD="$MERGE" node --input-type=module -e 'import {readFileSync} from "node:fs";const m=await import(process.env.MOD);const j=JSON.parse(readFileSync(process.argv[1]));const c=m.countVerdicts(j,["qa","secops"]);console.log(c.request_changes, c.approve_with_notes, c.approve)' "$W/peer-review.json")" \
  "1 0 1"
rm -f "$W/peer-review.json"; write_shards
( cd "$TEMP_PROJECT" && node "$MERGE" --status "$W/no-such-status.json" "$W/peer-review.json" "qa=$W/peer-review.qa.json" ) >/dev/null 2>"$W/err.txt"
assert_eq "an unreadable --status HALTS (exit 2) rather than guessing a cost class" "$?" "2"
assert_eq "and nothing was written" "$([[ -f "$W/peer-review.json" ]] && echo written || echo none)" "none"
( cd "$TEMP_PROJECT" && node "$MERGE" --cost-class cheap "$W/peer-review.json" "qa=$W/peer-review.qa.json" ) >/dev/null 2>&1
assert_eq "an off-enum --cost-class HALTS too" "$?" "2"

suite "materiality: the shared vocabularies agree with the schemas"

assert_eq "VETO_GROUNDS equals schemas/definitions.schema.json vetoGround" \
  "$(MOD="$MAT" node --input-type=module -e 'import {readFileSync} from "node:fs";const m=await import(process.env.MOD);const s=JSON.parse(readFileSync(process.argv[1]));console.log(JSON.stringify(m.VETO_GROUNDS)===JSON.stringify(s.definitions.vetoGround.enum)?"same":"DIFFERENT")' "$PLUGIN_ROOT/schemas/definitions.schema.json")" "same"
assert_eq "MERGE_CLASSES equals schemas/definitions.schema.json mergeClass" \
  "$(MOD="$MAT" node --input-type=module -e 'import {readFileSync} from "node:fs";const m=await import(process.env.MOD);const s=JSON.parse(readFileSync(process.argv[1]));console.log(JSON.stringify(m.MERGE_CLASSES)===JSON.stringify(s.definitions.mergeClass.enum)?"same":"DIFFERENT")' "$PLUGIN_ROOT/schemas/definitions.schema.json")" "same"
assert_eq "HARMS equals the peer-review harm enum" \
  "$(MOD="$MAT" node --input-type=module -e 'import {readFileSync} from "node:fs";const m=await import(process.env.MOD);const s=JSON.parse(readFileSync(process.argv[1]));console.log(JSON.stringify(m.HARMS)===JSON.stringify(s.definitions.panelVerdict.properties.concerns.items.properties.harm.enum)?"same":"DIFFERENT")' "$PLUGIN_ROOT/schemas/peer-review.schema.json")" "same"
for f in review peer-review; do
  assert_eq "$f.schema.json carries no inline copy of the veto_ground enum" \
    "$(grep -c '"veto_ground": {"type"' "$PLUGIN_ROOT/schemas/$f.schema.json" | tr -d ' ')" "0"
done

finish
