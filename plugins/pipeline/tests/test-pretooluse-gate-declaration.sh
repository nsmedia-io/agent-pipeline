#!/usr/bin/env bash
# #106, part 1 of 5: the DECLARATION and the STRUCTURE around it.
#
# AC1  the PreToolUse entry exists, reaches Bash, and its timeout is bounded IN SECONDS
# AC15 the phase vocabulary the gate acts on comes from its WRITER, not a third private copy
# AC16 the two-stage split, proven by process observation rather than by a clock
# AC18 cost, partitioned: a ratio only over the classes decidable without the node seam
# AC24 the inertness control -- a gate that denies nothing passes most of this suite
# AC35 the new suites are DISCOVERED by run.sh's existing glob, with no edit to run.sh
# AC36 no import cycle, and every entry direction still produces the reviewed commit's output
#
# THE TESTS IN THIS FILE FAIL AT THE REVIEWED COMMIT AND ARE MEANT TO. hooks.json declares three
# events and no PreToolUse, so the driver returns GATE-UNDECLARED and each assertion fails with
# its own message about the missing behaviour. That is on purpose (test-discipline rule 9): a
# `beforeAll` that threw would turn this file into one setup error and N skips, and a run
# reporting skips at exit 0 is indistinguishable from a run that checked nothing.

. "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
. "$(dirname "${BASH_SOURCE[0]}")/fixtures/pretooluse-gate-lib.sh"
require_node

make_temp_project 106 || exit 90
GATE_SCRATCH="$TEMP_PROJECT"

# ===============================================================================================
suite "AC1: the PreToolUse declaration, and its timeout in SECONDS"
# ===============================================================================================
#
# THE UNIT IS FIXED BY THE RUNTIME, NOT BY THE FILE'S NEIGHBOURS. Claude Code 2.1.85's hook-exec
# path computes `E = H.timeout ? H.timeout*1000 : EL` with `EL = 600000`, so `timeout` is SECONDS
# and the implicit ceiling is 600 s. The three already-shipped entries (10000, 120000, 15000) are
# therefore 2.8 h, 33.3 h and 4.2 h -- every one of them ABOVE the platform's own default -- so
# "smaller than Stop's 120000" bounds nothing and is refused here as a comparison. That
# seconds/milliseconds defect in the shipped three is #108 and is NOT fixed by this issue, which
# is why the assertion below is written against 600 and not against the neighbours.
#
# Version recorded beside the assertion, per the measurement rule: the ceiling is a property of
# the runtime under test, so a host on another version produces a different recorded number
# rather than a silently wrong pass.
record "RUNTIME UNDER TEST for the timeout unit: Claude Code 2.1.85, \`E=H.timeout?H.timeout*1000:EL\`, \`EL=600000\` -> field is SECONDS, ceiling 600"

HOOKS_JSON_PARSES="$(gate_hook_probe 'Object.keys(h.hooks||{}).sort().join(",")')"
assert_eq "hooks/hooks.json parses as JSON (a PARSE-ERROR here invalidates every other row)" \
  "$([[ "$HOOKS_JSON_PARSES" == "PARSE-ERROR" ]] && echo "PARSE-ERROR" || echo parses)" "parses"

assert_eq "the hooks object carries a PreToolUse key" \
  "$(gate_hook_probe 'h.hooks && h.hooks.PreToolUse ? "present" : "ABSENT"')" "present"

GATE_TPL="$(gate_command_template)"
assert_contains "its command resolves under \${CLAUDE_PLUGIN_ROOT}, like the other three" \
  "$GATE_TPL" '${CLAUDE_PLUGIN_ROOT}'

# The matcher must ADMIT tool_name Bash. Asserted as admission rather than as a literal string,
# because "Bash", "Bash|Write" and a regex that matches Bash all satisfy the requirement and
# pinning one spelling would refuse two correct implementations.
MATCHER="$(gate_declared_matcher)"
MATCHER_ADMITS="$("$GATE_REAL_NODE" -e '
  const m = process.argv[1];
  const entryPresent = process.argv[2] === "present";
  // An ABSENT matcher on a PRESENT entry means "every tool", which admits Bash. An absent ENTRY
  // admits nothing at all, and the first draft of this row read the two the same way -- so it
  // reported "admits" against the reviewed commit, which declares no PreToolUse hook. A row that
  // cannot go red in the state the issue exists to fix is a deleted row wearing a green tick.
  if (!entryPresent) { process.stdout.write("NO PreToolUse ENTRY, so nothing is matched"); process.exit(0); }
  if (m === "" || m === "undefined" || m === "null") { process.stdout.write("admits(no matcher = all tools)"); process.exit(0); }
  let v; try { v = JSON.parse(m); } catch { process.stdout.write("UNPARSEABLE"); process.exit(0); }
  if (typeof v !== "string") { process.stdout.write("NOT-A-STRING"); process.exit(0); }
  let ok = false;
  try { ok = new RegExp(v).test("Bash"); } catch { ok = (v === "Bash"); }
  process.stdout.write(ok ? "admits(Bash)" : "REFUSES Bash: " + v);
