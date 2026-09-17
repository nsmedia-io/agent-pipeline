#!/usr/bin/env bash
# checkpoint.mjs -- the status.json checkpoint as one command (#164 rows 2 and 22).
#
# WHY. The durable-checkpoint convention, the #110 verdict clear, the review_rounds increment, the
# telemetry refresh, the verdict and summary caps, the phase pattern, the checkpoint commit and
# the /phase rerun token were all prose the orchestrator applied by hand. Every cell below RUNS
# the script against a fixture record, and each refusal has a control beside it that differs in
# one input, so a script that refuses everything fails here as loudly as one that refuses nothing.

. "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
require_node

CP="$SCRIPTS_DIR/checkpoint.mjs"
pipeline_md_concat "$PLUGIN_ROOT" || exit 90
PIPELINE_MD="$PIPELINE_MD_CONCAT"
PHASE_MD="$PLUGIN_ROOT/commands/phase.md"

make_temp_project 9 || exit 90
ST="$TEMP_ISSUE_DIR/status.json"

# cp_run <args...> -> RC, OUT, ERR (cwd is the temp project, so no real config is read)
cp_run() {
  local outf="$TEMP_PROJECT/out.txt" errf="$TEMP_PROJECT/err.txt"
  ( cd "$TEMP_PROJECT" && CLAUDE_PROJECT_DIR="$TEMP_PROJECT" node "$CP" "$@" ) >"$outf" 2>"$errf"
  RC=$?
  OUT=$(cat "$outf")
  ERR=$(cat "$errf")
}
status() { printf '%s' "$1" > "$ST"; }
base() { printf '{"current_phase":"%s","started_at":"2026-09-01T00:00:00Z","updated_at":"2026-09-01T00:00:00Z","branch":"b","issue_number":9,"events":[]%s}' "$1" "${2:-}"; }
jget() { node -e 'const j=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));const v=process.argv[2].split(".").reduce((o,k)=>o==null?o:o[k],j);console.log(v===undefined?"undefined":JSON.stringify(v))' "$1" "$2"; }
sum() { node -e 'console.log(require("crypto").createHash("sha1").update(require("fs").readFileSync(process.argv[1])).digest("hex"))' "$1"; }

suite "enter: the exit event and the entry phase are ONE write"

