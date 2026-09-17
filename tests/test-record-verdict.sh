#!/usr/bin/env bash
# record-verdict.mjs -- the Phase 4 verdict, its record and its loop target (#164 rows 8 and 9).
#
# WHY. The five-row rubric, the verdict counts and the loop-back table were applied by hand beside
# code (finalVerdict, countVerdicts, round-budget.mjs) that already computed them, and the counts
# were taken over the delta subset. Every cell RUNS the command on a fixture; the verdict mapping,
# the exit codes, the full-panel count, the loop target and the budget line are each pinned with
# a control that differs in one input.

. "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
require_node

RV="$SCRIPTS_DIR/record-verdict.mjs"
CP="$SCRIPTS_DIR/checkpoint.mjs"
pipeline_md_concat "$PLUGIN_ROOT" || exit 90
PIPELINE_MD="$PIPELINE_MD_CONCAT"
PHASE_MD="$PLUGIN_ROOT/commands/phase.md"

make_temp_project 9 || exit 90
ST="$TEMP_ISSUE_DIR/status.json"
PR="$TEMP_PROJECT/peer-review.json"
BODY="$TEMP_PROJECT/pr-summary.md"

run() {  # run <script> <args...> -> RC, OUT, ERR
  local s="$1"; shift
  local outf="$TEMP_PROJECT/out.txt" errf="$TEMP_PROJECT/err.txt"
  ( cd "$TEMP_PROJECT" && CLAUDE_PROJECT_DIR="$TEMP_PROJECT" node "$s" "$@" ) >"$outf" 2>"$errf"
  RC=$?
  OUT=$(cat "$outf")
  ERR=$(cat "$errf")
}
rv() { run "$RV" --status "$ST" --peer-review "$PR" "$@"; }
status() { printf '%s' "$1" > "$ST"; }
st4() { printf '{"current_phase":"4-review","started_at":"2026-09-01T00:00:00Z","updated_at":"2026-09-01T00:00:00Z","branch":"b","issue_number":9,"events":[],"review_rounds":1,"schema_version":2,"fix_rounds":0,"spec_revisions":0%s}' "${1:-}"; }
jget() { node -e 'const j=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));const v=process.argv[2].split(".").reduce((o,k)=>o==null?o:o[k],j);console.log(v===undefined?"undefined":JSON.stringify(v))' "$1" "$2"; }
sum() { node -e 'console.log(require("crypto").createHash("sha1").update(require("fs").readFileSync(process.argv[1])).digest("hex"))' "$1"; }
stp() { status "$(st4 "$PANEL")"; }
jst() { jget "$ST" "$1"; }
panel3() { printf '{"qa":%s,"secops":%s,"dev":%s}' "$1" "$2" "$3" > "$PR"; }
line() { printf '%s\n' "$OUT" | grep "^$1=" | head -1; }

blk() { printf '{"verdict":"%s","materiality":{"open_blocker_ids":[%s],"blocks_merge":%s}}' "$1" "$2" "$3"; }
A=$(blk APPROVE "" false)
N=$(blk APPROVE_WITH_NOTES "" false)
RC_=$(blk REQUEST_CHANGES '"qa-1"' true)
RF=$(blk REQUEST_REFACTOR '"qa-2"' true)
VT='{"verdict":"VETO","veto_ground":"auth","materiality":{"open_blocker_ids":["secops-1"],"blocks_merge":true}}'
DEMOTED='{"verdict":"APPROVE_WITH_NOTES","verdict_as_returned":"REQUEST_CHANGES","materiality":{"open_blocker_ids":[],"blocks_merge":false}}'
PANEL=',"panel_roles":["qa","secops","dev"],"risk_tier":"standard","cost_class":"product"'

suite "the verdict mapping and the exit codes"
# The exit code is the orchestrator's branch, so each verdict is driven end to end through the CLI
# rather than through finalVerdict() alone. The rubric reads materiality.blocks_merge, not the verdict
# word, which is why the demoted REQUEST_CHANGES below is the control that keeps this cell honest.