' "$MATCHER" "$(gate_hook_probe 'h.hooks && h.hooks.PreToolUse ? "present" : "absent"')" 2>/dev/null)"
assert_contains "the matcher admits tool_name 'Bash'" "$MATCHER_ADMITS" "admits"

DECLARED_TIMEOUT="$(gate_declared_timeout)"
assert_eq "a \`timeout\` is DECLARED (absent is indistinguishable from taking the 600 s default)" \
  "$([[ -n "$DECLARED_TIMEOUT" ]] && echo declared || echo ABSENT)" "declared"
assert_eq "the declared timeout is NUMERIC" \
  "$([[ "$DECLARED_TIMEOUT" =~ ^[0-9]+([.][0-9]+)?$ ]] && echo numeric || echo "NOT-NUMERIC: ${DECLARED_TIMEOUT:-<absent>}")" "numeric"
assert_eq "and is STRICTLY LESS than the platform default ceiling of 600 SECONDS (not 'less than Stop's 120000', which bounds nothing)" \
  "$("$GATE_REAL_NODE" -e 'const t=Number(process.argv[1]); process.stdout.write(Number.isFinite(t)&&t<600?"under-600":"AT-OR-OVER-600: "+process.argv[1])' "${DECLARED_TIMEOUT:-NaN}" 2>/dev/null)" \
  "under-600"

# The magnitude R1 argues for: 66.68 ms node cold start plus one git subprocess on the escalation
# branch. A single-digit number of seconds. Asserted as a FLOOR too, so a `timeout: 0.001` that
# technically satisfies "< 600" but times the gate out on every escalation is caught.
assert_eq "and is a plausible bound for one node start plus one git subprocess (0 < t <= 30 s)" \
  "$("$GATE_REAL_NODE" -e 'const t=Number(process.argv[1]); process.stdout.write(Number.isFinite(t)&&t>0&&t<=30?"in-range":"OUT-OF-RANGE: "+process.argv[1])' "${DECLARED_TIMEOUT:-NaN}" 2>/dev/null)" \
  "in-range"

# The three existing event keys are unchanged IN CONTENT. Pinned as the exact serialization of
# each, so a change to a command or a timeout reddens here rather than only in whichever suite
# happens to drive that hook.
assert_eq "SessionStart entry is unchanged in content" \
  "$(gate_hook_probe 'JSON.stringify(h.hooks.SessionStart)')" \
  '[{"hooks":[{"type":"command","command":"${CLAUDE_PLUGIN_ROOT}/hooks/session-start.sh","timeout":10000}]}]'
assert_eq "Stop entry is unchanged in content" \
  "$(gate_hook_probe 'JSON.stringify(h.hooks.Stop)')" \
  '[{"hooks":[{"type":"command","command":"${CLAUDE_PLUGIN_ROOT}/hooks/stop.sh","timeout":120000}]}]'
assert_eq "SubagentStop entry is unchanged in content" \
  "$(gate_hook_probe 'JSON.stringify(h.hooks.SubagentStop)')" \
  '[{"hooks":[{"type":"command","command":"${CLAUDE_PLUGIN_ROOT}/hooks/subagent-stop.sh","timeout":15000}]}]'

# The declared command must actually be EXECUTABLE by the runtime, which runs the string through a
# shell. A declaration pointing at a file that is not there is the #106 shape one level up.
RESOLVED="$(gate_resolved_command "$GATE_PLUGIN_DIR")"
assert_eq "the resolved command names a file that exists and is executable" \
  "$("$GATE_REAL_NODE" -e '
     const {statSync} = require("node:fs");
     const first = (process.argv[1]||"").split(/\s+/)[0];
     if (!first) { process.stdout.write("NO-COMMAND"); process.exit(0); }
     try { const st = statSync(first); process.stdout.write(st.isFile() && (st.mode & 0o111) ? "executable" : "NOT-EXECUTABLE: "+first); }
     catch { process.stdout.write("MISSING: "+first); }
   ' "$RESOLVED" 2>/dev/null)" "executable"

# ===============================================================================================
suite "AC15: the phase vocabulary has ONE source, and it is the file that WRITES it"
# ===============================================================================================
#
# Both directions of a set comparison against commands/pipeline.md, the way
# tests/test-status-schema-contract.sh:403 already does it for the schema. A one-direction
# containment check passes on a gate that invented a fourth literal.

MD_PHASES="$(gate_pipeline_md_phases)"
MD_PHASE4="$(gate_phase4_literals)"
MD_PHASE4_N="$(printf '%s\n' "$MD_PHASE4" | grep -c . | tr -d ' ')"

assert_eq "VACUITY: pipeline.md yielded a non-empty phase vocabulary (a broken grep proves nothing)" \
  "$([[ "$(printf '%s\n' "$MD_PHASES" | grep -c . | tr -d ' ')" -ge 10 ]] && echo enough || echo TOO-FEW)" "enough"
assert_eq "pipeline.md writes exactly THREE Phase 4 current_phase literals" "$MD_PHASE4_N" "3"
assert_eq "and they are the three R12 names" \
  "$(printf '%s\n' "$MD_PHASE4" | tr '\n' ' ' | sed 's/ *$//')" \
  "4-review 4-review-complete 4-veto-rework-required"

