#!/usr/bin/env bash
# The two owner gates: Phase 1 open-questions, and the Phase 2.5 design-lock.
#
# Each gate is TWO mechanisms, and only one of them is code:
#
#   (1) The ARTIFACT can carry the gate — schema shape plus the bespoke non-blank checks.
#       Covered here at the validator, with a control on every mutation.
#   (2) The gate FIRES — the orchestrator halts and asks. That half is prose in
#       commands/pipeline.md that no script reads. It cannot be proved here.
#
# The prose half is not therefore untestable, and an earlier version of this file wrongly
# implied it was. Two cheap classes exist and are now covered below: the INSTRUCTION still
# being present in pipeline.md (it reddens when someone deletes a halt), and the phase strings
# the gates write conforming to status.schema.json's pattern. Neither proves a halt occurs.
# What would: a gate script asserting that a blocking question with no resolution cannot
# coexist with a current_phase past its gate. That script does not exist, so the honest
# statement of this suite's coverage is "the artifact can carry the gate, and the instruction
# is still written down" — NOT "the gate fires".
#
# On owner_decision NOT being schema-required: that was tried and reverted. See the schema's
# own description and AGENT_RULES' comment. The back-compat case is asserted below as a
# survivor, because it is a guarantee, not an accident.

. "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
require_node

VALIDATOR="$SCRIPTS_DIR/validate-pipeline-artifact.mjs"
PIPELINE_MD="$PLUGIN_ROOT/commands/pipeline.md"
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
suite "design.json: validated at all (it was in no AGENT_RULES entry before)"

DESIGN_VALID='{"issue_number":4243,"designed_at":"2026-01-01T00:00:00Z",
 "chosen_approach":{"summary":"s"},"rationale":"r",
 "rejected_alternatives":[{"approach":"a","why_rejected":"w"}],
 "owner_decision":{"required":false}}'

printf '%s' "$DESIGN_VALID" > "$TEMP_ISSUE_DIR/design.json"
hook dev
assert_eq "CONTROL: a valid design.json exits 0" "$RC" "0"
assert_eq "CONTROL: a valid design.json emits nothing" "$OUT" ""

# BACK-COMPAT SURVIVOR. A design.json written before owner_decision existed must keep
# validating. This is load-bearing, not incidental: owner_decision was briefly in the schema's
# required[] list, which failed every in-flight artifact AND surfaced the failure at the Phase 3
# DEV stop — the one role that does not own design.json and cannot fix it. If this case ever
# starts blocking, someone re-required the field and re-created that trap.
printf '%s' '{"issue_number":4243,"designed_at":"2026-01-01T00:00:00Z",
 "chosen_approach":{"summary":"s"},"rationale":"r",
 "rejected_alternatives":[{"approach":"a","why_rejected":"w"}],"residual_risks":["x"]}' \
  > "$TEMP_ISSUE_DIR/design.json"
assert_not_contains "the pre-owner_decision fixture really lacks the field" \
  "$(cat "$TEMP_ISSUE_DIR/design.json")" "owner_decision"
hook dev
assert_eq "SURVIVOR: a pre-owner_decision design.json still validates" "$OUT" ""

# The shape Dev CAN act on stays enforced: a missing chosen_approach is a malformed design the
# implementing thread should stop for.
printf '%s' '{"issue_number":4243,"designed_at":"2026-01-01T00:00:00Z","rationale":"r",
 "rejected_alternatives":[{"approach":"a","why_rejected":"w"}]}' > "$TEMP_ISSUE_DIR/design.json"
hook dev
assert_eq "a design.json missing chosen_approach STILL exits 0 (fail open)" "$RC" "0"
assert_contains "a design.json missing chosen_approach blocks" "$OUT" '"decision"'
assert_contains "and names the offending artifact" "$OUT" "design.json"

printf '%s' '{"issue_number":4243,"designed_at":"2026-01-01T00:00:00Z",
 "chosen_approach":{"summary":"s"},"rationale":"r",
 "rejected_alternatives":[{"approach":"a","why_rejected":"w"}],
 "owner_decision":{"required":"yes"}}' > "$TEMP_ISSUE_DIR/design.json"
hook dev
assert_contains "owner_decision.required as a string, not a boolean, blocks" "$OUT" '"decision"'

