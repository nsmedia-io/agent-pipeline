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

# A SCHEMA-SHAPED, IN-FLIGHT run record, not the `{"current_phase":"3"}` stub this used to be.
# #109 made the SubagentStop sweep resolve its scope by run OWNERSHIP: the marker below names a
# RECORD, not merely a directory, and an undatable record is never the resolved owner. With the
# stub, every case in this file would abstain and report zero failures -- passing the question by
# never asking it.
write_run_record "$TEMP_ISSUE_DIR/status.json" "3-impl"
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
# `updated_at` is COMPUTED, not the frozen 2026-01-01 literal this used to carry (#109). Which
# runs are CANDIDATES is decided by that field; which candidate wins is still decided by the
# mtimes stamped explicitly below. Two clocks, two jobs -- a clone refreshes every mtime and
# touches no `updated_at`, which is the whole reason the sweep stopped ranking by mtime.
RUN_RECORD="$(node -e 'process.stdout.write(JSON.stringify({current_phase:"2-review",started_at:"2026-01-01T00:00:00Z",updated_at:new Date(Date.now()-60000).toISOString(),branch:"b",events:[]}))')"
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

# WHICH RUN WINS. The rule is the validator's existing one -- the newest status.json -- so both
# directions are asserted, not only the one that flatters the change. Mtimes are set with an
# EXPLICIT `touch -t` rather than by write order: two files written microseconds apart do not
# reliably differ on Linux's coarser clock, and leaving the ordering to the host is #27 (green on
# APFS, red as a group on ubuntu-latest, at a fixed commit).
# Reset _archived to a NON-run first: the ambiguity case above left it holding a run record, and
# with two unnamable candidates the uniqueness rule refuses to pick either -- which would make the
# cases below pass for the wrong reason.
printf '%s' '{"x":1}' > "$ORPHAN_ROOT/.pipeline/_archived/status.json"
mkdir -p "$ORPHAN_ROOT/.pipeline/777"
printf '%s' "$RUN_RECORD" > "$ORPHAN_ROOT/.pipeline/777/status.json"
touch -t 202701010000 "$ORPHAN_ROOT/.pipeline/777/status.json"          # named is NEWER
touch -t 202601010000 "$ORPHAN_DIR/status.json"
orphan_hook
assert_contains "a NEWER named issue dir wins over the unnamable ones" "$ERR" "issue=777"
assert_eq "so the unnamable dir's defect does not block" "$OUT" ""

# The realistic adopting-project shape, and the one a last-resort-only fallback got WRONG: a
# finished numeric run from last month, plus today's unnamable one. Measured before this rule:
# 0 bytes on a fixture carrying real violations, because the stale named dir masked today's run.
touch -t 202601010000 "$ORPHAN_ROOT/.pipeline/777/status.json"          # named is now STALE
touch -t 202701010000 "$ORPHAN_DIR/status.json"                        # today's run is NEWER
orphan_hook
assert_contains "a NEWER unnamable run is no longer masked by a stale named one" "$ERR" "issue=tracker-unreachable-20260902"
assert_contains "and its defect is visible at last" "$OUT" '"decision":"block"'

# An EXPLICIT marker is never overridden, however new the unnamable dir is.
MARKED_ERR=$(printf '{"agent_type":"pipeline:secops","cwd":"%s","active_issue":"777"}' "$ORPHAN_ROOT" \
  | ( cd "$ORPHAN_ROOT" && CLAUDE_PROJECT_DIR="$ORPHAN_ROOT" node "$VALIDATOR" ) 2>&1 >/dev/null)
assert_contains "an explicit active_issue marker is never overridden" "$MARKED_ERR" "issue=777"

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

