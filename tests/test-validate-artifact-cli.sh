#!/usr/bin/env bash
# validate-pipeline-artifact.mjs --file: the validator run on one artifact, on demand
# (#164 rows 27 and 29).
#
# Two prose checks used to be done by hand. phase-3-architectural.md told the orchestrator to read
# spec.falsifiability_pass and check measured_state was present before Phase 3; the Phase 4
# preamble told each reviewer to parse its own shard with an inline node one-liner and eyeball
# the enum fields. Both now run this mode. The cells below check what it refuses, what it lets
# through, and that the hand instructions stay gone.

. "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
require_node

V="$SCRIPTS_DIR/validate-pipeline-artifact.mjs"
P3A="$PLUGIN_ROOT/orchestrator/phase-3-architectural.md"
PRE="$PLUGIN_ROOT/orchestrator/phase-4-panel-preamble.md"

make_temp_project 5 || exit 90
D="$TEMP_ISSUE_DIR"

# Run the CLI; sets OUT and RC.
v() {
  OUT="$(node "$V" "$@" 2>&1)"
  RC=$?
}

HEAD_FIELDS='"issue_number":5,"title":"t","problem":"p","requirements":["r1"],"impacted_domains":["api"],"trivial":false,"ba_approved_at":"2026-01-01T00:00:00Z"'
AC='"acceptance_criteria":["AC1. one","AC2. two"]'
FP_FULL='"falsifiability_pass":{"one_mutation_per_criterion":[{"criterion":"AC1","mutation":"m1"}],"unmutable":[{"criterion":"AC2","why":"w","discharged_by":"a read"}]}'
FP_SHORT='"falsifiability_pass":{"one_mutation_per_criterion":[{"criterion":"AC1","mutation":"m1"}]}'
MS='"measured_state":[{"label":"rows","value":3,"grain":"rows","window":"today","source":"a query"}]'
spec() { printf '{%s}' "$1" > "$D/spec.json"; }

suite "--file on spec.json: the architectural falsifiability gate"

spec "$HEAD_FIELDS,$AC,$FP_FULL,$MS"
v --file "$D/spec.json" --tier architectural
assert_eq "a spec with full coverage and measured_state is VALID (exit 0)" "$RC" "0"
assert_contains "and says so" "$OUT" "VALID: "
spec "$HEAD_FIELDS,$AC,$FP_SHORT,$MS"
v --file "$D/spec.json" --tier architectural
assert_eq "a criterion with no mutation and no unmutable row exits 2" "$RC" "2"
assert_contains "and names the uncovered criterion" "$OUT" "covers no mutation for AC2"
spec "$HEAD_FIELDS,$AC,$MS"
v --file "$D/spec.json" --tier architectural
assert_eq "no falsifiability_pass at the architectural tier exits 2" "$RC" "2"
assert_contains "and says it is absent" "$OUT" "falsifiability_pass is absent at the architectural tier"
spec "$HEAD_FIELDS,$AC,$FP_FULL"
v --file "$D/spec.json" --tier architectural
assert_eq "no measured_state at the architectural tier exits 2" "$RC" "2"
assert_contains "and names measured_state" "$OUT" "measured_state is absent or empty"
v --file "$D/spec.json" --tier standard
assert_eq "the same spec at the standard tier is VALID" "$RC" "0"
spec "$HEAD_FIELDS,$AC,$FP_FULL,\"risk_tier\":\"architectural\""
v --file "$D/spec.json"
assert_eq "with no --tier, the spec's own risk_tier applies" "$RC" "2"
spec "$HEAD_FIELDS,\"acceptance_criteria\":[\"one\",\"two\"],$FP_FULL,$MS"
v --file "$D/spec.json" --tier architectural
assert_eq "criteria without AC labels exit 2 (the gate would otherwise check nothing)" "$RC" "2"
spec "$HEAD_FIELDS,$FP_FULL,$MS"
v --file "$D/spec.json" --tier architectural
assert_contains "a schema violation is reported too" "$OUT" 'missing required field "acceptance_criteria"'

suite "--file on a peer-review shard: what the reviewer used to parse-check by hand"

