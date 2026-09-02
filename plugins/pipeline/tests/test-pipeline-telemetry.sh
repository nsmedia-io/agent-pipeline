#!/usr/bin/env bash
# The status.json half of issue #17: the shard-fallback path, the panel_roles enum, the
# derived telemetry, the effective-config audit record, and the no-absolute-paths rule.
#
# The thread running through all of it: status.json is committed AND archived verbatim by the
# Librarian, so anything written into it is written into a public tree. The schema used to
# carry a sentence claiming worktree_path "should be redacted before this file is archived",
# and NOTHING redacted anything -- `grep -rn redact plugins/pipeline/` returned three prose
# hits and no code. A prose claim about a control that does not exist is worse than no claim,
# so it is replaced by a PROHIBITION and by the assertion below that can go red.

. "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
require_node

make_temp_project || exit 90

PLUGIN_DIR="$PLUGIN_ROOT"
PIPELINE_MD="$PLUGIN_DIR/commands/pipeline.md"
SCHEMA="$PLUGIN_DIR/schemas/status.schema.json"
TELEMETRY="$SCRIPTS_DIR/pipeline-telemetry.mjs"
MERGE="$SCRIPTS_DIR/merge-peer-review.mjs"
REPO_ROOT="$(cd "$PLUGIN_DIR/../.." && pwd)"

node_run() { MOD="$1"; shift; MOD="$MOD" node --input-type=module -e "$@"; }

# --- BEGIN corpus helper (issue #30 D1) ---
# ONE corpus build, parameterised by PATTERN, shared by every site below that needs a set of
# status-shaped records. It lives in a marker-delimited block because test-corpus-union.sh
# extracts and DRIVES these two functions against a temp git tree: a function buried mid-suite
# cannot be driven, so its cells could only ever be reimplementations asserting themselves.
#
# WHY THE UNION. A tracked-only corpus cannot see an untracked in-flight record -- which is
# exactly where an absolute path gets written -- and the workaround (commit one status record
# per issue) makes this suite's colour a function of how far the run under review has itself
# progressed: the walk reads PATHS from the index but CONTENT from disk, so this pipeline's own
# checkpoint moved the suite from 95/1 to 96/0 at the same commit with nothing in plugins/
# changed. The union can only ever WIDEN the population, never narrow it.
#
# WHY THE PATTERN IS AN ARGUMENT, and not a convenience. One un-parameterised helper is wrong
# in both directions. On a `.pipeline`-only pattern it silently drops the issue-archive half of
# the absolute-path population -- a coverage narrowing inside the fix for coverage narrowing.
# On a blind union it feeds archive JSONs into the partition walk, where they parse fine, carry
# no events, land in tooShort, and redden the in-flight property the day the first archive
# lands, for a reason that has nothing to do with telemetry.
#
# corpus_files <repo-root> <pattern> [<pattern>...]
#   Prints the deduplicated union of the tracked set and an on-disk enumeration for the same
#   patterns, repo-relative, one path per line.
corpus_files() {
  local root="$1"; shift
  local pattern p
  {
    for pattern in "$@"; do
      ( cd "$root" 2>/dev/null && git ls-files -- "$pattern" 2>/dev/null )
      ( cd "$root" 2>/dev/null && shopt -s nullglob && for p in $pattern; do
          [[ -f "$p" ]] && printf '%s\n' "$p"
        done )
    done
  } | LC_ALL=C sort -u
}

# in_flight_short <status-file>
#   Exit 0 iff the record is a SHORT IN-FLIGHT one. All three conjuncts are load-bearing.
#   Dropping the events-array conjunct would make the predicate a restatement of half of
#   tooShort's own definition (`!Array.isArray(events) || events.length < 2`), which can
#   essentially never fail, and would silently excuse a malformed record that carries a
#   current_phase and no events array at all. Unreadable exits non-zero. Prints nothing, so the
#   verdict is the exit status and a debug line cannot masquerade as one.
in_flight_short() {
  node -e '
    const fs = require("fs");
    let s;
    try { s = JSON.parse(fs.readFileSync(process.argv[1], "utf8")); } catch { process.exit(2); }
    const ok = typeof s.current_phase === "string" && s.current_phase !== ""
      && Array.isArray(s.events) && s.events.length < 2;
    process.exit(ok ? 0 : 1);
  ' "$1" >/dev/null 2>&1
}
# --- END corpus helper ---

# =============================================================================
# AC13 -- THE PHASE 4 SHARD FALLBACK.
# =============================================================================
suite "AC13: the fallback directory is materially different from ARTIFACT_DIR"

# The old instruction told a reviewer whose write was refused to retry at
# <WORKTREE_PATH>/.pipeline/<issue>/, which IS <ARTIFACT_DIR> -- the same path, so a refused
# write had nowhere to go. Asserted as a STRING property of the instruction, because that is
# what a reviewer reads.
assert_eq "the preamble no longer names the worktree .pipeline dir as the fallback" \
  "$(grep -c 'write the shard beside your own worktree at <WORKTREE_PATH>/.pipeline/<issue>/' "$PIPELINE_MD" | tr -d ' ')" "0"
assert_eq "it names a distinct subdirectory instead" \
  "$(grep -c 'fallback-shards/peer-review.<role>.json' "$PIPELINE_MD" | tr -d ' ')" "1"

# The fallback is only worth anything if the MERGE reads it. Extracted from the merge block
# the orchestrator actually runs, not from prose about it.
MERGE_BLOCK="$TEMP_PROJECT/merge-block.sh"
awk '/^# Full round: reset, then fold every dispatched role/{f=1} f{print} f&&/^```$/{exit}' "$PIPELINE_MD" \
  | grep -v '^```' > "$MERGE_BLOCK"
assert_eq "the merge block was extracted (without this, the next assertion measures an empty file)" \
  "$([[ -s "$MERGE_BLOCK" ]] && echo yes || echo no)" "yes"
assert_eq "and it falls back to that directory before declaring a shard missing" \
  "$(grep -c 'fallback-shards' "$MERGE_BLOCK" | tr -d ' ')" "1"
assert_eq "the fallback is consulted BEFORE the missing-shard branch" \
  "$([[ "$(grep -n 'fallback-shards' "$MERGE_BLOCK" | cut -d: -f1)" -lt "$(grep -n 'MISSING SHARD' "$MERGE_BLOCK" | cut -d: -f1)" ]] && echo before || echo after)" \
  "before"

suite "AC13: a shard that lands NOWHERE still HALTS -- recoverability never became leniency"

# The fail direction is the point. Run the real merge script against a missing shard: a lost
# VETO must never merge as an absent-therefore-fine review.
MDIR="$TEMP_PROJECT/merge-fixture"
mkdir -p "$MDIR"
printf '%s' '{"verdict":"APPROVE","reviewed_at":"2026-08-01T00:00:00Z"}' > "$MDIR/peer-review.ba.json"
( cd "$MDIR" && node "$MERGE" "$MDIR/peer-review.json" ba="$MDIR/peer-review.ba.json" >/dev/null 2>&1 )
assert_eq "a present shard merges (exit 0), so the halt below is not the script refusing everything" "$?" "0"
( cd "$MDIR" && node "$MERGE" "$MDIR/peer-review.json" secops="$MDIR/peer-review.secops.json" >/dev/null 2>&1 )
assert_eq "a shard that exists nowhere HALTS with exit 2" "$?" "2"

# =============================================================================
# AC14 / AC15 -- panel_roles accepts all eight roles, and its description is true.
# =============================================================================
suite "AC14: panel_roles accepts the eight roles the orchestrator can actually append"

ROLES_OK=$(SCHEMA="$SCHEMA" node --input-type=module -e '
  import { readFileSync } from "node:fs";
  const schema = JSON.parse(readFileSync(process.env.SCHEMA, "utf8"));
  const allowed = schema.properties.panel_roles.items.enum;
  const want = ["ba","dba","devops","secops","dev","qa","design_review","art_director"];
  console.log(want.every(r => allowed.includes(r)) ? "all-accepted" : "missing:" + want.filter(r=>!allowed.includes(r)).join(","));
')
assert_eq "every role the panel can carry is in the enum" "$ROLES_OK" "all-accepted"
# NON-ZERO CONTROL: the enum is a real allowlist, not an any-string field that would accept
# a typo'd role and silently drop it from the rubric.
assert_eq "CONTROL: an invented role is still rejected by the enum" \
  "$(SCHEMA="$SCHEMA" node --input-type=module -e '
     import { readFileSync } from "node:fs";
     const s = JSON.parse(readFileSync(process.env.SCHEMA, "utf8"));
     console.log(s.properties.panel_roles.items.enum.includes("nonsense") ? "accepted" : "rejected");
   ')" "rejected"

suite "AC15: the description no longer contradicts what the orchestrator appends"

assert_eq "the 'tracked via its own shard' claim is gone" \
  "$(grep -c 'design_review lens is tracked via its own shard' "$SCHEMA" | tr -d ' ')" "0"
assert_eq "and the description says design_review is APPENDED to this array" \
  "$(grep -c 'design_review is APPENDED TO THIS ARRAY' "$SCHEMA" | tr -d ' ')" "1"
assert_eq "CONTROL: commands/pipeline.md really does append it (the fact the description now states)" \
  "$(grep -c 'PANEL_ROLES="$PANEL_ROLES design_review"' "$PIPELINE_MD" | tr -d ' ')" "1"

# =============================================================================
# AC16 -- the telemetry computation, against known timestamps.
# =============================================================================
suite "AC16: per-phase elapsed and lead time are the exact values the fixture implies"

FIX='{"review_rounds":2,"events":[
  {"phase":"1-ba","verdict":"APPROVE","at":"2026-08-01T00:00:00Z"},
  {"phase":"2-review","verdict":"APPROVE","at":"2026-08-01T01:00:00Z"},
  {"phase":"3-impl","verdict":"APPROVE","at":"2026-08-01T03:30:00Z"},
  {"phase":"4-review","verdict":"APPROVE","at":"2026-08-01T04:00:00Z"},
  {"phase":"4-review-complete","verdict":"APPROVE","at":"2026-08-01T05:00:00Z"}]}'