# ---------------------------------------------------------------------------
suite "validate-pipeline-artifact: the spec SIZE TRIPWIRE warns and never blocks (0.41.0)"
# ---------------------------------------------------------------------------
# commands/pipeline.md has said for its whole life that a spec crossing 10 requirements or 12
# acceptance criteria must justify its size or propose a split, and nothing read it. On the run
# that produced the rule, BA recommended a three-way split the first time it was asked directly
# and was right; nothing had asked.
#
# THE FAIL DIRECTION IS THE WHOLE DESIGN, so every cell below asserts stdout as well as stderr.
# The counts are a smell, not a defect: a genuinely large issue is a real thing, and "split
# this" is a decision only BA and the owner can take, at a moment a SubagentStop refusal cannot
# reach them. A warning that could ever turn into a block would be refusing correct work on a
# heuristic, which is how a control gets switched off.

PAYLOAD_BA="{\"agent_type\":\"ba\",\"cwd\":\"$TEMP_PROJECT\",\"active_issue\":\"$ISSUE\"}"

# write_spec_sized <n-requirements> <n-criteria> [size_justification]
write_spec_sized() {
  node -e '
    const fs = require("fs");
    const [, file, reqs, acs, just] = process.argv;
    const spec = {
      issue_number: 4242, title: "t", problem: "p",
      requirements: Array.from({ length: Number(reqs) }, (_, i) => `R${i + 1} do the thing`),
      acceptance_criteria: Array.from({ length: Number(acs) }, (_, i) => `AC${i + 1}. it is done`),
      impacted_domains: ["api"], trivial: false, ba_approved_at: "2026-01-01T00:00:00Z",
    };
    if (just !== "") spec.size_justification = just;
    fs.writeFileSync(file, JSON.stringify(spec));
  ' "$TEMP_ISSUE_DIR/spec.json" "$1" "$2" "${3:-}"
}

# A spec at the tripwire is not over it: 10 and 12 conform, and a warning at the boundary would
# fire on every spec that sits exactly where the rule says it may.
write_spec_sized 10 12 ""
hook "$PAYLOAD_BA"
assert_not_contains "BOUNDARY: exactly 10 requirements and 12 criteria is silent" "$ERR" "size tripwire"
assert_eq "BOUNDARY: exit 0" "$RC" "0"
assert_eq "BOUNDARY: and nothing on stdout" "$OUT" ""

write_spec_sized 11 12 ""
hook "$PAYLOAD_BA"
assert_eq "one requirement over the tripwire still exits 0" "$RC" "0"
assert_eq "AND WRITES NOTHING TO STDOUT: a warning must never become a decision:block" "$OUT" ""
assert_contains "the warning is on stderr" "$ERR" "agent-pipeline WARNING"
assert_contains "and names the tripwire" "$ERR" "size tripwire"
assert_contains "and names the requirement count" "$ERR" "11 requirements"
# BOTH counts, whichever crossed: "11 requirements" alone leaves the reader wondering whether
# the criteria are fine or simply unmentioned.
assert_contains "and the criteria count too, although that one did not cross" "$ERR" "12 acceptance criteria"
assert_contains "and names the field that answers it" "$ERR" "size_justification"
assert_contains "and says out loud that it blocks nothing" "$ERR" "blocks nothing"

write_spec_sized 10 13 ""
hook "$PAYLOAD_BA"
assert_eq "the criteria count crosses on its own" "$RC" "0"
assert_contains "and warns" "$ERR" "size tripwire"
assert_contains "naming both counts again" "$ERR" "13 acceptance criteria"
assert_eq "still nothing on stdout" "$OUT" ""

# THE FIELD ANSWERS IT. Without this cell the warning would be unconditional above the counts
# and `size_justification` would be a field nothing reads.
write_spec_sized 11 13 "One issue: the eleven requirements are one migration's blast radius and split three ways they cannot be reviewed."
hook "$PAYLOAD_BA"
assert_eq "a size_justification silences the warning" "$RC" "0"
assert_not_contains "the tripwire says nothing once the question is answered" "$ERR" "size tripwire"