status "$(base 0-setup)"
cp_run enter 1-ba --status "$ST" --exit-verdict OK --note "setup clean"
assert_eq "enter exits 0" "$RC" "0"
assert_eq "current_phase is the phase ENTERED" "$(jget "$ST" current_phase)" '"1-ba"'
assert_eq "the exit event closes the PRIOR phase" "$(jget "$ST" events.0.phase)" '"0-setup"'
assert_eq "  with its verdict" "$(jget "$ST" events.0.verdict)" '"OK"'
assert_eq "  and its note" "$(jget "$ST" events.0.note)" '"setup clean"'
assert_eq "updated_at is refreshed" "$([[ "$(jget "$ST" updated_at)" != '"2026-09-01T00:00:00Z"' ]] && echo fresh || echo stale)" "fresh"
assert_eq "the first write sets schema_version 2" "$(jget "$ST" schema_version)" "2"
assert_eq "  and fix_rounds 0" "$(jget "$ST" fix_rounds)" "0"
assert_eq "  and spec_revisions 0" "$(jget "$ST" spec_revisions)" "0"
assert_eq "telemetry is refreshed in the same write" "$(jget "$ST" telemetry.events_counted)" "1"
assert_eq "effective_config is refreshed in the same write" "$([[ "$(jget "$ST" effective_config.migration_globs_gate)" == "["* ]] && echo present || echo absent)" "present"

status "$(base 1-ba-complete)"
cp_run enter 2-review --status "$ST" --exit-verdict SPEC_CREATED
assert_eq "a -complete prior phase closes under its base label" "$(jget "$ST" events.0.phase)" '"1-ba"'
status "$(base 1-ba-complete)"
cp_run enter 2-review --status "$ST" --exit-verdict SPEC_CREATED --exit-phase 1-ba-size-ruling
assert_eq "--exit-phase names the closed phase explicitly" "$(jget "$ST" events.0.phase)" '"1-ba-size-ruling"'
status "$(base 2-review)"
cp_run enter 2.5-design --status "$ST"
assert_eq "CONTROL: no --exit-verdict appends no event" "$(jget "$ST" events)" "[]"
assert_eq "  but still enters the phase" "$(jget "$ST" current_phase)" '"2.5-design"'
status '{"started_at":"x","updated_at":"x","branch":"b","events":[]}'
cp_run enter 1-ba --status "$ST" --exit-verdict OK
assert_eq "an exit verdict with no phase to close and no --exit-phase is a usage error" "$RC" "1"
status "$(base 1-ba ',"schema_version":2,"fix_rounds":1,"spec_revisions":2')"
cp_run enter 2-review --status "$ST"
assert_eq "CONTROL: existing counters are never reset" "$(jget "$ST" fix_rounds)/$(jget "$ST" spec_revisions)" "1/2"

suite "enter: #110, final_verdict is cleared on 4-review and on every loop-back, and only there"

status "$(base 3-impl-complete ',"final_verdict":"REQUEST_CHANGES","peer_review_verdict_counts":{"approve":1}')"
cp_run enter 4-review --status "$ST" --exit-verdict GATE_PASSED
assert_eq "entering 4-review clears final_verdict" "$(jget "$ST" final_verdict)" "null"
assert_eq "  and peer_review_verdict_counts, in the same write" "$(jget "$ST" peer_review_verdict_counts)" "null"
status "$(base 4-review-complete ',"final_verdict":"REQUEST_CHANGES","peer_review_verdict_counts":{"approve":1}')"
cp_run enter 3-impl --status "$ST" --loopback
assert_eq "a loop-back into 3-impl clears final_verdict (the archive-43 shape)" "$(jget "$ST" final_verdict)" "null"
assert_eq "  and the counts" "$(jget "$ST" peer_review_verdict_counts)" "null"
status "$(base 4-review-complete ',"final_verdict":"SECOPS_VETO"')"
cp_run enter 2.5-design --status "$ST" --loopback
assert_eq "a loop-back to the judge clears it too" "$(jget "$ST" final_verdict)" "null"
status "$(base 4-review-complete ',"final_verdict":"APPROVE"')"
cp_run enter 5-archive --status "$ST" --exit-verdict APPROVE --exit-phase 4-review-merge
assert_eq "CONTROL: a forward entry that is not 4-review keeps the verdict" "$(jget "$ST" final_verdict)" '"APPROVE"'

suite "enter: review_rounds counts panel rounds"

status "$(base 3-impl-complete)"
cp_run enter 4-review --status "$ST"
assert_eq "the first panel round is review_rounds 1" "$(jget "$ST" review_rounds)" "1"
cp_run enter 4-review --status "$ST"
assert_eq "a re-checkpoint of the SAME 4-review (resume) is not a new round" "$(jget "$ST" review_rounds)" "1"
status "$(base 3-impl-complete ',"review_rounds":1')"
cp_run enter 4-review --status "$ST"
assert_eq "a delta round adds one" "$(jget "$ST" review_rounds)" "2"
status "$(base 2-review ',"review_rounds":1')"
cp_run enter 2.5-design --status "$ST"
assert_eq "CONTROL: entering any other phase leaves it alone" "$(jget "$ST" review_rounds)" "1"
assert_eq "telemetry.review_rounds follows the counter" "$(jget "$ST" telemetry.review_rounds)" "1"

suite "enter --loopback: the round is counted against round-budget.mjs, or refused with nothing written"

status "$(base 4-review-complete ',"cost_class":"tooling","fix_rounds":0,"schema_version":2')"
cp_run enter 3-impl --status "$ST" --loopback
assert_eq "tooling fix round 1: exit 0" "$RC" "0"
assert_eq "  and fix_rounds is 1" "$(jget "$ST" fix_rounds)" "1"
assert_contains "  and the output names the round and its budget" "$OUT" "fix_rounds 1 of 1"
status "$(base 4-review-complete ',"cost_class":"tooling","fix_rounds":1,"schema_version":2,"final_verdict":"REQUEST_CHANGES"')"
BEFORE="$(sum "$ST")"
cp_run enter 3-impl --status "$ST" --loopback --commit
assert_eq "tooling fix round 2 with no override: REFUSED, exit 2" "$RC" "2"
assert_eq "  and NOTHING was written (not the counter, not the clear, not the phase)" "$(sum "$ST")" "$BEFORE"
assert_contains "  and stdout carries the owner decision block" "$OUT" "### I need a decision"
assert_contains "  and stderr says nothing was written" "$ERR" "nothing was written"
status "$(base 4-review-complete ',"cost_class":"tooling","fix_rounds":1,"schema_version":2,"owner_overrides":[{"kind":"fix-round","up_to":2,"at":"2026-09-01T00:00:00Z","reason":"owner"}]')"
cp_run enter 3-impl --status "$ST" --loopback
assert_eq "CONTROL: the same round covered by an owner override is allowed" "$RC/$(jget "$ST" fix_rounds)" "0/2"
assert_contains "  and says so" "$OUT" "owner override"
status "$(base 4-review-complete ',"cost_class":"product","fix_rounds":1,"schema_version":2')"
cp_run enter 3-impl --status "$ST" --loopback
assert_eq "CONTROL: product fix round 2 is inside its budget" "$RC/$(jget "$ST" fix_rounds)" "0/2"
status "$(base 2-review ',"spec_revisions":0,"schema_version":2')"
cp_run enter 1-ba --status "$ST" --loopback --exit-verdict REQUEST_CHANGES
assert_eq "a loop-back into 1-ba spends a spec revision" "$RC/$(jget "$ST" spec_revisions)" "0/1"
status "$(base 2-review ',"spec_revisions":2,"schema_version":2')"
cp_run enter 1-ba --status "$ST" --loopback
assert_eq "the spec revision past the budget is refused" "$RC/$(jget "$ST" spec_revisions)" "2/2"
status "$(base 4-review-complete ',"fix_rounds":7,"spec_revisions":7,"schema_version":2')"
cp_run enter 2.5-design --status "$ST" --loopback
assert_eq "a loop-back to the judge counts nothing and is never refused" "$RC/$(jget "$ST" fix_rounds)/$(jget "$ST" spec_revisions)" "0/7/7"
status "$(base 4-review-complete ',"fix_rounds":"two"')"
cp_run enter 3-impl --status "$ST" --loopback
assert_eq "an unreadable counter refuses the loop-back" "$RC" "2"
status "$(base 4-review-complete ',"cost_class":"tooling","fix_rounds":1')"
cp_run enter 3-impl --status "$ST"
assert_eq "CONTROL: without --loopback (a gate re-entry) nothing is counted" "$RC/$(jget "$ST" fix_rounds)" "0/1"

suite "enter: the schema cap and the phase pattern refuse before anything is written"

V32="ABCDEFGHIJKLMNOPQRSTUVWXYZ_12345"; V33="${V32}6"
status "$(base 1-ba)"
BEFORE="$(sum "$ST")"
cp_run enter 2-review --status "$ST" --exit-verdict "$V33"
assert_eq "a 33-char exit verdict is REFUSED, exit 2" "$RC" "2"
assert_eq "  with nothing written" "$(sum "$ST")" "$BEFORE"
assert_contains "  naming the cap" "$ERR" "cap of 32"
cp_run enter 2-review --status "$ST" --exit-verdict "$V32"
assert_eq "CONTROL: a 32-char verdict is at the cap and accepted" "$RC" "0"
for bad in banana 3-Impl "4-review complete" "6-ship"; do
  status "$(base 1-ba)"
  BEFORE="$(sum "$ST")"
  cp_run enter "$bad" --status "$ST"
  assert_eq "phase '$bad' fails the schema pattern: exit 2, nothing written" "$RC/$(sum "$ST")" "2/$BEFORE"
done
for good in 0.5-map 2.5-design-owner-decision 3-impl-gate-failed halted-error; do
  status "$(base 1-ba)"
  cp_run enter "$good" --status "$ST"
  assert_eq "CONTROL: '$good' matches the pattern" "$RC" "0"
done
status "$(base 1-ba ",\"flags\":[{\"phase\":\"1-ba\",\"agent\":\"ba\",\"verdict\":\"$V33\",\"at\":\"x\"}]")"
BEFORE="$(sum "$ST")"
cp_run enter 2-review --status "$ST"
assert_eq "an over-cap verdict ALREADY in the record (a stale cp) is refused on the next write" "$RC/$(sum "$ST")" "2/$BEFORE"
assert_contains "  through check-status-record's own walk" "$ERR" "check-status-record"
printf '{not json' > "$ST"
cp_run enter 2-review --status "$ST"
assert_eq "an unreadable record is exit 1" "$RC" "1"
cp_run enter 2-review --status "$TEMP_PROJECT/nope.json"
assert_eq "a missing record is exit 1" "$RC" "1"
cp_run enter --status "$ST"
assert_eq "enter with no phase is a usage error" "$RC" "1"
cp_run enter 1-ba --status "$ST" --bogus
assert_eq "an unknown flag is a usage error" "$RC" "1"