T=$(MOD="$TELEMETRY" FIX="$FIX" node --input-type=module -e '
  const m = await import(process.env.MOD);
  const t = m.telemetry(JSON.parse(process.env.FIX));
  console.log(JSON.stringify(t));
')
# EXIT-MARKER VALUES. Each interval is credited to the phase the LATER event CLOSED, so the
# 1-ba -> 2-review hour belongs to phase 2, and phase 4 absorbs BOTH of its boundaries (the
# half hour into 4-review and the hour into 4-review-complete, whose leading token is also 4).
assert_eq "phase 2 elapsed is exactly one hour"     "$(printf '%s' "$T" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).phase_elapsed_ms["2"]))')" "3600000"
assert_eq "phase 3 elapsed is exactly two and a half hours" "$(printf '%s' "$T" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).phase_elapsed_ms["3"]))')" "9000000"
assert_eq "phase 4 absorbs both its boundaries: half an hour plus an hour" "$(printf '%s' "$T" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).phase_elapsed_ms["4"]))')" "5400000"
# THE MIRROR PROPERTY, asserted rather than left implicit: under exit markers the FIRST phase's
# START is genuinely unrecorded, so phase 1 gets no key here. It is not a dropped interval --
# there is no earlier event to measure from -- and inventing one from started_at is forbidden
# (on the real #17 record that would report 91,271,177 ms instead of 6,545).
assert_eq "the first phase gets no key, because nothing recorded when it started" \
  "$(printf '%s' "$T" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(Object.prototype.hasOwnProperty.call(JSON.parse(s).phase_elapsed_ms,"1")))')" "false"
assert_eq "total lead time is exactly five hours"   "$(printf '%s' "$T" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).total_lead_time_ms))')" "18000000"
assert_eq "review_rounds is the recorded counter, not a guess" "$(printf '%s' "$T" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).review_rounds))')" "2"

# The counter is EXPLICIT because events[] has no round field. When it is absent the number of
# 4-review ENTRIES is the honest floor, and that fallback is asserted rather than assumed.
T2=$(MOD="$TELEMETRY" node --input-type=module -e '
  const m = await import(process.env.MOD);
  console.log(m.telemetry({events:[{phase:"4-review",verdict:"REQUEST_CHANGES",at:"2026-08-01T00:00:00Z"},{phase:"4-review-complete",verdict:"APPROVE",at:"2026-08-01T01:00:00Z"},{phase:"4-review",verdict:"REQUEST_CHANGES",at:"2026-08-02T00:00:00Z"},{phase:"4-review-complete",verdict:"APPROVE",at:"2026-08-02T01:00:00Z"}]}).review_rounds);
')
assert_eq "with no counter recorded, the phase-4 entries are counted instead" "$T2" "2"

# -----------------------------------------------------------------------------
# The hand-maintained counter, checked against the events it claims to summarize.
# NOT EVERY 4-review EVENT IS A ROUND: the committed corpus writes delta-dispatch ENTRY markers
# (delta-dispatched, DELTA) and a `merged` TERMINUS under the same phase label. The shape below
# is the real #43 record's verdict sequence, which counts 4 entries against 2 actual panels --
# the exact overcount that made a wrong counter look right.
FIX_MARKERS='{"review_rounds":4,"events":[
  {"phase":"4-review","verdict":"REQUEST_CHANGES","at":"2026-08-01T00:00:00Z"},
  {"phase":"4-review","verdict":"delta-dispatched","at":"2026-08-01T01:00:00Z"},
  {"phase":"4-review","verdict":"APPROVE_WITH_NOTES","at":"2026-08-01T02:00:00Z"},
  {"phase":"4-review","verdict":"merged","at":"2026-08-01T03:00:00Z"}]}'
rr() { MOD="$TELEMETRY" FIX="$1" node --input-type=module -e '
  const m = await import(process.env.MOD);
  console.log(String(m.telemetry(JSON.parse(process.env.FIX))[process.env.F]));
'; }
F=review_rounds_observed
assert_eq "a delta-dispatch marker and a merge terminus are NOT panel rounds"   "$(F=review_rounds_observed rr "$FIX_MARKERS")" "2"
assert_eq "and the recorded counter's disagreement is reported as a signed number"   "$(F=review_rounds_recorded_delta rr "$FIX_MARKERS")" "2"
# THE OTHER DIRECTION, which is the one a round budget would silently pass: the real #56 record
# records 1 while three panels returned verdicts. A budget reading review_rounds alone binds on
# 1 and never trips.
FIX_UNDER='{"review_rounds":1,"events":[
  {"phase":"4-review","verdict":"REQUEST_CHANGES","at":"2026-08-01T00:00:00Z"},
  {"phase":"4-review","verdict":"DELTA","at":"2026-08-01T01:00:00Z"},
  {"phase":"4-review","verdict":"APPROVE_WITH_NOTES","at":"2026-08-01T02:00:00Z"},
  {"phase":"4-review","verdict":"APPROVE_WITH_NOTES","at":"2026-08-01T03:00:00Z"}]}'
assert_eq "an undercounting counter reports a NEGATIVE delta, so the direction survives"   "$(F=review_rounds_recorded_delta rr "$FIX_UNDER")" "-2"
# A run that never entered phase 4 while carrying a counter -- the real #17 and #39 shape.
assert_eq "a counter on a run that never reached a panel is caught too"   "$(F=review_rounds_recorded_delta rr '{"review_rounds":1,"events":[{"phase":"3-impl","verdict":"APPROVE","at":"2026-08-01T00:00:00Z"}]}')" "1"
# CONTROL: the delta is not non-zero for everything. An agreeing counter reports exactly 0, so
# a non-zero reading is a disagreement rather than an artifact of the arithmetic.
assert_eq "CONTROL: a counter that agrees with the events reports a delta of exactly 0"   "$(F=review_rounds_recorded_delta rr '{"review_rounds":2,"events":[{"phase":"4-review","verdict":"REQUEST_CHANGES","at":"2026-08-01T00:00:00Z"},{"phase":"4-review","verdict":"APPROVE","at":"2026-08-01T01:00:00Z"}]}')" "0"
# CONTROL: and an unrecognized verdict is a MARKER, not a round, so a typo cannot inflate the
# floor into agreeing with a counter that is wrong.
assert_eq "CONTROL: an unrecognized verdict counts as a marker, keeping the floor a floor"   "$(F=review_rounds_observed rr '{"events":[{"phase":"4-review","verdict":"APROVE_TYPO","at":"2026-08-01T00:00:00Z"}]}')" "0"
assert_eq "an empty status yields a null lead time, not a fabricated zero" \
  "$(MOD="$TELEMETRY" node --input-type=module -e 'const m=await import(process.env.MOD);console.log(String(m.telemetry({}).total_lead_time_ms))')" "null"
# The numbers-only rule, checked against a CLOSED allowlist rather than a shape regex. The
# regex this replaces was `[0-9.]+` for the phase keys, which would have rejected the "3a"/"3b"
# keys the parser now emits, so the guard and the accounting are pinned to the same declared
# set: the field names, plus KNOWN_PHASES. A phase key that is not a declared phase is exactly
# the free-text leak this assertion exists to catch.
FIX_SUFFIXED='{"review_rounds":1,"events":[
  {"phase":"3a-qa-tests","verdict":"APPROVE","at":"2026-08-01T00:00:00Z"},
  {"phase":"3b-dev","verdict":"APPROVE","at":"2026-08-01T01:00:00Z"},
  {"phase":"4-review","verdict":"APPROVE","at":"2026-08-01T02:00:00Z"}]}'
