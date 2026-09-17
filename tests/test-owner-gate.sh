#!/usr/bin/env bash
# owner-gate.mjs: the Phase 1 open-questions gate and the Phase 2.5 design-lock (#164 rows 12, 13).
#
# Before this, both gates were prose the orchestrator reasoned through, and the only mechanical
# hold was a grep that the instruction was still written down. These cells run the decision:
# every exit code, the ba_default write, the experiment carve-out, and the wrong-run refusal.

. "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
require_node

OG="$SCRIPTS_DIR/owner-gate.mjs"
P1="$PLUGIN_ROOT/orchestrator/phase-1-ba.md"
P25="$PLUGIN_ROOT/orchestrator/phase-2.5-design.md"

make_temp_project 4243 || exit 90
SPEC="$TEMP_ISSUE_DIR/spec.json"
DESIGN="$TEMP_ISSUE_DIR/design.json"
ST="$TEMP_ISSUE_DIR/status.json"
printf '{"issue_number":4243,"current_phase":"1-ba"}' > "$ST"

og() {
  ( cd "$TEMP_PROJECT" && node "$OG" "$@" ) >"$TEMP_PROJECT/o" 2>"$TEMP_PROJECT/e"
  RC=$?
  OUT=$(cat "$TEMP_PROJECT/o")
  ERR=$(cat "$TEMP_PROJECT/e")
}
jget() { node -e 'const j=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));const v=process.argv[2].split(".").reduce((o,k)=>o==null?o:o[k],j);console.log(v===undefined?"undefined":JSON.stringify(v))' "$1" "$2"; }

HEAD='"issue_number":4243,"title":"t","problem":"p","requirements":["r"],"acceptance_criteria":["a"],"impacted_domains":["api"],"trivial":false'
spec() { printf '{%s%s}' "$HEAD" "${1:+,$1}" > "$SPEC"; }
Q_NB='{"id":"q1","question":"q1?","why_it_matters":"w","ba_recommendation":"rec1","blocking":false}'
Q_B2='{"id":"q2","question":"q2?","why_it_matters":"w","ba_recommendation":"rec2","blocking":true}'
Q_B3='{"id":"q3","question":"q3?","why_it_matters":"w","ba_recommendation":"rec3","blocking":true}'

suite "open-questions: proceed"

spec ''
og open-questions --spec "$SPEC" --status "$ST"
assert_eq "no open_questions: exit 0" "$RC" "0"
assert_contains "and says PROCEED" "$OUT" "PROCEED"
spec '"open_questions":[]'
og open-questions --spec "$SPEC" --status "$ST"
assert_eq "an empty array: exit 0" "$RC" "0"

spec "\"open_questions\":[$Q_NB]"
og open-questions --spec "$SPEC" --status "$ST"
assert_eq "a non-blocking question: exit 0" "$RC" "0"
assert_eq "and its resolution is written as ba_default" "$(jget "$SPEC" open_questions.0.resolution.answered_by)" '"ba_default"'
assert_eq "with the recommendation as the answer" "$(jget "$SPEC" open_questions.0.resolution.answer)" '"rec1"'
assert_contains "and a timestamp" "$(jget "$SPEC" open_questions.0.resolution.at)" "T"
assert_contains "and it says which it defaulted" "$OUT" "DEFAULTED: q1"
AFTER1="$(cat "$SPEC")"
og open-questions --spec "$SPEC" --status "$ST"
assert_eq "a second run leaves a resolved spec byte-identical" "$(cat "$SPEC")" "$AFTER1"

suite "open-questions: ask the owner, one question at a time"

spec "\"open_questions\":[$Q_NB,$Q_B2,$Q_B3]"
og open-questions --spec "$SPEC" --status "$ST"
assert_eq "a blocking question: exit 2" "$RC" "2"
assert_contains "and it asks the FIRST blocking one" "$OUT" '"id":"q2"'
assert_not_contains "and not the second" "$OUT" '"id":"q3"'
assert_contains "and says one more remains" "$OUT" "REMAINING: 1"
assert_eq "the non-blocking one is still defaulted on the way" "$(jget "$SPEC" open_questions.0.resolution.answered_by)" '"ba_default"'
assert_eq "and the blocking one is NOT answered for the owner" "$(jget "$SPEC" open_questions.1.resolution)" "undefined"