suite "flag: the verdict cap refuses, the summary cap cuts"

status "$(base 2-review)"
LONG="$(printf 'x%.0s' $(seq 1 200))"
cp_run flag --status "$ST" --phase 2-secops --agent secops --verdict APPROVE_WITH_NOTES --summary "$LONG"
assert_eq "flag exits 0" "$RC" "0"
assert_eq "an over-cap summary is cut to exactly the schema's 140" "$(node -e 'const j=JSON.parse(require("fs").readFileSync(process.argv[1]));console.log([...j.flags[0].summary].length)' "$ST")" "140"
assert_contains "  ending in an ellipsis" "$(jget "$ST" flags.0.summary)" "…"
cp_run flag --status "$ST" --phase 2-dba --agent dba --verdict APPROVE
assert_eq "a verdict-only agent gets summary \"\"" "$(jget "$ST" flags.1.summary)" '""'
BEFORE="$(sum "$ST")"
cp_run flag --status "$ST" --phase 2-dba --agent dba --verdict "$V33"
assert_eq "an over-cap flag verdict is REFUSED with nothing written" "$RC/$(sum "$ST")" "2/$BEFORE"
cp_run flag --status "$ST" --agent dba
assert_eq "flag with no --phase is a usage error" "$RC" "1"

suite "rerun: the /phase role to its token-prefixed label"