LEAK_CHECK="$TEMP_PROJECT/leak-check.mjs"
cat > "$LEAK_CHECK" <<'EOF'
// Counts strings in a telemetry-shaped object that are neither a declared field name nor a
// declared phase label. Run over telemetry() output, and over a crafted object as its control.
import { readFileSync } from "node:fs";
const d = await import(process.env.DISPATCH);
// The field names come from the SCHEMA, not from a list hand-copied into this file. A copied
// list tracks whoever last remembered to update it: adding a field to telemetry() without
// touching this line used to redden here for the wrong reason, reporting a "leak" that was
// really a stale allowlist. Read from the schema, the check stays about leaks, and a field
// that telemetry() emits without declaring is still caught -- by the closed-object assertion
// and the emitted-keys-are-declared assertion further down, which are its two other halves.
const schema = JSON.parse(readFileSync(process.env.SCHEMA, "utf8"));
const props = schema.properties.telemetry.properties;
// The enum VALUES are read from the schema for the same reason the names are. `attribution`
// emits the literal "exit", which is a string value in a numbers-only record, so without this
// the marker that says which convention produced the figures would itself read as a leak. It
// is a CLOSED widening: only values the schema declares as an enum are admitted, so free text
// in the same field still counts -- which is what the control below measures.
const enumValues = Object.values(props).flatMap((p) => (Array.isArray(p.enum) ? p.enum : []));
const allowed = new Set([...Object.keys(props), ...d.KNOWN_PHASES, ...enumValues]);
let obj;
if (process.env.OBJ) {
  obj = JSON.parse(process.env.OBJ);
} else {
  const m = await import(process.env.MOD);
  obj = m.telemetry(JSON.parse(process.env.FIX));
}
console.log(JSON.stringify(obj).match(/"[^"]*"/g).map((s) => s.slice(1, -1)).filter((s) => !allowed.has(s)).length);
EOF
notes_leaked() { MOD="$TELEMETRY" DISPATCH="$SCRIPTS_DIR/dispatch-model.mjs" SCHEMA="$SCHEMA" FIX="$1" node "$LEAK_CHECK"; }
assert_eq "and nothing it emits is a free-text note, a path, or a command string" \
  "$(notes_leaked "$FIX")" "0"
assert_eq "including on the suffixed 3a/3b shape, whose keys are declared phases and not free text" \
  "$(notes_leaked "$FIX_SUFFIXED")" "0"
assert_eq "CONTROL: the same check reports 4 on an object carrying a note and a path (two keys, two values)" \
  "$(DISPATCH="$SCRIPTS_DIR/dispatch-model.mjs" SCHEMA="$SCHEMA" OBJ='{"phase_elapsed_ms":{"3a":1},"note":"loop back to BA","worktree_path":"/Users/x/wt"}' node "$LEAK_CHECK")" \
  "4"
# CONTROL ON THE WIDENING ITSELF. Admitting declared enum values is not "admit all strings":
# free text in the very field the widening was made for still leaks.
assert_eq "CONTROL: free text in \`attribution\` still leaks, so the enum widening is closed" \
  "$(DISPATCH="$SCRIPTS_DIR/dispatch-model.mjs" SCHEMA="$SCHEMA" OBJ='{"phase_elapsed_ms":{"3a":1},"attribution":"loop back to BA"}' node "$LEAK_CHECK")" \
  "1"

# =============================================================================
# AC16(b) -- THE PARTITION PROPERTY, and the 39% of a real run the old parser dropped.
# =============================================================================
#
# The escape: phaseNumber() was /^([0-5](?:\.5)?)-/, and this pipeline writes "3a-qa-tests"
# and "3b-dev" for its two implementation steps (both declared in KNOWN_PHASES). Neither
# matched, both hit the caller's `if (!key) continue`, and there was no "3" key at all in the
# output. Measured on this change's OWN status.json: total_lead_time_ms 10,465,309 against a
# phase sum of 6,376,821, leaving 4,088,488 ms unattributed -- 68 minutes, 39% of the run, and
# the single longest phase in it. Every fixture in the suite above uses well-formed "N-"
# labels, so all of it stayed green while the function under-reported.
#
# The assertion that makes the CLASS impossible to reintroduce is not "3a is now attributed"
# (a later "3c-" would escape it again) but the PARTITION: every millisecond between the first
# and last event is either credited to a phase or reported as unattributed. A parser that
# cannot read a future label shape then fails LOUDLY -- as a non-zero number in a committed
# file -- rather than silently dropping the time.

suite "AC16(b): sum(phase_elapsed_ms) + unattributed_ms == total_lead_time_ms"

# The property is checked by the harness, over any fixture, so a case below reads as the
# INPUT it is about rather than as arithmetic.
PARTITION="$TEMP_PROJECT/partition.mjs"
cat > "$PARTITION" <<'EOF'
const m = await import(process.env.MOD);
const t = m.telemetry(JSON.parse(process.env.FIX));
const sum = Object.values(t.phase_elapsed_ms).reduce((a, b) => a + b, 0);
const balances = sum + t.unattributed_ms === t.total_lead_time_ms;
console.log(JSON.stringify({
  balances, sum, unattributed_ms: t.unattributed_ms,
  unattributed_events: t.unattributed_events,
  untimed_events: t.untimed_events, events_counted: t.events_counted,
  total: t.total_lead_time_ms, keys: Object.keys(t.phase_elapsed_ms).sort().join(","),
  gap: t.total_lead_time_ms - sum,
}));
EOF
part() { MOD="$TELEMETRY" FIX="$1" node "$PARTITION"; }
field() { printf '%s' "$1" | node -e "let s='';process.stdin.on('data',d=>s+=d).on('end',()=>console.log(String(JSON.parse(s).$2)))"; }

# (1) THE REAL SHAPE. A fixture carrying the 3a-/3b- events this pipeline actually writes,
# with the real gap between them: 03:07:21.453 -> 04:15:29.941 is 4,088,488 ms. Under EXIT
# markers that gap is Dev's, credited to the 3b event that CLOSED it -- the whole point of the
# convention, and the number this pipeline's own run used to credit to QA.
REAL='{"review_rounds":1,"events":[
  {"phase":"2.5-design","verdict":"SKIPPED","at":"2026-08-19T02:41:49.314Z"},
  {"phase":"3a-qa-tests","verdict":"APPROVE","at":"2026-08-19T03:07:21.453Z"},
  {"phase":"3b-dev","verdict":"APPROVE","at":"2026-08-19T04:15:29.941Z"},
  {"phase":"4-review","verdict":"APPROVE","at":"2026-08-19T05:00:00.000Z"},
  {"phase":"4-review-complete","verdict":"APPROVE","at":"2026-08-19T05:30:00.000Z"}]}'
REAL_OUT=$(part "$REAL")
assert_eq "the partition balances on the real 3a/3b shape" "$(field "$REAL_OUT" balances)" "true"
assert_eq "3a is a key in its own right, at the elapsed its own event closed" \
  "$(MOD="$TELEMETRY" FIX="$REAL" node --input-type=module -e '
     const m = await import(process.env.MOD);
     console.log(String(m.telemetry(JSON.parse(process.env.FIX)).phase_elapsed_ms["3a"]));
   ')" "1532139"
assert_eq "3b is its own key too, carrying the 4,088,488 ms that used to land on 3a" \
  "$(MOD="$TELEMETRY" FIX="$REAL" node --input-type=module -e '
     const m = await import(process.env.MOD);
     console.log(String(m.telemetry(JSON.parse(process.env.FIX)).phase_elapsed_ms["3b"]));
   ')" "4088488"
assert_eq "nothing is unattributed on a run whose every label is declared" \
  "$(field "$REAL_OUT" unattributed_ms)" "0"
# 2.5 opens the record, so under exit markers it has no closing interval of its own and gets no
# key. Its own elapsed time would need an event BEFORE it, and there is none.
assert_eq "the keys are exactly the phases the events CLOSED" \
  "$(field "$REAL_OUT" keys)" "3a,3b,4"
# THE REGRESSION, named as the number it was. Before the fix this gap was 4088488.
assert_eq "no time is missing between the phase sum and the lead time" "$(field "$REAL_OUT" gap)" "0"

# (2) NON-ZERO CONTROL on the partition itself. An UNDECLARED label must not balance to zero
# unattributed: without this case, `unattributed_ms == 0` above could be a field hard-wired to
# 0 and the partition would still "hold".
FUTURE='{"events":[
  {"phase":"3a-qa-tests","verdict":"APPROVE","at":"2026-08-19T00:00:00Z"},
  {"phase":"9z-some-future-phase","verdict":"APPROVE","at":"2026-08-19T01:00:00Z"},
  {"phase":"4-review","verdict":"APPROVE","at":"2026-08-19T03:00:00Z"}]}'
FUTURE_OUT=$(part "$FUTURE")
assert_eq "an UNDECLARED phase label still balances the partition" "$(field "$FUTURE_OUT" balances)" "true"
# The undeclared label CLOSES the first interval, so it is that hour which no key can absorb.
assert_eq "and its time is REPORTED as unattributed rather than dropped" \
  "$(field "$FUTURE_OUT" unattributed_ms)" "3600000"
