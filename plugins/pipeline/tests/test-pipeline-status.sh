#!/usr/bin/env bash
# pipeline-status.mjs — the in-flight pipeline reporter.
#
# HERMETICITY IS THE HARD PART HERE, and it dictates the shape of every case below. The script
# binds `const ROOT = resolve(process.cwd())` at MODULE-IMPORT time (line 25) and takes no
# --root flag. So each case SPAWNS A SUBPROCESS with cwd set at spawn time:
#
#     ( cd "$dir" && node "$SCRIPTS_DIR/pipeline-status.mjs" )
#
# An in-process `process.chdir()` followed by a dynamic `import()` is NOT equivalent and does
# NOT satisfy this: an ESM module-level const is evaluated once at first import, so such a test
# would silently read THIS checkout's live .pipeline/ -- while run.sh is executing as the Stop
# hook's checkCommand during a real pipeline run. Do not "simplify" these cases into an import.

. "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
require_node

STATUS="$SCRIPTS_DIR/pipeline-status.mjs"

make_temp_project || exit 90

# ps_run <project-dir> <args...> -> RC, OUT
ps_run() {
  local dir="$1"; shift
  local outf="$TEMP_PROJECT/out.txt"
  ( cd "$dir" && node "$STATUS" "$@" ) >"$outf" 2>&1
  RC=$?
  OUT=$(cat "$outf")
}

new_root() { PROJ="$TEMP_PROJECT/$1"; mkdir -p "$PROJ"; }

# write_status <issue> <json>
write_status() {
  mkdir -p "$PROJ/.pipeline/$1"
  printf '%s' "$2" > "$PROJ/.pipeline/$1/status.json"
}
# write_spec <issue> <json>
write_spec() {
  mkdir -p "$PROJ/.pipeline/$1"
  printf '%s' "$2" > "$PROJ/.pipeline/$1/spec.json"
}

NOW=$(node -e 'console.log(new Date().toISOString())')
# `date -d` is GNU-only and `date -v` is BSD-only; node is already a hard dependency here, so
# it computes the timestamps and the suite stays portable.
OLD=$(node -e 'console.log(new Date(Date.now() - 48*3600*1000).toISOString())')

# ------------------------------------------------------------------------------------------------
# #74 s1: the ceiling is READ from the module that owns it, never re-spelled here.
#
# The old fixture was a bare `48*3600*1000` straddling a hardcoded 24h -- a straddle standing in
# for a boundary test, against pipeline-status.mjs's own copy of the number, with no boundary pair
# behind it. That is the same defect #63 fixed one level over, and #74 s4 records it. $OLD above is
# kept for the cases that only need "old", and the two cells below pin the BOUNDARY.
LEAF="$SCRIPTS_DIR/run-candidates.mjs"
CEIL="$(node --input-type=module -e 'const m = await import(process.argv[1]); process.stdout.write(String(m.IN_FLIGHT_MS))' "$LEAF" 2>/dev/null)"
MARGIN=$((60 * 60 * 1000))   # 1h, comfortably above any plausible wall-clock elapsed in one case
suite "pipeline-status: the ceiling is read from run-candidates.mjs, not re-spelled (#74 s1)"
# READ-STATE FIRST. A `$(( ))` on an empty or non-numeric read is the one spelling `set -u` does
# not catch: it evaluates to 0, which would date both fixtures in the future and pass every cell
# below for the wrong reason.
assert_eq "the leaf exports IN_FLIGHT_MS as a finite integer strictly greater than 2*MARGIN (below that, CEIL-MARGIN dates the INSIDE fixture in the FUTURE and the guard has no floor)" \
  "$(node -e 'const v = Number(process.argv[1]); const m = Number(process.argv[2]); process.stdout.write(Number.isSafeInteger(v) && v > 2*m ? "ok" : "UNUSABLE: " + JSON.stringify(process.argv[1]))' "$CEIL" "$MARGIN")" \
  "ok"
INSIDE=$(node -e 'console.log(new Date(Date.now() - (Number(process.argv[1]) - Number(process.argv[2]))).toISOString())' "$CEIL" "$MARGIN")
OUTSIDE=$(node -e 'console.log(new Date(Date.now() - (Number(process.argv[1]) + Number(process.argv[2]))).toISOString())' "$CEIL" "$MARGIN")

