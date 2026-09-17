#!/usr/bin/env bash
# round-budget.mjs -- the review-loop budget counted in code (review convergence).
#
# WHY. "One fix round by default, a second is the owner's call" was prose for several releases,
# and nothing counted. Measured on one consumer: one tooling issue ran 21 spec revisions and 8
# Phase 4 panel rounds. So the pins here are the refusal AND its lifting, in both directions:
# a budget that refuses everything is as broken as one that refuses nothing, and an override
# that covers every later round is an off-switch wearing a decision's name.

. "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
require_node

RB="$SCRIPTS_DIR/round-budget.mjs"
PIPELINE_MD="$PLUGIN_ROOT/commands/pipeline.md"
PHASE_MD="$PLUGIN_ROOT/commands/phase.md"

make_temp_project || exit 90
ST="$TEMP_PROJECT/status.json"
SPEC="$TEMP_PROJECT/spec.json"

# rb <args...> -> RC, OUT, ERR
rb() {
  local outf="$TEMP_PROJECT/out.txt" errf="$TEMP_PROJECT/err.txt"
  ( cd "$TEMP_PROJECT" && node "$RB" "$@" ) >"$outf" 2>"$errf"
  RC=$?
  OUT=$(cat "$outf")
  ERR=$(cat "$errf")
}
status() { printf '%s' "$1" > "$ST"; }
jget() { node -e 'const j=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));const v=process.argv[2].split(".").reduce((o,k)=>o==null?o:o[k],j);console.log(v===undefined?"undefined":JSON.stringify(v))' "$1" "$2"; }

suite "round-budget: the fix-round budget per cost_class"

status '{"issue_number":7,"cost_class":"tooling","fix_rounds":0,"schema_version":2}'
rb check fix-round --status "$ST"
assert_eq "tooling: fix round 1 is allowed" "$RC" "0"
status '{"issue_number":7,"cost_class":"tooling","fix_rounds":1,"schema_version":2}'
rb check fix-round --status "$ST"
assert_eq "tooling: fix round 2 is REFUSED with exit 2" "$RC" "2"
assert_contains "and the refusal names the budget and the cost class" "$ERR" "the budget at cost_class tooling is 1"
assert_contains "and stdout carries the owner decision block" "$OUT" "### I need a decision"
assert_contains "offering ship with deferrals" "$OUT" "Ship with deferrals"
assert_contains "and split" "$OUT" "Split"
assert_contains "and stop" "$OUT" "Stop"
assert_contains "and it says how the owner's 'keep going' is recorded" "$OUT" '"kind": "fix-round", "up_to": 2'
assert_not_contains "the decision block carries no em dash (voice.md)" "$OUT" "$(printf '\342\200\224')"
for cc in product product-money; do
  status "{\"cost_class\":\"$cc\",\"fix_rounds\":1}"
  rb check fix-round --status "$ST"
  assert_eq "$cc: fix round 2 is allowed" "$RC" "0"
  status "{\"cost_class\":\"$cc\",\"fix_rounds\":2}"
  rb check fix-round --status "$ST"
  assert_eq "$cc: fix round 3 is REFUSED" "$RC" "2"
done

suite "round-budget: an owner override lifts exactly the rounds it covers"

status '{"cost_class":"tooling","fix_rounds":1,"owner_overrides":[{"kind":"fix-round","up_to":2,"at":"2026-09-16T10:00:00Z","reason":"ship date"}]}'
rb check fix-round --status "$ST"
assert_eq "an override up_to 2 allows tooling fix round 2" "$RC" "0"
assert_contains "and says the override covered it" "$OUT" "covered by the owner override recorded at 2026-09-16T10:00:00Z"
status '{"cost_class":"tooling","fix_rounds":2,"owner_overrides":[{"kind":"fix-round","up_to":2,"at":"2026-09-16T10:00:00Z"}]}'
rb check fix-round --status "$ST"
assert_eq "CONTROL: the same override does NOT cover round 3" "$RC" "2"
status '{"cost_class":"tooling","fix_rounds":1,"owner_overrides":[{"kind":"spec-revision","up_to":9,"at":"2026-09-16T10:00:00Z"}]}'
rb check fix-round --status "$ST"
assert_eq "an override of the OTHER kind does not lift a fix round" "$RC" "2"
status '{"cost_class":"tooling","fix_rounds":1,"owner_overrides":[{"kind":"fix-round","up_to":2}]}'
rb check fix-round --status "$ST"
assert_eq "an override with no 'at' is not a recorded decision and lifts nothing" "$RC" "2"