assert_eq "with the boundary count that says how many labels it could not read" \
  "$(field "$FUTURE_OUT" unattributed_events)" "1"
assert_eq "CONTROL: the declared label in the SAME fixture is still attributed normally" \
  "$(MOD="$TELEMETRY" FIX="$FUTURE" node --input-type=module -e '
     const m = await import(process.env.MOD);
     console.log(String(m.telemetry(JSON.parse(process.env.FIX)).phase_elapsed_ms["4"]));
   ')" "7200000"

# (3) The partition over the shapes the old parser DID read, so the fix did not buy the new
# property by breaking the old one.
PLAIN='{"events":[
  {"phase":"0.5-map","verdict":"OK","at":"2026-08-01T00:00:00Z"},
  {"phase":"1-ba","verdict":"APPROVE","at":"2026-08-01T00:30:00Z"},
  {"phase":"2-review","verdict":"APPROVE","at":"2026-08-01T01:00:00Z"},
  {"phase":"2.5-design","verdict":"SKIPPED","at":"2026-08-01T02:00:00Z"},
  {"phase":"3-impl","verdict":"APPROVE","at":"2026-08-01T02:30:00Z"},
  {"phase":"5-archive","verdict":"DONE","at":"2026-08-01T03:00:00Z"}]}'
assert_eq "the partition balances on well-formed N- labels too" "$(field "$(part "$PLAIN")" balances)" "true"
assert_eq "and nothing there is unattributed" "$(field "$(part "$PLAIN")" unattributed_ms)" "0"

# (4) Out-of-order timestamps. A negative delta is still not a duration, so it is not credited
# to a phase -- but it is not silently discarded either, which is what would break the
# partition and reopen the same class through a different door.
BACKWARDS='{"events":[
  {"phase":"1-ba","verdict":"APPROVE","at":"2026-08-01T02:00:00Z"},
  {"phase":"2-review","verdict":"APPROVE","at":"2026-08-01T01:00:00Z"},
  {"phase":"3-impl","verdict":"APPROVE","at":"2026-08-01T03:00:00Z"}]}'
BACK_OUT=$(part "$BACKWARDS")
assert_eq "the partition balances even when events[] runs backwards" "$(field "$BACK_OUT" balances)" "true"
assert_eq "the backwards boundary is carried as a NEGATIVE unattributed value, which is the signal" \
  "$(field "$BACK_OUT" unattributed_ms)" "-3600000"
# (4b) The vacuous case, which a real record in this repo's corpus actually is: events with no
# parseable `at`. There is no lead time to partition, so the honest answer is null and a zero
# bucket -- never a fabricated 0 total that would make the partition "hold" by inventing one.
assert_eq "events with no timestamps yield a null lead time" \
  "$(MOD="$TELEMETRY" node --input-type=module -e '
     const m = await import(process.env.MOD);
     const t = m.telemetry({events:[{phase:"1-ba",verdict:"APPROVE"},{phase:"3a-qa-tests",verdict:"APPROVE"}]});
     console.log(String(t.total_lead_time_ms) + "/" + t.unattributed_ms + "/" + t.events_counted);
   ')" "null/0/0"

# (4c) THE MIXED CASE, which is where the partition was VACUOUS. Only the all-untimed shape
# above was ever tested, and it is the one shape where the omission cannot show: with zero
# timed events there is no lead time at all, so the honest null is returned either way.
#
# The defect: every figure -- total_lead_time_ms INCLUDED -- is computed over the SURVIVING
# events, so a dropped event shrinks the numerator and the denominator together. The partition
# then balances perfectly and reports unattributed_ms: 0 while an event has vanished. It is a
# true statement about a population that quietly lost a member, and the balance is what makes
# it convincing. QA's fixture, exactly: three events, the middle one with an unparseable `at`.
MIXED='{"events":[
  {"phase":"1-ba","verdict":"APPROVE","at":"2026-08-01T00:00:00Z"},
  {"phase":"3a-qa-tests","verdict":"APPROVE","at":"not-a-date"},
  {"phase":"5-archive","verdict":"DONE","at":"2026-08-01T02:00:00Z"}]}'
MIXED_OUT=$(part "$MIXED")
assert_eq "the mixed record still balances -- which is exactly why the balance alone proves nothing" \
  "$(field "$MIXED_OUT" balances)" "true"
assert_eq "and reports zero unattributed time, because the dropped event carried no duration" \
  "$(field "$MIXED_OUT" unattributed_ms)" "0"
# THE REPAIR: the drop is now a visible number instead of an absence.
assert_eq "the dropped event is COUNTED, so the balance above is read against what it covered" \
  "$(MOD="$TELEMETRY" FIX="$MIXED" node --input-type=module -e '
     const m = await import(process.env.MOD);
     console.log(String(m.telemetry(JSON.parse(process.env.FIX)).untimed_events));
   ')" "1"
assert_eq "and events_counted says how many survived, so the two numbers can be compared" \
  "$(field "$MIXED_OUT" events_counted)" "2"
# NON-ZERO CONTROL, and it is what makes untimed_events a verdict rather than a constant: a
# record whose every event parses reports ZERO.
assert_eq "CONTROL: a record with no dropped events reports untimed_events 0" \
  "$(MOD="$TELEMETRY" FIX="$REAL" node --input-type=module -e '
     const m = await import(process.env.MOD);
     console.log(String(m.telemetry(JSON.parse(process.env.FIX)).untimed_events));
   ')" "0"
# The second spelling of "dropped": a non-string phase. Both filters feed the same counter, so
# a battery over one spelling does not stand in for the other.
assert_eq "an event with a NON-STRING phase is counted as dropped too, not only a bad timestamp" \
  "$(MOD="$TELEMETRY" node --input-type=module -e '
     const m = await import(process.env.MOD);
     const t = m.telemetry({events:[
       {phase:"1-ba",verdict:"APPROVE",at:"2026-08-01T00:00:00Z"},
       {phase:42,verdict:"APPROVE",at:"2026-08-01T01:00:00Z"},
       {phase:"5-archive",verdict:"DONE",at:"2026-08-01T02:00:00Z"}]});
     console.log(t.untimed_events + "/" + t.events_counted + "/" + t.total_lead_time_ms);
   ')" "1/2/7200000"
# The all-untimed shape, which is the one the suite already had: it must ALSO report the count,
# or the repair covers every case except the one that was already tested.
assert_eq "the all-untimed record reports its drops as well" \
  "$(MOD="$TELEMETRY" node --input-type=module -e '
     const m = await import(process.env.MOD);
     const t = m.telemetry({events:[{phase:"1-ba",verdict:"APPROVE"},{phase:"3a-qa-tests",verdict:"APPROVE"}]});
     console.log(t.untimed_events + "/" + String(t.total_lead_time_ms));
   ')" "2/null"
# And the schema admits the field, or the orchestrator's write of this record is refused.
assert_eq "the schema declares untimed_events as a bounded integer" \
  "$(SCHEMA="$SCHEMA" node --input-type=module -e '
     import { readFileSync } from "node:fs";
     const s = JSON.parse(readFileSync(process.env.SCHEMA, "utf8"));
     const p = s.properties.telemetry.properties.untimed_events;
     console.log(p ? p.type + "/" + p.minimum : "ABSENT");
   ')" "integer/0"
# ...and telemetry is a CLOSED object, so an undeclared field would be a validation failure
# rather than a silently accepted one. That closure is what makes the assertion above matter.
assert_eq "telemetry is closed (additionalProperties false), so a new field must be declared" \
  "$(SCHEMA="$SCHEMA" node --input-type=module -e '
     import { readFileSync } from "node:fs";
     const s = JSON.parse(readFileSync(process.env.SCHEMA, "utf8"));
     console.log(String(s.properties.telemetry.additionalProperties));
   ')" "false"
# Every key telemetry() emits is declared, checked as a SET rather than one remembered name:
# the next field added is caught here whether or not anyone remembers this assertion.
assert_eq "every key telemetry() returns is declared in the schema" \
  "$(MOD="$TELEMETRY" SCHEMA="$SCHEMA" node --input-type=module -e '
     import { readFileSync } from "node:fs";
     const m = await import(process.env.MOD);
     const s = JSON.parse(readFileSync(process.env.SCHEMA, "utf8"));
     const declared = Object.keys(s.properties.telemetry.properties);
     const emitted = Object.keys(m.telemetry({events:[
       {phase:"1-ba",verdict:"APPROVE",at:"2026-08-01T00:00:00Z"},{phase:"5-archive",verdict:"DONE",at:"2026-08-01T01:00:00Z"}]}));
     const undeclared = emitted.filter(k => !declared.includes(k));
     console.log(undeclared.length ? "undeclared:" + undeclared.join(",") : "all-declared");
   ')" "all-declared"