for pair in ba:1-ba-rerun dba:2-review-rerun devops:2-review-rerun secops:2-review-rerun design-review:2-review-rerun qa:3a-qa-rerun dev:3b-dev-rerun peer-review:4-review-rerun librarian:5-archive-rerun; do
  cp_run rerun "${pair%%:*}"
  assert_eq "/phase ${pair%%:*} -> ${pair#*:}" "$RC/$OUT" "0/${pair#*:}"
done
for role in dba devops secops design-review qa; do
  cp_run rerun "$role" --panel
  assert_eq "/phase $role --panel -> 4-review-rerun" "$OUT" "4-review-rerun"
done
cp_run rerun ba --panel
assert_eq "CONTROL: --panel does not move a role with no panel re-run" "$OUT" "1-ba-rerun"
cp_run rerun architect
assert_eq "an unknown role is exit 1, never a guessed label" "$RC/$OUT" "1/"
EVERY_TOKEN_RESOLVES="$(SCRIPTS="$SCRIPTS_DIR" node --input-type=module -e '
  const c = await import(process.env.SCRIPTS + "/checkpoint.mjs");
  const t = await import(process.env.SCRIPTS + "/pipeline-telemetry.mjs");
  const bad = Object.values(c.RERUN_TOKENS).filter((x) => t.phaseKey(x) === null);
  console.log(bad.length ? "UNRESOLVED " + bad.join(",") : "all resolve");')"
assert_eq "every rerun label resolves through phaseKey, so the phase-entry guard can read it" "$EVERY_TOKEN_RESOLVES" "all resolve"
status "$(base 4-review-complete)"
cp_run rerun ba --status "$ST" --verdict SPEC_REWORKED --note "veto rework"
assert_eq "rerun --status appends the event" "$(jget "$ST" events.0.phase)/$(jget "$ST" events.0.verdict)" '"1-ba-rerun"/"SPEC_REWORKED"'
assert_eq "  and does not move current_phase" "$(jget "$ST" current_phase)" '"4-review-complete"'
cp_run rerun ba --status "$ST"
assert_eq "rerun --status with no --verdict is a usage error" "$RC" "1"

suite "--commit: the checkpoint commit stages ONLY status.json"