# '4-review-round-2' is an events[].phase EXIT label, never a current_phase write. AC15 forbids
# fixtures built on it, so the absence is asserted rather than assumed.
assert_eq "'4-review-round-2' is NOT a current_phase literal (it is an events[] exit label)" \
  "$(printf '%s\n' "$MD_PHASES" | grep -cx '4-review-round-2' | tr -d ' ')" "0"

# THE MUTATION AC15 NAMES: edit '4-review' to another slug in a SCRATCH COPY of pipeline.md and
# the gate must follow it. A gate carrying a private copy does not.
SCRATCH_MD_DIR="$TEMP_PROJECT/scratch-md"
mkdir -p "$SCRATCH_MD_DIR"
sed 's/4-review/4-reviewXQ/g' "$GATE_PIPELINE_MD" > "$SCRATCH_MD_DIR/pipeline.md"
# PROVE THE EDIT LANDED, and prove it is the edit meant: '4-review' must be GONE from the scratch
# copy's current_phase vocabulary, and the renamed slug must be there. Counting the renamed rows
# alone got this wrong once already -- the rename moves two literals ('4-review', '4-review-
# complete') and leaves '4-veto-rework-required' alone, so a count of 3 was never reachable.
assert_eq "MUTATION CONTROL: '4-review' is GONE from the scratch copy's vocabulary" \
  "$(gate_pipeline_md_phases "$SCRATCH_MD_DIR/pipeline.md" | grep -cx '4-review' | tr -d ' ')" "0"
assert_eq "MUTATION CONTROL: and the renamed slug is present, so the edit is not a no-op" \
  "$(gate_pipeline_md_phases "$SCRATCH_MD_DIR/pipeline.md" | grep -cx '4-reviewXQ' | tr -d ' ')" "1"

# The behavioural half: with the gate's OWN plugin dir pointed at a tree whose pipeline.md writes
# the mutated slug, a payload at the ORIGINAL '4-review' must stop being denied. If it is still
# denied, the gate is not reading pipeline.md and R12 is unmet.
MUT_ROOT="$TEMP_PROJECT/mutated-plugin"
mkdir -p "$MUT_ROOT"
cp -R "$GATE_PLUGIN_DIR/." "$MUT_ROOT/" 2>/dev/null
cp "$SCRATCH_MD_DIR/pipeline.md" "$MUT_ROOT/commands/pipeline.md" 2>/dev/null

VOCAB_PROJECT="$TEMP_PROJECT/vocab"
gate_inflight_status "$VOCAB_PROJECT/.pipeline/106/status.json" "4-review"
PAY_VOCAB="$(gate_payload 'git commit -a -m "m"' agent_id=sub-vocab agent_type=pipeline:qa)"

gate_reset_env "$VOCAB_PROJECT"
run_gate "$PAY_VOCAB"
assert_eq "PRECONDITION for the vocabulary mutation: the unmutated tree DENIES this payload" "$GATE_DECISION" "deny"

gate_reset_env "$VOCAB_PROJECT"
GATE_PLUGIN_ROOT_OVERRIDE="$MUT_ROOT"
run_gate "$PAY_VOCAB"
assert_eq "AC15: with pipeline.md's '4-review' renamed in the tree the gate READS, the same payload is no longer denied" \
  "$GATE_DECISION" "none"

# ===============================================================================================
suite "AC16: two-stage, proven by PROCESS OBSERVATION (not by a wall clock)"
# ===============================================================================================
#
# A `node` shim first on PATH records every invocation and execs the real node. Counting is the
# instrument: a timing bound would pass on a host where a node start happens to be cheap, which is
# the rendered-measurement defect evidence.md names.
#
# THE NON-ZERO CONTROL IS MANDATORY HERE. "0 node invocations" is equally consistent with "the
# gate is genuinely two-stage" and with "the shim was never on the gate's PATH at all" -- a gate
# invoking node by absolute path is invisible to it. So an ESCALATION case must show >= 1 first.

SPY_DIR="$TEMP_PROJECT/spy"
gate_spy_setup "$SPY_DIR"

SPY_PROJECT="$TEMP_PROJECT/spy-project"
gate_inflight_status "$SPY_PROJECT/.pipeline/106/status.json" "4-review"

# (control) the escalation branch: subagent-originated, forbidden command, a real record store.
: > "$GATE_SPY_LOG"
gate_reset_env "$SPY_PROJECT"; GATE_PATH="$GATE_SPY_PATH"
run_gate "$(gate_payload 'git commit -a -m "m"' agent_id=sub-spy agent_type=pipeline:qa)"
SPY_ESCALATION="$(gate_spy_invocations)"
assert_eq "NON-ZERO CONTROL: the spy SEES the gate's node invocations on the escalation branch (a 0 here voids every zero below)" \
  "$([[ "${SPY_ESCALATION:-0}" -ge 1 ]] && echo "observed" || echo "SAW NOTHING: the shim is not on the gate's node path")" "observed"