assert_eq "no phase is credited a negative duration" \
  "$(MOD="$TELEMETRY" FIX="$BACKWARDS" node --input-type=module -e '
     const m = await import(process.env.MOD);
     const t = m.telemetry(JSON.parse(process.env.FIX));
     console.log(Object.values(t.phase_elapsed_ms).some(v => v < 0) ? "NEGATIVE" : "none");
   ')" "none"

# (5) The parser reads its labels from KNOWN_PHASES, so declaring a phase and accounting for
# it cannot drift apart. Asserted over the REAL declaration, not a copy of it.
suite "AC16(b): every phase KNOWN_PHASES declares is a label the telemetry can attribute"

# The label under test sits on the LATER event, because that is the one that CLOSES the
# interval and therefore owns it. A pair whose second event was a fixed 5-archive would test
# only that "5" is attributable, once per iteration, and report all-attributable regardless.
assert_eq "no declared phase label falls through to unattributed" \
  "$(MOD="$TELEMETRY" DISPATCH="$SCRIPTS_DIR/dispatch-model.mjs" node --input-type=module -e '
     const t = await import(process.env.MOD);
     const d = await import(process.env.DISPATCH);
     const bad = d.KNOWN_PHASES.filter(p => {
       const r = t.telemetry({events:[{phase:"0-start",verdict:"OK",at:"2026-08-01T00:00:00Z"},{phase:p+"-x",verdict:"APPROVE",at:"2026-08-01T01:00:00Z"}]});
       return r.phase_elapsed_ms[p] !== 3600000;
     });
     console.log(bad.length ? "unattributable:" + bad.join(",") : "all-attributable");
   ')" "all-attributable"
assert_eq "CONTROL: a label NOT in KNOWN_PHASES is not attributable, so the check above discriminates" \
  "$(MOD="$TELEMETRY" node --input-type=module -e '
     const t = await import(process.env.MOD);
     const r = t.telemetry({events:[{phase:"5-archive",verdict:"DONE",at:"2026-08-01T00:00:00Z"},{phase:"7q-x",verdict:"APPROVE",at:"2026-08-01T01:00:00Z"}]});
     console.log(Object.keys(r.phase_elapsed_ms).length === 0 ? "not-attributed" : "attributed");
   ')" "not-attributed"
assert_eq "3a and 3b are declared, which is what makes them attributable rather than a special case" \
  "$(DISPATCH="$SCRIPTS_DIR/dispatch-model.mjs" node --input-type=module -e '
     const d = await import(process.env.DISPATCH);
     console.log(["3a","3b"].every(p => d.KNOWN_PHASES.includes(p)) ? "declared" : "MISSING");
   ')" "declared"

suite "AC16(b): the partition holds over the REAL status.json corpus, not only over fixtures"

# Over every status.json this checkout actually has, so the property is measured against what
# the orchestrator writes rather than against what this file imagines it writes. The corpus
# SIZE is asserted first: a "0 imbalanced" over an empty corpus is a zero with no control.
#
# THE CORPUS IS THE UNION of the tracked set and what is on disk, built by the one helper at
# the top of this file. It used to be `git ls-files` and nothing else, which is a population
# that structurally cannot contain an in-flight record -- and before that it was an on-disk
# path that existed only on the machine this suite was written on, which made the `tests`
# workflow RED from the commit that introduced it. The union is the shape that is right in a
# fresh clone (where it equals the tracked set exactly, so CI's population is unchanged) AND on
# a developer's machine, where the record that has never been committed is the one that matters.
CORPUS_FILES=()
while IFS= read -r f; do [[ -n "$f" ]] && CORPUS_FILES+=("$REPO_ROOT/$f"); done \
  < <(corpus_files "$REPO_ROOT" '.pipeline/*/status.json')
# THE WALK IS A FILE, not an inline `-e`, for one reason: it is driven over the LIVE corpus
# AND over a crafted temp tree below. An inline copy per population is two implementations
# asserting each other, and the crafted cell exists precisely because the live one cannot be
# made to contain a half-written record on demand.
PARTITION="$TEMP_PROJECT/partition.mjs"
cat > "$PARTITION" <<'EOF'
import { readFileSync } from "node:fs";
const m = await import(process.env.MOD);
let scanned = 0, imbalanced = 0, withSuffixed = 0, untimed = 0, unreadable = 0, tooShort = 0;
for (const f of process.argv.slice(2)) {
  // Every `continue` below increments a counter. An unreported skip and a pass produce the
  // same output, so the six numbers must add up to the file count and the assertions check
  // that they do -- otherwise a record could leave this loop without being accounted for.
  let st; try { st = JSON.parse(readFileSync(f, "utf8")); } catch { unreadable++; continue; }
  if (!Array.isArray(st.events) || st.events.length < 2) { tooShort++; continue; }
  const t = m.telemetry(st);
  // A record whose events carry no parseable `at` has no lead time to partition, and one
  // such file is really in this corpus.
  if (t.total_lead_time_ms === null) { untimed++; continue; }
  scanned++;
  const sum = Object.values(t.phase_elapsed_ms).reduce((a, b) => a + b, 0);
  if (sum + t.unattributed_ms !== t.total_lead_time_ms) imbalanced++;
  if (Object.keys(t.phase_elapsed_ms).some(k => /[a-z]/.test(k))) withSuffixed++;
}
console.log(JSON.stringify({ scanned, imbalanced, withSuffixed, untimed, unreadable, tooShort }));
EOF
CORPUS_PARTITION=$(MOD="$TELEMETRY" node "$PARTITION" "${CORPUS_FILES[@]}")

assert_eq "the real corpus is non-empty (a zero over an empty corpus proves nothing)" \
  "$([[ "$(field "$CORPUS_PARTITION" scanned)" -ge 1 ]] && echo "scanned>=1" || echo "scanned=0: NOTHING WAS WALKED")" \
  "scanned>=1"
assert_eq "no real status.json has unaccounted-for time" "$(field "$CORPUS_PARTITION" imbalanced)" "0"
# EVERY file handed in leaves the loop through exactly one counter. Without this the three
# `continue` branches are places where "checked and fine" and "never checked" look the same.
assert_eq "every corpus file is accounted for by one of the counters: none fell through" \
  "$(( $(field "$CORPUS_PARTITION" scanned) + $(field "$CORPUS_PARTITION" untimed) \
     + $(field "$CORPUS_PARTITION" unreadable) + $(field "$CORPUS_PARTITION" tooShort) ))" \
  "${#CORPUS_FILES[@]}"
assert_eq "and the corpus is more than one file, so it is a population rather than an example" \
  "$([[ "${#CORPUS_FILES[@]}" -ge 2 ]] && echo ">=2" || echo "only ${#CORPUS_FILES[@]}")" ">=2"
# The skipped records are NAMED as numbers rather than left invisible, so the pass above is
# read against how much of the corpus it actually covered.
assert_eq "the records with no parseable timestamps are counted, not silently dropped from the pass" \
  "$([[ "$(field "$CORPUS_PARTITION" untimed)" -ge 0 ]] && echo counted || echo unreported)" "counted"
# A PROPERTY, not an absolute count. `untimed == 1` was a number over a population this helper
# widens, and it survived the widening only by luck -- the newly-included records happen to have
# parseable timestamps. So it is expressed as a floor that NAMES the record which carries it,
# and the name is checked live below: a stale name then fails loudly instead of passing
# confidently about a corpus that no longer contains it.
assert_eq "at least one record has no parseable timestamps, so the counter is a verdict" \
  "$([[ "$(field "$CORPUS_PARTITION" untimed)" -ge 1 ]] && echo ">=1" || echo "untimed=0: the corpus no longer carries an untimed record")" \
  ">=1"
assert_eq "and .pipeline/exp-script-test-coverage/status.json is the record that carries it" \
  "$(MOD="$TELEMETRY" R="$REPO_ROOT/.pipeline/exp-script-test-coverage/status.json" node --input-type=module -e '
     import { readFileSync } from "node:fs";
     const m = await import(process.env.MOD);
     console.log(m.telemetry(JSON.parse(readFileSync(process.env.R,"utf8"))).untimed_events > 0 ? "yes" : "no");
   ')" "yes"
# The same treatment for the counters one line below, which were pinned at 0/0 over the LIVE
# corpus. Under the union that is a bet on how far every run on this machine has progressed: a
# genuinely short in-flight record is a normal state this pipeline produces routinely, and it
# would redden here for a reason that has nothing to do with the partition.
#
# `unreadable` IS THE SAME BET, and it was the one left pinned. The union widened the corpus to
# untracked in-flight records; commands/pipeline.md rewrites exactly those, non-atomically, at
# every phase transition; and run.sh is the Stop-hook checkCommand that runs DURING a live
# pipeline run. Reader and writer overlap BY DESIGN, so a half-written record is a normal
# transient and a pin here reports "a corpus file is unreadable" -- a defect -- when the true
# state is a partial write. Reproduced unforced (the first run.sh in this worktree read
# passed=98 failed=1) and then deterministically, by planting a truncated record.
#
# So both are REPORTED. The property the pin was standing in for is asserted where it can be
# constructed on demand instead: over the crafted tree below, where an unreadable record is
# COUNTED rather than thrown on or silently skipped. CI cannot reach any of this -- a fresh
# clone is never mid-write -- which is why the crafted cell has to exist rather than being
# left to the live population.
printf '  note  live corpus records that did not parse: %s (REPORTED, never pinned -- see the crafted cell below)\n' \
  "$(field "$CORPUS_PARTITION" unreadable)"
printf '  note  live corpus records too short to partition: %s (REPORTED, never pinned)\n' \
  "$(field "$CORPUS_PARTITION" tooShort)"
# Stated rather than assumed, and it is a present-tense fact about the corpus that must stay
# true: this run's own record carries 3a/3b, so if this number ever reads 0 the corpus has been
# replaced by one that cannot exercise the defect this section exists for.
assert_eq "at least one real record carries a suffixed phase key (3a/3b), the shape that used to vanish" \
  "$([[ "$(field "$CORPUS_PARTITION" withSuffixed)" -ge 1 ]] && echo "present" || echo "ABSENT: the corpus no longer exercises the defect")" \
  "present"

suite "AC16(b) CRAFTED: the partition ACCOUNTS for a half-written record instead of pinning it away"

# The population the live corpus cannot be made to contain on demand, built on demand: one
# record of each kind the walk can meet, including the PARTIALLY-WRITTEN one that a phase
# transition produces while this suite is reading. The same walk runs over it, so this is the
# live assertion's own implementation and not a restatement of it.
PART_TREE="$TEMP_PROJECT/partition-tree/.pipeline"
mkdir -p "$PART_TREE/good" "$PART_TREE/truncated" "$PART_TREE/short" "$PART_TREE/untimed"
printf '%s' '{"current_phase":"4-review","events":[
  {"phase":"1-ba","verdict":"APPROVE","at":"2026-08-02T00:00:00Z"},
  {"phase":"3a-qa","verdict":"APPROVE","at":"2026-08-02T00:10:00Z"},
  {"phase":"4-review","verdict":"APPROVE","at":"2026-08-02T00:30:00Z"}]}' \
  > "$PART_TREE/good/status.json"