# A BLANK field is not an answer. `""` satisfies a required-string check while claiming a
# justification exists, which is the cheapest-valid-value defect this repo has already shipped
# once on a required free-text field.
write_spec_sized 11 13 "   "
hook "$PAYLOAD_BA"
assert_contains "a whitespace-only size_justification does NOT silence it" "$ERR" "size tripwire"
assert_eq "and it still blocks nothing" "$OUT" ""

# CONTROL ON THE INSTRUMENT: the same oversized spec, otherwise valid, must produce no schema
# failure. Without this the warning cells could be riding on an artifact that was refused for
# some other reason entirely.
write_spec_sized 11 13 ""
hook "$PAYLOAD_BA"
assert_not_contains "CONTROL: the oversized spec is otherwise schema-valid" "$OUT" "decision"
assert_contains "CONTROL: and the run reports it CHECKED the artifact" "$ERR" "verdict=checked"

rm -f "$TEMP_ISSUE_DIR/spec.json"


suite "validate-pipeline-artifact: the QA 3a satisfiability record is REQUIRED at the architectural tier (#158)"

# QA writes tasks.json first at Phase 3a; impl-report.json does not exist yet. spec.json says
# architectural. With no satisfiability_proof the QA stop is BLOCKED; with a complete one it is
# not; below the architectural tier, or once impl-report.json exists (the Phase 4 QA stop), the
# check is off. tasks.json is not in QA's AGENT_RULES, so this is the one place it is read.
PAYLOAD_QA="{\"agent_type\":\"qa\",\"cwd\":\"$TEMP_PROJECT\",\"active_issue\":\"$ISSUE\"}"
SAVED_REPORT="$TEMP_PROJECT/saved-impl-report.json"
[ -f "$TEMP_ISSUE_DIR/impl-report.json" ] && mv "$TEMP_ISSUE_DIR/impl-report.json" "$SAVED_REPORT"
printf '%s' '{"issue_number":4242,"title":"t","problem":"p","requirements":["r"],"acceptance_criteria":["AC1. x"],"impacted_domains":["api"],"trivial":false,"risk_tier":"architectural"}' > "$TEMP_ISSUE_DIR/spec.json"
printf '%s' '{"issue_number":4242,"tasks":[{"id":"t1","title":"author tests","status":"done"}]}' > "$TEMP_ISSUE_DIR/tasks.json"
hook "$PAYLOAD_QA"
assert_eq "qa stop with no satisfiability_proof at architectural exits 0 (hook contract)" "$RC" "0"
assert_contains "qa stop with no satisfiability_proof is BLOCKED" "$OUT" '"decision":"block"'
assert_contains "the reason names the missing block" "$OUT" "satisfiability_proof is absent"

printf '%s' '{"issue_number":4242,"tasks":[{"id":"t1","title":"author tests","status":"done"}],"satisfiability_proof":{"reference_impl_run":true,"criteria_proven":["AC1"],"criteria_unproven":[],"configs_run":["vitest.config.ts"]}}' > "$TEMP_ISSUE_DIR/tasks.json"
hook "$PAYLOAD_QA"
assert_eq "qa stop with a complete record exits 0" "$RC" "0"
assert_not_contains "qa stop with a complete record is NOT blocked" "$OUT" '"decision":"block"'

printf '%s' '{"issue_number":4242,"tasks":[],"satisfiability_proof":{"reference_impl_run":true,"criteria_proven":[],"criteria_unproven":[],"configs_run":["a"]}}' > "$TEMP_ISSUE_DIR/tasks.json"
hook "$PAYLOAD_QA"
assert_contains "a record naming no criterion in either list is BLOCKED" "$OUT" "names no criterion"

# Below the architectural tier the block is not required (QA does not author the contract).
printf '%s' '{"issue_number":4242,"title":"t","problem":"p","requirements":["r"],"acceptance_criteria":["AC1. x"],"impacted_domains":["api"],"trivial":false,"risk_tier":"standard"}' > "$TEMP_ISSUE_DIR/spec.json"
printf '%s' '{"issue_number":4242,"tasks":[]}' > "$TEMP_ISSUE_DIR/tasks.json"
hook "$PAYLOAD_QA"
assert_not_contains "standard tier: no satisfiability block required" "$OUT" "satisfiability_proof"