# (i) non-git command: decidable without the seam.
: > "$GATE_SPY_LOG"
gate_reset_env "$SPY_PROJECT"; GATE_PATH="$GATE_SPY_PATH"
run_gate "$(gate_payload 'pnpm exec vitest run' agent_id=sub-spy agent_type=pipeline:qa)"
assert_eq "AC16(i): a non-git command spawns ZERO node processes" "$(gate_spy_invocations)" "0"
assert_eq "AC16(i): and is not denied" "$GATE_DECISION" "none"

# (ii) no agent_id: decidable without the seam.
: > "$GATE_SPY_LOG"
gate_reset_env "$SPY_PROJECT"; GATE_PATH="$GATE_SPY_PATH"
run_gate "$(gate_payload 'git commit -a -m "m"' agent_id=__ABSENT__)"
assert_eq "AC16(ii): a payload with NO agent_id spawns ZERO node processes" "$(gate_spy_invocations)" "0"
assert_eq "AC16(ii): and is not denied" "$GATE_DECISION" "none"

# (iii) a non-Bash tool: the matcher may admit it, but it can never stage anything.
: > "$GATE_SPY_LOG"
gate_reset_env "$SPY_PROJECT"; GATE_PATH="$GATE_SPY_PATH"
run_gate "$(gate_payload 'irrelevant' agent_id=sub-spy tool_name=Write)"
assert_eq "AC16(iii): a non-Bash tool_name spawns ZERO node processes" "$(gate_spy_invocations)" "0"
assert_eq "AC16(iii): and is not denied" "$GATE_DECISION" "none"

# ===============================================================================================
suite "AC18: cost, PARTITIONED -- a ratio only where the seam is not required"
# ===============================================================================================
#
# BASELINES, recorded with the machine that produced them, because a threshold on a rendered
# measurement measures the runner. Round 8 retired the absolute 3x-of-baseline bound this block
# used to assert: a DO-NOTHING stub driven through this same path costs more than that bound, so
# the bound was a threshold on the harness's own scaffolding rather than on the gate. What is
# bounded now is the DIFFERENCE against that stub, measured in the same run; the seam-requiring
# class is the live non-zero control for the comparison and is never itself bounded, because
# bounding it would be pinning this host's node start time.

now_ms() { "$GATE_REAL_NODE" -e 'process.stdout.write(String(Date.now()))'; }

# The same-run bash no-op baseline, measured HERE rather than transcribed.
COST_N=20
T0="$(now_ms)"
for _ in $(seq 1 $COST_N); do sh -c ':'; done
T1="$(now_ms)"
BASH_BASELINE_MS="$(( (T1 - T0) / COST_N ))"
record "COST BASELINE (this run, this host): sh -c ':' = ${BASH_BASELINE_MS} ms/call over ${COST_N} calls; node $("$GATE_REAL_NODE" --version), $(uname -sr)"

# run_gate_RAW, never run_gate: the decision parse is a node start belonging to the SUITE, and
# the first draft of this file measured 78 ms/call for a gate that does not exist yet because the
# harness's own probes were inside the loop. Nothing in the loop below may be the instrument.
gate_cache_declaration
cost_of() {  # <payload> -> ms/call, printed
  local pay="$1" a b
  a="$(now_ms)"
  local i
  for i in $(seq 1 $COST_N); do run_gate_raw "$pay"; done
  b="$(now_ms)"
  printf '%s' "$(( (b - a) / COST_N ))"
}

# THE HARNESS IS THE FLOOR, so the floor is measured and subtracted. No shebang and chmod +x on
# purpose: the shipped hook has no shebang, so the invoking shell runs it after ENOEXEC with no
# second exec; a stub WITH one would buy an exec the gate does not pay and bias the difference
# downward. It does not read stdin either, so the difference charges the gate for its own read.
COST_STUB_ROOT="$TEMP_PROJECT/cost-stub-root"
mkdir -p "$COST_STUB_ROOT/hooks"
printf 'exit 0\n' > "$COST_STUB_ROOT/hooks/pre-tool-use.sh"
chmod +x "$COST_STUB_ROOT/hooks/pre-tool-use.sh"

# gate_reset_env RESETS the override, so the override is set after it, never before.
gate_reset_env "$SPY_PROJECT"; GATE_PLUGIN_ROOT_OVERRIDE="$COST_STUB_ROOT"
COST_STUB="$(cost_of "$(gate_payload 'pnpm exec vitest run' agent_id=sub-cost agent_type=pipeline:qa)")"

gate_reset_env "$SPY_PROJECT"
COST_NONGIT="$(cost_of "$(gate_payload 'pnpm exec vitest run' agent_id=sub-cost agent_type=pipeline:qa)")"
gate_reset_env "$SPY_PROJECT"
COST_NOAGENT="$(cost_of "$(gate_payload 'git commit -a -m "m"' agent_id=__ABSENT__)")"
gate_reset_env "$SPY_PROJECT"
COST_SEAM="$(cost_of "$(gate_payload 'git commit -a -m "m"' agent_id=sub-cost agent_type=pipeline:qa)")"