node -e 'const f=process.argv[1];const j=JSON.parse(require("fs").readFileSync(f,"utf8"));j.open_questions[1].resolution={answer:"a",answered_by:"owner",at:"2026-01-01T00:00:00Z"};require("fs").writeFileSync(f,JSON.stringify(j))' "$SPEC"
og open-questions --spec "$SPEC" --status "$ST"
assert_eq "after the owner answers q2, the gate asks q3 (exit 2)" "$RC" "2"
assert_contains "q3 now" "$OUT" '"id":"q3"'
node -e 'const f=process.argv[1];const j=JSON.parse(require("fs").readFileSync(f,"utf8"));j.open_questions[2].resolution={answer:"b",answered_by:"owner",at:"2026-01-01T00:00:00Z"};require("fs").writeFileSync(f,JSON.stringify(j))' "$SPEC"
og open-questions --spec "$SPEC" --status "$ST"
assert_eq "with every blocking question answered: exit 0" "$RC" "0"
assert_eq "and the owner's answer is kept, not overwritten by a default" "$(jget "$SPEC" open_questions.1.resolution.answered_by)" '"owner"'

suite "open-questions: experiment runs never block"

spec "\"open_questions\":[$Q_B2]"
og open-questions --spec "$SPEC" --status "$ST" --experiment
assert_eq "--experiment with a blocking question: exit 0" "$RC" "0"
assert_eq "and it is resolved to ba_default" "$(jget "$SPEC" open_questions.0.resolution.answered_by)" '"ba_default"'
printf '{"issue_number":"exp-owner-gate","title":"t","problem":"p","requirements":["r"],"acceptance_criteria":["a"],"impacted_domains":["api"],"trivial":false,"open_questions":[%s]}' "$Q_B2" > "$SPEC"
printf '{"issue_number":null}' > "$TEMP_PROJECT/st-exp.json"
og open-questions --spec "$SPEC" --status "$TEMP_PROJECT/st-exp.json"
assert_eq "an exp-<slug> spec is experiment mode without the flag: exit 0" "$RC" "0"
spec "\"open_questions\":[$Q_B2]"
og open-questions --spec "$SPEC" --status "$ST"
assert_eq "CONTROL: the same blocking question without the flag, on a numbered issue, still blocks" "$RC" "2"

suite "open-questions: invalid spec"

printf '{"issue_number":4243,"title":"t","problem":"p","requirements":["r"],"impacted_domains":["api"],"trivial":false}' > "$SPEC"
og open-questions --spec "$SPEC" --status "$ST"
assert_eq "a missing acceptance_criteria: exit 2" "$RC" "2"
assert_contains "and it names the field" "$OUT" "INVALID: missing or empty: acceptance_criteria"
printf '{"issue_number":4243,"title":"  ","problem":"p","requirements":["r"],"acceptance_criteria":["a"],"impacted_domains":["api"]}' > "$SPEC"
og open-questions --spec "$SPEC" --status "$ST"
assert_contains "a blank title and a missing trivial are both named" "$OUT" "title, trivial"
assert_eq "trivial: false is present, not missing (CONTROL on the falsy value)" \
  "$(spec ''; og open-questions --spec "$SPEC" --status "$ST"; printf '%s' "$RC")" "0"
spec '"open_questions":[{"id":"q9","question":"q","why_it_matters":"w","ba_recommendation":" ","blocking":false}]'
og open-questions --spec "$SPEC" --status "$ST"
assert_eq "a non-blocking question with no recommendation cannot be defaulted: exit 2" "$RC" "2"
assert_contains "and it names the question" "$OUT" "open_questions[q9].ba_recommendation"

suite "open-questions: a resolution the gate may stand on"

for R in '{}' '{"answered_by":"ba_default"}' '{"answer":"  ","answered_by":"owner","at":"2026-01-01T00:00:00Z"}' '{"answer":"a","answered_by":"owner"}' '{"answer":"a","answered_by":"someone","at":"2026-01-01T00:00:00Z"}'; do
  spec "\"open_questions\":[{\"id\":\"q5\",\"question\":\"q\",\"why_it_matters\":\"w\",\"ba_recommendation\":\"rec\",\"blocking\":true,\"resolution\":$R}]"
  og open-questions --spec "$SPEC" --status "$ST"
  assert_eq "REGRESSION: a blocking question with resolution $R is not resolved: exit 2" "$RC" "2"
  assert_contains "  and it is named INVALID, not silently accepted ($R)" "$OUT" "INVALID: missing or empty: open_questions[q5].resolution"
