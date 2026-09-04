#!/usr/bin/env bash
# materiality.mjs -- the rule that decides what a review finding may BLOCK on, and the
# normalizer merge-peer-review.mjs applies to every shard it folds.
#
# The dangerous shapes here are both silent. Too loose: a reviewer writes REQUEST_CHANGES on a
# hypothetical and the run loops for a day. Too tight: a genuine normal-use blocker is filed as a
# note and merges. So every transition is pinned in BOTH directions, the fail-closed cells
# (unrated, approve-with-blocker, veto-without-ground) each have a positive control beside them,
# and the CLI path is exercised end to end so the rubric is shown to read the NORMALIZED verdict.

. "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
require_node

MAT="$SCRIPTS_DIR/materiality.mjs"
MERGE="$SCRIPTS_DIR/merge-peer-review.mjs"

make_temp_project || exit 90

RATE="$TEMP_PROJECT/rate.mjs"
cat > "$RATE" <<'JS'
// rate <concern-json> -> "blocking|note" plus "unrated" when set
const m = await import(process.env.MOD);
const r = m.rateConcern(JSON.parse(process.argv[2]));
console.log((r.blocking ? "blocking" : "note") + (r.unrated ? " unrated" : ""));
JS
NORM="$TEMP_PROJECT/norm.mjs"
cat > "$NORM" <<'JS'
// norm <role> <block-json> -> "<effective>|<as_returned or ->|<blocking_count>"
const m = await import(process.env.MOD);
const out = m.normalizeBlock(JSON.parse(process.argv[3]), process.argv[2]);
console.log([out.verdict, out.verdict_as_returned ?? "-", out.materiality ? out.materiality.blocking_concerns : "?"].join("|"));
JS
rate() { MOD="$MAT" node "$RATE" "$1"; }
norm() { MOD="$MAT" node "$NORM" "$1" "$2"; }

suite "materiality: rateConcern, cell by cell"

C='{"severity":"blocker","likelihood":"normal-use","reversibility":"undo-button","harm":"internal"}'
assert_eq "normal-use blocker blocks, whatever its reversibility or harm" "$(rate "$C")" "blocking"
C='{"severity":"high","likelihood":"edge-case","reversibility":"undo-button","harm":"cosmetic"}'
assert_eq "edge-case high blocks" "$(rate "$C")" "blocking"
C='{"severity":"critical","likelihood":"hypothetical","reversibility":"one-way-door","harm":"data-or-security"}'
assert_eq "hypothetical NEVER blocks, even at critical, irreversible, data harm" "$(rate "$C")" "note"
C='{"severity":"blocker","likelihood":"adversarial","reversibility":"undo-button","harm":"internal"}'
assert_eq "adversarial-only, reversible, internal harm is a note" "$(rate "$C")" "note"
C='{"severity":"blocker","likelihood":"adversarial","reversibility":"one-way-door","harm":"internal"}'
assert_eq "adversarial but irreversible blocks" "$(rate "$C")" "blocking"
C='{"severity":"blocker","likelihood":"adversarial","reversibility":"undo-button","harm":"data-or-security"}'
assert_eq "adversarial with data-or-security harm blocks" "$(rate "$C")" "blocking"
C='{"severity":"major","likelihood":"normal-use","reversibility":"one-way-door","harm":"data-or-security"}'
assert_eq "major is a note whatever its rating: only blocker/critical/high can block" "$(rate "$C")" "note"
for sev in nit medium low info; do
  C="{\"severity\":\"$sev\",\"likelihood\":\"normal-use\",\"reversibility\":\"one-way-door\",\"harm\":\"data-or-security\"}"
  assert_eq "severity $sev is a note" "$(rate "$C")" "note"
done
C='{"severity":"BLOCKER","likelihood":"Normal-Use","reversibility":"Undo-Button","harm":"Internal"}'
assert_eq "ratings are case-insensitive" "$(rate "$C")" "blocking"

suite "materiality: the fail-closed cells, each with its control"