record "COST no-seam class 'non-git command':  ${COST_NONGIT} ms/call"
record "COST no-seam class 'no agent_id':      ${COST_NOAGENT} ms/call"
record "COST seam-requiring class 'escalation': ${COST_SEAM} ms/call (RECORDED, deliberately NOT bounded)"

BOUND_MS=$(( BASH_BASELINE_MS * 2 ))
[[ "$BOUND_MS" -ge 2 ]] || BOUND_MS=2
D_NONGIT=$(( COST_NONGIT - COST_STUB )); A_NONGIT=$(( D_NONGIT < 0 ? -D_NONGIT : D_NONGIT ))
D_NOAGENT=$(( COST_NOAGENT - COST_STUB )); A_NOAGENT=$(( D_NOAGENT < 0 ? -D_NOAGENT : D_NOAGENT ))
D_SEAM=$(( COST_SEAM - COST_STUB ))
record "COST HARNESS FLOOR (do-nothing stub, identical path): ${COST_STUB} ms/call -- the quantity the retired absolute 3x bound was measuring"
record "COST MARGINAL (class minus floor): non-git ${D_NONGIT} ms, no-agent ${D_NOAGENT} ms, seam ${D_SEAM} ms; bound +-${BOUND_MS} ms"

assert_eq "VACUITY: both reference figures are non-zero (a 0 ms baseline or floor makes every difference below unfalsifiable)" \
  "$([[ "${BASH_BASELINE_MS:-0}" -gt 0 && "${COST_STUB:-0}" -gt 0 ]] && echo measured || echo "B=${BASH_BASELINE_MS} S=${COST_STUB}")" "measured"
assert_eq "EXPIRY: the harness floor still dominates the bash baseline (${COST_STUB} ms > ${BASH_BASELINE_MS} ms). If this is FALSE the scaffolding is no longer the dominant term, AC18's retired absolute bound could be re-derived, and this methodology needs re-measuring rather than assuming" \
  "$([[ "${COST_STUB:-0}" -gt "${BASH_BASELINE_MS:-0}" ]] && echo floor-dominates || echo "FLOOR COLLAPSED: stub ${COST_STUB} vs baseline ${BASH_BASELINE_MS}")" "floor-dominates"
assert_eq "AC18: the 'non-git command' class's OWN marginal cost is within +-${BOUND_MS} ms of a do-nothing stub on the identical path (${D_NONGIT} ms)" \
  "$([[ "$A_NONGIT" -le "$BOUND_MS" ]] && echo within || echo "OUT: ${D_NONGIT} ms vs +-${BOUND_MS} ms")" "within"
assert_eq "AC18: the 'no agent_id' class's OWN marginal cost is within +-${BOUND_MS} ms of the same floor (${D_NOAGENT} ms)" \
  "$([[ "$A_NOAGENT" -le "$BOUND_MS" ]] && echo within || echo "OUT: ${D_NOAGENT} ms vs +-${BOUND_MS} ms")" "within"
assert_eq "AC18 NON-ZERO CONTROL, LIVE: the same instrument in the same run puts the seam class OVER the bound the no-seam classes sit under (${D_SEAM} ms > ${BOUND_MS} ms), so a green transcript has watched this comparison report a violation with nothing planted" \
  "$([[ "$D_SEAM" -gt "$BOUND_MS" ]] && echo over || echo "NOT OVER: seam ${D_SEAM} ms vs bound ${BOUND_MS} ms")" "over"
assert_eq "AC18: the seam-requiring class's figure is PRESENT and non-zero (recorded, not bounded)" \
  "$([[ "${COST_SEAM:-0}" -gt 0 ]] && echo present || echo "ABSENT-OR-ZERO: ${COST_SEAM}")" "present"

# THE PARTITION MUST BE REAL, or the three rows above are satisfied by a gate that does nothing at
# all -- which is the state at the reviewed commit, where all three classes measured 4 ms because
# no hook ran. This is AC24's inertness argument applied to AC18's own numbers: a partition
# nobody can observe is not a partition. The seam class starts a node; the no-seam classes must
# not; so the seam class must cost measurably more on the same host in the same run.
assert_eq "AC18 PARTITION IS REAL: the seam-requiring class costs measurably more than both no-seam classes on this host, in this run (${COST_SEAM} vs ${COST_NONGIT}/${COST_NOAGENT} ms)" \
  "$([[ "${COST_SEAM:-0}" -gt "${COST_NONGIT:-0}" && "${COST_SEAM:-0}" -gt "${COST_NOAGENT:-0}" ]] \
     && echo partitioned || echo "NOT PARTITIONED: seam=${COST_SEAM} nongit=${COST_NONGIT} noagent=${COST_NOAGENT}")" \
  "partitioned"

# ===============================================================================================
suite "AC24: INERTNESS CONTROL -- a gate that denies nothing must not pass this suite"
# ===============================================================================================
#
# AC2, AC3, AC8, AC9, AC11(i) and AC21 are all satisfied by a gate that returns allow
# unconditionally. This is the row that refuses it, and it is asserted in the same harness
# invocation path as the allows, so it cannot be satisfied by a suite that never ran.