verdict_case() {  # <label> <qa block> <secops block> <expected verdict> <expected rc>
  stp
  panel3 "$2" "$3" "$A"
  rv
  assert_eq "$1 -> $4, exit $5" "$(line final_verdict)/$RC" "final_verdict=$4/$5"
}
verdict_case "all APPROVE" "$A" "$A" APPROVE 0
verdict_case "one APPROVE_WITH_NOTES" "$N" "$A" APPROVE_WITH_NOTES 0
verdict_case "a blocking REQUEST_CHANGES" "$RC_" "$A" REQUEST_CHANGES 3
verdict_case "a blocking REQUEST_REFACTOR outranks REQUEST_CHANGES" "$RC_" "$RF" REQUEST_REFACTOR 3
verdict_case "a blocking VETO outranks everything" "$RF" "$VT" SECOPS_VETO 4
verdict_case "CONTROL: a REQUEST_CHANGES demoted to a note (blocks_merge false) does not block" "$DEMOTED" "$A" APPROVE_WITH_NOTES 0
verdict_case "the legacy alias APPROVE_WITH_NITS reads as notes" '{"verdict":"APPROVE_WITH_NITS"}' "$A" APPROVE_WITH_NOTES 0

suite "the record: one write through checkpoint.mjs"
# The verdict, its counts, the 4-review exit event and the phase land in ONE write. That is what keeps
# gate-phase-entry.mjs's 4-review-complete row unreachable, and it is what lets telemetry count the round
# from the event rather than from a hand-maintained counter that disagreed on five of seven records.

stp
panel3 "$RC_" "$A" "$N"
rv --note "delta re-review: qa"
assert_eq "current_phase is 4-review-complete" "$(jst current_phase)" '"4-review-complete"'
assert_eq "final_verdict is written" "$(jst final_verdict)" '"REQUEST_CHANGES"'
assert_eq "peer_review_verdict_counts is written" "$(jst peer_review_verdict_counts)" '{"approve":1,"approve_with_notes":1,"request_changes":1,"request_refactor":0,"veto":0}'
assert_eq "the 4-review exit event carries the panel verdict" "$(jst events.0.phase)/$(jst events.0.verdict)" '"4-review"/"REQUEST_CHANGES"'
assert_eq "  and the delta note" "$(jst events.0.note)" '"delta re-review: qa"'
assert_eq "the counter agrees with the observed rounds after the verdict is recorded" "$(jst telemetry.review_rounds_recorded_delta)" "0"
assert_eq "  so no delta line is printed" "$(line review_rounds_recorded_delta)" ""
stp
panel3 "$A" "$VT" "$A"
rv --veto-reason "session token logged"
assert_eq "a veto parks at 4-veto-rework-required" "$(jst current_phase)" '"4-veto-rework-required"'
assert_eq "  with veto_reason" "$(jst veto_reason)" '"session token logged"'
assert_eq "  and its event verdict is the panel token VETO, which telemetry counts as a round" "$(jst events.0.verdict)/$(jst telemetry.review_rounds_observed)" '"VETO"/1'

suite "counts over the FULL panel_roles, never a delta subset"
# A delta round re-dispatches a subset, and the tally used to be taken over that subset. The panel is
# whatever status.json recorded on the first round; a shard left behind by a role nobody seated counts
# for nothing, and a seated role with no verdict at all is a halt, never a quiet zero.

status "$(st4 ',"panel_roles":["ba","dev","qa","secops","dba"],"risk_tier":"standard"')"
printf '{"ba":%s,"dev":%s,"qa":%s,"secops":%s,"dba":%s,"devops":%s}' "$A" "$A" "$N" "$A" "$A" "$RC_" > "$PR"
rv
assert_eq "all five seated roles are counted; a block for an UNSEATED role is not" "$(jst peer_review_verdict_counts)" '{"approve":4,"approve_with_notes":1,"request_changes":0,"request_refactor":0,"veto":0}'
assert_eq "  and cannot block the verdict" "$(line final_verdict)" "final_verdict=APPROVE_WITH_NOTES"
stp
printf '{"qa":%s,"secops":%s}' "$A" "$A" > "$PR"
BEFORE="$(sum "$ST")"
rv
assert_eq "a seated role with no verdict is exit 1 with nothing written" "$RC/$(sum "$ST")" "1/$BEFORE"
assert_contains "  naming the role" "$ERR" "dev"
status "$(st4 ',"panel_roles":[]')"
rv
assert_eq "an empty panel_roles is exit 1" "$RC" "1"
stp
printf '{nope' > "$PR"
rv
assert_eq "an unreadable peer-review.json is exit 1" "$RC" "1"
run "$RV" --status "$ST"
assert_eq "a missing --peer-review is a usage error" "$RC" "1"