C='{"severity":"blocker","description":"no rating at all"}'
assert_eq "an UNRATED blocking-severity concern is treated as blocking (fail closed)" "$(rate "$C")" "blocking unrated"
C='{"severity":"high","likelihood":"normal-use","reversibility":"undo-button"}'
assert_eq "a PARTIAL rating (harm missing) is unrated too" "$(rate "$C")" "blocking unrated"
C='{"severity":"high","likelihood":"sometimes","reversibility":"undo-button","harm":"internal"}'
assert_eq "an off-enum likelihood is unrated, never silently read as a note" "$(rate "$C")" "blocking unrated"
C='{"severity":"nit"}'
assert_eq "CONTROL: an unrated NIT is still a note (only blocking severities fail closed)" "$(rate "$C")" "note"
assert_eq "a non-object concern is ignored rather than crashing the merge" "$(rate '"just a string"')" "note"
assert_eq "null is ignored too" "$(rate 'null')" "note"

suite "materiality: normalizeBlock transitions"

B='{"verdict":"REQUEST_CHANGES","concerns":[{"severity":"blocker","likelihood":"hypothetical","reversibility":"undo-button","harm":"internal"}]}'
assert_eq "REQUEST_CHANGES on a hypothetical reads as APPROVE_WITH_NOTES, original preserved" \
  "$(norm qa "$B")" "APPROVE_WITH_NOTES|REQUEST_CHANGES|0"
B='{"verdict":"REQUEST_CHANGES","concerns":[]}'
assert_eq "REQUEST_CHANGES with no concerns reads as APPROVE_WITH_NOTES" "$(norm qa "$B")" "APPROVE_WITH_NOTES|REQUEST_CHANGES|0"
B='{"verdict":"REQUEST_CHANGES","concerns":[{"severity":"blocker","likelihood":"normal-use","reversibility":"undo-button","harm":"user-visible"}]}'
assert_eq "CONTROL: REQUEST_CHANGES on a normal-use blocker STANDS" "$(norm qa "$B")" "REQUEST_CHANGES|-|1"
B='{"verdict":"APPROVE","concerns":[{"severity":"blocker","likelihood":"normal-use","reversibility":"undo-button","harm":"user-visible"}]}'
assert_eq "APPROVE carrying a blocking concern reads as REQUEST_CHANGES (fail closed)" "$(norm dev "$B")" "REQUEST_CHANGES|APPROVE|1"
B='{"verdict":"APPROVE_WITH_NITS","concerns":[{"severity":"nit"}]}'
assert_eq "the legacy alias is normalized and a nit stays a note" "$(norm dev "$B")" "APPROVE_WITH_NOTES|APPROVE_WITH_NITS|0"
B='{"verdict":"APPROVE","concerns":[]}'
assert_eq "a clean APPROVE is untouched" "$(norm dev "$B")" "APPROVE|-|0"
B='{"verdict":"REQUEST_REFACTOR","concerns":[]}'
assert_eq "REQUEST_REFACTOR is QA's testability mechanism and is left alone" "$(norm qa "$B")" "REQUEST_REFACTOR|-|0"
B='{"verdict":"REQUEST_CHANGES","concerns":[{"severity":"blocker","description":"unrated"}]}'
assert_eq "an unrated blocker keeps a REQUEST_CHANGES standing (fail closed)" "$(norm dba "$B")" "REQUEST_CHANGES|-|1"

suite "materiality: the veto is narrow"