suite "round-budget: enter records the round, and refuses without writing"

status '{"issue_number":7,"cost_class":"product","fix_rounds":0}'
rb enter fix-round --status "$ST"
assert_eq "enter exits 0 inside the budget" "$RC" "0"
assert_eq "and writes fix_rounds 1" "$(jget "$ST" fix_rounds)" "1"
assert_eq "and stamps schema_version 2" "$(jget "$ST" schema_version)" "2"
assert_eq "and keeps the rest of the record" "$(jget "$ST" issue_number)" "7"
rb enter fix-round --status "$ST"
assert_eq "a second enter at product exits 0" "$RC" "0"
assert_eq "and writes fix_rounds 2" "$(jget "$ST" fix_rounds)" "2"
rb enter fix-round --status "$ST"
assert_eq "a third enter at product is REFUSED" "$RC" "2"
assert_eq "and the refusal did NOT write the counter" "$(jget "$ST" fix_rounds)" "2"

suite "round-budget: spec revisions after Phase 2 (2 at every cost class)"

for cc in tooling product product-money; do
  status "{\"cost_class\":\"$cc\",\"spec_revisions\":1}"
  rb enter spec-revision --status "$ST"
  assert_eq "$cc: spec revision 2 is allowed" "$RC" "0"
  rb enter spec-revision --status "$ST"
  assert_eq "$cc: spec revision 3 is REFUSED" "$RC" "2"
  assert_contains "$cc: and the block explains a spec that keeps changing" "$OUT" "revised 2 time(s)"
done
status '{"cost_class":"product","spec_revisions":2,"owner_overrides":[{"kind":"spec-revision","up_to":3,"at":"2026-09-16T10:00:00Z"}]}'
rb enter spec-revision --status "$ST"
assert_eq "an owner override allows spec revision 3" "$RC" "0"
assert_eq "and records it" "$(jget "$ST" spec_revisions)" "3"

suite "round-budget: a legacy record, and inputs it cannot read"

status '{"issue_number":7}'
rb check fix-round --status "$ST"
assert_eq "a record with no cost_class and no counter reads as product round 1 (allowed)" "$RC" "0"
assert_contains "and says it defaulted the cost class" "$ERR" "no cost_class; reading it as product"
assert_contains "and says it counted from 0" "$ERR" "counting from 0"
status '{"fix_rounds":"two"}'
rb check fix-round --status "$ST"
assert_eq "a non-integer counter is REFUSED (exit 2), never an allow" "$RC" "2"
assert_contains "  and still brings the owner the decision block" "$OUT" "### I need a decision"
status '{"issue_number":7,"cost_class":"tooling","fix_rounds":null}'
rb enter fix-round --status "$ST"
assert_eq "REVIEW REPRO: fix_rounds null is REFUSED with exit 2, not a bare exit 1" "$RC" "2"
assert_contains "  and prints the owner decision block" "$OUT" "issue #7 cannot count its fix rounds"
assert_contains "  and says the counter is unreadable on stderr" "$ERR" "the counter is unreadable"
assert_eq "  and writes nothing" "$(jget "$ST" fix_rounds)" "null"
status '{"cost_class":"Tooling","fix_rounds":1}'
rb check fix-round --status "$ST"
assert_eq "a mixed-case Tooling is applied as tooling (round 2 refused)" "$RC" "2"
assert_contains "REVIEW REPRO: and the warning says tooling, the class actually applied" "$ERR" 'cost_class "Tooling" is not spelled as one of product-money, product, tooling; reading it as tooling'
assert_not_contains "  not product" "$ERR" "reading it as product"
rb check fix-round --status "$TEMP_PROJECT/missing.json"
assert_eq "an unreadable status is exit 1, never an allow" "$RC" "1"
rb check nonsense --status "$ST"
assert_eq "an unknown kind is a usage error" "$RC" "1"
rb check fix-round
assert_eq "a missing --status is exit 1" "$RC" "1"

