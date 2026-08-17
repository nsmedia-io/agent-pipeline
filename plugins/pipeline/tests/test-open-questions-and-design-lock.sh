#!/usr/bin/env bash
# The two Phase-1/Phase-2.5 owner gates, proved at the only layer that can enforce them.
#
# Both gates have an ENFORCED half and an UNENFORCED half, and the split is the point:
#
#   ENFORCED here (schema + SubagentStop validator):
#     - design.json is validated at all. It was in NO AGENT_RULES entry until now, so
#       design.schema.json had never validated anything since the day it was written.
#       The bake-off judge runs as subagent_type "dev", so it validates at dev's stop.
#     - open_questions entries carry id/question/why_it_matters/ba_recommendation/blocking.
#       ba_recommendation being schema-required is what stops "here are three questions,
#       you decide" from being a valid spec.
#
#   NOT enforceable here, and deliberately not faked:
#     - whether `blocking` was set HONESTLY (the two-acceptance-criteria bar), and
#     - conditional completeness of owner_decision when required is true.
#       The validator does not implement if/then (see its header), so those live in the
#       orchestrator's prose gates. A test asserting them would be testing this file's
#       fixtures, not the pipeline.
#
# Every mutation below is paired with the control that proves the check can also stay quiet;
# "blocks" from a validator that blocks everything is a zero result.

. "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
require_node

VALIDATOR="$SCRIPTS_DIR/validate-pipeline-artifact.mjs"
ISSUE=4243

make_temp_project "$ISSUE" || exit 90
printf '%s' '{"current_phase":"2.5-design"}' > "$TEMP_ISSUE_DIR/status.json"

# hook <agent_type> -> RC, OUT
hook() {
  local outf="$TEMP_PROJECT/out.txt"
  printf '{"agent_type":"%s","cwd":"%s","active_issue":"%s"}' "$1" "$TEMP_PROJECT" "$ISSUE" \
    | ( cd "$TEMP_PROJECT" && CLAUDE_PROJECT_DIR="$TEMP_PROJECT" node "$VALIDATOR" ) \
      >"$outf" 2>/dev/null
  RC=$?
  OUT=$(cat "$outf")
}

# ---------------------------------------------------------------------------
suite "design.json: reachable by the validator at all (it was not, before)"

DESIGN_VALID='{"issue_number":4243,"designed_at":"2026-01-01T00:00:00Z",
 "chosen_approach":{"summary":"s"},"rationale":"r",
 "rejected_alternatives":[{"approach":"a","why_rejected":"w"}],
 "owner_decision":{"required":false}}'

printf '%s' "$DESIGN_VALID" > "$TEMP_ISSUE_DIR/design.json"
hook dev
assert_eq "CONTROL: a valid design.json exits 0" "$RC" "0"
assert_eq "CONTROL: a valid design.json emits nothing" "$OUT" ""

# Written out literally rather than edited out of the valid fixture. A regex mutation that
# silently no-ops reads identically to a real one at the assertion.
printf '%s' '{"issue_number":4243,"designed_at":"2026-01-01T00:00:00Z",
 "chosen_approach":{"summary":"s"},"rationale":"r",
 "rejected_alternatives":[{"approach":"a","why_rejected":"w"}]}' > "$TEMP_ISSUE_DIR/design.json"
assert_not_contains "the mutation actually landed (no owner_decision in the fixture)" \
  "$(cat "$TEMP_ISSUE_DIR/design.json")" "owner_decision"
hook dev
assert_eq "a design.json missing owner_decision STILL exits 0 (fail open)" "$RC" "0"
assert_contains "a design.json missing owner_decision blocks" "$OUT" '"decision"'
assert_contains "and names the offending artifact" "$OUT" "design.json"
assert_contains "and names the missing field" "$OUT" "owner_decision"

printf '%s' '{"issue_number":4243,"designed_at":"2026-01-01T00:00:00Z",
 "chosen_approach":{"summary":"s"},"rationale":"r",
 "rejected_alternatives":[{"approach":"a","why_rejected":"w"}],
 "owner_decision":{"required":"yes"}}' > "$TEMP_ISSUE_DIR/design.json"
hook dev
assert_contains "owner_decision.required as a string, not a boolean, blocks" "$OUT" '"decision"'

rm -f "$TEMP_ISSUE_DIR/design.json"

# ---------------------------------------------------------------------------
suite "spec.json open_questions: the field that lets BA ask instead of guess"

SPEC_HEAD='{"issue_number":4243,"title":"t","problem":"p","requirements":["r1"],
 "acceptance_criteria":["ac1"],"impacted_domains":["api"],"trivial":false,
 "ba_approved_at":"2026-01-01T00:00:00Z"'

Q_VALID='{"id":"q1","question":"q","why_it_matters":"w","ba_recommendation":"rec","blocking":true}'

printf '%s' "$SPEC_HEAD,\"open_questions\":[$Q_VALID]}" > "$TEMP_ISSUE_DIR/spec.json"
hook ba
assert_eq "CONTROL: a well-formed blocking question exits 0" "$RC" "0"
assert_eq "CONTROL: a well-formed blocking question emits nothing" "$OUT" ""

printf '%s' "$SPEC_HEAD,\"open_questions\":[{\"id\":\"q1\",\"question\":\"q\",\"why_it_matters\":\"w\",\"blocking\":true}]}" \
  > "$TEMP_ISSUE_DIR/spec.json"
hook ba
assert_eq "a question with no ba_recommendation STILL exits 0 (fail open)" "$RC" "0"
assert_contains "a question with no ba_recommendation blocks" "$OUT" '"decision"'
assert_contains "and names the field BA skipped" "$OUT" "ba_recommendation"

printf '%s' "$SPEC_HEAD,\"open_questions\":[{\"id\":\"q1\",\"question\":\"q\",\"why_it_matters\":\"w\",\"ba_recommendation\":\"rec\",\"blocking\":\"true\"}]}" \
  > "$TEMP_ISSUE_DIR/spec.json"
hook ba
assert_contains "blocking as a string, not a boolean, blocks" "$OUT" '"decision"'

# EXPECTED SURVIVOR (evidence.md rule 3b). open_questions is optional by design: the common
# case is an unambiguous ask, and a spec without the array must stay valid. If this one ever
# starts blocking, someone made the field required and every pre-existing spec just broke.
printf '%s' "$SPEC_HEAD}" > "$TEMP_ISSUE_DIR/spec.json"
hook ba
assert_eq "SURVIVOR: a spec with no open_questions at all stays quiet" "$OUT" ""

finish