new_root boundary-inside
write_status 700 "{\"current_phase\":\"3\",\"updated_at\":\"$INSIDE\"}"
ps_run "$PROJ"
assert_not_contains "a record MARGIN INSIDE the ceiling is not stuck" "$OUT" "Possibly stuck"

new_root boundary-outside
write_status 701 "{\"current_phase\":\"3\",\"updated_at\":\"$OUTSIDE\"}"
ps_run "$PROJ"
assert_contains "a record MARGIN OUTSIDE the ceiling is stuck" "$OUT" "Possibly stuck"
assert_contains "and is named" "$OUT" "/pipeline --resume 701"

suite "pipeline-status: nothing in flight"

new_root empty-no-dir
ps_run "$PROJ"
assert_eq "an absent .pipeline exits 0" "$RC" "0"
assert_contains "and says there are no active pipelines" "$OUT" "No active pipelines here."

new_root empty-dir
mkdir -p "$PROJ/.pipeline"
ps_run "$PROJ"
assert_contains "an empty .pipeline says the same" "$OUT" "No active pipelines here."
assert_not_contains "and renders no table" "$OUT" "| Issue |"

suite "pipeline-status: one active issue renders one row"

new_root one-row
write_status 123 "{\"current_phase\":\"3\",\"risk_tier\":\"standard\",\"final_verdict\":\"APPROVE\",\"branch\":\"feat/x\",\"pr_url\":\"https://example.test/pr/1\",\"updated_at\":\"$NOW\"}"
write_spec 123 '{"title":"Courier roster rotation"}'
ps_run "$PROJ"
assert_eq "a numeric issue dir with status.json exits 0" "$RC" "0"
assert_contains "the table header is rendered" "$OUT" "| Issue | Title | Phase | Tier | Verdict | Branch | PR | Updated |"
assert_contains "the row carries the issue number" "$OUT" "| #123 |"
assert_contains "the row carries the title" "$OUT" "Courier roster rotation"
assert_contains "the row carries the phase" "$OUT" '`3`'
assert_contains "the row carries the tier" "$OUT" "standard"
assert_contains "the row carries the verdict" "$OUT" "APPROVE"
assert_contains "the row carries the branch" "$OUT" '`feat/x`'
assert_contains "the row carries the PR link" "$OUT" "[link](https://example.test/pr/1)"

suite "pipeline-status: only numeric issue dirs are pipelines"

new_root siblings
write_status 200 "{\"current_phase\":\"2\",\"updated_at\":\"$NOW\"}"
mkdir -p "$PROJ/.pipeline/schemas" "$PROJ/.pipeline/exp-script-test-coverage"
printf '%s' '{"current_phase":"9"}' > "$PROJ/.pipeline/schemas/status.json"
printf '%s' '{"current_phase":"9"}' > "$PROJ/.pipeline/exp-script-test-coverage/status.json"
ps_run "$PROJ"
assert_contains "the numeric issue dir is listed" "$OUT" "| #200 |"
assert_not_contains "a 'schemas' sibling is ignored" "$OUT" "schemas"
assert_not_contains "an exp-<slug> sibling is ignored" "$OUT" "exp-script-test-coverage"

suite "pipeline-status: tier resolution precedence"

new_root tier-status
write_status 1 "{\"current_phase\":\"3\",\"risk_tier\":\"architectural\",\"updated_at\":\"$NOW\"}"
write_spec 1 '{"risk_tier":"trivial","trivial":true}'
ps_run "$PROJ"
assert_contains "status.risk_tier wins over spec" "$OUT" "architectural"

new_root tier-spec
write_status 2 "{\"current_phase\":\"3\",\"updated_at\":\"$NOW\"}"
write_spec 2 '{"risk_tier":"standard","trivial":true}'
ps_run "$PROJ"
assert_contains "spec.risk_tier is next" "$OUT" "standard"

new_root tier-legacy
write_status 3 "{\"current_phase\":\"3\",\"updated_at\":\"$NOW\"}"
write_spec 3 '{"trivial":true}'
ps_run "$PROJ"
assert_contains "the legacy trivial boolean maps to trivial" "$OUT" "trivial"

new_root tier-none
write_status 4 "{\"current_phase\":\"3\",\"updated_at\":\"$NOW\"}"
ps_run "$PROJ"
assert_contains "no tier signal renders a dash" "$OUT" "| - |"

suite "pipeline-status: the stuck heading"