suite "next= and the budget line: the loop-back table as code"
# The loop target used to be a table row read by hand, with the budget numbers restated beside it in
# six places. Here the target comes from the verdict and the tier, and the budget from round-budget.mjs
# itself, so a change to either constant moves this output without any prose having to follow it.

stp
panel3 "$N" "$A" "$A"
rv
assert_eq "APPROVE_WITH_NOTES -> next=merge, no budget line" "$(line next)|$(line budget)" "next=merge|"
panel3 "$RC_" "$A" "$A"
stp
rv
assert_eq "REQUEST_CHANGES -> next=dev" "$(line next)" "next=dev"
assert_eq "  with the fix-round budget from round-budget.mjs (product: round 1 of 2)" "$(line budget)" "budget=fix-round round=1 of=2 allowed=yes"
status "$(st4 ',"panel_roles":["qa","secops","dev"],"cost_class":"tooling","fix_rounds":1')"
rv
assert_eq "tooling, round 2: the budget line says allowed=no" "$(line budget)" "budget=fix-round round=2 of=1 allowed=no"
assert_contains "  and the owner decision block follows" "$OUT" "### I need a decision"
assert_eq "  and the exit code is still the verdict's, 3" "$RC" "3"
status "$(st4 ',"panel_roles":["qa","secops","dev"],"cost_class":"tooling","fix_rounds":1,"risk_tier":"architectural","owner_overrides":[{"kind":"fix-round","up_to":2,"at":"2026-09-01T00:00:00Z"}]')"
rv
assert_eq "architectural, a fix round past the budget the OWNER chose -> next=judge then=dev" "$(line next)|$(line then)|$(line budget)" "next=judge|then=dev|budget=fix-round round=2 of=1 allowed=override"
status "$(st4 ',"panel_roles":["qa","secops","dev"],"cost_class":"tooling","fix_rounds":1,"risk_tier":"standard","owner_overrides":[{"kind":"fix-round","up_to":2,"at":"2026-09-01T00:00:00Z"}]')"
rv
assert_eq "CONTROL: the same override below the architectural tier has no design to re-open -> next=dev" "$(line next)|$(line then)" "next=dev|"
panel3 "$A" "$VT" "$A"
stp
rv
assert_eq "SECOPS_VETO -> next=ba with the spec-revision budget" "$(line next)|$(line then)|$(line budget)" "next=ba||budget=spec-revision round=1 of=2 allowed=yes"
status "$(st4 ',"panel_roles":["qa","secops","dev"],"risk_tier":"architectural"')"
rv
assert_eq "SECOPS_VETO at the architectural tier -> then=judge" "$(line next)|$(line then)" "next=ba|then=judge"

suite "--pr-body: one row per panel role, the unseated lenses named"
# The owner reads this table on the PR. A trimmed panel must say which lenses were not seated, and a
# verdict the materiality rule demoted must still show what the reviewer actually returned.

stp
panel3 "$RC_" "$A" "$DEMOTED"
rv --pr-body "$BODY"
B="$(cat "$BODY")"
assert_contains "the heading names the tier" "$B" "## Phase 4 Peer Review (standard tier panel)"
assert_contains "a blocking role lists its open blocker ids" "$B" "| QA | REQUEST_CHANGES | qa-1 |"
assert_contains "a standing approval has no blockers" "$B" "| SecOps | APPROVE | - |"
assert_contains "a demoted verdict shows what the reviewer returned" "$B" "| Dev | APPROVE_WITH_NOTES (returned REQUEST_CHANGES) | - |"
assert_contains "the trimmed lenses are named, never ambiguous" "$B" "Not on panel (standard tier): BA, DBA, DevOps"
assert_contains "and the final verdict" "$B" "**Final verdict:** REQUEST_CHANGES"
status "$(st4 ',"panel_roles":["ba","dba","devops","secops","dev","qa","design_review"],"risk_tier":"architectural"')"
printf '{"ba":%s,"dba":%s,"devops":%s,"secops":%s,"dev":%s,"qa":%s,"design_review":%s}' "$A" "$A" "$A" "$A" "$A" "$A" "$N" > "$PR"
rv --pr-body "$BODY"
assert_not_contains "CONTROL: a full architectural panel has no Not-on-panel line" "$(cat "$BODY")" "Not on panel"
assert_contains "  and Design is a row" "$(cat "$BODY")" "| Design | APPROVE_WITH_NOTES | - |"

