#!/usr/bin/env bash
# merge-peer-review.mjs — the ONE merge mechanism behind both the auto re-review (pipeline.md)
# and the manual /phase peer-review re-run.
#
# The dangerous shape here is a SILENT one: a delta round that resets the roles it did not
# re-dispatch would drop standing approvals (or standing objections) with no error anywhere,
# and the rubric would then be counted over a panel that never existed. The additive contract
# and the two non-zero halts (missing shard, recovered-but-null verdict) are the whole point of
# the script, so both are pinned in both directions.

. "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
require_node

MERGE="$SCRIPTS_DIR/merge-peer-review.mjs"

make_temp_project || exit 90

JGET="$TEMP_PROJECT/jget.mjs"
cat > "$JGET" <<'EOF'
// jget <file> <dotted.path> -> prints the value, or "undefined"
import { readFileSync } from "node:fs";
const [file, dotted] = process.argv.slice(2);
let cur = JSON.parse(readFileSync(file, "utf8"));
for (const k of dotted.split(".")) cur = cur == null ? undefined : cur[k];
console.log(typeof cur === "object" ? JSON.stringify(cur) : String(cur));
EOF

COUNTS="$TEMP_PROJECT/counts.mjs"
cat > "$COUNTS" <<'EOF'
// counts <merged-json> <roles-json> -> prints the countVerdicts tally
const m = await import(process.env.MOD);
const [merged, roles] = process.argv.slice(2);
console.log(JSON.stringify(m.countVerdicts(JSON.parse(merged), JSON.parse(roles))));
EOF

jget() { node "$JGET" "$1" "$2"; }
counts() { MOD="$MERGE" node "$COUNTS" "$1" "$2"; }

# merge <args...> -> RC, OUT, ERR
merge() {
  local outf="$TEMP_PROJECT/out.txt" errf="$TEMP_PROJECT/err.txt"
  ( cd "$TEMP_PROJECT" && node "$MERGE" "$@" ) >"$outf" 2>"$errf"
  RC=$?
  OUT=$(cat "$outf")
  ERR=$(cat "$errf")
}

W="$TEMP_PROJECT/work"
mkdir -p "$W"

suite "merge-peer-review: the merge is ADDITIVE"

# A delta round: only dev is re-dispatched. dba's and qa's standing verdicts were rendered in
# the previous round and must survive untouched.
cat > "$W/peer-review.json" <<'EOF'
{"dba":{"verdict":"APPROVE","notes":"standing"},"qa":{"verdict":"REQUEST_CHANGES"},"dev":{"verdict":"REQUEST_CHANGES"}}
EOF
printf '%s' '{"verdict":"APPROVE","notes":"fixed"}' > "$W/peer-review.dev.json"
merge "$W/peer-review.json" "dev=$W/peer-review.dev.json"
assert_eq "a delta merge exits 0" "$RC" "0"
assert_eq "the re-dispatched role is overwritten" "$(jget "$W/peer-review.json" dev.verdict)" "APPROVE"
assert_eq "a standing APPROVE is preserved" "$(jget "$W/peer-review.json" dba.verdict)" "APPROVE"
assert_eq "a standing objection is preserved too" "$(jget "$W/peer-review.json" qa.verdict)" "REQUEST_CHANGES"
assert_eq "untouched roles keep their whole block, not just the verdict" \
  "$(jget "$W/peer-review.json" dba.notes)" "standing"

# A full round starts from no target file at all.
merge "$W/fresh.json" "dev=$W/peer-review.dev.json"
assert_eq "an absent target is created" "$RC" "0"
assert_eq "the created target carries the shard" "$(jget "$W/fresh.json" dev.verdict)" "APPROVE"

suite "merge-peer-review: a wrapped shard is recovered, not read as null"

# The failure this defends against: an agent writes {"dba": {...}} instead of a bare block, the
# merge stores the wrapper, and the rubric reads merged.dba.verdict as undefined -- a missing
# review that looks like a present one.
printf '%s' '{"dba":{"verdict":"VETO","concerns":[]}}' > "$W/peer-review.dba.json"
merge "$W/peer-review.json" "dba=$W/peer-review.dba.json"
assert_eq "a wrapped shard merges cleanly" "$RC" "0"
assert_eq "the wrapped verdict is recovered" "$(jget "$W/peer-review.json" dba.verdict)" "VETO"