# A run that has not moved in over 24h and never reached a verdict is the shape worth
# surfacing; one that finished is not stuck no matter how old it is.
new_root stuck
write_status 300 "{\"current_phase\":\"3\",\"updated_at\":\"$OLD\"}"
ps_run "$PROJ"
assert_contains "an old run with no final verdict is flagged" "$OUT" "## Possibly stuck (over 24h, no final verdict)"
assert_contains "and names how to resume it" "$OUT" "/pipeline --resume 300"

new_root not-stuck
write_status 301 "{\"current_phase\":\"5\",\"final_verdict\":\"APPROVE\",\"updated_at\":\"$OLD\"}"
ps_run "$PROJ"
assert_not_contains "an old run WITH a final verdict is not flagged" "$OUT" "Possibly stuck"

new_root fresh
write_status 302 "{\"current_phase\":\"3\",\"updated_at\":\"$NOW\"}"
ps_run "$PROJ"
assert_not_contains "a fresh run with no verdict is not flagged" "$OUT" "Possibly stuck"

suite "pipeline-status: --json and --output"

new_root json-mode
write_status 400 "{\"current_phase\":\"4\",\"risk_tier\":\"standard\",\"branch\":\"feat/y\",\"updated_at\":\"$NOW\"}"
write_spec 400 '{"title":"JSON mode","impacted_domains":["testing"]}'
ps_run "$PROJ" --json
assert_eq "--json exits 0" "$RC" "0"
assert_contains "--json emits a pipelines array" "$OUT" '"pipelines"'
assert_contains "--json stamps generated_at" "$OUT" '"generated_at"'
assert_contains "--json carries the issue number as a number" "$OUT" '"issue_number": 400'
assert_contains "--json carries the resolved tier" "$OUT" '"tier": "standard"'
assert_contains "--json carries impacted_domains from the spec" "$OUT" '"impacted_domains"'
assert_not_contains "--json emits no markdown table" "$OUT" "| Issue |"

OUTFILE="$PROJ/report.json"
ps_run "$PROJ" --json "--output=$OUTFILE"
assert_eq "--output exits 0" "$RC" "0"
assert_eq "--output writes the payload to the file" \
  "$([[ -s "$OUTFILE" ]] && echo written || echo missing)" "written"
assert_contains "the written payload is the JSON report" "$(cat "$OUTFILE")" '"generated_at"'
# stdout is NOT suppressed by --output: the orchestrator reads the stream while the file is
# for humans, and silently swallowing stdout would break the caller that pipes it.
assert_contains "--output still prints to stdout" "$OUT" '"pipelines"'

MDFILE="$PROJ/report.md"
ps_run "$PROJ" "--output=$MDFILE"
assert_contains "--output in markdown mode writes the table" "$(cat "$MDFILE")" "| Issue |"
assert_contains "--output in markdown mode still prints to stdout" "$OUT" "| #400 |"

suite "pipeline-status: malformed artifacts do not wedge the report"

new_root malformed
write_status 500 "{\"current_phase\":\"3\",\"updated_at\":\"$NOW\"}"
printf '%s' '{"title": }' > "$PROJ/.pipeline/500/spec.json"
ps_run "$PROJ"
assert_eq "an unparseable spec.json still exits 0" "$RC" "0"
assert_contains "the issue is still listed" "$OUT" "| #500 |"
assert_contains "with a placeholder title" "$OUT" "(untitled)"

new_root no-status
mkdir -p "$PROJ/.pipeline/600"
printf '%s' '{"title":"no status here"}' > "$PROJ/.pipeline/600/spec.json"
ps_run "$PROJ"
assert_contains "an issue dir with no status.json is skipped" "$OUT" "No active pipelines here."

suite "pipeline-status: the mtime substitution no longer reaches the DECISION (#74 s2, same grain)"

# A record with NO updated_at used to be dated by its FILE MTIME (`updated_at: status?.updated_at
# ?? mtime`) and so appeared under the stuck heading as soon as the FILE was a day old -- a figure
# about the checkout, not about the run, and one a fresh clone resets. The display column still
# falls back to mtime; the decision reads only the record's own claim.
new_root undatable
write_status 800 '{"current_phase":"3"}'
# Backdate the FILE well past the ceiling. If the decision still read mtime, this would be stuck.
touch -t 202001010000.00 "$PROJ/.pipeline/800/status.json"
ps_run "$PROJ"
assert_not_contains "a record with no updated_at is NOT called stuck on the strength of an ancient file mtime" "$OUT" "Possibly stuck"
# ...and it is not silently dropped either. "We cannot judge this one" must not read as "fine".
assert_contains "it is named under its own heading instead" "$OUT" "## Cannot be dated (no parseable updated_at, no final verdict)"
assert_contains "and the row is still in the table" "$OUT" "| #800 |"