done
spec "\"open_questions\":[{\"id\":\"q5\",\"question\":\"q\",\"why_it_matters\":\"w\",\"ba_recommendation\":\"rec\",\"blocking\":false,\"resolution\":{}}]"
og open-questions --spec "$SPEC" --status "$ST"
assert_eq "an empty resolution on a NON-blocking question is not overwritten by a default either: exit 2" "$RC" "2"
assert_eq "  and the spec is left as it was" "$(jget "$SPEC" open_questions.0.resolution)" "{}"
for B in '"true"' 'null' '1'; do
  spec "\"open_questions\":[{\"id\":\"q6\",\"question\":\"q\",\"why_it_matters\":\"w\",\"ba_recommendation\":\"rec\",\"blocking\":$B}]"
  og open-questions --spec "$SPEC" --status "$ST"
  assert_eq "REGRESSION: blocking $B is rejected, not defaulted: exit 2" "$RC" "2"
  assert_contains "  and named ($B)" "$OUT" "open_questions[q6].blocking (not a boolean)"
  assert_eq "  and no default was written ($B)" "$(jget "$SPEC" open_questions.0.resolution)" "undefined"
done
spec "\"open_questions\":[{\"id\":\"q7\",\"question\":\"q\",\"why_it_matters\":\"w\",\"blocking\":false}]"
og open-questions --spec "$SPEC" --status "$ST"
assert_eq "CONTROL: a missing ba_recommendation still halts a normal run: exit 2" "$RC" "2"

suite "open-questions: an experiment run with no recommendation proceeds"

spec "\"open_questions\":[{\"id\":\"q8\",\"question\":\"q\",\"why_it_matters\":\"w\",\"blocking\":true},$Q_NB]"
og open-questions --spec "$SPEC" --status "$ST" --experiment
assert_eq "REGRESSION: an experiment run with a blocking question and no ba_recommendation: exit 0" "$RC" "0"
assert_contains "and records it as unresolved" "$OUT" "UNRESOLVED: q8"
assert_eq "and writes no invented resolution for it" "$(jget "$SPEC" open_questions.0.resolution)" "undefined"
assert_eq "while the question that has a recommendation is still defaulted" "$(jget "$SPEC" open_questions.1.resolution.answered_by)" '"ba_default"'

suite "open-questions: usage and the wrong run"

spec ''
printf '{"issue_number":999}' > "$TEMP_PROJECT/st-other.json"
og open-questions --spec "$SPEC" --status "$TEMP_PROJECT/st-other.json"
assert_eq "a status naming a different issue: exit 1" "$RC" "1"
assert_contains "and it says wrong artifact" "$ERR" "wrong artifact"
og open-questions --spec "$SPEC"
assert_eq "no --status: exit 1" "$RC" "1"
og open-questions --spec "$TEMP_PROJECT/nope.json" --status "$ST"
assert_eq "an unreadable spec: exit 1" "$RC" "1"
og bogus
assert_eq "an unknown subcommand: exit 1" "$RC" "1"

suite "design-lock"

design() { printf '{"issue_number":4243,"chosen_approach":{"summary":"s"}%s}' "${1:+,$1}" > "$DESIGN"; }
FULL='"required":true,"question":"which?","option_a":"A","option_b":"B","recommendation":"A because"'

