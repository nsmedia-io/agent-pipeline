#!/usr/bin/env bash
# validate-pipeline-artifact.mjs — the deliberately fail-OPEN SubagentStop validator.
#
# Two layers are covered here, and they are different jobs:
#   (1) The script's own 56-case --self-test, WIRED IN rather than re-implemented. It already
#       covers the pure functions (schema walk, active-issue resolution, grounding); copying
#       those assertions into bash would duplicate them badly and let the two drift. Until this
#       change it ran under nothing: not CI, not the Stop hook, not an adopting project.
#   (2) The PROCESS contract the self-test cannot reach: the stdin payload, the stdout shape
#       the hook consumes, and the fail-open exit-0 guarantee. A validator that exits non-zero
#       (or prints garbage) wedges a legitimate subagent stop.
#
# Hermeticity: pipelineDirs UNIONS [payload.cwd, CLAUDE_PROJECT_DIR, process.cwd()] and
# enumerates EVERY root that exists, so pinning only one of the three would still let a case
# read this checkout's live .pipeline/ mid-pipeline. All three are pinned to the temp tree.

. "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
require_node

VALIDATOR="$SCRIPTS_DIR/validate-pipeline-artifact.mjs"
ISSUE=4242

make_temp_project "$ISSUE" || exit 90

# hook <payload-json> -> RC, OUT (stdout: what the hook actually consumes), ERR
hook() {
  local outf="$TEMP_PROJECT/out.txt" errf="$TEMP_PROJECT/err.txt"
  printf '%s' "$1" \
    | ( cd "$TEMP_PROJECT" && CLAUDE_PROJECT_DIR="$TEMP_PROJECT" node "$VALIDATOR" ) \
      >"$outf" 2>"$errf"
  RC=$?
  OUT=$(cat "$outf")
  ERR=$(cat "$errf")
}

printf '%s' '{"current_phase":"3"}' > "$TEMP_ISSUE_DIR/status.json"
# The report claims this file was touched; grounding checks that the claim is corroborated by
# the tree, so it must actually exist under the temp worktree root.
mkdir -p "$TEMP_PROJECT/src"
printf '%s' 'export const x = 1;' > "$TEMP_PROJECT/src/x.ts"

VALID_REPORT='{
  "issue_number": 4242,
  "branch": "feat/script-coverage",
  "commits": [{"sha": "a1", "message": "m", "files_changed": ["src/x.ts"]}],
  "checks_passed": {"typecheck": true, "test": true, "lint": true},
  "completed_at": "2026-01-01T00:00:00Z",
  "requirement_checks": [
    {"requirement_index": 0, "requirement_text": "AC1 handled", "status": "PASS", "notes": "n"}
  ],
  "acceptance_criteria_met": [{"criterion": "AC1: the courier roster rotates", "met": true, "evidence": "test"}],
  "qa_signoff": {"acceptance_mapping": [{"criterion": "AC1", "test": "roster rotation case"}], "verdict": "APPROVE"}
}'

PAYLOAD_DEV="{\"agent_type\":\"dev\",\"cwd\":\"$TEMP_PROJECT\",\"active_issue\":\"$ISSUE\"}"

suite "validate-pipeline-artifact: the shipped 56-case self-test runs under checkCommand"

( cd "$TEMP_PROJECT" && CLAUDE_PROJECT_DIR="$TEMP_PROJECT" node "$VALIDATOR" --self-test ) \
  > "$TEMP_PROJECT/selftest.out" 2>&1
SELFTEST_RC=$?
assert_eq "node validate-pipeline-artifact.mjs --self-test exits 0" "$SELFTEST_RC" "0"
assert_contains "the self-test reports zero failures" "$(cat "$TEMP_PROJECT/selftest.out")" "0 failed"

suite "validate-pipeline-artifact: process contract (stdin -> stdout decision)"

printf '%s' "$VALID_REPORT" > "$TEMP_ISSUE_DIR/impl-report.json"
hook "$PAYLOAD_DEV"
assert_eq "a valid artifact allows the stop (exit 0)" "$RC" "0"
assert_eq "a valid artifact writes NOTHING to stdout" "$OUT" ""

# The block shape is a hook contract: Claude Code reads a top-level decision:"block" on stdout.
# A schema violation must still exit 0 -- the block is carried by the payload, not the code.
printf '%s' '{
  "issue_number": 4242,
  "branch": "feat/script-coverage",
  "commits": [],
  "checks_passed": {"typecheck": true, "test": true},
  "completed_at": "2026-01-01T00:00:00Z",
  "requirement_checks": [
    {"requirement_index": 0, "requirement_text": "AC1 handled", "status": "PASS", "notes": "n"}
  ]
}' > "$TEMP_ISSUE_DIR/impl-report.json"
hook "$PAYLOAD_DEV"
assert_eq "a schema-violating artifact STILL exits 0 (fail open)" "$RC" "0"
assert_contains "it emits a top-level decision:block" "$OUT" '"decision":"block"'
assert_contains "the reason names the offending artifact" "$OUT" "impl-report.json"
# The reason travels inside a JSON string, so the quoting is escaped on the wire. Asserting
# the escaped form is deliberate: it pins the stdout BYTES the hook consumes, not a
# pretty-printed rendering of them.
assert_contains "the reason names the specific violation" "$OUT" 'missing required field \"lint\"'
assert_contains "the reason names the field's location" "$OUT" "/checks_passed"
assert_contains "the reason tells the agent what to do" "$OUT" "Fix the artifact before finishing"

# An unparseable artifact is a block, not a crash: JSON.parse failures are reported as a
# violation of the artifact, never allowed to throw out of the hook.
printf '%s' '{"issue_number": }' > "$TEMP_ISSUE_DIR/impl-report.json"
hook "$PAYLOAD_DEV"
assert_eq "an unparseable artifact still exits 0" "$RC" "0"
assert_contains "an unparseable artifact blocks" "$OUT" '"decision":"block"'
assert_contains "and says it is not valid JSON" "$OUT" "not valid JSON"

printf '%s' "$VALID_REPORT" > "$TEMP_ISSUE_DIR/impl-report.json"

suite "validate-pipeline-artifact: fail-OPEN guarantees"

hook 'not json at all {{{'
assert_eq "a garbled payload exits 0" "$RC" "0"
assert_eq "a garbled payload emits nothing" "$OUT" ""

hook ''
assert_eq "an empty payload exits 0" "$RC" "0"
assert_eq "an empty payload emits nothing" "$OUT" ""

hook "{\"agent_type\":\"wizard\",\"cwd\":\"$TEMP_PROJECT\",\"active_issue\":\"$ISSUE\"}"
assert_eq "an unknown agent_type exits 0" "$RC" "0"
assert_eq "an unknown agent_type emits nothing" "$OUT" ""

hook "{\"cwd\":\"$TEMP_PROJECT\",\"active_issue\":\"$ISSUE\"}"
assert_eq "a payload with no agent_type exits 0" "$RC" "0"
assert_eq "a payload with no agent_type emits nothing" "$OUT" ""

# An agent whose artifact is simply absent is not a failure: agents stop mid-phase all the
# time, and blocking on absence would wedge every one of them.
hook "{\"agent_type\":\"librarian\",\"cwd\":\"$TEMP_PROJECT\",\"active_issue\":\"$ISSUE\"}"
assert_eq "an agent with no artifact written yet exits 0" "$RC" "0"
assert_eq "an agent with no artifact written yet emits nothing" "$OUT" ""

finish
