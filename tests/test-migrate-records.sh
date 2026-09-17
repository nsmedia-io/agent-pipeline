#!/usr/bin/env bash
# scripts/migrate-records.mjs: the upgrade path for .pipeline records written by an older release.
#
# What it must do: REPORT every record the current schemas reject, NORMALISE only what is
# mechanical (a recorded merge makes the terminal phase "5-archive"; a record with nothing else
# wrong gets its schema_version), and NEVER invent a rating. Dry run unless --write.
# Every write row has a CONTROL that differs by the one fact that licenses the write, and every
# never-write row compares bytes, not a parse.

. "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
require_node

MIGRATE="$SCRIPTS_DIR/migrate-records.mjs"

make_temp_project 1 || exit 90
ROOT="$TEMP_PROJECT"
P="$ROOT/.pipeline"

run() { OUT=$(node "$MIGRATE" --root "$ROOT" "$@" 2>&1); RC=$?; }
field() { node -e 'const v=require(process.argv[1])[process.argv[2]]; console.log(v===undefined?"<absent>":JSON.stringify(v))' "$1" "$2"; }
sum() { cksum < "$1" | tr -d ' \t'; }

status() { # <issue> <json>
  mkdir -p "$P/$1"; printf '%s\n' "$2" > "$P/$1/status.json"
}
BASE='"started_at":"2026-08-01T00:00:00Z","updated_at":"2026-08-02T00:00:00Z","branch":"b"'

# ---------------------------------------------------------------------------
suite "migrate-records: a malformed phase on a run that records a merge"

status 101 "{\"current_phase\":\"phase3_complete_rev21\",$BASE,\"events\":[{\"phase\":\"4-review\",\"verdict\":\"merged\",\"at\":\"2026-08-02T00:00:00Z\"}]}"
BEFORE=$(sum "$P/101/status.json")
run
assert_eq "a dry run exits 0" "$RC" "0"
assert_contains "the dry run names the phase the live schema rejects" "$OUT" '"phase3_complete_rev21" -> "5-archive"'
assert_contains "and says it WOULD change, not that it did" "$OUT" "would change: current_phase"
assert_eq "and the dry run leaves the file byte-identical" "$(sum "$P/101/status.json")" "$BEFORE"

run --write
assert_contains "--write reports the change as made" "$OUT" "changed: current_phase"
assert_eq "--write sets current_phase to 5-archive" "$(field "$P/101/status.json" current_phase)" '"5-archive"'
assert_eq "and stamps schema_version on the now-valid record" "$(field "$P/101/status.json" schema_version)" "1"
assert_eq "and keeps every other field" "$(field "$P/101/status.json" branch)" '"b"'
AFTER=$(sum "$P/101/status.json")
run --write
assert_eq "a second --write changes nothing (idempotent)" "$(sum "$P/101/status.json")" "$AFTER"
assert_not_contains "and reports nothing for that record" "$OUT" ".pipeline/101/"

# ---------------------------------------------------------------------------
suite "migrate-records: the same malformed phase with NO merge record (control)"

status 102 "{\"current_phase\":\"phase3_complete_rev21\",$BASE,\"completed_at\":\"2026-08-02T00:00:00Z\",\"final_verdict\":\"APPROVE\",\"events\":[]}"
BEFORE=$(sum "$P/102/status.json")
run --write
assert_contains "CONTROL: it is reported for an owner decision" "$OUT" 'owner: current_phase "phase3_complete_rev21" is rejected and the record carries NO merge'
assert_contains "and the concluded state is named" "$OUT" "although the run reads as concluded"
assert_eq "CONTROL: --write leaves it byte-identical (no phase inferred, no stamp)" "$(sum "$P/102/status.json")" "$BEFORE"

status 103 "{\"current_phase\":\"4-review\",$BASE,\"completed_at\":\"2026-08-02 merged at 9451894\",\"events\":[]}"
BEFORE=$(sum "$P/103/status.json")
run --write
assert_contains "a merge mentioned in free text is not a merge record: the bad timestamp is reported" "$OUT" "/completed_at"
assert_eq "and the phase is not moved on the strength of prose" "$(field "$P/103/status.json" current_phase)" '"4-review"'
assert_eq "and the file is byte-identical" "$(sum "$P/103/status.json")" "$BEFORE"