design ''
og design-lock --design "$DESIGN" --status "$ST"
assert_eq "owner_decision absent: exit 3 (re-dispatch the judge)" "$RC" "3"
assert_contains "and it says so" "$OUT" "REDISPATCH_JUDGE: owner_decision is absent"
design '"owner_decision":{"required":"yes"}'
og design-lock --design "$DESIGN" --status "$ST"
assert_eq "required not a boolean: exit 3" "$RC" "3"
design '"owner_decision":{"required":false}'
og design-lock --design "$DESIGN" --status "$ST"
assert_eq "required false: exit 0" "$RC" "0"
design '"owner_decision":{"required":true,"question":"which?","option_a":"A","option_b":"","recommendation":"A"}'
og design-lock --design "$DESIGN" --status "$ST"
assert_eq "required true with an empty option_b: exit 3" "$RC" "3"
assert_contains "and it names the gap" "$OUT" "option_b missing or empty"
design '"owner_decision":{"required":true,"question":"which?"}'
og design-lock --design "$DESIGN" --status "$ST"
assert_contains "every gap is named" "$OUT" "option_a, option_b, recommendation"
design "\"owner_decision\":{$FULL}"
og design-lock --design "$DESIGN" --status "$ST"
assert_eq "required true and complete, unresolved: exit 2 (ask the owner)" "$RC" "2"
assert_contains "and the block is printed for the decision" "$OUT" '"option_a":"A"'
design "\"owner_decision\":{$FULL,\"resolution\":{\"chosen\":\"option_b\",\"reasoning\":\"r\",\"resolved_at\":\"2026-01-01T00:00:00Z\"}}"
og design-lock --design "$DESIGN" --status "$ST"
assert_eq "required true and resolved: exit 0" "$RC" "0"
design "\"owner_decision\":{$FULL,\"resolution\":{\"chosen\":\"\",\"reasoning\":\"r\"}}"
og design-lock --design "$DESIGN" --status "$ST"
assert_eq "a resolution with no choice is not resolved: exit 2" "$RC" "2"
design "\"owner_decision\":{$FULL,\"resolution\":{\"chosen\":\"option_b\",\"resolved_at\":\"2026-01-01T00:00:00Z\"}}"
og design-lock --design "$DESIGN" --status "$ST"
assert_eq "REGRESSION: a resolution without the owner's reasoning is not resolved: exit 2" "$RC" "2"
design "\"owner_decision\":{$FULL,\"resolution\":{\"chosen\":\"option_b\",\"reasoning\":\"   \",\"resolved_at\":\"2026-01-01T00:00:00Z\"}}"
og design-lock --design "$DESIGN" --status "$ST"
assert_eq "a blank reasoning is not reasoning: exit 2" "$RC" "2"
design "\"owner_decision\":{$FULL,\"resolution\":{\"chosen\":\"whatever\",\"reasoning\":\"r\",\"resolved_at\":\"2026-01-01T00:00:00Z\"}}"
og design-lock --design "$DESIGN" --status "$ST"
assert_eq "a choice outside option_a/option_b/variant is not resolved: exit 2" "$RC" "2"
design '"owner_decision":{"required":false}'
og design-lock --design "$DESIGN" --status "$TEMP_PROJECT/st-other.json"
assert_eq "a status naming a different issue: exit 1" "$RC" "1"
og design-lock --design "$DESIGN"
assert_eq "no --status: exit 1" "$RC" "1"

suite "the prose calls the gates, and the removed decision prose stays removed"

M1="$(cat "$P1")"
M25="$(cat "$P25")"
assert_contains "phase-1-ba.md runs the open-questions gate" "$M1" 'scripts/owner-gate.mjs" open-questions --spec'
assert_contains "phase-1-ba.md still writes the halt phase" "$M1" '"1-ba-open-questions"'
assert_not_contains "the required-field list is gone from the prose" "$M1" "Validate required fields present"
assert_not_contains "the ba_default write rule is gone from the prose" "$M1" "For each entry with \`blocking: false\`"
assert_not_contains "the experiment paragraph is gone from the prose" "$M1" "Experiment runs never block"
assert_contains "phase-2.5-design.md runs design-lock" "$M25" 'scripts/owner-gate.mjs" design-lock --design'
assert_contains "phase-2.5-design.md still writes the halt phase" "$M25" '"2.5-design-owner-decision"'
assert_contains "phase-1-ba.md halts on any exit other than 0 or 2" "$M1" "Any exit other than 0 or 2: halt and show the owner the output."
assert_contains "phase-2.5-design.md halts on any other exit" "$M25" "**Any other exit**: halt and show the owner the output."
assert_contains "phase-2-lite.md halts on any other exit" "$(cat "$PLUGIN_ROOT/orchestrator/phase-2-lite.md")" "Any other exit but 0: halt and show the owner the output."
assert_not_contains "the absent-key branch is gone from the prose" "$M25" "key is absent entirely"
assert_not_contains "the incomplete-block branch is gone from the prose" "$M25" "any of \`question\`, \`option_a\`, \`option_b\`, \`recommendation\` is missing"

finish
