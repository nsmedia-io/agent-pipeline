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

finish