SHARD="$D/peer-review.qa.json"
printf '%s' '{"verdict":"APPROVE_WITH_NOTES","concerns":[{"id":"qa-1","severity":"high","likelihood":"edge-case","harm":"internal","merge_class":"none"}]}' > "$SHARD"
v --file "$SHARD"
assert_eq "a well-formed shard is VALID" "$RC" "0"
assert_contains "validated as a peer-review shard" "$OUT" "(peer-review)"
printf '%s' '{"verdict":"APPROVE","concerns":[' > "$SHARD"
v --file "$SHARD"
assert_eq "a stray bracket (JSON that will not parse) exits 2" "$RC" "2"
assert_contains "and says it is not JSON" "$OUT" "not readable as JSON"
printf '%s' '{"verdict":"APPROVE","concerns":[{"id":"qa-1","severity":"this is quite bad","likelihood":"edge-case","harm":"internal","merge_class":"none"}]}' > "$SHARD"
v --file "$SHARD"
assert_eq "prose where a severity token belongs exits 2" "$RC" "2"
assert_contains "and names the field" "$OUT" "/concerns[0]/severity"
printf '%s' '{"verdict":"APPROVE","concerns":[{"severity":"blocker","likelihood":"normal-use","harm":"money","merge_class":"money"}]}' > "$SHARD"
v --file "$SHARD"
assert_eq "a blocker with no id exits 2" "$RC" "2"
assert_contains "and names the id" "$OUT" 'missing required field "id"'
printf '%s' '{"verdict":"APPROVE","concerns":[{"severity":"nit","likelihood":"normal-use","harm":"cosmetic","merge_class":"none"}]}' > "$SHARD"
v --file "$SHARD"
assert_eq "CONTROL: a nit with no id is VALID (the id is required only on blocking severities)" "$RC" "0"
printf '%s' '{"verdict":"LGTM"}' > "$SHARD"
v --file "$SHARD"
assert_eq "a verdict outside the enum exits 2" "$RC" "2"
printf '%s' '{"verdict":"VETO","veto_ground":"not-a-ground","reviewed_at":"2026-01-01T00:00:00Z","concerns":[],"notes":[]}' > "$D/review.secops.json"
v --file "$D/review.secops.json"
assert_eq "a SecOps review shard is checked against the SecOps block (veto_ground enum)" "$RC" "2"

suite "--file: schema selection and usage"

cp "$SHARD" "$D/renamed.json"
v --file "$D/renamed.json"
assert_eq "a file name that implies no schema, with no --schema, is a usage error (exit 1)" "$RC" "1"
printf '%s' '{"verdict":"LGTM"}' > "$D/renamed.json"
v --file "$D/renamed.json" --schema peer-review
assert_eq "--schema names it; a whole peer-review file with a bad shape exits 2" "$RC" "2"
v --file "$D/spec.json" --schema nonsense
assert_eq "an unknown --schema is a usage error" "$RC" "1"
v --file "$D/spec.json" --tier enormous
assert_eq "an unknown --tier is a usage error" "$RC" "1"
v --file "$D/does-not-exist.json" --schema spec
assert_eq "a missing file is INVALID, not a silent pass (exit 2)" "$RC" "2"
v --file "$D/spec.json" --bogus
assert_eq "an unknown flag is a usage error" "$RC" "1"
OUT="$(printf "{}" | node "$V" 2>/dev/null)"
assert_eq "CONTROL: hook mode (stdin, no --file) prints no decision on stdout for an empty payload" "$OUT" ""

suite "--file: the hand instructions it replaced stay removed"

assert_eq "phase-3-architectural.md no longer tells the orchestrator to read falsifiability_pass by hand" \
  "$(grep -c 'Read `spec.falsifiability_pass`' "$P3A" | tr -d ' ')" "0"
assert_eq "nor to check measured_state presence by hand" \
  "$(grep -c 'Also check `spec.measured_state` is present' "$P3A" | tr -d ' ')" "0"
assert_contains "the gate runs the CLI at the architectural tier" "$(cat "$P3A")" 'validate-pipeline-artifact.mjs" --file "$ARTIFACT_DIR/spec.json" --tier architectural'
assert_eq "the preamble no longer carries the inline parse-check one-liner" \
  "$(grep -c 'PARSE-CHECK the shard' "$PRE" | tr -d ' ')" "0"
assert_contains "the preamble runs the CLI on the reviewer's own shard" "$(cat "$PRE")" 'validate-pipeline-artifact.mjs" --file <ARTIFACT_DIR>/peer-review.<role>.json'

finish