B='{"verdict":"VETO","veto_ground":"auth","concerns":[]}'
assert_eq "a SecOps VETO on a named ground STANDS, with or without concerns" "$(norm secops "$B")" "VETO|-|0"
B='{"verdict":"VETO","concerns":[{"severity":"critical","likelihood":"normal-use","reversibility":"one-way-door","harm":"data-or-security"}]}'
assert_eq "a SecOps VETO with NO ground reads as REQUEST_CHANGES (still refuses the merge)" "$(norm secops "$B")" "REQUEST_CHANGES|VETO|1"
B='{"verdict":"VETO","veto_ground":"code-style","concerns":[{"severity":"critical","likelihood":"normal-use","reversibility":"one-way-door","harm":"data-or-security"}]}'
assert_eq "a SecOps VETO on an off-enum ground reads as REQUEST_CHANGES" "$(norm secops "$B")" "REQUEST_CHANGES|VETO|1"
B='{"verdict":"VETO","veto_ground":"code-style","concerns":[{"severity":"critical","likelihood":"hypothetical","reversibility":"one-way-door","harm":"data-or-security"}]}'
assert_eq "and that downgraded veto then obeys materiality: a hypothetical ships as notes" "$(norm secops "$B")" "APPROVE_WITH_NOTES|VETO|0"
B='{"verdict":"VETO","veto_ground":"auth","concerns":[]}'
assert_eq "VETO from a non-SecOps role reads as REQUEST_CHANGES even on a valid ground" "$(norm dba "$B")" "APPROVE_WITH_NOTES|VETO|0"
B='{"verdict":"VETO","veto_ground":"auth","concerns":[{"severity":"blocker","likelihood":"normal-use","reversibility":"undo-button","harm":"internal"}]}'
assert_eq "...and stands as REQUEST_CHANGES when it carries a real blocker" "$(norm dba "$B")" "REQUEST_CHANGES|VETO|1"

suite "materiality: idempotent, and the merge CLI applies it"

B='{"verdict":"REQUEST_CHANGES","concerns":[{"severity":"blocker","likelihood":"hypothetical","reversibility":"undo-button","harm":"internal"}]}'
ONCE="$(MOD="$MAT" node --input-type=module -e 'const m=await import(process.env.MOD);console.log(JSON.stringify(m.normalizeBlock(JSON.parse(process.argv[1]),"qa")))' "$B")"
TWICE="$(MOD="$MAT" node --input-type=module -e 'const m=await import(process.env.MOD);console.log(JSON.stringify(m.normalizeBlock(JSON.parse(process.argv[1]),"qa")))' "$ONCE")"
assert_eq "normalizing an already-normalized block changes nothing" "$TWICE" "$ONCE"

W="$TEMP_PROJECT/work"; mkdir -p "$W"
printf '%s' '{"verdict":"REQUEST_CHANGES","concerns":[{"severity":"high","likelihood":"hypothetical","reversibility":"undo-button","harm":"internal","description":"only if someone edits the config to disable the guard"}]}' > "$W/peer-review.qa.json"
printf '%s' '{"verdict":"APPROVE","concerns":[]}' > "$W/peer-review.secops.json"
( cd "$TEMP_PROJECT" && node "$MERGE" "$W/peer-review.json" "qa=$W/peer-review.qa.json" "secops=$W/peer-review.secops.json" ) >"$W/out.txt" 2>"$W/err.txt"
assert_eq "the merge CLI exits 0" "$?" "0"
assert_eq "the merged qa verdict is the NORMALIZED one" \
  "$(node --input-type=module -e 'import {readFileSync} from "node:fs";const j=JSON.parse(readFileSync(process.argv[1]));console.log(j.qa.verdict, j.qa.verdict_as_returned)' "$W/peer-review.json")" \
  "APPROVE_WITH_NOTES REQUEST_CHANGES"
assert_contains "and the merge SAYS it normalized, on stderr" "$(cat "$W/err.txt")" "normalized qa"
assert_eq "countVerdicts reads the normalized verdict, so the rubric does too" \
  "$(MOD="$MERGE" node --input-type=module -e 'import {readFileSync} from "node:fs";const m=await import(process.env.MOD);const j=JSON.parse(readFileSync(process.argv[1]));const c=m.countVerdicts(j,["qa","secops"]);console.log(c.request_changes, c.approve_with_notes, c.approve)' "$W/peer-review.json")" \
  "0 1 1"

finish