# resolution is what Phase 4 and Phase 5 read. Deleting its sub-schema once survived this
# suite entirely, so its shape is asserted rather than assumed.
printf '%s' '{"issue_number":4243,"designed_at":"2026-01-01T00:00:00Z",
 "chosen_approach":{"summary":"s"},"rationale":"r",
 "rejected_alternatives":[{"approach":"a","why_rejected":"w"}],
 "owner_decision":{"required":true,"resolution":{"chosen":"option_a","reasoning":"r"}}}' \
  > "$TEMP_ISSUE_DIR/design.json"
hook dev
assert_contains "owner_decision.resolution missing resolved_at blocks" "$OUT" '"decision"'

printf '%s' '{"issue_number":4243,"designed_at":"2026-01-01T00:00:00Z",
 "chosen_approach":{"summary":"s"},"rationale":"r",
 "rejected_alternatives":[{"approach":"a","why_rejected":"w"}],
 "owner_decision":{"required":true,"resolution":{"chosen":"whatever","reasoning":"r","resolved_at":"2026-01-01T00:00:00Z"}}}' \
  > "$TEMP_ISSUE_DIR/design.json"
hook dev
assert_contains "resolution.chosen outside its enum blocks" "$OUT" '"decision"'

rm -f "$TEMP_ISSUE_DIR/design.json"

# ---------------------------------------------------------------------------
suite "spec.json open_questions: the field that lets BA ask instead of guess"

SPEC_HEAD='{"issue_number":4243,"title":"t","problem":"p","requirements":["r1"],
 "acceptance_criteria":["ac1"],"impacted_domains":["api"],"trivial":false,
 "ba_approved_at":"2026-01-01T00:00:00Z"'

spec_with() { printf '%s' "$SPEC_HEAD,\"open_questions\":[$1]}" > "$TEMP_ISSUE_DIR/spec.json"; }

spec_with '{"id":"q1","question":"q","why_it_matters":"w","ba_recommendation":"rec","blocking":true}'
hook ba
assert_eq "CONTROL: a well-formed blocking question exits 0" "$RC" "0"
assert_eq "CONTROL: a well-formed blocking question emits nothing" "$OUT" ""

spec_with '{"id":"q1","question":"q","why_it_matters":"w","blocking":true}'
hook ba
assert_eq "a question with no ba_recommendation STILL exits 0 (fail open)" "$RC" "0"
assert_contains "a question with no ba_recommendation blocks" "$OUT" '"decision"'
assert_contains "and names the field BA skipped" "$OUT" "ba_recommendation"

spec_with '{"id":"q1","question":"q","why_it_matters":"w","ba_recommendation":"rec","blocking":"true"}'
hook ba
assert_contains "blocking as a string, not a boolean, blocks" "$OUT" '"decision"'

# The empty-string floor. `required` + `type` are both satisfied by "", which made the blank
# the cheapest valid value on the one field the whole feature rests on — the same gradient this
# change exists to remove, one level up, and worse than a missing key because the artifact still
# claims a recommendation exists. Enforced by groundOpenQuestions, not by the schema walker
# (which implements neither minLength nor if/then).
spec_with '{"id":"q1","question":"q","why_it_matters":"w","ba_recommendation":"","blocking":true}'
hook ba
assert_eq "an empty ba_recommendation STILL exits 0 (fail open)" "$RC" "0"
assert_contains "an empty ba_recommendation blocks" "$OUT" '"decision"'
assert_contains "and says a blank claims an answer that does not exist" "$OUT" "claims an answer exists"

spec_with '{"id":"q1","question":"   ","why_it_matters":"w","ba_recommendation":"rec","blocking":true}'
hook ba
assert_contains "a whitespace-only question blocks (trim, not just empty)" "$OUT" '"decision"'

spec_with '{"id":"q1","question":"q","why_it_matters":"w","ba_recommendation":"rec","blocking":false,
 "resolution":{"answer":"","answered_by":"ba_default","at":"2026-01-01T00:00:00Z"}}'
hook ba
assert_contains "an empty resolution.answer blocks" "$OUT" "records a decision nobody made"

