#!/usr/bin/env bash
# validate-pipeline-artifact.mjs — the deliberately fail-OPEN SubagentStop validator.
#
# Two layers are covered here, and they are different jobs:
#   (1) The script's own --self-test, WIRED IN rather than re-implemented. It already
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

suite "validate-pipeline-artifact: the shipped self-test runs under checkCommand"

( cd "$TEMP_PROJECT" && CLAUDE_PROJECT_DIR="$TEMP_PROJECT" node "$VALIDATOR" --self-test ) \
  > "$TEMP_PROJECT/selftest.out" 2>&1
SELFTEST_RC=$?
SELFTEST_OUT=$(cat "$TEMP_PROJECT/selftest.out")

# The self-test names every case it runs, but this wrapper captured that output and threw it
# away, so a red here said only "4 failed" and never which four. That is issue #27: a gate that
# reddens without saying why is the gate that eventually gets switched off, and it cost a
# main-is-red investigation that could not proceed past the summary line. Echo the failing
# cases -- and ONLY on failure, so the ~60 ok lines do not drown the transcript.
if [ "$SELFTEST_RC" != "0" ]; then
  printf '%s\n' "--- self-test failing cases (issue #27) ---" >&2
  printf '%s\n' "$SELFTEST_OUT" | grep -iE '^[[:space:]]*(FAIL|not ok)' >&2 || \
    printf '%s\n' "(no FAIL-shaped line found; full output follows)" "$SELFTEST_OUT" >&2
  printf '%s\n' "--- end self-test failing cases ---" >&2
fi
assert_eq "node validate-pipeline-artifact.mjs --self-test exits 0" "$SELFTEST_RC" "0"

# This wrapper delegates 56 of the suite's cases, so it has to be able to tell 56 from ZERO.
# Exit 0 cannot: a self-test whose cases never ran prints "self-test: 0 passed, 0 failed" and
# exits 0. Neither can a substring test for "0 failed", which is also a substring of
# "10 failed". Both numbers are therefore parsed out of the summary line and compared as
# integers. The pass count is a FLOOR, not an equality, so ADDING a case to the self-test does
# not turn this red -- but removing them all does.
SELFTEST_PASSED=$(printf '%s' "$SELFTEST_OUT" | sed -n 's/^self-test: \([0-9][0-9]*\) passed, .*/\1/p')
SELFTEST_FAILED=$(printf '%s' "$SELFTEST_OUT" | sed -n 's/^self-test: [0-9][0-9]* passed, \([0-9][0-9]*\) failed$/\1/p')
assert_eq "the self-test prints a parseable summary line" \
  "$([[ -n "$SELFTEST_PASSED" && -n "$SELFTEST_FAILED" ]] && echo parsed || echo unparseable)" "parsed"
assert_eq "the self-test reports zero failures" "$SELFTEST_FAILED" "0"
assert_eq "the self-test actually RAN its case list (>= 56 passed, not 0)" \
  "$([[ "${SELFTEST_PASSED:-0}" -ge 56 ]] && echo ok || echo "only ${SELFTEST_PASSED:-0} ran")" "ok"

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

suite "validate-pipeline-artifact: a fail-open path SAYS it failed open (#66 property 2)"

# THE DEFECT, measured on the shipped hook at 856a5d0 before this change: an agent_type with no
# AGENT_RULES entry and an agent whose artifacts are genuinely CLEAN both produced 0 bytes of
# stdout and exit 0 -- byte-identical, so "I never checked" and "I checked and it was fine" were
# the same observation. stdout is asserted UNCHANGED here (it is the hook's decision channel and
# must stay pure JSON or nothing); the discrimination lives on stderr.
printf '%s' "$VALID_REPORT" > "$TEMP_ISSUE_DIR/impl-report.json"
hook "$PAYLOAD_DEV"
CLEAN_OUT="$OUT"; CLEAN_ERR="$ERR"
assert_eq "a clean run still writes nothing to stdout" "$CLEAN_OUT" ""
assert_contains "a clean run reports verdict=checked on stderr" "$CLEAN_ERR" "verdict=checked"
assert_contains "and names the issue dir it checked" "$CLEAN_ERR" "issue=$ISSUE"

hook "{\"agent_type\":\"art-director\",\"cwd\":\"$TEMP_PROJECT\",\"active_issue\":\"$ISSUE\"}"
assert_eq "an unregistered agent still writes nothing to stdout" "$OUT" ""
assert_contains "an unregistered agent reports verdict=no-rules on stderr" "$ERR" "verdict=no-rules"
# The whole point: the two zero-failure cases must not be the same bytes.
assert_eq "the lookup miss and the clean pass are DISTINGUISHABLE" \
  "$([[ "$CLEAN_OUT$CLEAN_ERR" != "$OUT$ERR" ]] && echo distinguishable || echo identical)" "distinguishable"