# Once impl-report.json exists this is the Phase 4 QA stop and tasks.json is Dev's; check is off.
printf '%s' '{"issue_number":4242,"title":"t","problem":"p","requirements":["r"],"acceptance_criteria":["AC1. x"],"impacted_domains":["api"],"trivial":false,"risk_tier":"architectural"}' > "$TEMP_ISSUE_DIR/spec.json"
printf '%s' "$VALID_REPORT" > "$TEMP_ISSUE_DIR/impl-report.json"
hook "$PAYLOAD_QA"
assert_not_contains "with impl-report.json present (Phase 4 QA stop) the 3a check is off" "$OUT" "satisfiability_proof"
rm -f "$TEMP_ISSUE_DIR/impl-report.json" "$TEMP_ISSUE_DIR/tasks.json"
[ -f "$SAVED_REPORT" ] && mv "$SAVED_REPORT" "$TEMP_ISSUE_DIR/impl-report.json"


suite "validate-pipeline-artifact: a MALFORMED phase does not make a run dir unrecognised (B2)"

# Recognition of an unnamable run dir used to require a schema-SHAPED current_phase, so one mistyped
# checkpoint made the whole run invisible to this validator. It now requires the schema's required
# keys and a non-empty string phase; the shape itself is refused by check-status-record.mjs and the
# phase-entry guard.
new_tmpdir || exit 90
MAL_ROOT="$NEW_TMPDIR"
MAL_DIR="$MAL_ROOT/.pipeline/tracker-offline-20260916"
mkdir -p "$MAL_DIR"
node -e 'process.stdout.write(JSON.stringify({current_phase:"Phase 4 review",started_at:"2026-01-01T00:00:00Z",updated_at:new Date(Date.now()-60000).toISOString(),branch:"b",events:[]}))' > "$MAL_DIR/status.json"
printf '%s' '{"verdict":"NOT_A_VERDICT"}' > "$MAL_DIR/peer-review.secops.json"
mal_hook() {
  local outf="$MAL_ROOT/out.txt" errf="$MAL_ROOT/err.txt"
  printf '{"agent_type":"pipeline:secops","cwd":"%s"}' "$MAL_ROOT" \
    | ( cd "$MAL_ROOT" && CLAUDE_PROJECT_DIR="$MAL_ROOT" node "$VALIDATOR" ) >"$outf" 2>"$errf"
  OUT=$(cat "$outf"); ERR=$(cat "$errf")
}
mal_hook
assert_contains "a run record with a malformed phase is still a run: its defect blocks (was silent before B2)" "$OUT" '"decision":"block"'
assert_contains "  ...reported as the unnamed run it is" "$ERR" "verdict=unnamed-run"
# CONTROL: take current_phase away entirely and the directory is no longer a run.
node -e 'process.stdout.write(JSON.stringify({started_at:"2026-01-01T00:00:00Z",updated_at:new Date(Date.now()-60000).toISOString(),branch:"b",events:[]}))' > "$MAL_DIR/status.json"
mal_hook
assert_eq "CONTROL: the same record with NO current_phase is not a run, so nothing blocks" "$OUT" ""

suite "validate-pipeline-artifact: map.json is validated at BA's stop (B2)"