# answered_by is what Phase 4 keys its harder look on and what Phase 5 degrades Confidence by.
spec_with '{"id":"q1","question":"q","why_it_matters":"w","ba_recommendation":"rec","blocking":false,
 "resolution":{"answer":"a","answered_by":"the owner","at":"2026-01-01T00:00:00Z"}}'
hook ba
assert_contains "answered_by outside its enum blocks" "$OUT" '"decision"'

spec_with '{"id":"q1","question":"q","why_it_matters":"w","ba_recommendation":"rec","blocking":false,
 "resolution":{"answer":"a","answered_by":"owner"}}'
hook ba
assert_contains "a resolution missing its timestamp blocks" "$OUT" '"decision"'

spec_with '{"id":"q1","question":"q","why_it_matters":"w","ba_recommendation":"rec","blocking":false,
 "options":[{"label":"A"}]}'
hook ba
assert_contains "an option missing its implication blocks" "$OUT" '"decision"'

# SURVIVOR. open_questions is optional by design: the common case is an unambiguous ask, and a
# spec without the array must stay valid. If this starts blocking, the field was made required
# and every pre-existing spec broke.
printf '%s' "$SPEC_HEAD}" > "$TEMP_ISSUE_DIR/spec.json"
hook ba
assert_eq "SURVIVOR: a spec with no open_questions at all stays quiet" "$OUT" ""

# INSTRUMENT CHECK (evidence.md rule 3b, turned on the harness itself). Every assertion above
# reads "blocks", so this suite cannot tell a working validator from one that blocks
# indiscriminately unless something valid-but-unusual stays quiet. A fully-populated entry,
# every optional field present, must not block.
spec_with '{"id":"q1","question":"q","why_it_matters":"w","ba_recommendation":"rec","blocking":false,
 "options":[{"label":"A","implication":"i"},{"label":"B","implication":"i2"}],
 "resolution":{"answer":"a","answered_by":"ba_default","at":"2026-01-01T00:00:00Z"}}'
hook ba
assert_eq "INSTRUMENT: a fully-populated valid entry stays quiet" "$OUT" ""

# ---------------------------------------------------------------------------
suite "the halt half: the instruction is still written down (it is prose, not code)"

# These do NOT prove a halt fires. They redden when someone deletes the instruction that says
# to halt, which is the only mechanical hold available on prose. Named for what they are.
MD=$(cat "$PIPELINE_MD")

assert_contains "Phase 2.5 still assigns stance A verbatim" "$MD" "smallest blast radius"
assert_contains "Phase 2.5 still assigns stance B verbatim" "$MD" "cleanest seam"
assert_contains "the two-poles rationale survives (it invites a third sketch)" "$MD" "Two poles, not three"
assert_contains "the open-questions gate still HALTs" "$MD" "1-ba-open-questions"
assert_contains "the design-lock gate still HALTs" "$MD" "2.5-design-owner-decision"
assert_contains "the experiment-mode carve-out survives" "$MD" "Experiment runs never block"
assert_contains "design-lock still forbids self-answering" "$MD" "progress tick wearing a costume"
assert_contains "the absent-owner_decision branch exists (schema cannot catch it)" \
  "$MD" "key is absent entirely"

# ---------------------------------------------------------------------------
suite "the phase strings the gates write are valid status.json values"

# status.schema.json is in NO AGENT_RULES entry and the walker does not implement `pattern`,
# so nothing checks a phase string at runtime. A typo here ships silently.
PHASE_RE='^([0-5](\.5)?-[a-z0-9-]+|halted-error)$'
for p in "1-ba-open-questions" "2.5-design-owner-decision" "2.5-design-complete"; do
  if [[ "$p" =~ $PHASE_RE ]]; then
    assert_eq "phase string '$p' matches status.schema.json's pattern" "ok" "ok"
  else
    assert_eq "phase string '$p' matches status.schema.json's pattern" "NO MATCH" "ok"
  fi
done
# CONTROL: the pattern must be able to reject, or the loop above proves nothing.
if [[ "1_ba_open_questions" =~ $PHASE_RE ]]; then
  assert_eq "CONTROL: the phase pattern rejects an underscored string" "matched" "rejected"
else
  assert_eq "CONTROL: the phase pattern rejects an underscored string" "rejected" "rejected"
fi

finish