new_root undatable-concluded
write_status 801 '{"current_phase":"5-archived","final_verdict":"APPROVE"}'
touch -t 202001010000.00 "$PROJ/.pipeline/801/status.json"
ps_run "$PROJ"
assert_not_contains "a CONCLUDED record is not listed undatable: concluded is decided before dating" "$OUT" "Cannot be dated"

# NON-ZERO CONTROL for the heading above: it must be able to stay absent. A `assert_not_contains`
# on a heading that never renders under any input proves nothing about this fixture.
new_root undatable-control
write_status 802 "{\"current_phase\":\"3\",\"updated_at\":\"$NOW\"}"
ps_run "$PROJ"
assert_not_contains "CONTROL: a datable record renders NO undatable section (so its presence above was caused by the fixture)" "$OUT" "Cannot be dated"

# ================================================================================================
suite "#74 s1 BITE PROOF: one mutation of the leaf must move BOTH consumers"
# ================================================================================================
#
# Unifying two modules on one symbol is worth nothing if only one of them actually reads it. So
# this does not assert that the import exists -- it MUTATES the single source and requires both
# consumers to change their answer about the SAME record.
#
# WHOLE-DIRECTORY COPY, never one file: pipeline-status.mjs imports ./run-candidates.mjs and
# validate-pipeline-artifact.mjs imports it too, and a one-file copy dies with
# ERR_MODULE_NOT_FOUND, which reads as a failure of the behaviour under test rather than of the
# fixture (the lesson is #63's R6(a), recorded there against six whole-directory copies).
#
# VALUE-RELATIVE SHIFT, never a rewrite of the literal `24 * 60 * 60 * 1000`: the shipped value is
# read at runtime and the replacement is computed from it, so this cell survives a future retune
# of the constant instead of dying on it.
new_tmpdir || exit 90
MUT="$NEW_TMPDIR/scripts"
mkdir -p "$MUT"
cp "$SCRIPTS_DIR"/*.mjs "$MUT/" 2>/dev/null
mkdir -p "$NEW_TMPDIR/schemas" && cp "$PLUGIN_ROOT/schemas"/*.json "$NEW_TMPDIR/schemas/" 2>/dev/null

DECL_COUNT="$(grep -c '^export const IN_FLIGHT_MS = .*;$' "$MUT/run-candidates.mjs" | tr -d ' ')"
assert_eq "the leaf carries EXACTLY ONE ceiling declaration to mutate (a mutation that edits zero lines is a rubber stamp that reports green)" \
  "$DECL_COUNT" "1"

SHIFTED=$(( (CEIL - MARGIN) / 2 ))
node -e '
const fs = require("node:fs");
const f = process.argv[1];
const before = fs.readFileSync(f, "utf8");
const re = /^export const IN_FLIGHT_MS = .*;$/m;
const after = before.replace(re, "export const IN_FLIGHT_MS = " + process.argv[2] + ";");
if (after === before) { console.error("MUTATION DID NOT APPLY"); process.exit(1); }
fs.writeFileSync(f, after);
process.stdout.write(after.match(re)[0]);
' "$MUT/run-candidates.mjs" "$SHIFTED" > "$TEMP_PROJECT/mutline.txt"
# PROVE THE MUTATION YOU APPLIED IS THE MUTATION YOU MEANT: print the changed line and assert it.
record "mutated leaf declaration now reads: $(cat "$TEMP_PROJECT/mutline.txt")"
assert_eq "the mutation landed on the declaration line and wrote the computed value" \
  "$(cat "$TEMP_PROJECT/mutline.txt")" "export const IN_FLIGHT_MS = $SHIFTED;"

# The SAME record for both consumers: age = CEIL - MARGIN. Inside the shipped ceiling, outside
# the shifted one. Under the shipped constant it is neither stuck nor excluded from candidacy.
new_root bite
write_status 900 "{\"current_phase\":\"4-review\",\"updated_at\":\"$INSIDE\"}"

# CONSUMER 1 -- the reporter. Baseline first: the UNMUTATED module must call it not-stuck, or the
# flip below is not a flip.
ps_run "$PROJ"
assert_not_contains "CONSUMER 1 baseline: the shipped module does not call the fixture stuck" "$OUT" "Possibly stuck"
MUT_OUT="$( ( cd "$PROJ" && node "$MUT/pipeline-status.mjs" ) 2>&1 )"
assert_contains "CONSUMER 1 BITES: the same record IS stuck once the leaf's ceiling is shifted, so pipeline-status.mjs genuinely reads it" \
  "$MUT_OUT" "Possibly stuck"

# CONSUMER 2 -- validate-pipeline-artifact.mjs's run-owner resolution, which the PreToolUse gate
# uses. Same record, same mutated leaf, no ceiling passed in, so it takes the leaf's default.
owner_provenance() {  # <scripts-dir> -> the provenance resolveRunOwner returns for $PROJ
  node --input-type=module -e '
    const m = await import(process.argv[1] + "/validate-pipeline-artifact.mjs");
    const r = m.resolveRunOwner(process.argv[2] + "/.pipeline", {});
    process.stdout.write(String(r && r.provenance));
  ' "$1" "$2" 2>/dev/null
}
assert_eq "CONSUMER 2 baseline: under the SHIPPED leaf the record is the single candidate and resolves as the owner" \
  "$(owner_provenance "$SCRIPTS_DIR" "$PROJ")" "inference"
assert_eq "CONSUMER 2 BITES: under the SHIFTED leaf the same record is no longer recent, so it leaves the candidate set and no owner resolves -- one mutation, two consumers, which is what 'unified' has to mean" \
  "$(owner_provenance "$MUT" "$PROJ")" "none"

# ------------------------------------------------------------------------------------------------
# THE MUTATION EXPECTED TO SURVIVE. A battery where every mutation reddens cannot tell coverage
# from a rubber stamp, so one cell here is a mutation that must NOT move the reporter -- and it is
# a THEOREM about the design rather than a coverage gap. gate-phase-entry.mjs declares its own
# IN_FLIGHT_MS and passes it EXPLICITLY into inFlightObservations; run-candidates.mjs's copy is the
# default for callers with no guard to ask. That separation is deliberate and documented at
# run-candidates.mjs's declaration (#63-A2 pins the guard's exact source text, and folding it into
# a re-export would leave that mutation driving the shipped number). So a rewrite of the GUARD's
# declaration must leave pipeline-status.mjs's answer untouched. What keeps the two equal is
# tests/test-pretooluse-inflight-ceiling.sh, which asserts both declarations carry the same value
# expression -- if THIS cell ever reddens, the separation has been collapsed and that suite, not
# this one, is where the drift should have been caught.
new_tmpdir || exit 90
SURV="$NEW_TMPDIR/scripts"
mkdir -p "$SURV"
cp "$SCRIPTS_DIR"/*.mjs "$SURV/" 2>/dev/null
node -e '
const fs = require("node:fs");
const f = process.argv[1];
const before = fs.readFileSync(f, "utf8");
const re = /^export const IN_FLIGHT_MS = .*;$/m;
const after = before.replace(re, "export const IN_FLIGHT_MS = " + process.argv[2] + ";");
if (after === before) { console.error("MUTATION DID NOT APPLY"); process.exit(1); }
fs.writeFileSync(f, after);
process.stdout.write(after.match(re)[0]);
' "$SURV/gate-phase-entry.mjs" "$SHIFTED" > "$TEMP_PROJECT/survline.txt"
record "mutated GUARD declaration now reads: $(cat "$TEMP_PROJECT/survline.txt")"
assert_eq "the survivor mutation also landed where it was aimed" \
  "$(cat "$TEMP_PROJECT/survline.txt")" "export const IN_FLIGHT_MS = $SHIFTED;"
SURV_OUT="$( ( cd "$PROJ" && node "$SURV/pipeline-status.mjs" ) 2>&1 )"
assert_not_contains "EXPECTED SURVIVOR: shifting gate-phase-entry.mjs's OWN declaration does NOT move the reporter, because the guard passes its constant in explicitly and the reporter reads the leaf's default (#74 s1; the two are kept equal by test-pretooluse-inflight-ceiling.sh, not by sharing a symbol)" \
  "$SURV_OUT" "Possibly stuck"

finish