suite "the loop, end to end: enter, verdict, loop back, delta, verdict, refused"
# The two scripts together, in the order the orchestrator runs them on a tooling issue: the first fix
# round is inside the budget, the second is not, and the refusal leaves the record exactly as it was.

status '{"current_phase":"3-impl-complete","started_at":"2026-09-01T00:00:00Z","updated_at":"2026-09-01T00:00:00Z","branch":"b","issue_number":9,"events":[],"panel_roles":["qa","secops","dev"],"cost_class":"tooling","risk_tier":"standard","final_verdict":"REQUEST_CHANGES"}'
panel3 "$RC_" "$A" "$A"
run "$CP" enter 4-review --status "$ST" --exit-verdict GATE_PASSED
assert_eq "round 1 enters with the stale verdict cleared" "$RC/$(jst final_verdict)/$(jst review_rounds)" "0/null/1"
rv
assert_eq "round 1 records REQUEST_CHANGES, exit 3, next=dev" "$RC/$(line next)" "3/next=dev"
run "$CP" enter 3-impl --status "$ST" --loopback
assert_eq "the loop-back spends fix round 1 and clears the verdict" "$RC/$(jst fix_rounds)/$(jst final_verdict)" "0/1/null"
run "$CP" enter 4-review --status "$ST" --exit-verdict FIX_ROUND_COMPLETE --exit-phase 3-impl
rv --note "delta re-review: qa"
assert_eq "round 2 records again, and the counter matches the events" "$RC/$(jst review_rounds)/$(jst telemetry.review_rounds_recorded_delta)" "3/2/0"
assert_eq "  and the budget line already says the next round needs the owner" "$(line budget)" "budget=fix-round round=2 of=1 allowed=no"
BEFORE="$(sum "$ST")"
run "$CP" enter 3-impl --status "$ST" --loopback
assert_eq "so the loop-back is refused, with nothing written" "$RC/$(sum "$ST")" "2/$BEFORE"

suite "the prose calls the script, and the rubric, the table and the numbers stay removed"
# Removed prose tends to come back as a helpful restatement. These cells fail the day the rubric, the
# hand count, the Phase 4 loop-back rows or a budget number reappear beside the command that owns them.

CONCAT="$(cat "$PIPELINE_MD")"
assert_contains "phase-4-verdict.md runs record-verdict.mjs" "$CONCAT" \
  'node "${CLAUDE_PLUGIN_ROOT}/scripts/record-verdict.mjs" --status "$PIPELINE_BASE/<issue>/status.json" --peer-review "$ARTIFACT_DIR/peer-review.json"'
assert_contains "phase-4-delta.md records the delta verdict through it" "$CONCAT" 'Record the verdict with `record-verdict.mjs`'
assert_contains "loop-backs.md acts on next= with the loop-back command" "$CONCAT" 'checkpoint.mjs" enter <target> --status "$PIPELINE_BASE/<issue>/status.json" --loopback --commit'
for gone in \
  '### Final verdict rubric (strict precedence, first match wins)' \
  '### After computing `final_verdict`' \
  '| Agent | Verdict | Blockers |' \
  'Verdict-name normalization:' \
  'via a `node -e` one-liner against the `countVerdicts` export' \
  'Apply the final-verdict rubric in `phase-4-verdict.md` over the FULL panel' \
  '| SecOps `VETO` (valid `veto_ground` AND a blocking concern) |' \
  '| Any `REQUEST_CHANGES` with `blocks_merge`' \
  '| `REQUEST_REFACTOR` with `blocks_merge` (testability) |' \
  'Two are allowed at every cost class' \
  'round-budget.mjs" enter fix-round' \
  'round-budget.mjs" enter spec-revision'; do
  assert_not_contains "removed from the orchestrator prose: $gone" "$CONCAT" "$gone"
done
# The budget NUMBERS: prose cites round-budget.mjs, never a restated budget.
for f in "$PIPELINE_MD" "$PHASE_MD" "$PLUGIN_ROOT/agents/ba.md"; do
  assert_eq "no restated fix-round budget in $(basename "$f")" \
    "$(grep -cE 'tooling[` ]*1, *`?product`? *2|Budget: `tooling` 1' "$f" | tr -d ' ')" "0"
done
assert_contains "the budgets are cited by name instead" "$CONCAT" '`FIX_ROUND_BUDGET`'

finish