suite "round-budget: a tooling spec over 12 acceptance criteria needs size_justification"

acs() { node -e 'console.log(JSON.stringify(Array.from({length:+process.argv[1]},(_,i)=>"AC"+(i+1)+". c")))' "$1"; }
printf '{"cost_class":"tooling","acceptance_criteria":%s}' "$(acs 13)" > "$SPEC"
rb spec-size --spec "$SPEC"
assert_eq "a tooling spec with 13 ACs and no justification is REFUSED" "$RC" "2"
assert_contains "and the refusal says what to do" "$ERR" "split it, cut it, or write size_justification"
printf '{"cost_class":"tooling","acceptance_criteria":%s}' "$(acs 12)" > "$SPEC"
rb spec-size --spec "$SPEC"
assert_eq "CONTROL: 12 ACs is allowed" "$RC" "0"
printf '{"cost_class":"tooling","acceptance_criteria":%s,"size_justification":"one gate, one table"}' "$(acs 13)" > "$SPEC"
rb spec-size --spec "$SPEC"
assert_eq "13 ACs WITH a justification is allowed" "$RC" "0"
printf '{"cost_class":"tooling","acceptance_criteria":%s,"size_justification":"   "}' "$(acs 13)" > "$SPEC"
rb spec-size --spec "$SPEC"
assert_eq "a blank justification does not count" "$RC" "2"
printf '{"cost_class":"product","acceptance_criteria":%s}' "$(acs 40)" > "$SPEC"
rb spec-size --spec "$SPEC"
assert_eq "CONTROL: a product spec over the count is not refused here (the validator warns)" "$RC" "0"
printf '{"acceptance_criteria":%s}' "$(acs 13)" > "$SPEC"
status '{"cost_class":"tooling"}'
rb spec-size --spec "$SPEC" --status "$ST"
assert_eq "a spec with no cost_class takes it from status.json" "$RC" "2"

suite "round-budget: the prose calls it at the fix-round and spec-revision points"

assert_contains "pipeline.md counts a fix round before dispatching Dev" "$(cat "$PIPELINE_MD")" \
  'round-budget.mjs" enter fix-round --status "$PIPELINE_BASE/<issue>/status.json"'
assert_contains "pipeline.md counts a spec revision before looping back to BA" "$(cat "$PIPELINE_MD")" \
  'round-budget.mjs" enter spec-revision --status "$PIPELINE_BASE/<issue>/status.json"'
assert_contains "pipeline.md refuses an oversized tooling spec after BA returns" "$(cat "$PIPELINE_MD")" \
  'round-budget.mjs" spec-size --spec "$PIPELINE_BASE/<issue>/spec.json"'
assert_contains "phase.md's manual re-review is held to the same fix-round count" "$(cat "$PHASE_MD")" \
  'round-budget.mjs" enter fix-round --status'
assert_eq "the old prose-only 'ONE round by default' row is gone" \
  "$(grep -c 'ONE round by default' "$PIPELINE_MD" | tr -d ' ')" "0"
assert_eq "checkRoundBudget is exported for a gate to call" \
  "$(RB="$RB" node --input-type=module -e 'const m=await import(process.env.RB);console.log(typeof m.checkRoundBudget)')" "function"

finish