INERT_PROJECT="$TEMP_PROJECT/inert"
gate_inflight_status "$INERT_PROJECT/.pipeline/106/status.json" "4-review"
gate_reset_env "$INERT_PROJECT"
run_gate "$(gate_payload 'git add -A' agent_id=sub-inert agent_type=pipeline:dba)"
INERT_DENY="$GATE_DECISION"
gate_reset_env "$INERT_PROJECT"
run_gate "$(gate_payload 'git add plugins/pipeline/agents/dba.md' agent_id=sub-inert agent_type=pipeline:dba)"
INERT_ALLOW="$GATE_DECISION"

assert_eq "AC24: at least one DENY was produced in this run" "$INERT_DENY" "deny"
assert_eq "AC24: at least one ALLOW (non-deny) was produced in the same run" "$INERT_ALLOW" "none"
assert_eq "AC24: and the two differ, so the suite has discriminated rather than merely fired" \
  "$([[ "$INERT_DENY" != "$INERT_ALLOW" ]] && echo differ || echo "IDENTICAL: $INERT_DENY")" "differ"

# ===============================================================================================
suite "AC35: discovered by run.sh's existing glob, with no edit to run.sh"
# ===============================================================================================

RUN_SH="$GATE_TESTS_DIR/run.sh"
RUN_PATTERNS="$(sed -n 's/^[[:space:]]*for t in \(.*\); do[[:space:]]*$/\1/p' "$RUN_SH" | head -1)"
assert_eq "run.sh's discovery line is still exactly the flat test-*.sh glob (this issue must not edit it)" \
  "$RUN_PATTERNS" "test-*.sh"

for s in test-pretooluse-gate-declaration.sh test-pretooluse-gate-verdicts.sh \
         test-pretooluse-gate-ownership.sh test-pretooluse-gate-channel.sh \
         test-pretooluse-doc-retirement.sh; do
  assert_eq "run.sh's own glob discovers $s" \
    "$( ( cd "$GATE_TESTS_DIR" && eval "for t in $RUN_PATTERNS; do [ \"\$t\" = \"$s\" ] && printf discovered; done" ) )" \
    "discovered"
done
# The shared driver must NOT be discovered as a suite: it is sourced, and a sourced file run as a
# suite would report a green pass having asserted nothing.
assert_eq "and does NOT discover the sourced driver (it lives under fixtures/ for exactly this reason)" \
  "$( ( cd "$GATE_TESTS_DIR" && eval "for t in $RUN_PATTERNS; do [ \"\$t\" = \"pretooluse-gate-lib.sh\" ] && printf FOUND; done" ) )" \
  ""

# ===============================================================================================
suite "AC36(a): the scripts/ module graph stays ACYCLIC, with a non-zero control"
# ===============================================================================================
#
# THIS HALF IS LOAD-BEARING ON ITS OWN. DBA's round-4 variant put the reverse edge at FUNCTION
# scope: the cycle is still there, every runtime check passes clean, and only a static edge walk
# sees it. So the graph check is not a proxy for (b) -- it is the only instrument for that shape.

CYCLE_MJS="$TEMP_PROJECT/cycles.mjs"
cat > "$CYCLE_MJS" <<'MJS'
// Static import-edge walk over a scripts dir. Exit 1 and print each cycle when any exists.
import { readdirSync, readFileSync } from "node:fs";
import path from "node:path";
const dir = process.argv[2];
const files = readdirSync(dir).filter((f) => f.endsWith(".mjs"));
const edges = new Map();
for (const f of files) {
  const src = readFileSync(path.join(dir, f), "utf8");
  const out = new Set();
  // static `from "./x.mjs"` and dynamic `import("./x.mjs")` alike: a function-scope edge is an
  // edge, which is the whole point of this check.
  for (const m of src.matchAll(/from\s+["'](\.\/[^"']+\.mjs)["']/g)) out.add(path.basename(m[1]));
  for (const m of src.matchAll(/import\(\s*["'](\.\/[^"']+\.mjs)["']\s*\)/g)) out.add(path.basename(m[1]));
  edges.set(f, [...out].filter((x) => files.includes(x)));
}
const cycles = [];
const state = new Map();
const stack = [];
function dfs(n) {
  state.set(n, 1); stack.push(n);
  for (const m of edges.get(n) || []) {
    if (state.get(m) === 1) cycles.push([...stack.slice(stack.indexOf(m)), m].join(" -> "));
    else if (!state.get(m)) dfs(m);
  }
  stack.pop(); state.set(n, 2);
}
for (const f of files) if (!state.get(f)) dfs(f);
process.stdout.write(`modules=${files.length} cycles=${cycles.length}\n`);
for (const c of cycles) process.stdout.write(`  ${c}\n`);
process.exit(cycles.length ? 1 : 0);
MJS

GRAPH_OUT="$("$GATE_REAL_NODE" "$CYCLE_MJS" "$GATE_PLUGIN_DIR/scripts" 2>&1)"; GRAPH_RC=$?
record "MODULE GRAPH (this tree): $(printf '%s' "$GRAPH_OUT" | head -1)"
assert_eq "AC36(a): zero import cycles among plugins/pipeline/scripts/*.mjs" \
  "$(printf '%s' "$GRAPH_OUT" | sed -n 's/.*cycles=\([0-9]*\).*/\1/p' | head -1)" "0"