status 104 "{\"current_phase\":\"4-review-complete\",$BASE,\"final_verdict\":\"APPROVE\",\"events\":[]}"
run --write
assert_eq "CONTROL: a VALID non-terminal phase without a merge keeps its phase" "$(field "$P/104/status.json" current_phase)" '"4-review-complete"'
assert_eq "and, being otherwise valid, is stamped" "$(field "$P/104/status.json" schema_version)" "1"

status 105 "{\"current_phase\":\"4-review\",\"branch\":\"b\",\"merged_at\":\"2026-08-02T00:00:00Z\"}"
run --write
assert_eq "merged_at is a merge record: phase moves to 5-archive" "$(field "$P/105/status.json" current_phase)" '"5-archive"'
assert_eq "but a record still missing required fields is NOT stamped" "$(field "$P/105/status.json" schema_version)" "<absent>"
assert_contains "and says why" "$OUT" "not stamped while"
assert_contains "and names the missing field" "$OUT" 'missing required field "started_at"'

status 106 "{\"current_phase\":\"3-impl\",$BASE,\"events\":[],\"schema_version\":\"1\",\"fix_rounds\":-1,\"owner_overrides\":{}}"
run
assert_contains "a string schema_version is reported" "$OUT" "/schema_version: expected an integer"
assert_contains "a negative fix_rounds is reported" "$OUT" "/fix_rounds: expected an integer >= 0"
assert_contains "a non-array owner_overrides is reported" "$OUT" "/owner_overrides: expected an array"

mkdir -p "$P/107"; printf '{ not json' > "$P/107/status.json"
run --write
assert_contains "an unparseable status.json is reported, not a crash" "$OUT" ".pipeline/107/status.json"
assert_eq "and the run still exits 0" "$RC" "0"

# ---------------------------------------------------------------------------
suite "migrate-records: review shards are reported and NEVER written"

mkdir -p "$P/201"
cat > "$P/201/review.dba.json" <<'JSON'
{"verdict":"REQUEST_CHANGES","reviewed_at":"2026-08-01T00:00:00Z","notes":"x","concerns":[
  {"severity":"major","description":"unrated","must_satisfy":"x"},
  {"severity":"major","description":"rated","must_satisfy":"x","likelihood":"edge-case","harm":"internal","merge_class":"none"},
  {"severity":"major","description":"bad class","must_satisfy":"x","likelihood":"edge-case","harm":"internal","merge_class":"catastrophe"}
]}
JSON
cat > "$P/201/review.json" <<'JSON'
{"secops":{"verdict":"APPROVE","reviewed_at":"2026-08-01T00:00:00Z","notes":"x","concerns":[],
  "vulnerabilities":[{"severity":"low","description":"no fix"},{"severity":"low","description":"fixed","remediation":"rotate"}]}}
JSON
cat > "$P/201/peer-review.qa.json" <<'JSON'
{"qa":{"verdict":"APPROVE_WITH_NOTES","concerns":[{"severity":"nit","must_satisfy":"x","likelihood":"normal-use","harm":"cosmetic","merge_class":"none"}]}}
JSON
S1=$(sum "$P/201/review.dba.json"); S2=$(sum "$P/201/review.json"); S3=$(sum "$P/201/peer-review.qa.json")
run --write
assert_contains "an unrated concern is reported with the fields it lacks" "$OUT" "/concerns/0: missing likelihood, harm, merge_class"
assert_not_contains "CONTROL: the fully rated concern beside it is not reported" "$OUT" "/concerns/1"
assert_contains "a merge_class outside the enum is reported" "$OUT" '/concerns/2/merge_class: "catastrophe"'
assert_contains "a vulnerability without remediation is reported, found inside a merged review" "$OUT" "/secops/vulnerabilities/0: missing remediation"
assert_not_contains "CONTROL: the vulnerability with a remediation is not" "$OUT" "/vulnerabilities/1"
assert_not_contains "CONTROL: a role-wrapped peer-review shard with a fully rated concern is clean" "$OUT" "peer-review.qa.json"
assert_contains "the report says ratings are never filled in" "$OUT" "never filled in by migration"
assert_eq "--write leaves review.dba.json byte-identical" "$(sum "$P/201/review.dba.json")" "$S1"
assert_eq "--write leaves review.json byte-identical" "$(sum "$P/201/review.json")" "$S2"
assert_eq "--write leaves peer-review.qa.json byte-identical" "$(sum "$P/201/peer-review.qa.json")" "$S3"

# ---------------------------------------------------------------------------
suite "migrate-records: legacy fix_round / spec_revision counters map only when asked"