# GRADED, not merely reported: a shipped agent that owns no artifact is a different event from a
# name nobody registered. Deriving that from the shipped agent list is #66 property 3's
# configuration-not-history half.
assert_contains "a shipped artifact-less agent is graded as such" "$ERR" "owns no schema-validated artifact"
hook "{\"agent_type\":\"wizard\",\"cwd\":\"$TEMP_PROJECT\",\"active_issue\":\"$ISSUE\"}"
assert_contains "an unknown name is graded differently" "$ERR" "is not a shipped pipeline agent"

# THE SILENCE THAT MUST SURVIVE. A session that owns no .pipeline at all is the genuinely ad-hoc
# case the fail-open exists for, and it must not be taxed a line per subagent stop. This is the
# non-zero control for the announcement: the same agent_type that announced above says nothing
# here, so the line is a signal and not an unconditional print.
new_tmpdir || exit 90
ADHOC="$NEW_TMPDIR"
ADHOC_ERR=$(printf '{"agent_type":"secops","cwd":"%s"}' "$ADHOC" \
  | ( cd "$ADHOC" && CLAUDE_PROJECT_DIR="$ADHOC" node "$VALIDATOR" ) 2>&1 >/dev/null)
assert_eq "an ad-hoc session with no .pipeline announces NOTHING" "$ADHOC_ERR" ""

suite "validate-pipeline-artifact: an unnamable run dir is checked, not skipped (#115)"

# ISSUE_DIR_RE admits only <number> and exp-<slug>. ba.md duty 8 sanctions no third naming path,
# so `gh issue create` failing outside EXPERIMENT_MODE (tracker down, auth expired, offline) left
# BA improvising a name that silently opted the whole run out of every check issueDirs() feeds.
# Measured before this change: this exact fixture emitted 1180 bytes under `.pipeline/9001` and
# 0 bytes under `.pipeline/tracker-unreachable-20260902`. The name was the only difference.
new_tmpdir || exit 90
ORPHAN_ROOT="$NEW_TMPDIR"
ORPHAN_DIR="$ORPHAN_ROOT/.pipeline/tracker-unreachable-20260902"
mkdir -p "$ORPHAN_DIR"
RUN_RECORD='{"current_phase":"2-review","started_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z","branch":"b","events":[]}'
printf '%s' "$RUN_RECORD" > "$ORPHAN_DIR/status.json"
printf '%s' '{"verdict":"NOT_A_VERDICT"}' > "$ORPHAN_DIR/peer-review.secops.json"

orphan_hook() {
  local outf="$ORPHAN_ROOT/out.txt" errf="$ORPHAN_ROOT/err.txt"
  printf '{"agent_type":"pipeline:secops","cwd":"%s"}' "$ORPHAN_ROOT" \
    | ( cd "$ORPHAN_ROOT" && CLAUDE_PROJECT_DIR="$ORPHAN_ROOT" node "$VALIDATOR" ) \
      >"$outf" 2>"$errf"
  RC=$?
  OUT=$(cat "$outf")
  ERR=$(cat "$errf")
}

orphan_hook
assert_eq "an unnamable run dir still exits 0" "$RC" "0"
assert_contains "its defective artifact NOW blocks (was silent)" "$OUT" '"decision":"block"'
assert_contains "the block names the artifact" "$OUT" "peer-review.secops.json"
assert_contains "stderr reports verdict=unnamed-run" "$ERR" "verdict=unnamed-run"
assert_contains "and names the directory that could not be named" "$ERR" "tracker-unreachable-20260902"

# NON-ZERO CONTROL, the other direction: the same unnamable dir with a VALID artifact must pass.
# Without this the block above could be an unconditional refusal of any unnamed dir.
printf '%s' '{"verdict":"APPROVE","reviewed_at":"2026-01-01T00:00:00Z","concerns":[],"notes":"n"}' \
  > "$ORPHAN_DIR/peer-review.secops.json"
orphan_hook
assert_eq "a VALID artifact in an unnamable dir does NOT block" "$OUT" ""
assert_contains "but the naming gap is still reported" "$ERR" "verdict=unnamed-run"
printf '%s' '{"verdict":"NOT_A_VERDICT"}' > "$ORPHAN_DIR/peer-review.secops.json"

# A NON-RUN sibling is not adopted. `_archived` is a real name in this repo's own .pipeline.
# NOTE ON ORDERING: every case below only ever ADDS a fixture or overwrites a file in place.
# Nothing here removes a directory, deliberately -- harness.sh owns the single guarded rm -rf in
# these suites, and test-harness.sh refuses a hand-rolled one (a path from a failed mktemp is
# set-and-EMPTY, which `set -u` does not catch, so `rm -rf "$dir"/...` reaches the filesystem
# root). So the "a named dir wins" case is stated LAST, where it needs no teardown.
mkdir -p "$ORPHAN_ROOT/.pipeline/_archived"
printf '%s' '{"x":1}' > "$ORPHAN_ROOT/.pipeline/_archived/status.json"
orphan_hook
assert_contains "a status.json with no phase is not mistaken for a run" "$ERR" "tracker-unreachable-20260902"
assert_contains "so the real orphan is still the one checked" "$OUT" '"decision":"block"'