# gate-phase-entry.mjs REQUIRES map.json at 2-review, and nothing validated it against
# map.schema.json. It is now one of BA's artifacts.
# The #158 suite above leaves a spec.json behind; this suite asserts on map.json alone.
rm -f "$TEMP_ISSUE_DIR/spec.json"
PAYLOAD_BA_MAP="{\"agent_type\":\"pipeline:ba\",\"cwd\":\"$TEMP_PROJECT\",\"active_issue\":\"$ISSUE\"}"
printf '%s' '{"mapped_at":"2026-01-01T00:00:00Z","depth":"shallow"}' > "$TEMP_ISSUE_DIR/map.json"
hook "$PAYLOAD_BA_MAP"
assert_contains "an invalid map.json (no contracts, bad depth) blocks BA's stop" "$OUT" '"decision":"block"'
assert_contains "  ...naming map.json and the missing field" "$OUT" 'map.json (root): missing required field \"contracts\"'
assert_contains "  ...and the enum violation" "$OUT" 'map.json /depth'
printf '%s' '{"mapped_at":"2026-01-01T00:00:00Z","depth":"light","contracts":[{"name":"orders","kind":"table","readers":{}}]}' > "$TEMP_ISSUE_DIR/map.json"
hook "$PAYLOAD_BA_MAP"
assert_eq "CONTROL: a valid map.json does not block" "$OUT" ""
rm -f "$TEMP_ISSUE_DIR/map.json"

suite "validate-pipeline-artifact: a namespaced agent_type reaches the rules THROUGH THE HOOK (#66)"

# #66's four-cell fixture, driven through hooks/subagent-stop.sh rather than checkArtifacts, so the
# whole installed path is covered: the hook, the payload, the namespace strip, the rules table.
new_tmpdir || exit 90
NS_ROOT="$NEW_TMPDIR"
write_run_record "$NS_ROOT/.pipeline/66/status.json" "4-review"
printf '%s' '{"verdict":"NOT_A_VERDICT"}' > "$NS_ROOT/.pipeline/66/peer-review.secops.json"
ns_hook() { # <plugin-root> <agent_type>
  printf '{"agent_type":"%s","cwd":"%s"}' "$2" "$NS_ROOT" \
    | ( cd "$NS_ROOT" && CLAUDE_PROJECT_DIR="$NS_ROOT" CLAUDE_PLUGIN_ROOT="$1" bash "$HOOKS_DIR/subagent-stop.sh" 2>/dev/null )
}
for t in secops SecOps pipeline:secops agent-pipeline:secops plugin:pipeline:secops Pipeline:SecOps; do
  assert_contains "#66: agent_type '$t' blocks on the SAME defective shard through the hook" \
    "$(ns_hook "$PLUGIN_ROOT" "$t")" '"decision":"block"'