REPO="$TEMP_PROJECT/repo"
mkdir -p "$REPO/.pipeline/9"
git -C "$REPO" init -q
git -C "$REPO" config user.email t@t; git -C "$REPO" config user.name t
printf 'x\n' > "$REPO/other.txt"
git -C "$REPO" add other.txt && git -C "$REPO" commit -q -m base
printf 'y\n' > "$REPO/other.txt"; git -C "$REPO" add other.txt
printf '{"transient":1}' > "$REPO/.pipeline/9/spec.json"
base 2-review > "$REPO/.pipeline/9/status.json"
cp_run enter 2.5-design --status "$REPO/.pipeline/9/status.json" --exit-verdict APPROVE --commit
assert_eq "enter --commit exits 0" "$RC" "0"
assert_contains "  and reports the commit" "$OUT" "committed"
assert_eq "the commit touches exactly status.json" "$(git -C "$REPO" show --name-only --format= HEAD)" ".pipeline/9/status.json"
assert_eq "  with the checkpoint message" "$(git -C "$REPO" log -1 --format=%s)" "chore(pipeline): checkpoint phase 2.5-design for #9"
assert_eq "a file someone else staged stays staged and uncommitted" "$(git -C "$REPO" diff --cached --name-only)" "other.txt"
assert_eq "  and the committed record is the written one" "$(git -C "$REPO" show HEAD:.pipeline/9/status.json | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).current_phase))')" "2.5-design"
NOGIT="$TEMP_PROJECT/nogit/.pipeline/9"; mkdir -p "$NOGIT"
base 2-review > "$NOGIT/status.json"
cp_run enter 2.5-design --status "$NOGIT/status.json" --commit
assert_eq "outside a repository the write lands but the commit fails loudly, exit 1" "$RC/$(jget "$NOGIT/status.json" current_phase)" '1/"2.5-design"'
assert_contains "  saying WRITTEN but NOT committed" "$ERR" "WRITTEN but NOT committed"

suite "qa-contract (row 22): commit and satisfiability, then the record"

git -C "$REPO" add other.txt && git -C "$REPO" commit -q -m "test: contract"
SHA="$(git -C "$REPO" rev-parse HEAD)"
TASKS="$TEMP_PROJECT/tasks.json"
GOOD='{"satisfiability_proof":{"reference_impl_run":true,"criteria_proven":["AC1"],"criteria_unproven":[],"configs_run":["tests/run.sh"]}}'
status "$(base 3-impl)"
printf '%s' "$GOOD" > "$TASKS"
BEFORE="$(sum "$ST")"
cp_run qa-contract --sha deadbeef1234 --tasks "$TASKS" --status "$ST" --worktree "$REPO"
assert_eq "a sha naming no commit is REFUSED with nothing written" "$RC/$(sum "$ST")" "2/$BEFORE"
assert_contains "  and says do NOT dispatch Dev" "$ERR" "do NOT dispatch Dev"
cp_run qa-contract --sha "main; echo x" --tasks "$TASKS" --status "$ST" --worktree "$REPO"
assert_eq "a non-hex sha is refused before git sees it" "$RC" "2"
for bad in '{"satisfiability_proof":{"reference_impl_run":true,"criteria_proven":[],"criteria_unproven":[],"configs_run":["a"]}}' \
           '{"satisfiability_proof":{"reference_impl_run":false,"criteria_proven":["AC1"],"configs_run":["a"]}}' \
           '{"satisfiability_proof":{"reference_impl_run":true,"criteria_proven":["AC1"],"configs_run":[]}}' \
           '{"tasks":[]}'; do
  printf '%s' "$bad" > "$TASKS"
  cp_run qa-contract --sha "$SHA" --tasks "$TASKS" --status "$ST" --worktree "$REPO"
  assert_eq "an unsatisfiable-or-unproven contract is refused, nothing written: $(printf '%s' "$bad" | cut -c1-60)" "$RC/$(sum "$ST")" "2/$BEFORE"
done
assert_contains "  and the reason cites #158" "$ERR" "#158"
cp_run qa-contract --sha "$SHA" --tasks "$TEMP_PROJECT/absent.json" --status "$ST" --worktree "$REPO"
assert_eq "an ABSENT tasks.json is refused, not failed open" "$RC" "2"
printf '%s' '{"satisfiability_proof":{"reference_impl_run":false,"criteria_proven":[],"criteria_unproven":[{"criterion":"AC2","reason":"needs live db"}],"configs_run":["a"]}}' > "$TASKS"
cp_run qa-contract --sha "${SHA:0:10}" --tasks "$TASKS" --status "$ST" --worktree "$REPO"
assert_eq "CONTROL: criteria_unproven with reasons satisfies the check" "$RC" "0"
assert_eq "  and the FULL sha is recorded" "$(jget "$ST" phase3_qa_test_commit)" "\"$SHA\""
assert_eq "  with a qa flags entry" "$(jget "$ST" flags.0.agent)/$(jget "$ST" flags.0.verdict)" '"qa"/"CONTRACT_AUTHORED"'