# Byte-for-byte what a non-atomic rewrite leaves behind mid-write: valid prefix, no terminator.
printf '%s' '{"current_phase":"3-impl","events":[' > "$PART_TREE/truncated/status.json"
printf '%s' '{"current_phase":"1-ba","events":[{"phase":"1-ba","verdict":"APPROVE","at":"2026-08-02T00:00:00Z"}]}' \
  > "$PART_TREE/short/status.json"
printf '%s' '{"current_phase":"2-review","events":[{"phase":"1-ba","verdict":"APPROVE"},{"phase":"2-review","verdict":"APPROVE"}]}' \
  > "$PART_TREE/untimed/status.json"
CRAFTED=$(MOD="$TELEMETRY" node "$PARTITION" \
  "$PART_TREE/good/status.json" "$PART_TREE/truncated/status.json" \
  "$PART_TREE/short/status.json" "$PART_TREE/untimed/status.json")

# The point of the cell: a record that does not parse is COUNTED. It does not throw the walk,
# and it does not leave through a silent skip -- the two outcomes a bare `catch {}` cannot be
# told apart from a clean read.
assert_eq "AC16(b) CRAFTED: a half-written record is counted as unreadable, not thrown on" \
  "$(field "$CRAFTED" unreadable)" "1"
assert_eq "AC16(b) CRAFTED: and the other three land in their own counters" \
  "$(field "$CRAFTED" scanned)/$(field "$CRAFTED" tooShort)/$(field "$CRAFTED" untimed)" "1/1/1"
assert_eq "AC16(b) CRAFTED: so all four are accounted for, none fell through" \
  "$(( $(field "$CRAFTED" scanned) + $(field "$CRAFTED" untimed) \
     + $(field "$CRAFTED" unreadable) + $(field "$CRAFTED" tooShort) ))" "4"
assert_eq "AC16(b) CRAFTED: and the partition still balances on the record that could be read" \
  "$(field "$CRAFTED" imbalanced)" "0"

# THE NON-ZERO CONTROL, and the reason the counts above are not four constants: repair the one
# truncated byte-range and the SAME walk reports a different partition. Without it, a walk that
# hard-coded `unreadable: 1` would satisfy every assertion above.
printf '%s' '{"current_phase":"4-review","events":[
  {"phase":"1-ba","verdict":"APPROVE","at":"2026-08-02T00:00:00Z"},
  {"phase":"4-review","verdict":"APPROVE","at":"2026-08-02T00:20:00Z"}]}' \
  > "$PART_TREE/truncated/status.json"
CRAFTED_FIXED=$(MOD="$TELEMETRY" node "$PARTITION" \
  "$PART_TREE/good/status.json" "$PART_TREE/truncated/status.json" \
  "$PART_TREE/short/status.json" "$PART_TREE/untimed/status.json")
assert_eq "AC16(b) CRAFTED CONTROL: finish that write and the same walk reports 0 unreadable, 2 scanned" \
  "$(field "$CRAFTED_FIXED" unreadable)/$(field "$CRAFTED_FIXED" scanned)" "0/2"

# =============================================================================
# AC43 -- the two migration sets are recorded as DISTINCT entries.
# =============================================================================
suite "AC43: effective_config records the tripwire set and the gate set separately"

eff() { MOD="$TELEMETRY" CFG="$1" node --input-type=module -e '
  const m = await import(process.env.MOD);
  console.log(JSON.stringify(m.effectiveConfig(JSON.parse(process.env.CFG))));
'; }
EFF_CUSTOM=$(eff '{"migrationGlobs":["db/changes/**"]}')
EFF_NONE=$(eff '{}')
same_sets() { printf '%s' "$1" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const c=JSON.parse(s);console.log(JSON.stringify(c.migration_globs_tripwire)===JSON.stringify(c.migration_globs_gate)?"equal":"different")})'; }

assert_eq "under a narrowing config the two entries DIFFER" "$(same_sets "$EFF_CUSTOM")" "different"
# NON-ZERO CONTROL, and it is what makes the assertion about DISTINCTNESS rather than presence:
# under no config the same two entries are equal, and the check must be watched telling the
# two cases apart.
assert_eq "under no config at all they are equal" "$(same_sets "$EFF_NONE")" "equal"
assert_contains "both keys exist by name" "$EFF_CUSTOM" "migration_globs_tripwire"
assert_contains "and the gate's set is the narrowed one" "$EFF_CUSTOM" '"migration_globs_gate":["db/changes/**"]'

suite "AC33: the schema REFUSES an unexpected property inside effective_config"

assert_eq "effective_config is closed (additionalProperties false)" \
  "$(SCHEMA="$SCHEMA" node --input-type=module -e '
     import { readFileSync } from "node:fs";
     const s = JSON.parse(readFileSync(process.env.SCHEMA, "utf8"));
     console.log(String(s.properties.effective_config.additionalProperties));
   ')" "false"
assert_eq "and its model values are allowlisted, so the audit record cannot carry a full model ID" \
  "$(SCHEMA="$SCHEMA" node --input-type=module -e '
     import { readFileSync } from "node:fs";
     const s = JSON.parse(readFileSync(process.env.SCHEMA, "utf8"));
     console.log(s.properties.effective_config.properties.models.additionalProperties.enum.join("/"));
   ')" "opus/sonnet/haiku"
assert_eq "CONTROL: a sibling object in the same schema is NOT closed, so 'false' means something" \
  "$(SCHEMA="$SCHEMA" node --input-type=module -e '
     import { readFileSync } from "node:fs";
     const s = JSON.parse(readFileSync(process.env.SCHEMA, "utf8"));
     console.log(String(s.properties.peer_review_verdict_counts.additionalProperties));
   ')" "undefined"

# =============================================================================
# AC34 -- NO ABSOLUTE PATHS IN status.json, over the REAL corpus.
# =============================================================================
suite "AC34: no string at any depth in a status.json looks like an absolute path"