assert_eq "AC36(a): and the detector exits 0 on the real tree" "$GRAPH_RC" "0"

# NON-ZERO CONTROL, on a scratch copy: add the reverse edge validate-pipeline-artifact.mjs ->
# gate-phase-entry.mjs and the detector must find it and exit 1. Without this, "0 cycles" is
# equally consistent with a detector that cannot see any edge at all.
CYCLE_SCRATCH="$TEMP_PROJECT/scripts-with-reverse-edge"
mkdir -p "$CYCLE_SCRATCH"
cp "$GATE_PLUGIN_DIR"/scripts/*.mjs "$CYCLE_SCRATCH/" 2>/dev/null
printf '\nimport { IN_FLIGHT_MS as _probe } from "./gate-phase-entry.mjs";\nexport const _reverseEdgeProbe = _probe;\n' \
  >> "$CYCLE_SCRATCH/validate-pipeline-artifact.mjs"
CTRL_OUT="$("$GATE_REAL_NODE" "$CYCLE_MJS" "$CYCLE_SCRATCH" 2>&1)"; CTRL_RC=$?
assert_eq "NON-ZERO CONTROL: with the reverse edge added, the detector reports exactly 1 cycle" \
  "$(printf '%s' "$CTRL_OUT" | sed -n 's/.*cycles=\([0-9]*\).*/\1/p' | head -1)" "1"
assert_eq "NON-ZERO CONTROL: and names the participants" \
  "$([[ "$CTRL_OUT" == *"gate-phase-entry.mjs"* && "$CTRL_OUT" == *"validate-pipeline-artifact.mjs"* ]] && echo named || echo "NOT NAMED: $CTRL_OUT")" "named"
assert_eq "NON-ZERO CONTROL: and exits 1" "$CTRL_RC" "1"

# FUNCTION-SCOPE VARIANT: the edge that every runtime check passes clean. The static walk must
# still see it, or (a) is not load-bearing and (b) is the only instrument -- which DBA proved
# it cannot be.
FN_SCRATCH="$TEMP_PROJECT/scripts-with-fn-scope-edge"
mkdir -p "$FN_SCRATCH"
cp "$GATE_PLUGIN_DIR"/scripts/*.mjs "$FN_SCRATCH/" 2>/dev/null
printf '\nexport async function _fnScopeProbe() { const m = await import("./gate-phase-entry.mjs"); return m.IN_FLIGHT_MS; }\n' \
  >> "$FN_SCRATCH/validate-pipeline-artifact.mjs"
FN_OUT="$("$GATE_REAL_NODE" "$CYCLE_MJS" "$FN_SCRATCH" 2>&1)"
assert_eq "AC36(a): a FUNCTION-SCOPE reverse edge is still a cycle and is still detected" \
  "$(printf '%s' "$FN_OUT" | sed -n 's/.*cycles=\([0-9]*\).*/\1/p' | head -1)" "1"

# The module count is a present-tense fact, so a stale expectation fails loudly rather than
# passing confidently: 16 at the reviewed commit, 17 once R6's leaf module lands.
MODULE_N="$(printf '%s' "$GRAPH_OUT" | sed -n 's/modules=\([0-9]*\).*/\1/p' | head -1)"
assert_eq "AC36: R6's LEAF module has landed, so scripts/ holds 17 modules, not the reviewed commit's 16" \
  "$MODULE_N" "17"

# ===============================================================================================
suite "AC36(b): three entry directions, PAIRED SAME-RUN CAPTURE against the reviewed commit"
# ===============================================================================================
#
# NOT an assertion against a transcribed number. gate-phase-entry.mjs's entire output is a
# function of the .pipeline record store under cwd, and .pipeline/<issue>/status.json is TRACKED
# and rewritten by this issue's own checkpoint commits, so any literal recorded here is stale
# before it is read. So: check out the reviewed commit into its own worktree, and run BOTH trees
# from the SAME pinned cwd against the SAME record-store state, inside one invocation.

BASE_SHA="$(git -C "$GATE_REPO_ROOT" merge-base HEAD origin/main 2>/dev/null || git -C "$GATE_REPO_ROOT" rev-parse HEAD~1 2>/dev/null || printf '')"
BASE_WT="$TEMP_PROJECT/base-tree"
BASE_OK=no
if [[ -n "$BASE_SHA" ]] && git -C "$GATE_REPO_ROOT" worktree add -q --detach "$BASE_WT" "$BASE_SHA" >/dev/null 2>&1; then
  BASE_OK=yes
fi
assert_eq "PRECONDITION: the reviewed commit is checked out for the paired capture (an unpinned comparison measures the runner)" \
  "$BASE_OK" "yes"
record "PAIRED CAPTURE BASE: $BASE_SHA"

# One pinned cwd, one record-store state, both trees.
PINNED_CWD="$TEMP_PROJECT/pinned-cwd"
gate_inflight_status "$PINNED_CWD/.pipeline/106/status.json" "4-review"