# A current_phase that IS a string but is not phase-SHAPED, which is the case that makes the
# status-schema pattern clause load-bearing rather than dead weight.
printf '%s' '{"current_phase":"archived"}' > "$ORPHAN_ROOT/.pipeline/_archived/status.json"
orphan_hook
assert_contains "a non-phase-shaped current_phase is not a run either" "$ERR" "tracker-unreachable-20260902"
assert_contains "so the real orphan is STILL the one checked" "$OUT" '"decision":"block"'

# TWO unnamable runs: abstain rather than guess, and say so. Same rule as activeIssueDir's mtime
# tie -- two candidates are the absence of a signal, not a weaker one.
printf '%s' "$RUN_RECORD" > "$ORPHAN_ROOT/.pipeline/_archived/status.json"
orphan_hook
assert_eq "two unnamable runs block nothing (fail open)" "$OUT" ""
assert_contains "and the abstention is named" "$ERR" "verdict=unnamed-run-ambiguous"
assert_contains "naming both candidates" "$ERR" "_archived"

# A NAMED dir wins, even with two unnamable runs sitting beside it. The recovery is a last resort
# and must never redirect a stop away from a run that resolved the ordinary way -- that would be a
# false block on work the session never touched.
mkdir -p "$ORPHAN_ROOT/.pipeline/777"
printf '%s' "$RUN_RECORD" > "$ORPHAN_ROOT/.pipeline/777/status.json"
orphan_hook
assert_contains "a named issue dir still wins over any unnamable one" "$ERR" "issue=777"
assert_eq "so the unnamable dir's defect no longer blocks" "$OUT" ""

suite "validate-pipeline-artifact: every SHIPPED agent is classified (#66 property 3)"

# THE CHECK THAT WOULD HAVE REDDENED ON DAY ONE. Nothing in this repo noticed that the validator
# had been inert since its first release commit; detecting it took a 353,907-line cross-machine
# transcript census. The reason is that liveness was only ever derivable from HISTORY -- what had
# been validated -- and inferring what SHOULD run from what HAS run makes an inert gate look like
# a smaller working one.
#
# So this derives the expectation from CONFIGURATION instead: the `name:` frontmatter of every
# agents/*.md the plugin ships. Each one must be either registered in AGENT_RULES or declared
# artifact-less. Adding an agent file without deciding which reddens here, as does deleting one,
# as does a namespaced dispatch resolving differently from a bare one.
# Paths arrive as argv, NOT interpolated into the script body: nesting shell quoting inside a
# node -e string is a second escaping layer under the thing being measured, and a path that
# happened to contain a quote or a space would corrupt the program rather than the result.
MANIFEST=$(node -e '
const [scriptsDir, agentsDir] = process.argv.slice(1);
import("file://" + scriptsDir + "/validate-pipeline-artifact.mjs").then(async (m) => {
  const fs = await import("node:fs");
  const path = await import("node:path");
  const shipped = fs.readdirSync(agentsDir)
    .filter((f) => f.endsWith(".md"))
    .map((f) => {
      const head = fs.readFileSync(path.join(agentsDir, f), "utf8").split("\n").slice(0, 10);
      const line = head.find((l) => l.startsWith("name:"));
      return line ? line.slice(5).trim() : "";
    })
    .filter(Boolean)
    .sort();
  const classified = [...new Set([...m.registeredAgents(), ...m.ARTIFACTLESS_AGENTS])].sort();
  const missing = shipped.filter((a) => !classified.includes(a));
  const extra = classified.filter((a) => !shipped.includes(a));
  // Every shipped agent must also resolve identically bare and plugin-namespaced.
  const drift = shipped.filter((a) =>
    m.checkArtifacts(a, {}, Date.now(), []).verdict !== m.checkArtifacts("pipeline:" + a, {}, Date.now(), []).verdict);
  process.stdout.write(JSON.stringify({ shipped: shipped.length, missing, extra, drift }));
});
' "$SCRIPTS_DIR" "$PLUGIN_ROOT/agents" 2>&1)
assert_contains "the manifest check ran and enumerated the shipped agents" "$MANIFEST" '"shipped":9'
assert_contains "every shipped agent is registered or declared artifact-less" "$MANIFEST" '"missing":[]'
assert_contains "and nothing is classified that the plugin does not ship" "$MANIFEST" '"extra":[]'
assert_contains "bare and plugin-namespaced dispatch agree for every shipped agent" "$MANIFEST" '"drift":[]'

finish