# The walk is the same one in both directions: it runs over the REAL corpus (every tracked
# .pipeline/*/status.json and every knowledge/issue-archive/*.json) AND over two crafted
# fixtures it must redden on. A fixture-only check is a test whose fixture never constructs
# the collision it claims to test.
WALK="$TEMP_PROJECT/walk.mjs"
cat > "$WALK" <<'EOF'
import { readFileSync } from "node:fs";
const ABS = [/^\//, /^[A-Za-z]:\\/];
const hits = [];
function walk(v, path) {
  if (typeof v === "string") { if (ABS.some(re => re.test(v))) hits.push(path + "=" + v); return; }
  if (Array.isArray(v)) return v.forEach((x, i) => walk(x, path + "[" + i + "]"));
  if (v && typeof v === "object") return Object.entries(v).forEach(([k, x]) => walk(x, path + "." + k));
}
let scanned = 0, unreadable = 0;
// slice(2), not slice(1): this walk is invoked as `node walk.mjs <file>...`, so argv[1] is
// walk.mjs itself. It was slice(1), and the walk read its own source as a corpus record every
// run -- invisible, because the catch swallowed it and nothing counted what the catch caught.
for (const f of process.argv.slice(2)) {
  // A record this walk could not READ is a record it did not CHECK, and the two used to be
  // indistinguishable: the catch incremented nothing, so a truncated status.json carrying a
  // real absolute path left the loop looking exactly like a clean one. It is counted now, and
  // the accounting assertion below is what makes the count mean something.
  try { walk(JSON.parse(readFileSync(f, "utf8")), f); scanned++; } catch { unreadable++; }
}
console.log(JSON.stringify({ scanned, unreadable, hits }));
EOF

# BOTH patterns here, and that is the criterion rather than a detail: dropping the archive one
# would narrow the population this walk exists to cover, inside the change that fixes a
# narrowed population.
CORPUS=()
while IFS= read -r f; do [[ -n "$f" ]] && CORPUS+=("$REPO_ROOT/$f"); done \
  < <(corpus_files "$REPO_ROOT" '.pipeline/*/status.json' 'knowledge/issue-archive/*.json')
CORPUS_RESULT=$(node "$WALK" "${CORPUS[@]}" 2>/dev/null)
SCANNED=$(printf '%s' "$CORPUS_RESULT" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).scanned))')
UNREADABLE=$(printf '%s' "$CORPUS_RESULT" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).unreadable))')
HITS=$(printf '%s' "$CORPUS_RESULT" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).hits.join(" ")))')

# The corpus size is REPORTED, not assumed. If the archive is still empty the suite says so
# rather than reporting a silent pass over nothing: this number is carried by the .pipeline
# status files plus however many archives exist, and the archive half is counted just below.
assert_eq "the real corpus is non-empty (a zero over an empty corpus proves nothing)" \
  "$([[ "$SCANNED" -ge 1 ]] && echo "scanned>=1" || echo "scanned=$SCANNED: NOTHING WAS WALKED")" "scanned>=1"

# THE ARCHIVE HALF IS DERIVED, NEVER PINNED. This site read `git ls-files | grep -c
# 'knowledge/issue-archive/.*\.json$'` against a literal 0, described in its own comment as
# "stated rather than assumed" -- a tripwire meant to fire exactly once, on the day the first
# archive landed. It fired. Pinning the new number rebuilds the same tripwire one higher, and
# the old form was counting the wrong population regardless: it read the TRACKED set while the
# walk above reads the tracked/on-disk union, so an untracked archive carrying a real leaked
# path sat outside the number and inside the walk. It was reproduced exactly that way.
#
# The durable claim is the RELATION, not the size: every archive record the corpus enumerates
# is a record this walk READ. An archive is a terminal record written in one writeFileSync, so
# unlike the in-flight .pipeline half there is no legitimate unreadable case to excuse here,
# and a walk that read fewer than it enumerated goes red rather than reporting a clean pass
# over records it never opened.
ARCHIVE_CORPUS=()
while IFS= read -r f; do [[ -n "$f" ]] && ARCHIVE_CORPUS+=("$REPO_ROOT/$f"); done \
  < <(corpus_files "$REPO_ROOT" 'knowledge/issue-archive/*.json')
scanned_of() {
  node "$WALK" "$@" 2>/dev/null \
    | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).scanned))'
}
ARCHIVE_SCANNED=$(scanned_of ${ARCHIVE_CORPUS[@]+"${ARCHIVE_CORPUS[@]}"})
printf '  note  archive records this walk enumerated: %s (REPORTED, never pinned)\n' "${#ARCHIVE_CORPUS[@]}"
assert_eq "every archive record the corpus enumerates is one this walk read" \
  "read=$ARCHIVE_SCANNED of=${#ARCHIVE_CORPUS[@]}" "read=${#ARCHIVE_CORPUS[@]} of=${#ARCHIVE_CORPUS[@]}"
# NON-ZERO CONTROL, and it is what keeps the cell above from being vacuous while the archive
# directory is empty: 0-of-0 passes for the same reason 3-of-3 does, so the accounting is put
# in front of a record it CANNOT read and must report the shortfall.
printf '%s' '{"issue_number":34,"tasks":{' > "$TEMP_PROJECT/archive-unreadable.json"
assert_eq "CONTROL: the same accounting reports a shortfall on an archive record it cannot read" \
  "read=$(scanned_of "$TEMP_PROJECT/archive-unreadable.json") of=1" "read=0 of=1"
# EVERY RECORD LEAVES THIS WALK THROUGH ONE COUNTER, the same six-counter convention the
# partition walk above uses. The catch used to increment nothing and `scanned` was asserted
# only `>= 1`, so a record the walk never read was indistinguishable from a clean one: a
# truncated status.json carrying worktree_path="/Users/leaked/secret-client-name" was planted
# in this corpus and the hits assertion below stayed green. The corpus is a set of paths this
# file just listed, so anything not scanned and not counted unreadable is a hole in the walk.
assert_eq "every corpus record is accounted for: scanned + unreadable equals the corpus size" \
  "$(( SCANNED + UNREADABLE ))" "${#CORPUS[@]}"
# ...and the unreadable half is REPORTED, not pinned to 0. The corpus includes UNTRACKED
# in-flight records that a live phase transition rewrites non-atomically while this suite is
# the Stop-hook checkCommand reading them, so a half-written record here is a transient rather
# than a defect. Pinning it red-lights a normal state; counting it keeps the claim honest.
printf '  note  corpus records this walk could not parse, and therefore did not check: %s (REPORTED)\n' \
  "$UNREADABLE"
# NAMED FOR WHAT IT ENFORCES. It is a statement about the records that PARSED, and the count
# above says how many that was.
assert_eq "no absolute-path string appears in any corpus record this walk could read" "$HITS" ""

# NON-ZERO CONTROL, in two spellings, because a check anchored on '/Users/' alone is a
# blocklist over one spelling of one machine's layout.
FIX1="$TEMP_PROJECT/abs-users.json"
printf '%s' '{"current_phase":"3-impl","worktree_path":"/Users/someone/worktrees/x"}' > "$FIX1"
FIX2="$TEMP_PROJECT/abs-var.json"
printf '%s' '{"current_phase":"3-impl","events":[{"phase":"3-impl","verdict":"APPROVE","note":"/var/folders/z/tmp"}]}' > "$FIX2"
assert_contains "CONTROL: the same walk reddens on /Users/..." "$(node "$WALK" "$FIX1")" "/Users/someone/worktrees/x"
assert_contains "CONTROL: and on /var/folders/... at depth, inside an array" "$(node "$WALK" "$FIX2")" "/var/folders/z/tmp"

# THE EXEMPTION, MADE VISIBLE AND BOUNDED. A record that does not parse is not checked, and no
# rewording changes that; what the counter changes is whether the walk SAYS so. The pair below
# is the same leaked path in two files that differ only by the closing bytes.
FIX3="$TEMP_PROJECT/abs-truncated.json"
printf '%s' '{"current_phase":"3-impl","worktree_path":"/Users/leaked/secret-client-name","events":[' > "$FIX3"
TRUNC_RESULT=$(node "$WALK" "$FIX3")
assert_eq "CONTROL: a truncated record is COUNTED unreadable rather than silently exempted" \
  "$(printf '%s' "$TRUNC_RESULT" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const r=JSON.parse(s);console.log(r.scanned+"/"+r.unreadable+"/"+r.hits.length)})')" \
  "0/1/0"
# ...and the SAME bytes, terminated, do produce the hit. Without this half, the cell above
# would also pass on a walk whose absolute-path predicate had stopped working altogether.
FIX4="$TEMP_PROJECT/abs-terminated.json"
printf '%s' '{"current_phase":"3-impl","worktree_path":"/Users/leaked/secret-client-name","events":[]}' > "$FIX4"
assert_contains "CONTROL: finish that same write and the leak IS reported" \
  "$(node "$WALK" "$FIX4")" "/Users/leaked/secret-client-name"

suite "AC34(b): an absolute glob in a project config is never written through"

EFF_ABS=$(eff '{"migrationGlobs":["/Users/x/repo/db/migrations/**"]}')
assert_not_contains "the absolute glob string does not reach effective_config" "$EFF_ABS" "/Users/x/repo"
assert_contains "it is replaced by the rejection token" "$EFF_ABS" "<absolute-glob-rejected>"
assert_contains "and the rejection is counted, so it is reportable rather than silent" "$EFF_ABS" '"rejected_absolute_globs":'
assert_eq "CONTROL: an ordinary glob is recorded verbatim" \
  "$(printf '%s' "$(eff '{"migrationGlobs":["db/changes/**"]}')" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).migration_globs_gate.join(",")))')" \
  "db/changes/**"