capture3() {  # <scripts-dir> -> "rc|stdout|stderr" for each of the three entry directions
  local sd="$1" out
  out=""
  local o e r
  o="$( ( cd "$PINNED_CWD" && "$GATE_REAL_NODE" "$sd/gate-phase-entry.mjs" 2>"$TEMP_PROJECT/e1" ) )"; r=$?
  e="$(cat "$TEMP_PROJECT/e1")"
  out="CLI rc=$r out=[$o] err=[$e]"
  o="$( ( cd "$PINNED_CWD" && "$GATE_REAL_NODE" --input-type=module -e "import('file://$sd/gate-phase-entry.mjs').then(()=>{}).catch(err=>{console.error(String(err&&err.message));process.exit(1)})" 2>"$TEMP_PROJECT/e2" ) )"; r=$?
  e="$(cat "$TEMP_PROJECT/e2")"
  out="$out
EVAL-IMPORT rc=$r out=[$o] err=[$e]"
  o="$( ( cd "$PINNED_CWD" && printf '%s' '{"hook_event_name":"SubagentStop","session_id":"paired","agent_type":"pipeline:qa"}' \
        | CLAUDE_PROJECT_DIR="$PINNED_CWD" "$GATE_REAL_NODE" "$sd/validate-pipeline-artifact.mjs" 2>"$TEMP_PROJECT/e3" ) )"; r=$?
  # The #115 attribution line is a DELIBERATE difference from the reviewed commit: the validator
  # now writes one `agent-pipeline SubagentStop: ...` line to stderr on every stop, because before
  # it a lookup miss and a clean artifact were byte-identical. It is stripped HERE and only here,
  # so exit code, stdout and every OTHER stderr byte stay pinned; a SECOND new stderr line would
  # still redden this. The premise -- that the line exists at HEAD and not at the base -- is
  # asserted in test-pretooluse-gate-ownership.sh's AC28 FILTER PREMISE pair.
  e="$(grep -v '^agent-pipeline SubagentStop: ' "$TEMP_PROJECT/e3" || true)"
  out="$out
VALIDATOR-STDIN rc=$r out=[$o] err=[$e]"
  printf '%s' "$out"
}

if [[ "$BASE_OK" == "yes" ]]; then
  CAP_BASE="$(capture3 "$BASE_WT/plugins/pipeline/scripts")"
  CAP_HEAD="$(capture3 "$GATE_PLUGIN_DIR/scripts")"
  record "PAIRED CAPTURE, reviewed commit: $(printf '%s' "$CAP_BASE" | tr '\n' ' | ')"
  assert_eq "AC36(b): all three entry directions produce the reviewed commit's exit code, stdout and stderr, byte for byte" \
    "$CAP_HEAD" "$CAP_BASE"
  # VACUITY: the capture must have produced something. Two empty strings are equal.
  assert_eq "VACUITY: the paired capture is non-empty and names all three directions" \
    "$([[ "$CAP_BASE" == *"CLI rc="* && "$CAP_BASE" == *"EVAL-IMPORT rc="* && "$CAP_BASE" == *"VALIDATOR-STDIN rc="* ]] && echo three || echo "INCOMPLETE: $CAP_BASE")" "three"
  git -C "$GATE_REPO_ROOT" worktree remove --force "$BASE_WT" >/dev/null 2>&1
else
  assert_eq "AC36(b): the paired capture could not run (the reviewed commit did not check out) -- reported as a FAILURE, never a skip" \
    "could-not-check-out-$BASE_SHA" "ran"
fi

# ===============================================================================================
suite "AC36(c): the additive export introduces no module-scope side effect"
# ===============================================================================================
#
# The structural clause ("no new module-scope statement beyond the declarations themselves") is
# asserted through its OBSERVABLE consequence: importing the module writes nothing, prints
# nothing, and creates no file. A statement-count assertion would need a parser and would redden
# on a reformat; the side-effect observation is what the requirement is for.

SIDE_DIR="$TEMP_PROJECT/side-effect-probe"
mkdir -p "$SIDE_DIR"
# The manifest lives OUTSIDE the walked root. Kept inside, the snapshot's own file registers as a
# new file on the next walk and the check reports a side effect the module never had.
SIDE_MANIFEST="$TEMP_PROJECT/side-effect-manifest.json"
gate_sink_snap "$SIDE_MANIFEST" "$SIDE_DIR"
SIDE_OUT="$( ( cd "$SIDE_DIR" && TMPDIR="$SIDE_DIR" "$GATE_REAL_NODE" --input-type=module \
  -e "await import('file://$GATE_PLUGIN_DIR/scripts/validate-pipeline-artifact.mjs')" 2>"$SIDE_DIR/err" ) )"
SIDE_ERR="$(cat "$SIDE_DIR/err" 2>/dev/null)"
rm -f "$SIDE_DIR/err"
assert_eq "AC36(c): importing validate-pipeline-artifact.mjs prints nothing on stdout" "$SIDE_OUT" ""
assert_eq "AC36(c): and nothing on stderr" "$SIDE_ERR" ""
assert_eq "AC36(c): and creates no file in its cwd or TMPDIR" "$(gate_sink_count "$SIDE_MANIFEST" "$SIDE_DIR")" "0"

finish