suite "the prose calls the script (and the removed prose stays removed)"

CONCAT="$(cat "$PIPELINE_MD")"
for phase in 0.5-map 1-ba 2-constraints 2-review 2.5-design 3-impl 4-review 5-archive; do
  assert_eq "the $phase checkpoint line is a checkpoint.mjs call" \
    "$(grep -c "Checkpoint first.*checkpoint.mjs enter $phase --exit-verdict" "$PIPELINE_MD" | tr -d ' ')" "1"
done
assert_eq "no Checkpoint-first line tells the orchestrator to set current_phase by hand" \
  "$(grep -c 'Checkpoint first:\*\* set `current_phase' "$PIPELINE_MD" | tr -d ' ')" "0"
assert_contains "status-record.md documents the one enter command" "$CONCAT" \
  'node "${CLAUDE_PLUGIN_ROOT}/scripts/checkpoint.mjs" enter <phase> --status "$PIPELINE_BASE/<issue>/status.json" --exit-verdict'
for gone in \
  'git add .pipeline/<issue>/status.json' \
  'git commit -m "chore(pipeline): checkpoint phase <n> for #<issue>"' \
  'Strict 140-char cap; truncate with ellipsis if longer' \
  'Rules for `verdict` (the same rule governs' \
  'import(process.env.CLAUDE_PLUGIN_ROOT+"/scripts/pipeline-telemetry.mjs")' \
  'increment `review_rounds` (1 on the first full panel, +1 per delta round)' \
  'on the first write of a run also set `schema_version: 2`' \
  'Set both to `null`; do not leave the previous round' \
  'When you set `current_phase` to the Dev implementation step for a `REQUEST_REFACTOR`' \
  'git -C <WORKTREE_PATH> show --stat <sha>' \
  '**Read `<ARTIFACT_DIR>/tasks.json` `satisfiability_proof` (#158).**'; do
  assert_not_contains "removed from the orchestrator prose: $gone" "$CONCAT" "$gone"
done
assert_not_contains "phase.md no longer spells the rerun mapping by hand" "$(cat "$PHASE_MD")" '`3b-dev-rerun` for `/phase dev`'
assert_contains "phase.md appends the rerun event through the script" "$(cat "$PHASE_MD")" 'checkpoint.mjs" rerun <phase name>'
assert_contains "phase-3-architectural.md records the QA contract through the script" "$CONCAT" 'checkpoint.mjs" qa-contract --sha <sha> --tasks'

# The documented command is the command that runs: extracted from the recipe and EXECUTED.
DOC_CMD="$(sed -n '/^### Durable checkpoint convention/,/^\*\*After each agent/p' "$PIPELINE_MD" | grep '^node .*checkpoint.mjs" enter' | head -1)"
assert_eq "VACUITY: a runnable enter line was extracted from the recipe" "$([[ -n "$DOC_CMD" ]] && echo extracted || echo MISSING)" "extracted"
DOC_CMD="${DOC_CMD//\$\{CLAUDE_PLUGIN_ROOT\}/$PLUGIN_ROOT}"
DOC_CMD="${DOC_CMD//\$PIPELINE_BASE\/<issue>/$TEMP_PROJECT/.pipeline/9}"
DOC_CMD="${DOC_CMD//<phase>/2.5-design}"
DOC_CMD="${DOC_CMD//<verdict token of the phase closing>/$V33}"
DOC_CMD="${DOC_CMD// --commit/}"
status "$(base 2-review)"
DOC_RUN="$( cd "$TEMP_PROJECT" && eval "$DOC_CMD" 2>&1; printf '|%s' "$?" )"
assert_eq "THE DOCUMENTED COMMAND RUNS, and refuses an over-cap verdict" "${DOC_RUN##*|}" "2"
DOC_CMD="${DOC_CMD//$V33/APPROVE}"
DOC_RUN="$( cd "$TEMP_PROJECT" && eval "$DOC_CMD" 2>&1; printf '|%s' "$?" )"
assert_eq "GATE BITES, the other half: the same command with a token verdict exits 0" "${DOC_RUN##*|}" "0"

finish