suite "merge-peer-review: halts (a missing review is never a pass)"

merge "$W/peer-review.json" "devops=$W/nope.json"
assert_eq "a named shard that does not exist exits 2" "$RC" "2"
assert_contains "the halt says MISSING SHARD" "$ERR" "MISSING SHARD"
assert_contains "the halt names the role" "$ERR" "devops"

printf '%s' '{"notes":"I forgot the verdict"}' > "$W/peer-review.secops.json"
merge "$W/peer-review.json" "secops=$W/peer-review.secops.json"
assert_eq "a shard with no recoverable verdict exits 2" "$RC" "2"
assert_contains "the halt says NO RECOVERABLE VERDICT" "$ERR" "NO RECOVERABLE VERDICT"

printf '%s' '{"verdict":"   "}' > "$W/peer-review.blank.json"
merge "$W/peer-review.json" "secops=$W/peer-review.blank.json"
assert_eq "a blank-string verdict is not a verdict" "$RC" "2"

merge "$W/peer-review.json" "this-has-no-equals-sign"
assert_eq "a malformed role=shard argument exits 1" "$RC" "1"
assert_contains "and says which argument" "$ERR" "bad role=shard argument"

merge
assert_eq "no arguments exits 1" "$RC" "1"
assert_contains "and prints the usage line" "$ERR" "usage: merge-peer-review.mjs"

merge "$W/peer-review.json"
assert_eq "a target with no shards exits 1" "$RC" "1"

suite "merge-peer-review: the written file is well-formed"

printf '%s' '{"verdict":"APPROVE"}' > "$W/peer-review.ba.json"
merge "$W/out.json" "ba=$W/peer-review.ba.json"
node -e 'JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"))' "$W/out.json"
assert_eq "the target is valid JSON" "$?" "0"
LAST=$(tail -c 1 "$W/out.json")
assert_eq "the target ends with a trailing newline" "$(printf '%s' "$LAST" | wc -c | tr -d ' ')" "0"

suite "merge-peer-review: countVerdicts over the FULL panel"

ROLES='["dba","devops","secops","qa","dev","ba"]'
MERGED='{"dba":{"verdict":"APPROVE"},"devops":{"verdict":"APPROVE_WITH_NITS"},"secops":{"verdict":"VETO"},"qa":{"verdict":"REQUEST_REFACTOR"},"dev":{"verdict":"REQUEST_CHANGES"}}'
TALLY=$(counts "$MERGED" "$ROLES")
assert_contains "APPROVE lands in approve" "$TALLY" '"approve":1'
# APPROVE_WITH_NITS is the same verdict wearing an older name; counting it as its own bucket
# would silently drop it out of the rubric's approval tally.
assert_contains "APPROVE_WITH_NITS is tallied as approve_with_notes" "$TALLY" '"approve_with_notes":1'
assert_contains "REQUEST_CHANGES has its own bucket" "$TALLY" '"request_changes":1'
assert_contains "REQUEST_REFACTOR has its own bucket" "$TALLY" '"request_refactor":1'
assert_contains "VETO has its own bucket" "$TALLY" '"veto":1'

# ba is in the role list but absent from the merged object: it must land in NO bucket, so the
# caller can see that the panel is incomplete instead of reading a quiet zero as consensus.
TALLY_SUM=$(node -e 'const t=JSON.parse(process.argv[1]);console.log(Object.values(t).reduce((a,b)=>a+b,0))' "$TALLY")
assert_eq "a role absent from the merged object is counted nowhere" "$TALLY_SUM" "5"

TALLY=$(counts '{"dba":{"verdict":"approve"}}' '["dba"]')
assert_contains "verdict matching is case-insensitive" "$TALLY" '"approve":1'

TALLY=$(counts '{"dba":{"verdict":42}}' '["dba"]')
assert_contains "a non-string verdict is counted nowhere" "$TALLY" '"approve":0'

finish