done
# THE CONTROL THAT FAILS WITHOUT THE FIX: a copy of the plugin whose validator looks the agent up by
# the raw lowercased agent_type, which is what #66 found shipped. The bare name still blocks there;
# every namespaced spelling goes silent.
new_tmpdir || exit 90
NS_MUT="$NEW_TMPDIR"
mkdir -p "$NS_MUT/scripts" "$NS_MUT/schemas" "$NS_MUT/hooks"
cp "$SCRIPTS_DIR"/*.mjs "$SCRIPTS_DIR"/*.json "$NS_MUT/scripts/" 2>/dev/null
cp "$PLUGIN_ROOT/schemas"/*.json "$NS_MUT/schemas/"
node -e '
  const fs = require("fs"); const f = process.argv[1];
  const s = fs.readFileSync(f, "utf8");
  const a = "const agent = bareRole(agentType);";
  if (!s.includes(a)) { process.stdout.write("MUTATION-SITE-MISSING"); process.exit(0); }
  fs.writeFileSync(f, s.replace(a, "const agent = String(agentType || \"\").toLowerCase();"));
  process.stdout.write("mutated");
' "$NS_MUT/scripts/validate-pipeline-artifact.mjs" > "$NS_MUT/mutation.txt"
assert_eq "#66 CONTROL premise: the mutation site exists and was applied" "$(cat "$NS_MUT/mutation.txt")" "mutated"
assert_contains "#66 CONTROL: under the mutation the BARE name still blocks" "$(ns_hook "$NS_MUT" secops)" '"decision":"block"'
assert_eq "#66 CONTROL: under the mutation 'pipeline:secops' goes SILENT, which is the shipped defect" \
  "$(ns_hook "$NS_MUT" pipeline:secops)" ""
# And a VALID shard does not block under any spelling.
printf '%s' '{"verdict":"APPROVE","reviewed_at":"2026-01-01T00:00:00Z","concerns":[],"notes":"n"}' > "$NS_ROOT/.pipeline/66/peer-review.secops.json"
assert_eq "#66: a valid shard does not block under the namespaced spelling" "$(ns_hook "$PLUGIN_ROOT" pipeline:secops)" ""

suite "validate-pipeline-artifact: a review shard written into the WRONG CHECKOUT refuses the stop (B2)"

# The live shape: the orchestrator's project dir P, a dispatch worktree W nested under it (a `.git`
# FILE marks W as its own checkout), and a QA panelist dispatched into W who wrote its shard into P.
new_tmpdir || exit 90
STRAY_P="$NEW_TMPDIR"
mkdir -p "$STRAY_P/.git"
STRAY_W="$STRAY_P/.claude/worktrees/4242-panel"
mkdir -p "$STRAY_W"
printf 'gitdir: %s/.git/worktrees/4242-panel\n' "$STRAY_P" > "$STRAY_W/.git"
write_run_record "$STRAY_P/.pipeline/4242/status.json" "4-review"
write_run_record "$STRAY_W/.pipeline/4242/status.json" "4-review"
VALID_QA_SHARD='{"verdict":"APPROVE","reviewed_at":"2026-01-01T00:00:00Z","concerns":[],"notes":"n"}'
printf '%s' "$VALID_QA_SHARD" > "$STRAY_P/.pipeline/4242/peer-review.qa.json"
stray_hook() { # <cwd>
  local outf="$STRAY_P/out.txt" errf="$STRAY_P/err.txt"
  printf '{"agent_type":"pipeline:qa","cwd":"%s"}' "$1" \
    | ( cd "$1" && CLAUDE_PROJECT_DIR="$STRAY_P" node "$VALIDATOR" ) >"$outf" 2>"$errf"
  OUT=$(cat "$outf"); ERR=$(cat "$errf")
}
stray_hook "$STRAY_W"
assert_contains "a shard in the project dir while dispatched to a worktree BLOCKS the stop" "$OUT" '"decision":"block"'
assert_contains "  ...naming the stray path" "$OUT" "peer-review.qa.json was written to $STRAY_P/.pipeline/4242/peer-review.qa.json"
assert_contains "  ...and the dispatch checkout" "$OUT" "4242-panel"
assert_contains "  ...and saying where the merge reads it" "$OUT" "where the merge reads"

# CONTROL 1: once the shard ALSO exists where the merge reads it, nothing is missing.
printf '%s' "$VALID_QA_SHARD" > "$STRAY_W/.pipeline/4242/peer-review.qa.json"
stray_hook "$STRAY_W"
assert_eq "CONTROL: the same stray copy with the shard present in the worktree does not block" "$OUT" ""
rm -f "$STRAY_W/.pipeline/4242/peer-review.qa.json"
# CONTROL 2: an agent working in the project dir itself has no wrong checkout to write into.
stray_hook "$STRAY_P"
assert_eq "CONTROL: an agent whose cwd IS the project dir is not refused" "$OUT" ""
# CONTROL 3: a shard older than this subagent (its transcript's first timestamp) is not its write.
touch -t 202001010000 "$STRAY_P/.pipeline/4242/peer-review.qa.json"
node -e 'process.stdout.write(JSON.stringify({type:"user",timestamp:new Date().toISOString()})+"\n")' > "$STRAY_P/agent-transcript.jsonl"
printf '{"agent_type":"pipeline:qa","cwd":"%s","agent_transcript_path":"%s"}' "$STRAY_W" "$STRAY_P/agent-transcript.jsonl" \
  | ( cd "$STRAY_W" && CLAUDE_PROJECT_DIR="$STRAY_P" node "$VALIDATOR" ) >"$STRAY_P/out.txt" 2>/dev/null
assert_eq "CONTROL: a shard last modified BEFORE this subagent started is not attributed to it" "$(cat "$STRAY_P/out.txt")" ""

finish