# A record from before the counters were named: fix_round and spec_revision held the CURRENT
# round and revision numbers, which is what fix_rounds and spec_revisions count.
status 301 "{\"current_phase\":\"4-review\",$BASE,\"events\":[],\"fix_round\":2,\"spec_revision\":3}"
BEFORE=$(sum "$P/301/status.json")
run
assert_contains "a dry run suggests fix_rounds = fix_round" "$OUT" "legacy counter fix_round 2: suggested mapping fix_rounds = 2"
assert_contains "and spec_revisions = spec_revision" "$OUT" "legacy counter spec_revision 3: suggested mapping spec_revisions = 3"
assert_contains "and names the flags that apply it" "$OUT" "apply it with --write --map-legacy-counters"
run --write
assert_eq "--write WITHOUT --map-legacy-counters leaves the record byte-identical" "$(sum "$P/301/status.json")" "$BEFORE"
assert_contains "  ...and still reports the suggestion as an owner decision" "$OUT" "owner: legacy counter fix_round 2"
run --map-legacy-counters
assert_contains "--map-legacy-counters without --write is a dry run that says what WOULD change" "$OUT" "would change: fix_rounds set to 2 from the legacy fix_round 2"
assert_eq "  ...and writes nothing" "$(sum "$P/301/status.json")" "$BEFORE"
run --write --map-legacy-counters
assert_contains "--write --map-legacy-counters reports the mapping as made" "$OUT" "changed: spec_revisions set to 3 from the legacy spec_revision 3"
assert_eq "  ...fix_rounds = fix_round" "$(field "$P/301/status.json" fix_rounds)" "2"
assert_eq "  ...spec_revisions = spec_revision" "$(field "$P/301/status.json" spec_revisions)" "3"
assert_eq "  ...and the legacy key is kept" "$(field "$P/301/status.json" fix_round)" "2"
AFTER=$(sum "$P/301/status.json")
run --write --map-legacy-counters
assert_eq "a second mapped write changes nothing (idempotent)" "$(sum "$P/301/status.json")" "$AFTER"
assert_not_contains "  ...and reports no legacy counter for it" "$OUT" "legacy counter fix_round"

status 302 "{\"current_phase\":\"4-review\",$BASE,\"events\":[],\"fix_round\":2,\"fix_rounds\":1}"
BEFORE=$(sum "$P/302/status.json")
run --write --map-legacy-counters
assert_contains "CONTROL: a legacy counter that DISAGREES with the new field is an owner decision" "$OUT" "legacy counter fix_round 2 disagrees with fix_rounds 1"
assert_eq "  ...and is not overwritten" "$(sum "$P/302/status.json")" "$BEFORE"

status 303 "{\"current_phase\":\"4-review\",$BASE,\"events\":[],\"fix_round\":\"two\"}"
BEFORE=$(sum "$P/303/status.json")
run --write --map-legacy-counters
assert_contains "CONTROL: a legacy counter that is not a non-negative integer is not mapped" "$OUT" 'legacy counter fix_round "two" is not a non-negative integer'
assert_eq "  ...and the record is byte-identical" "$(sum "$P/303/status.json")" "$BEFORE"

# ---------------------------------------------------------------------------
suite "migrate-records: scope, exit codes and usage"

mkdir -p "$P/_archived/9"
printf '{"current_phase":"garbage_phase"}' > "$P/_archived/9/status.json"
run
assert_not_contains "_-prefixed dirs are not scanned" "$OUT" "_archived"

run --check
assert_eq "--check exits 1 while records need attention" "$RC" "1"

make_temp_project 2 || exit 90
CLEAN="$TEMP_PROJECT"
mkdir -p "$CLEAN/.pipeline/5"
printf '%s\n' "{\"current_phase\":\"3-impl\",$BASE,\"events\":[],\"schema_version\":1}" > "$CLEAN/.pipeline/5/status.json"
OUT=$(node "$MIGRATE" --root "$CLEAN" --check 2>&1); RC=$?
assert_eq "CONTROL: --check exits 0 on a project whose records are all accepted" "$RC" "0"
assert_contains "and says so" "$OUT" "every record the current schemas check is accepted"
assert_contains "VACUITY: and it did read the record" "$OUT" "1 record file(s)"

OUT=$(node "$MIGRATE" --root "$CLEAN" --bogus 2>&1); RC=$?
assert_eq "an unknown argument exits 2" "$RC" "2"

JSON=$(node "$MIGRATE" --root "$ROOT" --json)
assert_contains "--json emits the machine report" "$JSON" '"targetSchemaVersion": 1'

finish