suite "AC23: the redaction claim is gone, replaced by a prohibition that can go red"

assert_eq "the schema no longer claims worktree_path should be redacted" \
  "$(grep -c 'should be redacted before this file is archived' "$SCHEMA" | tr -d ' ')" "0"
assert_contains "it carries a writer prohibition instead" "$(cat "$SCHEMA")" "must never carry an absolute filesystem path"
# Scoped to the SHIPPED tree, not the suites: this file quotes the deleted sentence in its own
# header, and a grep that counted itself would be un-passable for the wrong reason.
assert_eq "and nothing shipped claims a redaction step exists in code" \
  "$(grep -rl 'redacted before this file is archived' "$PLUGIN_DIR/scripts" "$PLUGIN_DIR/schemas" "$PLUGIN_DIR/commands" "$PLUGIN_DIR/agents" 2>/dev/null | wc -l | tr -d ' ')" "0"

suite "SecOps nit: worktree_path has a SHAPE, and the orchestrator is told what it is"

# The field was typed as a repo-relative path, is not in `required`, and no code reads it out
# of status.json -- every consumer reads it from tasks.json. The orchestrator had no
# instruction either way and wrote an English sentence into it, which is a free-text note in a
# field the schema types as a path.
assert_eq "worktree_path is not required, so omitting it is legal" \
  "$(SCHEMA="$SCHEMA" node --input-type=module -e '
     import { readFileSync } from "node:fs";
     const s = JSON.parse(readFileSync(process.env.SCHEMA, "utf8"));
     console.log(s.required.includes("worktree_path") ? "required" : "optional");
   ')" "optional"
assert_eq "CONTROL: a field that IS required reads as required, so the check discriminates" \
  "$(SCHEMA="$SCHEMA" node --input-type=module -e '
     import { readFileSync } from "node:fs";
     const s = JSON.parse(readFileSync(process.env.SCHEMA, "utf8"));
     console.log(s.required.includes("current_phase") ? "required" : "optional");
   ')" "required"
assert_contains "the schema says the field is preferably omitted and names where the path really lives" \
  "$(cat "$SCHEMA")" "preferably OMITTED: no code reads this field from status.json"
assert_contains "the orchestrator is told to omit it" "$(cat "$PIPELINE_MD")" \
  "Do not write \`worktree_path\` into \`status.json\`. OMIT the field."
assert_contains "and told the only legal alternative is a repo-relative path" "$(cat "$PIPELINE_MD")" \
  "it must be a REPO-RELATIVE path"
# CODE CHECK for the "nothing reads it" claim, over the shipped tree. tasks.json is the reader,
# and the one script that does touch a worktree_path reads the artifact it was handed, not
# status.json.
# -h, not -n alone (#117): grep -r prefixes each hit with the ABSOLUTE path it was given, so
# the second grep was matching this repo's own CHECKOUT DIRECTORY. Measured: identical sources
# report 0 at /Users/.../agent-pipeline and 8 from a worktree named `i117-status-check`, and the
# eight hits were in validate-pipeline-artifact.mjs and knowledge-store.mjs, neither of which
# had changed. The needle belongs to the LINE CONTENT, which is what this assertion means; -h
# drops the path and keeps -n's line number. It matters more now that scripts/ holds a file
# whose own NAME carries the needle (check-status-record.mjs).
assert_eq "no shipped script reads worktree_path out of a status file" \
  "$(grep -rhn 'worktree_path' "$PLUGIN_DIR/scripts" 2>/dev/null | grep -c 'status' | tr -d ' ')" "0"
assert_eq "CONTROL: the same grep DOES find the field being read somewhere, so the zero is not vacuous" \
  "$([[ "$(grep -rc 'worktree_path' "$PLUGIN_DIR/scripts"/*.mjs 2>/dev/null | grep -v ':0$' | wc -l | tr -d ' ')" -ge 1 ]] && echo found || echo "nothing reads it anywhere")" \
  "found"

# Over the REAL corpus: where the field is present at all, it must look like a repo-relative
# path -- not absolute, and not a sentence. Asserted as an OUTCOME property rather than as a
# blocklist over the one sentence that was actually written, which would pass the next one.
SHAPE_WALK="$TEMP_PROJECT/wt-shape.mjs"
cat > "$SHAPE_WALK" <<'EOF'
import { readFileSync } from "node:fs";
let present = 0, malformed = 0;
for (const f of process.argv.slice(1)) {
  let s; try { s = JSON.parse(readFileSync(f, "utf8")); } catch { continue; }
  if (typeof s.worktree_path !== "string") continue;
  present++;
  const v = s.worktree_path;
  if (/^\//.test(v) || /^[A-Za-z]:\\/.test(v) || /\s/.test(v)) malformed++;
}
console.log(JSON.stringify({ present, malformed }));
EOF
WT_CORPUS=()
while IFS= read -r f; do [[ -n "$f" ]] && WT_CORPUS+=("$REPO_ROOT/$f"); done \
  < <(corpus_files "$REPO_ROOT" '.pipeline/*/status.json')
WT_SHAPE=$(node "$SHAPE_WALK" "${WT_CORPUS[@]}" 2>/dev/null)
assert_eq "no real status.json carries a malformed worktree_path (absolute, or containing spaces)" \
  "$(field "$WT_SHAPE" malformed)" "0"
# NON-ZERO CONTROLS in both spellings the property forbids, because "0 malformed" over a corpus
# where the field is absent everywhere is a zero with nothing behind it.
WT_FIX1="$TEMP_PROJECT/wt-abs.json"
printf '%s' '{"worktree_path":"/Users/x/.claude/worktrees/42"}' > "$WT_FIX1"
WT_FIX2="$TEMP_PROJECT/wt-sentence.json"
printf '%s' '{"worktree_path":"(recorded in tasks.json; omitted here)"}' > "$WT_FIX2"
WT_FIX3="$TEMP_PROJECT/wt-ok.json"
printf '%s' '{"worktree_path":".claude/worktrees/42-phase3-20260101-120000"}' > "$WT_FIX3"
assert_eq "CONTROL: the same walk reddens on an absolute path" \
  "$(field "$(node "$SHAPE_WALK" "$WT_FIX1")" malformed)" "1"
assert_eq "CONTROL: and on the English sentence that was actually written into it" \
  "$(field "$(node "$SHAPE_WALK" "$WT_FIX2")" malformed)" "1"
assert_eq "CONTROL: and PASSES a well-formed repo-relative path, so it is not refusing everything" \
  "$(field "$(node "$SHAPE_WALK" "$WT_FIX3")" malformed)" "0"
# ...and that pass is over a field the walk actually SAW: `malformed=0` is also what an absent
# field returns, so the two cases have to be told apart.
assert_eq "and it saw the field there, so that 0 is a verdict rather than an absence" \
  "$(field "$(node "$SHAPE_WALK" "$WT_FIX3")" present)" "1"

# =============================================================================
# AC17 / AC32 -- the archival path is untouched, and the config file is a tier trigger.
# =============================================================================
suite "AC17: the archival path is untouched"

assert_eq "'status' is still an ARCHIVE_ARTIFACTS entry, on the line that defines the list" \
  "$(grep -c 'const ARCHIVE_ARTIFACTS = .*"status"' "$SCRIPTS_DIR/knowledge-store.mjs" | tr -d ' ')" "1"
assert_eq "CONTROL: the same grep reports 0 for an artifact that is NOT archived" \
  "$(grep -c 'const ARCHIVE_ARTIFACTS = .*"design_gate"' "$SCRIPTS_DIR/knowledge-store.mjs" | tr -d ' ')" "0"

suite "AC32: pipeline.config.json is itself an architectural trigger, in BOTH configs"

trigger_paths() { node --input-type=module -e '
  import { readFileSync } from "node:fs";
  const c = JSON.parse(readFileSync(process.env.F, "utf8"));
  const p = (c.architecturalTriggers && c.architecturalTriggers.paths) || [];
  console.log(p.join(","));
'; }
assert_eq "this repo's own config lists it" "$(F="$REPO_ROOT/pipeline.config.json" trigger_paths)" "pipeline.config.json"
assert_eq "and so does the shipped example" "$(F="$PLUGIN_DIR/pipeline.config.example.json" trigger_paths)" "pipeline.config.json"
assert_contains "and the orchestrator states the rule where the tier is decided" \
  "$(cat "$PIPELINE_MD")" "A diff that touches \`pipeline.config.json\` itself is architectural, always"
# NON-ZERO CONTROL: the trigger is a specific path, not a rule that promotes every diff.
assert_eq "CONTROL: README.md is not in the trigger list" \
  "$([[ "$(F="$REPO_ROOT/pipeline.config.json" trigger_paths)" == *"README"* ]] && echo listed || echo "not-listed")" "not-listed"

finish
